-- Guild groups and what happens in them.
--
-- A guild group: at least 2 guildies in the same party or raid, and in the same zone or
-- instance, for at least 10 minutes, with at least one addon user among them (this one).
-- Inside a dungeon, raid or battleground it's that activity. In the open world it's a
-- quest group once there's a turn-in, quest progress or a fight together; otherwise "other".
-- Moments with guildies nearby in the group go in the log too: a camp set up, a dance,
-- cheering together.
--
-- The Forever client keeps the combat log from addons (registering it gets the addon
-- blocked), so fights and bandages are read from the player's own casts and combat state.
local ADDON, ns = ...

local Activity = {}
ns.Activity = Activity

local Store, Pieces, Compat, Time, Events, Log = ns.Store, ns.Pieces, ns.Compat, ns.Time, ns.Events, ns.Log
local ACT = Pieces.ACT

local QUALIFY = 600
local TICK = 15
local APART_GRACE = 45

local together = {}     -- guildie -> seconds with this player in the group, same zone
local questSign = false -- turn-in, progress or a fight together since the group formed
local lastTick = nil
local lastRecord = nil
local groupQuest = {}       -- questID -> true for quests the game marks for several players
local nearby = {}       -- guildie -> unit: who counted as nearby at the last look
local apartSince = {}   -- guildie -> GetTime() of the first "elsewhere" answer in a row
local unitNames = {}    -- unit -> full name, for while the client hides names
local lastLook = nil    -- what the last look found, for the trace and /pinto nearby
local lastRosterAsk = -100

-- Who's nearby -------------------------------------------------------------------------
-- A guildie in the group counts as nearby while they're in the same zone or instance as
-- the player. The game doesn't always say where a group member is: inside an instance the
-- Forever client gives Pinto no usable map for anyone, and in combat it hides more. So
-- Pinto asks several things, and while it gets no clear answer the last one stands:
--   nearby:    on the same map, in sight or in range; or, where the maps don't say, in
--              the player's zone by the guild roster
--   elsewhere: offline; or, for 45 seconds running, on another map in the open world or
--              in another zone by the guild roster
-- The 45 seconds cover a group walking into a dungeon one after another, and the roster,
-- which runs a little behind. A unit's name is remembered while the client hides it.

local function rosterZone(name)
  local member = name and ns.Roster.Get(name)
  local zone = member and member.zone
  if ns.Secret(zone) or type(zone) ~= "string" or zone == "" then return nil end
  return zone
end

-- What the game says about the player's own place.
local function readMe()
  return { map = Compat.MapForUnit("player"), zone = Compat.ZoneText(), rosterZone = rosterZone(ns.me),
    kind = Compat.InstanceKind(), inst = Compat.InstanceID() }
end

-- What the game says about a group unit. An answer is nil while the client hides it or
-- doesn't know; a hidden map is false.
local function read(unit, name)
  return { online = Compat.IsConnected(unit), map = Compat.MapForUnit(unit), sight = Compat.IsVisible(unit),
    range = Compat.InRange(unit), zone = rosterZone(name) }
end
Activity.Read = read   -- the trace asks the same of group members who aren't guildies

-- Whether those answers put the unit with the player: true, false, or nil when they
-- don't say. And which answer decided.
local function isWith(r, me)
  if r.online == false then return false, "offline" end
  if me.map and r.map and r.map == me.map then return true, "map" end
  if r.sight then return true, "sight" end
  if r.range then return true, "range" end
  -- two known maps that differ: elsewhere. Not inside an instance, where a map can be one
  -- floor of several.
  if me.map and r.map and me.kind == "none" then return false, "map" end
  if r.zone and (me.zone or me.rosterZone) then
    if r.zone == me.zone or r.zone == me.rosterZone then return true, "roster" end
    return false, "roster"
  end
  return nil, "none"
end

