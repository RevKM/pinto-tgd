-- Wiring: start-up, the guild check, saving and the slash command.
local ADDON, ns = ...

local Events, Time, Compat, Store = ns.Events, ns.Time, ns.Compat, ns.Store

-- nil while Pinto runs, otherwise why he's off: "guild" (another guild or none: stays
-- hidden), "trial" (trial or lapsed account), "newer" (saved by a newer version) or
-- "migration" (saved data couldn't be updated).
ns.disabled = nil
ns.started = false

local function slot()
  PintoTGD_DB.data = PintoTGD_DB.data or {}
  local key = Store.slotKey()
  PintoTGD_DB.data[key] = PintoTGD_DB.data[key] or {}
  return PintoTGD_DB.data[key]
end

local function startUI()
  if ns.UI and ns.UI.Init then ns.UI.Init() end
  Events.Fire("PINTO_STATE")
end

local lastPruneDay

-- Started in this order.
local MODULES = { "Roster", "Comm", "Protocol", "People", "Formula", "Pack", "Release", "Player",
  "Activity", "Trades", "Guild", "Trace", "Health", "Quests", "Officer" }

local function start()
  if ns.started then return end
  local guild = Compat.GuildName()
  if not guild then return end
  ns.started = true
  ns.me = Compat.UnitFullName("player")
  if guild ~= ns.GUILD then
    ns.disabled = "guild"
    Events.Fire("PINTO_STATE")
    return
  end
  if Compat.IsTrialOrLapsed() then
    ns.disabled = "trial"
    startUI()
    return
  end
  local ok, why = Store.Load(slot())
  if not ok then
    ns.disabled = why
    startUI()
    return
  end
  lastPruneDay = Time.day()
  Store.Prune(lastPruneDay)

  -- sync listens first, so every fact recorded from here on goes out live. A module that
  -- fails to start is reported, and the others start anyway. One whose file didn't load
  -- is left out: the addon was updated while the game ran (ns.UpdateUnfinished).
  ns.account = ns.Player.AccountId()
  for _, name in ipairs(MODULES) do
    local module = ns[name]
    if module == nil then
      ns.UpdateUnfinished()
    else
      local ok, err = pcall(module.Init)
      if not ok then ns.report(err) end
    end
  end

  ns.Every(60, function()
    local d = Time.day()
    if d ~= lastPruneDay then
      lastPruneDay = d
      Store.Prune(d)
    end
  end)
  startUI()
end

Events.On("ADDON_LOADED", function(name)
  if name ~= ADDON then return end
  -- no saved data yet: Pinto's first run on this account, so the start notice says where
  -- he lives (UI.Win.NoticeText)
  if PintoTGD_DB == nil then PintoTGD_DB = { ui = { welcome = true } } end
end)

Events.On("PLAYER_LOGIN", function()
  PintoTGD_DB = PintoTGD_DB or {}
  Compat.RequestRoster()
  start()
end)

-- The guild name can arrive a little after login.
Events.On("PLAYER_GUILD_UPDATE", start)
Events.On("GUILD_ROSTER_UPDATE", start)

Events.On("PLAYER_LOGOUT", function()
  if ns.started and not ns.disabled then
    Store.Save(slot())
  end
end)

-- Slash command ----------------------------------------------------------------------

-- Only Pinto's own key in the game's list: writing the SlashCmdList global itself, even
-- putting back the same table, taints it, and the game then blocks protected slash commands
-- such as /pvp, blaming Pinto.
SLASH_PINTO1 = "/pinto"
SlashCmdList.PINTO = function(msg)
  msg = (msg or ""):gsub("^%s+", ""):gsub("%s+$", "")
  local cmd, rest = msg:match("^(%S*)%s*(.-)$")
  cmd = (cmd or ""):lower()
  if cmd == "link" then
    if rest == "" then
      ns.Print("Your link code is |cffffffff" .. ns.Player.LinkCode() .. "|r. On your other WoW license, type /pinto link followed by this code.")
    elseif ns.Player.Link(rest) then
      ns.Print("Linked! Pinto now counts both licenses as one player.")
    else
      ns.Print("That link code doesn't look right.")
    end
  elseif cmd == "unlink" then
    ns.Player.Unlink()
    ns.Print("Unlinked.")
  elseif cmd == "status" then
    local w, wealth, state = ns.Health.Shape()
    local kind = ns.Build.test and (ns.Build.testTools and " test" or " beta") or ""
    ns.Print(string.format("version %s%s, sync %s, state %s, weight %.2f, hoard %.2f, %d pieces",
      ns.Build.version, kind, ns.Protocol.state, state, w, wealth, #Store.ids()))
    if next(ns.unknownEvents) then
      ns.Print("events this client doesn't have: " .. table.concat(ns.Util.sortedKeys(ns.unknownEvents), ", "))
    end
    if Compat.Surnames() then
      local listed = not ns.Roster.loaded or ns.Roster.Get(ns.me) ~= nil
      ns.Print(string.format("you are %s%s; whispers %s", tostring(ns.me), listed and "" or ", not found in the roster",
        ns.Comm.WhisperState()))
    end
  elseif cmd == "debug" then
    PintoTGD_DB.debug = not PintoTGD_DB.debug
    ns.Print("Debug messages " .. (PintoTGD_DB.debug and "on." or "off."))
    if ns.UI and ns.UI.ToggleDebugPanel and PintoTGD_DB.debug then ns.UI.ToggleDebugPanel() end
  elseif cmd == "small" then
    if ns.UI then ns.UI.Open("small") end
  elseif cmd == "nearby" then
    -- who in the group Pinto counts as nearby right now, and what the game said
    if ns.started and not ns.disabled then
      for _, line in ipairs(ns.Activity.Describe()) do ns.Print(line) end
    end
  elseif cmd == "test" and ns.Build.testTools then
    -- builds with the test tools only
    local sub, arg = rest:lower():match("^(%S*)%s*(.-)$")
    if sub == "reroll" then
      ns.Print(ns.Quests.TestGiveRerollBack() and "Your weekly reroll is back." or "You haven't used this week's reroll.")
    elseif sub == "complete" then
      -- a finished quest, as a preview; the test look starts with it, so Pinto eats it in the test
      local slot = tonumber(arg:match("%d+") or "")
      local q = ns.Quests.TestFinish(slot, arg:find("bonus", 1, true) ~= nil)
      if q then
        if ns.UI and ns.UI.Win then ns.UI.Win.StartTest() end
        ns.Print(string.format("Preview: quest %d is finished. Nothing is saved or shared; /pinto test reset brings it back.", q.slot))
      elseif slot then
        ns.Print(string.format("Quest %d is already finished, or there's no quest %d.", slot, slot))
      else
        ns.Print("All your quests are finished. /pinto test reset brings back the previews.")
      end
    elseif sub == "reset" then
      local was = ns.UI and ns.UI.TestReset and ns.UI.TestReset()
      ns.Print(was and "Test over: Pinto shows the guild's state again, and the previews are gone."
        or "No test is running.")
    elseif sub == "refresh" then
      local ok, why = ns.Quests.TestRefresh()
      if ok then
        ns.Print("New quests for this week, rolled the way Monday's refresh rolls them. Your reroll is back too.")
      elseif why == "done" then
        ns.Print("You've finished a quest this week, so your quests stay as they are.")
      else
        ns.Print("There are no quests to refresh yet.")
      end
    elseif sub == "notice" then
      if not (ns.UI and ns.UI.Win and ns.UI.Win.ShowNotice()) then ns.Print("Pinto has nothing to say right now.") end
    else
      ns.Print("Test build commands:")
      ns.Print("/pinto test complete [1-4] [bonus]: finish a quest as a preview, with the new guildie bonus if you add bonus")
      ns.Print("/pinto test reset: end the test look and the previews")
      ns.Print("/pinto test refresh: new quests for this week")
      ns.Print("/pinto test notice: show the start notice again")
      ns.Print("/pinto test reroll: your weekly reroll back")
    end
  else
    if ns.UI then ns.UI.Toggle("full") end
  end
end
