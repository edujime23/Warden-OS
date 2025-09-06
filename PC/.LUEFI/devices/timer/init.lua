-- devices/timer/init.lua
-- Timer device entry point. Exports the Timer class.

local Timer = require("devices.timer.timer")

return {
    Timer = Timer
}