-- The guild's data as this addon knows it: every piece, its fingerprint, pruning, and
-- saving to SavedVariables. Facts this addon records go through Store.merge exactly like
-- data from other addons, so there is only one way data changes.
local ADDON, ns = ...

local Store = {}
ns.Store = Store

local Pieces, Util, Bytes, Time, Events = ns.Pieces, ns.Util, ns.Bytes, ns.Time, ns.Events

Store.pieces = {}
local cache = {}  -- id -> { bin = encoded piece, fp = fingerprint }
local dirty = {}  -- ids changed since the last save
local wholeFp = nil

local function touched(id)
  cache[id] = nil
  dirty[id] = true
  wholeFp = nil
end

-- What we keep: day pieces for 100 days, week pieces for 8 weeks, nothing from before
-- go-live. Every addon prunes by the same rule at the same daily boundary.
function Store.inWindow(id, today)
  today = today or Time.day()
  local letter, num = Pieces.parse(id)
  if not Pieces.codec[letter] then return false end
  local goLive = Time.goLiveDay()
  if letter == "d" then return num >= goLive and num > today - 100 and num <= today + 1 end
  if letter == "w" then
    local wk = Time.week(today)
    return num >= Time.week(goLive) and num > wk - 8 and num <= wk + 1
  end
  return true
end

function Store.get(id)
  return Store.pieces[id]
end

-- Merges a whole piece or a delta into ours. origin is "local" for facts this addon
-- records (they get broadcast) and "remote" for data from other addons.
function Store.merge(id, incoming, origin)
  if not Store.inWindow(id) then return false end
  local p = Store.pieces[id] or Pieces.new(id)
  local changed = Pieces.codec[p.letter].merge(p, incoming)
  if changed then
    Store.pieces[id] = p
    touched(id)
    Events.Fire("PINTO_DATA_CHANGED", id, origin)
    if origin == "local" then Events.Fire("PINTO_LOCAL_DELTA", id, incoming) end
  end
  return changed
end

function Store.encoded(id)
  local c = cache[id]
  if not c then
    local bin = Pieces.encode(id, Store.pieces[id])
    c = { bin = bin, fp = Util.hash(bin) }
    cache[id] = c
  end
  return c.bin, c.fp
end

function Store.fingerprint(id)
  local _, fp = Store.encoded(id)
  return fp
end

