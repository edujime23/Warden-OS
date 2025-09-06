-- devices/cpu/cache_controller.lua
-- Multi-level inclusive write-back cache hierarchy with LRU replacement.

---@class CacheController
local CacheController = {}
CacheController.__index = CacheController

local function create_cache_line()
    return {
        valid = false, dirty = false, tag = 0, data = {}, lru_counter = 0,
        present_l1d = false, present_l1i = false, present_l2 = false
    }
end

local function clone_block(bytes)
    local out = {}
    for i = 1, #bytes do out[i] = bytes[i] end
    return out
end

---Create a new cache controller.
---@param backend IBackend
---@param config table|nil
---@return CacheController
function CacheController:new(backend, config)
    local self_ = {
        backend = backend,
        levels = {},
        next_level = { l1d = "l2", l1i = "l2", l2 = "l3", l3 = nil },
        policy = { inclusion = "inclusive", write_allocate = true, write_back = true },
        global_counter = 0,
        statistics = {
            hits = { l1d = 0, l1i = 0, l2 = 0, l3 = 0 },
            misses = { l1d = 0, l1i = 0, l2 = 0, l3 = 0 },
            evictions = { l1d = 0, l1i = 0, l2 = 0, l3 = 0 },
            writebacks = { l1d = 0, l1i = 0, l2 = 0, l3 = 0 },
            fills = { l1d = 0, l1i = 0, l2 = 0, l3 = 0 },
            prefetches = { l1d = 0, l1i = 0, l2 = 0, l3 = 0 }
        }
    }

    local defaults = {
        l1d = { size = 32 * 1024, line_size = 64, associativity = 8 },
        l1i = { size = 32 * 1024, line_size = 64, associativity = 8 },
        l2  = { size = 256 * 1024, line_size = 64, associativity = 8 },
        l3  = { size = 8 * 1024 * 1024, line_size = 64, associativity = 16 },
    }
    local cfg = config or {}

    local function make_level(c)
        local cache = {
            size = c.size, line_size = c.line_size, associativity = c.associativity,
            num_sets = c.size / (c.line_size * c.associativity), sets = {}
        }
        for i = 0, cache.num_sets - 1 do
            cache.sets[i] = {}
            for j = 1, cache.associativity do
                cache.sets[i][j] = create_cache_line()
            end
        end
        return cache
    end

    self_.levels.l1d = make_level(cfg.l1d or defaults.l1d)
    self_.levels.l1i = make_level(cfg.l1i or defaults.l1i)
    self_.levels.l2  = make_level(cfg.l2  or defaults.l2)
    self_.levels.l3  = make_level(cfg.l3  or defaults.l3)

    return setmetatable(self_, CacheController)
end

-- Address helpers
function CacheController:get_set_index(address, cache)
    local block_number = math.floor(address / cache.line_size)
    return block_number % cache.num_sets
end
function CacheController:get_tag(address, cache)
    return math.floor(address / (cache.line_size * cache.num_sets))
end
function CacheController:block_address_for_level(level_name, address)
    local cache = self.levels[level_name]
    return address - (address % cache.line_size)
end
function CacheController:block_address_from_components(cache, tag, set_index)
    local block_number = tag * cache.num_sets + set_index
    return block_number * cache.line_size
end

-- Lookup
function CacheController:find_line(level_name, block_address)
    local cache = self.levels[level_name]
    local set_index = self:get_set_index(block_address, cache)
    local tag = self:get_tag(block_address, cache)
    local set = cache.sets[set_index]
    for way = 1, cache.associativity do
        local line = set[way]
        if line.valid and line.tag == tag then
            return cache, set_index, way, line
        end
    end
    return cache, set_index, nil, nil
end

-- Presence bookkeeping
function CacheController:set_l2_presence(block_address, which, present)
    local _, _, _, line = self:find_line("l2", block_address)
    if not line then return end
    if which == "l1d" then line.present_l1d = present
    elseif which == "l1i" then line.present_l1i = present end
end
function CacheController:set_l3_presence(block_address, present)
    local _, _, _, line = self:find_line("l3", block_address)
    if not line then return end
    line.present_l2 = present
end

-- Writeback
function CacheController:writeback_to_next(level_name, block_address, data)
    local next_name = self.next_level[level_name]
    if not next_name then
        self.backend:write_bytes(block_address, data)
        self.statistics.writebacks[level_name] = (self.statistics.writebacks[level_name] or 0) + 1
        return
    end
    local _, _, _, next_line = self:find_line(next_name, block_address)
    if next_line then
        next_line.data = clone_block(data)
        next_line.dirty = true
        self.global_counter = self.global_counter + 1
        next_line.lru_counter = self.global_counter
    else
        self:install_line(block_address, next_name, data, true)
    end
    self.statistics.writebacks[level_name] = (self.statistics.writebacks[level_name] or 0) + 1
    if level_name == "l1d" then
        self:set_l2_presence(block_address, "l1d", false)
    elseif level_name == "l1i" then
        self:set_l2_presence(block_address, "l1i", false)
    end
