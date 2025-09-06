-- firmware/runtimeservices/time.lua
-- UEFI Runtime Services: Time and Reset (stubbed, realistic behavior).
-- Provides:
--   get_time() -> table {Year,Month,Day,Hour,Minute,Second,Nanosecond,TimeZone,Daylight}
--   set_time(tbl)  -- sets an offset so subsequent get_time reflects new value
--   set_timezone(minutes_west), set_daylight(flags)
--   reset_system(kind, status, data) -- non-returning stub: throws an error.

local RTTime = {}
RTTime.__index = RTTime

-- Helpers: choose a time base
local function now_utc_ms()
    if type(os.epoch) == "function" then
        return os.epoch("utc") -- ms since epoch
    end
    if type(os.clock) == "function" then
        return math.floor(os.clock() * 1000)
    end
    return 0
end

local function is_leap(y)
    if (y % 400) == 0 then return true end
    if (y % 100) == 0 then return false end
    return (y % 4) == 0
end

local dim = {31,28,31,30,31,30,31,31,30,31,30,31}
local function days_in_month(y,m)
    if m == 2 then return is_leap(y) and 29 or 28 end
    return dim[m]
end

-- Convert Y-M-D to days since 1970-01-01
local function days_from_civil(y,m,d)
    -- Shift months so March=1..February=12 to simplify leap handling
    local y1 = y
    local m1 = m
    if m1 <= 2 then
        y1 = y1 - 1
        m1 = m1 + 12
    end
    local era = math.floor(y1 / 400)
    local yoe = y1 - era * 400
    local doy = math.floor((153 * (m1 - 3) + 2) / 5) + d - 1
    local doe = yoe * 365 + math.floor(yoe / 4) - math.floor(yoe / 100) + doy
    return era * 146097 + doe - 719468  -- days since 1970-01-01
end

-- Convert days since epoch to Y-M-D
local function civil_from_days(z)
    z = z + 719468
    local era = math.floor(z / 146097)
    local doe = z - era * 146097
    local yoe = math.floor((400 * doe + 591) / 146097)
    local doy = doe - (365 * yoe + math.floor(yoe / 4) - math.floor(yoe / 100))
    local mp = math.floor((5 * doy + 2) / 153)
    local d = doy - math.floor((153 * mp + 2) / 5) + 1
    local m = mp + 3
    local y = era * 400 + yoe
    if m > 12 then
        m = m - 12
        y = y + 1
    end
    return y, m, d
end

local function epoch_from_ymdhms(y,mo,d,h,mi,s,tz_minutes)
    -- tz_minutes is minutes west of UTC (UEFI semantics), so subtract to get UTC
    local seconds = (days_from_civil(y,mo,d) * 86400) + h*3600 + mi*60 + s
    if tz_minutes then seconds = seconds + (tz_minutes * 60) end
    return seconds
end

local function ymdhms_from_epoch(sec, tz_minutes)
    if tz_minutes then sec = sec - (tz_minutes * 60) end
    local days = math.floor(sec / 86400)
    local r    = sec - days * 86400
    if r < 0 then
        days = days - 1
        r = r + 86400
    end
    local h = math.floor(r / 3600); r = r - h * 3600
    local mi= math.floor(r / 60);   r = r - mi * 60
    local s = math.floor(r)
    local y, m, d = civil_from_days(days)
    return y, m, d, h, mi, s
end

---Create time service
---@param _cpu any|nil  -- not required now, kept for symmetry
---@param opts { timezone?: integer, daylight?: integer }|nil
function RTTime:new(_cpu, opts)
    opts = opts or {}
    local self_ = {
        -- Offset added to the "now" epoch seconds. set_time updates this.
        offset_sec = 0,
        timezone   = opts.timezone or 0, -- minutes west of UTC (UEFI semantics)
        daylight   = opts.daylight or 0  -- bitmask; we don’t manipulate daylight rules here
    }
    return setmetatable(self_, RTTime)
end

---Get current time (UEFI-like fields)
function RTTime:get_time()
    local now_sec = math.floor(now_utc_ms() / 1000) + self.offset_sec
    local y, m, d, h, mi, s = ymdhms_from_epoch(now_sec, self.timezone)
    return {
        Year = y, Month = m, Day = d,
        Hour = h, Minute = mi, Second = s,
        Nanosecond = 0,
        TimeZone = self.timezone,
        Daylight = self.daylight
    }
end

---Set time (computes offset so that get_time() returns this value subsequently)
---@param t table  -- {Year,Month,Day,Hour,Minute,Second,TimeZone?,Daylight?}
function RTTime:set_time(t)
    assert(t and t.Year and t.Month and t.Day and t.Hour ~= nil and t.Minute ~= nil and t.Second ~= nil,
        "set_time: require Year,Month,Day,Hour,Minute,Second")
    local tz = (t.TimeZone ~= nil) and t.TimeZone or self.timezone
    local target = epoch_from_ymdhms(t.Year, t.Month, t.Day, t.Hour, t.Minute, t.Second, tz)
    local now = math.floor(now_utc_ms() / 1000)
    self.offset_sec = target - now
    if t.TimeZone ~= nil then self.timezone = t.TimeZone end
    if t.Daylight ~= nil then self.daylight = t.Daylight end
end

function RTTime:set_timezone(minutes_west) self.timezone = minutes_west or 0 end
function RTTime:set_daylight(flags) self.daylight = flags or 0 end

---ResetSystem stub (non-returning). kind: "cold"|"warm"|"shutdown"|"platform"
---@param kind string
---@param status integer|nil
---@param data any|nil
function RTTime:reset_system(kind, status, data)
    error(string.format("RESET: kind=%s status=%s data=%s", tostring(kind), tostring(status), tostring(data or "")), 0)
end

---Return ISO 8601 UTC string for convenience
function RTTime:to_iso8601()
    local t = self:get_time()
    return string.format("%04d-%02d-%02dT%02d:%02d:%02dZ",
        t.Year, t.Month, t.Day, t.Hour, t.Minute, t.Second)
end

return RTTime