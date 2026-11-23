-- The debug panel (/pinto debug), in builds with the test tools: sliders for weight and
-- gold, asleep/awake, a feed button and the colour presets, all driving the scene directly.
-- For trying Pinto out; the real state comes back when the panel closes. Those builds also
-- get the test controls in the full window (see below). Without the tools, /pinto debug
-- only switches the debug messages.
local ADDON, ns = ...

local UI = ns.UI
local Debug = {}
UI.Debug = Debug

local panel

local function slider(parent, label, y, onChange)
  local s = CreateFrame("Slider", nil, parent)
  s:SetOrientation("HORIZONTAL")
  s:SetSize(200, 16)
  s:SetPoint("TOPLEFT", 16, y)
  s:SetMinMaxValues(0, 100)
  s:SetValueStep(1)
  if s.SetObeyStepOnDrag then s:SetObeyStepOnDrag(true) end
  local bg = s:CreateTexture(nil, "BACKGROUND")
  bg:SetColorTexture(0.2, 0.2, 0.2, 1)
  bg:SetPoint("LEFT")
  bg:SetPoint("RIGHT")
  bg:SetHeight(4)
  s:SetThumbTexture("Interface\\Buttons\\UI-SliderBar-Button-Horizontal")
  local t = UI.Text(s, "GameFontHighlightSmall")
  t:SetPoint("BOTTOMLEFT", s, "TOPLEFT", 0, 2)
  t:SetText(label)
  s:SetScript("OnValueChanged", function(_, v) onChange(v / 100) end)
  return s
end

local function build()
  panel = UI.Window("PintoTGDDebug", 250, 250)
  panel:SetPoint("TOPLEFT", UIParent, "TOPLEFT", 40, -200)
  local title = UI.Text(panel, "GameFontNormal")
  title:SetPoint("TOPLEFT", 14, -14)
  title:SetText("Pinto debug")
  local function scene() return UI.Win.Scene() end
  panel.weight = slider(panel, "Weight", -52, function(v) if scene() then scene():SetWeight(v) end end)
  panel.gold = slider(panel, "Gold hoard", -92, function(v) if scene() then scene():SetWealth(v) end end)
  local asleep = UI.Button(panel, "Asleep", 70)
  asleep:SetPoint("TOPLEFT", 14, -116)
  asleep:SetScript("OnClick", function() if scene() then scene():SetAwake(false) end end)
  local awake = UI.Button(panel, "Awake", 70)
  awake:SetPoint("LEFT", asleep, "RIGHT", 4, 0)
  awake:SetScript("OnClick", function() if scene() then scene():SetAwake(true) end end)
  local feed = UI.Button(panel, "Feed", 70)
  feed:SetPoint("LEFT", awake, "RIGHT", 4, 0)
  feed:SetScript("OnClick", function()
    local s = scene()
    if s then
      s:SetAwake(true)
      s:Feed(660, 60)
    end
  end)
  for i, p in ipairs(ns.Render and ns.Render.PRESETS or {}) do
    local b = UI.Button(panel, p.name, 70, 20)
    b:SetPoint("TOPLEFT", 14 + ((i - 1) % 3) * 74, -146 - math.floor((i - 1) / 3) * 24)
    b:SetScript("OnClick", function()
      UI.Settings().palette = { p.body, p.belly, p.spikes }
      if scene() then scene():SetPalette(p.body, p.belly, p.spikes) end
    end)
  end
  panel:SetScript("OnHide", function() UI.Win.Refresh() end)
end

