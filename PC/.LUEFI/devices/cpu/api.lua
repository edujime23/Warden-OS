-- devices/cpu/api.lua
-- CPU base class and public API for implementers.
-- Provides MMU/TLB + cache hierarchy integration and typed load/store/fetch.
-- Extend CPUBase to implement a real pipeline (decode/execute).

local TargetSel = require("devices.cpu.target")
local MMU       = require("devices.cpu.mmu")
local Cache     = require("devices.cpu.cache_controller")

---@class IBackend
---@field read_bytes fun(self: IBackend, phys_addr: integer, count: integer): integer[]  -- return array of bytes (1..n)
---@field write_bytes fun(self: IBackend, phys_addr: integer, bytes: integer[])          -- write array of bytes

---@class PagePerm
---@field write boolean|nil
---@field execute boolean|nil
---@field user boolean|nil
---@field cached boolean|nil

---@class CPUStats
---@field target { isa: string, xlen: integer, endianness: string }
---@field mmu table
---@field cache table

---@class CPUBase
---@field target table                   -- ISA target (endianness, xlen, pack/unpack)
---@field backend IBackend               -- Memory/bus backend
---@field mmu MMU                        -- Virtual memory manager
---@field icache CacheController         -- Instruction-side cache view
---@field dcache CacheController         -- Data-side cache view (same controller)
local CPUBase = {}
CPUBase.__index = CPUBase

---Create a new CPUBase.
---@param opts { target?: string|table, backend: IBackend, cache?: table, mmu?: table }
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
    }

    -- One controller exposes L1D/L1I/L2/L3 (inclusive).
    local cache = Cache:new(self_.backend, opts.cache or {})
    self_.icache = cache
    self_.dcache = cache

    return setmetatable(self_, CPUBase)
end

-- ========= Virtual hooks (override in subclasses) =========

---Reset CPU state (registers, PC, state machines). No default state here.
---@param _state any|nil
function CPUBase:reset(_state)
    -- Intentionally empty: architecture-specific CPUs define their own reset.
end

---Execute one cycle/step (fetch->decode->execute). Must be overridden by real CPUs.
function CPUBase:step()
    error("CPUBase:step() not implemented. Override in your CPU subclass.")
end

-- ========= Public memory operations (VA) =========

---Fetch instruction bytes from virtual address VA.
---@param va integer
---@param size integer|nil @ default 4
---@return integer[] bytes
function CPUBase:fetch(va, size)
    size = size or 4
    local pa, pte = self.mmu:translate(va)
    if not pte.executable then error("Execute permission denied") end
    if pte.cached then
        return self:_cache_read_bytes(pa, size, "l1i")
    else
        return self.backend:read_bytes(pa, size)
    end
end

---Load an integer from virtual address VA with size and signedness.
---@param va integer
---@param size integer @ 1|2|4|8
---@param signed boolean|nil
---@return integer
function CPUBase:load(va, size, signed)
    local pa, pte = self.mmu:translate(va)
    local bytes
    if pte.cached then
        bytes = self:_cache_read_bytes(pa, size, "l1d")
    else
        bytes = self.backend:read_bytes(pa, size)
    end
    return self.target:unpack_int(bytes, signed and true or false)
end

---Store an integer to virtual address VA.
---@param va integer
---@param size integer @ 1|2|4|8
---@param value integer
---@param signed boolean|nil
function CPUBase:store(va, size, value, signed)
    local pa, pte = self.mmu:translate(va)
    if not pte.writable then error("Write permission denied") end
    local bytes = self.target:pack_int(value, size, signed and true or false)
    if pte.cached then
        self:_cache_write_bytes(pa, bytes)
    else
        self.backend:write_bytes(pa, bytes)
    end
    pte.dirty = true
end

-- ========= MMU helpers =========

---Map a virtual page to a frame with permissions.
---@param vpage integer
---@param pframe integer|nil
---@param perm PagePerm|nil
---@return integer frame
function CPUBase:map_page(vpage, pframe, perm)
    return self.mmu:map_page(vpage, pframe, perm)
end

---Unmap a virtual page.
---@param vpage integer
---@return boolean
function CPUBase:unmap_page(vpage)
    return self.mmu:unmap_page(vpage)
end

---Translate virtual address to physical address.
---@param va integer
---@return integer pa, table pte
function CPUBase:translate(va)
    return self.mmu:translate(va)
end

---Set PTE attributes for a mapped virtual page.
---@param vpage integer
---@param attr PagePerm
function CPUBase:set_page_attributes(vpage, attr)
    self.mmu:set_page_attributes(vpage, attr)
end

-- ========= Cache/TLB maintenance =========

function CPUBase:flush_icache() self.icache:flush_all("l1i") end
function CPUBase:flush_dcache() self.dcache:flush_all("l1d") end
function CPUBase:flush_l2()     self.dcache:flush_all("l2")  end
function CPUBase:flush_l3()     self.dcache:flush_all("l3")  end
function CPUBase:flush_tlb()    self.mmu:flush_tlb()         end

---Prefetch (advisory).
---@param va integer
function CPUBase:prefetch_data(va)
    local pa = (self.mmu:translate(va))
    self.dcache:read(pa, 0, "l1d")
end

---Prefetch (advisory).
---@param va integer
function CPUBase:prefetch_inst(va)
    local pa = (self.mmu:translate(va))
    self.icache:read(pa, 0, "l1i")
end

---Get CPU stats.
---@return CPUStats
function CPUBase:get_stats()
    return {
        target = { isa = self.target.isa, xlen = self.target.xlen, endianness = self.target.endianness },
        mmu = self.mmu:get_statistics(),
        cache = self.dcache:get_statistics()
    }
end

-- ========= Low-level helpers (PA) =========

-- Read arbitrary byte count via cache hierarchy (handles line splits).
---@param pa integer
---@param size integer
---@param which "l1d"|"l1i"
---@return integer[] bytes
function CPUBase:_cache_read_bytes(pa, size, which)
    local cache = (which == "l1i") and self.icache or self.dcache
    local line_size = cache.levels[which].line_size
    local remain, addr, idx = size, pa, 1
    local out = {}
    while remain > 0 do
        local block = addr - (addr % line_size)
        local line  = cache:read(addr, 0, which)   -- full line
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

-- Write a vector of bytes via cache hierarchy (handles line splits).
---@param pa integer
---@param bytes integer[]
function CPUBase:_cache_write_bytes(pa, bytes)
    self.dcache:write_bytes(pa, bytes, "l1d")
end

return CPUBase