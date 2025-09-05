-- devices/cpu/target/init.lua
-- Target selector: choose an ISA target (rv32/rv64) or accept a custom module.

local function select(name)
    name = (name or "rv64"):lower()
    if name == "rv32" then
        return require("devices.cpu.target.rv32")
    else
        return require("devices.cpu.target.rv64")
    end
end

return { select = select }