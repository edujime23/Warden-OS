-- devices/memory/init.lua
-- Memory device entry point. Exports the DRAM class.

local DRAM = require("devices.memory.dram")

return {
    DRAM = DRAM
}