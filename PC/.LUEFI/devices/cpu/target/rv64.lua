-- devices/cpu/target/rv64.lua
-- RISC-V 64-bit target: XLEN=64, little-endian.

local Target = {
    isa = "rv64",
    xlen = 64,
    endianness = "little",
}

function Target:pointer_size() return math.floor(self.xlen / 8) end

local function fmt(endian, signed, size)
    local e = (endian == "little") and "<" or ">"
    local t = (signed and "i" or "I") .. tostring(size)
    return e .. t
end

function Target:pack_int(value, size, signed)
    local s = string.pack(fmt(self.endianness, signed, size), value)
    return { s:byte(1, #s) }
end

function Target:unpack_int(bytes, signed)
    local s = string.char(table.unpack(bytes))
    return string.unpack(fmt(self.endianness, signed, #bytes), s)
end

return Target