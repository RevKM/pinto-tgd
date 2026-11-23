-- The small and full windows, Pinto's scene in them, and what they show.
--
-- One scene moves between the two windows. The windows remember their position, neither
-- opens by itself unless the player ticks "Open small on start", and Pinto changes shape
-- the first time the player opens a window after new data came in: from the shape they
-- last saw to the current one. Once the login sync is done, the start notice beside the
-- minimap button says how he is.
local ADDON, ns = ...

local UI = ns.UI
local Win = {}
UI.Win = Win

local Health, Time, Quests, Events = ns.Health, ns.Time, ns.Quests, ns.Events

local FULL_W, FULL_H = 1010, 560
-- Pinto sits this far below the title: 10% of the window lower than the top of his side
local SCENE_TOP = 40 + math.floor(FULL_H * 0.1)
-- the title, 5% of the window lower than just under the window's edge
local TITLE_Y = -22 - math.floor(FULL_H * 0.05)
-- the text: under the title while Pinto's awake; while he sleeps, a little larger and well
-- above the middle of his side (10% of the window higher than just above it)
local AWAKE_TEXT_Y = TITLE_Y - 26
local ASLEEP_TEXT_Y = -(FULL_H / 2 - 12) + math.floor(FULL_H * 0.1)
local ASLEEP_TEXT_GROW = 2   -- points larger
local SMALL_W, SMALL_H = 244, 198
local SCENE_W, SCENE_H = 680, 420

local full, small
local scene
local active = nil       -- "full", "small" or nil
local firstSyncDone = false
local busyReveal = false
local testLook = nil     -- test builds: the look the test controls set, while a test runs

-- The scene ---------------------------------------------------------------------------

-- A stand-in with the scene's API, used if the renderer couldn't start.
local function placeholderScene(parent)
  local f = CreateFrame("Frame", nil, parent)
  local t = f:CreateTexture(nil, "ARTWORK")
  t:SetSize(96, 96)
  t:SetPoint("CENTER")
  t:SetTexture(UI.Media("MinimapHead"))
  local s = { frame = f, w = 0.5, h = 0, awake = false, sil = 0, pile = 0 }
  function s:SetWeight(v) self.w = v end
  function s:SetWealth(v) self.h = v end
  function s:GetWeight() return self.w end
  function s:GetWealth() return self.h end
  function s:AnimateTo(w, h, _, done) self.w, self.h = w, h; if done then done() end end
  function s:SetAwake(a) self.awake = a end
  function s:IsAwake() return self.awake end
  function s:SetPalette() end
  function s:SetSilhouette(v)
    self.sil = v
    t:SetVertexColor(1 - v, 1 - v, 1 - v)
    if self.backdrop then self.backdrop:SetAlpha(v) end
  end
  function s:GetSilhouette() return self.sil end
  function s:SetBackdrop(tex)
    if self.backdrop and self.backdrop ~= tex then self.backdrop:SetAlpha(0) end
    self.backdrop = tex
    if tex then tex:SetAlpha(self.sil) end
  end
  function s:SetMeatPile(n) self.pile = n or 0 end
  function s:GetMeatPile() return self.pile end
  function s:EatPile(onEach, onDone) self.pile = 0; if onDone then onDone() end end
  function s:IsEatingPile() return false end
  function s:PileSpot() return 652, 380, 0, 34 end
  function s:HaunchSize() return 42 end
  function s:Scale() return 1 end
  function s:Feed(_, _, onChomp) if onChomp then onChomp() end end
  function s:IsBusy() return false end
  function s:StopFeeding() end
  function s:SetNibbling() end
  function s:GetMouth() return 400, 200 end
  function s:SceneToFrame(x, y) return x, -(y - 20) end
  function s:FrameToScene(dx, dy) return dx, 20 - dy end
  function s:SetFrameRate() end
  function s:SetPaused() end
  return s
end

local function makeScene(parent)
  if ns.Render and ns.Render.New then
    local ok, s = pcall(ns.Render.New, parent)
    if ok and s then return s end
    ns.report(s)
  end
  return placeholderScene(parent)
end

function Win.Scene() return scene end

