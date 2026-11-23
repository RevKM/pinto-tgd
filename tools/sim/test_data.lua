-- Encoding, hashing, server days and the merge rules of every piece kind.
local H = require("harness")
local wow = require("wow")

local world = wow.world({ seed = 7 })
world:addMember(wow.full("Kiri"))
local client = world:client(wow.full("Kiri"))
client.online = true
local env = client:makeEnv()
local ns = H.load({ "Core/Build.lua", "Core/Init.lua", "Core/Compat.lua", "Core/Util.lua",
  "Core/Time.lua", "Sync/Bytes.lua", "Data/Pieces.lua", "Data/Migrations.lua", "Data/Store.lua" }, {}, env)

local Util, Bytes, Time, Pieces, Store = ns.Util, ns.Bytes, ns.Time, ns.Pieces, ns.Store

local function randomBytes(n)
  local t = {}
  for i = 1, n do t[i] = string.char(math.random(0, 255)) end
  return table.concat(t)
end

-- Bytes -----------------------------------------------------------------------------

H.test("bytes round trip", function()
  local w = Bytes.writer()
  w:u8(0):u8(255):u16(0):u16(65535):u32(0):u32(4294967295)
  w:varint(0):varint(127):varint(128):varint(300):varint(4294967296):varint(9007199254740991)
  w:str(""):str("hello\0world"):bool(true):bool(false)
  local r = Bytes.reader(w:result())
  H.eq(r:u8(), 0); H.eq(r:u8(), 255); H.eq(r:u16(), 0); H.eq(r:u16(), 65535)
  H.eq(r:u32(), 0); H.eq(r:u32(), 4294967295)
  H.eq(r:varint(), 0); H.eq(r:varint(), 127); H.eq(r:varint(), 128); H.eq(r:varint(), 300)
  H.eq(r:varint(), 4294967296); H.eq(r:varint(), 9007199254740991)
  H.eq(r:str(), ""); H.eq(r:str(), "hello\0world"); H.eq(r:bool(), true); H.eq(r:bool(), false)
  H.ok(r:atEnd())
end)

H.test("bytes reject bad input", function()
  H.raises(function() Bytes.writer():u8(256) end, "out of range")
  H.raises(function() Bytes.writer():u16(1.5) end, "out of range")
  H.raises(function() Bytes.writer():varint(-1) end, "out of range")
  local res, why = Bytes.decode("\1", function(r) return r:u16() end)
  H.eq(res, nil)
  H.eq(why, "u16")
end)

-- Util ------------------------------------------------------------------------------

H.test("base64 round trip", function()
  for n = 0, 40 do
    local s = randomBytes(n)
    H.eq(Util.unbase64(Util.base64(s)), s)
  end
  H.eq(Util.base64("Man"), "TWFu")
  H.eq(Util.base64("Ma"), "TWE=")
  H.eq(Util.unbase64("TWFu!!=="), nil)
end)

