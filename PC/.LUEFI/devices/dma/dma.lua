-- devices/dma/dma.lua
-- Simple bus-master DMA engine: single-shot mem->mem copy, optional IRQ on DONE.
-- MMIO regs (LE 32-bit): SRC_LO/H, DST_LO/H, LEN, CTRL (START/IRQ_EN), STATUS (BUSY/DONE/ERR).

local bit32 = bit32

---@class DMA
---@field base integer
---@field size integer
---@field bus any
---@field src_lo integer
---@field src_hi integer
---@field dst_lo integer
---@field dst_hi integer
---@field len integer
---@field ctrl integer
---@field status integer
---@field regs table<integer, integer>
---@field irq_sink { dev: any, id: integer }|nil
---@field _irq_level boolean
---@field stats table
---@field ram_only boolean
local DMA = {}
DMA.__index = DMA

local OFF_SRC_LO = 0x00; local OFF_SRC_HI = 0x04; local OFF_DST_LO = 0x08; local OFF_DST_HI = 0x0C;
local OFF_LEN    = 0x10; local OFF_CTRL   = 0x14; local OFF_STATUS = 0x18;
local CTRL_START = 0x1;  local CTRL_IRQ_EN  = 0x2;
local ST_BUSY = 0x1; local ST_DONE = 0x2; local ST_ERR  = 0x4;

local function pack32(val)
    return { bit32.band(val, 0xFF), bit32.band(bit32.rshift(val, 8), 0xFF), bit32.band(bit32.rshift(val, 16), 0xFF), bit32.band(bit32.rshift(val, 24), 0xFF) }
end
local function unpack32(bytes)
    return bit32.bor(bytes[1] or 0, bit32.lshift(bytes[2] or 0, 8), bit32.lshift(bytes[3] or 0, 16), bit32.lshift(bytes[4] or 0, 24))
end
local function to_u32(x) return bit32.band(x or 0, 0xFFFFFFFF) end

function DMA:new(base, bus, opts)
    assert(bus and bus.read_bytes and bus.write_bytes, "DMA: requires system bus")
    opts = opts or {}
    local self_ = {
        base = base, size = 0x20, bus  = bus, src_lo = 0, src_hi = 0, dst_lo = 0, dst_hi = 0,
        len = 0, ctrl = 0, status = 0, regs = {}, irq_sink = nil, _irq_level = false,
        stats = { starts = 0, bytes = 0, errors = 0, writes = 0, reads = 0 },
        ram_only = opts.ram_only == true
    }
    setmetatable(self_, DMA)
    return self_
end

function DMA:get_region() return self.base, self.size end
function DMA:get_mmio_caps() return { align = 4, widths = { 4 } } end

function DMA:attach_irq(plic, id)
    self.irq_sink = { dev = plic, id = id }; self:_update_irq_line()
end

local function u64(lo, hi)
    return (hi * 4294967296) + lo
end

function DMA:_update_irq_line()
    local sink = self.irq_sink; if not sink then return end
    local irq_en = (bit32.band(self.ctrl, CTRL_IRQ_EN) ~= 0)
    local level = irq_en and (bit32.band(self.status, ST_DONE) ~= 0) or false
    if level ~= self._irq_level then
        if level then sink.dev:raise(sink.id) else sink.dev:lower(sink.id) end
        self._irq_level = level
    end
end

local function range_ok_ram(bus, addr, len)
    local regions = bus:list_regions(); local a = addr; local remain = len
    while remain > 0 do
        local found = nil
        for _, r in ipairs(regions) do
            if r.kind == "ram" and a >= r.base and a <= r["end"] then
                local avail = r["end"] - a + 1; local chunk = (remain < avail) and remain or avail
                a = a + chunk; remain = remain - chunk; found = true; break
            end
        end
        if not found then return false end
    end
    return true
end

