-- render_svg.lua: draws Pinto's scene offline, from the geometry uistub.lua recorded,
-- into SVG files under tools/sim/out/ with an index.html to browse them.
--
--   lua tools/sim/render_svg.lua
--
-- Tinted textures use the PNG previews tools/textures.py writes to tools/sim/out/media/.
package.path = "tools/sim/?.lua;" .. package.path
local H = require("harness")
local U = require("uistub")

local OUT = "tools/sim/out/"

local R = {}

function R.Load()
  local env = U.Env()
  local ns = H.load({ "Render/MediaData.lua", "Render/Draw.lua", "Render/Pinto.lua" }, {}, env)
  return ns, env
end

local function fmt(v) return string.format("%.2f", v) end

local function hex(c)
  return string.format("#%02x%02x%02x", math.floor(c[1] * 255 + 0.5), math.floor(c[2] * 255 + 0.5),
    math.floor(c[3] * 255 + 0.5))
end

-- Texture box of a region: its TOPLEFT offset and size, in frame units (y up).
local function quad(r)
  local p = r.points.TOPLEFT
  if not p then return nil end
  return p.x, p.y, r.w, r.h
end

-- The affine map texture (s, t) -> frame (x, y), from the quad and its texture coords.
local function affine(r)
  local x, y, w, h = quad(r)
  local tc = r.tc or { 0, 0, 0, 1, 1, 0, 1, 1 }
  -- corners: UL (x, y), LL (x, y - h), UR (x + w, y)
  local s0, t0 = tc[1], tc[2]
  local sL, tL = tc[3], tc[4]
  local sR, tR = tc[5], tc[6]
  -- frame = UL + J·(st - st0); J maps the texture differences to frame differences
  local a11, a21 = sR - s0, tR - t0   -- texture delta for UR - UL
  local a12, a22 = sL - s0, tL - t0   -- texture delta for LL - UL
  local det = a11 * a22 - a12 * a21
  if math.abs(det) < 1e-12 then return nil end
  -- frame deltas: UR - UL = (w, 0), LL - UL = (0, -h)
  local i11, i12, i21, i22 = a22 / det, -a12 / det, -a21 / det, a11 / det
  local J11 = w * i11 + 0 * i21
  local J12 = w * i12 + 0 * i22
  local J21 = 0 * i11 + (-h) * i21
  local J22 = 0 * i12 + (-h) * i22
  return function(s, t)
    local ds, dt = s - s0, t - t0
    return x + J11 * ds + J12 * dt, y + J21 * ds + J22 * dt
  end, { J11, J21, J12, J22 }, x, y, s0, t0
end

