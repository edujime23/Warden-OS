-- memory/core/cache_controller.lua
-- Multi-level cache simulation with set-associative mapping (inclusive, write-back)

local Constants = require("memory.utils.constants")

local CacheController = {}
CacheController.__index = CacheController

-- Cache line structure
local function create_cache_line()
    return {
        valid = false,
        dirty = false,
        tag = 0,
        data = {},
        lru_counter = 0,

        -- Inclusion tracking:
        -- Only meaningful on:
        --   L2 lines: present_l1d / present_l1i tell if child L1s hold this line
        --   L3 lines: present_l2 tells if child L2 holds this line
        present_l1d = false,
        present_l1i = false,
        present_l2  = false
    }
end

local function clone_block(bytes)
    local copy = {}
    for i = 1, #bytes do
        copy[i] = bytes[i]
    end
    return copy
end

-- Initialize cache controller
function CacheController:new(memory_pool, opts)
    opts = opts or {}
    local controller = {
        pool = memory_pool,
        levels = {},
        global_counter = 0,  -- For LRU tracking
        policy = {
            inclusion = opts.inclusion or "inclusive",   -- currently supports "inclusive"
            write_allocate = (opts.write_allocate ~= false), -- default true
            write_back = (opts.write_back ~= false)      -- default true
        },
        statistics = {
            hits = {l1d = 0, l1i = 0, l2 = 0, l3 = 0},
            misses = {l1d = 0, l1i = 0, l2 = 0, l3 = 0},
            evictions = {l1d = 0, l1i = 0, l2 = 0, l3 = 0},
            writebacks = {l1d = 0, l1i = 0, l2 = 0, l3 = 0}
        }
    }

    -- Initialize cache levels
    controller.levels.l1d = self:create_cache_level(Constants.CACHE_CONFIG.L1_DATA)
    controller.levels.l1i = self:create_cache_level(Constants.CACHE_CONFIG.L1_INST)
    controller.levels.l2  = self:create_cache_level(Constants.CACHE_CONFIG.L2)
    controller.levels.l3  = self:create_cache_level(Constants.CACHE_CONFIG.L3)

    -- Next-level mapping (inclusive hierarchy)
    controller.next_level = { l1d = "l2", l1i = "l2", l2 = "l3", l3 = nil }

    setmetatable(controller, CacheController)
    return controller
end

-- Create a cache level
function CacheController:create_cache_level(config)
    local cache = {
        size = config.size,
        line_size = config.line_size,
        associativity = config.associativity,
        num_sets = config.size / (config.line_size * config.associativity),
        sets = {}
    }

    -- Initialize sets
    for i = 0, cache.num_sets - 1 do
        cache.sets[i] = {}
        for j = 1, cache.associativity do
            cache.sets[i][j] = create_cache_line()
        end
    end

    return cache
end

-- Helpers: indexing and addressing
function CacheController:get_set_index(address, cache)
    local block_number = math.floor(address / cache.line_size)
    return block_number % cache.num_sets
end

function CacheController:get_tag(address, cache)
    return math.floor(address / (cache.line_size * cache.num_sets))
end

function CacheController:get_offset(address, cache)
    return address % cache.line_size
end

function CacheController:block_address_from_components(cache, tag, set_index)
    local block_number = tag * cache.num_sets + set_index
    return block_number * cache.line_size
end

function CacheController:block_address_for_level(level_name, address)
    local cache = self.levels[level_name]
    return address - (address % cache.line_size)
end

-- Find line in level by block address
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

-- Presence flag helpers (inclusive)
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

-- Writeback helpers
function CacheController:writeback_to_next(level_name, block_address, data)
    local next_name = self.next_level[level_name]
    if not next_name then
        -- Write back to memory
        self.pool:write_bytes(block_address, data)
        self.statistics.writebacks[level_name] = (self.statistics.writebacks[level_name] or 0) + 1
        return
    end

    -- Write into next cache (update if exists, else install)
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

    -- Maintain inclusion flags only for L1 -> L2 eviction (child is gone).
    if level_name == "l1d" then
        self:set_l2_presence(block_address, "l1d", false)
    elseif level_name == "l1i" then
        self:set_l2_presence(block_address, "l1i", false)
    end
end

