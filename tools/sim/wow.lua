-- wow.lua: a stand-in for the WoW client, enough for Pinto's non-UI code.
--
-- A world holds the server clock, the guild roster, the addon-message network and any
-- number of simulated clients. Each client runs its own copy of the addon in its own
-- global environment, with its own SavedVariables:
--
--   local wow = require("wow")
--   local world = wow.world({ seed = 1 })
--   world:addMember("Kiri-Forever", { rankIndex = 0 })
--   local kiri = world:client("Kiri-Forever")
--   kiri:login()                  -- loads the addon (all .toc files) and fires login events
--   world:run(60)                 -- advances 60 seconds: timers, OnUpdate, message delivery
--   kiri:logout()                 -- fires PLAYER_LOGOUT and keeps its SavedVariables
--   kiri:crash()                  -- goes offline without saving
--
-- The network follows Blizzard's rules: GUILD messages reach every online guildie
-- including the sender, WHISPER reaches one character, at most 255 bytes, no zero
-- bytes, and each sender gets a burst of 10 messages then 1 per second per prefix.
--
-- Names follow Forever's: no realms, and every character is "Name Surname". UnitName
-- gives the surname as its second value, RegionalUniqueNamesEnabled says so, and the
-- characters of one guild can sit on different realms behind the scenes. Two world
-- options cover what Forever hasn't shown yet:
--   senderForm   how addon messages name the sender: "space" (Name Surname, the
--                default), "hyphen" (Name-Surname) or "realm" (Name Surname-Realm)
--   whisperForm  how a whisper must name its target to arrive: "space" (the default)
--                or "hyphen"; any other name gets "No player named ..." back
-- With PINTO_NAMES=realm, characters are "Name-Realm" instead, as on older clients.
-- Tests write a character as wow.full("Kiri"): "Kiri Forever", or "Kiri-Forever".

local H = require("harness")

local wow = {}

wow.NAMES = os.getenv("PINTO_NAMES") == "realm" and "realm" or "forever"

function wow.full(first)
  if wow.NAMES == "realm" then return first .. "-Forever" end
  return first .. " Forever"
end

-- Events the Forever client won't let addons register. Registering one raises no Lua
-- error: the game blocks the addon and tells the player. Clients note each attempt in
-- client.forbidden.
wow.FORBIDDEN = { COMBAT_LOG_EVENT_UNFILTERED = true, COMBAT_LOG_EVENT = true }

-- Secret values, the way newer clients hand them out: they can be passed around, but
-- reading, comparing, joining or printing one raises an error. wow.secret() makes one;
-- the client's issecretvalue knows them.
local SECRET = {}
local function secretError() error("attempt to use a secret value", 2) end
for _, m in ipairs({ "__index", "__newindex", "__call", "__concat", "__len", "__eq", "__lt", "__le",
  "__add", "__sub", "__mul", "__div", "__unm", "__tostring" }) do
  SECRET[m] = secretError
end
function wow.secret() return setmetatable({}, SECRET) end
function wow.isSecret(v) return type(v) == "table" and getmetatable(v) == SECRET end

-- Skill line ids, for GetProfessionInfo.
wow.SKILL_LINES = { Alchemy = 171, Blacksmithing = 164, Enchanting = 333, Engineering = 202, Herbalism = 182,
  Leatherworking = 165, Mining = 186, Skinning = 393, Tailoring = 197, Cooking = 185, ["First Aid"] = 129,
  Fishing = 356 }

-- Spell names the client knows (English), for C_Spell.
wow.SPELLS = {
  [746] = "First Aid", [3273] = "First Aid", [2550] = "Cooking", [7620] = "Fishing",
  [2259] = "Alchemy", [2018] = "Blacksmithing", [7411] = "Enchanting", [4036] = "Engineering",
  [2366] = "Herb Gathering", [2368] = "Herb Gathering", [2108] = "Leatherworking",
  [2575] = "Mining", [2576] = "Mining", [8613] = "Skinning", [3908] = "Tailoring",
  [133] = "Fireball", [836] = "LOGINEFFECT", [3267] = "First Aid", [7927] = "First Aid",
}

local World = {}
World.__index = World

local Client = {}
Client.__index = Client

