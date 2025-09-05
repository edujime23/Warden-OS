-- memory_debug.lua
-- Memory debugging and visualization utilities

local Constants = require("memory.utils.constants")

local MemoryDebug = {}

local function format_byte(byte) return string.format("%02X", byte) end
local function format_address(address, width) width = width or 4; return string.format("%0" .. width .. "X", address) end
local function is_printable(byte) return byte >= 32 and byte <= 126 end

function MemoryDebug.hexdump(memory_pool, start_address, length, bytes_per_line)
    start_address = start_address or 0
    length = length or 256
    bytes_per_line = bytes_per_line or 16

    local output = {}
    table.insert(output, string.format("Memory dump from 0x%s to 0x%s:",
        format_address(start_address, 8),
        format_address(start_address + length - 1, 8)))
    table.insert(output, "")

    for addr = start_address, start_address + length - 1, bytes_per_line do
        local hex_part, ascii_part = {}, {}
        local line = format_address(addr, 8) .. ":  "

        for i = 0, bytes_per_line - 1 do
            if addr + i < start_address + length then
                local byte = memory_pool:read_u8(addr + i)
                table.insert(hex_part, format_byte(byte))
                table.insert(ascii_part, is_printable(byte) and string.char(byte) or ".")
            else
                table.insert(hex_part, "  ")
                table.insert(ascii_part, " ")
            end
            if i % 4 == 3 then table.insert(hex_part, " ") end
        end

        line = line .. table.concat(hex_part, " ") .. "  |" .. table.concat(ascii_part) .. "|"
        table.insert(output, line)
    end
    return table.concat(output, "\n")
end

function MemoryDebug.memory_map(stats)
    local output = {}
    table.insert(output, "Memory Region Map:")
    table.insert(output, "==================")

    for _, region in pairs(Constants.MEMORY_REGIONS) do
        table.insert(output, string.format("%-10s: 0x%s - 0x%s (%d KB)",
            region.name,
            format_address(region.base, 8),
            format_address(region.base + region.size - 1, 8),
            region.size / 1024))
    end
    return table.concat(output, "\n")
end

function MemoryDebug.stack_trace(stack_manager)
    local output = {}
    table.insert(output, "Stack Trace:")
    table.insert(output, "============")
    local stats = stack_manager:get_statistics()
    table.insert(output, string.format("Stack pointer: 0x%s", format_address(stats.stack_top, 8)))
    table.insert(output, string.format("Stack base:    0x%s", format_address(stats.stack_base, 8)))
    table.insert(output, string.format("Stack used:    %d bytes", stats.stack_used))
    table.insert(output, string.format("Frame depth:   %d", stats.current_depth))
    return table.concat(output, "\n")
end

function MemoryDebug.heap_analysis(heap_allocator)
    local stats = heap_allocator:get_statistics()
    local output = {}
    table.insert(output, "Heap Analysis:")
    table.insert(output, "==============")
    table.insert(output, string.format("Total size:        %d bytes", stats.heap_size))
    table.insert(output, string.format("Allocated:         %d bytes", stats.allocated_bytes))
    table.insert(output, string.format("Free:              %d bytes", stats.free_bytes))
    table.insert(output, string.format("Allocated blocks:  %d", stats.allocated_blocks))
    table.insert(output, string.format("Free blocks:       %d", stats.free_blocks))
    table.insert(output, string.format("Fragmentation:     %.2f%%", stats.fragmentation * 100))
    table.insert(output, string.format("Total allocations: %d", stats.allocation_count))
    table.insert(output, string.format("Total frees:       %d", stats.free_count))
    return table.concat(output, "\n")
end