H.test("escape round trip and no zero bytes", function()
  local all = {}
  for b = 0, 255 do all[#all + 1] = string.char(b) end
  local s = table.concat(all) .. "\0\0\1\1" .. randomBytes(300)
  local e = Util.escape(s)
  H.ok(not e:find("\0", 1, true), "escaped text still has a zero byte")
  H.eq(Util.unescape(e), s)
  H.eq(Util.unescape("ab\1"), nil)
  H.eq(Util.escape("plain"), "plain")
end)

H.test("hash and ids", function()
  H.eq(Util.hash("abc"), Util.hash("abc"))
  H.ok(Util.hash("abc") ~= Util.hash("abd"))
  H.ok(Util.nameId("Kiri-Forever") ~= Util.nameId("Kiri-Forevr"))
  local v = Util.hash(randomBytes(500))
  H.ok(v >= 0 and v < 4294967296 and v == math.floor(v))
  for _ = 1, 50 do
    local id = Util.randomU32()
    local code = Util.linkCode(id)
    H.eq(Util.parseLinkCode(code), id)
    H.eq(Util.parseLinkCode(code:lower()), id)
  end
  H.eq(Util.parseLinkCode("ABCD-EFGZ"), nil)
end)

H.test("byte order and statistics", function()
  H.ok(Util.byteLess("a", "b"))
  H.ok(Util.byteLess("Z", "a"))
  H.ok(Util.byteLess("ab", "abc"))
  H.ok(not Util.byteLess("abc", "abc"))
  H.ok(Util.byteLess("\0", "\1"))
  H.eq(Util.median({ 3, 1, 2 }), 2)
  H.eq(Util.median({ 4, 1, 2, 3 }), 2.5)
  H.near(Util.percentile({ 1, 2, 3, 4, 5 }, 0.9), 4.6)
end)

-- Time ------------------------------------------------------------------------------

H.test("calendar days", function()
  H.eq(Time.dayOfDate("1970-01-01"), 0)
  H.eq(Time.dayOfDate("2026-01-01"), 20454)
  H.eq(Time.dayOfDate("2026-12-07"), 20794)
  H.eq(Time.dateOfDay(20794), "2026-12-07")
  H.eq(Time.dateOfDay(Time.dayOfDate("2028-02-29")), "2028-02-29")
end)

H.test("days start at 03:00 server time, winter and summer", function()
  -- 2026-12-07 03:00 CET = 02:00 UTC
  H.eq(Time.day(1796608800), 20794)
  H.eq(Time.day(1796608799), 20793)
  H.eq(Time.dayStart(20794), 1796608800)
  -- 2026-07-01 03:00 CEST = 01:00 UTC
  H.eq(Time.day(1782867600), 20635)
  H.eq(Time.day(1782867599), 20634)
  H.eq(Time.dayStart(20635), 1782867600)
  -- summer time 2026: from 01:00 UTC on 29 March to 01:00 UTC on 25 October
  local march29 = Time.dayOfDate("2026-03-29") * 86400
  H.eq(Time.offset(march29 + 3599), 3600)
  H.eq(Time.offset(march29 + 3600), 7200)
  local oct25 = Time.dayOfDate("2026-10-25") * 86400
  H.eq(Time.offset(oct25 + 3599), 7200)
  H.eq(Time.offset(oct25 + 3600), 3600)
  -- the days around both switches still start at 03:00 local
  for _, iso in ipairs({ "2026-03-28", "2026-03-29", "2026-03-30", "2026-10-24", "2026-10-25", "2026-10-26" }) do
    local d = Time.dayOfDate(iso)
    local start = Time.dayStart(d)
    H.eq(Time.day(start), d, iso)
    H.eq(Time.day(start - 1), d - 1, iso)
    H.eq(Time.hour(start), 3, iso)
  end
end)

H.test("weeks start on Monday", function()
  H.eq(Time.week(20794), Time.week(20800))
  H.eq(Time.week(20793) + 1, Time.week(20794))
  H.eq(Time.weekStartDay(Time.week(20797)), 20794)
  H.eq(Time.secondsToWeekReset(1796608800), 7 * 86400)
end)

H.test("countdown text", function()
  H.eq(Time.countdown((3 * 24 + 7) * 3600 + 100), "3 days and 7 hours")
  H.eq(Time.countdown(25 * 3600), "1 day and 1 hour")
  H.eq(Time.countdown(5 * 3600 + 59), "5 hours")
  H.eq(Time.countdown(3600), "1 hour")
  H.eq(Time.countdown(48 * 3600), "2 days")
  H.eq(Time.countdown(3599), nil)
end)

-- Pieces: random data for every kind ------------------------------------------------

local names = {}
for i = 1, 12 do names[i] = Util.nameId(string.format("Guildie%d-Forever", i)) end
local accounts = { 11, 22, 33, 44 }

local function pick(list) return list[math.random(#list)] end

local function randomDelta(id)
  local d = Pieces.new(id)
  local letter = d.letter
  if letter == "d" then
    for _ = 1, math.random(0, 3) do d.played[pick(names)] = true end
    for _ = 1, math.random(0, 4) do
      local a, b = pick(names), pick(names)
      if a ~= b then
        local act = math.random(0, 4)
        local key, lo, hi = Pieces.togetherKey(a, b, act)
        d.together[key] = { a = lo, b = hi, act = act, rep = { [pick(accounts)] = true } }
      end
    end
    for _ = 1, math.random(0, 2) do
      local g, r = pick(names), pick(names)
      if g ~= r then
        local kind, item = math.random(1, 4), math.random(1, 3)
        d.trades[Pieces.tradeKey(g, r, kind, item)] =
          { g = g, r = r, kind = kind, item = item, count = math.random(1, 20), rep = { [pick(accounts)] = true } }
      end
    end
  elseif letter == "p" then
    local acct = pick(accounts)
    local slots = {}
    for s = 1, 17 do slots[s] = math.random(0, 80) end
    d.cards[acct] = { updated = math.random(1, 5), player = pick(accounts), version = "0.1.0",
      dataVersion = 1, hours = math.random(0, 16777215), gold = math.random(0, 255),
      chars = { { name = "Char" .. acct .. "-Forever", level = math.random(1, 60), slots = slots,
        prof = { { id = math.random(1, 9), skill = math.random(1, 300) } }, cook = 1, aid = 2, fish = 3 } } }
  elseif letter == "j" then
    for _ = 1, math.random(1, 3) do
      local i = math.random(1, 12)
      local n = string.format("Guildie%d-Forever", i)
      d.entries[Util.nameId(n)] = { name = n, day = math.random(100, 110), how = math.random(0, 2),
        seen = math.random(100, 120) }
    end
  elseif letter == "w" then
    local c = pick(names)
    local quests = {}
    for q = 1, 5 do quests[q] = { t = math.random(1, 40), worth = math.random(1, 3), named = { pick(names) } } end
    d.sets[c] = { created = math.random(1, 5), author = pick(accounts), pack = 1, quests = quests }
    d.rerolls[pick(names)] = { time = math.random(1, 5), slot = math.random(1, 4) }
    local slot = math.random(1, 5)
    d.done[Pieces.doneKey(c, slot)] = { char = c, slot = slot, time = math.random(1, 5),
      members = { pick(names), pick(names) }, inst = math.random(0, 400), bosses = math.random(0, 9),
      rep = { [pick(accounts)] = true } }
  elseif letter == "h" then
    local e = { H = math.random(0, 10000), W = 5, Q = 1, G = 2, P = 3, T = 4, K = 5,
      N = math.random(6, 30), fv = math.random(1, 2), data = math.random(1, 3) }
    d.days[math.random(20790, 20794)] = e
  elseif letter == "s" then
    d.entries[pick({ "ranks", "void:1:2", "excl:3" })] =
      { value = tostring(math.random(1, 9)), time = math.random(1, 5), author = pick(accounts), by = "Kiri-Forever" }
  elseif letter == "k" then
    d.packs[math.random(1, 3)] = { data = "pack" .. math.random(1, 2), sig = string.rep("s", 64) }
    if math.random() < 0.5 then
      d.stamp = { version = pick({ "0.1.0", "0.2.0", "0.1.5" }), dataVersion = 1, protocolVersion = 1,
        pack = 1, important = math.random() < 0.5, sig = string.rep(pick({ "a", "b" }), 64) }
    end
  end
  return d
end

local IDS = { "d20794", "p", "j", "w2971", "h", "s", "k" }

local function encodeOf(id, piece) return Pieces.encode(id, piece) end

H.test("every piece kind encodes and decodes to the same bytes", function()
  for _, id in ipairs(IDS) do
    for _ = 1, 20 do
      local p = Pieces.new(id)
      for _ = 1, 5 do Pieces.codec[p.letter].merge(p, randomDelta(id)) end
      local bin = encodeOf(id, p)
      local res = Pieces.decode(bin)
      H.ok(res, "decode failed for " .. id)
      H.eq(res.id, id)
      H.eq(encodeOf(id, res.piece), bin, "re-encoding " .. id)
    end
  end
end)

H.test("merges give the same result in any order, and twice is the same as once", function()
  for _, id in ipairs(IDS) do
    for _ = 1, 30 do
      local deltas = {}
      for i = 1, math.random(2, 8) do deltas[i] = randomDelta(id) end
      local a, b = Pieces.new(id), Pieces.new(id)
      local codec = Pieces.codec[a.letter]
      for i = 1, #deltas do codec.merge(a, deltas[i]) end
      local order = {}
      for i = 1, #deltas do order[i] = i end
      for i = #order, 2, -1 do
        local j = math.random(i)
        order[i], order[j] = order[j], order[i]
      end
      for _, i in ipairs(order) do codec.merge(b, deltas[i]) end
      H.eq(encodeOf(id, a), encodeOf(id, b), "order changed the result for " .. id)
      -- merging everything again changes nothing
      for i = 1, #deltas do H.eq(codec.merge(a, deltas[i]), false, "second merge changed " .. id) end
      -- merging two halves built separately gives the same too
      local c1, c2 = Pieces.new(id), Pieces.new(id)
      for i = 1, #deltas do
        if i % 2 == 0 then codec.merge(c1, deltas[i]) else codec.merge(c2, deltas[i]) end
      end
      codec.merge(c1, c2)
      H.eq(encodeOf(id, c1), encodeOf(id, a), "halves merged differently for " .. id)
    end
  end
end)

H.test("decoding rejects damaged pieces", function()
  local p = randomDelta("d20794")
  local bin = encodeOf("d20794", p)
  for cut = 1, #bin - 1 do
    local res = Pieces.decode(bin:sub(1, cut))
    H.eq(res, nil, "a truncated piece decoded")
  end
  H.eq((Pieces.decode(bin .. "x")), nil, "trailing bytes accepted")
  H.eq((Pieces.decode("\9" .. bin:sub(2))), nil, "a newer data version accepted")
end)

-- Store ------------------------------------------------------------------------------

H.test("store merges, fingerprints, saves and loads", function()
  local deltas = {}
  ns.Events.On("PINTO_LOCAL_DELTA", function(id) deltas[#deltas + 1] = id end)
  local today = Time.day(world.time)
  H.ok(Store.AddPlayed(today, "Kiri-Forever"))
  H.eq(Store.AddPlayed(today, "Kiri-Forever"), false, "the same fact twice")
  H.ok(Store.AddGroup(today, { "Kiri-Forever", "Thorn-Forever", "Bram-Forever" }, Pieces.ACT.dungeon, 11))
  H.eq(#deltas, 2)
  local fp1 = Store.wholeFingerprint()
  H.ok(Store.AddTrade(today, "Kiri-Forever", "Thorn-Forever", Pieces.TRADE.crafted, 2589, 1, 11))
  H.ok(Store.wholeFingerprint() ~= fp1)
  -- too old and before go-live: ignored
  H.eq(Store.AddPlayed(today - 120, "Kiri-Forever"), false)

  local slot = {}
  Store.Save(slot)
  local saved = H.deepCopy(slot)
  local before = Store.wholeFingerprint()
  Store.pieces = {}
  H.ok(Store.Load(saved))
  H.eq(Store.wholeFingerprint(), before)
  -- saved pieces are not readable text
  for _, text in pairs(saved.pieces) do H.ok(not text:find("Kiri", 1, true)) end
end)

H.test("pruning drops old days and stale characters", function()
  local today = Time.day(world.time)
  Store.pieces = {}
  Store.AddPlayed(today, "Kiri-Forever")
  Store.NoteJoins({ { name = "Kiri-Forever", day = today, how = Pieces.JOIN.founding } }, today)
  Store.Prune(today + 100)
  H.eq(Store.get(Pieces.id("d", today)), nil)
  H.eq(Store.get("j"), nil, "a character not seen for 100 days stays")
end)

H.finish()
