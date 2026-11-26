-- Thin wrappers over WoW API calls that differ between client versions.
-- The probe addon checks which of these exist in the Forever client.
local ADDON, ns = ...

local Compat = {}
ns.Compat = Compat

Compat.Secret = ns.Secret

-- Addon messages -------------------------------------------------------------------

function Compat.RegisterPrefix(prefix)
  if C_ChatInfo and C_ChatInfo.RegisterAddonMessagePrefix then
    return C_ChatInfo.RegisterAddonMessagePrefix(prefix)
  elseif RegisterAddonMessagePrefix then
    return RegisterAddonMessagePrefix(prefix)
  end
end

-- The result code newer clients give while addon messages are locked down, or false.
local lockdownCode
local function lockdownResult()
  if lockdownCode == nil then
    lockdownCode = false
    local codes = Enum and Enum.SendAddonMessageResult
    if type(codes) == "table" then
      for name, code in pairs(codes) do
        if type(name) == "string" and name:find("Lockdown", 1, true) then lockdownCode = code end
      end
    end
  end
  return lockdownCode
end

-- Returns "ok", "throttled", "locked" or "failed". Newer clients return a result code,
-- older a boolean.
function Compat.SendAddonMessage(prefix, text, channel, target)
  local send = (C_ChatInfo and C_ChatInfo.SendAddonMessage) or SendAddonMessage
  local ok, result = pcall(send, prefix, text, channel, target)
  if not ok then return "failed" end
  if result == nil or result == true or result == 0 then return "ok" end
  if result == 3 or result == 8 then return "throttled" end -- AddonMessageThrottle, ChannelThrottle
  local locked = lockdownResult()
  if locked and result == locked then return "locked" end
  return "failed"
end

-- Whether the game holds back addon messages right now. Newer clients lock them down
-- during boss encounters and PvP matches, and say so through InChatMessagingLockdown.
-- Without it, Pinto assumes a lockdown in PvP and in combat inside an instance.
function Compat.ChatLockdown()
  if C_ChatInfo and C_ChatInfo.InChatMessagingLockdown then
    local ok, locked = pcall(C_ChatInfo.InChatMessagingLockdown)
    if ok and not ns.Secret(locked) then return locked and true or false end
  end
  local kind = Compat.InstanceKind()
  if kind == "pvp" or kind == "arena" then return true end
  return kind ~= "none" and InCombatLockdown ~= nil and InCombatLockdown() and true or false
end

-- Accounts -------------------------------------------------------------------------

-- Trial and lapsed accounts can't send addon messages.
function Compat.IsTrialOrLapsed()
  if IsTrialAccount and IsTrialAccount() then return true end
  if IsVeteranTrialAccount and IsVeteranTrialAccount() then return true end
  if IsRestrictedAccount and IsRestrictedAccount() then return true end
  if GameLimitedMode_IsActive and GameLimitedMode_IsActive() then return true end
  return false
end

-- Names ----------------------------------------------------------------------------
-- Characters are stored by their full name as the guild roster gives it, so the same
-- character has the same key on every client. Older clients name characters
-- "Name-Realm". Forever has no realms: every character has a name and a surname,
-- "Name Surname", unique in the region. There UnitName gives the surname where older
-- clients give the realm, and other calls may write a name "Name-Surname"; either way
-- the key is "Name Surname".

local surnames
function Compat.Surnames()
  if surnames == nil then
    if RegionalUniqueNamesEnabled then
      local ok, on = pcall(RegionalUniqueNamesEnabled)
      surnames = ok and on == true
    else
      -- without the flag: UnitName gives older clients no realm for the player
      local name, second = UnitName("player")
      if not ns.AnySecret(name, second) and name then surnames = second ~= nil and second ~= "" end
    end
  end
  return surnames == true
end

local function realm()
  local r = GetNormalizedRealmName and GetNormalizedRealmName()
  if not r or r == "" then r = (GetRealmName() or ""):gsub("[%s%-]", "") end
  return r
