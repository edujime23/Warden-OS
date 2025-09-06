-- devices/intc/intc.lua
-- Simple interrupt controller (level-latched). 32 sources max by default.
-- MMIO register map (little-endian 32-bit).

local bit32 = bit32

---@class InterruptController
---@field base integer
---@field size integer
---@field sources integer
---@field pending_lo integer
---@field pending_hi integer
---@field enable_lo integer
---@field enable_hi integer
---@field regs table<integer, integer>
---@field stats table
local InterruptController = {}
InterruptController.__index = InterruptController

local SIZE = 0x20

local PENDING_LO = 0x00
local PENDING_HI = 0x04
local ENABLE_LO  = 0x08
local ENABLE_HI  = 0x0C
local CLAIM      = 0x10
local COMPLETE   = 0x14

local function to_u32(x) return bit32.band(x or 0, 0xFFFFFFFF) end

local function first_set_bit(mask)
    if mask == 0 then return 0 end
    for i = 0, 31 do
        if bit32.band(mask, bit32.lshift(1, i)) ~= 0 then
            return i + 1
        end
    end
    return 0
end

function InterruptController:new(base, opts)
    opts = opts or {}
    local self_ = {
        base = base,
        size = SIZE,
        sources = math.max(1, math.min(64, opts.sources or 32)),
        pending_lo = 0,
        pending_hi = 0,
        enable_lo  = 0,
        enable_hi  = 0,
        regs = {},
        stats = { reads = 0, read_bytes = 0, writes = 0, write_bytes = 0 }
    }
    setmetatable(self_, InterruptController)

    for i = 0, self_.size - 1 do self_.regs[i] = 0 end
    self_:_sync_to_regs()
    return self_
end

function InterruptController:get_region() return self.base, self.size end

function InterruptController:get_mmio_caps()
    return { align = 4, widths = { 4 } }
end

function InterruptController:raise(id)
    if id < 1 or id > self.sources then return end
    if id <= 32 then
        self.pending_lo = bit32.bor(self.pending_lo, bit32.lshift(1, id - 1))
    else
        self.pending_hi = bit32.bor(self.pending_hi, bit32.lshift(1, id - 33))
    end
end

function InterruptController:lower(id)
    if id < 1 or id > self.sources then return end
    if id <= 32 then
        self.pending_lo = bit32.band(self.pending_lo, bit32.bnot(bit32.lshift(1, id - 1)))
    else
        self.pending_hi = bit32.band(self.pending_hi, bit32.bnot(bit32.lshift(1, id - 33)))
    end
end

local function pack32(val)
    return {
        bit32.band(val, 0xFF),
        bit32.band(bit32.rshift(val, 8), 0xFF),
        bit32.band(bit32.rshift(val, 16), 0xFF),
        bit32.band(bit32.rshift(val, 24), 0xFF)
    }
end

local function unpack32(bytes)
    local b0 = bytes[1] or 0
    local b1 = bytes[2] or 0
    local b2 = bytes[3] or 0
    local b3 = bytes[4] or 0
    return bit32.bor(b0, bit32.lshift(b1, 8), bit32.lshift(b2, 16), bit32.lshift(b3, 24))
end

function InterruptController:_sync_to_regs()
    local function poke(off, val)
        local p = pack32(val)
        self.regs[off + 0] = p[1]
        self.regs[off + 1] = p[2]
        self.regs[off + 2] = p[3]
        self.regs[off + 3] = p[4]
    end
    poke(PENDING_LO, self.pending_lo)
    poke(PENDING_HI, self.pending_hi)
    poke(ENABLE_LO,  self.enable_lo)
    poke(ENABLE_HI,  self.enable_hi)
end

function InterruptController:_claim_value()
    local eff_lo = bit32.band(self.pending_lo, self.enable_lo)
    local eff_hi = bit32.band(self.pending_hi, self.enable_hi)
    local id = first_set_bit(eff_lo)
    if id == 0 then
        local id_hi = first_set_bit(eff_hi)
        if id_hi ~= 0 then id = 32 + id_hi end
    end
    return id
end

function InterruptController:read(offset, count)
    self:_sync_to_regs()
    local out = {}
    local n = 0
    local claim_val = nil

    for i = 0, count - 1 do
        local addr = offset + i
        local b
        if addr >= CLAIM and addr < (CLAIM + 4) then
            if claim_val == nil then claim_val = self:_claim_value() end
            local shift = (addr - CLAIM) * 8
            b = bit32.band(bit32.rshift(claim_val, shift), 0xFF)
        else
            b = self.regs[addr] or 0
        end
        out[#out + 1] = b
        n = n + 1
    end

    self.stats.reads = self.stats.reads + 1
    self.stats.read_bytes = self.stats.read_bytes + n
    return out
end

function InterruptController:write(offset, bytes)
    local n = #bytes
    for i = 1, n do
        local a = offset + (i - 1)
        if a >= 0 and a < self.size then
            self.regs[a] = bit32.band(bytes[i], 0xFF)
        end
    end

    if n >= 4 then
        local val = unpack32(bytes)
        if offset == ENABLE_LO then
            self.enable_lo = to_u32(val)
        elseif offset == ENABLE_HI then
            self.enable_hi = to_u32(val)
        elseif offset == COMPLETE then
            local id = val
            if id >= 1 and id <= self.sources then
                self:lower(id)
            end
        end
    end

    self.stats.writes = self.stats.writes + 1
    self.stats.write_bytes = self.stats.write_bytes + n
end

return InterruptController