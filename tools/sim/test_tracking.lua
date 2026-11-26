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

-- More guildies in Kiri's group, all in the same zone.
local function party(client, ns, names)
  client.group, client.unitMap = {}, {}
  for i, n in ipairs(names) do
    ns.Roster.members[full(n)] = { name = full(n), rankIndex = 2, level = 30, online = true, note = "" }
    client.group[i] = full(n)
    client.unitMap["party" .. i] = full(n)
  end
end

local function moments(ns, kind)
  local list = {}
  for _, m in ipairs(ns.Log.Moments(ns.Log.Mine())) do
    if m.kind == kind then list[#list + 1] = m end
  end
  return list
end

local function size(set)
  local n = 0
  for _ in pairs(set) do n = n + 1 end
  return n
end

-- A table's keys with their values, one per line, for failure messages.
local function dump(t)
  local lines = {}
  for k, v in pairs(t) do lines[#lines + 1] = tostring(k) .. " = " .. tostring(v) end
  table.sort(lines)
  return table.concat(lines, "\n")
end

H.test("a camp: a campfire lit, then a feature added within 15 minutes, with a guildie nearby", function()
  local world, client, _, ns = setup()
  local function cast(id) client:fire("UNIT_SPELLCAST_SUCCEEDED", "player", "Cast", id) end
  -- crafting a Basic Campfire Kit and a Camp Tent (their recipes) isn't setting up camp,
  -- and a feature with no campfire lit isn't either
  cast(1229737)
  cast(1229432)
  cast(1307230)
  H.eq(#moments(ns, "camp"), 0)
  -- a Basic Campfire Kit, then 10 minutes later a Camp Tent
  cast(1307227)
  H.eq(#moments(ns, "camp"), 0, "a campfire alone isn't a camp yet")
  world:run(600)
  cast(1307230)
  local camps = moments(ns, "camp")
  H.eq(#camps, 1)
  H.ok(camps[1].guildies[full("Thorn")], "Thorn was there")
  -- 16 minutes after the campfire, its campsite is gone: a Fish Bowl is too late
  world:run(360)
  cast(1307245)
  H.eq(#moments(ns, "camp"), 1)
  -- an Expert Campfire Kit and a Fish Bowl, alone: nothing
  cast(1307237)
  client.group, client.unitMap = {}, {}
  cast(1307245)
  H.eq(#moments(ns, "camp"), 1)
  H.eq(#client.errors, 0)
end)

H.test("a camp item whose spell Pinto doesn't list counts by the spell the client says it casts", function()
  local world, client, _, ns = setup()
  local function cast(id) client:fire("UNIT_SPELLCAST_SUCCEEDED", "player", "Cast", id) end
  -- before the client has the items: an unknown spell is nothing
  cast(1999002)
  cast(1999001)
  H.eq(#moments(ns, "camp"), 0)
  -- the client has them now (asked again a minute later): a Basic Campfire Kit and an Iron
  -- Oven under spells Pinto doesn't list
  wow.ITEM_SPELLS[279981], wow.ITEM_SPELLS[279982] = 1999002, 1999001
  world:run(61)
  cast(1999002)
  cast(1999001)
  wow.ITEM_SPELLS[279981], wow.ITEM_SPELLS[279982] = nil, nil
  H.eq(#moments(ns, "camp"), 1)
  H.eq(#client.errors, 0)
end)

H.test("dancing: the player and guildies nearby in the group, all within a minute", function()
  local world, client, _, ns = setup()
  party(client, ns, { "Thorn", "Bram", "Ash" })
  local function emote(text, who) client:fire("CHAT_MSG_TEXT_EMOTE", text, who) end
  -- Thorn first: nothing yet, since Kiri isn't dancing
  emote("Thorn bursts into dance.", full("Thorn"))
  H.eq(#moments(ns, "dance"), 0)
  -- Kiri joins in (the game gives just the first name), then the others; another emote
  -- doesn't count
  emote("You burst into dance.", "Kiri")
  emote("Bram cheers at you.", "Bram")
  H.eq(size(moments(ns, "dance")[1].guildies), 1)
  world:run(20)
  emote("Bram dances with you.", "Bram")
  world:run(20)
  emote("Ash bursts into dance.", full("Ash"))
  local dances = moments(ns, "dance")
  H.eq(#dances, 3, "noted again each time more join in")
  H.eq(size(dances[3].guildies), 3)
  for _, n in ipairs({ "Thorn", "Bram", "Ash" }) do H.ok(dances[3].guildies[full(n)], n .. " danced") end
  -- the same dancers again within the minute: not noted again
  emote("Thorn bursts into dance.", full("Thorn"))
  H.eq(#moments(ns, "dance"), 3)
  -- a minute later, a dance on its own doesn't count with the old ones
  world:run(61)
  emote("You burst into dance.", "Kiri")
  emote("Thorn bursts into dance.", full("Thorn"))
  dances = moments(ns, "dance")
  H.eq(size(dances[#dances].guildies), 1, "only Thorn, this minute")
  H.eq(#client.errors, 0)
end)

H.test("cheering together: /cheer, /clap or /congratulate, any mix, all within a minute", function()
  local world, client, _, ns = setup()
  party(client, ns, { "Thorn", "Bram", "Ash" })
  local function emote(text, who) client:fire("CHAT_MSG_TEXT_EMOTE", text, who) end
  emote("You cheer!", "Kiri")
  emote("Thorn claps excitedly for you.", full("Thorn"))
  emote("Bram dances with you.", "Bram")
  H.eq(size(moments(ns, "jolly")[1].guildies), 1, "a dance isn't cheering")
  emote("Bram congratulates you.", "Bram")
  world:run(30)
  emote("Ash cheers at Bram.", full("Ash"))
  local cheers = moments(ns, "jolly")
  H.eq(#cheers, 3)
  H.eq(size(cheers[3].guildies), 3)
  H.eq(#moments(ns, "dance"), 0, "Bram danced alone")
  H.eq(#client.errors, 0)
end)

H.test("an emote is read right after whoever used it, so a name isn't taken for one", function()
  local _, _, _, ns = setup()
  local kind = ns.Activity.EmoteKind
  H.eq(kind("You burst into dance.", "Kiri"), "dance")
  H.eq(kind("You dance with Thorn.", "Kiri"), "dance")
  H.eq(kind("Thorn Oak dances with you.", "Thorn Oak"), "dance")
  H.eq(kind("Thorn bursts into dance.", "Thorn-Realm"), "dance")
  H.eq(kind("You cheer!", "Kiri"), "jolly")
  H.eq(kind("Bram claps excitedly.", "Bram"), "jolly")
  H.eq(kind("You congratulate everyone around you.", "Kiri"), "jolly")
  H.eq(kind("Ash congratulates you.", "Ash"), "jolly")
  H.eq(kind("Clapton cheers at you.", "Clapton"), "jolly")
  H.eq(kind("Cheerio waves.", "Cheerio"), nil)
  H.eq(kind("Thorn waves at Dancer.", "Thorn"), nil)
  H.eq(kind("Bram waves at Cheers.", "Bram"), nil)
  H.eq(kind("You applaud. Bravo!", "Kiri"), nil)
  H.eq(kind("Thorn cheers!", "Bram"), nil, "the text has to start with whoever used it")
end)

H.test("in a dungeon with the maps hidden, a guildie who comes later counts once in sight", function()
  local world, client, _, ns = setup()
  client:fire("GROUP_ROSTER_UPDATE")
  world:run(2)
  -- into Shadowfang Keep: the client hides where everyone is
  client.instance = { kind = "party", id = 33 }
  client.hideMaps = true
  client:fire("ZONE_CHANGED_NEW_AREA")
  world:run(3)
  H.ok(ns.Activity.Present()[full("Thorn")], "Thorn came in with Kiri")
  -- Bram joins the group, still on the way
  party(client, ns, { "Thorn", "Bram" })
  client.unseen[full("Bram")] = true
  world:run(15)
  H.eq(ns.Activity.Present()[full("Bram")], nil, "Bram isn't here yet")
  -- Bram arrives: in sight, Bram counts, and goes on counting out of sight
  client.unseen[full("Bram")] = nil
  world:run(15)
  H.ok(ns.Activity.Present()[full("Bram")], "Bram is in sight")
  client.unseen[full("Bram")] = true
  world:run(620)
  local session = ns.Log.OpenSession()
  H.eq(session.act, ns.Pieces.ACT.dungeon)
  H.ok(session.members[full("Bram")], "10 minutes with Bram in the dungeon")
  client:fire("ENCOUNTER_END", 2755, "Archmage Arugal", 1, 5, 1)
  H.eq(session.bosses, 1)
  -- while the client hides who's in sight too, someone new waits for an answer
  client.hideSight = true
  party(client, ns, { "Thorn", "Bram", "Ash" })
  H.eq(ns.Activity.Present()[full("Ash")], nil)
  H.ok(ns.Activity.Present()[full("Bram")], "Bram stays")
  -- someone who goes offline isn't nearby, whatever the last answer was
  client.offline[full("Bram")] = true
  H.eq(ns.Activity.Present()[full("Bram")], nil, "Bram went offline")
  H.eq(#client.errors, 0)
end)

-- Kiri walks into an instance the client has no maps for, or back out of one.
local function goInside(world, client, id, zone)
  client.instance, client.noMaps, client.zone = { kind = "party", id = id }, true, zone
  client:fire("ZONE_CHANGED_NEW_AREA")
  world:run(3)
end

local function goOutside(world, client, zone)
  client.instance, client.noMaps, client.zone = { kind = "none", id = 0 }, false, zone
  client:fire("ZONE_CHANGED_NEW_AREA")
  world:run(3)
end

-- The zone the guild roster shows for some members.
local function rosterZone(ns, zone, names)
  for _, n in ipairs(names) do ns.Roster.members[full(n)].zone = zone end
end

H.test("a dungeon the client has no maps for: the group walks in one by one, and the run is logged with everyone", function()
  local world, client, _, ns = setup()
  party(client, ns, { "Thorn", "Bram", "Ash", "Wren" })
  client.zone = "The Barrens"
  rosterZone(ns, "The Barrens", { "Kiri", "Thorn", "Bram", "Ash", "Wren" })
  client:fire("GROUP_ROSTER_UPDATE")
  world:run(30)
  H.eq(size(ns.Activity.Present()), 4)
  -- Thorn and Bram walk in ahead: the client has no map for them now, they're out of
  -- sight, and the guild roster says so a little later
  for _, n in ipairs({ "Thorn", "Bram" }) do client.maps[full(n)], client.unseen[full(n)] = false, true end
  world:run(15)
  rosterZone(ns, "Wailing Caverns", { "Thorn", "Bram" })
  world:run(15)
  H.eq(size(ns.Activity.Present()), 4, "those ahead still count while Kiri follows")
  -- Kiri walks in, and sees them again; Ash and Wren follow half a minute later
  for _, n in ipairs({ "Thorn", "Bram" }) do client.unseen[full(n)] = nil end
  for _, n in ipairs({ "Ash", "Wren" }) do client.unseen[full(n)] = true end
  goInside(world, client, 43, "Wailing Caverns")
  rosterZone(ns, "Wailing Caverns", { "Kiri" })
  world:run(30)
  H.eq(size(ns.Activity.Present()), 4, "those behind still count for 45 seconds")
  rosterZone(ns, "Wailing Caverns", { "Ash", "Wren" })
  for _, n in ipairs({ "Ash", "Wren" }) do client.unseen[full(n)] = nil end
  -- the run: 25 minutes and two bosses, with Wren out of sight for the second half
  world:run(600)
  client:fire("ENCOUNTER_END", 9001, "Lord Cobrahn", 1, 5, 1)
  client.unseen[full("Wren")] = true
  world:run(600)
  client:fire("ENCOUNTER_END", 9002, "Lady Anacondra", 1, 5, 1)
  world:run(300)
  local s = ns.Log.OpenSession()
  H.eq(s.act, ns.Pieces.ACT.dungeon)
  H.eq(s.inst, 43)
  H.eq(s.bosses, 2)
  H.eq(size(s.members), 4, "all four were with Kiri for 10 minutes")
  H.eq(size(s.present), 4, "Wren counts by the guild roster's zone")
  H.ok(s.last - s.start >= 1200, "a 25 minute run")
  H.eq(#client.errors, 0)
end)

H.test("a guildie who stays outside the dungeon stops counting after 45 seconds", function()
  local world, client, _, ns = setup()
  party(client, ns, { "Thorn", "Bram" })
  client.zone = "Silverpine Forest"
  rosterZone(ns, "Silverpine Forest", { "Kiri", "Thorn", "Bram" })
  client:fire("GROUP_ROSTER_UPDATE")
  world:run(20)
  -- Kiri and Thorn go in; Bram stays outside, out of sight
  client.unseen[full("Bram")] = true
  goInside(world, client, 33, "Shadowfang Keep")
  rosterZone(ns, "Shadowfang Keep", { "Kiri", "Thorn" })
  world:run(30)
  H.ok(ns.Activity.Present()[full("Bram")], "Bram may still be on the way")
  world:run(30)
  H.eq(ns.Activity.Present()[full("Bram")], nil, "Bram stayed outside")
  H.ok(ns.Activity.Present()[full("Thorn")], "Thorn is inside with Kiri")
  -- Bram comes in after all: the roster shows it, in sight or not
  rosterZone(ns, "Shadowfang Keep", { "Bram" })
  H.ok(ns.Activity.Present()[full("Bram")], "Bram is in the dungeon by the roster")
  H.eq(#client.errors, 0)
end)

H.test("in the open world, a guildie on another map stops counting after 45 seconds, unless in sight", function()
  local world, client, _, ns = setup()
  client:fire("GROUP_ROSTER_UPDATE")
  world:run(2)
  client.maps[full("Thorn")] = 1411
  H.ok(ns.Activity.Present()[full("Thorn")], "in sight across a zone border")
  client.unseen[full("Thorn")] = true
  H.ok(ns.Activity.Present()[full("Thorn")], "a moment's grace")
  world:run(50)
  H.eq(ns.Activity.Present()[full("Thorn")], nil, "Thorn is elsewhere")
  -- within spell range counts like in sight does
  client.inRange[full("Thorn")] = true
  H.ok(ns.Activity.Present()[full("Thorn")], "in range")
  client.inRange[full("Thorn")] = nil
  world:run(50)
  -- back on Kiri's map
  client.maps[full("Thorn")] = nil
  H.ok(ns.Activity.Present()[full("Thorn")], "on the same map again")
  H.eq(#client.errors, 0)
end)

H.test("while the client hides group members' names, whoever was nearby stays nearby", function()
  local world, client, _, ns = setup()
  party(client, ns, { "Thorn", "Bram" })
  client:fire("GROUP_ROSTER_UPDATE")
  world:run(2)
  H.eq(size(ns.Activity.Present()), 2)
  -- the units are known by the names they had, so what the game says of them still counts
  client.hideNames = true
  H.eq(size(ns.Activity.Present()), 2, "known by the names their units had")
  client.offline[full("Bram")] = true
  H.eq(size(ns.Activity.Present()), 1, "Bram went offline")
  client.offline[full("Bram")] = nil
  H.eq(size(ns.Activity.Present()), 2, "and came back")
  -- Thorn leaves while the names are hidden: "party1" is Bram now, and nobody can be told
  -- apart, so everyone stays as they were
  party(client, ns, { "Bram" })
  client:fire("GROUP_ROSTER_UPDATE")
  world:run(2)
  H.eq(size(ns.Activity.Present()), 2)
  -- the names are back: only Bram is in the group
  client.hideNames = false
  H.eq(size(ns.Activity.Present()), 1)
  H.ok(ns.Activity.Present()[full("Bram")], "Bram is still here")
  H.eq(#client.errors, 0)
end)

H.test("inside a dungeon that has maps, a guildie on another floor is still in the dungeon", function()
  local world, client, _, ns = setup()
  party(client, ns, { "Thorn", "Bram" })
  client.instance, client.zone = { kind = "party", id = 48 }, "Blackfathom Deeps"
  rosterZone(ns, "Blackfathom Deeps", { "Thorn" })
  for _, n in ipairs({ "Thorn", "Bram" }) do client.maps[full(n)], client.unseen[full(n)] = 222, true end
  -- Thorn: another floor's map, out of sight, and by the roster in the place the game
  -- names for Kiri. Bram: the roster doesn't say, so there's nothing to go by yet.
  local present = ns.Activity.Present()
  H.ok(present[full("Thorn")], "Thorn is in the dungeon")
  H.eq(present[full("Bram")], nil)
  world:run(60)
  H.ok(ns.Activity.Present()[full("Thorn")], "and stays there")
  -- the game stops naming the place, but the roster shows Kiri and Bram in it too
  client.zone = nil
  rosterZone(ns, "Blackfathom Deeps", { "Kiri", "Bram" })
  H.ok(ns.Activity.Present()[full("Bram")], "Bram is in the dungeon by the roster's zone for Kiri")
  H.eq(#client.errors, 0)
end)

H.test("while the maps don't say who's where, the guild roster is asked for more often", function()
  local world, client, env, ns = setup()
  local asks = 0
  local ask = env.C_GuildInfo.GuildRoster
  env.C_GuildInfo.GuildRoster = function() asks = asks + 1 return ask() end
  client:fire("GROUP_ROSTER_UPDATE")
  world:run(60)
  H.eq(asks, 0, "the maps say who's where")
  client.unseen[full("Thorn")] = true
  goInside(world, client, 33, "Shadowfang Keep")
  world:run(60)
  H.ok(asks >= 3 and asks <= 6, "about every 15 seconds: " .. asks)
  H.eq(#client.errors, 0)
end)

H.test("a wipe and the run back don't split a dungeon run; a finished run isn't taken up again", function()
  local world, client, _, ns = setup()
  client.zone = "Silverpine Forest"
  client:fire("GROUP_ROSTER_UPDATE")
  world:run(2)
  goInside(world, client, 33, "Shadowfang Keep")
  world:run(300)
  client:fire("ENCOUNTER_END", 2748, "Rethilgore", 1, 5, 1)
  local run = ns.Log.OpenSession()
  H.eq(run.bosses, 1)
  -- a wipe: 5 minutes outside, running back from the graveyard
  goOutside(world, client, "Silverpine Forest")
  world:run(300)
  H.ok(ns.Log.OpenSession() ~= run, "outside is a session of its own")
  H.eq(#ns.Log.Mine().groups, 3, "outside before, the run, outside after")
  goInside(world, client, 33, "Shadowfang Keep")
  H.ok(ns.Log.OpenSession() == run, "back inside: the same run")
  H.eq(#ns.Log.Mine().groups, 3)
  client:fire("ENCOUNTER_END", 2749, "Razorclaw the Butcher", 1, 5, 1)
  H.eq(run.bosses, 2)
  -- more than half an hour away: a new run
  goOutside(world, client, "Silverpine Forest")
  world:run(1900)
  goInside(world, client, 33, "Shadowfang Keep")
  local second = ns.Log.OpenSession()
  H.ok(second ~= run, "after half an hour away it's a new run")
  H.eq(second.bosses, 0)
  -- a run whose final boss is down isn't taken up again
  second.final = true
  goOutside(world, client, "Silverpine Forest")
  world:run(60)
  goInside(world, client, 33, "Shadowfang Keep")
  H.ok(ns.Log.OpenSession() ~= second, "a finished run stays finished")
  H.eq(ns.Log.OpenSession().bosses, 0)
  H.eq(#client.errors, 0)
end)

H.test("while the client hides which instance this is, the last answer stands", function()
  local world, client, env, ns = setup()
  client:fire("GROUP_ROSTER_UPDATE")
  world:run(2)
  goInside(world, client, 33, "Shadowfang Keep")
  local run = ns.Log.OpenSession()
  H.eq(run.inst, 33)
  client.hideInstance = true
  world:run(60)
  H.eq(ns.Activity.Kind(), ns.Pieces.ACT.dungeon)
  H.ok(ns.Log.OpenSession() == run, "the same session goes on")
  H.eq(#ns.Log.Mine().groups, 2, "outside before, and the run")
  local trace = env.PintoTGD_DB.trace
  H.ok(trace.inside[#trace.inside].place:find("Instance|hidden|", 1, true), "the trace says what was hidden")
  H.eq(#client.errors, 0)
end)

H.test("the trace: what the game says inside an instance, each picture once per visit", function()
  local world, client, env, ns = setup()
  ns.Trace.Init()
  client.zone = "Silverpine Forest"
  client:fire("GROUP_ROSTER_UPDATE")
  world:run(60)
  H.eq(env.PintoTGD_DB.trace, nil, "nothing to note in the open world while the maps say who's where")
  goInside(world, client, 33, "Shadowfang Keep")
  world:run(120)
  local trace = env.PintoTGD_DB.trace
  H.eq(#trace.inside, 1, "one picture, however many looks")
  local s = trace.inside[1]
  H.ok(s.n >= 8, "seen at every look")
  H.eq(s.me, full("Kiri"))
  for _, part in ipairs({ "|party|", "|33|map=none|", "zone=Shadowfang Keep" }) do
    H.ok(s.place:find(part, 1, true), "the place should say " .. part .. ": " .. s.place)
  end
  H.eq(s.units[1], "party1 " .. full("Thorn") .. ": online=yes map=none sight=yes range=? roster=none -> with me by sight, nearby")
  H.eq(s.combat, "no")
  H.ok(s.place:find("|guild=2", 1, true), "the size of the roster Pinto has: " .. s.place)
  -- someone from outside the guild joins: counted, and known by the shape of their name
  client.group[2], client.unitMap.party2 = full("Zed"), full("Zed")
  world:run(15)
  H.eq(#trace.inside, 2)
  H.eq(trace.inside[2].others, "1")
  H.eq(trace.inside[2].units[2], "party2: not a guildie, name like " .. (full("Zed"):gsub("%u", "A"):gsub("%l", "a")))
  H.ok(not trace.inside[2].units[2]:find("Zed", 1, true), "never the name itself")
  client.group[2], client.unitMap.party2 = nil, nil
  world:run(15)
  -- another picture: Thorn out of sight, counted as before
  client.unseen[full("Thorn")] = true
  world:run(30)
  H.eq(#trace.inside, 3)
  H.ok(trace.inside[3].units[1]:find("sight=no range=? roster=none -> unclear by none, nearby", 1, true), trace.inside[3].units[1])
  -- back in sight: the first picture again, not a fourth
  client.unseen[full("Thorn")] = nil
  world:run(30)
  H.eq(#trace.inside, 3)
  H.ok(trace.inside[1].last > trace.inside[3].last, "the first picture was seen again")
  -- a boss: where the game says the fight was
  client:fire("ENCOUNTER_START", 2748, "Rethilgore", 1, 5)
  client:fire("ENCOUNTER_END", 2748, "Rethilgore", 1, 5, 1)
  client:fire("ENCOUNTER_END", 2749, "Razorclaw the Butcher", 1, 5, 0)
  client:fire("ENCOUNTER_END", wow.secret(), wow.secret(), 1, 5, wow.secret())
  local boss = trace.bosses["2748"]
  H.eq(boss.name, "Rethilgore")
  H.eq(boss.kills, 1)
  H.eq(boss.kind, "party")
  H.eq(boss.inst, 33)
  H.eq(boss.zone, "Shadowfang Keep")
  H.eq(trace.bosses["2749"].wipes, 1)
  H.eq(trace.bosses["?"].unclear, 1, "a boss the game won't name, and an end it won't call")
  -- outside again: only the pictures the maps don't settle
  goOutside(world, client, "Silverpine Forest")
  world:run(30)
  H.eq(#trace.outside, 0)
  client.hideMaps = true
  world:run(20)
  H.eq(#trace.outside, 1)
  H.ok(trace.outside[1].place:find("map=hidden", 1, true), trace.outside[1].place)
  -- back inside: a new visit, so its first picture is noted afresh
  client.hideMaps = false
  goInside(world, client, 33, "Shadowfang Keep")
  world:run(20)
  H.eq(#trace.inside, 4)
  H.eq(trace.inside[4].units[1], trace.inside[1].units[1])
  H.eq(#client.errors, 0)
end)

H.test("a fault in the trace is reported and doesn't stop the tracking", function()
  local world, client, env, ns = setup()
  local reported
  env.geterrorhandler = function() return function(err) reported = err end end
  ns.Trace.Note = function() error("a fault in the trace") end
  client:fire("GROUP_ROSTER_UPDATE")
  world:run(20)
  H.ok(ns.Log.OpenSession(), "the group session is logged all the same")
  H.ok(tostring(reported):find("a fault in the trace", 1, true), "the fault is reported")
end)

H.test("the trace keeps its newest samples, and no more than its share", function()
  local world, client, env, ns = setup()
  client:fire("GROUP_ROSTER_UPDATE")
  world:run(2)
  -- every look a new picture: Thorn's map changes each time, inside an instance
  client.instance = { kind = "party", id = 33 }
  for i = 1, 230 do
    client.maps[full("Thorn")] = 5000 + i
    ns.Activity.Present()
    ns.Trace.Note("test")
  end
  local inside = env.PintoTGD_DB.trace.inside
  H.eq(#inside, 200)
  H.ok(inside[200].units[1]:find("map=5230", 1, true), "the newest is kept")
  H.ok(inside[1].units[1]:find("map=5031", 1, true), "the oldest are dropped")
  H.eq(#client.errors, 0)
end)

H.test("the trace counts the game's answers about everyone in the group, guildie or not, without names", function()
  local world, client, env, ns = setup()
  ns.Trace.Init()
  world:addMember(full("Kiri"))
  world:addMember(full("Thorn"))
  -- Thorn is a guildie. Zed has no guild, and Moss is in another one.
  client.group = { full("Thorn"), full("Zed"), full("Moss") }
  client.unitMap = { party1 = full("Thorn"), party2 = full("Zed"), party3 = full("Moss") }
  client.guildOf[full("Moss")] = "Another Guild"
  client.inRange[full("Zed")] = true
  client.unseen[full("Moss")] = true
  client.zone = "Silverpine Forest"
  client:fire("GROUP_ROSTER_UPDATE")
  world:run(60)
  H.eq(env.PintoTGD_DB.trace, nil, "nothing to count in the open world while the maps say who's where")
  goInside(world, client, 33, "Shadowfang Keep")
  world:run(60)
  local signals = env.PintoTGD_DB.trace.signals
  H.eq(#signals, 1, "one visit")
  local v = signals[1]
  H.eq(v.place, "party:33")
  H.eq(v.me, full("Kiri"))
  local calm = "combat=no boss=no"
  for _, line in ipairs({
    "guildie | " .. calm .. " | online=yes map=none sight=yes range=? roster=none guild=yes/same",
    "other | " .. calm .. " | online=yes map=none sight=yes range=yes roster=none guild=no/none",
    "other | " .. calm .. " | online=yes map=none sight=no range=? roster=none guild=no/other",
  }) do
    H.ok((v.counts[line] or 0) >= 4, "counted at every look: " .. line .. "\n" .. dump(v.counts))
  end
  H.eq(size(v.counts), 3, dump(v.counts))
  H.eq(v.lines, 3)
  for line in pairs(v.counts) do
    for _, n in ipairs({ "Thorn", "Zed", "Moss", "Kiri" }) do
      H.ok(not line:find(n, 1, true), "never a name: " .. line)
    end
  end
  -- Moss is still outside: the client has a map for Moss, and none for Kiri in here
  client.maps[full("Moss")] = 1421
  world:run(15)
  H.ok(v.counts["other | " .. calm .. " | online=yes map=known sight=no range=? roster=none guild=no/other"], dump(v.counts))
  client.maps[full("Moss")] = nil
  -- the roster's zone for a guildie, against the player's own
  rosterZone(ns, "Shadowfang Keep", { "Thorn" })
  world:run(15)
  H.ok(v.counts["guildie | " .. calm .. " | online=yes map=none sight=yes range=? roster=same guild=yes/same"], dump(v.counts))
  rosterZone(ns, "Silverpine Forest", { "Thorn" })
  world:run(15)
  H.ok(v.counts["guildie | " .. calm .. " | online=yes map=none sight=yes range=? roster=other guild=yes/same"], dump(v.counts))
  -- in a fight, with the game hiding maps, sight and guilds: lines of their own
  client.combat, client.hideMaps, client.hideSight, client.hideGuild = true, true, true, true
  world:run(15)
  local fight = "combat=yes boss=no"
  H.ok(v.counts["guildie | " .. fight .. " | online=yes map=hidden sight=? range=? roster=other guild=?/?"], dump(v.counts))
  H.ok(v.counts["other | " .. fight .. " | online=yes map=hidden sight=? range=yes roster=none guild=?/?"], dump(v.counts))
  H.ok(v.counts["other | " .. fight .. " | online=yes map=hidden sight=? range=? roster=none guild=?/?"], dump(v.counts))
  client.combat, client.hideMaps, client.hideSight, client.hideGuild = false, false, false, false
  -- another place is another visit, counted afresh
  goOutside(world, client, "Silverpine Forest")
  world:run(20)
  goInside(world, client, 36, "The Deadmines")
  world:run(20)
  H.eq(#signals, 2)
  H.eq(signals[2].place, "party:36")
  H.ok(signals[2].last >= signals[2].t and signals[2].t > v.t, "each visit keeps when it began and was last seen")
  H.eq(#client.errors, 0)
end)

H.test("the trace counts answers in a group without guildies too, and no more than its share", function()
  local world, client, env, ns = setup()
  world:addMember(full("Kiri"))
  -- a group of one stranger, inside an instance: every look gives another answer
  client.group, client.unitMap = { full("Zed") }, { party1 = full("Zed") }
  client.instance = { kind = "party", id = 33 }
  local seen = 0
  for _, combat in ipairs({ false, true }) do
    for _, offline in ipairs({ false, true }) do
      for _, map in ipairs({ "same", "other", "none" }) do
        for _, unseen in ipairs({ false, true }) do
          for _, inRange in ipairs({ false, true }) do
            for _, guild in ipairs({ "none", "other", "same", "hidden" }) do
              client.combat = combat
              client.offline[full("Zed")] = offline or nil
              -- false: the client has no map for Zed; nil: Zed is on Kiri's map
              local zedsMap = nil
              if map == "other" then zedsMap = 1411 elseif map == "none" then zedsMap = false end
              client.maps[full("Zed")] = zedsMap
              client.unseen[full("Zed")] = unseen or nil
              client.inRange[full("Zed")] = inRange or nil
              client.hideGuild = guild == "hidden"
              client.guildOf[full("Zed")] = (guild == "other" and "Another Guild") or (guild == "same" and world.guild) or false
              ns.Activity.Present()
              ns.Trace.Note("test")
              seen = seen + 1
            end
          end
        end
      end
    end
  end
  H.eq(seen, 192)
  local v = env.PintoTGD_DB.trace.signals[1]
  H.eq(#env.PintoTGD_DB.trace.signals, 1)
  H.eq(size(v.counts), 100, "100 distinct answers at most")
  H.eq(v.lines, 100)
  H.eq(v.more, 92, "the rest are only counted")
  H.ok(v.counts["other | combat=no boss=no | online=yes map=same sight=yes range=? roster=none guild=no/none"], dump(v.counts))
  H.ok(v.counts["other | combat=no boss=no | online=no map=other sight=no range=yes roster=none guild=yes/same"], dump(v.counts))
  -- an answer already listed is still counted
  client.combat, client.hideGuild = false, false
  client.offline[full("Zed")], client.maps[full("Zed")], client.unseen[full("Zed")], client.inRange[full("Zed")] = nil, nil, nil, nil
  client.guildOf[full("Zed")] = false
  ns.Activity.Present()
  ns.Trace.Note("test")
  H.eq(v.counts["other | combat=no boss=no | online=yes map=same sight=yes range=? roster=none guild=no/none"], 2)
  H.eq(v.more, 92)
  -- 35 visits to 35 places: the newest 20 are kept
  for i = 1, 35 do
    client.instance = { kind = "party", id = 100 + i }
    ns.Activity.Present()
    ns.Trace.Note("test")
  end
  local signals = env.PintoTGD_DB.trace.signals
  H.eq(#signals, 20)
  H.eq(signals[20].place, "party:135")
  H.eq(signals[1].place, "party:116")
  H.eq(#client.errors, 0)
end)

H.test("the game's own word on a group member's guild: plain, hidden or missing", function()
  local world, client, env, ns = setup()
  world:addMember(full("Kiri"))
  world:addMember(full("Thorn"))
  local function guild() return { ns.Compat.UnitGuild("party1") } end
  H.deepEq(guild(), { true, "same" })
  client.guildOf[full("Thorn")] = "Another Guild"
  H.deepEq(guild(), { false, "other" })
  client.guildOf[full("Thorn")] = false
  H.deepEq(guild(), { false, "none" })
  client.guildOf[full("Thorn")] = nil
  client.hideGuild = true
  H.deepEq(guild(), {}, "hidden: no answer")
  client.hideGuild = false
  -- a client without UnitIsInMyGuild still has the guild's name to go by
  env.UnitIsInMyGuild = nil
  H.deepEq(guild(), { nil, "same" })
  H.eq(#client.errors, 0)
end)

H.test("/pinto nearby points out a group member the game puts in the guild but the roster doesn't list", function()
  local world, client, env, ns = setup()
  local short = ns.Compat.ShortName
  world:addMember(full("Kiri"))
  world:addMember(full("Zed"))   -- in the guild by the game; the roster Pinto has doesn't list Zed
  client.group, client.unitMap = { full("Zed"), full("Moss") }, { party1 = full("Zed"), party2 = full("Moss") }
  local lines = ns.Activity.Describe()
  H.eq(lines[2], short(full("Zed")) .. ": in your guild by the game, but not in the guild roster Pinto has.")
  H.eq(#lines, 2, "nothing about Moss, who isn't in the guild")
  H.eq(size(ns.Activity.Present()), 0, "and Zed doesn't count as a guildie nearby: the roster decides")
  -- by the game's yes alone, while Zed is too far away for the client to know the guild's name
  local guildInfo = env.GetGuildInfo
  env.GetGuildInfo = function(unit) if unit == "player" then return guildInfo(unit) end return nil end
  H.eq(ns.Activity.Describe()[2], short(full("Zed")) .. ": in your guild by the game, but not in the guild roster Pinto has.")
  env.GetGuildInfo = guildInfo
  -- by the guild's name alone, on a client without UnitIsInMyGuild
  env.UnitIsInMyGuild = nil
  H.eq(ns.Activity.Describe()[2], short(full("Zed")) .. ": in your guild by the game, but not in the guild roster Pinto has.")
  -- nobody like that: it says so, also while the game hides the answer
  client.guildOf[full("Zed")] = false
  H.eq(ns.Activity.Describe()[2], "No guildies in your group.")
  client.guildOf[full("Zed")] = nil
  client.hideGuild = true
  H.eq(ns.Activity.Describe()[2], "No guildies in your group.")
  H.eq(#client.errors, 0)
end)

H.test("a guild roster the client hides part of leaves the roster Pinto has as it was", function()
  local world, client, _, ns = setup()
  for _, n in ipairs({ "Kiri", "Thorn", "Bram" }) do world:addMember(full(n)) end
  H.eq(ns.Roster.Scan(), true)
  H.eq(size(ns.Roster.members), 3)
  -- Bram leaves the guild while the client hides the roster's names: a scan that can't be
  -- read in full changes nothing, rather than leaving members out
  world:removeMember(full("Bram"))
  client.hideRoster = true
  H.eq(ns.Roster.Scan(), false)
  H.eq(size(ns.Roster.members), 3, "the last roster stands")
  H.ok(ns.Roster.Get(full("Thorn")), "Thorn is still known as a guildie")
  client.hideRoster = false
  H.eq(ns.Roster.Scan(), true)
  H.eq(size(ns.Roster.members), 2)
  H.eq(#client.errors, 0)
end)

H.test("/pinto nearby says who counts as nearby, and what the game said", function()
  local _, client, _, ns = setup()
  local short = ns.Compat.ShortName
  party(client, ns, { "Thorn", "Bram" })
  client.instance, client.noMaps, client.zone = { kind = "party", id = 33 }, true, "Shadowfang Keep"
  rosterZone(ns, "Silverpine Forest", { "Bram" })
  client.unseen[full("Bram")] = true
  local lines = ns.Activity.Describe()
  H.eq(lines[1], "You're in Shadowfang Keep, a dungeon.")
  H.eq(lines[2], short(full("Thorn")) .. ": nearby (in sight)")
  H.eq(lines[3], short(full("Bram")) .. ": not nearby (the guild roster says Silverpine Forest)")
  H.eq(#lines, 3)
  -- out of sight with nothing else to go by: counted as before
  client.unseen[full("Thorn")] = true
  H.eq(ns.Activity.Describe()[2], short(full("Thorn")) .. ": nearby (the game doesn't say where they are; counted as before)")
  client.group, client.unitMap = {}, {}
  H.eq(ns.Activity.Describe()[1], "You're not in a group.")
  H.eq(#client.errors, 0)
end)

H.test("an invite: someone new this character invited joins, from the game's own messages", function()
  local world, client, env, ns = setup()
  env.ERR_GUILD_INVITE_S = "You have invited %s to join your guild."
  env.ERR_GUILD_JOIN_S = "%s has joined the guild."
  ns.Guild.Init()
  local function system(text) client:fire("CHAT_MSG_SYSTEM", text) end
  -- invited by first name; the guild hears the whole name
  system("You have invited Nissin to join your guild.")
  system(full("Nissin") .. " has joined the guild.")
  H.eq(#moments(ns, "invite"), 1)
  -- someone else's invite joining: nothing
  system(full("Gimble") .. " has joined the guild.")
  H.eq(#moments(ns, "invite"), 1)
  -- a member who was in the guild before isn't someone new
  local today = ns.Time.day()
  ns.Store.NoteJoins({ { name = full("Wren"), day = today - 40 } }, today - 40)
  system("You have invited Wren to join your guild.")
  system(full("Wren") .. " has joined the guild.")
  H.eq(#moments(ns, "invite"), 1)
  -- an invite more than a day old has lapsed
  system("You have invited Pip to join your guild.")
  world.time = world.time + 86401
  system(full("Pip") .. " has joined the guild.")
  H.eq(#moments(ns, "invite"), 1)
  H.eq(#client.errors, 0)
end)

H.test("the guild bank: opening it is remembered, and something crafted put in it is noted", function()
  local world, client, env, ns = setup()
  ns.Guild.Init()
  local counts = { [4245] = 3, [2589] = 20 }
  env.GetItemCount = function(id) return counts[id] or 0 end
  env.PintoTGD_DB.crafted = { [4245] = { prof = "Tailoring", at = 0 } }
  H.eq(env.PintoTGD_DB.bankSeen, nil)
  client:fire("PLAYER_INTERACTION_MANAGER_FRAME_SHOW", 10)
  H.eq(env.PintoTGD_DB.bankSeen, true, "the player has used the guild bank")
  -- one crafted bag goes in: the bags lose it as the bank changes
  counts[4245] = 2
  client:fire("GUILDBANKBAGSLOTS_CHANGED")
  client:fire("BAG_UPDATE_DELAYED")
  world:run(1)
  local deposits = moments(ns, "deposit")
  H.eq(#deposits, 1)
  H.eq(deposits[1].count, 1)
  -- one used up while the bank doesn't change, and cloth that wasn't crafted: nothing
  counts[4245], counts[2589] = 1, 10
  client:fire("BAG_UPDATE_DELAYED")
  world:run(1)
  H.eq(#moments(ns, "deposit"), 1)
  -- the bank closed: nothing
  client:fire("PLAYER_INTERACTION_MANAGER_FRAME_HIDE", 10)
  counts[4245] = 0
  client:fire("GUILDBANKBAGSLOTS_CHANGED")
  client:fire("BAG_UPDATE_DELAYED")
  world:run(1)
  H.eq(#moments(ns, "deposit"), 1)
  -- an older client says the guild bank opened instead
  counts[4245] = 2
  client:fire("GUILDBANKFRAME_OPENED")
  counts[4245] = 0
  client:fire("GUILDBANKBAGSLOTS_CHANGED")
  world:run(1)
  H.eq(moments(ns, "deposit")[2].count, 2)
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

H.test("food isn't gear, on a client that gives every item an equip location", function()
  local _, _, _, ns = setup()
  local _, _, food = ns.Trades.Classify("item:1082 class:0:5 equip:INVTYPE_NON_EQUIP_IGNORE", false)
  H.ok(food.food, "food should be tagged as food")
  H.eq(food.gear, nil, "food isn't gear")
  local _, _, boots = ns.Trades.Classify("item:2000 class:4:2 equip:INVTYPE_FEET ilvl:20", false)
  H.ok(boots.gear, "boots are gear")
  H.eq(boots.equipLoc, "INVTYPE_FEET")
  H.eq(boots.ilvl, 20)
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
