-- firmware/runtimeservices/variables.lua
-- UEFI Runtime Services: Variables (stubbed, with optional persistence).
-- Provides a small variable store keyed by (VendorGuid, Name).
-- Attributes: NV, BS (boot service access), RT (runtime access), READ_ONLY, APPEND_WRITE.

local bit32 = bit32

---@class Variables
---@field cpu any
---@field store table<string, {name:string,guid:string,attr:integer,data:integer[]}>
---@field persist_path string|nil
local Variables = {}
Variables.__index = Variables

-- Attribute flags (subset)
local Attr = {
    NV       = 0x00000001, -- non-volatile (persist to file if persist_path set)
    BS       = 0x00000002, -- boot service access
    RT       = 0x00000004, -- runtime access
    READ_ONLY= 0x00000008, -- read-only (cannot change once set)
    APPEND   = 0x00000040  -- append write (not implemented: treated as replace)
}
Variables.Attr = Attr

local function to_bytes(s_or_bytes)
    if type(s_or_bytes) == "table" then
        local out = {}
        for i = 1, #s_or_bytes do out[i] = bit32.band(s_or_bytes[i] or 0, 0xFF) end
        return out
    elseif type(s_or_bytes) == "string" then
        local out = {}
        for i = 1, #s_or_bytes do out[i] = string.byte(s_or_bytes, i) end
        return out
    else
        return {}
    end
end

local function hex_of_bytes(bytes)
    local t = {}
    for i = 1, #bytes do t[i] = string.format("%02X", bytes[i]) end
    return table.concat(t)
end

local function bytes_of_hex(s)
    local out = {}
    for bb in s:gmatch("%x%x") do
        out[#out + 1] = tonumber(bb, 16) or 0
    end
    return out
end

local function key_of(guid, name)
    return string.format("%s|%s", tostring(guid or ""), tostring(name or ""))
end

---Create store
---@param cpu any
---@param opts { persist_path?: string }|nil
function Variables:new(cpu, opts)
    opts = opts or {}
    local self_ = {
        cpu = cpu,
        store = {},
        persist_path = opts.persist_path
    }
    setmetatable(self_, Variables)
    if self_.persist_path then self_:load() end
    return self_
end

-- Persistence format: one var per line: hex(attr) \t guid \t name \t hex(data)
function Variables:save()
    if not self.persist_path then return end
    local dir = fs.getDir(self.persist_path)
    if dir and dir ~= "" and not fs.exists(dir) then fs.makeDir(dir) end
    local fh = fs.open(self.persist_path, "w")
    if not fh then return end
    for _, v in pairs(self.store) do
        local line = string.format("%08X\t%s\t%s\t%s\n", v.attr or 0, v.guid or "", v.name or "", hex_of_bytes(v.data or {}))
        fh.write(line)
    end
    fh.close()
end

function Variables:load()
    if not self.persist_path or not fs.exists(self.persist_path) then return end
    local fh = fs.open(self.persist_path, "r")
    if not fh then return end
    self.store = {}
    while true do
        local line = fh.readLine()
        if not line then break end
        local attr_hex, guid, name, data_hex = line:match("^(%x+)%s*\t(.-)%s*\t(.-)%s*\t(%x*)$")
        if attr_hex and name then
            local attr = tonumber(attr_hex, 16) or 0
            local data = bytes_of_hex(data_hex or "")
            local k = key_of(guid, name)
            self.store[k] = { name = name, guid = guid or "", attr = attr, data = data }
        end
    end
    fh.close()
end

---Set variable
---@param name string
---@param data string|integer[]
---@param attr integer|nil
---@param guid string|nil
function Variables:set(name, data, attr, guid)
    local k = key_of(guid, name)
    local cur = self.store[k]
    if cur and bit32.band(cur.attr or 0, Attr.READ_ONLY) ~= 0 then
        error(string.format("Variable '%s' is READ_ONLY", name))
    end
    self.store[k] = {
        name = name, guid = guid or "", attr = attr or 0, data = to_bytes(data)
    }
    if self.persist_path and bit32.band(attr or 0, Attr.NV) ~= 0 then
        self:save()
    end
end

---Get variable
---@param name string
---@param guid string|nil
---@return integer[] data, integer attr
function Variables:get(name, guid)
    local k = key_of(guid, name)
    local v = self.store[k]
    if not v then return nil, nil end
    -- return a shallow copy of data
    local bytes = {}
    for i = 1, #v.data do bytes[i] = v.data[i] end
    return bytes, v.attr
end

---Delete variable
function Variables:delete(name, guid)
    local k = key_of(guid, name)
    local v = self.store[k]
    if not v then return false end
    if bit32.band(v.attr or 0, Attr.READ_ONLY) ~= 0 then
        error(string.format("Variable '%s' is READ_ONLY", name))
    end
    self.store[k] = nil
    if self.persist_path then self:save() end
    return true
end

---List variables
---@return table[] list of { name, guid, attr, size }
function Variables:list()
    local out = {}
    for _, v in pairs(self.store) do
        out[#out + 1] = { name = v.name, guid = v.guid, attr = v.attr, size = #v.data }
    end
    table.sort(out, function(a,b)
        if a.guid == b.guid then return a.name < b.name end
        return a.guid < b.guid
    end)
    return out
end

-- Write a compact variable index to a VA buffer:
-- For each var: [U32 name_len][U32 data_len][U32 attr][U32 guid_len][name bytes][guid bytes][data bytes]
-- Returns total_bytes, count
function Variables:write_index_to_mem(base_va)
    local abi = require("firmware.abi").Types:new(self.cpu)
    local function U32(va) return abi:view("uint32", va) end
    local function put_bytes(va, bytes)
        for i = 1, #bytes do self.cpu:store(va + (i - 1), 1, bytes[i], false) end
    end

    local list = self:list()
    local off = base_va
    for _, v in ipairs(list) do
        local name_b = to_bytes(v.name or "")
        local guid_b = to_bytes(v.guid or "")
        local data_b = v.data and to_bytes(v.data) or (self.store[key_of(v.guid, v.name)] and self.store[key_of(v.guid, v.name)].data or {})
        U32(off + 0):set(#name_b)
        U32(off + 4):set(#data_b)
        U32(off + 8):set(v.attr or 0)
        U32(off + 12):set(#guid_b)
        off = off + 16
        put_bytes(off, name_b); off = off + #name_b
        put_bytes(off, guid_b); off = off + #guid_b
        put_bytes(off, data_b); off = off + #data_b
    end
    return off - base_va, #list
end

return Variables