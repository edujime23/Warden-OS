-- memory_pool.lua
-- Core memory pool implementation with byte-level storage

local Constants = require("memory.utils.constants")

local MemoryPool = {}
MemoryPool.__index = MemoryPool

-- Initialize a new memory pool
function MemoryPool:new(size_bytes)
    local pool = {
        size = size_bytes or 65536,  -- Default 64KB
        data = {},                    -- Byte storage
        endianness = "little",        -- Default to little-endian
        access_count = 0,             -- Statistics
        fault_count = 0
    }

    -- Initialize all bytes to zero
    for i = 0, pool.size - 1 do
        pool.data[i] = 0
    end

    setmetatable(pool, MemoryPool)
    return pool
end

-- Validate memory access bounds
function MemoryPool:validate_access(address, size_bytes)
    if address < 0 or address + size_bytes > self.size then
        self.fault_count = self.fault_count + 1
        error(string.format(
            "Memory access violation: address=0x%X, size=%d, pool_size=%d",
            address, size_bytes, self.size
        ))
    end
    self.access_count = self.access_count + 1
end

-- Read a single byte from memory
function MemoryPool:read_u8(address)
    self:validate_access(address, 1)
    return bit32.band(self.data[address], 0xFF)
end

-- Write a single byte to memory
function MemoryPool:write_u8(address, value)
    self:validate_access(address, 1)
    self.data[address] = bit32.band(value, 0xFF)
end

-- Read multiple bytes from memory
function MemoryPool:read_bytes(address, count)
    self:validate_access(address, count)
    local bytes = {}
    for i = 0, count - 1 do
        bytes[i + 1] = self.data[address + i]
    end
    return bytes
end

-- Write multiple bytes to memory
function MemoryPool:write_bytes(address, byte_array)
    local count = #byte_array
    self:validate_access(address, count)
    for i = 1, count do
        self.data[address + i - 1] = bit32.band(byte_array[i], 0xFF)
    end
end

-- Read a multi-byte integer value
function MemoryPool:read_integer(address, size_bytes, signed)
    local bytes = self:read_bytes(address, size_bytes)
    local value = 0

    if self.endianness == "little" then
        -- Little-endian: LSB first
        for i = size_bytes, 1, -1 do
            value = bit32.bor(bit32.lshift(value, 8), bytes[i])
        end
    else
        -- Big-endian: MSB first
        for i = 1, size_bytes do
            value = bit32.bor(bit32.lshift(value, 8), bytes[i])
        end
    end

    -- Handle signed integers using two's complement
    if signed then
        local max_positive = bit32.lshift(1, (size_bytes * 8 - 1)) - 1
        if value > max_positive then
            value = value - bit32.lshift(1, (size_bytes * 8))
        end
    end

    return value
end

-- Write a multi-byte integer value
function MemoryPool:write_integer(address, value, size_bytes, signed)
    -- Handle negative numbers for signed types
    if signed and value < 0 then
        value = value + bit32.lshift(1, (size_bytes * 8))
    end

    local bytes = {}
    for i = 1, size_bytes do
        if self.endianness == "little" then
            bytes[i] = bit32.band(value, 0xFF)
            value = bit32.rshift(value, 8)
        else
            bytes[size_bytes - i + 1] = bit32.band(value, 0xFF)
            value = bit32.rshift(value, 8)
        end
    end

    self:write_bytes(address, bytes)
end

-- Clear a memory region
function MemoryPool:clear(address, size_bytes)
    self:validate_access(address, size_bytes)
    for i = address, address + size_bytes - 1 do
        self.data[i] = 0
    end
end

-- Copy memory from one location to another
function MemoryPool:copy(dest_addr, src_addr, size_bytes)
    -- Validate both source and destination
    self:validate_access(src_addr, size_bytes)
    self:validate_access(dest_addr, size_bytes)

    -- Handle overlapping regions
    if dest_addr < src_addr then
        for i = 0, size_bytes - 1 do
            self.data[dest_addr + i] = self.data[src_addr + i]
        end
    else
        for i = size_bytes - 1, 0, -1 do
            self.data[dest_addr + i] = self.data[src_addr + i]
        end
    end
end

-- Compare two memory regions
function MemoryPool:compare(addr1, addr2, size_bytes)
    self:validate_access(addr1, size_bytes)
    self:validate_access(addr2, size_bytes)

    for i = 0, size_bytes - 1 do
        local diff = self.data[addr1 + i] - self.data[addr2 + i]
        if diff ~= 0 then
            return diff
        end
    end
    return 0
end

-- Get pool statistics
function MemoryPool:get_statistics()
    return {
        size = self.size,
        access_count = self.access_count,
        fault_count = self.fault_count,
        endianness = self.endianness
    }
end

return MemoryPool