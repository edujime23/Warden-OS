-- heap_allocator.lua
-- Dynamic memory allocation with first-fit algorithm and coalescing

local Constants = require("memory.utils.constants")

local HeapAllocator = {}
HeapAllocator.__index = HeapAllocator

local function create_block(address, size, is_free)
    return {
        address = address,
        size = size,
        is_free = is_free,
        next = nil,
        prev = nil,
        alignment = Constants.ALIGNMENT.DEFAULT
    }
end

function HeapAllocator:new(memory_pool, base_address, heap_size)
    local allocator = {
        pool = memory_pool,
        base = base_address or Constants.MEMORY_REGIONS.HEAP.base,
        size = heap_size or Constants.MEMORY_REGIONS.HEAP.size,
        free_list = nil,
        allocated_list = nil,
        total_allocated = 0,
        allocation_count = 0,
        free_count = 0
    }

    allocator.free_list = create_block(allocator.base, allocator.size, true)
    setmetatable(allocator, HeapAllocator)
    return allocator
end

local function align_up(address, alignment)
    local mask = alignment - 1
    return bit32.band((address + mask), bit32.bnot(mask))
end

function HeapAllocator:allocate(size, alignment)
    alignment = alignment or Constants.ALIGNMENT.DEFAULT
    if bit32.band(alignment, (alignment - 1)) ~= 0 then
        error("Alignment must be power of 2")
    end

    size = align_up(size, alignment)

    local current = self.free_list
    local best_fit, best_size = nil, math.huge
    local best_aligned_addr, best_padding = nil, 0

    while current do
        local aligned_addr = align_up(current.address, alignment)
        local padding = aligned_addr - current.address
        local total_size = size + padding

        if current.size >= total_size and current.size < best_size then
            best_fit = current
            best_size = current.size
            best_aligned_addr = aligned_addr
            best_padding = padding
        end

        current = current.next
    end

    if not best_fit then
        error(string.format("Out of memory: requested=%d bytes, alignment=%d", size, alignment))
    end

    self:remove_from_list(best_fit, true)

    if best_padding > 0 then
        local left = create_block(best_fit.address, best_padding, true)
        self:add_to_list(left, true)
    end

    local allocated = create_block(best_aligned_addr, size, false)
    allocated.alignment = alignment
    self:add_to_list(allocated, false)

    local used = best_padding + size
    local remainder = best_fit.size - used
    if remainder > 0 then
        local right = create_block(best_aligned_addr + size, remainder, true)
        self:add_to_list(right, true)
    end

    self.total_allocated = self.total_allocated + size
    self.allocation_count = self.allocation_count + 1
    self.pool:clear(allocated.address, size)

    return allocated.address
end

-- Free allocated memory
function HeapAllocator:free(address)
    -- Find allocated block
    local block = self:find_block(address, false)
    if not block then
        error(string.format("Invalid free: address 0x%X not allocated", address))
    end

    -- Remove from allocated list
    self:remove_from_list(block, false)

    -- Capture original size before coalescing modifies the block
    local freed_size = block.size

    -- Mark as free and add to free list
    block.is_free = true
    self:add_to_list(block, true)

    -- Update statistics
    self.total_allocated = self.total_allocated - freed_size
    self.free_count = self.free_count + 1

    -- Coalesce adjacent free blocks
    self:coalesce_free_blocks()

    return true
end

function HeapAllocator:reallocate(address, new_size, alignment)
    local block = self:find_block(address, false)
    if not block then
        error(string.format("Invalid realloc: address 0x%X not allocated", address))
    end

    alignment = alignment or block.alignment
    new_size = align_up(new_size, alignment)

    if new_size <= block.size then
        local freed_size = block.size - new_size
        if freed_size > 0 then
            -- Shrink in-place and return tail to free list
            block.size = new_size
            self.total_allocated = self.total_allocated - freed_size

            local tail = create_block(address + new_size, freed_size, true)
            self:add_to_list(tail, true)
            self:coalesce_free_blocks()
        end
        return address
    end

    -- Need a new block
    local new_address = self:allocate(new_size, alignment)
    self.pool:copy(new_address, address, block.size)
    self:free(address)
    return new_address
end

function HeapAllocator:find_block(address, in_free_list)
    local list = in_free_list and self.free_list or self.allocated_list
    local current = list
    while current do
        if current.address == address then
            return current
        end
        current = current.next
    end
    return nil
end

function HeapAllocator:add_to_list(block, to_free_list)
    if to_free_list then
        block.next = self.free_list
        if self.free_list then self.free_list.prev = block end
        self.free_list = block
    else
        block.next = self.allocated_list
        if self.allocated_list then self.allocated_list.prev = block end
        self.allocated_list = block
    end
    block.prev = nil
end

function HeapAllocator:remove_from_list(block, from_free_list)
    if block.prev then
        block.prev.next = block.next
    else
        if from_free_list then
            self.free_list = block.next
        else
            self.allocated_list = block.next
        end
    end
    if block.next then
        block.next.prev = block.prev
    end
    block.next, block.prev = nil, nil
end

function HeapAllocator:coalesce_free_blocks()
    local blocks, current = {}, self.free_list
    while current do
        table.insert(blocks, current)
        current = current.next
    end
    if #blocks <= 1 then return end

    table.sort(blocks, function(a, b) return a.address < b.address end)

    self.free_list = nil
    local i = 1
    while i <= #blocks do
        local block = blocks[i]
        local j = i + 1
        while j <= #blocks and block.address + block.size == blocks[j].address do
            block.size = block.size + blocks[j].size
            j = j + 1
        end
        block.next, block.prev = nil, nil
        self:add_to_list(block, true)
        i = j
    end
end

function HeapAllocator:get_statistics()
    local free_blocks, free_bytes, allocated_blocks = 0, 0, 0

    local current = self.free_list
    while current do
        free_blocks = free_blocks + 1
        free_bytes = free_bytes + current.size
        current = current.next
    end

    current = self.allocated_list
    while current do
        allocated_blocks = allocated_blocks + 1
        current = current.next
    end

    return {
        heap_size = self.size,
        allocated_bytes = self.total_allocated,
        free_bytes = free_bytes,
        allocated_blocks = allocated_blocks,
        free_blocks = free_blocks,
        allocation_count = self.allocation_count,
        free_count = self.free_count,
        fragmentation = free_blocks > 0 and (free_blocks - 1) / free_blocks or 0
    }
end

return HeapAllocator