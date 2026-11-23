-- The blocks quest templates are built from. Like a migration contract, a released block
-- never changes meaning; new behavior gets a new block. A template that uses a block this
-- version doesn't know is skipped.
--
-- Goal blocks check the character's own activity log (Track/Log.lua) and synced facts.
-- Need blocks say who can get a quest. Rules say who a quest can name as X or Y.
-- Roles: "X" and "Y" are named guildies; "@new" any new member; "@low" any low-gear
-- member; any other "@name" is the set of guildies an earlier block bound with bind.
local ADDON, ns = ...

local Blocks = {}
ns.Blocks = Blocks

local Store, Pieces, People, Util, Time, Compat = ns.Store, ns.Pieces, ns.People, ns.Util, ns.Time, ns.Compat
local ACT, TRADE = Pieces.ACT, Pieces.TRADE

local CRAFTING = { [1] = true, [2] = true, [3] = true, [4] = true, [6] = true, [9] = true }
local GATHERING = { [5] = true, [7] = true, [8] = true }
local USES_MATERIALS = { [1] = true, [2] = true, [4] = true, [6] = true, [9] = true }
local PROF_ID = {}
for id, name in ipairs(Pieces.PROFESSIONS) do PROF_ID[name] = id end

local ACT_CODE = { other = ACT.other, quest = ACT.quest, bg = ACT.bg, raid = ACT.raid, dungeon = ACT.dungeon }
local KIND_CODE = { crafted = TRADE.crafted, enchant = TRADE.enchant, materials = TRADE.materials, recipe = TRADE.recipe }

-- Helpers ------------------------------------------------------------------------------

local function keyOf(fullName)
  return People.PlayerOf(Util.nameId(fullName))
end

local function actSet(list)
  if type(list) ~= "table" then return nil end
  local s = {}
  for _, name in ipairs(list) do
    local code = ACT_CODE[name]
    if code then s[code] = true end
  end
  return s
end

-- Does player key k fill role spec in this context?
local function fills(ctx, spec, k)
  if k == ctx.meKey then return false end
  if spec == nil then return true end
  if spec == "X" or spec == "Y" then return ctx.named[spec] == k end
  if spec == "@new" then return People.IsNew(k, ctx.today) end
  if spec == "@low" then return ctx.low()[k] == true end
  local var = ctx.vars[spec]
  return var ~= nil and var[k] == true
end

local function keysOf(names)
  local s = {}
  for name in pairs(names or {}) do s[keyOf(name)] = true end
  return s
end

local function isRun(s)
  if s.act ~= ACT.dungeon then return false end
  return s.final or (s.bosses >= 2 and (s.last - s.start) >= 1200)
end

local function runMembers(s)
  if s.final and next(s.finalMembers) then return s.finalMembers end
  return s.members
end

-- Goals: each returns done, have, need, evidence ---------------------------------------
-- Evidence is the group that met the goal: a group session, or { members = {name=true} }
-- with the guildies who took part. The completion keeps its members (for witnesses and
-- the new-member bonus).

Blocks.goals = {}
local G = Blocks.goals

local function count(set)
  local n = 0
  for _ in pairs(set) do n = n + 1 end
  return n
end

local function addAll(into, set)
  for name in pairs(set or {}) do into[name] = true end
end

-- Quest turn-ins with guildies in the group (guildies: how many at least, 1 by default);
-- group: only quests the game marks for several players.
G.turnins = function(ctx, p)
  local n, members = 0, {}
  local least = p.guildies or 1
  for _, t in ipairs(ctx.log.turnins) do
    if count(t.guildies) >= least and (not p.group or t.group) then
      n = n + 1
      addAll(members, t.guildies)
    end
  end
  local need = p.count or 1
  return n >= need, math.min(n, need), need, n > 0 and { members = members } or nil
end

G.levelup = function(ctx)
  for _, l in ipairs(ctx.log.levels) do
    if next(l.guildies) then return true, 1, 1, { members = l.guildies } end
  end
  return false, 0, 1
end

