-- The minimap button: Pinto's head on the edge of the minimap. Drag it around the
-- minimap; hover for Pinto's mood line; click to open the window size used last.
-- When a Pinto quest finishes, a haunch pops up and the button gives a happy wiggle.
-- A small haunch badge stays on it until Pinto has eaten. After the login sync, the start
-- notice slides out beside it for a few seconds.
local ADDON, ns = ...

local UI = ns.UI
local MiniButton = {}
UI.MiniButton = MiniButton

local button, badge, pop, wiggleT, note

local function place()
  local angle = UI.Settings().minimapAngle or 220
  local rad = math.rad(angle)
  local r = (Minimap:GetWidth() / 2) + 5
  button:ClearAllPoints()
  button:SetPoint("CENTER", Minimap, "CENTER", math.cos(rad) * r, math.sin(rad) * r)
end

local function onDragUpdate()
  local mx, my = Minimap:GetCenter()
  local cx, cy = GetCursorPosition()
  local scale = Minimap:GetEffectiveScale()
  cx, cy = cx / scale, cy / scale
  UI.Settings().minimapAngle = math.deg(math.atan2(cy - my, cx - mx)) % 360
  place()
end

function MiniButton.Refresh()
  if not button then return end
  local waiting = not ns.disabled and #ns.Quests.Uneaten() > 0
  badge:SetShown(waiting)
end

-- The finished-quest notification: a haunch pops up and the button wiggles.
function MiniButton.Notify()
  if not button then return end
  pop:Show()
  pop:SetAlpha(1)
  wiggleT = 0
  button:SetScript("OnUpdate", function(self, elapsed)
    wiggleT = wiggleT + elapsed
    local t = wiggleT
    local angle = math.sin(t * 18) * 0.35 * math.max(0, 1 - t / 0.9)
    self.icon:SetRotation(angle)
    pop:ClearAllPoints()
    pop:SetPoint("BOTTOM", self, "TOP", 0, -6 + 18 * UI.Smooth(math.min(1, t / 0.4)))
    pop:SetAlpha(1 - UI.Smooth(math.max(0, (t - 0.8) / 0.5)))
    if t > 1.4 then
      self.icon:SetRotation(0)
      pop:Hide()
      self:SetScript("OnUpdate", nil)
    end
  end)
  MiniButton.Refresh()
end

-- The start notice ---------------------------------------------------------------------------
-- A small note beside the button with a few words on how Pinto is (UI.Win.NoticeText). It
-- slides out from Pinto's head while it fades in, stays 8 seconds, and drifts a little
-- further while it fades out. It sits on the side of the button facing the middle of the
-- screen.

local NOTE_IN, NOTE_STAY, NOTE_OUT = 0.5, 8, 0.7
local NOTE_SLIDE = 14   -- how far it slides out from the button, in pixels
local NOTE_GAP = 4
local NOTE_ICON = 18    -- Pinto's head in it

local function buildNote()
  local f = CreateFrame("Frame", nil, UIParent, BackdropTemplateMixin and "BackdropTemplate" or nil)
  f:SetFrameStrata("MEDIUM")
  f:SetFrameLevel(20)
  f:SetClampedToScreen(true)
  f:SetSize(160, 30)
  if f.SetBackdrop then
    f:SetBackdrop({
      bgFile = "Interface\\Tooltips\\UI-Tooltip-Background",
      edgeFile = "Interface\\Tooltips\\UI-Tooltip-Border",
      tile = true, tileSize = 16, edgeSize = 12,
      insets = { left = 3, right = 3, top = 3, bottom = 3 },
    })
    f:SetBackdropColor(0.08, 0.06, 0.05, 0.92)
    f:SetBackdropBorderColor(0.85, 0.68, 0.3, 0.9)
  end
  f.icon = f:CreateTexture(nil, "ARTWORK")
  f.icon:SetSize(NOTE_ICON, NOTE_ICON)
  f.icon:SetPoint("LEFT", 6, 0)
  f.icon:SetTexture(UI.Media("MinimapHead"))
  f.text = UI.Text(f, "GameFontHighlight")
  f.text:SetPoint("LEFT", f.icon, "RIGHT", 5, 0)
  f:Hide()
  return f
end

-- slide: pixels away from the button past its resting place (less than 0: closer)
local function placeNote(slide)
  note:ClearAllPoints()
  if note.left then
    note:SetPoint("RIGHT", note.anchor, "LEFT", -(NOTE_GAP + slide), 0)
  else
    note:SetPoint("LEFT", note.anchor, "RIGHT", NOTE_GAP + slide, 0)
  end
