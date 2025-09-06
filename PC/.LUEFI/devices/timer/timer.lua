-- devices/timer/timer.lua
-- Simple MMIO timer: 64-bit counter with compare/IRQ, auto-reload, and tick increment.

local bit32 = bit32

---@class Timer
---@field base integer
---@field size integer
---@field regs table<integer, integer>
---@field counter_lo integer
---@field counter_hi integer
---@field compare_lo integer
---@field compare_hi integer
---@field tick integer
---@field enable boolean
---@field irq_enable boolean
---@field auto_reload boolean
---@field irq_pending boolean
---@field irq_sink { dev: any, id: integer }|nil
---@field _irq_level boolean
---@field stats table
local Timer = {}
Timer.__index = Timer

local SIZE = 0x20

local CNT_LO  = 0x00
local CNT_HI  = 0x04
local CMP_LO  = 0x08
local CMP_HI  = 0x0C
local CTRL    = 0x10
local STATUS  = 0x14
local TICK    = 0x18

local function to_u32(x) return bit32.band(x or 0, 0xFFFFFFFF) end

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

function Timer:new(base, opts)
    opts = opts or {}
    local self_ = {
        base = base, size = SIZE, regs = {},
        counter_lo = 0, counter_hi = 0,
        compare_lo = 0, compare_hi = 0,
        tick = to_u32(opts.tick or 1),
        enable = false, irq_enable = false, auto_reload = false,
        irq_pending = false, irq_sink = opts.irq_sink, _irq_level = false,
        stats = { reads = 0, read_bytes = 0, writes = 0, write_bytes = 0, advances = 0 }
    }
    setmetatable(self_, Timer)
    for i = 0, self_.size - 1 do self_.regs[i] = 0 end
    self_:_sync_to_regs()
    self_:_update_irq_line()
    return self_
end

function Timer:get_region() return self.base, self.size end
function Timer:get_mmio_caps() return { align = 4, widths = { 4 } } end

function Timer:attach_irq(plic, id)
    self.irq_sink = { dev = plic, id = id }
    self:_update_irq_line()
end

function Timer:_poke32(off, val)
    self.regs[off + 0] = bit32.band(val, 0xFF)
    self.regs[off + 1] = bit32.band(bit32.rshift(val, 8), 0xFF)
    self.regs[off + 2] = bit32.band(bit32.rshift(val, 16), 0xFF)
    self.regs[off + 3] = bit32.band(bit32.rshift(val, 24), 0xFF)
end

function Timer:_peek32(off)
    local b0 = self.regs[off + 0] or 0
    local b1 = self.regs[off + 1] or 0
    local b2 = self.regs[off + 2] or 0
    local b3 = self.regs[off + 3] or 0
    return bit32.bor(b0, bit32.lshift(b1, 8), bit32.lshift(b2, 16), bit32.lshift(b3, 24))
end

function Timer:_update_irq_line()
    local sink = self.irq_sink
    if not sink then return end
    local level = (self.irq_enable and self.irq_pending) and true or false
    if level ~= self._irq_level then
        if level then sink.dev:raise(sink.id) else sink.dev:lower(sink.id) end
        self._irq_level = level
    end
end

function Timer:_sync_to_regs()
    self:_poke32(CNT_LO, self.counter_lo)
    self:_poke32(CNT_HI, self.counter_hi)
    local status_val = self.irq_pending and 0x1 or 0x0
    self:_poke32(STATUS, status_val)
    local ctrl = (self.enable and 1 or 0) + (self.irq_enable and 2 or 0) + (self.auto_reload and 4 or 0)
    self:_poke32(CTRL, ctrl)
    self:_poke32(TICK, self.tick)
    self:_poke32(CMP_LO, self.compare_lo)
    self:_poke32(CMP_HI, self.compare_hi)
end

function Timer:_sync_from_regs(last_write_off, wrote_bytes)
    local ctrl = self:_peek32(CTRL)
    self.enable      = bit32.band(ctrl, 0x1) ~= 0
    self.irq_enable  = bit32.band(ctrl, 0x2) ~= 0
    self.auto_reload = bit32.band(ctrl, 0x4) ~= 0

    self.tick = to_u32(self:_peek32(TICK))
    if self.tick == 0 then self.tick = 1 end

    self.compare_lo = to_u32(self:_peek32(CMP_LO))
    self.compare_hi = to_u32(self:_peek32(CMP_HI))

    if last_write_off and last_write_off <= STATUS and (last_write_off + wrote_bytes - 1) >= STATUS then
        local w = self:_peek32(STATUS)
        if bit32.band(w, 0x1) ~= 0 then
            self.irq_pending = false
        end
    end
    self:_update_irq_line()
end

function Timer:read(offset, count)
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

function Timer:write(offset, bytes)
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

function Timer:advance(ticks)
    ticks = math.max(0, ticks or 0)
    if not self.enable or ticks == 0 then return end
    for _ = 1, ticks do
        self.counter_hi, self.counter_lo = add64(self.counter_hi, self.counter_lo, self.tick, 0)
        if (self.compare_hi ~= 0 or self.compare_lo ~= 0) then
            if cmp64(self.counter_hi, self.counter_lo, self.compare_hi, self.compare_lo) >= 0 then
                self.irq_pending = true
                if self.auto_reload then
                    self.counter_hi, self.counter_lo = 0, 0
                end
            end
        end
    end
    self.stats.advances = self.stats.advances + ticks
    self:_sync_to_regs()
    self:_update_irq_line()
end

function Timer:get_irq_pending()
    return self.irq_pending and self.irq_enable or false
end

return Timer