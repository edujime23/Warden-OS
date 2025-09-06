-- devices/cpu/csr.lua
-- Minimal M-mode CSR block: mstatus, mie, mip, mepc, mcause (interrupt delivery only).
-- We model:
--   - mstatus.MIE (bit 3), mstatus.MPIE (bit 7)
--   - mie/mip: MSIE (bit3), MTIE (bit7), MEIE (bit11) and MSIP/MTIP/MEIP (same bits)
--   - mcause: store cause code only (3/7/11), track interrupt vs exception separately
-- This avoids 64-bit mcause MSB handling (not needed for our demos in Lua doubles).

local CSR = {}
CSR.__index = CSR

local BITS = {
    MSTATUS_MIE  = 0x00000008,
    MSTATUS_MPIE = 0x00000080,

    MIP_MSIP = 0x00000008,
    MIP_MTIP = 0x00000080,
    MIP_MEIP = 0x00000800,

    MIE_MSIE = 0x00000008,
    MIE_MTIE = 0x00000080,
    MIE_MEIE = 0x00000800,
}

local CAUSE = {
    MSIE = 3,
    MTIE = 7,
    MEIE = 11
}

---Create CSR block.
---@param _target any  -- not used now, kept for symmetry
function CSR:new(_target)
    local self_ = {
        mstatus = 0,
        mie = 0,
        mip = 0,
        mepc = 0,
        mcause = 0,
        mcause_interrupt = false
    }
    return setmetatable(self_, CSR)
end

function CSR:get_bits(val, mask) return (bit32.band(val, mask) ~= 0) end
function CSR:set_bits(val, mask, on)
    if on then return bit32.bor(val, mask) else return bit32.band(val, bit32.bnot(mask)) end
end

-- Global enable/disable
function CSR:enable_mie(on) self.mstatus = self:set_bits(self.mstatus, BITS.MSTATUS_MIE, on and true or false) end

-- IE bits control
function CSR:enable_msie(on) self.mie = self:set_bits(self.mie, BITS.MIE_MSIE, on and true or false) end
function CSR:enable_mtie(on) self.mie = self:set_bits(self.mie, BITS.MIE_MTIE, on and true or false) end
function CSR:enable_meie(on) self.mie = self:set_bits(self.mie, BITS.MIE_MEIE, on and true or false) end

-- Pending bits update (from devices)
function CSR:set_mip(kind, on)
    local m = self.mip
    if kind == "msip" then
        m = self:set_bits(m, BITS.MIP_MSIP, on)
    elseif kind == "mtip" then
        m = self:set_bits(m, BITS.MIP_MTIP, on)
    elseif kind == "meip" then
        m = self:set_bits(m, BITS.MIP_MEIP, on)
    end
    self.mip = m
end

function CSR:is_global_enabled() return self:get_bits(self.mstatus, BITS.MSTATUS_MIE) end
function CSR:is_enabled_and_pending(mask, bit) return self:get_bits(self.mie, bit) and self:get_bits(self.mip, bit) end

-- Return highest-priority pending enabled IRQ cause or nil.
function CSR:should_take_interrupt()
    if not self:is_global_enabled() then return nil end
    -- Priority: MEIP > MTIP > MSIP (Machine-level)
    if self:is_enabled_and_pending(self.mie, BITS.MIE_MEIE) and self:get_bits(self.mip, BITS.MIP_MEIP) then return CAUSE.MEIE end
    if self:is_enabled_and_pending(self.mie, BITS.MIE_MTIE) and self:get_bits(self.mip, BITS.MIP_MTIP) then return CAUSE.MTIE end
    if self:is_enabled_and_pending(self.mie, BITS.MIE_MSIE) and self:get_bits(self.mip, BITS.MIP_MSIP) then return CAUSE.MSIE end
    return nil
end

-- Trap entry per RISC-V rules (simplified): MPIE <= MIE, MIE <= 0
function CSR:trap_enter(cause, is_interrupt)
    -- Save MIE into MPIE, then clear MIE
    local mie_on = self:is_global_enabled()
    self.mstatus = self:set_bits(self.mstatus, BITS.MSTATUS_MPIE, mie_on)
    self.mstatus = self:set_bits(self.mstatus, BITS.MSTATUS_MIE, false)
    -- We don't model PC; store cause only
    self.mcause, self.mcause_interrupt = cause, is_interrupt and true or false
end

-- Return from machine mode trap (mret)
function CSR:mret()
    local mpie_on = self:get_bits(self.mstatus, BITS.MSTATUS_MPIE)
    -- MIE <= MPIE; MPIE <= 1
    self.mstatus = self:set_bits(self.mstatus, BITS.MSTATUS_MIE, mpie_on)
    self.mstatus = self:set_bits(self.mstatus, BITS.MSTATUS_MPIE, true)
    -- Clear cause for clarity (optional)
    self.mcause, self.mcause_interrupt = 0, false
end

return {
    CSR = CSR,
    BITS = BITS,
    CAUSE = CAUSE
}