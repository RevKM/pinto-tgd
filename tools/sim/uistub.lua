-- uistub.lua: just enough of WoW's UI widgets to run Pinto's UI code offline. Every
-- frame, texture, line and font string records its geometry, so tests can check it and
-- render_svg.lua can draw it. Methods this stub doesn't know are accepted and ignored.
local U = {}

local STRATA = { BACKGROUND = 1, LOW = 2, MEDIUM = 3, HIGH = 4, DIALOG = 5, FULLSCREEN = 6, TOOLTIP = 7 }
local LAYER = { BACKGROUND = 1, BORDER = 2, ARTWORK = 3, OVERLAY = 4, HIGHLIGHT = 5 }
U.STRATA, U.LAYER = STRATA, LAYER

local seq = 0
U.frames = {}
U.time = 0

local function noop() end

local function method(mt, name, fn) mt.__methods[name] = fn end

local function newClass()
  local mt = { __methods = {} }
  mt.__index = function(_, k)
    local m = mt.__methods[k]
    if m then return m end
    if type(k) == "string" and k:match("^[A-Z]") then return noop end
    return nil
  end
  return mt
end

-- Regions (textures, lines, font strings) ---------------------------------------------

local Region = newClass()

local function newRegion(kind, frame, layer, sub)
  seq = seq + 1
  local r = setmetatable({ kind = kind, frame = frame, layer = layer or "ARTWORK", sub = sub or 0, seq = seq,
    shown = true, w = 0, h = 0, alpha = 1, vc = { 1, 1, 1, 1 }, points = {} }, Region)
  frame.regions[#frame.regions + 1] = r
  return r
end

method(Region, "SetPoint", function(self, point, rel, relPoint, x, y)
  if type(rel) == "number" then rel, relPoint, x, y = nil, point, rel, relPoint end
  if type(relPoint) == "number" then relPoint, x, y = point, relPoint, x end
  self.points[point] = { rel = rel, relPoint = relPoint or point, x = x or 0, y = y or 0 }
end)
method(Region, "ClearAllPoints", function(self) self.points = {} end)
method(Region, "SetAllPoints", function(self, rel) self.points = { ALL = { rel = rel } } end)
method(Region, "SetSize", function(self, w, h) self.w, self.h = w, h end)
method(Region, "SetWidth", function(self, w) self.w = w end)
method(Region, "SetHeight", function(self, h) self.h = h end)
method(Region, "GetWidth", function(self) return self.w end)
method(Region, "GetHeight", function(self) return self.h end)
method(Region, "Show", function(self) self.shown = true end)
method(Region, "Hide", function(self) self.shown = false end)
method(Region, "SetShown", function(self, v) self.shown = v and true or false end)
method(Region, "IsShown", function(self) return self.shown end)
method(Region, "IsVisible", function(self) return self.shown and self.frame:IsVisible() end)
method(Region, "SetAlpha", function(self, a) self.alpha = a end)
method(Region, "GetAlpha", function(self) return self.alpha end)
method(Region, "SetTexture", function(self, path) self.path = path; self.color = nil end)
method(Region, "GetTexture", function(self) return self.path end)
method(Region, "SetColorTexture", function(self, r, g, b, a) self.path = "color"; self.color = { r, g, b, a or 1 } end)
method(Region, "SetVertexColor", function(self, r, g, b, a) self.vc = { r, g, b, a or 1 } end)
method(Region, "SetTexCoord", function(self, ...)
  local n = select("#", ...)
  local v = { ... }
  if n == 4 then
    local l, r, t, b = v[1], v[2], v[3], v[4]
    v = { l, t, l, b, r, t, r, b }
  end
  for i = 1, 8 do
    if type(v[i]) ~= "number" or v[i] ~= v[i] or math.abs(v[i]) == math.huge then
      error("SetTexCoord got a bad value: " .. tostring(v[i]), 2)
    end
  end
  self.tc = v
end)
method(Region, "SetDrawLayer", function(self, layer, sub) self.layer, self.sub = layer, sub or 0 end)
method(Region, "SetRotation", function(self, a) self.rotation = a end)
method(Region, "SetBlendMode", function(self, m) self.blend = m end)
method(Region, "SetStartPoint", function(self, point, rel, x, y) self.p1 = { x = x, y = y } end)
method(Region, "SetEndPoint", function(self, point, rel, x, y) self.p2 = { x = x, y = y } end)
method(Region, "SetThickness", function(self, t) self.thickness = t end)
method(Region, "SetFont", function(self, font, size) self.font, self.size = font, size; return true end)
method(Region, "GetFont", function(self) return self.font or "Fonts\\FRIZQT__.TTF", self.size or 12, "" end)
method(Region, "SetFontObject", function(self) self.size = self.size or 12 end)
method(Region, "SetText", function(self, t) self.text = t end)
method(Region, "GetText", function(self) return self.text end)
method(Region, "SetTextColor", function(self, r, g, b, a) self.vc = { r, g, b, a or 1 } end)
method(Region, "GetStringWidth", function(self) return #(self.text or "") * (self.size or 12) * 0.5 end)
method(Region, "GetStringHeight", function(self) return self.size or 12 end)
method(Region, "GetObjectType", function(self) return self.kind end)

-- Frames -------------------------------------------------------------------------------------

local Frame = newClass()

function U.CreateFrame(kind, name, parent, template)
  seq = seq + 1
  local f = setmetatable({ kind = kind or "Frame", name = name, parent = parent, regions = {}, children = {},
    scripts = {}, shown = true, w = 0, h = 0, level = parent and (parent.level + 1) or 0,
    strata = parent and parent.strata or "MEDIUM", seq = seq, points = {}, events = {} }, Frame)
  if parent then parent.children[#parent.children + 1] = f end
  U.frames[#U.frames + 1] = f
  return f
end

method(Frame, "CreateTexture", function(self, name, layer, template, sub) return newRegion("Texture", self, layer, sub) end)
method(Frame, "CreateMaskTexture", function(self, name, layer) return newRegion("MaskTexture", self, layer, 0) end)
method(Frame, "CreateLine", function(self, name, layer, template, sub) return newRegion("Line", self, layer, sub) end)
method(Frame, "CreateFontString", function(self, name, layer) return newRegion("FontString", self, layer, 0) end)
method(Frame, "SetPoint", Region.__methods.SetPoint)
method(Frame, "ClearAllPoints", Region.__methods.ClearAllPoints)
method(Frame, "SetAllPoints", function(self, rel) self.points = { ALL = { rel = rel or self.parent } } end)
method(Frame, "SetSize", function(self, w, h)
  self.w, self.h = w, h
  local fn = self.scripts.OnSizeChanged
  if fn then fn(self, w, h) end
end)
method(Frame, "SetWidth", function(self, w) self.w = w end)
method(Frame, "SetHeight", function(self, h) self.h = h end)
method(Frame, "GetWidth", function(self)
  if self.points.ALL and self.points.ALL.rel then return self.points.ALL.rel:GetWidth() end
  return self.w
end)
method(Frame, "GetHeight", function(self)
  if self.points.ALL and self.points.ALL.rel then return self.points.ALL.rel:GetHeight() end
  return self.h
end)
method(Frame, "GetSize", function(self) return self:GetWidth(), self:GetHeight() end)
method(Frame, "SetAlpha", function(self, a) self.alpha = a end)
method(Frame, "GetAlpha", function(self) return self.alpha or 1 end)
method(Frame, "Show", function(self) self.shown = true end)
method(Frame, "Hide", function(self)
  self.shown = false
  local fn = self.scripts.OnHide
  if fn then fn(self) end
end)
method(Frame, "SetShown", function(self, v) if v then self:Show() else self:Hide() end end)
method(Frame, "IsShown", function(self) return self.shown end)
method(Frame, "IsVisible", function(self)
  local f = self
  while f do
    if not f.shown then return false end
    f = f.parent
  end
  return true
end)
method(Frame, "SetScript", function(self, name, fn) self.scripts[name] = fn end)
method(Frame, "GetScript", function(self, name) return self.scripts[name] end)
method(Frame, "HookScript", function(self, name, fn)
  local old = self.scripts[name]
  self.scripts[name] = function(...) if old then old(...) end fn(...) end
end)
method(Frame, "SetFrameLevel", function(self, l) self.level = l end)
method(Frame, "GetFrameLevel", function(self) return self.level end)
method(Frame, "SetFrameStrata", function(self, s) self.strata = s end)
method(Frame, "GetFrameStrata", function(self) return self.strata end)
method(Frame, "SetParent", function(self, p)
  if self.parent then
    for i, c in ipairs(self.parent.children) do
      if c == self then table.remove(self.parent.children, i) break end
    end
  end
  self.parent = p
  if p then p.children[#p.children + 1] = self end
end)
method(Frame, "GetParent", function(self) return self.parent end)
method(Frame, "GetName", function(self) return self.name end)
method(Frame, "RegisterEvent", function(self, e) self.events[e] = true end)
method(Frame, "UnregisterEvent", function(self, e) self.events[e] = nil end)
method(Frame, "GetCenter", function(self) return 0, 0 end)
method(Frame, "GetLeft", function(self) return 0 end)
method(Frame, "GetTop", function(self) return 0 end)
method(Frame, "GetEffectiveScale", function(self) return 1 end)
method(Frame, "GetObjectType", function(self) return self.kind end)
method(Frame, "SetText", function(self, t) self.text = t end)
method(Frame, "GetText", function(self) return self.text end)
method(Frame, "SetChecked", function(self, v) self.checked = v end)
method(Frame, "GetChecked", function(self) return self.checked end)
method(Frame, "SetValue", function(self, v)
  self.value = v
  local fn = self.scripts.OnValueChanged
  if fn then fn(self, v) end
end)
method(Frame, "GetValue", function(self) return self.value or 0 end)
method(Frame, "GetMinMaxValues", function(self) return 0, 1 end)
method(Frame, "SetMinMaxValues", function() end)
method(Frame, "GetVerticalScroll", function() return 0 end)

-- Runs OnUpdate for every shown frame.
function U.Update(elapsed)
  U.time = U.time + elapsed
  for _, f in ipairs(U.frames) do
    local fn = f.scripts.OnUpdate
    if fn and f:IsVisible() then fn(f, elapsed) end
  end
end

-- Every visible region under a frame, in WoW's draw order.
function U.Collect(root)
  local out = {}
  local function walk(f)
    if not f.shown then return end
    for _, r in ipairs(f.regions) do
      if r.shown and r.kind ~= "MaskTexture" then
        out[#out + 1] = { r = r, key = { STRATA[f.strata] or 3, f.level, LAYER[r.layer] or 3, r.sub or 0, r.seq } }
      end
    end
    for _, c in ipairs(f.children) do walk(c) end
  end
  walk(root)
  table.sort(out, function(a, b)
    for i = 1, 5 do
      if a.key[i] ~= b.key[i] then return a.key[i] < b.key[i] end
    end
    return false
  end)
  local list = {}
  for i, e in ipairs(out) do list[i] = e.r end
  return list
end

-- A global environment with the stub's widgets, for loading addon files.
function U.Env(extra)
  local env = setmetatable({}, { __index = _G })
  env._G = env
  env.CreateFrame = U.CreateFrame
  env.GetTime = function() return U.time end
  env.UIParent = U.CreateFrame("Frame", "UIParent")
  env.UIParent.w, env.UIParent.h = 1920, 1080
  env.Minimap = U.CreateFrame("Frame", "Minimap", env.UIParent)
  env.Minimap.w, env.Minimap.h = 140, 140
  env.GameTooltip = U.CreateFrame("Frame", "GameTooltip", env.UIParent)
  env.UISpecialFrames = {}
  env.GetCursorPosition = function() return 0, 0 end
  env.geterrorhandler = function() return function(e) error(e, 0) end end
  env.InCombatLockdown = function() return false end
  env.IsInInstance = function() return false, "none" end
  env.StaticPopupDialogs = {}
  env.StaticPopup_Show = function(which) U.popups = U.popups or {}; U.popups[#U.popups + 1] = which end
  env.OKAY, env.CANCEL = "Okay", "Cancel"
  for k, v in pairs(extra or {}) do env[k] = v end
  return env
end

return U
