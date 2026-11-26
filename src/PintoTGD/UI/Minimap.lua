-- The minimap button: Pinto's head on the edge of the minimap. Drag it around the
-- minimap; hover for Pinto's mood line and, in a group, who counts as nearby; click to
-- open the window size used last.
-- When a Pinto quest finishes, a haunch pops up and the button gives a happy wiggle.
-- A small haunch badge stays on it until Pinto has eaten. Notices slide out beside it for
-- a few seconds, one at a time: the start notice after the login sync, and the others in
-- UI/Notices.lua.
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

-- Notices ------------------------------------------------------------------------------------
-- A small note beside the button with a few words: how Pinto is after the login sync
-- (UI.Win.NoticeText), a new version, finished quests waiting. It slides out from Pinto's
-- head while it fades in, stays 8 seconds, and drifts a little further while it fades out.
-- It sits on the side of the button facing the middle of the screen.
--
-- Notices take turns: one that comes while another shows waits in line, and comes in a
-- moment after the one before has faded out, so none cuts another short. One that's no
-- longer true by its turn (its still() says so) is skipped, and the same words are never
-- in line twice. Clicking a note opens Pinto, or does what that notice is about, and sends
-- the note on its way out.

local NOTE_IN, NOTE_STAY, NOTE_OUT = 0.5, 8, 0.7
local NOTE_PAUSE = 0.3  -- between one note fading out and the next coming in
local NOTE_SLIDE = 14   -- how far it slides out from the button, in pixels
local NOTE_GAP = 4
local NOTE_ICON = 18    -- Pinto's head in it

local queue = {}        -- { text, still, click } waiting their turn
local playNext

-- What clicking a notice does when it doesn't say: open the window size used last.
local function openPinto()
  if ns.disabled == "guild" then return end
  if not UI.Active() then UI.Open(UI.Settings().last or "full") end
end

local function buildNote()
  local f = CreateFrame("Frame", nil, UIParent, BackdropTemplateMixin and "BackdropTemplate" or nil)
  f:SetFrameStrata("MEDIUM")
  f:SetFrameLevel(20)
  f:SetClampedToScreen(true)
  f:SetSize(160, 30)
  f:EnableMouse(true)
  f:SetScript("OnMouseUp", function(self, mouseButton)
    if mouseButton ~= "LeftButton" or not self:IsShown() then return end
    local click = self.click or openPinto
    -- on its way out now, if it wasn't already
    if self.t < NOTE_IN + NOTE_STAY then self.t = NOTE_IN + NOTE_STAY end
    click()
  end)
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
      self.phase, self.click = "gone", nil
      if #queue > 0 then ns.After(NOTE_PAUSE, playNext) end
    end
  end
end

local function busy() return note ~= nil and note:IsShown() end

-- Shows the next notice in line that's still true, if no note is showing.
playNext = function()
  if busy() then return end
  local anchor = (button and button:IsShown()) and button or Minimap
  if not anchor then return end
  local n
  repeat
    n = table.remove(queue, 1)
  until not n or not n.still or n.still()
  if not n then return end
  note = note or buildNote()
  note.text:SetText(n.text)
  note:SetWidth(math.ceil(note.text:GetStringWidth()) + 6 + NOTE_ICON + 5 + 10)
  note.anchor = anchor
  note.click = n.click
  local x = anchor:GetCenter()
  local scale = anchor:GetEffectiveScale() / UIParent:GetEffectiveScale()
  note.left = x ~= nil and x * scale > UIParent:GetWidth() / 2
  note.t, note.phase = 0, "in"
  note:SetAlpha(0)
  placeNote(-NOTE_SLIDE)
  note:Show()
  note:SetScript("OnUpdate", stepNote)
end

-- Puts a notice in line. opts.still: checked when its turn comes, false skips it.
-- opts.click: what clicking it does, instead of opening Pinto.
function MiniButton.ShowNotice(text, opts)
  if not text or text == "" then return end
  if busy() and note.text:GetText() == text then return end
  for _, n in ipairs(queue) do
    if n.text == text then return end
  end
  queue[#queue + 1] = { text = text, still = opts and opts.still, click = opts and opts.click }
  playNext()
end

function MiniButton.Notice() return note end

-- The texts of the notices waiting their turn.
function MiniButton.Waiting()
  local list = {}
  for i, n in ipairs(queue) do list[i] = n.text end
  return list
end
function MiniButton.Button() return button, badge end

-- The tooltip's text: Pinto's mood line and, in a group, who Pinto counts as nearby and
-- why. Those are the lines /pinto nearby prints, here with nothing typed: after any
-- addon's slash command the game closes its chat box under that addon's name, and that
-- can raise an error in the game's own code (it did once, after a Battle.net whisper).
local function tipText()
  local text = UI.StatusLine()
  if not ns.started or ns.disabled or not ns.Activity or not IsInGroup() then return text end
  local ok, lines = pcall(ns.Activity.Describe)
  if not ok then
    ns.report(lines)
    return text
  end
  local group = table.concat(lines, "\n")
  return text and (text .. "\n\n" .. group) or group
end

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
  button:SetScript("OnEnter", function(self) UI.ShowTip(self, "LEFT", "Pinto, the Girthy Dragon", tipText()) end)
  button:SetScript("OnLeave", function(self) UI.HideTip(self) end)
  place()
  MiniButton.Refresh()
end