local filters = {}
local filterDefs = {}
local prefix = ""
local function filterFor(c)
  local key = string.format("%.3f_%.3f_%.3f", c[1], c[2], c[3])
  if not filters[key] then
    local id = prefix .. "f" .. (#filterDefs + 1)
    filters[key] = id
    filterDefs[#filterDefs + 1] = string.format(
      '<filter id="%s" color-interpolation-filters="sRGB"><feColorMatrix type="matrix" values="%s 0 0 0 0  0 %s 0 0 0  0 0 %s 0 0  0 0 0 1 0"/></filter>',
      id, fmt(c[1]), fmt(c[2]), fmt(c[3]))
  end
  return filters[key]
end

local TRI = { 8 / 256, 8 / 256, 248 / 256, 8 / 256, 8 / 256, 248 / 256 }

-- Textures go into the SVG itself, so it works anywhere (also as a data: URL).
local B64 = "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789+/"
local function base64(s)
  local out = {}
  for i = 1, #s, 3 do
    local a, b, c = s:byte(i, i + 2)
    local v = a * 65536 + (b or 0) * 256 + (c or 0)
    local function ch(k) return B64:sub(k + 1, k + 1) end
    out[#out + 1] = ch(v // 262144 % 64) .. ch(v // 4096 % 64) .. (b and ch(v // 64 % 64) or "=") .. (c and ch(v % 64) or "=")
  end
  return table.concat(out)
end

local imageDefs, imageUsed = {}, {}
local function imageRef(name)
  if not imageUsed[name] then
    imageUsed[name] = true
    local f = io.open(OUT .. "media/" .. name .. ".png", "rb")
    local data = f and f:read("a") or ""
    if f then f:close() end
    imageDefs[#imageDefs + 1] = string.format(
      '<image id="m_%s" width="1" height="1" preserveAspectRatio="none" href="data:image/png;base64,%s"/>', name, base64(data))
  end
  return "#m_" .. name
end

-- shared: when given, image definitions go into it instead of this SVG (contact sheets)
function R.SVG(root, w, h, title, idPrefix, shared)
  filters, filterDefs = {}, {}
  prefix = idPrefix or ""
  if shared then
    imageDefs, imageUsed = shared.defs, shared.used
  else
    imageDefs, imageUsed = {}, {}
  end
  local body = {}
  local clipN = 0
  for _, r in ipairs(U.Collect(root)) do
    local c = r.vc or { 1, 1, 1, 1 }
    local alpha = (c[4] or 1) * (r.alpha or 1)
    if alpha > 0.003 then
      if r.kind == "Line" and r.p1 and r.p2 then
        body[#body + 1] = string.format('<line x1="%s" y1="%s" x2="%s" y2="%s" stroke="%s" stroke-opacity="%s" stroke-width="%s"/>',
          fmt(r.p1.x), fmt(-r.p1.y), fmt(r.p2.x), fmt(-r.p2.y), hex(c), fmt(alpha), fmt(r.thickness or 1))
      elseif r.kind == "FontString" and r.text then
        local p = r.points.BOTTOMLEFT or r.points.TOPLEFT or { x = 0, y = 0 }
        body[#body + 1] = string.format('<text x="%s" y="%s" font-size="%s" fill="%s" fill-opacity="%s" font-family="sans-serif">%s</text>',
          fmt(p.x), fmt(-p.y), fmt(r.size or 12), hex(c), fmt(alpha), r.text)
      elseif r.kind == "Texture" and r.path then
        local x, y, tw, th = quad(r)
        if x then
          if r.path == "color" then
            local col = r.color or { 1, 1, 1, 1 }
            local cc = { col[1] * c[1], col[2] * c[2], col[3] * c[3] }
            body[#body + 1] = string.format('<rect x="%s" y="%s" width="%s" height="%s" fill="%s" fill-opacity="%s"/>',
              fmt(x), fmt(-y), fmt(tw), fmt(th), hex(cc), fmt(alpha * (col[4] or 1)))
          else
            local name = r.path:match("([^\\]+)$")
            local map, J, ux, uy, s0, t0 = affine(r)
            if map then
              if name == "Tri" then
                local ax, ay = map(TRI[1], TRI[2])
                local bx, by = map(TRI[3], TRI[4])
                local cx, cy = map(TRI[5], TRI[6])
                body[#body + 1] = string.format('<polygon points="%s,%s %s,%s %s,%s" fill="%s" fill-opacity="%s"/>',
                  fmt(ax), fmt(-ay), fmt(bx), fmt(-by), fmt(cx), fmt(-cy), hex(c), fmt(alpha))
              else
                -- the image's unit square through the affine map, clipped to the quad
                clipN = clipN + 1
                local ox, oy = map(0, 0)
                local m = string.format("matrix(%s %s %s %s %s %s)", fmt(J[1]), fmt(-J[2]), fmt(J[3]), fmt(-J[4]), fmt(ox), fmt(-oy))
                local fid = filterFor(c)
                body[#body + 1] = string.format(
                  '<clipPath id="%sc%d"><rect x="%s" y="%s" width="%s" height="%s"/></clipPath><g clip-path="url(#%sc%d)" opacity="%s"><use href="%s" transform="%s" filter="url(#%s)"/></g>',
                  prefix, clipN, fmt(x), fmt(-y), fmt(tw), fmt(th), prefix, clipN, fmt(alpha), imageRef(name), m, fid)
              end
            end
          end
        end
      end
    end
  end
  return string.format('<svg xmlns="http://www.w3.org/2000/svg" viewBox="0 0 %d %d" width="%d" height="%d"><title>%s</title><defs>%s%s</defs><rect width="100%%" height="100%%" fill="#1f1f1d"/>%s</svg>',
    w, h, w, h, title or "", table.concat(filterDefs), shared and "" or table.concat(imageDefs), table.concat(body, "\n"))
end

-- One scene in a fresh root, sized 680x420.
function R.NewScene(ns, env)
  local holder = U.CreateFrame("Frame", nil, env.UIParent)
  holder:SetSize(680, 420)
  local scene = ns.Render.New(holder)
  scene.frame:SetAllPoints(holder)
  return scene, holder
end

function R.Write(name, svg)
  local f = assert(io.open(OUT .. name, "w"))
  f:write(svg)
  f:close()
end

-- Snapshots for a grid of states.
function R.Snapshots()
  os.execute(package.config:sub(1, 1) == "\\" and 'mkdir "tools\\sim\\out" 2>nul' or "mkdir -p tools/sim/out")
  local ns, env = R.Load()
  local items = {}
  local sheet = { defs = {}, used = {} }
  local sheetBody = {}
  local function snap(name, setup, t)
    local scene, holder = R.NewScene(ns, env)
    setup(scene)
    U.time = (t or 5000) / 1000
    for _ = 1, 3 do scene:Render(t or 5000) end
    R.Write(name .. ".svg", R.SVG(holder, 680, 420, name))
    items[#items + 1] = name
    sheetBody[#sheetBody + 1] = string.format('<figure>%s<figcaption>%s</figcaption></figure>',
      R.SVG(holder, 680, 420, name, "s" .. #items, sheet):gsub('width="680" height="420"', 'width="340" height="210"', 1), name)
  end
  for _, F in ipairs({ 0.05, 0.25, 0.5, 0.75, 0.95 }) do
    for _, Hw in ipairs({ 0, 0.35, 1 }) do
      for _, awake in ipairs({ true, false }) do
        snap(string.format("w%02d_g%03d_%s", math.floor(F * 100 + 0.5), math.floor(Hw * 100 + 0.5), awake and "awake" or "asleep"),
          function(s)
            s:SetWeight(F)
            s:SetWealth(Hw)
            s:SetAwake(awake, true)
          end)
      end
    end
  end
  for mood, F in ipairs({ 0.05, 0.25, 0.5, 0.75, 0.95 }) do
    local S = ns.Render.EATS[mood]
    snap(string.format("eat%d_flying", mood), function(s)
      s:SetWeight(F)
      s:SetWealth(0.35)
      s:SetAwake(true, true)
      s:Feed(640, 60)
      s:Render(1000)
    end, 1000 + S.ch * 0.6)
    snap(string.format("eat%d_chomp", mood), function(s)
      s:SetWeight(F)
      s:SetWealth(0.35)
      s:SetAwake(true, true)
      s:Feed(640, 60)
      s:Render(1000)
    end, 1000 + S.ch + 250)
  end
  snap("silhouette", function(s)
    s:SetWeight(0.6)
    s:SetWealth(0.5)
    s:SetAwake(true, true)
    s:SetSilhouette(1)
  end)
  snap("pile6_asleep", function(s)
    s:SetWeight(0.5)
    s:SetWealth(0.35)
    s:SetAwake(false, true)
    s:SetMeatPile(6)
  end)
  local html = { "<!doctype html><meta charset=utf-8><title>Pinto snapshots</title><style>body{background:#111;color:#ccc;font:13px sans-serif}figure{display:inline-block;margin:6px}img{width:340px;border:1px solid #333}</style>" }
  for _, name in ipairs(items) do
    html[#html + 1] = string.format('<figure><img src="%s.svg"><figcaption>%s</figcaption></figure>', name, name)
  end
  R.Write("index.html", table.concat(html, "\n"))
  R.Write("sheet.html", "<!doctype html><meta charset=utf-8><title>Pinto contact sheet</title>"
    .. "<style>body{background:#111;color:#ccc;font:12px sans-serif;margin:8px}figure{display:inline-block;margin:4px}</style>"
    .. '<svg width="0" height="0" style="position:absolute"><defs>' .. table.concat(sheet.defs) .. "</defs></svg>"
    .. table.concat(sheetBody, "\n"))
  return #items
end

if arg and arg[0] and arg[0]:find("render_svg") then
  local n = R.Snapshots()
  print(string.format("wrote %d snapshots to %sindex.html", n, OUT))
end

return R
