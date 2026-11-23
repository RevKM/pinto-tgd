-- Drawing primitives for Pinto's scene.
--
-- WoW's UI can't fill paths, so everything is a texture or a line:
--   * any affine image of a texture (a rotated, scaled or sheared sprite) is drawn as an
--     axis-aligned texture over its bounding box, with 8-argument SetTexCoord mapping the
--     box's corners back into the texture. Textures have transparent borders, so the
--     parts of the box outside the shape stay invisible. Ellipses are the Circle texture,
--     pieces of Pinto are pre-drawn textures, and triangles are the Tri texture mapped
--     onto any three points;
--   * strokes are Line objects with a thickness.
--
-- Draw order: a canvas holds planes (child frames, one above the other), and each plane
-- holds groups (a draw layer and sublevel each), in the order they're created. Every frame
-- a group hands out pooled textures and hides whatever it didn't use.
--
-- Coordinates are the demo's scene units: x 0..680, y 20..440, y pointing down.
local ADDON, ns = ...

local Draw = {}
ns.RenderDraw = Draw

local floor, sqrt, min, max, abs = math.floor, math.sqrt, math.min, math.max, math.abs

local MEDIA = "Interface\\AddOns\\PintoTGD\\Media\\"
local LAYERS = { "BACKGROUND", "BORDER", "ARTWORK", "OVERLAY" }
local TRI_A, TRI_K = 8 / 256, 240 / 256

Draw.SCENE_W, Draw.SCENE_H, Draw.SCENE_Y = 680, 420, 20

-- Canvas ------------------------------------------------------------------------------

local Canvas = {}
Canvas.__index = Canvas

function Draw.NewCanvas(parent)
  local root = CreateFrame("Frame", nil, parent)
  local c = setmetatable({ root = root, planes = {}, s = 1, ox = 0, oy = 0, sil = 0 }, Canvas)
  return c
end

-- Fits the scene into the root frame, keeping its aspect.
function Canvas:Layout()
  local w, h = self.root:GetWidth() or 0, self.root:GetHeight() or 0
  if w <= 0 or h <= 0 then return false end
  local s = min(w / Draw.SCENE_W, h / Draw.SCENE_H)
  local changed = s ~= self.s
  self.s = s
  self.ox = (w - Draw.SCENE_W * s) / 2
  self.oy = (h - Draw.SCENE_H * s) / 2
  return changed
end

-- Scene point -> offsets from the root's TOPLEFT (x right, y up).
function Canvas:ToFrame(x, y)
  return self.ox + x * self.s, -(self.oy + (y - Draw.SCENE_Y) * self.s)
end

function Canvas:ToScene(fx, fy)
  return (fx - self.ox) / self.s, (-fy - self.oy) / self.s + Draw.SCENE_Y
end

local Plane = {}
Plane.__index = Plane