G.group = function(ctx, p)
  local acts = actSet(p.act)
  local with = p.with
  local need = p.need or 1
  local best, seen, evidence = 0, {}, nil
  for _, s in ipairs(ctx.log.groups) do
    if next(s.members) and (not acts or acts[s.act]) then
      local keys = keysOf(s.members)
      if type(with) == "table" then
        local all = true
        for _, role in ipairs(with) do
          local found = false
          for k in pairs(keys) do
            if fills(ctx, role, k) then found = true break end
          end
          if not found then all = false break end
        end
        if all then return true, 1, 1, s end
      else
        local n = 0
        for k in pairs(keys) do
          if fills(ctx, with, k) then
            n = n + 1
            seen[k] = true
          end
        end
        if n > best then
          best = n
          evidence = s
        end
      end
    end
  end
  if type(with) == "table" then return false, 0, 1 end
  if p.each then
    local n = 0
    for _ in pairs(seen) do n = n + 1 end
    return n >= need, math.min(n, need), need, evidence
  end
  return best >= need, math.min(best, need), need, evidence
end

G.dungeon = function(ctx, p)
  local runs, evidence = 0, nil
  local needRuns = p.count or 1
  for _, s in ipairs(ctx.log.groups) do
    if isRun(s) then
      local members = runMembers(s)
      local keys = keysOf(members)
      local total, matching = 0, 0
      for k in pairs(keys) do
        if k ~= ctx.meKey then
          total = total + 1
          if p.with and fills(ctx, p.with, k) then matching = matching + 1 end
        end
      end
      local ok = total >= (p.guildies or 1)
      if p.with then ok = ok and matching >= (p.need or 1) end
      if ok and p.bandaged then
        local n = 0
        for name in pairs(s.bandaged or {}) do
          if members[name] then n = n + 1 end
        end
        ok = n >= p.bandaged
      end
      if ok and p.gave == "potion" then
        for k in pairs(keys) do
          if k ~= ctx.meKey then
            local gave = false
            for _, tr in ipairs(ctx.log.trades) do
              if tr.dir == "out" and tr.day == s.day and tr.tags and tr.tags.potion and keyOf(tr.who) == k then
                gave = true
                break
              end
            end
            if not gave then ok = false break end
          end
        end
      end
      if ok then
        runs = runs + 1
        evidence = s
      end
    end
  end
  return runs >= needRuns, math.min(runs, needRuns), needRuns, evidence
end

G.distinct = function(ctx, p)
  local acts = actSet(p.act)
  local seen, n, members = {}, 0, {}
  for _, s in ipairs(ctx.log.groups) do
    if not acts or acts[s.act] then
      for name in pairs(s.members) do
        local k = keyOf(name)
        if k ~= ctx.meKey and not seen[k] then
          seen[k] = true
          n = n + 1
          members[name] = true
        end
      end
    end
  end
  return n >= p.count, math.min(n, p.count), p.count, n > 0 and { members = members } or nil
end

G.days = function(ctx, p)
  local acts = actSet(p.act)
  local days, n, members = {}, 0, {}
  for _, s in ipairs(ctx.log.groups) do
    if next(s.members) and (not acts or acts[s.act]) and not days[s.day] then
      days[s.day] = true
      n = n + 1
      addAll(members, s.members)
    end
  end
  return n >= p.count, math.min(n, p.count), p.count, n > 0 and { members = members } or nil
end

G.gather = function(ctx, p)
  local kinds = {}
  for _, k in ipairs(p.kinds or {}) do kinds[k] = true end
  local n, members = 0, {}
  for _, g in ipairs(ctx.log.gathers) do
    if kinds[g.kind] and next(g.guildies) then
      local ok = true
      if p.with then
        ok = false
        for name in pairs(g.guildies) do
          if fills(ctx, p.with, keyOf(name)) then ok = true break end
        end
      end
      if ok then
        n = n + g.count
        addAll(members, g.guildies)
      end
    end
  end
  return n >= p.count, math.min(n, p.count), p.count, n > 0 and { members = members } or nil
end

