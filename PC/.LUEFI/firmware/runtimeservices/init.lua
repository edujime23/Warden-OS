-- firmware/runtimeservices/init.lua
-- Runtime Services entry point.

local Variables = require("firmware.runtimeservices.variables")
local Time      = require("firmware.runtimeservices.time")

return {
    Variables = Variables,
    Time      = Time
}