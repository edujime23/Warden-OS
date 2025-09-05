-- smart_pointers.lua
-- C++ smart pointer implementations

local PrimitiveTypes = require("memory.types.primitive_types")

local SmartPointers = {}

-- Reference counting control block
local ControlBlock = {}
ControlBlock.__index = ControlBlock

function ControlBlock:new(memory_pool, allocator)
    local block_addr = allocator:allocate(16)  -- 8 bytes strong + 8 bytes weak

    local block = {
        pool = memory_pool,
        allocator = allocator,
        address = block_addr,
        strong_count_addr = block_addr,
        weak_count_addr = block_addr + 8
    }

    -- Initialize counts
    memory_pool:write_integer(block.strong_count_addr, 0, 8, false)
    memory_pool:write_integer(block.weak_count_addr, 0, 8, false)

    setmetatable(block, ControlBlock)
    return block
end

function ControlBlock:add_strong()
    local count = self.pool:read_integer(self.strong_count_addr, 8, false)
    self.pool:write_integer(self.strong_count_addr, count + 1, 8, false)
    return count + 1
end

function ControlBlock:release_strong()
    local count = self.pool:read_integer(self.strong_count_addr, 8, false)
    if count > 0 then
        self.pool:write_integer(self.strong_count_addr, count - 1, 8, false)
    end
    return count - 1
end

function ControlBlock:add_weak()
    local count = self.pool:read_integer(self.weak_count_addr, 8, false)
    self.pool:write_integer(self.weak_count_addr, count + 1, 8, false)
    return count + 1
end

function ControlBlock:release_weak()
    local count = self.pool:read_integer(self.weak_count_addr, 8, false)
    if count > 0 then
        self.pool:write_integer(self.weak_count_addr, count - 1, 8, false)
    end
    return count - 1
end

function ControlBlock:strong_count()
    return self.pool:read_integer(self.strong_count_addr, 8, false)
end

function ControlBlock:weak_count()
    return self.pool:read_integer(self.weak_count_addr, 8, false)
end

function ControlBlock:destroy()
    if self:strong_count() == 0 and self:weak_count() == 0 then
        self.allocator:free(self.address)
        return true
    end
    return false
end

-- Unique pointer implementation
local UniquePtr = {}
UniquePtr.__index = UniquePtr

function UniquePtr:new(typename, memory_pool, allocator)
    local typedef = PrimitiveTypes.definitions[typename]
    if not typedef then
        error(string.format("Unknown type for unique_ptr: %s", typename))
    end

    local ptr = {
        typename = typename,
        typedef = typedef,
        pool = memory_pool,
        allocator = allocator,
        address = nil,  -- Managed object address
        owns = false    -- Ownership flag
    }

    setmetatable(ptr, self)
    return ptr
end

function UniquePtr:make(initial_value)
    -- Release current resource if any
    if self.owns and self.address then
        self:reset()
    end

    -- Allocate new object
    self.address = self.allocator:allocate(self.typedef.size, self.typedef.alignment)
    self.owns = true

    -- Initialize value
    if initial_value ~= nil then
        local obj = PrimitiveTypes.create(self.typename, self.pool, self.address)
        obj:set(initial_value)
    end

    return self
end

function UniquePtr:get()
    if not self.address then
        return nil
    end
    return PrimitiveTypes.create(self.typename, self.pool, self.address)
end

function UniquePtr:release()
    local addr = self.address
    self.address = nil
    self.owns = false
    return addr
end

function UniquePtr:reset(new_address)
    -- Free current resource
    if self.owns and self.address then
        self.allocator:free(self.address)
    end

    -- Take ownership of new resource
    self.address = new_address
    self.owns = new_address ~= nil
end

function UniquePtr:move()
    -- Transfer ownership to new unique_ptr
    local new_ptr = UniquePtr:new(self.typename, self.pool, self.allocator)
    new_ptr.address = self.address
    new_ptr.owns = self.owns

    -- Release ownership from this pointer
    self.address = nil
    self.owns = false

    return new_ptr
end

function UniquePtr:swap(other)
    self.address, other.address = other.address, self.address
    self.owns, other.owns = other.owns, self.owns
end

function UniquePtr:__tostring()
    if self.address then
        local value = self:get()
        return string.format("unique_ptr<%s>@0x%X -> %s",
            self.typename, self.address, value and tostring(value:get()) or "null")
    else
        return string.format("unique_ptr<%s>(nullptr)", self.typename)
    end
