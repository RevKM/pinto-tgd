-- Each character's own activity this week, kept locally for its quests:
-- group sessions, quest turn-ins, level-ups, gathering and trades.
--
-- PintoTGD_DB.log[full name] = { week, groups, turnins, levels, gathers, trades }
--   groups[i]  = { day, act, inst, start, last, members = {name=true}, present = {name=true},
--                  bosses, final, finalMembers = {name=true}, bandaged = {name=true} }
--   turnins[i] = { day, quest, group, guildies = {name=true} }
--   levels[i]  = { day, guildies = {name=true} }
--   gathers[i] = { day, kind, count, guildies = {name=true} }
--   trades[i]  = { day, time, dir ("out"/"in"), who, kind, item, count, tags = {} }
--   moments[i] = { day, kind, count, guildies = {name=true} }: a campfire lit, a dance
--                together, a member invited who joined, something put in the guild bank
--   invited    = { [full name] = server time }: who this character invited to the guild
-- A log from before moments and invited came gets them when they're first needed.
local ADDON, ns = ...

local Log = {}
ns.Log = Log

local Time = ns.Time

function Log.For(name, week)
  local d = PintoTGD_DB
  d.log = d.log or {}
  week = week or Time.week(Time.day())
  local l = d.log[name]
  if not l or l.week ~= week then
    l = { week = week, groups = {}, turnins = {}, levels = {}, gathers = {}, trades = {} }
    d.log[name] = l
  end
  return l
end

function Log.Mine()
  return Log.For(ns.me)
end

local function set(list)
  local s = {}
  for name in pairs(list) do s[name] = true end
  return s
end
Log.set = set

function Log.AddTurnin(quest, isGroup, guildies)
  local l = Log.Mine()
  l.turnins[#l.turnins + 1] = { day = Time.day(), quest = quest, group = isGroup and true or false, guildies = set(guildies) }
  ns.Events.Fire("PINTO_LOG")
end

function Log.AddLevel(guildies)
  local l = Log.Mine()
  l.levels[#l.levels + 1] = { day = Time.day(), guildies = set(guildies) }
  ns.Events.Fire("PINTO_LOG")
end

function Log.AddGather(kind, count, guildies)
  local l = Log.Mine()
  l.gathers[#l.gathers + 1] = { day = Time.day(), kind = kind, count = count or 1, guildies = set(guildies) }
  ns.Events.Fire("PINTO_LOG")
end

function Log.AddTrade(dir, who, kind, item, count, tags)
  local l = Log.Mine()
  l.trades[#l.trades + 1] = { day = Time.day(), time = Time.now(), dir = dir, who = who, kind = kind,
    item = item, count = count or 1, tags = tags or {} }
  ns.Events.Fire("PINTO_LOG")
end

-- A character's moments this week (empty for a log from before they were kept).
function Log.Moments(l)
  l.moments = l.moments or {}
  return l.moments
end

function Log.AddMoment(kind, guildies, count)
  local moments = Log.Moments(Log.Mine())
  moments[#moments + 1] = { day = Time.day(), kind = kind, count = count or 1, guildies = set(guildies or {}) }
  ns.Events.Fire("PINTO_LOG")
end

-- Who this character invited to the guild this week, and when.
function Log.Invited()
  local l = Log.Mine()
  l.invited = l.invited or {}
  return l.invited
end

-- Back inside a dungeon or raid left less than half an hour ago, the same day and with its
-- final boss still standing: that run's session, to carry on with. A wipe and the run
-- back, or a trip outside, doesn't split a run in two.
local RESUME = 1800
local function resumable(l, act, inst, today)
  local ACT = ns.Pieces.ACT
  if act ~= ACT.dungeon and act ~= ACT.raid then return nil end
  for i = #l.groups, math.max(1, #l.groups - 20), -1 do
    local s = l.groups[i]
    if s.day == today and s.inst == inst and s.act == act and not s.final and Time.now() - s.last <= RESUME then
      table.remove(l.groups, i)
      l.groups[#l.groups + 1] = s
      s.closed = nil
      return s
    end
  end
  return nil
end

-- The open group session, started when guildies join and ended when they're gone,
-- the instance changes or a new day starts.
function Log.Session(act, inst)
  local l = Log.Mine()
  local s = l.groups[#l.groups]
  local today = Time.day()
  if not s or s.closed or s.day ~= today or s.inst ~= inst then
    if s then s.closed = true end
    s = resumable(l, act, inst, today)
    if not s then
      s = { day = today, act = act, inst = inst, start = Time.now(), last = Time.now(),
        members = {}, present = {}, bosses = 0, final = false, finalMembers = {}, bandaged = {} }
      l.groups[#l.groups + 1] = s
    end
  end
  return s
end

function Log.CloseSession()
  local l = Log.Mine()
  local s = l.groups[#l.groups]
  if s and not s.closed then
    s.closed = true
    ns.Events.Fire("PINTO_LOG")
  end
end

function Log.OpenSession()
  local l = Log.Mine()
  local s = l.groups[#l.groups]
  if s and not s.closed then return s end
end
