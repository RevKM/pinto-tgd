-- Pinto quests: rolling a character's weekly set, the reroll, live completion checks,
-- witnesses, officer voids and what's waiting to be eaten.
--
-- Each character gets 4 quests a week plus 1 hidden spare (slot 5) for its one reroll.
-- PintoTGD_DB.eaten["<week>:<char id>:<slot>"] = true once Pinto has eaten that quest.
local ADDON, ns = ...

local Quests = {}
ns.Quests = Quests

local Store, Pieces, People, Util, Time, Events, Log, Pack, Blocks, Compat =
  ns.Store, ns.Pieces, ns.People, ns.Util, ns.Time, ns.Events, ns.Log, ns.Pack, ns.Blocks, ns.Compat

local SPARE = 5
Quests.progress = {}

local function keyOf(fullName) return People.PlayerOf(Util.nameId(fullName)) end

function Quests.Week() return Time.week(Time.day()) end

function Quests.Piece(week)
  return Store.get(Pieces.id("w", week or Quests.Week()))
end

-- The quest in a slot, after the reroll.
function Quests.Effective(wp, charId, slot)
  local set = wp and wp.sets[charId]
  if not set then return nil end
  local rr = wp.rerolls[charId]
  if rr and rr.slot == slot then return set.quests[SPARE] end
  return set.quests[slot]
end

function Quests.WorthOf(wp, charId, slot)
  local q = Quests.Effective(wp, charId, slot)
  return q and q.worth or 0
end

function Quests.Template(wp, charId, q)
  local set = wp and wp.sets[charId]
  local pack = set and Pack.Get(set.pack)
  return pack and q and pack.templates[q.t] or nil
end

-- Whether a template asks for a new member already ("@new" anywhere in its goal).
local function asksForNew(t)
  local function scan(v)
    if v == "@new" then return true end
    if type(v) == "table" then
      for _, x in pairs(v) do
        if scan(x) then return true end
      end
    end
    return false
  end
  return scan(t.goal)
end

-- The surprise haunch: a finished quest that names nobody earns one haunch more than it
-- showed when a guildie who's new to the guild was part of the group that met it. Never
-- on a quest that names a guildie or asks for a new member: those already count it. Worked
-- out from the completion's group and the join dates, so every addon agrees.
function Quests.BonusOf(wp, rec)
  if not rec or not rec.members or #rec.members == 0 then return 0 end
  local q = Quests.Effective(wp, rec.char, rec.slot)
  local t = Quests.Template(wp, rec.char, q)
  if not t or #t.names > 0 or asksForNew(t) then return 0 end
  local day = Time.day(rec.time)
  for _, id in ipairs(rec.members) do
    if People.IsNew(People.PlayerOf(id), day) then return 1 end
  end
  return 0
end

-- What a finished quest fed Pinto: its worth and the bonus.
function Quests.EarnedOf(wp, rec)
  return Quests.WorthOf(wp, rec.char, rec.slot) + Quests.BonusOf(wp, rec)
end

-- Officer actions ----------------------------------------------------------------------

local function officerEntry(key)
  local s = Store.get("s")
  local e = s and s.entries[key]
  if e and e.value == "1" and ns.Roster.IsOfficer(e.by) then return e end
end

function Quests.IsVoided(charId, week)
  local pl = People.PlayerOf(charId)
  return officerEntry(string.format("void:%.0f:%d", charId, week)) ~= nil
    or officerEntry("voidp:" .. pl .. ":" .. string.format("%d", week)) ~= nil
    or Quests.IsExcluded(pl)
end

function Quests.IsExcluded(playerKey)
  return officerEntry("excl:" .. playerKey) ~= nil
end

-- Context for blocks ---------------------------------------------------------------------

