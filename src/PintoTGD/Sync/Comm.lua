-- Addon messages: one prefix, pacing, multi-part messages and escaping.
--
-- Every message is [protocol version u8][type u8][payload], escaped so it carries no
-- zero byte, and at most 255 bytes. Longer messages travel as PART messages:
-- [protocol][PART][message id u16][index u8][count u8][chunk].
-- Blizzard allows a burst of 10 addon messages, then 1 per second per prefix.
local ADDON, ns = ...

local Comm = {}
ns.Comm = Comm

local Util, Bytes, Compat = ns.Util, ns.Bytes, ns.Compat

Comm.PREFIX = ns.Build.test and "PintoTGDt" or "PintoTGD"
Comm.T = { PART = 1, HELLO = 2, FACTS = 3, LIST_REQ = 4, LIST = 5, PIECES_REQ = 6, PIECES = 7, PING = 8 }
local T = Comm.T

local MAX = 255
local PART_HEADER_MAX = 12 -- the 6-byte part header, escaped, at worst
-- a little under Blizzard's limits, so rounding never tips us over
local BURST, RATE = 9, 0.95
local PARTS_TIMEOUT = 120
local MAX_PARTS = 255

Comm.handlers = {}

-- Priorities: 1 live updates, 2 hellos, 3 catch-up.
local queues = { {}, {}, {} }
local tokens = BURST
local lastRefill = 0
local msgSeq = math.random(0, 65535)
local partials = {}
Comm.stats = { sent = 0, received = 0, throttled = 0 }

local function proto() return ns.Build.protocolVersion end

-- Whispers wait outside instances and combat: whispers are throttled in instances.
function Comm.HoldWhispers()
  if InCombatLockdown and InCombatLockdown() then return true end
  return Compat.InstanceKind() ~= "none"
end

