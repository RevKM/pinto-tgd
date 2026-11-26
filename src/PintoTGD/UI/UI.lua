-- Starts the UI once Pinto knows who and where the player is.
local ADDON, ns = ...

local UI = ns.UI
local started = false

function UI.Init()
  if started then return end
  started = true
  UI.MiniButton.Init()
  UI.Win.Init()
  if not ns.disabled then
    UI.Popups.Init()
    -- Notices.lua came with 0.1.1: not there after an update from 0.1.0 while the game ran
    if UI.Notices then UI.Notices.Init() else ns.UpdateUnfinished() end
    local pending = false
    local function refresh()
      if pending then return end
      pending = true
      ns.After(0.5, function()
        pending = false
        UI.QuestList.Refresh()
        UI.MiniButton.Refresh()
      end)
    end
    ns.Events.On("PINTO_QUESTS", refresh)
    ns.Events.On("PINTO_EATEN", refresh)
    ns.Events.On("PINTO_DATA_CHANGED", function(id)
      if id and id:sub(1, 1) == "w" then refresh() end
    end)
    ns.Every(30, function()
      UI.QuestList.UpdateFooter()
      UI.MiniButton.Refresh()
    end)
  end
end
