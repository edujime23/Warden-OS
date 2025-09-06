-- devices/uart/uart.lua
-- Simple MMIO UART device with TX, RX FIFO and optional IRQ on RX ready.
-- Register map (little-endian):
--   0x00 DATA   (R/W)
--        - write: TX one byte
--        - read : RX one byte (non-blocking; returns 0 if empty)
--   0x04 STATUS (R)
--        bit0 = 1 (TX always ready in this model)
--        bit1 = RX ready (1 when RX FIFO non-empty)
--   0x08 CTRL   (R/W)
--        bit0 = RX IRQ enable (1=enable). IRQ asserts when RX ready.
--
-- IRQ (optional): attach via uart:attach_irq(plic, id).
-- Line asserts when (rx_irq_enable && rx_ready), deasserts when RX empties or IRQ disabled.

---@class UART
---@field base integer
---@field size integer
---@field verbose boolean
---@field on_tx fun(byte: integer)|nil
---@field stats table
---@field rx_fifo integer[]
---@field rx_capacity integer
---@field rx_irq_enable boolean
---@field irq_sink { dev: any, id: integer }|nil
---@field _irq_level boolean
local UART = {}
UART.__index = UART

local bit32 = bit32

local OFF_DATA   = 0x00
local OFF_STATUS = 0x04
local OFF_CTRL   = 0x08

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

---Create a new UART.
---@param base integer
---@param size integer|nil @ default 16
---@param opts { verbose?: boolean, on_tx?: fun(byte: integer), rx_capacity?: integer }|nil
---@return UART
function UART:new(base, size, opts)
    size = size or 16
    opts = opts or {}
    local self_ = {
        base = base,
        size = size,
        verbose = opts.verbose == true,
        on_tx = opts.on_tx,
        stats = { writes = 0, reads = 0, tx_bytes = 0, rx_bytes = 0 },
        rx_fifo = {},
        rx_capacity = math.max(1, opts.rx_capacity or 64),
        rx_irq_enable = false,
        irq_sink = nil,
        _irq_level = false
    }
    return setmetatable(self_, UART)
end

---Get device region (base, size).
function UART:get_region() return self.base, self.size end

---Strict MMIO caps: DATA allows 1B; STATUS/CTRL allow 4B.
function UART:get_mmio_caps() return { align = 1, widths = { 1, 4 } } end

---Attach a PLIC sink for automatic IRQ line driving (RX ready).
---@param plic any
---@param id integer
function UART:attach_irq(plic, id)
    self.irq_sink = { dev = plic, id = id }
    self:_update_irq_line()
end

local function printable(b)
    if b >= 32 and b <= 126 then return string.char(b) else return "." end
end

-- ========== RX helpers ==========
function UART:_rx_ready() return #self.rx_fifo > 0 end

function UART:_update_irq_line()
    local sink = self.irq_sink
    if not sink then return end
    local level = (self.rx_irq_enable and self:_rx_ready()) and true or false
    if level ~= self._irq_level then
        if level then sink.dev:raise(sink.id) else sink.dev:lower(sink.id) end
        self._irq_level = level
    end
end

---Feed RX with bytes (table of 0..255 or string).
function UART:feed_bytes(data)
    if type(data) == "string" then
        for i = 1, #data do
            if #self.rx_fifo < self.rx_capacity then
                self.rx_fifo[#self.rx_fifo + 1] = string.byte(data, i)
            end
        end
    elseif type(data) == "table" then
        for i = 1, #data do
            local b = data[i] or 0
            if #self.rx_fifo < self.rx_capacity then
                self.rx_fifo[#self.rx_fifo + 1] = bit32.band(b, 0xFF)
            end
        end
    end
    self:_update_irq_line()
end

function UART:feed_string(s) self:feed_bytes(s) end

-- ========== MMIO ==========

---MMIO read: return 'count' bytes starting at 'offset'.
---@param offset integer
---@param count integer
---@return integer[] bytes
function UART:read(offset, count)
    self.stats.reads = self.stats.reads + 1
    local out = {}
    for i = 0, count - 1 do
        local addr = offset + i
        local b = 0
        if addr == OFF_DATA then
            -- Read one RX byte (non-blocking)
            if self:_rx_ready() then
                b = table.remove(self.rx_fifo, 1)
                self.stats.rx_bytes = self.stats.rx_bytes + 1
                -- Edge: if FIFO empties, deassert IRQ (if enabled)
                if not self:_rx_ready() then self:_update_irq_line() end
            else
                b = 0
            end
        elseif addr >= OFF_STATUS and addr < (OFF_STATUS + 4) then
            -- STATUS word: bit0=TX ready, bit1=RX ready
            local status = 0x1
            if self:_rx_ready() then status = bit32.bor(status, 0x2) end
            local p = pack32(status)
            b = p[addr - OFF_STATUS + 1]
        elseif addr >= OFF_CTRL and addr < (OFF_CTRL + 4) then
            local ctrl = self.rx_irq_enable and 0x1 or 0x0
            local p = pack32(ctrl)
            b = p[addr - OFF_CTRL + 1]
        else
            b = 0
        end
        out[i + 1] = b
    end
    return out
end

---MMIO write: write 'bytes' starting at 'offset'.
---@param offset integer
---@param bytes integer[]
function UART:write(offset, bytes)
    self.stats.writes = self.stats.writes + 1
    for i = 1, #bytes do
        local addr = offset + (i - 1)
        local b = bit32.band(bytes[i] or 0, 0xFF)
        if addr == OFF_DATA then
            -- Transmit one byte
            self.stats.tx_bytes = self.stats.tx_bytes + 1
            if self.on_tx then
                pcall(self.on_tx, b)
            else
                -- Default: print character without newline
                io.write(string.format("%s", printable(b)))
            end
            if self.verbose then
                print(string.format("uart tx: 0x%02X '%s'", b, printable(b)))
            end
        elseif addr >= OFF_CTRL and addr < (OFF_CTRL + 4) then
            -- Full 32-bit write decoded when 4 bytes present/aligned
            -- We'll collect the whole word only once per burst
            -- but since Bus enforces widths, this will typically be a single 4B write.
        end
    end
    -- Decode CTRL if a 4-byte word was written at OFF_CTRL
    if #bytes >= 4 and offset == OFF_CTRL then
        local val = unpack32(bytes)
        local new_en = bit32.band(val, 0x1) ~= 0
        if new_en ~= self.rx_irq_enable then
            self.rx_irq_enable = new_en
            self:_update_irq_line()
        end
    end
end

return UART