-- target is a character's key; a raw target goes out exactly as given.
local function enqueue(wire, channel, target, prio, raw)
  local q = queues[prio or 3]
  q[#q + 1] = { wire = wire, channel = channel, target = target, raw = raw }
end

-- Splits a body so each escaped part fits in one message.
local function split(body)
  local chunks = {}
  local budget = MAX - PART_HEADER_MAX
  local start, size = 1, 0
  for i = 1, #body do
    local b = body:byte(i)
    local cost = (b == 0 or b == 1) and 2 or 1
    if size + cost > budget then
      chunks[#chunks + 1] = body:sub(start, i - 1)
      start, size = i, 0
    end
    size = size + cost
  end
  chunks[#chunks + 1] = body:sub(start)
  return chunks
end

-- Sends payload (binary) as message type typ. Returns false if it's too big to send.
function Comm.Send(typ, payload, channel, target, prio)
  local body = string.char(proto(), typ) .. payload
  local wire = Util.escape(body)
  if #wire <= MAX then
    enqueue(wire, channel, target, prio)
    return true
  end
  local chunks = split(body)
  if #chunks > MAX_PARTS then
    ns.Debug("message too big to send: %d bytes", #body)
    return false
  end
  msgSeq = (msgSeq + 1) % 65536
  local id = Bytes.u16str(msgSeq)
  for i, chunk in ipairs(chunks) do
    local part = string.char(proto(), T.PART) .. id .. string.char(i, #chunks) .. chunk
    enqueue(Util.escape(part), channel, target, prio)
  end
  return true
end

function Comm.QueueSize()
  return #queues[1] + #queues[2] + #queues[3]
end

-- Drops queued messages to a target (a catch-up partner who went away).
function Comm.DropFor(target)
  for _, q in ipairs(queues) do
    for i = #q, 1, -1 do
      if q[i].target == target then table.remove(q, i) end
    end
  end
end

local function nextMessage(holdWhispers)
  for _, q in ipairs(queues) do
    for i = 1, #q do
      local m = q[i]
      if not (holdWhispers and m.channel == "WHISPER") then
        table.remove(q, i)
        return m
      end
    end
  end
end

-- Boss fights. During a dungeon boss fight Forever reports no lockdown and accepts addon
-- messages, but they never arrive. So nothing goes out from a boss fight's start to its
-- end, or to a loading screen, or for half an hour at most in case the end never comes.
local BOSS_FIGHT_MAX = 1800
local bossFightSince = nil

function Comm.InBossFight()
  return bossFightSince ~= nil and GetTime() - bossFightSince < BOSS_FIGHT_MAX
end

-- Nothing goes out while the game locks addon messages down (boss encounters, PvP) or
-- during a boss fight; the queue waits, and a message refused for a lockdown goes back
-- in front.
function Comm.Pump()
  local now = GetTime()
  tokens = math.min(BURST, tokens + (now - lastRefill) * RATE)
  lastRefill = now
  if Compat.ChatLockdown() or Comm.InBossFight() then return end
  local hold = Comm.HoldWhispers()
  while tokens >= 1 do
    local m = nextMessage(hold)
    if not m then break end
    local target = m.target
    if m.channel == "WHISPER" and not m.raw then target = Compat.WhisperTarget(target) end
    local result = Compat.SendAddonMessage(Comm.PREFIX, m.wire, m.channel, target)
    if result == "throttled" or result == "locked" then
      table.insert(queues[1], 1, m)
      tokens = 0
      if result == "throttled" then Comm.stats.throttled = Comm.stats.throttled + 1 end
      break
    end
    if m.raw then Comm.whisperCheck.queued = false end
    tokens = tokens - 1
    if result == "ok" then Comm.stats.sent = Comm.stats.sent + 1 end
  end
end

-- Whispers on Forever -----------------------------------------------------------------
-- Forever names characters "Name Surname", and nothing says how an addon whisper must
-- name one. A little after login Pinto whispers itself, as "Name Surname" and then, if
-- that doesn't arrive, as "Name-Surname", and uses the first form that arrives. Until
-- then, and if neither does, whispers use "Name Surname".

local FORMS = { "space", "hyphen" }
local PING_WAIT = 30
-- state: nil off Forever, else "checking", "space", "hyphen" or "none"
Comm.whisperCheck = { tried = 0, queued = false, state = nil }

local function sendPing()
  local check = Comm.whisperCheck
  if check.state ~= "checking" or not ns.me then return end
  if check.queued then   -- the last one is still waiting to go out
    ns.After(PING_WAIT, sendPing)
    return
  end
  check.tried = check.tried + 1
  local form = FORMS[check.tried]
  if not form then
    check.state = "none"
    ns.Debug("whispers to myself didn't arrive as Name Surname or Name-Surname")
    return
  end
  local target = form == "hyphen" and ns.me:gsub(" ", "-") or ns.me
  check.queued = true
  enqueue(Util.escape(string.char(proto(), T.PING, check.tried)), "WHISPER", target, 1, true)
  ns.After(PING_WAIT, sendPing)
end

local function onPing(body)
  local check = Comm.whisperCheck
  local i = body:byte(3)
  local form = i and FORMS[i]
  if not form or not check.state then return end
  if check.state == "checking" or check.state == "none" or i < check.got then
    check.state, check.got = form, i
    Compat.whisperForm = form
  end
end

-- Receiving -------------------------------------------------------------------------

local function dispatch(body, sender, channel)
  local version, typ = body:byte(1, 2)
  if version ~= proto() or not typ then return end
  local handler = Comm.handlers[typ]
  if not handler then return end
  local ok, err = pcall(handler, Bytes.reader(body, 3), sender, channel)
  if not ok and not (type(err) == "table") then ns.report(err) end
end

local function onPart(body, sender, channel)
  if #body < 7 then return end
  local id = body:byte(3) * 256 + body:byte(4)
  local index, count = body:byte(5), body:byte(6)
  if index < 1 or index > count then return end
  local key = sender .. ":" .. string.format("%d", id)
  local p = partials[key]
  if not p or p.count ~= count then
    p = { count = count, got = 0, parts = {} }
    partials[key] = p
  end
  p.at = GetTime()
  if not p.parts[index] then
    p.parts[index] = body:sub(7)
    p.got = p.got + 1
  end
  if p.got == count then
    partials[key] = nil
    local whole = table.concat(p.parts, "", 1, count)
    if whole:byte(2) ~= T.PART then dispatch(whole, sender, channel) end
  end
end

function Comm.OnMessage(prefix, text, channel, sender)
  if prefix ~= Comm.PREFIX then return end
  sender = Compat.FullName(sender)
  if not sender then return end
  local body = Util.unescape(text)
  if not body or #body < 2 then return end
  if sender == ns.me then
    if channel == "WHISPER" and #body >= 3 and body:byte(1) == proto() and body:byte(2) == T.PING then
      onPing(body)
    end
    return
  end
  if not ns.Roster.IsMember(sender) then return end
  Comm.stats.received = Comm.stats.received + 1
  if body:byte(2) == T.PART then
    if body:byte(1) == proto() then onPart(body, sender, channel) end
  else
    dispatch(body, sender, channel)
  end
end

local function expireParts()
  local now = GetTime()
  for key, p in pairs(partials) do
    if now - p.at > PARTS_TIMEOUT then partials[key] = nil end
  end
end

function Comm.Init()
  Compat.RegisterPrefix(Comm.PREFIX)
  lastRefill = GetTime()
  ns.Events.On("CHAT_MSG_ADDON", Comm.OnMessage)
  ns.Events.On("ENCOUNTER_START", function() bossFightSince = GetTime() end)
  ns.Events.On("ENCOUNTER_END", function() bossFightSince = nil end)
  ns.Events.On("PLAYER_ENTERING_WORLD", function() bossFightSince = nil end)
  ns.Every(0.1, Comm.Pump)
  ns.Every(30, expireParts)
  if Compat.Surnames() then
    Comm.whisperCheck.state = "checking"
    ns.After(15, sendPing)
  end
end

-- For /pinto status, on Forever.
function Comm.WhisperState()
  local state = Comm.whisperCheck.state
  if state == "space" then return "arrive as Name Surname" end
  if state == "hyphen" then return "arrive as Name-Surname" end
  if state == "none" then return "to yourself didn't arrive" end
  return "being checked"
end
