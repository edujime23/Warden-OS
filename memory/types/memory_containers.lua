-- memory_containers.lua
-- C++ container types (array, span, optional)

local PrimitiveTypes = require("memory.types.primitive_types")

local MemoryContainers = {}

-- Fixed-size array implementation
local Array = {}
Array.__index = Array

function Array:new(typename, memory_pool, address, size)
    local typedef = PrimitiveTypes.definitions[typename]
    if not typedef then
        error(string.format("Unknown type for array: %s", typename))
    end

    local array = {
        typename = typename,
        typedef = typedef,
        pool = memory_pool,
        address = address,
        size = size,
        element_size = typedef.size,
        total_size = typedef.size * size
    }

    setmetatable(array, self)
    return array
end

function Array:at(index)
    -- 1-based indexing for Lua compatibility
    if index < 1 or index > self.size then
        error(string.format("Array index %d out of bounds [1, %d]", index, self.size))
    end

    local element_addr = self.address + (index - 1) * self.element_size
    return PrimitiveTypes.create(self.typename, self.pool, element_addr)
end

function Array:set(index, value)
    local element = self:at(index)
    element:set(value)
end

function Array:get(index)
    local element = self:at(index)
    return element:get()
end

function Array:fill(value)
    for i = 1, self.size do
        self:set(i, value)
    end
end

function Array:data()
    return self.address
end

function Array:__index(key)
    if type(key) == "number" then
        return self:at(key)
    else
        return Array[key]
    end
end

function Array:__newindex(key, value)
    if type(key) == "number" then
        self:set(key, value)
    else
        rawset(self, key, value)
    end
end

function Array:__len()
    return self.size
end

function Array:__tostring()
    local values = {}
    local max_show = math.min(self.size, 10)

    for i = 1, max_show do
        table.insert(values, tostring(self:get(i)))
    end

    if self.size > max_show then
        table.insert(values, "...")
    end

    return string.format("array<%s, %d>@0x%X {%s}",
        self.typename, self.size, self.address, table.concat(values, ", "))
end

-- Span implementation (non-owning view)
local Span = {}
Span.__index = Span

function Span:new(typename, memory_pool, address, size)
    local typedef = PrimitiveTypes.definitions[typename]
    if not typedef then
        error(string.format("Unknown type for span: %s", typename))
    end

    local span = {
        typename = typename,
        typedef = typedef,
        pool = memory_pool,
        address = address,
        size = size,
        element_size = typedef.size
    }

    setmetatable(span, self)
    return span
end

function Span:at(index)
    if index < 1 or index > self.size then
        error(string.format("Span index %d out of bounds [1, %d]", index, self.size))
    end

    local element_addr = self.address + (index - 1) * self.element_size
    return PrimitiveTypes.create(self.typename, self.pool, element_addr)
end

function Span:subspan(offset, count)
    offset = offset or 1
    count = count or (self.size - offset + 1)

    if offset < 1 or offset > self.size then
        error("Subspan offset out of range")
    end

    if offset + count - 1 > self.size then
        error("Subspan exceeds span bounds")
    end

    local new_address = self.address + (offset - 1) * self.element_size
    return Span:new(self.typename, self.pool, new_address, count)
end

function Span:first(n)
    return self:subspan(1, n or 1)
end

function Span:last(n)
    n = n or 1
    return self:subspan(self.size - n + 1, n)
end

function Span:empty()
    return self.size == 0
end

function Span:data()
    return self.address
end

function Span:__index(key)
    if type(key) == "number" then
        return self:at(key)
    else
        return Span[key]
    end
end

function Span:__len()
    return self.size
end

function Span:__tostring()
    return string.format("span<%s, %d>@0x%X",
        self.typename, self.size, self.address)
end

-- Optional implementation
local Optional = {}
Optional.__index = Optional

function Optional:new(typename, memory_pool, allocator)
    local typedef = PrimitiveTypes.definitions[typename]
    if not typedef then
        error(string.format("Unknown type for optional: %s", typename))
    end

    local opt = {
        typename = typename,
        typedef = typedef,
        pool = memory_pool,
        allocator = allocator,
        storage = nil,
        has_value_flag = nil
    }

    -- Allocate storage (value + bool flag)
    local total_size = typedef.size + 1
    opt.storage = allocator:allocate(total_size, typedef.alignment)
    opt.has_value_flag = opt.storage + typedef.size

    -- Initialize as empty
    memory_pool:write_u8(opt.has_value_flag, 0)

    setmetatable(opt, self)
    return opt
end

function Optional:has_value()
    return self.pool:read_u8(self.has_value_flag) ~= 0
end

function Optional:value()
    if not self:has_value() then
        error("bad_optional_access: optional is empty")
    end
    return PrimitiveTypes.create(self.typename, self.pool, self.storage)
end

function Optional:value_or(default_value)
    if self:has_value() then
        return self:value():get()
    else
        return default_value
    end
end

function Optional:emplace(value)
    local obj = PrimitiveTypes.create(self.typename, self.pool, self.storage)
    obj:set(value)
    self.pool:write_u8(self.has_value_flag, 1)
end

function Optional:reset()
    self.pool:write_u8(self.has_value_flag, 0)
end

function Optional:__tostring()
    if self:has_value() then
        local val = self:value():get()
        return string.format("optional<%s>(%s)", self.typename, tostring(val))
    else
        return string.format("optional<%s>(nullopt)", self.typename)
    end
end

-- String view implementation
local StringView = {}
StringView.__index = StringView

function StringView:new(memory_pool, address, length)
    local view = {
        pool = memory_pool,
        address = address,
        length = length
    }

    setmetatable(view, self)
    return view
end

function StringView:at(index)
    if index < 1 or index > self.length then
        error(string.format("String index %d out of bounds [1, %d]", index, self.length))
    end

    return self.pool:read_u8(self.address + index - 1)
end

function StringView:substr(pos, len)
    pos = pos or 1
    len = len or (self.length - pos + 1)

    if pos < 1 or pos > self.length then
        error("Substring position out of range")
    end

    len = math.min(len, self.length - pos + 1)
    return StringView:new(self.pool, self.address + pos - 1, len)
end

function StringView:to_string()
    local chars = {}
    for i = 1, self.length do
        local byte = self.pool:read_u8(self.address + i - 1)
        if byte == 0 then
            break  -- Null terminator
        end
        table.insert(chars, string.char(byte))
    end
    return table.concat(chars)
end

function StringView:__tostring()
    return string.format('string_view("%s")', self:to_string())
end

function StringView:__len()
    return self.length
end

-- Export container types
MemoryContainers.Array = Array
MemoryContainers.Span = Span
MemoryContainers.Optional = Optional
MemoryContainers.StringView = StringView

return MemoryContainers