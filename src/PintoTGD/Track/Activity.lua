-- Guild groups and what happens in them.
--
-- A guild group: at least 2 guildies in the same party or raid, and in the same zone or
-- instance, for at least 10 minutes, with at least one addon user among them (this one).
-- Inside a dungeon, raid or battleground it's that activity. In the open world it's a
-- quest group once there's a turn-in, quest progress or a fight together; otherwise "other".
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

local together = {}     -- guildie -> seconds with this player in the group, same zone
local questSign = false -- turn-in, progress or a fight together since the group formed
local lastTick = nil
local lastRecord = nil
local groupQuest = {}       -- questID -> true for quests the game marks for several players
local lastPresent = {}

-- Guildies in the group and in the same zone or instance right now: name -> unit.
-- While the client hides where someone is or whether they're online (it can in combat
-- and in instances), the last answer for them stands.
function Activity.Present()
  local list = {}
  if not IsInGroup() then
    lastPresent = list
    return list
  end
  local myMap = Compat.MapForUnit("player")
  for _, unit in ipairs(Compat.GroupUnits()) do
    local name = Compat.UnitFullName(unit)
    if name and name ~= ns.me and ns.Roster.Get(name) then
      local online = Compat.IsConnected(unit)
      local theirs = Compat.MapForUnit(unit)
      if online == nil or myMap == false or theirs == false then
        if lastPresent[name] then list[name] = unit end
      elseif online and theirs and theirs == myMap then
        list[name] = unit
      end
    end
  end
  lastPresent = list
  return list
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

local function tick()
  if ns.disabled or not Time.isLive() then return end
  local now = GetTime()
  local dt = lastTick and math.min(2 * TICK, now - lastTick) or 0
  lastTick = now
  local present = Activity.Present()
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

local function onSpellcast(unit, _, spellID)
  if unit ~= "player" or not Time.isLive() then return end
  local kind = gatherKind(spellID)
  if kind then
    Log.AddGather(kind, 1, Activity.Present())
  elseif isBandage(spellID) then
    onBandage()
  end
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
  Events.On("GROUP_ROSTER_UPDATE", function() ns.After(1, tick) end)
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
  cacheQuestLog()
end
