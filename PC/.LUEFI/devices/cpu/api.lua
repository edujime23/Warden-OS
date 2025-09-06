-- devices/cpu/api.lua
-- CPU base class and public API for implementers.
-- MMU/TLB + cache hierarchy, memory types, prefetcher, and store buffer (WC).

local TargetSel = require("devices.cpu.target")
local MMU       = require("devices.cpu.mmu")
local Cache     = require("devices.cpu.cache_controller")
local CSRMod    = require("devices.cpu.csr")

---@class IBackend
---@field read_bytes fun(self: IBackend, phys_addr: integer, count: integer): integer[]
---@field write_bytes fun(self: IBackend, phys_addr: integer, bytes: integer[])

---@class PagePerm
---@field write boolean|nil
---@field execute boolean|nil
---@field user boolean|nil
---@field cached boolean|nil
---@field memtype "normal"|"device"|"wc"|nil

---@class CPUStats
---@field target { isa: string, xlen: integer, endianness: string }
---@field mmu table
---@field cache table

---@class CPUBase
---@field target table
---@field backend IBackend
---@field mmu MMU
---@field icache CacheController
---@field dcache CacheController
---@field prefetch_cfg { enable: boolean, to: "l1d"|"l2"|"l3" }
---@field _wc_buf { base: integer|nil, bytes: integer[]|nil, line_size: integer }
---@field irq_ctrl { kind: "plic", dev: any, base: integer, layout: "compact"|"canonical", off: table, ctx_id: integer }|nil
---@field clint_ctrl { dev: any, hart: integer }|nil
---@field csr any
local CPUBase = {}
CPUBase.__index = CPUBase

---Create a new CPUBase.
---@param opts { target?: string|table, backend: IBackend, cache?: table, mmu?: table, prefetch?: { enable?: boolean, to?: "l1d"|"l2"|"l3" } }
---@return CPUBase
function CPUBase:new(opts)
    opts = opts or {}
    assert(opts.backend and opts.backend.read_bytes and opts.backend.write_bytes, "CPU: backend with read_bytes/write_bytes required")

    local target = opts.target
    if type(target) == "string" or target == nil then
        target = TargetSel.select(target or "rv64")
    end

    local self_ = {
        target  = target,
        backend = opts.backend,
        mmu     = MMU:new(opts.mmu or {}),
        prefetch_cfg = { enable = true, to = "l2" },
        _wc_buf = { base = nil, bytes = nil, line_size = 64 },
        irq_ctrl = nil,
        clint_ctrl = nil,
        csr = CSRMod.CSR:new(target)
    }
    -- prefetch config
    if opts.prefetch then
        if opts.prefetch.enable ~= nil then self_.prefetch_cfg.enable = opts.prefetch.enable end
        if opts.prefetch.to     ~= nil then self_.prefetch_cfg.to     = opts.prefetch.to     end
    end

    -- One controller exposes L1D/L1I/L2/L3 (inclusive).
    local cache = Cache:new(self_.backend, opts.cache or {})
    -- adopt line size for WC buffer (use L1D)
    self_._wc_buf.line_size = cache.levels.l1d.line_size

    self_.icache = cache
    self_.dcache = cache

    -- Ensure ASID 0 exists
    self_.mmu:set_asid(0)

    return setmetatable(self_, CPUBase)
end

-- ========= Virtual hooks =========
function CPUBase:reset(_state) end
function CPUBase:step() error("CPUBase:step() not implemented. Override in your CPU subclass.") end

-- ========= ASID management =========
function CPUBase:set_asid(asid)
    self.mmu:set_asid(asid)
end

-- ========= Public memory operations (VA) =========

function CPUBase:fetch(va, size)
    size = size or 4
    local pa, pte = self.mmu:translate(va)
    if not pte.executable then error("Execute permission denied") end
    if pte.cached and pte.memtype == "normal" then
        local b = self:_cache_read_bytes(pa, size, "l1i")
        self:_maybe_prefetch(pa, pte, "l1i")
        return b
    else
        return self.backend:read_bytes(pa, size)
    end
end

function CPUBase:load(va, size, signed)
    local pa, pte = self.mmu:translate(va)
    local bytes
    if pte.cached and pte.memtype == "normal" then
        bytes = self:_cache_read_bytes(pa, size, "l1d")
        self:_maybe_prefetch(pa, pte, "l1d")
    else
        bytes = self.backend:read_bytes(pa, size)
    end
    return self.target:unpack_int(bytes, signed and true or false)