-- Guildies in the group and nearby right now: name -> unit.
function Activity.Present()
  local list = {}
  if not IsInGroup() then
    nearby, apartSince, unitNames, lastLook = list, {}, {}, nil
    return list
  end
  local now = GetTime()
  local me = readMe()
  local look = { me = me, units = {} }
  local named, unnamed = {}, false
  for _, unit in ipairs(Compat.GroupUnits()) do
    local name = Compat.UnitFullName(unit)
    if name then unitNames[unit] = name else name = unitNames[unit] end
    if not name or name ~= ns.me then
      local entry = { unit = unit, name = name }
      look.units[#look.units + 1] = entry
      if not name then
        unnamed = true
      else
        named[name] = true
        entry.guildie = ns.Roster.Get(name) ~= nil
      end
      if entry.guildie then
        local r = read(unit, name)
        local with, via = isWith(r, me)
        local was = nearby[name] ~= nil
        local stays
        if with == true then
          stays = true
          apartSince[name] = nil
        elseif with == false then
          -- elsewhere: at once when offline, otherwise once it has been so for a while
          stays = false
          if was and via ~= "offline" then
            apartSince[name] = apartSince[name] or now
            stays = now - apartSince[name] < APART_GRACE
          end
        else
          stays = was
        end
        if stays then list[name] = unit end
        entry.read, entry.with, entry.via, entry.nearby = r, with, via, stays
      end
    end
  end
  -- a unit the client won't name can't be told from the others: whoever was nearby and
  -- isn't among the named units stays as they were
  if unnamed then
    for name, unit in pairs(nearby) do
      if not named[name] then list[name] = unit end
    end
  end
  for name in pairs(apartSince) do
    if not list[name] then apartSince[name] = nil end
  end
  nearby, lastLook = list, look
  return list
end

-- What the last look found: { me = the player's place, units = { { unit, name, guildie,
-- read, with, via, nearby }, ... } }, or nil outside a group.
function Activity.LastLook()
  return lastLook
end

