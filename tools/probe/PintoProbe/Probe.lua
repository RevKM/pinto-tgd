-- Pinto Probe: milestone 0. Checks what the Forever client offers Pinto, and logs the
-- events Pinto's tracking relies on while you play. Everything lands in PintoProbeDB,
-- which WoW writes to WTF\Account\<account>\SavedVariables\PintoProbe.lua on /reload or
-- logout.
--
-- Missing functions are what the probe is here to find, so it never raises an error:
-- problems go to PintoProbeDB.errors, with one line in the chat the first time.
--
-- Like newer clients, Forever keeps the combat log from addons (registering it gets the
-- addon blocked), and hands some values to addons as secrets that can't be read. The
-- probe never registers the combat log, notes which events carry secrets and where, and
-- logs every "blocked action" the game reports.
--
-- Forever has no realms: every character is "Name Surname". A little after login the
-- probe whispers itself an addon message as "Name Surname" and as "Name-Surname", and
-- sends one to the guild, to log which arrive and how the sender is named. The form
-- that doesn't arrive may get a "No player named ..." line in the chat.
--
--   /pintoprobe          checks the APIs now and prints a summary
--   /pintoprobe show     shows a test frame: rotation, masks, affine triangles, lines
--   /pintoprobe crypto   times one Ed25519 check
--   /pintoprobe reset    clears the log
local ADDON, ns = ...

local VERSION = 4
local PREFIX = "PintoProbe"
local MAX_SAMPLES = 8   -- the first few of each event
local RECENT = 4        -- and the latest few
local MAX_ERRORS = 40
local MAX_SPELLS = 300
local MAX_SNAPSHOTS = 12
local db
local inEncounter = false
local warned = false

local function out(text) DEFAULT_CHAT_FRAME:AddMessage("|cff5dcaa5Pinto Probe:|r " .. text) end

local function has(v) return v ~= nil end

-- Secret values: passed around freely, but reading one raises an error.
local isSecret = issecretvalue
local function secret(v) return isSecret ~= nil and isSecret(v) == true end
local function anySecret(...)
  if not isSecret then return false end
  for i = 1, select("#", ...) do
    if isSecret((select(i, ...))) then return true end
  end
  return false
end
-- A value that may be secret, safe to store.
local function safe(v)
  if secret(v) then return "<secret>" end
  return v
end

local function now()
  if GetServerTime then return GetServerTime() end
  if time then return time() end
  return 0
end

-- "C_Spell.GetSpellName" and the like; nil when any part is missing.
local function lookup(path)
  local v = _G
  for part in path:gmatch("[^%.]+") do
    if type(v) ~= "table" then return nil end
    v = v[part]
  end
  return v
end

