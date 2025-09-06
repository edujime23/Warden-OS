-- devices/intc/plic.lua
-- RISC-V PLIC-like interrupt controller (single CPU, multi-context).

local bit32 = bit32

---@class PLIC
---@field base integer
---@field size integer
---@field sources integer
---@field contexts integer
---@field layout "compact"|"canonical"
---@field mode "level"|"latched"
---@field off table
---@field prio integer[]
---@field pend_lo integer
---@field pend_hi integer
---@field en_lo integer[]
---@field en_hi integer[]
---@field threshold integer[]
---@field line_high boolean[]
---@field regs table<integer, integer>
---@field stats table
local PLIC = {}
PLIC.__index = PLIC

local function to_u32(x) return bit32.band(x or 0, 0xFFFFFFFF) end
local function pack32(v) return { bit32.band(v,0xFF), bit32.band(bit32.rshift(v,8),0xFF), bit32.band(bit32.rshift(v,16),0xFF), bit32.band(bit32.rshift(v,24),0xFF) } end
local function unpack32(b) return bit32.bor(b[1] or 0, bit32.lshift(b[2] or 0, 8), bit32.lshift(b[3] or 0, 16), bit32.lshift(b[4] or 0, 24)) end
local function bit_set(mask, i) return bit32.band(mask, bit32.lshift(1, i)) ~= 0 end

local function offsets_for_layout(layout)
    layout = (layout or "compact"):lower()
    if layout == "canonical" then
        return { OFF_PRIORITY_BASE=0x0000, OFF_PENDING_LO=0x1000, OFF_PENDING_HI=0x1004, OFF_CTX_BASE=0x2000, CTX_STRIDE=0x1000, CTX_ENABLE_LO=0x000, CTX_ENABLE_HI=0x004, CTX_THRESHOLD=0x008, CTX_CLAIM=0x00C, CTX_COMPLETE=0x010 }
    else
        return { OFF_PRIORITY_BASE=0x000,  OFF_PENDING_LO=0x100,  OFF_PENDING_HI=0x104,  OFF_CTX_BASE=0x180,  CTX_STRIDE=0x20,   CTX_ENABLE_LO=0x00,  CTX_ENABLE_HI=0x04,  CTX_THRESHOLD=0x08,  CTX_CLAIM=0x0C,  CTX_COMPLETE=0x10 }
    end
end

function PLIC:new(base, opts)
    opts = opts or {}
    local nsrc = math.max(1, math.min(64, opts.sources or 32))
    local nctx = math.max(1, math.min(8,  opts.contexts or 2))
    local layout = (opts.layout or "compact")
    local mode   = (opts.mode   or "level")

    local self_ = {
        base = base, sources = nsrc, contexts = nctx, layout = layout, mode = mode,
        off = offsets_for_layout(layout),
        prio = {}, pend_lo = 0, pend_hi = 0, en_lo = {}, en_hi = {}, threshold = {}, line_high = {},
        regs = {}, stats = { reads = 0, read_bytes = 0, writes = 0, write_bytes = 0 }
    }
    setmetatable(self_, PLIC)

    local off = self_.off
    local prio_end = off.OFF_PRIORITY_BASE + nsrc * 4
    local pend_end = off.OFF_PENDING_HI + 4
    local ctx_end  = off.OFF_CTX_BASE + nctx * off.CTX_STRIDE
    self_.size = math.max(prio_end, math.max(pend_end, ctx_end))

    for i = 0, self_.size - 1 do self_.regs[i] = 0 end
    for i = 1, nsrc do self_.prio[i] = 0; self_.line_high[i] = false end
    for c = 1, nctx do self_.en_lo[c] = 0; self_.en_hi[c] = 0; self_.threshold[c] = 0 end

    self_:_sync_to_regs()
    return self_
end

function PLIC:get_region() return self.base, self.size end
function PLIC:get_mmio_caps() return { align = 4, widths = { 4 } } end

function PLIC:_set_pending(id, on)
    if id <= 32 then
        local bit = bit32.lshift(1, id - 1)
        self.pend_lo = on and bit32.bor(self.pend_lo, bit) or bit32.band(self.pend_lo, bit32.bnot(bit))
    else
        local b = id - 33
        local bit = bit32.lshift(1, b)
        self.pend_hi = on and bit32.bor(self.pend_hi, bit) or bit32.band(self.pend_hi, bit32.bnot(bit))
    end
end

function PLIC:raise(id)
    if id < 1 or id > self.sources then return end
    local was = self.line_high[id]; self.line_high[id] = true
    if self.mode == "level" or not was then self:_set_pending(id, true) end
end
function PLIC:lower(id)
    if id < 1 or id > self.sources then return end
    self.line_high[id] = false
    if self.mode == "level" then self:_set_pending(id, false) end
end

function PLIC:_claim_value(ctx)
    local best_id, best_pr = 0, -1
    local en_lo = self.en_lo[ctx + 1] or 0
    local en_hi = self.en_hi[ctx + 1] or 0
    local threshold = self.threshold[ctx + 1] or 0
    for i = 1, self.sources do
        local p = self.prio[i] or 0
        if p > threshold and p > 0 then
            local enabled = (i <= 32) and bit_set(en_lo, i - 1) or bit_set(en_hi, i - 33)
            local pending = (i <= 32) and (bit32.band(self.pend_lo, bit32.lshift(1, i - 1)) ~= 0)
                                      or  (bit32.band(self.pend_hi, bit32.lshift(1, i - 33)) ~= 0)
            if enabled and pending then
                if p > best_pr or (p == best_pr and i < best_id) then best_id, best_pr = i, p end
            end
        end
    end
    return best_id
