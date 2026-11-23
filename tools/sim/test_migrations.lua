-- Migration contracts: a sample contract from data version 1 to 2 runs the way a real
-- one would. Facts survive, the old copy stays until the new one has loaded once, and a
-- failing contract leaves the saved data untouched.
local H = require("harness")
local wow = require("wow")

local world = wow.world({ seed = 5 })
local client = world:client(wow.full("Kiri"))
client.online = true
local env = client:makeEnv()
env.PintoTGD_DB = {}
local ns = H.load({ "Core/Build.lua", "Core/Init.lua", "Core/Compat.lua", "Core/Util.lua", "Core/Time.lua",
  "Sync/Bytes.lua", "Data/Pieces.lua", "Data/Migrations.lua", "Data/Store.lua" }, {}, env)
local Store, Pieces, Migrations, Time, Util = ns.Store, ns.Pieces, ns.Migrations, ns.Time, ns.Util

local today = Time.day()

-- Version 1 data, saved the way version 1 saves it.
local function version1Slot()
  Store.pieces = {}
  Store.AddPlayed(today, "Kiri-Forever")
  Store.AddGroup(today, { "Kiri-Forever", "Thorn-Forever" }, Pieces.ACT.dungeon, 7)
  Store.SetHistory(today, { H = 4200, W = 3000, Q = 1, G = 2, P = 3, T = 4, K = 5, N = 8, fv = 1, data = 9 })
  local slot = {}
  Store.Save(slot)
  return slot
end

-- The sample contract: version 2 doubles every history entry's data count, so the test
-- can see the contract ran. Everything else carries over as it is.
local function sampleContract(fail)
  return {
    decode = {
      d = function(r, num) return Pieces.decodeContent(r, "d", num) end,
      h = function(r, num) return Pieces.decodeContent(r, "h", num) end,
    },
    upgrade = function(letter, old)
      if fail then error("broken contract") end
      if letter == "h" then
        for _, e in pairs(old.days) do e.data = e.data * 2 end
      end
      return old
    end,
    moves = { h = { data = "data, doubled" } },
  }
end

H.test("a contract carries version 1 data to version 2", function()
  local slot = version1Slot()
  Migrations.contracts = {}
  Migrations.register(1, sampleContract(false))
  ns.Build.dataVersion = 2
  local ok = Store.Load(slot)
  H.ok(ok, "load failed")
  -- facts survive
  local d = Store.get(Pieces.id("d", today))
  H.ok(d.played[Util.nameId("Kiri-Forever")])
  H.eq(Util.count(d.together), 1)
  H.eq(Store.get("h").days[today].data, 18)
  H.eq(Store.get("h").days[today].H, 4200, "H changed")
  -- the old copy stays until the new one has been saved and loaded once
  H.ok(slot.backup, "no backup kept")
  Store.Save(slot)
  H.eq(slot.v, 2)
  H.ok(slot.check)
  H.ok(Store.Load(slot))
  H.eq(slot.backup, nil, "backup still there after a clean load")
  ns.Build.dataVersion = 1
end)

H.test("a failing contract leaves the saved data untouched and reports it", function()
  local slot = version1Slot()
  local before = H.deepCopy(slot)
  Migrations.contracts = {}
  Migrations.register(1, sampleContract(true))
  ns.Build.dataVersion = 2
  local ok, why = Store.Load(slot)
  H.eq(ok, false)
  H.eq(why, "migration")
  H.deepEq(slot.pieces, before.pieces, "saved pieces changed")
  ns.Build.dataVersion = 1
end)

H.test("data from a newer version is refused, not overwritten", function()
  local slot = version1Slot()
  slot.v = 3
  local ok, why = Store.Load(slot)
  H.eq(ok, false)
  H.eq(why, "newer")
end)

H.test("contracts can't be registered twice", function()
  Migrations.contracts = {}
  Migrations.register(1, sampleContract(false))
  H.raises(function() Migrations.register(1, sampleContract(false)) end, "twice")
end)

H.finish()