end

-- What this account's saved data for the guild is filed under: the realm. On Forever a
-- guild's characters sit on different realms behind the scenes, so it's one key there.
function Compat.HomeKey()
  if Compat.Surnames() then return "Forever" end
  return realm()
end

-- A character's key from a name in any form the client gives. second is UnitName's
-- second value: the realm on older clients, the surname on Forever.
function Compat.FullName(name, second)
  if not name or name == "" then return nil end
  if Compat.Surnames() then
    if name:find(" ", 1, true) then return (name:match("^[^%-]+")) end   -- "Name Surname", maybe "-Realm" after
    if second and second ~= "" then return name .. " " .. second end
    local first, surname = name:match("^([^%-]+)%-([^%-]+)")             -- "Name-Surname"
    if first then return first .. " " .. surname end
    return name
  end
  if name:find("-", 1, true) then return name end
  if second and second ~= "" then return name .. "-" .. second:gsub("[%s%-]", "") end
  return name .. "-" .. realm()
end

-- Nil while the client hides the unit's name. UnitNameUnmodified, where the client has
-- it, ignores display options such as a hidden surname. The check for a secret comes
-- before any other look at the name: even "not name" raises an error on a hidden one.
function Compat.UnitFullName(unit)
  local name, second = (UnitNameUnmodified or UnitName)(unit)
  if ns.AnySecret(name, second) or not name or name == UNKNOWNOBJECT then return nil end
  return Compat.FullName(name, second)
end

-- How the windows show a character: without the realm. On Forever the whole name, since
-- first names repeat.
function Compat.ShortName(full)
  if not full then return "?" end
  if Compat.Surnames() then return full end
  return (full:gsub("%-[^%-]*$", ""))
end

-- The first name, on Forever: alt notes may name a main by it.
function Compat.FirstName(full)
  return full and full:match("^(%S+) ")
end

-- The name to whisper a character by. On Forever, Comm checks at login which form a
-- whisper arrives under (whisperForm "space" or "hyphen"); until then, "Name Surname".
Compat.whisperForm = "space"
function Compat.WhisperTarget(full)
  if full and Compat.whisperForm == "hyphen" and Compat.Surnames() then return (full:gsub(" ", "-")) end
  return full
end

-- Guild roster ---------------------------------------------------------------------

function Compat.RequestRoster()
  if SetGuildRosterShowOffline then SetGuildRosterShowOffline(true) end
  if C_GuildInfo and C_GuildInfo.GuildRoster then
    C_GuildInfo.GuildRoster()
  elseif GuildRoster then
    GuildRoster()
  end
end

-- One roster row, normalized. lastOnlineDays is nil while the member is online. Nil when
-- there's no such row; false while the client hides any of it.
function Compat.RosterEntry(i)
  local name, _, rankIndex, level, _, zone, note, _, online, _, classFile = GetGuildRosterInfo(i)
  if ns.AnySecret(name, rankIndex, level, zone, note, online, classFile) then return false end
  if not name then return nil end
  local entry = {
    name = Compat.FullName(name),
    rankIndex = rankIndex or 0,
    level = level or 0,
    zone = zone,
    note = note or "",
    online = online and true or false,
    class = classFile,
  }
  if not entry.online and GetGuildRosterLastOnline then
    local years, months, days, hours = GetGuildRosterLastOnline(i)
    if ns.AnySecret(years, months, days, hours) then return false end
    entry.lastOnlineDays = (years or 0) * 365 + (months or 0) * 30 + (days or 0) + (hours or 0) / 24
  end
  return entry
end

function Compat.NumRoster()
  local total = GetNumGuildMembers()
  if ns.Secret(total) or type(total) ~= "number" then return 0 end
  return total
end

function Compat.GuildName()
  if not IsInGuild() then return nil end
  return (GetGuildInfo("player"))
end

