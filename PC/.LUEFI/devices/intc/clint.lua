-- devices/intc/clint.lua
-- RISC-V CLINT (Core Local Interruptor) stub.

local bit32 = bit32

---@class CLINT
---@field base integer
---@field size integer
---@field harts integer
---@field tick integer
---@field msip boolean[]
---@field mtimecmp_hi integer[]
---@field mtimecmp_lo integer[]
---@field mtime_hi integer
---@field mtime_lo integer
---@field regs table<integer,integer>
---@field stats table
local CLINT = {}
CLINT.__index = CLINT

local MSIP_BASE     = 0x0000
local MTIMECMP_BASE = 0x4000
local MTIME_BASE    = 0xBFF8
local SIZE          = 0xC000

local function to_u32(x) return bit32.band(x or 0, 0xFFFFFFFF) end

local function pack32(val)
    return {
        bit32.band(val, 0xFF),
        bit32.band(bit32.rshift(val, 8), 0xFF),
        bit32.band(bit32.rshift(val, 16), 0xFF),
        bit32.band(bit32.rshift(val, 24), 0xFF)
    }
end
local function pack64(hi, lo)
    local p = {}
    local w0 = pack32(lo); local w1 = pack32(hi)
    p[1], p[2], p[3], p[4] = w0[1], w0[2], w0[3], w0[4]
    p[5], p[6], p[7], p[8] = w1[1], w1[2], w1[3], w1[4]
    return p
end
local function unpack32(bytes)
    local b0 = bytes[1] or 0
    local b1 = bytes[2] or 0
    local b2 = bytes[3] or 0
    local b3 = bytes[4] or 0
    return bit32.bor(b0, bit32.lshift(b1, 8), bit32.lshift(b2, 16), bit32.lshift(b3, 24))
end
local function add64(hi, lo, add_lo, add_hi)
    local lo_sum = (lo + add_lo) % 0x100000000
    local carry = ((lo + add_lo) >= 0x100000000) and 1 or 0
    local hi_sum = (hi + add_hi + carry) % 0x100000000
    return hi_sum, lo_sum
end
local function cmp64(a_hi, a_lo, b_hi, b_lo)
    if a_hi ~= b_hi then return (a_hi > b_hi) and 1 or -1 end
    if a_lo == b_lo then return 0 end
    return (a_lo > b_lo) and 1 or -1
end

function CLINT:new(base, opts)
    opts = opts or {}
    local n_harts = math.max(1, math.min(8, opts.harts or 1))
    local self_ = {
        base = base, size = SIZE, harts = n_harts, tick = to_u32(opts.tick or 1),
        msip = {}, mtimecmp_hi = {}, mtimecmp_lo = {},
        mtime_hi = 0, mtime_lo = 0, regs = {},
        stats = { reads = 0, read_bytes = 0, writes = 0, write_bytes = 0, advances = 0 }
    }
    setmetatable(self_, CLINT)
    for i = 0, self_.size - 1 do self_.regs[i] = 0 end
    for h = 1, n_harts do self_.msip[h] = false; self_.mtimecmp_hi[h], self_.mtimecmp_lo[h] = 0, 0 end
    self_:_sync_to_regs()
    return self_
end

function CLINT:get_region() return self.base, self.size end
function CLINT:get_mmio_caps() return { align = 4, widths = { 4, 8 } } end

function CLINT:_poke32(off, val)
    self.regs[off + 0] = bit32.band(val, 0xFF)
    self.regs[off + 1] = bit32.band(bit32.rshift(val, 8), 0xFF)
    self.regs[off + 2] = bit32.band(bit32.rshift(val, 16), 0xFF)
    self.regs[off + 3] = bit32.band(bit32.rshift(val, 24), 0xFF)
end

function CLINT:_sync_to_regs()
    for h = 0, self.harts - 1 do
        local v = self.msip[h + 1] and 1 or 0
        self:_poke32(MSIP_BASE + 4 * h, v)
    end
    for h = 0, self.harts - 1 do
        local off = MTIMECMP_BASE + 8 * h
        local lo = self.mtimecmp_lo[h + 1] or 0
        local hi = self.mtimecmp_hi[h + 1] or 0
        local p = pack64(hi, lo)
        for i = 0, 7 do self.regs[off + i] = p[i + 1] end
    end
    local p = pack64(self.mtime_hi, self.mtime_lo)
    for i = 0, 7 do self.regs[MTIME_BASE + i] = p[i + 1] end
