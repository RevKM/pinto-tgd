-- A short record of what the game tells Pinto about group members inside instances, for
-- working out how the Forever client reports who's where. It stays on this computer
-- (PintoTGD_DB.trace) and is never shared with the guild.
--
-- PintoTGD_DB.trace = { v = 1, inside = { sample, ... }, outside = { sample, ... },
--   bosses = { [encounter id] = { name, kind, inst, zone, kills, wipes, unclear, t } },
--   signals = { { visit, me, place, t, last, lines, more, counts = { [answer] = n } }, ... } }
-- sample = { t, last, n, visit, why, me, place, combat, boss, units = { text, ... }, others }
-- units: each guildie's answers and Pinto's verdict. Anyone else in the group is only
-- counted (others), with the shape of their name, not the name.
-- Each distinct picture is kept once per visit to a place, with when it was first and
-- last seen and how often (n). inside: in instances. outside: in the open world, and only
-- while the maps don't settle where a guildie in the group is.
-- signals: what the game answered about each group member at each of those looks, guildie
-- or not, counted per visit and without names, like
--   "other | combat=yes boss=no | online=yes map=none sight=yes range=? roster=none guild=no/other"
-- (who: guildie, other or unnamed; the player's own state; the unit's answers, with its
-- map and roster zone against the player's; and the game's own word on its guild). They
-- show which answers can be relied on in a place, in a group of strangers too.
local ADDON, ns = ...

local Trace = {}
ns.Trace = Trace

local Time, Compat, Events = ns.Time, ns.Compat, ns.Events

local KEEP = { inside = 200, outside = 40 }
local LOOK_BACK = 60    -- how many samples of a visit are checked for the same picture
local MAX_UNITS = 12    -- guildies written out per sample
local MAX_BOSSES = 150
local MAX_VISITS = 20   -- visits whose answers are counted
local MAX_LINES = 100   -- distinct answers listed per visit; any beyond are only counted

local visit, visitKey = 0, nil

local function db()
  local t = PintoTGD_DB.trace
  if type(t) ~= "table" or t.v ~= 1 then
    t = { v = 1, inside = {}, outside = {}, bosses = {} }
    PintoTGD_DB.trace = t
  end
  -- the counts came after the first traces were saved
  if type(t.signals) ~= "table" then t.signals = {} end
  return t
end

local function mapText(map)
  if map == false then return "hidden" end
  if type(map) ~= "number" then return "none" end
  return string.format("%d", map)
end

local function yesNo(v)
  if v == nil then return "?" end
  return v and "yes" or "no"
end

local function unitText(e)
  local r = e.read
  return string.format("%s %s: online=%s map=%s sight=%s range=%s roster=%s -> %s by %s, %s", e.unit, e.name,
    yesNo(r.online), mapText(r.map), yesNo(r.sight), yesNo(r.range), r.zone or "none",
    e.with == nil and "unclear" or (e.with and "with me" or "elsewhere"), e.via, e.nearby and "nearby" or "not nearby")
end

-- A name's shape without the name, like "Aaaa Aaaaaaa": how the client wrote it, for a
-- group member Pinto didn't find in the guild roster.
local HIGH = "[" .. string.char(128) .. "-" .. string.char(255) .. "]+"   -- the bytes of letters beyond ASCII
local function shape(name)
  return (name:gsub(HIGH, "a"):gsub("%u", "A"):gsub("%l", "a"):gsub("%d", "0"))
end

local function pictureOf(s)
  return table.concat({ s.place, s.combat, s.boss, s.others, table.concat(s.units, ";") }, "#")
end

-- A unit's map against the player's: the id itself would make a line for every map.
local function mapKind(map, mine)
  if map == false then return "hidden" end
  if type(map) ~= "number" then return "none" end
  if type(mine) ~= "number" then return "known" end
  return map == mine and "same" or "other"
end