function Canvas:Plane(name, levelOffset, strata)
  local f = CreateFrame("Frame", nil, self.root)
  f:SetAllPoints(self.root)
  f:SetFrameLevel(self.root:GetFrameLevel() + (levelOffset or (#self.planes + 1)))
  if strata then f:SetFrameStrata(strata) end
  local p = setmetatable({ name = name, frame = f, canvas = self, groups = {}, slot = 0 }, Plane)
  self.planes[#self.planes + 1] = p
  return p
end

local Group = {}
Group.__index = Group

-- A group draws above every group created before it in the same plane.
function Plane:Group(name)
  local slot = self.slot
  self.slot = slot + 1
  local layer = LAYERS[floor(slot / 16) + 1] or "OVERLAY"
  local sub = (slot % 16) - 8
  local g = setmetatable({ name = name, plane = self, canvas = self.canvas, layer = layer, sub = sub,
    tex = {}, lines = {}, texts = {}, nt = 0, nl = 0, nx = 0, nf = 0 }, Group)
  self.groups[#self.groups + 1] = g
  return g
end

function Plane:Begin()
  for _, g in ipairs(self.groups) do g.nt, g.nl, g.nx, g.nf = 0, 0, 0, 0 end
end

function Plane:End()
  for _, g in ipairs(self.groups) do g:Finish() end
end

function Group:Finish()
  for i = self.nt + 1, #self.tex do
    local t = self.tex[i]
    if t.shown then
      t:Hide()
      t.shown = false
    end
  end
  for i = self.nl + 1, #self.lines do
    local l = self.lines[i]
    if l.shown then
      l:Hide()
      l.shown = false
    end
  end
  for i = self.nx + 1, #self.texts do
    local x = self.texts[i]
    if x.shown then
      x:Hide()
      x.shown = false
    end
  end
end

-- Colours -------------------------------------------------------------------------------
-- Colours are { r, g, b } in 0..1. The silhouette blends everything toward black.

function Draw.Hex(h)
  h = h:gsub("#", "")
  return { tonumber(h:sub(1, 2), 16) / 255, tonumber(h:sub(3, 4), 16) / 255, tonumber(h:sub(5, 6), 16) / 255 }
end
local WHITE = { 1, 1, 1 }

local function setColor(obj, col, alpha, sil)
  col = col or WHITE
  local k = 1 - sil
  local r, g, b, a = col[1] * k, col[2] * k, col[3] * k, alpha or 1
  if obj.cr ~= r or obj.cg ~= g or obj.cb ~= b or obj.ca ~= a then
    obj.cr, obj.cg, obj.cb, obj.ca = r, g, b, a
    obj:SetVertexColor(r, g, b, a)
  end
end

-- Textures ------------------------------------------------------------------------------

-- Newer clients snap textures and lines to whole pixels, which makes slowly moving parts
-- step a pixel at a time and look grainy. The scene turns that off where it can.
local function smooth(obj)
  if obj.SetSnapToPixelGrid then
    obj:SetSnapToPixelGrid(false)
    obj:SetTexelSnappingBias(0)
  end
end

function Group:Texture(path)
  local n = self.nt + 1
  self.nt = n
  local t = self.tex[n]
  if not t then
    t = self.plane.frame:CreateTexture(nil, self.layer, nil, self.sub)
    smooth(t)
    self.tex[n] = t
  end
  if t.path ~= path then
    t.path = path
    t.ox, t.rl = nil, nil
    if path == "color" then
      t:SetColorTexture(1, 1, 1, 1)
    else
      -- plain bilinear, never mipmapped: a sheared triangle's box would pick a tiny mip
      -- level and fill the whole box with a see-through blur
      t:SetTexture(path, "CLAMP", "CLAMP", "LINEAR")
    end
    t.cr = nil
  end
  if not t.shown then
    t:Show()
    t.shown = true
  end
  return t
end

-- A part that moved less than this many frame pixels since it was last placed stays where
-- it is: nobody sees the difference, and every placement costs the game a layout pass.
-- While Pinto only breathes, most of him moves less than that from one frame to the next.
local EPS = 0.12
Draw.EPS = EPS

-- Places texture t over the frame-space parallelogram O + s·U + t·V (s, t in 0..1 of the
-- texture), as an axis-aligned box with the matching texture coordinates.
local function placeAffine(c, t, Ox, Oy, Ux, Uy, Vx, Vy)
  local det = Ux * Vy - Uy * Vx
  if abs(det) < 1e-9 then
    if t.shown then
      t:Hide()
      t.shown = false
    end
    t.ox = nil
    return false
  end
  local ox = t.ox
  if ox and abs(Ox - ox) < EPS and abs(Oy - t.oy) < EPS and abs(Ux - t.ux) < EPS and abs(Uy - t.uy) < EPS
    and abs(Vx - t.vx) < EPS and abs(Vy - t.vy) < EPS then
    return true
  end
  t.ox, t.oy, t.ux, t.uy, t.vx, t.vy = Ox, Oy, Ux, Uy, Vx, Vy
  t.rl = nil
  local x1, x2 = Ox, Ox
  local y1, y2 = Oy, Oy
  local px, py = Ox + Ux, Oy + Uy
  if px < x1 then x1 = px elseif px > x2 then x2 = px end
  if py < y1 then y1 = py elseif py > y2 then y2 = py end
  px, py = Ox + Vx, Oy + Vy
  if px < x1 then x1 = px elseif px > x2 then x2 = px end
  if py < y1 then y1 = py elseif py > y2 then y2 = py end
  px, py = Ox + Ux + Vx, Oy + Uy + Vy
  if px < x1 then x1 = px elseif px > x2 then x2 = px end
  if py < y1 then y1 = py elseif py > y2 then y2 = py end
  -- the box's corners -> texture coordinates
  local inv = 1 / det
  local ax, ay, bx, by = (x1 - Ox) * inv, (y1 - Oy) * inv, (x2 - Ox) * inv, (y2 - Oy) * inv
  t:SetTexCoord(ax * Vy - by * Vx, Ux * by - Uy * ax, ax * Vy - ay * Vx, Ux * ay - Uy * ax,
    bx * Vy - by * Vx, Ux * by - Uy * bx, bx * Vy - ay * Vx, Ux * ay - Uy * bx)
  t:SetPoint("TOPLEFT", c.root, "TOPLEFT", x1, y2)
  t:SetSize(max(x2 - x1, 0.01), max(y2 - y1, 0.01))
  return true
end
Draw.placeAffine = placeAffine

-- A media texture (from Render/MediaData.lua) through a local -> scene affine transform
-- m = { a, b, c, d, e, f }: scene = (a·x + c·y + e, b·x + d·y + f).
function Group:Sprite(name, m, col, alpha)
  local media = ns.RenderMedia[name]
  if not media then return end
  local c = self.canvas
  local t = self:Texture(media[1])
  local x0, y0, x1, y1 = media[2], media[3], media[4], media[5]
  local a, b, cc, d, e, f = m[1], m[2], m[3], m[4], m[5], m[6]
  local s = c.s
  -- texture corners in scene units
  local sx0, sy0 = a * x0 + cc * y0 + e, b * x0 + d * y0 + f
  local sx1, sy1 = a * x1 + cc * y0 + e, b * x1 + d * y0 + f
  local sx2, sy2 = a * x0 + cc * y1 + e, b * x0 + d * y1 + f
  local Ox, Oy = c:ToFrame(sx0, sy0)
  if placeAffine(c, t, Ox, Oy, (sx1 - sx0) * s, -(sy1 - sy0) * s, (sx2 - sx0) * s, -(sy2 - sy0) * s) then
    setColor(t, col, alpha, c.sil)
  end
end

-- Transform helpers: translate, rotate (radians, clockwise on screen like SVG) and scale.
function Draw.M(tx, ty, angle, sx, sy)
  local co, si = math.cos(angle or 0), math.sin(angle or 0)
  sx = sx or 1
  sy = sy or sx
  return { co * sx, si * sx, -si * sy, co * sy, tx, ty }
end

local CIRCLE = MEDIA .. "Circle"

-- An ellipse with semi-axes rx, ry, turned by angle (radians, clockwise on screen).
function Group:Ellipse(cx, cy, rx, ry, angle, col, alpha)
  if rx <= 0 or ry <= 0 then return end
  self:Sprite("Circle", Draw.M(cx, cy, angle, rx, ry), col, alpha)
end

function Group:Circle(cx, cy, r, col, alpha)
  if r <= 0 then return end
  self:Sprite("Circle", { r, 0, 0, r, cx, cy }, col, alpha)
end

-- A triangle, grown by `grow` frame pixels on every side so neighbours overlap and no
-- seams show between them.
local TRI = MEDIA .. "Tri"

-- The unit normal of the edge p -> r, pointing out of a triangle wound sgn.
local function edgeNormal(sgn, px, py, rx, ry)
  local dx, dy = rx - px, ry - py
  local l = sqrt(dx * dx + dy * dy)
  if l < 1e-9 then return 0, 0 end
  return sgn * dy / l, -sgn * dx / l
end

-- Vertex v moved out by grow along the bisector of its edges' normals m and n (a capped
-- miter).
local function pushOut(grow, vx, vy, mx, my, nx, ny)
  local dot = 1 + mx * nx + my * ny
  if dot < 0.1 then dot = 0.1 end
  local k = grow / dot
  return vx + (mx + nx) * k, vy + (my + ny) * k
end

function Group:Tri(x1, y1, x2, y2, x3, y3, col, alpha, grow)
  local c = self.canvas
  local s = c.s
  grow = grow or 0.5
  -- the same triangle as last time, give or take EPS: nothing to work out or move
  local t = self.tex[self.nt + 1]
  if t and t.tx1 and t.path == TRI and t.shown and t.ts == s and t.tox == c.ox and t.toy == c.oy and t.tg == grow then
    local e = EPS / s
    if abs(x1 - t.tx1) < e and abs(y1 - t.ty1) < e and abs(x2 - t.tx2) < e and abs(y2 - t.ty2) < e
      and abs(x3 - t.tx3) < e and abs(y3 - t.ty3) < e then
      self.nt = self.nt + 1
      setColor(t, col, alpha, c.sil)
      return
    end
  end
  local ox, oy = c.ox, c.oy + Draw.SCENE_Y * -s
  -- scene -> frame, as Canvas:ToFrame does
  local ax, ay = ox + x1 * s, -(oy + y1 * s)
  local bx, by = ox + x2 * s, -(oy + y2 * s)
  local qx, qy = ox + x3 * s, -(oy + y3 * s)
  if grow > 0 then
    local area = (bx - ax) * (qy - ay) - (by - ay) * (qx - ax)
    if abs(area) < 1e-6 then return end
    local sgn = area > 0 and 1 or -1
    local n1x, n1y = edgeNormal(sgn, ax, ay, bx, by)
    local n2x, n2y = edgeNormal(sgn, bx, by, qx, qy)
    local n3x, n3y = edgeNormal(sgn, qx, qy, ax, ay)
    local nax, nay = pushOut(grow, ax, ay, n3x, n3y, n1x, n1y)
    local nbx, nby = pushOut(grow, bx, by, n1x, n1y, n2x, n2y)
    local nqx, nqy = pushOut(grow, qx, qy, n2x, n2y, n3x, n3y)
    ax, ay, bx, by, qx, qy = nax, nay, nbx, nby, nqx, nqy
  end
  t = self:Texture(TRI)
  -- texture (s, t): A=(a, a) -> P1, B=(a+k, a) -> P2, C=(a, a+k) -> P3
  local Ux, Uy = (bx - ax) / TRI_K, (by - ay) / TRI_K
  local Vx, Vy = (qx - ax) / TRI_K, (qy - ay) / TRI_K
  local Ox, Oy = ax - TRI_A * Ux - TRI_A * Vx, ay - TRI_A * Uy - TRI_A * Vy
  t.ox = nil
  if placeAffine(c, t, Ox, Oy, Ux, Uy, Vx, Vy) then
    t.tx1, t.ty1, t.tx2, t.ty2, t.tx3, t.ty3 = x1, y1, x2, y2, x3, y3
    t.ts, t.tox, t.toy, t.tg = s, c.ox, c.oy, grow
    setColor(t, col, alpha, c.sil)
  else
    t.tx1 = nil
  end
end

-- A filled rectangle in scene units, axis-aligned. raw: not darkened by the silhouette.
function Group:Rect(x1, y1, x2, y2, col, alpha, raw)
  local c = self.canvas
  local t = self:Texture("color")
  local fx1, fy1 = c:ToFrame(x1, y1)
  local fx2, fy2 = c:ToFrame(x2, y2)
  local left, top, w, h = min(fx1, fx2), max(fy1, fy2), max(abs(fx2 - fx1), 0.01), max(abs(fy2 - fy1), 0.01)
  if t.rl ~= left or t.rt ~= top or t.rw ~= w or t.rh ~= h then
    t.rl, t.rt, t.rw, t.rh, t.ox = left, top, w, h, nil
    t:SetPoint("TOPLEFT", c.root, "TOPLEFT", left, top)
    t:SetSize(w, h)
  end
  setColor(t, col, alpha, raw and 0 or c.sil)
end

-- An axis-aligned piece of a media texture: scene rect -> the same rect of the texture box.
function Group:Slice(name, x1, y1, x2, y2, alpha)
  local media = ns.RenderMedia[name]
  if not media then return end
  local c = self.canvas
  local t = self:Texture(media[1])
  t.ox, t.rl = nil, nil
  local bx0, by0, bx1, by1 = media[2], media[3], media[4], media[5]
  local fx1, fy1 = c:ToFrame(x1, y1)
  local fx2, fy2 = c:ToFrame(x2, y2)
  t:SetTexCoord((x1 - bx0) / (bx1 - bx0), (x2 - bx0) / (bx1 - bx0), (y1 - by0) / (by1 - by0), (y2 - by0) / (by1 - by0))
  t:SetPoint("TOPLEFT", c.root, "TOPLEFT", fx1, fy1)
  t:SetSize(max(fx2 - fx1, 0.01), max(fy1 - fy2, 0.01))
  setColor(t, nil, alpha, c.sil)
end

-- Lines ----------------------------------------------------------------------------------

function Group:Line(x1, y1, x2, y2, width, col, alpha)
  local c = self.canvas
  local n = self.nl + 1
  self.nl = n
  local l = self.lines[n]
  if not l then
    l = self.plane.frame:CreateLine(nil, self.layer, nil, self.sub)
    l:SetColorTexture(1, 1, 1, 1)
    smooth(l)
    self.lines[n] = l
  end
  if not l.shown then
    l:Show()
    l.shown = true
  end
  local ax, ay = c:ToFrame(x1, y1)
  local bx, by = c:ToFrame(x2, y2)
  local lx = l.ax
  if not (lx and abs(ax - lx) < EPS and abs(ay - l.ay) < EPS and abs(bx - l.bx) < EPS and abs(by - l.by) < EPS) then
    l.ax, l.ay, l.bx, l.by = ax, ay, bx, by
    l:SetStartPoint("TOPLEFT", c.root, ax, ay)
    l:SetEndPoint("TOPLEFT", c.root, bx, by)
  end
  local th = max(0.5, width * c.s)
  if l.th ~= th then
    l.th = th
    l:SetThickness(th)
  end
  setColor(l, col, alpha, c.sil)
end

-- A polyline (flat list x1, y1, x2, y2, ...). Round caps and joins add small discs,
-- for thick strokes where the corners would show.
function Group:Poly(pts, width, col, alpha, round)
  local n = #pts
  for i = 1, n - 3, 2 do
    self:Line(pts[i], pts[i + 1], pts[i + 2], pts[i + 3], width, col, alpha)
  end
  if round then
    for i = 1, n - 1, 2 do self:Circle(pts[i], pts[i + 1], width / 2, col, alpha) end
  end
end

-- Text ------------------------------------------------------------------------------------

function Group:Text(text, x, y, size, col, alpha)
  local c = self.canvas
  local n = self.nx + 1
  self.nx = n
  local fs = self.texts[n]
  if not fs then
    fs = self.plane.frame:CreateFontString(nil, self.layer)
    self.texts[n] = fs
  end
  if not fs.shown then
    fs:Show()
    fs.shown = true
  end
  local px = max(6, floor(size * c.s + 0.5))
  if fs.px ~= px then
    fs.px = px
    fs:SetFont("Fonts\\FRIZQT__.TTF", px, "")
  end
  if fs.text ~= text then
    fs.text = text
    fs:SetText(text)
  end
  local fx, fy = c:ToFrame(x, y)
  fs:SetPoint("BOTTOMLEFT", c.root, "TOPLEFT", fx, fy)
  local k = 1 - c.sil
  fs:SetTextColor(col[1] * k, col[2] * k, col[3] * k, alpha or 1)
end

-- Shapes ------------------------------------------------------------------------------------

-- Fills a star-shaped polygon (flat point list) as a fan from its centroid.
function Group:Fan(pts, col, alpha, grow)
  local n = #pts / 2
  if n < 3 then return end
  local cx, cy = 0, 0
  for i = 1, #pts, 2 do
    cx, cy = cx + pts[i], cy + pts[i + 1]
  end
  cx, cy = cx / n, cy / n
  for i = 1, #pts, 2 do
    local j = i + 2
    if j > #pts then j = 1 end
    self:Tri(cx, cy, pts[i], pts[i + 1], pts[j], pts[j + 1], col, alpha, grow)
  end
end

-- Fills the band between two point lists of equal length (flat lists).
function Group:Strip(lo, hi, col, alpha, grow)
  for i = 1, #lo - 3, 2 do
    self:Tri(lo[i], lo[i + 1], lo[i + 2], lo[i + 3], hi[i], hi[i + 1], col, alpha, grow)
    self:Tri(hi[i], hi[i + 1], lo[i + 2], lo[i + 3], hi[i + 2], hi[i + 3], col, alpha, grow)
  end
end

-- Ear clipping: the triangles of a simple polygon (flat point list), as a flat list of
-- vertex numbers, plus the polygon's winding.
local function earClip(pts, n)
  local idx = {}
  local area = 0
  for i = 1, n do
    idx[i] = i
    local j = i % n + 1
    area = area + pts[2 * i - 1] * pts[2 * j] - pts[2 * j - 1] * pts[2 * i]
  end
  local sgn = area > 0 and 1 or -1
  local tris = {}
  local guard = 0
  while #idx > 3 and guard < 4 * n do
    guard = guard + 1
    local m = #idx
    local clipped = false
    for k = 1, m do
      local a, b, cc = idx[(k - 2) % m + 1], idx[k], idx[k % m + 1]
      local ax, ay, bx, by = pts[2 * a - 1], pts[2 * a], pts[2 * b - 1], pts[2 * b]
      local cx, cy = pts[2 * cc - 1], pts[2 * cc]
      local cross = (bx - ax) * (cy - ay) - (by - ay) * (cx - ax)
      if cross * sgn > 1e-9 then
        local ear = true
        for q = 1, m do
          local p = idx[q]
          if p ~= a and p ~= b and p ~= cc then
            local px, py = pts[2 * p - 1], pts[2 * p]
            local d1 = (bx - ax) * (py - ay) - (by - ay) * (px - ax)
            local d2 = (cx - bx) * (py - by) - (cy - by) * (px - bx)
            local d3 = (ax - cx) * (py - cy) - (ay - cy) * (px - cx)
            if d1 * sgn >= 0 and d2 * sgn >= 0 and d3 * sgn >= 0 then
              ear = false
              break
            end
          end
        end
        if ear then
          tris[#tris + 1], tris[#tris + 2], tris[#tris + 3] = a, b, cc
          table.remove(idx, k)
          clipped = true
          break
        end
      end
    end
    if not clipped then break end
  end
  if #idx == 3 then tris[#tris + 1], tris[#tris + 2], tris[#tris + 3] = idx[1], idx[2], idx[3] end
  return tris, sgn
end

-- Whether last frame's triangles still fit the polygon: every one keeps its winding.
local function stillFits(tris, sgn, pts)
  for i = 1, #tris, 3 do
    local a, b, c = tris[i], tris[i + 1], tris[i + 2]
    local ax, ay = pts[2 * a - 1], pts[2 * a]
    local cross = (pts[2 * b - 1] - ax) * (pts[2 * c] - ay) - (pts[2 * b] - ay) * (pts[2 * c - 1] - ax)
    if cross * sgn <= 1e-9 then return false end
  end
  return true
end

-- Fills any simple polygon by ear clipping (flat point list). A polygon that only moves a
-- little from frame to frame, like the breathing wing, keeps last frame's triangles for as
-- long as they fit, which saves finding the ears again.
function Group:Fill(pts, col, alpha, grow)
  local n = #pts / 2
  if n < 3 then return end
  local k = self.nf + 1
  self.nf = k
  self.fills = self.fills or {}
  local cache = self.fills[k]
  if not (cache and cache.n == n and stillFits(cache.tris, cache.sgn, pts)) then
    local tris, sgn = earClip(pts, n)
    cache = { n = n, tris = tris, sgn = sgn }
    self.fills[k] = cache
  end
  local tris = cache.tris
  for i = 1, #tris, 3 do
    local a, b, c = tris[i], tris[i + 1], tris[i + 2]
    self:Tri(pts[2 * a - 1], pts[2 * a], pts[2 * b - 1], pts[2 * b], pts[2 * c - 1], pts[2 * c], col, alpha, grow)
  end
end

-- Moves every vertex of a closed polygon outward by d scene units (along the average of
-- its two edge normals). Returns a new flat list.
function Draw.Offset(pts, d)
  local n = #pts / 2
  local out = {}
  local area = 0
  for i = 1, n do
    local j = i % n + 1
    area = area + pts[2 * i - 1] * pts[2 * j] - pts[2 * j - 1] * pts[2 * i]
  end
  local sgn = area > 0 and -1 or 1
  for i = 1, n do
    local p = (i - 2) % n + 1
    local q = i % n + 1
    local ex1, ey1 = pts[2 * i - 1] - pts[2 * p - 1], pts[2 * i] - pts[2 * p]
    local ex2, ey2 = pts[2 * q - 1] - pts[2 * i - 1], pts[2 * q] - pts[2 * i]
    local l1 = sqrt(ex1 * ex1 + ey1 * ey1)
    local l2 = sqrt(ex2 * ex2 + ey2 * ey2)
    local nx, ny = 0, 0
    if l1 > 1e-9 then nx, ny = nx + sgn * ey1 / l1, ny - sgn * ex1 / l1 end
    if l2 > 1e-9 then nx, ny = nx + sgn * ey2 / l2, ny - sgn * ex2 / l2 end
    local l = sqrt(nx * nx + ny * ny)
    if l > 1e-9 then nx, ny = nx / l, ny / l end
    out[2 * i - 1] = pts[2 * i - 1] + nx * d
    out[2 * i] = pts[2 * i] + ny * d
  end
  return out
end

-- Root frame visibility helpers
function Canvas:Show() self.root:Show() end
function Canvas:Hide() self.root:Hide() end