end

-- Inclusive child eviction
function CacheController:evict_child_l1(which, block_address, parent_l2_line)
    local lvl = (which == "l1d") and "l1d" or "l1i"
    local _, _, _, line = self:find_line(lvl, block_address)
    if line and line.valid then
        if line.dirty then
            parent_l2_line.data = clone_block(line.data)
            parent_l2_line.dirty = true
            self.statistics.writebacks[lvl] = (self.statistics.writebacks[lvl] or 0) + 1
        end
        line.valid = false
    end
    if which == "l1d" then parent_l2_line.present_l1d = false else parent_l2_line.present_l1i = false end
end
function CacheController:evict_child_l2(block_address)
    local _, _, _, l2_line = self:find_line("l2", block_address)
    if not l2_line or not l2_line.valid then return end
    if l2_line.present_l1d then self:evict_child_l1("l1d", block_address, l2_line) end
    if l2_line.present_l1i then self:evict_child_l1("l1i", block_address, l2_line) end
    if l2_line.dirty then
        self.backend:write_bytes(block_address, l2_line.data)
        self.statistics.writebacks.l2 = (self.statistics.writebacks.l2 or 0) + 1
    end
    l2_line.valid = false
end

-- Victim selection
function CacheController:choose_victim(level_name, cache, set)
    for i = 1, cache.associativity do
        if not set[i].valid then return i, set[i] end
    end
    local best_idx, best_lru
    if level_name == "l2" then
        for i = 1, cache.associativity do
            local line = set[i]
            if not line.present_l1d and not line.present_l1i then
                if not best_idx or line.lru_counter < best_lru then
                    best_idx, best_lru = i, line.lru_counter
                end
            end
        end
    elseif level_name == "l3" then
        for i = 1, cache.associativity do
            local line = set[i]
            if not line.present_l2 then
                if not best_idx or line.lru_counter < best_lru then
                    best_idx, best_lru = i, line.lru_counter
                end
            end
        end
    end
    if not best_idx then
        best_idx, best_lru = 1, set[1].lru_counter
        for i = 2, cache.associativity do
            if set[i].lru_counter < best_lru then
                best_idx, best_lru = i, set[i].lru_counter
            end
        end
    end
    return best_idx, set[best_idx]
end

function CacheController:handle_eviction(level_name, cache, set_index, victim)
    if not victim or not victim.valid then return end
    self.statistics.evictions[level_name] = (self.statistics.evictions[level_name] or 0) + 1
    local block_address = self:block_address_from_components(cache, victim.tag, set_index)

    if level_name == "l1d" or level_name == "l1i" then
        if victim.dirty then self:writeback_to_next(level_name, block_address, victim.data) end
        self:set_l2_presence(block_address, (level_name == "l1d") and "l1d" or "l1i", false)

    elseif level_name == "l2" then
        if victim.present_l1d then self:evict_child_l1("l1d", block_address, victim) end
        if victim.present_l1i then self:evict_child_l1("l1i", block_address, victim) end
        if victim.dirty then self:writeback_to_next("l2", block_address, victim.data) end
        self:set_l3_presence(block_address, false)

    elseif level_name == "l3" then
        if victim.present_l2 then
            self:evict_child_l2(block_address)
            victim.present_l2 = false
            victim.dirty = false
        else
            if victim.dirty then
                self.backend:write_bytes(block_address, victim.data)
                self.statistics.writebacks.l3 = (self.statistics.writebacks.l3 or 0) + 1
            end
        end
    end
end

-- Probe only
function CacheController:access(address, level_name, is_write)
    local cache = self.levels[level_name]
    local block_address = self:block_address_for_level(level_name, address)
    local set_index = self:get_set_index(block_address, cache)
    local tag = self:get_tag(block_address, cache)
    local set = cache.sets[set_index]
    for i = 1, cache.associativity do
        local line = set[i]
        if line.valid and line.tag == tag then
            self.statistics.hits[level_name] = (self.statistics.hits[level_name] or 0) + 1
            self.global_counter = self.global_counter + 1
            line.lru_counter = self.global_counter
            if is_write then line.dirty = true end
            return true, block_address, set_index, i, line
        end
    end
    self.statistics.misses[level_name] = (self.statistics.misses[level_name] or 0) + 1
    return false, block_address, set_index, nil, nil
end

