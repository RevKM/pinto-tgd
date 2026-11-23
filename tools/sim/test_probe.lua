-- The probe addon: it must never raise an error, whatever the client lacks, and it must
-- record what Pinto needs to know.
local H = require("harness")
local wow = require("wow")

local PROBE = "tools/probe/PintoProbe/Probe.lua"
local CRYPTO = H.ROOT .. "/Sync/Crypto.lua"

local function loadProbe(env)
  local ns = {}
  for _, path in ipairs({ CRYPTO, PROBE }) do
    local chunk = assert(loadfile(path, "t", env))
    chunk("PintoProbe", ns)
  end
  return ns
end

-- A client with the calls the probe reads, in a guild group with Thorn.
local function fullClient()
  local world = wow.world({ seed = 3 })
  world:addMember(wow.full("Kiri"), { rankIndex = 0 })
  world:addMember(wow.full("Thorn"))
  local client = world:client(wow.full("Kiri"), { ui = true })
  client.online = true
  local env = client:makeEnv()
  env.date = os.date
  env.GetBuildInfo = function() return "1.60.1", "65000", "Nov 1 2026", 16001 end
  env.GetGameTime = function() return 9, 30 end
  env.UnitIsVisible = function() return true end
  env.GetRaidRosterInfo = function() return nil end
  env.GetTradePlayerItemInfo = function() return nil end
  env.GetTradeTargetItemInfo = function() return nil end
  env.GetTradePlayerItemLink = function() return nil end
  env.GetTradeTargetItemLink = function() return nil end
  env.GetInventoryItemLink = function(_, slot) if slot == 16 then return "item:2000 ilvl:24 equip:INVTYPE_2HWEAPON" end end
  env.SlashCmdList = {}
  client.group = { wow.full("Thorn") }
  client.unitMap = { party1 = wow.full("Thorn") }
  env.UnitGUID = function(unit)
    if unit == "player" then return "Player-1-" .. wow.full("Kiri") end
    return "Player-1-" .. wow.full("Thorn")
  end
  client.env = env
  local ns = loadProbe(env)
  return world, client, env, ns
end

local function slash(env, msg)
  local ok, err = pcall(env.SlashCmdList.PINTOPROBE, msg)
  H.ok(ok, "/pintoprobe " .. msg .. " raised: " .. tostring(err))
end

