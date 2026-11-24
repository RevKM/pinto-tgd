-- The kinds of synced data ("pieces"), each with its binary format and its merge rule.
--
-- Every merge is commutative, associative and idempotent: receiving anything twice, or in
-- any order, gives the same result. Encodings are canonical (everything sorted), so two
-- addons holding the same data produce the same bytes and the same fingerprint.
-- docs/format.md is the key to every code used here.
local ADDON, ns = ...

local Pieces = {}
ns.Pieces = Pieces

local Util, Bytes = ns.Util, ns.Bytes
local fail = Bytes.fail
local u32str = Bytes.u32str
local char = string.char

-- Frozen codes (part of the data format) -------------------------------------------

-- Activities. Ties weigh only the highest activity per pair per day.
Pieces.ACT = { other = 0, quest = 1, bg = 2, raid = 3, dungeon = 4 }
Pieces.WEIGHT = { [0] = 0, 0.5, 0.5, 0.25, 1 }
Pieces.BRIDGE = { [1] = true, [2] = true, [4] = true }

-- Trades that help a quest.
Pieces.TRADE = { crafted = 1, enchant = 2, materials = 3, recipe = 4 }

-- How a join date was learned. On the same day, the lower code wins.
Pieces.JOIN = { founding = 0, message = 1, seen = 2 }

-- Gear slots counted for item level: every slot but shirt and tabard.
Pieces.GEAR_SLOTS = { 1, 2, 3, 15, 5, 9, 10, 6, 7, 8, 11, 12, 13, 14, 16, 17, 18 }
local SLOTS = #Pieces.GEAR_SLOTS

-- The 9 primary professions.
Pieces.PROFESSIONS = { "Alchemy", "Blacksmithing", "Enchanting", "Engineering", "Herbalism",
  "Leatherworking", "Mining", "Skinning", "Tailoring" }

-- Piece ids ------------------------------------------------------------------------
-- "d<day>" and "w<week>", plus "p" players, "j" join dates, "h" H history,
-- "s" settings and "k" quest packs and release stamps.

local NUMBERED = { d = true, w = true }
local KINDS = { d = 1, p = 2, j = 3, w = 4, h = 5, s = 6, k = 7 }
local LETTERS = { "d", "p", "j", "w", "h", "s", "k" }

function Pieces.id(letter, num)
  if NUMBERED[letter] then return letter .. string.format("%d", num) end
  return letter
end

function Pieces.parse(id)
  local letter = id:sub(1, 1)
  if NUMBERED[letter] then return letter, tonumber(id:sub(2)) end
  return letter, nil
end

function Pieces.writeId(w, id)
  local letter, num = Pieces.parse(id)
  w:u8(KINDS[letter])
  if num then w:u16(num) end
end

function Pieces.readId(r)
  local letter = LETTERS[r:u8()]
  if not letter then fail("piece kind") end
  if NUMBERED[letter] then return Pieces.id(letter, r:u16()) end
  return letter
end

-- Helpers --------------------------------------------------------------------------

local function unionSet(dst, src)
  local changed = false
  for k in pairs(src) do
    if not dst[k] then
      dst[k] = true
      changed = true
    end
  end
  return changed
end

