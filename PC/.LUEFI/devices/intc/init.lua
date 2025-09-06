-- devices/intc/init.lua
-- Interrupt controller entry point. Exports simple INTc, PLIC-like controller, and CLINT.

local InterruptController = require("devices.intc.intc")
local PLIC                = require("devices.intc.plic")
local CLINT               = require("devices.intc.clint")

return {
    InterruptController = InterruptController,
    PLIC                = PLIC,
    CLINT               = CLINT
}