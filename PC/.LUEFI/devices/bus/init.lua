-- devices/bus/init.lua
-- Bus device entry point. Exports the Bus class.

local Bus = require("devices.bus.bus")

return {
    Bus = Bus
}