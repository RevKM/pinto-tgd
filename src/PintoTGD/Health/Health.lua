-- Pinto's state from day to day: the daily H history, the calibration week, too few
-- players, wealth, today's feeding and the mood status.
local ADDON, ns = ...

local Health = {}
ns.Health = Health

local Store, Pieces, Formula, Util, Time, Events = ns.Store, ns.Pieces, ns.Formula, ns.Util, ns.Time, ns.Events

local CALIBRATION_DAYS = 7
local HOLD_DAYS = 7
local SLIM_PER_DAY = 0.02
local SLIM_FLOOR = 0.2
local KEEP_DAYS = 14 -- history older than this is frozen
local RECOMPUTE_GAP = 30

local function round(x) return math.floor(x + 0.5) end

-- Daily history --------------------------------------------------------------------

local function entryFor(t)
  local c = Formula.Compute(t)
  local e = { N = math.min(255, c.N), fv = ns.Build.formulaVersion,
    data = math.min(4294967295, c.data), H = 0, W = 0, Q = 0, G = 0, P = 0, T = 0, K = 0 }
  if c.H then
    e.H = Util.clamp(round(c.H * 100), 0, 10000)
    for _, f in ipairs({ "Q", "G", "P", "T", "K" }) do
      e[f] = Util.clamp(round(c[f] * 10000), 0, 10000)
    end
  end
  e.W = Util.clamp(round(Formula.Wealth(t, c) * 10000), 0, 10000)
  return e, c
end

local stale = {}       -- days whose H needs recalculating
local lastRun = -1000

function Health.MarkStale(day)
  local today = Time.day()
  local first = math.max(Time.goLiveDay(), today - KEEP_DAYS + 1)
  for t = math.max(first, day + 1), math.min(today, day + 7) do stale[t] = true end
end

-- Recalculates the stale days, one per call, newest first. Returns true while more wait.
function Health.Step()
  local today = Time.day()
  if today < Time.goLiveDay() then return false end
  local best
  for t in pairs(stale) do
    if not best or t > best then best = t end
  end
  if not best then return false end
  stale[best] = nil
  if best < today - KEEP_DAYS + 1 then return next(stale) ~= nil end
  local e, c = entryFor(best)
  Store.SetHistory(best, e)
  if best == today then Health.today, Health.todayDay = c, today end
  return next(stale) ~= nil
end

-- The hoard's two halves for the windows: gear (the median g) and gold (B), 0..1 each.
-- Worked out when a window asks, and again after new data or a new day.
local wealthCache
function Health.WealthParts(today)
  today = today or Time.day()
  if not wealthCache or wealthCache.day ~= today then
    local c = Health.todayDay == today and Health.today or nil
    local gear, gold = Formula.WealthParts(today, c)
    wealthCache = { day = today, gear = gear or 0, gold = gold or 0 }
  end
  return wealthCache.gear, wealthCache.gold
end

-- What the windows say about them: a general word, and 1 to 5 coins. Never the numbers.
Health.GEAR_WORDS = { "Threadbare", "Patched up", "Well kitted", "Gleaming" }
Health.GOLD_WORDS = { "Scraping by", "Getting by", "Comfortable", "Rolling in gold" }