-- Whether this character may invite players to the guild.
function Compat.CanGuildInvite()
  local fn = (C_GuildInfo and C_GuildInfo.CanGuildInvite) or CanGuildInvite
  if not fn then return false end
  local ok, can = pcall(fn)
  return ok and can and true or false
end

-- The spell an item casts when it's used, or nil (also while the client hasn't the item
-- cached).
function Compat.ItemSpell(itemID)
  local fn = (C_Item and C_Item.GetItemSpell) or GetItemSpell
  if not fn or not itemID then return nil end
  local ok, _, spellID = pcall(fn, itemID)
  if not ok or ns.Secret(spellID) or type(spellID) ~= "number" then return nil end
  return spellID
end

-- How many of an item are in the player's bags.
function Compat.ItemCount(itemID)
  local fn = (C_Item and C_Item.GetItemCount) or GetItemCount
  if not fn or not itemID then return 0 end
  local ok, n = pcall(fn, itemID)
  return ok and tonumber(n) or 0
end

-- The client's language, like "enUS" or "deDE".
function Compat.Locale()
  return GetLocale and GetLocale() or "enUS"
end

function Compat.PlayerRankIndex()
  local _, _, rankIndex = GetGuildInfo("player")
  return rankIndex
end

-- Groups and places ----------------------------------------------------------------

-- The kind of instance the player is in ("party", "raid", "pvp", "arena"), or "none".
-- While the client hides it, the last answer stands.
local lastKind, lastInstance = "none", 0
function Compat.InstanceKind()
  local inInstance, kind = IsInInstance()
  if ns.AnySecret(inInstance, kind) then return lastKind end
  lastKind = inInstance and type(kind) == "string" and kind or "none"
  return lastKind
end

-- The id of the instance or continent the player is in. While the client hides it, the
-- last answer stands.
function Compat.InstanceID()
  local _, _, _, _, _, _, _, instanceID = GetInstanceInfo()
  if ns.Secret(instanceID) then return lastInstance end
  lastInstance = type(instanceID) == "number" and instanceID or 0
  return lastInstance
end

-- What the client says about where the player is, for the trace: the instance's name,
-- type, difficulty, size and id, as text.
local function infoText(v)
  if ns.Secret(v) then return "hidden" end
  if v == nil then return "" end
  return tostring(v)
end

function Compat.InstanceInfo()
  local name, kind, difficulty, _, size, _, _, id = GetInstanceInfo()
  return table.concat({ infoText(name), infoText(kind), infoText(difficulty), infoText(size), infoText(id) }, "|")
end

-- The zone or instance the player is in, by name ("Wailing Caverns"): the way the guild
-- roster names a member's zone. Nil while the client doesn't say.
function Compat.ZoneText()
  local fn = GetRealZoneText or GetZoneText
  if not fn then return nil end
  local zone = fn()
  if ns.Secret(zone) or type(zone) ~= "string" or zone == "" then return nil end
  return zone
end

-- The map a unit is on: nil when unknown, false while the client hides it.
function Compat.MapForUnit(unit)
  if not (C_Map and C_Map.GetBestMapForUnit) then return nil end
  local map = C_Map.GetBestMapForUnit(unit)
  if ns.Secret(map) then return false end
  return map
end

-- Whether two units are the same; nil while the client hides it.
function Compat.IsUnit(a, b)
  local same = UnitIsUnit(a, b)
  if ns.Secret(same) then return nil end
  return same
end

-- Whether a unit is in combat; nil while the client hides it.
function Compat.InCombat(unit)
  if not UnitAffectingCombat then return nil end
  local v = UnitAffectingCombat(unit)
  if ns.Secret(v) then return nil end
  return v
end

-- Whether a group member is online; nil while the client hides it.
function Compat.IsConnected(unit)
  local v = UnitIsConnected(unit)
  if ns.Secret(v) then return nil end
  return v
end

-- Whether a unit is close enough for the client to show it (about 100 yards); nil while
-- the client hides it or can't say.
function Compat.IsVisible(unit)
  if not UnitIsVisible then return nil end
  local v = UnitIsVisible(unit)
  if ns.Secret(v) then return nil end
  return v and true or false
