-- Update popups. When the addon learns of a newer release, it shows a friendly popup once
-- for that version. If the newer release can't share data with this one, or its stamp
-- marks it as an important fix, the popup comes back at every login until the player
-- updates. Popups wait until the player is out of combat and out of instances, and carry
-- the GitHub link in a box to copy, since WoW can't open links. The popup is Pinto's own
-- window: the game's popups are shared with its secure code, and an addon that shows one
-- taints it.
local ADDON, ns = ...

local UI = ns.UI
local Popups = {}
UI.Popups = Popups

local shownNeeded = false
local pending = false
local frame

local function link() return ns.Build.releaseUrl or "" end

local function build()
  frame = UI.Window("PintoTGDUpdate", 360, 132)
  frame:SetFrameStrata("DIALOG")
  frame.text = UI.Text(frame, "GameFontHighlight")
  frame.text:SetPoint("TOP", 0, -24)
  frame.text:SetWidth(310)
  frame.text:SetJustifyH("CENTER")
  local function close() frame:Hide() end
  -- the link, selected for copying once clicked; whatever is typed, it stays the link. It
  -- doesn't take the keyboard by itself, so a player walking along keeps walking.
  local box = CreateFrame("EditBox", nil, frame, "InputBoxTemplate")
  box:SetSize(290, 20)
  box:SetPoint("TOP", frame.text, "BOTTOM", 0, -14)
  box:SetAutoFocus(false)
  box:SetScript("OnEditFocusGained", function(self) self:HighlightText() end)
  box:SetScript("OnEnterPressed", close)
  box:SetScript("OnEscapePressed", close)
  box:SetScript("OnTextChanged", function(self, typed)
    if typed then
      self:SetText(link())
      self:HighlightText()
    end
  end)
  frame.box = box
  local ok = UI.Button(frame, OKAY or "Okay", 90)
  ok:SetPoint("BOTTOM", 0, 16)
  ok:SetScript("OnClick", close)
  frame.ok = ok
  frame:SetScript("OnHide", function() box:ClearFocus() end)
end

local function show(text)
  if not frame then build() end
  frame.text:SetText(text)
  frame.box:SetText(link())
  UI.RestorePosition(frame, 0, 200)
  frame:Show()
end

function Popups.Frame() return frame end

local function busy()
  if InCombatLockdown and InCombatLockdown() then return true end
  local inInstance = IsInInstance()
  return inInstance and true or false
end

function Popups.Check()
  local status, st = ns.Release.Status()
  if not status then return end
  if busy() then
    if not pending then
      pending = true
      ns.After(15, function()
        pending = false
        Popups.Check()
      end)
    end
    return
  end
  local ui = UI.Settings()
  if status == "available" then
    ui.popups = ui.popups or {}
    if ui.popups[st.version] then return end
    ui.popups[st.version] = true
    show(string.format("Pinto %s is out! Update when you get a chance.", st.version))
  elseif not shownNeeded then
    shownNeeded = true
    show("Pinto needs an update to stay in sync with the guild.")
  end
end

function Popups.Init()
  ns.Events.On("PINTO_DATA_CHANGED", function(id)
    if id == "k" then ns.After(2, Popups.Check) end
  end)
  ns.Events.On("PLAYER_REGEN_ENABLED", function() if pending then Popups.Check() end end)
  ns.After(20, Popups.Check)
end
