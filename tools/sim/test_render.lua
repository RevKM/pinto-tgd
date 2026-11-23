-- Pinto's scene runs hundreds of frames in every state without errors, with finite
-- coordinates everywhere (uistub raises on bad texture coordinates).
local H = require("harness")
local U = require("uistub")
local R = require("render_svg")

local ns, env = R.Load()

local function finite(v) return type(v) == "number" and v == v and math.abs(v) < 1e7 end

local function checkGeometry(root)
  for _, r in ipairs(U.Collect(root)) do
    if r.kind == "Texture" then
      local p = r.points.TOPLEFT
      if p then
        H.ok(finite(p.x) and finite(p.y) and finite(r.w) and finite(r.h), "bad texture geometry")
      end
    elseif r.kind == "Line" and r.p1 then
      H.ok(finite(r.p1.x) and finite(r.p1.y) and finite(r.p2.x) and finite(r.p2.y), "bad line geometry")
    end
  end
end

-- One frame, a 30th of a second on.
local function tick(scene, t)
  t = t + 1000 / 30
  U.time = t / 1000
  scene:Step(1 / 30, t)
  return t
end

local function run(scene, holder, seconds, t0)
  local t = t0 or 1000
  local steps = math.floor(seconds * 30)
  for _ = 1, steps do
    t = t + 1000 / 30
    U.time = t / 1000
    scene:Step(1 / 30, t)
  end
  checkGeometry(holder)
  return t
end

H.test("every weight and wealth, awake and asleep", function()
  local scene, holder = R.NewScene(ns, env)
  for _, F in ipairs({ 0, 0.1, 0.3, 0.5, 0.7, 0.9, 1 }) do
    for _, Hw in ipairs({ 0, 0.5, 1 }) do
      scene:SetWeight(F)
      scene:SetWealth(Hw)
      scene:SetAwake(F > 0.4)
      run(scene, holder, 1.5)
    end
  end
end)

H.test("feeding in every mood: one chomp per haunch, then idle", function()
  local scene, holder = R.NewScene(ns, env)
  scene:SetAwake(true, true)
  for mood, F in ipairs({ 0.05, 0.25, 0.5, 0.75, 0.95 }) do
    scene:SetWeight(F)
    local chomps = 0
    scene:Feed(900, 100, function() chomps = chomps + 1 end)
    scene:Feed(900, 100, function() chomps = chomps + 1 end)
    H.ok(scene:IsBusy())
    run(scene, holder, 8)
    H.eq(chomps, 2, "chomps in mood " .. mood)
    H.ok(not scene:IsBusy(), "still busy after eating")
  end
end)