-- A value as text. Lists keep their order, nils in the middle included. Only the first
-- argument counts, so str(f()) is safe when f returns several values.
local function text(v, depth)
  if secret(v) then return "<secret>" end
  if type(v) ~= "table" then return tostring(v) end
  if depth > 2 then return "{...}" end
  local n = 0
  for k in pairs(v) do
    if type(k) == "number" and k > n and k == math.floor(k) then n = k end
  end
  local parts, named = {}, {}
  for i = 1, n do parts[i] = text(v[i], depth + 1) end
  for k, x in pairs(v) do
    if not (type(k) == "number" and k >= 1 and k <= n and k == math.floor(k)) then
      named[#named + 1] = tostring(k) .. "=" .. text(x, depth + 1)
    end
  end
  table.sort(named)
  for _, p in ipairs(named) do parts[#parts + 1] = p end
  return "{" .. table.concat(parts, ", ") .. "}"
end
local function str(v) return text(v, 0) end

-- The arguments, with each secret replaced by "<secret>".
local function cleaned(...)
  local n = select("#", ...)
  local args = { ... }
  for i = 1, n do
    if secret(args[i]) then args[i] = "<secret>" end
  end
  return unpack(args, 1, n)
end

local function pack(...) return { n = select("#", ...), ... } end

local function count(t)
  local n = 0
  for _ in pairs(t) do n = n + 1 end
  return n
end

-- Errors ---------------------------------------------------------------------------------------

local function logError(where, err)
  if not db then return end
  db.errors = db.errors or {}
  local key = where .. ": " .. tostring(err)
  local e = db.errors[key]
  if e then
    e.count = e.count + 1
    return
  end
  if count(db.errors) >= MAX_ERRORS then return end
  db.errors[key] = { count = 1, at = now() }
  if not warned then
    warned = true
    out("noted a problem: " .. key .. ". Finding these is the probe's job, so just keep playing.")
  end
end

-- Runs fn; an error is logged under where instead of shown. Returns whether it worked.
local function try(where, fn, ...)
  local ok, err = pcall(fn, ...)
  if not ok then logError(where, err) end
  return ok
end

-- Spells and items, through whichever calls this client has -----------------------------------

local spellVia
local function spellName(id)
  if C_Spell and C_Spell.GetSpellName then
    local ok, name = pcall(C_Spell.GetSpellName, id)
    if ok and name then
      spellVia = "C_Spell.GetSpellName"
      return name
    end
  end
  if C_Spell and C_Spell.GetSpellInfo then
    local ok, info = pcall(C_Spell.GetSpellInfo, id)
    if ok and type(info) == "table" and info.name then
      spellVia = "C_Spell.GetSpellInfo"
      return info.name
    end
  end
  if GetSpellInfo then
    local ok, name = pcall(GetSpellInfo, id)
    if ok and name then
      spellVia = "GetSpellInfo"
      return name
    end
  end
  return nil
end

local function itemCall(name, item)
  local fn = (C_Item and C_Item[name]) or _G[name]
  if not fn then return nil end
  return fn(item)
end

-- A Lua pattern from a client message such as "%s has joined the guild."
local function patternOf(s)
  if type(s) ~= "string" then return nil end
  local p = s:gsub("([%(%)%.%+%-%*%?%[%]%^%$])", "%%%1"):gsub("%%s", "(.+)"):gsub("%%d", "(%%d+)")
  return "^" .. p .. "$"
end

-- What Pinto uses ------------------------------------------------------------------------------

-- Every WoW name Pinto reads (listed with luac), plus the Lua parts WoW provides. Some
-- have a fallback in Pinto (GetSpellInfo, GetItemInfo, GetNumSkillLines, ...).
local PINTO_API = {
  "BackdropTemplateMixin", "C_ChatInfo.InChatMessagingLockdown", "C_ChatInfo.RegisterAddonMessagePrefix",
  "C_ChatInfo.SendAddonMessage", "C_EncodingUtil.CompressString", "C_EncodingUtil.DecompressString",
  "C_GuildInfo.GuildRoster", "C_Item.GetDetailedItemLevelInfo", "C_Item.GetItemInfo", "C_Item.GetItemInfoInstant",
  "C_Map.GetBestMapForUnit", "C_Spell.GetSpellInfo", "C_Spell.GetSpellName", "C_Timer.After", "C_Timer.NewTicker",
  "CanInspect", "CheckInteractDistance", "CreateFrame", "DEFAULT_CHAT_FRAME", "ERR_GUILD_JOIN_S",
  "ERR_TRADE_COMPLETE", "Enum.CompressionMethod.Deflate", "Enum.SendAddonMessageResult", "GameLimitedMode_IsActive",
  "GameTooltip", "GetCursorPosition", "GetDetailedItemLevelInfo", "GetGuildInfo", "GetGuildRosterInfo",
  "GetGuildRosterLastOnline", "GetInstanceInfo", "GetInventoryItemLink", "GetItemInfo", "GetItemInfoInstant",
  "GetMoney", "GetNormalizedRealmName", "GetNumGroupMembers", "GetNumGuildMembers", "GetNumQuestLogEntries",
  "GetNumSkillLines", "GetNumSubgroupMembers", "GetProfessionInfo", "GetProfessions", "GetQuestLogTitle",
  "GetRealmName", "GetServerTime", "GetSkillLineInfo", "GetSpellInfo", "GetTime", "GetTradePlayerItemInfo",
  "GetTradePlayerItemLink", "GetTradeSkillLine", "GetTradeTargetItemInfo", "GetTradeTargetItemLink",
  "GuildControlGetNumRanks", "GuildControlGetRankName", "GuildRoster", "InCombatLockdown", "IsFishingLoot",
  "IsInGroup", "IsInGuild", "IsInInstance", "IsInRaid", "IsRestrictedAccount", "IsTrialAccount",
  "IsVeteranTrialAccount", "LOOT_ITEM_CREATED_SELF", "LOOT_ITEM_CREATED_SELF_MULTIPLE", "LOOT_ITEM_PUSHED_SELF",
  "LOOT_ITEM_PUSHED_SELF_MULTIPLE", "LOOT_ITEM_SELF", "LOOT_ITEM_SELF_MULTIPLE", "Minimap", "NotifyInspect", "OKAY",
  "RegisterAddonMessagePrefix", "SendAddonMessage", "SetGuildRosterShowOffline", "SlashCmdList",
  "StaticPopupDialogs", "StaticPopup_Show", "UIParent", "UISpecialFrames", "UNKNOWNOBJECT", "UnitAffectingCombat",
  "UnitIsConnected", "UnitIsUnit", "UnitLevel", "UnitName", "issecretvalue", "RegionalUniqueNamesEnabled",
  "UnitNameUnmodified", "C_QuestLog.GetNumQuestLogEntries", "C_QuestLog.GetInfo",
  "C_TradeSkillUI.GetBaseProfessionInfo",
  "bit.bxor", "bit.band", "bit.bor", "bit.bnot", "bit.lshift", "bit.rshift", "coroutine.create",
  "coroutine.resume", "coroutine.yield", "coroutine.status", "geterrorhandler", "unpack", "math.atan2",
  "debugprofilestop", "time", "date", "wipe",
}

-- Where newer clients moved some of those, and other calls Pinto could use.
local ALTERNATIVES = {
  "C_Spell.GetSpellName", "C_Spell.GetSpellInfo", "C_Item.GetItemInfo", "C_Item.GetItemInfoInstant",
  "C_Item.GetDetailedItemLevelInfo", "C_QuestLog.GetInfo", "C_QuestLog.GetNumQuestLogEntries",
  "C_QuestLog.GetTitleForQuestID", "GetProfessions", "GetProfessionInfo", "C_TradeSkillUI.GetTradeSkillLine",
  "C_TradeSkillUI.GetBaseProfessionInfo", "C_DateAndTime.GetCurrentCalendarTime",
  "C_DateAndTime.GetSecondsUntilDailyReset", "C_DateAndTime.GetSecondsUntilWeeklyReset", "GetQuestResetTime",
  "GetGameTime", "GetGuildBankMoney", "C_Bank", "C_Club.GetGuildClubId", "C_GuildInfo.IsGuildOfficer",
  "C_AddOns.GetAddOnMetadata", "GetAddOnMetadata", "C_Container.GetContainerItemInfo", "GetContainerItemInfo",
  "C_EventUtils.IsEventValid", "GetCraftDisplaySkillLine", "GetCraftSkillLine",
}

-- Namespaces whose every function is listed.
local DUMP_NAMESPACES = { "C_Spell", "C_Item", "C_QuestLog", "C_TradeSkillUI", "C_GuildInfo", "C_ChatInfo",
  "C_Map", "C_EncodingUtil", "C_Container", "C_PartyInfo", "C_SpellBook", "C_DateAndTime", "C_Club",
  "C_PlayerInfo", "C_Timer", "C_RestrictedActions", "C_Secrets", "C_EventUtils" }

-- Every widget method Pinto calls.
local METHODS = {
  "AddLine", "AddMessage", "ClearAllPoints", "CreateFontString", "CreateLine", "CreateTexture", "EnableMouse",
  "GetCenter", "GetChecked", "GetEffectiveScale", "GetFont", "GetFrameLevel", "GetHeight", "GetLeft", "GetName",
  "GetParent", "GetPoint", "GetStringHeight", "GetStringWidth", "GetText", "GetTextColor", "GetTop", "GetWidth",
  "Hide", "HighlightText", "HookScript", "IsShown", "IsVisible", "RegisterEvent", "RegisterForClicks",
  "RegisterForDrag", "SetAllPoints", "SetAlpha", "SetBackdrop", "SetBlendMode", "SetChecked", "SetClampedToScreen",
  "SetColorTexture", "SetEnabled", "SetEndPoint", "SetFocus", "SetFont", "SetFontObject", "SetFrameLevel",
  "SetFrameStrata", "SetHeight", "SetHighlightTexture", "SetJustifyH", "SetJustifyV", "SetMinMaxValues",
  "SetMovable", "SetObeyStepOnDrag", "SetOrientation", "SetOwner", "SetParent", "SetPoint", "SetRotation",
  "SetScale", "SetScript", "SetScrollChild", "SetShown", "SetSize", "SetStartPoint", "SetTexCoord", "SetText",
  "SetTextColor", "SetTexture", "SetThickness", "SetThumbTexture", "SetToplevel", "SetValue", "SetValueStep",
  "SetVertexColor", "SetWidth", "SetWordWrap", "Show", "StartMoving", "StopMovingOrSizing", "UnregisterEvent",
  "CreateMaskTexture", "AddMaskTexture", "SetAutoFocus", "RegisterUnitEvent",
}

-- Every event Pinto registers, then the ones only the probe watches. Never the combat
-- log: Forever blocks any addon that registers it.
local PINTO_EVENTS = { "ADDON_LOADED", "CHAT_MSG_ADDON", "CHAT_MSG_LOOT", "CHAT_MSG_SYSTEM", "ENCOUNTER_END",
  "GROUP_ROSTER_UPDATE", "GUILD_ROSTER_UPDATE", "LOOT_OPENED", "PLAYER_EQUIPMENT_CHANGED", "PLAYER_GUILD_UPDATE",
  "PLAYER_LEVEL_UP", "PLAYER_LOGIN", "PLAYER_LOGOUT", "PLAYER_MONEY", "PLAYER_REGEN_DISABLED",
  "PLAYER_REGEN_ENABLED", "QUEST_LOG_UPDATE", "QUEST_TURNED_IN", "SKILL_LINES_CHANGED", "TRADE_ACCEPT_UPDATE",
  "TRADE_CLOSED", "TRADE_PLAYER_ITEM_CHANGED", "TRADE_SHOW", "TRADE_TARGET_ITEM_CHANGED", "UI_INFO_MESSAGE",
  "UNIT_SPELLCAST_SUCCEEDED", "ZONE_CHANGED_NEW_AREA" }
local PROBE_EVENTS = { "ENCOUNTER_START", "BOSS_KILL", "QUEST_WATCH_UPDATE", "QUEST_ACCEPTED", "INSPECT_READY",
  "PLAYER_ENTERING_WORLD", "UNIT_SPELLCAST_SENT", "TRADE_SKILL_SHOW" }

-- Profession, gathering-rank and bandage spells.
local SPELL_IDS = { 2259, 2018, 7411, 4036, 2366, 2368, 3570, 11993, 2108, 2575, 2576, 3564, 10248, 8613, 8617,
  8618, 10768, 3908, 2550, 3273, 7620, 746 }

-- Static checks --------------------------------------------------------------------------------

local registered = {}   -- event -> whether this client let the probe register it

local function namespaces()
  local all, dump = {}, {}
  for k, v in pairs(_G) do
    if type(k) == "string" and k:sub(1, 2) == "C_" and type(v) == "table" then
      local n = 0
      for _, f in pairs(v) do
        if type(f) == "function" then n = n + 1 end
      end
      all[k] = n
    end
  end
  for _, name in ipairs(DUMP_NAMESPACES) do
    local t = _G[name]
    if type(t) == "table" then
      local fns = {}
      for f, v in pairs(t) do
        if type(v) == "function" then fns[#fns + 1] = f end
      end
      table.sort(fns)
      dump[name] = table.concat(fns, " ")
    else
      dump[name] = "missing"
    end
  end
  return all, dump
end

local function widgetMethods()
  local holder = CreateFrame("Frame")
  holder:Hide()
  local order, made = {}, {}
  local function add(name, make)
    local ok, w = pcall(make)
    order[#order + 1] = name
    made[name] = (ok and w) or false
  end
  add("Frame", function() return holder end)
  add("Button", function() return CreateFrame("Button", nil, holder) end)
  add("CheckButton", function() return CreateFrame("CheckButton", nil, holder) end)
  add("Slider", function() return CreateFrame("Slider", nil, holder) end)
  add("EditBox", function()
    local e = CreateFrame("EditBox", nil, holder)
    e:SetAutoFocus(false)
    e:Hide()
    return e
  end)
  add("ScrollFrame", function() return CreateFrame("ScrollFrame", nil, holder) end)
  add("Texture", function() return holder:CreateTexture() end)
  add("FontString", function() return holder:CreateFontString() end)
  add("Line", function() return holder:CreateLine() end)
  add("MaskTexture", function() return holder:CreateMaskTexture() end)
  add("GameTooltip", function() return GameTooltip end)
  add("ChatFrame", function() return DEFAULT_CHAT_FRAME end)
  local r = { made = {}, missing = {}, where = {} }
  for _, name in ipairs(order) do r.made[name] = made[name] and true or false end
  for _, m in ipairs(METHODS) do
    local list = {}
    for _, name in ipairs(order) do
      local w = made[name]
      if w and type(w[m]) == "function" then list[#list + 1] = name end
    end
    if #list == 0 then r.missing[#r.missing + 1] = m end
    r.where[m] = table.concat(list, " ")
  end
  return r
end

local function check()
  local r = { probe = VERSION, failed = {} }
  local function section(name, fn)
    local ok, err = pcall(fn)
    if not ok then
      r.failed[name] = tostring(err)
      logError("check " .. name, err)
    end
  end

  section("build", function()
    local version, build, date_, interface = GetBuildInfo()
    r.build = { version = version, build = build, date = date_, interface = interface }
  end)

  -- GetServerTime is UTC; GetGameTime and the calendar are the server's own clock
  section("time", function()
    local st = now()
    local utc = date("!*t", st)
    r.time = { serverTime = st, utcHour = utc.hour, utcMinute = utc.min, date = date("!%Y-%m-%d %H:%M", st) }
    if GetGameTime then
      local gh, gm = GetGameTime()
      r.time.gameHour, r.time.gameMinute = gh, gm
      r.time.offsetHours = ((gh - utc.hour + 36) % 24) - 12
    end
    local cal = C_DateAndTime and C_DateAndTime.GetCurrentCalendarTime and C_DateAndTime.GetCurrentCalendarTime()
    if cal then
      r.time.calendar = str(cal)
      if not r.time.offsetHours and cal.hour then r.time.offsetHours = ((cal.hour - utc.hour + 36) % 24) - 12 end
    end
    if C_DateAndTime and C_DateAndTime.GetSecondsUntilDailyReset then
      r.time.dailyResetIn = C_DateAndTime.GetSecondsUntilDailyReset()
    elseif GetQuestResetTime then
      r.time.dailyResetIn = GetQuestResetTime()
    end
    if C_DateAndTime and C_DateAndTime.GetSecondsUntilWeeklyReset then
      r.time.weeklyResetIn = C_DateAndTime.GetSecondsUntilWeeklyReset()
    end
  end)

  section("accounts", function()
    r.accounts = {}
    for _, name in ipairs({ "IsTrialAccount", "IsVeteranTrialAccount", "IsRestrictedAccount", "GameLimitedMode_IsActive" }) do
      local fn = _G[name]
      if fn then
        local ok, v = pcall(fn)
        r.accounts[name] = ok and tostring(v) or ("error: " .. tostring(v))
      else
        r.accounts[name] = "missing"
      end
    end
  end)

  section("guildBank", function()
    r.guildBank = { GetGuildBankMoney = has(GetGuildBankMoney), GuildBankFrame = has(GuildBankFrame) }
    if GetGuildBankMoney then r.guildBank.money = GetGuildBankMoney() end
  end)

  section("roster", function()
    if not IsInGuild() then return end
    if SetGuildRosterShowOffline then SetGuildRosterShowOffline(true) end
    local total, online = GetNumGuildMembers()
    r.roster = { total = total, online = online, guild = str({ GetGuildInfo("player") }), rows = {} }
    for i = 1, math.min(5, total or 0) do
      r.roster.rows[i] = { info = str({ GetGuildRosterInfo(i) }),
        lastOnline = GetGuildRosterLastOnline and str({ GetGuildRosterLastOnline(i) }) or "missing" }
    end
    r.ranks = {}
    if GuildControlGetNumRanks then
      for i = 1, GuildControlGetNumRanks() do r.ranks[i] = GuildControlGetRankName(i) end
    end
  end)

  -- how the client names the player, in every call that does
  section("names", function()
    r.names = { UnitName = str({ UnitName("player") }), realm = GetRealmName(),
      normalizedRealm = GetNormalizedRealmName and GetNormalizedRealmName() or "missing",
      UnitNameUnmodified = UnitNameUnmodified and str({ UnitNameUnmodified("player") }) or "missing",
      UnitFullName = UnitFullName and str({ UnitFullName("player") }) or "missing",
      GetUnitName = GetUnitName and str(GetUnitName("player", true)) or "missing",
      regionalUnique = RegionalUniqueNamesEnabled and str(RegionalUniqueNamesEnabled()) or "missing",
      showSurname = (C_PlayerInfo and C_PlayerInfo.ShouldDisplaySurname) and str(C_PlayerInfo.ShouldDisplaySurname())
        or "missing" }
    -- the player's own row in the guild roster, found by GUID
    local guid = UnitGUID and UnitGUID("player")
    if guid and not secret(guid) and IsInGuild() then
      for i = 1, (GetNumGuildMembers()) or 0 do
        local row = pack(GetGuildRosterInfo(i))
        if row[17] == guid then
          r.names.roster = str(row[1])
          if Ambiguate then
            r.names.ambiguate = str(Ambiguate(row[1], "none")) .. " / " .. str(Ambiguate(row[1], "short"))
          end
          break
        end
      end
    end
  end)

  section("api", function()
    r.api, r.missing = {}, {}
    for _, path in ipairs(PINTO_API) do
      local v = lookup(path)
      r.api[path] = type(v)
      if v == nil then r.missing[#r.missing + 1] = path end
    end
    r.alternatives = {}
    for _, path in ipairs(ALTERNATIVES) do r.alternatives[path] = type(lookup(path)) end
    r.namespaces, r.namespaceFunctions = namespaces()
  end)

  section("events", function()
    r.unknownEvents = {}
    for _, e in ipairs(PINTO_EVENTS) do
      if registered[e] == false then r.unknownEvents[#r.unknownEvents + 1] = e end
    end
    for _, e in ipairs(PROBE_EVENTS) do
      if registered[e] == false then r.unknownEvents[#r.unknownEvents + 1] = e .. " (probe only)" end
    end
  end)

  section("strings", function()
    r.strings = {}
    for _, name in ipairs({ "ERR_GUILD_JOIN_S", "ERR_TRADE_COMPLETE", "LOOT_ITEM_SELF", "LOOT_ITEM_SELF_MULTIPLE",
      "LOOT_ITEM_PUSHED_SELF", "LOOT_ITEM_PUSHED_SELF_MULTIPLE", "LOOT_ITEM_CREATED_SELF",
      "LOOT_ITEM_CREATED_SELF_MULTIPLE", "UNKNOWNOBJECT", "OKAY" }) do
      r.strings[name] = _G[name] or "missing"
    end
  end)

  section("bit", function()
    local ok3, x3 = pcall(bit.bxor, 1, 2, 4)
    r.bit = { bnot0 = bit.bnot(0), lshift31 = bit.lshift(1, 31), bxor3args = ok3 and x3 or "error",
      band = bit.band(0xF0F0, 0xFF00), rshift = bit.rshift(0x80000000, 31) }
  end)

  section("widgets", function()
    local f = CreateFrame("Frame")
    local t = f:CreateTexture()
    r.widgets = { SetRotation = has(t.SetRotation), CreateMaskTexture = has(f.CreateMaskTexture),
      CreateLine = has(f.CreateLine), AddMaskTexture = has(t.AddMaskTexture),
      SetTexCoord8 = pcall(t.SetTexCoord, t, 0, 0, 0, 1, 1, 0, 1, 1), RegisterUnitEvent = has(f.RegisterUnitEvent) }
    r.methods = widgetMethods()
  end)

  section("windows", function()
    r.windows = {}
    for _, name in ipairs({ "WorldMapFrame", "QuestLogFrame", "QuestMapFrame", "CharacterFrame" }) do
      local w = _G[name]
      r.windows[name] = (w and w.GetSize) and str({ w:GetSize() }) or "missing"
    end
  end)

  -- both ways a client can list professions, when it has them
  section("skills", function()
    r.skills = {}
    if GetNumSkillLines and GetSkillLineInfo then
      for i = 1, GetNumSkillLines() do r.skills[i] = str({ GetSkillLineInfo(i) }) end
    end
    if GetProfessions and GetProfessionInfo then
      local list = pack(GetProfessions())
      r.professions = { indices = str(list) }
      for i = 1, list.n do
        if list[i] then r.professions[i] = str({ GetProfessionInfo(list[i]) }) end
      end
    end
  end)

  section("restrictions", function()
    r.restrictions = { issecretvalue = has(issecretvalue), sendResults = str(Enum and Enum.SendAddonMessageResult) }
    if C_ChatInfo and C_ChatInfo.InChatMessagingLockdown then
      r.restrictions.chatLockdownNow = str(C_ChatInfo.InChatMessagingLockdown())
    else
      r.restrictions.chatLockdownNow = "missing"
    end
    r.restrictions.blockedActions = db.forbidden and #db.forbidden or 0
  end)

  section("spells", function()
    r.spells = { names = {}, GetSpellInfo = has(GetSpellInfo) }
    for _, id in ipairs(SPELL_IDS) do r.spells.names[id] = spellName(id) or "missing" end
    r.spells.via = spellVia or "none"
    if C_Spell and C_Spell.GetSpellInfo then r.spells.shape = str(C_Spell.GetSpellInfo(746)) end
  end)

  section("gear", function()
    r.items = { via = (C_Item and C_Item.GetItemInfo) and "C_Item" or (GetItemInfo and "globals") or "none" }
    r.gear = {}
    for slot = 1, 19 do
      local link = GetInventoryItemLink("player", slot)
      if link then
        local info = pack(itemCall("GetItemInfo", link))
        r.gear[slot] = { link = link, itemLevel = info[4], equipLoc = info[9],
          detailed = str(itemCall("GetDetailedItemLevelInfo", link)),
          instant = str({ itemCall("GetItemInfoInstant", link) }) }
      end
    end
  end)

  section("quests", function()
    r.quests = {}
    if GetNumQuestLogEntries and GetQuestLogTitle then
      for i = 1, math.min(8, GetNumQuestLogEntries()) do r.quests[i] = str({ GetQuestLogTitle(i) }) end
    elseif C_QuestLog and C_QuestLog.GetNumQuestLogEntries and C_QuestLog.GetInfo then
      for i = 1, math.min(8, C_QuestLog.GetNumQuestLogEntries()) do r.quests[i] = str(C_QuestLog.GetInfo(i)) end
      r.questsVia = "C_QuestLog"
    end
  end)

  db.checks = r
  return r
end

local function list(t, limit)
  if #t == 0 then return "none" end
  local shown = {}
  for i = 1, math.min(limit, #t) do shown[i] = t[i] end
  local s = table.concat(shown, ", ")
  if #t > limit then s = s .. string.format(" and %d more", #t - limit) end
  return s
end

local function summary(r)
  local function line(fn)
    local ok, text = pcall(fn)
    if ok and text then out(text) end
  end
  line(function() return string.format("probe %d, interface %s, client %s", VERSION, tostring(r.build.interface), tostring(r.build.version)) end)
  line(function()
    if not r.time.offsetHours then return "server clock: no way to read it" end
    return string.format("server clock is UTC%+d", r.time.offsetHours)
  end)
  line(function() return "spell names come from " .. r.spells.via .. ", item details from " .. r.items.via end)
  line(function()
    return string.format("of the %d names Pinto uses, missing: %s", #PINTO_API, list(r.missing, 8))
  end)
  line(function() return "events this client doesn't have: " .. list(r.unknownEvents, 8) end)
  line(function() return "widget methods missing: " .. list(r.methods.missing, 8) end)
  line(function()
    return "rotation " .. tostring(r.widgets.SetRotation) .. ", masks " .. tostring(r.widgets.CreateMaskTexture)
      .. ", lines " .. tostring(r.widgets.CreateLine) .. ", 8-point texcoords " .. tostring(r.widgets.SetTexCoord8)
  end)
  line(function()
    return "compression " .. tostring(r.api["C_EncodingUtil.CompressString"] == "function") .. ", bit.bnot(0) = "
      .. tostring(r.bit.bnot0) .. ", 3-argument bxor = " .. tostring(r.bit.bxor3args)
  end)
  line(function()
    local n = r.names
    return string.format("you are %s in the roster, %s to UnitName; regional names %s",
      tostring(n.roster or "not found"), n.UnitName, n.regionalUnique)
  end)
  line(function()
    local w = db.whisperTest
    if not w then return "the whisper test runs a few seconds after login" end
    local got = {}
    for text in pairs(w.arrived) do got[#got + 1] = text end
    table.sort(got)
    return "addon messages to yourself that arrived: " .. list(got, 4)
  end)
  line(function()
    local hidden = db.secrets and count(db.secrets) or 0
    return string.format("secret values %s (in %d kinds of event so far), chat lockdown now %s, blocked actions %d",
      tostring(r.restrictions.issecretvalue), hidden, r.restrictions.chatLockdownNow, r.restrictions.blockedActions)
  end)
  line(function()
    local failed = {}
    for name in pairs(r.failed) do failed[#failed + 1] = name end
    table.sort(failed)
    local n = db.errors and count(db.errors) or 0
    return string.format("checks that failed: %s; problems noted so far: %d", list(failed, 8), n)
  end)
  out("Saved. Play a little (see the README), then /reload and send PintoProbe.lua from SavedVariables.")
end

-- Events --------------------------------------------------------------------------------------

local function sample(event, ...)
  db.events = db.events or {}
  local e = db.events[event]
  if not e then
    e = { count = 0, samples = {} }
    db.events[event] = e
  end
  e.count = e.count + 1
  local args = pack(...)
  local strs = {}
  for i = 1, args.n do strs[i] = str(args[i]) end
  local s = { t = now(), args = strs, encounter = inEncounter or nil }
  if #e.samples < MAX_SAMPLES then
    e.samples[#e.samples + 1] = s
  else
    e.recent = e.recent or {}
    e.recent[(e.count - MAX_SAMPLES - 1) % RECENT + 1] = s
  end
end

-- Only the first few, without counting: for events that fire constantly.
local function sampleFew(event, ...)
  local e = db.events and db.events[event]
  if e and #e.samples >= MAX_SAMPLES then return end
  sample(event, ...)
end

local function snapshot(key, fn)
  db[key] = db[key] or {}
  if #db[key] >= MAX_SNAPSHOTS then return end
  local ok, s = pcall(fn)
  if ok then
    db[key][#db[key] + 1] = s
  else
    logError(key, s)
  end
end

local function tradeSnapshot()
  local s = { player = {}, target = {}, partner = str({ UnitName("NPC") }) }
  for i = 1, 7 do
    s.player[i] = { info = str({ GetTradePlayerItemInfo(i) }), link = GetTradePlayerItemLink(i) }
    s.target[i] = { info = str({ GetTradeTargetItemInfo(i) }), link = GetTradeTargetItemLink(i) }
  end
  return s
end

local function groupSnapshot()
  local units = {}
  local raid = IsInRaid()
  local n = raid and GetNumGroupMembers() or GetNumSubgroupMembers()
  local getMap = C_Map and C_Map.GetBestMapForUnit
  for i = 1, n do
    local unit = raid and ("raid" .. i) or ("party" .. i)
    units[#units + 1] = { unit = unit, name = str({ UnitName(unit) }), guid = str(UnitGUID and UnitGUID(unit)),
      map = str(getMap and getMap(unit) or "missing"), myMap = str(getMap and getMap("player") or "missing"),
      visible = str(UnitIsVisible(unit)), connected = str(UnitIsConnected(unit)),
      inCombat = str(UnitAffectingCombat(unit)), isTarget = str(UnitIsUnit("target", unit)),
      raidInfo = raid and str({ GetRaidRosterInfo(i) }) or nil }
  end
  return { units = units, instance = str({ IsInInstance() }), instanceInfo = str({ GetInstanceInfo() }),
    lockdown = C_ChatInfo and C_ChatInfo.InChatMessagingLockdown and str(C_ChatInfo.InChatMessagingLockdown()) or "missing",
    t = now() }
end

-- Which group member is the target: "party2", "none", or "hidden" while the client hides it.
local function targetInGroup()
  local raid = IsInRaid()
  local n = raid and GetNumGroupMembers() or GetNumSubgroupMembers()
  for i = 1, n do
    local unit = raid and ("raid" .. i) or ("party" .. i)
    local same = UnitIsUnit("target", unit)
    if secret(same) then return "hidden" end
    if same then return unit end
  end
  return "none"
end

-- Who in the group is in combat: "player=true party1=false party2=<secret>".
local function combatStates()
  local parts = { "player=" .. str(UnitAffectingCombat("player")) }
  local raid = IsInRaid()
  local n = raid and GetNumGroupMembers() or GetNumSubgroupMembers()
  for i = 1, n do
    local unit = raid and ("raid" .. i) or ("party" .. i)
    parts[#parts + 1] = unit .. "=" .. str(UnitAffectingCombat(unit))
  end
  return table.concat(parts, " ")
end

local function lockdownState()
  if C_ChatInfo and C_ChatInfo.InChatMessagingLockdown then return str(C_ChatInfo.InChatMessagingLockdown()) end
  return "missing"
end

-- Addon messages to ourselves: whispers naming us "Name Surname" and "Name-Surname", and
-- one to the guild. What arrives, and the sender's name, land in db.whisperTest.
local function whisperTest()
  if not (C_ChatInfo and C_ChatInfo.SendAddonMessage) then return end
  local name, surname = (UnitNameUnmodified or UnitName)("player")
  if not name or secret(name) or secret(surname) then return end
  local full = (surname and surname ~= "") and (name .. " " .. surname) or name
  local w = { sent = {}, arrived = {}, system = {}, started = now() }
  db.whisperTest = w
  local forms = { { "space", full } }
  if full:find(" ", 1, true) then forms[2] = { "hyphen", (full:gsub(" ", "-")) } end
  for _, f in ipairs(forms) do
    local ok, result = pcall(C_ChatInfo.SendAddonMessage, PREFIX, "w:" .. f[1], "WHISPER", f[2])
    w.sent[f[1]] = { target = f[2], ok = ok, result = str(result) }
  end
  if IsInGuild() then
    local ok, result = pcall(C_ChatInfo.SendAddonMessage, PREFIX, "g:guild", "GUILD")
    w.sent.guild = { ok = ok, result = str(result) }
  end
end

-- The open trade skill, as C_TradeSkillUI names it.
local function tradeSkillInfo()
  if not (C_TradeSkillUI and C_TradeSkillUI.GetBaseProfessionInfo) then return "missing" end
  local ok, info = pcall(C_TradeSkillUI.GetBaseProfessionInfo)
  if not ok then return "error" end
  return str(info)
end

-- Events that carry secret values: how often, which arguments, and where.
local function noteSecret(event, ...)
  db.secrets = db.secrets or {}
  local s = db.secrets[event]
  if not s then
    s = { count = 0, args = {}, where = {} }
    db.secrets[event] = s
  end
  s.count = s.count + 1
  for i = 1, select("#", ...) do
    if secret((select(i, ...))) then s.args[i] = true end
  end
  local _, kind = IsInInstance()
  local where = tostring(kind or "none")
  if inEncounter then where = where .. "+encounter" end
  if safe(UnitAffectingCombat("player")) == true then where = where .. "+combat" end
  s.where[where] = (s.where[where] or 0) + 1
end

-- "Blocked action" reports from the game, for this or any addon. They can arrive before
-- the saved log loads, so they wait in a list until then.
local blockedEarly = {}
local registering   -- the event the probe is registering right now, if any
local function noteBlocked(event, ...)
  local entry = { event = event, args = str(pack(...)), during = registering, t = now() }
  if not db then
    blockedEarly[#blockedEarly + 1] = entry
    return
  end
  db.forbidden = db.forbidden or {}
  if #db.forbidden < 20 then db.forbidden[#db.forbidden + 1] = entry end
end

local function noteSpell(spellID)
  if not spellID then return end
  db.spells = db.spells or {}
  local s = db.spells[spellID]
  if not s then
    if count(db.spells) >= MAX_SPELLS then return end
    s = { name = spellName(spellID) or "?", count = 0 }
    db.spells[spellID] = s
  end
  s.count = s.count + 1
end

local function noteEncounter(source, id, name, difficulty, size, success)
  db.encounters = db.encounters or {}
  local key = source .. ":" .. tostring(id)
  local e = db.encounters[key] or { kills = 0, wipes = 0 }
  local inst = pack(GetInstanceInfo())
  e.name, e.difficulty, e.size = name, difficulty, size
  e.instance, e.instanceID = inst[1], inst[8]
  if success == 1 or success == true then e.kills = e.kills + 1 else e.wipes = e.wipes + 1 end
  db.encounters[key] = e
end

local patterns
local function messagePatterns()
  if not patterns then
    patterns = { join = patternOf(ERR_GUILD_JOIN_S), created = patternOf(LOOT_ITEM_CREATED_SELF),
      createdMany = patternOf(LOOT_ITEM_CREATED_SELF_MULTIPLE) }
  end
  return patterns
end

local firstAid
local loginChecked = false
local handle

local function onEvent(_, event, ...)
  if event == "ADDON_ACTION_FORBIDDEN" or event == "ADDON_ACTION_BLOCKED" then
    noteBlocked(event, ...)
    return
  end
  if event == "ADDON_LOADED" then
    if ... == ADDON then
      PintoProbeDB = PintoProbeDB or {}
      db = PintoProbeDB
      -- a new probe version starts a fresh log
      if db.probe ~= VERSION then wipe(db) end
      db.probe = VERSION
      db.forbidden = db.forbidden or {}
      for _, entry in ipairs(blockedEarly) do
        if #db.forbidden < 20 then db.forbidden[#db.forbidden + 1] = entry end
      end
      blockedEarly = {}
      if C_ChatInfo and C_ChatInfo.RegisterAddonMessagePrefix then C_ChatInfo.RegisterAddonMessagePrefix(PREFIX) end
    end
    return
  end
  if not db then return end
  -- secrets can't be read: note which arguments and where, then go on without them
  if anySecret(...) then
    noteSecret(event, ...)
    return handle(event, cleaned(...))
  end
  return handle(event, ...)
end

function handle(event, ...)
  if event == "UNIT_SPELLCAST_SUCCEEDED" then
    local unit, _, spellID = ...
    if unit == "player" then
      noteSpell(spellID)
      sampleFew(event, ...)
      -- bandages: Pinto counts a First Aid cast on a guildie in the group who's the target
      firstAid = firstAid or spellName(746) or "First Aid"
      if spellName(spellID) == firstAid then
        sample("FIRST_AID_CAST", spellID, str(UnitName("target")), targetInGroup())
      end
    end
    return
  end
  if event == "UNIT_SPELLCAST_SENT" then
    if ... == "player" then sampleFew(event, ...) end
    return
  end
  if event == "PLAYER_REGEN_DISABLED" then
    -- fights together: Pinto checks who else in the group is in combat, 2 seconds in
    if IsInGroup() then
      C_Timer.After(2, function()
        try("fight together", function() sample("FIGHT_TOGETHER", select(2, IsInInstance()), combatStates()) end)
      end)
    end
    sample(event)
    return
  end
  if event == "CHAT_MSG_ADDON" then
    local prefix, text, channel, sender, target = ...
    if prefix == PREFIX then
      sample(event, ...)
      if db.whisperTest and type(text) == "string" then
        db.whisperTest.arrived[text] = { channel = str(channel), sender = str(sender), target = str(target), t = now() }
      end
    end
    return
  end
  if event == "PLAYER_ENTERING_WORLD" then
    if not loginChecked then
      loginChecked = true
      -- a quiet check a little after login, in case /pintoprobe is forgotten
      C_Timer.After(8, function() try("check after login", check) end)
      C_Timer.After(12, function() try("whisper test", whisperTest) end)
      out("version " .. VERSION .. " is logging. Type /pintoprobe for a summary.")
    end
  elseif event == "TRADE_SKILL_SHOW" then
    sample("TRADE_SKILL_INFO", tradeSkillInfo())
  elseif event == "ENCOUNTER_START" then
    inEncounter = true
    -- do addon messages work during boss fights? whisper ourselves, unless the client
    -- already says they're locked down
    local locked = lockdownState()
    if locked == "true" then
      sample("BOSS_FIGHT_SEND", "lockdown")
    elseif C_ChatInfo and C_ChatInfo.SendAddonMessage then
      -- to ourselves, named the way the whisper test found arrives (else "Name Surname")
      local w = db.whisperTest
      local form = w and ((w.arrived["w:space"] and "space") or (w.arrived["w:hyphen"] and "hyphen"))
      local target = form and w.sent[form] and w.sent[form].target
      if not target then
        local name, surname = (UnitNameUnmodified or UnitName)("player")
        target = (surname and surname ~= "" and not secret(surname)) and (name .. " " .. surname) or name
      end
      local ok, result = pcall(C_ChatInfo.SendAddonMessage, PREFIX, "boss-test", "WHISPER", target)
      sample("BOSS_FIGHT_SEND", locked, ok, result)
    end
  elseif event == "ENCOUNTER_END" then
    inEncounter = false
    noteEncounter("ENCOUNTER_END", ...)
  elseif event == "BOSS_KILL" then
    local id, name = ...
    noteEncounter("BOSS_KILL", id, name, nil, nil, 1)
  elseif event == "TRADE_SHOW" or event == "TRADE_ACCEPT_UPDATE" then
    snapshot("trades", tradeSnapshot)
  elseif event == "GROUP_ROSTER_UPDATE" or event == "ZONE_CHANGED_NEW_AREA" then
    if IsInGroup() then snapshot("groups", groupSnapshot) end
    if event == "ZONE_CHANGED_NEW_AREA" then
      -- does the chat lockdown cover whole instances, or only encounters?
      sample("CHAT_LOCKDOWN_BY_ZONE", select(2, IsInInstance()), lockdownState())
    end
  elseif event == "LOOT_OPENED" then
    sample("LOOT_OPENED_FISHING", IsFishingLoot and IsFishingLoot() or "missing")
  elseif event == "CHAT_MSG_SYSTEM" then
    local text = ...
    local p = messagePatterns()
    if type(text) == "string" then
      -- replies to the whisper test, like "No player named ..."
      local w = db.whisperTest
      if w and now() - w.started < 30 and #w.system < 5 then w.system[#w.system + 1] = text end
      if p.join and text:match(p.join) then
        sample("GUILD_JOIN_MESSAGE", text)
      elseif text:lower():find("guild", 1, true) then
        sample("GUILD_SYSTEM_MESSAGE", text)
      end
    end
  elseif event == "UI_INFO_MESSAGE" then
    local a, b = ...
    local text = type(b) == "string" and b or a
    if type(text) == "string" then
      if text:find("%d+/%d+") then sample("QUEST_PROGRESS", ...) end
      if text == ERR_TRADE_COMPLETE then sample("TRADE_COMPLETE_MESSAGE", ...) end
    end
  elseif event == "CHAT_MSG_LOOT" then
    local text = ...
    local p = messagePatterns()
    if type(text) == "string" and ((p.created and text:match(p.created)) or (p.createdMany and text:match(p.createdMany))) then
      sample("CRAFTED", text, GetTradeSkillLine and GetTradeSkillLine() or "missing", tradeSkillInfo())
    end
  end
  sample(event, ...)
end

local frame = CreateFrame("Frame")
frame:SetScript("OnEvent", function(self, event, ...)
  local ok, err = pcall(onEvent, self, event, ...)
  if not ok then logError(event, err) end
end)
-- the game's "blocked action" reports first, so any that follow are logged
for _, e in ipairs({ "ADDON_ACTION_FORBIDDEN", "ADDON_ACTION_BLOCKED" }) do pcall(frame.RegisterEvent, frame, e) end
frame:RegisterEvent("ADDON_LOADED")
for _, events in ipairs({ PINTO_EVENTS, PROBE_EVENTS }) do
  for _, e in ipairs(events) do
    registering = e
    registered[e] = pcall(frame.RegisterEvent, frame, e) and true or false
  end
end
registering = nil

-- The visual test ------------------------------------------------------------------------------

local test
local function showTest()
  if test then
    test:SetShown(not test:IsShown())
    return
  end
  test = CreateFrame("Frame", "PintoProbeTest", UIParent)
  test:SetSize(420, 200)
  test:SetPoint("CENTER")
  test:SetFrameStrata("HIGH")
  local bg = test:CreateTexture(nil, "BACKGROUND")
  bg:SetAllPoints()
  bg:SetColorTexture(0.1, 0.1, 0.1, 0.9)
  local path = "Interface\\AddOns\\PintoProbe\\"
  local parts = {}
  -- 1. a 80x20 bar turned 30 degrees: should look like a rotated rectangle, not squashed
  parts.rotation = try("show rotation", function()
    local r = test:CreateTexture(nil, "ARTWORK")
    r:SetSize(80, 20)
    r:SetPoint("CENTER", test, "TOPLEFT", 70, -70)
    r:SetColorTexture(0.36, 0.79, 0.65, 1)
    r:SetRotation(math.rad(30))
  end)
  -- 2. an ellipse and a sheared triangle, drawn with 8-point texture coordinates
  parts.ellipse = try("show ellipse", function()
    local e = test:CreateTexture(nil, "ARTWORK")
    e:SetTexture(path .. "Circle", "CLAMP", "CLAMP", "LINEAR")
    e:SetPoint("TOPLEFT", test, "TOPLEFT", 150, -40)
    e:SetSize(80, 60)
    e:SetTexCoord(0, 0, 0, 1, 1, 0, 1, 1)
    e:SetVertexColor(0.98, 0.78, 0.46)
  end)
  parts.triangle = try("show triangle", function()
    local tri = test:CreateTexture(nil, "ARTWORK")
    tri:SetTexture(path .. "Tri", "CLAMP", "CLAMP", "LINEAR")
    tri:SetPoint("TOPLEFT", test, "TOPLEFT", 260, -40)
    tri:SetSize(80, 80)
    -- should look like a slanted triangle with clean edges
    tri:SetTexCoord(0.0, 0.0, -0.3, 1.0, 1.0, 0.0, 0.7, 1.0)
    tri:SetVertexColor(0.94, 0.6, 0.48)
  end)
  -- 3. a square masked to a circle
  parts.mask = try("show mask", function()
    local sq = test:CreateTexture(nil, "ARTWORK")
    sq:SetColorTexture(0.3, 0.55, 0.85, 1)
    sq:SetSize(60, 60)
    sq:SetPoint("TOPLEFT", test, "TOPLEFT", 40, -120)
    local mask = test:CreateMaskTexture()
    mask:SetTexture(path .. "Circle", "CLAMPTOBLACKADDITIVE", "CLAMPTOBLACKADDITIVE")
    mask:SetAllPoints(sq)
    sq:AddMaskTexture(mask)
  end)
  -- 4. a line, 3 pixels thick
  parts.line = try("show line", function()
    local l = test:CreateLine(nil, "ARTWORK")
    l:SetColorTexture(1, 1, 1, 1)
    l:SetThickness(3)
    l:SetStartPoint("TOPLEFT", test, 150, -140)
    l:SetEndPoint("TOPLEFT", test, 380, -180)
  end)
  db.visual = parts
  local label = test:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
  label:SetPoint("BOTTOM", 0, 6)
  label:SetText("rotated bar | ellipse | slanted triangle | circle mask | line   (type /pintoprobe show to close)")
  test:Show()
end

local function timeCrypto()
  if not ns.Crypto then
    out("Crypto.lua is missing from this build of the probe.")
    return
  end
  -- RFC 8032 TEST 1
  local pk = ns.Crypto.unhex("d75a980182b10ab7d54bfed3c964073a0ee172f3daa62325af021a68f707511a")
  local sig = ns.Crypto.unhex("e5564300c360ac729086e2cc806e828a84877f1eb8e5d974d873e065224901555fb8821590a33bacc61e39701cf9b46bd25bf5f0595bbe24655141438e7a100b")
  local t0 = debugprofilestop()
  local ok = ns.Crypto.verify(pk, "", sig)
  local whole = debugprofilestop() - t0
  local step = ns.Crypto.verifier(pk, "", sig)
  local steps, longest, result = 0, 0, nil
  repeat
    local s0 = debugprofilestop()
    result = step()
    local d = debugprofilestop() - s0
    steps = steps + 1
    if d > longest then longest = d end
  until result ~= nil or steps > 500
  db.crypto = { ok = ok, stepped = result, wholeMs = whole, steps = steps, longestStepMs = longest, slice = ns.Crypto.SLICE }
  out(string.format("Ed25519 check: %s in %.1f ms; in %d steps, the longest %.1f ms", tostring(ok), whole, steps, longest))
end

SLASH_PINTOPROBE1 = "/pintoprobe"
SlashCmdList.PINTOPROBE = function(msg)
  if not db then
    out("not ready yet: PintoProbeDB hasn't loaded.")
    return
  end
  msg = (msg or ""):lower()
  if msg == "show" then
    if not try("show", showTest) then out("the test frame failed; it's noted in the log.") end
  elseif msg == "crypto" then
    if not try("crypto", timeCrypto) then out("the crypto check failed; it's noted in the log.") end
  elseif msg == "reset" then
    wipe(PintoProbeDB)
    PintoProbeDB.probe = VERSION
    warned = false
    out("Cleared.")
  else
    local ok, r = pcall(check)
    if ok then
      summary(r)
    else
      logError("check", r)
      out("the check failed; it's noted in the log.")
    end
  end
end
