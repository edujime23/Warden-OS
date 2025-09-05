-- devices/cpu/cpu.lua
-- Generic CPU built on CPUBase. Provides memory ops and MMU/caches, but no pipeline.

local CPUBase = require("devices.cpu.api")

---@class GenericCPU: CPUBase
local CPU = setmetatable({}, { __index = CPUBase })
CPU.__index = CPU

---@param opts table
---@return GenericCPU
function CPU:new(opts)
    return setmetatable(CPUBase:new(opts), CPU)
end

-- Example no-op step. Real CPUs should override and run fetch/decode/execute.
function CPU:step()
    -- No pipeline here. Override in your CPU to execute instructions.
    return false
end

return CPU