-- The test controls ---------------------------------------------------------------------------
-- Builds with the test tools only: two rows of small buttons at the bottom right of Pinto's
-- side in the full window, for trying every look and animation in any combination:
--   Weight - + (0.05 at a time, with its band; while he sleeps, the weight he wakes to),
--   Gold - + (the hoard's size, 0.1 at a time), and the day's feeding for the mood line (a
--   hungry, fed or feast day);
--   Feed (a haunch flies in and he eats it the way his weight band eats, or it lands on the
--   pile while he sleeps), Sleep or Wake (waking runs the end of the calibration: he eats the
--   pile in one stream, then eases into the weight set), Silhouette or Colors (the syncing
--   look), Pile + (awake, he eats it a haunch at a time) and Eat pile (in one stream), and
--   Reset.
-- Using one starts a test look (UI.Win.StartTest): nothing it does is saved or shared, and
-- Reset brings back the guild's state, the same as /pinto test reset.

local DAYS = { "Hungry day", "Fed day", "Feast day" }
local ROW = 24

local function smallButton(parent, text, width)
  local b = UI.Button(parent, text, width, 20)
  if b.SetNormalFontObject then
    b:SetNormalFontObject("GameFontNormalSmall")
    b:SetHighlightFontObject("GameFontHighlightSmall")
    b:SetDisabledFontObject("GameFontDisableSmall")
  end
  return b
end

-- Ends a test: the previews go and Pinto shows the guild's state again.
function UI.TestReset()
  local cleared = ns.Quests.TestClearPreviews()
  local testing = UI.Win.Testing()
  UI.Win.EndTest()
  return cleared or testing
end

function Debug.BuildTestBar(win, right, bottom)
  local Win = UI.Win
  local bar = CreateFrame("Frame", nil, win)
  bar:SetSize(420, ROW * 2)
  bar:SetPoint("BOTTOMRIGHT", win, "BOTTOMLEFT", right, bottom)
  bar:SetFrameLevel(win:GetFrameLevel() + 20)   -- over Pinto's scene
  bar.buttons = {}

  -- Lays a row out from the right: { widget, width } pairs, left to right.
  local function row(y, items)
    local x = 0
    for i = #items, 1, -1 do
      local w, width = items[i][1], items[i][2]
      w:ClearAllPoints()
      w:SetPoint("RIGHT", bar, "BOTTOMRIGHT", -x, y + 10)
      if w.SetWidth and w.GetObjectType and w:GetObjectType() == "FontString" then w:SetWidth(width) end
      x = x + width + (items[i][3] or 4)
    end
  end
  local function label(text, justify)
    local fs = UI.Text(bar, "GameFontHighlightSmall")
    fs:SetJustifyH(justify or "RIGHT")
    fs:SetText(text)
    return fs
  end
  local function button(key, text, width, onClick)
    local b = smallButton(bar, text, width)
    b:SetScript("OnClick", function()
      local t = Win.StartTest()
      if t then onClick(t, Win.Scene()) end
      Win.Refresh()
    end)
    bar.buttons[key] = b
    return b
  end
  -- the shape on screen: his weight while he's awake; asleep, the one he fell asleep in
  local function shape(t, s)
    t.waking = nil
    if s then s:AnimateTo(t.awake and t.weight or s:GetWeight(), t.wealth, 0.6) end
  end
  -- one step up or down, on a grid of `per` steps from 0 to 1
  local function step(v, dir, per)
    return math.max(0, math.min(per, math.floor(v * per + 0.5) + dir)) / per
  end

  local weightLabel, weightValue = label("Weight"), label("", "LEFT")
  local hoardLabel, hoardValue = label("Gold"), label("", "LEFT")
  bar.weightLabel, bar.weightValue, bar.hoardValue = weightLabel, weightValue, hoardValue
  local function setWeight(t, s, dir)
    t.weight = step(t.weight, dir, 20)
    if t.awake then shape(t, s) end
  end
  local wMinus = button("weightDown", "-", 20, function(t, s) setWeight(t, s, -1) end)
  local wPlus = button("weightUp", "+", 20, function(t, s) setWeight(t, s, 1) end)
  local hMinus = button("hoardDown", "-", 20, function(t, s) t.wealth = step(t.wealth, -1, 10); shape(t, s) end)
  local hPlus = button("hoardUp", "+", 20, function(t, s) t.wealth = step(t.wealth, 1, 10); shape(t, s) end)
  local day = button("day", DAYS[2], 76, function(t) t.day = t.day % 3 + 1 end)
  row(ROW, { { weightLabel, 50 }, { wMinus, 20, 2 }, { wPlus, 20 }, { weightValue, 84 }, { hoardLabel, 36 },
    { hMinus, 20, 2 }, { hPlus, 20 }, { hoardValue, 30 }, { day, 76, 0 } })

  local feed = button("feed", "Feed", 46, function(t, s)
    if not s then return end
    if t.awake then s:Feed(700, 120) else Win.AddToPile(1) end
  end)
  local sleep = button("sleep", "Sleep", 52, function(t, s)
    if t.awake then
      t.awake, t.waking = false, nil
      if s then
        t.shape = s:GetWeight()
        s:SetAwake(false)
      end
    elseif s then
      Win.TestWake()
    else
      t.awake = true
    end
  end)
  local sil = button("silhouette", "Silhouette", 72, function(t, s)
    t.sil = not t.sil
    if s then s:SetSilhouette(t.sil and 1 or 0, 0.6) end
  end)
  local pileUp = button("pile", "Pile +", 50, function() Win.AddToPile(1) end)
  local eatPile = button("eatPile", "Eat pile", 62, function(t, s)
    if not s or t.pile <= 0 then return end
    t.awake = true
    s:SetAwake(true)
    s:EatPile(function(remaining)
      t.pile = remaining
      Win.Refresh()
    end, function() t.pile = 0 end)
  end)
  local reset = smallButton(bar, "Reset", 52)
  reset:SetScript("OnClick", function() UI.TestReset() end)
  bar.buttons.reset = reset
  row(0, { { feed, 46 }, { sleep, 52 }, { sil, 72 }, { pileUp, 50 }, { eatPile, 62 }, { reset, 52, 0 } })

  function bar:Update()
    local t = Win.TestLook()
    local s = Win.Scene()
    local weight = t and t.weight or (s and s:GetWeight()) or 0.5
    local wealth = t and t.wealth or (s and s:GetWealth()) or 0
    local awake = t and t.awake
    if not t then awake = s and s:IsAwake() end
    local silhouette = t and t.sil
    if not t then silhouette = s and s:GetSilhouette() > 0.5 end
    weightLabel:SetText(awake and "Weight" or "Wakes to")
    weightValue:SetText(string.format("%.2f %s", weight, ns.Health.LABELS[ns.Health.Band(weight)]))
    hoardValue:SetText(string.format("%.1f", wealth))
    day:SetText(DAYS[t and t.day or 2])
    sleep:SetText(awake and "Sleep" or "Wake")
    sil:SetText(silhouette and "Colors" or "Silhouette")
    reset:SetEnabled(t ~= nil)
  end
  bar:Update()
  return bar
end

function UI.ToggleDebugPanel()
  if not ns.Build.testTools then return end
  if not panel then build() end
  if panel:IsShown() then
    panel:Hide()
  else
    if UI.Active() == nil then UI.Open("full") end
    local s = UI.Win.Scene()
    if s then
      panel.weight:SetValue(math.floor(s:GetWeight() * 100 + 0.5))
      panel.gold:SetValue(math.floor(s:GetWealth() * 100 + 0.5))
    end
    panel:Show()
  end
end
