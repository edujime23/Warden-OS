-- firmware/abi/types.lua
-- Target-aware basic types and TypeView using CPU load/store.

---@class ABITypes
---@field target table
local ABITypes = {}
ABITypes.__index = ABITypes

---Create ABI types for a given CPU target.
---@param cpu any -- CPUBase
---@return ABITypes
function ABITypes:new(cpu)
    local t = {
        target = cpu.target,
        cpu = cpu,
        defs = {}
    }
    setmetatable(t, ABITypes)

    local ps = cpu.target:pointer_size()

    -- Basic integer types
    t.defs["uint8"]  = { size = 1, signed = false }
    t.defs["uint16"] = { size = 2, signed = false }
    t.defs["uint32"] = { size = 4, signed = false }
    t.defs["uint64"] = { size = 8, signed = false }

    t.defs["int8"]   = { size = 1, signed = true }
    t.defs["int16"]  = { size = 2, signed = true }
    t.defs["int32"]  = { size = 4, signed = true }
    t.defs["int64"]  = { size = 8, signed = true }

    -- Pointer-sized types
    t.defs["uintptr"] = { size = ps, signed = false }
    t.defs["intptr"]  = { size = ps, signed = true  }
    t.defs["size_t"]  = { size = ps, signed = false }

    -- UEFI-ish aliases (illustrative)
    t.defs["EFI_UINTN"]       = t.defs["uintptr"]
    t.defs["EFI_INTN"]        = t.defs["intptr"]
    t.defs["EFI_STATUS"]      = t.defs["uintptr"]
    t.defs["EFI_PHYS_ADDR"]   = t.defs["uint64"]

    return t
end

---@class TypeView
---@field abi ABITypes
---@field name string
---@field def { size: integer, signed: boolean }
---@field addr integer   -- virtual address
local TypeView = {}
TypeView.__index = TypeView

---Get the value as a Lua number (accurate up to ~53 bits).
function TypeView:get()
    return self.abi.cpu:load(self.addr, self.def.size, self.def.signed)
end

---Set the value from a Lua number.
function TypeView:set(value)
    self.abi.cpu:store(self.addr, self.def.size, value, self.def.signed)
end

---Read raw bytes of the value from memory (VA) as 0..255.
---@return integer[]
function TypeView:get_bytes()
    local cpu = self.abi.cpu
    local n = self.def.size
    local bytes = {}
    for i = 0, n - 1 do
        bytes[i + 1] = cpu:load(self.addr + i, 1, false)
    end
    return bytes
end

---Return a canonical hex string (0x...) regardless of numeric precision.
---@return string
function TypeView:to_hex()
    local endian = self.abi.target.endianness
    local n = self.def.size
    local cpu = self.abi.cpu
    local parts = {}
    if endian == "little" then
        for i = n - 1, 0, -1 do
            local b = cpu:load(self.addr + i, 1, false)
            parts[#parts + 1] = string.format("%02X", b)
        end
    else
        for i = 0, n - 1 do
            local b = cpu:load(self.addr + i, 1, false)
            parts[#parts + 1] = string.format("%02X", b)
        end
    end
    return "0x" .. table.concat(parts)
end

---Create a TypeView for a type at VA.
---@param name string
---@param addr integer
function ABITypes:view(name, addr)
    local def = self.defs[name]
    assert(def, "Unknown ABI type: " .. tostring(name))
    return setmetatable({ abi = self, name = name, def = def, addr = addr }, TypeView)
end

return ABITypes