function DMA:_do_start()
    if bit32.band(self.status, ST_BUSY) ~= 0 then return end
    self.status = bit32.bor(ST_BUSY, bit32.band(self.status, bit32.bnot(ST_DONE + ST_ERR)))
    local src, dst, len = u64(self.src_lo, self.src_hi), u64(self.dst_lo, self.dst_hi), to_u32(self.len)

    if self.ram_only and len > 0 then
        if not (range_ok_ram(self.bus, src, len) and range_ok_ram(self.bus, dst, len)) then
            self.status = bit32.bor(ST_ERR, bit32.band(self.status, bit32.bnot(ST_BUSY)))
            self.stats.errors = self.stats.errors + 1; self:_update_irq_line(); return
        end
    end

    local ok, copied = true, 0
    if len > 0 then
        local addr_s, addr_d, remain = src, dst, len
        while remain > 0 do
            local chunk = math.min(remain, 256)

            -- pcall returns (ok, result)
            local ok_r, bytes = pcall(self.bus.read_bytes, self.bus, addr_s, chunk)
            if not ok_r or type(bytes) ~= "table" or #bytes ~= chunk then ok = false; break end

            local ok_w = pcall(self.bus.write_bytes, self.bus, addr_d, bytes)
            if not ok_w then ok = false; break end

            addr_s = addr_s + chunk; addr_d = addr_d + chunk
            remain = remain - chunk; copied = copied + chunk
        end
    end

    self.stats.starts = self.stats.starts + 1; self.stats.bytes = self.stats.bytes + copied
    if not ok then self.stats.errors = self.stats.errors + 1; self.status = bit32.bor(self.status, ST_ERR) end
    self.status = bit32.bor(ST_DONE, bit32.band(self.status, bit32.bnot(ST_BUSY)))
    self:_update_irq_line()
end

function DMA:read(offset, count)
    local out = {}
    for i = 0, count - 1 do
        local addr, b = offset + i, 0
        if addr >= OFF_SRC_LO and addr < OFF_SRC_LO + 4 then b = pack32(self.src_lo)[addr - OFF_SRC_LO + 1]
        elseif addr >= OFF_SRC_HI and addr < OFF_SRC_HI + 4 then b = pack32(self.src_hi)[addr - OFF_SRC_HI + 1]
        elseif addr >= OFF_DST_LO and addr < OFF_DST_LO + 4 then b = pack32(self.dst_lo)[addr - OFF_DST_LO + 1]
        elseif addr >= OFF_DST_HI and addr < OFF_DST_HI + 4 then b = pack32(self.dst_hi)[addr - OFF_DST_HI + 1]
        elseif addr >= OFF_LEN and addr < OFF_LEN + 4 then b = pack32(self.len)[addr - OFF_LEN + 1]
        elseif addr >= OFF_CTRL and addr < OFF_CTRL + 4 then b = pack32(self.ctrl)[addr - OFF_CTRL + 1]
        elseif addr >= OFF_STATUS and addr < OFF_STATUS + 4 then b = pack32(self.status)[addr - OFF_STATUS + 1] end
        out[i + 1] = b
    end
    self.stats.reads = self.stats.reads + 1
    return out
end

function DMA:write(offset, bytes)
    if #bytes >= 4 then
        local val = unpack32(bytes)
        if offset == OFF_SRC_LO then self.src_lo = to_u32(val)
        elseif offset == OFF_SRC_HI then self.src_hi = to_u32(val)
        elseif offset == OFF_DST_LO then self.dst_lo = to_u32(val)
        elseif offset == OFF_DST_HI then self.dst_hi = to_u32(val)
        elseif offset == OFF_LEN    then self.len    = to_u32(val)
        elseif offset == OFF_CTRL   then
            self.ctrl = to_u32(val)
            if bit32.band(self.ctrl, CTRL_START) ~= 0 then
                self.ctrl = bit32.band(self.ctrl, bit32.bnot(CTRL_START))
                self:_do_start()
            else
                self:_update_irq_line()
            end
        elseif offset == OFF_STATUS then
            if bit32.band(val, ST_DONE) ~= 0 then self.status = bit32.band(self.status, bit32.bnot(ST_DONE)) end
            if bit32.band(val, ST_ERR)  ~= 0 then self.status = bit32.band(self.status, bit32.bnot(ST_ERR))  end
            self:_update_irq_line()
        end
    end
    self.stats.writes = self.stats.writes + 1
end

return DMA