end

local function stepNote(self, elapsed)
  self.t = self.t + elapsed
  local t = self.t
  if t < NOTE_IN then
    local e = UI.Smooth(t / NOTE_IN)
    self:SetAlpha(e)
    placeNote(-NOTE_SLIDE * (1 - e))
  elseif t < NOTE_IN + NOTE_STAY then
    if self.phase ~= "stay" then
      self.phase = "stay"
      self:SetAlpha(1)
      placeNote(0)
    end
  else
    local e = UI.Smooth((t - NOTE_IN - NOTE_STAY) / NOTE_OUT)
    self.phase = "out"
    self:SetAlpha(1 - e)
    placeNote(NOTE_SLIDE * 0.5 * e)
    if e >= 1 then
      self:SetScript("OnUpdate", nil)
      self:Hide()
    end
  end
end

function MiniButton.ShowNotice(text)
  local anchor = (button and button:IsShown()) and button or Minimap
  if not text or text == "" or not anchor then return end
  note = note or buildNote()
  note.text:SetText(text)
  note:SetWidth(math.ceil(note.text:GetStringWidth()) + 6 + NOTE_ICON + 5 + 10)
  note.anchor = anchor
  local x = anchor:GetCenter()
  local scale = anchor:GetEffectiveScale() / UIParent:GetEffectiveScale()
  note.left = x ~= nil and x * scale > UIParent:GetWidth() / 2
  note.t, note.phase = 0, "in"
  note:SetAlpha(0)
  placeNote(-NOTE_SLIDE)
  note:Show()
  note:SetScript("OnUpdate", stepNote)
end

function MiniButton.Notice() return note end
function MiniButton.Button() return button, badge end

function MiniButton.Init()
  if button or not Minimap then return end
  button = CreateFrame("Button", "PintoTGDMinimapButton", Minimap)
  button:SetSize(31, 31)
  button:SetFrameStrata("MEDIUM")
  button:SetFrameLevel(8)
  button:RegisterForClicks("LeftButtonUp", "RightButtonUp")
  button:RegisterForDrag("LeftButton")
  button:SetHighlightTexture("Interface\\Minimap\\UI-Minimap-ZoomButton-Highlight")

  -- laid out the way LibDBIcon lays out other addons' minimap buttons, so Pinto's sits in
  -- its border like theirs: the border, a dark round background that fills the border's
  -- hole, and the head on top. Clients with the addon compartment have the newer minimap
  -- art, which is a little smaller and centred.
  local newArt = AddonCompartmentFrame ~= nil
  local border = button:CreateTexture(nil, "OVERLAY")
  border:SetSize(newArt and 50 or 53, newArt and 50 or 53)
  border:SetPoint("TOPLEFT")
  border:SetTexture("Interface\\Minimap\\MiniMap-TrackingBorder")
  button.border = border

  local bg = button:CreateTexture(nil, "BACKGROUND")
  bg:SetTexture("Interface\\Minimap\\UI-Minimap-Background")
  if newArt then
    bg:SetSize(24, 24)
    bg:SetPoint("CENTER")
  else
    bg:SetSize(20, 20)
    bg:SetPoint("TOPLEFT", 7, -5)
  end
  button.bg = bg

  local icon = button:CreateTexture(nil, "ARTWORK")
  icon:SetSize(newArt and 20 or 18, newArt and 20 or 18)
  icon:SetPoint("CENTER", bg, "CENTER")
  icon:SetTexture(UI.Media("MinimapHead"))
  button.icon = icon

  badge = button:CreateTexture(nil, "OVERLAY", nil, 2)
  badge:SetSize(14, 14)
  badge:SetPoint("BOTTOMRIGHT", 2, -2)
  badge:SetTexture(UI.Media("Haunch"))
  badge:Hide()

  pop = button:CreateTexture(nil, "OVERLAY", nil, 3)
  pop:SetSize(18, 18)
  pop:SetTexture(UI.Media("Haunch"))
  pop:Hide()

  button:SetScript("OnDragStart", function(self) self:SetScript("OnUpdate", onDragUpdate) end)
  button:SetScript("OnDragStop", function(self) self:SetScript("OnUpdate", nil) end)
  button:SetScript("OnClick", function() UI.ToggleLast() end)
  button:SetScript("OnEnter", function(self) UI.ShowTip(self, "LEFT", "Pinto, the Girthy Dragon", UI.StatusLine()) end)
  button:SetScript("OnLeave", function(self) UI.HideTip(self) end)
  place()
  MiniButton.Refresh()
end