-- Invalidate child L1 line if present; if dirty, push into parent L2 line first
function CacheController:evict_child_l1(which, block_address, parent_l2_line)
    local level_name = (which == "l1d") and "l1d" or "l1i"
    local _, _, _, line = self:find_line(level_name, block_address)
    if line and line.valid then
        if line.dirty then
            -- Merge dirty child data up into parent L2
            parent_l2_line.data = clone_block(line.data)
            parent_l2_line.dirty = true
            self.statistics.writebacks[level_name] = (self.statistics.writebacks[level_name] or 0) + 1
        end
        line.valid = false
    end
    if which == "l1d" then parent_l2_line.present_l1d = false else parent_l2_line.present_l1i = false end
end

-- Invalidate child L2 line if present; drains its L1s and writes to memory if dirty
function CacheController:evict_child_l2(block_address)
    local _, _, _, l2_line = self:find_line("l2", block_address)
    if not l2_line or not l2_line.valid then return end

    -- Drain L1 children (merge dirty into L2)
    if l2_line.present_l1d then self:evict_child_l1("l1d", block_address, l2_line) end
    if l2_line.present_l1i then self:evict_child_l1("l1i", block_address, l2_line) end

    -- Now write L2 to memory if dirty (since L3 victim is going away)
    if l2_line.dirty then
        self.pool:write_bytes(block_address, l2_line.data)
        self.statistics.writebacks.l2 = (self.statistics.writebacks.l2 or 0) + 1
    end

    -- Invalidate L2
    l2_line.valid = false
end

-- Victim selection: prefer invalid, else true LRU; avoid evicting lines with children if possible (inclusive)
function CacheController:choose_victim(level_name, cache, set)
    -- Prefer invalid line
    for i = 1, cache.associativity do
        if not set[i].valid then return i, set[i] end
    end

    -- Inclusive: prefer victims with no children
    local best_idx, best_lru = nil, nil
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

    -- If all candidates have children, fall back to LRU
    if not best_idx then
        best_idx = 1
        best_lru = set[1].lru_counter
        for i = 2, cache.associativity do
            if set[i].lru_counter < best_lru then
                best_idx, best_lru = i, set[i].lru_counter
            end
        end
    end

    return best_idx, set[best_idx]
end

-- Handle inclusion-aware eviction (propagate dirty, invalidate children)
function CacheController:handle_eviction(level_name, cache, set_index, victim)
    if not victim or not victim.valid then return end

    self.statistics.evictions[level_name] = (self.statistics.evictions[level_name] or 0) + 1
    local block_address = self:block_address_from_components(cache, victim.tag, set_index)

    if level_name == "l1d" or level_name == "l1i" then
        if victim.dirty then
            self:writeback_to_next(level_name, block_address, victim.data)
        end
        -- Clear presence in L2 for this block
        self:set_l2_presence(block_address, (level_name == "l1d") and "l1d" or "l1i", false)

    elseif level_name == "l2" then
        -- Invalidate/merge L1 children if present
        if victim.present_l1d then self:evict_child_l1("l1d", block_address, victim) end
        if victim.present_l1i then self:evict_child_l1("l1i", block_address, victim) end

        -- Write back to L3 (or install) if dirty
        if victim.dirty then
            self:writeback_to_next("l2", block_address, victim.data)
        end

        -- Clear presence in L3 for this block
        self:set_l3_presence(block_address, false)

    elseif level_name == "l3" then
        -- Track if we drained a child L2
        local had_child = victim.present_l2
        if had_child then
            -- Drain L2 (and its L1s). L2 will write to memory if dirty.
            self:evict_child_l2(block_address)
            victim.present_l2 = false
            -- After draining, don't write L3 again to memory (would risk stale overwrite).
            victim.dirty = false
        else
            -- No child: write L3 to memory if dirty.
            if victim.dirty then
                self.pool:write_bytes(block_address, victim.data)
                self.statistics.writebacks.l3 = (self.statistics.writebacks.l3 or 0) + 1
            end
        end
    end
end

-- Probe a single level: update LRU on hit, do NOT allocate/fetch on miss.
-- Returns: hit, block_address, set_index, way_or_nil, line_or_nil
function CacheController:access(address, level_name, is_write)
    local cache = self.levels[level_name]
    if not cache then error("Invalid cache level: " .. tostring(level_name)) end

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