function Quests.LowGear(today)
  local gs, list = {}, {}
  for name, m in pairs(ns.Roster.members) do
    if m.online or (m.lastOnlineDays or 99) <= 7 then
      local id = Util.nameId(name)
      local k = People.PlayerOf(id)
      local pl = People.View().players[k]
      local ch = pl and pl.chars[id]
      local g
      if ch and ch.slots then
        g = ns.Formula.GearProgress(ch)
      else
        local seen = PintoTGD_DB.inspect and PintoTGD_DB.inspect[name]
        if seen then g = ns.Formula.GearProgress({ slots = seen.slots, level = m.level }) end
      end
      if g then
        gs[#gs + 1] = g
        list[#list + 1] = { k = k, g = g }
      end
    end
  end
  local low = {}
  if #gs < 3 then return low end
  local cut = Util.percentile(gs, 1 / 3)
  for _, e in ipairs(list) do
    if e.g <= cut then low[e.k] = true end
  end
  return low
end

function Quests.Context(me, week)
  local today = Time.day()
  local ctx = {
    me = me, meKey = keyOf(me), week = week, today = today,
    level = UnitLevel("player") or 1, skills = ns.Player.Skills(),
    log = Log.For(me, week), named = {}, vars = {},
  }
  local low, ties, grouped, ever, bridging, pairs_
  ctx.low = function()
    if not low then low = Quests.LowGear(today) end
    return low
  end
  ctx.tie = function(k)
    if not ties then ties = ns.Formula.Ties(today) end
    local a, b = ctx.meKey, k
    if Util.byteLess(b, a) then a, b = b, a end
    local e = ties[a .. "|" .. b]
    return e and e.w or 0
  end
  ctx.groupedWeek = function()
    if not grouped then
      grouped = {}
      for d = Time.weekStartDay(week), today do
        local act = ns.Formula.Day(d)
        local with = act and act.grouped[ctx.meKey]
        for k in pairs(with or {}) do grouped[k] = true end
      end
      for _, s in ipairs(ctx.log.groups) do
        for name in pairs(s.members) do grouped[keyOf(name)] = true end
      end
    end
    return grouped
  end
  ctx.everGrouped = function(a, b)
    if not ever then
      ever = {}
      for d = today - 99, today do
        local act = ns.Formula.Day(d)
        for x, with in pairs(act and act.grouped or {}) do
          for y in pairs(with) do ever[x .. "|" .. y] = true end
        end
      end
    end
    return ever[a .. "|" .. b] == true
  end
  ctx.bridging = function()
    if not bridging then bridging = Quests.BridgingRates(today) end
    return bridging
  end
  ctx.pairs = function()
    if not pairs_ then pairs_ = Quests.PairAsks(week) end
    return pairs_
  end
  return ctx
end

-- Bridging rate: bridge days ÷ play days over the last 4 weeks, once a player has at
-- least 4 play days. Quests use it; H doesn't.
function Quests.BridgingRates(today)
  local ties = ns.Formula.Ties(today)
  local strongest = {}
  for _, e in pairs(ties) do
    for _, pair in ipairs({ { e.a, e.b }, { e.b, e.a } }) do
      local list = strongest[pair[1]] or {}
      list[#list + 1] = { other = pair[2], w = e.w }
      strongest[pair[1]] = list
    end
  end
  local crews = {}
  for k, list in pairs(strongest) do
    table.sort(list, function(x, y)
      if x.w ~= y.w then return x.w > y.w end
      return Util.byteLess(x.other, y.other)
    end)
    local crew = {}
    for i = 1, math.min(4, #list) do crew[list[i].other] = true end
    crews[k] = crew
  end
  local played, bridged = {}, {}
  for d = today - 28, today - 1 do
    local act = ns.Formula.Day(d)
    if act then
      for k in pairs(act.played) do played[k] = (played[k] or 0) + 1 end
      for k, with in pairs(act.bridge) do
        local crew = crews[k] or {}
        for other in pairs(with) do
          if not crew[other] then
            bridged[k] = (bridged[k] or 0) + 1
            break
          end
        end
      end
    end
  end
  local rates, values = {}, {}
  for k, n in pairs(played) do
    if n >= 4 and People.IsAddonPlayer(k) then
      rates[k] = (bridged[k] or 0) / n
      values[#values + 1] = rates[k]
    end
  end
  if #values > 0 then rates.median = Util.median(values) end
  return rates
end

-- Guildies whose quest this week asks them to run a dungeon with one of my characters.
function Quests.PairAsks(week)
  local asks = {}
  local wp = Quests.Piece(week)
  if not wp then return asks end
  local mine = {}
  local view = People.View()
  local myKey = keyOf(ns.me)
  for id in pairs((view.players[myKey] or {}).chars or {}) do mine[id] = true end
  for charId, set in pairs(wp.sets) do
    local holder = People.PlayerOf(charId)
    if holder ~= myKey then
      for slot = 1, 4 do
        local q = Quests.Effective(wp, charId, slot)
        local t = Quests.Template(wp, charId, q)
        if t then
          for _, b in ipairs(t.goal) do
            if b[1] == "dungeon" and type(b[2]) == "table" and b[2].with == "X" and mine[q.named[1]] then
              asks[holder] = People.Name(charId) or true
            end
          end
        end
      end
    end
  end
  return asks
end

-- Rolling ----------------------------------------------------------------------------------

local function shuffled(list)
  local out = {}
  for i, v in ipairs(list) do out[i] = v end
  for i = #out, 2, -1 do
    local j = math.random(i)
    out[i], out[j] = out[j], out[i]
  end
  return out
end

local function eligible(pack, setName, ctx)
  local list = {}
  for _, id in ipairs(pack.ids) do
    local t = pack.templates[id]
    if t.supported and t.set == setName then
      local ok = true
      for _, need in ipairs(t.needs) do
        if not Blocks.CheckNeed(ctx, need) then
          ok = false
          break
        end
      end
      if ok then list[#list + 1] = t end
    end
  end
  return list
end

local function hoursOverlap(myMask, k)
  local pl = People.View().players[k]
  if not pl or not pl.addon or not myMask then return true end
  for _, card in ipairs(pl.cards or {}) do
    local a, b = myMask, card.hours or 0
    for _ = 0, 23 do
      if a % 2 == 1 and b % 2 == 1 then return true end
      a, b = math.floor(a / 2), math.floor(b / 2)
    end
  end
  return false
end

-- Names a template's roles. Prefers guildies few quests name this week, strangers, and
-- guildies who play at the same hours. Returns the named character ids, or nil.
local function nameRoles(t, ctx, used, counts, myMask)
  ctx.named = {}
  local ids = {}
  for _, role in ipairs(t.names) do
    local best, bestScore
    for name, m in pairs(ns.Roster.members) do
      local k = keyOf(name)
      if k ~= ctx.meKey and not used[k] and not Quests.IsExcluded(k) then
        local taken = false
        for _, other in pairs(ctx.named) do
          if other == k then taken = true end
        end
        if not taken then
          local c = { name = name, key = k, member = m }
          local ok = true
          for _, rule in ipairs(role.rules or {}) do
            if not Blocks.CheckRule(ctx, rule, c) then
              ok = false
              break
            end
          end
          if ok then
            local n = counts[k] or 0
            local score = n * 10 + (n >= 3 and 100 or 0) + ctx.tie(k) * 3
              + (hoursOverlap(myMask, k) and 0 or 2) + math.random()
            if not bestScore or score < bestScore then best, bestScore = c, score end
          end
        end
      end
    end
    if not best then return nil end
    ctx.named[role.role] = best.key
    ids[#ids + 1] = Util.nameId(best.name)
  end
  return ids
end

function Quests.NamedCounts(week)
  local counts = {}
  local wp = Quests.Piece(week)
  for _, set in pairs(wp and wp.sets or {}) do
    for _, q in ipairs(set.quests) do
      for _, id in ipairs(q.named) do
        local k = People.PlayerOf(id)
        counts[k] = (counts[k] or 0) + 1
      end
    end
  end
  return counts
end

-- The calibration set runs while the calibration does, and on a fresh install that
-- couldn't sync.
function Quests.UseCalibrationSet()
  if ns.Health.InCalibration() then return true end
  local h = Store.get("h")
  return ns.Protocol.state == "alone" and (not h or not next(h.days))
end

local function isPair(t)
  for _, r in ipairs(t.names[1] and t.names[1].rules or {}) do
    if r[1] == "pair" then return true end
  end
  return false
end

-- How many of the 4 quests name a guildie, and which: 1 or 2, half the time each, so being
-- named stays special. A wanted pair quest goes in slot 1, and it names its asker.
local function namedPlan(pairFirst)
  local k = math.random(2)
  local planned, free = {}, {}
  for s = pairFirst and 2 or 1, 4 do free[#free + 1] = s end
  local left = k
  if pairFirst then
    planned[1] = true
    left = left - 1
  end
  for _ = 1, left do planned[table.remove(free, math.random(#free))] = true end
  return k, planned
end

-- The order the slots are rolled in: set 2's first, since its named quests need a guild
-- crafter and so are the likeliest to find nobody to name, and a planned slot that can't
-- name anyone hands its turn to a slot rolled after it. The spare comes last.
local ROLL_ORDER = { 4, 1, 2, 3, 5 }

-- Whether the i-th slot rolled should name a guildie, given how many rolled before it do.
-- The spare names one only when just 1 of the 4 does, so a reroll keeps it at 1 or 2.
local function wantsNamed(i, k, planned, named)
  local slot = ROLL_ORDER[i]
  if slot == 5 then return named == 1 end
  if named >= k then return false end
  if planned[slot] then return true end
  local later = 0
  for j = i + 1, 4 do
    if planned[ROLL_ORDER[j]] then later = later + 1 end
  end
  return k - named > later
end

function Quests.Roll(week)
  local num = Pack.Newest()
  local pack = num and Pack.Get(num)
  if not pack then return nil end
  local ctx = Quests.Context(ns.me, week)
  local counts = Quests.NamedCounts(week)
  local myCard = Store.get("p") and Store.get("p").cards[ns.Player.AccountId()]
  local myMask = myCard and myCard.hours
  -- guildies my other characters already named this week count as used where possible
  local used = {}
  local plan
  if Quests.UseCalibrationSet() then
    plan = { "calibration", "calibration", "calibration", "calibration", "calibration" }
  else
    plan = { 1, 1, 1, 2, 1 }
  end
  local pairsWanted = next(ctx.pairs()) ~= nil and plan[1] == 1
  local k, planned = namedPlan(pairsWanted)
  local named = 0
  local quests, usedTemplates = {}, {}
  for i, slot in ipairs(ROLL_ORDER) do
    local setName = plan[slot]
    local pool = shuffled(eligible(pack, setName, ctx))
    if setName == 2 and #pool == 0 then pool = shuffled(eligible(pack, 1, ctx)) end
    -- the kind of quest the slot wants first (a wanted pair quest before anything), and the
    -- other kind when none of those can be rolled
    local want = wantsNamed(i, k, planned, named)
    local tiers = { {}, {}, {} }
    for _, t in ipairs(pool) do
      local tier = ((#t.names > 0) == want) and 2 or 3
      if slot == 1 and pairsWanted and isPair(t) then tier = 1 end
      local list = tiers[tier]
      list[#list + 1] = t
    end
    pool = {}
    for _, list in ipairs(tiers) do
      for _, t in ipairs(list) do pool[#pool + 1] = t end
    end
    local picked
    for _, t in ipairs(pool) do
      if not usedTemplates[t.id] then
        local ids = nameRoles(t, ctx, used, counts, myMask)
        if ids then
          picked = { t = t.id, worth = t.worth, named = ids }
          usedTemplates[t.id] = true
          for _, id in ipairs(ids) do used[People.PlayerOf(id)] = true end
          break
        end
      end
    end
    if not picked then return nil end
    quests[slot] = picked
    if #picked.named > 0 then named = named + 1 end
  end
  return { created = Time.now(), author = ns.Player.AccountId(), pack = pack.num, quests = quests }
end

-- Rolls this character's quests for the week if nobody has yet.
-- Test builds: this account's quests for the week follow the newest quest pack, so a new
-- pack's worth and wording reach quests that are already rolled. Each slot keeps its
-- quest, its named guildies and its progress, and the week's reroll comes back, since the
-- quests changed under the player. The upgraded set says it was rolled a second earlier,
-- so the merge, which keeps the earliest set, takes it on every addon.
function Quests.UpgradeToNewestPack(week)
  if not ns.Build.test then return false end
  local num = Pack.Newest()
  local pack = num and Pack.Get(num)
  local wp = Quests.Piece(week)
  if not pack or not wp then return false end
  local acct = ns.Player.AccountId()
  local upgrades = {}
  for charId, set in pairs(wp.sets) do
    if set.author == acct and set.pack and set.pack < num then
      local quests = {}
      for i, q in ipairs(set.quests) do
        local t = pack.templates[q.t]
        if not t then
          quests = nil
          break
        end
        quests[i] = { t = q.t, worth = t.worth, named = Util.copy(q.named or {}) }
      end
      if quests then
        upgrades[charId] = { created = math.max(0, set.created - 1), author = set.author, pack = num, quests = quests }
      end
    end
  end
  if not next(upgrades) then return false end
  local id = Pieces.id("w", week)
  local delta = Pieces.new(id)
  for charId, set in pairs(upgrades) do delta.sets[charId] = set end
  Store.merge(id, delta, "local")
  -- the reroll comes back only where the upgraded set took
  local any = false
  for charId in pairs(upgrades) do
    local now = Quests.Piece(week).sets[charId]
    if now and now.pack == num then
      Store.ForgetReroll(week, charId)
      any = true
    end
  end
  if any then Quests.progress = {} end
  return any
end

-- Test tools: gives this character its weekly reroll back, and the quest it swapped away.
function Quests.TestGiveRerollBack()
  if not ns.Build.testTools or not ns.me then return false end
  if not Store.ForgetReroll(Quests.Week(), Util.nameId(ns.me)) then return false end
  Quests.progress = {}
  Events.Fire("PINTO_QUESTS")
  return true
end

local previews = {}   -- test tools: slot -> { entry = what's waiting to be eaten, eaten = true once eaten }

-- Test tools: rolls this character's quests for the week again, the way Monday's refresh
-- does. The new set says it was rolled a second before the old one, so the merge keeps it
-- on every addon, and the week's reroll comes back. Returns true, or false and why not:
-- "none" (nothing rolled yet), "done" (a quest of the week is finished: those stay put) or
-- "roll" (nothing to roll from).
function Quests.TestRefresh()
  if not ns.Build.testTools or not ns.me or ns.disabled or not Time.isLive() then return false, "none" end
  local week = Quests.Week()
  local wp = Quests.Piece(week)
  local myId = Util.nameId(ns.me)
  local old = wp and wp.sets[myId]
  if not old then return false, "none" end
  for slot = 1, 4 do
    if wp.done[Pieces.doneKey(myId, slot)] then return false, "done" end
  end
  local set = Quests.Roll(week)
  if not set then return false, "roll" end
  set.created = math.max(0, old.created - 1)
  Store.SetQuestSet(week, ns.me, set)
  local now = Quests.Piece(week).sets[myId]
  if not now or now.created ~= set.created then return false, "roll" end
  Store.ForgetReroll(week, myId)
  Quests.progress = {}
  previews = {}
  Events.Fire("PINTO_QUESTS")
  return true
end

-- Test tools: finished quests that are only previews. They're kept in memory, never saved
-- or shared, so finishing a quest and Pinto eating it can be watched as often as needed.
-- TestFinish finishes one of this character's quests that way: the given slot, or the first
-- that isn't finished. bonus: it earned the new guildie bonus. Returns the quest, or nil.
function Quests.TestFinish(slot, bonus)
  if not ns.Build.testTools or not ns.me then return nil end
  local week = Quests.Week()
  local pick
  for _, q in ipairs(Quests.Mine()) do
    if (not slot or q.slot == slot) and not q.done and not previews[q.slot] then
      pick = q
      break
    end
  end
  if not pick then return nil end
  previews[pick.slot] = { entry = { key = string.format("preview:%d:%d", week, pick.slot), week = week,
    char = Util.nameId(ns.me), slot = pick.slot, time = Time.now(), worth = pick.q.worth or 1,
    bonus = bonus and 1 or 0, text = pick.text, mine = true, preview = true } }
  Events.Fire("PINTO_QUEST_DONE", pick.slot, pick.q, pick.t)
  Events.Fire("PINTO_QUESTS")
  return pick
end

-- A slot's preview: { entry, eaten }, or nil.
function Quests.PreviewOf(slot) return previews[slot] end

function Quests.TestClearPreviews()
  if not next(previews) then return false end
  previews = {}
  Events.Fire("PINTO_QUESTS")
  Events.Fire("PINTO_EATEN")
  return true
end

function Quests.Ensure()
  if ns.disabled or not ns.me or not Time.isLive() then return end
  local week = Quests.Week()
  if ns.Build.test and Quests.UpgradeToNewestPack(week) then Events.Fire("PINTO_QUESTS") end
  local wp = Quests.Piece(week)
  if wp and wp.sets[Util.nameId(ns.me)] then return end
  local set = Quests.Roll(week)
  if set then
    Store.SetQuestSet(week, ns.me, set)
    Events.Fire("PINTO_QUESTS")
  end
end

function Quests.CanReroll()
  local wp = Quests.Piece()
  local id = Util.nameId(ns.me)
  return wp ~= nil and wp.sets[id] ~= nil and wp.rerolls[id] == nil
end

function Quests.Reroll(slot)
  if not Quests.CanReroll() or slot < 1 or slot > 4 then return false end
  local wp = Quests.Piece()
  if wp.done[Pieces.doneKey(Util.nameId(ns.me), slot)] then return false end
  Store.SetReroll(Quests.Week(), ns.me, slot, Time.now())
  Quests.progress = {}
  Events.Fire("PINTO_QUESTS")
  return true
end

-- Text with names filled in.
function Quests.Text(t, q)
  local text = t.text
  for i, role in ipairs(t.names) do
    local id = q.named[i]
    local name = id and People.Name(id)
    local short = name and Compat.ShortName(name) or "a guildie"
    text = text:gsub("{" .. role.role .. "}", (short:gsub("%%", "%%%%")))
  end
  return text
end

-- This character's visible quests: { slot, q, t, text, done, progress }.
function Quests.Mine()
  local list = {}
  local wp = Quests.Piece()
  local id = ns.me and Util.nameId(ns.me)
  if not wp or not id or not wp.sets[id] then return list end
  for slot = 1, 4 do
    local q = Quests.Effective(wp, id, slot)
    local t = Quests.Template(wp, id, q)
    if q then
      list[#list + 1] = { slot = slot, q = q, t = t, text = t and Quests.Text(t, q) or "A quest from a newer version of Pinto.",
        done = wp.done[Pieces.doneKey(id, slot)] ~= nil, progress = Quests.progress[slot] }
    end
  end
  return list
end

-- Completion ---------------------------------------------------------------------------------

function Quests.Check()
  if ns.disabled or not ns.me or not Time.isLive() then return end
  local week = Quests.Week()
  local wp = Quests.Piece(week)
  local myId = Util.nameId(ns.me)
  if not wp or not wp.sets[myId] then return end
  local ctx = Quests.Context(ns.me, week)
  for slot = 1, 4 do
    local q = Quests.Effective(wp, myId, slot)
    local t = Quests.Template(wp, myId, q)
    if t and t.supported then
      ctx.named = {}
      for i, role in ipairs(t.names) do
        if q.named[i] then ctx.named[role.role] = People.PlayerOf(q.named[i]) end
      end
      local done, progress, ev = Blocks.Evaluate(t, ctx)
      Quests.progress[slot] = progress
      local key = Pieces.doneKey(myId, slot)
      if done and not wp.done[key] then
        local members = {}
        local from = ev and ((ev.final and next(ev.finalMembers or {})) and ev.finalMembers or ev.members) or {}
        for name in pairs(from) do
          if #members < 40 then members[#members + 1] = Util.nameId(name) end
        end
        Store.AddCompletion(week, { char = myId, slot = slot, time = Time.now(), members = members,
          inst = ev and ev.inst or 0, bosses = ev and math.min(255, ev.bosses or 0) or 0 }, ns.Player.AccountId())
        Events.Fire("PINTO_QUEST_DONE", slot, q, t)
      end
    end
  end
  Events.Fire("PINTO_QUESTS")
end

local checkPending = false
local function scheduleCheck()
  if checkPending then return end
  checkPending = true
  ns.After(2, function()
    checkPending = false
    Quests.Check()
  end)
end

-- Witnesses: a completion shared live by someone in this player's group gets confirmed.
local seenDone = {}
local function confirm(id, origin)
  if origin ~= "remote" or not id or id:sub(1, 1) ~= "w" or not ns.me then return end
  local wp = Store.get(id)
  if not wp then return end
  local myId = Util.nameId(ns.me)
  local acct = ns.Player.AccountId()
  local session = Log.OpenSession()
  for key, rec in pairs(wp.done) do
    if not seenDone[key] then
      seenDone[key] = true
      local listed = false
      for _, m in ipairs(rec.members) do
        if m == myId then listed = true end
      end
      local who = People.Name(rec.char)
      if listed and who and not rec.rep[acct] and Time.now() - rec.time < 3600 and session
        and (session.members[who] or session.present[who]) then
        Store.AddWitness(wp.num, rec.char, rec.slot, acct)
      end
    end
  end
end

-- Eating -------------------------------------------------------------------------------------

local function eatenKey(week, charId, slot)
  return string.format("%d:%.0f:%d", week, charId, slot)
end

-- Finished quests of this account's characters that Pinto hasn't eaten yet, oldest first,
-- with a test build's previews (entry.preview).
function Quests.Uneaten()
  local list = {}
  PintoTGD_DB.eaten = PintoTGD_DB.eaten or {}
  local week = Quests.Week()
  for w = week - 1, week do
    local wp = Quests.Piece(w)
    if wp then
      for name, c in pairs(PintoTGD_DB.chars or {}) do
        if c.guild == Store.slotKey() then
          local id = Util.nameId(name)
          for slot = 1, 4 do
            local rec = wp.done[Pieces.doneKey(id, slot)]
            local key = eatenKey(w, id, slot)
            if rec and not PintoTGD_DB.eaten[key] and not Quests.IsVoided(id, w) then
              local q = Quests.Effective(wp, id, slot)
              local t = Quests.Template(wp, id, q)
              list[#list + 1] = { key = key, week = w, char = id, slot = slot, time = rec.time,
                worth = q and q.worth or 1, bonus = Quests.BonusOf(wp, rec), text = t and Quests.Text(t, q) or "", mine = name == ns.me }
            end
          end
        end
      end
    end
  end
  for _, p in pairs(previews) do
    if not p.eaten then list[#list + 1] = p.entry end
  end
  table.sort(list, function(a, b)
    if a.time ~= b.time then return a.time < b.time end
    return Util.byteLess(a.key, b.key)
  end)
  return list
end

-- Every haunch the whole guild has earned since go-live: the worth of each finished quest,
-- leaving out voided weeks and players the officers left out. While Pinto sleeps, that's
-- the pile waiting for him.
function Quests.GuildHaunches()
  local total = 0
  for w = Time.week(Time.goLiveDay()), Quests.Week() do
    local wp = Quests.Piece(w)
    if wp then
      for _, rec in pairs(wp.done) do
        if rec.char and rec.slot and not Quests.IsVoided(rec.char, w) then
          total = total + Quests.EarnedOf(wp, rec)
        end
      end
    end
  end
  return total
end

function Quests.MarkEaten(entry)
  if entry.preview then
    local p = previews[entry.slot]
    if p and p.entry.key == entry.key then p.eaten = true end
  else
    PintoTGD_DB.eaten = PintoTGD_DB.eaten or {}
    PintoTGD_DB.eaten[entry.key] = true
  end
  Events.Fire("PINTO_EATEN")
end

function Quests.PruneEaten()
  local week = Quests.Week()
  for key in pairs(PintoTGD_DB.eaten or {}) do
    local w = tonumber(key:match("^(%d+):"))
    if not w or w < week - 2 then PintoTGD_DB.eaten[key] = nil end
  end
end

function Quests.Init()
  local lastWeek = Quests.Week()
  Events.On("PINTO_SYNC_STATE", function(state)
    if state == "synced" or state == "alone" then ns.After(3, Quests.Ensure) end
  end)
  ns.After(60, Quests.Ensure)
  ns.Every(60, function()
    local week = Quests.Week()
    if week ~= lastWeek then
      lastWeek = week
      Quests.progress = {}
      previews = {}
      ns.After(math.random() * 30, Quests.Ensure)
    end
  end)
  Events.On("PINTO_LOG", scheduleCheck)
  Events.On("PINTO_DATA_CHANGED", function(id, origin)
    if id and (id:sub(1, 1) == "w" or id:sub(1, 1) == "d") then scheduleCheck() end
    confirm(id, origin)
  end)
  Quests.PruneEaten()
end
