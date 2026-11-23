-- Shared UI helpers: window frames, buttons, text, haunch icons and UTF-8 glyphs.
local ADDON, ns = ...

local UI = {}
ns.UI = UI

local MEDIA = "Interface\\AddOns\\PintoTGD\\Media\\"
UI.MEDIA = MEDIA

function UI.Media(name)
  local m = ns.Render and ns.Render.MEDIA
  if m and m[name] then return m[name] end
  return MEDIA .. name
end

UI.colors = {
  text = { 1, 0.82, 0 },
  body = { 0.9, 0.9, 0.85 },
  muted = { 0.6, 0.6, 0.6 },
  good = { 0.36, 0.79, 0.65 },
}

local backdropTemplate = BackdropTemplateMixin and "BackdropTemplate" or nil

-- The cave behind Pinto, inside the window's border: from the left edge to `right` pixels
-- from the window's left (the whole window without it), top to bottom. It fills that
-- area like a cover photo, centred: the picture keeps its shape and the overflow is cut
-- off. With `right`, its last 2% fades out, so the quest side keeps the window's own
-- see-through background. Media/Cave is the picture squeezed to 1024x512 (see
-- tools/backdrop.py); CAVE_ASPECT is its real shape.
local CAVE_ASPECT = 1672 / 941
function UI.Cave(f, inset, right)
  local t = f:CreateTexture(nil, "BACKGROUND", nil, 1)
  t:SetTexture(MEDIA .. "Cave", "CLAMP", "CLAMP", "TRILINEAR")
  t:SetPoint("TOPLEFT", inset, -inset)
  if right then
    t:SetPoint("BOTTOMRIGHT", f, "BOTTOMLEFT", right, inset)
    if f.CreateMaskTexture and t.AddMaskTexture then
      local mask = f:CreateMaskTexture(nil, "BACKGROUND")
      mask:SetTexture(MEDIA .. "FadeRight", "CLAMPTOBLACKADDITIVE", "CLAMPTOBLACKADDITIVE")
      mask:SetAllPoints(t)
      t:AddMaskTexture(mask)
      t.mask = mask
    end
  else
    t:SetPoint("BOTTOMRIGHT", -inset, inset)
  end
  local function crop()
    local w = (right or ((f:GetWidth() or 0) - inset)) - inset
    local h = (f:GetHeight() or 0) - 2 * inset
    if w <= 0 or h <= 0 then return end
    local a = w / h
    if a > CAVE_ASPECT then
      local k = CAVE_ASPECT / a
      t:SetTexCoord(0, 1, (1 - k) / 2, (1 + k) / 2)
    else
      local k = a / CAVE_ASPECT
      t:SetTexCoord((1 - k) / 2, (1 + k) / 2, 0, 1)
    end
  end
  f:HookScript("OnSizeChanged", crop)
  crop()
  return t
end

-- The dark background behind Pinto's silhouette while the addon syncs: over the whole cave,
-- fading out where the cave does. The scene sets how much of it shows (Scene:SetBackdrop).
function UI.CaveCover(f, cave)
  local t = f:CreateTexture(nil, "BACKGROUND", nil, 2)
  t:SetAllPoints(cave)
  local c = ns.Render and ns.Render.SILHOUETTE_BG or { 0.227, 0.239, 0.251 }
  t:SetColorTexture(c[1], c[2], c[3])
  if cave.mask and t.AddMaskTexture then t:AddMaskTexture(cave.mask) end
  t:SetAlpha(0)
  return t
end

-- A movable window with the game's dark, see-through dialog background and a close button.
function UI.Window(name, width, height)
  local f = CreateFrame("Frame", name, UIParent, backdropTemplate)
  f:SetSize(width, height)
  f:SetFrameStrata("HIGH")
  f:SetToplevel(true)
  f:SetClampedToScreen(true)
  f:SetMovable(true)
  f:EnableMouse(true)
  f:RegisterForDrag("LeftButton")
  f:SetScript("OnDragStart", f.StartMoving)
  f:SetScript("OnDragStop", function(self)
    self:StopMovingOrSizing()
    UI.SavePosition(self)
  end)
  if f.SetBackdrop then
    f:SetBackdrop({
      bgFile = "Interface\\DialogFrame\\UI-DialogBox-Background-Dark",
      edgeFile = "Interface\\DialogFrame\\UI-DialogBox-Border",
      tile = true, tileSize = 32, edgeSize = 24,
      insets = { left = 6, right = 6, top = 6, bottom = 6 },
    })
  end
  local close = CreateFrame("Button", nil, f, "UIPanelCloseButton")
  close:SetPoint("TOPRIGHT", -2, -2)
  f.close = close
  f:Hide()
  if name and UISpecialFrames then table.insert(UISpecialFrames, name) end
  return f
end

function UI.SavePosition(f)
  local ui = UI.Settings()
  local point, _, relPoint, x, y = f:GetPoint(1)
  ui.positions = ui.positions or {}
  ui.positions[f:GetName() or "?"] = { point, relPoint, x, y }
end

function UI.RestorePosition(f, defaultX, defaultY)
  local ui = UI.Settings()
  local p = ui.positions and ui.positions[f:GetName() or "?"]
  f:ClearAllPoints()
  if p then
    f:SetPoint(p[1], UIParent, p[2], p[3], p[4])
  else
    f:SetPoint("CENTER", UIParent, "CENTER", defaultX or 0, defaultY or 0)
  end
