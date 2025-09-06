-- test.lua

local LOG_PATH = "logs/test.log"
local NVRAM_PATH = "logs/test_nvram.vars"

-- Logger
local Logger = {}
Logger.__index = Logger
function Logger:new(path)
    local dir = fs.getDir(path)
    if dir ~= "" and not fs.exists(dir) then pcall(fs.makeDir, dir) end
    local fh = fs.open(path, "w")
    return setmetatable({ fh = fh, start_time = os.clock() }, Logger)
end
function Logger:log(...)
    local msg = string.format(...)
    local t = string.format("[%7.3f] %s", os.clock() - self.start_time, msg)
    print(t)
    if self.fh then self.fh.writeLine(t) end
end
function Logger:close() if self.fh then self.fh.close() end end

-- Tester
local Tester = {}
Tester.__index = Tester
function Tester:new(logger) return setmetatable({ logger = logger, passed = 0, failed = 0 }, Tester) end
function Tester:group(name) self.logger:log("\n----------------------------------------\n-- %s\n----------------------------------------", name) end
function Tester:test(name, func)
    self.logger:log("RUNNING: %s", name)
    local ok, err = pcall(func)
    if ok then
        self.logger:log("  PASS")
        self.passed = self.passed + 1
    else
        self.logger:log("  FAIL: %s", tostring(err):gsub(":%d+: ", ": "))
        self.failed = self.failed + 1
    end
end
function Tester:summary()
    self.logger:log("\n========================================")
    self.logger:log("Test Summary:")
    self.logger:log("  Passed: %d", self.passed)
    self.logger:log("  Failed: %d", self.failed)
    self.logger:log("========================================")
end

-- Asserts
local function assert_true(c, m) assert(c, m or "Assertion failed: expected true") end
local function assert_eq(a,b,m) assert(a==b, m or string.format("Assertion failed: expected %s == %s", tostring(a), tostring(b))) end
local function assert_neq(a,b,m) assert(a~=b, m or string.format("Assertion failed: expected %s ~= %s", tostring(a), tostring(b))) end
local function assert_throws(f, msg)
    local ok, err = pcall(f)
    assert(not ok, "Assertion failed: expected function to throw an error")
    if msg then assert(string.find(tostring(err), msg, 1, true), ("Error '%s' did not contain '%s'"):format(err, msg)) end
end

-- Helpers
local function unpack32(b)
    return bit32.bor(b[1] or 0, bit32.lshift(b[2] or 0, 8), bit32.lshift(b[3] or 0, 16), bit32.lshift(b[4] or 0, 24))
end
local function pack32_le(v)
    return {
        bit32.band(v,0xFF),
        bit32.band(bit32.rshift(v,8),0xFF),
        bit32.band(bit32.rshift(v,16),0xFF),
        bit32.band(bit32.rshift(v,24),0xFF)
    }
end

-- Build machine
local function build_machine()
    local m = {}
    m.components = {
        Bus = require("devices.bus").Bus, CPU = require("devices.cpu").CPU, DRAM = require("devices.memory").DRAM,
        ROM = require("devices.rom").ROM, PLIC = require("devices.intc").PLIC, CLINT = require("devices.intc").CLINT,
        DMA = require("devices.dma").DMA, Timer = require("devices.timer").Timer, UART = require("devices.uart").UART,
        BootMem = require("firmware.bootservices").Memory, RTTime = require("firmware.runtimeservices").Time,
        RTVars = require("firmware.runtimeservices").Variables
    }
    m.bus = m.components.Bus:new({ strict_mmio = true })
    m.dram = m.components.DRAM:new(16 * 1024 * 1024)
    m.bus:map_ram("dram_main", 0x80000000, 16 * 1024 * 1024, m.dram, 0)
    m.dram_high = m.components.DRAM:new(8 * 1024 * 1024)
    m.bus:map_ram("dram_high", 0x200000000, 8 * 1024 * 1024, m.dram_high, 0)

    m.plic = m.components.PLIC:new(0x0C000000, { sources = 10 })
    m.clint = m.components.CLINT:new(0x02000000, { harts = 1 })
    m.dma = m.components.DMA:new(0x10001000, m.bus, { ram_only = true })
    m.timer = m.components.Timer:new(0x10002000)
    m.uart = m.components.UART:new(0x10000000)
    m.rom = m.components.ROM:new(0x2000, 4096, { strict = true })
    for name, dev in pairs({plic=m.plic, clint=m.clint, dma=m.dma, timer=m.timer, uart=m.uart, rom=m.rom}) do
        m.bus:register_mmio(name, dev)
    end

    m.cpu = m.components.CPU:new({ target = "rv64", backend = m.bus })
    m.dma:attach_irq(m.plic, 1); m.timer:attach_irq(m.plic, 2); m.uart:attach_irq(m.plic, 3)
    m.plic.prio[1]=1; m.plic.prio[2]=2; m.plic.prio[3]=3
    m.cpu:attach_plic(m.plic, 0x0C000000); m.cpu:attach_clint(m.clint)

    m.boot_mem = m.components.BootMem:new(m.cpu, m.bus)
    m.rt_time = m.components.RTTime:new()
    m.rt_vars = m.components.RTVars:new(m.cpu, { persist_path = NVRAM_PATH })

    -- Enable PLIC sources 1..3 for context 0 via MMIO
    do
        local en_mask = bit32.bor(bit32.lshift(1,0), bit32.lshift(1,1), bit32.lshift(1,2))
        local en_off = m.plic.off.OFF_CTX_BASE + m.plic.off.CTX_ENABLE_LO
        m.plic:write(en_off, pack32_le(en_mask))
    end

    return m
