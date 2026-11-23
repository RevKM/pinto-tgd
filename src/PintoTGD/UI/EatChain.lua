-- The "quest eaten" animation, in the full window, for each finished quest the player
-- hasn't seen eaten yet:
--   1. the quest line is redrawn as one FontString per character, so each can fade;
--   2. a glowing mote sweeps over it, and each glyph fades as the mote passes; the quest's
--      marker and its other lines fade with it;
--   3. the reward fades in where the quest was, "Rewards [haunch][haunch] haunches", while
--      the row eases to the reward's height and the lines below follow;
--   4. it stays 3 seconds. If the quest earned the new-member bonus, one more drumstick pops
--      in after the others meanwhile, in a burst of golden sparks, with "New guildie bonus!"
--      over it, and the word after them makes room. Nothing announced the bonus before, so
--      this is where the player finds out;
--   5. the row collapses over the reward's words as they fade, and the lines below slide up.
--      Its drumsticks come loose first, so they neither fade nor get cut off: each lifts off
--      and grows to Pinto's size. The first one to find him free flies into his mouth (the
--      scene does that) and he eats it with the eating sequence for his mood; the others hop
--      along a playful arc onto his meat pile, spinning once, and he eats the pile a haunch at
--      a time whenever he's free. While he sleeps, they all hop onto the pile.
local ADDON, ns = ...

local UI = ns.UI
local Eat = {}
UI.Eat = Eat

local frame, flyer
local queue = {}
local cur = nil
local glyphPool, motes, icons, sparks = {}, {}, {}, {}
local bonusLabel

local SWEEP_MIN, SWEEP_MAX = 0.7, 1.8
local REVEAL = 0.45      -- the reward fades in and the row eases to the reward's height
local HOLD = 3           -- the reward stays this long once it's in
local COLLAPSE = 0.4     -- the row closes over the reward's words
local REWARD_H = 26      -- the row's height while it shows the reward
local ICON = 18          -- a drumstick in the reward line
local LIFT = 0.25        -- a drumstick lifts off and grows to Pinto's size
local HOP = 0.85         -- its hop onto the pile
local HOP_HEIGHT = 90    -- how far above the higher end the hop's arc reaches
local STAGGER = 0.12     -- between drumsticks
local BONUS_AT = 0.6     -- the bonus drumstick pops in this long into the hold
local BONUS_POP = 0.45   -- its pop
local LABEL_TIME = 1.6   -- "New guildie bonus!", from the pop
local BURST = 0.8        -- the sparks
local SPARKS = 10

local TEXT_X = UI.QuestList.TEXT_X or 26

function Eat.Running() return cur ~= nil end

local function glyph(i, parent)
  local g = glyphPool[i]
  if not g then
    g = parent:CreateFontString(nil, "OVERLAY", "GameFontHighlight")
    glyphPool[i] = g
  end
  g:SetParent(parent)
  g:Show()
  g:SetAlpha(1)
  return g
end

local function clear()
  for _, g in ipairs(glyphPool) do g:Hide() end
  for _, m in ipairs(motes) do m:Hide() end
  for _, h in ipairs(icons) do h:Hide() end
  for _, s in ipairs(sparks) do s:Hide() end
  if bonusLabel then bonusLabel:Hide() end
end

-- All the haunches a finished quest feeds Pinto: its worth and the bonus.
local function total(entry) return entry.worth + (entry.bonus or 0) end

-- Places -----------------------------------------------------------------------------------
-- The drumsticks live on their own frame over the whole window, above Pinto's scene, so they
-- can fly from the quest list to him. Places are offsets from the window's top-left corner.

local function at(tex, x, y)
  tex:ClearAllPoints()
  tex:SetPoint("CENTER", UI.FullWindow(), "TOPLEFT", x, y)
end

local function sceneToWindow(sx, sy)
  local fx, fy = UI.Win.Scene():SceneToFrame(sx, sy)
  local hx, hy = UI.Win.HolderOffset()
  return hx + fx, hy + fy
end

local function windowToScene(x, y)
  local hx, hy = UI.Win.HolderOffset()
  return UI.Win.Scene():FrameToScene(x - hx, y - hy)
end