function wow.world(opts)
  opts = opts or {}
  local world = setmetatable({
    time = opts.time or 1796608800,   -- 2026-12-07 03:00 server time (02:00 UTC), a Monday
    mono = 1000,
    timers = {},
    timerSeq = 0,
    queue = {},                       -- addon messages in flight
    clients = {},
    members = {},                     -- roster: list of { name, rankIndex, level, note, ... }
    guild = opts.guild or "The Girthy Dragons",
    realm = opts.realm or (wow.NAMES == "realm" and "Forever" or "CAMWOW EU4 Realm 7 PvE"),
    senderForm = opts.senderForm or "space",
    whisperForm = opts.whisperForm or "space",
    rng = opts.seed and opts.seed or 1,
    latency = opts.latency or 0.2,
    drop = opts.drop or 0,            -- chance a message is lost
    log = {},
    stats = { sent = 0, delivered = 0, throttled = 0, dropped = 0, bytes = 0 },
  }, World)
  math.randomseed(world.rng)
  return world
end

function World:addMember(name, fields)
  local m = { name = name, rankIndex = 2, level = 60, note = "", class = "WARRIOR", zone = "Orgrimmar" }
  for k, v in pairs(fields or {}) do m[k] = v end
  self.members[#self.members + 1] = m
  return m
end

function World:member(name)
  for _, m in ipairs(self.members) do
    if m.name == name then return m end
  end
end

function World:removeMember(name)
  for i, m in ipairs(self.members) do
    if m.name == name then
      table.remove(self.members, i)
      return
    end
  end
end

-- Timers ---------------------------------------------------------------------------

function World:addTimer(client, delay, fn, interval)
  self.timerSeq = self.timerSeq + 1
  local t = { at = self.mono + math.max(delay, 0.001), fn = fn, client = client,
    interval = interval, seq = self.timerSeq }
  self.timers[#self.timers + 1] = t
  return t
end

-- Advances the world by dt seconds, in steps of at most `step` seconds.
function World:run(dt, step)
  step = step or 0.1
  local target = self.mono + dt
  while self.mono < target - 1e-9 do
    local d = math.min(step, target - self.mono)
    self.mono = self.mono + d
    self.time = self.time + d
    self:tick(d)
  end
end

function World:tick(elapsed)
  -- due timers, oldest first
  local due = {}
  for _, t in ipairs(self.timers) do
    if not t.cancelled and t.at <= self.mono then due[#due + 1] = t end
  end
  table.sort(due, function(a, b)
    if a.at ~= b.at then return a.at < b.at end
    return a.seq < b.seq
  end)
  for _, t in ipairs(due) do
    if not t.cancelled and t.client.online then
      if t.interval then t.at = t.at + t.interval else t.cancelled = true end
      t.client:call(t.fn)
    else
      t.cancelled = true
    end
  end
  local keep = {}
  for _, t in ipairs(self.timers) do
    if not t.cancelled then keep[#keep + 1] = t end
  end
  self.timers = keep

  -- messages that have arrived
  local pending = {}
  for _, m in ipairs(self.queue) do
    if m.at <= self.mono then
      self:deliver(m)
    else
      pending[#pending + 1] = m
    end
  end
  self.queue = pending

  -- throttle refill and OnUpdate
  for _, c in pairs(self.clients) do
    if c.online then
      for prefix, tokens in pairs(c.tokens) do
        c.tokens[prefix] = math.min(10, tokens + elapsed)
      end
      c:onUpdate(elapsed)
    end
  end
end

-- Network --------------------------------------------------------------------------

function World:send(from, prefix, text, channel, target)
  if #prefix > 16 then return 9 end
  if #text > 255 or text:find("\0", 1, true) then error("addon message too long or has a zero byte") end
  local tokens = from.tokens[prefix] or 10
  if tokens < 1 then
    self.stats.throttled = self.stats.throttled + 1
    return 3
  end
  from.tokens[prefix] = tokens - 1
  self.stats.sent = self.stats.sent + 1
  self.stats.bytes = self.stats.bytes + #text
  local base = { prefix = prefix, text = text, channel = channel, sender = self:senderName(from) }
  if channel == "GUILD" then
    for _, c in pairs(self.clients) do
      if c.online then self:enqueue(base, c) end
    end
  elseif channel == "WHISPER" then
    local c = self:whispered(target)
    if c and c.online then
      self:enqueue(base, c)
    else
      self.stats.unknownTargets = (self.stats.unknownTargets or 0) + 1
      self:addTimer(from, self.latency, function()
        from:fire("CHAT_MSG_SYSTEM", string.format("No player named '%s' is currently playing.", tostring(target)))
      end)
    end
  end
  return 0
end

-- How an addon message names its sender.
function World:senderName(from)
  if wow.NAMES == "realm" or self.senderForm == "space" then return from.name end
  if self.senderForm == "hyphen" then return (from.name:gsub(" ", "-")) end
  return from.name .. "-" .. from:realm():gsub("%s", "")
end

-- The client a whisper reaches, if its target is named the way the server wants.
function World:whispered(target)
  if wow.NAMES == "realm" then
    -- "Name" alone means the sender's realm, which in the stand-in is everyone's
    return self.clients[target] or self.clients[target .. "-" .. self.realm:gsub("%s", "")]
  end
  for name, c in pairs(self.clients) do
    local form
    if self.whisperForm == "space" then form = name end
    if self.whisperForm == "hyphen" then form = name:gsub(" ", "-") end
    if form == target then return c end
  end
end

function World:enqueue(base, to)
  if self.drop > 0 and math.random() < self.drop then
    self.stats.dropped = self.stats.dropped + 1
    return
  end
  self.queue[#self.queue + 1] = { prefix = base.prefix, text = base.text, channel = base.channel,
    sender = base.sender, to = to, sentAt = self.mono,
    at = self.mono + self.latency * (0.5 + math.random()) }
end

function World:deliver(m)
  local c = m.to
  if not c.online then return end
  if not c.prefixes[m.prefix] then return end
  self.stats.delivered = self.stats.delivered + 1
  c:fire("CHAT_MSG_ADDON", m.prefix, m.text, m.channel, m.sender, c.name, 0, 0, "", 0)
end

-- Clients --------------------------------------------------------------------------

function World:client(name, opts)
  local c = self.clients[name]
  if c then return c end
  c = setmetatable({
    world = self, name = name, online = false, saved = nil, frames = {}, tokens = {},
    prefixes = {}, chat = {}, errors = {}, opts = opts or {}, forbidden = {},
    group = {}, instance = { kind = "none", id = 0 }, combat = false, mapId = 1454,
    target = nil,          -- full name of the target
    inCombat = {},         -- full name -> true, for group members in combat
    hideMaps = false,      -- C_Map answers with secrets, like in combat on Forever
    lockdown = false,      -- addon messages locked down, like during a boss encounter
  }, Client)
  self.clients[name] = c
  return c
end

function Client:call(fn, ...)
  local ok, err = xpcall(fn, debug.traceback, ...)
  if not ok then
    self.errors[#self.errors + 1] = err
    if not self.opts.quietErrors then print("error in " .. self.name .. ": " .. tostring(err)) end
  end
end

function Client:fire(event, ...)
  for _, f in ipairs(self.frames) do
    if f.events[event] and f.scripts.OnEvent then
      -- a unit event registered for some units only reaches the frame for those
      local units = f.units and f.units[event]
      if not units or units[(...)] then self:call(f.scripts.OnEvent, f, event, ...) end
    end
  end
end

-- The realm this character sits on: behind the scenes on Forever, where one guild's
-- characters can sit on different realms.
function Client:realm()
  return self.opts.realm or self.world.realm
end

function Client:onUpdate(elapsed)
  for _, f in ipairs(self.frames) do
    if f.shown and f.scripts.OnUpdate then self:call(f.scripts.OnUpdate, f, elapsed) end
  end
end

-- UnitName's two values for a character: name and surname on Forever; on older clients
-- the name alone, since the stand-in's characters share one realm.
local function nameParts(full)
  if wow.NAMES == "realm" then return (full:gsub("%-[^%-]*$", "")), nil end
  local first, surname = full:match("^(%S+) (.+)$")
  if first then return first, surname end
  return full, nil
end

-- Unit events: RegisterUnitEvent(event, unit1[, unit2]) registers an event for those
-- units only.
local function addUnitEvents(f)
  function f:RegisterUnitEvent(e, u1, u2)
    self:RegisterEvent(e)
    if self.events[e] then
      self.units = self.units or {}
      self.units[e] = { [u1] = true }
      if u2 then self.units[e][u2] = true end
    end
  end
end

-- Builds the global environment this client's addon sees.
function Client:makeEnv()
  local c, world = self, self.world
  local env = setmetatable({}, { __index = _G })
  env._G = env

  local function newFrame()
    local f = { events = {}, scripts = {}, shown = true }
    function f:RegisterEvent(e)
      -- like newer clients, which raise an error for events they don't have
      if c.opts.unknownEvents and c.opts.unknownEvents[e] then
        error('Attempt to register unknown event "' .. e .. '"', 2)
      end
      if wow.FORBIDDEN[e] then
        c.forbidden[#c.forbidden + 1] = e
        return
      end
      self.events[e] = true
      if self.units then self.units[e] = nil end
    end
    addUnitEvents(f)
    function f:UnregisterEvent(e) self.events[e] = nil end
    function f:UnregisterAllEvents() self.events = {} end
    function f:SetScript(name, fn) self.scripts[name] = fn end
    function f:GetScript(name) return self.scripts[name] end
    function f:Show() self.shown = true end
    function f:Hide() self.shown = false end
    function f:IsShown() return self.shown end
    c.frames[#c.frames + 1] = f
    return f
  end
  env.CreateFrame = function() return newFrame() end

  env.C_Timer = {
    After = function(delay, fn) world:addTimer(c, delay, fn) end,
    NewTicker = function(interval, fn)
      local t = world:addTimer(c, interval, fn, interval)
      return { Cancel = function() t.cancelled = true end, IsCancelled = function() return t.cancelled end }
    end,
  }
  env.GetServerTime = function() return math.floor(world.time) end
  env.time = function() return math.floor(world.time) end
  env.GetTime = function() return world.mono end
  env.debugprofilestop = function() return os.clock() * 1000 end
  env.geterrorhandler = function() return function(err) c.errors[#c.errors + 1] = err; print("error in " .. c.name .. ": " .. tostring(err)) end end
  env.DEFAULT_CHAT_FRAME = { AddMessage = function(_, text) c.chat[#c.chat + 1] = text end }
  env.UNKNOWNOBJECT = "Unknown"

  env.wipe = function(t) for k in pairs(t) do t[k] = nil end return t end
  env.tinsert, env.tremove = table.insert, table.remove
  env.strtrim = function(s) return (s:gsub("^%s+", ""):gsub("%s+$", "")) end
  env.strsplit = function(sep, s, limit)
    local out, start = {}, 1
    while true do
      if limit and #out == limit - 1 then out[#out + 1] = s:sub(start); break end
      local i, j = s:find(sep, start, true)
      if not i then out[#out + 1] = s:sub(start); break end
      out[#out + 1] = s:sub(start, i - 1)
      start = j + 1
    end
    return unpack(out)
  end

  env.UnitName = function(unit)
    if unit == "player" then return nameParts(c.name) end
    local m = (unit == "target" and c.target) or (c.unitMap and c.unitMap[unit])
    if m then return nameParts(m) end
    return nil
  end
  if wow.NAMES == "forever" then
    env.RegionalUniqueNamesEnabled = function() return true end
    env.UnitNameUnmodified = function(unit) return env.UnitName(unit) end
  end
  env.UnitGUID = function(unit)
    local name = (unit == "player" and c.name) or (unit == "target" and c.target) or (c.unitMap and c.unitMap[unit])
    return name and ("Player-1-" .. name) or nil
  end
  env.UnitLevel = function(unit)
    local m = world:member(unit == "player" and c.name or (c.unitMap and c.unitMap[unit]) or "")
    return m and m.level or 1
  end
  -- the full name behind a unit token
  local function who(unit)
    if unit == "player" then return c.name end
    if unit == "target" then return c.target end
    return c.unitMap and c.unitMap[unit]
  end
  env.UnitIsUnit = function(a, b)
    local x, y = who(a), who(b)
    return x ~= nil and x == y
  end
  env.UnitIsConnected = function() return true end
  env.issecretvalue = wow.isSecret
  env.GetRealmName = function() return c:realm() end
  env.GetNormalizedRealmName = function() return (c:realm():gsub("%s", "")) end
  env.IsInGuild = function() return world:member(c.name) ~= nil end
  env.GetGuildInfo = function(unit)
    local m = world:member(c.name)
    if not m then return nil end
    return world.guild, "Rank" .. m.rankIndex, m.rankIndex
  end
  env.GetNumGuildMembers = function()
    local online = 0
    for _, m in ipairs(world.members) do
      local cl = world.clients[m.name]
      if cl and cl.online then online = online + 1 end
    end
    return #world.members, online, online
  end
  env.GetGuildRosterInfo = function(i)
    local m = world.members[i]
    if not m then return nil end
    local cl = world.clients[m.name]
    local online = (cl and cl.online) or m.online or false
    return m.name, "Rank" .. m.rankIndex, m.rankIndex, m.level, m.class, m.zone, m.note, "",
      online, 0, m.class, 0, 0, false, false, 0, "Player-1-" .. m.name
  end
  env.GetGuildRosterLastOnline = function() return 0, 0, 1, 0 end
  env.SetGuildRosterShowOffline = function() end
  env.C_GuildInfo = { GuildRoster = function() world:addTimer(c, 0.1, function() c:fire("GUILD_ROSTER_UPDATE", false) end) end }
  env.GuildControlGetNumRanks = function() return 5 end
  env.GuildControlGetRankName = function(i) return "Rank" .. (i - 1) end

  env.C_ChatInfo = {
    RegisterAddonMessagePrefix = function(prefix) c.prefixes[prefix] = true; return true end,
    SendAddonMessage = function(prefix, text, channel, target)
      if c.lockdown then return 11 end
      return world:send(c, prefix, text, channel, target)
    end,
    InChatMessagingLockdown = function() return c.lockdown end,
  }
  env.Enum = { SendAddonMessageResult = { Success = 0, AddonMessageThrottle = 3, NotInGroup = 5,
    ChannelThrottle = 8, GeneralError = 9, AddOnMessageLockdown = 11 } }

  env.IsTrialAccount = function() return c.opts.trial or false end
  env.IsVeteranTrialAccount = function() return false end
  env.IsInInstance = function()
    if c.instance.kind == "none" then return false, "none" end
    return true, c.instance.kind
  end
  env.GetInstanceInfo = function()
    return "Instance", c.instance.kind, 1, "Normal", 5, 0, false, c.instance.id
  end
  env.InCombatLockdown = function() return c.combat end
  env.UnitAffectingCombat = function(unit)
    if unit == "player" then return c.combat end
    local name = who(unit)
    return name ~= nil and c.inCombat[name] == true
  end
  env.IsInGroup = function() return #c.group > 0 end
  env.IsInRaid = function() return #c.group > 4 end
  env.GetNumGroupMembers = function() return #c.group > 0 and #c.group + 1 or 0 end
  env.GetNumSubgroupMembers = function() return #c.group end
  env.C_Map = { GetBestMapForUnit = function()
    if c.hideMaps then return wow.secret() end
    return c.mapId
  end }

  -- character details the tracking reads. Test item links carry what the client would
  -- know about the item: "item:2589 class:7:5 equip:INVTYPE_BAG ilvl:20".
  env.GetInventoryItemLink = function(_, slot) return c.gear and c.gear[slot] end
  local items = {
    GetItemInfo = function() return nil end,
    GetItemInfoInstant = function(link)
      local id = tonumber((link or ""):match("item:(%d+)"))
      if not id then return nil end
      local classID, subclassID = link:match("class:(%d+):(%d+)")
      return id, "", "", link:match("equip:([%w_]+)") or "", 0, tonumber(classID), tonumber(subclassID)
    end,
    GetDetailedItemLevelInfo = function(link) return tonumber((link or ""):match("ilvl:(%d+)")) end,
  }
  -- PINTO_API=modern: items only through C_Item, the way newer clients have them
  if os.getenv("PINTO_API") == "modern" or c.opts.modernItems then
    env.C_Item = items
  else
    for k, fn in pairs(items) do env[k] = fn end
  end
  -- skills: { { name = "Tailoring", rank = 120 }, ... }. With { professions = true } the
  -- client lists them through GetProfessions, the way Forever does, and has no skill lines.
  if c.opts.professions then
    env.GetProfessions = function()
      local primary, slot = {}, {}
      for i, s in ipairs(c.skills or {}) do
        if s.name == "Fishing" then slot.fish = i
        elseif s.name == "Cooking" then slot.cook = i
        elseif s.name == "First Aid" then slot.aid = i
        elseif #primary < 2 then primary[#primary + 1] = i end
      end
      return primary[1], primary[2], nil, slot.fish, slot.cook, slot.aid
    end
    env.GetProfessionInfo = function(i)
      local s = c.skills[i]
      return s.name, 0, s.rank, 300, 0, 0, wow.SKILL_LINES[s.name]
    end
  else
    env.GetNumSkillLines = function() return c.skills and #c.skills or 0 end
    env.GetSkillLineInfo = function(i) local s = c.skills[i]; return s.name, false, true, s.rank end
  end
  env.GetMoney = function() return c.copper or 0 end
  -- the Forever client has no GetSpellInfo, only C_Spell
  env.C_Spell = {
    GetSpellName = function(id) return wow.SPELLS[id] end,
    GetSpellInfo = function(id)
      return wow.SPELLS[id] and { name = wow.SPELLS[id], spellID = id, iconID = 0 } or nil
    end,
  }
  -- the quest log: c.quests = { { questID = 1, suggestedGroup = 3 }, { title = "Elwynn",
  -- isHeader = true }, { questID = 2, elite = true }, ... }. Forever has it through
  -- C_QuestLog only; { oldQuestLog = true } gives the older GetQuestLogTitle instead. An
  -- elite quest is tagged the way each client tags one.
  local function quest(id)
    for _, q in ipairs(c.quests or {}) do
      if q.questID == id and not q.isHeader then return q end
    end
  end
  if c.opts.oldQuestLog then
    env.GetNumQuestLogEntries = function() return #(c.quests or {}) end
    env.GetQuestLogTitle = function(i)
      local q = (c.quests or {})[i]
      if not q then return nil end
      return q.title or "Quest", 10, q.suggestedGroup or 0, q.isHeader or false, false, false, false, q.questID
    end
    env.GetQuestTagInfo = function(id)
      local q = quest(id)
      if q and q.elite then return 0, "Elite" end
      return nil
    end
  else
    env.C_QuestLog = {
      GetNumQuestLogEntries = function() return #(c.quests or {}), #(c.quests or {}) end,
      GetInfo = function(i)
        local q = (c.quests or {})[i]
        if not q then return nil end
        return { title = q.title or "Quest", questLogIndex = i, questID = q.isHeader and 0 or q.questID,
          isHeader = q.isHeader or false, suggestedGroup = q.suggestedGroup or 0, level = 10 }
      end,
      GetQuestTagInfo = function(id)
        local q = quest(id)
        if q and q.elite then return { tagID = 0, tagName = "Elite", isElite = true } end
        return nil
      end,
    }
  end
  env.IsFishingLoot = function() return false end
  -- the trade skill window: Forever names it through C_TradeSkillUI only (c.tradeSkill
  -- while one is open)
  env.C_TradeSkillUI = {
    GetBaseProfessionInfo = function()
      return { professionID = c.tradeSkill and wow.SKILL_LINES[c.tradeSkill] or 0, professionName = c.tradeSkill or "" }
    end,
  }
  env.ERR_GUILD_JOIN_S = "%s has joined the guild."
  env.ERR_TRADE_COMPLETE = "Trade complete."
  env.LOOT_ITEM_SELF = "You receive loot: %s."
  env.LOOT_ITEM_SELF_MULTIPLE = "You receive loot: %sx%d."
  env.LOOT_ITEM_CREATED_SELF = "You create: %s."
  env.LOOT_ITEM_CREATED_SELF_MULTIPLE = "You create: %sx%d."
  env.SlashCmdList = {}

  -- with { ui = true }, the client also gets uistub's widgets, so the whole UI runs
  if self.opts.ui then
    local U = require("uistub")
    for k, v in pairs(U.Env()) do
      if k ~= "_G" and k ~= "GetTime" and k ~= "geterrorhandler" and k ~= "InCombatLockdown"
        and k ~= "IsInInstance" then
        env[k] = v
      end
    end
    env.CreateFrame = function(kind, name, parent, template)
      local f = U.CreateFrame(kind, name, parent, template)
      c.frames[#c.frames + 1] = f
      f.RegisterEvent = function(self, e)
        if wow.FORBIDDEN[e] then
          c.forbidden[#c.forbidden + 1] = e
          return
        end
        self.events[e] = true
        if self.units then self.units[e] = nil end
      end
      addUnitEvents(f)
      return f
    end
    env.GetGuildRosterInfo = env.GetGuildRosterInfo
    env.GuildControlGetNumRanks = function() return 5 end
  end
  return env
end

function Client:login()
  assert(not self.online, self.name .. " is already online")
  self.online = true
  self.frames = {}
  self.tokens = {}
  self.prefixes = {}
  self.env = self:makeEnv()
  self.env.PintoTGD_DB = self.saved and H.deepCopy(self.saved) or nil
  self.env = self:watchGlobals(self.env)
  self.ns = {}
  for _, f in ipairs(H.tocFiles()) do
    if not self.world.skipFile or not self.world.skipFile(f) then
      local chunk = assert(loadfile(H.ROOT .. "/" .. f, "t", self.env))
      self:call(chunk, H.ADDON, self.ns)
    end
  end
  self:fire("ADDON_LOADED", H.ADDON)
  self:fire("PLAYER_LOGIN")
  self:fire("PLAYER_ENTERING_WORLD", true, false)
  return self
end

-- One level of a table, plus a frame's handlers and anchors.
local DEEP = { scripts = true, points = true }
local function snapshot(t)
  local s = {}
  for k, v in pairs(t) do
    if DEEP[k] and type(v) == "table" then
      local c = {}
      for k2, v2 in pairs(v) do c[k2] = v2 end
      s[k] = c
    else
      s[k] = v
    end
  end
  return s
end

-- What the addon changed in the game's own tables since login: { name, key, value } for every
-- key added, removed or given another value, with "scripts.OnShow" style keys for a frame's
-- handlers and anchors.
function Client:gameTableChanges()
  local out = {}
  local function note(name, key, value) out[#out + 1] = { name = name, key = key, value = value } end
  for name, s in pairs(self.gameTables) do
    local t = rawget(self.baseEnv, name)
    if t ~= nil and type(t) ~= "table" then
      note(name, nil, t)
    elseif t then
      for k, v in pairs(t) do
        local old = s[k]
        if DEEP[k] and type(v) == "table" and type(old) == "table" then
          for k2, v2 in pairs(v) do if old[k2] ~= v2 then note(name, k .. "." .. tostring(k2), v2) end end
          for k2 in pairs(old) do if v[k2] == nil then note(name, k .. "." .. tostring(k2), nil) end end
        elseif old ~= v then
          note(name, k, v)
        end
      end
      for k in pairs(s) do if t[k] == nil then note(name, k, nil) end end
    end
  end
  table.sort(out, function(a, b) return a.name .. "." .. tostring(a.key) < b.name .. "." .. tostring(b.key) end)
  return out
end

-- WoW marks every global an addon writes as tainted, even when it writes back the value that
-- was there, and Blizzard code that reads a tainted global can't call protected functions
-- afterwards. So the addon sees its globals through this table, which notes every name it
-- writes in client.globalWrites.
function Client:watchGlobals(env)
  local writes = {}
  self.globalWrites = writes
  -- the game's own tables as the addon finds them, for client:gameTableChanges()
  local before = {}
  for name, t in pairs(env) do
    if type(t) == "table" and name ~= "_G" and not name:find("^PintoTGD") then before[name] = snapshot(t) end
  end
  self.gameTables, self.baseEnv = before, env
  local watched = setmetatable({}, {
    __index = env,
    __newindex = function(_, k, v)
      writes[k] = true
      env[k] = v
    end,
  })
  env._G = watched
  return watched
end

function Client:logout()
  if not self.online then return end
  self:fire("PLAYER_LOGOUT")
  self.saved = H.deepCopy(self.env.PintoTGD_DB)
  self.online = false
end

function Client:crash()
  self.online = false
end

return wow
