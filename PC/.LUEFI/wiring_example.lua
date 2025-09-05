-- examples/wiring_example.lua
-- End-to-end wiring: CPU + Bus + DRAM + UART with a realistic MMIO hole,
-- plus cache/TLB demonstrations (cold vs warm, eviction, write-back).

package.path = package.path .. ";./?.lua"

local CPUDev   = require("devices.cpu")
local MemDev   = require("devices.memory")
local BusDev   = require("devices.bus")
local UARTDev  = require("devices.uart")

local bit32 = bit32

-- Helpers to snapshot and print cache deltas
local function cache_snapshot(cpu)
    local s = cpu:get_stats().cache.levels
    local function take(cs) return { h=cs.hits, m=cs.misses, f=cs.fills, ev=cs.evictions, wb=cs.writebacks } end
    return { l1d=take(s.l1d), l1i=take(s.l1i), l2=take(s.l2), l3=take(s.l3) }
end

local function cache_delta(a, b)
    local function d(x, y) return { h=y.h-x.h, m=y.m-x.m, f=y.f-x.f, ev=y.ev-x.ev, wb=y.wb-x.wb } end
    return { l1d=d(a.l1d,b.l1d), l1i=d(a.l1i,b.l1i), l2=d(a.l2,b.l2), l3=d(a.l3,b.l3) }
end

local function print_cache(label, s)
    local function line(tag, t)
        local total = t.h + t.m
        local rate  = total > 0 and (100 * t.h / total) or 0
        print(string.format("%-8s %-3s: hits=%3d misses=%3d (%.1f%%) fills=%3d evict=%2d wb=%2d",
            label, tag, t.h, t.m, rate, t.f, t.ev, t.wb))
    end
    line("L1D", s.l1d); line("L1I", s.l1i); line("L2", s.l2); line("L3", s.l3)
end

-- Create devices
local dram = MemDev.DRAM:new(0x20000)           -- 128 KiB DRAM [0x00000..0x1FFFF]
local bus  = BusDev.Bus:new()
local cpu  = CPUDev.CPU:new({ backend = bus, target = "rv64" })

-- Carve out an MMIO window [0x0C000..0x0DFFF] (8 KiB) from physical space:
-- Map RAM around that hole, keeping a single contiguous DRAM backing via mem_offset.
bus:map_ram("ram0", 0x00000, 0x0C000, dram, 0x00000) -- [0x00000..0x0BFFF] -> DRAM[0x00000..0x0BFFF]
bus:map_ram("ram1", 0x0E000, 0x12000, dram, 0x0C000) -- [0x0E000..0x1FFFF] -> DRAM[0x0C000..0x1FFFF]

-- MMIO UART @ [0x0C000..0x0C00F] inside the MMIO hole
local uart = UARTDev.UART:new(0x0C000, 0x0010, { verbose = true })
bus:register_mmio("uart0", uart)

-- Identity-map all pages (128 KiB / 4 KiB = 32 pages).
-- Mark the MMIO window pages (0x0C000..0x0DFFF -> vpages 12 & 13) as uncached.
local page_shift = 12
local function vpage(addr) return bit32.rshift(addr, page_shift) end
for vp = 0, 31 do
    local cached = not (vp == vpage(0x0C000) or vp == vpage(0x0D000))
    cpu:map_page(vp, vp, { write = true, execute = false, cached = cached })
end

-- 0) Basic DRAM store/load via CPU (exercises write-allocate on store)
cpu:store(0x0000, 4, 0x11223344, false)
local r = cpu:load(0x0000, 4, false)
print(string.format("LOAD @0x0000 -> 0x%08X", r))

-- 1) MMIO UART write (uncached): should print "Hello!"
local msg = "Hello!"
for i = 1, #msg do
    cpu:store(0x0C000, 1, string.byte(msg, i), false)
end
print("")

