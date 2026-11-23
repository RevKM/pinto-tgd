-- The whole addon with its UI, offline: guildies log in, the windows open, a quest is
-- finished and eaten (onto the meat pile during the calibration, into Pinto after it),
-- and the windows, tabs and debug panel all work without errors.
local H = require("harness")
local wow = require("wow")

local NAMES = { "Kiri", "Thorn", "Bram", "Ash", "Wren", "Moss", "Fern", "Rook" }
local full = wow.full

local function setup(time)
  local world = wow.world({ seed = 23, time = time })
  for i, n in ipairs(NAMES) do world:addMember(full(n), { rankIndex = i == 1 and 0 or 2, level = 40 }) end
  local clients = {}
  for i, n in ipairs(NAMES) do
    clients[i] = world:client(full(n), { ui = i == 1 })
    clients[i]:login()
  end
  world:run(90)
  return world, clients[1], clients
end

local function errorsOf(c)
  return #c.errors == 0, tostring(c.errors[1])
end

local function finishDungeonQuest(c)
  local ns = c.ns
  local Store, Pieces, Util, Time = ns.Store, ns.Pieces, ns.Util, ns.Time
  local week = Time.week(Time.day())
  Store.SetQuestSet(week, c.name, { created = 1, author = ns.Player.AccountId(), pack = ns.Pack.Newest(),
    quests = { { t = 8, worth = 2, named = {} }, { t = 1, worth = 1, named = {} }, { t = 7, worth = 2, named = {} },
      { t = 11, worth = 3, named = {} }, { t = 10, worth = 3, named = {} } } })
  local s = ns.Log.Session(Pieces.ACT.dungeon, 36)
  s.members = { [full("Thorn")] = true, [full("Bram")] = true }
  s.final, s.bosses = true, 6
  s.finalMembers = { [full("Thorn")] = true, [full("Bram")] = true }
  ns.Quests.Check()
  return week
end

