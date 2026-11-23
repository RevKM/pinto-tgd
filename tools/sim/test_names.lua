-- Names. Forever has no realms: every character is "Name Surname", and one guild's
-- characters can sit on different realms behind the scenes. Pinto keys characters by
-- the roster's name, reads every form the client gives, and finds out at login how a
-- whisper must name its target. With PINTO_NAMES=realm the same tests run on
-- "Name-Realm" names, where they apply.
local H = require("harness")
local wow = require("wow")

local full = wow.full
local forever = wow.NAMES == "forever"

H.test("names in every form the client gives come to the same key", function()
  local world = wow.world({ seed = 31 })
  world:addMember(full("Kiri"), { rankIndex = 0 })
  local client = world:client(full("Kiri"))
  client:login()
  local Compat = client.ns.Compat
  H.eq(client.ns.me, full("Kiri"))
  if forever then
    H.eq(Compat.Surnames(), true)
    for _, form in ipairs({ "Ihotchu Noworries", "Ihotchu-Noworries", "Ihotchu Noworries-CAMWOWEU5Realm7PvE",
      "Ihotchu-Noworries-CAMWOWEU5Realm7PvE" }) do
      H.eq(Compat.FullName(form), "Ihotchu Noworries", form)
    end
    H.eq(Compat.FullName("Ihotchu", "Noworries"), "Ihotchu Noworries")
    H.eq(Compat.ShortName("Ihotchu Noworries"), "Ihotchu Noworries", "first names repeat, so the whole name shows")
    H.eq(Compat.FirstName("Ihotchu Noworries"), "Ihotchu")
    H.eq(Compat.WhisperTarget("Ihotchu Noworries"), "Ihotchu Noworries")
    Compat.whisperForm = "hyphen"
    H.eq(Compat.WhisperTarget("Ihotchu Noworries"), "Ihotchu-Noworries")
  else
    H.eq(Compat.Surnames(), false)
    H.eq(Compat.FullName("Thorn"), "Thorn-Forever")
    H.eq(Compat.FullName("Thorn", "Argent Dawn"), "Thorn-ArgentDawn")
    H.eq(Compat.FullName("Thorn-ArgentDawn"), "Thorn-ArgentDawn")
    H.eq(Compat.ShortName("Thorn-ArgentDawn"), "Thorn")
    H.eq(Compat.WhisperTarget("Thorn-ArgentDawn"), "Thorn-ArgentDawn")
  end
  H.eq(#client.errors, 0)
end)

H.test("the guild's join message gives the new member's full name", function()
  local world = wow.world({ seed = 35 })
  world:addMember(full("Kiri"), { rankIndex = 0 })
  local kiri = world:client(full("Kiri"))
  kiri:login()
  world:run(30)
  if forever then
    kiri:fire("CHAT_MSG_SYSTEM", "|Hplayer:Wren Forever|h[Wren Forever]|h has joined the guild.")
  else
    kiri:fire("CHAT_MSG_SYSTEM", "Wren has joined the guild.")
  end
  local ns = kiri.ns
  local e = ns.Roster.JoinInfo(ns.Util.nameId(full("Wren")))
  H.ok(e, "Wren's join wasn't noted")
  H.eq(e and e.name, full("Wren"))
  H.eq(#kiri.errors, 0)
end)

if forever then
  local REALMS = { "CAMWOW EU4 Realm 7 PvE", "CAMWOW EU5 Realm 7 PvE", "CAMWOW EU2 Realm 7 PvE" }
  local NAMES = { "Kiri", "Thorn", "Bram" }

  local function played(c)
    local ns = c.ns
    ns.Store.AddPlayed(ns.Time.day(), c.name)
  end

  local function hasPlayed(c, name)
    local ns = c.ns
    local piece = ns.Store.get(ns.Pieces.id("d", ns.Time.day()))
    return piece ~= nil and piece.played[ns.Util.nameId(name)] == true
  end

  -- Kiri and Thorn play, Kiri logs off, Thorn and Bram play on, and Kiri comes back and
  -- has to catch up over whispers.
  local CASES = {
    { senderForm = "space", whisperForm = "space" },
    { senderForm = "hyphen", whisperForm = "hyphen" },
    { senderForm = "realm", whisperForm = "space" },
    { senderForm = "space", whisperForm = "hyphen" },
  }
  for _, case in ipairs(CASES) do
    H.test(string.format("guildies on different realms catch up (senders %s, whispers %s)",
      case.senderForm, case.whisperForm), function()
      local world = wow.world({ seed = 32, senderForm = case.senderForm, whisperForm = case.whisperForm })
      for i, n in ipairs(NAMES) do world:addMember(full(n), { rankIndex = i == 1 and 0 or 2 }) end
      local clients = {}
      for i, n in ipairs(NAMES) do clients[i] = world:client(full(n), { realm = REALMS[i] }) end
      local kiri, thorn, bram = clients[1], clients[2], clients[3]
      kiri:login()
      thorn:login()
      world:run(120)
      played(kiri)
      played(thorn)
      world:run(120)
      kiri:logout()
      bram:login()
      world:run(60)
      played(bram)
      world:run(120)
      kiri:login()
      world:run(1500)
      for _, c in ipairs(clients) do
        H.eq(c.ns.me, c.name)
        H.ok(c.ns.Roster.Get(c.ns.me), c.name .. " isn't in its own roster")
        H.eq(c.ns.Store.slotKey():sub(1, 8), "Forever/", "one save slot whatever the realm")
        H.eq(c.ns.Comm.whisperCheck.state, case.whisperForm, c.name .. "'s whisper check")
        H.eq(c.ns.Compat.whisperForm, case.whisperForm)
        for _, n in ipairs(NAMES) do H.ok(hasPlayed(c, full(n)), c.name .. " lacks " .. n .. "'s day") end
        H.eq(#c.errors, 0)
      end
      H.eq(kiri.ns.Store.wholeFingerprint(), thorn.ns.Store.wholeFingerprint())
      H.eq(kiri.ns.Store.wholeFingerprint(), bram.ns.Store.wholeFingerprint())
    end)
  end

  H.test("when no whisper to oneself arrives, whispers stay Name Surname and status says so", function()
    local world = wow.world({ seed = 33, whisperForm = "neither" })
    world:addMember(full("Kiri"), { rankIndex = 0 })
    local kiri = world:client(full("Kiri"))
    kiri:login()
    world:run(120)
    H.eq(kiri.ns.Comm.whisperCheck.state, "none")
    H.eq(kiri.ns.Compat.whisperForm, "space")
    H.eq(world.stats.unknownTargets, 2, "one try in each form")
    H.eq(kiri.ns.Comm.WhisperState(), "to yourself didn't arrive")
    H.eq(#kiri.errors, 0)
  end)

  H.test("the whisper check waits out combat and instances", function()
    local world = wow.world({ seed = 36, whisperForm = "hyphen" })
    world:addMember(full("Kiri"), { rankIndex = 0 })
    local kiri = world:client(full("Kiri"))
    kiri.combat = true
    kiri:login()
    world:run(200)
    H.eq(kiri.ns.Comm.whisperCheck.state, "checking", "nothing goes out in combat")
    H.eq(world.stats.unknownTargets or 0, 0)
    kiri.combat = false
    world:run(120)
    H.eq(kiri.ns.Comm.whisperCheck.state, "hyphen")
    H.eq(world.stats.unknownTargets, 1, "only the first form missed")
  end)

  H.test("on Forever an alt note can name its main by first name, when it's the only one", function()
    local world = wow.world({ seed = 34 })
    world:addMember(full("Kiri"), { rankIndex = 0 })
    world:addMember("Bram Stonehand", { note = "Kiri's alt" })
    world:addMember("Wren Forever", { note = "alt of thorn stonehand" })
    world:addMember("Thorn Stonehand")
    local kiri = world:client(full("Kiri"))
    kiri:login()
    world:run(10)
    local Roster = kiri.ns.Roster
    H.eq(Roster.MainOf("Bram Stonehand"), full("Kiri"))
    H.eq(Roster.MainOf("Wren Forever"), "Thorn Stonehand")
    -- a second Kiri joins: the first name alone no longer says who
    world:addMember("Kiri Ashvale")
    kiri.ns.Compat.RequestRoster()
    world:run(10)
    H.eq(Roster.MainOf("Bram Stonehand"), nil)
    H.eq(Roster.MainOf("Wren Forever"), "Thorn Stonehand")
  end)
end

H.finish()