function Health.WealthWord(v, words)
  return words[math.min(#words, math.floor(math.max(0, v) * #words) + 1)]
end

function Health.WealthLevel(v)
  return math.min(5, math.floor(math.max(0, v) * 5) + 1)
end

local running = false   -- a recalculation is under way

local function schedule()
  if GetTime() - lastRun < RECOMPUTE_GAP then return end
  lastRun = GetTime()
  local function run()
    running = true
    if Health.Step() then
      ns.After(0.5, run)
    else
      running = false
      Events.Fire("PINTO_HEALTH")
    end
  end
  run()
end

-- Whether Pinto's numbers are being recalculated right now.
function Health.Busy() return running end

-- Every missing or possibly outdated day of the last two weeks.
function Health.MarkRecent()
  local today = Time.day()
  local first = math.max(Time.goLiveDay(), today - KEEP_DAYS + 1)
  for t = first, today do stale[t] = true end
end

function Health.Entry(day)
  local h = Store.get("h")
  return h and h.days[day]
end

-- Calibration ------------------------------------------------------------------------
-- Days 1-7 Pinto sleeps at weight 0.5. From day 8 the real H takes over, on the first day
-- at least 6 guildies with the addon are active. Until then the calibration runs on.

-- The day Pinto wakes up (at 03:00): 7 days after go-live, unless the build sets its own
-- wake-up day (Build.wakeUp, a date in server time).
function Health.WakeDay()
  local wake = ns.Build.wakeUp and Time.dayOfDate(ns.Build.wakeUp)
  return wake or (Time.goLiveDay() + CALIBRATION_DAYS)
end

function Health.CalibrationEnd()
  local h = Store.get("h")
  if not h then return nil end
  local from = Health.WakeDay()
  local first
  for d, e in pairs(h.days) do
    if d >= from and e.N >= Formula.MIN_N and (not first or d < first) then first = d end
  end
  return first
end

function Health.InCalibration(today)
  today = today or Time.day()
  local done = Health.CalibrationEnd()
  return not done or today < done
end

-- The moment the calibration week ends.
function Health.CalibrationWeekEnd()
  return Time.dayStart(Health.WakeDay())
end

-- Weight -------------------------------------------------------------------------------
-- Returns weight (0..1), wealth (0..1) and the state: "before", "calibration", "long"
-- (calibration running on), "normal" or "missing" (fewer than 6 after calibration).

function Health.Shape(today)
  today = today or Time.day()
  if today < Time.goLiveDay() then return 0.5, 0, "before" end
  local entry = Health.Entry(today)
  local wealth = entry and entry.W / 10000
  if not wealth then
    local prev = Health.Entry(today - 1)
    wealth = prev and prev.W / 10000 or 0
  end
  if Health.InCalibration(today) then
    local state = today >= Health.WakeDay() and "long" or "calibration"
    return 0.5, wealth, state
  end
  if entry and entry.N >= Formula.MIN_N then return entry.H / 10000, wealth, "normal" end
  -- too few players: keep the last H for 7 days, then slim down to Thin
  local last, lastDay
  local stop = Health.CalibrationEnd() or today
  for d = today - 1, stop, -1 do
    local e = Health.Entry(d)
    if e and e.N >= Formula.MIN_N then
      last, lastDay = e.H / 10000, d
      break
    end
  end
  if not last then return 0.5, wealth, "missing" end
  local gap = today - lastDay
  local weight = last
  if gap > HOLD_DAYS and last > SLIM_FLOOR then
    weight = math.max(SLIM_FLOOR, last - SLIM_PER_DAY * (gap - HOLD_DAYS))
  end
  return weight, wealth, "missing"
end

-- Feeding and mood -------------------------------------------------------------------

local BANDS = { 0.12, 0.32, 0.62, 0.85 }
Health.LABELS = { "Starving", "Thin", "Healthy", "Chubby", "Very fat" }
Health.MOODS = { "Despair", "Sad", "Content", "Happy", "Proud" }

function Health.Band(weight)
  for i, top in ipairs(BANDS) do
    if weight < top then return i end
  end
  return 5
end

-- [band][feeding]: 1 hungry, 2 fed, 3 feast
local LINES = {
  {
    "Famished and forlorn... dreaming of Dragonbreath Chili.",
    "Weak, but grateful for every crumb.",
    "Overjoyed to be fed! The color's coming back to those scales.",
  },
  {
    "Sorrowful and hungry... that tummy rumbles like a kodo stampede.",
    "Nibbling hopefully. A few more feasts and he'll perk right up!",
    "Thankful, but still hungry. Every bite helps!",
  },
  {
    "Doing alright, though the tummy's starting to grumble.",
    "Content and cozy atop the gold.",
    "Full and fired up! Ready to guard the hoard all night.",
  },
  {
    "A little hungry, but still happy! Is that a haunch in your bags?",
    "Happy as a gnome in a gear shop.",
    "Gluttonously happy! *Burps proudly in your direction.*",
  },
  {
    "Peckish, but far too proud of you lot to complain.",
    "Plump, proud and perfectly pleased.",
    "Magnificently stuffed! Can't even see the hoard past this belly.",
  },
}

-- Feeding = haunches earned today ÷ (characters that played today with the addon ×
-- the average haunches per character per day).
function Health.Feeding(today)
  today = today or Time.day()
  local Quests = ns.Quests
  local wp = Store.get(Pieces.id("w", Time.week(today)))
  local earned, totalWorth, sets = 0, 0, 0
  local from, to = Time.dayStart(today), Time.dayStart(today + 1)
  if wp and Quests then
    for _, rec in pairs(wp.done) do
      if rec.time >= from and rec.time < to and not Quests.IsVoided(rec.char, wp.num) then
        earned = earned + Quests.EarnedOf(wp, rec)
      end
    end
    for charId in pairs(wp.sets) do
      local sum = 0
      for slot = 1, 4 do sum = sum + Quests.WorthOf(wp, charId, slot) end
      totalWorth = totalWorth + sum
      sets = sets + 1
    end
  end
  local perDay = sets > 0 and totalWorth / sets / 7 or 1
  local dp = Store.get(Pieces.id("d", today))
  local players = 0
  if dp then
    for _ in pairs(dp.played) do players = players + 1 end
  end
  if players == 0 or perDay <= 0 then return 0 end
  return earned / (players * perDay)
end

function Health.FeedingLevel(feeding)
  if feeding < 0.5 then return 1 end
  if feeding <= 1.2 then return 2 end
  return 3
end

function Health.MoodLine(weight, feeding)
  return LINES[Health.Band(weight)][Health.FeedingLevel(feeding)]
end

-- The start notice's short versions, [band][feeding] like the mood lines.
local SHORT = {
  { "Pinto is famished...", "Pinto is weak, but grateful", "Pinto is overjoyed!" },
  { "Pinto is hungry", "Pinto is hopeful", "Pinto is thankful" },
  { "Pinto is hungry", "Pinto is content", "Pinto is full and fired up!" },
  { "Pinto is hungry", "Pinto is happy", "Pinto is gluttonously happy!" },
  { "Pinto is peckish", "Pinto is proud", "Pinto is stuffed!" },
}

function Health.ShortMood(weight, feeding)
  return SHORT[Health.Band(weight)][Health.FeedingLevel(feeding)]
end

-- The start notice's other lines
Health.NOTICE = {
  quests = "There are new Pinto quests for you!",
  asleep = "Pinto is snoozing on the hoard",
  gaining = "Pinto is gaining girth!",
  losing = "Pinto is losing girth...",
}

-- Special lines
Health.TEXT = {
  calibration = "Snoozing on the hoard while the feast piles up.",
  long = "Still snoozing until the gang's all here. Pinto wakes up when 6 guildies with the addon have played on 2 of the last 7 days.",
  missing = "Missing the gang! Pinto can only see how the guild's doing once 6 guildies with the addon have played on 2 of the last 7 days.",
  syncing = "Syncing data…",
  alone = "Waiting for a guildie to sync with…",
  trial = "Pinto can't hear you yet! Trial and lapsed accounts can't send addon messages, so you can join in once your account is fully active.",
  -- the small window's shorter versions
  longShort = "Still snoozing until the gang's all here.",
  trialShort = "Pinto can't hear you yet: trial and lapsed accounts can't join in.",
}

function Health.ArrivesText(now)
  now = now or Time.now()
  local left = Time.dayStart(Time.goLiveDay()) - now
  local text = Time.countdown(left)
  if not text then return "Pinto arrives in less than an hour!" end
  return "Pinto arrives in " .. text .. "!"
end

function Health.AwakesText(now)
  now = now or Time.now()
  local text = Time.countdown(Health.CalibrationWeekEnd() - now)
  if not text then return "Pinto awakes in less than an hour" end
  return "Pinto awakes in " .. text
end

function Health.Init()
  Events.On("PINTO_DATA_CHANGED", function(id)
    if not id then return end
    local letter = id:sub(1, 1)
    if letter ~= "h" and letter ~= "w" then wealthCache = nil end
    if letter == "d" then
      Health.MarkStale(tonumber(id:sub(2)))
    elseif letter == "p" or letter == "j" then
      Health.MarkStale(Time.day() - 1)
    elseif letter == "h" then
      Events.Fire("PINTO_HEALTH")
    end
  end)
  Events.On("PINTO_SYNCED", function()
    Health.MarkRecent()
    schedule()
  end)
  ns.Every(30, function()
    -- a new day starts at 03:00: make sure today gets its H
    if not Health.Entry(Time.day()) then stale[Time.day()] = true end
    if next(stale) then schedule() end
  end)
  Health.MarkRecent()
  ns.After(15, schedule)
end