local function icon(i)
  local h = icons[i]
  if not h then
    h = UI.Haunch(flyer, ICON, "OVERLAY")
    icons[i] = h
  end
  h:SetSize(ICON, ICON)
  h:SetRotation(0)
  h:SetAlpha(1)
  h:Show()
  return h
end

-- The reward line: "Rewards", the drumsticks, then "haunch" or "haunches".
local function iconX(c, i) return c.ix0 + (i - 0.5) * ICON + (i - 1) end

local function words(row)
  if not row.rewardWords then row.rewardWords = { UI.Text(row, "GameFontNormal"), UI.Text(row, "GameFontNormal") } end
  return row.rewardWords[1], row.rewardWords[2]
end

local function placeTail(c, extra)
  if not c.tail then return end
  c.tail:ClearAllPoints()
  c.tail:SetPoint("LEFT", c.row, "TOPLEFT", c.ix0 + c.n * ICON + (c.n - 1) + 5 + extra, -REWARD_H / 2)
end

-- The sweep -----------------------------------------------------------------------------------

local function startReveal(c)
  c.phase, c.t = "reveal", 0
  c.n = c.entry.worth
  local row = c.row
  if row then
    c.ox, c.oy = UI.QuestList.RowOrigin(row)
    c.h0 = row.height or row.full or REWARD_H
    c.label, c.tail = words(row)
    c.label:SetText("Rewards")
    c.label:ClearAllPoints()
    c.label:SetPoint("LEFT", row, "TOPLEFT", TEXT_X, -REWARD_H / 2)
    c.label:SetAlpha(0)
    c.label:Show()
    c.ix0 = TEXT_X + (c.label:GetStringWidth() or 40) + 5
    c.tail:SetText(c.n == 1 and "haunch" or "haunches")
    c.tail:SetAlpha(0)
    c.tail:Show()
    placeTail(c, 0)
    c.hold = HOLD
  else
    -- not on screen: the drumsticks alone, at the top of the quest list
    c.ox, c.oy = UI.Win.PanelOffset()
    c.oy = c.oy - 4
    c.ix0 = TEXT_X
    c.hold = (c.entry.bonus or 0) > 0 and BONUS_AT + LABEL_TIME or 0.3
  end
  for i = 1, c.n do
    local h = icon(i)
    at(h, c.ox + iconX(c, i), c.oy - REWARD_H / 2)
    h:SetAlpha(0)
  end
end

local function stepSweep(c)
  local t = c.t
  local n = #c.glyphs
  local p = math.min(1, t / c.dur)
  local pos = p * (n + 2)
  -- the marker, the note and the reward line fade with the text
  local fade = 1 - UI.Smooth(p * 1.4)
  for _, part in ipairs({ c.row.note, c.row.reward, c.row.bullet, c.row.check }) do part:SetAlpha(fade) end
  for i, g in ipairs(c.glyphs) do
    local since = (pos - i) / n * c.dur
    g.fs:SetAlpha(1 - UI.Smooth(since / 0.15))
  end
  -- the mote rides along the glyphs, with a short sparkle trail
  local idx = math.max(1, math.min(n, math.floor(pos)))
  if c.glyphs[idx] then
    for k, m in ipairs(motes) do
      local j = math.max(1, idx - (k - 1) * 2)
      local tg = c.glyphs[j]
      m:ClearAllPoints()
      m:SetPoint("CENTER", c.row, "TOPLEFT", tg.x + 4, tg.y - 6)
      m:SetAlpha((p < 1 and 1 or 0) * (k == 1 and 1 or 0.45 / k))
      m:Show()
    end
  end
  if p >= 1 then
    for _, m in ipairs(motes) do m:Hide() end
    for _, g in ipairs(c.glyphs) do g.fs:Hide() end
    startReveal(c)
  end
end

-- The reward ---------------------------------------------------------------------------------

local function stepReveal(c)
  local q = math.min(1, c.t / REVEAL)
  local e = UI.Smooth(q)
  if c.row then
    UI.QuestList.SetRowHeight(c.row, c.h0 + (REWARD_H - c.h0) * e)
    c.label:SetAlpha(e)
    c.tail:SetAlpha(e)
  end
  for i = 1, c.n do icons[i]:SetAlpha(e) end
  if q >= 1 then c.phase, c.t = "hold", 0 end
