-- devices/memory/dram.lua
-- DRAM device: byte-addressable physical memory backend (sparse implementation).
-- Implements the IBackend interface used by the CPU (read_bytes/write_bytes).

---@class DRAM
---@field size integer
---@field data table<integer, integer>
---@field fill_byte integer
---@field stats table
local DRAM = {}
DRAM.__index = DRAM

function DRAM:new(size_bytes, opts)
    assert(type(size_bytes) == "number" and size_bytes > 0, "DRAM:new(size) requires positive size")
    opts = opts or {}

    local self_ = {
        size = size_bytes,
        data = {}, -- The table is now sparse (initially empty)
        fill_byte = bit32.band(opts.fill or 0, 0xFF), -- The default value for unwritten memory
        stats = { accesses=0, faults=0, reads=0, read_bytes=0, writes=0, write_bytes=0 }
    }

    return setmetatable(self_, DRAM)
end

function DRAM:_validate(address, count)
    if address < 0 or count < 0 or (address + count) > self.size then
        self.stats.faults = self.stats.faults + 1
        error(string.format("DRAM access violation: addr=0x%X len=%d (size=%d)", address, count, self.size))
    end
    self.stats.accesses = self.stats.accesses + 1
end

function DRAM:read_bytes(phys_addr, count)
    self:_validate(phys_addr, count)
    local out = {}
    for i = 0, count - 1 do
        out[i + 1] = self.data[phys_addr + i] or self.fill_byte
    end
    self.stats.reads = self.stats.reads + 1
    self.stats.read_bytes = self.stats.read_bytes + count
    return out
end

function DRAM:write_bytes(phys_addr, bytes)
    local n = #bytes
    self:_validate(phys_addr, n)
    for i = 1, n do
        self.data[phys_addr + i - 1] = bit32.band(bytes[i], 0xFF)
    end
    self.stats.writes = self.stats.writes + 1
    self.stats.write_bytes = self.stats.write_bytes + n
end

function DRAM:read_u8(phys_addr)
    self:_validate(phys_addr, 1)
    self.stats.reads = self.stats.reads + 1
    self.stats.read_bytes = self.stats.read_bytes + 1
    return self.data[phys_addr] or self.fill_byte
end

function DRAM:write_u8(phys_addr, value)
    self:_validate(phys_addr, 1)
    self.data[phys_addr] = bit32.band(value, 0xFF)
    self.stats.writes = self.stats.writes + 1
    self.stats.write_bytes = self.stats.write_bytes + 1
end

function DRAM:fill(phys_addr, count, value)
    self:_validate(phys_addr, count)
    local v = bit32.band(value or 0, 0xFF)
    for i = 0, count - 1 do
        self.data[phys_addr + i] = v
    end
    self.stats.writes = self.stats.writes + 1
    self.stats.write_bytes = self.stats.write_bytes + count
end

function DRAM:clear(phys_addr, count)
    self:fill(phys_addr, count, 0)
end

function DRAM:copy(dest, src, count)
    self:_validate(src, count)
    self:_validate(dest, count)
    if dest < src then
        for i = 0, count - 1 do
            self.data[dest + i] = self.data[src + i] or self.fill_byte
        end
    else
        for i = count - 1, 0, -1 do
            self.data[dest + i] = self.data[src + i] or self.fill_byte
        end
    end
    self.stats.writes = self.stats.writes + 1
    self.stats.write_bytes = self.stats.write_bytes + count
end

function DRAM:load_image(phys_addr, bytes)
    self:write_bytes(phys_addr, bytes)
end

function DRAM:peek(phys_addr, count)
    return self:read_bytes(phys_addr, count)
end

function DRAM:get_statistics()
    return {
        size = self.size,
        accesses = self.stats.accesses,
        faults = self.stats.faults,
        reads = self.stats.reads,
        read_bytes = self.stats.read_bytes,
        writes = self.stats.writes,
        write_bytes = self.stats.write_bytes
    }
end

return DRAM