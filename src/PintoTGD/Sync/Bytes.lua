-- Binary writer and reader for pieces and messages. Big-endian, with unsigned LEB128
-- varints for counts and small numbers.
local ADDON, ns = ...

local Bytes = {}
ns.Bytes = Bytes

local char, byte, floor = string.char, string.byte, math.floor

local function whole(v, lo, hi, what)
  if type(v) ~= "number" or v ~= v or v < lo or v > hi or floor(v) ~= v then
    error(string.format("Bytes: %s out of range: %s", what, tostring(v)), 3)
  end
end

function Bytes.u16str(v)
  whole(v, 0, 65535, "u16")
  return char(floor(v / 256), v % 256)
end

function Bytes.u32str(v)
  whole(v, 0, 4294967295, "u32")
  return char(floor(v / 16777216), floor(v / 65536) % 256, floor(v / 256) % 256, v % 256)
end

function Bytes.readU32(s, p)
  local a, b, c, d = byte(s, p, p + 3)
  return ((a * 256 + b) * 256 + c) * 256 + d
end

-- Writer ----------------------------------------------------------------------------

local Writer = {}
Writer.__index = Writer

function Bytes.writer()
  return setmetatable({ parts = {}, n = 0 }, Writer)
end

function Writer:raw(s)
  local n = self.n + 1
  self.n = n
  self.parts[n] = s
  return self
end

function Writer:u8(v)
  whole(v, 0, 255, "u8")
  return self:raw(char(v))
end

function Writer:u16(v) return self:raw(Bytes.u16str(v)) end

function Writer:u32(v) return self:raw(Bytes.u32str(v)) end

function Writer:varint(v)
  whole(v, 0, 9007199254740991, "varint")
  local out, n = {}, 0
  repeat
    local b = v % 128
    v = floor(v / 128)
    n = n + 1
    out[n] = v > 0 and b + 128 or b
  until v == 0
  return self:raw(char(unpack(out, 1, n)))
end

function Writer:str(s)
  self:varint(#s)
  return self:raw(s)
end

function Writer:bool(b) return self:raw(b and "\1" or "\0") end

function Writer:result()
  return table.concat(self.parts, "", 1, self.n)
end

-- Reader ----------------------------------------------------------------------------

local DECODE = {}

-- Raises a decode error: Bytes.decode turns it into a nil result. Use it for bad data.
function Bytes.fail(what)
  error({ [DECODE] = true, what = what }, 0)
end
local fail = Bytes.fail

local Reader = {}
Reader.__index = Reader

function Bytes.reader(s, pos)
  return setmetatable({ s = s, pos = pos or 1, len = #s }, Reader)
end

function Reader:u8()
  local p = self.pos
  if p > self.len then fail("u8") end
  self.pos = p + 1
  return byte(self.s, p)
end

function Reader:u16()
  local p = self.pos
  if p + 1 > self.len then fail("u16") end
  self.pos = p + 2
  local a, b = byte(self.s, p, p + 1)
  return a * 256 + b
end

function Reader:u32()
  local p = self.pos
  if p + 3 > self.len then fail("u32") end
  self.pos = p + 4
  return Bytes.readU32(self.s, p)
end

function Reader:varint()
  local v, mul = 0, 1
  for _ = 1, 8 do
    local b = self:u8()
    if b < 128 then return v + b * mul end
    v = v + (b - 128) * mul
    mul = mul * 128
  end
  fail("varint")
end

-- A count, checked against a sanity limit.
function Reader:count(max)
  local n = self:varint()
  if n > (max or 10000) then fail("count") end
  return n
end

function Reader:bytes(n)
  local p = self.pos
  if p + n - 1 > self.len then fail("bytes") end
  self.pos = p + n
  return self.s:sub(p, p + n - 1)
end

function Reader:str(max)
  local n = self:varint()
  if n > (max or 4096) then fail("string length") end
  return self:bytes(n)
end

function Reader:bool()
  local b = self:u8()
  if b > 1 then fail("bool") end
  return b == 1
end

function Reader:atEnd() return self.pos > self.len end

function Reader:rest()
  local s = self.s:sub(self.pos)
  self.pos = self.len + 1
  return s
end

-- Runs decoder(reader, ...) over s. Returns its result, or nil and a reason when the data
-- is malformed. Any other error is a bug and is raised again.
function Bytes.decode(s, decoder, ...)
  local r = Bytes.reader(s)
  local ok, res = pcall(decoder, r, ...)
  if ok then return res end
  if type(res) == "table" and res[DECODE] then return nil, res.what end
  error(res, 0)
end
