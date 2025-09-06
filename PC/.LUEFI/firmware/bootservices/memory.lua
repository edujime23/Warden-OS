-- firmware/bootservices/memory.lua
-- Tiny UEFI-like Boot Services memory manager and memory map.

local ABITypes = require("firmware.abi.types")

local BootMem = {}
BootMem.__index = BootMem

local MT = {
    EfiReservedMemoryType=0, EfiLoaderCode=1, EfiLoaderData=2, EfiBootServicesCode=3, EfiBootServicesData=4,
    EfiRuntimeServicesCode=5, EfiRuntimeServicesData=6, EfiConventionalMemory=7, EfiUnusableMemory=8,
    EfiACPIReclaimMemory=9, EfiACPIMemoryNVS=10, EfiMemoryMappedIO=11, EfiMemoryMappedIOPortSpace=12,
    EfiPalCode=13, EfiPersistentMemory=14
}
BootMem.MemoryType = MT
local MA = {
    EFI_MEMORY_UC=1, EFI_MEMORY_WC=2, EFI_MEMORY_WT=4, EFI_MEMORY_WB=8, EFI_MEMORY_WP=4096,
    EFI_MEMORY_RP=8192, EFI_MEMORY_XP=16384, EFI_MEMORY_RUNTIME=2097152
}
BootMem.MemoryAttr = MA
local AT = { AnyAddress=0, MaxAddress=1, Address=2 }
BootMem.AllocateType = AT

function BootMem:new(cpu, bus)
    local self_ = {
        cpu = cpu, bus = bus, page_size = cpu.mmu.page_size, map_key = 1, segments = {},
        abi = ABITypes:new(cpu), descriptor_size = 40, descriptor_version = 1
    }
    setmetatable(self_, BootMem)
    self_:initialize_from_bus()
    return self_
end

function BootMem:initialize_from_bus()
    local regions = self.bus:list_regions(); local ps = self.page_size; local segs = {}
    for _, r in ipairs(regions) do
        local pages = math.floor(r.size / ps)
        if pages > 0 then
            if r.kind == "ram" then
                table.insert(segs, { base = r.base, pages = pages, type = MT.EfiConventionalMemory, attr = MA.EFI_MEMORY_WB, alloc = false, name = r.name })
            elseif r.kind == "mmio" then
                table.insert(segs, { base = r.base, pages = pages, type = MT.EfiMemoryMappedIO, attr = MA.EFI_MEMORY_UC, alloc = true, name = r.name })
            end
        end
    end
    table.sort(segs, function(a,b) return a.base < b.base end)
    self.segments = segs
end

local function align_up(n, a)
    if a == 0 or a == 1 then return n end
    return math.floor((n + a - 1) / a) * a
end