-- Counts what the game answered about each group member at this look, under the visit.
local function count(look, key, now, combat, boss)
  local list = db().signals
  local v = list[#list]
  if not v or v.visit ~= visit or v.place ~= key or v.me ~= ns.me then
    v = { visit = visit, me = ns.me, place = key, t = now, lines = 0, more = 0, counts = {} }
    list[#list + 1] = v
    while #list > MAX_VISITS do table.remove(list, 1) end
  end
  v.last = now
  local me = look.me
  for _, e in ipairs(look.units) do
    -- a guildie's answers are the ones Pinto went by; anyone else is asked the same now
    local r = e.read or ns.Activity.Read(e.unit, e.name)
    local zone = "none"
    if r.zone then zone = (r.zone == me.zone or r.zone == me.rosterZone) and "same" or "other" end
    local inMine, relation = Compat.UnitGuild(e.unit)
    local text = string.format("%s | combat=%s boss=%s | online=%s map=%s sight=%s range=%s roster=%s guild=%s/%s",
      (not e.name and "unnamed") or (e.guildie and "guildie") or "other", combat, boss,
      yesNo(r.online), mapKind(r.map, me.map), yesNo(r.sight), yesNo(r.range), zone, yesNo(inMine), relation or "?")
    if v.counts[text] then
      v.counts[text] = v.counts[text] + 1
    elseif v.lines < MAX_LINES then
      v.counts[text], v.lines = 1, v.lines + 1
    else
      v.more = v.more + 1
    end
  end
end

-- Notes the picture the last look gave (Activity.LastLook), if it's one worth keeping.
function Trace.Note(why)
  local look = ns.Activity and ns.Activity.LastLook()
  if not look or not ns.me then return end
  local me = look.me
  local inside = me.kind ~= "none"
  local units, others, unsettled = {}, 0, false
  for _, e in ipairs(look.units) do
    if not e.name then
      unsettled = true
      units[#units + 1] = e.unit .. ": name hidden"
    elseif not e.guildie then
      others = others + 1
      if #units < MAX_UNITS then units[#units + 1] = e.unit .. ": not a guildie, name like " .. shape(e.name) end
    else
      if e.via ~= "map" then unsettled = true end
      if #units < MAX_UNITS then units[#units + 1] = unitText(e) end
    end
  end
  if not inside and not unsettled then return end

  local now = Time.now()
  local key = me.kind .. ":" .. string.format("%d", me.inst)
  if key ~= visitKey then
    visitKey = key
    visit = now
  end
  local guild = 0
  for _ in pairs(ns.Roster.members) do guild = guild + 1 end
  local combat = yesNo(Compat.InCombat("player"))
  local boss = yesNo(ns.Comm and ns.Comm.InBossFight and ns.Comm.InBossFight())
  count(look, key, now, combat, boss)
  local sample = { t = now, last = now, n = 1, visit = visit, why = why, me = ns.me,
    place = string.format("%s|map=%s|zone=%s|roster=%s|guild=%d", Compat.InstanceInfo(), mapText(me.map),
      me.zone or "none", me.rosterZone or "none", guild),
    combat = combat, boss = boss,
    units = units, others = string.format("%d", others) }
  local list = db()[inside and "inside" or "outside"]
  local picture = pictureOf(sample)
  for i = #list, math.max(1, #list - LOOK_BACK + 1), -1 do
    local s = list[i]
    if s.visit ~= visit or s.me ~= sample.me then break end
    if pictureOf(s) == picture then
      s.n = s.n + 1
      s.last = now
      return
    end
  end
  list[#list + 1] = sample
  while #list > KEEP[inside and "inside" or "outside"] do table.remove(list, 1) end
end

-- Boss fights: where each one happened, as the game put it. A boss the game won't name
-- is kept under "?".
local function onEncounter(ended, id, name, success)
  if not Time.isLive() then return end
  local bosses = db().bosses
  local key = id and string.format("%d", id) or "?"
  local b = bosses[key]
  if not b then
    local count = 0
    for _ in pairs(bosses) do count = count + 1 end
    if count >= MAX_BOSSES then return end
    b = { kills = 0, wipes = 0, unclear = 0 }
    bosses[key] = b
  end
  b.name = name or b.name
  b.kind, b.inst, b.zone, b.t = Compat.InstanceKind(), Compat.InstanceID(), Compat.ZoneText(), Time.now()
  if ended then
    if success == 1 then b.kills = b.kills + 1
    elseif success == nil then b.unclear = b.unclear + 1
    else b.wipes = b.wipes + 1 end
  end
  if ns.Activity then
    ns.Activity.Present()
    Trace.Note(ended and "boss end" or "boss start")
  end
end

function Trace.Init()
  Events.On("ENCOUNTER_START", function(id, name) onEncounter(false, id, name) end)
  Events.On("ENCOUNTER_END", function(id, name, _, _, success) onEncounter(true, id, name, success) end)
end
