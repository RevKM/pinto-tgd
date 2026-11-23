-- Pinto's scene: the demo's math (build, map, span, draw, the K keyframes and EATS),
-- ported from docs/reference/dragon_hoard_smooth_neck.html almost line for line, drawn
-- with the primitives in Render/Draw.lua.
local ADDON, ns = ...

local Render = {}
ns.Render = Render

local Draw = ns.RenderDraw
local M = Draw.M

local sin, cos, sqrt, abs, min, max, floor, exp = math.sin, math.cos, math.sqrt, math.abs, math.min, math.max,
  math.floor, math.exp
local atan2 = math.atan2
local PI = math.pi
local TP = PI * 2

-- The demo's constants
local G, CX, X0, DX, N, IC, NC, HK, EX, EY = 392, 350, -260, 2, 601, 305, 26, 1.12, 50, -28
local HGX, HGY = 40, -12
local JLX, JLY = 16, -20

local function lerp(a, b, t) return a + (b - a) * t end
local function clamp(v, a, b)
  if v < a then return a end
  if v > b then return b end
  return v
end
local function sst(a, b, x)
  local t = clamp((x - a) / (b - a), 0, 1)
  return t * t * (3 - 2 * t)
end
local function sc(v) return 0.5 * (v + sqrt(v * v + 16)) end
local function rot(x, y, a)
  local c, s = cos(a), sin(a)
  return x * c - y * s, x * s + y * c
end
local function rotA(px, py, hx, hy, a)
  local rx, ry = rot(px - hx, py - hy, a)
  return hx + rx, hy + ry
end
local function dirW(d)
  local a = d * PI / 180
  return cos(a), -sin(a)
end
local function hypot(x, y) return sqrt(x * x + y * y) end

