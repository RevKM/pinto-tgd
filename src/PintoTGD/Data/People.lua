-- Who's who: characters grouped into players.
--
-- A player is one person with all their characters. Addon users are grouped by the
-- player id on their cards (an account, or the account a second license was linked to).
-- A character without the addon is its own player, unless a public note names its main.
-- Everything here is worked out from synced data and the public roster, so every addon
-- arrives at the same grouping.
local ADDON, ns = ...

local People = {}
ns.People = People

local Store, Util, Time, Roster, Events = ns.Store, ns.Util, ns.Time, ns.Roster, ns.Events

local view = nil

local function key(prefix, n) return prefix .. string.format("%.0f", n) end

function People.Rebuild()
  local v = { players = {}, ofChar = {}, names = {} }

  local j = Store.get("j")
  if j then
    for id, e in pairs(j.entries) do v.names[id] = e.name end
  end

  -- addon users
  local p = Store.get("p")
  if p then
    local accts = {}
    for acct in pairs(p.cards) do accts[#accts + 1] = acct end
    table.sort(accts)
    for _, acct in ipairs(accts) do
      local card = p.cards[acct]
      local k = key("a", card.player)
      local pl = v.players[k]
      if not pl then
        pl = { key = k, addon = true, chars = {}, cards = {} }
        v.players[k] = pl
      end
      pl.cards[#pl.cards + 1] = card
      for _, ch in ipairs(card.chars) do
        local id = Util.nameId(ch.name)
        pl.chars[id] = ch
        v.ofChar[id] = k
        v.names[id] = ch.name
      end
    end
  end

  -- everyone else, with public alt notes
  if j then
    for id, e in pairs(j.entries) do
      if not v.ofChar[id] then
        local main = Roster.MainOf(e.name)
        local mainId = main and Util.nameId(main)
        local k = mainId and v.ofChar[mainId]
        if not k then k = key("c", mainId or id) end
        local pl = v.players[k]
        if not pl then
          pl = { key = k, addon = false, chars = {} }
          v.players[k] = pl
        end
        pl.chars[id] = { name = e.name }
        v.ofChar[id] = k
      end
    end
  end
  view = v
  return v
end

function People.View()
  return view or People.Rebuild()
end

-- The player a character belongs to. Unknown characters are their own player.
function People.PlayerOf(nameId)
  local v = People.View()
  return v.ofChar[nameId] or key("c", nameId)
end

function People.Name(nameId)
  return People.View().names[nameId]
end

function People.IsAddonPlayer(k)
  local pl = People.View().players[k]
  return pl ~= nil and pl.addon
end

-- The player's join: the earliest of their characters' join days. A player with a
-- character in the founding register is a founding member.
function People.Join(k)
  local pl = People.View().players[k]
  if not pl then return nil end
  local day, founding = nil, false
  for id in pairs(pl.chars) do
    local info = Roster.JoinInfo(id)
    if info then
      if info.founding then founding = true end
      if not day or info.day < day then day = info.day end
    end
  end
  if not day then return nil end
  return { day = day, founding = founding }
end

-- New: joined in the last 30 days. Founding members are never new.
function People.IsNew(k, today)
  local join = People.Join(k)
  if not join or join.founding then return false end
  return today - join.day < 30
end

-- New players count from their fourth day in the guild.
function People.Counts(k, today)
  local join = People.Join(k)
  if not join or join.founding then return true end
  return today - join.day >= 3
end

function People.Established(k, today)
  return not People.IsNew(k, today)
end

-- Main characters --------------------------------------------------------------------
-- A player's g and p come from their main: the character with the most play days in the
-- last 7 days. On equal play days, yesterday's main stays. With no main yet, the highest
-- level character, then the first by name. Worked out day by day from 30 days back, so
-- every addon gets the same answer.

local function playDays(charIds, day)
  local counts = {}
  for d = day - 7, day - 1 do
    local piece = Store.get("d" .. string.format("%d", d))
    if piece then
      for id in pairs(charIds) do
        if piece.played[id] then counts[id] = (counts[id] or 0) + 1 end
      end
    end
  end
  return counts
end

local function fallbackMain(chars)
  local best, bestId
  for id, ch in pairs(chars) do
    if not best or (ch.level or 0) > (best.level or 0)
      or ((ch.level or 0) == (best.level or 0) and Util.byteLess(ch.name, best.name)) then
      best, bestId = ch, id
    end
  end
  return bestId
end

local mainCache = {}

function People.MainOf(k, day)
  local pl = People.View().players[k]
  if not pl then return nil end
  local cacheKey = k .. ":" .. string.format("%d", day)
  if mainCache[cacheKey] then return mainCache[cacheKey] end
  local main = fallbackMain(pl.chars)
  for d = day - 30, day do
    local counts = playDays(pl.chars, d)
    local best, bestN = nil, 0
    for id, n in pairs(counts) do
      if n > bestN or (n == bestN and best and Util.byteLess(pl.chars[id].name, pl.chars[best].name)) then
        best, bestN = id, n
      end
    end
    if best then
      -- on equal play days, yesterday's main stays
      if main and counts[main] == bestN then best = main end
      main = best
    end
  end
  mainCache[cacheKey] = main
  return main
end

function People.Init()
  Events.On("PINTO_DATA_CHANGED", function(id)
    if id == nil or id == "p" or id == "j" then view = nil end
    if id == nil or id == "p" or id == "j" or (id and id:sub(1, 1) == "d") then mainCache = {} end
  end)
  Events.On("PINTO_ROSTER", function() view = nil end)
end
