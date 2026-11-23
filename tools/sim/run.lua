-- run.lua: runs every tools/sim/test_*.lua file and prints the totals.
-- Usage, from the project root:  lua tools/sim/run.lua [name filter]

package.path = "tools/sim/?.lua;" .. package.path
local H = require("harness")
H.runningAll = true

local filter = arg and arg[1]
local files = {}
local list = io.popen('dir /b "tools\\sim\\test_*.lua" 2>nul')
if list then
  for name in list:lines() do files[#files + 1] = name end
  list:close()
end
if #files == 0 then
  list = io.popen("ls tools/sim/ 2>/dev/null")
  if list then
    for name in list:lines() do
      if name:find("^test_.*%.lua$") then files[#files + 1] = name end
    end
    list:close()
  end
end
table.sort(files)

for _, name in ipairs(files) do
  if not filter or name:find(filter, 1, true) then
    print(name)
    local ok, err = pcall(dofile, "tools/sim/" .. name)
    if not ok then
      H.results.fail = H.results.fail + 1
      print("  FAIL  (file) " .. tostring(err))
    end
  end
end

print(string.format("\n%d passed, %d failed", H.results.pass, H.results.fail))
if H.results.fail > 0 then os.exit(1) end