H.test("during the calibration: windows, a finished quest lands on the meat pile", function()
  -- 2026-12-04, day 4 of the calibration
  local world, kiri = setup(1796349600)
  local ns = kiri.ns
  H.ok(ns.started and not ns.disabled, "Pinto didn't start: " .. tostring(ns.disabled))
  ns.UI.Open("full")
  world:run(5)
  local state = ns.UI.Win.State()
  H.eq(state, "calibration")
  -- the window: the title over Pinto, the quest list's heading, the guild's empty pile
  local win = ns.UI.FullWindow()
  H.eq(win.title:GetText(), "Pinto, the Girthy Dragon")
  -- the title sits 5% of the window lower than just under the window's edge
  H.eq(win.title.points.TOP and win.title.points.TOP.relPoint, "TOPLEFT")
  H.eq(win.title.points.TOP.y, -(22 + 28))
  -- Pinto sits 10% of the window lower than his side's top; asleep, the text sits 10% of
  -- the window higher than just above the middle of his side, 2 points larger
  H.eq(win.holder.points.TOPLEFT.y, -(40 + 56))
  local bottom = win.status.points.BOTTOM
  H.ok(bottom and bottom.relPoint == "TOPLEFT" and bottom.y == -(560 / 2 - 12) + 56 and not win.status.points.TOP,
    "the sleepy text should sit well above the middle")
  local _, size = win.status:GetFont()
  H.eq(size, 14, "the sleepy text is a little larger")
  -- the bottom left: "Small" and the start setting next to it, and no "Hide" button
  H.eq(win.toSmall:GetText(), "Small")
  H.eq(win.onStart.label:GetText(), "Open small on start")
  H.eq(win.onStart.points.LEFT.rel, win.toSmall)
  for _, c in ipairs(win.children) do
    H.ok(c:GetText() ~= "Hide", "the full window has no Hide button")
  end
  local QL = ns.UI.QuestList
  local hoard = QL.Hoard()
  H.ok(hoard:IsShown(), "the guild's pile should show during the calibration")
  H.eq(hoard.title:GetText(), "The guild's pile so far")
  H.eq(hoard.count:GetText(), "0 haunches")
  -- the small window keeps only the countdown under Pinto (or, once the calibration runs on,
  -- the short sleepy line; a test build's go-live is its build day)
  local _, smallText = ns.UI.Win.State("small")
  local _, fullText = ns.UI.Win.State("full")
  local _, _, sub = ns.Health.Shape()
  if sub == "calibration" then
    H.eq(smallText, ns.Health.AwakesText())
    H.ok(fullText:find("Snoozing on the hoard", 1, true), "the full window keeps the sleepy line")
  else
    H.eq(sub, "long")
    H.eq(smallText, ns.Health.TEXT.longShort)
    H.eq(fullText, ns.Health.TEXT.long)
  end
  finishDungeonQuest(kiri)
  H.eq(#ns.Quests.Uneaten(), 1)
  ns.UI.QuestList.Refresh()
  local row = QL.Rows()[1]
  H.ok(row and row.reward:GetText():find("^Rewards |T"), "the reward line: " .. tostring(row and row.reward:GetText()))
  H.ok(row.reward:GetText():find(" haunches$"), "the reward line ends with haunches")
  world:run(20)
  H.eq(#ns.Quests.Uneaten(), 0, "the quest wasn't eaten")
  H.eq(ns.UI.Win.Pile().count, 2, "two haunches should be on the pile")
  H.eq(ns.Quests.GuildHaunches(), 2)
  QL.Refresh()
  H.eq(hoard.count:GetText(), "2 haunches")
  ns.UI.Open("small")
  world:run(2)
  ns.UI.Toggle("full")
  world:run(2)
  ns.Build.testTools = true   -- the debug panel, whatever this build has
  ns.UI.ToggleDebugPanel()
  world:run(2)
  local ok, err = errorsOf(kiri)
  H.ok(ok, err)
end)

H.test("after the calibration: Pinto wakes, eats the pile, then eats new quests", function()
  -- 2026-12-14: calibration over, if 6 addon users are active
  local world, kiri, clients = setup(1797213600)
  local ns = kiri.ns
  -- give everyone play days so H can be calculated
  for _, c in ipairs(clients) do
    for d = ns.Time.day() - 7, ns.Time.day() - 1 do c.ns.Store.AddPlayed(d, c.name) end
  end
  world:run(120)
  ns.Health.MarkRecent()
  for _ = 1, 20 do ns.Health.Step() end
  local _, _, hstate = ns.Health.Shape()
  H.ok(hstate == "normal" or hstate == "missing", "health state " .. tostring(hstate))
  ns.UI.Win.Pile().count = 3
  ns.UI.Open("full")
  -- he eats the pile first, all of it in one stream, at the shape he slept in
  local scene = ns.UI.Win.Scene()
  H.ok(scene:IsEatingPile(), "the pile comes first")
  H.eq(scene:GetMeatPile(), 3)
  world:run(2.5)
  H.ok(scene:IsEatingPile() or scene:IsBusy(), "still eating the pile")
  H.ok(ns.UI.Win.Pile().count < 3, "haunches leave the pile as they fly")
  H.eq(scene:GetWeight(), 0.5, "the shape he slept in while he eats")
  -- then he eases into his real weight
  world:run(30)
  H.eq(ns.UI.Win.Pile().count, 0, "the pile wasn't eaten")
  H.ok(math.abs(scene:GetWeight() - ns.Health.Shape()) < 1e-9, "his real weight after the pile")
  -- awake, a well-fed Pinto reaches higher: the text goes under the title, at its usual size
  local status = ns.UI.FullWindow().status
  H.ok(status.points.TOP and status.points.TOP.y == -(22 + 28 + 26) and not status.points.BOTTOM,
    "the text should sit under the title once Pinto is awake")
  local _, size = status:GetFont()
  H.eq(size, 12)
  -- the start notice: new quests on the reset day; on another day, a change of shape since
  -- the player last saw him, or his mood in a few words
  local Win, Health = ns.UI.Win, ns.Health
  H.eq(Win.NoticeText(), Health.NOTICE.quests, "Monday: new quests")
  local weekStartDay = ns.Time.weekStartDay
  ns.Time.weekStartDay = function() return -1 end
  local weight = Health.Shape()
  local seen = Win.startSeen
  Win.startSeen = { weight = weight - 0.1 }
  H.eq(Win.NoticeText(), "Pinto is gaining girth!")
  Win.startSeen = { weight = weight + 0.1 }
  H.eq(Win.NoticeText(), "Pinto is losing girth...")
  Win.startSeen = { weight = weight }
  H.eq(Win.NoticeText(), Health.ShortMood(weight, Health.Feeding()))
  Win.startSeen = seen
  ns.Time.weekStartDay = weekStartDay
  -- awake: the guild's hoard, as a word and coins for gear and for gold
  local hoard = ns.UI.QuestList.Hoard()
  H.ok(hoard:IsShown(), "the guild's hoard should show once Pinto is awake")
  H.eq(hoard.title:GetText(), "The guild's hoard")
  H.eq(hoard.lines[1].label:GetText(), "Gear")
  H.eq(hoard.lines[2].label:GetText(), "Gold")
  local words = {}
  for _, w in ipairs(ns.Health.GEAR_WORDS) do words[w] = true end
  for _, w in ipairs(ns.Health.GOLD_WORDS) do words[w] = true end
  H.ok(words[hoard.lines[1].word:GetText()] and words[hoard.lines[2].word:GetText()], "a general word for each")
  -- awake: the quest's first drumstick goes into his mouth, the second onto his pile, which
  -- he eats on its own once he's done
  finishDungeonQuest(kiri)
  local most, now = 0, 0
  while now < 30 do
    world:run(0.1)
    now = now + 0.1
    most = math.max(most, scene:GetMeatPile())
    if ns.UI.Win.Pile().count > 0 then H.eq(ns.UI.Win.Pile().awake, true, "set aside while he was awake") end
  end
  H.eq(most, 1, "the second drumstick waits on the pile")
  H.eq(scene:GetMeatPile(), 0, "and he eats it")
  H.eq(ns.UI.Win.Pile().count, 0)
  H.eq(ns.UI.Win.Pile().awake, nil)
  H.eq(#ns.Quests.Uneaten(), 0, "the new quest wasn't eaten")
  local ok, err = errorsOf(kiri)
  H.ok(ok, err)
end)

H.test("a new guild member in the group: one more haunch pops in after the others", function()
  -- 2026-12-04, day 4 of the calibration: the haunches land on the pile
  local world, kiri = setup(1796349600)
  local ns = kiri.ns
  local Store, Pieces, Time = ns.Store, ns.Pieces, ns.Time
  -- Quill joined yesterday, after the founding register
  world:addMember(full("Quill"), { rankIndex = 4, level = 40 })
  local today = Time.day()
  Store.NoteJoins({ { name = full("Quill"), day = today - 1, how = Pieces.JOIN.message } }, today)
  ns.UI.Open("full")
  world:run(5)
  local week = Time.week(today)
  Store.SetQuestSet(week, kiri.name, { created = 1, author = ns.Player.AccountId(), pack = ns.Pack.Newest(),
    quests = { { t = 8, worth = 2, named = {} }, { t = 1, worth = 1, named = {} }, { t = 7, worth = 2, named = {} },
      { t = 11, worth = 3, named = {} }, { t = 10, worth = 3, named = {} } } })
  local s = ns.Log.Session(Pieces.ACT.dungeon, 36)
  s.members = { [full("Thorn")] = true, [full("Quill")] = true }
  s.final, s.bosses = true, 6
  s.finalMembers = { [full("Thorn")] = true, [full("Quill")] = true }
  ns.Quests.Check()
  local waiting = ns.Quests.Uneaten()
  H.eq(#waiting, 1)
  H.eq(waiting[1].worth, 2)
  H.eq(waiting[1].bonus, 1, "Quill is new to the guild")
  ns.UI.QuestList.Refresh()
  local row = ns.UI.QuestList.Rows()[1]
  local _, icons = row.reward:GetText():gsub("|T", "")
  H.eq(icons, 2, "the reward line shows the quest's 2 haunches, never the bonus")
  world:run(25)
  H.eq(#ns.Quests.Uneaten(), 0, "the quest wasn't eaten")
  H.eq(ns.UI.Win.Pile().count, 3, "the 2 haunches and the bonus should be on the pile")
  local found = false
  for _, r in ipairs(ns.UI.QuestList.Panel().regions) do
    if r.kind == "FontString" and r.text == "New guildie bonus!" then found = true end
  end
  H.ok(found, "the bonus should be announced when it pops in")
  local ok, err = errorsOf(kiri)
  H.ok(ok, err)
end)

H.test("only officers see the Quests and Officer corner buttons, inside the window", function()
  local world = wow.world({ seed = 24, time = 1796349600 })
  world:addMember(full("Kiri"), { rankIndex = 0 })
  world:addMember(full("Thorn"), { rankIndex = 3 })
  local kiri = world:client(full("Kiri"), { ui = true })
  local thorn = world:client(full("Thorn"), { ui = true })
  kiri:login()
  thorn:login()
  world:run(30)
  for _, c in ipairs({ kiri, thorn }) do
    c.ns.UI.Open("full")
    world:run(2)
  end
  local quests, officer = kiri.ns.UI.OfficerTab.Buttons()
  H.ok(quests:IsShown() and officer:IsShown(), "the guild master should see both buttons")
  local br = officer.points.BOTTOMRIGHT
  H.ok(br and br.relPoint == "BOTTOMRIGHT" and br.x <= -12, "the Officer corner button should sit inside the border")
  H.eq(quests.points.RIGHT.rel, officer)
  local q2, o2 = thorn.ns.UI.OfficerTab.Buttons()
  H.ok(not q2:IsShown() and not o2:IsShown(), "a member who isn't an officer sees neither")
  H.eq(#kiri.errors + #thorn.errors, 0)
end)

local function rowFor(QL, slot)
  for _, r in ipairs(QL.Rows()) do
    if r.slot == slot then return r end
  end
end

H.test("rerolling a quest: it slides out, the new quest slides in, and the reroll is spent", function()
  local world, kiri = setup(1796349600)
  local ns = kiri.ns
  local Quests, Util, Time = ns.Quests, ns.Util, ns.Time
  local week = Time.week(Time.day())
  local me = Util.nameId(kiri.name)
  ns.Store.SetQuestSet(week, kiri.name, { created = 1, author = ns.Player.AccountId(), pack = ns.Pack.Newest(),
    quests = { { t = 8, worth = 2, named = {} }, { t = 1, worth = 1, named = {} }, { t = 7, worth = 2, named = {} },
      { t = 11, worth = 3, named = {} }, { t = 10, worth = 3, named = {} } } })
  ns.UI.Open("full")
  world:run(5)
  local QL = ns.UI.QuestList
  QL.Refresh()
  H.ok(Quests.CanReroll(), "the week's reroll should be there")
  local row = rowFor(QL, 2)
  H.ok(row and row.reroll:IsShown(), "the quest should have its reroll icon")
  local before = row.text:GetText()
  row.reroll.scripts.OnClick(row.reroll)
  H.ok(QL.Rerolling(), "the animation should start")
  H.eq(QL.AnimateReroll(rowFor(QL, 3)), false, "one reroll at a time")
  world:run(0.1, 0.05)
  H.ok(row.dx < 0 and row:GetAlpha() < 1, "the old quest slides to the left and fades")
  H.ok(row.reroll.icon.rotation < 0, "the reroll icon turns")
  H.ok(Quests.CanReroll(), "the reroll happens once the old quest has left")
  world:run(0.3, 0.05)
  H.ok(not Quests.CanReroll(), "the reroll should be spent")
  H.eq(Quests.Effective(Quests.Piece(), me, 2).t, 10, "slot 2 now has the spare")
  local new = rowFor(QL, 2)
  H.ok(new.text:GetText() ~= before, "the row shows the new quest")
  H.ok(new.dx > 0 and new:GetAlpha() < 1, "the new quest slides in from the right")
  world:run(1, 0.05)
  H.ok(not QL.Rerolling(), "the animation should end")
  new = rowFor(QL, 2)
  H.eq(new.dx, 0)
  H.eq(new:GetAlpha(), 1)
  H.eq(new.height, new.full)
  for _, r in ipairs(QL.Rows()) do H.ok(not r.reroll:IsShown(), "no reroll icons once it's spent") end
  -- the test tools, whatever this build has: the reroll comes back, and so does the quest it
  -- swapped away. They only come with test builds, which keep test data, so this is a test
  -- build for the command.
  ns.Build.testTools = true
  local wasTest = ns.Build.test
  ns.Build.test = true
  kiri.env.SlashCmdList.PINTO("test reroll")
  ns.Build.test = wasTest
  H.ok(kiri.chat[#kiri.chat]:find("Your weekly reroll is back.", 1, true), tostring(kiri.chat[#kiri.chat]))
  world:run(1)
  H.ok(Quests.CanReroll(), "the reroll should be back")
  H.eq(Quests.Effective(Quests.Piece(), me, 2).t, 1, "and the quest it swapped away")
  H.ok(rowFor(QL, 2).reroll:IsShown(), "the reroll icons come back")
  -- closing the window halfway through still rerolls; the list shows the new quest next time
  local third = rowFor(QL, 3).text:GetText()
  rowFor(QL, 3).reroll.scripts.OnClick(rowFor(QL, 3).reroll)
  world:run(0.1, 0.05)
  ns.UI.Close()
  world:run(0.1, 0.05)
  H.ok(not QL.Rerolling(), "the animation should stop with the window")
  H.eq(Quests.Effective(Quests.Piece(), me, 3).t, 10)
  ns.UI.Open("full")
  world:run(2)
  H.ok(rowFor(QL, 3).text:GetText() ~= third, "the list shows the new quest")
  H.eq(rowFor(QL, 3).dx, 0)
  H.ok(errorsOf(kiri))
end)

H.test("the officer corner: each player's name, with its two choices side by side under it", function()
  local world, kiri = setup(1796349600)
  local ns = kiri.ns
  ns.UI.Open("full")
  world:run(2)
  local _, officer = ns.UI.OfficerTab.Buttons()
  officer.scripts.OnClick(officer)
  world:run(1)
  local content = ns.UI.OfficerTab.Content()
  local voids, leaves = {}, {}
  for _, c in ipairs(content.children) do
    if c.shown and c.label then
      local t = c.label:GetText()
      if t == "Void this week" then voids[#voids + 1] = c end
      if t == "Leave out" then leaves[#leaves + 1] = c end
    end
  end
  H.eq(#voids, #NAMES)
  H.eq(#leaves, #NAMES)
  local spans = {}   -- every line and checkbox row, top to bottom: { top, bottom }
  for i, v in ipairs(voids) do
    local vp, lp = v.points.TOPLEFT, leaves[i].points.TOPLEFT
    H.eq(vp.y, lp.y, "the two choices sit side by side")
    H.ok(vp.x + 22 + v.label:GetStringWidth() < lp.x, "the first label ends before the second checkbox")
    spans[#spans + 1] = { -vp.y, -vp.y + 20 }
  end
  for _, r in ipairs(content.regions) do
    if r.kind == "FontString" and r.shown and r.points.TOPLEFT then
      spans[#spans + 1] = { -r.points.TOPLEFT.y, -r.points.TOPLEFT.y + r:GetStringHeight() }
    end
  end
  table.sort(spans, function(a, b) return a[1] < b[1] end)
  for i = 2, #spans do
    H.ok(spans[i][1] >= spans[i - 1][2], "nothing in the officer corner overlaps")
  end
  H.ok(errorsOf(kiri))
end)

-- Runs the world a second at a time until fn() is true, for at most `limit` seconds.
local function runUntil(world, limit, fn)
  for _ = 1, limit do
    if fn() then return true end
    world:run(1)
  end
  return fn()
end

H.test("starting up: no window opens by itself unless the small one is asked for, and a notice follows the sync", function()
  -- 2026-12-04, a Friday on day 4 of the calibration
  local world = wow.world({ seed = 26, time = 1796349600 })
  for i, n in ipairs(NAMES) do world:addMember(full(n), { rankIndex = i == 1 and 0 or 2, level = 40 }) end
  local clients = {}
  for i, n in ipairs(NAMES) do clients[i] = world:client(full(n), { ui = i == 1 }) end
  for i = 2, #clients do clients[i]:login() end
  world:run(30)
  local kiri = clients[1]
  kiri:login()
  local ns = kiri.ns
  -- the minimap button, laid out like other addons' buttons: a dark round background in the
  -- border's hole, Pinto's head centred on it
  local button = ns.UI.MiniButton.Button()
  H.eq(button.bg.path, "Interface\\Minimap\\UI-Minimap-Background")
  H.eq(button.bg.layer, "BACKGROUND")
  H.eq(button.bg.w, 20)
  H.eq(button.bg.points.TOPLEFT.x, 7)
  H.eq(button.bg.points.TOPLEFT.y, -5)
  H.eq(button.border.w, 53)
  H.eq(button.icon.layer, "ARTWORK")
  H.eq(button.icon.points.CENTER.rel, button.bg)
  -- no window opens; the notice waits for the sync, then slides in beside the button
  world:run(2)
  H.eq(ns.UI.Active(), nil, "nothing opens by itself")
  local MB = ns.UI.MiniButton
  H.ok(not (MB.Notice() and MB.Notice().shown), "no notice before the sync")
  H.ok(runUntil(world, 90, function() return MB.Notice() and MB.Notice().shown end), "the start notice should show")
  local note = MB.Notice()
  H.eq(note.text:GetText(), "There are new Pinto quests for you!", "the first login of the week")
  H.eq(note.points.LEFT.rel, button)
  world:run(2)
  H.eq(note.alpha, 1)
  world:run(9)
  H.ok(not note.shown, "it goes after 8 seconds")
  -- tick "Open small on start": the small window opens at the next start, on the syncing
  -- silhouette, with the dark cover over its whole cave
  ns.UI.Open("full")
  world:run(1)
  local onStart = ns.UI.FullWindow().onStart
  onStart:SetChecked(true)
  onStart.scripts.OnClick(onStart)
  H.eq(ns.UI.Settings().openSmall, true)
  kiri:logout()
  kiri:login()
  ns = kiri.ns
  H.eq(ns.UI.Active(), "small", "the small window opens on start")
  local small = ns.UI.SmallWindow()
  H.eq(ns.UI.Win.State(), "syncing")
  H.eq(small.cover.points.ALL.rel, small.cave, "the cover spans the whole cave")
  H.eq(small.cover.alpha, 1)
  MB = ns.UI.MiniButton
  H.ok(runUntil(world, 90, function() return MB.Notice() and MB.Notice().shown end), "the start notice should show again")
  H.eq(MB.Notice().text:GetText(), "Pinto is snoozing on the hoard", "told about the quests already this week")
  world:run(3)
  H.ok(small.cover.alpha < 0.01, "the cover fades with the silhouette")
  -- unticked, nothing opens, even with the full window open at logout
  ns.UI.Open("full")
  world:run(1)
  onStart = ns.UI.FullWindow().onStart
  H.eq(onStart:GetChecked(), true)
  onStart:SetChecked(false)
  onStart.scripts.OnClick(onStart)
  kiri:logout()
  kiri:login()
  world:run(2)
  H.eq(kiri.ns.UI.Active(), nil)
  H.ok(errorsOf(kiri))
end)

H.test("test controls: Pinto's weight, hoard and animations in any combination, and Reset brings the guild's Pinto back", function()
  local world, kiri = setup(1796349600)
  local ns = kiri.ns
  ns.Build.testTools = true   -- the test tools, whatever this build has
  ns.UI.Open("full")
  world:run(5)
  local Win = ns.UI.Win
  local win = ns.UI.FullWindow()
  local scene = Win.Scene()
  local bar = win.testBar
  H.ok(bar, "test builds have the test controls")
  H.eq(bar.points.BOTTOMRIGHT.x, 16 + 680 - 4, "at the bottom right of Pinto's side")
  local function click(key)
    local b = bar.buttons[key]
    b.scripts.OnClick(b)
  end
  H.ok(not Win.Testing())
  -- asleep in the calibration: wake him, make him very fat on a feast day, and richer
  click("sleep")
  H.ok(Win.Testing() and scene:IsAwake(), "awake for the test")
  for _ = 1, 8 do click("weightUp") end
  click("hoardUp")
  click("day")
  world:run(1)
  local t = Win.TestLook()
  H.eq(t.weight, 0.9)
  H.eq(scene:GetWeight(), 0.9, "the scene changes shape")
  H.eq(bar.weightValue:GetText(), "0.90 Very fat")
  H.eq(win.status:GetText(), ns.Health.MoodLine(0.9, 1.5), "the mood line follows the test look")
  H.ok(win.status.points.TOP, "awake: the text under the title")
  -- feeding: a haunch flies in and he eats it
  click("feed")
  H.ok(scene:IsBusy())
  world:run(10)
  H.ok(not scene:IsBusy(), "the haunch was eaten")
  -- the meat pile, eaten
  click("pile")
  click("pile")
  H.eq(Win.PileCount(), 2)
  H.eq(scene:GetMeatPile(), 2)
  click("eatPile")
  world:run(20)
  H.eq(Win.PileCount(), 0)
  H.eq(scene:GetMeatPile(), 0)
  -- the syncing silhouette, over the whole cave
  click("silhouette")
  world:run(1)
  H.ok(win.cover.alpha > 0.99, "the cover shows with the silhouette")
  H.eq(win.status:GetText(), ns.Health.TEXT.syncing)
  -- asleep, a haunch lands on the pile
  click("sleep")
  click("feed")
  H.eq(Win.PileCount(), 1)
  H.eq(Win.Pile().count, 0, "the player's own pile is untouched")
  -- Reset: the guild's Pinto again, asleep at 0.5, in color
  bar.buttons.reset.scripts.OnClick(bar.buttons.reset)
  world:run(3)
  H.ok(not Win.Testing())
  H.ok(not scene:IsAwake())
  H.eq(scene:GetWeight(), 0.5)
  H.eq(scene:GetSilhouette(), 0)
  H.eq(scene:GetMeatPile(), 0)
  H.ok(win.cover.alpha < 0.01)
  H.ok(errorsOf(kiri))
end)

H.test("test controls: waking him beside a pile runs the end of the calibration", function()
  local world, kiri = setup(1796349600)
  local ns = kiri.ns
  ns.Build.testTools = true
  ns.UI.Open("full")
  world:run(5)
  local Win = ns.UI.Win
  local scene = Win.Scene()
  local bar = ns.UI.FullWindow().testBar
  local function click(key)
    local b = bar.buttons[key]
    b.scripts.OnClick(b)
  end
  for _ = 1, 5 do click("pile") end
  H.eq(Win.PileCount(), 5)
  -- asleep, the weight buttons set the weight he wakes to; he sleeps on at 0.50
  for _ = 1, 6 do click("weightUp") end
  world:run(1)
  H.eq(Win.TestLook().weight, 0.8)
  H.eq(scene:GetWeight(), 0.5, "he sleeps on at the shape he fell asleep in")
  H.eq(bar.weightLabel:GetText(), "Wakes to")
  -- wake: the pile in one stream at 0.50, then he eases into 0.80
  click("sleep")
  H.ok(scene:IsAwake() and scene:IsEatingPile(), "he wakes up to his pile")
  world:run(2)
  H.eq(scene:GetWeight(), 0.5, "the shape he slept in while he eats")
  H.ok(Win.PileCount() < 5, "the pile goes as he eats")
  world:run(10)
  H.eq(Win.PileCount(), 0)
  H.eq(scene:GetWeight(), 0.8, "then his new weight")
  H.eq(bar.weightLabel:GetText(), "Weight")
  H.eq(Win.Pile().count, 0, "the player's own pile is untouched")
  H.ok(errorsOf(kiri))
end)

H.test("previewing finished quests: eaten at once with the window open, or the next time it opens", function()
  local world, kiri = setup(1796349600)
  local ns = kiri.ns
  ns.Build.testTools = true
  local Quests, Win, QL = ns.Quests, ns.UI.Win, ns.UI.QuestList
  local slash = kiri.env.SlashCmdList.PINTO
  local week = ns.Time.week(ns.Time.day())
  local me = ns.Util.nameId(kiri.name)
  -- slot 1 is worth 2, slot 2 1, slot 3 2 and slot 4 3
  ns.Store.SetQuestSet(week, kiri.name, { created = 1, author = ns.Player.AccountId(), pack = ns.Pack.Newest(),
    quests = { { t = 8, worth = 2, named = {} }, { t = 1, worth = 1, named = {} }, { t = 7, worth = 2, named = {} },
      { t = 11, worth = 3, named = {} }, { t = 10, worth = 3, named = {} } } })
  ns.UI.Open("full")
  world:run(5)
  -- with the window open: the minimap button cheers, and Pinto, asleep, gets it on the pile
  slash("test complete 2")
  H.ok(kiri.chat[#kiri.chat]:find("Preview: quest 2 is finished", 1, true), tostring(kiri.chat[#kiri.chat]))
  H.ok(Win.Testing(), "a preview starts the test look")
  local _, badge = ns.UI.MiniButton.Button()
  H.ok(badge.shown, "the minimap badge shows")
  world:run(20)
  H.ok(Quests.PreviewOf(2).eaten, "the preview was eaten")
  H.eq(rowFor(QL, 2), nil, "an eaten quest leaves the list")
  H.eq(Win.PileCount(), 1, "quest 2's haunch is on the test's pile")
  -- with the window closed: two more, eaten when it opens, one with the new guildie bonus
  ns.UI.Close()
  slash("test complete 3 bonus")
  slash("test complete")
  H.ok(Quests.PreviewOf(1) and Quests.PreviewOf(3), "the first quest that isn't finished, and quest 3")
  H.eq(#Quests.Uneaten(), 2)
  world:run(5)
  H.ok(not Quests.PreviewOf(1).eaten, "nothing is eaten while the window is closed")
  ns.UI.Open("full")
  world:run(40)
  H.ok(Quests.PreviewOf(1).eaten and Quests.PreviewOf(3).eaten, "both are eaten when the window opens")
  H.eq(Win.PileCount(), 1 + 2 + (2 + 1))
  local found = false
  for _, r in ipairs(QL.Panel().regions) do
    if r.kind == "FontString" and r.text == "New guildie bonus!" then found = true end
  end
  H.ok(found, "the bonus haunch pops in with its label")
  -- nothing was recorded
  local wp = Quests.Piece(week)
  for slot = 1, 4 do H.eq(wp.done[ns.Pieces.doneKey(me, slot)], nil, "a preview was recorded") end
  for key in pairs(kiri.env.PintoTGD_DB.eaten or {}) do H.ok(not key:find("preview", 1, true), "a preview marked eaten") end
  H.eq(Win.Pile().count, 0, "the player's own pile is untouched")
  slash("test complete 9")
  H.ok(kiri.chat[#kiri.chat]:find("there's no quest 9", 1, true), tostring(kiri.chat[#kiri.chat]))
  H.eq(Quests.PreviewOf(9), nil)
  -- reset: the quests come back unfinished
  slash("test reset")
  H.ok(kiri.chat[#kiri.chat]:find("Test over", 1, true), tostring(kiri.chat[#kiri.chat]))
  world:run(2)
  H.ok(not Win.Testing())
  H.eq(#Quests.Uneaten(), 0)
  for slot = 1, 4 do
    local r = rowFor(QL, slot)
    H.ok(r and not r.item.done, "quest " .. slot .. " is back, unfinished")
  end
  H.eq(Win.Scene():GetMeatPile(), 0)
  -- the week's quests rolled again, and the start notice once more
  slash("test refresh")
  H.ok(kiri.chat[#kiri.chat]:find("New quests for this week", 1, true), tostring(kiri.chat[#kiri.chat]))
  H.eq(Quests.Piece(week).sets[me].created, 0)
  slash("test notice")
  world:run(1)
  H.ok(ns.UI.MiniButton.Notice().shown)
  H.ok(errorsOf(kiri))
end)

H.test("every build says whether it has the test tools, and a release build never has them", function()
  local build = H.load({ "Core/Build.lua" }).Build
  H.eq(type(build.testTools), "boolean")
  if not build.test then H.eq(build.testTools, false) end
end)

H.test("beta and release builds: no test controls or /pinto test, and /pinto debug only switches the messages", function()
  local world, kiri = setup(1796349600)
  local ns = kiri.ns
  ns.Build.testTools = false
  local slash = kiri.env.SlashCmdList.PINTO
  local Win = ns.UI.Win
  -- colors picked in a test build's debug panel once: Pinto wears Ruby all the same
  ns.UI.Settings().palette = { "4a90d9", "a3c8f0", "e8f1fa" }
  ns.UI.Open("full")
  world:run(5)
  H.eq(ns.UI.FullWindow().testBar, nil, "no test controls")
  H.eq(Win.StartTest(), nil, "no test look")
  H.eq(Win.Scene().pal.bd[1], ns.Render.Palette("e2574c", "fac775", "faeeda").bd[1], "he wears Ruby")
  -- /pinto test is no command: like any other word after /pinto, it shuts the open window
  local said = #kiri.chat
  slash("test complete 1")
  H.eq(ns.UI.Active(), nil)
  H.eq(#kiri.chat, said, "nothing about tests")
  H.eq(ns.Quests.TestFinish(1), nil)
  H.eq(#ns.Quests.Uneaten(), 0, "no preview")
  -- /pinto debug switches the debug messages, and no panel opens (it would open the window)
  slash("debug")
  H.ok(kiri.env.PintoTGD_DB.debug)
  H.ok(kiri.chat[#kiri.chat]:find("Debug messages on.", 1, true), tostring(kiri.chat[#kiri.chat]))
  world:run(1)
  H.eq(ns.UI.Active(), nil, "no debug panel")
  slash("debug")
  H.ok(not kiri.env.PintoTGD_DB.debug)
  -- /pinto status says which build this is
  said = #kiri.chat
  slash("status")
  local version = "version " .. ns.Build.version .. (ns.Build.test and " beta" or "") .. ", "
  local found = false
  for i = said + 1, #kiri.chat do
    if kiri.chat[i]:find(version, 1, true) then found = true end
  end
  H.ok(found, "the status line names the build: " .. tostring(kiri.chat[said + 1]))
  H.ok(errorsOf(kiri))
end)

H.test("Pinto writes none of the game's globals, and of its tables only adds /pinto and its windows", function()
  -- a game global or table entry an addon writes is tainted, even if the same value goes back,
  -- and the game's own code that reads it then can't call protected functions: /pvp and
  -- /guildinvite got blocked that way once
  local world, kiri, clients = setup(1796349600)
  local ns = kiri.ns
  local slash = kiri.env.SlashCmdList.PINTO
  H.eq(type(slash), "function", "/pinto is in the game's list")
  -- a busy session: both windows, the commands, the tooltips, an update popup, a finished
  -- quest eaten
  ns.UI.Open("small")
  world:run(2)
  slash("")
  world:run(2)
  for _, cmd in ipairs({ "status", "debug", "debug", "small", "link", "test", "anything" }) do slash(cmd) end
  finishDungeonQuest(kiri)
  ns.UI.Open("full")
  world:run(20)
  local button = ns.UI.MiniButton.Button()
  button.scripts.OnEnter(button)
  H.ok(ns.UI.Tip():IsShown(), "Pinto's own tooltip")
  H.eq(ns.UI.Tip().title:GetText(), "Pinto, the Girthy Dragon")
  button.scripts.OnLeave(button)
  H.ok(not ns.UI.Tip():IsShown())
  local reroll = ns.UI.QuestList.Rows()[1].reroll
  reroll.scripts.OnEnter(reroll)
  H.eq(ns.UI.Tip().body:GetText(), "Reroll this quest for another one. You get one reroll a week.")
  reroll.scripts.OnLeave(reroll)
  ns.Release.Status = function() return "available", { version = "9.9.9" } end
  ns.UI.Popups.Check()
  H.ok(ns.UI.Popups.Frame():IsShown(), "the update popup")
  world:run(2)
  local own = { PintoTGD_DB = true, SLASH_PINTO1 = true }
  for _, c in ipairs(clients) do
    for name in pairs(c.globalWrites) do H.ok(own[name], c.name .. " wrote the game's global " .. name) end
    for _, ch in ipairs(c:gameTableChanges()) do
      local fine = (ch.name == "SlashCmdList" and ch.key == "PINTO")
        or (ch.name == "UISpecialFrames" and type(ch.value) == "string" and ch.value:find("^PintoTGD") ~= nil)
      H.ok(fine, string.format("%s changed the game's %s.%s", c.name, ch.name, tostring(ch.key)))
    end
  end
  H.ok(kiri.globalWrites.SLASH_PINTO1 and kiri.globalWrites.PintoTGD_DB, "the writes are watched")
  local changed = {}
  for _, ch in ipairs(kiri:gameTableChanges()) do changed[ch.name .. "." .. tostring(ch.key)] = true end
  H.ok(changed["SlashCmdList.PINTO"], "the table changes are watched")
  H.ok(errorsOf(kiri))
end)

H.test("Pinto's code never uses the game's shared tooltip, popups, menus, chat code or option panels", function()
  -- an addon taints whatever shared frame or table of the game's it touches, and the game's own
  -- code after it then can't call protected functions
  local NEVER = { "GameTooltip", "StaticPopup", "UIDropDownMenu", "EasyMenu", "ToggleDropDownMenu",
    "ChatEdit_", "ChatFrame_", "ChatFrameUtil", "hooksecurefunc", "SetCVar", "InterfaceOptions",
    "Settings%.Register", "ShowUIPanel", "HideUIPanel", "UIParent_ManageFramePositions", "_G%[",
    "setglobal", "SlashCmdList%s*=" }
  local found = {}
  for _, file in ipairs(H.tocFiles()) do
    local n = 0
    for line in io.lines(H.ROOT .. "/" .. file) do
      n = n + 1
      local code = line:gsub("%-%-.*$", "")
      for _, word in ipairs(NEVER) do
        if code:find(word) then found[#found + 1] = string.format("%s:%d %s", file, n, word) end
      end
    end
  end
  H.eq(#found, 0, table.concat(found, ", "))
end)

H.test("an update popup: Pinto's own window with the link to copy, after combat, once per version", function()
  local world, kiri = setup(1796349600)
  local ns = kiri.ns
  local Popups = ns.UI.Popups
  local status = "available"
  ns.Release.Status = function() return status, { version = "0.2.0" } end
  -- in combat it waits until combat ends
  kiri.combat = true
  Popups.Check()
  H.ok(not (Popups.Frame() and Popups.Frame():IsShown()), "not in combat")
  kiri.combat = false
  kiri:fire("PLAYER_REGEN_ENABLED")
  local f = Popups.Frame()
  H.ok(f and f:IsShown(), "after combat")
  H.eq(f.text:GetText(), "Pinto 0.2.0 is out! Update when you get a chance.")
  H.eq(f.box:GetText(), ns.Build.releaseUrl, "the link, to copy")
  f.box:SetText("oops")
  f.box.scripts.OnTextChanged(f.box, true)
  H.eq(f.box:GetText(), ns.Build.releaseUrl, "typing doesn't change it")
  local listed = false
  for _, name in ipairs(kiri.env.UISpecialFrames) do if name == "PintoTGDUpdate" then listed = true end end
  H.ok(listed, "Escape closes it, like the game's own windows")
  f.ok.scripts.OnClick(f.ok)
  H.ok(not f:IsShown(), "Okay closes it")
  Popups.Check()
  H.ok(not f:IsShown(), "once per version")
  -- an update that's needed: again, with its own words
  status = "needed"
  Popups.Check()
  H.ok(f:IsShown())
  H.eq(f.text:GetText(), "Pinto needs an update to stay in sync with the guild.")
  H.eq(next(kiri.env.StaticPopupDialogs), nil, "the game's popups are left alone")
  H.ok(errorsOf(kiri))
end)

H.test("eating a finished quest: its text never comes back, the reward stays 3 seconds, then its drumsticks hop onto the pile", function()
  -- 2026-12-04, day 4 of the calibration: Pinto sleeps
  local world, kiri = setup(1796349600)
  local ns = kiri.ns
  local QL, Eat, Win = ns.UI.QuestList, ns.UI.Eat, ns.UI.Win
  ns.UI.Open("full")
  world:run(5)
  local pile0 = Win.PileCount()
  finishDungeonQuest(kiri)   -- quest 1, worth 2
  H.eq(Eat.Phase(), "sweep", "the window is open, so the eating starts at once")
  local row = rowFor(QL, 1)
  H.ok(row and row.eating)
  local phases, textBack, holdAt, collapseAt = {}, false, nil, nil
  local now = 0
  while now < 25 do
    world:run(0.05, 0.05)
    now = now + 0.05
    local ph = Eat.Phase()
    if not ph then break end
    if phases[#phases] ~= ph then phases[#phases + 1] = ph end
    if row.eating and row.text.alpha > 0 then textBack = true end
    if ph == "hold" and not holdAt then
      holdAt = now
      local label, tail = row.rewardWords[1], row.rewardWords[2]
      H.eq(label:GetText(), "Rewards")
      H.eq(tail:GetText(), "haunches")
      H.eq(label.alpha, 1, "the reward has faded in")
      H.eq(row.height, 26, "the row eased to the reward's height")
      H.eq(row.note.alpha, 0, "the note went with the quest's text")
      local shown = 0
      for _, r in ipairs(Eat.Flyer().regions) do
        if r.shown and r.alpha == 1 then shown = shown + 1 end
      end
      H.eq(shown, 2, "the reward's two drumsticks")
    end
    if ph == "collapse" and not collapseAt then
      collapseAt = now
      H.eq(Win.PileCount(), pile0, "nothing lands on the pile before the drumsticks fly")
    end
  end
  H.ok(not textBack, "the quest's text popped back")
  H.eq(table.concat(phases, " "), "sweep reveal hold collapse fly")
  H.ok(holdAt and collapseAt and math.abs(collapseAt - holdAt - 3) < 0.1,
    "the reward stays 3 seconds: " .. tostring(collapseAt and holdAt and collapseAt - holdAt))
  H.eq(Win.PileCount(), pile0 + 2, "both drumsticks landed on the pile")
  H.eq(#ns.Quests.Uneaten(), 0)
  H.ok(errorsOf(kiri))
end)

H.finish()
