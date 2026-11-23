-- Migration contracts: each one carries saved data from data version n to n+1.
--
-- A contract file in migrations/ registers itself with
--   ns.Migrations.register(n, {
--     decode = { [letter] = function(reader, num) ... end },   -- frozen copy of version n's decoders
--     upgrade = function(letter, old, num) ... end,           -- version n structure -> version n+1
--     moves = { ... },                                        -- where every old value goes
--   })
-- Released contracts never change; a fix is a new contract. Data from any older version
-- runs through the contracts in order. tools/sim/test_migrations.lua checks each contract
-- against samples of old data and the exact result it must give.
local ADDON, ns = ...

local Migrations = {}
ns.Migrations = Migrations

Migrations.contracts = {}

function Migrations.register(n, contract)
  assert(not Migrations.contracts[n], "migration contract registered twice")
  assert(contract.decode and contract.upgrade, "migration contract needs decode and upgrade")
  Migrations.contracts[n] = contract
end

-- Decodes piece content written at data version dv and carries it up to the current version.
function Migrations.decode(dv, letter, num, r)
  local current = ns.Build.dataVersion
  local first = Migrations.contracts[dv]
  if not first or not first.decode[letter] then ns.Bytes.fail("no migration contract") end
  local data = first.decode[letter](r, num)
  for v = dv, current - 1 do
    local contract = Migrations.contracts[v]
    if not contract then ns.Bytes.fail("missing migration contract") end
    data = contract.upgrade(letter, data, num)
  end
  return data
end
