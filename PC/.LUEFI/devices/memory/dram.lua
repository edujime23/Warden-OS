-- devices/memory/dram.lua
-- DRAM device: byte-addressable physical memory backend.
-- Implements the IBackend interface used by the CPU (read_bytes/write_bytes).

---@class DRAM
---@field size integer                     -- total bytes
---@field data table<integer, integer>     -- 0..size-1 -> byte (0..255)
---@field stats table                      -- counters
local DRAM = {}
DRAM.__index = DRAM

local bit32 = bit32

---Create a new DRAM device.
---@param size_bytes integer          -- total memory size in bytes
---@param opts table|nil              -- { fill?: integer (default 0) }
---@return DRAM
function DRAM:new(size_bytes, opts)
    assert(type(size_bytes) == "number" and size_bytes > 0, "DRAM:new(size) requires positive size")
    opts = opts or {}
    local fill = opts.fill or 0

    local self_ = {
        size = size_bytes,
        data = {},
        stats = {
            accesses = 0,
            faults = 0,
            reads = 0,
            read_bytes = 0,
            writes = 0,
            write_bytes = 0
        }
    }

    -- Initialize memory to fill (default 0)
    fill = bit32.band(fill, 0xFF)
    for i = 0, size_bytes - 1 do
        self_.data[i] = fill
    end

    return setmetatable(self_, DRAM)
end

-- ========= Internal helpers =========

---Bounds check; increments fault counter on violation.
---@param address integer
---@param count integer
function DRAM:_validate(address, count)
    if address < 0 or count < 0 or (address + count) > self.size then
        self.stats.faults = self.stats.faults + 1
        error(string.format("DRAM access violation: addr=0x%X len=%d (size=%d)", address, count, self.size))
    end
    self.stats.accesses = self.stats.accesses + 1
end

-- ========= IBackend: physical byte I/O =========

---Read a sequence of bytes starting at a physical address.
---@param phys_addr integer
---@param count integer
---@return integer[] bytes @ 1..count, each 0..255
function DRAM:read_bytes(phys_addr, count)
    self:_validate(phys_addr, count)
    local out = {}
    for i = 0, count - 1 do
        out[i + 1] = self.data[phys_addr + i]
    end
    self.stats.reads = self.stats.reads + 1
    self.stats.read_bytes = self.stats.read_bytes + count
    return out
end

---Write a sequence of bytes starting at a physical address.
---@param phys_addr integer
---@param bytes integer[] @ 1..n, each 0..255
function DRAM:write_bytes(phys_addr, bytes)
    local n = #bytes
    self:_validate(phys_addr, n)
    for i = 1, n do
        self.data[phys_addr + i - 1] = bit32.band(bytes[i], 0xFF)
    end
    self.stats.writes = self.stats.writes + 1
    self.stats.write_bytes = self.stats.write_bytes + n
end

-- ========= Convenience helpers (optional) =========

---Read a single byte.
---@param phys_addr integer
---@return integer
function DRAM:read_u8(phys_addr)
    self:_validate(phys_addr, 1)
    self.stats.reads = self.stats.reads + 1
    self.stats.read_bytes = self.stats.read_bytes + 1
    return self.data[phys_addr]
end

---Write a single byte.
---@param phys_addr integer
---@param value integer
function DRAM:write_u8(phys_addr, value)
    self:_validate(phys_addr, 1)
    self.data[phys_addr] = bit32.band(value, 0xFF)
    self.stats.writes = self.stats.writes + 1
    self.stats.write_bytes = self.stats.write_bytes + 1
end

---Fill a memory region with a constant byte.
---@param phys_addr integer
---@param count integer
---@param value integer
function DRAM:fill(phys_addr, count, value)
    self:_validate(phys_addr, count)
    local v = bit32.band(value or 0, 0xFF)
    for i = 0, count - 1 do
        self.data[phys_addr + i] = v
    end
    self.stats.writes = self.stats.writes + 1
    self.stats.write_bytes = self.stats.write_bytes + count
end

---Clear a memory region (set to zero).
---@param phys_addr integer
---@param count integer
function DRAM:clear(phys_addr, count)
    self:fill(phys_addr, count, 0)
end

---Copy a memory region (handles overlapping regions).
---@param dest integer
---@param src integer
---@param count integer
function DRAM:copy(dest, src, count)
    self:_validate(src, count)
    self:_validate(dest, count)
    if dest < src then
        for i = 0, count - 1 do
            self.data[dest + i] = self.data[src + i]
        end
    else
        for i = count - 1, 0, -1 do
            self.data[dest + i] = self.data[src + i]
        end
    end
    self.stats.writes = self.stats.writes + 1
    self.stats.write_bytes = self.stats.write_bytes + count
end

---Load an image (byte array) at an address (e.g., firmware or program).
---@param phys_addr integer
---@param bytes integer[]
function DRAM:load_image(phys_addr, bytes)
    self:write_bytes(phys_addr, bytes)
end

---Return a shallow snapshot of a region as a byte table.
---@param phys_addr integer
---@param count integer
---@return integer[] bytes
function DRAM:peek(phys_addr, count)
    return self:read_bytes(phys_addr, count)
end

-- ========= Introspection =========

---Get device statistics.
---@return table
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