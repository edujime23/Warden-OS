-- devices/cpu/mmu.lua
-- Virtual memory manager with paging, ASIDs, and an LRU TLB.

local MMU = {}
MMU.__index = MMU

local function create_pte()
    return {
        frame_number = 0, present = false, dirty = false, accessed = false,
        user = false, writable = true, executable = false, cached = true,
        memtype = "normal"
    }
end

function MMU:new(opts)
    opts = opts or {}
    local page_size = opts.page_size or 4096
    return setmetatable({
        page_size   = page_size,
        page_shift  = math.floor(math.log(page_size, 2)),
        tlb_entries = opts.tlb_entries or 64, max_frames  = opts.max_frames or 16384,
        current_asid = 0, page_table   = {}, tlb          = {}, tlb_tick     = 0,
        tlb_hits     = 0, tlb_misses   = 0, page_faults  = 0, next_frame   = 0
    }, MMU)
end

local function tlb_key(asid, vpage) return tostring(asid) .. ":" .. tostring(vpage) end

function MMU:get_page_number(va)
    return math.floor(va / self.page_size)
end

function MMU:get_page_offset(va)
    return va % self.page_size
end

function MMU:set_asid(asid)
    self.current_asid = asid or 0
    if not self.page_table[self.current_asid] then
        self.page_table[self.current_asid] = {}
    end
end

function MMU:map_page(vpage, pframe, perm, asid)
    local space = asid or self.current_asid
    if not self.page_table[space] then self.page_table[space] = {} end
    local pte = create_pte()
    pte.frame_number = pframe or self:allocate_frame()
    pte.present = true
    if perm then
        if perm.write     ~= nil then pte.writable   = perm.write end
        if perm.execute   ~= nil then pte.executable = perm.execute end
        if perm.user      ~= nil then pte.user       = perm.user end
        if perm.cached    ~= nil then pte.cached     = perm.cached end
        if perm.memtype   ~= nil then pte.memtype    = perm.memtype end
    end
    if pte.memtype == "device" or pte.memtype == "wc" then
        pte.cached = perm and perm.cached ~= nil and perm.cached or false
    end
    self.page_table[space][vpage] = pte
    self.tlb[tlb_key(space, vpage)] = nil
    return pte.frame_number
end

function MMU:unmap_page(vpage, asid)
    local space = asid or self.current_asid
    if self.page_table[space] and self.page_table[space][vpage] then
        self.page_table[space][vpage] = nil
        self.tlb[tlb_key(space, vpage)] = nil
        return true
    end
    return false
end

function MMU:translate(va)
    local space = self.current_asid
    local vpage  = self:get_page_number(va)
    local offset = self:get_page_offset(va)
    local k = tlb_key(space, vpage)
    local e = self.tlb[k]
    if e then
        self.tlb_hits = self.tlb_hits + 1; self.tlb_tick = self.tlb_tick + 1; e.tick = self.tlb_tick
        local pte = self.page_table[space] and self.page_table[space][vpage]
        return (e.frame_number * self.page_size) + offset, pte
    end
    self.tlb_misses = self.tlb_misses + 1
    local pt = self.page_table[space]
    local pte = pt and pt[vpage] or nil
    if not pte or not pte.present then
        self.page_faults = self.page_faults + 1
        error(string.format("Page fault @VA 0x%X (asid=%d vpage=0x%X)", va, space, vpage))
    end
    self:update_tlb(space, vpage, pte)
    pte.accessed = true
    return (pte.frame_number * self.page_size) + offset, pte
end

function MMU:update_tlb(asid, vpage, pte)
    local count = 0
    for _ in pairs(self.tlb) do count = count + 1 end
    if count >= self.tlb_entries then
        local oldest, oldest_tick
        for key, ent in pairs(self.tlb) do
            if not oldest_tick or ent.tick < oldest_tick then oldest, oldest_tick = key, ent.tick end
        end
        if oldest then self.tlb[oldest] = nil end
    end
    self.tlb_tick = self.tlb_tick + 1
    self.tlb[tlb_key(asid, vpage)] = { frame_number = pte.frame_number, tick = self.tlb_tick }
end

function MMU:allocate_frame()
    local f = self.next_frame; self.next_frame = self.next_frame + 1
    if f >= self.max_frames then error("Out of physical frames") end
    return f
end

function MMU:flush_tlb(asid)
    if asid == nil then self.tlb = {}; return end
    for key, _ in pairs(self.tlb) do
        if key:match("^"..tostring(asid) .. ":") then self.tlb[key] = nil end
    end
end

function MMU:flush_tlb_entry(vpage, asid)
    local space = asid or self.current_asid; self.tlb[tlb_key(space, vpage)] = nil
end

function MMU:set_page_attributes(vpage, attributes, asid)
    local space = asid or self.current_asid
    local pte = self.page_table[space] and self.page_table[space][vpage]
    if not pte then error(string.format("Page 0x%X not mapped (asid=%d)", vpage, space)) end
    if attributes.writable   ~= nil then pte.writable   = attributes.writable   end
    if attributes.executable ~= nil then pte.executable = attributes.executable end
    if attributes.user       ~= nil then pte.user       = attributes.user       end
    if attributes.cached     ~= nil then pte.cached     = attributes.cached     end
    if attributes.memtype    ~= nil then
        pte.memtype = attributes.memtype
        if pte.memtype == "device" or pte.memtype == "wc" then
            if attributes.cached == nil then pte.cached = false end
        end
    end
    self:flush_tlb_entry(vpage, space)
end

function MMU:check_access(va, kind)
    local space = self.current_asid; local vpage = self:get_page_number(va)
    local pt = self.page_table[space]; local pte = pt and pt[vpage]
    if not pte or not pte.present then return false, "not present" end
    if kind == "write" and not pte.writable then return false, "write denied" end
    if kind == "execute" and not pte.executable then return false, "exec denied" end
    return true
end

function MMU:get_statistics()
    local mapped, dirty, accessed, spaces = 0, 0, 0, 0
    for asid, pt in pairs(self.page_table) do
        spaces = spaces + 1
        for _, pte in pairs(pt) do
            if pte.present then mapped=mapped+1; if pte.dirty then dirty=dirty+1 end; if pte.accessed then accessed=accessed+1 end end
        end
    end
    local total = self.tlb_hits + self.tlb_misses
    return {
        page_size = self.page_size, asid = self.current_asid, spaces = spaces,
        mapped = mapped, dirty = dirty, accessed = accessed,
        tlb_hits = self.tlb_hits, tlb_misses = self.tlb_misses,
        tlb_rate = total > 0 and (self.tlb_hits / total) or 0, page_faults = self.page_faults
    }
end

return MMU