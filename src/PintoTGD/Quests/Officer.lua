-- The officer corner's logic: voiding completions, excluding a player, picking officer
-- ranks, and the notifications. Flags are hints to start a friendly chat, not
-- automatic punishments.
local ADDON, ns = ...

local Officer = {}
ns.Officer = Officer

local Store, Pieces, People, Util, Time, Events, Roster = ns.Store, ns.Pieces, ns.People, ns.Util, ns.Time, ns.Events, ns.Roster

local BURST_WINDOW = 300
local BURST_COUNT = 3
local WITNESS_WAIT = 48 * 3600

local caughtUp = {}  -- done keys that arrived by catch-up instead of live

function Officer.IsOfficer()
  return ns.me ~= nil and Roster.IsOfficer(ns.me)
end

local function write(key, value)
  if not Officer.IsOfficer() then return false end
  return Store.SetSetting(key, value, Time.now(), ns.Player.AccountId(), ns.me)
end

-- Tools ---------------------------------------------------------------------------------

function Officer.VoidWeek(playerKey, week, on)
  return write("voidp:" .. playerKey .. ":" .. string.format("%d", week), on and "1" or "0")
end

function Officer.Exclude(playerKey, on)
  return write("excl:" .. playerKey, on and "1" or "0")
end

-- Only the guild master picks officer ranks. ranks: list of rank indices.
function Officer.SetRanks(ranks)
  if not Roster.IsGuildMaster(ns.me) then return false end
  local parts = {}
  for _, r in ipairs(ranks) do parts[#parts + 1] = string.format("%d", r) end
  return Store.SetSetting("ranks", table.concat(parts, ","), Time.now(), ns.Player.AccountId(), ns.me)
end

-- Notifications ---------------------------------------------------------------------------

local function nameOf(id)
  local n = People.Name(id)
  return n and ns.Compat.ShortName(n) or "someone"
end

-- Every flag for the current and last week: { kind, text, time }.
function Officer.Flags()
  local flags = {}
  local now = Time.now()
  local week = Time.week(Time.day())
  for w = week - 1, week do
    local wp = Store.get(Pieces.id("w", w))
    if wp then
      -- bursts: several quests completed within a few minutes
      local byChar = {}
      for _, rec in pairs(wp.done) do
        byChar[rec.char] = byChar[rec.char] or {}
        table.insert(byChar[rec.char], rec.time)
      end
      for charId, times in pairs(byChar) do
        table.sort(times)
        for i = BURST_COUNT, #times do
          if times[i] - times[i - BURST_COUNT + 1] <= BURST_WINDOW then
            flags[#flags + 1] = { kind = "burst", time = times[i],
              text = string.format("%s finished %d quests within %d minutes.", nameOf(charId), BURST_COUNT, BURST_WINDOW / 60) }
            break
          end
        end
      end
      -- no witness: nobody else in the group confirmed it, 48 hours on
      for key, rec in pairs(wp.done) do
        if now - rec.time > WITNESS_WAIT then
          local reporters = 0
          for _ in pairs(rec.rep) do reporters = reporters + 1 end
          local others = 0
          local mine = People.PlayerOf(rec.char)
          for _, m in ipairs(rec.members) do
            local k = People.PlayerOf(m)
            if k ~= mine and People.IsAddonPlayer(k) then others = others + 1 end
          end
          if reporters <= 1 and others > 0 then
            flags[#flags + 1] = { kind = "witness", time = rec.time,
              text = string.format("Nobody in %s's group confirmed one of their quests.", nameOf(rec.char)) }
          end
        end
        if caughtUp[key] then
          flags[#flags + 1] = { kind = "trace", time = rec.time,
            text = string.format("%s's quest showed up after a reload without being shared live.", nameOf(rec.char)) }
        end
      end
    end
  end
  table.sort(flags, function(a, b) return a.time > b.time end)
  return flags
end

-- No live trace: a completion that arrived by catch-up although this addon was online
-- and synced when it was made.
local onlineSince = nil
local function onData(id, origin)
  if origin ~= "remote" or not id or id:sub(1, 1) ~= "w" then return end
  if ns.Protocol.receiving ~= "catchup" or not onlineSince then return end
  local wp = Store.get(id)
  for key, rec in pairs(wp and wp.done or {}) do
    if not caughtUp[key] and rec.time > onlineSince + 300 and Time.now() - rec.time > 120
      and People.PlayerOf(rec.char) ~= People.PlayerOf(Util.nameId(ns.me)) then
      caughtUp[key] = true
    end
  end
end

function Officer.Init()
  Events.On("PINTO_SYNC_STATE", function(state)
    if state == "synced" and not onlineSince then onlineSince = Time.now() end
  end)
  Events.On("PINTO_DATA_CHANGED", onData)
end