end

function CPUBase:store(va, size, value, signed)
    local pa, pte = self.mmu:translate(va)
    if not pte.writable then error("Write permission denied") end
    local bytes = self.target:pack_int(value, size, signed and true or false)

    if pte.memtype == "device" then
        self:memory_barrier()  -- ensure prior WC writes are visible
        self.backend:write_bytes(pa, bytes)
        return
    elseif pte.memtype == "wc" then
        self:_wc_store(pa, bytes)
        return
    end

    if pte.cached then
        self:_cache_write_bytes(pa, bytes)
    else
        self.backend:write_bytes(pa, bytes)
    end
    pte.dirty = true
end

-- ========= MMU helpers =========
function CPUBase:map_page(vpage, pframe, perm, asid) return self.mmu:map_page(vpage, pframe, perm, asid) end
function CPUBase:unmap_page(vpage, asid) return self.mmu:unmap_page(vpage, asid) end
function CPUBase:translate(va) return self.mmu:translate(va) end
function CPUBase:set_page_attributes(vpage, attr, asid) self.mmu:set_page_attributes(vpage, attr, asid) end

-- ========= Cache/TLB maintenance =========
function CPUBase:flush_icache() self.icache:flush_all("l1i") end
function CPUBase:flush_dcache() self.dcache:flush_all("l1d") end
function CPUBase:flush_l2()     self.dcache:flush_all("l2")  end
function CPUBase:flush_l3()     self.dcache:flush_all("l3")  end
function CPUBase:flush_tlb(asid) self.mmu:flush_tlb(asid)    end

function CPUBase:prefetch_data(va)
    local pa, pte = self.mmu:translate(va)
    if pte.memtype == "normal" and pte.cached then
        self:_maybe_prefetch(pa, pte, "l1d")
    end
end

function CPUBase:prefetch_inst(va)
    local pa, pte = self.mmu:translate(va)
    if pte.memtype == "normal" and pte.cached then
        self:_maybe_prefetch(pa, pte, "l1i")
    end
end

function CPUBase:get_stats()
    return {
        target = { isa = self.target.isa, xlen = self.target.xlen, endianness = self.target.endianness },
        mmu = self.mmu:get_statistics(),
        cache = self.dcache:get_statistics()
    }
end

-- ========= Low-level helpers (PA) =========
function CPUBase:_cache_read_bytes(pa, size, which)
    local cache = (which == "l1i") and self.icache or self.dcache
    local line_size = cache.levels[which].line_size
    local remain, addr, idx = size, pa, 1
    local out = {}
    while remain > 0 do
        local block = addr - (addr % line_size)
        local line  = cache:read(addr, 0, which)
        local off   = addr - block
        local chunk = math.min(remain, line_size - off)
        for i = 0, chunk - 1 do
            out[idx + i] = line[off + 1 + i]
        end
        idx   = idx + chunk
        remain = remain - chunk
        addr  = addr + chunk
    end
    return out
end

function CPUBase:_cache_write_bytes(pa, bytes)
    self.dcache:write_bytes(pa, bytes, "l1d")
end

function CPUBase:_maybe_prefetch(pa, pte, which)
    if not self.prefetch_cfg.enable then return end
    if pte.memtype ~= "normal" or not pte.cached then return end
    local cache = (which == "l1i") and self.icache or self.dcache
    local line_size = cache.levels[which].line_size
    local block = pa - (pa % line_size)
    local next_pa = block + line_size
    if self.mmu:get_page_number(pa) ~= self.mmu:get_page_number(next_pa) then return end
    local to_level = self.prefetch_cfg.to or "l2"
    cache:prefetch_line(to_level, next_pa)
end

-- ========= Write-combining buffer =========
function CPUBase:_wc_flush()
    local buf = self._wc_buf
    if buf.base and buf.bytes and #buf.bytes > 0 then
        self.backend:write_bytes(buf.base, buf.bytes)
    end
    buf.base, buf.bytes = nil, nil
end

function CPUBase:memory_barrier()
    self:_wc_flush()
end

function CPUBase:_wc_store(pa, bytes)
    local buf = self._wc_buf
    local line_size = buf.line_size
    if not buf.base or not buf.bytes then
        buf.base, buf.bytes = pa, { table.unpack(bytes) }
        return
    end
    local next_expected = buf.base + #buf.bytes
    local same_line = (math.floor(pa / line_size) == math.floor(buf.base / line_size))
    if pa == next_expected and same_line then
        for i = 1, #bytes do buf.bytes[#buf.bytes + 1] = bytes[i] end
    else
        self:_wc_flush()
        buf.base, buf.bytes = pa, { table.unpack(bytes) }
    end