-- What a player wears in the slot an item goes in, if anyone knows.
local SLOT_OF = { INVTYPE_HEAD = { 1 }, INVTYPE_NECK = { 2 }, INVTYPE_SHOULDER = { 3 }, INVTYPE_CLOAK = { 4 },
  INVTYPE_CHEST = { 5 }, INVTYPE_ROBE = { 5 }, INVTYPE_WRIST = { 6 }, INVTYPE_HAND = { 7 }, INVTYPE_WAIST = { 8 },
  INVTYPE_LEGS = { 9 }, INVTYPE_FEET = { 10 }, INVTYPE_FINGER = { 11, 12 }, INVTYPE_TRINKET = { 13, 14 },
  INVTYPE_WEAPON = { 15, 16 }, INVTYPE_WEAPONMAINHAND = { 15 }, INVTYPE_2HWEAPON = { 15 }, INVTYPE_WEAPONOFFHAND = { 16 },
  INVTYPE_SHIELD = { 16 }, INVTYPE_HOLDABLE = { 16 }, INVTYPE_RANGED = { 17 }, INVTYPE_RANGEDRIGHT = { 17 },
  INVTYPE_THROWN = { 17 }, INVTYPE_RELIC = { 17 } }

function Blocks.WornLevel(fullName, equipLoc)
  local slots = SLOT_OF[equipLoc]
  if not slots then return nil end
  local id = Util.nameId(fullName)
  local k = People.PlayerOf(id)
  local pl = People.View().players[k]
  local ch = pl and pl.chars[id]
  local gear = ch and ch.slots
  if not gear then
    local seen = PintoTGD_DB.inspect and PintoTGD_DB.inspect[fullName]
    gear = seen and seen.slots
  end
  if not gear then return nil end
  local low
  for _, s in ipairs(slots) do
    local v = gear[s] or 0
    if not low or v < low then low = v end
  end
  return low
end

G.give = function(ctx, p)
  local kind = KIND_CODE[p.kind]
  local who, count = {}, 0
  for _, tr in ipairs(ctx.log.trades) do
    if tr.dir == "out" and (not kind or tr.kind == kind) then
      local ok = true
      for _, tag in ipairs(p.tags or {}) do
        if not (tr.tags and tr.tags[tag]) then ok = false end
      end
      local k = keyOf(tr.who)
      if ok and p.to then ok = fills(ctx, p.to, k) end
      if ok and p.upgrade then
        ok = tr.tags and tr.tags.gear
        if ok then
          local worn = Blocks.WornLevel(tr.who, tr.tags.equipLoc)
          ok = worn == nil or (tr.tags.ilvl or 0) > worn
        end
      end
      if ok then
        who[k] = true
        count = count + (tr.count or 1)
      end
    end
  end
  local people = 0
  for _ in pairs(who) do people = people + 1 end
  if p.bind then ctx.vars[p.bind] = who end
  if p.distinct then return people >= p.distinct, math.min(people, p.distinct), p.distinct end
  if p.count then return count >= p.count, math.min(count, p.count), p.count end
  return people >= 1, math.min(people, 1), 1
end

G.receive = function(ctx, p)
  local kind = KIND_CODE[p.kind]
  local meId = Util.nameId(ctx.me)
  local first = Time.weekStartDay(ctx.week)
  for d = first, math.min(first + 6, ctx.today) do
    local piece = Store.get(Pieces.id("d", d))
    if piece then
      for _, rec in pairs(piece.trades) do
        if rec.r == meId and (not kind or rec.kind == kind) and fills(ctx, p.from, People.PlayerOf(rec.g)) then
          return true, 1, 1
        end
      end
    end
  end
  return false, 0, 1
end

-- Needs: who can get a quest ----------------------------------------------------------

Blocks.needs = {}
local N = Blocks.needs

N.level = function(ctx, min) return ctx.level >= min end
N.max_level = function(ctx, max) return ctx.level <= max end
N.established = function(ctx) return not People.IsNew(ctx.meKey, ctx.today) end
N.new = function(ctx) return People.IsNew(ctx.meKey, ctx.today) end
N.crafter = function(ctx)
  for id in pairs(CRAFTING) do if ctx.skills[id] then return true end end
  return false
end
N.gatherer = function(ctx)
  for id in pairs(GATHERING) do if ctx.skills[id] then return true end end
  return false
end
N.makes = function(ctx)
  return N.crafter(ctx) or (ctx.skills.cook or 0) > 0 or (ctx.skills.aid or 0) > 0
end
N.profession = function(ctx, list)
  for _, name in ipairs(type(list) == "table" and list or {}) do
    local id = PROF_ID[name]
    if id and ctx.skills[id] then return true end
  end
  return false
