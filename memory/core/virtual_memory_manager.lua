-- virtual_memory_manager.lua
-- Virtual memory management with paging and TLB

local Constants = require("memory.utils.constants")

local VirtualMemoryManager = {}
VirtualMemoryManager.__index = VirtualMemoryManager

-- Page table entry structure
local function create_pte()
    return {
        frame_number = 0,     -- Physical frame number
        present = false,      -- Page in memory
        dirty = false,        -- Page modified
        accessed = false,     -- Page accessed
        user = false,         -- User/kernel mode
        writable = true,      -- Write permission
        executable = false,   -- Execute permission
        cached = true         -- Cacheable
    }
end

-- Initialize virtual memory manager
function VirtualMemoryManager:new(memory_pool)
    local vmm = {
        pool = memory_pool,
        page_size = Constants.VM_CONFIG.PAGE_SIZE,
        page_shift = Constants.VM_CONFIG.PAGE_SHIFT,
        page_table = {},     -- Virtual to physical mapping
        tlb = {},            -- Translation lookaside buffer
        tlb_size = Constants.VM_CONFIG.TLB_ENTRIES,
        tlb_hits = 0,
        tlb_misses = 0,
        page_faults = 0,
        next_frame = 0,      -- Next available physical frame
        tlb_tick = 0         -- Monotonic counter for TLB LRU
    }

    setmetatable(vmm, VirtualMemoryManager)
    return vmm
end

-- Extract page number from virtual address
function VirtualMemoryManager:get_page_number(virtual_address)
    return bit32.rshift(virtual_address, self.page_shift)
end

-- Extract page offset from virtual address
function VirtualMemoryManager:get_page_offset(virtual_address)
    return bit32.band(virtual_address, (self.page_size - 1))
end

-- Map virtual page to physical frame
function VirtualMemoryManager:map_page(virtual_page, physical_frame, permissions)
    local pte = create_pte()
    pte.frame_number = physical_frame or self:allocate_frame()
    pte.present = true

    -- Set permissions
    if permissions then
        pte.writable = permissions.write ~= false
        pte.executable = permissions.execute == true
        pte.user = permissions.user == true
        pte.cached = permissions.cached ~= false
    end

    -- Update page table
    self.page_table[virtual_page] = pte

    -- Invalidate TLB entry
    self.tlb[virtual_page] = nil

    return pte.frame_number
end

-- Unmap virtual page
function VirtualMemoryManager:unmap_page(virtual_page)
    local pte = self.page_table[virtual_page]
    if pte then
        self.page_table[virtual_page] = nil
        self.tlb[virtual_page] = nil
        return true
    end
    return false
end

-- Translate virtual address to physical address
function VirtualMemoryManager:translate(virtual_address)
    local page = self:get_page_number(virtual_address)
    local offset = self:get_page_offset(virtual_address)

    -- Check TLB first
    local tlb_entry = self.tlb[page]
    if tlb_entry then
        self.tlb_hits = self.tlb_hits + 1
        self.tlb_tick = self.tlb_tick + 1
        tlb_entry.tick = self.tlb_tick  -- Update LRU tick
        return bit32.bor(bit32.lshift(tlb_entry.frame_number, self.page_shift), offset)
    end

    self.tlb_misses = self.tlb_misses + 1

    -- Page table lookup
    local pte = self.page_table[page]
    if not pte or not pte.present then
        self.page_faults = self.page_faults + 1
        error(string.format(
            "Page fault: virtual address 0x%X, page 0x%X not mapped",
            virtual_address, page
        ))
    end

    -- Update TLB
    self:update_tlb(page, pte)

    -- Mark page as accessed
    pte.accessed = true

    return bit32.bor(bit32.lshift(pte.frame_number, self.page_shift), offset)
end

-- Update TLB with new entry (LRU by monotonic tick)
function VirtualMemoryManager:update_tlb(virtual_page, pte)
    -- Evict LRU if full
    local tlb_count = 0
    for _ in pairs(self.tlb) do
        tlb_count = tlb_count + 1
    end

    if tlb_count >= self.tlb_size then
        local oldest_page = nil
        local oldest_tick = math.huge
        for page, entry in pairs(self.tlb) do
            if entry.tick < oldest_tick then
                oldest_tick = entry.tick
                oldest_page = page
            end
        end
        if oldest_page then
            self.tlb[oldest_page] = nil
        end
    end

    -- Add new TLB entry
    self.tlb_tick = self.tlb_tick + 1
    self.tlb[virtual_page] = {
        frame_number = pte.frame_number,
        tick = self.tlb_tick
    }
end

-- Allocate physical frame
function VirtualMemoryManager:allocate_frame()
    local frame = self.next_frame
    self.next_frame = self.next_frame + 1

    if frame >= Constants.VM_CONFIG.MAX_PAGES then
        error("Out of physical frames")
    end

    return frame
end

-- Flush entire TLB
function VirtualMemoryManager:flush_tlb()
    self.tlb = {}
end

-- Flush specific TLB entry
function VirtualMemoryManager:flush_tlb_entry(virtual_page)
    self.tlb[virtual_page] = nil
end

-- Set page attributes
function VirtualMemoryManager:set_page_attributes(virtual_page, attributes)
    local pte = self.page_table[virtual_page]
    if not pte then
        error(string.format("Page 0x%X not mapped", virtual_page))
    end

    if attributes.writable ~= nil then
        pte.writable = attributes.writable
    end
    if attributes.executable ~= nil then
        pte.executable = attributes.executable
    end
    if attributes.user ~= nil then
        pte.user = attributes.user
    end
    if attributes.cached ~= nil then
        pte.cached = attributes.cached
    end

    self:flush_tlb_entry(virtual_page)
end

-- Check access permissions
function VirtualMemoryManager:check_access(virtual_address, access_type)
    local page = self:get_page_number(virtual_address)
    local pte = self.page_table[page]

    if not pte or not pte.present then
        return false, "Page not present"
    end

    if access_type == "write" and not pte.writable then
        return false, "Write permission denied"
    end

    if access_type == "execute" and not pte.executable then
        return false, "Execute permission denied"
    end

    return true
end

-- Get virtual memory statistics
function VirtualMemoryManager:get_statistics()
    local mapped_pages = 0
    local dirty_pages = 0
    local accessed_pages = 0

    for _, pte in pairs(self.page_table) do
        if pte.present then
            mapped_pages = mapped_pages + 1
            if pte.dirty then dirty_pages = dirty_pages + 1 end
            if pte.accessed then accessed_pages = accessed_pages + 1 end
        end
    end

    return {
        page_size = self.page_size,
        mapped_pages = mapped_pages,
        dirty_pages = dirty_pages,
        accessed_pages = accessed_pages,
        tlb_entries = self.tlb_size,
        tlb_hits = self.tlb_hits,
        tlb_misses = self.tlb_misses,
        tlb_hit_rate = self.tlb_hits / math.max(1, self.tlb_hits + self.tlb_misses),
        page_faults = self.page_faults
    }
end

return VirtualMemoryManager