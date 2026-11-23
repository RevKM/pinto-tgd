-- Quest packs: signed data holding the quest templates.
--
-- A pack is "PintoPack", u16 pack number, u8 format, then one value: a small tree of
-- false/true/whole numbers/strings/lists/maps (type byte, then the value), written by
-- tools/build.py from quests/*.json. Templates are data only: the addon never runs
-- anything it receives.
local ADDON, ns = ...

local Pack = {}
ns.Pack = Pack

local Bytes, Store = ns.Bytes, ns.Store
local fail = Bytes.fail

local FORMAT = 1
local cache = {}

local function readValue(r, depth)
  if depth > 12 then fail("pack too deep") end
  local t = r:u8()
  if t == 0 then return false end
  if t == 1 then return true end
  if t == 2 then return r:varint() end
  if t == 3 then return -r:varint() end
  if t == 4 then return r:str(4096) end
  if t == 5 then
    local list = {}
    for i = 1, r:count(2000) do list[i] = readValue(r, depth + 1) end
    return list
  end
  if t == 6 then
    local map = {}
    for _ = 1, r:count(2000) do
      local key = r:str(64)
      map[key] = readValue(r, depth + 1)
    end
    return map
  end
  fail("pack value type")
end
Pack.readValue = readValue

local SETS = { calibration = "calibration", [1] = 1, [2] = 2 }

-- Returns { num, templates = { [id] = template }, ids = { sorted }, finalBosses = { name = true } }
function Pack.Decode(data)
  return Bytes.decode(data, function(r)
    if r:bytes(9) ~= "PintoPack" then fail("pack magic") end
    local num = r:u16()
    if r:u8() ~= FORMAT then fail("pack format") end
    local root = readValue(r, 0)
    if not r:atEnd() then fail("pack trailing bytes") end
    if type(root) ~= "table" or type(root.templates) ~= "table" then fail("pack root") end
    local pack = { num = num, templates = {}, ids = {}, finalBosses = {} }
    for _, t in ipairs(root.templates) do
      if type(t) == "table" and type(t.id) == "number" and type(t.text) == "string"
        and type(t.worth) == "number" and t.worth >= 1 and t.worth <= 3 and SETS[t.set] then
        t.needs = type(t.needs) == "table" and t.needs or {}
        t.names = type(t.names) == "table" and t.names or {}
        t.goal = type(t.goal) == "table" and t.goal or {}
        t.supported = ns.Blocks.Supports(t)
        pack.templates[t.id] = t
        pack.ids[#pack.ids + 1] = t.id
      end
    end
    table.sort(pack.ids)
    for _, name in ipairs(type(root.finalBosses) == "table" and root.finalBosses or {}) do
      if type(name) == "string" then pack.finalBosses[name] = true end
    end
    for _, id in ipairs(type(root.finalBossIds) == "table" and root.finalBossIds or {}) do
      if type(id) == "number" then pack.finalBosses[id] = true end
    end
    return pack
  end)
end

function Pack.Get(num)
  if cache[num] ~= nil then return cache[num] or nil end
  local k = Store.get("k")
  local pk = k and k.packs[num]
  if not pk then return nil end
  local pack = Pack.Decode(pk.data)
  cache[num] = pack or false
  return pack
end

function Pack.Newest()
  local k = Store.get("k")
  local newest
  for num in pairs(k and k.packs or {}) do
    if not newest or num > newest then newest = num end
  end
  return newest
end

function Pack.Init()
  ns.Events.On("PINTO_DATA_CHANGED", function(id)
    if id == "k" or id == nil then cache = {} end
  end)
end