end

-- Whether a group member is within reach of the player's helpful spells (about 40
-- yards); nil while the client hides it or hasn't checked.
function Compat.InRange(unit)
  if not UnitInRange then return nil end
  local inRange, checked = UnitInRange(unit)
  if ns.AnySecret(inRange, checked) or not checked then return nil end
  return inRange and true or false
end

-- The game's own word on a group member's guild, a second opinion next to the guild
-- roster. Two answers: whether it's the player's guild (nil when the client hides that, or
-- has no such call), and how the unit's guild name compares with the player's: "same",
-- "other", "none" (no guild, or too far away for the client to know), or nil while hidden.
function Compat.UnitGuild(unit)
  local inMine, relation
  if UnitIsInMyGuild then
    local ok, v = pcall(UnitIsInMyGuild, unit)
    -- checked for a secret first: a hidden answer can't even be compared with nil
    if ok and not ns.Secret(v) and v ~= nil then inMine = v and true or false end
  end
  if GetGuildInfo then
    local ok, theirs = pcall(GetGuildInfo, unit)
    local mine = Compat.GuildName()
    if ok and not ns.AnySecret(theirs, mine) and type(mine) == "string" then
      if type(theirs) ~= "string" or theirs == "" then
        relation = "none"
      else
        relation = theirs == mine and "same" or "other"
      end
    end
  end
  return inMine, relation
end

