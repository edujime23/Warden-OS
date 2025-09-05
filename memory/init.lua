-- memory/init.lua
-- Main library entry point

local Memory = {}

-- Version information
Memory.VERSION = "1.0.0"
Memory.AUTHOR = "Memory Simulation Library"

-- Load core modules
Memory.MemoryPool = require("memory.core.memory_pool")
Memory.HeapAllocator = require("memory.core.heap_allocator")
Memory.StackManager = require("memory.core.stack_manager")
Memory.VirtualMemoryManager = require("memory.core.virtual_memory_manager")
Memory.CacheController = require("memory.core.cache_controller")

-- Load I/O modules
Memory.MMIOController = require("memory.io.mmio_controller")

-- Load type modules
Memory.PrimitiveTypes = require("memory.types.primitive_types")
Memory.SmartPointers = require("memory.types.smart_pointers")
Memory.MemoryContainers = require("memory.types.memory_containers")

-- Load utility modules
Memory.Constants = require("memory.utils.constants")
Memory.Debug = require("memory.utils.memory_debug")

-- Create a complete memory system
function Memory.create_system(config)
    config = config or {}

    local system = {}

    -- Create memory pool
    system.pool = Memory.MemoryPool:new(config.size or 65536)

    -- Create memory managers
    system.heap  = Memory.HeapAllocator:new(system.pool)
    system.stack = Memory.StackManager:new(system.pool)
    system.vm    = Memory.VirtualMemoryManager:new(system.pool)

    -- Cache controller accepts optional policy/config in config.cache
    system.cache = Memory.CacheController:new(system.pool, config.cache or {})

    -- MMIO
    system.mmio = Memory.MMIOController:new(system.pool)

    -- Convenience functions
    function system:malloc(size, alignment)
        return self.heap:allocate(size, alignment)
    end

    function system:free(address)
        return self.heap:free(address)
    end

    function system:create_type(typename, address)
        return Memory.PrimitiveTypes.create(typename, self.pool, address)
    end

    function system:create_array(typename, address, size)
        return Memory.MemoryContainers.Array:new(typename, self.pool, address, size)
    end

    function system:create_unique_ptr(typename)
        return Memory.SmartPointers.UniquePtr:new(typename, self.pool, self.heap)
    end

    function system:create_shared_ptr(typename)
        return Memory.SmartPointers.SharedPtr:new(typename, self.pool, self.heap)
    end

    function system:report()
        return Memory.Debug.system_report({
            memory_pool      = self.pool,
            stack_manager    = self.stack,
            heap_allocator   = self.heap,
            vm_manager       = self.vm,
            cache_controller = self.cache,
            mmio_controller  = self.mmio
        })
    end

    return system
end

return Memory