-- Install line
function CacheController:install_line(block_address, level_name, data, is_write)
    local cache = self.levels[level_name]
    local set_index = self:get_set_index(block_address, cache)
    local tag = self:get_tag(block_address, cache)
    local set = cache.sets[set_index]

    local victim_idx, victim = self:choose_victim(level_name, cache, set)
    if victim and victim.valid then
        self:handle_eviction(level_name, cache, set_index, victim)
    end

    local line = set[victim_idx]
    line.valid = true
    line.dirty = is_write and true or false
    line.tag = tag
    self.global_counter = self.global_counter + 1
    line.lru_counter = self.global_counter
    line.data = clone_block(data)

    if level_name == "l1d" then
        self:set_l2_presence(block_address, "l1d", true)
    elseif level_name == "l1i" then
        self:set_l2_presence(block_address, "l1i", true)
    elseif level_name == "l2" then
        self:set_l3_presence(block_address, true)
    end

    self.statistics.fills[level_name] = (self.statistics.fills[level_name] or 0) + 1
    return line
end

-- Demand read
function CacheController:read(address, size, cache_type)
    cache_type = cache_type or "l1d"
    local hit, block_addr, _, _, line = self:access(address, cache_type, false)
    if hit then return line.data end

    hit, block_addr, _, _, line = self:access(address, "l2", false)
    if hit then
        self:install_line(block_addr, cache_type, line.data, false)
        return line.data
    end

    hit, block_addr, _, _, line = self:access(address, "l3", false)
    if hit then
        self:install_line(block_addr, "l2", line.data, false)
        self:install_line(block_addr, cache_type, line.data, false)
        return line.data
    end

    local line_size = self.levels.l3.line_size
    local mem_data = self.backend:read_bytes(block_addr, line_size)
    self:install_line(block_addr, "l3", mem_data, false)
    self:install_line(block_addr, "l2", mem_data, false)
    self:install_line(block_addr, cache_type, mem_data, false)
    return mem_data
end

-- No-stats prefetch into a target level (typically L2).
function CacheController:prefetch_line(level_name, block_address)
    local _, _, _, line = self:find_line(level_name, block_address)
    if line and line.valid then return end
    local cache = self.levels[level_name]
    local line_size = cache.line_size
    local bytes = self.backend:read_bytes(block_address, line_size)
    self:install_line(block_address, level_name, bytes, false)
    self.statistics.prefetches[level_name] = (self.statistics.prefetches[level_name] or 0) + 1
end

-- Write bytes through cache (handles line splits)
function CacheController:write_bytes(address, bytes, cache_type)
    cache_type = cache_type or "l1d"
    local idx, remaining, addr = 1, #bytes, address
    local line_size = self.levels[cache_type].line_size
    while remaining > 0 do
        local block_addr = self:block_address_for_level(cache_type, addr)
        local offset = addr - block_addr
        local chunk = math.min(remaining, line_size - offset)
        local line = self:read(addr, 0, cache_type)
        local _, _, _, l = self:find_line(cache_type, block_addr)
        if l then
            for i = 0, chunk - 1 do
                l.data[offset + 1 + i] = bytes[idx + i]
            end
            l.dirty = true
        end
        idx = idx + chunk
        remaining = remaining - chunk
        addr = addr + chunk
    end
end

-- Flushes and stats
function CacheController:flush_line(address, level_name)
    local cache = self.levels[level_name]
    if not cache then return false end
    local block_addr = self:block_address_for_level(level_name, address)
    local set_index = self:get_set_index(block_addr, cache)
    local tag = self:get_tag(block_addr, cache)
    local set = cache.sets[set_index]
    for i = 1, cache.associativity do
        local line = set[i]
        if line.valid and line.tag == tag then
            self:handle_eviction(level_name, cache, set_index, line)
            line.valid = false
            return true
        end
    end
    return false
end

function CacheController:flush_all(level_name)
    local cache = self.levels[level_name]
    for set_idx = 0, cache.num_sets - 1 do
        local set = cache.sets[set_idx]
        for way = 1, cache.associativity do
            local line = set[way]
            if line.valid then self:handle_eviction(level_name, cache, set_idx, line) end
            cache.sets[set_idx][way] = create_cache_line()
        end
    end
end

function CacheController:get_statistics()
    local stats = { levels = {} }
    for name, cache in pairs(self.levels) do
        local hits = self.statistics.hits[name] or 0
        local misses = self.statistics.misses[name] or 0
        local total = hits + misses
        stats.levels[name] = {
            size = cache.size, line_size = cache.line_size,
            associativity = cache.associativity, num_sets = cache.num_sets,
            hits = hits, misses = misses, hit_rate = total > 0 and hits / total or 0,
            evictions = self.statistics.evictions[name] or 0,
            writebacks = self.statistics.writebacks[name] or 0,
            fills = self.statistics.fills[name] or 0,
            prefetches = self.statistics.prefetches[name] or 0
        }
    end
    return stats
end

return CacheController