end

-- Account-local UI settings: positions, the window size used last, whether the small window
-- opens on start, the minimap angle, what the player last saw.
function UI.Settings()
  PintoTGD_DB.ui = PintoTGD_DB.ui or {}
  return PintoTGD_DB.ui
end

function UI.Text(parent, template, layer)
  local fs = parent:CreateFontString(nil, layer or "OVERLAY", template or "GameFontHighlight")
  fs:SetJustifyH("LEFT")
  fs:SetJustifyV("TOP")
  return fs
end

function UI.Button(parent, text, width, height)
  local b = CreateFrame("Button", nil, parent, "UIPanelButtonTemplate")
  b:SetSize(width or 80, height or 22)
  b:SetText(text)
  return b
end

-- Pinto's own tooltip, in the game's tooltip style. The game's tooltip is shared with its
-- secure code, and an addon that shows it taints it, so Pinto never touches it.
local TIP_WIDTH = 260
local tip

local function buildTip()
  tip = CreateFrame("Frame", nil, UIParent, backdropTemplate)
  tip:SetFrameStrata("TOOLTIP")
  tip:SetClampedToScreen(true)
  if tip.SetBackdrop then
    tip:SetBackdrop({
      bgFile = "Interface\\Tooltips\\UI-Tooltip-Background",
      edgeFile = "Interface\\Tooltips\\UI-Tooltip-Border",
      tile = true, tileSize = 16, edgeSize = 16,
      insets = { left = 4, right = 4, top = 4, bottom = 4 },
    })
    tip:SetBackdropColor(0.09, 0.09, 0.19, 0.95)
    tip:SetBackdropBorderColor(1, 1, 1, 1)
  end
  tip.title = UI.Text(tip, "GameFontNormal")
  tip.title:SetPoint("TOPLEFT", 10, -10)
  tip.body = UI.Text(tip, "GameFontHighlight")
  -- it goes with the frame it belongs to, like the game's tooltip
  tip:SetScript("OnUpdate", function(self)
    if not (self.owner and self.owner:IsVisible()) then self:Hide() end
  end)
  tip:Hide()
end

local function naturalWidth(fs, text)
  fs:SetText(text)
  return fs.GetUnboundedStringWidth and fs:GetUnboundedStringWidth() or fs:GetStringWidth()
end

-- Shows the tooltip above `owner`, on its "LEFT" or "RIGHT" side: a gold title and white,
-- wrapped text, either of them optional.
function UI.ShowTip(owner, side, title, text)
  if not tip then buildTip() end
  tip.owner = owner
  local w = math.max(title and naturalWidth(tip.title, title) or 0, text and naturalWidth(tip.body, text) or 0)
  w = math.ceil(math.min(TIP_WIDTH, w))
  tip.title:SetWidth(w)
  tip.body:SetWidth(w)
  tip.title:SetShown(title ~= nil)
  tip.body:SetShown(text ~= nil)
  tip.body:ClearAllPoints()
  if title then
    tip.body:SetPoint("TOPLEFT", tip.title, "BOTTOMLEFT", 0, -3)
  else
    tip.body:SetPoint("TOPLEFT", 10, -10)
  end
  local h = (title and tip.title:GetStringHeight() or 0) + (text and tip.body:GetStringHeight() or 0)
  if title and text then h = h + 3 end
  tip:SetSize(w + 20, math.ceil(h) + 20)
  tip:ClearAllPoints()
  if side == "LEFT" then
    tip:SetPoint("BOTTOMRIGHT", owner, "TOPLEFT", 0, 0)
  else
    tip:SetPoint("BOTTOMLEFT", owner, "TOPRIGHT", 0, 0)
  end
  tip:Show()
end

-- Hides the tooltip; with an owner, only if it's that frame's.
function UI.HideTip(owner)
  if tip and (owner == nil or tip.owner == owner) then tip:Hide() end
end

function UI.Tip() return tip end

-- A small square icon button with a tooltip.
function UI.IconButton(parent, texture, size, tooltip)
  local b = CreateFrame("Button", nil, parent)
  b:SetSize(size, size)
  local t = b:CreateTexture(nil, "ARTWORK")
  t:SetAllPoints()
  t:SetTexture(texture)
  b.icon = t
  b:SetHighlightTexture("Interface\\Buttons\\ButtonHilight-Square", "ADD")
  if tooltip then
    b:SetScript("OnEnter", function(self) UI.ShowTip(self, "RIGHT", nil, tooltip) end)
    b:SetScript("OnLeave", function(self) UI.HideTip(self) end)
  end
  return b
end

-- The haunch icon, as a texture on a parent.
function UI.Haunch(parent, size, layer)
  local t = parent:CreateTexture(nil, layer or "ARTWORK")
  t:SetSize(size, size)
  t:SetTexture(UI.Media("Haunch"))
  return t
end

-- Splits text into UTF-8 characters.
function UI.Glyphs(text)
  local list = {}
  for ch in text:gmatch("[\1-\127\194-\244][\128-\191]*") do list[#list + 1] = ch end
  return list
end

-- Easing
function UI.Smooth(t)
  if t <= 0 then return 0 end
  if t >= 1 then return 1 end
  return t * t * (3 - 2 * t)
end
