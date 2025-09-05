-- devices/uart/init.lua
-- UART device entry point. Exports the UART class.

local UART = require("devices.uart.uart")

return {
    UART = UART
}