end

-- ========= Interrupt controller (PLIC/CLINT) integration =========

function CPUBase:_plic_offsets(layout)
    layout = (layout or "compact"):lower()
    if layout == "canonical" then
        return {
            OFF_PRIORITY_BASE = 0x0000,
            OFF_PENDING_LO    = 0x1000,
            OFF_PENDING_HI    = 0x1004,
            OFF_CTX_BASE      = 0x2000,
            CTX_STRIDE        = 0x1000,
            CTX_ENABLE_LO     = 0x000,
            CTX_ENABLE_HI     = 0x004,
            CTX_THRESHOLD     = 0x008,
            CTX_CLAIM         = 0x00C,
            CTX_COMPLETE      = 0x010
        }
    else
        return {
            OFF_PRIORITY_BASE = 0x000,
            OFF_PENDING_LO    = 0x100,
            OFF_PENDING_HI    = 0x104,
            OFF_CTX_BASE      = 0x180,
            CTX_STRIDE        = 0x20,
            CTX_ENABLE_LO     = 0x00,
            CTX_ENABLE_HI     = 0x04,
            CTX_THRESHOLD     = 0x08,
            CTX_CLAIM         = 0x0C,
            CTX_COMPLETE      = 0x10
        }
    end
end

---Attach a PLIC-like controller for CPU polling and MEIP aggregation.
---@param plic any
---@param base integer
---@param opts { layout?: "compact"|"canonical", ctx_id?: integer }|nil
function CPUBase:attach_plic(plic, base, opts)
    opts = opts or {}
    self.irq_ctrl = {
        kind = "plic",
        dev = plic,
        base = base,
        layout = (opts.layout or "compact"),
        off = self:_plic_offsets(opts.layout),
        ctx_id = opts.ctx_id or 0
    }
end

---Attach CLINT for MSIP/MTIP aggregation.
---@param clint any
---@param opts { hart?: integer }|nil
function CPUBase:attach_clint(clint, opts)
    opts = opts or {}
    self.clint_ctrl = { dev = clint, hart = (opts.hart or 0) }
end

---Poll interrupts for a PLIC context (M-mode poller helper).
function CPUBase:poll_interrupts(ctx_id, handler)
    assert(self.irq_ctrl and self.irq_ctrl.kind == "plic", "CPU: no PLIC attached (use attach_plic)")
    local ic = self.irq_ctrl
    local off = ic.off
    local ctx_base = ic.base + off.OFF_CTX_BASE + ctx_id * off.CTX_STRIDE
    local claim_addr = ctx_base + off.CTX_CLAIM
    local complete_addr = ctx_base + off.CTX_COMPLETE

    local id = self:load(claim_addr, 4, false)
    if id ~= 0 then
        if handler then pcall(handler, id) end
        self:store(complete_addr, 4, id, false)
    end
    return id
end

---Aggregate device IRQ lines into mip (MSIP/MTIP/MEIP).
function CPUBase:sample_irqs()
    -- CLINT MSIP/MTIP
    if self.clint_ctrl and self.clint_ctrl.dev and self.clint_ctrl.dev.get_irq_levels then
        local levels = self.clint_ctrl.dev:get_irq_levels((self.clint_ctrl.hart or 0) + 1)
        self.csr:set_mip("msip", levels.msip and true or false)
        self.csr:set_mip("mtip", levels.mtip and true or false)
    end
    -- PLIC MEIP (context-level external IRQ line)
    if self.irq_ctrl and self.irq_ctrl.kind == "plic" and self.irq_ctrl.dev and self.irq_ctrl.dev.get_context_irq then
        local meip = self.irq_ctrl.dev:get_context_irq(self.irq_ctrl.ctx_id or 0)
        self.csr:set_mip("meip", meip and true or false)
    end
end

---Deliver an interrupt if enabled+pending and MIE set. Returns cause code or nil.
function CPUBase:maybe_take_interrupt()
    local cause = self.csr:should_take_interrupt()
    if not cause then return nil end
    self.csr:trap_enter(cause, true)
    return cause
end

---Return from trap (mret).
function CPUBase:complete_trap()
    self.csr:mret()
end

---Access CSR for tests/demos.
function CPUBase:csr_block()
    return self.csr
end

return CPUBase