-- Install a given block into a level (evict if necessary) and deep copy data.
function CacheController:install_line(block_address, level_name, data, is_write)
    local cache = self.levels[level_name]
    if not cache then return end

    local set_index = self:get_set_index(block_address, cache)
    local tag = self:get_tag(block_address, cache)
    local set = cache.sets[set_index]

    -- Choose victim using inclusive-aware policy.
    local victim_idx, victim = self:choose_victim(level_name, cache, set)

    -- Evict if needed with full bookkeeping (children/writebacks).
    if victim and victim.valid then
        self:handle_eviction(level_name, cache, set_index, victim)
    end

    -- Install new line.
    local line = set[victim_idx]
    line.valid = true
    line.dirty = is_write and true or false
    line.tag = tag
    self.global_counter = self.global_counter + 1
    line.lru_counter = self.global_counter
    line.data = clone_block(data)

    -- Maintain inclusion presence flags on fill.
    if level_name == "l1d" then
        self:set_l2_presence(block_address, "l1d", true)
    elseif level_name == "l1i" then
        self:set_l2_presence(block_address, "l1i", true)
    elseif level_name == "l2" then
        self:set_l3_presence(block_address, true)
    end

    return line
end

-- Read through hierarchy with inclusive fills. Returns the cache line bytes.
function CacheController:read(address, size, cache_type)
    cache_type = cache_type or "l1d"

    -- Try L1
    local hit, block_addr, _, _, line = self:access(address, cache_type, false)
    if hit then return line.data end

    -- Try L2
    hit, block_addr, _, _, line = self:access(address, "l2", false)
    if hit then
        -- Fill back into L1 (inclusive)
        self:install_line(block_addr, cache_type, line.data, false)
        return line.data
    end

    -- Try L3
    hit, block_addr, _, _, line = self:access(address, "l3", false)
    if hit then
        -- Fill back: L3 -> L2 -> L1
        self:install_line(block_addr, "l2", line.data, false)
        self:install_line(block_addr, cache_type, line.data, false)
        return line.data
    end

    -- Miss at all levels: fetch once from memory and install down the hierarchy.
    local line_size = self.levels.l3.line_size
    local mem_data = self.pool:read_bytes(block_addr, line_size)
    self:install_line(block_addr, "l3", mem_data, false)
    self:install_line(block_addr, "l2", mem_data, false)
    self:install_line(block_addr, cache_type, mem_data, false)
    return mem_data
end

-- Write with write-allocate: fetch line into L1, mark dirty; inclusion ensured by fills
function CacheController:write(address, size, cache_type)
    cache_type = cache_type or "l1d"

    local hit = self:access(address, cache_type, true)
    if hit then return end

    if not self.policy.write_allocate then
        -- No-allocate: write directly to memory (simulate store). Intentionally a no-op on bytes here.
        return
    end

    -- Ensure line is in L1 (and inclusive lower levels) then mark dirty.
    local _ = self:read(address, size, cache_type)
    local _, _, _, l1_line = self:find_line(cache_type, self:block_address_for_level(cache_type, address))
    if l1_line then l1_line.dirty = true end
end

-- Flush cache line (write back if dirty, then invalidate), inclusion-aware
function CacheController:flush_line(address, level_name)
    local cache = self.levels[level_name]
    if not cache then return false end

    local block_address = self:block_address_for_level(level_name, address)
    local set_index = self:get_set_index(block_address, cache)
    local tag = self:get_tag(block_address, cache)
    local set = cache.sets[set_index]

    for i = 1, cache.associativity do
        local line = set[i]
        if line.valid and line.tag == tag then
            -- Use eviction path to keep hierarchy consistent
            self:handle_eviction(level_name, cache, set_index, line)
            line.valid = false
            return true
        end
    end
    return false
end

-- Flush entire cache level (inclusive-aware)
function CacheController:flush_all(level_name)
    local cache = self.levels[level_name]
    if not cache then return end

    for set_idx = 0, cache.num_sets - 1 do
        local set = cache.sets[set_idx]
        for way = 1, cache.associativity do
            local line = set[way]
            if line.valid then
                self:handle_eviction(level_name, cache, set_idx, line)
            end
            cache.sets[set_idx][way] = create_cache_line()
        end
    end
end

-- Prefetch data into cache (bring line into hierarchy)
function CacheController:prefetch(address, level_name)
    level_name = level_name or "l1d"
    self:read(address, 0, level_name)
end

-- Get cache statistics
function CacheController:get_statistics()
    local stats = { levels = {} }
    for name, cache in pairs(self.levels) do
        local hits = self.statistics.hits[name] or 0
        local misses = self.statistics.misses[name] or 0
        local total = hits + misses
        stats.levels[name] = {
            size = cache.size,
            line_size = cache.line_size,
            associativity = cache.associativity,
            num_sets = cache.num_sets,
            hits = hits,
            misses = misses,
            hit_rate = total > 0 and hits / total or 0,
            evictions = self.statistics.evictions[name] or 0,
            writebacks = self.statistics.writebacks[name] or 0
        }
    end
    return stats
end

return CacheController