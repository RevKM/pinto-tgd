-- harness.lua: shared setup for Pinto's offline tests.
--
-- Run from the project root:
--   lua tools/sim/run.lua               all tests
--   lua tools/sim/test_bytes.lua        one test file
--
-- A test file looks like this:
--   local H = require("harness")
--   local ns = H.load({ "Core/Init.lua", "Sync/Bytes.lua" })
--   H.test("round trip", function() H.eq(ns.Bytes.something(), 1) end)
--   H.finish()

package.path = "tools/sim/?.lua;" .. package.path

local compat = require("compat")

local H = {}
H.compat = compat
-- PINTO_ROOT=dist/PintoTGD runs the tests against a build instead of the source.
H.ROOT = os.getenv("PINTO_ROOT") or "src/PintoTGD"
H.ADDON = "PintoTGD"

local results = { pass = 0, fail = 0 }
H.results = results

-- The addon's Lua files in .toc order. Skips comments, directives and XML files.
function H.tocFiles()
  local files = {}
  for raw in io.lines(H.ROOT .. "/" .. H.ADDON .. ".toc") do
    local line = raw:gsub("^%s+", ""):gsub("%s+$", "")
    if line ~= "" and not line:find("^#") and line:find("%.lua$") then
      files[#files + 1] = line:gsub("\\", "/")
    end
  end
  return files
end

-- Loads addon files into one namespace, the way WoW calls each file with (addonName, ns).
-- env, if given, is the global environment the files see (a simulated client's).
function H.load(files, ns, env)
  ns = ns or {}
  for _, f in ipairs(files) do
    local path = H.ROOT .. "/" .. f:gsub("\\", "/")
    local chunk, err = loadfile(path, "t", env or _G)
    if not chunk then error(err, 2) end
    chunk(H.ADDON, ns)
  end
  return ns
end

function H.deepCopy(t)
  if type(t) ~= "table" then return t end
  local c = {}
  for k, v in pairs(t) do c[k] = H.deepCopy(v) end
  return c
end

-- Shows a value for failure messages. Binary strings come out as hex.
function H.show(v)
  if type(v) == "string" then
    if v:find("[^\32-\126]") then
      return "hex:" .. (v:gsub(".", function(c) return string.format("%02x", c:byte()) end))
    end
    return string.format("%q", v)
  end
  return tostring(v)
end

function H.test(name, fn)
  local ok, err = xpcall(fn, debug.traceback)
  if ok then
    results.pass = results.pass + 1
    print("  ok    " .. name)
  else
    results.fail = results.fail + 1
    print("  FAIL  " .. name .. "\n" .. tostring(err))
  end
end

function H.ok(v, msg)
  if not v then error(msg or "expected a true value", 2) end
  return v
end

function H.eq(got, want, msg)
  if got ~= want then
    error((msg or "values differ") .. ": expected " .. H.show(want) .. ", got " .. H.show(got), 2)
  end
end

function H.near(got, want, eps, msg)
  eps = eps or 1e-9
  if type(got) ~= "number" or math.abs(got - want) > eps then
    error((msg or "numbers differ") .. ": expected " .. tostring(want) .. " ± " .. tostring(eps)
      .. ", got " .. tostring(got), 2)
  end
end

local function deepEq(a, b, path)
  if type(a) ~= type(b) then return false, path .. ": " .. type(a) .. " vs " .. type(b) end
  if type(a) ~= "table" then
    if a == b then return true end
    return false, path .. ": " .. H.show(a) .. " vs " .. H.show(b)
  end
  for k, v in pairs(a) do
    local ok, where = deepEq(v, b[k], path .. "." .. tostring(k))
    if not ok then return false, where end
  end
  for k in pairs(b) do
    if a[k] == nil then return false, path .. "." .. tostring(k) .. ": missing on the left" end
  end
  return true
end

function H.deepEq(got, want, msg)
  local ok, where = deepEq(got, want, "value")
  if not ok then error((msg or "tables differ") .. " at " .. where, 2) end
end

function H.raises(fn, pattern, msg)
  local ok, err = pcall(fn)
  if ok then error(msg or "expected an error", 2) end
  if pattern and not tostring(err):find(pattern) then
    error((msg or "wrong error") .. ": " .. tostring(err), 2)
  end
end

-- Prints the totals. Exits with an error code when a test file runs on its own and failed.
function H.finish()
  if H.runningAll then return end
  print(string.format("%d passed, %d failed", results.pass, results.fail))
  if results.fail > 0 then os.exit(1) end
end

return H
