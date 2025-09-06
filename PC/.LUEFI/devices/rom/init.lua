-- devices/rom/init.lua
-- ROM device entry point. Exports the ROM class.

local ROM = require("devices.rom.rom")

return {
    ROM = ROM
}