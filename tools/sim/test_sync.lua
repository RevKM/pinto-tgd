-- The sync simulator: guildies log on and off at random, crash before saving, lose
-- messages, and hit Blizzard's throttle. Everyone online must end up with exactly the
-- same data, nothing may be lost beyond the known exception, and nothing duplicated.
local H = require("harness")
local wow = require("wow")

local ADDON_USERS = { "Kiri", "Thorn", "Bram", "Ash", "Wren", "Moss", "Fern", "Rook" }
local OTHERS = { "Nox", "Pip", "Quill", "Sage" }

local full = wow.full

local function newWorld(seed, drop)
  local world = wow.world({ seed = seed, drop = drop })
  for i, n in ipairs(ADDON_USERS) do world:addMember(full(n), { rankIndex = i == 1 and 0 or 2 }) end
  for _, n in ipairs(OTHERS) do world:addMember(full(n), { online = false }) end
  return world
end

local function fp(c) return c.ns.Store.wholeFingerprint() end

-- Every played fact and pair each client created, to check nothing got lost.
local created = { played = {}, together = {} }

local function addFacts(c, partner)
  local ns = c.ns
  local today = ns.Time.day()
  local day = string.format("%d", today)
  ns.Store.AddPlayed(today, c.name)
  created.played[c.name .. ":" .. day] = true
  if partner then
    ns.Store.AddGroup(today, { c.name, partner }, ns.Pieces.ACT.dungeon, ns.Player.AccountId())
    local a, b = c.name, partner
    if b < a then a, b = b, a end
    created.together[a .. "+" .. b .. ":" .. day] = true
  end
end

local function hasFacts(c, lost)
  local ns = c.ns
  local missing = {}
  for key in pairs(created.played) do
    local name, day = key:match("^(.-):(%d+)$")
    local piece = ns.Store.get(ns.Pieces.id("d", tonumber(day)))
    if not lost[key] and not (piece and piece.played[ns.Util.nameId(name)]) then missing[#missing + 1] = key end
  end
  for key in pairs(created.together) do
    local a, b, day = key:match("^(.-)%+(.-):(%d+)$")
    local piece = ns.Store.get(ns.Pieces.id("d", tonumber(day)))
    local k = ns.Pieces.togetherKey(ns.Util.nameId(a), ns.Util.nameId(b), ns.Pieces.ACT.dungeon)
    if not lost[key] and not (piece and piece.together[k]) then missing[#missing + 1] = key end
  end
  return missing
end

local function online(world)
  local list = {}
  for _, n in ipairs(ADDON_USERS) do
    local c = world.clients[full(n)]
    if c and c.online then list[#list + 1] = c end
  end
  return list
end

local function checkConverged(world)
  local list = online(world)
  for i = 2, #list do
    H.eq(fp(list[i]), fp(list[1]), list[i].name .. " differs from " .. list[1].name)
  end
  return list
end

local function noErrors(world)
  for _, c in pairs(world.clients) do
    H.eq(#c.errors, 0, c.name .. " had errors: " .. tostring(c.errors[1]))
  end
end

H.test("guildies who play at different times end up with the same data", function()
  created = { played = {}, together = {} }
  local world = newWorld(11, 0)
  local kiri, thorn, bram = world:client(full("Kiri")), world:client(full("Thorn")), world:client(full("Bram"))
  kiri:login(); thorn:login(); bram:login()
  world:run(60)
  addFacts(kiri, thorn.name)
  addFacts(thorn, kiri.name)
  addFacts(bram)
  world:run(120)
  checkConverged(world)

  -- Ash arrives later and catches up
  local ash = world:client(full("Ash"))
  ash:login()
  world:run(180)
  checkConverged(world)
  H.eq(#hasFacts(ash, {}), 0, "Ash is missing facts")

  -- Kiri logs out; Moss plays alone after everyone leaves, then they meet again
  kiri:logout()
  thorn:logout(); bram:logout(); ash:logout()
  local moss = world:client(full("Moss"))
  moss:login()
  world:run(60)
  addFacts(moss, full("Nox"))
  world:run(60)
  moss:logout()
  local fern = world:client(full("Fern"))
  fern:login()
  world:run(60)
  H.eq(fern.ns.Protocol.state, "alone")
  moss:login()
  kiri:login()
  world:run(400)
  local list = checkConverged(world)
  for _, c in ipairs(list) do H.eq(#hasFacts(c, {}), 0, c.name .. " is missing facts") end
  noErrors(world)
end)

H.test("lost messages, crashes and late joiners still converge without loss", function()
  created = { played = {}, together = {} }
  local world = newWorld(29, 0.05)
  local clients = {}
  for _, n in ipairs(ADDON_USERS) do clients[n] = world:client(full(n), { quietErrors = false }) end
  local lost = {}
  for round = 1, 6 do
    -- random logins and logouts
    for _, n in ipairs(ADDON_USERS) do
      local c = clients[n]
      local r = math.random()
      if c.online and r < 0.3 then
        c:logout()
      elseif not c.online and r < 0.5 then
        c:login()
      end
    end
    world:run(30)
    for _, c in ipairs(online(world)) do
      local others = online(world)
      local partner = #others > 1 and others[math.random(#others)].name or nil
      if partner == c.name then partner = nil end
      addFacts(c, partner)
    end
    world:run(45)
    -- a crash: facts already shared live survive; a crash with nobody else online loses them
    if round == 3 then
      local victims = online(world)
      local v = victims[1]
      if v then
        local today = v.ns.Time.day()
        v.ns.Store.AddPlayed(today, v.name)
        local key = v.name .. ":" .. string.format("%d", today)
        if not created.played[key] then lost[key] = true end
        v:crash()
      end
    end
    world:run(60)
  end
  -- everyone comes online and stays for a while
  for _, n in ipairs(ADDON_USERS) do
    if not clients[n].online then clients[n]:login() end
  end
  world:run(30 * 60)
  local list = checkConverged(world)
  H.eq(#list, #ADDON_USERS)
  for _, c in ipairs(list) do
    local missing = hasFacts(c, lost)
    H.eq(#missing, 0, c.name .. " is missing " .. tostring(missing[1]))
  end
  H.eq(world.stats.throttled, 0, "an addon hit Blizzard's throttle")
  noErrors(world)
end)

H.test("data arrives in any order and still gives the same result", function()
  created = { played = {}, together = {} }
  local world = newWorld(5, 0)
  local a, b = world:client(full("Kiri")), world:client(full("Thorn"))
  a:login()
  world:run(30)
  -- a builds facts alone, b builds others alone
  for i = 1, 5 do addFacts(a, full(OTHERS[(i % #OTHERS) + 1])) end
  a:logout()
  b:login()
  world:run(30)
  for i = 1, 5 do addFacts(b, full(OTHERS[((i + 1) % #OTHERS) + 1])) end
  a:login()
  world:run(300)
  checkConverged(world)
  H.eq(#hasFacts(a, {}), 0)
  H.eq(#hasFacts(b, {}), 0)
  noErrors(world)
end)

H.finish()
