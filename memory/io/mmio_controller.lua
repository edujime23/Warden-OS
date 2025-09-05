-- mmio_controller.lua
-- Memory-mapped I/O controller for device simulation

local Constants = require("memory.utils.constants")

local MMIOController = {}
MMIOController.__index = MMIOController

-- Initialize MMIO controller
function MMIOController:new(memory_pool)
    local controller = {
        pool = memory_pool,
        devices = {},
        base = Constants.MEMORY_REGIONS.MMIO.base,
        size = Constants.MEMORY_REGIONS.MMIO.size,
        access_count = 0
    }

    setmetatable(controller, MMIOController)
    return controller
end

-- Register a memory-mapped device
function MMIOController:register_device(device_config)
    -- Validate device configuration
    if not device_config.name then
        error("Device must have a name")
    end

    if not device_config.base_address or not device_config.size then
        error("Device must specify base_address and size")
    end

    -- Check if address range is within MMIO region
    if device_config.base_address < self.base or
       device_config.base_address + device_config.size > self.base + self.size then
        error(string.format(
            "Device '%s' address range [0x%X-0x%X] outside MMIO region [0x%X-0x%X]",
            device_config.name,
            device_config.base_address,
            device_config.base_address + device_config.size - 1,
            self.base,
            self.base + self.size - 1
        ))
    end

    -- Check for overlapping devices
    for _, existing in pairs(self.devices) do
        local overlap = not (
            device_config.base_address >= existing.base_address + existing.size or
            existing.base_address >= device_config.base_address + device_config.size
        )

        if overlap then
            error(string.format(
                "Device '%s' overlaps with existing device '%s'",
                device_config.name, existing.name
            ))
        end
    end

    -- Create device entry
    local device = {
        name = device_config.name,
        base_address = device_config.base_address,
        size = device_config.size,
        registers = device_config.registers or {},
        read_handler = device_config.read_handler,
        write_handler = device_config.write_handler,
        data = {}  -- Internal device storage
    }

    -- Initialize device registers
    for reg_name, reg_config in pairs(device.registers) do
        device.data[reg_config.offset] = reg_config.default or 0
    end

    self.devices[device_config.name] = device
    return true
end

-- Find device for given address
function MMIOController:find_device(address)
    for _, device in pairs(self.devices) do
        if address >= device.base_address and
           address < device.base_address + device.size then
            return device, address - device.base_address
        end
    end
    return nil, nil
end

-- Read from MMIO address
function MMIOController:read(address, size)
    local device, offset = self:find_device(address)

    if not device then
        return nil  -- No device at this address
    end

    self.access_count = self.access_count + 1

    -- Use custom read handler if provided
    if device.read_handler then
        return device.read_handler(offset, size)
    end

    -- Default read from device data
    if device.data[offset] then
        return device.data[offset]
    end

    return 0  -- Default value for unmapped registers
end

-- Write to MMIO address
function MMIOController:write(address, value, size)
    local device, offset = self:find_device(address)

    if not device or not offset then
        return false  -- No device at this address
    end

    self.access_count = self.access_count + 1

    -- Use custom write handler if provided
    if device.write_handler then
        device.write_handler(offset, value, size)
        return true
    end

    -- Default write to device data
    device.data[offset] = value
    return true
end

-- Check if address is MMIO
function MMIOController:is_mmio_address(address)
    return address >= self.base and address < self.base + self.size
end

-- Get device by name
function MMIOController:get_device(name)
    return self.devices[name]
end

-- List all registered devices
function MMIOController:list_devices()
    local list = {}
    for name, device in pairs(self.devices) do
        table.insert(list, {
            name = name,
            base_address = device.base_address,
            size = device.size,
            end_address = device.base_address + device.size - 1
        })
    end
    table.sort(list, function(a, b) return a.base_address < b.base_address end)
    return list
end

-- Get MMIO statistics
function MMIOController:get_statistics()
    return {
        mmio_base = self.base,
        mmio_size = self.size,
        device_count = #self:list_devices(),
        access_count = self.access_count,
        devices = self:list_devices()
    }
end

return MMIOController