-- The officer corner: a tab in the full window, visible only to officers. Pinto works
-- without it. Flags are hints to start a friendly chat, not automatic punishments.
local ADDON, ns = ...

local UI = ns.UI
local OfficerTab = {}
UI.OfficerTab = OfficerTab

local Officer, People, Compat, Time = ns.Officer, ns.People, ns.Compat, ns.Time

local view, questsBtn, officerBtn, content, scroll
local lines = {}
local CHOICE_X = { 8, 136 }   -- a player's "Void this week" and "Leave out" checkboxes

local function line(i)
  local fs = lines[i]
  if not fs then
    fs = UI.Text(content, "GameFontHighlightSmall")
    fs:SetWidth(250)
    lines[i] = fs
  end
  fs:Show()
  return fs
end

local checks = {}
local function check(i)
  local c = checks[i]
  if not c then
    c = CreateFrame("CheckButton", nil, content, "UICheckButtonTemplate")
    c:SetSize(20, 20)
    c.label = UI.Text(c, "GameFontHighlightSmall")
    c.label:SetPoint("LEFT", c, "RIGHT", 2, 0)
    checks[i] = c
  end
  c.rank = nil
  c:Show()
  return c
end

local function players()
  local list = {}
  for k, pl in pairs(People.View().players) do
    if pl.addon then
      local name
      for _, ch in pairs(pl.chars) do
        if ch.name and (not name or ns.Util.byteLess(ch.name, name)) then name = ch.name end
      end
      list[#list + 1] = { key = k, name = Compat.ShortName(name or k) }
    end
  end
  table.sort(list, function(a, b) return ns.Util.byteLess(a.name, b.name) end)
  return list
end

function OfficerTab.Refresh()
  if not view or not view:IsShown() then return end
  for _, fs in ipairs(lines) do fs:Hide() end
  for _, c in ipairs(checks) do c:Hide() end
  local y, li, ci = 0, 0, 0
  local function text(s, template)
    li = li + 1
    local fs = line(li)
    fs:SetFontObject(template or "GameFontHighlightSmall")
    fs:SetText(s)
    fs:ClearAllPoints()
    fs:SetPoint("TOPLEFT", content, "TOPLEFT", 0, -y)
    y = y + fs:GetStringHeight() + 4
  end
  text("Notifications", "GameFontNormal")
  local flags = Officer.Flags()
  if #flags == 0 then text("Nothing to look at right now.") end
  for i = 1, math.min(10, #flags) do
    local f = flags[i]
    text(Time.dateOfDay(Time.day(f.time)) .. "  " .. f.text)
  end
  y = y + 8
  text("Players", "GameFontNormal")
  text("Void a player's quests this week, or leave them out of Pinto.")
  local week = Time.week(Time.day())
  local s = ns.Store.get("s")
  for _, p in ipairs(players()) do
    -- the name on its own line, with its two choices side by side under it
    text(p.name, "GameFontHighlight")
    ci = ci + 1
    local c = check(ci)
    c:ClearAllPoints()
    c:SetPoint("TOPLEFT", content, "TOPLEFT", CHOICE_X[1], -y)
    c.label:SetText("Void this week")
    local e = s and s.entries["voidp:" .. p.key .. ":" .. string.format("%d", week)]
    c:SetChecked(e and e.value == "1")
    c:SetScript("OnClick", function(self) Officer.VoidWeek(p.key, week, self:GetChecked()) end)
    ci = ci + 1
    local x = check(ci)
    x:ClearAllPoints()
    x:SetPoint("TOPLEFT", content, "TOPLEFT", CHOICE_X[2], -y)
    x.label:SetText("Leave out")
    local ex = s and s.entries["excl:" .. p.key]
    x:SetChecked(ex and ex.value == "1")
    x:SetScript("OnClick", function(self) Officer.Exclude(p.key, self:GetChecked()) end)
    y = y + 22 + 8
  end
  if ns.Roster.IsGuildMaster(ns.me) and GuildControlGetNumRanks then
    y = y + 8
    text("Officer ranks", "GameFontNormal")
    local ranks = ns.Roster.OfficerRanks()
    for r = 1, GuildControlGetNumRanks() - 1 do
      ci = ci + 1
      local c = check(ci)
      c:ClearAllPoints()
      c:SetPoint("TOPLEFT", content, "TOPLEFT", 0, -y)
      c.label:SetText(GuildControlGetRankName(r + 1) or ("Rank " .. r))
      c:SetChecked(ranks[r] == true)
      c:SetScript("OnClick", function()
        local list = {}
        for i = 1, ci do
          local cb = checks[i]
          if cb.rank and cb:GetChecked() then list[#list + 1] = cb.rank end
        end
        Officer.SetRanks(list)
      end)
      c.rank = r
      y = y + 22
    end
  end
  content:SetHeight(y + 10)
end

local function show(which)
  local officer = which == "officer"
  view:SetShown(officer)
  UI.QuestList.Panel():SetShown(not officer)
  questsBtn:SetEnabled(officer)
  officerBtn:SetEnabled(not officer)
  if officer then OfficerTab.Refresh() end
end

function OfficerTab.Build(win, panel)
  view = CreateFrame("Frame", nil, win)
  view:SetAllPoints(panel)
  view:SetFrameLevel(panel:GetFrameLevel())
  view:Hide()
  scroll = CreateFrame("ScrollFrame", nil, view, "UIPanelScrollFrameTemplate")
  scroll:SetPoint("TOPLEFT", 0, -4)
  scroll:SetPoint("BOTTOMRIGHT", -24, 4)
  content = CreateFrame("Frame", nil, scroll)
  content:SetSize(250, 400)
  scroll:SetScrollChild(content)

  -- bottom right, inside the window's border; only officers see them (visibility below)
  officerBtn = UI.Button(win, "Officer corner", 116)
  officerBtn:SetPoint("BOTTOMRIGHT", win, "BOTTOMRIGHT", -16, 14)
  officerBtn:SetScript("OnClick", function() show("officer") end)
  questsBtn = UI.Button(win, "Quests", 80)
  questsBtn:SetPoint("RIGHT", officerBtn, "LEFT", -4, 0)
  questsBtn:SetScript("OnClick", function() show("quests") end)
  questsBtn:SetEnabled(false)
  local function visibility()
    local isOfficer = Officer.IsOfficer()
    questsBtn:SetShown(isOfficer)
    officerBtn:SetShown(isOfficer)
    if not isOfficer and view:IsShown() then show("quests") end
  end
  OfficerTab.visibility = visibility
  win:HookScript("OnShow", visibility)
  ns.Events.On("PINTO_ROSTER", visibility)
  ns.Events.On("PINTO_DATA_CHANGED", function(id)
    if id == "s" or (id and id:sub(1, 1) == "w") then OfficerTab.Refresh() end
  end)
  visibility()
end

function OfficerTab.Buttons() return questsBtn, officerBtn end
function OfficerTab.Content() return content end
