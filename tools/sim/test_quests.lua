-- Quest packs, rolling, completion and rerolls.
local H = require("harness")
local wow = require("wow")

local world = wow.world({ seed = 17 })
local client = world:client(wow.full("Kiri"))
client.online = true
local env = client:makeEnv()
env.PintoTGD_DB = {}
local files = {}
for _, f in ipairs(H.tocFiles()) do
  if f ~= "Main.lua" then files[#files + 1] = f end
end
local ns = H.load(files, {}, env)
local Store, Pieces, Time, Util, Quests, Pack, Blocks, Roster, Log =
  ns.Store, ns.Pieces, ns.Time, ns.Util, ns.Quests, ns.Pack, ns.Blocks, ns.Roster, ns.Log
ns.People.Init()
ns.Formula.Init()
Pack.Init()

local GO = Time.dayOfDate(ns.Build.goLive)
local full = wow.full
ns.me = full("Kiri")
-- the test tools are tested whatever this build has: a beta build has none
ns.Build.testTools = true

local NAMES = { "Kiri", "Thorn", "Bram", "Ash", "Wren", "Moss", "Fern", "Rook", "Nox", "Pip" }
local function setup(today)
  world.time = Time.dayStart(today) + 7200
  Store.pieces = {}
  Roster.members = {}
  for i, n in ipairs(NAMES) do
    Roster.members[full(n)] = { name = full(n), rankIndex = i == 1 and 0 or 2, level = 30 + i, online = true, note = "" }
  end
  Roster.loaded = true
  ns.Events.Fire("PINTO_ROSTER")
  Store.NoteJoins((function()
    local list = {}
    for _, n in ipairs(NAMES) do list[#list + 1] = { name = full(n), day = GO, how = Pieces.JOIN.founding } end
    return list
  end)(), today)
  env.PintoTGD_DB.chars = { [full("Kiri")] = { level = 35, slots = {}, prof = { { id = 9, skill = 120 } },
    cook = 50, aid = 0, fish = 0, guild = Store.slotKey() } }
  env.PintoTGD_DB.log = {}
  env.PintoTGD_DB.eaten = {}
  ns.Release.LoadEmbedded()
  ns.Events.Fire("PINTO_DATA_CHANGED", nil, "test")
end
env.UnitLevel = function() return 35 end

H.test("the embedded quest pack decodes and this version supports every template", function()
  setup(GO + 2)
  local pack = Pack.Get(Pack.Newest())
  H.ok(pack, "no pack")
  H.eq(#pack.ids, 36)
  for _, id in ipairs(pack.ids) do
    H.ok(pack.templates[id].supported, "template " .. id .. " uses an unknown block")
  end
  H.ok(pack.finalBosses["Edwin VanCleef"])
  H.ok(pack.finalBosses[2755], "Archmage Arugal, by encounter id")
  H.ok(Blocks.IsFinalBoss(2755, "Erzmagier Arugal"), "by id, whatever the client's language calls him")
  H.ok(Blocks.IsFinalBoss(2747, "Edwin VanCleef"), "by English name where the id isn't known")
  H.eq(Blocks.IsFinalBoss(2753, "Fenrus the Devourer"), false)
end)

H.test("during calibration every quest comes from the calibration set", function()
  setup(GO + 2)
  Quests.Ensure()
  local wp = Quests.Piece()
  local set = wp and wp.sets[Util.nameId(ns.me)]
  H.ok(set, "no quest set was rolled")
  H.eq(#set.quests, 5)
  local pack = Pack.Get(set.pack)
  local seen = {}
  for _, q in ipairs(set.quests) do
    H.eq(pack.templates[q.t].set, "calibration")
    H.ok(not seen[q.t], "the same template twice")
    seen[q.t] = true
  end
end)

H.test("after calibration: 3 from set 1, 1 from set 2, and a set 1 spare", function()
  local today = GO + 14
  setup(today)
  for d = GO, today do
    Store.SetHistory(d, { H = 5000, W = 3000, Q = 0, G = 0, P = 0, T = 0, K = 0, N = 8, fv = 1, data = 5 })
  end
  Quests.Ensure()
  local wp = Quests.Piece()
  local set = wp.sets[Util.nameId(ns.me)]
  local pack = Pack.Get(set.pack)
  local sets = {}
  for i, q in ipairs(set.quests) do sets[i] = pack.templates[q.t].set end
  H.eq(sets[1], 1); H.eq(sets[2], 1); H.eq(sets[3], 1); H.eq(sets[4], 2); H.eq(sets[5], 1)
  -- nobody is named twice, and never this player
  local named = {}
  for _, q in ipairs(set.quests) do
    for _, id in ipairs(q.named) do
      H.ok(id ~= Util.nameId(ns.me), "named themselves")
      H.ok(not named[id], "named the same guildie twice")
      named[id] = true
    end
  end
  -- text has names filled in
  for _, mine in ipairs(Quests.Mine()) do
    H.ok(not mine.text:find("{", 1, true), mine.text)
  end
end)

H.test("a dungeon run with 2 guildies completes the quest, once", function()
  local today = GO + 2
  setup(today)
  -- a set with "Run a dungeon with at least 2 guildies." (id 8) in slot 1
  Store.SetQuestSet(Time.week(today), ns.me, { created = 1, author = 1, pack = Pack.Newest(),
    quests = { { t = 8, worth = 2, named = {} }, { t = 1, worth = 1, named = {} }, { t = 7, worth = 2, named = {} },
      { t = 11, worth = 3, named = {} }, { t = 10, worth = 3, named = {} } } })
  local s = Log.Session(Pieces.ACT.dungeon, 36)
  s.members = { [full("Thorn")] = true, [full("Bram")] = true }
  s.final = true
  s.finalMembers = { [full("Thorn")] = true, [full("Bram")] = true }
  s.bosses = 6
  Quests.Check()
  local wp = Quests.Piece()
  local rec = wp.done[Pieces.doneKey(Util.nameId(ns.me), 1)]
  H.ok(rec, "the dungeon quest didn't complete")
  H.eq(#rec.members, 2)
  H.eq(rec.inst, 36)
  H.eq(wp.done[Pieces.doneKey(Util.nameId(ns.me), 2)], nil, "the turn-in quest completed without turn-ins")
  -- feeding counts it; the eating queue has it
  local uneaten = Quests.Uneaten()
  H.eq(#uneaten, 1)
  H.eq(uneaten[1].worth, 2)
  Quests.MarkEaten(uneaten[1])
  H.eq(#Quests.Uneaten(), 0)
end)

H.test("a dungeon without the final boss and with one guildie doesn't count", function()
  local today = GO + 2
  setup(today)
  Store.SetQuestSet(Time.week(today), ns.me, { created = 1, author = 1, pack = Pack.Newest(),
    quests = { { t = 8, worth = 2, named = {} }, { t = 1, worth = 1, named = {} }, { t = 7, worth = 2, named = {} },
      { t = 11, worth = 3, named = {} }, { t = 10, worth = 3, named = {} } } })
  local s = Log.Session(Pieces.ACT.dungeon, 36)
  s.members = { [full("Thorn")] = true }
  s.bosses = 1
  Quests.Check()
  H.eq(Quests.Piece().done[Pieces.doneKey(Util.nameId(ns.me), 1)], nil)
  H.eq(Quests.progress[1][1].have, 0)
end)

-- Quill joined the guild 3 days ago; everyone else founded it.
local function addNewMember(today)
  Roster.members[full("Quill")] = { name = full("Quill"), rankIndex = 4, level = 20, online = true, note = "" }
  Store.NoteJoins({ { name = full("Quill"), day = today - 3, how = Pieces.JOIN.message } }, today)
  ns.Events.Fire("PINTO_DATA_CHANGED", nil, "test")
end

H.test("a new guild member in the group earns an unnamed quest one surprise haunch", function()
  local today = GO + 9
  setup(today)
  addNewMember(today)
  local week = Time.week(today)
  local me = Util.nameId(ns.me)
  local thorn, quill, bram = Util.nameId(full("Thorn")), Util.nameId(full("Quill")), Util.nameId(full("Bram"))
  -- 1: party up for quests (names nobody), 2: a quest with Thorn (named), 3: a quest with
  -- a new member (asks for one already), 4: fish with a guildie (names nobody)
  Store.SetQuestSet(week, ns.me, { created = 1, author = 1, pack = Pack.Newest(),
    quests = { { t = 1, worth = 1, named = {} }, { t = 5, worth = 2, named = { thorn } }, { t = 9, worth = 2, named = {} },
      { t = 3, worth = 1, named = {} }, { t = 10, worth = 3, named = {} } } })
  local now = Time.now()
  for slot, members in ipairs({ { bram, quill }, { thorn, quill }, { quill }, { bram } }) do
    Store.AddCompletion(week, { char = me, slot = slot, time = now, members = members, inst = 0, bosses = 0 }, 1)
  end
  local wp = Quests.Piece(week)
  local function rec(slot) return wp.done[Pieces.doneKey(me, slot)] end
  H.eq(Quests.BonusOf(wp, rec(1)), 1, "a quest that names nobody, with a new member along")
  H.eq(Quests.BonusOf(wp, rec(2)), 0, "a quest that names a guildie already gets its extra haunch")
  H.eq(Quests.BonusOf(wp, rec(3)), 0, "a quest that asks for a new member already counts them")
  H.eq(Quests.BonusOf(wp, rec(4)), 0, "nobody new in the group")
  H.eq(Quests.EarnedOf(wp, rec(1)), 2)
  H.eq(Quests.GuildHaunches(), 2 + 2 + 2 + 1)
  local bonus = {}
  for _, e in ipairs(Quests.Uneaten()) do bonus[e.slot] = e.bonus end
  H.eq(bonus[1], 1)
  H.eq(bonus[2], 0)
  -- a member stops being new after 30 days
  H.eq(Quests.BonusOf(wp, { char = me, slot = 1, time = Time.dayStart(today + 30), members = { quill } }), 0)
end)

H.test("turn-ins: a group quest needs the game's mark, and the reworked one 2 guildies", function()
  local G = ns.Blocks.goals
  local one = { [full("Thorn")] = true }
  local two = { [full("Thorn")] = true, [full("Bram")] = true }
  local ctx = { log = { turnins = { { quest = 1, group = true, guildies = one }, { quest = 2, group = false, guildies = two } } } }
  H.eq((G.turnins(ctx, { count = 1, group = true })), true)
  H.eq((G.turnins(ctx, { count = 1, group = true, guildies = 2 })), false)
  ctx.log.turnins[3] = { quest = 3, group = true, guildies = two }
  local done, _, _, ev = G.turnins(ctx, { count = 1, group = true, guildies = 2 })
  H.ok(done)
  H.ok(ev and ev.members[full("Bram")], "the guildies who took part are the evidence")
end)

H.test("a build's wake-up day moves the end of the calibration", function()
  local saved = ns.Build.wakeUp
  ns.Build.wakeUp = nil
  setup(GO + 8)
  H.eq(ns.Health.WakeDay(), GO + 7)
  local _, _, before = ns.Health.Shape(GO + 8)
  H.eq(before, "long", "7 days after go-live, with too few players")
  ns.Build.wakeUp = Time.dateOfDay(GO + 10)
  H.eq(ns.Health.WakeDay(), GO + 10)
  H.eq(ns.Health.CalibrationWeekEnd(), Time.dayStart(GO + 10))
  local _, _, state = ns.Health.Shape(GO + 8)
  H.eq(state, "calibration", "still the calibration week until the wake-up day")
  ns.Build.wakeUp = saved
end)

H.test("crafting quests: 3 crafted gifts, then a group with each", function()
  local today = GO + 2
  setup(today)
  Store.SetQuestSet(Time.week(today), ns.me, { created = 1, author = 1, pack = Pack.Newest(),
    quests = { { t = 211, worth = 3, named = {} }, { t = 1, worth = 1, named = {} }, { t = 7, worth = 2, named = {} },
      { t = 11, worth = 3, named = {} }, { t = 10, worth = 3, named = {} } } })
  for _, n in ipairs({ "Thorn", "Bram", "Ash" }) do
    Log.AddTrade("out", full(n), Pieces.TRADE.crafted, 2580, 1, {})
  end
  Quests.Check()
  H.eq(Quests.Piece().done[Pieces.doneKey(Util.nameId(ns.me), 1)], nil, "done before grouping")
  H.eq(Quests.progress[1][1].have, 3)
  for _, n in ipairs({ "Thorn", "Bram", "Ash" }) do
    local s = Log.Session(Pieces.ACT.quest, 0)
    s.members = { [full(n)] = true }
    Log.CloseSession()
  end
  Quests.Check()
  H.ok(Quests.Piece().done[Pieces.doneKey(Util.nameId(ns.me), 1)], "not done after grouping with all 3")
end)

H.test("the reroll swaps one quest for the spare, once a week", function()
  local today = GO + 2
  setup(today)
  Quests.Ensure()
  local wp = Quests.Piece()
  local set = wp.sets[Util.nameId(ns.me)]
  H.ok(Quests.CanReroll())
  H.ok(Quests.Reroll(3))
  H.eq(Quests.Effective(wp, Util.nameId(ns.me), 3), set.quests[5])
  H.ok(not Quests.CanReroll())
  H.eq(Quests.Reroll(2), false)
end)

H.test("test builds: quests rolled from an older pack follow the newest, and the reroll comes back", function()
  setup(GO + 2)
  local week = Quests.Week()
  local me = Util.nameId(ns.me)
  local newest = Pack.Newest()
  local pack = Pack.Get(newest)
  local old = {}
  for i = 1, 5 do old[i] = { t = pack.ids[i], worth = 9, named = {} } end
  -- this account's quests from the older pack, rerolled once, one of them finished
  Store.SetQuestSet(week, ns.me, { created = 5000, author = ns.Player.AccountId(), pack = newest - 1, quests = old })
  Store.SetReroll(week, ns.me, 2, 6000)
  Store.AddCompletion(week, { char = me, slot = 1, time = 6100, members = {}, inst = 0, bosses = 0 }, 1)
  -- another account's quests stay as they are
  local thorn = Util.nameId(full("Thorn"))
  Store.SetQuestSet(week, full("Thorn"), { created = 5000, author = 77, pack = newest - 1, quests = Util.copy(old) })
  Store.SetReroll(week, full("Thorn"), 4, 6000)
  H.ok(not Quests.CanReroll())
  ns.Build.test = false
  H.eq(Quests.UpgradeToNewestPack(week), false, "release builds never change rolled quests")
  ns.Build.test = true
  H.ok(Quests.UpgradeToNewestPack(week))
  local wp = Quests.Piece(week)
  local set = wp.sets[me]
  H.eq(set.pack, newest)
  H.eq(set.created, 4999, "a second earlier, so the merge keeps it everywhere")
  for i = 1, 5 do
    H.eq(set.quests[i].t, pack.ids[i])
    H.eq(set.quests[i].worth, pack.templates[pack.ids[i]].worth)
  end
  H.ok(Quests.CanReroll(), "the reroll should be back")
  H.eq(Quests.Effective(wp, me, 2), set.quests[2])
  H.ok(wp.done[Pieces.doneKey(me, 1)], "a finished quest stays finished")
  H.eq(wp.sets[thorn].pack, newest - 1)
  H.ok(wp.rerolls[thorn], "another account's reroll stays")
  H.eq(Quests.UpgradeToNewestPack(week), false, "nothing left to upgrade")
  -- the upgraded set wins the merge against the one it replaced
  local id = Pieces.id("w", week)
  local delta = Pieces.new(id)
  delta.sets[me] = { created = 5000, author = ns.Player.AccountId(), pack = newest - 1, quests = Util.copy(old) }
  Store.merge(id, delta, "remote")
  H.eq(Quests.Piece(week).sets[me].pack, newest)
end)

H.test("test tools: the weekly reroll can be given back", function()
  setup(GO + 2)
  Quests.Ensure()
  local wp = Quests.Piece()
  local me = Util.nameId(ns.me)
  local set = wp.sets[me]
  H.eq(Quests.TestGiveRerollBack(), false, "no reroll used yet")
  H.ok(Quests.Reroll(3))
  ns.Build.testTools = false
  H.eq(Quests.TestGiveRerollBack(), false, "beta and release builds never give it back")
  ns.Build.testTools = true
  H.ok(Quests.TestGiveRerollBack())
  H.ok(Quests.CanReroll())
  H.eq(Quests.Effective(wp, me, 3), set.quests[3], "the quest it swapped away is back")
  H.ok(Quests.Reroll(1), "and the reroll can be used again")
end)

-- How many of a set's 4 quests name a guildie, and whether its spare does.
local function namedIn(set)
  local n = 0
  for s = 1, 4 do
    if #set.quests[s].named > 0 then n = n + 1 end
  end
  return n, #set.quests[5].named > 0
end

H.test("1 or 2 of the 4 quests name a guildie, and the spare keeps a reroll at 1 or 2", function()
  for _, today in ipairs({ GO + 2, GO + 14 }) do
    setup(today)
    for d = GO, today do
      if today > GO + 7 then
        Store.SetHistory(d, { H = 5000, W = 3000, Q = 0, G = 0, P = 0, T = 0, K = 0, N = 8, fv = 1, data = 5 })
      end
    end
    local week = Time.week(today)
    local seen = {}
    for _ = 1, 40 do
      local set = Quests.Roll(week)
      H.ok(set, "no set rolled")
      local n, spare = namedIn(set)
      H.ok(n == 1 or n == 2, string.format("%d of the 4 quests name a guildie", n))
      H.eq(spare, n == 1, "the spare names a guildie only when just one of the 4 does")
      seen[n] = true
    end
    H.ok(seen[1] and seen[2], "sometimes 1, sometimes 2")
  end
end)

H.test("test tools: a character's quests for the week can be rolled again", function()
  setup(GO + 2)
  Quests.Ensure()
  local week = Quests.Week()
  local me = Util.nameId(ns.me)
  local old = Quests.Piece(week).sets[me]
  H.ok(Quests.Reroll(2))
  local ok = Quests.TestRefresh()
  H.ok(ok, "the quests should be rolled again")
  local wp = Quests.Piece(week)
  local set = wp.sets[me]
  H.ok(set ~= old and set.created == old.created - 1, "a second earlier, so the merge keeps it everywhere")
  H.ok(Quests.CanReroll(), "the reroll comes back with the new quests")
  local n = namedIn(set)
  H.ok(n == 1 or n == 2)
  -- a finished quest keeps the week's quests as they are
  Store.AddCompletion(week, { char = me, slot = 1, time = Time.now(), members = {}, inst = 0, bosses = 0 }, 1)
  local again, why = Quests.TestRefresh()
  H.eq(again, false)
  H.eq(why, "done")
  ns.Build.testTools = false
  H.eq(Quests.TestRefresh(), false, "beta and release builds never roll again")
  ns.Build.testTools = true
end)

H.finish()