local function sortedNumbers(set)
  local list = {}
  for k in pairs(set) do list[#list + 1] = k end
  table.sort(list)
  return list
end

local function values(t)
  local list = {}
  for _, v in pairs(t) do list[#list + 1] = v end
  return list
end

local function byFields(fields)
  return function(x, y)
    for i = 1, #fields do
      local f = fields[i]
      if x[f] ~= y[f] then return x[f] < y[f] end
    end
    return false
  end
end

-- A deterministic tie-break between two different records that rank the same.
local function hashWith(writeFn, ...)
  local w = Bytes.writer()
  writeFn(w, ...)
  return Util.hash(w:result())
end

local function writeU32Set(w, set)
  local list = sortedNumbers(set)
  w:varint(#list)
  for i = 1, #list do w:u32(list[i]) end
end

local function readU32Set(r, max)
  local set = {}
  for _ = 1, r:count(max) do set[r:u32()] = true end
  return set
end

-- Day pieces -----------------------------------------------------------------------
-- played[nameId] = true: a character of an addon user played that day.
-- together[key] = { a, b, act, rep }: two guildies were in a guild group (a < b).
-- trades[key] = { g, r, kind, item, count, rep }: a trade that helps a quest.
-- rep is the set of reporting accounts, for the witness checks.

local day = {}

function day.new(num)
  return { letter = "d", num = num, played = {}, together = {}, trades = {} }
end

function Pieces.togetherKey(a, b, act)
  if b < a then a, b = b, a end
  return u32str(a) .. u32str(b) .. char(act), a, b
end

function Pieces.tradeKey(g, r, kind, item)
  return u32str(g) .. u32str(r) .. char(kind) .. u32str(item)
end

function day.merge(p, q)
  local changed = unionSet(p.played, q.played)
  for key, rec in pairs(q.together) do
    local mine = p.together[key]
    if not mine then
      p.together[key] = { a = rec.a, b = rec.b, act = rec.act, rep = Util.copy(rec.rep) }
      changed = true
    elseif unionSet(mine.rep, rec.rep) then
      changed = true
    end
  end
  for key, rec in pairs(q.trades) do
    local mine = p.trades[key]
    if not mine then
      p.trades[key] = { g = rec.g, r = rec.r, kind = rec.kind, item = rec.item,
        count = rec.count, rep = Util.copy(rec.rep) }
      changed = true
    else
      if rec.count > mine.count then
        mine.count = rec.count
        changed = true
      end
      if unionSet(mine.rep, rec.rep) then changed = true end
    end
  end
  return changed
end

local togetherOrder = byFields({ "a", "b", "act" })
local tradeOrder = byFields({ "g", "r", "kind", "item" })

local function writeReps(w, rep, ridx)
  local list = {}
  for acct in pairs(rep) do list[#list + 1] = ridx[acct] end
  table.sort(list)
  w:varint(#list)
  for i = 1, #list do w:varint(list[i]) end
end

local function readReps(r, reps)
  local set = {}
  for _ = 1, r:count(255) do
    local acct = reps[r:varint() + 1]
    if not acct then fail("reporter index") end
    set[acct] = true
  end
  return set
end

function day.encode(p, w)
  -- the day's name list, then everything refers to positions in it
  local names = {}
  for id in pairs(p.played) do names[id] = true end
  for _, rec in pairs(p.together) do names[rec.a] = true; names[rec.b] = true end
  for _, rec in pairs(p.trades) do names[rec.g] = true; names[rec.r] = true end
  local nameList = sortedNumbers(names)
  local idx = {}
  w:varint(#nameList)
  for i, id in ipairs(nameList) do
    idx[id] = i - 1
    w:u32(id)
  end

  local reps = {}
  for _, rec in pairs(p.together) do for a in pairs(rec.rep) do reps[a] = true end end
  for _, rec in pairs(p.trades) do for a in pairs(rec.rep) do reps[a] = true end end
  local repList = sortedNumbers(reps)
  local ridx = {}
  w:varint(#repList)
  for i, a in ipairs(repList) do
    ridx[a] = i - 1
    w:u32(a)
  end

  local played = sortedNumbers(p.played)
  w:varint(#played)
  for _, id in ipairs(played) do w:varint(idx[id]) end

  local together = values(p.together)
  table.sort(together, togetherOrder)
  w:varint(#together)
  for _, rec in ipairs(together) do
    w:varint(idx[rec.a])
    w:varint(idx[rec.b])
    w:u8(rec.act)
    writeReps(w, rec.rep, ridx)
  end

  local trades = values(p.trades)
  table.sort(trades, tradeOrder)
  w:varint(#trades)
  for _, rec in ipairs(trades) do
    w:varint(idx[rec.g])
    w:varint(idx[rec.r])
    w:u8(rec.kind)
    w:u32(rec.item)
    w:varint(rec.count)
    writeReps(w, rec.rep, ridx)
  end
end

function day.decode(r, num)
  local p = day.new(num)
  local names = {}
  for i = 1, r:count(1000) do names[i] = r:u32() end
  local reps = {}
  for i = 1, r:count(1000) do reps[i] = r:u32() end
  local function name()
    local id = names[r:varint() + 1]
    if not id then fail("name index") end
    return id
  end
  for _ = 1, r:count(1000) do p.played[name()] = true end
  for _ = 1, r:count(50000) do
    local a, b = name(), name()
    local act = r:u8()
    if act > 4 or a >= b then fail("together") end
    p.together[Pieces.togetherKey(a, b, act)] = { a = a, b = b, act = act, rep = readReps(r, reps) }
  end
  for _ = 1, r:count(5000) do
    local g, rc = name(), name()
    local kind = r:u8()
    if kind < 1 or kind > 4 or g == rc then fail("trade") end
    local item = r:u32()
    local count = r:varint()
    p.trades[Pieces.tradeKey(g, rc, kind, item)] =
      { g = g, r = rc, kind = kind, item = item, count = count, rep = readReps(r, reps) }
  end
  return p
end

-- Players --------------------------------------------------------------------------
-- cards[account] = { updated, player, version, dataVersion, hours, gold, chars }
-- Each WoW account writes its own card; the newest card wins. player is the account
-- this one is linked to (itself unless a second license was linked with a code).
-- chars[i] = { name, level, slots[17] (item level per gear slot), prof = { {id, skill} },
--              cook, aid, fish }

local players = {}

function players.new()
  return { letter = "p", cards = {} }
end

local function writeCard(w, acct, c)
  w:u32(acct)
  w:u32(c.updated)
  w:u32(c.player)
  w:str(c.version or "")
  w:u8(c.dataVersion or 0)
  w:u32(c.hours or 0)
  w:u8(c.gold or 255)
  local chars = {}
  for i = 1, #c.chars do chars[i] = c.chars[i] end
  table.sort(chars, function(x, y) return Util.byteLess(x.name, y.name) end)
  w:varint(#chars)
  for _, ch in ipairs(chars) do
    w:str(ch.name)
    w:u8(ch.level)
    for s = 1, SLOTS do w:u16(ch.slots[s] or 0) end
    local prof = ch.prof or {}
    w:u8(#prof)
    for _, pr in ipairs(prof) do
      w:u8(pr.id)
      w:u16(pr.skill)
    end
    w:u16(ch.cook or 0)
    w:u16(ch.aid or 0)
    w:u16(ch.fish or 0)
  end
end
Pieces.writeCard = writeCard

local function readCard(r)
  local acct = r:u32()
  local c = { updated = r:u32(), player = r:u32(), version = r:str(16), dataVersion = r:u8(),
    hours = r:u32(), gold = r:u8(), chars = {} }
  if c.hours >= 16777216 then fail("hours") end
  for i = 1, r:count(50) do
    local ch = { name = r:str(64), level = r:u8(), slots = {}, prof = {} }
    if ch.name == "" or ch.level > 100 then fail("character") end
    for s = 1, SLOTS do ch.slots[s] = r:u16() end
    local np = r:u8()
    if np > 2 then fail("professions") end
    for j = 1, np do
      local id = r:u8()
      if id < 1 or id > 9 then fail("profession") end
      ch.prof[j] = { id = id, skill = r:u16() }
    end
    ch.cook, ch.aid, ch.fish = r:u16(), r:u16(), r:u16()
    c.chars[i] = ch
  end
  return acct, c
end

function players.merge(p, q)
  local changed = false
  for acct, c in pairs(q.cards) do
    local mine = p.cards[acct]
    local take = not mine
    if mine and mine ~= c then
      if c.updated ~= mine.updated then
        take = c.updated > mine.updated
      else
        take = hashWith(writeCard, acct, c) > hashWith(writeCard, acct, mine)
      end
    end
    if take then
      p.cards[acct] = Util.copy(c)
      changed = true
    end
  end
  return changed
end

function players.encode(p, w)
  local accts = sortedNumbers(p.cards)
  w:varint(#accts)
  for _, acct in ipairs(accts) do writeCard(w, acct, p.cards[acct]) end
end

function players.decode(r)
  local p = players.new()
  for _ = 1, r:count(1000) do
    local acct, c = readCard(r)
    p.cards[acct] = c
  end
  return p
end

-- Join dates -----------------------------------------------------------------------
-- entries[nameId] = { name, day, how, seen }: the earliest join day wins (founding before
-- a join message before first seen on the same day), and seen is the last day an addon
-- saw the character in the roster.

local joins = {}

function joins.new()
  return { letter = "j", entries = {} }
end

function joins.merge(p, q)
  local changed = false
  for id, e in pairs(q.entries) do
    local mine = p.entries[id]
    if not mine then
      p.entries[id] = { name = e.name, day = e.day, how = e.how, seen = e.seen }
      changed = true
    else
      if e.day < mine.day or (e.day == mine.day and e.how < mine.how) then
        mine.day, mine.how = e.day, e.how
        changed = true
      end
      if e.seen > mine.seen then
        mine.seen = e.seen
        changed = true
      end
    end
  end
  return changed
end

function joins.encode(p, w)
  local ids = sortedNumbers(p.entries)
  w:varint(#ids)
  for _, id in ipairs(ids) do
    local e = p.entries[id]
    w:str(e.name)
    w:u16(e.day)
    w:u8(e.how)
    w:u16(e.seen)
  end
end

function joins.decode(r)
  local p = joins.new()
  for _ = 1, r:count(10000) do
    local name = r:str(64)
    local e = { name = name, day = r:u16(), how = r:u8(), seen = r:u16() }
    if name == "" or e.how > 2 then fail("join entry") end
    p.entries[Util.nameId(name)] = e
  end
  return p
end

-- Weeks ----------------------------------------------------------------------------
-- sets[charId] = { created, author, pack, quests = { { t, worth, named = { nameId } } x5 } }
--   slots 1-4 are the character's quests, slot 5 is the hidden spare. First generated wins.
-- rerolls[charId] = { time, slot }: the one reroll; the earliest wins.
-- done[key] = { char, slot, time, members, inst, bosses, rep }: completions, with evidence.

local week = {}

function week.new(num)
  return { letter = "w", num = num, sets = {}, rerolls = {}, done = {} }
end

local function writeSet(w, charId, s)
  w:u32(charId)
  w:u32(s.created)
  w:u32(s.author)
  w:u16(s.pack)
  w:u8(#s.quests)
  for _, q in ipairs(s.quests) do
    w:u16(q.t)
    w:u8(q.worth)
    w:u8(#q.named)
    for _, id in ipairs(q.named) do w:u32(id) end
  end
end

local function readSet(r)
  local charId = r:u32()
  local s = { created = r:u32(), author = r:u32(), pack = r:u16(), quests = {} }
  local n = r:u8()
  if n > 8 then fail("quest count") end
  for i = 1, n do
    local q = { t = r:u16(), worth = r:u8(), named = {} }
    if q.worth < 1 or q.worth > 3 then fail("worth") end
    local nn = r:u8()
    if nn > 4 then fail("named") end
    for j = 1, nn do q.named[j] = r:u32() end
    s.quests[i] = q
  end
  return charId, s
end

function Pieces.doneKey(charId, slot)
  return u32str(charId) .. char(slot)
end

local function writeDone(w, rec)
  w:u32(rec.char)
  w:u8(rec.slot)
  w:u32(rec.time)
  local members = {}
  for i = 1, #rec.members do members[i] = rec.members[i] end
  table.sort(members)
  w:varint(#members)
  for _, id in ipairs(members) do w:u32(id) end
  w:varint(rec.inst)
  w:u8(rec.bosses)
end

local function writeDoneFull(w, rec)
  writeDone(w, rec)
  writeU32Set(w, rec.rep)
end

local function readDone(r)
  local rec = { char = r:u32(), slot = r:u8(), time = r:u32(), members = {} }
  if rec.slot < 1 or rec.slot > 5 then fail("slot") end
  for i = 1, r:count(40) do rec.members[i] = r:u32() end
  rec.inst = r:varint()
  rec.bosses = r:u8()
  rec.rep = readU32Set(r, 255)
  return rec
end

local function copyDone(rec)
  local c = Util.copy(rec)
  return c
end

function week.merge(p, q)
  local changed = false
  for charId, s in pairs(q.sets) do
    local mine = p.sets[charId]
    local take = not mine
    if mine and mine ~= s then
      if s.created ~= mine.created then take = s.created < mine.created
      elseif s.author ~= mine.author then take = s.author < mine.author
      else take = hashWith(writeSet, charId, s) < hashWith(writeSet, charId, mine) end
    end
    if take then
      p.sets[charId] = Util.copy(s)
      changed = true
    end
  end
  for charId, rr in pairs(q.rerolls) do
    local mine = p.rerolls[charId]
    if not mine or rr.time < mine.time or (rr.time == mine.time and rr.slot < mine.slot) then
      if not mine or mine.time ~= rr.time or mine.slot ~= rr.slot then
        p.rerolls[charId] = { time = rr.time, slot = rr.slot }
        changed = true
      end
    end
  end
  for key, rec in pairs(q.done) do
    local mine = p.done[key]
    if not mine then
      p.done[key] = copyDone(rec)
      changed = true
    else
      local earlier = rec.time < mine.time
      if rec.time == mine.time then
        earlier = hashWith(writeDone, rec) < hashWith(writeDone, mine)
      end
      if earlier then
        mine.time, mine.inst, mine.bosses = rec.time, rec.inst, rec.bosses
        mine.members = Util.copy(rec.members)
        changed = true
      end
      if unionSet(mine.rep, rec.rep) then changed = true end
    end
  end
  return changed
end

function week.encode(p, w)
  local ids = sortedNumbers(p.sets)
  w:varint(#ids)
  for _, id in ipairs(ids) do writeSet(w, id, p.sets[id]) end
  ids = sortedNumbers(p.rerolls)
  w:varint(#ids)
  for _, id in ipairs(ids) do
    w:u32(id)
    w:u32(p.rerolls[id].time)
    w:u8(p.rerolls[id].slot)
  end
  local done = values(p.done)
  table.sort(done, byFields({ "char", "slot" }))
  w:varint(#done)
  for _, rec in ipairs(done) do writeDoneFull(w, rec) end
end

function week.decode(r, num)
  local p = week.new(num)
  for _ = 1, r:count(2000) do
    local id, s = readSet(r)
    p.sets[id] = s
  end
  for _ = 1, r:count(2000) do
    local id = r:u32()
    local rr = { time = r:u32(), slot = r:u8() }
    if rr.slot < 1 or rr.slot > 4 then fail("reroll slot") end
    p.rerolls[id] = rr
  end
  for _ = 1, r:count(10000) do
    local rec = readDone(r)
    p.done[Pieces.doneKey(rec.char, rec.slot)] = rec
  end
  return p
end

-- H history ------------------------------------------------------------------------
-- days[day] = { H, W, Q, G, P, T, K (0..10000), N, fv (formula version), data }
-- The newest formula version wins, then the one calculated from the most data.

local history = {}
local HFIELDS = { "H", "W", "Q", "G", "P", "T", "K" }

function history.new()
  return { letter = "h", days = {} }
end

local function writeEntry(w, d, e)
  w:u16(d)
  for _, f in ipairs(HFIELDS) do w:u16(e[f]) end
  w:u8(e.N)
  w:u8(e.fv)
  w:u32(e.data)
end

function history.merge(p, q)
  local changed = false
  for d, e in pairs(q.days) do
    local mine = p.days[d]
    local take = not mine
    if mine and mine ~= e then
      if e.fv ~= mine.fv then take = e.fv > mine.fv
      elseif e.data ~= mine.data then take = e.data > mine.data
      else take = hashWith(writeEntry, d, e) > hashWith(writeEntry, d, mine) end
    end
    if take then
      p.days[d] = Util.copy(e)
      changed = true
    end
  end
  return changed
end

function history.encode(p, w)
  local days = sortedNumbers(p.days)
  w:varint(#days)
  for _, d in ipairs(days) do writeEntry(w, d, p.days[d]) end
end

function history.decode(r)
  local p = history.new()
  for _ = 1, r:count(40000) do
    local d = r:u16()
    local e = {}
    for _, f in ipairs(HFIELDS) do
      e[f] = r:u16()
      if e[f] > 10000 then fail("history value") end
    end
    e.N, e.fv, e.data = r:u8(), r:u8(), r:u32()
    p.days[d] = e
  end
  return p
end

-- Settings -------------------------------------------------------------------------
-- entries[key] = { value, time, author, by }: officer ranks and officer actions.
-- The newest entry per key wins. Whether the author was an officer is checked when
-- the entry is used, so every addon stores the same entries.

local settings = {}

function settings.new()
  return { letter = "s", entries = {} }
end

local function writeSetting(w, key, e)
  w:str(key)
  w:str(e.value)
  w:u32(e.time)
  w:u32(e.author)
  w:str(e.by)
end

function settings.merge(p, q)
  local changed = false
  for key, e in pairs(q.entries) do
    local mine = p.entries[key]
    local take = not mine
    if mine and mine ~= e then
      if e.time ~= mine.time then take = e.time > mine.time
      else take = hashWith(writeSetting, key, e) > hashWith(writeSetting, key, mine) end
    end
    if take then
      p.entries[key] = { value = e.value, time = e.time, author = e.author, by = e.by }
      changed = true
    end
  end
  return changed
end

function settings.encode(p, w)
  local keys = Util.sortedKeys(p.entries, Util.byteLess)
  w:varint(#keys)
  for _, key in ipairs(keys) do writeSetting(w, key, p.entries[key]) end
end

function settings.decode(r)
  local p = settings.new()
  for _ = 1, r:count(5000) do
    local key = r:str(64)
    p.entries[key] = { value = r:str(255), time = r:u32(), author = r:u32(), by = r:str(64) }
  end
  return p
end

-- Quest packs and release stamps ---------------------------------------------------
-- packs[num] = { data, sig }, stamp = { version, dataVersion, protocolVersion, pack,
-- important, sig }. Only signature-checked packs and stamps are ever merged in.

local packs = {}

function packs.new()
  return { letter = "k", packs = {} }
end

function Pieces.versionNumber(v)
  local a, b, c = (v or ""):match("^(%d+)%.(%d+)%.(%d+)$")
  if not a then return -1 end
  return (tonumber(a) * 1000 + tonumber(b)) * 1000 + tonumber(c)
end

-- The bytes a release stamp's signature covers.
function Pieces.stampBody(st)
  local w = Bytes.writer()
  w:raw("PintoStamp")
  w:str(st.version)
  w:u8(st.dataVersion)
  w:u8(st.protocolVersion)
  w:u16(st.pack)
  w:bool(st.important)
  return w:result()
end

local function writePack(w, num, pk)
  w:u16(num)
  w:str(pk.data)
  w:raw(pk.sig)
end

local function writeStamp(w, st)
  w:raw(Pieces.stampBody(st))
  w:raw(st.sig)
end

function packs.merge(p, q)
  local changed = false
  for num, pk in pairs(q.packs) do
    local mine = p.packs[num]
    local take = not mine
    if mine and mine ~= pk and (mine.data ~= pk.data or mine.sig ~= pk.sig) then
      take = hashWith(writePack, num, pk) < hashWith(writePack, num, mine)
    end
    if take then
      p.packs[num] = { data = pk.data, sig = pk.sig }
      changed = true
    end
  end
  local st = q.stamp
  if st then
    local mine = p.stamp
    local take = not mine
    if mine and mine ~= st then
      local a, b = Pieces.versionNumber(st.version), Pieces.versionNumber(mine.version)
      if a ~= b then take = a > b
      else
        local ha, hb = hashWith(writeStamp, st), hashWith(writeStamp, mine)
        take = ha > hb
      end
    end
    if take then
      p.stamp = Util.copy(st)
      changed = true
    end
  end
  return changed
end

function packs.encode(p, w)
  local nums = sortedNumbers(p.packs)
  w:varint(#nums)
  for _, num in ipairs(nums) do writePack(w, num, p.packs[num]) end
  w:bool(p.stamp ~= nil)
  if p.stamp then writeStamp(w, p.stamp) end
end

-- A stamp on its own, as a STAMP message carries it (Release.Offer): the signed body, then
-- the signature. Every version reads it with Pieces.readStamp, so it never changes.
function Pieces.stampBytes(st)
  return Pieces.stampBody(st) .. st.sig
end

function Pieces.readStamp(r)
  if r:bytes(10) ~= "PintoStamp" then fail("stamp") end
  local st = { version = r:str(16), dataVersion = r:u8(), protocolVersion = r:u8(),
    pack = r:u16(), important = r:bool() }
  st.sig = r:bytes(64)
  return st
end

function packs.decode(r)
  local p = packs.new()
  for _ = 1, r:count(64) do
    local num = r:u16()
    p.packs[num] = { data = r:str(65535), sig = r:bytes(64) }
  end
  if r:bool() then p.stamp = Pieces.readStamp(r) end
  return p
end

-- Registry -------------------------------------------------------------------------

Pieces.codec = { d = day, p = players, j = joins, w = week, h = history, s = settings, k = packs }

function Pieces.new(id)
  local letter, num = Pieces.parse(id)
  return Pieces.codec[letter].new(num)
end

-- A whole piece: [data version u8][piece id][content].
function Pieces.encode(id, piece)
  local w = Bytes.writer()
  w:u8(ns.Build.dataVersion)
  Pieces.writeId(w, id)
  Pieces.codec[piece.letter].encode(piece, w)
  return w:result()
end

-- The content decoder for the current data version, used by Pieces.decode and migrations.
function Pieces.decodeContent(r, letter, num)
  return Pieces.codec[letter].decode(r, num)
end

-- Returns { id, piece, migrated } or nil and a reason.
function Pieces.decode(bin)
  return Bytes.decode(bin, function(r)
    local dv = r:u8()
    local id = Pieces.readId(r)
    local letter, num = Pieces.parse(id)
    local piece
    if dv == ns.Build.dataVersion then
      piece = Pieces.decodeContent(r, letter, num)
    elseif dv < ns.Build.dataVersion and dv >= 1 then
      piece = ns.Migrations.decode(dv, letter, num, r)
    else
      fail("data version")
    end
    if not r:atEnd() then fail("trailing bytes") end
    return { id = id, piece = piece, migrated = dv ~= ns.Build.dataVersion }
  end)
end