end

-- Tests
local function run_all_tests(logger)
    local T = Tester:new(logger)

    logger:log("Building main test machine instance...")
    local m = build_machine()
    local cpu, dram, dram_high, plic, clint, dma, timer, uart, rom = m.cpu, m.dram, m.dram_high, m.plic, m.clint, m.dma, m.timer, m.uart, m.rom
    local boot_mem, rt_time, rt_vars = m.boot_mem, m.rt_time, m.rt_vars
    logger:log("Machine build complete.")

    T:group("Bus and Memory Subsystem")
    T:test("Bus should prevent overlapping memory regions", function()
        local bus = require("devices.bus").Bus:new()
        local d = require("devices.memory").DRAM:new(4096)
        bus:map_ram("ram1", 0x1000, 4096, d)
        assert_throws(function() bus:map_ram("ram2", 0x1500, 4096, d) end, "Bus region overlap")
    end)
    T:test("Bus should handle reads that cross region boundaries", function()
        local bus = require("devices.bus").Bus:new()
        local d = require("devices.memory").DRAM:new(4096); d:write_bytes(4094, {0x11, 0x22})
        local r = require("devices.rom").ROM:new(0x1000, 4); r:load_image({0xCC, 0xDD})
        bus:map_ram("ram_low", 0x0, 4096, d); bus:register_mmio("rom_high", r)
        local bytes = bus:read_bytes(4094, 4)
        assert_eq(bytes[1], 0x11); assert_eq(bytes[2], 0x22); assert_eq(bytes[3], 0xCC); assert_eq(bytes[4], 0xDD)
    end)
    T:test("DRAM should handle overlapping internal copy (memmove)", function()
        local d = require("devices.memory").DRAM:new(16); d:load_image(0, {1,2,3,4,5,0,0,0})
        d:copy(2, 0, 5); assert_eq(d:peek(0, 8)[3], 1); assert_eq(d:peek(0, 8)[7], 5)
        d:load_image(0, {1,2,3,4,5,0,0,0}); d:copy(0, 2, 5)
        assert_eq(d:peek(0, 8)[1], 3); assert_eq(d:peek(0, 8)[5], 0)
    end)
    T:test("ROM should throw error on write in strict mode", function()
        assert_throws(function() rom:write(0, {1}) end, "Write to ROM region is not allowed")
    end)

    T:group("CPU, MMU, Cache")
    T:test("MMU should correctly translate a high (>32-bit) virtual address", function()
        local VA, PA = 0x543210000, 0x200010000
        cpu:map_page(cpu.mmu:get_page_number(VA), cpu.mmu:get_page_number(PA))
        local translated_pa = select(1, cpu:translate(VA)); assert_eq(translated_pa, PA)
    end)
    T:test("MMU should throw a page fault for unmapped addresses", function()
        assert_throws(function() cpu:load(0xDEADBEEF, 4) end, "Page fault")
    end)
    T:test("Cache should perform write-back on eviction", function()
        local VA, PA = 0x90000000, 0x80000000
        cpu:map_page(cpu.mmu:get_page_number(VA), cpu.mmu:get_page_number(PA))
        cpu:store(VA, 4, 0xDEADBEEF)
        assert_neq(dram:read_bytes(0, 4)[1], 0xEF)
        cpu.dcache:flush_line(PA, "l1d"); cpu.dcache:flush_line(PA, "l2"); cpu.dcache:flush_line(PA, "l3")
        assert_eq(dram:read_bytes(0, 4)[4], 0xDE)
    end)
    T:test("Cache should bypass for 'device' memory type", function()
        local VA, PA = 0xA0000000, 0x80010000
        cpu:map_page(cpu.mmu:get_page_number(VA), cpu.mmu:get_page_number(PA), { memtype = "device" })
        local s0 = cpu:get_stats().cache.levels.l1d
        cpu:load(VA, 4)
        local s1 = cpu:get_stats().cache.levels.l1d
        assert_eq(s1.hits, s0.hits); assert_eq(s1.misses, s0.misses)
    end)
    T:test("Cache write-combining buffer should coalesce sequential writes", function()
        local VA, PA = 0xB0000000, 0x80020000
        cpu:map_page(cpu.mmu:get_page_number(VA), cpu.mmu:get_page_number(PA), { memtype = "wc" })
        cpu:store(VA, 4, 1); cpu:store(VA + 4, 4, 2)
        assert_eq(#cpu._wc_buf.bytes, 8)
        cpu:store(VA + 100, 4, 3)
        assert_eq(cpu._wc_buf.base, PA + 100); assert_eq(#cpu._wc_buf.bytes, 4)
        cpu:memory_barrier()
    end)

    T:group("DMA Controller")
    T:test("DMA should perform a copy to/from high (>32-bit) memory", function()
        dram_high:write_bytes(0, {0xDE, 0xAD, 0xBE, 0xEF})
        dma:write(0x04, pack32_le(0x00000002))       -- SRC_HI = 2
        dma:write(0x00, pack32_le(0x00000000))       -- SRC_LO = 0
        dma:write(0x0C, pack32_le(0x00000002))       -- DST_HI = 2
        dma:write(0x08, pack32_le(0x00001000))       -- DST_LO = 0x1000
        dma:write(0x10, pack32_le(4))
        dma:write(0x14, pack32_le(1))
        local r = dram_high:read_bytes(0x1000, 4)
        assert_eq(r[1], 0xDE); assert_eq(r[4], 0xEF)
    end)
    T:test("DMA should set error status on bad address", function()
        dma:write(0x04, pack32_le(0x00000000))       -- SRC_HI = 0 (unmapped region LO=1)
        dma:write(0x00, pack32_le(0x00000001))       -- SRC_LO = 1
        dma:write(0x0C, pack32_le(0x00000000))       -- DST_HI = 0
        dma:write(0x08, pack32_le(0x80001000))       -- DST_LO = valid DRAM
        dma:write(0x10, pack32_le(4)); dma:write(0x14, pack32_le(1))
        local status_b0 = dma:read(0x18, 4)[1]
        assert_eq(bit32.band(status_b0, 4), 4)
    end)
    T:test("DMA should not access MMIO when ram_only is set", function()
        dma:write(0x04, pack32_le(0))
        dma:write(0x00, pack32_le(0x00002000))       -- ROM MMIO
        dma:write(0x0C, pack32_le(0))
        dma:write(0x08, pack32_le(0x80002000))       -- valid DRAM
        dma:write(0x10, pack32_le(4)); dma:write(0x14, pack32_le(1))
        local status = dma:read(0x18, 4)[1]; assert_eq(bit32.band(status, 4), 4)
    end)
    T:test("DMA should raise IRQ on completion", function()
        plic:lower(1); dma:write(0x18, pack32_le(2))
        dma:write(0x04, pack32_le(0x00000000))
        dma:write(0x00, pack32_le(0x80000000))
        dma:write(0x0C, pack32_le(0x00000000))
        dma:write(0x08, pack32_le(0x80001000))
        dma:write(0x10, pack32_le(4))
        dma:write(0x14, pack32_le(3))                -- START + IRQ_EN
        assert_true(plic:get_context_irq(0), "DMA IRQ did not fire")
    end)

    T:group("Interrupt Controllers (PLIC and CLINT)")
    T:test("PLIC should prioritize higher priority interrupts", function()
        plic:lower(2); plic:lower(3); plic:raise(2); plic:raise(3)
        local claim_off = plic.off.OFF_CTX_BASE + plic.off.CTX_CLAIM
        local comp_off  = plic.off.OFF_CTX_BASE + plic.off.CTX_COMPLETE
        local claim_bytes = plic:read(claim_off, 4)
        assert_eq(unpack32(claim_bytes), 3)
        -- complete and make sure line is lowered (level mode needs the line cleared)
        plic:write(comp_off, pack32_le(3))
        plic:lower(3); plic:lower(2)
    end)
    T:test("PLIC should ignore interrupts below threshold", function()
        local thr_off  = plic.off.OFF_CTX_BASE + plic.off.CTX_THRESHOLD
        local claim_off= plic.off.OFF_CTX_BASE + plic.off.CTX_CLAIM
        local comp_off = plic.off.OFF_CTX_BASE + plic.off.CTX_COMPLETE

        -- start clean: all lines low
        plic:lower(1); plic:lower(2); plic:lower(3)

        plic:write(thr_off, pack32_le(2))  -- threshold = 2

        -- IRQ1 prio=1 <= thr=2 -> claim should be 0
        plic:raise(1)
        local c1 = unpack32(plic:read(claim_off, 4))
        assert_eq(c1, 0)
        plic:lower(1)

        -- IRQ3 prio=3 > thr=2 -> claim should be 3
        plic:raise(3)
        local c2 = unpack32(plic:read(claim_off, 4))
        assert_eq(c2, 3)
        plic:write(comp_off, pack32_le(3))
        plic:lower(3)

        plic:write(thr_off, pack32_le(0))
    end)
    T:test("CLINT should trigger MTIP when mtime >= mtimecmp", function()
        clint:write(0x4000, pack32_le(100)); clint:write(0x4004, pack32_le(0))
        clint:advance(99); assert_true(not clint:get_irq_levels(1).mtip)
        clint:advance(1);  assert_true(clint:get_irq_levels(1).mtip)
    end)

    T:group("Timer Device")
    T:test("Timer should advance by a large number of ticks efficiently", function()
        timer:write(0x10, pack32_le(1))
        local t0 = os.clock(); timer:advance(50000)
        assert_true(os.clock() - t0 < 0.2, "Timer advance took too long")
    end)
    T:test("Timer should auto-reload when enabled", function()
        timer:write(0x08, pack32_le(5)); timer:write(0x10, pack32_le(5))
        timer:advance(6)
        local val = timer:read(0, 4); assert_eq(unpack32(val), 0)
    end)

    T:group("UART Device")
    T:test("UART FIFO should maintain order", function()
        uart:feed_bytes({10, 20, 30})
        assert_eq(uart:read(0,1)[1], 10); assert_eq(uart:read(0,1)[1], 20); assert_eq(uart:read(0,1)[1], 30)
    end)
    T:test("UART FIFO should not overflow", function()
        for i=1, uart.rx_capacity+10 do uart:feed_string("a") end
        assert_eq(#uart.rx_fifo, uart.rx_capacity)
    end)

    T:group("Firmware Boot Services")
    T:test("BootMem should correctly allocate in high (>32-bit) memory", function()
        local addr = 0x200100000
        local page = boot_mem:allocate_pages(boot_mem.MemoryType.EfiLoaderCode, 1, { allocate_type = boot_mem.AllocateType.Address, address = addr })
        assert_eq(page, addr)
    end)
    T:test("BootMem should allocate and free pages correctly", function()
        local m1 = #boot_mem:get_memory_map().descriptors
        local addr = boot_mem:allocate_pages(boot_mem.MemoryType.EfiLoaderData, 10)
        boot_mem:free_pages(addr, 10)
        local m2 = #boot_mem:get_memory_map().descriptors
        assert_eq(m1, m2)
    end)
    T:test("BootMem should throw error when out of memory", function()
        assert_throws(function() boot_mem:allocate_pages(boot_mem.MemoryType.EfiLoaderData, 9999999) end, "out of memory")
    end)

    T:group("Firmware Runtime Services")
    T:test("RTVars should set and get a variable", function()
        rt_vars:set("TestVar", "Hello", 0, "GUID1")
        local data = select(1, rt_vars:get("TestVar", "GUID1"))
        assert_eq(string.char(table.unpack(data)), "Hello")
    end)
    T:test("RTVars should persist non-volatile variables", function()
        pcall(fs.delete, NVRAM_PATH)
        local vars1 = m.components.RTVars:new(cpu, { persist_path = NVRAM_PATH })
        vars1:set("BootOrder", {0,1}, vars1.Attr.NV + vars1.Attr.BS); vars1:save()
        local vars2 = m.components.RTVars:new(cpu, { persist_path = NVRAM_PATH })
        local data = select(1, vars2:get("BootOrder")); assert_eq(data[2], 1)
        pcall(fs.delete, NVRAM_PATH)
    end)
    T:test("RTVars should enforce READ_ONLY attribute", function()
        rt_vars:set("Immutable", "Data", rt_vars.Attr.READ_ONLY)
        assert_throws(function() rt_vars:set("Immutable", "NewData", rt_vars.Attr.READ_ONLY) end, "READ_ONLY")
    end)
    T:test("RTTime should set and get time", function()
        rt_time:set_time({Year=2024, Month=5, Day=10, Hour=12, Minute=0, Second=0, TimeZone=0})
        local t = rt_time:get_time(); assert_eq(t.Year, 2024); assert_eq(t.Minute, 0)
    end)

    T:summary()
end

-- Main
local logger = Logger:new(LOG_PATH)
run_all_tests(logger)
logger:close()