function MemoryDebug.cache_stats(cache_controller)
    local stats = cache_controller:get_statistics()
    local output = {}
    table.insert(output, "Cache Statistics:")
    table.insert(output, "=================")

    local order = { "l1d", "l1i", "l2", "l3" }
    for _, name in ipairs(order) do
        local level_stats = stats.levels[name]
        if level_stats then
            table.insert(output, string.format("\n%s Cache:", string.upper(name)))
            table.insert(output, string.format("  Size:        %d KB", level_stats.size / 1024))
            table.insert(output, string.format("  Line size:   %d bytes", level_stats.line_size))
            table.insert(output, string.format("  Ways:        %d", level_stats.associativity))
            table.insert(output, string.format("  Sets:        %d", level_stats.num_sets))
            table.insert(output, string.format("  Hits:        %d", level_stats.hits))
            table.insert(output, string.format("  Misses:      %d", level_stats.misses))
            table.insert(output, string.format("  Hit rate:    %.2f%%", level_stats.hit_rate * 100))
            table.insert(output, string.format("  Evictions:   %d", level_stats.evictions))
            table.insert(output, string.format("  Writebacks:  %d", level_stats.writebacks))
        end
    end

    return table.concat(output, "\n")
end

function MemoryDebug.mmio_stats(mmio_controller)
    local stats = mmio_controller:get_statistics()
    local output = {}

    table.insert(output, "MMIO Statistics:")
    table.insert(output, "================")
    table.insert(output, string.format("Base: 0x%s", format_address(stats.mmio_base, 8)))
    table.insert(output, string.format("Size: %d bytes", stats.mmio_size))
    table.insert(output, string.format("Devices: %d", stats.device_count))
    table.insert(output, string.format("Accesses: %d", stats.access_count))

    if stats.devices and #stats.devices > 0 then
        table.insert(output, "")
        table.insert(output, "Devices:")
        for _, dev in ipairs(stats.devices) do
            table.insert(output, string.format(
                "  - %s @ [0x%s - 0x%s] (%d bytes)",
                dev.name,
                format_address(dev.base_address, 8),
                format_address(dev.end_address, 8),
                dev.size
            ))
        end
    end
    return table.concat(output, "\n")
end

function MemoryDebug.vm_stats(vm_manager)
    local stats = vm_manager:get_statistics()
    local output = {}
    table.insert(output, "Virtual Memory Statistics:")
    table.insert(output, "==========================")
    table.insert(output, string.format("Page size:       %d bytes", stats.page_size))
    table.insert(output, string.format("Mapped pages:    %d", stats.mapped_pages))
    table.insert(output, string.format("Dirty pages:     %d", stats.dirty_pages))
    table.insert(output, string.format("Accessed pages:  %d", stats.accessed_pages))
    table.insert(output, string.format("TLB entries:     %d", stats.tlb_entries))
    table.insert(output, string.format("TLB hits:        %d", stats.tlb_hits))
    table.insert(output, string.format("TLB misses:      %d", stats.tlb_misses))
    table.insert(output, string.format("TLB hit rate:    %.2f%%", stats.tlb_hit_rate * 100))
    table.insert(output, string.format("Page faults:     %d", stats.page_faults))
    return table.concat(output, "\n")
end

function MemoryDebug.system_report(components)
    local output = {}
    table.insert(output, "=" .. string.rep("=", 60))
    table.insert(output, "MEMORY SYSTEM REPORT")
    table.insert(output, "=" .. string.rep("=", 60))
    table.insert(output, "")

    if components.memory_pool then
        local stats = components.memory_pool:get_statistics()
        table.insert(output, string.format("Memory Pool: %d KB total, %d accesses, %d faults",
            stats.size / 1024, stats.access_count, stats.fault_count))
        table.insert(output, "")
    end

    if components.stack_manager then
        table.insert(output, MemoryDebug.stack_trace(components.stack_manager))
        table.insert(output, "")
    end

    if components.heap_allocator then
        table.insert(output, MemoryDebug.heap_analysis(components.heap_allocator))
        table.insert(output, "")
    end

    if components.vm_manager then
        table.insert(output, MemoryDebug.vm_stats(components.vm_manager))
        table.insert(output, "")
    end

    if components.cache_controller then
        table.insert(output, MemoryDebug.cache_stats(components.cache_controller))
        table.insert(output, "")
    end

    if components.mmio_controller then
        table.insert(output, MemoryDebug.mmio_stats(components.mmio_controller))
        table.insert(output, "")
    end

    table.insert(output, "=" .. string.rep("=", 60))
    return table.concat(output, "\n")
end

return MemoryDebug