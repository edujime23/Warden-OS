-- firmware/bootservices/init.lua
-- Boot Services entry point.

local Memory = require("firmware.bootservices.memory")

return {
    Memory = Memory
}