-- The Pinto quests in the full window, where the Map & Quest Log window has its quest log:
-- each quest with its progress and its reward in haunches, a reroll icon for the one
-- weekly reroll, finished quests waiting to be eaten (also an alt's), invitations from pair
-- quests and the time left until Monday's reset. Above that countdown: the whole guild's
-- pile of haunches while Pinto sleeps, and the guild's hoard once he's awake.
local ADDON, ns = ...

local UI = ns.UI
local QuestList = {}
UI.QuestList = QuestList

local Quests, Time, Compat, Health = ns.Quests, ns.Time, ns.Compat, ns.Health

local WIDTH = 270
local TEXT_X = 26           -- where a quest's text starts, right of its marker
local TEXT_W = 226
local GAP = 14              -- between quests
local LINE_SPACING = 3      -- extra space between a quest's lines
local HOARD_H = 92

local panel, header, footer, invites, hoard
local rows = {}       -- shown rows, top to bottom
local pool = {}

-- "Rewards [haunch][haunch] haunches", with the haunch icon inline.
function QuestList.RewardText(worth)
  worth = math.max(1, worth or 1)
  local icon = "|T" .. UI.Media("Haunch") .. ":15:15:0:-2|t"
  return "Rewards " .. string.rep(icon, worth) .. " " .. (worth == 1 and "haunch" or "haunches")
end

-- Rows -------------------------------------------------------------------------------------

local function newRow()
  local r = CreateFrame("Frame", nil, panel)
  r:SetWidth(WIDTH)
  r.text = UI.Text(r, "GameFontHighlight")
  r.text:SetPoint("TOPLEFT", TEXT_X, 0)
  r.text:SetWidth(TEXT_W)
  r.text:SetWordWrap(true)
  r.text:SetSpacing(LINE_SPACING)
  r.note = UI.Text(r, "GameFontNormalSmall")
  r.note:SetPoint("TOPLEFT", r.text, "BOTTOMLEFT", 0, -3)
  r.note:SetWidth(TEXT_W)
  r.reward = UI.Text(r, "GameFontNormalSmall")
  r.reward:SetWidth(TEXT_W)
  r.check = r:CreateTexture(nil, "ARTWORK")
  r.check:SetSize(18, 18)
  r.check:SetPoint("CENTER", r, "TOPLEFT", 12, -7)
  r.check:SetTexture("Interface\\RaidFrame\\ReadyCheck-Ready")
  -- the quest marker: a glowing yellow disc with an exclamation mark
  r.bullet = r:CreateTexture(nil, "ARTWORK")
  r.bullet:SetSize(30, 30)
  r.bullet:SetPoint("CENTER", r, "TOPLEFT", 12, -7)
  r.bullet:SetTexture(UI.Media("QuestMark"), "CLAMP", "CLAMP", "TRILINEAR")
  r.reroll = UI.IconButton(r, "Interface\\Buttons\\UI-RefreshButton", 14,
    "Reroll this quest for another one. You get one reroll a week.")
  r.reroll:SetPoint("TOPRIGHT", -2, 0)
  r.reroll:SetScript("OnClick", function(self) QuestList.AnimateReroll(self:GetParent()) end)
  return r
end

local function getRow(i)
  local r = pool[i]
  if not r then
    r = newRow()
    pool[i] = r
  end
  r:Show()
  r.text:Show()
  return r
end

local function fill(r, item)
  r.dx = 0
  r:SetAlpha(1)
  -- whatever the eating animation left on the row
  r.eating = nil
  if r.SetClipsChildren then r:SetClipsChildren(false) end
  if r.rewardWords then
    for _, w in ipairs(r.rewardWords) do w:Hide() end
  end
  r.check:SetAlpha(1)
  r.item = item
  r.slot = item.slot
  r.key = item.key
  r.text:SetText(item.text)
  r.text:SetTextColor(unpack(item.done and UI.colors.muted or UI.colors.body))
  r.text:SetAlpha(1)
  local hasNote = item.note and item.note ~= ""
  r.note:SetText(item.note or "")
  r.note:SetAlpha(1)
  r.reward:ClearAllPoints()
  r.reward:SetPoint("TOPLEFT", hasNote and r.note or r.text, "BOTTOMLEFT", 0, -3)
  r.reward:SetText(QuestList.RewardText(item.worth))
  r.reward:SetAlpha(item.done and 0.6 or 1)
  r.check:SetShown(item.done)
  r.bullet:SetShown(not item.done)
  r.bullet:SetAlpha(1)
  r.reroll:SetShown(item.canReroll and true or false)
  r.reroll:SetAlpha(1)
  r.reroll.icon:SetRotation(0)
  local h = r.text:GetStringHeight() + (hasNote and (r.note:GetStringHeight() + 3) or 0)
    + 3 + r.reward:GetStringHeight()
  r.full = math.max(20, h) + GAP
  r.height = r.full
  r:SetHeight(r.full)
end

-- Lays the rows out from the top, each at its current height. The guild's pile or hoard
-- shows above the countdown when the quests leave room for it.
function QuestList.Layout()
  if not panel then return end
  local y = -28
  for _, r in ipairs(rows) do
    r.y = y
    r:ClearAllPoints()
    r:SetPoint("TOPLEFT", panel, "TOPLEFT", r.dx or 0, y)
    y = y - (r.height or r.full or 30)
    -- a row closed to nothing hides its text; a row being eaten shows its own
    if not r.eating then
      local visible = (r.height or 0) > 2
      r.text:SetAlpha(visible and 1 or 0)
    end
  end
  invites:ClearAllPoints()
  invites:SetPoint("TOPLEFT", panel, "TOPLEFT", 0, y - 6)
  local used = -y + 6 + ((invites:GetText() or "") ~= "" and invites:GetStringHeight() or 0)
  local height = panel:GetHeight() or 0
  local free = height - used - footer:GetStringHeight() - 16
  if hoard then hoard.room = height <= 0 or free >= HOARD_H end
  QuestList.UpdateHoard()
end

function QuestList.SetRowHeight(r, h)
  r.height = math.max(0, h)
  r:SetHeight(math.max(0.01, r.height))
  QuestList.Layout()
end

local function progressNote(p)
  if not p then return nil end
  local parts = {}
  for _, b in ipairs(p) do
    if b.need > 1 then parts[#parts + 1] = string.format("%d/%d", b.have, b.need) end
  end
  if #parts == 0 then return nil end
  return "Progress: " .. table.concat(parts, " · ")
end

-- The quests to show: this character's, then finished quests of other characters that
-- Pinto hasn't eaten yet. A test build's previews show as finished, then as eaten.
local function items()
  local list = {}
  local eaten = PintoTGD_DB.eaten or {}
  local uneaten = Quests.Uneaten()
  local waiting = {}
  for _, e in ipairs(uneaten) do waiting[e.key] = e end
  local canReroll = Quests.CanReroll()
  local week = Quests.Week()
  local myId = ns.me and ns.Util.nameId(ns.me)
  local eatenCount = 0
  for _, q in ipairs(Quests.Mine()) do
    local key = string.format("%d:%.0f:%d", week, myId, q.slot)
    local done, isEaten = q.done, q.done and eaten[key]
    local preview = not q.done and Quests.PreviewOf(q.slot)
    if preview then key, done, isEaten = preview.entry.key, true, preview.eaten end
    if isEaten then
      eatenCount = eatenCount + 1
    else
      list[#list + 1] = { key = key, slot = q.slot, text = q.text, worth = q.q.worth, done = done,
        note = done and "Finished! Pinto's dinner is waiting." or progressNote(q.progress),
        canReroll = canReroll and not done, entry = waiting[key] }
    end
  end
  for _, e in ipairs(uneaten) do
    if not e.mine then
      local name = "An alt"
      for n in pairs(PintoTGD_DB.chars or {}) do
        if ns.Util.nameId(n) == e.char then name = Compat.ShortName(n) end
      end
      list[#list + 1] = { key = e.key, text = name .. ": " .. e.text, worth = e.worth, done = true,
        note = "Finished! Pinto's dinner is waiting.", entry = e }
    end
  end
  return list, eatenCount
end

local rerolling   -- the reroll animation, while it plays

function QuestList.Refresh(force)
  if not panel or not panel:IsVisible() then return end
  if rerolling and not force then
    rerolling.stale = true   -- refreshed once the animation ends
    return
  end
  if UI.Eat.Running() then return end
  local list, eatenCount = items()
  for _, r in ipairs(pool) do r:Hide() end
  rows = {}
  for i, item in ipairs(list) do
    local r = getRow(i)
    fill(r, item)
    rows[#rows + 1] = r
  end
  -- invitations from pair quests
  local asks = {}
  for _, name in pairs(Quests.PairAsks(Quests.Week())) do
    if type(name) == "string" then
      asks[#asks + 1] = Compat.ShortName(name) .. " has a quest to run a dungeon with you."
    end
  end
  invites:SetText(#asks > 0 and ("|cffffd100Invitations|r\n" .. table.concat(asks, "\n")) or "")
  QuestList.UpdateFooter(eatenCount)
  QuestList.Layout()
end

function QuestList.UpdateFooter(eatenCount)
  if not footer then return end
  local left = Time.countdown(Time.secondsToWeekReset())
  local text = "New quests in " .. (left or "less than an hour")
  if eatenCount and eatenCount > 0 then
    text = text .. "\n" .. ns.Util.plural(eatenCount, "quest") .. " eaten this week"
  end
  footer:SetText(text)
end

-- The guild's pile and hoard ---------------------------------------------------------------
-- While Pinto sleeps: every haunch the guild's finished quests have earned since go-live,
-- as a pile of drumsticks and a number. Once he's awake: how the guild is doing for gear
-- and for gold, as a word and five coins each, never as numbers.

local PILE_ROWS = { 7, 6, 5, 4, 3, 2, 1 }   -- up to 28 drumsticks, bottom row first
local PILE_MAX = 28

local function pip(i)
  local p = hoard.pips[i]
  if not p then
    p = hoard:CreateTexture(nil, "ARTWORK")
    p:SetTexture(UI.Media("CoinLoose"), "CLAMP", "CLAMP", "TRILINEAR")
    p:SetSize(16, 8)
    hoard.pips[i] = p
  end
  p:Show()
  return p
end

local function buildHoard()
  hoard = CreateFrame("Frame", nil, panel)
  hoard:SetSize(WIDTH, HOARD_H)
  hoard:SetPoint("BOTTOMLEFT", footer, "TOPLEFT", 0, 12)
  hoard.title = UI.Text(hoard, "GameFontNormal")
  hoard.title:SetPoint("TOPLEFT", 0, 0)
  hoard.icons, hoard.pips, hoard.lines = {}, {}, {}
  hoard.count = UI.Text(hoard, "GameFontHighlightLarge")
  hoard.count:SetPoint("LEFT", hoard, "BOTTOMLEFT", 104, 42)
  hoard.note = UI.Text(hoard, "GameFontDisableSmall")
  hoard.note:SetPoint("TOPLEFT", hoard.count, "BOTTOMLEFT", 0, -3)
  hoard.note:SetWidth(WIDTH - 104)
  for i = 1, 2 do
    local label = UI.Text(hoard, "GameFontHighlight")
    label:SetPoint("TOPLEFT", 0, -10 - i * 24)
    local word = UI.Text(hoard, "GameFontNormal")
    word:SetPoint("TOPLEFT", 48, -10 - i * 24)
    hoard.lines[i] = { label = label, word = word }
  end
  hoard.room = true
end

local function hideAll(list)
  for _, x in ipairs(list) do x:Hide() end
end

-- The guild's pile while Pinto sleeps.
local function showPile(total)
  hoard.title:SetText("The guild's pile so far")
  for _, l in ipairs(hoard.lines) do
    l.label:Hide()
    l.word:Hide()
  end
  hideAll(hoard.pips)
  local n = math.min(total, PILE_MAX)
  local i = 0
  for row, cap in ipairs(PILE_ROWS) do
    local inRow = math.min(cap, n - i)
    if inRow <= 0 then break end
    for k = 1, inRow do
      i = i + 1
      local icon = hoard.icons[i]
      if not icon then
        icon = UI.Haunch(hoard, 18)
        hoard.icons[i] = icon
      end
      icon:ClearAllPoints()
      icon:SetPoint("CENTER", hoard, "BOTTOMLEFT", 12 + (7 - cap) * 6 + (k - 1) * 12 + (cap - inRow) * 6,
        11 + (row - 1) * 8)
      icon:Show()
    end
  end
  for j = i + 1, #hoard.icons do hoard.icons[j]:Hide() end
  hoard.count:SetText(total == 1 and "1 haunch" or string.format("%d haunches", total))
  hoard.count:Show()
  hoard.note:SetText(total == 0 and "Finish a Pinto quest to start the pile."
    or "Pinto eats them when he wakes up.")
  hoard.note:Show()
end

-- The guild's hoard once Pinto is awake.
local function showWealth()
  hoard.title:SetText("The guild's hoard")
  hideAll(hoard.icons)
  hoard.count:Hide()
  hoard.note:Hide()
  local gear, gold = Health.WealthParts()
  local parts = { { "Gear", gear, Health.GEAR_WORDS }, { "Gold", gold, Health.GOLD_WORDS } }
  local p = 0
  for i, part in ipairs(parts) do
    local l = hoard.lines[i]
    l.label:SetText(part[1])
    l.label:Show()
    l.word:SetText(Health.WealthWord(part[2], part[3]))
    l.word:Show()
    local filled = Health.WealthLevel(part[2])
    for k = 1, 5 do
      p = p + 1
      local c = pip(p)
      c:ClearAllPoints()
      c:SetPoint("LEFT", hoard, "TOPLEFT", 176 + (k - 1) * 17, -16 - i * 24)
      if k <= filled then
        c:SetVertexColor(1, 1, 1)
        c:SetAlpha(1)
      else
        c:SetVertexColor(0.35, 0.3, 0.25)
        c:SetAlpha(0.55)
      end
    end
  end
  for j = p + 1, #hoard.pips do hoard.pips[j]:Hide() end
end

function QuestList.UpdateHoard()
  if not hoard then return end
  local state = UI.Win.State()
  local show = hoard.room and (state == "calibration" or state == "normal" or state == "missing" or state == "alone")
  hoard:SetShown(show and true or false)
  if not show then return end
  if state == "calibration" then
    showPile(Quests.GuildHaunches())
  else
    showWealth()
  end
end

-- Rerolling --------------------------------------------------------------------------------
-- The quest slides off to the left and fades while its reroll icon turns, and the other
-- quests' reroll icons fade with it. Then the new quest slides in from the right and fades
-- in, and its row eases to the new height with the quests below following along.

local REROLL_OUT = 0.22     -- seconds for the old quest to leave
local REROLL_IN = 0.34      -- and for the new one to arrive
local REROLL_SLIDE = 26     -- how far each one slides, in pixels
local rerollFrame

local function place(r)
  r:ClearAllPoints()
  r:SetPoint("TOPLEFT", panel, "TOPLEFT", r.dx or 0, r.y or 0)
end

-- Ends the animation. If the window closes before the old quest has left, the reroll
-- still happens, and the list shows the new quest next time.
local function endReroll()
  local a = rerolling
  if not a then return end
  rerolling = nil
  rerollFrame:SetScript("OnUpdate", nil)
  if a.phase == "out" then Quests.Reroll(a.slot) end
  for _, r in ipairs(rows) do
    r.reroll:SetAlpha(1)
    r.reroll.icon:SetRotation(0)
  end
  -- only the animated row: another row may be in the middle of being eaten
  local r = a.row
  r.dx = 0
  r:SetAlpha(1)
  if r.full then
    r.height = r.full
    r:SetHeight(r.full)
  end
  QuestList.Layout()
  if a.stale then QuestList.Refresh() end
end

local function stepReroll(_, elapsed)
  local a = rerolling
  if not a then
    rerollFrame:SetScript("OnUpdate", nil)
    return
  end
  if not panel:IsVisible() then return endReroll() end
  a.t = a.t + elapsed
  if a.phase == "out" then
    local p = math.min(1, a.t / REROLL_OUT)
    local e = UI.Smooth(p)
    a.row.dx = -REROLL_SLIDE * e
    a.row:SetAlpha(1 - e)
    a.row.reroll.icon:SetRotation(-math.pi * e)
    for _, r in ipairs(rows) do
      if r ~= a.row then r.reroll:SetAlpha(1 - e) end
    end
    place(a.row)
    if p < 1 then return end
    -- the old quest is gone: reroll, and bring the new one in where it was
    local oldH = a.row.height or a.row.full or 30
    a.phase, a.t = "in", 0
    Quests.Reroll(a.slot)
    QuestList.Refresh(true)
    local row
    for _, r in ipairs(rows) do
      if r.slot == a.slot then row = r end
    end
    if not row then return endReroll() end
    a.row, a.oldH = row, oldH
    row.dx = REROLL_SLIDE
    row:SetAlpha(0)
    QuestList.SetRowHeight(row, oldH)
  else
    local p = math.min(1, a.t / REROLL_IN)
    local e = UI.Smooth(p)
    a.row.dx = REROLL_SLIDE * (1 - e)
    a.row:SetAlpha(UI.Smooth(p * 1.25))
    QuestList.SetRowHeight(a.row, a.oldH + ((a.row.full or a.oldH) - a.oldH) * e)
    if p >= 1 then endReroll() end
  end
end

-- Rerolls the quest in a row: animated while the full window shows the list, at once
-- otherwise. Returns whether the reroll goes ahead.
function QuestList.AnimateReroll(row)
  if rerolling or not row or not row.slot or not Quests.CanReroll() then return false end
  if not panel or not panel:IsVisible() or UI.Eat.Running() then
    return Quests.Reroll(row.slot)
  end
  UI.HideTip()
  rerollFrame = rerollFrame or CreateFrame("Frame", nil, panel)
  rerolling = { row = row, slot = row.slot, phase = "out", t = 0 }
  rerollFrame:SetScript("OnUpdate", stepReroll)
  return true
end

function QuestList.Rerolling() return rerolling ~= nil end

-- Eating -----------------------------------------------------------------------------------

-- The row showing a quest that's waiting to be eaten.
function QuestList.RowFor(entry)
  for _, r in ipairs(rows) do
    if r.key == entry.key then return r end
  end
end

-- Where each glyph of a row's text sits, word-wrapped like the FontString: { ch, x, y }
-- relative to the row's top-left, in the row's font.
function QuestList.GlyphLayout(r)
  local measure = QuestList.measure
  if not measure then
    measure = panel:CreateFontString(nil, "OVERLAY", "GameFontHighlight")
    measure:Hide()
    QuestList.measure = measure
  end
  local font, size, flags = r.text:GetFont()
  if font then measure:SetFont(font, size, flags) end
  local function width(s)
    measure:SetText(s)
    return measure:GetStringWidth()
  end
  local lineH = (size or 12) + 2 + LINE_SPACING
  local out = {}
  local text = r.text:GetText() or ""
  local words = {}
  for w in text:gmatch("%S+") do words[#words + 1] = w end
  local line, y = "", 0
  local function emit(s)
    local glyphs = UI.Glyphs(s)
    local prefix = ""
    for _, ch in ipairs(glyphs) do
      out[#out + 1] = { ch = ch, x = TEXT_X + width(prefix), y = -y }
      prefix = prefix .. ch
    end
  end
  for _, w in ipairs(words) do
    local candidate = line == "" and w or (line .. " " .. w)
    if line ~= "" and width(candidate) > TEXT_W then
      emit(line)
      y = y + lineH
      line = w
    else
      line = candidate
    end
  end
  if line ~= "" then emit(line) end
  return out, lineH
end

function QuestList.Build(parent)
  panel = CreateFrame("Frame", nil, parent)
  panel:SetAllPoints(parent)
  header = UI.Text(panel, "GameFontNormal")
  header:SetPoint("TOPLEFT", 0, -4)
  header:SetText("Pinto quests")
  invites = UI.Text(panel, "GameFontNormalSmall")
  invites:SetWidth(WIDTH)
  footer = UI.Text(panel, "GameFontDisableSmall")
  footer:SetPoint("BOTTOMLEFT", 0, 4)
  footer:SetWidth(WIDTH)
  buildHoard()
  panel:SetScript("OnShow", function() QuestList.Refresh() end)
  panel:SetScript("OnHide", endReroll)
  QuestList.panel = panel
end

function QuestList.Panel() return panel end
function QuestList.Hoard() return hoard end
function QuestList.Rows() return rows end

-- Where a row's top-left corner is, from the full window's top-left corner.
function QuestList.RowOrigin(r)
  local px, py = UI.Win.PanelOffset()
  return px + (r.dx or 0), py + (r.y or 0)
end

QuestList.TEXT_X = TEXT_X