H.test("the meat pile: eaten in one stream, each haunch leaving the pile as it starts to fly", function()
  local scene, holder = R.NewScene(ns, env)
  scene:SetAwake(false, true)
  scene:SetMeatPile(40)
  local t = run(scene, holder, 1)
  local seen, done = {}, false
  scene:EatPile(function(left) seen[#seen + 1] = left end, function() done = true end)
  t = run(scene, holder, 1, t)
  H.eq(#seen, 0, "nothing leaves the pile while he sleeps")
  scene:SetAwake(true)
  -- he wakes (0.9 s) and opens wide (0.35 s); the first haunch leaves the pile as it flies
  local steps = 0
  while #seen == 0 and steps < 90 do
    t = tick(scene, t)
    steps = steps + 1
  end
  H.eq(#seen, 1)
  H.eq(scene:GetMeatPile(), 39, "the haunch left the pile the moment it started flying")
  local sm = scene.stream
  H.eq(sm.gulp, 0, "his jaw holds still while he opens wide")
  H.eq(#sm.flying, 1)
  H.eq(sm.open, 1, "his mouth is wide open")
  local f = sm.flying[1]
  local x, y, rot, s = scene:StreamPoint(f, f.t0, 400, 200)
  H.ok(x == f.x and y == f.y and rot == f.rot and s == 0.8, "it starts exactly as it lay on the pile")
  -- 10 a second, each flying 0.8 s: about 8 in the air at once
  local most, gulpBefore, gulpAfter = 0, 0, 0
  local start = t
  while not done and t - start < 15000 do
    t = tick(scene, t)
    if scene.stream then most = math.max(most, #scene.stream.flying) end
    -- his jaw holds still until the first haunch goes in, then gulps as they go in
    if scene.stream and sm.phase == "flow" then
      if sm.t < f.t0 + 0.8 - 1e-6 then
        gulpBefore = math.max(gulpBefore, sm.gulp)
      else
        gulpAfter = math.max(gulpAfter, sm.gulp)
      end
    end
    if #seen == 11 and not sm.atEleven then sm.atEleven = (t - start) / 1000 end
  end
  H.ok(sm.atEleven and math.abs(sm.atEleven - 1) < 0.1, "10 more a second: " .. tostring(sm.atEleven))
  H.ok(most >= 7 and most <= 9, "haunches in the air at once: " .. most)
  H.eq(gulpBefore, 0, "his jaw moved before the first haunch went in")
  H.ok(gulpAfter > 0.9, "his jaw gulps as the haunches go in")
  checkGeometry(holder)
  H.ok(done, "the pile wasn't finished")
  -- the last leaves after 3.9 s and lands 0.8 s later; then he shuts his mouth and chews
  local took = (t - start) / 1000
  H.ok(took > 4.9 and took < 9, "the stream took " .. took .. " s")
  H.eq(#seen, 40)
  H.eq(seen[#seen], 0)
  H.eq(scene:GetMeatPile(), 0)
  H.ok(not scene:IsBusy())
  -- in every mood, a small pile ends with that mood's chewing
  for _, F in ipairs({ 0.05, 0.25, 0.5, 0.75, 0.95 }) do
    scene:SetWeight(F)
    scene:SetMeatPile(3)
    local finished = false
    scene:EatPile(nil, function() finished = true end)
    t = run(scene, holder, 8, t)
    H.ok(finished, "the pile wasn't finished at weight " .. F)
  end
end)

H.test("awake with a few haunches set aside on his pile, he eats them one at a time", function()
  local scene, holder = R.NewScene(ns, env)
  scene:SetAwake(true, true)
  scene:SetWeight(0.5)
  local lefts = {}
  scene:SetNibbling(true, function(left) lefts[#lefts + 1] = left end)
  scene:SetMeatPile(3)
  local t = tick(scene, 1000)
  -- the top haunch leaves the pile as it starts to fly, lying the way it lay there
  H.ok(scene.eat, "he starts on the top haunch")
  H.eq(scene:GetMeatPile(), 2)
  H.eq(lefts[1], 2)
  H.eq(scene.eat.rot0, -0.3)
  H.eq(scene.eat.scale0, 0.8)
  local eats, last = 1, scene.eat
  for _ = 1, 30 * 12 do
    t = tick(scene, t)
    if scene.eat and scene.eat ~= last then
      eats = eats + 1
      last = scene.eat
    end
  end
  checkGeometry(holder)
  H.eq(eats, 3, "one eating sequence per haunch")
  H.eq(scene:GetMeatPile(), 0)
  H.eq(#lefts, 3)
  H.ok(lefts[1] == 2 and lefts[2] == 1 and lefts[3] == 0, "the pile went 2, 1, 0")
  -- asleep, he leaves his pile alone
  scene:SetAwake(false, true)
  scene:SetMeatPile(2)
  run(scene, holder, 5, t)
  H.eq(scene:GetMeatPile(), 2)
end)

H.test("shape changes, the silhouette and frame-rate caps", function()
  local scene, holder = R.NewScene(ns, env)
  scene:SetSilhouette(1)
  run(scene, holder, 0.5)
  scene:SetSilhouette(0, 0.6)
  local finished = false
  scene:AnimateTo(0.9, 0.8, 1.5, function() finished = true end)
  run(scene, holder, 2)
  H.ok(finished)
  H.near(scene:GetWeight(), 0.9, 1e-9)
  scene:SetFrameRate(15)
  scene:SetPaused(true)
  scene:OnUpdate(1)
  scene:SetPaused(false)
  -- scene <-> frame coordinates round trip
  local fx, fy = scene:SceneToFrame(340, 230)
  local sx, sy = scene:FrameToScene(fx, fy)
  H.near(sx, 340, 1e-6)
  H.near(sy, 230, 1e-6)
end)

-- Placing a texture costs the game a layout pass, so parts that haven't moved more than a
-- fraction of a pixel stay put.
H.test("a frame that changes nothing places nothing, and idle frames place a fraction", function()
  local scene, holder = R.NewScene(ns, env)
  scene:SetWeight(0.5)
  scene:SetWealth(0.5)
  scene:SetAwake(true, true)
  local probe = holder:CreateTexture()
  local methods = getmetatable(probe).__methods
  local calls = 0
  local saved = {}
  for _, name in ipairs({ "SetPoint", "SetSize", "SetTexCoord", "SetStartPoint", "SetEndPoint" }) do
    local fn = methods[name]
    saved[name] = fn
    methods[name] = function(...)
      calls = calls + 1
      return fn(...)
    end
  end
  local ok, err = pcall(function()
    local t = 5000
    scene:Step(0, t)
    calls = 0
    scene:Step(0, t)
    H.eq(calls, 0, "the same frame again shouldn't place anything")
    for _ = 1, 30 do
      t = t + 1000 / 30
      scene:Step(1 / 30, t)
    end
    calls = 0
    for _ = 1, 90 do
      t = t + 1000 / 30
      scene:Step(1 / 30, t)
    end
    -- every part placed every frame would be about 1800 calls a frame
    H.ok(calls / 90 < 700, string.format("%.0f placements a frame while breathing", calls / 90))
  end)
  for name, fn in pairs(saved) do methods[name] = fn end
  H.ok(ok, tostring(err))
end)

H.test("a small window scales the same scene down", function()
  local holder = U.CreateFrame("Frame", nil, env.UIParent)
  holder:SetSize(224, 138)
  local scene = ns.Render.New(holder)
  scene.frame:SetAllPoints(holder)
  scene:SetAwake(true, true)
  run(scene, holder, 1)
  H.near(scene.canvas.s, 224 / 680, 1e-3)
end)

H.finish()
