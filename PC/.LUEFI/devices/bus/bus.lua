-- devices/bus/bus.lua
-- System bus: routes physical addresses to RAM and MMIO devices.
-- Implements the CPU backend interface (read_bytes/write_bytes).

---@class BusRegion
---@field kind "ram"|"mmio"
---@field base integer
---@field size integer
---@field end_addr integer
---@field name string
---@field backend any        -- for RAM: DRAM (IBackend)
---@field mem_offset integer -- for RAM: backend offset (default 0)
---@field device any         -- for MMIO: device with :read(offset,count) and :write(offset,bytes)

---@class Bus
---@field regions BusRegion[]
---@field stats table
local Bus = {}
Bus.__index = Bus

local bit32 = bit32

---Create a new bus.
---@return Bus
function Bus:new()
    local self_ = {
        regions = {},
        stats = {
            reads = 0, read_bytes = 0,
            writes = 0, write_bytes = 0,
            faults = 0
        }
    }
    return setmetatable(self_, Bus)
end

-- ===== Region management =====

local function overlaps(a_base, a_end, b_base, b_end)
    return not (a_end < b_base or b_end < a_base)
end

---Insert a region (internal) ensuring no overlap.
---@param r BusRegion
function Bus:_insert_region(r)
    -- overlap check
    for _, ex in ipairs(self.regions) do
        if overlaps(r.base, r.end_addr, ex.base, ex.end_addr) then
            error(string.format("Bus region overlap: '%s' [0x%X..0x%X] with '%s' [0x%X..0x%X]",
                r.name, r.base, r.end_addr, ex.name, ex.base, ex.end_addr))
        end
    end
    table.insert(self.regions, r)
    table.sort(self.regions, function(a,b) return a.base < b.base end)
end

---Map a DRAM region.
---@param name string
---@param base integer
---@param size integer
---@param dram any        -- IBackend (read_bytes/write_bytes)
---@param mem_offset integer|nil
function Bus:map_ram(name, base, size, dram, mem_offset)
    assert(dram and dram.read_bytes and dram.write_bytes, "Bus: map_ram requires a backend with read_bytes/write_bytes")
    assert(size > 0, "Bus: map_ram size must be > 0")
    local r = {
        kind = "ram",
        name = name or "ram",
        base = base,
        size = size,
        end_addr = base + size - 1,
        backend = dram,
        mem_offset = mem_offset or 0
    }
    self:_insert_region(r)
end

---Register an MMIO device.
-- Device must provide device:get_region() -> base, size and device:read(offset,count), device:write(offset,bytes)
---@param name string
---@param device any
function Bus:register_mmio(name, device)
    assert(device and device.get_region and device.read and device.write, "Bus: MMIO device must define get_region/read/write")
    local base, size = device:get_region()
    assert(type(base) == "number" and type(size) == "number" and size > 0, "Bus: invalid device region")
    local r = {
        kind = "mmio",
        name = name or "mmio",
        base = base,
        size = size,
        end_addr = base + size - 1,
        device = device
    }
    self:_insert_region(r)
end

---Find region by physical address. Returns region and local offset.
---@param pa integer
---@return BusRegion|nil, integer|nil
function Bus:_find_region(pa)
    for _, r in ipairs(self.regions) do
        if pa >= r.base and pa <= r.end_addr then
            return r, pa - r.base
        end
    end
    return nil, nil
end

-- ===== CPU backend interface =====

---Read bytes starting at physical address, splitting across regions if needed.
---@param phys_addr integer
---@param count integer
---@return integer[] bytes
function Bus:read_bytes(phys_addr, count)
    if count < 0 then count = 0 end
    local out, idx = {}, 1
    local addr, remain = phys_addr, count

    while remain > 0 do
        local r, off = self:_find_region(addr)
        if not r then
            self.stats.faults = self.stats.faults + 1
            error(string.format("Bus: unmapped read at 0x%X (len=%d)", addr, remain))
        end

        local avail = (r.end_addr - addr + 1)
        local chunk = (remain < avail) and remain or avail

        if r.kind == "ram" then
            local baddr = r.mem_offset + off
            local bytes = r.backend:read_bytes(baddr, chunk)
            for i = 1, #bytes do out[idx] = bytes[i]; idx = idx + 1 end
        else
            local bytes = r.device:read(off, chunk)
            for i = 1, #bytes do out[idx] = bit32.band(bytes[i], 0xFF); idx = idx + 1 end
        end

        addr   = addr + chunk
        remain = remain - chunk
    end

    self.stats.reads = self.stats.reads + 1
    self.stats.read_bytes = self.stats.read_bytes + count
    return out
end

---Write bytes starting at physical address, splitting across regions if needed.
---@param phys_addr integer
---@param bytes integer[]
function Bus:write_bytes(phys_addr, bytes)
    local addr, idx, remain = phys_addr, 1, #bytes

    while remain > 0 do
        local r, off = self:_find_region(addr)
        if not r then
            self.stats.faults = self.stats.faults + 1
            error(string.format("Bus: unmapped write at 0x%X (len=%d)", addr, remain))
        end

        local avail = (r.end_addr - addr + 1)
        local chunk = (remain < avail) and remain or avail

        if r.kind == "ram" then
            local baddr = r.mem_offset + off
            local slice = {}
            for i = 0, chunk - 1 do slice[i + 1] = bytes[idx + i] end
            r.backend:write_bytes(baddr, slice)
        else
            local slice = {}
            for i = 0, chunk - 1 do slice[i + 1] = bytes[idx + i] end
            r.device:write(off, slice)
        end

        addr   = addr + chunk
        idx    = idx + chunk
        remain = remain - chunk
    end

    self.stats.writes = self.stats.writes + 1
    self.stats.write_bytes = self.stats.write_bytes + #bytes
end

-- ===== Introspection =====

---List regions.
---@return table[]
function Bus:list_regions()
    local t = {}
    for _, r in ipairs(self.regions) do
        table.insert(t, {
            name = r.name, kind = r.kind,
            base = r.base, size = r.size, ["end"] = r.end_addr
        })
    end
    return t
end

---Get stats.
---@return table
function Bus:get_statistics()
    return {
        reads = self.stats.reads, read_bytes = self.stats.read_bytes,
        writes = self.stats.writes, write_bytes = self.stats.write_bytes,
        faults = self.stats.faults,
        regions = self:list_regions()
    }
end

return Bus