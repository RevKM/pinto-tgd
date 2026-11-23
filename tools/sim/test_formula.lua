-- H and its parts on small worked examples, plus calibration, too few players, mood.
local H = require("harness")
local wow = require("wow")

local world = wow.world({ seed = 3 })
local client = world:client(wow.full("Kiri"))
client.online = true
local env = client:makeEnv()
env.PintoTGD_DB = {}
local files = {}
for _, f in ipairs(H.tocFiles()) do
  if f ~= "Main.lua" then files[#files + 1] = f end
end
local ns = H.load(files, {}, env)
local Store, Pieces, Time, Util, Formula, Health, People, Roster =
  ns.Store, ns.Pieces, ns.Time, ns.Util, ns.Formula, ns.Health, ns.People, ns.Roster
-- the handlers that clear caches when data changes
People.Init()
Formula.Init()
ns.Pack.Init()

local GO = Time.dayOfDate(ns.Build.goLive)
-- the standard calibration week: 7 days after go-live, whatever wake-up day a test build
-- sets (test_quests checks that one)
ns.Build.wakeUp = nil
local T = GO + 30
world.time = Time.dayStart(T) + 3600

local full = wow.full

local function reset(members)
  Store.pieces = {}
  Roster.members = {}
  for _, n in ipairs(members) do
    Roster.members[full(n)] = { name = full(n), rankIndex = 2, level = 60, online = true, note = "" }
  end
  Roster.loaded = true
  Roster.altCache = nil
  ns.Events.Fire("PINTO_ROSTER")
  ns.Events.Fire("PINTO_DATA_CHANGED", nil, "test")
end

local acct = 100
local function addPlayer(n, opts)
  opts = opts or {}
  acct = acct + 1
  local slots = {}
  for s = 1, 17 do slots[s] = opts.ilvl or 50 end
  Store.SetCard(acct, { updated = 1, player = acct, version = "0.1.0", dataVersion = 1, hours = 0, gold = opts.gold or 0,
    chars = { { name = full(n), level = 60, slots = slots, prof = opts.prof or {}, cook = 0, aid = 0, fish = 0 } } })
  local join = opts.joined or GO
  Store.NoteJoins({ { name = full(n), day = join, how = opts.joined and Pieces.JOIN.message or Pieces.JOIN.founding } }, T - 1)
  return acct
end

local function playDays(names, from, to)
  for d = from, to do
    for _, n in ipairs(names) do Store.AddPlayed(d, full(n)) end
  end
end

local function group(names, act, from, to)
  local list = {}
  for i, n in ipairs(names) do list[i] = full(n) end
  for d = from, to do Store.AddGroup(d, list, act, 1) end
end

local function near(a, b, msg) H.near(a, b, 1e-6, msg) end

-- Two trios that each run a dungeon every day for 30 days.
local function twoTrios()
  reset({ "A", "B", "C", "D", "E", "F" })
  for _, n in ipairs({ "A", "B", "C", "D", "E", "F" }) do addPlayer(n) end
  playDays({ "A", "B", "C", "D", "E", "F" }, T - 30, T - 1)
  group({ "A", "B", "C" }, Pieces.ACT.dungeon, T - 30, T - 1)
  group({ "D", "E", "F" }, Pieces.ACT.dungeon, T - 30, T - 1)
end

H.test("worked example: two trios that never mix", function()
  twoTrios()
  local c = Formula.Compute(T)
  H.eq(c.N, 6)
  -- ties: a dungeon every day for 30 days, w = (1 - 0.96^30) / 0.04, far above z
  local z = 1.8 * (1 - 0.96 ^ 30)
  near(c.z, z)
  near(c.T1, 1, "everyone grouped every play day")
  local T2 = 2 / (4 * math.log10(6))
  near(c.T2, T2, "2 ties each")
  local Tv = (0.40 * 1 + 0.35 * T2) / 0.75
  near(c.T, Tv, "no new players, so T3 drops out")
  -- crews of 2, no bridges: k = (2/3)·0.3
  near(c.K1, (2 / 3) * 0.3)
  near(c.K2, 3 / 6, "two groups of 3")
  local g = (50 - 0.55 * 60) / ((60 + 6) - 0.55 * 60)
  near(c.G1, g / 0.6)
  near(c.G2, 1)
  near(c.P, 0)
  local K = 0.7 * (2 / 3) * 0.3 + 0.3 * 0.5
  local G = 0.6 * (g / 0.6) + 0.4
  near(c.H, 100 * 1 * (0.15 * G + 0.45 * Tv + 0.25 * K))
end)

H.test("worked example: one quest across the trios is a bridge day for both", function()
  twoTrios()
  group({ "A", "D" }, Pieces.ACT.quest, T - 1, T - 1)
  local c = Formula.Compute(T)
  -- A and D bridged; the others didn't
  near(c.K1, (2 * (2 / 3) * 1.0 + 4 * (2 / 3) * 0.3) / 6)
  near(c.K2, 0.5, "one quest doesn't make a tie, so the groups stay apart")
end)

H.test("too few players: H needs 6 active addon users", function()
  twoTrios()
  -- F stops playing: only 5 left active
  Store.pieces = {}
  reset({ "A", "B", "C", "D", "E", "F" })
  for _, n in ipairs({ "A", "B", "C", "D", "E", "F" }) do addPlayer(n) end
  playDays({ "A", "B", "C", "D", "E" }, T - 7, T - 1)
  playDays({ "F" }, T - 7, T - 7)
  local c = Formula.Compute(T)
  H.eq(c.N, 5)
  H.eq(c.H, nil)
end)

H.test("new members: T3 from how many grouped with an established guildie", function()
  twoTrios()
  for _, n in ipairs({ "G", "H", "I" }) do
    Roster.members[full(n)] = { name = full(n), rankIndex = 4, level = 60, online = true, note = "" }
    addPlayer(n, { joined = T - 10 })
  end
  ns.Events.Fire("PINTO_DATA_CHANGED", nil, "test")
  playDays({ "G", "H", "I" }, T - 7, T - 1)
  group({ "G", "A" }, Pieces.ACT.quest, T - 7, T - 1)
  group({ "H", "I" }, Pieces.ACT.quest, T - 7, T - 1)
  local c = Formula.Compute(T)
  H.eq(c.N, 9)
  near(c.M, 1 / 3)
  near(c.T3, (1 / 3) / 0.75)
end)

H.test("new players count from their fourth day", function()
  twoTrios()
  Roster.members[full("G")] = { name = full("G"), rankIndex = 4, level = 60, online = true, note = "" }
  addPlayer("G", { joined = T - 2 })
  ns.Events.Fire("PINTO_DATA_CHANGED", nil, "test")
  playDays({ "G" }, T - 2, T - 1)
  H.eq(Formula.Compute(T).N, 6)
end)

H.test("profession coverage", function()
  twoTrios()
  -- give A, B and C Tailoring at 300 (cap 300 at 60): ratio 1
  Store.pieces.p = nil
  acct = 100
  for _, n in ipairs({ "A", "B", "C" }) do addPlayer(n, { prof = { { id = 9, skill = 300 } } }) end
  for _, n in ipairs({ "D", "E", "F" }) do addPlayer(n) end
  ns.Events.Fire("PINTO_DATA_CHANGED", "p", "test")
  local c = Formula.Compute(T)
  -- p = mean over two slots, empty = 0: 0.5 for A-C, 0 for D-F; median 0.25
  near(c.P1, 0.25)
  -- D = max(1, round(log10 6)) = 1, so 1 of 9 professions is covered
  near(c.P2, 1 / 9)
end)

H.test("alts: a public note links a character without the addon to its main", function()
  twoTrios()
  Roster.members[full("Nox")] = { name = full("Nox"), rankIndex = 4, level = 20, online = true, note = "A's alt" }
  Roster.altCache = nil
  Store.NoteJoins({ { name = full("Nox"), day = GO, how = Pieces.JOIN.founding } }, T - 1)
  ns.Events.Fire("PINTO_ROSTER")
  H.eq(People.PlayerOf(Util.nameId(full("Nox"))), People.PlayerOf(Util.nameId(full("A"))))
end)

H.test("calibration, missing the gang and slimming down", function()
  twoTrios()
  -- before day 8, Pinto sleeps at 0.5
  local entry = { H = 6000, W = 3000, Q = 0, G = 0, P = 0, T = 0, K = 0, N = 10, fv = 1, data = 9 }
  for d = GO, GO + 6 do Store.SetHistory(d, entry) end
  local w, _, state = Health.Shape(GO + 3)
  H.eq(state, "calibration")
  H.eq(w, 0.5)
  -- day 8 with only 5 active: the calibration runs on
  Store.SetHistory(GO + 7, { H = 0, W = 3000, Q = 0, G = 0, P = 0, T = 0, K = 0, N = 5, fv = 1, data = 9 })
  _, _, state = Health.Shape(GO + 7)
  H.eq(state, "long")
  -- day 9 with 7: the real H takes over
  Store.SetHistory(GO + 8, { H = 4200, W = 3000, Q = 0, G = 0, P = 0, T = 0, K = 0, N = 7, fv = 1, data = 9 })
  w, _, state = Health.Shape(GO + 8)
  H.eq(state, "normal")
  near(w, 0.42)
  -- then too few players: 7 days at 0.42, then 0.02 a day down to 0.2
  for d = GO + 9, GO + 30 do
    Store.SetHistory(d, { H = 0, W = 3000, Q = 0, G = 0, P = 0, T = 0, K = 0, N = 4, fv = 1, data = 9 })
  end
  w, _, state = Health.Shape(GO + 15)
  H.eq(state, "missing")
  near(w, 0.42)
  w = Health.Shape(GO + 18)
  near(w, 0.42 - 0.02 * 3)
  w = Health.Shape(GO + 30)
  near(w, 0.2)
end)

H.test("mood lines and feeding bands", function()
  H.eq(Health.Band(0.05), 1)
  H.eq(Health.Band(0.12), 2)
  H.eq(Health.Band(0.5), 3)
  H.eq(Health.Band(0.85), 5)
  H.eq(Health.MoodLine(0.5, 0.2), "Doing alright, though the tummy's starting to grumble.")
  H.eq(Health.MoodLine(0.9, 2), "Magnificently stuffed! Can't even see the hoard past this belly.")
  H.eq(Health.FeedingLevel(1.2), 2)
  H.eq(Health.FeedingLevel(1.21), 3)
end)

H.test("countdown lines", function()
  local start = Time.dayStart(GO + 7)
  H.eq(Health.AwakesText(start - (3 * 86400 + 7 * 3600 + 5)), "Pinto awakes in 3 days and 7 hours")
  H.eq(Health.AwakesText(start - 1800), "Pinto awakes in less than an hour")
  H.eq(Health.ArrivesText(Time.dayStart(GO) - 2 * 86400), "Pinto arrives in 2 days!")
end)

H.finish()