end
N.secondary = function(ctx, which) return (ctx.skills[which] or 0) > 0 end
N.exists = function(ctx, role)
  for name, m in pairs(ns.Roster.members) do
    if (m.online or (m.lastOnlineDays or 99) <= 3) and fills(ctx, role, keyOf(name)) then return true end
  end
  return false
end
N.any = function(ctx, list)
  for _, need in ipairs(type(list) == "table" and list or {}) do
    if Blocks.CheckNeed(ctx, need) then return true end
  end
  return false
end

function Blocks.CheckNeed(ctx, need)
  local fn = type(need) == "table" and N[need[1]]
  if not fn then return false end
  return fn(ctx, need[2], need[3]) and true or false
end

-- Rules: who a quest can name ---------------------------------------------------------

Blocks.rules = {}
local R = Blocks.rules

local function cardChars(k)
  local pl = People.View().players[k]
  return pl and pl.addon and pl.chars or nil
end

local function hasProfession(k, set)
  for _, ch in pairs(cardChars(k) or {}) do
    for _, pr in ipairs(ch.prof or {}) do
      if not set or set[pr.id] then return true end
    end
  end
  return false
end

R.online = function(ctx, c, days)
  return c.member.online or (c.member.lastOnlineDays or 99) <= days
end
R.level_near = function(ctx, c, n) return math.abs((c.member.level or 0) - ctx.level) <= n end
R.level_below = function(ctx, c, n) return (c.member.level or 0) <= ctx.level - n end
R.addon = function(ctx, c) return People.IsAddonPlayer(c.key) end
R.established = function(ctx, c) return not People.IsNew(c.key, ctx.today) end
R.new = function(ctx, c) return People.IsNew(c.key, ctx.today) end
R.crafter = function(ctx, c) return hasProfession(c.key, CRAFTING) end
R.professional = function(ctx, c) return hasProfession(c.key, nil) end
R.uses_materials = function(ctx, c) return hasProfession(c.key, USES_MATERIALS) end
R.not_grouped_week = function(ctx, c) return not ctx.groupedWeek()[c.key] end
R.rarely = function(ctx, c) return ctx.tie(c.key) < 0.5 end
R.never_with = function(ctx, c, role)
  local other = ctx.named[role]
  return other ~= nil and other ~= c.key and not ctx.everGrouped(other, c.key)
end
R.bridger = function(ctx, c)
  local rate = ctx.bridging()[c.key]
  local median = ctx.bridging().median
  return rate ~= nil and median ~= nil and rate >= median
end
R.pair = function(ctx, c) return ctx.pairs()[c.key] ~= nil end

function Blocks.CheckRule(ctx, rule, candidate)
  local fn = type(rule) == "table" and R[rule[1]]
  if not fn then return false end
  return fn(ctx, candidate, rule[2], rule[3]) and true or false
end

-- Whether this version knows every block a template uses.
function Blocks.Supports(t)
  for _, b in ipairs(t.goal or {}) do
    if type(b) ~= "table" or not G[b[1]] or (b[2] ~= nil and type(b[2]) ~= "table") then return false end
  end
  for _, b in ipairs(t.needs or {}) do
    if type(b) ~= "table" or not N[b[1]] then return false end
  end
  for _, role in ipairs(t.names or {}) do
    if type(role) ~= "table" or (role.role ~= "X" and role.role ~= "Y") then return false end
    for _, rule in ipairs(role.rules or {}) do
      if type(rule) ~= "table" or not R[rule[1]] then return false end
    end
  end
  return #(t.goal or {}) > 0
end

-- Evaluates a quest's goal. Returns done, progress ({have, need} per block), evidence.
function Blocks.Evaluate(t, ctx)
  ctx.vars = {}
  local done, progress, evidence = true, {}, nil
  for i, b in ipairs(t.goal) do
    local ok, have, need, ev = G[b[1]](ctx, b[2] or {})
    progress[i] = { have = have or 0, need = need or 1 }
    if ev then evidence = ev end
    if not ok then done = false end
  end
  return done, progress, evidence
end

-- Final bosses: from the newest quest pack, by encounter id or English name.
function Blocks.IsFinalBoss(encounterID, name)
  local pack = ns.Pack.Get(ns.Pack.Newest() or -1)
  if not pack then return false end
  return pack.finalBosses[encounterID] == true or pack.finalBosses[name] == true
end
