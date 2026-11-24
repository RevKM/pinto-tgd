-- Notices beside the minimap button that come from what happens during play, besides the
-- start notice after the login sync (UI/Windows.lua). They take their turn with the others
-- (UI/Minimap.lua).
--
-- A newer Pinto: once per login, the first time another guildie's addon says hello, if a
-- signed release stamp says there's a newer version than this one. A hello only carries a
-- version number, which anyone could make up, so the stamp decides; it spreads with the
-- sync, so the notice may come a moment after the hello. Clicking it shows the update
-- popup with the link.
--
-- Finished quests waiting: "You have completed quests! Open to feed Pinto!" once an hour
-- has passed since the first of them was finished, the full window hasn't opened since,
-- and the player has been out of combat for 2 minutes. Once for those quests per login.
-- Clicking it opens the full window, where Pinto eats them.
local ADDON, ns = ...

local UI = ns.UI
local Notices = {}
UI.Notices = Notices

local Events, Time = ns.Events, ns.Time

Notices.FEED_TEXT = "You have completed quests! Open to feed Pinto!"
Notices.FEED_AFTER = 3600   -- seconds since the first waiting quest was finished
Notices.CALM = 120          -- seconds out of combat before the reminder

local heard = false         -- another guildie's addon has said hello this login
local toldUpdate = false
local fullOpenedAt = nil    -- server time the full window last opened, this login
local combatEnd = nil       -- GetTime() when the player last left combat
local remindedFor = nil     -- the first waiting quest the reminder was for

-- The update notice's words, or nil when this is the newest Pinto.
function Notices.UpdateText()
  local status, st = ns.Release.Status()
  if status == "needed" then return "Pinto needs an update to stay in sync!" end
  if status == "available" then return string.format("Pinto %s is out! Update when you can.", st.version) end
  return nil
end

local function checkUpdate()
  if toldUpdate or not heard or ns.disabled then return end
  local text = Notices.UpdateText()
  if not text then return end
  toldUpdate = true
  UI.MiniButton.ShowNotice(text, { click = function() UI.Popups.ShowUpdate() end })
end

local function calm()
  if InCombatLockdown and InCombatLockdown() then return false end
  return combatEnd == nil or GetTime() - combatEnd >= Notices.CALM
end

-- The first of this account's finished quests Pinto hasn't eaten, if the reminder is due
-- for it: an hour after it was finished, with the full window not opened since.
local function feedDue()
  if ns.disabled or UI.Active() == "full" then return nil end
  local first
  for _, e in ipairs(ns.Quests.Uneaten()) do
    if not e.preview then
      first = e
      break
    end
  end
  if not first or not first.time or Time.now() - first.time < Notices.FEED_AFTER then return nil end
  if fullOpenedAt and fullOpenedAt >= first.time then return nil end
  return first
end

function Notices.CheckFeed()
  local first = feedDue()
  if not first or remindedFor == first.key or not calm() then return end
  remindedFor = first.key
  UI.MiniButton.ShowNotice(Notices.FEED_TEXT, {
    still = function() return feedDue() ~= nil end,
    click = function() UI.Open("full") end,
  })
end

function Notices.FullOpened() fullOpenedAt = Time.now() end

function Notices.Init()
  if ns.disabled then return end
  Events.On("PINTO_PEER", function()
    heard = true
    checkUpdate()
  end)
  Events.On("PINTO_DATA_CHANGED", function(id)
    if id == "k" then checkUpdate() end
  end)
  Events.On("PLAYER_REGEN_ENABLED", function() combatEnd = GetTime() end)
  ns.Every(15, Notices.CheckFeed)
end
