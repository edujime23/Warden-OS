-- devices/cpu/init.lua
-- CPU device entry point. Exports the CPU API and a generic CPU.

local API = require("devices.cpu.api")
local CPU = require("devices.cpu.cpu")
local Target = require("devices.cpu.target")

return {
    API = API,       -- Base class and type annotations for CPU implementers
    CPU = CPU,       -- Generic CPU built on the API (no ISA pipeline)
    Target = Target  -- Target selector (rv32/rv64)
}