-- 2) Cold vs warm cache: second pass should be L1D hits
-- Choose a footprint smaller than L1D to stay resident.
local function touch_footprint(lines)
    for i = 1, lines do
        local addr = (i * 64) % 0x4000  -- lines in first 16 KiB
        cpu:load(addr, 4, false)
    end
end

cpu:flush_dcache()  -- start cold for clarity (L1D only; inclusive will refill lower)
cpu:flush_l2()
cpu:flush_l3()

local before = cache_snapshot(cpu)
touch_footprint(96)     -- cold pass: fills + misses
local mid    = cache_snapshot(cpu)
touch_footprint(96)     -- warm pass: should mostly hit in L1D
local after  = cache_snapshot(cpu)

print_cache("cold+warm", cache_delta(before, after))
-- If you want to see them separately:
-- print_cache("cold", cache_delta(before, mid))
-- print_cache("warm", cache_delta(mid, after))

-- 3) Set conflict + eviction:
-- L1D has 64 sets, 8 ways, 64B line. Addresses spaced by 4096B (64*64) map to the same set.
-- Access 9 distinct lines in that set to force an eviction (ways=8).
local base = 0x2000  -- pick an address in RAM
cpu:flush_dcache(); cpu:flush_l2(); cpu:flush_l3()
before = cache_snapshot(cpu)
for k = 0, 8 do
    cpu:load(base + k * 4096, 4, false)
end
-- Now touch the first line again; should be a miss if it got evicted by the 9th fill.
cpu:load(base, 4, false)
after = cache_snapshot(cpu)
print_cache("conflict", cache_delta(before, after))

-- 4) Write-back demonstration:
-- Store to a line, check DRAM before/after cache flush. Without flush, DRAM should not reflect the store.
local wb_addr = 0x3000
cpu:store(wb_addr, 8, 0xDEADBEEFCAFEBABE, false)

-- Read physical DRAM bytes directly (backend), before flush: expect zeroes (was cleared at init).
local pre = dram:peek(wb_addr, 8)
local function bytes_to_hex(bs) local t={}; for i=1,#bs do t[i]=string.format("%02X", bs[i]) end; return table.concat(t) end
print("DRAM before flush @0x3000:", bytes_to_hex(pre))

-- Flush all levels to push dirty data back to DRAM
cpu:flush_dcache(); cpu:flush_l2(); cpu:flush_l3()

local post = dram:peek(wb_addr, 8)
print("DRAM after  flush @0x3000:", bytes_to_hex(post))

-- 5) MMU execute permission demo
local ok, err = pcall(function() cpu:fetch(0x0000, 4) end)
print("Fetch @0x0000 with execute=false:", ok and "OK" or ("DENIED: "..tostring(err)))
-- Allow execute on that page and try again
cpu:set_page_attributes(vpage(0x0000), { executable = true })
ok, err = pcall(function() cpu:fetch(0x0000, 4) end)
print("Fetch @0x0000 with execute=true:", ok and "OK" or ("DENIED: "..tostring(err)))

-- 6) Final stats overview
local s = cpu:get_stats()
print("\nCPU Target:", s.target.isa, s.target.xlen, s.target.endianness)
print(string.format("MMU: TLB hits=%d misses=%d faults=%d", s.mmu.tlb_hits, s.mmu.tlb_misses, s.mmu.page_faults))
print("Bus regions:")
for _, rgn in ipairs(bus:list_regions()) do
    print(string.format("  %-6s [0x%05X..0x%05X] (%d bytes)", rgn.name, rgn.base, rgn["end"], rgn.size))
end
print("\nCache totals:")
local levels = s.cache.levels
local function rate(h, m) local t=h+m; return t>0 and (100*h/t) or 0 end
for _, lvl in ipairs({ "l1d", "l1i", "l2", "l3" }) do
    local cs = levels[lvl]
    print(string.format("%-3s: hits=%d misses=%d (%.1f%%) fills=%d evict=%d wb=%d",
        lvl:upper(), cs.hits, cs.misses, rate(cs.hits, cs.misses), cs.fills, cs.evictions, cs.writebacks))
end