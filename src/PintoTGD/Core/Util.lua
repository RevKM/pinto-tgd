-- Small helpers: hashing, text encodings, tables and ids.
local ADDON, ns = ...

local Util = {}
ns.Util = Util

local byte, char, floor = string.byte, string.char, math.floor

-- Hashing --------------------------------------------------------------------------
-- A polynomial hash modulo the largest prime below 2^32. Plain arithmetic, so it gives
-- the same answer in every Lua, and every product stays below 2^41.

local PRIME = 4294967291

function Util.hash(s, seed)
  local h = seed or 2166136261
  for i = 1, #s do
    h = (h * 257 + byte(s, i) + 1) % PRIME
  end
  return h
end

-- A character's 32-bit id: the hash of its "Name-Realm".
function Util.nameId(fullName)
  return Util.hash(fullName, 7919)
end

-- Base64, for storing binary pieces in SavedVariables ------------------------------

local B64 = "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789+/"
local b64enc, b64dec = {}, {}
for i = 1, 64 do
  local c = B64:sub(i, i)
  b64enc[i - 1] = c
  b64dec[byte(c)] = i - 1
end

function Util.base64(s)
  local out = {}
  for i = 1, #s, 3 do
    local a, b, c = byte(s, i, i + 2)
    local v = a * 65536 + (b or 0) * 256 + (c or 0)
    out[#out + 1] = b64enc[floor(v / 262144) % 64] .. b64enc[floor(v / 4096) % 64]
      .. (b and b64enc[floor(v / 64) % 64] or "=") .. (c and b64enc[v % 64] or "=")
  end
  return table.concat(out)
end

-- Returns nil for text that isn't valid base64.
function Util.unbase64(s)
  if #s % 4 ~= 0 then return nil end
  local out = {}
  for i = 1, #s, 4 do
    local a, b, c, d = byte(s, i, i + 3)
    local va, vb = b64dec[a], b64dec[b]
    if not va or not vb then return nil end
    local vc = c ~= 61 and b64dec[c] or nil
    local vd = d ~= 61 and b64dec[d] or nil
    if (c ~= 61 and not vc) or (d ~= 61 and not vd) then return nil end
    local v = va * 262144 + vb * 4096 + (vc or 0) * 64 + (vd or 0)
    if vc and vd then
      out[#out + 1] = char(floor(v / 65536), floor(v / 256) % 256, v % 256)
    elseif vc then
      out[#out + 1] = char(floor(v / 65536), floor(v / 256) % 256)
    else
      out[#out + 1] = char(floor(v / 65536))
    end
  end
  return table.concat(out)
end

-- Escaping for addon messages -------------------------------------------------------
-- Addon messages carry any byte except 0. Byte 1 is the escape: 0 -> 1 2, 1 -> 1 3.

function Util.escape(s)
  if not s:find("[%c]") then return s end
  local out, n = {}, 0
  for i = 1, #s do
    local b = byte(s, i)
    n = n + 1
    if b == 0 then out[n] = "\1\2"
    elseif b == 1 then out[n] = "\1\3"
    else out[n] = char(b) end
  end
  return table.concat(out)
end

-- Returns nil for a broken escape.
function Util.unescape(s)
  if not s:find("\1", 1, true) then return s end
  local out, n, i = {}, 0, 1
  local len = #s
  while i <= len do
    local b = byte(s, i)
    n = n + 1
    if b == 1 then
      local e = byte(s, i + 1)
      if e == 2 then out[n] = "\0"
      elseif e == 3 then out[n] = "\1"
      else return nil end
      i = i + 2
    else
      out[n] = char(b)
      i = i + 1
    end
  end
  return table.concat(out)
end

-- Ids -------------------------------------------------------------------------------

function Util.randomU32()
  local v = 0
  while v == 0 do
    v = math.random(0, 65535) * 65536 + math.random(0, 65535)
  end
  return v
end

-- Link codes for a second WoW license: the account id in Crockford base32 plus a check letter.
local B32 = "0123456789ABCDEFGHJKMNPQRSTVWXYZ"

function Util.linkCode(id)
  local digits = {}
  local v = id
  for i = 7, 1, -1 do
    local d = v % 32
    digits[i] = B32:sub(d + 1, d + 1)
    v = floor(v / 32)
  end
  local check = (id % 31) + 1
  return table.concat(digits, "", 1, 4) .. "-" .. table.concat(digits, "", 5, 7) .. B32:sub(check, check)
end

function Util.parseLinkCode(code)
  code = (code or ""):upper():gsub("[%s%-]", ""):gsub("O", "0"):gsub("[IL]", "1")
  if #code ~= 8 then return nil end
  local v = 0
  for i = 1, 7 do
    local d = B32:find(code:sub(i, i), 1, true)
    if not d then return nil end
    v = v * 32 + d - 1
  end
  if v >= 4294967296 or v == 0 then return nil end
  local check = (v % 31) + 1
  if code:sub(8, 8) ~= B32:sub(check, check) then return nil end
  return v
end

-- Tables ----------------------------------------------------------------------------

function Util.wipe(t)
  for k in pairs(t) do t[k] = nil end
  return t
end

function Util.copy(t)
  if type(t) ~= "table" then return t end
  local c = {}
  for k, v in pairs(t) do c[k] = Util.copy(v) end
  return c
end

function Util.sortedKeys(t, less)
  local keys = {}
  for k in pairs(t) do keys[#keys + 1] = k end
  table.sort(keys, less)
  return keys
end

function Util.count(t)
  local n = 0
  for _ in pairs(t) do n = n + 1 end
  return n
end

function Util.clamp(v, lo, hi)
  if v < lo then return lo end
  if v > hi then return hi end
  return v
end

function Util.median(values)
  local n = #values
  if n == 0 then return 0 end
  local s = {}
  for i = 1, n do s[i] = values[i] end
  table.sort(s)
  local m = floor(n / 2)
  if n % 2 == 1 then return s[m + 1] end
  return (s[m] + s[m + 1]) / 2
end

-- Linear interpolation between order statistics, like numpy's default.
function Util.percentile(values, q)
  local n = #values
  if n == 0 then return 0 end
  local s = {}
  for i = 1, n do s[i] = values[i] end
  table.sort(s)
  local pos = q * (n - 1)
  local lo = floor(pos)
  local hi = math.min(lo + 1, n - 1)
  return s[lo + 1] + (s[hi + 1] - s[lo + 1]) * (pos - lo)
end

-- Byte-by-byte string order, the same on every client (Lua 5.1's < uses the locale).
function Util.byteLess(a, b)
  local la, lb = #a, #b
  local n = la < lb and la or lb
  for i = 1, n do
    local x, y = byte(a, i), byte(b, i)
    if x ~= y then return x < y end
  end
  return la < lb
end

function Util.hex(s)
  return (s:gsub(".", function(c) return string.format("%02x", byte(c)) end))
end

-- Text ------------------------------------------------------------------------------

function Util.plural(n, one, many)
  if n == 1 then return string.format("%d %s", n, one) end
  return string.format("%d %s", n, many or (one .. "s"))
end