function BootMem:coalesce()
    local out = {}; table.sort(self.segments, function(a,b) return a.base < b.base end)
    for _, s in ipairs(self.segments) do
        if #out == 0 then out[1] = s else
            local last = out[#out]; local last_end = last.base + last.pages * self.page_size
            if (not last.alloc) and (not s.alloc) and last.type == s.type and last.attr == s.attr and s.base == last_end then
                last.pages = last.pages + s.pages
            else out[#out + 1] = s end
        end
    end
    self.segments = out
end

function BootMem:find_free(pages, opts)
    opts = opts or {}; local ps = self.page_size
    local align_pages = math.max(1, opts.align_pages or 1); local align_bytes = align_pages * ps
    local max_addr = opts.max_address; local best_idx, best_base = nil, nil
    for idx, s in ipairs(self.segments) do
        if not s.alloc and s.type == MT.EfiConventionalMemory and s.pages >= pages then
            local seg_base = s.base; local seg_end  = s.base + s.pages * ps
            local alloc_base = align_up(seg_base, align_bytes); local alloc_end = alloc_base + pages * ps
            if alloc_end <= seg_end then
                if not max_addr or (alloc_end - 1) <= max_addr then
                    best_idx, best_base = idx, alloc_base
                    if opts.allocate_type == AT.MaxAddress then
                        local highest_base = math.min(seg_end - pages*ps, max_addr and (max_addr - pages*ps + 1) or (seg_end - pages*ps))
                        highest_base = align_up(highest_base, align_bytes)
                        if highest_base >= seg_base and (highest_base + pages * ps) <= seg_end then best_base = highest_base end
                    end
                    if opts.allocate_type ~= AT.MaxAddress then break end
                end
            end
        end
    end
    return best_idx, best_base
end

function BootMem:allocate_from_segment(idx, alloc_base, page_count, memtype, attr)
    local ps = self.page_size; local s = self.segments[idx]
    local seg_base, seg_end = s.base, s.base + s.pages * ps
    local alloc_end = alloc_base + page_count * ps
    local prefix_pages = math.floor((alloc_base - seg_base) / ps)
    local suffix_pages = math.floor((seg_end - alloc_end) / ps)
    local new = {}
    if prefix_pages > 0 then table.insert(new, { base = seg_base, pages = prefix_pages, type = s.type, attr = s.attr, alloc = s.alloc, name = s.name }) end
    table.insert(new, { base = alloc_base, pages = page_count, type = memtype, attr = attr or s.attr, alloc = true, name = "alloc" })
    if suffix_pages > 0 then table.insert(new, { base = alloc_end, pages = suffix_pages, type = s.type, attr = s.attr, alloc = s.alloc, name = s.name }) end
    table.remove(self.segments, idx)
    for i = #new, 1, -1 do table.insert(self.segments, idx, new[i]) end
    self:coalesce(); self.map_key = self.map_key + 1
end

function BootMem:allocate_pages(memtype, pages, opts)
    opts = opts or {}; local ps = self.page_size
    if opts.allocate_type == AT.Address then
        local addr = opts.address; assert(addr and (addr % ps == 0), "AllocateAddress requires page-aligned address")
        for idx, s in ipairs(self.segments) do
            if not s.alloc and s.type == MT.EfiConventionalMemory then
                local seg_end = s.base + s.pages * ps
                if addr >= s.base and (addr + pages * ps) <= seg_end then
                    self:allocate_from_segment(idx, addr, pages, memtype, s.attr); return addr
                end
            end
        end
        error("AllocatePages(Address): no suitable range")
    else
        local idx, base = self:find_free(pages, opts)
        if not idx then error("AllocatePages: out of memory") end
        self:allocate_from_segment(idx, base, pages, memtype, self.segments[idx].attr); return base
    end
end

function BootMem:free_pages(phys_addr, pages)
    local ps = self.page_size
    for idx, s in ipairs(self.segments) do
        if s.alloc and s.base == phys_addr and s.pages == pages then
            s.alloc = false; s.type = MT.EfiConventionalMemory; s.attr = MA.EFI_MEMORY_WB; s.name = "free"
            self:coalesce(); self.map_key = self.map_key + 1; return true
        end
    end
    error(string.format("FreePages: block not found at 0x%X (%d pages)", phys_addr, pages))
end

function BootMem:allocate_pool(size_bytes)
    local pages = math.max(1, math.ceil(size_bytes / self.page_size))
    local base = self:allocate_pages(MT.EfiBootServicesData, pages, { allocate_type = AT.AnyAddress })
    return base, pages
end
function BootMem:free_pool(base, size_bytes)
    local pages = math.max(1, math.ceil(size_bytes / self.page_size))
    return self:free_pages(base, pages)
end

function BootMem:get_memory_map()
    local out = {}; for _, s in ipairs(self.segments) do
        table.insert(out, { Type = s.type, PhysicalStart = s.base, VirtualStart = 0, NumberOfPages = s.pages, Attribute = s.attr })
    end
    return { descriptors = out, map_key = self.map_key, descriptor_size = self.descriptor_size, descriptor_version = self.descriptor_version }
end

function BootMem:write_memory_map(buffer_va)
    local mm = self:get_memory_map(); local abi = self.abi; local ds = mm.descriptor_size
    local base = buffer_va; local cnt = #mm.descriptors
    local function U32(addr) return abi:view("uint32", addr) end
    local function U64(addr) return abi:view("uint64", addr) end
    for i, d in ipairs(mm.descriptors) do
        local off = base + (i - 1) * ds
        U32(off + 0):set(d.Type); U32(off + 4):set(0)
        U64(off + 8):set(d.PhysicalStart); U64(off + 16):set(0)
        U64(off + 24):set(d.NumberOfPages); U64(off + 32):set(d.Attribute)
    end
    return cnt * ds, cnt
end

return BootMem