local function attachScene(win, fps)
  local holder = win.holder
  if not scene then
    scene = makeScene(holder)
    -- colors picked in the debug panel; without the test tools he wears Ruby, as everyone sees him
    local pal = ns.Build.testTools and UI.Settings().palette
    if pal then scene:SetPalette(pal[1], pal[2], pal[3]) end
    local seen = UI.Settings().lastSeen
    if seen then
      scene:SetWeight(seen.weight)
      scene:SetWealth(seen.wealth)
    else
      scene:SetWeight(0.5)
      scene:SetWealth(0)
    end
    -- awake, he eats haunches set aside on his pile one at a time
    scene:SetNibbling(true, function(left) Win.PileLeft(left) end)
  end
  scene.frame:SetParent(holder)
  scene.frame:ClearAllPoints()
  scene.frame:SetAllPoints(holder)
  scene.frame:Show()
  scene:SetBackdrop(win.cover)
  scene:SetFrameRate(fps)
  scene:SetPaused(false)
end

-- What to show ------------------------------------------------------------------------
-- Returns the window state and the text under Pinto. The small window has room for about
-- two short lines, so it gets the short versions.

function Win.RealState(kind)
  local small = kind == "small"
  if ns.disabled == "trial" then return "off", small and Health.TEXT.trialShort or Health.TEXT.trial end
  if ns.disabled == "migration" then
    return "off", small and "Pinto couldn't update your saved data, so he's staying off."
      or "Pinto couldn't update your saved data, so he's keeping it safe and staying off. Please tell an officer so it can be reported."
  end
  if ns.disabled == "newer" then return "off", "Pinto needs an update to read your saved data." end
  if not Time.isLive() then return "before", Health.ArrivesText() end
  local sync = ns.Protocol.state
  if not firstSyncDone and (sync == "waiting" or sync == "syncing") then
    return "syncing", Health.TEXT.syncing
  end
  local weight, _, state = Health.Shape()
  if state == "calibration" then
    if small then return "calibration", Health.AwakesText() end
    return "calibration", Health.TEXT.calibration .. "\n" .. Health.AwakesText()
  end
  if state == "long" then return "calibration", small and Health.TEXT.longShort or Health.TEXT.long end
  if sync == "alone" then return "alone", Health.TEXT.alone end
  local line = Health.MoodLine(weight, Health.Feeding())
  if state == "missing" then return "missing", small and line or (line .. "\n" .. Health.TEXT.missing) end
  return "normal", line
end

-- The test look's state and text: what the windows would say for that look. The day is a
-- hungry, fed or feast day for the mood line.
local TEST_FEEDING = { 0.2, 1, 1.5 }
local function testState(kind)
  local t = testLook
  if t.sil then return "syncing", Health.TEXT.syncing end
  if not t.awake then
    if kind == "small" then return "calibration", Health.AwakesText() end
    return "calibration", Health.TEXT.calibration .. "\n" .. Health.AwakesText()
  end
  return "normal", Health.MoodLine(t.weight, TEST_FEEDING[t.day])
end

-- What the windows show: the guild's state, or the test look while a test runs.
function Win.State(kind)
  if testLook then return testState(kind) end
  return Win.RealState(kind)
end

function UI.StatusLine()
  if ns.disabled == "guild" then return nil end
  local _, text = Win.State()
  return text
end

-- The meat pile: haunches finished during the calibration, kept here until the first
-- window opens after the calibration ends. Each data slot has its own, so a test build's
-- pile never reaches the release.
function Win.Pile()
  local ui = UI.Settings()
  ui.piles = ui.piles or {}
  local key = ns.Store.slotKey()
  if ui.pile then
    -- kept for every slot at once before: only test builds ran then
    if ns.Build.test and not ui.piles[key] then ui.piles[key] = ui.pile end
    ui.pile = nil
  end
  ui.piles[key] = ui.piles[key] or { count = 0 }
  return ui.piles[key]
end

-- The haunches on the pile Pinto shows: the player's own, or the test look's.
function Win.PileCount()
  if testLook then return testLook.pile end
  return Win.Pile().count
end

-- Haunches that land on the pile: while Pinto sleeps, or set aside while he's busy eating.
-- A pile from his sleep is eaten in one stream when he wakes; one set aside while he was
-- awake (pile.awake) a haunch at a time.
function Win.AddToPile(n)
  if testLook then
    testLook.pile = testLook.pile + n
  else
    local pile = Win.Pile()
    pile.count = pile.count + n
    if scene and scene:IsAwake() then pile.awake = true end
  end
  if scene then scene:SetMeatPile(Win.PileCount()) end
end

-- The haunches left on the pile, as Pinto eats it.
function Win.PileLeft(left)
  if testLook then
    testLook.pile = left
  else
    local pile = Win.Pile()
    pile.count = left
    if left <= 0 then pile.awake = nil end
  end
end

