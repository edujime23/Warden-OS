-- examples/wiring_example.lua
-- CPU + Bus + DRAM + UART + Timer + PLIC + CLINT + CSR delivery + UART RX IRQ (concise logs).

package.path = package.path .. ";./?.lua"

local CPUDev   = require("devices.cpu")
local MemDev   = require("devices.memory")
local BusDev   = require("devices.bus")
local UARTDev  = require("devices.uart")
local ROMDev   = require("devices.rom")
local TimerDev = require("devices.timer")
local INTDev   = require("devices.intc")
local ABI      = require("firmware.abi")
local Boot     = require("firmware.bootservices")
local RT       = require("firmware.runtimeservices")
local bit32    = bit32

-- Logger
local raw_print = _G.print
local function create_logger(path)
    local dir = fs.combine(fs.getDir(path), ""); if dir ~= "" and not fs.exists(dir) then fs.makeDir(dir) end
    local fh = fs.open(path, "w")
    local function println_to_file(line) if fh then fh.write(line .. "\n") end end
    local function println(...) local n=select("#", ...); if n==0 then println_to_file(""); return end
        local t={}; for i=1,n do t[#t+1]=tostring(select(i,...)) end; println_to_file(table.concat(t," ")) end
    local function printf(fmt, ...) println_to_file(string.format(fmt, ...)) end
    local function close() if fh then fh.close() end end
    return { println=println, printf=printf, close=close }
end
local LOG_PATH = "logs/wiring_example.log"
local logger = create_logger(LOG_PATH)
print = logger.println
local function printf(fmt, ...) logger.printf(fmt, ...) end

-- Helpers
local function bytes_to_hex(bs, n)
    local t, k = {}, math.min(#bs, n or #bs)
    for i=1,k do t[i]=string.format("%02X", bs[i]) end
    return table.concat(t)
end
local function cache_snapshot(cpu)
    local s = cpu:get_stats().cache.levels
    local function take(cs) return { h=cs.hits, m=cs.misses, f=cs.fills, ev=cs.evictions, wb=cs.writebacks, pf=cs.prefetches or 0 } end
    return { l1d=take(s.l1d), l1i=take(s.l1i), l2=take(s.l2), l3=take(s.l3) }
end
local function cache_delta(a, b)
    local function d(x, y) return { h=y.h-x.h, m=y.m-x.m, f=y.f-x.f, ev=y.ev-x.ev, wb=y.wb-x.wb, pf=y.pf-x.pf } end
    return { l1d=d(a.l1d,b.l1d), l1i=d(a.l1i,b.l1i), l2=d(a.l2,b.l2), l3=d(a.l3,b.l3) }
end
local function print_cache(label, s)
    local function line(tag, t) local total=t.h+t.m; local rate= total>0 and (100*t.h/total) or 0
        printf("%-8s %s h=%3d m=%3d r=%5.1f%% f=%3d ev=%2d wb=%2d pf=%2d", label, tag, t.h, t.m, rate, t.f, t.ev, t.wb, t.pf) end
    line("L1D", s.l1d); line("L1I", s.l1i); line("L2", s.l2); line("L3", s.l3)
end

-- Devices
local dram = MemDev.DRAM:new(0x20000)
local bus  = BusDev.Bus:new()
local cpu  = CPUDev.CPU:new({ backend = bus, target = "rv64", prefetch = { enable = true, to = "l2" } })

bus:map_ram("ram0", 0x00000, 0x0C000, dram, 0x00000)
bus:map_ram("ram1", 0x0E000, 0x12000, dram, 0x0C000)

local uart  = UARTDev.UART:new(0x0C000, 0x0010, { verbose = true }); bus:register_mmio("uart0",  uart)
local rom   = ROMDev.ROM:new (0x20000, 0x1000, { fill = 0xFF });      bus:register_mmio("rom0",   rom)
local timer = TimerDev.Timer:new(0x0C100, { tick = 10 });             bus:register_mmio("timer0", timer)
local plic  = INTDev.PLIC:new(0x0C200, { sources = 8, contexts = 2 }) -- compact (level)
bus:register_mmio("plic0",  plic)

local CLINT_BASE = 0x24000
local clint = INTDev.CLINT:new(CLINT_BASE, { harts = 1, tick = 1 })
bus:register_mmio("clint0", clint)

local PLIC_CAN_BASE = 0x30000
local plic_can = INTDev.PLIC:new(PLIC_CAN_BASE, { sources = 4, contexts = 1, layout = "canonical", mode = "latched" })
bus:register_mmio("plic1_canonical", plic_can)

-- ROM init
local img={}; for i=1,256 do img[i]=(i-1)%256 end
rom:load_image(img,0); rom:load_image_string("LUEFI-ROM",256)

-- MMU map
local page_shift=12; local function vpage(a) return bit32.rshift(a,page_shift) end
for vp=0,31 do
    local cached = not (vp == vpage(0x0C000) or vp == vpage(0x0D000))
    cpu:map_page(vp, vp, { write=true, execute=false, cached=cached, memtype="normal" })
end
cpu:map_page(vpage(0x20000), vpage(0x20000), { write=false, execute=true, cached=true, memtype="normal" })
cpu:set_page_attributes(vpage(0x8000), { memtype="wc", cached=false })
for vp = vpage(CLINT_BASE), vpage(CLINT_BASE + 0xC000 - 1) do
    cpu:map_page(vp, vp, { write=true, execute=false, cached=false, memtype="device" })
end
for vp = vpage(PLIC_CAN_BASE), vpage(PLIC_CAN_BASE + 0x3FFF) do
    cpu:map_page(vp, vp, { write=true, execute=false, cached=false, memtype="device" })
end

-- Sanity IO
cpu:store(0x0000,4,0x11223344,false)
print(string.format("LOAD @0x0000 -> 0x%08X", cpu:load(0x0000,4,false)))
local rom_bytes=cpu:fetch(0x20000,16); print("ROM[0..7] @0x20000:", bytes_to_hex(rom_bytes, 8))
print("")

-- Timer + PLIC (level)
local function write32(a,v) cpu:store(a,4,v,false) end
local function read32(a) return cpu:load(a,4,false) end
local function write64(a,v) cpu:store(a,8,v,false) end

cpu:attach_plic(plic, 0x0C200, { layout = "compact", ctx_id = 0 })
cpu:attach_clint(clint, { hart = 0 })
timer:attach_irq(plic, 1)

write32(0x0C108,100); write32(0x0C10C,0); write32(0x0C118,10); write32(0x0C110,0x7)
write32(0x0C200 + 0x000, 1)
write32(0x0C200 + 0x180 + 0x00, 0x1); write32(0x0C200 + 0x180 + 0x08, 0)
write32(0x0C200 + 0x1A0 + 0x00, 0x1); write32(0x0C200 + 0x1A0 + 0x08, 2)

local function drain_ctx0(handler)
    local n=0
    while true do
        local id = cpu:poll_interrupts(0, handler)
        if id == 0 then break end
        n = n + 1
    end
    return n
end

for step=1,5 do
    timer:advance(5)
    local claims, err_id, noh_id = 0, 0, 0
    if step == 2 then
        claims = drain_ctx0(function(_id) write32(0x0C114, 1) end)
    elseif step == 3 then
        write32(0x0C108, 100); timer:advance(10)
        write32(0x0C110, 0x5); cpu:poll_interrupts(0, nil)
        write32(0x0C110, 0x7)
        claims = drain_ctx0(function(_id) write32(0x0C114, 1) end)
    elseif step == 4 then
        err_id = cpu:poll_interrupts(0, function(_id) error("simulated ISR failure") end)
        noh_id = cpu:poll_interrupts(0, nil)
        write32(0x0C114, 1)
        claims = drain_ctx0(nil)
    else
        cpu:poll_interrupts(0, nil)
    end
    local ctx1_claim = cpu:poll_interrupts(1, nil)
    local pend = bit32.band(read32(0x0C114),1) ~= 0
    printf("TMR step %d: pend=%s claims=%d err=%d noh=%d ctx1=%d", step, tostring(pend), claims, err_id, noh_id, ctx1_claim)
end
print("")

-- CLINT demo
local function MSIP(h)     return CLINT_BASE + 0x0000 + 4*h end
local function MTIMECMP(h) return CLINT_BASE + 0x4000 + 8*h end
local MTIME = CLINT_BASE + 0xBFF8

write32(MSIP(0), 1);  local lv = clint:get_irq_levels(1); printf("CLINT: msip set -> %s", tostring(lv.msip))
write32(MSIP(0), 0);  lv = clint:get_irq_levels(1);       printf("CLINT: msip clr -> %s", tostring(lv.msip))
write64(MTIME, 0); write64(MTIMECMP(0), 50)
clint:advance(40); lv = clint:get_irq_levels(1); printf("CLINT: mtip @40 -> %s", tostring(lv.mtip))
clint:advance(10); lv = clint:get_irq_levels(1); printf("CLINT: mtip @50 -> %s", tostring(lv.mtip))
write64(MTIMECMP(0), 0); lv = clint:get_irq_levels(1);     printf("CLINT: mtip off-> %s", tostring(lv.mtip))
print("")

-- Canonical PLIC (latched) manual test
local CLAIM_CAN     = PLIC_CAN_BASE + 0x2000 + 0x00C
local COMPLETE_CAN  = PLIC_CAN_BASE + 0x2000 + 0x010
write32(PLIC_CAN_BASE + 0x0000 + 4*(2-1), 3)
write32(PLIC_CAN_BASE + 0x2000 + 0x000, 0x2)
write32(PLIC_CAN_BASE + 0x2000 + 0x008, 0)
plic_can:raise(2)
local a = cpu:load(CLAIM_CAN, 4, false)
local b = cpu:load(CLAIM_CAN, 4, false)
cpu:store(COMPLETE_CAN, 4, a, false)
local c = cpu:load(CLAIM_CAN, 4, false)
plic_can:lower(2)
cpu:store(COMPLETE_CAN, 4, c, false)
local d = cpu:load(CLAIM_CAN, 4, false)
printf("PLIC(latched) manual: a=%d b=%d c=%d d=%d", a, b, c, d)
print("")

-- CSR interrupt delivery tests (unchanged)
local csr = cpu:csr_block()
csr:enable_mie(false); csr:enable_msie(false); csr:enable_mtie(false); csr:enable_meie(false)
write64(MTIME, 0); write64(MTIMECMP(0), 20); clint:advance(20); cpu:sample_irqs()
local cause = cpu:maybe_take_interrupt() or "none"; printf("CSR MTIP masked: %s", tostring(cause))
csr:enable_mtie(true); cpu:sample_irqs()
cause = cpu:maybe_take_interrupt() or "none";        printf("CSR MTIP no MIE: %s", tostring(cause))
csr:enable_mie(true); cpu:sample_irqs()
cause = cpu:maybe_take_interrupt() or "none";        printf("CSR MTIP taken : %s", tostring(cause))
cpu:complete_trap(); write64(MTIMECMP(0), 0); cpu:sample_irqs(); print("CSR MTIP cleared")
csr:enable_msie(true); csr:enable_mie(true); write32(MSIP(0), 1); cpu:sample_irqs()
cause = cpu:maybe_take_interrupt() or "none"; printf("CSR MSIP taken : %s", tostring(cause))
cpu:complete_trap(); write32(MSIP(0), 0); cpu:sample_irqs()
csr:enable_meie(true); csr:enable_mie(true)
write32(0x0C200 + 0x000, 1); write32(0x0C200 + 0x180 + 0x00, 0x1); write32(0x0C200 + 0x180 + 0x08, 0)
plic:raise(1); cpu:sample_irqs()
cause = cpu:maybe_take_interrupt() or "none"; printf("CSR MEIP taken : %s", tostring(cause))
cpu:complete_trap(); plic:lower(1); cpu:sample_irqs()
print("")

-- UART RX IRQ demo (compact PLIC, level mode)
-- Wire UART->PLIC source 3; enable RX IRQ; inject "OK\n"; drain via poller.
uart:attach_irq(plic, 3)
write32(0x0C200 + 0x000 + 4*(3-1), 2)          -- prio[3]=2
write32(0x0C200 + 0x180 + 0x00, 0x5)           -- enable src1|src3 for ctx0
write32(0x0C000 + 0x08, 0x1)                    -- CTRL: RX IRQ enable
uart:feed_string("OK\n")
local rx_read = 0
local claims = drain_ctx0(function(id)
    if id == 3 then
        -- Read until RX empty
        while true do
            local b = cpu:load(0x0C000 + 0x00, 1, false)
            if b == 0 then break end
            rx_read = rx_read + 1
        end
    end
end)
printf("UART RX: claims=%d read=%d", claims, rx_read)
print("")

-- UART TX (existing behavior)
local msg="Hello!"; for i=1,#msg do cpu:store(0x0C000,1,string.byte(msg,i),false) end
print("")

-- Cache demos (unchanged)
local before=cache_snapshot(cpu); local function touch(n) for i=1,n do local a=(i*64)%0x4000; cpu:load(a,4,false) end end
cpu:flush_dcache(); cpu:flush_l2(); cpu:flush_l3(); touch(96); touch(96); local after=cache_snapshot(cpu)
print_cache("cold+warm", cache_delta(before,after))

local base=0x2000; cpu:flush_dcache(); cpu:flush_l2(); cpu:flush_l3(); before=cache_snapshot(cpu)
for k=0,8 do cpu:load(base + k*4096, 4, false) end
cpu:load(base, 4, false); after=cache_snapshot(cpu)
print_cache("conflict", cache_delta(before,after))

-- Write-back / WC (unchanged)
local wb_addr=0x3000; cpu:store(wb_addr,8,0xDEADBEEFCAFEBABE,false)
local pre = dram:peek(wb_addr,8); print("DRAM before:", bytes_to_hex(pre))
cpu:flush_dcache(); cpu:flush_l2(); cpu:flush_l3()
local post = dram:peek(wb_addr,8); print("DRAM after :", bytes_to_hex(post))

local wcb_base=0x8000
local w_before=bus:get_statistics().writes
for i=0,31 do cpu:store(wcb_base+i,1,i,false) end
local w_mid=bus:get_statistics().writes; printf("WC before barrier: %d -> %d", w_before, w_mid)
cpu:memory_barrier()
local w_after=bus:get_statistics().writes; printf("WC after  barrier: %d -> %d", w_mid, w_after)

-- Exec perms (unchanged)
local ok = pcall(function() cpu:fetch(0x0000,4) end); print("Exec @0x0000 false:", ok and "OK" or "DENIED")
cpu:set_page_attributes(vpage(0x0000), { executable=true })
ok = pcall(function() cpu:fetch(0x0000,4) end);       print("Exec @0x0000 true :", ok and "OK" or "DENIED")

-- Boot/Runtime (unchanged)
local memsrv=Boot.Memory:new(cpu,bus)
local pool_size=6*1024
local pool_base,pool_pages = memsrv:allocate_pool(pool_size)
printf("BS: pool %d bytes @0x%05X (%d pages)", pool_size, pool_base, pool_pages)
local written_bytes,count = memsrv:write_memory_map(pool_base)
printf("BS: memmap %d desc, %d bytes", count, written_bytes)
local abiT=ABI.Types:new(cpu); local function U32(va) return abiT:view("uint32",va) end; local function U64(va) return abiT:view("uint64",va) end
local ds=40; local first=pool_base
local t_type  = U32(first+0):get(); local t_phys=U64(first+8):to_hex()
local t_pages = U64(first+24):get(); local t_attr=U64(first+32):get()
printf("BS: desc0 Type=%d Phys=%s Pages=%d Attr=0x%X", t_type, t_phys, t_pages, t_attr)
memsrv:free_pool(pool_base, pool_size); print("BS: pool freed")

local Vars = RT.Variables; local vars = Vars:new(cpu, { persist_path = "nvram/vars.txt" })
vars:set("PlatformLang","en-US", bit32.bor(Vars.Attr.NV, Vars.Attr.BS, Vars.Attr.RT), "{00000000-0000-0000-0000-000000000000}")
vars:set("BootOrder",{0,1,2,3}, bit32.bor(Vars.Attr.NV, Vars.Attr.BS, Vars.Attr.RT), "{8BE4DF61-93CA-11D2-AA0D-00E098032B8C}")
local data_lang, attr_lang = vars:get("PlatformLang","{00000000-0000-0000-0000-000000000000}")
local data_bo,   attr_bo   = vars:get("BootOrder","{8BE4DF61-93CA-11D2-AA0D-00E098032B8C}")
printf("RT: Lang='%s' attr=0x%X", string.char(table.unpack(data_lang or {})), attr_lang or 0)
printf("RT: BootOrder=%s attr=0x%X", bytes_to_hex(data_bo or {}), attr_bo or 0)
local vpool_size=4096; local vpool_base,_= memsrv:allocate_pool(vpool_size)
local vbytes,vcount = vars:write_index_to_mem(vpool_base); printf("RT: var index %d vars, %d bytes", vcount, vbytes)
memsrv:free_pool(vpool_base, vpool_size)

-- ASID + ABI (unchanged)
cpu:set_asid(1); cpu:map_page(vpage(0x0000), vpage(0x0000), { write=true, cached=true, memtype="normal" }, 1); cpu:load(0x0000,4,false)
local abi2=ABI.Types:new(cpu); local t_u64 = abi2:view("uint64",0x0010); t_u64:set(0xAABBCCDDEEFF0011)
print(string.format("ABI u64 @0x0010 -> %s", t_u64:to_hex()))

-- Final stats
local s=cpu:get_stats(); print("")
printf("CPU: %s %d %s", s.target.isa, s.target.xlen, s.target.endianness)
printf("MMU: ASID=%d TLB hits=%d miss=%d faults=%d", s.mmu.asid, s.mmu.tlb_hits, s.mmu.tlb_misses, s.mmu.page_faults)
print("Bus regions:"); for _,rgn in ipairs(bus:list_regions()) do printf("  %-6s [0x%05X..0x%05X] (%dB)", rgn.name, rgn.base, rgn['end'], rgn.size) end
print(""); print("Cache totals:")
local levels=s.cache.levels; local function rate(h,m) local t=h+m; return t>0 and (100*h/t) or 0 end
for _,lvl in ipairs({"l1d","l1i","l2","l3"}) do local cs=levels[lvl]
    printf("%-3s h=%d m=%d r=%4.1f%% f=%d pf=%d ev=%d wb=%d",
        lvl:upper(), cs.hits, cs.misses, rate(cs.hits, cs.misses), cs.fills, cs.prefetches or 0, cs.evictions, cs.writebacks)
end

logger.close(); if raw_print then raw_print("Log saved to " .. LOG_PATH) end