function Store.ids()
  local ids = {}
  for id in pairs(Store.pieces) do ids[#ids + 1] = id end
  table.sort(ids, Util.byteLess)
  return ids
end

-- A fingerprint of everything: each piece id and fingerprint, in a fixed order.
function Store.wholeFingerprint()
  if not wholeFp then
    local h = 2166136261
    for _, id in ipairs(Store.ids()) do
      h = Util.hash(id, h)
      h = Util.hash(Bytes.u32str(Store.fingerprint(id)), h)
    end
    wholeFp = h
  end
  return wholeFp
end

local function isEmpty(p)
  if p.letter == "j" then return next(p.entries) == nil end
  if p.letter == "p" then return next(p.cards) == nil end
  if p.letter == "k" then return next(p.packs) == nil and p.stamp == nil end
  return false
end

function Store.Prune(today)
  today = today or Time.day()
  for _, id in ipairs(Store.ids()) do
    if not Store.inWindow(id, today) then
      Store.pieces[id] = nil
      touched(id)
    end
  end
  local cutoff = today - 99

  -- join dates: 100 days after a character was last seen in the roster
  local j = Store.pieces.j
  if j then
    local any = false
    for nid, e in pairs(j.entries) do
      if e.seen < cutoff then
        j.entries[nid] = nil
        any = true
      end
    end
    if any then touched("j") end
  end

  -- player cards: while one of their characters is still known, or recently updated
  local p = Store.pieces.p
  if p then
    local cutoffTime = Time.dayStart(cutoff)
    local any = false
    for acct, c in pairs(p.cards) do
      local keep = c.updated >= cutoffTime
      if not keep and j then
        for _, ch in ipairs(c.chars) do
          if j.entries[Util.nameId(ch.name)] then
            keep = true
            break
          end
        end
      end
      if not keep then
        p.cards[acct] = nil
        any = true
      end
    end
    if any then touched("p") end
  end

  -- quest packs: the newest, plus any that a stored quest set still uses
  local k = Store.pieces.k
  if k then
    local used, newest = {}, -1
    for num in pairs(k.packs) do
      if num > newest then newest = num end
    end
    used[newest] = true
    for _, piece in pairs(Store.pieces) do
      if piece.letter == "w" then
        for _, s in pairs(piece.sets) do used[s.pack] = true end
      end
    end
    local any = false
    for num in pairs(k.packs) do
      if not used[num] then
        k.packs[num] = nil
        any = true
      end
    end
    if any then touched("k") end
  end

  for _, id in ipairs({ "j", "p", "k" }) do
    if Store.pieces[id] and isEmpty(Store.pieces[id]) then
      Store.pieces[id] = nil
      touched(id)
    end
  end
  Events.Fire("PINTO_DATA_CHANGED", nil, "prune")
end

-- Saving ----------------------------------------------------------------------------
-- PintoTGD_DB.data[slotKey] = { v = data version, pieces = { [id] = base64 },
--   backup = { v, pieces } while a migration hasn't been confirmed, check = true }

function Store.slotKey()
  return string.format("%s/%s/%s%s", ns.Compat.HomeKey(), ns.GUILD,
    ns.Build.test and "test-" or "", ns.Build.goLive)
end

-- Returns true, or false and "newer" (saved by a newer addon) or "migration" (a contract
-- failed). On failure the saved data stays exactly as it was.
function Store.Load(slot)
  slot.pieces = slot.pieces or {}
  local from = slot.v or ns.Build.dataVersion
  if from > ns.Build.dataVersion then return false, "newer" end

  local loaded, migrated = {}, {}
  for id, text in pairs(slot.pieces) do
    local bin = Util.unbase64(text)
    if bin then
      local ok, res = pcall(Pieces.decode, bin)
      if not ok then return false, "migration" end
      if res then
        loaded[res.id] = res.piece
        if res.migrated then migrated[res.id] = true end
      end
      -- a malformed piece is dropped; sync fetches it again
    end
  end

  if from < ns.Build.dataVersion and not slot.backup then
    slot.backup = { v = from, pieces = Util.copy(slot.pieces) }
  end
  -- the migrated copy was saved and has now loaded without errors: drop the old one
  if slot.check and from == ns.Build.dataVersion then
    slot.backup = nil
    slot.check = nil
  end

  Store.pieces = loaded
  cache, dirty, wholeFp = {}, migrated, nil
  for id in pairs(slot.pieces) do
    if not loaded[id] then dirty[id] = true end
  end
  return true
end

function Store.Save(slot)
  slot.pieces = slot.pieces or {}
  local from = slot.v or ns.Build.dataVersion
  if from < ns.Build.dataVersion then
    for id in pairs(Store.pieces) do dirty[id] = true end
    slot.check = true
  end
  for id in pairs(dirty) do
    if Store.pieces[id] then
      slot.pieces[id] = Util.base64((Store.encoded(id)))
    else
      slot.pieces[id] = nil
    end
  end
  for id in pairs(slot.pieces) do
    if not Store.pieces[id] then slot.pieces[id] = nil end
  end
  slot.v = ns.Build.dataVersion
  dirty = {}
end

-- Facts this addon records ----------------------------------------------------------

function Store.AddPlayed(day, name)
  local id = Pieces.id("d", day)
  local delta = Pieces.new(id)
  delta.played[Util.nameId(name)] = true
  return Store.merge(id, delta, "local")
end

-- Records every pair in a guild group with one activity.
function Store.AddGroup(day, names, act, reporter)
  local id = Pieces.id("d", day)
  local delta = Pieces.new(id)
  local ids = {}
  for i, n in ipairs(names) do ids[i] = Util.nameId(n) end
  for i = 1, #ids do
    for k = i + 1, #ids do
      if ids[i] ~= ids[k] then
        local key, a, b = Pieces.togetherKey(ids[i], ids[k], act)
        delta.together[key] = { a = a, b = b, act = act, rep = { [reporter] = true } }
      end
    end
  end
  return Store.merge(id, delta, "local")
end

function Store.AddTrade(day, giver, receiver, kind, item, count, reporter)
  local id = Pieces.id("d", day)
  local delta = Pieces.new(id)
  local g, r = Util.nameId(giver), Util.nameId(receiver)
  if g == r then return false end
  delta.trades[Pieces.tradeKey(g, r, kind, item)] =
    { g = g, r = r, kind = kind, item = item, count = count, rep = { [reporter] = true } }
  return Store.merge(id, delta, "local")
end

function Store.SetCard(account, card)
  local delta = Pieces.new("p")
  delta.cards[account] = card
  return Store.merge("p", delta, "local")
end

-- entries: list of { name, day, how }. seen is set to today for all of them.
function Store.NoteJoins(entries, today)
  local delta = Pieces.new("j")
  for _, e in ipairs(entries) do
    delta.entries[Util.nameId(e.name)] =
      { name = e.name, day = e.day or today, how = e.how, seen = today }
  end
  return Store.merge("j", delta, "local")
end

function Store.SetQuestSet(week, name, set)
  local id = Pieces.id("w", week)
  local delta = Pieces.new(id)
  delta.sets[Util.nameId(name)] = set
  return Store.merge(id, delta, "local")
end

-- Test builds only: forgets a character's reroll for the week, which the merge never
-- does. Only for a reroll no other addon has yet, or it comes back with the next sync.
function Store.ForgetReroll(week, charId)
  local id = Pieces.id("w", week)
  local p = Store.pieces[id]
  if not ns.Build.test or not p or not p.rerolls[charId] then return false end
  p.rerolls[charId] = nil
  touched(id)
  Events.Fire("PINTO_DATA_CHANGED", id, "local")
  return true
end

function Store.SetReroll(week, name, slot, time)
  local id = Pieces.id("w", week)
  local delta = Pieces.new(id)
  delta.rerolls[Util.nameId(name)] = { time = time, slot = slot }
  return Store.merge(id, delta, "local")
end

-- rec = { char, slot, time, members, inst, bosses }
function Store.AddCompletion(week, rec, reporter)
  local id = Pieces.id("w", week)
  local delta = Pieces.new(id)
  local copy = Util.copy(rec)
  copy.rep = { [reporter] = true }
  delta.done[Pieces.doneKey(rec.char, rec.slot)] = copy
  return Store.merge(id, delta, "local")
end

-- A witness confirms a completion this addon already knows about.
function Store.AddWitness(week, charId, slot, reporter)
  local id = Pieces.id("w", week)
  local piece = Store.pieces[id]
  local rec = piece and piece.done[Pieces.doneKey(charId, slot)]
  if not rec or rec.rep[reporter] then return false end
  local delta = Pieces.new(id)
  local copy = Util.copy(rec)
  copy.rep = { [reporter] = true }
  delta.done[Pieces.doneKey(charId, slot)] = copy
  return Store.merge(id, delta, "local")
end

function Store.SetHistory(day, entry)
  local delta = Pieces.new("h")
  delta.days[day] = entry
  return Store.merge("h", delta, "local")
end

function Store.SetSetting(key, value, time, author, by)
  local delta = Pieces.new("s")
  delta.entries[key] = { value = value, time = time, author = author, by = by }
  return Store.merge("s", delta, "local")
end

-- Packs and stamps must be signature-checked before they get here.
function Store.AddPack(num, data, sig, origin)
  local delta = Pieces.new("k")
  delta.packs[num] = { data = data, sig = sig }
  return Store.merge("k", delta, origin or "local")
end

function Store.SetStamp(stamp, origin)
  local delta = Pieces.new("k")
  delta.stamp = stamp
  return Store.merge("k", delta, origin or "local")
end
