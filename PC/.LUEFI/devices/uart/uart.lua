-- devices/uart/uart.lua
-- Simple MMIO UART device: DATA (offset 0) write-only, STATUS (offset 4) read-only.
-- STATUS bit0=1 (TX ready). Returns/read/writes as byte arrays.

---@class UART
---@field base integer
---@field size integer
---@field verbose boolean
---@field on_tx fun(byte: integer)|nil
---@field stats table
local UART = {}
UART.__index = UART

---Create a new UART.
---@param base integer
---@param size integer|nil @ default 16
---@param opts { verbose?: boolean, on_tx?: fun(byte: integer) }|nil
---@return UART
function UART:new(base, size, opts)
    size = size or 16
    opts = opts or {}
    local self_ = {
        base = base,
        size = size,
        verbose = opts.verbose == true,
        on_tx = opts.on_tx,
        stats = { writes = 0, reads = 0, tx_bytes = 0 }
    }
    return setmetatable(self_, UART)
end

---Get device region (base, size).
---@return integer, integer
function UART:get_region()
    return self.base, self.size
end

local function printable(b)
    if b >= 32 and b <= 126 then return string.char(b) else return "." end
end

---MMIO read: return 'count' bytes starting at 'offset'.
---@param offset integer
---@param count integer
---@return integer[] bytes
function UART:read(offset, count)
    self.stats.reads = self.stats.reads + 1
    local out = {}
    for i = 0, count - 1 do
        local addr = offset + i
        -- STATUS register at 4..7 -> value 1 (little-endian 32-bit)
        if addr >= 4 and addr < 8 then
            out[i + 1] = (addr == 4) and 1 or 0
        else
            out[i + 1] = 0
        end
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
        local b = bytes[i] or 0
        if addr == 0 then
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
        else
            -- Other offsets ignored for simplicity
        end
    end
end

return UART