end

function CLINT:_sync_from_regs(last_off, wrote_bytes)
    for h = 0, self.harts - 1 do
        local off = MSIP_BASE + 4 * h
        if last_off <= off + 3 and (last_off + wrote_bytes - 1) >= off then
            local v = unpack32({
                self.regs[off + 0] or 0, self.regs[off + 1] or 0,
                self.regs[off + 2] or 0, self.regs[off + 3] or 0
            })
            self.msip[h + 1] = bit32.band(v, 1) ~= 0
        end
    end
    for h = 0, self.harts - 1 do
        local off = MTIMECMP_BASE + 8 * h
        if last_off <= off + 7 and (last_off + wrote_bytes - 1) >= off then
            local lo = unpack32({ self.regs[off+0], self.regs[off+1], self.regs[off+2], self.regs[off+3] })
            local hi = unpack32({ self.regs[off+4], self.regs[off+5], self.regs[off+6], self.regs[off+7] })
            self.mtimecmp_lo[h + 1] = to_u32(lo)
            self.mtimecmp_hi[h + 1] = to_u32(hi)
        end
    end
    if last_off <= MTIME_BASE + 7 and (last_off + wrote_bytes - 1) >= MTIME_BASE then
        local lo = unpack32({ self.regs[MTIME_BASE+0], self.regs[MTIME_BASE+1], self.regs[MTIME_BASE+2], self.regs[MTIME_BASE+3] })
        local hi = unpack32({ self.regs[MTIME_BASE+4], self.regs[MTIME_BASE+5], self.regs[MTIME_BASE+6], self.regs[MTIME_BASE+7] })
        self.mtime_lo = to_u32(lo); self.mtime_hi = to_u32(hi)
    end
end

function CLINT:read(offset, count)
    self:_sync_to_regs()
    local out = {}
    local n = 0
    for i = 0, count - 1 do
        local a = offset + i
        if a >= 0 and a < self.size then
            out[i + 1] = self.regs[a]
            n = n + 1
        else
            out[i + 1] = 0
        end
    end
    self.stats.reads = self.stats.reads + 1
    self.stats.read_bytes = self.stats.read_bytes + n
    return out
end

function CLINT:write(offset, bytes)
    local n = #bytes
    for i = 1, n do
        local a = offset + (i - 1)
        if a >= 0 and a < self.size then
            self.regs[a] = bit32.band(bytes[i], 0xFF)
        end
    end
    self.stats.writes = self.stats.writes + 1
    self.stats.write_bytes = self.stats.write_bytes + n
    self:_sync_from_regs(offset, n)
end

function CLINT:advance(ticks)
    ticks = math.max(0, ticks or 0)
    if ticks == 0 then return {} end
    local add = to_u32(self.tick * ticks)
    self.mtime_hi, self.mtime_lo = add64(self.mtime_hi, self.mtime_lo, add, 0)
    self.stats.advances = self.stats.advances + ticks
    self:_sync_to_regs()

    local mtip = {}
    for h = 1, self.harts do
        local cmp_hi, cmp_lo = self.mtimecmp_hi[h] or 0, self.mtimecmp_lo[h] or 0
        local level = not (cmp_hi == 0 and cmp_lo == 0) and (cmp64(self.mtime_hi, self.mtime_lo, cmp_hi, cmp_lo) >= 0) or false
        mtip[h] = level and true or false
    end
    return mtip
end

function CLINT:get_irq_levels(hart)
    local h = math.max(1, math.min(self.harts, hart or 1))
    local cmp_hi, cmp_lo = self.mtimecmp_hi[h] or 0, self.mtimecmp_lo[h] or 0
    local mtip = not (cmp_hi == 0 and cmp_lo == 0) and (cmp64(self.mtime_hi, self.mtime_lo, cmp_hi, cmp_lo) >= 0) or false
    return { msip = self.msip[h] and true or false, mtip = mtip and true or false }
end

return CLINT