-- The guild's social health H, from 0 to 100, as PLAN.md's Guild health section defines it.
-- A pure calculation over synced data, so every addon gets the same numbers.
--
-- H = 100·Q·(0.15·G + 0.15·P + 0.45·T + 0.25·K), Q = min(1, 2·T), over the 7 full days
-- before day t, for active addon users only, and only when there are at least 6 of them.
local ADDON, ns = ...

local Formula = {}
ns.Formula = Formula

local Store, Pieces, People, Util, Time, Events = ns.Store, ns.Pieces, ns.People, ns.Util, ns.Time, ns.Events

local DECAY = 0.96
local WEIGHT = Pieces.WEIGHT
local BRIDGE = Pieces.BRIDGE
local GATHERING = { [5] = true, [7] = true, [8] = true } -- Herbalism, Mining, Skinning
local MIN_N = 6
Formula.MIN_N = MIN_N

-- Lookup tables ---------------------------------------------------------------------

-- The highest skill a character of level L can train to.
function Formula.Cap(profId, level)
  if GATHERING[profId] then
    if level >= 25 then return 300 elseif level >= 10 then return 225 end
    return 150
  end
  if level >= 35 then return 300 elseif level >= 20 then return 225 elseif level >= 10 then return 150 end
  return 75
end

-- The usual lowest and highest item level at level L, measured like ilvl (the mean over
-- all 17 gear slots, empty slots counting 0). Version 0.1 starts from typical quest-green
-- and dungeon-blue levels; version 0.2 replaces them with the guild's own percentiles.
function Formula.ItemLevelRange(level)
  return 0.55 * level, level + 6
end

-- Gold per player that fills the hoard's gold half.
Formula.FULL_GOLD = 500

function Formula.Z(t)
  return 1.8 * (1 - DECAY ^ t)
end

-- Per day: pairs of players with their highest activity weight, who played, and who
-- was in a guild group with whom. Cached until that day's data changes.

local dayCache = {}

local function pairKey(a, b)
  if Util.byteLess(b, a) then a, b = b, a end
  return a .. "|" .. b, a, b
end

local function addTo(map, a, b)
  local s = map[a]
  if not s then
    s = {}
    map[a] = s
  end
  s[b] = true
end

function Formula.Day(d)
  local cached = dayCache[d]
  if cached ~= nil then return cached or nil end
  local piece = Store.get(Pieces.id("d", d))
  if not piece then
    dayCache[d] = false
    return nil
  end
  local act = { pairs = {}, grouped = {}, bridge = {}, played = {}, facts = 0 }
  for id in pairs(piece.played) do
    act.played[People.PlayerOf(id)] = true
    act.facts = act.facts + 1
  end
  for _, rec in pairs(piece.together) do
    local pa, pb = People.PlayerOf(rec.a), People.PlayerOf(rec.b)
    act.facts = act.facts + 1
    if pa ~= pb then
      local key, a, b = pairKey(pa, pb)
      local w = WEIGHT[rec.act]
      local e = act.pairs[key]
      if not e then
        act.pairs[key] = { a = a, b = b, w = w }
      elseif w > e.w then
        e.w = w
      end
      addTo(act.grouped, pa, pb)
      addTo(act.grouped, pb, pa)
      if BRIDGE[rec.act] then
        addTo(act.bridge, pa, pb)
        addTo(act.bridge, pb, pa)
      end
    end
  end
  dayCache[d] = act
  return act
end

-- Tie strength w for every pair of players, after day t-1:
-- w = 0.96·w_prev + a each day, starting at 0 at go-live.
function Formula.Ties(t)
  local w = {}
  local first = math.max(Time.goLiveDay(), t - 100)
  for d = first, t - 1 do
    for _, e in pairs(w) do e.w = e.w * DECAY end
    local act = Formula.Day(d)
    if act then
      for key, p in pairs(act.pairs) do
        if p.w > 0 then
          local e = w[key]
          if not e then
            e = { a = p.a, b = p.b, w = 0 }
            w[key] = e
          end
          e.w = e.w + p.w
        end
      end
    end
  end
  return w
end

-- Profession and gear progress of a player's main character.
local function mainOf(k, t)
  local pl = People.View().players[k]
  local id = People.MainOf(k, t)
  return id and pl and pl.chars[id] or nil
end