H.test("the probe checks the client and logs Pinto's events without a single error", function()
  local world, client, env = fullClient()
  client:fire("ADDON_LOADED", "PintoProbe")
  client:fire("PLAYER_ENTERING_WORLD", true, false)
  world:run(10)
  local db = env.PintoProbeDB
  H.ok(db.checks, "the check after login didn't run")
  H.eq(db.probe, 4)

  slash(env, "")
  slash(env, "show")
  slash(env, "crypto")

  client:fire("UNIT_SPELLCAST_SUCCEEDED", "player", "Cast-3-1-0-1-2575-0", 2575)
  client:fire("UNIT_SPELLCAST_SUCCEEDED", "player", "Cast-3-1-0-1-2575-0", 2575)
  client.target = wow.full("Thorn")
  client:fire("UNIT_SPELLCAST_SUCCEEDED", "player", "Cast-3-1-0-1-7927-0", 7927)   -- a bandage on Thorn
  client.combat = true
  client.inCombat[wow.full("Thorn")] = true
  client:fire("PLAYER_REGEN_DISABLED")
  world:run(3)
  client:fire("CHAT_MSG_SYSTEM", wow.secret())
  client:fire("ADDON_ACTION_FORBIDDEN", "SomeAddon", "UNKNOWN()")
  client:fire("CHAT_MSG_SYSTEM", "Wren has joined the guild.")
  client:fire("CHAT_MSG_SYSTEM", "You are now Away.")
  client:fire("UI_INFO_MESSAGE", 0, "Kobold Vermin slain: 3/10")
  client:fire("UI_INFO_MESSAGE", 0, "Trade complete.")
  client.tradeSkill = "First Aid"
  client:fire("TRADE_SKILL_SHOW")
  client:fire("CHAT_MSG_LOOT", "You create: [Linen Bandage].")
  client:fire("ENCOUNTER_START", 663, "Edwin VanCleef", 1, 5)
  client:fire("ENCOUNTER_END", 663, "Edwin VanCleef", 1, 5, 1)
  client:fire("BOSS_KILL", 663, "Edwin VanCleef")
  client:fire("TRADE_SHOW")
  client:fire("GROUP_ROSTER_UPDATE")
  client.hideMaps = true
  client:fire("GROUP_ROSTER_UPDATE")
  client:fire("LOOT_OPENED", false)
  for _ = 1, 20 do client:fire("PLAYER_MONEY") end

  H.eq(#client.errors, 0, "an error reached the client")
  H.eq(#client.forbidden, 0, "the probe registered a forbidden event: " .. tostring(client.forbidden[1]))
  local errors = {}
  for k in pairs(db.errors or {}) do errors[#errors + 1] = k end
  H.eq(#errors, 0, "problems noted: " .. table.concat(errors, " | "))

  local c = db.checks
  H.eq(c.spells.via, "C_Spell.GetSpellName")
  H.eq(c.spells.names[2575], "Mining")
  local utcHour = tonumber(os.date("!%H", math.floor(world.time)))
  H.eq(c.time.offsetHours, ((9 - utcHour + 36) % 24) - 12)
  local missing = table.concat(c.missing, " ")
  H.ok(missing:find("GetSpellInfo", 1, true), "GetSpellInfo should be listed as missing")
  H.ok(next(c.failed) == nil, "a check failed: " .. tostring(next(c.failed)))
  H.eq(c.gear[16].equipLoc, nil)
  H.eq(db.spells[2575].name, "Mining")
  H.eq(db.spells[2575].count, 2)
  H.eq(db.events.FIRST_AID_CAST.count, 1)
  H.eq(db.events.FIRST_AID_CAST.samples[1].args[2], "Thorn")
  H.eq(db.events.FIRST_AID_CAST.samples[1].args[3], "party1")
  H.eq(db.events.FIGHT_TOGETHER.count, 1)
  H.eq(db.events.FIGHT_TOGETHER.samples[1].args[2], "player=true party1=true")
  H.eq(db.secrets.CHAT_MSG_SYSTEM.count, 1)
  H.eq(db.secrets.CHAT_MSG_SYSTEM.args[1], true)
  H.eq(#db.forbidden, 1)
  H.eq(db.forbidden[1].args, "{SomeAddon, UNKNOWN(), n=2}")
  H.eq(db.groups[2].units[1].map, "<secret>")
  H.eq(db.groups[1].units[1].map, "1454")
  H.ok(c.restrictions.issecretvalue, "issecretvalue should be found")
  H.eq(c.restrictions.chatLockdownNow, "false")
  H.ok(c.professions == nil and #c.skills == 0, "no professions on this client")
  H.eq(db.events.GUILD_JOIN_MESSAGE.count, 1)
  H.eq(db.events.GUILD_JOIN_MESSAGE.samples[1].args[1], "Wren has joined the guild.")
  H.eq(db.events.QUEST_PROGRESS.count, 1)
  H.eq(db.events.TRADE_COMPLETE_MESSAGE.count, 1)
  H.eq(db.events.CRAFTED.count, 1)
  H.eq(db.encounters["ENCOUNTER_END:663"].kills, 1)
  H.eq(db.encounters["ENCOUNTER_END:663"].name, "Edwin VanCleef")
  H.eq(db.events.BOSS_FIGHT_SEND.count, 1)
  H.eq(#db.trades, 1)
  H.eq(#db.groups, 2)
  H.eq(db.crypto.ok, true)
  H.eq(db.crypto.stepped, true)
  H.eq(db.events.PLAYER_MONEY.count, 20)
  H.eq(#db.events.PLAYER_MONEY.samples, 8)
  H.eq(#db.events.PLAYER_MONEY.recent, 4)
  H.ok(db.events.TRADE_SKILL_INFO.samples[1].args[1]:find("professionName=First Aid", 1, true),
    "the trade skill's name: " .. tostring(db.events.TRADE_SKILL_INFO.samples[1].args[1]))
  H.ok(db.events.CRAFTED.samples[1].args[3]:find("First Aid", 1, true), "a craft notes the trade skill")
  H.eq(c.widgets.RegisterUnitEvent, true)

  -- names, and the addon messages to itself a little after login
  H.eq(c.names.roster, wow.full("Kiri"))
  local w = db.whisperTest
  H.ok(w, "the whisper test didn't run")
  H.eq(w.arrived["g:guild"].channel, "GUILD")
  H.eq(w.arrived["g:guild"].sender, wow.full("Kiri"))
  if wow.NAMES == "forever" then
    H.eq(c.names.UnitName, "{Kiri, Forever}")
    H.eq(c.names.regionalUnique, "true")
    H.eq(w.sent.space.target, "Kiri Forever")
    H.eq(w.sent.hyphen.target, "Kiri-Forever")
    H.eq(w.arrived["w:space"].sender, "Kiri Forever")
    H.eq(w.arrived["w:hyphen"], nil, "the stand-in only takes whispers to Name Surname")
    H.eq(w.system[1], "No player named 'Kiri-Forever' is currently playing.")
  else
    H.eq(c.names.UnitName, "{Kiri}")
    H.eq(c.names.regionalUnique, "missing")
    H.eq(w.sent.space.target, "Kiri")
    H.eq(w.sent.hyphen, nil)
    H.eq(w.arrived["w:space"].sender, "Kiri-Forever")
  end
end)

H.test("on a client that lacks nearly everything, the probe notes problems and never raises", function()
  local world = wow.world({ seed = 4 })
  local client = world:client(wow.full("Kiri"), { ui = true })
  client.online = true
  local full = client:makeEnv()
  -- Lua itself, and from WoW only frames, the chat frame, timers and wipe
  local KEEP = { CreateFrame = true, DEFAULT_CHAT_FRAME = true, C_Timer = true, UIParent = true, wipe = true,
    pairs = true, ipairs = true, type = true, tostring = true, tonumber = true, pcall = true, xpcall = true,
    select = true, next = true, error = true, assert = true, setmetatable = true, getmetatable = true,
    rawget = true, rawset = true, unpack = true, math = true, string = true, table = true, coroutine = true,
    bit = true }
  local env = setmetatable({}, { __index = function(_, k)
    if KEEP[k] then return full[k] end
    return nil
  end })
  env._G = env
  env.SlashCmdList = {}
  client.env = env
  loadProbe(env)
  client:fire("ADDON_LOADED", "PintoProbe")
  client:fire("PLAYER_ENTERING_WORLD", true, false)
  world:run(10)
  slash(env, "")
  slash(env, "show")
  slash(env, "crypto")
  client:fire("UNIT_SPELLCAST_SUCCEEDED", "player", "Cast", 2575)
  client:fire("COMBAT_LOG_EVENT_UNFILTERED")
  client:fire("TRADE_SHOW")
  client:fire("GROUP_ROSTER_UPDATE")
  client:fire("CHAT_MSG_LOOT", "You create: [Linen Bandage].")
  H.eq(#client.errors, 0, "an error reached the client: " .. tostring(client.errors[1]))
  local db = env.PintoProbeDB
  H.ok(db and db.errors and next(db.errors), "the problems should be noted")
  H.ok(db.checks and next(db.checks.failed), "the checks that failed should be listed")
  H.eq(db.spells[2575].name, "?")
end)

H.test("a new probe version starts a fresh log", function()
  local _, client, env = fullClient()
  env.PintoProbeDB = { events = { OLD = { count = 3, samples = {} } }, groups = { {}, {}, {} } }
  client:fire("ADDON_LOADED", "PintoProbe")
  H.eq(env.PintoProbeDB.events, nil)
  H.eq(env.PintoProbeDB.groups, nil)
  H.eq(env.PintoProbeDB.probe, 4)
end)

H.finish()