-- Group member units, not including the player.
function Compat.GroupUnits()
  local units = {}
  if IsInRaid() then
    for i = 1, GetNumGroupMembers() do
      local unit = "raid" .. i
      local isMe = Compat.IsUnit(unit, "player")
      if isMe == nil then isMe = Compat.UnitFullName(unit) == ns.me end
      if not isMe then units[#units + 1] = unit end
    end
  elseif IsInGroup() then
    for i = 1, GetNumSubgroupMembers() do units[#units + 1] = "party" .. i end
  end
  return units
end

-- Spells and items -----------------------------------------------------------------
-- The Forever client has no GetSpellInfo. Newer clients look spells and items up through
-- C_Spell and C_Item, so these try those first and the old globals after.

-- A spell's name in the client's language, or nil.
function Compat.SpellName(id)
  if not id then return nil end
  if C_Spell and C_Spell.GetSpellName then
    local ok, name = pcall(C_Spell.GetSpellName, id)
    if ok and name then return name end
  end
  if C_Spell and C_Spell.GetSpellInfo then
    local ok, info = pcall(C_Spell.GetSpellInfo, id)
    if ok and type(info) == "table" and info.name then return info.name end
    if ok and type(info) == "string" then return info end
  end
  if GetSpellInfo then
    local ok, name = pcall(GetSpellInfo, id)
    if ok and name then return name end
  end
  return nil
end

-- GetItemInfo's returns: name, link, quality, item level, ... equip location (9th).
-- Nil until the client has the item cached.
function Compat.ItemInfo(item)
  local fn = (C_Item and C_Item.GetItemInfo) or GetItemInfo
  if not fn or not item then return nil end
  return fn(item)
end

-- GetItemInfoInstant's returns: id, type, subtype, equip location, icon, class id, subclass id.
function Compat.ItemInfoInstant(item)
  local fn = (C_Item and C_Item.GetItemInfoInstant) or GetItemInfoInstant
  if not fn or not item then return nil end
  return fn(item)
end

function Compat.ItemLevel(link)
  if not link then return 0 end
  local detailed = (C_Item and C_Item.GetDetailedItemLevelInfo) or GetDetailedItemLevelInfo
  if detailed then
    local level = detailed(link)
    if level then return level end
  end
  local _, _, _, level = Compat.ItemInfo(link)
  return level or 0
end

-- Professions -----------------------------------------------------------------------

-- Skill line ids: Pinto's profession numbers, and the secondary skills.
Compat.SKILL_LINES = {
  [171] = 1, [164] = 2, [333] = 3, [202] = 4, [182] = 5, [165] = 6, [186] = 7, [393] = 8, [197] = 9,
  [185] = "cook", [129] = "aid", [356] = "fish",
}

-- The character's professions as GetProfessions lists them (Forever has it):
-- { { skillLine, name, rank }, ... }. Nil when the client doesn't have it.
function Compat.Professions()
  if not (GetProfessions and GetProfessionInfo) then return nil end
  local list = {}
  local indices = { GetProfessions() }
  for i = 1, 8 do
    local index = indices[i]
    if index then
      local name, _, rank, _, _, _, skillLine = GetProfessionInfo(index)
      if name then list[#list + 1] = { skillLine = skillLine, name = name, rank = rank or 0 } end
    end
  end
  return list
end

-- The trade skill window that's open: its name and skill line id (nil when the client
-- doesn't say), or nil. Forever has no GetTradeSkillLine; C_TradeSkillUI gives both there,
-- for every profession, Enchanting included.
function Compat.TradeSkill()
  if GetTradeSkillLine then
    local name = GetTradeSkillLine()
    if not ns.Secret(name) and type(name) == "string" and name ~= "" and name ~= "UNKNOWN" then return name, nil end
  end
  if C_TradeSkillUI and C_TradeSkillUI.GetBaseProfessionInfo then
    local ok, info = pcall(C_TradeSkillUI.GetBaseProfessionInfo)
    if not ok or type(info) ~= "table" then return nil end
    local name, line = info.professionName, info.professionID
    if ns.AnySecret(name, line) or type(name) ~= "string" or name == "" then return nil end
    return name, (type(line) == "number" and line > 0) and line or nil
  end
  return nil
end

-- Whether the game marks a quest for several players: tagged Group or Elite in the quest
-- log, or with a suggested group size. C_QuestLog gives the tag as a table, older clients
-- as an id and a name.
local GROUP_TAG = 1   -- Enum.QuestTag.Group
local function taggedForGroup(questID)
  local ok, a, b
  if C_QuestLog and C_QuestLog.GetQuestTagInfo then
    ok, a = pcall(C_QuestLog.GetQuestTagInfo, questID)
    if ok and type(a) == "table" then
      if a.isElite == true or a.tagID == ((Enum and Enum.QuestTag and Enum.QuestTag.Group) or GROUP_TAG) then return true end
      return a.tagName == "Elite" or a.tagName == "Group"
    end
  end
  if GetQuestTagInfo then
    ok, a, b = pcall(GetQuestTagInfo, questID)
    if ok then return a == GROUP_TAG or b == "Elite" or b == "Group" end
  end
  return false
end

-- Quests in the log: { questID, group }, group being true for quests marked for several
-- players. Forever lists them through C_QuestLog, older clients through GetQuestLogTitle.
function Compat.QuestLog()
  local list = {}
  if C_QuestLog and C_QuestLog.GetNumQuestLogEntries and C_QuestLog.GetInfo then
    for i = 1, C_QuestLog.GetNumQuestLogEntries() or 0 do
      local info = C_QuestLog.GetInfo(i)
      if type(info) == "table" and not info.isHeader and info.questID and info.questID > 0 then
        list[#list + 1] = { questID = info.questID,
          group = (info.suggestedGroup or 0) > 1 or taggedForGroup(info.questID) }
      end
    end
  elseif GetNumQuestLogEntries and GetQuestLogTitle then
    for i = 1, GetNumQuestLogEntries() or 0 do
      local _, _, suggestedGroup, isHeader, _, _, _, questID = GetQuestLogTitle(i)
      if not isHeader and questID then
        list[#list + 1] = { questID = questID, group = (suggestedGroup or 0) > 1 or taggedForGroup(questID) }
      end
    end
  end
  return list
end

function Compat.ItemID(link)
  if not link then return nil end
  local id = link:match("item:(%d+)")
  return id and tonumber(id) or nil
end
