-- devices/cpu/mmu.lua
-- Virtual memory manager with paging and an LRU TLB.

local MMU = {}
MMU.__index = MMU

local function create_pte()
    return {
        frame_number = 0,
        present = false,
        dirty = false,
        accessed = false,
        user = false,
        writable = true,
        executable = false,
        cached = true
    }
end

---Create a new MMU instance.
---@param opts { page_size?: integer, tlb_entries?: integer, max_frames?: integer }|nil
---@return MMU
function MMU:new(opts)
    opts = opts or {}
    local page_size = opts.page_size or 4096
    local self_ = {
        page_size   = page_size,
        page_shift  = math.floor(math.log(page_size, 2)),
        tlb_entries = opts.tlb_entries or 64,
        max_frames  = opts.max_frames or 16384,

        page_table  = {},
        tlb         = {},
        tlb_tick    = 0,
        tlb_hits    = 0,
        tlb_misses  = 0,
        page_faults = 0,
        next_frame  = 0
    }
    return setmetatable(self_, MMU)
end

local bit32 = bit32

---@param va integer
---@return integer
function MMU:get_page_number(va)
    return bit32.rshift(va, self.page_shift)
end

---@param va integer
---@return integer
function MMU:get_page_offset(va)
    return bit32.band(va, self.page_size - 1)
end

---Map virtual page to frame.
---@param vpage integer
---@param pframe integer|nil
---@param perm table|nil
---@return integer frame
function MMU:map_page(vpage, pframe, perm)
    local pte = create_pte()
    pte.frame_number = pframe or self:allocate_frame()
    pte.present = true
    if perm then
        pte.writable   = perm.write ~= false
        pte.executable = perm.execute == true
        pte.user       = perm.user == true
        pte.cached     = perm.cached ~= false
    end
    self.page_table[vpage] = pte
    self.tlb[vpage] = nil
    return pte.frame_number
end

---@param vpage integer
---@return boolean
function MMU:unmap_page(vpage)
    if self.page_table[vpage] then
        self.page_table[vpage] = nil
        self.tlb[vpage] = nil
        return true
    end
    return false
end

---Translate VA -> (PA, PTE).
---@param va integer
---@return integer pa, table pte
function MMU:translate(va)
    local vpage  = self:get_page_number(va)
    local offset = self:get_page_offset(va)

    local e = self.tlb[vpage]
    if e then
        self.tlb_hits = self.tlb_hits + 1
        self.tlb_tick = self.tlb_tick + 1
        e.tick = self.tlb_tick
        return bit32.bor(bit32.lshift(e.frame_number, self.page_shift), offset), self.page_table[vpage]
    end

    self.tlb_misses = self.tlb_misses + 1
    local pte = self.page_table[vpage]
    if not pte or not pte.present then
        self.page_faults = self.page_faults + 1
        error(string.format("Page fault @VA 0x%X (vpage 0x%X)", va, vpage))
    end

    self:update_tlb(vpage, pte)
    pte.accessed = true
    return bit32.bor(bit32.lshift(pte.frame_number, self.page_shift), offset), pte
end

---@param vpage integer
---@param pte table
function MMU:update_tlb(vpage, pte)
    local count = 0
    for _ in pairs(self.tlb) do count = count + 1 end
    if count >= self.tlb_entries then
        local oldest, oldest_tick
        for vp, ent in pairs(self.tlb) do
            if not oldest_tick or ent.tick < oldest_tick then
                oldest, oldest_tick = vp, ent.tick
            end
        end
        if oldest then self.tlb[oldest] = nil end
    end
    self.tlb_tick = self.tlb_tick + 1
    self.tlb[vpage] = { frame_number = pte.frame_number, tick = self.tlb_tick }
end

---@return integer
function MMU:allocate_frame()
    local f = self.next_frame
    self.next_frame = self.next_frame + 1
    if f >= self.max_frames then
        error("Out of physical frames")
    end
    return f
end

function MMU:flush_tlb()
    self.tlb = {}
end

---@param vpage integer
function MMU:flush_tlb_entry(vpage)
    self.tlb[vpage] = nil
end

---@param vpage integer
---@param attributes table
function MMU:set_page_attributes(vpage, attributes)
    local pte = self.page_table[vpage]
    if not pte then error(string.format("Page 0x%X not mapped", vpage)) end
    if attributes.writable   ~= nil then pte.writable   = attributes.writable   end
    if attributes.executable ~= nil then pte.executable = attributes.executable end
    if attributes.user       ~= nil then pte.user       = attributes.user       end
    if attributes.cached     ~= nil then pte.cached     = attributes.cached     end
    self:flush_tlb_entry(vpage)
end

---@param va integer
---@param kind "read"|"write"|"execute"
---@return boolean,string|nil
function MMU:check_access(va, kind)
    local vpage = self:get_page_number(va)
    local pte = self.page_table[vpage]
    if not pte or not pte.present then return false, "not present" end
    if kind == "write" and not pte.writable then return false, "write denied" end
    if kind == "execute" and not pte.executable then return false, "exec denied" end
    return true
end

function MMU:get_statistics()
    local mapped, dirty, accessed = 0, 0, 0
    for _, pte in pairs(self.page_table) do
        if pte.present then
            mapped = mapped + 1
            if pte.dirty then dirty = dirty + 1 end
            if pte.accessed then accessed = accessed + 1 end
        end
    end
    local total = self.tlb_hits + self.tlb_misses
    return {
        page_size = self.page_size,
        mapped = mapped, dirty = dirty, accessed = accessed,
        tlb_hits = self.tlb_hits, tlb_misses = self.tlb_misses,
        tlb_rate = total > 0 and (self.tlb_hits / total) or 0,
        page_faults = self.page_faults
    }
end

return MMU