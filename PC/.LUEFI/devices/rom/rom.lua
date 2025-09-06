-- devices/rom/rom.lua
-- Read-only ROM device: byte-addressable, mapped via the system bus as an MMIO-like region.

---@class ROM
---@field base integer
---@field size integer
---@field data table<integer, integer>
---@field stats table
local ROM = {}
ROM.__index = ROM

local bit32 = bit32

function ROM:new(base, size, opts)
    assert(type(base) == "number" and base >= 0, "ROM:new base must be non-negative")
    assert(type(size) == "number" and size > 0, "ROM:new size must be > 0")
    opts = opts or {}
    local fill = bit32.band(opts.fill or 0, 0xFF)

    local self_ = {
        base = base,
        size = size,
        data = {},
        strict = opts.strict == true,
        stats = { reads = 0, read_bytes = 0, writes = 0, write_bytes = 0 }
    }
    setmetatable(self_, ROM)

    for i = 0, size - 1 do
        self_.data[i] = fill
    end
    return self_
end

function ROM:get_region() return self.base, self.size end
-- Allow any width/alignment (code fetches may ask for longer bursts)
function ROM:get_mmio_caps() return { align = 1, widths = nil } end

function ROM:read(offset, count)
    local bytes = {}
    local n = 0
    for i = 0, count - 1 do
        local a = offset + i
        if a >= 0 and a < self.size then
            bytes[i + 1] = self.data[a]
            n = n + 1
        else
            bytes[i + 1] = 0
        end
    end
    self.stats.reads = self.stats.reads + 1
    self.stats.read_bytes = self.stats.read_bytes + n
    return bytes
end

function ROM:write(offset, bytes)
    self.stats.writes = self.stats.writes + 1
    self.stats.write_bytes = self.stats.write_bytes + (#bytes or 0)
    if self.strict then
        error("Write to ROM region is not allowed")
    end
end

function ROM:load_image(bytes, offset)
    offset = offset or 0
    for i = 1, #bytes do
        local a = offset + (i - 1)
        if a >= 0 and a < self.size then
            self.data[a] = bit32.band(bytes[i], 0xFF)
        end
    end
end

function ROM:load_image_string(s, offset)
    offset = offset or 0
    for i = 1, #s do
        local a = offset + (i - 1)
        if a >= 0 and a < self.size then
            self.data[a] = string.byte(s, i)
        end
    end
end

return ROM