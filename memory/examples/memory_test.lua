-- examples/memory_test.lua
-- Comprehensive test and demonstration of the memory system
package.path = package.path .. ';../../?.lua'

local Memory = require("memory.init")

-- open log file
local logfile = fs.open("memory_test.log", "w")
local _print = _G.print  -- keep original

-- safe logger: printf-style or plain strings; handles blank lines
local function log(fmt, ...)
    local n = select("#", ...)
    local msg
    if fmt == nil and n == 0 then
        msg = ""
    elseif n > 0 then
        msg = string.format(fmt, ...)
    else
        msg = tostring(fmt)
    end
    if logfile then logfile.write(msg .. "\n") end
    if _print then _print(msg) end
end

print = log

-- === script begins ===

local mem = Memory.create_system({size = 131072})  -- 128KB
print("Memory v" .. Memory.VERSION)
print("=" .. string.rep("=", 60))
print("")

-- Test 1: Basic memory operations
print("TEST 1: Basic Memory Operations")
print("-" .. string.rep("-", 40))
print("")

local addr1 = mem:malloc(32)
print(string.format("Allocated 32 bytes at 0x%08X", addr1))

local int32 = mem:create_type("int32", addr1)
int32:set(42)
print(string.format("Stored int32 value: %d", int32:get()))

local float_addr = mem:malloc(4, 4)
local float = mem:create_type("float", float_addr)
float:set(3.14159)
print(string.format("Stored float value: %.5f", float:get()))
print("")

-- Test 2: Arrays
print("TEST 2: Array Operations")
print("-" .. string.rep("-", 40))
print("")

local array_addr = mem:malloc(40, 8)  -- 10 int32s, 8-byte aligned
local array = mem:create_array("int32", array_addr, 10)

for i = 1, 10 do
    array[i]:set(i * i)
end

print("Array contents (squares):")
local values = {}
for i = 1, 10 do
    table.insert(values, tostring(array[i]:get()))
end
print("  " .. table.concat(values, ", "))
print("")

-- Test 3: Stack operations
print("TEST 3: Stack Operations")
print("-" .. string.rep("-", 40))
print("")

mem.stack:enter_frame(64)
local local_var = mem.stack:allocate_local(8)
local stack_var = mem:create_type("int64", local_var)
stack_var:set(1234567890)
print(string.format("Stack variable: %d", stack_var:get()))
print(string.format("Stack usage: %d bytes", mem.stack:get_usage()))
mem.stack:leave_frame()
print(string.format("Stack after frame exit: %d bytes", mem.stack:get_usage()))
print("")

-- Test 4: Smart pointers
print("TEST 4: Smart Pointers")
print("-" .. string.rep("-", 40))
print("")

local unique = mem:create_unique_ptr("int32")
unique:make(100)
print(tostring(unique))

local shared1 = mem:create_shared_ptr("int64")
shared1:make(999)
print(tostring(shared1))

local shared2 = shared1:copy()
print(string.format("Shared pointer copied, use count: %d", shared1:use_count()))
print("")

-- Test 5: Virtual memory
print("TEST 5: Virtual Memory")
print("-" .. string.rep("-", 40))
print("")

mem.vm:map_page(0, 0, {write = true, execute = false})
mem.vm:map_page(1, 1, {write = true, execute = false})
mem.vm:map_page(10, 2, {write = false, execute = true})

local virt_addr = 0x1000  -- Page 1
local phys_addr = mem.vm:translate(virt_addr)
print(string.format("Virtual 0x%04X -> Physical 0x%04X", virt_addr, phys_addr))
print("")

-- Test 6: Cache simulation
print("TEST 6: Cache Operations")
print("-" .. string.rep("-", 40))
print("")

for i = 1, 100 do
    local addr = (i * 64) % 4096  -- Different cache lines
    mem.cache:read(addr, 4, "l1d")
end

for i = 1, 50 do
    local addr = (i * 64) % 4096
    mem.cache:read(addr, 4, "l1d")
end

local cache_stats = mem.cache:get_statistics()
print(string.format("L1D Cache - Hits: %d, Misses: %d, Hit Rate: %.1f%%",
    cache_stats.levels.l1d.hits,
    cache_stats.levels.l1d.misses,
    cache_stats.levels.l1d.hit_rate * 100))
print("")

-- Test 7: Memory-mapped I/O
print("TEST 7: Memory-Mapped I/O")
print("-" .. string.rep("-", 40))
print("")

mem.mmio:register_device({
    name = "uart0",
    base_address = 0xC000,
    size = 16,
    registers = {
        data = {offset = 0, default = 0},
        status = {offset = 4, default = 1}
    },
    write_handler = function(offset, value, size)
        if offset == 0 then
            local ch = (value >= 32 and value <= 126) and string.char(value) or "?"
            print(string.format("  UART: Transmitted byte 0x%02X ('%s')", value, ch))
        end
    end,
    read_handler = function(offset, size)
        if offset == 4 then
            return 1  -- Always ready
        end
        return 0
    end
})

local message = "Hello!"
for i = 1, #message do
    mem.mmio:write(0xC000, string.byte(message, i), 1)
end
print("")

-- Test 8: Memory dump
print("TEST 8: Memory Dump")
print("-" .. string.rep("-", 40))
print("")
print(Memory.Debug.hexdump(mem.pool, addr1, 64))
print("")

-- Clean shutdown to reflect frees in the report
print("CLEANUP")
print("-" .. string.rep("-", 40))
print("")

-- Release smart pointers
shared2:reset()
shared1:reset()
unique:reset()
print("Released smart pointers")

-- Free heap allocations from tests
mem:free(array_addr)
mem:free(float_addr)
mem:free(addr1)
print("Freed array, float, and int allocations")
print("")

-- Final report
print("SYSTEM REPORT")
print("=" .. string.rep("=", 60))
print(Memory.Debug.system_report({
    memory_pool = mem.pool,
    stack_manager = mem.stack,
    heap_allocator = mem.heap,
    vm_manager = mem.vm,
    cache_controller = mem.cache,
    mmio_controller = mem.mmio
}))

if logfile then logfile.close() end