-- What Pinto makes of the group right now, as lines of text, for /pinto nearby.
local PLACE = { party = "a dungeon", raid = "a raid", pvp = "a battleground", arena = "an arena" }
function Activity.Describe()
  Activity.Present()
  local look = lastLook
  if not look then return { "You're not in a group." } end
  local place = look.me.zone or "a place the game doesn't name"
  if PLACE[look.me.kind] then place = place .. ", " .. PLACE[look.me.kind] end
  local lines = { "You're in " .. place .. "." }
  local any = false
  for _, e in ipairs(look.units) do
    if e.guildie then
      any = true
      local how
      if e.via == "map" then how = e.with and "on your map" or "on another map"
      elseif e.via == "sight" then how = "in sight"
      elseif e.via == "range" then how = "in range"
      elseif e.via == "roster" then how = "the guild roster says " .. e.read.zone
      elseif e.via == "offline" then how = "offline"
      else how = "the game doesn't say where they are" end
      if e.nearby and e.with ~= true then how = how .. "; counted as before" end
      lines[#lines + 1] = string.format("%s: %s (%s)", Compat.ShortName(e.name), e.nearby and "nearby" or "not nearby", how)
    elseif not e.name then
      any = true
      lines[#lines + 1] = "Someone whose name the game is hiding right now."
    else
      -- not in the roster Pinto has. If the game itself puts them in the guild, the roster
      -- and the game disagree, and that's worth knowing: the roster decides who counts.
      local inMine, relation = Compat.UnitGuild(e.unit)
      if inMine == true or relation == "same" then
        any = true
        lines[#lines + 1] = Compat.ShortName(e.name) .. ": in your guild by the game, but not in the guild roster Pinto has."
      end
    end
  end
  if not any then lines[#lines + 1] = "No guildies in your group." end
  return lines
end

function Activity.Kind()
  local kind = Compat.InstanceKind()
  if kind == "party" then return ACT.dungeon end
  if kind == "raid" then return ACT.raid end
  if kind == "pvp" or kind == "arena" then return ACT.bg end
  return questSign and ACT.quest or ACT.other
end

local function recordGroup(qualified, act)
  local names = { ns.me }
  for _, n in ipairs(qualified) do names[#names + 1] = n end
  table.sort(names, ns.Util.byteLess)
  local today = Time.day()
  local sig = string.format("%d:%d:", today, act) .. table.concat(names, ",")
  if sig == lastRecord then return end
  lastRecord = sig
  Store.AddGroup(today, names, act, ns.Player.AccountId())
end

-- Where the maps don't say who's with the player, the guild roster's zones do, so the
-- roster is asked for again (it's asked for every minute anyway).
local function askRoster(now)
  if not lastLook or now - lastRosterAsk < TICK - 1 then return end
  for _, e in ipairs(lastLook.units) do
    if e.guildie and (e.via == "roster" or e.via == "none") then
      lastRosterAsk = now
      Compat.RequestRoster()
      return
    end
  end
end

local function tick()
  if ns.disabled or not Time.isLive() then return end
  local now = GetTime()
  local dt = lastTick and math.min(2 * TICK, now - lastTick) or 0
  lastTick = now
  local present = Activity.Present()
  askRoster(now)
  -- the trace is only a record: a fault in it must never stop the tracking
  if ns.Trace then
    local ok, err = pcall(ns.Trace.Note, "tick")
    if not ok then ns.report(err) end
  end
  for name in pairs(together) do
    if not present[name] then together[name] = nil end
  end
  if not next(present) then
    questSign = false
    Log.CloseSession()
    return
  end
  for name in pairs(present) do together[name] = (together[name] or 0) + dt end

  local act = Activity.Kind()
  local session = Log.Session(act, Compat.InstanceID())
  session.last = Time.now()
  session.present = Log.set(present)
  if act ~= ACT.other and session.act == ACT.other then session.act = act end

  local qualified = {}
  for name, secs in pairs(together) do
    if secs >= QUALIFY then
      qualified[#qualified + 1] = name
      session.members[name] = true
    end
  end
  if #qualified > 0 then recordGroup(qualified, act) end
end

-- Quest signs ------------------------------------------------------------------------

local function cacheQuestLog()
  for _, q in ipairs(Compat.QuestLog()) do groupQuest[q.questID] = q.group or nil end
end

local function onTurnin(questID)
  if not Time.isLive() then return end
  local present = Activity.Present()
  if next(present) then questSign = true end
  local group = groupQuest[questID] == true
  Log.AddTurnin(questID, group, present)
  tick()
end

local function onInfo(_, text)
  if type(text) == "string" and text:find("%d+/%d+") and next(Activity.Present()) then
    questSign = true
  end
end

-- Fighting together: a few seconds into a fight in the open world, a guildie in the
-- group is in combat too.
local function onCombatStart()
  if not Time.isLive() or Compat.InstanceKind() ~= "none" or not next(Activity.Present()) then return end
  ns.After(2, function()
    if not Compat.InCombat("player") then return end
    for _, unit in pairs(Activity.Present()) do
      if Compat.InCombat(unit) then
        questSign = true
        return
      end
    end
  end)
end

-- Bandages: a First Aid cast while a guildie in the group is the target. A bandage goes
-- to a friendly target, so that's who it patched up. Casting the First Aid skill itself,
-- which opens its window, doesn't count.
local BANDAGES = { [746] = true, [1159] = true, [3267] = true, [3268] = true, [7926] = true, [7927] = true,
  [10838] = true, [10839] = true, [18608] = true, [18610] = true }
local FIRST_AID_SKILL = { [3273] = true, [3274] = true, [7924] = true, [10846] = true }
local firstAidName
local function isBandage(spellID)
  if BANDAGES[spellID] then return true end
  if FIRST_AID_SKILL[spellID] then return false end
  firstAidName = firstAidName or Compat.SpellName(746) or "First Aid"
  return Compat.SpellName(spellID) == firstAidName
end

local function onBandage()
  local session = Log.OpenSession()
  if not session then return end
  for name, unit in pairs(Activity.Present()) do
    if Compat.IsUnit("target", unit) then
      session.bandaged[name] = true
      Events.Fire("PINTO_LOG")
      return
    end
  end
end

local function onEncounterEnd(encounterID, encounterName, _, _, success)
  if success ~= 1 or Compat.InstanceKind() ~= "party" then return end
  tick()
  local session = Log.OpenSession()
  if not session then return end
  session.bosses = session.bosses + 1
  if ns.Blocks and ns.Blocks.IsFinalBoss(encounterID, encounterName) then
    session.final = true
    session.finalMembers = Log.set(Activity.Present())
  end
  Events.Fire("PINTO_LOG")
end

local function onLevelUp()
  if not Time.isLive() then return end
  Log.AddLevel(Activity.Present())
end

-- Gathering and fishing ----------------------------------------------------------------

-- Gathering casts are known by name, which every rank shares. The ranks' spell ids
-- (apprentice to artisan) count too, for when the client can't name a spell.
local GATHER_SPELLS = { mine = 2575, herb = 2366, skin = 8613 }
local GATHER_IDS = {
  [2575] = "mine", [2576] = "mine", [3564] = "mine", [10248] = "mine",
  [2366] = "herb", [2368] = "herb", [3570] = "herb", [11993] = "herb",
  [8613] = "skin", [8617] = "skin", [8618] = "skin", [10768] = "skin",
}
local gatherNames
local function gatherKind(spellID)
  if GATHER_IDS[spellID] then return GATHER_IDS[spellID] end
  if not gatherNames then
    gatherNames = { ["Mining"] = "mine", ["Herb Gathering"] = "herb", ["Skinning"] = "skin" }
    for kind, id in pairs(GATHER_SPELLS) do
      local name = Compat.SpellName(id)
      if name then gatherNames[name] = kind end
    end
  end
  local name = Compat.SpellName(spellID)
  return name and gatherNames[name]
end
Activity.GatherKind = gatherKind

-- Camping on Forever: a campfire from a campfire kit (Cooking), then camp features, each
-- placed near a campfire from a profession's camp item. Each is known by the spell its
-- item casts when used: crafting the item is another spell, which can carry the same
-- name, and doesn't count. The ids are from Wowhead's Forever database; for a camp item
-- whose spell isn't among them, the client says which spell it casts. A feature added
-- within 15 minutes of the player lighting a campfire, about as long as a campsite lasts,
-- with guildies nearby in the group, is noted as a camp.
local CAMPFIRES = {
  [818] = true,                                             -- Basic Campfire, before Forever
  [1307227] = true, [1307252] = true, [1307237] = true,     -- Basic, Journeyman, Expert Campfire Kit
}
local FEATURES = {
  [1307259] = true, [1307242] = true, [1307172] = true,     -- Mana Well, Fermenter, Alchemy Laboratory
  [1307392] = true, [1307175] = true, [1307261] = true,     -- Sharpening Wheel, Anvil, Master Forge
  [1307234] = true, [1307223] = true, [1307176] = true,     -- Enchanted Lute, Arcane Salvager, Arcane Forge
  [1307266] = true, [1307385] = true, [1307174] = true,     -- Reagent Bot, Repair Bot, Anarchist's Workbench
  [1307251] = true, [1307248] = true, [1307387] = true,     -- Incense Candle, Greenhouse, Seed Hybridizer
  [1307230] = true, [1307395] = true, [1307391] = true,     -- Camp Tent, Tanning Rack, Sewing Machine
  [1307254] = true, [1307386] = true, [1307264] = true,     -- Lodestone, Rock Garden, Molten Foundry
  [1307229] = true, [1307243] = true, [1307397] = true,     -- Camp Chair, Field Guide, Trapper's Workbench
  [1307240] = true, [1307393] = true, [1307255] = true,     -- Faction Banner, Spinning Wheel, Loom
  [1307257] = true,                                         -- Cookie's Feast
  [1307244] = true, [1307396] = true, [1307265] = true,     -- First Aid Kit, Toxin Study, Plague Doctor's Laboratory
  [1307245] = true, [1307247] = true, [1307246] = true,     -- Fish Bowl, Fishing Rack, Fishing Hut
}
local CAMPFIRE_KITS = { 279981, 279961, 279974 }
local FEATURE_ITEMS = { 279956, 279970, 279990, 279944, 279988, 279955, 279976, 279985, 279987, 279950,
  279949, 279989, 279962, 279964, 279947, 279978, 279941, 279945, 279960, 279948, 279952, 279979, 279969,
  279938, 279972, 279943, 279959, 279957, 279982, 279968, 279940, 279951, 279967, 279965, 279966 }
local CAMP_WINDOW = 900
local lastFire                          -- GetTime() of the player's last campfire
local itemSpells, itemSpellsAt, itemsMissing = nil, 0, false

local function campKind(spellID)
  if CAMPFIRES[spellID] then return "fire" end
  if FEATURES[spellID] then return "feature" end
  -- the camp items' own word on their spells; asked again (once a minute at most) while
  -- the client still lacks some of the items
  local now = GetTime()
  if not itemSpells or (itemsMissing and now - itemSpellsAt >= 60) then
    itemSpells, itemSpellsAt, itemsMissing = {}, now, false
    for kind, items in pairs({ fire = CAMPFIRE_KITS, feature = FEATURE_ITEMS }) do
      for _, id in ipairs(items) do
        local spell = Compat.ItemSpell(id)
        if spell then itemSpells[spell] = kind else itemsMissing = true end
      end
    end
  end
  return itemSpells[spellID]
end

local function onSpellcast(unit, _, spellID)
  if unit ~= "player" or not Time.isLive() then return end
  local kind = gatherKind(spellID)
  if kind then
    Log.AddGather(kind, 1, Activity.Present())
  elseif isBandage(spellID) then
    onBandage()
  else
    local camp = campKind(spellID)
    if camp == "fire" then
      lastFire = GetTime()
    elseif camp == "feature" and lastFire and GetTime() - lastFire <= CAMP_WINDOW then
      local present = Activity.Present()
      if next(present) then Log.AddMoment("camp", present) end
    end
  end
end

-- Emotes together: the player and guildies nearby in the group each use an emote of one
-- kind within a minute: /dance for a dance, /cheer, /clap or /congratulate (any mix) for
-- cheering together. The game words its emotes in the client's language and Pinto knows
-- the English ones, so these quests only go to English clients. A moment is noted once,
-- and again whenever more guildies join in. Whoever used an emote is known by their first
-- name: an emote may name someone with or without their surname or realm.
local EMOTE_WINDOW = 60
-- Each kind's emotes as they read after "You " or the name of whoever used them ("You
-- burst into dance.", "Kiri dances with you.", "You cheer at Thorn.", "Bram claps
-- excitedly.", "Ash congratulates you."). Reading right after the name keeps a name like
-- Cheerio, or someone waving at a Dancer, from counting.
local EMOTES = {
  dance = { "^burst into dance", "^bursts into dance", "^dances? with " },
  jolly = { "^cheers?%f[%A]", "^claps?%f[%A]", "^congratulates?%f[%A]" },
}
local emoted = { dance = {}, jolly = {} }   -- kind -> first name, lowercase -> GetTime()
local lastNoted = {}                         -- kind -> { at, n }: the moment last noted

local function firstName(name)
  return (name:match("^[^%s%-]+") or name):lower()
end

-- An emote's words after whoever used it, lowercase, or nil when it doesn't start with them.
local function afterSubject(text, sender)
  local lower = text:lower()
  if lower:sub(1, 4) == "you " then return lower:sub(5) end
  local full = sender:lower()
  for _, n in ipairs({ full, (full:gsub("%-[^%-]*$", "")), firstName(sender) }) do
    if lower:sub(1, #n + 1) == n .. " " then return lower:sub(#n + 2) end
  end
  return nil
end

local function emoteKind(text, sender)
  local rest = afterSubject(text, sender)
  if not rest then return nil end
  for kind, patterns in pairs(EMOTES) do
    for _, p in ipairs(patterns) do
      if rest:find(p) then return kind end
    end
  end
  return nil
end
Activity.EmoteKind = emoteKind

local function onTextEmote(text, sender)
  if not Time.isLive() or type(text) ~= "string" or type(sender) ~= "string" or sender == "" then return end
  local kind = emoteKind(text, sender)
  if not kind then return end
  local now = GetTime()
  local seen = emoted[kind]
  seen[firstName(sender)] = now
  for who, at in pairs(seen) do
    if now - at > EMOTE_WINDOW then seen[who] = nil end
  end
  if not seen[firstName(ns.me)] then return end
  local with, n = {}, 0
  for name in pairs(Activity.Present()) do
    if seen[firstName(name)] then
      with[name] = true
      n = n + 1
    end
  end
  local last = lastNoted[kind]
  if n == 0 or (last and now - last.at <= EMOTE_WINDOW and n <= last.n) then return end
  lastNoted[kind] = { at = now, n = n }
  Log.AddMoment(kind, with)
end

local function onLootOpened()
  if Time.isLive() and IsFishingLoot and IsFishingLoot() then
    Log.AddGather("fish", 1, Activity.Present())
  end
end

-- Materials looted while grouped: cloth, leather, ore and herbs.
local MATERIAL = { [5] = "cloth", [6] = "leather", [7] = "ore", [9] = "herb" }
function Activity.MaterialKind(item)
  local _, _, _, _, _, classID, subclassID = Compat.ItemInfoInstant(item)
  if classID == 7 then return MATERIAL[subclassID] end
  return nil
end

local lootPatterns
local function onLoot(text)
  if not Time.isLive() then return end
  if not lootPatterns then
    lootPatterns = {}
    for _, g in ipairs({ LOOT_ITEM_SELF_MULTIPLE, LOOT_ITEM_PUSHED_SELF_MULTIPLE, LOOT_ITEM_SELF, LOOT_ITEM_PUSHED_SELF }) do
      if g then
        local p = g:gsub("([%(%)%.%+%-%*%?%[%]%^%$])", "%%%1"):gsub("%%s", "(.+)"):gsub("%%d", "(%%d+)")
        lootPatterns[#lootPatterns + 1] = "^" .. p .. "$"
      end
    end
  end
  for _, p in ipairs(lootPatterns) do
    local link, count = text:match(p)
    if link then
      local kind = Activity.MaterialKind(link)
      if kind then Log.AddGather("loot:" .. kind, tonumber(count) or 1, Activity.Present()) end
      return
    end
  end
end

function Activity.Init()
  ns.Every(TICK, tick)
  Events.On("GROUP_ROSTER_UPDATE", function()
    unitNames = {}   -- the group changed: "party2" may be someone else now
    ns.After(1, tick)
  end)
  Events.On("ZONE_CHANGED_NEW_AREA", function() ns.After(2, tick) end)
  Events.On("QUEST_LOG_UPDATE", cacheQuestLog)
  Events.On("QUEST_TURNED_IN", onTurnin)
  Events.On("UI_INFO_MESSAGE", onInfo)
  Events.On("PLAYER_REGEN_DISABLED", onCombatStart)
  Events.On("ENCOUNTER_END", onEncounterEnd)
  Events.On("PLAYER_LEVEL_UP", onLevelUp)
  -- only the player's own casts: other units' come with their spell hidden
  Events.On("UNIT_SPELLCAST_SUCCEEDED", onSpellcast, "player")
  Events.On("LOOT_OPENED", onLootOpened)
  Events.On("CHAT_MSG_LOOT", onLoot)
  Events.On("CHAT_MSG_TEXT_EMOTE", onTextEmote)
  cacheQuestLog()
end
