-- The guild roster: who's in the guild and online, join dates, the founding register,
-- alt notes and officer ranks.
local ADDON, ns = ...

local Roster = {}
ns.Roster = Roster

local Compat, Store, Pieces, Util, Time, Events = ns.Compat, ns.Store, ns.Pieces, ns.Util, ns.Time, ns.Events
local JOIN = Pieces.JOIN

Roster.members = {}   -- full name -> { name, rankIndex, level, note, online, class, lastOnlineDays }
Roster.loaded = false
local lastScan = -100
local seenNotedDay = nil

function Roster.IsMember(name)
  -- until the roster has loaded, accept everyone: data is still validated on its own
  if not Roster.loaded then return true end
  return Roster.members[name] ~= nil
end

function Roster.IsOnline(name)
  local m = Roster.members[name]
  return m ~= nil and m.online
end

function Roster.Get(name)
  return Roster.members[name]
end

function Roster.Names()
  return Util.sortedKeys(Roster.members, Util.byteLess)
end

function Roster.Scan()
  local total = Compat.NumRoster()
  if total == 0 then return false end
  local members = {}
  for i = 1, total do
    local e = Compat.RosterEntry(i)
    if e and e.name then members[e.name] = e end
  end
  Roster.members = members
  Roster.loaded = true
  lastScan = GetTime()
  Roster.altCache = nil
  Events.Fire("PINTO_ROSTER", members)
  return true
end

-- Join dates ------------------------------------------------------------------------

-- The day of the earliest founding register: only that register counts.
function Roster.FoundingDay()
  local j = Store.get("j")
  if not j then return nil end
  local first
  for _, e in pairs(j.entries) do
    if e.how == JOIN.founding and (not first or e.day < first) then first = e.day end
  end
  return first
end

-- { day, founding } for a character, from the merged join entries.
function Roster.JoinInfo(nameId)
  local j = Store.get("j")
  local e = j and j.entries[nameId]
  if not e then return nil end
  local founding = e.how == JOIN.founding and e.day == Roster.FoundingDay()
  return { day = e.day, founding = founding, name = e.name }
end

-- The first addon to run after go-live records everyone in the roster as founding
-- members. It waits for the first sync so it doesn't start a second register.
function Roster.MaybeFound()
  if not Roster.loaded or not Time.isLive() then return end
  if Roster.FoundingDay() then return end
  local today = Time.day()
  local entries = {}
  for name in pairs(Roster.members) do
    entries[#entries + 1] = { name = name, day = today, how = JOIN.founding }
  end
  if #entries > 0 then
    Store.NoteJoins(entries, today)
    ns.Debug("recorded the founding register: %d members", #entries)
  end
end

-- Everyone in the roster was seen today. Anyone without a join date gets today, as a
-- missed join; earlier dates always win in the merge.
function Roster.NoteSeen()
  if not Roster.loaded or not Time.isLive() then return end
  local today = Time.day()
  if seenNotedDay == today then return end
  seenNotedDay = today
  local entries = {}
  for name in pairs(Roster.members) do
    entries[#entries + 1] = { name = name, day = today, how = JOIN.seen }
  end
  Store.NoteJoins(entries, today)
end

local joinPattern
local function onSystemMessage(text)
  if not joinPattern and ERR_GUILD_JOIN_S then
    joinPattern = "^" .. ERR_GUILD_JOIN_S:gsub("([%(%)%.%%%+%-%*%?%[%]%^%$])", "%%%1"):gsub("%%%%s", "(.+)") .. "$"
  end
  if not joinPattern or not Time.isLive() then return end
  local who = text:match(joinPattern)
  if who then
    who = who:gsub("|H.-|h", ""):gsub("|h", ""):gsub("[%[%]]", "")
    local today = Time.day()
    Store.NoteJoins({ { name = Compat.FullName(who), day = today, how = JOIN.message } }, today)
    Compat.RequestRoster()
  end
end

-- Alts ------------------------------------------------------------------------------
-- A public note that names a main, like "Kiri's alt", links an alt without the addon to
-- its main. Every addon reads the same public notes, so every addon links the same way.
-- On Forever a note may give the main's first name alone, which counts when no one
-- else in the guild has that first name.

local function shortLower(full)
  return Compat.ShortName(full):lower()
end

function Roster.MainOf(name)
  if not Roster.altCache then
    local cache = {}
    local byShort = {}
    for full in pairs(Roster.members) do byShort[shortLower(full)] = full end
    if Compat.Surnames() then
      local byFirst, shared = {}, {}
      for full in pairs(Roster.members) do
        local first = Compat.FirstName(full)
        if first then
          first = first:lower()
          if byFirst[first] then shared[first] = true end
          byFirst[first] = full
        end
      end
      for first, full in pairs(byFirst) do
        if not shared[first] and not byShort[first] then byShort[first] = full end
      end
    end
    for full, m in pairs(Roster.members) do
      local note = (m.note or ""):lower()
      if note:find("alt", 1, true) then
        local best, bestLen = nil, 0
        for s, other in pairs(byShort) do
          if other ~= full and #s > bestLen then
            local i, j = note:find(s, 1, true)
            if i then
              local before = i == 1 or not note:sub(i - 1, i - 1):find("[%a]")
              local after = j == #note or not note:sub(j + 1, j + 1):find("[%a]")
              if before and after then best, bestLen = other, #s end
            end
          end
        end
        if best then cache[full] = best end
      end
    end
    Roster.altCache = cache
  end
  return Roster.altCache[name]
end

-- Officers --------------------------------------------------------------------------
-- Officer ranks are picked by the guild master in the officer corner. By default, the
-- guild master and the rank below.

function Roster.OfficerRanks()
  local s = Store.get("s")
  local e = s and s.entries.ranks
  if e then
    local author = Roster.members[e.by]
    if author and author.rankIndex == 0 then
      local ranks = {}
      for r in e.value:gmatch("%d+") do ranks[tonumber(r)] = true end
      ranks[0] = true
      return ranks
    end
  end
  return { [0] = true, [1] = true }
end

function Roster.IsOfficer(name)
  local m = Roster.members[name]
  return m ~= nil and Roster.OfficerRanks()[m.rankIndex] == true
end

function Roster.IsGuildMaster(name)
  local m = Roster.members[name]
  return m ~= nil and m.rankIndex == 0
end

-- Init ------------------------------------------------------------------------------

function Roster.Init()
  Events.On("GUILD_ROSTER_UPDATE", function()
    if GetTime() - lastScan < 5 then return end
    if Roster.Scan() then
      Roster.NoteSeen()
    end
  end)
  Events.On("CHAT_MSG_SYSTEM", onSystemMessage)
  Events.On("PINTO_SYNC_STATE", function(state)
    if state == "synced" or state == "alone" then
      ns.After(5, function()
        Roster.MaybeFound()
        Roster.NoteSeen()
      end)
    end
  end)
  Compat.RequestRoster()
  ns.Every(60, Compat.RequestRoster)
end