end

function UniquePtr:__gc()
    if self.owns and self.address then
        self:reset()
    end
end

-- Shared pointer implementation
local SharedPtr = {}
SharedPtr.__index = SharedPtr

function SharedPtr:new(typename, memory_pool, allocator)
    local typedef = PrimitiveTypes.definitions[typename]
    if not typedef then
        error(string.format("Unknown type for shared_ptr: %s", typename))
    end

    local ptr = {
        typename = typename,
        typedef = typedef,
        pool = memory_pool,
        allocator = allocator,
        address = nil,      -- Managed object address
        control = nil       -- Control block
    }

    setmetatable(ptr, self)
    return ptr
end

function SharedPtr:make(initial_value)
    -- Release current resource if any
    if self.control then
        self:reset()
    end

    -- Allocate object and control block
    self.address = self.allocator:allocate(self.typedef.size, self.typedef.alignment)
    self.control = ControlBlock:new(self.pool, self.allocator)
    self.control:add_strong()

    -- Initialize value
    if initial_value ~= nil then
        local obj = PrimitiveTypes.create(self.typename, self.pool, self.address)
        obj:set(initial_value)
    end

    return self
end

function SharedPtr:get()
    if not self.address then
        return nil
    end
    return PrimitiveTypes.create(self.typename, self.pool, self.address)
end

function SharedPtr:use_count()
    if self.control then
        return self.control:strong_count()
    end
    return 0
end

function SharedPtr:unique()
    return self:use_count() == 1
end

function SharedPtr:reset()
    if self.control then
        if self.control:release_strong() == 0 then
            -- Last reference, free object
            if self.address then
                self.allocator:free(self.address)
            end

            -- Destroy control block if no weak references
            self.control:destroy()
        end
    end

    self.address = nil
    self.control = nil
end

function SharedPtr:copy()
    if not self.control then
        return SharedPtr:new(self.typename, self.pool, self.allocator)
    end

    local new_ptr = SharedPtr:new(self.typename, self.pool, self.allocator)
    new_ptr.address = self.address
    new_ptr.control = self.control
    new_ptr.control:add_strong()

    return new_ptr
end

function SharedPtr:__tostring()
    if self.address then
        local value = self:get()
        return string.format("shared_ptr<%s>@0x%X -> %s (refs:%d)",
            self.typename, self.address,
            value and tostring(value:get()) or "null",
            self:use_count())
    else
        return string.format("shared_ptr<%s>(nullptr)", self.typename)
    end
end

function SharedPtr:__gc()
    self:reset()
end

-- Weak pointer implementation
local WeakPtr = {}
WeakPtr.__index = WeakPtr

function WeakPtr:new(typename, memory_pool, allocator)
    local ptr = {
        typename = typename,
        pool = memory_pool,
        allocator = allocator,
        control = nil
    }

    setmetatable(ptr, self)
    return ptr
end

function WeakPtr:assign(shared_ptr)
    -- Release old reference
    if self.control then
        self.control:release_weak()
    end

    -- Take new reference
    self.control = shared_ptr.control
    if self.control then
        self.control:add_weak()
    end
end

function WeakPtr:expired()
    if not self.control then
        return true
    end
    return self.control:strong_count() == 0
end

function WeakPtr:use_count()
    if self.control then
        return self.control:strong_count()
    end
    return 0
end

function WeakPtr:lock()
    if self:expired() then
        return nil
    end

    -- Create shared_ptr from weak_ptr
    local shared = SharedPtr:new(self.typename, self.pool, self.allocator)
    shared.control = self.control
    shared.control:add_strong()

    -- Need to recover the object address
    -- In real implementation, control block would store this
    -- For now, this is a limitation

    return shared
end

function WeakPtr:reset()
    if self.control then
        self.control:release_weak()
        self.control:destroy()
    end
    self.control = nil
end

function WeakPtr:__tostring()
    if self.control then
        return string.format("weak_ptr<%s>(expired:%s, refs:%d)",
            self.typename, tostring(self:expired()), self:use_count())
    else
        return string.format("weak_ptr<%s>(nullptr)", self.typename)
    end
end

function WeakPtr:__gc()
    self:reset()
end

-- Export types
SmartPointers.UniquePtr = UniquePtr
SmartPointers.SharedPtr = SharedPtr
SmartPointers.WeakPtr = WeakPtr

return SmartPointers