end

-- The bonus drumstick, after the others, with its sparks and label; the word after the
-- drumsticks makes room for it.
local function startBonus(c)
  c.bonus = true
  local panel = UI.QuestList.Panel()
  local h = icon(c.n + 1)
  h:SetSize(1, 1)
  at(h, c.ox + iconX(c, c.n + 1), c.oy - REWARD_H / 2)
  c.bonusIcon = h
  for k = 1, SPARKS do
    local s = sparks[k]
    if not s then
      s = panel:CreateTexture(nil, "OVERLAY", nil, 6)
      s:SetTexture(UI.Media("Mote"))
      s:SetBlendMode("ADD")
      s:SetVertexColor(1, 0.82, 0.3)
      sparks[k] = s
    end
    s:Hide()
  end
  if not bonusLabel then
    bonusLabel = UI.Text(panel, "GameFontNormal")
    bonusLabel:SetJustifyH("CENTER")
    bonusLabel:SetText("New guildie bonus!")
  end
  bonusLabel:ClearAllPoints()
  bonusLabel:SetPoint("BOTTOM", h, "CENTER", 0, 18)
  bonusLabel:SetAlpha(0)
  bonusLabel:Show()
  if c.tail then c.tail:SetText("haunches") end
end

local function stepBonus(c, t)
  local h = c.bonusIcon
  -- pop: grows past its size and settles back
  local q = math.min(1, t / BONUS_POP)
  local size = ICON * UI.Smooth(math.min(1, q * 1.6)) * (1 + 0.4 * math.sin(math.pi * q))
  h:SetSize(math.max(1, size), math.max(1, size))
  placeTail(c, (ICON + 1) * UI.Smooth(math.min(1, t / 0.25)))
  -- a ring of sparks flying out and fading
  local b = math.min(1, t / BURST)
  for k = 1, SPARKS do
    local s = sparks[k]
    if b < 1 then
      local a = (k - 1) / SPARKS * 2 * math.pi + 0.3
      local r = 6 + 42 * UI.Smooth(b)
      s:ClearAllPoints()
      s:SetPoint("CENTER", h, "CENTER", math.cos(a) * r, math.sin(a) * r)
      local sz = 18 - 10 * b
      s:SetSize(sz, sz)
      s:SetAlpha(1 - b)
      s:Show()
    else
      s:Hide()
    end
  end
  -- the label fades in, stays and fades out
  local la = math.min(1, t / 0.2) * math.min(1, (LABEL_TIME - t) / 0.35)
  bonusLabel:SetAlpha(math.max(0, la))
  if t >= LABEL_TIME then bonusLabel:Hide() end
end

local function startCollapse(c)
  c.phase, c.t = "collapse", 0
  if c.row and c.row.SetClipsChildren then c.row:SetClipsChildren(true) end
  -- the drumsticks come loose: from here on they're on their own
  local scene = UI.Win.Scene()
  c.sleeping = not scene:IsAwake()
  c.flySize = scene:HaunchSize() * scene:Scale()
  c.flights, c.hops, c.ft = {}, {}, 0
  local count = total(c.entry)
  for i = 1, count do
    local h = icons[i] or icon(i)
    local x, y = c.ox + iconX(c, i), c.oy - REWARD_H / 2
    at(h, x, y)
    h:SetSize(ICON, ICON)
    h:SetAlpha(1)
    c.flights[i] = { h = h, x0 = x, y0 = y, t0 = (i - 1) * STAGGER, phase = "wait" }
  end
  c.waiting = count
  for _, s in ipairs(sparks) do s:Hide() end
  if bonusLabel then bonusLabel:Hide() end
end

local function stepHold(c)
  if (c.entry.bonus or 0) > 0 then
    if c.t >= BONUS_AT and not c.bonus then startBonus(c) end
    if c.bonus then stepBonus(c, c.t - BONUS_AT) end
  end
  if c.t >= c.hold then startCollapse(c) end
end

