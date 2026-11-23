-- Tracking through the client's own events: gathering, bandages and items, on a client
-- like Forever's (no GetSpellInfo), and on clients that lack some events.
local H = require("harness")
local wow = require("wow")

local FILES = {}
for _, f in ipairs(H.tocFiles()) do
  if f ~= "Main.lua" then FILES[#FILES + 1] = f end
end

local full = wow.full

-- Kiri, in a guild group with Thorn in the same zone. The addon is loaded and its
-- tracking started; change(env) can take APIs away before it loads.
local function setup(opts, change)
  local world = wow.world({ seed = 5 })
  local client = world:client(full("Kiri"), opts)
  client.online = true
  local env = client:makeEnv()
  env.PintoTGD_DB = {}
  if change then change(env) end
  local ns = H.load(FILES, {}, env)
  ns.me = full("Kiri")
  world.time = ns.Time.dayStart(ns.Time.dayOfDate(ns.Build.goLive) + 10) + 7200
  ns.Roster.members = {
    [full("Kiri")] = { name = full("Kiri"), rankIndex = 2, level = 30, online = true, note = "" },
    [full("Thorn")] = { name = full("Thorn"), rankIndex = 2, level = 31, online = true, note = "" },
  }
  ns.Roster.loaded = true
  client.group = { full("Thorn") }
  client.unitMap = { party1 = full("Thorn") }
  env.UnitGUID = function(unit)
    if unit == "player" then return "Player-1-Kiri" end
    if unit == "party1" then return "Player-1-Thorn" end
  end
  ns.Activity.Init()
  return world, client, env, ns
end

H.test("gathering with a guildie counts, on a client that only has C_Spell", function()
  local _, client, env, ns = setup()
  H.eq(env.GetSpellInfo, nil, "the stand-in client should have no GetSpellInfo")
  client:fire("UNIT_SPELLCAST_SUCCEEDED", "player", "Cast-3-1-0-1-2575-0", 2575)
  client:fire("UNIT_SPELLCAST_SUCCEEDED", "player", "Cast-3-1-0-1-133-0", 133)     -- Fireball
  client:fire("UNIT_SPELLCAST_SUCCEEDED", "party1", "Cast-3-1-0-1-2366-0", 2366)   -- not ours
  local gathers = ns.Log.Mine().gathers
  H.eq(#gathers, 1)
  H.eq(gathers[1].kind, "mine")
  H.ok(gathers[1].guildies[full("Thorn")], "Thorn should be noted")
  H.eq(#client.errors, 0)
end)

H.test("a gathering cast the addon has no id for is known by its name", function()
  wow.SPELLS[32606] = "Mining"
  local _, client, _, ns = setup()
  client:fire("UNIT_SPELLCAST_SUCCEEDED", "player", "Cast", 32606)
  wow.SPELLS[32606] = nil
  H.eq(#ns.Log.Mine().gathers, 1)
  H.eq(ns.Log.Mine().gathers[1].kind, "mine")
end)

H.test("with no way to name spells, gathering still counts by spell id", function()
  local _, client, _, ns = setup(nil, function(env) env.C_Spell = nil end)
  H.eq(ns.Compat.SpellName(2575), nil)
  client:fire("UNIT_SPELLCAST_SUCCEEDED", "player", "Cast", 8613)
  H.eq(ns.Log.Mine().gathers[1].kind, "skin")
  H.eq(#client.errors, 0)
end)

H.test("an old client with only GetSpellInfo still names spells", function()
  local _, _, _, ns = setup(nil, function(env)
    env.C_Spell = nil
    env.GetSpellInfo = function(id) return wow.SPELLS[id], nil, 0 end
  end)
  H.eq(ns.Compat.SpellName(7620), "Fishing")
end)

H.test("bandaging the guildie you target is noted in the group session", function()
  local world, client, _, ns = setup()
  client:fire("GROUP_ROSTER_UPDATE")
  world:run(2)
  local session = ns.Log.OpenSession()
  H.ok(session, "no group session")
  -- on yourself (nothing targeted), and the First Aid skill itself: neither counts
  client:fire("UNIT_SPELLCAST_SUCCEEDED", "player", "Cast", 3267)
  client.target = full("Thorn")
  client:fire("UNIT_SPELLCAST_SUCCEEDED", "player", "Cast", 3273)
  H.eq(next(session.bandaged), nil, "nothing should be noted yet")
  -- a Heavy Silk Bandage on Thorn
  client:fire("UNIT_SPELLCAST_SUCCEEDED", "player", "Cast", 7927)
  H.ok(session.bandaged[full("Thorn")], "the bandage wasn't noted")
  H.eq(#client.errors, 0)
end)

H.test("a fight together in the open world makes it a quest group", function()
  local world, client, _, ns = setup()
  client:fire("GROUP_ROSTER_UPDATE")
  world:run(2)
  H.eq(ns.Activity.Kind(), ns.Pieces.ACT.other)
  -- fighting alone while grouped doesn't count
  client.combat = true
  client:fire("PLAYER_REGEN_DISABLED")
  world:run(3)
  H.eq(ns.Activity.Kind(), ns.Pieces.ACT.other)
  client.combat = false
  client:fire("PLAYER_REGEN_ENABLED")
  -- Thorn joins in
  client.combat = true
  client.inCombat[full("Thorn")] = true
  client:fire("PLAYER_REGEN_DISABLED")
  world:run(3)
  H.eq(ns.Activity.Kind(), ns.Pieces.ACT.quest)
  H.eq(#client.errors, 0)
end)

H.test("while the client hides maps, who's present stays as it was", function()
  local world, client, _, ns = setup()
  client:fire("GROUP_ROSTER_UPDATE")
  world:run(2)
  H.ok(ns.Activity.Present()[full("Thorn")], "Thorn should be present")
  client.hideMaps = true
  H.ok(ns.Activity.Present()[full("Thorn")], "Thorn should stay present while maps are hidden")
  client.hideMaps = false
  client.group, client.unitMap = {}, {}
  H.eq(next(ns.Activity.Present()), nil)
  client.hideMaps = true
  H.eq(next(ns.Activity.Present()), nil, "nobody comes back while maps are hidden")
  H.eq(#client.errors, 0)
end)

H.test("hidden values: an event is skipped when Pinto reads them, not otherwise", function()
  local _, client, _, ns = setup()
  client:fire("CHAT_MSG_LOOT", wow.secret())
  client:fire("UI_INFO_MESSAGE", 0, wow.secret())
  client:fire("CHAT_MSG_SYSTEM", wow.secret())
  client:fire("UNIT_SPELLCAST_SUCCEEDED", "player", "Cast", wow.secret())   -- the spell hidden: skipped
  H.eq(#ns.Log.Mine().gathers, 0)
  client:fire("UNIT_SPELLCAST_SUCCEEDED", "player", wow.secret(), 2575)     -- only the cast id: counts
  H.eq(#ns.Log.Mine().gathers, 1)
  client:fire("CHAT_MSG_LOOT", "You receive loot: item:2589 class:7:5.", wow.secret())
  H.eq(#client.errors, 0, "an event with a hidden value raised: " .. tostring(client.errors[1]))
end)

H.test("professions come from GetProfessions on a client that lists them that way", function()
  local _, client, env, ns = setup({ professions = true })
  H.eq(env.GetNumSkillLines, nil, "the stand-in client should only have GetProfessions")
  client.skills = { { name = "Tailoring", rank = 120 }, { name = "Fishing", rank = 75 },
    { name = "Enchanting", rank = 95 }, { name = "First Aid", rank = 150 } }
  env.PintoTGD_DB.chars = {}
  ns.Player.Refresh()
  local c = env.PintoTGD_DB.chars[full("Kiri")]
  H.eq(#c.prof, 2)
  H.eq(c.prof[1].id, 3)      -- Enchanting
  H.eq(c.prof[1].skill, 95)
  H.eq(c.prof[2].id, 9)      -- Tailoring
  H.eq(c.fish, 75)
  H.eq(c.aid, 150)
  H.eq(c.cook, 0)
end)

H.test("an older client's skill lines still give the professions", function()
  local _, client, env, ns = setup()
  client.skills = { { name = "Mining", rank = 210 }, { name = "Cooking", rank = 40 } }
  env.PintoTGD_DB.chars = {}
  ns.Player.Refresh()
  local c = env.PintoTGD_DB.chars[full("Kiri")]
  H.eq(#c.prof, 1)
  H.eq(c.prof[1].id, 7)      -- Mining
  H.eq(c.cook, 40)
end)

H.test("items through C_Item only: materials, item levels and bags", function()
  local _, _, env, ns = setup({ modernItems = true })
  H.eq(env.GetItemInfoInstant, nil, "the stand-in client should only have C_Item")
  H.eq(ns.Activity.MaterialKind("item:2589 class:7:5"), "cloth")
  H.eq(ns.Activity.MaterialKind("item:2770 class:7:7"), "ore")
  H.eq(ns.Activity.MaterialKind("item:118 class:0:1"), nil)
  H.eq(ns.Compat.ItemLevel("item:2000 ilvl:24"), 24)
  local _, id, tags = ns.Trades.Classify("item:4496 class:1:0 equip:INVTYPE_BAG", false)
  H.eq(id, 4496)
  H.ok(tags.bag, "a bag should be tagged as one")
end)

H.test("group quests come from the quest log: C_QuestLog, or an older client's GetQuestLogTitle", function()
  for _, old in ipairs({ false, true }) do
    local world, client, env, ns = setup({ oldQuestLog = old })
    H.eq(env.GetQuestLogTitle == nil, not old)
    client.quests = { { title = "Elwynn Forest", isHeader = true }, { questID = 100, suggestedGroup = 3 },
      { questID = 101, suggestedGroup = 0 }, { questID = 102, elite = true } }
    client:fire("QUEST_LOG_UPDATE")
    client:fire("GROUP_ROSTER_UPDATE")
    world:run(2)
    client:fire("QUEST_TURNED_IN", 100, 500, 0)
    client:fire("QUEST_TURNED_IN", 101, 500, 0)
    client:fire("QUEST_TURNED_IN", 102, 500, 0)
    local turnins = ns.Log.Mine().turnins
    H.eq(#turnins, 3)
    H.eq(turnins[1].group, true, "quest 100 has a suggested group")
    H.eq(turnins[2].group, false)
    H.eq(turnins[3].group, true, "quest 102 is tagged Elite")
    H.ok(turnins[1].guildies[full("Thorn")], "Thorn was there")
    H.eq(#client.errors, 0)
  end
end)

H.test("a crafted item remembers its profession, from C_TradeSkillUI or an older client's GetTradeSkillLine", function()
  local _, client, env, ns = setup()
  ns.Trades.Init()
  H.eq(env.GetTradeSkillLine, nil, "the stand-in client should have no GetTradeSkillLine")
  client.tradeSkill = "First Aid"
  client:fire("CHAT_MSG_LOOT", "You create: |cnIQ1:|Hitem:2581::::::::24:1484:::::::::|h[Heavy Linen Bandage]|h|r.")
  local crafted = env.PintoTGD_DB.crafted[2581]
  H.eq(crafted.prof, "First Aid")
  H.eq(crafted.line, 129)
  -- the skill line counts whatever the client's language calls the profession
  crafted.prof = "Erste Hilfe"
  local _, _, tags = ns.Trades.Classify("item:2581", true)
  H.ok(tags.bandage, "a First Aid craft should count as a bandage")
  client.tradeSkill = nil
  H.eq(ns.Compat.TradeSkill(), nil, "no trade skill window is open")
  env.GetTradeSkillLine = function() return "Tailoring" end
  local name, line = ns.Compat.TradeSkill()
  H.eq(name, "Tailoring")
  H.eq(line, nil)
  env.GetTradeSkillLine = function() return "UNKNOWN" end
  H.eq(ns.Compat.TradeSkill(), nil)
  H.eq(#client.errors, 0)
end)

-- A trade window. mine and theirs: { [slot] = { link, count, enchant, quest } }, slot 7
-- being the one whose item isn't traded. As on Forever, our side's values are name, icon,
-- count, quality, enchant, quest item, bound, item id; theirs are name, icon, count,
-- quality, usable, enchant, item id.
local function tradeWindow(env, mine, theirs)
  env.GetTradePlayerItemLink = function(i) return mine[i] and mine[i].link end
  env.GetTradeTargetItemLink = function(i) return theirs[i] and theirs[i].link end
  env.GetTradePlayerItemInfo = function(i)
    local it = mine[i]
    if not it then return nil, nil, 0, 0, nil, false, false, 0 end
    return "Item", 0, it.count or 1, 1, it.enchant, it.quest or false, false, 0
  end
  env.GetTradeTargetItemInfo = function(i)
    local it = theirs[i]
    if not it then return nil, nil, 0, 0, nil, nil, 0 end
    return "Item", 0, it.count or 1, 1, true, it.enchant, 0
  end
end

H.test("a trade with a guildie: materials, and enchants on the item that isn't traded", function()
  local world, client, env, ns = setup()
  ns.Trades.Init()
  local TRADE = ns.Pieces.TRADE
  client.unitMap.NPC = full("Thorn")
  -- Kiri gives Thorn wool cloth, and Thorn enchants Kiri's gloves in slot 7
  tradeWindow(env, { [1] = { link = "item:2592 class:7:5", count = 10 },
    [7] = { link = "item:2036", enchant = "Enchant Gloves - Mining" } }, {})
  client:fire("TRADE_SHOW")
  client:fire("UI_INFO_MESSAGE", 251, "Trade complete.")
  client:fire("TRADE_CLOSED")
  world:run(1)
  -- a quest item in Kiri's slot 7 isn't an enchant; Thorn's chest that Kiri enchants is
  tradeWindow(env, { [7] = { link = "item:5000", quest = true } },
    { [7] = { link = "item:2985", enchant = "Enchant Chest - Minor Health" } })
  client:fire("TRADE_SHOW")
  client:fire("UI_INFO_MESSAGE", 251, "Trade complete.")
  local trades = ns.Log.Mine().trades
  H.eq(#trades, 3)
  H.eq(trades[1].dir, "out")
  H.eq(trades[1].kind, TRADE.materials)
  H.eq(trades[1].who, full("Thorn"))
  H.eq(trades[1].count, 10)
  H.eq(trades[2].dir, "in")
  H.eq(trades[2].kind, TRADE.enchant)
  H.eq(trades[3].dir, "out")
  H.eq(trades[3].kind, TRADE.enchant)
  H.eq(trades[3].item, 2985)
  H.eq(#client.errors, 0)
end)

H.test("only the player's own casts reach Pinto: other units' come with their spell hidden", function()
  local _, client, _, ns = setup()
  local units = ns.eventFrame.units and ns.eventFrame.units.UNIT_SPELLCAST_SUCCEEDED
  H.ok(units and units.player, "UNIT_SPELLCAST_SUCCEEDED should be registered for the player only")
  local count = 0
  ns.Events.On("UNIT_SPELLCAST_SUCCEEDED", function() count = count + 1 end)
  client:fire("UNIT_SPELLCAST_SUCCEEDED", "party1", wow.secret(), wow.secret())
  client:fire("UNIT_SPELLCAST_SUCCEEDED", "nameplate3", wow.secret(), wow.secret())
  client:fire("UNIT_SPELLCAST_SUCCEEDED", "player", "Cast-3-1-0-1-133-0", 133)
  H.eq(count, 1)
  H.eq(#client.errors, 0)
end)

H.test("events the client doesn't have are skipped, and the rest still work", function()
  local _, client, _, ns = setup({ unknownEvents = { ENCOUNTER_END = true, LOOT_OPENED = true } })
  H.ok(ns.unknownEvents.ENCOUNTER_END)
  H.ok(ns.unknownEvents.LOOT_OPENED)
  H.eq(ns.unknownEvents.UNIT_SPELLCAST_SUCCEEDED, nil)
  client:fire("UNIT_SPELLCAST_SUCCEEDED", "player", "Cast", 2575)
  H.eq(#ns.Log.Mine().gathers, 1)
end)

H.test("Pinto starts on a client that lacks some events", function()
  local world = wow.world({ seed = 9 })
  world:addMember(full("Kiri"), { rankIndex = 0 })
  local client = world:client(full("Kiri"), {
    unknownEvents = { ENCOUNTER_END = true, TRADE_ACCEPT_UPDATE = true, QUEST_TURNED_IN = true } })
  client:login()
  world:run(5)
  H.eq(#client.errors, 0)
  H.ok(client.ns.started, "Pinto didn't start")
  H.eq(client.ns.disabled, nil)
  H.ok(client.ns.unknownEvents.QUEST_TURNED_IN)
end)

H.test("Pinto never registers an event the client forbids", function()
  local world = wow.world({ seed = 10 })
  world:addMember(full("Kiri"), { rankIndex = 0 })
  local client = world:client(full("Kiri"), { ui = true })
  client:login()
  world:run(5)
  H.eq(#client.errors, 0)
  H.ok(client.ns.started, "Pinto didn't start")
  H.eq(#client.forbidden, 0, "registered a forbidden event: " .. tostring(client.forbidden[1]))
end)

H.test("addon messages wait out a chat lockdown, then go", function()
  local world = wow.world({ seed = 11 })
  world:addMember(full("Kiri"), { rankIndex = 0 })
  world:addMember(full("Thorn"))
  local kiri = world:client(full("Kiri"))
  kiri:login()
  world:run(10)
  local sent = world.stats.sent
  kiri.lockdown = true
  kiri.ns.Protocol.Hello()
  world:run(5)
  H.eq(world.stats.sent, sent, "nothing should go out during a lockdown")
  H.ok(kiri.ns.Comm.QueueSize() > 0, "the hello should wait in the queue")
  -- the client says it isn't locked, but refuses the message anyway: it waits again
  kiri.env.C_ChatInfo.InChatMessagingLockdown = function() return false end
  world:run(3)
  H.eq(world.stats.sent, sent)
  H.ok(kiri.ns.Comm.QueueSize() > 0, "a refused message should go back in the queue")
  kiri.lockdown = false
  world:run(5)
  H.ok(world.stats.sent > sent, "the hello should go out after the lockdown")
  H.eq(kiri.ns.Comm.QueueSize(), 0)
  H.eq(#kiri.errors, 0)
end)

-- Forever takes addon messages during a dungeon boss fight without a lockdown, and they
-- never arrive: Pinto holds them until the fight ends.
H.test("addon messages wait out a boss fight, which the client doesn't call a lockdown", function()
  local world = wow.world({ seed = 12 })
  world:addMember(full("Kiri"), { rankIndex = 0 })
  world:addMember(full("Thorn"))
  local kiri = world:client(full("Kiri"))
  kiri:login()
  world:run(60)
  local Comm = kiri.ns.Comm
  local function fight(id, name)
    kiri:fire("ENCOUNTER_START", id, name, 1, 5)
    kiri.ns.Protocol.Hello()
    world:run(30)
    return Comm.stats.sent
  end
  local sent = Comm.stats.sent
  H.eq(fight(2755, "Archmage Arugal"), sent, "nothing should go out during the fight")
  H.ok(Comm.QueueSize() > 0, "the hello should wait in the queue")
  kiri:fire("ENCOUNTER_END", 2755, "Archmage Arugal", 1, 5, 1, {})
  world:run(5)
  H.ok(Comm.stats.sent > sent, "the hello should go out after the fight")
  -- a fight whose end never comes: a loading screen ends the wait
  sent = Comm.stats.sent
  H.eq(fight(2753, "Fenrus the Devourer"), sent)
  kiri:fire("PLAYER_ENTERING_WORLD", false, false)
  world:run(5)
  H.ok(Comm.stats.sent > sent, "a loading screen should end the wait")
  -- and so does half an hour
  sent = Comm.stats.sent
  H.eq(fight(2753, "Fenrus the Devourer"), sent)
  world:run(1760)
  H.eq(Comm.stats.sent, sent)
  world:run(20)
  H.ok(Comm.stats.sent > sent, "half an hour should end the wait")
  H.eq(#kiri.errors, 0)
end)

H.finish()