end

function PLIC:get_context_irq(ctx)
    return self:_claim_value(ctx or 0) ~= 0
end

function PLIC:_sync_to_regs()
    local off = self.off
    local function poke(addr, val)
        local p = pack32(val)
        self.regs[addr + 0] = p[1]; self.regs[addr + 1] = p[2]
        self.regs[addr + 2] = p[3]; self.regs[addr + 3] = p[4]
    end
    poke(off.OFF_PENDING_LO, self.pend_lo)
    poke(off.OFF_PENDING_HI, self.pend_hi)
    for ctx = 0, self.contexts - 1 do
        local base = off.OFF_CTX_BASE + ctx * off.CTX_STRIDE
        poke(base + off.CTX_ENABLE_LO, self.en_lo[ctx + 1] or 0)
        poke(base + off.CTX_ENABLE_HI, self.en_hi[ctx + 1] or 0)
        poke(base + off.CTX_THRESHOLD, self.threshold[ctx + 1] or 0)
    end
end

function PLIC:read(offset, count)
    self:_sync_to_regs()
    local out = {}
    local off = self.off
    local prio_end = off.OFF_PRIORITY_BASE + self.sources * 4

    local claimed_ctx = nil
    local claimed_id  = 0

    for i = 0, count - 1 do
        local addr = offset + i
        local b = 0

        if addr >= off.OFF_PRIORITY_BASE and addr < prio_end then
            local idx = math.floor((addr - off.OFF_PRIORITY_BASE) / 4) + 1
            if idx >= 1 and idx <= self.sources then
                local word_off = (idx - 1) * 4
                local shift = (addr - off.OFF_PRIORITY_BASE - word_off) * 8
                local val = to_u32(self.prio[idx] or 0)
                b = bit32.band(bit32.rshift(val, shift), 0xFF)
            end

        elseif addr >= off.OFF_PENDING_LO and addr < (off.OFF_PENDING_LO + 4) then
            local shift = (addr - off.OFF_PENDING_LO) * 8
            b = bit32.band(bit32.rshift(self.pend_lo, shift), 0xFF)

        elseif addr >= off.OFF_PENDING_HI and addr < (off.OFF_PENDING_HI + 4) then
            local shift = (addr - off.OFF_PENDING_HI) * 8
            b = bit32.band(bit32.rshift(self.pend_hi, shift), 0xFF)

        elseif addr >= off.OFF_CTX_BASE and addr < (off.OFF_CTX_BASE + self.contexts * off.CTX_STRIDE) then
            local rel = addr - off.OFF_CTX_BASE
            local ctx = math.floor(rel / off.CTX_STRIDE)
            local coff = rel % off.CTX_STRIDE
            local base = off.OFF_CTX_BASE + ctx * off.CTX_STRIDE

            if coff == off.CTX_CLAIM or coff == off.CTX_CLAIM + 1 or coff == off.CTX_CLAIM + 2 or coff == off.CTX_CLAIM + 3 then
                if claimed_ctx == nil then
                    claimed_ctx = ctx
                    claimed_id  = self:_claim_value(ctx)
                    if self.mode == "latched" and claimed_id ~= 0 then
                        self:_set_pending(claimed_id, false)
                    end
                end
                local shift = (addr - (base + off.CTX_CLAIM)) * 8
                b = bit32.band(bit32.rshift(claimed_id, shift), 0xFF)
            else
                b = self.regs[addr] or 0
            end
        end

        out[#out + 1] = b
    end

    self.stats.reads = self.stats.reads + 1
    self.stats.read_bytes = self.stats.read_bytes + count
    return out
end

function PLIC:write(offset, bytes)
    local n = #bytes; if n < 4 then self.stats.writes = self.stats.writes + 1; self.stats.write_bytes = self.stats.write_bytes + n; return end
    local val = unpack32(bytes)
    local off = self.off
    local prio_end = off.OFF_PRIORITY_BASE + self.sources * 4

    if offset >= off.OFF_PRIORITY_BASE and offset < prio_end then
        local idx = math.floor((offset - off.OFF_PRIORITY_BASE) / 4) + 1
        if idx >= 1 and idx <= self.sources then self.prio[idx] = to_u32(val) end

    elseif offset >= off.OFF_CTX_BASE and offset < (off.OFF_CTX_BASE + self.contexts * off.CTX_STRIDE) then
        local rel = offset - off.OFF_CTX_BASE
        local ctx = math.floor(rel / off.CTX_STRIDE)
        local coff = rel % off.CTX_STRIDE

        if coff == off.CTX_ENABLE_LO then
            self.en_lo[ctx + 1] = to_u32(val)
        elseif coff == off.CTX_ENABLE_HI then
            self.en_hi[ctx + 1] = to_u32(val)
        elseif coff == off.CTX_THRESHOLD then
            self.threshold[ctx + 1] = to_u32(val)
        elseif coff == off.CTX_COMPLETE then
            if self.mode == "latched" then
                local id = to_u32(val)
                if id >= 1 and id <= self.sources then
                    if self.line_high[id] then self:_set_pending(id, true) else self:_set_pending(id, false) end
                end
            end
        end
    end

    self.stats.writes = self.stats.writes + 1
    self.stats.write_bytes = self.stats.write_bytes + n
end

return PLIC