-- "Your contribution so far", above the meat pile while he sleeps beside one.
local function updatePileLabel(win)
  if not win.pileLabel then
    win.pileLabel = UI.Text(win, win == small and "GameFontHighlightSmall" or "GameFontNormalSmall")
    win.pileLabel:SetJustifyH("CENTER")
    win.pileLabel:SetText("Your contribution so far")
  end
  local count = Win.PileCount()
  if not scene or count <= 0 or not scene.frame:IsShown() or scene:IsAwake() then
    win.pileLabel:Hide()
    return
  end
  local x, y = scene:SceneToFrame(652, 352 - math.min(count, 15) * 1.5)
  win.pileLabel:ClearAllPoints()
  win.pileLabel:SetPoint("BOTTOM", win.holder, "TOPLEFT", math.min(x, win.holder:GetWidth() - 50), y)
  win.pileLabel:Show()
end

-- A font string's size: its template's, or a few points larger.
local function setTextSize(fs, grow)
  if fs.baseFont == nil then
    local font, size, flags = fs:GetFont()
    fs.baseFont = font and { font, size, flags } or false
  end
  local b = fs.baseFont
  if b then fs:SetFont(b[1], b[2] + grow, b[3]) end
end

-- Where the full window's text goes: centred on Pinto's side, well above its middle and a
-- little larger while he sleeps (he only fills the lower part of his scene then), and under
-- the title while he's awake, since a well-fed Pinto reaches much higher.
local function placeStatus(win, state)
  if win ~= full then return end
  local awake = state == "normal" or state == "missing" or state == "alone" or state == "syncing"
  if win.statusAwake == awake then return end
  win.statusAwake = awake
  win.status:ClearAllPoints()
  if awake then
    win.status:SetPoint("TOP", win, "TOPLEFT", 16 + SCENE_W / 2, AWAKE_TEXT_Y)
    setTextSize(win.status, 0)
  else
    win.status:SetPoint("BOTTOM", win, "TOPLEFT", 16 + SCENE_W / 2, ASLEEP_TEXT_Y)
    setTextSize(win.status, ASLEEP_TEXT_GROW)
  end
end

local function updateText(win)
  if not win then return end
  local state, text = Win.State(win == small and "small" or "full")
  win.status:SetText(text or "")
  placeStatus(win, state)
  updatePileLabel(win)
  if win == full then
    UI.QuestList.UpdateHoard()
    if win.testBar then win.testBar:Update() end
  end
end

local function remember()
  UI.Settings().lastSeen = { weight = scene:GetWeight(), wealth = scene:GetWealth() }
end

-- Puts the test look on the scene at once.
local function applyTest()
  local t = testLook
  t.applied = true
  scene:SetWeight(t.awake and t.weight or t.shape)
  scene:SetWealth(t.wealth)
  scene:SetAwake(t.awake, true)
  scene:SetSilhouette(t.sil and 1 or 0)
  scene:SetMeatPile(t.pile)
end