local function gearProgress(ch)
  if not ch or not ch.slots then return 0 end
  local sum = 0
  for s = 1, #Pieces.GEAR_SLOTS do sum = sum + (ch.slots[s] or 0) end
  local ilvl = sum / #Pieces.GEAR_SLOTS
  local lo, hi = Formula.ItemLevelRange(ch.level or 1)
  return Util.clamp((ilvl - lo) / (hi - lo), 0, 1)
end
Formula.GearProgress = gearProgress

local function professionProgress(ch)
  if not ch or not ch.prof then return 0, {} end
  local sum, ratios = 0, {}
  for i = 1, 2 do
    local pr = ch.prof[i]
    if pr then
      local ratio = Util.clamp(pr.skill / Formula.Cap(pr.id, ch.level or 1), 0, 1)
      sum = sum + ratio
      ratios[pr.id] = ratio
    end
  end
  return sum / 2, ratios
end

-- Everything for day t. Returns a table with H (0..100) and all its parts, or with only
-- N when fewer than 6 addon users are active.
function Formula.Compute(t)
  local view = People.View()
  -- the 7 full days before t; days nobody recorded anything are left out
  local window = {}
  local facts = 0
  for d = t - 7, t - 1 do
    local act = Formula.Day(d)
    if act then
      window[#window + 1] = act
      facts = facts + act.facts
    end
  end

  -- who's measured: addon users who played on 2 of the last 7 days, from their 4th day
  local active = {}
  local keys = Util.sortedKeys(view.players, Util.byteLess)
  for _, k in ipairs(keys) do
    local pl = view.players[k]
    if pl.addon and People.Counts(k, t) then
      local pd = 0
      for _, act in pairs(window) do
        if act and act.played[k] then pd = pd + 1 end
      end
      if pd >= 2 then active[#active + 1] = { key = k, pd = pd } end
    end
  end
  local N = #active
  local out = { N = N, data = facts }
  local p = Store.get("p")
  if p then
    for _ in pairs(p.cards) do out.data = out.data + 1 end
  end
  if N < MIN_N then return out end

  local isActive = {}
  for _, a in ipairs(active) do isActive[a.key] = true end

  -- ties
  local ties = Formula.Ties(t)
  local z = Formula.Z(t - Time.goLiveDay())
  local tiesOf = {}
  local parent = {}
  local function find(x)
    while parent[x] and parent[x] ~= x do
      parent[x] = parent[parent[x]] or parent[x]
      x = parent[x]
    end
    return x
  end
  local tieKeys = Util.sortedKeys(ties, Util.byteLess)
  for _, key in ipairs(tieKeys) do
    local e = ties[key]
    if e.w > 0 and e.w >= z then
      tiesOf[e.a] = tiesOf[e.a] or {}
      tiesOf[e.b] = tiesOf[e.b] or {}
      table.insert(tiesOf[e.a], { other = e.b, w = e.w })
      table.insert(tiesOf[e.b], { other = e.a, w = e.w })
      parent[e.a] = parent[e.a] or e.a
      parent[e.b] = parent[e.b] or e.b
      local ra, rb = find(e.a), find(e.b)
      if ra ~= rb then
        if Util.byteLess(ra, rb) then parent[rb] = ra else parent[ra] = rb end
      end
    end
  end

  local dv, nv, kv, gv, pv = {}, {}, {}, {}, {}
  local skilled = {}
  local newActive = {}
  for _, a in ipairs(active) do
    local k = a.key
    -- d: guild group days / play days
    local gd = 0
    for _, act in pairs(window) do
      if act and act.grouped[k] then gd = gd + 1 end
    end
    dv[#dv + 1] = math.min(1, gd / a.pd)

    -- n, crew, bridges
    local mine = tiesOf[k] or {}
    table.sort(mine, function(x, y)
      if x.w ~= y.w then return x.w > y.w end
      return Util.byteLess(x.other, y.other)
    end)
    nv[#nv + 1] = #mine
    local crew = {}
    for i = 1, math.min(4, #mine) do crew[mine[i].other] = true end
    local c = math.min(1, math.min(4, #mine) / 3)
    local bridged = 0
    for _, act in pairs(window) do
      local with = act and act.bridge[k]
      if with then
        for other in pairs(with) do
          if not crew[other] then
            bridged = 1
            break
          end
        end
      end
      if bridged == 1 then break end
    end
    kv[#kv + 1] = c * (0.3 + 0.7 * bridged)

    -- g and p from the main
    local ch = mainOf(k, t)
    gv[#gv + 1] = gearProgress(ch)
    local prog, ratios = professionProgress(ch)
    pv[#pv + 1] = prog
    for id, ratio in pairs(ratios) do
      if ratio >= 0.75 then skilled[id] = (skilled[id] or 0) + 1 end
    end

    if People.IsNew(k, t) then newActive[#newActive + 1] = k end
  end

  -- G
  local medG = Util.median(gv)
  local G1 = math.min(1, medG / 0.6)
  local G2 = 1 - math.min(1, math.max(0, Util.percentile(gv, 0.9) - medG) / 0.4)
  local G = 0.6 * G1 + 0.4 * G2

  -- P
  local D = math.max(1, math.floor(math.log10(N) + 0.5))
  local covered = 0
  for id = 1, 9 do
    if (skilled[id] or 0) >= D then covered = covered + 1 end
  end
  local P1 = Util.median(pv)
  local P2 = covered / 9
  local P = 0.7 * P1 + 0.3 * P2

  -- T
  local T1 = math.min(1, Util.median(dv) / 0.5)
  local T2 = math.min(1, Util.median(nv) / (4 * math.log10(N)))
  local T3, M
  if #newActive >= 3 then
    local hit = 0
    for _, k in ipairs(newActive) do
      local found = false
      for _, act in pairs(window) do
        local with = act and act.grouped[k]
        if with then
          for other in pairs(with) do
            if People.Established(other, t) then
              found = true
              break
            end
          end
        end
        if found then break end
      end
      if found then hit = hit + 1 end
    end
    M = hit / #newActive
    T3 = math.min(1, M / 0.75)
  end
  local T
  if T3 then
    T = 0.40 * T1 + 0.35 * T2 + 0.25 * T3
  else
    T = (0.40 * T1 + 0.35 * T2) / 0.75
  end

  -- K
  local K1 = 0
  for _, v in ipairs(kv) do K1 = K1 + v end
  K1 = K1 / N
  local sizes = {}
  local R = 0
  for _, a in ipairs(active) do
    local root = parent[a.key] and find(a.key) or a.key
    sizes[root] = (sizes[root] or 0) + 1
    if sizes[root] > R then R = sizes[root] end
  end
  local K2 = R / N
  local K = 0.7 * K1 + 0.3 * K2

  local Q = math.min(1, 2 * T)
  local H = 100 * Q * (0.15 * G + 0.15 * P + 0.45 * T + 0.25 * K)

  out.H, out.Q, out.G, out.P, out.T, out.K = H, Q, G, P, T, K
  out.G1, out.G2, out.P1, out.P2, out.T1, out.T2, out.T3, out.M = G1, G2, P1, P2, T1, T2, T3, M
  out.K1, out.K2, out.R, out.z = K1, K2, R, z
  out.medianG = medG
  out.active = active
  return out
end

-- Wealth W = 0.5·median(g) + 0.5·B, with B = min(1, log10(1 + x) / log10(1 + X)).
-- x is the guild bank's gold per player when an addon could read it, otherwise the
-- median of the players' gold brackets. WealthParts gives the two halves: gear, the
-- median g, and gold, B.
function Formula.WealthParts(t, computed)
  computed = computed or Formula.Compute(t)
  local view = People.View()
  local gs, golds = {}, {}
  local list = computed.active
  if not list then
    list = {}
    for k, pl in pairs(view.players) do
      if pl.addon then list[#list + 1] = { key = k } end
    end
  end
  for _, a in ipairs(list) do
    gs[#gs + 1] = gearProgress(mainOf(a.key, t))
    local pl = view.players[a.key]
    local best = 0
    for _, card in ipairs(pl and pl.cards or {}) do
      best = math.max(best, ns.Player.BracketGold(card.gold))
    end
    golds[#golds + 1] = best
  end
  local x = Util.median(golds)
  local s = Store.get("s")
  local bank = s and s.entries.bank
  if bank and #list > 0 then
    local copper = tonumber(bank.value) or 0
    x = copper / 10000 / #list
  end
  local B = math.min(1, math.log10(1 + x) / math.log10(1 + Formula.FULL_GOLD))
  return Util.median(gs), B
end

function Formula.Wealth(t, computed)
  local gear, gold = Formula.WealthParts(t, computed)
  return 0.5 * gear + 0.5 * gold
end

function Formula.Init()
  Events.On("PINTO_DATA_CHANGED", function(id)
    if id == nil or id == "p" or id == "j" then
      dayCache = {}
    elseif id:sub(1, 1) == "d" then
      dayCache[tonumber(id:sub(2))] = nil
    end
  end)
  Events.On("PINTO_ROSTER", function() dayCache = {} end)
end