local function stepCollapse(c)
  local q = math.min(1, c.t / COLLAPSE)
  if c.row and c.phase == "collapse" then
    local e = UI.Smooth(q)
    UI.QuestList.SetRowHeight(c.row, REWARD_H * (1 - e))
    c.label:SetAlpha(1 - e)
    c.tail:SetAlpha(1 - e)
    if q >= 1 then c.row:Hide() end
  end
  if q >= 1 then c.phase = "fly" end
end

-- The flights ---------------------------------------------------------------------------------

local HAUNCH = ns.RenderMedia and ns.RenderMedia.Haunch
local function ease(q) return q < 0.5 and 4 * q * q * q or 1 - ((-2 * q + 2) ^ 3) / 2 end

-- Where a hopping drumstick lands: on top of the pile, after those hopping ahead of it. Worked
-- out again every frame, since Pinto may take a haunch off the pile meanwhile.
local function aim(c, f, k)
  local scene = UI.Win.Scene()
  local sx, sy, rot, width = scene:PileSpot(UI.Win.PileCount() + k)
  f.tx, f.ty = sceneToWindow(sx, sy)
  f.trot, f.tsize = rot, width * scene:Scale()
end

-- A drumstick that has lifted off: into Pinto's mouth if it's the first to find him free,
-- otherwise onto the pile, where he eats it later (or wakes up to it).
local function launch(c, f)
  local scene = UI.Win.Scene()
  f.x1, f.y1 = f.x0, f.y0 + 10
  if c.sleeping or c.fed or scene:IsBusy() then
    f.phase = "hop"
    c.hops[#c.hops + 1] = f
    aim(c, f, #c.hops)
  else
    c.fed = true
    -- the scene takes it from here, from the same spot and at the same size: what it's
    -- handed is the picture's anchor, a little off its middle
    local sx, sy = windowToScene(f.x1, f.y1)
    local cx = HAUNCH and (HAUNCH[2] + HAUNCH[4]) / 2 or 0
    local cy = HAUNCH and (HAUNCH[3] + HAUNCH[5]) / 2 or 0
    scene:Feed(sx - cx, sy - cy, function() c.waiting = c.waiting - 1 end)
    f.h:Hide()
    f.phase = "done"
  end
end

local function stepFlights(c)
  for _, f in ipairs(c.flights) do
    local ft = c.ft - f.t0
    if f.phase ~= "done" and ft >= 0 then
      if f.phase == "wait" then f.phase = "lift" end
      if f.phase == "lift" then
        local e = UI.Smooth(math.min(1, ft / LIFT))
        local size = ICON + (c.flySize - ICON) * e
        f.h:SetSize(size, size)
        at(f.h, f.x0, f.y0 + 10 * e)
        if ft >= LIFT then launch(c, f) end
      elseif f.phase == "hop" then
        for k, g in ipairs(c.hops) do
          if g == f then aim(c, f, k) end
        end
        local q = math.min(1, (ft - LIFT) / HOP)
        local e = ease(q)
        local v = 1 - e
        local cx, cy = (f.x1 + f.tx) / 2, math.max(f.y1, f.ty) + HOP_HEIGHT
        at(f.h, v * v * f.x1 + 2 * e * v * cx + e * e * f.tx, v * v * f.y1 + 2 * e * v * cy + e * e * f.ty)
        local size = c.flySize + (f.tsize - c.flySize) * e
        f.h:SetSize(size, size)
        -- one full turn, ending at the way the pile's haunch lies (the scene turns clockwise)
        f.h:SetRotation(-(f.trot + 2 * math.pi) * e)
        if q >= 1 then
          f.h:Hide()
          f.phase = "done"
          for k, g in ipairs(c.hops) do
            if g == f then table.remove(c.hops, k) break end
          end
          UI.Win.AddToPile(1)
          c.waiting = c.waiting - 1
        end
      end
    end
  end
end

-- Running the chain ---------------------------------------------------------------------------

local function finishEntry()
  if cur then ns.Quests.MarkEaten(cur.entry) end
  cur = nil
  clear()
  UI.QuestList.Refresh()
  Eat.Next()
end

local function step(_, elapsed)
  local c = cur
  if not c then
    frame:SetScript("OnUpdate", nil)
    return
  end
  c.t = c.t + elapsed
  if c.phase == "sweep" then
    stepSweep(c)
  elseif c.phase == "reveal" then
    stepReveal(c)
  elseif c.phase == "hold" then
    stepHold(c)
  else
    stepCollapse(c)
  end
  if c.flights then
    c.ft = c.ft + elapsed
    stepFlights(c)
    -- wait for the landings and chomps, but never get stuck
    if c.phase == "fly" and (c.waiting <= 0 or c.ft > 12 * #c.flights + 4) then finishEntry() end
  end
end

function Eat.Next()
  local entry = table.remove(queue, 1)
  if not entry then
    frame:SetScript("OnUpdate", nil)
    return
  end
  local row = UI.QuestList.RowFor(entry)
  if not row or not row:IsVisible() then
    cur = { entry = entry, t = 0 }
    startReveal(cur)
    frame:SetScript("OnUpdate", step)
    return
  end
  local layout = UI.QuestList.GlyphLayout(row)
  local glyphs = {}
  for i, gpos in ipairs(layout) do
    local fs = glyph(i, row)
    fs:SetFont(row.text:GetFont())
    fs:SetTextColor(row.text:GetTextColor())
    fs:SetText(gpos.ch)
    fs:ClearAllPoints()
    fs:SetPoint("TOPLEFT", row, "TOPLEFT", gpos.x, gpos.y)
    glyphs[i] = { fs = fs, x = gpos.x, y = gpos.y }
  end
  -- the row shows its glyphs from here on, never its own text
  row.eating = true
  row.text:SetAlpha(0)
  local n = math.max(1, #glyphs)
  cur = { entry = entry, row = row, glyphs = glyphs, t = 0, phase = "sweep",
    dur = math.max(SWEEP_MIN, math.min(SWEEP_MAX, 0.5 + 0.012 * n)) }
  if #motes == 0 then
    for k = 1, 4 do
      local m = UI.QuestList.Panel():CreateTexture(nil, "OVERLAY", nil, 7)
      m:SetTexture(UI.Media("Mote"))
      m:SetBlendMode("ADD")
      m:SetVertexColor(1, 0.85, 0.45)
      local s = k == 1 and 26 or (18 - k * 2)
      m:SetSize(s, s)
      motes[k] = m
    end
  end
  frame:SetScript("OnUpdate", step)
end

-- Starts eating whatever is waiting, if the full window shows Pinto ready for it. While a
-- test runs (test builds), only the test's previews: real quests wait for the guild's Pinto.
function Eat.Start()
  if cur then return end
  local win = UI.FullWindow()
  if not win or not win:IsShown() or UI.Active() ~= "full" then return end
  local testing = UI.Win.Testing()
  queue = {}
  for _, e in ipairs(ns.Quests.Uneaten()) do
    if (e.preview == true) == testing then queue[#queue + 1] = e end
  end
  if #queue == 0 then return end
  frame = frame or CreateFrame("Frame")
  if not flyer then
    flyer = CreateFrame("Frame", nil, win)
    flyer:SetAllPoints(win)
    flyer:SetFrameStrata("DIALOG")
  end
  UI.QuestList.Refresh()
  Eat.Next()
end

-- Stops the chain, as when the window closes. A quest whose drumsticks are already on their
-- way counts as eaten, and the ones not yet in his mouth or on the pile land on the pile at
-- once, so none is missed or counted twice; an earlier quest is eaten again next time.
function Eat.Stop()
  if not frame then return end
  frame:SetScript("OnUpdate", nil)
  local c = cur
  if c and c.flights then
    for _, f in ipairs(c.flights) do
      if f.phase ~= "done" then UI.Win.AddToPile(1) end
    end
    ns.Quests.MarkEaten(c.entry)
  end
  local r = c and c.row
  if r and r.full then
    r.eating = nil
    if r.SetClipsChildren then r:SetClipsChildren(false) end
    if r.rewardWords then
      for _, w in ipairs(r.rewardWords) do w:Hide() end
    end
    r:Show()
    UI.QuestList.SetRowHeight(r, r.full)
    for _, part in ipairs({ r.text, r.note, r.reward, r.bullet, r.check }) do part:SetAlpha(1) end
  end
  cur = nil
  queue = {}
  clear()
end

function Eat.Flyer() return flyer end
function Eat.Phase() return cur and cur.phase end
