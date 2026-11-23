-- compat.lua: run Pinto's Lua 5.1 code (written for WoW) on a modern Lua such as 5.5.
-- harness.lua loads it once, before any addon file.
--
-- What it covers:
--   * Lua 5.1 globals that newer Lua removed: unpack, loadstring, table.getn, math.mod.
--   * WoW's bit library (bit.band, bor, bxor, bnot, lshift, rshift, arshift) on 32-bit values.
--     Results are unsigned (0 .. 2^32-1) by default. Set PINTO_BIT_SIGNED=1 for signed results,
--     like LuaBitOp, so code gets tested against both. Arguments must be whole numbers within
--     -2^31 .. 2^32-1; anything else raises an error here, so code never relies on wrapping.
--   * An optional "WoW numbers" mode (PINTO_FLOATS=1, or compat.floats()): string.byte,
--     math.floor, math.ceil and the bit functions return floats, so arithmetic happens in
--     doubles as in WoW, and precision bugs above 2^53 show up.
--
-- One difference can't be patched: modern Lua prints a float like 3.0 as "3.0", WoW as "3".
-- So addon code turns numbers into text with string.format("%d", n), never with .. or tostring.

local compat = {}

unpack = unpack or table.unpack
loadstring = loadstring or load
table.getn = table.getn or function(t) return #t end
math.mod = math.mod or math.fmod
string.gfind = string.gfind or string.gmatch
math.log10 = math.log10 or function(x) return math.log(x, 10) end
math.pow = math.pow or function(x, y) return x ^ y end
math.ldexp = math.ldexp or function(m, e) return m * 2.0 ^ e end
math.atan2 = math.atan2 or function(y, x) return math.atan(y, x) end

local SIGNED = os.getenv("PINTO_BIT_SIGNED") == "1"
local FLOATS = false

local function toint(x, level)
  if math.type(x) == "integer" then return x end
  local i = type(x) == "number" and math.tointeger(x)
  if not i then error("bit: argument is not a whole number: " .. tostring(x), level) end
  return i
end

local function arg(x)
  local i = toint(x, 4)
  if i >= 4294967296 or i < -2147483648 then
    error("bit: argument outside 32 bits: " .. tostring(x), 3)
  end
  return i & 0xFFFFFFFF
end

local function res(x)
  x = x & 0xFFFFFFFF
  if SIGNED and x >= 0x80000000 then x = x - 0x100000000 end
  if FLOATS then return x + 0.0 end
  return x
end

local function shiftCount(n)
  n = toint(n, 4)
  if n < 0 or n > 31 then error("bit: shift count outside 0..31: " .. tostring(n), 3) end
  return n
end

bit = {}

function bit.band(a, b, ...)
  local r = arg(a) & arg(b)
  for i = 1, select("#", ...) do r = r & arg((select(i, ...))) end
  return res(r)
end

function bit.bor(a, b, ...)
  local r = arg(a) | arg(b)
  for i = 1, select("#", ...) do r = r | arg((select(i, ...))) end
  return res(r)
end

function bit.bxor(a, b, ...)
  local r = arg(a) ~ arg(b)
  for i = 1, select("#", ...) do r = r ~ arg((select(i, ...))) end
  return res(r)
end

function bit.bnot(a) return res(~arg(a)) end

function bit.lshift(a, n) return res(arg(a) << shiftCount(n)) end

function bit.rshift(a, n) return res(arg(a) >> shiftCount(n)) end

function bit.arshift(a, n)
  local x = arg(a)
  if x >= 0x80000000 then x = x - 0x100000000 end
  return res(x // (1 << shiftCount(n)))
end

function bit.mod(a, b) return res(arg(a) % arg(b)) end

-- Switch to WoW numbers: everything that would produce an integer produces a float instead.
function compat.floats()
  if FLOATS then return end
  FLOATS = true
  local byte, floor, ceil = string.byte, math.floor, math.ceil
  local function floatAll(n, ...)
    if n == 0 then return end
    if n == 1 then return (...) + 0.0 end
    local t = { ... }
    for k = 1, n do t[k] = t[k] + 0.0 end
    return table.unpack(t, 1, n)
  end
  string.byte = function(s, i, j) return floatAll(select("#", byte(s, i, j)), byte(s, i, j)) end
  math.floor = function(x) return floor(x) + 0.0 end
  math.ceil = function(x) return ceil(x) + 0.0 end
end

if os.getenv("PINTO_FLOATS") == "1" then compat.floats() end

compat.signedBits = SIGNED
function compat.usingFloats() return FLOATS end

return compat
