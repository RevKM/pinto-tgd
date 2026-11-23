-- Namespace, events, timers and logging. Loads first.
local ADDON, ns = ...

ns.ADDON = ADDON
ns.NAME = "Pinto"
ns.GUILD = "The Girthy Dragons"

-- Events --------------------------------------------------------------------------
-- WoW events and the addon's own messages share one dispatcher. Own messages are
-- prefixed "PINTO_" and never registered with the game.

local Events = {}
ns.Events = Events

local handlers = {}
local frame = CreateFrame("Frame")
ns.eventFrame = frame

local function report(err)
  local handler = geterrorhandler and geterrorhandler()
  if handler then handler(err) else print(err) end
end

-- Hidden values. The Forever client hands addons some values as secrets, mostly in
-- combat and in instances: chat text, spell targets, unit GUIDs, map ids. Addon code
-- can't read, compare or search them, so Pinto checks before touching such a value,
-- and skips any event that carries one.
local isSecret = issecretvalue

function ns.Secret(v)
  return isSecret ~= nil and isSecret(v) == true
end

function ns.AnySecret(...)
  if not isSecret then return false end
  for i = 1, select("#", ...) do
    if isSecret((select(i, ...))) then return true end
  end
  return false
end

-- The arguments Pinto reads, for events where others may be secret: a secret it doesn't
-- read is passed on as nil. Any other event carrying a secret is skipped.
local READS = {
  UNIT_SPELLCAST_SUCCEEDED = { [1] = true, [3] = true },   -- unit, spell id
  CHAT_MSG_ADDON = { [1] = true, [2] = true, [3] = true, [4] = true },
  CHAT_MSG_LOOT = { [1] = true },
  CHAT_MSG_SYSTEM = { [1] = true },
  UI_INFO_MESSAGE = { [1] = true, [2] = true },
  -- a boss fight's start and end matter even when the boss can't be named
  ENCOUNTER_START = {},
  ENCOUNTER_END = {},
}

local function run(list, ...)
  -- copy so handlers can unregister themselves while running
  local n = #list
  local copy = {}
  for i = 1, n do copy[i] = list[i] end
  for i = 1, n do
    local ok, err = pcall(copy[i], ...)
    if not ok then report(err) end
  end
end

local function dispatch(event, ...)
  local list = handlers[event]
  if not list then return end
  if not ns.AnySecret(...) then return run(list, ...) end
  local reads = READS[event]
  if not reads then return end
  local n = select("#", ...)
  local args = { ... }
  for i = 1, n do
    if ns.Secret(args[i]) then
      if reads[i] then return end
      args[i] = nil
    end
  end
  return run(list, unpack(args, 1, n))
end

frame:SetScript("OnEvent", function(_, event, ...) dispatch(event, ...) end)

local function isOwn(event) return event:sub(1, 6) == "PINTO_" end

-- Game events this client doesn't have. Newer clients raise an error when an addon
-- registers one; Pinto notes it and carries on without that event.
-- (Events the client forbids, like the combat log on Forever, raise no error: the game
-- blocks the addon and tells the player. Pinto never registers those.)
ns.unknownEvents = {}

-- With a unit, a unit event comes only for that unit (say the player's own casts), where
-- the client can filter it. The first handler of an event decides this for all of them.
function Events.On(event, fn, unit)
  local list = handlers[event]
  if not list then
    list = {}
    handlers[event] = list
    if not isOwn(event) then
      local ok
      if unit and frame.RegisterUnitEvent then
        ok = pcall(frame.RegisterUnitEvent, frame, event, unit)
      else
        ok = pcall(frame.RegisterEvent, frame, event)
      end
      if not ok then ns.unknownEvents[event] = true end
    end
  end
  list[#list + 1] = fn
end

function Events.Off(event, fn)
  local list = handlers[event]
  if not list then return end
  for i = #list, 1, -1 do
    if list[i] == fn then table.remove(list, i) end
  end
  if #list == 0 then
    handlers[event] = nil
    if not isOwn(event) then frame:UnregisterEvent(event) end
  end
end

function Events.Fire(event, ...)
  dispatch(event, ...)
end

-- Timers ---------------------------------------------------------------------------

function ns.After(seconds, fn)
  C_Timer.After(seconds, function()
    local ok, err = pcall(fn)
    if not ok then report(err) end
  end)
end

function ns.Every(seconds, fn)
  return C_Timer.NewTicker(seconds, function()
    local ok, err = pcall(fn)
    if not ok then report(err) end
  end)
end

-- Logging --------------------------------------------------------------------------

function ns.Print(text)
  DEFAULT_CHAT_FRAME:AddMessage("|cffe2574cPinto:|r " .. text)
end

function ns.Debug(fmt, ...)
  if PintoTGD_DB and PintoTGD_DB.debug then
    local ok, text = pcall(string.format, fmt, ...)
    DEFAULT_CHAT_FRAME:AddMessage("|cff888888Pinto debug:|r " .. (ok and text or fmt))
  end
end

ns.report = report
