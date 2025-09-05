-- primitive_types.lua
-- Primitive C/C++ type definitions and operations

local Constants = require("memory.utils.constants")

local PrimitiveTypes = {}

-- Type definition registry
PrimitiveTypes.definitions = {
    -- Unsigned integers
    uint8  = { size = 1, signed = false, min = 0, max = 255, alignment = 1 },
    uint16 = { size = 2, signed = false, min = 0, max = 65535, alignment = 2 },
    uint32 = { size = 4, signed = false, min = 0, max = 4294967295, alignment = 4 },
    uint64 = { size = 8, signed = false, min = 0, max = 2^64 - 1, alignment = 8 },

    -- Signed integers
    int8   = { size = 1, signed = true, min = -128, max = 127, alignment = 1 },
    int16  = { size = 2, signed = true, min = -32768, max = 32767, alignment = 2 },
    int32  = { size = 4, signed = true, min = -2147483648, max = 2147483647, alignment = 4 },
    int64  = { size = 8, signed = true, min = -2^63, max = 2^63 - 1, alignment = 8 },

    -- Character types
    char   = { size = 1, signed = true, min = -128, max = 127, alignment = 1 },
    uchar  = { size = 1, signed = false, min = 0, max = 255, alignment = 1 },

    -- Boolean
    bool   = { size = 1, signed = false, min = 0, max = 1, alignment = 1 },

    -- Floating point (simplified representation)
    float  = { size = 4, signed = true, floating = true, alignment = 4 },
    double = { size = 8, signed = true, floating = true, alignment = 8 },

    -- Pointer types
    ptr    = { size = 8, signed = false, min = 0, max = 2^64 - 1, alignment = 8 },
    size_t = { size = 8, signed = false, min = 0, max = 2^64 - 1, alignment = 8 },

    -- Fixed-size types (C99)
    int8_t   = { size = 1, signed = true, min = -128, max = 127, alignment = 1 },
    int16_t  = { size = 2, signed = true, min = -32768, max = 32767, alignment = 2 },
    int32_t  = { size = 4, signed = true, min = -2147483648, max = 2147483647, alignment = 4 },
    int64_t  = { size = 8, signed = true, min = -2^63, max = 2^63 - 1, alignment = 8 },

    uint8_t  = { size = 1, signed = false, min = 0, max = 255, alignment = 1 },
    uint16_t = { size = 2, signed = false, min = 0, max = 65535, alignment = 2 },
    uint32_t = { size = 4, signed = false, min = 0, max = 4294967295, alignment = 4 },
    uint64_t = { size = 8, signed = false, min = 0, max = 2^64 - 1, alignment = 8 }
}

-- Primitive type class
local PrimitiveType = {}
PrimitiveType.__index = PrimitiveType

-- Create a new primitive type instance
function PrimitiveType:new(typename, memory_pool, address)
    local typedef = PrimitiveTypes.definitions[typename]
    if not typedef then
        error(string.format("Unknown primitive type: %s", typename))
    end

    local instance = {
        typename = typename,
        typedef = typedef,
        pool = memory_pool,
        address = address
    }

    setmetatable(instance, self)
    return instance
end

-- Read value from memory
function PrimitiveType:get()
    if self.typedef.floating then
        -- Simplified floating point handling
        local int_value = self.pool:read_integer(self.address, self.typedef.size, true)
        return int_value / 1000000.0  -- Simple fixed-point representation
    else
        return self.pool:read_integer(self.address, self.typedef.size, self.typedef.signed)
    end
end

-- Write value to memory
function PrimitiveType:set(value)
    -- Type validation
    if type(value) ~= "number" then
        error(string.format("Expected number for %s, got %s", self.typename, type(value)))
    end

    -- Range validation for non-floating types
    if not self.typedef.floating then
        if value < self.typedef.min or value > self.typedef.max then
            error(string.format(
                "Value %g out of range for %s [%g, %g]",
                value, self.typename, self.typedef.min, self.typedef.max
            ))
        end

        -- Ensure integer value
        value = math.floor(value + 0.5)
    else
        -- Convert floating point to fixed-point representation
        value = math.floor(value * 1000000)
    end

    self.pool:write_integer(self.address, value, self.typedef.size, self.typedef.signed)
end

-- Arithmetic operations
function PrimitiveType:__add(other)
    local a = self:get()
    local b = type(other) == "table" and other:get() or other
    return a + b
end

function PrimitiveType:__sub(other)
    local a = self:get()
    local b = type(other) == "table" and other:get() or other
    return a - b
end

function PrimitiveType:__mul(other)
    local a = self:get()
    local b = type(other) == "table" and other:get() or other
    return a * b
end

function PrimitiveType:__div(other)
    local a = self:get()
    local b = type(other) == "table" and other:get() or other
    return a / b
end

-- Comparison operations
function PrimitiveType:__eq(other)
    local a = self:get()
    local b = type(other) == "table" and other:get() or other
    return a == b
end

function PrimitiveType:__lt(other)
    local a = self:get()
    local b = type(other) == "table" and other:get() or other
    return a < b
end

function PrimitiveType:__le(other)
    local a = self:get()
    local b = type(other) == "table" and other:get() or other
    return a <= b
end

-- String representation
function PrimitiveType:__tostring()
    return string.format("%s@0x%X = %s", self.typename, self.address, tostring(self:get()))
end

-- Get size of type
function PrimitiveType:sizeof()
    return self.typedef.size
end

-- Get alignment requirement
function PrimitiveType:alignof()
    return self.typedef.alignment
end

-- Factory function
function PrimitiveTypes.create(typename, memory_pool, address)
    return PrimitiveType:new(typename, memory_pool, address)
end

-- Export class
PrimitiveTypes.PrimitiveType = PrimitiveType

return PrimitiveTypes