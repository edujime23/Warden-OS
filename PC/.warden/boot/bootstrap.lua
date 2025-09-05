local function POST()
    term.setBackgroundColor(colors.gray)
    term.write("Starting POST scan")
    peripherals = peripheral.getNames()
    for i, periph in ipairs(peripherals) do
        term.write("Peripheral #" .. i .. "")
    end
end

local function main()
    POST()
end

main()