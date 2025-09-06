-- devices/bus/bus.lua
-- System bus: routes physical addresses to RAM and MMIO devices.
-- Implements the CPU backend interface (read_bytes/write_bytes).

---@class BusRegion
---@field kind "ram"|"mmio"
---@field base integer
---@field size integer
---@field end_addr integer
---@field name string
---@field backend any
---@field mem_offset integer
---@field device any
---@field caps { align?: integer, widths?: integer[] }|nil

---@class Bus
---@field regions BusRegion[]
---@field stats table
---@field strict_mmio boolean
local Bus = {}
Bus.__index = Bus

function Bus:new(opts)
    opts = opts or {}
    local self_ = {
        regions = {},
        stats = { reads = 0, read_bytes = 0, writes = 0, write_bytes = 0, faults = 0 },
        strict_mmio = (opts.strict_mmio ~= false)
    }
    return setmetatable(self_, Bus)
end

local function overlaps(a_base, a_end, b_base, b_end)
    return not (a_end < b_base or b_end < a_base)
end

function Bus:_insert_region(r)
    for _, ex in ipairs(self.regions) do
        if overlaps(r.base, r.end_addr, ex.base, ex.end_addr) then
            error(string.format("Bus region overlap: '%s' [0x%X..0x%X] with '%s' [0x%X..0x%X]",
                r.name, r.base, r.end_addr, ex.name, ex.base, ex.end_addr))
        end
    end
    table.insert(self.regions, r)
    table.sort(self.regions, function(a,b) return a.base < b.base end)
end

function Bus:map_ram(name, base, size, dram, mem_offset)
    assert(dram and dram.read_bytes and dram.write_bytes, "Bus: map_ram requires a backend")
    assert(size > 0, "Bus: map_ram size must be > 0")
    self:_insert_region({
        kind = "ram", name = name or "ram", base = base, size = size, end_addr = base + size - 1,
        backend = dram, mem_offset = mem_offset or 0
    })
end

local function mmio_caps_of(device)
    if device and device.get_mmio_caps then
        local ok, caps = pcall(device.get_mmio_caps, device)
        if ok and type(caps) == "table" then
            return {
                align = (type(caps.align) == "number" and caps.align >= 1) and caps.align or 1,
                widths = (type(caps.widths) == "table") and caps.widths or nil
            }
        end
    end
    return { align = 1, widths = nil }
end

function Bus:register_mmio(name, device)
    assert(device and device.get_region and device.read and device.write, "Bus: MMIO device must define get_region/read/write")
    local base, size = device:get_region()
    assert(type(base) == "number" and type(size) == "number" and size > 0, "Bus: invalid device region")
    self:_insert_region({
        kind = "mmio", name = name or "mmio", base = base, size = size, end_addr = base + size - 1,
        device = device, caps = mmio_caps_of(device)
    })
end

function Bus:_find_region(pa)
    -- This search can be optimized to binary search later if needed, as regions are sorted.
    for _, r in ipairs(self.regions) do
        if pa >= r.base and pa <= r.end_addr then
            return r, pa - r.base
        end
    end
    return nil, nil
end

local function widths_to_str(t)
    if not t then return "any" end; local b={}; for i=1,#t do b[i]=tostring(t[i]) end; return table.concat(b,",")
end

local function enforce_mmio(self, r, off, count)
    if not self.strict_mmio then return end
    local caps = r.caps or { align = 1, widths = nil }
    local align = caps.align or 1
    if align > 1 and (off % align) ~= 0 then
        error(string.format("Bus/MMIO '%s': unaligned access off=0x%X align=%d", r.name, off, align))
    end
    if caps.widths then
        local ok = false
        for i=1,#caps.widths do if caps.widths[i] == count then ok = true; break end end
        if not ok then
            error(string.format("Bus/MMIO '%s': unsupported access size len=%d (allowed: %s) off=0x%X",
                r.name, count, widths_to_str(caps.widths), off))
        end
    end
end

function Bus:read_bytes(phys_addr, count)
    if count <= 0 then return {} end
    local out, idx = {}, 1; local addr, remain = phys_addr, count
    while remain > 0 do
        local r, off = self:_find_region(addr)
        if not r then
            self.stats.faults = self.stats.faults + 1
            error(string.format("Bus: unmapped read at 0x%X (len=%d)", addr, remain))
        end
        local avail = r.end_addr - addr + 1
        local chunk = math.min(remain, avail)
        if r.kind == "ram" then
            local bytes = r.backend:read_bytes(r.mem_offset + off, chunk)
            if type(bytes) ~= "table" or #bytes ~= chunk then error("Bus: RAM backend returned wrong length") end
            for i = 1, chunk do out[idx] = bit32.band(bytes[i], 0xFF); idx = idx + 1 end
        else -- mmio
            enforce_mmio(self, r, off, chunk)
            local bytes = r.device:read(off, chunk)
            if type(bytes) ~= "table" or #bytes ~= chunk then
                if self.strict_mmio then error(string.format("Bus: device '%s' returned wrong length", r.name)) end
                local got = (type(bytes) == "table") and #bytes or 0
                for i = 1, chunk do out[idx] = bit32.band((got >= i and bytes[i] or 0), 0xFF); idx=idx+1 end
            else
                for i = 1, chunk do out[idx] = bit32.band(bytes[i], 0xFF); idx = idx + 1 end
            end
        end
        addr = addr + chunk; remain = remain - chunk
    end
    self.stats.reads = self.stats.reads + 1; self.stats.read_bytes = self.stats.read_bytes + count
    return out
end

function Bus:write_bytes(phys_addr, bytes)
    local addr, idx, remain = phys_addr, 1, #bytes
    while remain > 0 do
        local r, off = self:_find_region(addr)
        if not r then
            self.stats.faults = self.stats.faults + 1
            error(string.format("Bus: unmapped write at 0x%X (len=%d)", addr, remain))
        end
        local avail = r.end_addr - addr + 1
        local chunk = math.min(remain, avail)
        local slice = table.move(bytes, idx, idx + chunk - 1, 1, {})
        if r.kind == "ram" then
            r.backend:write_bytes(r.mem_offset + off, slice)
        else -- mmio
            enforce_mmio(self, r, off, chunk)
            r.device:write(off, slice)
        end
        addr = addr + chunk; idx = idx + chunk; remain = remain - chunk
    end
    self.stats.writes = self.stats.writes + 1; self.stats.write_bytes = self.stats.write_bytes + #bytes
end

function Bus:list_regions()
    local t = {}; for _, r in ipairs(self.regions) do table.insert(t, { name = r.name, kind = r.kind, base = r.base, size = r.size, ["end"] = r.end_addr }) end; return t
end

function Bus:get_statistics()
    return { reads = self.stats.reads, read_bytes = self.stats.read_bytes, writes = self.stats.writes,
        write_bytes = self.stats.write_bytes, faults = self.stats.faults, regions = self:list_regions() }
end

return Bus