-- Things done for the guild outside a group: inviting someone new, and filling the guild
-- bank.
--
-- Invites: the game tells the inviter "You have invited %s to join your guild." and the
-- whole guild "%s has joined the guild." (ERR_GUILD_INVITE_S and ERR_GUILD_JOIN_S, in the
-- client's language). Someone this character invited who joins within a day, and has no
-- join date from before today, so was never in the guild as far as Pinto knows, is a
-- member invited. Names are matched by their first part, since a message may give a name
-- with or without its surname or realm.
--
-- The guild bank: opening it shows the guild has one and this player uses it (the bank
-- quest's need). While it's open, an item this account crafted that leaves the bags while
-- the bank's contents change went into the bank.
local ADDON, ns = ...

local Guild = {}
ns.Guild = Guild

local Compat, Time, Events, Log, Util = ns.Compat, ns.Time, ns.Events, ns.Log, ns.Util

local INVITE_KEEP = 86400   -- an invite counts if they join within a day

local function pattern(s)
  if not s then return nil end
  local p = s:gsub("([%(%)%.%+%-%*%?%[%]%^%$])", "%%%1"):gsub("%%s", "(.+)")
  return "^" .. p .. "$"
end

-- The first part of a name, for matching it in either message.
local function firstName(name)
  return (name:match("^[^%s%-]+") or name):lower()
end

local invitedPattern, joinedPattern

local function onSystem(text)
  if type(text) ~= "string" or not Time.isLive() then return end
  invitedPattern = invitedPattern or pattern(ERR_GUILD_INVITE_S) or false
  joinedPattern = joinedPattern or pattern(ERR_GUILD_JOIN_S) or false
  local who = invitedPattern and text:match(invitedPattern)
  if who then
    Log.Invited()[firstName(who)] = Time.now()
    return
  end
  who = joinedPattern and text:match(joinedPattern)
  if not who then return end
  local invited = Log.Invited()
  local at = invited[firstName(who)]
  if not at or Time.now() - at > INVITE_KEEP then return end
  invited[firstName(who)] = nil
  local name = Compat.FullName(who)
  local join = name and ns.Roster.JoinInfo(Util.nameId(name))
  if join and join.day < Time.day() then return end   -- back again, not someone new
  Log.AddMoment("invite")
end

-- The guild bank -------------------------------------------------------------------------

local bankOpen, counts, changed, pending = false, nil, false, false

-- How many of each item this account crafted are in the bags.
local function countCrafted()
  local c = {}
  for id in pairs(PintoTGD_DB.crafted or {}) do
    local n = Compat.ItemCount(id)
    if n > 0 then c[id] = n end
  end
  return c
end

local function check()
  pending = false
  if not bankOpen or not counts then return end
  local now = countCrafted()
  local gone = 0
  for id, n in pairs(counts) do
    if (now[id] or 0) < n then gone = gone + n - (now[id] or 0) end
  end
  counts = now
  if gone > 0 and changed and Time.isLive() then Log.AddMoment("deposit", nil, gone) end
  changed = false
end

local function soon()
  if pending then return end
  pending = true
  ns.After(0.5, check)
end

function Guild.BankOpened()
  PintoTGD_DB.bankSeen = true
  bankOpen, changed = true, false
  counts = countCrafted()
end

function Guild.BankClosed()
  bankOpen, counts = false, nil
end

local GUILD_BANKER = 10   -- Enum.PlayerInteractionType.GuildBanker

local function isBanker(kind)
  local enum = Enum and Enum.PlayerInteractionType
  return kind == ((enum and enum.GuildBanker) or GUILD_BANKER)
end

function Guild.Init()
  Events.On("CHAT_MSG_SYSTEM", onSystem)
  -- older clients say the guild bank opened; newer ones say an interaction began
  Events.On("GUILDBANKFRAME_OPENED", Guild.BankOpened)
  Events.On("GUILDBANKFRAME_CLOSED", Guild.BankClosed)
  Events.On("PLAYER_INTERACTION_MANAGER_FRAME_SHOW", function(kind)
    if isBanker(kind) then Guild.BankOpened() end
  end)
  Events.On("PLAYER_INTERACTION_MANAGER_FRAME_HIDE", function(kind)
    if isBanker(kind) then Guild.BankClosed() end
  end)
  Events.On("GUILDBANKBAGSLOTS_CHANGED", function()
    if bankOpen then
      changed = true
      soon()
    end
  end)
  Events.On("BAG_UPDATE_DELAYED", function()
    if bankOpen then soon() end
  end)
end
