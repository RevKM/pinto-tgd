-- Server days and weeks. A day runs from 03:00 to 03:00 server time, a week from
-- Monday 03:00. Every addon must land on the same day number, so this uses the server's
-- clock (GetServerTime, UTC seconds) and one fixed timezone rule: Central European Time
-- with EU summer time, as EU realms use. The guild's Forever realm keeps that time: its
-- clock read UTC+1 in November. (The game's own resets, 05:00 daily and Wednesday
-- weekly, play no part.)
local ADDON, ns = ...

local Time = {}
ns.Time = Time

local floor = math.floor
local DAY = 86400
local DAY_START = 3 * 3600

Time.DAY = DAY

-- Days since 1970-01-01 for a calendar date (proleptic Gregorian).
local function daysFromCivil(y, m, d)
  if m <= 2 then y = y - 1 end
  local era = floor(y / 400)
  local yoe = y - era * 400
  local mp = (m + 9) % 12
  local doy = floor((153 * mp + 2) / 5) + d - 1
  local doe = yoe * 365 + floor(yoe / 4) - floor(yoe / 100) + doy
  return era * 146097 + doe - 719468
end
Time.daysFromCivil = daysFromCivil

local function civilFromDays(z)
  z = z + 719468
  local era = floor(z / 146097)
  local doe = z - era * 146097
  local yoe = floor((doe - floor(doe / 1460) + floor(doe / 36524) - floor(doe / 146096)) / 365)
  local y = yoe + era * 400
  local doy = doe - (365 * yoe + floor(yoe / 4) - floor(yoe / 100))
  local mp = floor((5 * doy + 2) / 153)
  local d = doy - floor((153 * mp + 2) / 5) + 1
  local m = mp < 10 and mp + 3 or mp - 9
  if m <= 2 then y = y + 1 end
  return y, m, d
end
Time.civilFromDays = civilFromDays

-- 0 = Sunday .. 6 = Saturday. 1970-01-01 was a Thursday.
local function weekday(days) return (days + 4) % 7 end

local function lastSunday(y, m)
  local nextFirst = m == 12 and daysFromCivil(y + 1, 1, 1) or daysFromCivil(y, m + 1, 1)
  local last = nextFirst - 1
  return last - weekday(last)
end

Time.STANDARD_OFFSET = 3600

-- The server's offset from UTC at a moment: +1 hour, or +2 from 01:00 UTC on the last
-- Sunday of March until 01:00 UTC on the last Sunday of October.
function Time.offset(utc)
  local y = civilFromDays(floor(utc / DAY))
  local summerStart = lastSunday(y, 3) * DAY + 3600
  local summerEnd = lastSunday(y, 10) * DAY + 3600
  if utc >= summerStart and utc < summerEnd then return Time.STANDARD_OFFSET + 3600 end
  return Time.STANDARD_OFFSET
end

function Time.now()
  return GetServerTime()
end

-- The game day a moment belongs to, counted from 1970-01-01.
function Time.day(utc)
  utc = utc or Time.now()
  return floor((utc + Time.offset(utc) - DAY_START) / DAY)
end

-- The moment (UTC seconds) a game day starts: 03:00 server time on that date.
function Time.dayStart(day)
  local localStart = day * DAY + DAY_START
  return localStart - Time.offset(localStart - Time.STANDARD_OFFSET)
end

-- Weeks start on Monday. 1970-01-05 was the first Monday, which is day 4 and week 1.
function Time.week(day)
  return floor((day + 3) / 7)
end

function Time.weekStartDay(week)
  return week * 7 - 3
end

-- The game day starting at 03:00 on an ISO date "YYYY-MM-DD".
function Time.dayOfDate(iso)
  local y, m, d = (iso or ""):match("^(%d+)-(%d+)-(%d+)$")
  if not y then return nil end
  return daysFromCivil(tonumber(y), tonumber(m), tonumber(d))
end

function Time.dateOfDay(day)
  local y, m, d = civilFromDays(day)
  return string.format("%04d-%02d-%02d", y, m, d)
end

function Time.goLiveDay()
  return Time.dayOfDate(ns.Build.goLive)
end

function Time.isLive(utc)
  return Time.day(utc) >= Time.goLiveDay()
end

-- Server-time hour of day, 0..23.
function Time.hour(utc)
  utc = utc or Time.now()
  return floor(((utc + Time.offset(utc)) % DAY) / 3600)
end

function Time.secondsToWeekReset(utc)
  utc = utc or Time.now()
  local nextWeek = Time.week(Time.day(utc)) + 1
  return Time.dayStart(Time.weekStartDay(nextWeek)) - utc
end

-- "3 days and 7 hours", "1 day and 1 hour", only hours on the last day.
-- Returns nil under an hour, where the caller says "less than an hour".
function Time.countdown(seconds)
  if seconds < 3600 then return nil end
  local hours = floor(seconds / 3600)
  local days = floor(hours / 24)
  hours = hours % 24
  local Util = ns.Util
  if days == 0 then return Util.plural(hours, "hour") end
  if hours == 0 then return Util.plural(days, "day") end
  return Util.plural(days, "day") .. " and " .. Util.plural(hours, "hour")
end
