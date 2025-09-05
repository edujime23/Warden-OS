-- constants.lua
-- Memory system constants and configuration parameters

local Constants = {}

-- Memory region definitions (in bytes)
Constants.MEMORY_REGIONS = {
    -- Stack region: 0x0000 - 0x3FFF (16KB)
    STACK = {
        base = 0x0000,
        size = 0x4000,
        name = "Stack"
    },

    -- Heap region: 0x4000 - 0xBFFF (32KB)
    HEAP = {
        base = 0x4000,
        size = 0x8000,
        name = "Heap"
    },

    -- Memory-mapped I/O: 0xC000 - 0xDFFF (8KB)
    MMIO = {
        base = 0xC000,
        size = 0x2000,
        name = "MMIO"
    },

    -- Static data: 0xE000 - 0xFFFF (8KB)
    STATIC = {
        base = 0xE000,
        size = 0x2000,
        name = "Static"
    }
}

-- Virtual memory configuration
Constants.VM_CONFIG = {
    PAGE_SIZE = 4096,        -- 4KB pages
    PAGE_SHIFT = 12,         -- log2(PAGE_SIZE)
    TLB_ENTRIES = 64,        -- TLB cache size
    MAX_PAGES = 16384        -- Maximum number of pages
}

-- Cache configuration
Constants.CACHE_CONFIG = {
    L1_DATA = {
        size = 32768,        -- 32KB
        line_size = 64,      -- 64 byte cache lines
        associativity = 8,   -- 8-way set associative
        name = "L1D"
    },
    L1_INST = {
        size = 32768,        -- 32KB
        line_size = 64,
        associativity = 8,
        name = "L1I"
    },
    L2 = {
        size = 262144,       -- 256KB
        line_size = 64,
        associativity = 8,
        name = "L2"
    },
    L3 = {
        size = 8388608,      -- 8MB
        line_size = 64,
        associativity = 16,
        name = "L3"
    }
}

-- Type size definitions (in bytes)
Constants.TYPE_SIZES = {
    -- Unsigned integers
    uint8  = 1,
    uint16 = 2,
    uint32 = 4,
    uint64 = 8,

    -- Signed integers
    int8   = 1,
    int16  = 2,
    int32  = 4,
    int64  = 8,

    -- Floating point
    float  = 4,
    double = 8,

    -- Other
    char   = 1,
    bool   = 1,
    ptr    = 8  -- 64-bit pointers
}

-- Alignment requirements
Constants.ALIGNMENT = {
    DEFAULT = 8,
    CACHE_LINE = 64,
    PAGE = 4096,
    SIMD_128 = 16,
    SIMD_256 = 32,
    SIMD_512 = 64
}

-- Error codes
Constants.ERROR = {
    SUCCESS = 0,
    OUT_OF_MEMORY = -1,
    INVALID_ADDRESS = -2,
    ALIGNMENT_FAULT = -3,
    PAGE_FAULT = -4,
    PROTECTION_FAULT = -5,
    DOUBLE_FREE = -6,
    MEMORY_LEAK = -7
}

return Constants