-- keyframes: { t0, v0, t1, v1, ... }, smoothstep between pairs
local function kf(k, e)
  if e <= k[1] then return k[2] end
  for i = 2, #k - 1, 2 do
    if e < k[i + 1] then
      local a = k[i - 1]
      local u = (e - a) / (k[i + 1] - a)
      return k[i] + (k[i + 2] - k[i]) * u * u * (3 - 2 * u)
    end
  end
  return k[#k]
end

local KF = { 0, 0.22, 0.47, 0.73, 1 }
local K = {
  phi = { 30, 26, 50, 56, 70 }, ln = { 58, 60, 64, 64, 66 }, pitch = { -10, -16, 2, 8, 22 }, dw = { 1, 0, 0, 0, 0 },
  fl = { 0, 0, 0, 5, 28 }, puff = { 1, 1, 1, 1.03, 1.12 }, arch = { 16, 5, 0, 0, 0 }, prop = { 0, 0, 0, 0.15, 1 },
  jaw = { 12, 0, 0, 3, 20 }, sm = { -1, -0.55, 0.3, 0.9, 0.85 }, open = { 0, 0.9, 1, 0.68, 0.8 },
  ul = { 0, 0.28, 0.06, 0.04, 0.42 }, tl = { 0, 3, 0, 0, -1 }, ll = { 0, 0, 0.06, 0.42, 0.22 },
  bi = { -5, -4, 0, -2, 1 }, bo = { 3, 2, 0, -1.5, -4 }, ba = { 0, 0, -1, -2, -2.5 }, lx = { 0, 0.5, 1.2, 1.4, 1.8 },
  ly = { 0, 2.6, 0.2, -0.4, 1.6 }, ps = { 1, 1.18, 1, 1.04, 0.94 }, blush = { 0.15, 0.1, 0.15, 0.55, 0.45 },
  str = { 1, 0, 0, 0, 0 }, wel = { 0, 1, 0, 0, 0 }, sq = { 1, 0, 0, 0, 0 },
}

-- The eating sequence for each mood: despair, sad, content, happy, proud.
local EATS = {
  { ch = 600, dur = 2800, cr = { 640, 820, 1000, 1150 }, k = {
    jaw = { 0, 10, 200, 6, 420, 30, 540, 34, 600, 0, 2000, 0, 2150, 6, 2350, 0 },
    open = { 0, 0.2, 120, 1.15, 650, 1.1, 800, 0.35, 1300, 0.35, 1500, 0.25, 1900, 0.85, 2700, 0.7 },
    sq = { 0, 0 }, str = { 0, 0 }, wel = { 0, 0, 1700, 0, 1900, 1 }, td = { 0, 0, 1950, 0, 2650, 1 },
    bi = { 0, -5, 150, -6, 700, -1, 1700, -1, 1950, -4 }, bo = { 0, 3, 150, -3, 700, 0, 1700, 0, 1950, 2 },
    ps = { 0, 1, 150, 1.3, 600, 1.25, 900, 1 },
    sm = { 0, -1, 150, -0.4, 600, -0.2, 1700, -0.2, 1950, 0.45, 2600, 0.25 },
    bl = { 0, 0.1, 1950, 0.1, 2200, 0.35 }, look = { 0, 1, 600, 1, 700, 0 },
    hx = { 0, 0, 250, 4, 520, 12, 600, 18, 750, 10, 1700, 6, 2100, 2, 2800, 0 },
    hy = { 0, 0, 250, -14, 520, -26, 600, -30, 750, -20, 1700, -16, 2000, -18, 2500, -6, 2800, 0 },
    hr = { 0, 0, 250, -6, 560, -12, 620, -2, 800, 0, 1700, -5, 2000, -3, 2800, 0 },
    ar = { 0, 0, 300, -8, 600, -10, 1800, -6, 2800, 0 }, fl = { 0, 0, 400, 6, 1800, 4, 2800, 0 },
    tl = { 0, 0, 400, 6, 2800, 0 }, chew = { f = 7.5, a = { 600, 0, 660, 10, 1250, 10, 1320, 0 } },
    ck = { 0, 0, 620, 1, 1300, 0.9, 1500, 0 }, shv = { f = 11, a = { 1500, 0, 1600, 1.4, 1900, 1.4, 2050, 0 } },
    gp = { 0, -1, 1360, 0, 1700, 1, 1701, -1 },
  } },
  { ch = 820, dur = 3000, k = {
    jaw = { 0, 0, 350, 0, 700, 22, 760, 23, 820, 0 },
    open = { 0, 0.9, 200, 1.08, 820, 1, 950, 0.1, 1750, 0.1, 2000, 0.95 },
    ul = { 0, 0.28, 200, 0.05, 1900, 0.05, 2200, 0.2 }, td = { 0, 0, 1000, 0, 1700, 1 },
    bi = { 0, -4, 200, -5.5, 2000, -3 }, bo = { 0, 2, 200, -1, 2000, 0 }, ps = { 0, 1.18, 200, 1.35, 820, 1.3, 1000, 1.18 },
    sm = { 0, -0.55, 250, -0.1, 820, 0, 1000, 0.15, 2000, 0.55, 2800, 0.4 },
    bl = { 0, 0.1, 1900, 0.1, 2150, 0.6, 2800, 0.45 }, look = { 0, 1, 820, 1, 900, 0 },
    hx = { 0, 0, 300, 3, 760, 9, 820, 10, 1000, 5, 2800, 0 },
    hy = { 0, 0, 250, -7, 760, -6, 1000, -4, 1700, -4, 2200, -8, 2800, 0 },
    hr = { 0, 0, 250, -4, 500, -3, 800, 1, 1000, 2, 1700, 2, 1850, -5, 1950, -1, 2300, -4, 2800, 0 },
    chew = { f = 3.2, a = { 820, 0, 880, 6, 1650, 6, 1720, 0 } }, ck = { 0, 0, 840, 0.6, 1650, 0.5, 1800, 0 },
    gp = { 0, -1, 1760, 0, 2080, 1, 2081, -1 }, tl = { 0, 0, 2000, 0, 2300, 8, 2800, 0 },
    wag = { f = 1.6, a = { 2100, 0, 2300, 4, 2800, 0 } },
  } },
  { ch = 700, dur = 2700, k = {
    jaw = { 0, 0, 250, 0, 600, 26, 650, 27, 700, 0, 1500, 0, 1550, 3, 1600, 0 },
    open = { 0, 1, 650, 1.05, 760, 0.05, 1500, 0.05, 1650, 1 },
    eh = { 0, 0, 700, 0, 780, 1, 1500, 1, 1600, 0, 2250, 0, 2350, 1, 2600, 1 },
    sm = { 0, 0.3, 200, 0.55, 600, 0.3, 760, 0.75, 1500, 0.75, 1900, 0.6, 2300, 0.85 },
    bo = { 0, 0, 200, -1 }, bl = { 0, 0.15, 760, 0.35 }, look = { 0, 1, 700, 1, 780, 0 },
    hx = { 0, 0, 400, 4, 650, 7, 760, 4, 2700, 0 }, hy = { 0, 0, 400, -2, 1500, -2, 2700, 0 },
    hr = { 0, 0, 200, 4, 600, -2, 760, 0, 1520, -4, 1700, 0 },
    bob = { f = 2.6, a = { 700, 0, 780, 1.6, 1450, 1.6, 1520, 0 } },
    chew = { f = 2.6, a = { 700, 0, 760, 7, 1450, 7, 1500, 0 } }, ck = { 0, 0, 720, 0.7, 1450, 0.6, 1550, 0 },
    gp = { 0, -1, 1520, 0, 1820, 1, 1821, -1 }, lick = { 0, 0, 1900, 0, 2300, 1 },
    wag = { f = 0.9, a = { 700, 0, 1000, 5, 2400, 5, 2700, 0 } },
  } },
  { ch = 650, dur = 2800, ht = { 1780, 1960, 2140 }, k = {
    jaw = { 0, 3, 150, 6, 450, 32, 590, 34, 650, 0 },
    open = { 0, 0.68, 150, 1.1, 650, 1.05, 720, 0.05, 1450, 0.05, 1700, 1, 2800, 0.8 },
    eh = { 0, 0, 650, 0, 720, 1, 1450, 1, 1550, 0, 1850, 0, 1950, 1, 2600, 1 },
    ll = { 0, 0.42, 150, 0.2, 650, 0.2, 1700, 0.42 }, sm = { 0, 0.9, 150, 1.1, 650, 0.5, 720, 1 },
    ps = { 0, 1.04, 150, 1.3, 650, 1.25, 800, 1.04 }, bl = { 0, 0.55, 720, 0.9, 2800, 0.8 },
    bi = { 0, -2, 150, -3 }, bo = { 0, -1.5, 150, -3 }, look = { 0, 1, 650, 1, 720, 0 },
    hx = { 0, 0, 300, 5, 600, 9, 700, 5, 2800, 0 }, hy = { 0, 0, 120, -8, 260, 0, 380, -6, 520, -2, 660, -6, 800, 0 },
    fl = { 0, 0, 120, 10, 260, 0, 380, 7, 520, 0, 660, 5, 800, 0 }, hr = { 0, 0, 600, -3, 700, 0, 1450, -4, 1600, 0 },
    wig = { f = 3.5, a = { 150, 0, 300, 5, 600, 2, 700, 0, 760, 0, 860, 4, 1400, 4, 1500, 0, 1900, 0, 2000, 3, 2700, 3, 2800, 0 } },
    chew = { f = 4.5, a = { 650, 0, 700, 8, 1380, 8, 1430, 0 } }, ck = { 0, 0, 670, 1, 1380, 0.9, 1480, 0 },
    gp = { 0, -1, 1460, 0, 1760, 1, 1761, -1 }, wag = { f = 3, a = { 0, 0, 200, 9, 2600, 9, 2800, 0 } },
    tl = { 0, 0, 200, 6, 2600, 6, 2800, 0 },
  } },
  { ch = 1000, dur = 3200, bp = { 2140, 2200, 2260, 2320 }, k = {
    jaw = { 0, 20, 300, 4, 550, 4, 820, 36, 930, 38, 1000, 0, 2050, 0, 2120, 22, 2350, 16, 2550, 0 },
    ul = { 0, 0.42, 300, 0.55, 820, 0.5, 1000, 0.3, 1050, 0.9, 1700, 0.9, 1900, 0.5, 2100, 0.2, 2400, 0.6, 3200, 0.5 },
    open = { 0, 0.8, 2050, 0.8, 2100, 0.15, 2300, 0.15, 2450, 0.8 }, sq = { 0, 0, 2050, 0, 2100, 1, 2300, 1, 2450, 0 },
    sm = { 0, 0.85, 300, 0.95, 820, 0.6, 1050, 0.9, 2050, 0.9, 2120, 0.2, 2400, 1 },
    bo = { 0, -4, 300, -6, 1000, -4, 2400, -6, 3200, -4 }, bi = { 0, 1, 300, 2, 1000, 1 },
    bl = { 0, 0.45, 2050, 0.45, 2200, 0.8, 3200, 0.6 }, look = { 0, 0.7, 1000, 0.7, 1050, 0 },
    hx = { 0, 0, 950, 0, 1000, -2, 1150, 0 }, hy = { 0, 0, 950, 0, 1000, 3, 1150, 0, 2050, 0, 2120, -4, 2400, 0 },
    hr = { 0, 0, 300, -7, 820, -9, 960, -10, 1000, -4, 1100, -7, 1700, -7, 1800, -10, 2050, -8, 2120, -14, 2350, -6, 3200, 0 },
    pu = { 0, 0, 1750, 0, 2000, 0.07, 2100, 0.1, 2350, 0.03, 2800, 0.06, 3200, 0 },
    chew = { f = 2.2, a = { 1000, 0, 1080, 7, 1650, 7, 1720, 0 } }, ck = { 0, 0, 1020, 0.6, 1650, 0.5, 1750, 0 },
    gp = { 0, -1, 1730, 0, 2030, 1, 2031, -1 }, tl = { 0, 0, 2120, 0, 2300, 8, 3200, 0 },
  } },
}
Render.EATS = EATS

-- The meat pile, eaten in one go (Scene:EatPile): he opens his mouth STREAM_JAW degrees over
-- STREAM_OPEN seconds, the haunches leave the top of the pile STREAM_RATE a second, each
-- flying STREAM_FLIGHT seconds into his mouth, and once the last is in he shuts it over
-- STREAM_SHUT seconds and chews and swallows the way his mood does.
local STREAM_JAW, STREAM_RATE, STREAM_FLIGHT = 30, 10, 0.8
local STREAM_OPEN, STREAM_SHUT = 0.35, 0.25
-- His jaw holds still while he waits; each haunch that goes in makes it gulp, closing
-- STREAM_GULP degrees and opening again over GULP_TIME seconds.
local STREAM_GULP, GULP_TIME = 6, 0.16
Render.STREAM_RATE, Render.STREAM_FLIGHT = STREAM_RATE, STREAM_FLIGHT

local JAWP = { { 12, -10 }, { 14, -2 }, { 28, 1 }, { 50, 1 }, { 72, 1 }, { 90, -1 }, { 98, -6 }, { 101, -8 }, { 100, -11 },
  { 96, -12 }, { 80, -14 }, { 50, -16 }, { 30, -16 }, { 20, -16 }, { 12, -14 }, { 12, -10 } }
local LS = { { 14, -6 }, { 28, 0 }, { 50, 1 }, { 72, 1 }, { 90, -1 }, { 98, -6 } }
local US = { { 104, -26 }, { 108, -16 }, { 102, -9 }, { 2, -10 }, { 0, -30 } }
local GEM = { { -0.42, 11, "GemRed" }, { 0.16, 15, "GemBlue" }, { 0.6, 9, "GemGreen" } }

Render.PRESETS = {
  { name = "Jade", body = "5dcaa5", belly = "faeeda", spikes = "f0997b" },
  { name = "Ruby", body = "e2574c", belly = "fac775", spikes = "faeeda" },
  { name = "Sapphire", body = "4f8fd8", belly = "e6f1fb", spikes = "fac775" },
  { name = "Amethyst", body = "9a8ce2", belly = "f4c0d1", spikes = "fac775" },
  { name = "Obsidian", body = "5f5e5a", belly = "d3d1c7", spikes = "e24b4a" },
  { name = "Rose", body = "ed93b1", belly = "fbeaf0", spikes = "7f77dd" },
}

local MEDIA = "Interface\\AddOns\\PintoTGD\\Media\\"
Render.MEDIA = { Haunch = MEDIA .. "Haunch", Mote = MEDIA .. "Mote", MinimapHead = MEDIA .. "MinimapHead",
  Circle = MEDIA .. "Circle" }

-- Weight bands: Starving, Thin, Healthy, Chubby, Very fat
function Render.Mood(F)
  if F < 0.12 then return 1 end
  if F < 0.32 then return 2 end
  if F < 0.62 then return 3 end
  if F < 0.85 then return 4 end
  return 5
end

-- Colours ---------------------------------------------------------------------------------

local H = Draw.Hex
local C = {
  mouth = H("4A1B0C"), tongue = H("D4537E"), blush = H("ED93B1"), tear = H("85B7EB"), white = H("FFFFFF"),
  smoke = H("B4B2A9"), crumb = H("BA7517"), crumbEdge = H("633806"), burp = H("D3D1C7"), burpEdge = H("888780"),
  shadow = H("2C2C2A"), zz = H("9C9A92"), bg = H("3A3D40"),
}
Render.SILHOUETTE_BG = C.bg

local function hx2hsl(hex)
  local c = H(hex)
  local r, g, b = c[1], c[2], c[3]
  local mx, mn = max(r, g, b), min(r, g, b)
  local l = (mx + mn) / 2
  local h, s = 0, 0
  if mx ~= mn then
    local d = mx - mn
    s = l > 0.5 and d / (2 - mx - mn) or d / (mx + mn)
    if mx == r then h = (g - b) / d + (g < b and 6 or 0)
    elseif mx == g then h = (b - r) / d + 2
    else h = (r - g) / d + 4 end
    h = h * 60
  end
  return h, s, l
end

local function hsl(h, s, l)
  s = clamp(s, 0, 1)
  l = clamp(l, 0, 1)
  local a = s * min(l, 1 - l)
  local function f(n)
    local k = (n + h / 30) % 12
    return l - a * max(-1, min(k - 3, 9 - k, 1))
  end
  -- the demo rounds to 8-bit hex; keep the same precision
  return { floor(f(0) * 255 + 0.5) / 255, floor(f(8) * 255 + 0.5) / 255, floor(f(4) * 255 + 0.5) / 255 }
end

local function palette(body, belly, spikes)
  local h, s, l = hx2hsl(body)
  local h2, s2, l2 = hx2hsl(belly)
  return {
    bd = H(body), wg = hsl(h, s * 1.3, l * 0.64), sh = hsl(h, s * 1.45, l * 0.43), dk = hsl(h, s * 1.55, l * 0.29),
    bl = H(belly), pl = hsl(h2, max(s2, 0.5), l2 * 0.6), sp = H(spikes), hn = hsl(h2, s2 * 0.25, l2 * 0.72),
  }
end
Render.Palette = palette

-- Scene -------------------------------------------------------------------------------------

local Scene = {}
Scene.__index = Scene

-- The demo's coin, rim and loose-coin randomness, continued after the coin field that
-- tools/textures.py drew into the Hoard texture (4 numbers per coin, 864 coins).
local RIM, LOOSE
local function hoardLayout()
  if RIM then return end
  local seed = 11
  local function rnd()
    seed = (seed * 16807) % 2147483647
    return seed / 2147483647
  end
  for _ = 1, 864 * 4 do rnd() end
  RIM, LOOSE = {}, {}
  for i = 0, 59 do
    RIM[i + 1] = { 30 + i * 10.5 + (rnd() - 0.5) * 4, (rnd() - 0.35) * 2.5, (rnd() - 0.5) * 30, i % 3 ~= 0 }
  end
  for i = 0, 13 do
    LOOSE[i + 1] = { i % 2 == 1 and 1 or -1, 8 + rnd() * 44, rnd() * 1.5, (rnd() - 0.5) * 8 }
  end
end

local function pawGroups(plane)
  return { plane:Group(), plane:Group(), plane:Group(), plane:Group() }
end

function Render.New(parent)
  hoardLayout()
  local self = setmetatable({}, Scene)
  local cv = Draw.NewCanvas(parent)
  self.canvas = cv
  self.frame = cv.root

  local g = {}
  self.g = g
  local bg = cv:Plane("bg", 1)
  g.bg = bg:Group()
  local floorP = cv:Plane("floor", 2)
  g.shadow = floorP:Group()
  local far = cv:Plane("far", 3)
  g.farO, g.farF = far:Group(), far:Group()
  g.farPaw = pawGroups(far)
  local spikes = cv:Plane("spikes", 4)
  g.spikeO, g.spikeF = spikes:Group(), spikes:Group()
  g.spadeF, g.spadeS = spikes:Group(), spikes:Group()
  local body = cv:Plane("body", 5)
  g.bodyO, g.bodyF, g.band, g.plates, g.ribs = body:Group(), body:Group(), body:Group(), body:Group(), body:Group()
  local limbs = cv:Plane("limbs", 6)
  g.footO, g.footF = limbs:Group(), limbs:Group()
  g.footPaw = pawGroups(limbs)
  g.thighO, g.thighF = limbs:Group(), limbs:Group()
  g.wing, g.wingLines = limbs:Group(), limbs:Group()
  g.clawO, g.claw = limbs:Group(), limbs:Group()
  g.armO, g.armF = limbs:Group(), limbs:Group()
  g.armPaw = pawGroups(limbs)
  local head = cv:Plane("head", 7)
  for _, k in ipairs({ "hornBackF", "hornBackS", "jowlO", "jowl", "jawO", "headO", "jawF", "headF", "finF", "finS",
    "mouth", "tongue", "mouthLine", "fangF", "fangS", "lick", "crease", "blush", "sunken", "eyeRing", "eyeWhite",
    "pupil", "glints", "tline", "lids", "lidLines", "eyeCurves", "brow", "nostril", "hornFrontF", "hornFrontS",
    "stream", "wdrop" }) do
    g[k] = head:Group()
  end
  local hoard = cv:Plane("hoard", 8)
  g.hoard, g.rim, g.gems, g.loose = hoard:Group(), hoard:Group(), hoard:Group(), hoard:Group()
  local pile = cv:Plane("pile", 9)
  g.pile = pile:Group()
  local fx = cv:Plane("fx", 10)
  g.drops, g.smoke, g.crumbs, g.burps, g.hearts, g.zs = fx:Group(), fx:Group(), fx:Group(), fx:Group(), fx:Group(), fx:Group()
  local food = cv:Plane("food", 40, "DIALOG")
  g.food = food:Group()
  self.planes = { bg = bg, floor = floorP, far = far, spikes = spikes, body = body, limbs = limbs, head = head,
    hoard = hoard, pile = pile, fx = fx, food = food }

  -- state, as in the demo
  self.F, self.H = 0.5, 0.35
  self.Wt, self.wl, self.W = 0, 0, 0
  self.eat, self.feeds = nil, {}
  self.pileCount = 0
  self.needB, self.Hb = true, -1
  self.xs, self.HH, self.HY, self.UY, self.SM, self.NX, self.NY, self.S = {}, {}, {}, {}, {}, {}, {}, {}
  self.s0, self.Hh, self.HW = 0, 0, 90
  self.FLc, self.fl0, self.fl1, self.ARc, self.arC = 0, 0, 1, 0, 0
  self.mouthX, self.mouthY = 400, 200
  self.fps, self.acc, self.paused = 30, 0, false
  self.sil, self.silFrom, self.silTo, self.silT, self.silDur = 0, 0, 0, 1, 0
  self.pal = palette("e2574c", "fac775", "faeeda")   -- Ruby, the demo's red preset
  self.staticDirty = true

  local scene = self
  self.frame:SetScript("OnUpdate", function(_, elapsed) scene:OnUpdate(elapsed) end)
  self.frame:SetScript("OnSizeChanged", function() scene.staticDirty = true end)
  return self
end

-- The demo's geometry ------------------------------------------------------------------------

function Scene:Build()
  local Hh = 140 * self.H
  local HW = 90 + 220 * self.H
  local dM = 5 + 15 * self.F
  local xs, HH, HY, UY, SM, NX, NY, S = self.xs, self.HH, self.HY, self.UY, self.SM, self.NX, self.NY, self.S
  for i = 0, N - 1 do
    local x = X0 + i * DX
    local u = (x - CX) / HW
    local hh = abs(u) < 1 and Hh * 0.5 * (1 + cos(PI * u)) or 0
    xs[i] = x
    HH[i] = hh
    HY[i] = G - hh
    UY[i] = G - hh + (hh > 0.01 and dM * (1 - exp(-hh * 0.5 / dM)) or 0)
  end
  -- 41-wide moving average with clamped ends
  local sum = 0
  for k = -20, 20 do sum = sum + UY[clamp(k, 0, N - 1)] end
  for i = 0, N - 1 do
    SM[i] = sum / 41
    sum = sum - UY[clamp(i - 20, 0, N - 1)] + UY[clamp(i + 21, 0, N - 1)]
  end
  for i = 0, N - 1 do
    local sl = (SM[min(i + 1, N - 1)] - SM[max(i - 1, 0)]) / (2 * DX)
    local L = sqrt(sl * sl + 1)
    NX[i] = sl / L
    NY[i] = -1 / L
  end
  S[0] = 0
  for i = 1, N - 1 do S[i] = S[i - 1] + hypot(DX, UY[i] - UY[i - 1]) end
  self.s0 = S[IC]
  self.Hh, self.HW = Hh, HW
end

local function at(arr, x)
  local fi = clamp((x - X0) / DX, 0, N - 1.001)
  local i = floor(fi)
  return arr[i] + (arr[i + 1] - arr[i]) * (fi - i)
end

function Scene:mapRaw(sx, sy)
  local S = self.S
  local s = self.s0 + sx
  local lo, hi = 0, N - 1
  if s >= S[N - 1] then
    lo = N - 2
  elseif s > S[0] then
    while hi - lo > 1 do
      local m = floor((lo + hi) / 2)
      if S[m] <= s then lo = m else hi = m end
    end
  end
  local t = (s - S[lo]) / (S[lo + 1] - S[lo])
  local xs, UY, NX, NY = self.xs, self.UY, self.NX, self.NY
  local x = lerp(xs[lo], xs[lo + 1], t)
  local y = lerp(UY[lo], UY[lo + 1], t)
  local nx = lerp(NX[lo], NX[lo + 1], t)
  local ny = lerp(NY[lo], NY[lo + 1], t)
  return x + nx * sy, y + ny * sy, x
end

function Scene:sinkAt(x) return max(0, at(self.UY, x) - at(self.HY, x)) end
function Scene:lim(x) return at(self.HY, x) + min(4, at(self.HH, x) * 0.5) end

function Scene:liftAt(sx, sy)
  local d = self.FLc * sst(self.fl0, self.fl1, sx)
  if self.ARc ~= 0 then
    local z = (sx - self.arC) / 55
    d = d + self.ARc * exp(-z * z) * clamp(sy / 30, 0, 1)
  end
  return d
end

function Scene:wgt(sx)
  local D = self.D
  if sx < D.tb0 then return lerp(0.25, 1, sst(D.tT, D.tb0, sx)) end
  if sx > D.tf0 then return lerp(1, 0.3, sst(D.tf0, D.nE + 30, sx)) end
  return 1
end

function Scene:map(sx, sy)
  local x, y, xb = self:mapRaw(sx, sy + self:liftAt(sx, sy))
  local w = self:wgt(sx)
  if w < 1 then y = y - (1 - w) * max(0, self:sinkAt(xb) - 2) end
  return x, y
end

function Scene:mapL(sx, sy)
  local x, y, xb = self:mapRaw(sx, sy)
  return x, y - max(0, self:sinkAt(xb) - 3)
end

function Scene:ellPts(p, n)
  local out = {}
  for k = 0, n - 1 do
    local th = k / n * TP
    local x, y = self:map(p.cx + p.ax * cos(th), sc(p.cy + p.b * sin(th)))
    out[#out + 1] = x
    out[#out + 1] = y
  end
  return out
end

-- An ellipse fitted to a torso part as the demo maps it onto the hoard: centre, then the
-- half-axis vectors across and up. Cheap stand-in for a ring of 48 mapped points.
function Scene:FitEllipse(p)
  local top, bottom = sc(p.cy + p.b), sc(p.cy - p.b)
  local yc, hb = (top + bottom) / 2, (top - bottom) / 2
  local cx, cy = self:map(p.cx, yc)
  local lx, ly = self:map(p.cx - p.ax, yc)
  local rx, ry = self:map(p.cx + p.ax, yc)
  local tx, ty = self:map(p.cx, yc + hb)
  local bx, by = self:map(p.cx, yc - hb)
  return cx, cy, (rx - lx) / 2, (ry - ly) / 2, (bx - tx) / 2, (by - ty) / 2
end

-- Draws a fitted ellipse, grown by `grow` scene units on every side.
local function fittedEllipse(group, cx, cy, ux, uy, vx, vy, grow, col)
  local lu, lv = hypot(ux, uy), hypot(vx, vy)
  if lu < 1e-6 or lv < 1e-6 then return end
  local ku, kv = (lu + grow) / lu, (lv + grow) / lv
  group:Sprite("Circle", { ux * ku, uy * ku, vx * kv, vy * kv, cx, cy }, col)
end

function Scene:span(sx)
  local D = self.D
  local lo, hi, ht = 1e9, -1e9, -1e9
  for _, p in ipairs(D.torso) do
    local u = (sx - p.cx) / p.ax
    if u > -1 and u < 1 then
      local r = sqrt(1 - u * u)
      local a, b = sc(p.cy - p.b * r), sc(p.cy + p.b * r)
      if a < lo then lo = a end
      if b > hi then hi = b end
      if b > ht then ht = b end
    end
  end
  if sx <= D.tB and sx >= D.tT then
    local q = (D.tB - sx) / (D.tB - D.tT)
    local l = D.tailL(q)
    if l < lo then lo = l end
    if l + D.tailT(q) > hi then hi = l + D.tailT(q) end
  end
  return lo, hi, ht
end

-- Hoard and floor ----------------------------------------------------------------------------

function Scene:DrawStatic()
  local g, pal = self.g, self.pal
  -- the dark background behind the silhouette: the window's cover when it has one
  -- (SetBackdrop), otherwise the scene's own rectangle
  self.planes.bg:Begin()
  if self.sil > 0 and not self.backdrop then g.bg:Rect(0, 20, 680, 440, C.bg, self.sil, true) end
  self.planes.bg:End()

  -- no floor of his own: he sits on the cave floor of the window's backdrop, with a soft
  -- shadow under the hoard
  self.planes.floor:Begin()
  g.shadow:Ellipse(CX, 395, max(self.HW + 25, 270), 6, 0, C.shadow, 0.25)
  self.planes.floor:End()

  self.planes.hoard:Begin()
  local HY, HH = self.HY, self.HH
  local HW, H = self.HW, self.H
  local on = self.Hh > 0.5
  if on then
    local x = CX - HW
    while x < CX + HW do
      local x2 = min(x + 3, CX + HW)
      local top = min(at(HY, x), at(HY, x2))
      if top < G - 0.2 then g.hoard:Slice("Hoard", x, top, x2 + 0.6, G) end
      x = x2
    end
    for _, r in ipairs(RIM) do
      local x0, j, ra, gold = r[1], r[2], r[3], r[4]
      if at(HH, x0) >= 2.5 then
        local y = at(HY, x0) + j
        local a = math.atan((at(HY, x0 + 3) - at(HY, x0 - 3)) / 6) + ra * PI / 180
        g.rim:Sprite(gold and "CoinRimGold" or "CoinRimPale", M(x0, y, a), nil)
      end
    end
    local nl = floor(14 * H + 0.5)
    for i = 1, nl do
      local c = LOOSE[i]
      local x0 = CX + c[1] * (HW + c[2])
      g.loose:Sprite("CoinLoose", M(x0, G - 2 + c[3] * 0.6, c[4] * PI / 180), nil)
    end
    if H >= 0.3 then
      for _, gm in ipairs(GEM) do
        local x0 = CX + gm[1] * HW
        g.gems:Sprite(gm[3], M(x0, at(HY, x0) + min(gm[2], at(HH, x0) * 0.5), 0), nil)
      end
    end
  end
  self.planes.hoard:End()
  self:DrawPile()
end

-- The meat pile, beside Pinto on the floor: a little stack of drumsticks.
local PILE = {}
do
  local rows = { { -20, -10, 0, 10, 20 }, { -15, -5, 5, 15 }, { -10, 0, 10 }, { -5, 5 }, { 0 } }
  for r, xs in ipairs(rows) do
    for _, dx in ipairs(xs) do PILE[#PILE + 1] = { 652 + dx, 387 - (r - 1) * 8 } end
  end
end

function Scene:PileTop()
  local n = clamp(self.pileCount, 1, #PILE)
  return PILE[n][1], PILE[n][2] - 6
end

function Scene:DrawPile()
  self.planes.pile:Begin()
  local n = min(self.pileCount, #PILE)
  for i = 1, n do
    local p = PILE[i]
    self.g.pile:Sprite("Haunch", M(p[1], p[2], (i % 2 == 0 and 0.35 or -0.3), 0.8), nil)
  end
  self.planes.pile:End()
end

-- One frame ------------------------------------------------------------------------------------

local function bez3(t, x0, y0, x1, y1, x2, y2, x3, y3)
  local v = 1 - t
  local a, b, c, d = v * v * v, 3 * v * v * t, 3 * v * t * t, t * t * t
  return a * x0 + b * x1 + c * x2 + d * x3, a * y0 + b * y1 + c * y2 + d * y3
end

local function quadPts(x0, y0, cx, cy, x1, y1, n, out)
  out = out or {}
  for i = 0, n do
    local u = i / n
    local a, b, c = (1 - u) * (1 - u), 2 * u * (1 - u), u * u
    out[#out + 1] = a * x0 + b * cx + c * x1
    out[#out + 1] = a * y0 + b * cy + c * y1
  end
  return out
end

-- Transforms a flat list of head-local points with matrix m.
local function xform(m, pts)
  local out = {}
  local a, b, c, d, e, f = m[1], m[2], m[3], m[4], m[5], m[6]
  for i = 1, #pts, 2 do
    local x, y = pts[i], pts[i + 1]
    out[i] = a * x + c * y + e
    out[i + 1] = b * x + d * y + f
  end
  return out
end

local function apply(m, x, y)
  return m[1] * x + m[3] * y + m[5], m[2] * x + m[4] * y + m[6]
end

-- m1 after m2
local function compose(m1, m2)
  return {
    m1[1] * m2[1] + m1[3] * m2[2], m1[2] * m2[1] + m1[4] * m2[2],
    m1[1] * m2[3] + m1[3] * m2[4], m1[2] * m2[3] + m1[4] * m2[4],
    m1[1] * m2[5] + m1[3] * m2[6] + m1[5], m1[2] * m2[5] + m1[4] * m2[6] + m1[6],
  }
end

-- Clips a polygon (flat list) to the inside of an ellipse, given as a convex polygon.
local function clipConvex(pts, clip)
  local out = pts
  local n = #clip / 2
  -- orientation of the clip polygon
  local area = 0
  for i = 1, n do
    local j = i % n + 1
    area = area + clip[2 * i - 1] * clip[2 * j] - clip[2 * j - 1] * clip[2 * i]
  end
  local sgn = area > 0 and 1 or -1
  for i = 1, n do
    local j = i % n + 1
    local ax, ay, bx, by = clip[2 * i - 1], clip[2 * i], clip[2 * j - 1], clip[2 * j]
    local function inside(x, y) return ((bx - ax) * (y - ay) - (by - ay) * (x - ax)) * sgn >= 0 end
    local input = out
    out = {}
    local m = #input / 2
    for k = 1, m do
      local px, py = input[2 * k - 1], input[2 * k]
      local q = (k - 2) % m + 1
      local qx, qy = input[2 * q - 1], input[2 * q]
      local pin, qin = inside(px, py), inside(qx, qy)
      if pin ~= qin then
        local dx, dy = px - qx, py - qy
        local den = (bx - ax) * dy - (by - ay) * dx
        if abs(den) > 1e-12 then
          local t = ((bx - ax) * (ay - qy) - (by - ay) * (ax - qx)) / den
          out[#out + 1] = qx + dx * t
          out[#out + 1] = qy + dy * t
        end
      end
      if pin then
        out[#out + 1] = px
        out[#out + 1] = py
      end
    end
    if #out < 6 then return {} end
  end
  return out
end

local function ellipsePoly(cx, cy, rx, ry, n)
  local out = {}
  for k = 0, n - 1 do
    local a = k / n * TP
    out[#out + 1] = cx + rx * cos(a)
    out[#out + 1] = cy + ry * sin(a)
  end
  return out
end

-- Clips a polyline (flat list) to the inside of an axis-aligned ellipse.
local function clipLine(pts, cx, cy, rx, ry)
  local out = {}
  for i = 1, #pts, 2 do
    local dx, dy = (pts[i] - cx) / rx, (pts[i + 1] - cy) / ry
    if dx * dx + dy * dy <= 1 then
      out[#out + 1] = pts[i]
      out[#out + 1] = pts[i + 1]
    end
  end
  return out
end

-- One frame: the pose is worked out first (into st), then each part is drawn. Lua allows
-- 200 locals per function, so the demo's draw() is split along its natural seams.
function Scene:Draw(t)
  local st = self:PoseBody(t)
  self:PoseHead(st)
  self:PoseNeck(st)
  self:DrawFood(st)
  self:DrawFar(st)
  self:DrawSpikes(st)
  self:DrawBody(st)
  self:DrawLimbs(st)
  self:DrawHead(st)
  self:DrawFx(st)
end

function Scene:PoseBody(t)
  local F, W = self.F, self.W
  local st = { t = t, F = F, W = W }
  local function P(a, m, b)
    if F < 0.5 then return lerp(a, m, F / 0.5) end
    return lerp(m, b, (F - 0.5) / 0.5)
  end
  st.P = P
  local eat = self.eat
  local E, c, eb = -1, nil, 0
  if eat then
    E = (t - eat.t0) * eat.speed
    c = eat.S.k
    eb = sst(0, 160, E) * (1 - sst(eat.S.dur - 350, eat.S.dur, E)) * W
    -- a sequence joined at its chomp (after the pile's stream) blends in over a moment
    if eat.join then eb = eb * sst(eat.join, eat.join + 220, E) end
  end
  st.eat, st.E, st.c, st.eb = eat, E, c, eb
  -- how wide he's holding his mouth open for the pile's stream
  st.so = (self.stream and self.stream.open or 0) * W
  st.sg = (self.stream and self.stream.gulp or 0) * W
  st.ov = function(b, n) if c and c[n] then return lerp(b, kf(c[n], E), eb) end return b end
  st.ad = function(n) if c and c[n] then return kf(c[n], E) * W end return 0 end
  st.rw = function(n) if c and c[n] then return kf(c[n], E) end return -1 end
  st.sn = function(f) return sin(TP * f * E / 1000) end
  st.os = function(n, fn) if c and c[n] then return kf(c[n].a, E) * W * fn(c[n].f) end return 0 end
  local ad, os, sn = st.ad, st.os, st.sn

  local si = 0
  while si < 3 and F > KF[si + 2] do si = si + 1 end
  local lt = clamp((F - KF[si + 1]) / (KF[si + 2] - KF[si + 1]), 0, 1)
  local ts = lt * lt * (3 - 2 * lt)
  local function V(a) return lerp(a[si + 1], a[si + 2], ts) end
  st.V = V
  local wk = { 0, 0, 0, 0, 0 }
  wk[si + 1] = 1 - lt
  wk[si + 2] = lt
  st.wk = wk
  st.iS, st.iT, st.iH, st.iC, st.iP = wk[1] * W, wk[2] * W, wk[3] * W, wk[4] * W, wk[5] * W

  local sob = ((max(0, sin(TP * t / 1150)) ^ 6) + 0.6 * (max(0, sin(TP * (t + 380) / 1150)) ^ 8))
    * (0.65 + 0.35 * sin(TP * t / 4100)) * st.iS * (1 - eb)
  local pf = 0.5 + 0.5 * sin(TP * t / 3600)
  local snp = (t % 3600) / 3600
  st.sob, st.pf = sob, pf
  st.sniff = snp < 0.12 and sin(PI * snp / 0.12) or 0
  local br = 1 + ((1 - W) * 0.028 * sin(TP * t / 3400) + W * (1 - wk[5]) * 0.02 * sin(TP * t / 2600)
    + W * wk[5] * 0.03 * (2 * pf - 1))
  st.br = br
  local puff = lerp(1, V(K.puff), W) + 0.035 * pf * st.iP + ad("pu")
  local chest = { cx = P(48, 52, 60), cy = P(30, 40, 60) * br, ax = P(58, 64, 80) * puff, b = P(32, 40, 62) * br * puff }
  local hip = { cx = P(-62, -64, -80), cy = P(28, 34, 56) * br, ax = P(44, 50, 74), b = P(28, 36, 60) * br }
  local waist = { cx = P(-6, -4, 0), cy = P(40, 38, 70) * br, ax = P(56, 62, 105), b = P(20, 34, 75) * br }
  local blob = { cx = P(0, 0, -5), cy = P(36, 34, 84) * br, ax = P(30, 90, 170), b = P(4, 40, 118) * br }
  st.chest, st.hip, st.waist, st.blob = chest, hip, waist, blob
  local torso = { hip, waist, blob, chest }
  self.FLc = W * V(K.fl) + ad("fl")
  self.fl0, self.fl1 = waist.cx, chest.cx + 10
  self.ARc = W * V(K.arch) + 4 * sob + ad("ar")
  self.arC = chest.cx - 25
  local tl = W * (7 * (0.5 + 0.5 * sin(TP * t / 5200)) * wk[3] + 12 * (0.5 + 0.5 * sin(TP * t / 1100)) * wk[4]
    + 4 * sin(TP * t / 3600) * wk[5]) + W * wk[5] * 12 + ad("tl") + os("wag", sn)
  local tb, te = P(18, 26, 66), P(1.2, 1.1, 0.85)
  local tB = hip.cx + 10
  local tT = tB - 215
  local nb, nt = P(26, 36, 80) * br, P(22, 28, 52)
  local nB = chest.cx + 10
  local nE = chest.cx + chest.ax + P(28, 30, 40)
  local tb0, tf0 = 1e9, -1e9
  for _, p in ipairs(torso) do
    tb0 = min(tb0, p.cx - p.ax)
    tf0 = max(tf0, p.cx + p.ax)
  end
  local D = {
    torso = torso, tB = tB, tT = tT, nB = nB, nE = nE, tb0 = tb0, tf0 = tf0,
    tailT = function(q) return 3 + (tb - 3) * (1 - q) ^ te end,
    tailL = function(q) return 20 * sst(0.62, 1, q) ^ 1.5 + tl * sst(0.45, 1, q) ^ 1.6 end,
    neckT = function(q) return nb + (nt - nb) * sst(0, 1, q) end,
  }
  self.D = D
  st.D = D
  st.ro = clamp((0.42 - F) / 0.3, 0, 1)
  st.co = clamp((F - 0.6) / 0.3, 0, 1)
  return st
end

function Scene:PoseHead(st)
  local t, F, W, V, ov, ad, os, sn = st.t, st.F, st.W, st.V, st.ov, st.ad, st.os, st.sn
  local eat, E, eb = st.eat, st.E, st.eb
  local chest, D = st.chest, st.D
  local function ex(a, arr) return lerp(a, V(arr), W) end
  local dwa = V(K.dw)
  st.dwa = dwa
  local open, ul, ll = ov(ex(0, K.open), "open"), ov(ex(0, K.ul), "ul"), ov(ex(0, K.ll), "ll")
  local lx, ly, bi = ex(0, K.lx), ex(0, K.ly), ov(ex(0, K.bi), "bi")
  st.tlid, st.sm, st.bo, st.ba = ex(0, K.tl), ov(ex(0.2, K.sm), "sm"), ov(ex(1, K.bo), "bo"), ex(0, K.ba)
  st.ps = ov(ex(1, K.ps), "ps")
  st.bls = ov(ex(0.55 * sst(0.4, 0.9, F), K.blush), "bl")
  st.str, st.wel, st.sqz, st.eh = ov(ex(0, K.str), "str"), ov(ex(0, K.wel), "wel"), ov(ex(0, K.sq), "sq"), ov(0, "eh")
  local sob, pf, sniff = st.sob, st.pf, st.sniff
  local ja = ov(ex(0, K.jaw) + 6 * sob + 2 * pf * st.iP, "jaw")
    + os("chew", function(f) return 0.5 - 0.5 * cos(TP * f * (E - (eat and eat.S.ch or 0)) / 1000) end)
  -- the pile's stream: his idle, with his mouth held wide open, gulping as haunches go in
  if st.so > 0 then ja = lerp(ja, STREAM_JAW - STREAM_GULP * st.sg, st.so) end
  local jaR = ja * PI / 180
  st.ja, st.jaR = ja, jaR
  local bph = (t % 4300) / 4300
  local blink = bph > 0.965 and sin(PI * (bph - 0.965) / 0.035) or 0
  local sph = ((t + 1700) % 5600) / 5600
  local slow = sph > 0.88 and sin(PI * (sph - 0.88) / 0.12) or 0
  open = open * (1 - blink * (st.iT + st.iH + st.iC) * (1 - eb))
  ul = ul + 0.4 * slow * st.iP * (1 - eb)
  lx = lx + 1.3 * sin(TP * t / 7000) * st.iH
  ly = ly + 0.5 * sin(TP * t / 2300) * st.iT
  bi = bi - 1.5 * sob
  st.qv = (0.9 * st.iS + 0.5 * st.iT) * (1 - eb)

  local hb = D.nE - 14
  local B0x, B0y = self:map(hb, 0)
  local B1x, B1y = self:map(hb + 112, 0)
  local anA = atan2(B1y - B0y, B1x - B0x)
  local jlx, jly = JLX * HK, JLY * HK
  local rax, ray = rot(jlx, jly, anA)
  local jAx, jAy = B0x + rax, B0y + ray
  local sxn = chest.cx + 0.45 * chest.ax
  local s0, s1 = self:span(sxn)
  local P0x, P0y = self:map(sxn, lerp(s0, s1, 0.62))
  local phi, Ln = V(K.phi), V(K.ln)
  local d3x, d3y = dirW(phi)
  local P3rx, P3ry = P0x + Ln * d3x, P0y + Ln * d3y
  local sxh = chest.cx + chest.ax + 20
  local P3dx, P3dy = self:map(sxh, 26)
  local gax, gay = self:mapL(sxh - 8, 0)
  local gbx, gby = self:mapL(sxh + 8, 0)
  local sa = atan2(gby - gay, gbx - gax)
  local jKx, jKy = lerp(P3rx, P3dx, dwa), lerp(P3ry, P3dy, dwa)
  local angK = lerp(-V(K.pitch) * PI / 180, sa + 24 * PI / 180, dwa)
  local dAng = (4 * sob - 3 * sniff * st.iT + 2 * sin(TP * t / 6000) * st.iH + 3 * sin(TP * t / 1700) * st.iC
    - 3 * pf * st.iP + ad("hr") + os("wig", sn) + os("shv", sn)) * PI / 180
  local ang = lerp(anA, angK, W) + dAng
  local jwx = lerp(jAx, jKx, W) + ad("hx")
  local jwy = lerp(jAy, jKy, W) + 1.5 * sob - 1.5 * sniff * st.iT + 1.5 * sin(TP * t / 850) * st.iC + ad("hy")
    + os("bob", sn)
  local jrx, jry = rot(jlx, jly, ang)
  local orgx, orgy = jwx - jrx, jwy - jry
  local lift = 0
  local function liftPoint(lpx, lpy)
    local vx, vy = rot(lpx * HK, lpy * HK, ang)
    lift = max(lift, orgy + vy - self:lim(orgx + vx))
  end
  for _, p in ipairs(LS) do liftPoint(rotA(p[1], p[2], HGX, HGY, jaR)) end
  for _, p in ipairs(US) do liftPoint(p[1], p[2]) end
  orgy, jwy = orgy - lift, jwy - lift
  st.P0x, st.P0y, st.phi, st.Ln, st.jKx, st.jKy, st.jwx, st.jwy, st.ang = P0x, P0y, phi, Ln, jKx, jKy, jwx, jwy, ang
  local mHead = M(orgx, orgy, ang, HK)
  st.mHead = mHead
  st.mJaw = compose(mHead, { cos(jaR), sin(jaR), -sin(jaR), cos(jaR),
    HGX - (HGX * cos(jaR) - HGY * sin(jaR)), HGY - (HGX * sin(jaR) + HGY * cos(jaR)) })

  local sm = st.sm
  local smp, smn = max(0, sm), max(0, -sm)
  local Fpx, Fpy = 101, -9
  local Cpx, Cpy = 62 - 8 * smp + 2 * smn, -12 - 4 * smp + 5 * smn
  local Qcx, Qcy = 80, -9 + 3.5 * sm
  st.Cpx, st.Cpy = Cpx, Cpy
  local function mq(u)
    local a, b, q = (1 - u) * (1 - u), 2 * u * (1 - u), u * u
    return a * Fpx + b * Qcx + q * Cpx, a * Fpy + b * Qcy + q * Cpy
  end
  st.mq = mq
  local mux, muy = mq(0.3)
  local mlx, mly = rotA(mux, muy, HGX, HGY, jaR)
  local MWx, MWy = apply(mHead, (mux + mlx) / 2, (muy + mly) / 2)
  self.mouthX, self.mouthY = MWx, MWy
  st.MWx, st.MWy = MWx, MWy

  -- the chomp, the flying food, the eyes following it
  if eat and not eat.fired and E >= eat.S.ch then
    eat.fired = true
    if not eat.cx and eat.onChomp then
      local ok, err = pcall(eat.onChomp)
      if not ok and ns.report then ns.report(err) end
    end
  end
  if eat and not eat.fired and not eat.cx then
    local q0 = clamp(E / eat.S.ch, 0, 1)
    local s = q0 < 0.5 and 4 * q0 * q0 * q0 or 1 - ((-2 * q0 + 2) ^ 3) / 2
    local C1x, C1y = MWx + 55, MWy - 22
    local v = 1 - s
    st.foodX = v * v * eat.S0x + 2 * s * v * C1x + s * s * MWx
    st.foodY = v * v * eat.S0y + 2 * s * v * C1y + s * s * MWy
    local wob = 18 * sin(E / 110) * v * PI / 180
    if eat.rot0 then
      -- a haunch off the pile starts exactly as it lay there
      local k = sst(0, 0.3, q0)
      st.foodRot, st.foodScale = lerp(eat.rot0, wob, k), lerp(eat.scale0 or 1, 1, k)
    else
      st.foodRot = wob
      st.foodScale = eat.fromOutside and 1 or sst(0, 150, E)
    end
  end
  local c = st.c
  if c and c.look and st.foodX then
    local lw = kf(c.look, E) * eb
    local eWx, eWy = apply(mHead, EX, EY)
    local dx, dy = rot(st.foodX - eWx, st.foodY - eWy, -ang)
    local L = hypot(dx, dy)
    if L < 1e-9 then L = 1 end
    lx = lerp(lx, 2.4 * dx / L, lw)
    ly = lerp(ly, 2.4 * dy / L, lw)
  end
  st.open, st.ul, st.ll, st.lx, st.ly, st.bi = open, ul, ll, lx, ly, bi
end

function Scene:PoseNeck(st)
  local W, dwa, D = st.W, st.dwa, st.D
  local Ln, phi, P0x, P0y, jKx, jKy = st.Ln, st.phi, st.P0x, st.P0y, st.jKx, st.jKy
  local c0, c1n = lerp(Ln * 0.42, 26, dwa), lerp(Ln * 0.38, 24, dwa)
  local f0x, f0y = dirW(lerp(phi + 15, 35, dwa))
  local f1x, f1y = dirW(lerp(phi - 25, -35, dwa))
  local Q1x, Q1y = P0x + f0x * c0, P0y + f0y * c0
  local Q2x, Q2y = jKx - f1x * c1n, jKy - f1y * c1n
  local gq = st.rw("gp")
  local gA = (gq > 0 and gq < 1) and 0.24 * sin(PI * gq) * W or 0
  local ug = 0.95 - 0.85 * gq
  local CLx, CLy, TH = {}, {}, {}
  for i = 0, NC - 1 do
    local u = i / (NC - 1)
    local h0 = D.neckT(u)
    local ax, ay = self:map(D.nB + u * (D.nE - D.nB), h0 / 2)
    local h = h0
    if gA ~= 0 then h = h0 * (1 + gA * exp(-((u - ug) / 0.09) ^ 2)) end
    local bx, by = bez3(u, P0x, P0y, Q1x, Q1y, Q2x, Q2y, jKx, jKy)
    CLx[i], CLy[i], TH[i] = lerp(ax, bx, W), lerp(ay, by, W), h
  end
  local dlx, dly = st.jwx - CLx[NC - 1], st.jwy - CLy[NC - 1]
  for i = 0, NC - 1 do
    local u = i / (NC - 1)
    local s = u * u * (3 - 2 * u)
    CLx[i], CLy[i] = CLx[i] + dlx * s, CLy[i] + dly * s
  end
  local NNx, NNy = {}, {}
  for i = 0, NC - 1 do
    local a, b = max(0, i - 1), min(NC - 1, i + 1)
    local tx, ty = CLx[b] - CLx[a], CLy[b] - CLy[a]
    local L = hypot(tx, ty)
    if L < 1e-9 then L = 1 end
    NNx[i], NNy[i] = ty / L, -tx / L
  end
  local Lc = { [0] = 0 }
  for i = 1, NC - 1 do Lc[i] = Lc[i - 1] + hypot(CLx[i] - CLx[i - 1], CLy[i] - CLy[i - 1]) end
  st.CLx, st.CLy, st.TH, st.NNx, st.NNy = CLx, CLy, TH, NNx, NNy
  st.nAt = function(u)
    local s = u * Lc[NC - 1]
    local i = 0
    while i < NC - 2 and Lc[i + 1] < s do i = i + 1 end
    local den = Lc[i + 1] - Lc[i]
    local f = clamp((s - Lc[i]) / (den ~= 0 and den or 1), 0, 1)
    local nx, ny = lerp(NNx[i], NNx[i + 1], f), lerp(NNy[i], NNy[i + 1], f)
    local L = hypot(nx, ny)
    if L < 1e-9 then L = 1 end
    nx, ny = nx / L, ny / L
    return lerp(CLx[i], CLx[i + 1], f), lerp(CLy[i], CLy[i + 1], f), nx, ny, -ny, nx, lerp(TH[i], TH[i + 1], f)
  end
end

function Scene:DrawFood(st)
  local pl = self.planes.food
  pl:Begin()
  if st.foodX then
    self.g.food:Sprite("Haunch", M(st.foodX, st.foodY, st.foodRot, st.foodScale), nil)
  end
  local sm = self.stream
  if sm then
    for _, f in ipairs(sm.flying) do
      local x, y, r, s = self:StreamPoint(f, sm.t, st.MWx, st.MWy)
      self.g.food:Sprite("Haunch", M(x, y, r, s), nil)
    end
  end
  pl:End()
end

-- Where a haunch of the pile's stream is, `now` seconds into the stream: it leaves the pile
-- exactly as it lay there, rises, turns and grows a little, and drops into his mouth along
-- a little arc, shrinking as it goes in.
function Scene:StreamPoint(f, now, MWx, MWy)
  local q0 = clamp((now - f.t0) / STREAM_FLIGHT, 0, 1)
  local s = q0 < 0.5 and 4 * q0 * q0 * q0 or 1 - ((-2 * q0 + 2) ^ 3) / 2
  local C1x, C1y = (f.x + MWx) / 2 + 20, min(f.y, MWy) - 70
  local v = 1 - s
  local x = v * v * f.x + 2 * s * v * C1x + s * s * MWx
  local y = v * v * f.y + 2 * s * v * C1y + s * s * MWy
  local lift = sst(0, 0.3, q0)
  local rot = lerp(f.rot, 18 * sin(q0 * 7 + f.k) * v * PI / 180, lift)
  local scale = lerp(0.8, 1, lift) * (1 - 0.45 * sst(0.8, 1, q0))
  return x, y, rot, scale
end

-- An arm from the shoulder to the paw: { shoulder, elbow, paw } and where the paw sits.
function Scene:Arm(st, o)
  local chest, P, W, dwa = st.chest, st.P, st.W, st.dwa
  local lw = P(10, 14, 24)
  local ly8 = 8 * lw / 14 + 0.5
  local wpp, wdd = W * st.V(K.prop), W * dwa
  local S0x, S0y = self:map(chest.cx + 4 + o, chest.cy * 0.95)
  local p0 = chest.cx + chest.ax + P(-2, 0, -8) + o
  local psx = p0 + (chest.cx + chest.ax * 0.55 + 4 + o - p0) * wpp + (chest.cx + chest.ax + 8 + o - p0) * wdd
  local Pwx, Pwy = self:mapL(psx, ly8)
  local Esx, Esy = self:mapL(chest.cx - 8 + o * 0.5, ly8)
  local vx, vy = Pwx - S0x, Pwy - S0y
  local L = hypot(vx, vy)
  if L < 1e-9 then L = 1 end
  local px, py = vy / L, -vx / L
  if px > 0 then px, py = -px, -py end
  local Emx = lerp(Esx, (S0x + Pwx) / 2 + px * 6, wpp)
  local Emy = lerp(Esy, (S0y + Pwy) / 2 + py * 6, wpp)
  return { S0x, S0y, Emx, Emy, Pwx, Pwy }, psx, Pwx, Pwy, lw
end

function Scene:Paw(groups, sx, px, py, k, fillCol)
  local pal = self.pal
  local ax, ay = self:mapL(sx - 4, 0)
  local bx, by = self:mapL(sx + 4, 0)
  local m = M(px, py, atan2(by - ay, bx - ax), k)
  groups[1]:Sprite("PawClaws", m, pal.bl)
  groups[2]:Sprite("PawClawsStroke", m, pal.dk)
  groups[3]:Sprite("PawFill", m, fillCol)
  groups[4]:Sprite("PawStroke", m, pal.dk)
end

function Scene:DrawFar(st)
  local g, pal, pl = self.g, self.pal, self.planes.far
  pl:Begin()
  local pts, psx, px, py, lw = self:Arm(st, 13)
  g.farO:Poly(pts, lw * 0.9 + 6, pal.dk, 1, true)
  g.farF:Poly(pts, lw * 0.9, pal.wg, 1, true)
  self:Paw(g.farPaw, psx, px, py, lw / 14 * 0.92, pal.wg)
  pl:End()
end

function Scene:DrawSpikes(st)
  local g, pal, pl = self.g, self.pal, self.planes.spikes
  local P, D, chest = st.P, st.D, st.chest
  pl:Begin()
  local function spike(ax, ay, bx, by, cx2, cy2)
    -- the outline: the same triangle grown a little, under the fill
    local mx, my = (ax + bx + cx2) / 3, (ay + by + cy2) / 3
    local function grow(x, y)
      local dx, dy = x - mx, y - my
      local L = hypot(dx, dy)
      if L < 1e-9 then return x, y end
      return x + dx / L * 1.6, y + dy / L * 1.6
    end
    local oax, oay = grow(ax, ay)
    local obx, oby = grow(bx, by)
    local ocx, ocy = grow(cx2, cy2)
    g.spikeO:Tri(oax, oay, obx, oby, ocx, ocy, pal.dk)
    g.spikeF:Tri(ax, ay, bx, by, cx2, cy2, pal.sp)
  end
  local k = 0
  local ds, hb0 = P(15, 17, 23), P(13, 11, 8)
  local sx = D.tT + 18
  while sx <= chest.cx + 4 and k < 46 do
    local a0, a1 = self:span(sx)
    local hs = hb0 * clamp((a1 - a0) / 26, 0.4, 1)
    local ccx, ccy = self:map(sx, a1 - 2)
    local _, h1 = self:span(sx - 3)
    local p1x, p1y = self:map(sx - 3, h1)
    local _, h2 = self:span(sx + 3)
    local p2x, p2y = self:map(sx + 3, h2)
    local tx, ty = p2x - p1x, p2y - p1y
    local L = hypot(tx, ty)
    if L < 1e-9 then L = 1 end
    tx, ty = tx / L, ty / L
    local sw = hs * 0.55
    spike(ccx - tx * sw, ccy - ty * sw, ccx + ty * hs - tx * hs * 0.45, ccy - tx * hs - ty * hs * 0.45,
      ccx + tx * sw, ccy + ty * sw)
    k = k + 1
    sx = sx + ds
  end
  for j = 0, 4 do
    if k >= 46 then break end
    local u = 0.12 + j * 0.2
    local cxn, cyn, nx, ny, qx, qy, h = st.nAt(u)
    local hs = hb0 * lerp(1, 0.55, u)
    local sw = hs * 0.55
    local ex, ey = cxn + nx * (h / 2 - 2), cyn + ny * (h / 2 - 2)
    spike(ex - qx * sw, ey - qy * sw, ex + nx * hs - qx * hs * 0.45, ey + ny * hs - qy * hs * 0.45, ex + qx * sw, ey + qy * sw)
    k = k + 1
  end
  local qa = 1 - 10 / 215
  local tax, tay = self:map(D.tT + 10, D.tailL(qa) + D.tailT(qa) / 2)
  local tcx, tcy = self:map(D.tT, D.tailL(1) + 1.5)
  local mSpade = M(tcx, tcy, atan2(tcy - tay, tcx - tax))
  g.spadeF:Sprite("SpadeFill", mSpade, pal.sp)
  g.spadeS:Sprite("SpadeStroke", mSpade, pal.dk)
  pl:End()
end

function Scene:DrawBody(st)
  local g, pal, pl = self.g, self.pal, self.planes.body
  local P, D, F = st.P, st.D, st.F
  local hip, waist, blob, chest = st.hip, st.waist, st.blob, st.chest
  local CLx, CLy, TH, NNx, NNy = st.CLx, st.CLy, st.TH, st.NNx, st.NNy
  pl:Begin()
  -- the tail, as a strip and as one closed ring for its outline
  local tailLo, tailUp = {}, {}
  local nSeg = 24
  for kk = 0, nSeg do
    local q = kk / nSeg
    local tsx = D.tB + (D.tT - D.tB) * q
    local l = D.tailL(q)
    local x1, y1 = self:map(tsx, l + 0.5)
    local x2, y2 = self:map(tsx, l + D.tailT(q))
    tailLo[#tailLo + 1], tailLo[#tailLo + 2] = x1, y1
    tailUp[#tailUp + 1], tailUp[#tailUp + 2] = x2, y2
  end
  local tailRing = {}
  for i = 1, #tailLo do tailRing[i] = tailLo[i] end
  for i = #tailUp - 1, 1, -2 do
    tailRing[#tailRing + 1] = tailUp[i]
    tailRing[#tailRing + 1] = tailUp[i + 1]
  end
  local tailOut = Draw.Offset(tailRing, 3)
  local loO, upO = {}, {}
  for i = 1, #tailLo do loO[i] = tailOut[i] end
  for i = 1, #tailLo, 2 do
    local j = #tailOut - i
    upO[i], upO[i + 1] = tailOut[j], tailOut[j + 1]
  end
  -- dark outlines under everything, then the fills
  g.bodyO:Strip(loO, upO, pal.dk)
  -- hip, waist and chest as fitted ellipses; the belly blob, which drapes over the hoard,
  -- as a ring of mapped points
  local fits = { { self:FitEllipse(hip) }, { self:FitEllipse(waist) }, { self:FitEllipse(chest) } }
  local blobRing = self:ellPts(blob, 36)
  for _, e in ipairs(fits) do fittedEllipse(g.bodyO, e[1], e[2], e[3], e[4], e[5], e[6], 3, pal.dk) end
  g.bodyO:Fan(Draw.Offset(blobRing, 3), pal.dk)
  for i = 0, NC - 1 do g.bodyO:Circle(CLx[i], CLy[i], TH[i] / 2 + 3, pal.dk) end
  g.bodyF:Strip(tailLo, tailUp, pal.bd)
  for _, e in ipairs(fits) do fittedEllipse(g.bodyF, e[1], e[2], e[3], e[4], e[5], e[6], 0, pal.bd) end
  g.bodyF:Fan(blobRing, pal.bd)
  for i = 0, NC - 1 do g.bodyF:Circle(CLx[i], CLy[i], TH[i] / 2, pal.bd) end

  -- the belly band and the neck's band
  local fr = P(0.3, 0.34, 0.42)
  local bandLo, bandHi = {}, {}
  local sx = D.tT + 6
  while sx <= D.tf0 - 1 do
    local a0, a1 = self:span(sx)
    if a1 >= a0 then
      local x1, y1 = self:map(sx, a0 + 0.5)
      local x2, y2 = self:map(sx, a0 + fr * (a1 - a0))
      bandLo[#bandLo + 1], bandLo[#bandLo + 2] = x1, y1
      bandHi[#bandHi + 1], bandHi[#bandHi + 2] = x2, y2
    end
    sx = sx + 9
  end
  g.band:Strip(bandLo, bandHi, pal.bl)
  local nLo, nHi = {}, {}
  for i = 0, NC - 1, 2 do
    local h = TH[i]
    nLo[#nLo + 1], nLo[#nLo + 2] = CLx[i] - NNx[i] * (h / 2 - 0.5), CLy[i] - NNy[i] * (h / 2 - 0.5)
    nHi[#nHi + 1], nHi[#nHi + 2] = CLx[i] + NNx[i] * (fr - 0.5) * h, CLy[i] + NNy[i] * (fr - 0.5) * h
  end
  g.band:Strip(nLo, nHi, pal.bl)

  -- belly plates
  local tfr = max(hip.cx + P(44, 50, 74), waist.cx + P(56, 62, 105), blob.cx + P(30, 90, 170), chest.cx + P(58, 64, 80))
  local k = 0
  local dp = P(10, 12, 18)
  local npl = F > 0.75 and 6 or 7
  sx = D.tT + 14
  while sx <= tfr - 6 and k < 64 do
    local a0, a1 = self:span(sx)
    if a1 >= a0 then
      k = k + 1
      local x1, y1 = self:map(sx, a0 + 1)
      local x2, y2 = self:map(sx - 2.5, a0 + fr * (a1 - a0) + 1)
      g.plates:Line(x1, y1, x2, y2, 1.5, pal.pl)
    end
    sx = sx + dp
  end
  for j = 0, npl - 1 do
    if k >= 64 then break end
    local ccx, ccy, nx, ny, qx, qy, h = st.nAt(0.1 + j * 0.8 / (npl - 1))
    local e = (fr - 0.5) * h + 1
    k = k + 1
    g.plates:Line(ccx - nx * (h / 2 - 1), ccy - ny * (h / 2 - 1), ccx + nx * e - qx * 2.5, ccy + ny * e - qy * 2.5, 1.5, pal.pl)
  end

  -- ribs when thin, creases when fat
  local ro, co = st.ro, st.co
  if ro > 0 then
    for i = 0, 4 do
      local rsx = chest.cx - 12 + i * 11
      local a0, a1 = self:span(rsx)
      local h = a1 - a0
      local x0, y0 = self:map(rsx + 4, a1 - 7)
      local cx1, cy1 = self:map(rsx - 10, a0 + h * 0.55)
      local x1, y1 = self:map(rsx - 7, a0 + h * 0.26)
      g.ribs:Poly(quadPts(x0, y0, cx1, cy1, x1, y1, 5), 2, pal.sh, ro * 0.85)
    end
  end
  if co > 0 then
    for _, sg in ipairs({ 1, -1 }) do
      local x0, y0 = self:map(blob.cx + sg * blob.ax * 0.48, 14)
      local cx1, cy1 = self:map(blob.cx + sg * blob.ax * 0.96, 14)
      local x1, y1 = self:map(blob.cx + sg * blob.ax * 0.93, blob.cy * 0.88)
      g.ribs:Poly(quadPts(x0, y0, cx1, cy1, x1, y1, 6), 2.5, pal.sh, co * 0.75)
    end
  end
  pl:End()
end

function Scene:DrawLimbs(st)
  local g, pal, pl = self.g, self.pal, self.planes.limbs
  local P, hip, chest, br = st.P, st.hip, st.chest, st.br
  pl:Begin()
  -- foot and thigh
  local tg = { cx = hip.cx + P(10, 10, 6), cy = P(22, 28, 46) * br, ax = P(24, 30, 46), b = P(23, 29, 44) * br }
  local fw = P(10, 13, 22)
  local fk = fw / 14
  local fy = 8 * fk + 0.5
  local fS = tg.cx + tg.ax + P(14, 16, 6)
  local fbx, fby = self:mapL(fS, fy)
  local fax, fay = self:mapL(tg.cx + tg.ax * 0.15, fy)
  g.footO:Poly({ fax, fay, fbx, fby }, fw + 6, pal.dk, 1, true)
  g.footF:Poly({ fax, fay, fbx, fby }, fw, pal.bd, 1, true)
  self:Paw(g.footPaw, fS, fbx, fby, fk, pal.bd)
  local tcx, tcy, tux, tuy, tvx, tvy = self:FitEllipse(tg)
  fittedEllipse(g.thighO, tcx, tcy, tux, tuy, tvx, tvy, 3, pal.dk)
  fittedEllipse(g.thighF, tcx, tcy, tux, tuy, tvx, tvy, 0, pal.bd)

  -- the wing
  local function T(tsx)
    local _, a1, ht = self:span(tsx)
    if ht > -1e8 then return ht end
    return a1
  end
  local function Wp(tsx, dy) return self:map(tsx, T(tsx) + dy) end
  local sr, dr = chest.cx - 6, P(30, 34, 40)
  local KW = { A = { sr, -4 }, Bc = { sr - 18, 16 }, B = { sr - 46, 14 }, Cc = { sr - 92, 16 }, C = { sr - 128, 2 },
    D1 = { sr - 104, -dr * 0.75 }, D2 = { sr - 74, -dr }, D3 = { sr - 42, -dr * 0.95 }, D4 = { sr - 10, -dr * 0.55 } }
  local function wp(name) return Wp(KW[name][1], KW[name][2]) end
  local function mid(a, b) return Wp((KW[a][1] + KW[b][1]) / 2, (KW[a][2] + KW[b][2]) / 2 + 9) end
  local wing = {}
  local function addQ(x0, y0, cx1, cy1, x1, y1)
    local q = quadPts(x0, y0, cx1, cy1, x1, y1, 6)
    for i = 3, #q do wing[#wing + 1] = q[i] end
    return x1, y1
  end
  local Ax, Ay = wp("A")
  wing[1], wing[2] = Ax, Ay
  local Bcx, Bcy = wp("Bc")
  local Bx, By = wp("B")
  local lxw, lyw = addQ(Ax, Ay, Bcx, Bcy, Bx, By)
  local Ccx, Ccy = wp("Cc")
  local Cx, Cy = wp("C")
  lxw, lyw = addQ(lxw, lyw, Ccx, Ccy, Cx, Cy)
  local prev = "C"
  for _, nm in ipairs({ "D1", "D2", "D3", "D4" }) do
    local mx, my = mid(prev, nm)
    local x1, y1 = wp(nm)
    lxw, lyw = addQ(lxw, lyw, mx, my, x1, y1)
    prev = nm
  end
  g.wing:Fill(wing, pal.wg)
  local outline = {}
  for i = 1, #wing do outline[i] = wing[i] end
  outline[#outline + 1], outline[#outline + 2] = wing[1], wing[2]
  g.wingLines:Poly(outline, 2.5, pal.dk)
  for _, nm in ipairs({ "D1", "D2", "D3" }) do
    local x1, y1 = wp(nm)
    g.wingLines:Line(Bx, By, x1, y1, 2, pal.dk)
  end
  local w1x, w1y = Wp(sr - 49, 13)
  local w2x, w2y = Wp(sr - 44, 23)
  local w3x, w3y = Wp(sr - 41, 12)
  local claw = { w1x, w1y, w2x, w2y, w3x, w3y }
  g.clawO:Fill(Draw.Offset(claw, 1), pal.dk)
  g.claw:Fill(claw, pal.bl)

  -- the near arm
  local pts, psx, px, py, lw = self:Arm(st, 0)
  g.armO:Poly(pts, lw + 6, pal.dk, 1, true)
  g.armF:Poly(pts, lw, pal.bd, 1, true)
  self:Paw(g.armPaw, psx, px, py, lw / 14, pal.bd)
  pl:End()
end

function Scene:DrawHead(st)
  local g, pal, pl = self.g, self.pal, self.planes.head
  local t, F, W = st.t, st.F, st.W
  local mHead, mJaw, ang, ja, jaR = st.mHead, st.mJaw, st.ang, st.ja, st.jaR
  local function toW(x, y) return apply(mHead, x, y) end
  pl:Begin()
  g.hornBackF:Sprite("HornBackFill", mHead, pal.hn)
  g.hornBackS:Sprite("HornBackStroke", mHead, pal.dk)
  local jwl = sst(0.55, 1, F)
  if jwl > 0.001 then
    local jx, jy = toW(16, -2)
    g.jowlO:Ellipse(jx, jy, (24 * jwl + 1.25) * HK, (12 * jwl + 1.25) * HK, ang, pal.dk)
    g.jowl:Ellipse(jx, jy, 24 * jwl * HK, 12 * jwl * HK, ang, pal.bd)
  end
  g.jawO:Sprite("JawOutline", mJaw, pal.dk)
  g.headO:Sprite("HeadOutline", mHead, pal.dk)
  g.jawF:Sprite("JawFill", mJaw, pal.bd)
  g.headF:Sprite("HeadFill", mHead, pal.bd)
  g.finF:Sprite("FinFill", mHead, pal.wg)
  g.finS:Sprite("FinStroke", mHead, pal.dk)

  -- mouth: the upper lip curve, and the same curve on the jaw
  local mq, qv = st.mq, st.qv
  local up, lo = {}, {}
  for i = 0, 10 do
    local u = i / 10
    local mx, my = mq(u)
    my = my + qv * sin(u * PI * 3 + t / 70) * sin(u * PI)
    up[#up + 1], up[#up + 2] = mx, my
    local rx, ry = rotA(mx, my, HGX, HGY, jaR)
    lo[#lo + 1], lo[#lo + 2] = rx, ry
  end
  local upW, loW = xform(mHead, up), xform(mHead, lo)
  if ja > 0.5 then g.mouth:Strip(upW, loW, C.mouth) end
  local tqx, tqy = rotA(76, -10, HGX, HGY, jaR)
  local gap = (76 - HGX) * sin(jaR)
  if gap > 1.5 then
    local tx, ty = toW(tqx, tqy)
    g.tongue:Ellipse(tx, ty, 13 * HK * 0.85, min(4, gap * 0.4) * HK, ang + jaR, C.tongue)
  end
  local ring = {}
  for i = 1, #upW do ring[i] = upW[i] end
  for i = #loW - 1, 1, -2 do
    ring[#ring + 1], ring[#ring + 2] = loW[i], loW[i + 1]
  end
  ring[#ring + 1], ring[#ring + 2] = upW[1], upW[2]
  g.mouthLine:Poly(ring, 2.3 * HK, pal.dk)
  local fa = sst(3, 9, ja)
  if fa > 0.01 then
    g.fangF:Sprite("FangFill", mHead, C.white, fa)
    g.fangS:Sprite("FangStroke", mHead, pal.dk, fa)
  end
  local lv = st.rw("lick")
  if lv > 0 and lv < 1 then
    local px, py = mq(0.85 - 0.7 * lv)
    local wx, wy = toW(px, py + 3)
    local s = sin(PI * lv) * W
    if s > 0.01 then
      g.lick:Ellipse(wx, wy, 5.75 * s * HK, 4.15 * s * HK, ang, pal.dk)
      g.lick:Ellipse(wx, wy, 5 * s * HK, 3.4 * s * HK, ang, C.tongue)
    end
  end
  local Cpx, Cpy = st.Cpx, st.Cpy
  local creaseA = sst(0.45, 0.85, st.sm)
  if creaseA > 0.01 then
    g.crease:Poly(xform(mHead, quadPts(Cpx + 1, Cpy + 2, Cpx - 3, Cpy - 0.5, Cpx - 1.5, Cpy - 3.5, 4)), 2 * HK, pal.dk, creaseA)
  end
  if st.bls > 0.005 then
    local bx, by = toW(40, -14)
    g.blush:Ellipse(bx, by, 9 * HK, 5 * HK, ang, C.blush, 0.6 * st.bls)
  end
  if st.ro > 0.01 then
    g.sunken:Poly(xform(mHead, quadPts(32, -18, 41, -11, 50, -13, 5)), 2 * HK, pal.sh, st.ro * 0.8)
  end

  self:DrawEye(st)

  local byy = -42.5
  local yo, yi = byy + st.bo, byy + st.bi
  g.brow:Poly(xform(mHead, quadPts(41, yo, 50, (yo + yi) / 2 - 1.5 + st.ba, 59, yi, 6)), 3 * HK, pal.dk, 1, true)
  g.nostril:Poly(xform(mHead, quadPts(91, -26, 94, -29, 97, -25, 4)), 2.3 * HK, pal.dk)
  g.hornFrontF:Sprite("HornFrontFill", mHead, pal.bl)
  g.hornFrontS:Sprite("HornFrontStroke", mHead, pal.dk)

  -- tears: the dashed stream and the welling drop
  local str, wel = st.str, st.wel
  if str > 0.01 then
    local pts = {}
    for i = 0, 24 do
      local x, y = bez3(i / 24, 49, -21, 47, -13, 51, -7, 50, 1)
      pts[#pts + 1], pts[#pts + 2] = x, y
    end
    local acc = -((t / 45) % 11)
    for i = 1, #pts - 3, 2 do
      local L = hypot(pts[i + 2] - pts[i], pts[i + 3] - pts[i + 1])
      if acc % 11 < 7 then
        local ax, ay = toW(pts[i], pts[i + 1])
        local bx, by = toW(pts[i + 2], pts[i + 3])
        g.stream:Line(ax, ay, bx, by, 3.4 * HK, C.tear, str)
      end
      acc = acc + L
    end
  end
  local ery = st.ery
  local tdv = st.rw("td")
  if tdv > 0 and tdv < 1 then
    local q = tdv < 0.55 and 0 or (tdv - 0.55) / 0.45
    local wr = tdv < 0.55 and 0.6 + 2.4 * tdv / 0.55 or 3 * (1 - 0.3 * q)
    local x, y = toW(EX + 6.5 - 1.5 * q, EY + ery * 0.8 + 18 * q * q)
    g.wdrop:Circle(x, y, wr * W * HK, C.tear, 1 - q ^ 4)
  elseif wel > 0 then
    local wp4 = (t % 4200) / 4200
    local wx, wy, wr, wo = EX + 6.5, EY + ery * 0.8, 2.4, wel
    if wp4 < 0.72 then
      wr = 0.6 + 2.4 * wp4 / 0.72
    else
      local q = (wp4 - 0.72) / 0.28
      wr = 3 * (1 - 0.3 * q)
      wy = wy + 18 * q * q
      wx = wx - 1.5 * q
      wo = wo * (1 - q ^ 4)
    end
    local x, y = toW(wx, wy)
    g.wdrop:Circle(x, y, wr * min(1, wel * 3) * HK, C.tear, wo)
  end
  pl:End()
end

function Scene:DrawEye(st)
  local g, pal = self.g, self.pal
  local mHead, ang = st.mHead, st.ang
  local open, eh, sqz, wel = st.open, st.eh, st.sqz, st.wel
  local ery = max(0.1, 9 * open)
  st.ery = ery
  local eo = sst(0.02, 0.3, open)
  local ev = eo * (1 - eh)
  if ev > 0.01 then
    local ecx, ecy = apply(mHead, EX, EY)
    g.eyeRing:Ellipse(ecx, ecy, (7.5 + 2.2) * HK, (ery + 2.2) * HK, ang, pal.dk, ev)
    g.eyeWhite:Ellipse(ecx, ecy, 7.5 * HK, ery * HK, ang, C.white, ev)
    local eyePoly = ellipsePoly(EX, EY, 7.5, ery, 24)
    local pcx, pcy = EX + 1.5 + st.lx, EY + 0.5 + st.ly
    local pupil = clipConvex(ellipsePoly(pcx, pcy, 4.6 * st.ps, 4.6 * st.ps, 20), eyePoly)
    if #pupil >= 6 then g.pupil:Fan(xform(mHead, pupil), pal.dk, ev) end
    local function glint(x, y, r, a)
      local gl = clipConvex(ellipsePoly(x, y, r, r, 12), eyePoly)
      if #gl >= 6 then g.glints:Fan(xform(mHead, gl), C.white, a) end
    end
    glint(pcx + 1.6, pcy - 2.2, 1.7, ev)
    if wel > 0.01 then
      glint(pcx - 1.8, pcy + 1.9, 1, ev * 0.9 * wel)
      local tline = clipLine(quadPts(EX - 6, EY + ery * 0.62, EX, EY + ery + 1, EX + 7, EY + ery * 0.55, 8), EX, EY, 7.5, ery)
      if #tline >= 4 then g.tline:Poly(xform(mHead, tline), 2.4 * HK, C.tear, wel * ev) end
    end
    local ul, ll, tlid = st.ul, st.ll, st.tlid
    local lidY = EY - ery + ul * 2 * ery
    local lowY = EY + ery - ll * 2 * ery
    local function lid(edgeY, curve, lineA, lineW)
      -- the lid: everything of the eye beyond its curve, clipped to the eye
      local shape = { 41, edgeY, 59, edgeY }
      for i = #curve - 1, 1, -2 do
        shape[#shape + 1], shape[#shape + 2] = curve[i], curve[i + 1]
      end
      local clipped = clipConvex(shape, eyePoly)
      if #clipped >= 6 then g.lids:Fill(xform(mHead, clipped), pal.bd, ev) end
      if lineA > 0.01 then
        local ln = clipLine(curve, EX, EY, 7.5 + 0.6, ery + 0.6)
        if #ln >= 4 then g.lidLines:Poly(xform(mHead, ln), lineW * HK, pal.dk, lineA * ev) end
      end
    end
    lid(EY - 11, quadPts(41, lidY + tlid, EX, lidY + 1.5, 59, lidY - tlid, 8), sst(0.03, 0.12, ul), 2)
    lid(EY + 11, quadPts(41, lowY, EX, lowY - 5 * ll, 59, lowY, 8), sst(0.05, 0.15, ll), 1.8)
  end
  local sA = (1 - eo) * (1 - sqz) * (1 - eh)
  if sA > 0.01 then g.eyeCurves:Poly(xform(mHead, quadPts(42, -28, 50, -21, 58, -28, 6)), 2.3 * HK, pal.dk, sA) end
  local qA = (1 - eo) * sqz * (1 - eh)
  if qA > 0.01 then
    local pts = quadPts(44, -35, 50, -31, 56, -28, 4)
    quadPts(56, -28, 50, -25, 44, -21, 4, pts)
    g.eyeCurves:Poly(xform(mHead, pts), 2.5 * HK, pal.dk, qA)
  end
  if eh > 0.01 then g.eyeCurves:Poly(xform(mHead, quadPts(42, -25, 50, -35, 58, -25, 6)), 2.5 * HK, pal.dk, eh) end
end

function Scene:DrawFx(st)
  local g, pl = self.g, self.planes.fx
  local t, W, E, eat, eb = st.t, st.W, st.E, st.eat, st.eb
  local mHead = st.mHead
  local function toW(x, y) return apply(mHead, x, y) end
  pl:Begin()
  local str = st.str
  if str > 0.05 then
    local dOx, dOy = toW(50, 2)
    for i = 0, 2 do
      local age = (t + i * 317) % 950
      local r, y = 0, dOy
      if age < 160 then
        r = 2.8 * age / 160
        y = y + r
      else
        local a2 = age - 160
        r = 2.8
        y = y + 2.8 + 0.00055 * a2 * a2 + 0.04 * a2
        if y > self:lim(dOx) - 1 then r = 0 end
      end
      if r > 0 then g.drops:Circle(dOx, y, r, C.tear, str) end
    end
  end
  if st.iP > 0.02 and eb < 0.5 then
    local nOx, nOy = toW(95, -27)
    for i = 0, 2 do
      local a = ((t + i * 867) % 2600) / 2600
      local o = (1 - a) * min(1, a / 0.12) * 0.65 * st.iP
      g.smoke:Circle(nOx + 8 * a + 2 * sin(a * 7 + i), nOy - 28 * a, 2 + 6 * a, C.smoke, o)
    end
  end
  if W < 1 then
    local zOx, zOy = toW(82, -58)
    for i = 0, 2 do
      local ph = (t / 2800 + i / 3) % 1
      g.zs:Text("z", zOx + ph * 26 + i * 2, zOy - ph * 52, 12 + ph * 9, C.zz, sin(PI * ph) * (1 - W))
    end
  end
  if eat then
    local q = eat.q
    while eat.qi <= #q and E >= q[eat.qi][2] do
      local kind = q[eat.qi][1]
      eat.qi = eat.qi + 1
      local i = eat.n[kind]
      eat.n[kind] = i + 1
      local ox, oy
      if kind == "c" then ox, oy = st.MWx, st.MWy
      elseif kind == "h" then ox, oy = toW(24 + i * 16, -66)
      else ox, oy = toW(106, -6) end
      eat.P[#eat.P + 1] = { k = kind, t0 = E, i = i, x = ox, y = oy }
    end
    for _, p in ipairs(eat.P) do
      local tau = (E - p.t0) / 1000
      if p.k == "c" then
        if tau <= 0.9 then
          local x = p.x + (50 + 25 * (p.i % 3)) * tau
          local y = min(p.y - 70 * tau + 300 * tau * tau, self:lim(x) - 1)
          local a = 1 - sst(0.5, 0.9, tau)
          g.crumbs:Circle(x, y, 2.7, C.crumbEdge, a)
          g.crumbs:Circle(x, y, 2.2, C.crumb, a)
        end
      elseif p.k == "h" then
        if tau <= 1.1 then
          local s = 0.6 + 0.6 * sst(0, 0.25, tau)
          g.hearts:Sprite("Heart", M(p.x + 6 * sin(tau * 7 + p.i), p.y - 45 * tau, 0, s), nil, 1 - sst(0.6, 1.1, tau))
        end
      elseif tau <= 1 then
        local r = 3 + 9 * tau
        local a = 0.85 * (1 - sst(0.3, 1, tau))
        local x, y = p.x + 30 * tau + 6 * p.i, p.y - 18 * tau - 4 * p.i
        g.burps:Circle(x, y, r + 0.6, C.burpEdge, a)
        g.burps:Circle(x, y, r, C.burp, a)
      end
    end
  end
  pl:End()
end

-- Eating -----------------------------------------------------------------------------------

-- feed: { x, y, onChomp, speed, outside, rot0, scale0 } (rot0 and scale0: how a haunch off
-- the pile lies there), or { join = true, onEnd } to start at the chomp, with nothing flying
-- in: the chewing and swallowing after the pile's stream.
function Scene:StartEat(t, feed)
  local m = Render.Mood(self.F)
  local S = EATS[m]
  local q = {}
  for _, v in ipairs(S.cr or {}) do q[#q + 1] = { "c", v } end
  for _, v in ipairs(S.ht or {}) do q[#q + 1] = { "h", v } end
  for _, v in ipairs(S.bp or {}) do q[#q + 1] = { "b", v } end
  table.sort(q, function(a, b) return a[2] < b[2] end)
  local speed = feed.speed or 1
  self.eat = { m = m, S = S, t0 = feed.join and t - S.ch / speed or t, join = feed.join and S.ch or nil,
    fired = false, cx = false, P = {}, q = q, qi = 1, n = { c = 0, h = 0, b = 0 },
    S0x = feed.x or self.mouthX, S0y = feed.y or self.mouthY, onChomp = feed.onChomp, onEnd = feed.onEnd,
    speed = speed, fromOutside = feed.outside, rot0 = feed.rot0, scale0 = feed.scale0 }
end

-- The top haunch of the pile, eaten on its own with his mood's eating sequence. It leaves
-- the pile the moment it starts to fly.
function Scene:NibbleOne(t)
  local n = self.pileCount
  local i = min(n, #PILE)
  self:SetMeatPile(n - 1)
  self:StartEat(t, { x = PILE[i][1], y = PILE[i][2], rot0 = i % 2 == 0 and 0.35 or -0.3, scale0 = 0.8 })
  if self.onNibble then
    local ok, err = pcall(self.onNibble, self.pileCount)
    if not ok and ns.report then ns.report(err) end
  end
end

-- The pile's stream, one step: waiting until he's awake and done eating, opening wide,
-- sending the haunches off the top of the pile and following them in, then shutting.
function Scene:StepStream(dt, t)
  local sm = self.stream
  if sm.phase == "wait" then
    if self.Wt ~= 1 or self.wl < 1 or self.eat then return end
    sm.phase, sm.t = "open", 0
  end
  sm.t = sm.t + dt
  if sm.phase == "open" then
    sm.open = sst(0, STREAM_OPEN, sm.t)
    if sm.t >= STREAM_OPEN then sm.phase, sm.t = "flow", 0 end
  elseif sm.phase == "flow" then
    sm.open = 1
    -- each haunch leaves the pile the moment it starts flying
    while sm.sent < sm.n and sm.t >= sm.sent / STREAM_RATE do
      local n = self.pileCount
      if n <= 0 then
        sm.n = sm.sent
        break
      end
      local i = min(n, #PILE)
      sm.flying[#sm.flying + 1] = { x = PILE[i][1], y = PILE[i][2], rot = i % 2 == 0 and 0.35 or -0.3,
        t0 = sm.sent / STREAM_RATE, k = sm.sent * 1.7 }
      sm.sent = sm.sent + 1
      self:SetMeatPile(n - 1)
      if sm.onEach then
        local ok, err = pcall(sm.onEach, self.pileCount)
        if not ok and ns.report then ns.report(err) end
      end
    end
    local i = 1
    while i <= #sm.flying do
      local f = sm.flying[i]
      if sm.t - f.t0 >= STREAM_FLIGHT then
        table.remove(sm.flying, i)
        sm.ins[#sm.ins + 1] = f.t0 + STREAM_FLIGHT   -- when it went in
      else
        i = i + 1
      end
    end
    -- each haunch that goes in makes his jaw gulp; until the first, it holds still
    local g, j = 0, 1
    while j <= #sm.ins do
      local x = (sm.t - sm.ins[j]) / GULP_TIME
      if x >= 1 then
        table.remove(sm.ins, j)
      else
        if x >= 0 then g = max(g, sin(PI * x)) end
        j = j + 1
      end
    end
    sm.gulp = g
    if sm.sent >= sm.n and #sm.flying == 0 and #sm.ins == 0 then sm.phase, sm.t = "shut", 0 end
  elseif sm.phase == "shut" then
    sm.open = 1 - sst(0, STREAM_SHUT, sm.t)
    sm.gulp = 0
    if sm.t >= STREAM_SHUT then
      self.stream = nil
      self:StartEat(t, { join = true, onEnd = sm.onDone })
    end
  end
end

-- One frame of animation, at most fps times a second, only while shown. While nothing but
-- breathing happens, 30 a second keeps him smooth; parts that move less than a fraction of
-- a pixel between frames aren't touched (see Draw.EPS).
local IDLE_FPS = 30

function Scene:OnUpdate(elapsed)
  if self.paused or not self.frame:IsVisible() then return end
  self.acc = self.acc + elapsed
  local fps = self.fps
  local busy = self.eat or self.stream or #self.feeds > 0 or self.anim or self.silT < 1 or self.wl ~= self.Wt
  if not busy and fps > IDLE_FPS then fps = IDLE_FPS end
  if self.acc < 1 / fps then return end
  local dt = min(0.1, self.acc)
  self.acc = 0
  self:Step(dt, GetTime() * 1000)
end

function Scene:Step(dt, t)
  if self.canvas:Layout() then self.staticDirty = true end
  -- shape changes
  local an = self.anim
  if an then
    an.p = min(1, an.p + dt / an.dur)
    local s = sst(0, 1, an.p)
    self.F = lerp(an.F0, an.F1, s)
    self.H = lerp(an.H0, an.H1, s)
    self.needB = true
    if an.p >= 1 then
      self.anim = nil
      if an.done then
        local ok, err = pcall(an.done)
        if not ok and ns.report then ns.report(err) end
      end
    end
  end
  -- silhouette fades
  if self.silT < 1 then
    self.silT = min(1, self.silT + dt / max(0.01, self.silDur))
    self.sil = lerp(self.silFrom, self.silTo, sst(0, 1, self.silT))
    self.canvas.sil = self.sil
    self.staticDirty = true
    if self.backdrop then self.backdrop:SetAlpha(self.sil) end
  end
  -- asleep <-> awake over 0.9 s
  if self.wl ~= self.Wt then
    if self.Wt > self.wl then self.wl = min(1, self.wl + dt / 0.9) else self.wl = max(0, self.wl - dt / 0.9) end
    self.W = sst(0, 1, self.wl)
  end
  -- eating: a haunch at a time, or the pile's stream (other haunches wait for it)
  local eat = self.eat
  if eat and (t - eat.t0) * eat.speed >= eat.S.dur then
    self.eat = nil
    if eat.onEnd and not eat.cx then
      local ok, err = pcall(eat.onEnd)
      if not ok and ns.report then ns.report(err) end
    end
  end
  if self.stream then self:StepStream(dt, t) end
  if not self.eat and not self.stream and self.Wt == 1 and self.wl >= 1 then
    if #self.feeds > 0 then
      self:StartEat(t, table.remove(self.feeds, 1))
    elseif self.nibble and self.pileCount > 0 then
      -- awake with nothing else to eat: his pile, a haunch at a time
      self:NibbleOne(t)
    end
  end
  if self.needB then
    self.needB = false
    self:Build()
    if self.H ~= self.Hb then
      self.Hb = self.H
      self.staticDirty = true
    end
  end
  if self.staticDirty then
    self.staticDirty = false
    self:DrawStatic()
  end
  self:Draw(t)
end

-- API ----------------------------------------------------------------------------------------

function Scene:SetWeight(F)
  self.F = clamp(F, 0, 1)
  self.anim = nil
  self.needB = true
end

function Scene:SetWealth(H)
  self.H = clamp(H, 0, 1)
  self.anim = nil
  self.needB = true
end

function Scene:GetWeight() return self.anim and self.anim.F1 or self.F end
function Scene:GetWealth() return self.anim and self.anim.H1 or self.H end

function Scene:AnimateTo(F, H, seconds, onDone)
  self.anim = { F0 = self.F, H0 = self.H, F1 = clamp(F, 0, 1), H1 = clamp(H, 0, 1), p = 0,
    dur = max(0.05, seconds or 1.5), done = onDone }
end

function Scene:SetAwake(awake, instant)
  self.Wt = awake and 1 or 0
  if instant then
    self.wl = self.Wt
    self.W = self.Wt
  end
  if not awake then
    if self.eat then self.eat.cx = true end
    self.feeds = {}
    self.stream = nil
  end
end

function Scene:IsAwake() return self.Wt == 1 end

function Scene:SetPalette(body, belly, spikes)
  self.pal = palette(body, belly, spikes)
  self.staticDirty = true
end

function Scene:SetSilhouette(t, seconds)
  t = clamp(t, 0, 1)
  if not seconds or seconds <= 0 then
    self.sil, self.silTo, self.silT = t, t, 1
    self.canvas.sil = t
    self.staticDirty = true
    if self.backdrop then self.backdrop:SetAlpha(t) end
  elseif t ~= self.silTo then
    self.silFrom, self.silTo, self.silT, self.silDur = self.sil, t, 0, seconds
  end
end

function Scene:GetSilhouette() return self.silTo end

-- The window's dark cover over its whole backdrop, a texture shown as much as the
-- silhouette is. The scene draws its own dark background only without one.
function Scene:SetBackdrop(tex)
  if self.backdrop and self.backdrop ~= tex then self.backdrop:SetAlpha(0) end
  self.backdrop = tex
  if tex then tex:SetAlpha(self.sil) end
  self.staticDirty = true
end

function Scene:GetMeatPile() return self.pileCount end

function Scene:SetMeatPile(n)
  n = max(0, floor(n or 0))
  if n ~= self.pileCount then
    self.pileCount = n
    self:DrawPile()
  end
end

-- Eats the whole pile in one go, as a stream of haunches into his open mouth (see
-- StepStream), as soon as he's awake: onEach(left) as each haunch leaves the pile, onDone()
-- once he's chewed and swallowed. It takes about (haunches / STREAM_RATE + STREAM_FLIGHT)
-- seconds, plus opening wide and the chewing.
function Scene:EatPile(onEach, onDone)
  local n = self.pileCount
  if n <= 0 then
    if onDone then onDone() end
    return
  end
  self.stream = { phase = "wait", t = 0, open = 0, gulp = 0, n = n, sent = 0, flying = {}, ins = {},
    onEach = onEach, onDone = onDone }
end

function Scene:IsEatingPile() return self.stream ~= nil end

-- Whether he eats his pile a haunch at a time while he's awake and has nothing else to eat
-- (the pile's stream aside); onTake(left) as each haunch leaves the pile.
function Scene:SetNibbling(on, onTake)
  self.nibble = on and true or false
  self.onNibble = onTake
end

-- Where the n-th haunch of the meat pile lies, as the pile draws it: the centre of its
-- picture in scene units, its turn (radians, clockwise) and the picture's width in scene
-- units. Haunches past the pile's 15 places lie on its top.
local HAUNCH_BOX = ns.RenderMedia.Haunch
function Scene:PileSpot(n)
  local i = clamp(n, 1, #PILE)
  local p = PILE[i]
  local rot = i % 2 == 0 and 0.35 or -0.3
  local k = 0.8
  local cx, cy = (HAUNCH_BOX[2] + HAUNCH_BOX[4]) / 2, (HAUNCH_BOX[3] + HAUNCH_BOX[5]) / 2
  local co, si = cos(rot), sin(rot)
  return p[1] + k * (co * cx - si * cy), p[2] + k * (si * cx + co * cy), rot, k * (HAUNCH_BOX[4] - HAUNCH_BOX[2])
end

-- The width of the haunch's picture when it flies to his mouth (scale 1), in scene units.
function Scene:HaunchSize() return HAUNCH_BOX[4] - HAUNCH_BOX[2] end

-- Frame pixels per scene unit.
function Scene:Scale()
  self.canvas:Layout()
  return self.canvas.s
end

-- A haunch flies from (fromX, fromY) in scene units into the mouth.
function Scene:Feed(fromX, fromY, onChomp)
  local outside = fromX < 0 or fromX > 680 or fromY < 20 or fromY > 440
  self.feeds[#self.feeds + 1] = { x = fromX, y = fromY, onChomp = onChomp, outside = outside }
end

function Scene:IsBusy() return self.eat ~= nil or self.stream ~= nil or #self.feeds > 0 end

-- Drops the haunches waiting to fly in and stops the pile's stream; the one he's eating, he
-- finishes. What's left on the pile stays there.
function Scene:StopFeeding()
  self.feeds = {}
  self.stream = nil
end

function Scene:GetMouth() return self.mouthX, self.mouthY end

function Scene:SceneToFrame(x, y)
  self.canvas:Layout()
  return self.canvas:ToFrame(x, y)
end

function Scene:FrameToScene(dx, dy)
  self.canvas:Layout()
  return self.canvas:ToScene(dx, dy)
end

function Scene:SetFrameRate(fps) self.fps = clamp(fps or 30, 1, 120) end

function Scene:SetPaused(paused)
  self.paused = paused and true or false
  if not paused then self.staticDirty = true end
end

-- Draws one frame now (for snapshots and tests).
function Scene:Render(t)
  self:Step(0, t or GetTime() * 1000)
end