-- Brings the scene to the current state; eats waiting food in the full window.
function Win.Refresh()
  local win = active == "full" and full or active == "small" and small or nil
  if not win then return end
  updateText(win)
  if win.badge then win.badge:SetShown(#Quests.Uneaten() > 0) end
  if not scene then return end
  if testLook then
    -- the test controls drive the scene; only the test's finished quests get eaten
    scene.frame:Show()
    if not testLook.applied then applyTest() end
    if active == "full" and not testLook.waking then UI.Eat.Start() end
    return
  end
  if busyReveal then return end
  local state = Win.State()
  local weight, wealth = Health.Shape()
  if state == "off" or state == "before" then
    scene.frame:Hide()
    return
  end
  scene.frame:Show()
  if state == "syncing" then
    scene:SetSilhouette(1)
    return
  end
  if state == "calibration" then
    scene:SetSilhouette(0, 0.6)
    scene:SetAwake(false)
    scene:SetMeatPile(Win.Pile().count)
    if math.abs(scene:GetWeight() - 0.5) > 0.001 or math.abs(scene:GetWealth() - wealth) > 0.001 then
      busyReveal = true
      scene:AnimateTo(0.5, wealth, 1.2, function()
        busyReveal = false
        remember()
        if active == "full" then UI.Eat.Start() end
      end)
    elseif active == "full" then
      UI.Eat.Start()
    end
    return
  end
  -- awake: the colors fade in first, then he wakes. A meat pile from the calibration comes
  -- next: he eats it all in one go, at the shape he slept in. Then he eases into his real
  -- shape, and then he eats the quests waiting for him.
  scene:SetSilhouette(0, 0.6)
  local pile = Win.Pile()
  local wasAsleep = not scene:IsAwake()
  scene:SetAwake(true)
  local function reshape()
    local w, h = Health.Shape()
    local function eatQuests()
      remember()
      if active == "full" then UI.Eat.Start() end
    end
    if math.abs(scene:GetWeight() - w) > 0.001 or math.abs(scene:GetWealth() - h) > 0.001 then
      busyReveal = true
      scene:AnimateTo(w, h, wasAsleep and 2.0 or 1.5, function()
        busyReveal = false
        eatQuests()
      end)
    else
      eatQuests()
    end
  end
  scene:SetMeatPile(pile.count)
  if pile.count > 0 and not pile.awake then
    busyReveal = true
    scene:EatPile(function(left) pile.count = left end, function()
      pile.count = 0
      busyReveal = false
      reshape()
    end)
  else
    -- haunches set aside while he was awake: he eats them one at a time as he goes
    reshape()
  end
end

-- The test look ------------------------------------------------------------------------
-- Builds with the test tools only. While a test runs, the test controls (UI/Debug.lua) and
-- the /pinto test commands drive Pinto instead of the guild's state, and nothing they do is
-- saved or shared: his weight, his hoard, asleep or awake, the syncing silhouette, the meat
-- pile and the day's feeding for the mood line. It starts from what the windows show and
-- lasts, across closing and opening the windows, until Win.EndTest.

function Win.StartTest()
  if not ns.Build.testTools then return nil end
  if testLook then return testLook end
  busyReveal = false
  -- a real quest Pinto is eating waits for the test to end, so its haunches can't land on
  -- the test's pile
  if UI.Eat.Running() then
    UI.Eat.Stop()
    UI.QuestList.Refresh()
  end
  local t = { day = 2 }
  if scene then
    t.weight, t.wealth = scene:GetWeight(), scene:GetWealth()
    t.shape = t.weight
    t.awake = scene:IsAwake()
    t.sil = scene:GetSilhouette() > 0.5
    t.pile = scene:GetMeatPile()
    t.applied = true
  else
    local state = Win.RealState()
    local weight, wealth = Health.Shape()
    t.weight = state == "calibration" and 0.5 or weight
    t.shape = t.weight
    t.wealth = wealth
    t.awake = state == "normal" or state == "missing" or state == "alone"
    t.sil = state == "syncing"
    t.pile = Win.Pile().count
  end
  testLook = t
  Win.Refresh()
  return t
end

-- Ends the test: Pinto goes back to the guild's state. The test's haunches still on their
-- way are dropped, and the quest list's eating stops for the real quests to take over.
function Win.EndTest()
  if not testLook then return end
  testLook = nil
  busyReveal = false
  UI.Eat.Stop()
  if scene then
    scene:StopFeeding()
    scene:SetMeatPile(Win.Pile().count)
  end
  UI.QuestList.Refresh()
  Win.Refresh()
end

-- Waking the test look up runs the end of the calibration: a pile beside him is eaten first,
-- in one stream, at the shape he slept in; then he eases into the weight the test controls
-- set while he slept, then he eats the test's finished quests.
function Win.TestWake()
  local t = testLook
  if not t or not scene then return end
  t.awake, t.waking = true, true
  scene:SetAwake(true)
  local function reshape()
    scene:AnimateTo(t.weight, t.wealth, 2.0, function()
      if testLook ~= t or not t.waking then return end
      t.waking = nil
      Win.Refresh()
    end)
  end
  if t.pile > 0 then
    scene:SetMeatPile(t.pile)
    scene:EatPile(function(left)
      t.pile = left
      Win.Refresh()
    end, function()
      t.pile = 0
      if testLook == t and t.waking then reshape() end
    end)
  else
    reshape()
  end
end

function Win.Testing() return testLook ~= nil end
function Win.TestLook() return testLook end

-- The start notice ---------------------------------------------------------------------
-- A few words once the login sync is done: new quests on the day they come out, and the
-- first time a character logs in that week; otherwise a change of shape since the player
-- last saw Pinto, or his mood. Always the guild's state, never a test look.

local GIRTH = 0.02   -- the change in weight that counts as gaining or losing girth

function Win.NoticeText()
  if ns.disabled then return nil end
  if not Time.isLive() then return Health.ArrivesText() end
  local state = Win.RealState()
  if state == "off" or state == "syncing" then return nil end
  local me = ns.me
  local week = Quests.Week()
  local ui = UI.Settings()
  ui.questNotice = ui.questNotice or {}
  local mark = string.format("%s:%d", ns.Store.slotKey(), week)
  if me and #Quests.Mine() > 0 and (Time.day() == Time.weekStartDay(week) or ui.questNotice[me] ~= mark) then
    ui.questNotice[me] = mark
    return Health.NOTICE.quests
  end
  if state == "calibration" then return Health.NOTICE.asleep end
  local weight = Health.Shape()
  local seen = Win.startSeen
  if seen and seen.weight then
    if weight > seen.weight + GIRTH then return Health.NOTICE.gaining end
    if weight < seen.weight - GIRTH then return Health.NOTICE.losing end
  end
  return Health.ShortMood(weight, Health.Feeding())
end

function Win.ShowNotice()
  local text = Win.NoticeText()
  if text then UI.MiniButton.ShowNotice(text) end
  return text
end

-- Windows ------------------------------------------------------------------------------

local function buildFull()
  local f = UI.Window("PintoTGDFullWindow", FULL_W, FULL_H)
  -- the cave behind Pinto's side only, fading out where the quests begin, and the dark
  -- cover over it while he's a silhouette
  f.cave = UI.Cave(f, 6, 16 + SCENE_W + 7)
  f.cover = UI.CaveCover(f, f.cave)
  local holder = CreateFrame("Frame", nil, f)
  holder:SetSize(SCENE_W, SCENE_H)
  holder:SetPoint("TOPLEFT", 16, -SCENE_TOP)
  f.holder = holder
  -- the title, centred over Pinto
  local title = UI.Text(f, "GameFontNormalLarge")
  title:SetPoint("TOP", f, "TOPLEFT", 16 + SCENE_W / 2, TITLE_Y)
  title:SetJustifyH("CENTER")
  title:SetText("Pinto, the Girthy Dragon")
  f.title = title

  local status = UI.Text(f, "GameFontHighlight")
  status:SetPoint("BOTTOM", f, "TOPLEFT", 16 + SCENE_W / 2, ASLEEP_TEXT_Y)
  status:SetWidth(SCENE_W - 60)
  status:SetJustifyH("CENTER")
  f.status = status

  -- bottom left: the small window, and whether it opens by itself
  local toSmall = UI.Button(f, "Small", 70)
  toSmall:SetPoint("BOTTOMLEFT", 16, 14)
  toSmall:SetScript("OnClick", function() UI.Open("small") end)
  f.toSmall = toSmall
  local onStart = CreateFrame("CheckButton", nil, f, "UICheckButtonTemplate")
  onStart:SetSize(22, 22)
  onStart:SetPoint("LEFT", toSmall, "RIGHT", 8, 0)
  onStart.label = UI.Text(onStart, "GameFontHighlightSmall")
  onStart.label:SetPoint("LEFT", onStart, "RIGHT", 1, 0)
  onStart.label:SetText("Open small on start")
  onStart:SetHitRectInsets(0, -110, 0, 0)
  onStart:SetChecked(UI.Settings().openSmall and true or false)
  onStart:SetScript("OnClick", function(self) UI.Settings().openSmall = self:GetChecked() and true or nil end)
  f:HookScript("OnShow", function() onStart:SetChecked(UI.Settings().openSmall and true or false) end)
  f.onStart = onStart

  local panel = CreateFrame("Frame", nil, f)
  panel:SetPoint("TOPLEFT", f, "TOPLEFT", 16 + SCENE_W + 14, -40)
  panel:SetPoint("BOTTOMRIGHT", -16, 44)
  f.panel = panel
  UI.QuestList.Build(panel)
  if UI.OfficerTab then UI.OfficerTab.Build(f, panel) end
  -- builds with the test tools: the test controls, at the bottom right of Pinto's side
  if ns.Build.testTools and UI.Debug and UI.Debug.BuildTestBar then
    f.testBar = UI.Debug.BuildTestBar(f, 16 + SCENE_W - 4, 14)
  end

  f:SetScript("OnHide", function()
    if active == "full" then active = nil end
    if scene and not active then scene:SetPaused(true) end
    UI.Eat.Stop()
  end)
  UI.RestorePosition(f, 0, 40)
  return f
end

local function buildSmall()
  local f = UI.Window("PintoTGDSmallWindow", SMALL_W, SMALL_H)
  f.cave = UI.Cave(f, 6)
  f.cover = UI.CaveCover(f, f.cave)
  local t = UI.Text(f, "GameFontNormalSmall")
  t:SetPoint("TOPLEFT", 12, -11)
  t:SetText("Pinto")
  local holder = CreateFrame("Frame", nil, f)
  holder:SetSize(SMALL_W - 20, (SMALL_W - 20) * SCENE_H / SCENE_W)
  holder:SetPoint("TOPLEFT", 10, -28)
  f.holder = holder
  local status = UI.Text(f, "GameFontHighlightSmall")
  status:SetPoint("TOPLEFT", holder, "BOTTOMLEFT", 0, -3)
  status:SetWidth(SMALL_W - 20)
  status:SetJustifyH("CENTER")
  status:SetHeight(30)
  f.status = status
  f.close:SetScale(0.8)

  local toFull = UI.IconButton(f, "Interface\\Buttons\\UI-Panel-BiggerButton-Up", 20, "Full window")
  toFull:SetPoint("RIGHT", f.close, "LEFT", 2, 0)
  toFull:SetScript("OnClick", function() UI.Open("full") end)

  local badge = UI.Haunch(f, 16, "OVERLAY")
  badge:SetPoint("BOTTOMRIGHT", -8, 8)
  badge:Hide()
  f.badge = badge

  f:SetScript("OnHide", function()
    if active == "small" then active = nil end
    if scene and not active then scene:SetPaused(true) end
  end)
  UI.RestorePosition(f, -300, 120)
  return f
end

function UI.Open(kind)
  if ns.disabled == "guild" then return end
  kind = kind == "small" and "small" or "full"
  if kind == "full" then
    full = full or buildFull()
    if small then small:Hide() end
    active = "full"
    attachScene(full, 40)
    full:Show()
    UI.QuestList.Refresh()
  else
    small = small or buildSmall()
    if full then full:Hide() end
    active = "small"
    attachScene(small, 24)
    small:Show()
  end
  UI.Settings().last = kind
  Win.Refresh()
end

function UI.Close()
  if full then full:Hide() end
  if small then small:Hide() end
  active = nil
end

function UI.Toggle(kind)
  kind = kind == "small" and "small" or "full"
  if active == kind then UI.Close() else UI.Open(kind) end
end

function UI.ToggleLast()
  if active then UI.Close() else UI.Open(UI.Settings().last or "full") end
end

function UI.Active() return active end
function UI.FullWindow() return full end
function UI.SmallWindow() return small end

-- Where, from the full window's top-left corner, the quest list and Pinto's scene start.
function Win.PanelOffset() return 16 + SCENE_W + 14, -40 end
function Win.HolderOffset() return 16, -SCENE_TOP end

function Win.Init()
  local function refresh() Win.Refresh() end
  -- the shape the player saw before this login, for the start notice
  Win.startSeen = UI.Settings().lastSeen
  -- the start notice: once the first sync is done, or nobody's online to sync with, as
  -- soon as nothing has been syncing or recalculating Pinto's numbers for 4 seconds (the
  -- quests are rolled 3 seconds after the sync), or after a minute at most
  local noticeQueued = false
  local function notice(calm, waited)
    if ns.Protocol.IsSyncing() or Health.Busy() or Win.RealState() == "syncing" then calm = 0 end
    if calm < 4 and waited < 60 then
      ns.After(1, function() notice(calm + 1, waited + 1) end)
      return
    end
    Win.ShowNotice()
  end
  local function syncDone()
    if noticeQueued or ns.disabled then return end
    noticeQueued = true
    notice(0, 0)
  end
  Events.On("PINTO_SYNC_STATE", function(state)
    if state == "synced" then firstSyncDone = true end
    if state == "synced" or state == "alone" then syncDone() end
    refresh()
  end)
  Events.On("PINTO_HEALTH", refresh)
  Events.On("PINTO_QUEST_DONE", function()
    UI.MiniButton.Notify()
    refresh()
  end)
  Events.On("PINTO_EATEN", function() UI.MiniButton.Refresh() end)
  Events.On("PINTO_STATE", refresh)
  -- countdowns and the day boundary
  ns.Every(30, function()
    if active then updateText(active == "full" and full or small) end
  end)
  -- alone for a while: show what this addon has
  ns.After(25, function()
    if ns.Protocol.state == "alone" then
      firstSyncDone = true
      refresh()
    end
  end)
  -- the windows only open by themselves when the player asked for the small one
  UI.Settings().open = nil
  if UI.Settings().openSmall and ns.disabled ~= "guild" then UI.Open("small") end
end
