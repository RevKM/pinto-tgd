local ADDON, ns = ...

-- Crypto.lua: SHA-512 and the Ed25519 signature check (RFC 8032), in plain Lua 5.1 for WoW.
--
-- The build signs release stamps and quest packs with tools/ed25519.py. Every addon checks those
-- signatures here before it trusts them. This file only checks: it holds no keys and can't sign.
--
--   Crypto.sha512(msg)            the 64-byte binary SHA-512 digest of a string
--   Crypto.verify(pub, msg, sig)  true or false, in one go. pub is 32 bytes, sig 64 bytes.
--   Crypto.verifier(pub, msg, sig)
--                                 a step function for OnUpdate. Each call does about
--                                 Crypto.SLICE units of work and returns nil until the check is
--                                 done, then true or false, and keeps returning that.
--   Crypto.hex(bin)               lowercase hex
--   Crypto.unhex(hex)             back to binary; nil if hex isn't an even number of hex digits
--
-- The check follows RFC 8032 section 5.1.7 without the cofactor: it accepts exactly when
-- [S]B = R + [k]A, with k = SHA-512(R || A || msg) mod L. It returns false, never an error, for
-- wrong lengths or types, a public key or R that doesn't decode to a curve point (including the
-- RFC's non-canonical encodings), and S >= L. It is not constant time; it only checks public data.
--
-- How it's built: field arithmetic as in TweetNaCl (16 limbs of 16 bits as plain numbers), with
-- the multiplications unrolled; the point formulas, exponent chains and the double scalar
-- multiplication with sliding windows from ref10 (SUPERCOP); reduction mod L from TweetNaCl.
--
-- WoW's numbers are doubles, so every whole number here stays below 2^53 (the largest are field
-- product columns, below 2^46). The bit library is only used for xor, on values in
-- 0 .. 2^32-1. Its results may come back signed, so they get % 2^32 before any arithmetic that
-- needs their exact value. Shifts, rotations and the other bit logic are plain arithmetic on
-- whole numbers, which is exact here.

local Crypto = {}
ns.Crypto = Crypto

-- Work units per step() of a verifier. A unit is about one field multiplication: 2.5
-- microseconds under Lua 5.5 on the dev PC, about 5 in the Forever client, which timed a
-- whole check at 18 ms. So the default is about 3 ms per step in the game. One check costs
-- about 3100 units, plus 340 per 128 bytes hashed (the message plus 64 bytes, padded): 6 steps
-- for a message of up to 47 bytes, 7 for a few hundred, up to 15 for 2000. Hashing is cheaper
-- than that in WoW, whose bit library is native code rather than the test harness's Lua.
Crypto.SLICE = 600

local bxor = bit.bxor
local byte, char, format, gsub, find, sub, rep =
  string.byte, string.char, string.format, string.gsub, string.find, string.sub, string.rep
local floor = math.floor
local unpack = unpack
local type, tonumber, error = type, tonumber, error
local cocreate, coresume, costatus, yield =
  coroutine.create, coroutine.resume, coroutine.status, coroutine.yield

local function noop() end

---------------------------------------------------------------------------------------------------
-- SHA-512 (FIPS 180-4)
--
-- Each 64-bit word is a pair of 32-bit halves, hi and lo, each a number in 0 .. 2^32-1. Sums
-- carry from lo into hi by hand. In the rotations, x % 2^n is x's low n bits and
-- (x - x % 2^n) / 2^n is x shifted right by n; the pieces of a rotation don't overlap, so they
-- are simply added.

local TWO32 = 4294967296

-- Round constants, as hi, lo halves
local K = {
  0x428a2f98, 0xd728ae22, 0x71374491, 0x23ef65cd, 0xb5c0fbcf, 0xec4d3b2f, 0xe9b5dba5, 0x8189dbbc,
  0x3956c25b, 0xf348b538, 0x59f111f1, 0xb605d019, 0x923f82a4, 0xaf194f9b, 0xab1c5ed5, 0xda6d8118,
  0xd807aa98, 0xa3030242, 0x12835b01, 0x45706fbe, 0x243185be, 0x4ee4b28c, 0x550c7dc3, 0xd5ffb4e2,
  0x72be5d74, 0xf27b896f, 0x80deb1fe, 0x3b1696b1, 0x9bdc06a7, 0x25c71235, 0xc19bf174, 0xcf692694,
  0xe49b69c1, 0x9ef14ad2, 0xefbe4786, 0x384f25e3, 0x0fc19dc6, 0x8b8cd5b5, 0x240ca1cc, 0x77ac9c65,
  0x2de92c6f, 0x592b0275, 0x4a7484aa, 0x6ea6e483, 0x5cb0a9dc, 0xbd41fbd4, 0x76f988da, 0x831153b5,
  0x983e5152, 0xee66dfab, 0xa831c66d, 0x2db43210, 0xb00327c8, 0x98fb213f, 0xbf597fc7, 0xbeef0ee4,
  0xc6e00bf3, 0x3da88fc2, 0xd5a79147, 0x930aa725, 0x06ca6351, 0xe003826f, 0x14292967, 0x0a0e6e70,
  0x27b70a85, 0x46d22ffc, 0x2e1b2138, 0x5c26c926, 0x4d2c6dfc, 0x5ac42aed, 0x53380d13, 0x9d95b3df,
  0x650a7354, 0x8baf63de, 0x766a0abb, 0x3c77b2a8, 0x81c2c92e, 0x47edaee6, 0x92722c85, 0x1482353b,
  0xa2bfe8a1, 0x4cf10364, 0xa81a664b, 0xbc423001, 0xc24b8b70, 0xd0f89791, 0xc76c51a3, 0x0654be30,
  0xd192e819, 0xd6ef5218, 0xd6990624, 0x5565a910, 0xf40e3585, 0x5771202a, 0x106aa070, 0x32bbd1b8,
  0x19a4c116, 0xb8d2d0c8, 0x1e376c08, 0x5141ab53, 0x2748774c, 0xdf8eeb99, 0x34b0bcb5, 0xe19b48a8,
  0x391c0cb3, 0xc5c95a63, 0x4ed8aa4a, 0xe3418acb, 0x5b9cca4f, 0x7763e373, 0x682e6ff3, 0xd6b2b8a3,
  0x748f82ee, 0x5defb2fc, 0x78a5636f, 0x43172f60, 0x84c87814, 0xa1f0ab72, 0x8cc70208, 0x1a6439ec,
  0x90befffa, 0x23631e28, 0xa4506ceb, 0xde82bde9, 0xbef9a3f7, 0xb2c67915, 0xc67178f2, 0xe372532b,
  0xca273ece, 0xea26619c, 0xd186b8c7, 0x21c0c207, 0xeada7dd6, 0xcde0eb1e, 0xf57d4f7f, 0xee6ed178,
  0x06f067aa, 0x72176fba, 0x0a637dc5, 0xa2c898a6, 0x113f9804, 0xbef90dae, 0x1b710b35, 0x131c471b,
  0x28db77f5, 0x23047d84, 0x32caab7b, 0x40c72493, 0x3c9ebe0a, 0x15c9bebc, 0x431d67c4, 0x9c100d4c,
  0x4cc5d4be, 0xcb3e42b6, 0x597f299c, 0xfc657e2a, 0x5fcb6fab, 0x3ad6faec, 0x6c44198c, 0x4a475817,
}

-- Initial hash value, as hi, lo halves
local H0 = {
  0x6a09e667, 0xf3bcc908, 0xbb67ae85, 0x84caa73b, 0x3c6ef372, 0xfe94f82b, 0xa54ff53a, 0x5f1d36f1,
  0x510e527f, 0xade682d1, 0x9b05688c, 0x2b3e6c1f, 0x1f83d9ab, 0xfb41bd6b, 0x5be0cd19, 0x137e2179,
}

-- Runs the compression function on the 128-byte block of s that starts at byte pos. H is the
-- state (8 words as 16 halves: hi, lo, hi, lo, ...), W scratch space for the 80-word schedule.
local function compress(H, W, s, pos)
  for i = 1, 32, 2 do
    local b1, b2, b3, b4, b5, b6, b7, b8 = byte(s, pos, pos + 7)
    W[i] = ((b1 * 256 + b2) * 256 + b3) * 256 + b4
    W[i + 1] = ((b5 * 256 + b6) * 256 + b7) * 256 + b8
    pos = pos + 8
  end

  -- Word t sits at W[2t+1] (hi) and W[2t+2] (lo):
  -- w[t] = s1(w[t-2]) + w[t-7] + s0(w[t-15]) + w[t-16]
  for i = 33, 159, 2 do
    -- s0(x) = rotr(x, 1) ^ rotr(x, 8) ^ (x >> 7), x = w[t-15]
    local xh, xl = W[i - 30], W[i - 29]
    local xh1, xl1, xh8, xl8, xh7, xl7 = xh % 2, xl % 2, xh % 256, xl % 256, xh % 128, xl % 128
    local s0h = bxor((xh - xh1) / 2 + xl1 * 2147483648, (xh - xh8) / 256 + xl8 * 16777216,
      (xh - xh7) / 128)
    local s0l = bxor((xl - xl1) / 2 + xh1 * 2147483648, (xl - xl8) / 256 + xh8 * 16777216,
      (xl - xl7) / 128 + xh7 * 33554432)
    -- s1(y) = rotr(y, 19) ^ rotr(y, 61) ^ (y >> 6), y = w[t-2]
    local yh, yl = W[i - 4], W[i - 3]
    local yh19, yl19, yh29, yl29, yh6, yl6 =
      yh % 524288, yl % 524288, yh % 536870912, yl % 536870912, yh % 64, yl % 64
    local s1h = bxor((yh - yh19) / 524288 + yl19 * 8192, (yl - yl29) / 536870912 + yh29 * 8,
      (yh - yh6) / 64)
    local s1l = bxor((yl - yl19) / 524288 + yh19 * 8192, (yh - yh29) / 536870912 + yl29 * 8,
      (yl - yl6) / 64 + yh6 * 67108864)
    local lo = W[i - 31] + W[i - 13] + s0l % TWO32 + s1l % TWO32
    local l = lo % TWO32
    W[i] = (W[i - 32] + W[i - 14] + s0h + s1h + (lo - l) / TWO32) % TWO32
    W[i + 1] = l
  end

  local ah, al, bh, bl, ch, cl, dh, dl = H[1], H[2], H[3], H[4], H[5], H[6], H[7], H[8]
  local eh, el, fh, fl, gh, gl, hh, hl = H[9], H[10], H[11], H[12], H[13], H[14], H[15], H[16]
  for i = 1, 159, 2 do
    -- S1(e) = rotr(e, 14) ^ rotr(e, 18) ^ rotr(e, 41)
    local eh14, el14, eh18, el18, eh9, el9 =
      eh % 16384, el % 16384, eh % 262144, el % 262144, eh % 512, el % 512
    local s1h = bxor((eh - eh14) / 16384 + el14 * 262144, (eh - eh18) / 262144 + el18 * 16384,
      (el - el9) / 512 + eh9 * 8388608)
    local s1l = bxor((el - el14) / 16384 + eh14 * 262144, (el - el18) / 262144 + eh18 * 16384,
      (eh - eh9) / 512 + el9 * 8388608)
    -- Ch(e, f, g) = (e & f) ^ (~e & g): f where e has a 1, else g. Bit by bit,
    -- f + g - (e ^ f) + (e ^ g) is 2f where e is 1 and 2g where e is 0.
    local chh = (fh + gh - bxor(eh, fh) % TWO32 + bxor(eh, gh) % TWO32) / 2
    local chl = (fl + gl - bxor(el, fl) % TWO32 + bxor(el, gl) % TWO32) / 2
    -- t1 = h + S1(e) + Ch(e, f, g) + K[t] + w[t], left unreduced
    local t1l = hl + s1l % TWO32 + chl + K[i + 1] + W[i + 1]
    local t1h = hh + s1h + chh + K[i] + W[i]
    -- S0(a) = rotr(a, 28) ^ rotr(a, 34) ^ rotr(a, 39)
    local ah28, al28, ah2, al2, ah7, al7 =
      ah % 268435456, al % 268435456, ah % 4, al % 4, ah % 128, al % 128
    local s0h = bxor((ah - ah28) / 268435456 + al28 * 16, (al - al2) / 4 + ah2 * 1073741824,
      (al - al7) / 128 + ah7 * 33554432)
    local s0l = bxor((al - al28) / 268435456 + ah28 * 16, (ah - ah2) / 4 + al2 * 1073741824,
      (ah - ah7) / 128 + al7 * 33554432)
    -- Maj(a, b, c) = (a & b) ^ (a & c) ^ (b & c): the majority bit. Bit by bit,
    -- a + b + c = 2 Maj + (a ^ b ^ c).
    local mjh = (ah + bh + ch - bxor(ah, bh, ch) % TWO32) / 2
    local mjl = (al + bl + cl - bxor(al, bl, cl) % TWO32) / 2
    -- e = d + t1, a = t1 + S0(a) + Maj(a, b, c); the others move down one
    hh, hl, gh, gl, fh, fl = gh, gl, fh, fl, eh, el
    local sum = dl + t1l
    el = sum % TWO32
    eh = (dh + t1h + (sum - el) / TWO32) % TWO32
    dh, dl, ch, cl, bh, bl = ch, cl, bh, bl, ah, al
    sum = t1l + s0l % TWO32 + mjl
    al = sum % TWO32
    ah = (t1h + s0h + mjh + (sum - al) / TWO32) % TWO32
  end

  local lo
  lo = H[2] + al;  H[2] = lo % TWO32;  H[1] = (H[1] + ah + (lo - H[2]) / TWO32) % TWO32
  lo = H[4] + bl;  H[4] = lo % TWO32;  H[3] = (H[3] + bh + (lo - H[4]) / TWO32) % TWO32
  lo = H[6] + cl;  H[6] = lo % TWO32;  H[5] = (H[5] + ch + (lo - H[6]) / TWO32) % TWO32
  lo = H[8] + dl;  H[8] = lo % TWO32;  H[7] = (H[7] + dh + (lo - H[8]) / TWO32) % TWO32
  lo = H[10] + el; H[10] = lo % TWO32; H[9] = (H[9] + eh + (lo - H[10]) / TWO32) % TWO32
  lo = H[12] + fl; H[12] = lo % TWO32; H[11] = (H[11] + fh + (lo - H[12]) / TWO32) % TWO32
  lo = H[14] + gl; H[14] = lo % TWO32; H[13] = (H[13] + gh + (lo - H[14]) / TWO32) % TWO32
  lo = H[16] + hl; H[16] = lo % TWO32; H[15] = (H[15] + hh + (lo - H[16]) / TWO32) % TWO32
end

-- Work units per 128-byte block (see Crypto.SLICE)
local COST_BLOCK = 340

-- SHA-512 of msg as 64 bytes (numbers 0..255). Calls tick after each block.
local function sha512bytes(msg, tick)
  local H, W = {}, {}
  for i = 1, 16 do H[i] = H0[i] end
  local len = #msg
  local full = len - len % 128
  for pos = 1, full, 128 do
    compress(H, W, msg, pos)
    tick(COST_BLOCK)
  end
  -- The rest of msg, a 1 bit, zeros, and the length in bits as 16 bytes, filling 1 or 2 blocks
  local bits, lengthBytes = len * 8, {}
  for i = 16, 1, -1 do
    local b = bits % 256
    lengthBytes[i] = b
    bits = (bits - b) / 256
  end
  local rest = len - full
  local tail = sub(msg, full + 1) .. "\128" .. rep("\0", (rest < 112 and 111 or 239) - rest)
    .. char(unpack(lengthBytes))
  for pos = 1, #tail, 128 do
    compress(H, W, tail, pos)
    tick(COST_BLOCK)
  end

  local out = {}
  for i = 1, 16 do
    local v = H[i]
    local b4 = v % 256
    v = (v - b4) / 256
    local b3 = v % 256
    v = (v - b3) / 256
    local b2 = v % 256
    out[4 * i - 3], out[4 * i - 2], out[4 * i - 1], out[4 * i] = (v - b2) / 256, b2, b3, b4
  end
  return out
end

function Crypto.sha512(msg)
  return char(unpack(sha512bytes(msg, noop)))
end

---------------------------------------------------------------------------------------------------
-- The field GF(p), p = 2^255 - 19
--
-- An element is a table of 16 limbs, least significant first: { l1, ..., l16 } is
-- l1 + l2 * 2^16 + ... + l16 * 2^240. Between reductions limbs may stray a little outside
-- 0 .. 65535, even below 0; fcanon gives the unique form. fmul and fsqr return limbs within
-- -16 .. 65551, and the formulas below only add or subtract a few of those before the next
-- multiplication, so inputs to fmul stay below 2^18 in size: a product column is below
-- 16 * 2^36, and folding the top half down (2^256 = 38 mod p) keeps it below 2^46.

local function gf(a)
  local o = { 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0 }
  if a then
    for i = 1, 16 do o[i] = a[i] end
  end
  return o
end

local ZERO = gf()
local ONE = gf()
ONE[1] = 1

-- Curve constants
local D = { 0x78a3, 0x1359, 0x4dca, 0x75eb, 0xd8ab, 0x4141, 0x0a4d, 0x0070,
            0xe898, 0x7779, 0x4079, 0x8cc7, 0xfe73, 0x2b6f, 0x6cee, 0x5203 } -- d = -121665/121666
local D2 = { 0xf159, 0x26b2, 0x9b94, 0xebd6, 0xb156, 0x8283, 0x149a, 0x00e0,
             0xd130, 0xeef3, 0x80f2, 0x198e, 0xfce7, 0x56df, 0xd9dc, 0x2406 } -- 2d
local SQRTM1 = { 0xa0b0, 0x4a0e, 0x1b27, 0xc4ee, 0xe478, 0xad2f, 0x1806, 0x2f43,
                 0xd7a7, 0x3dfb, 0x0099, 0x2b4d, 0xdf0b, 0x4fc1, 0x2480, 0x2b83 } -- sqrt(-1)
local BX = { 0xd51a, 0x8f25, 0x2d60, 0xc956, 0xa7b2, 0x9525, 0xc760, 0x692c,
             0xdc5c, 0xfdd6, 0xe231, 0xc0a4, 0x53fe, 0xcd6e, 0x36d3, 0x2169 } -- base point x
local BY = { 0x6658, 0x6666, 0x6666, 0x6666, 0x6666, 0x6666, 0x6666, 0x6666,
             0x6666, 0x6666, 0x6666, 0x6666, 0x6666, 0x6666, 0x6666, 0x6666 } -- base point y = 4/5
local P = { 0xffed, 0xffff, 0xffff, 0xffff, 0xffff, 0xffff, 0xffff, 0xffff,
            0xffff, 0xffff, 0xffff, 0xffff, 0xffff, 0xffff, 0xffff, 0x7fff } -- p itself

local function fcopy(o, a)
  for i = 1, 16 do o[i] = a[i] end
end

local function fadd(o, a, b)
  o[1], o[2], o[3], o[4] = a[1] + b[1], a[2] + b[2], a[3] + b[3], a[4] + b[4]
  o[5], o[6], o[7], o[8] = a[5] + b[5], a[6] + b[6], a[7] + b[7], a[8] + b[8]
  o[9], o[10], o[11], o[12] = a[9] + b[9], a[10] + b[10], a[11] + b[11], a[12] + b[12]
  o[13], o[14], o[15], o[16] = a[13] + b[13], a[14] + b[14], a[15] + b[15], a[16] + b[16]
end

local function fsub(o, a, b)
  o[1], o[2], o[3], o[4] = a[1] - b[1], a[2] - b[2], a[3] - b[3], a[4] - b[4]
  o[5], o[6], o[7], o[8] = a[5] - b[5], a[6] - b[6], a[7] - b[7], a[8] - b[8]
  o[9], o[10], o[11], o[12] = a[9] - b[9], a[10] - b[10], a[11] - b[11], a[12] - b[12]
  o[13], o[14], o[15], o[16] = a[13] - b[13], a[14] - b[14], a[15] - b[15], a[16] - b[16]
end

-- o = a * b. Column k of the schoolbook product gathers a_i * b_j with i + j = k, and columns
-- 16..30 fold into 0..14 times 38. Then one carry pass (the carry out of the top limb wraps to
-- the bottom times 38), and two more carries for the wrapped amount. o may be a or b.
local function fmul(o, a, b)
  local a0, a1, a2, a3, a4, a5, a6, a7 = a[1], a[2], a[3], a[4], a[5], a[6], a[7], a[8]
  local a8, a9, a10, a11, a12, a13, a14, a15 = a[9], a[10], a[11], a[12], a[13], a[14], a[15], a[16]
  local b0, b1, b2, b3, b4, b5, b6, b7 = b[1], b[2], b[3], b[4], b[5], b[6], b[7], b[8]
  local b8, b9, b10, b11, b12, b13, b14, b15 = b[9], b[10], b[11], b[12], b[13], b[14], b[15], b[16]
  local c0 = a0*b0
    + 38 * (a1*b15 + a2*b14 + a3*b13 + a4*b12 + a5*b11 + a6*b10 + a7*b9 + a8*b8 + a9*b7 + a10*b6
      + a11*b5 + a12*b4 + a13*b3 + a14*b2 + a15*b1)
  local c1 = a0*b1 + a1*b0
    + 38 * (a2*b15 + a3*b14 + a4*b13 + a5*b12 + a6*b11 + a7*b10 + a8*b9 + a9*b8 + a10*b7 + a11*b6
      + a12*b5 + a13*b4 + a14*b3 + a15*b2)
  local c2 = a0*b2 + a1*b1 + a2*b0
    + 38 * (a3*b15 + a4*b14 + a5*b13 + a6*b12 + a7*b11 + a8*b10 + a9*b9 + a10*b8 + a11*b7 + a12*b6
      + a13*b5 + a14*b4 + a15*b3)
  local c3 = a0*b3 + a1*b2 + a2*b1 + a3*b0
    + 38 * (a4*b15 + a5*b14 + a6*b13 + a7*b12 + a8*b11 + a9*b10 + a10*b9 + a11*b8 + a12*b7 + a13*b6
      + a14*b5 + a15*b4)
  local c4 = a0*b4 + a1*b3 + a2*b2 + a3*b1 + a4*b0
    + 38 * (a5*b15 + a6*b14 + a7*b13 + a8*b12 + a9*b11 + a10*b10 + a11*b9 + a12*b8 + a13*b7 + a14*b6
      + a15*b5)
  local c5 = a0*b5 + a1*b4 + a2*b3 + a3*b2 + a4*b1 + a5*b0
    + 38 * (a6*b15 + a7*b14 + a8*b13 + a9*b12 + a10*b11 + a11*b10 + a12*b9 + a13*b8 + a14*b7 + a15*b6)
  local c6 = a0*b6 + a1*b5 + a2*b4 + a3*b3 + a4*b2 + a5*b1 + a6*b0
    + 38 * (a7*b15 + a8*b14 + a9*b13 + a10*b12 + a11*b11 + a12*b10 + a13*b9 + a14*b8 + a15*b7)
  local c7 = a0*b7 + a1*b6 + a2*b5 + a3*b4 + a4*b3 + a5*b2 + a6*b1 + a7*b0
    + 38 * (a8*b15 + a9*b14 + a10*b13 + a11*b12 + a12*b11 + a13*b10 + a14*b9 + a15*b8)
  local c8 = a0*b8 + a1*b7 + a2*b6 + a3*b5 + a4*b4 + a5*b3 + a6*b2 + a7*b1 + a8*b0
    + 38 * (a9*b15 + a10*b14 + a11*b13 + a12*b12 + a13*b11 + a14*b10 + a15*b9)
  local c9 = a0*b9 + a1*b8 + a2*b7 + a3*b6 + a4*b5 + a5*b4 + a6*b3 + a7*b2 + a8*b1 + a9*b0
    + 38 * (a10*b15 + a11*b14 + a12*b13 + a13*b12 + a14*b11 + a15*b10)
  local c10 = a0*b10 + a1*b9 + a2*b8 + a3*b7 + a4*b6 + a5*b5 + a6*b4 + a7*b3 + a8*b2 + a9*b1
    + a10*b0
    + 38 * (a11*b15 + a12*b14 + a13*b13 + a14*b12 + a15*b11)
  local c11 = a0*b11 + a1*b10 + a2*b9 + a3*b8 + a4*b7 + a5*b6 + a6*b5 + a7*b4 + a8*b3 + a9*b2
    + a10*b1 + a11*b0
    + 38 * (a12*b15 + a13*b14 + a14*b13 + a15*b12)
  local c12 = a0*b12 + a1*b11 + a2*b10 + a3*b9 + a4*b8 + a5*b7 + a6*b6 + a7*b5 + a8*b4 + a9*b3
    + a10*b2 + a11*b1 + a12*b0
    + 38 * (a13*b15 + a14*b14 + a15*b13)
  local c13 = a0*b13 + a1*b12 + a2*b11 + a3*b10 + a4*b9 + a5*b8 + a6*b7 + a7*b6 + a8*b5 + a9*b4
    + a10*b3 + a11*b2 + a12*b1 + a13*b0
    + 38 * (a14*b15 + a15*b14)
  local c14 = a0*b14 + a1*b13 + a2*b12 + a3*b11 + a4*b10 + a5*b9 + a6*b8 + a7*b7 + a8*b6 + a9*b5
    + a10*b4 + a11*b3 + a12*b2 + a13*b1 + a14*b0
    + 38 * (a15*b15)
  local c15 = a0*b15 + a1*b14 + a2*b13 + a3*b12 + a4*b11 + a5*b10 + a6*b9 + a7*b8 + a8*b7 + a9*b6
    + a10*b5 + a11*b4 + a12*b3 + a13*b2 + a14*b1 + a15*b0
  local r
  r = c0 % 65536; c1 = c1 + (c0 - r) / 65536; c0 = r
  r = c1 % 65536; c2 = c2 + (c1 - r) / 65536; c1 = r
  r = c2 % 65536; c3 = c3 + (c2 - r) / 65536; c2 = r
  r = c3 % 65536; c4 = c4 + (c3 - r) / 65536; c3 = r
  r = c4 % 65536; c5 = c5 + (c4 - r) / 65536; c4 = r
  r = c5 % 65536; c6 = c6 + (c5 - r) / 65536; c5 = r
  r = c6 % 65536; c7 = c7 + (c6 - r) / 65536; c6 = r
  r = c7 % 65536; c8 = c8 + (c7 - r) / 65536; c7 = r
  r = c8 % 65536; c9 = c9 + (c8 - r) / 65536; c8 = r
  r = c9 % 65536; c10 = c10 + (c9 - r) / 65536; c9 = r
  r = c10 % 65536; c11 = c11 + (c10 - r) / 65536; c10 = r
  r = c11 % 65536; c12 = c12 + (c11 - r) / 65536; c11 = r
  r = c12 % 65536; c13 = c13 + (c12 - r) / 65536; c12 = r
  r = c13 % 65536; c14 = c14 + (c13 - r) / 65536; c13 = r
  r = c14 % 65536; c15 = c15 + (c14 - r) / 65536; c14 = r
  r = c15 % 65536; c0 = c0 + 38 * ((c15 - r) / 65536); c15 = r
  r = c0 % 65536; c1 = c1 + (c0 - r) / 65536; c0 = r
  r = c1 % 65536; c2 = c2 + (c1 - r) / 65536; c1 = r
  o[1], o[2], o[3], o[4], o[5], o[6], o[7], o[8] = c0, c1, c2, c3, c4, c5, c6, c7
  o[9], o[10], o[11], o[12], o[13], o[14], o[15], o[16] = c8, c9, c10, c11, c12, c13, c14, c15
end

-- o = a^2: fmul with each cross product a_i * a_j (i < j) counted once, as d_i * a_j where
-- d_i = 2 * a_i. o may be a.
local function fsqr(o, a)
  local a0, a1, a2, a3, a4, a5, a6, a7 = a[1], a[2], a[3], a[4], a[5], a[6], a[7], a[8]
  local a8, a9, a10, a11, a12, a13, a14, a15 = a[9], a[10], a[11], a[12], a[13], a[14], a[15], a[16]
  local d0, d1, d2, d3, d4, d5, d6, d7 =
    a0 + a0, a1 + a1, a2 + a2, a3 + a3, a4 + a4, a5 + a5, a6 + a6, a7 + a7
  local d8, d9, d10, d11, d12, d13, d14 =
    a8 + a8, a9 + a9, a10 + a10, a11 + a11, a12 + a12, a13 + a13, a14 + a14
  local c0 = a0*a0
    + 38 * (d1*a15 + d2*a14 + d3*a13 + d4*a12 + d5*a11 + d6*a10 + d7*a9 + a8*a8)
  local c1 = d0*a1
    + 38 * (d2*a15 + d3*a14 + d4*a13 + d5*a12 + d6*a11 + d7*a10 + d8*a9)
  local c2 = d0*a2 + a1*a1
    + 38 * (d3*a15 + d4*a14 + d5*a13 + d6*a12 + d7*a11 + d8*a10 + a9*a9)
  local c3 = d0*a3 + d1*a2
    + 38 * (d4*a15 + d5*a14 + d6*a13 + d7*a12 + d8*a11 + d9*a10)
  local c4 = d0*a4 + d1*a3 + a2*a2
    + 38 * (d5*a15 + d6*a14 + d7*a13 + d8*a12 + d9*a11 + a10*a10)
  local c5 = d0*a5 + d1*a4 + d2*a3
    + 38 * (d6*a15 + d7*a14 + d8*a13 + d9*a12 + d10*a11)
  local c6 = d0*a6 + d1*a5 + d2*a4 + a3*a3
    + 38 * (d7*a15 + d8*a14 + d9*a13 + d10*a12 + a11*a11)
  local c7 = d0*a7 + d1*a6 + d2*a5 + d3*a4
    + 38 * (d8*a15 + d9*a14 + d10*a13 + d11*a12)
  local c8 = d0*a8 + d1*a7 + d2*a6 + d3*a5 + a4*a4
    + 38 * (d9*a15 + d10*a14 + d11*a13 + a12*a12)
  local c9 = d0*a9 + d1*a8 + d2*a7 + d3*a6 + d4*a5
    + 38 * (d10*a15 + d11*a14 + d12*a13)
  local c10 = d0*a10 + d1*a9 + d2*a8 + d3*a7 + d4*a6 + a5*a5
    + 38 * (d11*a15 + d12*a14 + a13*a13)
  local c11 = d0*a11 + d1*a10 + d2*a9 + d3*a8 + d4*a7 + d5*a6
    + 38 * (d12*a15 + d13*a14)
  local c12 = d0*a12 + d1*a11 + d2*a10 + d3*a9 + d4*a8 + d5*a7 + a6*a6
    + 38 * (d13*a15 + a14*a14)
  local c13 = d0*a13 + d1*a12 + d2*a11 + d3*a10 + d4*a9 + d5*a8 + d6*a7
    + 38 * (d14*a15)
  local c14 = d0*a14 + d1*a13 + d2*a12 + d3*a11 + d4*a10 + d5*a9 + d6*a8 + a7*a7
    + 38 * (a15*a15)
  local c15 = d0*a15 + d1*a14 + d2*a13 + d3*a12 + d4*a11 + d5*a10 + d6*a9 + d7*a8
  local r
  r = c0 % 65536; c1 = c1 + (c0 - r) / 65536; c0 = r
  r = c1 % 65536; c2 = c2 + (c1 - r) / 65536; c1 = r
  r = c2 % 65536; c3 = c3 + (c2 - r) / 65536; c2 = r
  r = c3 % 65536; c4 = c4 + (c3 - r) / 65536; c3 = r
  r = c4 % 65536; c5 = c5 + (c4 - r) / 65536; c4 = r
  r = c5 % 65536; c6 = c6 + (c5 - r) / 65536; c5 = r
  r = c6 % 65536; c7 = c7 + (c6 - r) / 65536; c6 = r
  r = c7 % 65536; c8 = c8 + (c7 - r) / 65536; c7 = r
  r = c8 % 65536; c9 = c9 + (c8 - r) / 65536; c8 = r
  r = c9 % 65536; c10 = c10 + (c9 - r) / 65536; c9 = r
  r = c10 % 65536; c11 = c11 + (c10 - r) / 65536; c10 = r
  r = c11 % 65536; c12 = c12 + (c11 - r) / 65536; c11 = r
  r = c12 % 65536; c13 = c13 + (c12 - r) / 65536; c12 = r
  r = c13 % 65536; c14 = c14 + (c13 - r) / 65536; c13 = r
  r = c14 % 65536; c15 = c15 + (c14 - r) / 65536; c14 = r
  r = c15 % 65536; c0 = c0 + 38 * ((c15 - r) / 65536); c15 = r
  r = c0 % 65536; c1 = c1 + (c0 - r) / 65536; c0 = r
  r = c1 % 65536; c2 = c2 + (c1 - r) / 65536; c1 = r
  o[1], o[2], o[3], o[4], o[5], o[6], o[7], o[8] = c0, c1, c2, c3, c4, c5, c6, c7
  o[9], o[10], o[11], o[12], o[13], o[14], o[15], o[16] = c8, c9, c10, c11, c12, c13, c14, c15
end

-- o = a^(2^n), n >= 1
local function fsqrn(o, a, n)
  fsqr(o, a)
  for _ = 2, n do fsqr(o, o) end
end

-- Work units for a squaring (see Crypto.SLICE; a multiplication is 1)
local COST_SQR = 0.7

-- Returns a^(2^250 - 1) and a^11, the shared start of finv and fpow22523 (ref10's chain).
local function pow2250m1(a, tick)
  local a11, t0, t1, t2 = gf(), gf(), gf(), gf()
  fsqr(t0, a)                              -- a^2
  fsqrn(t1, t0, 2)                         -- a^8
  fmul(t1, t1, a)                          -- a^9
  fmul(a11, t1, t0)                        -- a^11
  fsqr(t0, a11)                            -- a^22
  fmul(t0, t0, t1)                         -- a^31 = a^(2^5 - 1)
  fsqrn(t1, t0, 5); fmul(t0, t1, t0)       -- a^(2^10 - 1)
  fsqrn(t1, t0, 10); fmul(t1, t1, t0)      -- a^(2^20 - 1)
  fsqrn(t2, t1, 20); fmul(t1, t2, t1)      -- a^(2^40 - 1)
  fsqrn(t1, t1, 10); fmul(t0, t1, t0)      -- a^(2^50 - 1)
  tick(49 * COST_SQR + 7)
  fsqrn(t1, t0, 50); fmul(t1, t1, t0)      -- a^(2^100 - 1)
  tick(50 * COST_SQR + 1)
  fsqrn(t2, t1, 100); fmul(t1, t2, t1)     -- a^(2^200 - 1)
  tick(100 * COST_SQR + 1)
  fsqrn(t1, t1, 50); fmul(t0, t1, t0)      -- a^(2^250 - 1)
  tick(50 * COST_SQR + 1)
  return t0, a11
end

-- o = 1/a = a^(p - 2) = a^(2^255 - 21)
local function finv(o, a, tick)
  local t, a11 = pow2250m1(a, tick)
  fsqrn(t, t, 5)                           -- a^(2^255 - 32)
  fmul(o, t, a11)
end

-- o = a^((p - 5) / 8) = a^(2^252 - 3), the power used for square roots
local function fpow22523(o, a, tick)
  local t = pow2250m1(a, tick)
  fsqrn(t, t, 2)                           -- a^(2^252 - 4)
  fmul(o, t, a)
end

-- o = a fully reduced: every limb in 0 .. 65535 and the value in 0 .. p-1. o may be a.
local function fcanon(o, a)
  local t = gf(a)
  local c
  repeat
    for i = 1, 15 do
      local r = t[i] % 65536
      t[i + 1] = t[i + 1] + (t[i] - r) / 65536
      t[i] = r
    end
    local r = t[16] % 65536
    c = (t[16] - r) / 65536
    t[16] = r
    t[1] = t[1] + 38 * c
  until c == 0
  -- Now 0 <= t < 2^256 < 3p: subtract p while t >= p
  for _ = 1, 2 do
    local m, borrow = {}, 0
    for i = 1, 16 do
      local v = t[i] - P[i] + borrow
      local r = v % 65536
      m[i] = r
      borrow = (v - r) / 65536
    end
    if borrow == 0 then t = m end
  end
  fcopy(o, t)
end

local function feq(a, b)
  local x, y = gf(), gf()
  fcanon(x, a)
  fcanon(y, b)
  for i = 1, 16 do
    if x[i] ~= y[i] then return false end
  end
  return true
end

---------------------------------------------------------------------------------------------------
-- Points on the curve -x^2 + y^2 = 1 + d x^2 y^2 (ref10's representations)
--
--   extended   { X, Y, Z, T }      x = X/Z, y = Y/Z, x*y = T/Z
--   projective { X, Y, Z }         x = X/Z, y = Y/Z
--   completed  { X, Y, Z, T }      x = X/Z, y = Y/T  (what dbl and add produce)
--   cached     { Y+X, Y-X, Z, 2dT } of an extended point, ready to be added

local function point()
  return { gf(), gf(), gf(), gf() }
end

-- r (completed) = 2p, for p projective or extended. t0 is scratch; r must not be p.
local function pdbl(r, p, t0)
  local X, Y, Z, T = r[1], r[2], r[3], r[4]
  fsqr(X, p[1])           -- X1^2
  fsqr(Z, p[2])           -- Y1^2
  fsqr(T, p[3])
  fadd(T, T, T)           -- 2 Z1^2
  fadd(Y, p[1], p[2])
  fsqr(t0, Y)             -- (X1 + Y1)^2
  fadd(Y, Z, X)           -- Y1^2 + X1^2
  fsub(Z, Z, X)           -- Y1^2 - X1^2
  fsub(X, t0, Y)          -- 2 X1 Y1
  fsub(T, T, Z)           -- 2 Z1^2 - (Y1^2 - X1^2)
end

-- r (completed) = p + q, or p - q if neg; p extended, q cached. t0 is scratch; r must not be p.
local function padd(r, p, q, neg, t0)
  local X, Y, Z, T = r[1], r[2], r[3], r[4]
  fadd(X, p[2], p[1])     -- Y1 + X1
  fsub(Y, p[2], p[1])     -- Y1 - X1
  if neg then             -- -q has Y+X and Y-X swapped and T negated
    fmul(Z, X, q[2])
    fmul(Y, Y, q[1])
  else
    fmul(Z, X, q[1])      -- A = (Y1 + X1)(Y2 + X2)
    fmul(Y, Y, q[2])      -- B = (Y1 - X1)(Y2 - X2)
  end
  fmul(T, q[4], p[4])     -- C = 2d T1 T2
  fmul(X, p[3], q[3])
  fadd(t0, X, X)          -- D = 2 Z1 Z2
  fsub(X, Z, Y)           -- A - B
  fadd(Y, Z, Y)           -- A + B
  if neg then
    fsub(Z, t0, T)
    fadd(T, t0, T)
  else
    fadd(Z, t0, T)        -- D + C
    fsub(T, t0, T)        -- D - C
  end
end

-- Completed p to projective r
local function toProjective(r, p)
  fmul(r[1], p[1], p[4])
  fmul(r[2], p[2], p[3])
  fmul(r[3], p[3], p[4])
end

-- Completed p to extended r
local function toExtended(r, p)
  fmul(r[1], p[1], p[4])
  fmul(r[2], p[2], p[3])
  fmul(r[3], p[3], p[4])
  fmul(r[4], p[1], p[2])
end

local function toCached(p)
  local c = { gf(), gf(), gf(p[3]), gf() }
  fadd(c[1], p[2], p[1])
  fsub(c[2], p[2], p[1])
  fmul(c[4], p[4], D2)
  return c
end

-- Cached p, 3p, 5p, ..., 15p for p extended
local function oddMultiples(p)
  local tbl = { toCached(p) }
  local t, p2, u, t0 = point(), point(), point(), gf()
  pdbl(t, p, t0)
  toExtended(p2, t)
  for i = 2, 8 do
    padd(t, p2, tbl[i - 1], false, t0)
    toExtended(u, t)
    tbl[i] = toCached(u)
  end
  return tbl
end

-- Work units to build a table with oddMultiples, and for the part of decodePoint outside its
-- square root
local COST_TABLE, COST_DECODE = 90, 35

-- The odd multiples of the base point B, made on first use and shared from then on
local baseTable
local function getBaseTable(tick)
  if not baseTable then
    local B = { gf(BX), gf(BY), gf(ONE), gf() }
    fmul(B[4], B[1], B[2])
    baseTable = oddMultiples(B)
    tick(COST_TABLE)
  end
  return baseTable
end

-- Decodes bytes k+1 .. k+32 of s (RFC 8032 5.1.3) into p as an extended point with Z = 1.
-- Returns false, with p unspecified, unless they encode a curve point: y must be below p, x^2
-- must have a square root, and x = 0 must come with a clear sign bit.
local function decodePoint(p, s, k, tick)
  local X, Y = p[1], p[2]
  for i = 1, 16 do
    local lo, hi = byte(s, k + 2 * i - 1, k + 2 * i)
    Y[i] = lo + 256 * hi
  end
  local sign = 0
  if Y[16] >= 32768 then
    sign = 1
    Y[16] = Y[16] - 32768
  end
  if Y[16] == 0x7fff and Y[1] >= 0xffed then  -- y >= p unless a middle limb is below 0xffff
    local below = false
    for i = 2, 15 do
      if Y[i] ~= 0xffff then below = true break end
    end
    if not below then return false end
  end

  -- x^2 = u/v with u = y^2 - 1 and v = d y^2 + 1. The candidate root is
  -- x = u v^3 (u v^7)^((p-5)/8); then v x^2 is u (done), -u (x times sqrt(-1) is the root),
  -- or neither (no root: not a point).
  local u, v, v3, x, chk = gf(), gf(), gf(), gf(), gf()
  fsqr(u, Y)
  fmul(v, u, D)
  fsub(u, u, ONE)
  fadd(v, v, ONE)
  fsqr(v3, v)
  fmul(v3, v3, v)            -- v^3
  fsqr(x, v3)
  fmul(x, x, v)
  fmul(x, x, u)              -- u v^7
  fpow22523(x, x, tick)
  fmul(x, x, v3)
  fmul(x, x, u)
  fsqr(chk, x)
  fmul(chk, chk, v)          -- v x^2
  if not feq(chk, u) then
    fadd(chk, chk, u)
    if not feq(chk, ZERO) then return false end
    fmul(x, x, SQRTM1)
  end
  fcanon(x, x)
  if x[1] % 2 ~= sign then
    if feq(x, ZERO) then return false end
    fsub(x, ZERO, x)
  end
  fcopy(X, x)
  fcopy(p[3], ONE)
  fmul(p[4], X, Y)
  tick(COST_DECODE)
  return true
end

-- The 32-byte encoding (RFC 8032 5.1.2) of projective r
local function encodePoint(r, tick)
  local zi, x, y = gf(), gf(), gf()
  finv(zi, r[3], tick)
  fmul(x, r[1], zi)
  fcanon(x, x)
  fmul(y, r[2], zi)
  fcanon(y, y)
  local out = {}
  for i = 1, 16 do
    local v = y[i]
    local lo = v % 256
    out[2 * i - 1], out[2 * i] = lo, (v - lo) / 256
  end
  out[32] = out[32] + 128 * (x[1] % 2)
  return char(unpack(out))
end

---------------------------------------------------------------------------------------------------
-- Scalars: numbers mod L = 2^252 + 27742317777372353535851937790883648493, as tables of bytes,
-- least significant first

local L = { 0xed, 0xd3, 0xf5, 0x5c, 0x1a, 0x63, 0x12, 0x58, 0xd6, 0x9c, 0xf7, 0xa2, 0xde, 0xf9,
            0xde, 0x14, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0x10 }

-- True if the 32 bytes in s are a number below L
local function belowL(s)
  for i = 32, 1, -1 do
    if s[i] ~= L[i] then return s[i] < L[i] end
  end
  return false
end

-- The 64 bytes in x (a SHA-512 digest read as a little-endian number) mod L, as 32 bytes.
-- TweetNaCl's modL, shifted to 1-based indexes. Bytes go negative on the way, so its >> and &
-- are floor division and % here. x is used up.
local function modL(x)
  for i = 64, 33, -1 do
    -- x[i] * 256^(i-1) = x[i] * 16 * 2^252 * 256^(i-33), and 2^252 = -(L - 2^252) mod L
    local carry, xi = 0, x[i]
    for j = i - 32, i - 13 do
      local v = x[j] + carry - 16 * xi * L[j - i + 33]
      carry = floor((v + 128) / 256)
      x[j] = v - carry * 256
    end
    x[i - 12] = x[i - 12] + carry
    x[i] = 0
  end
  -- Take out the multiple of L held in the top 4 bits of x[32], then add L back if below 0
  local carry, top = 0, floor(x[32] / 16)
  for j = 1, 32 do
    local v = x[j] + carry - top * L[j]
    carry = floor(v / 256)
    x[j] = v - carry * 256
  end
  for j = 1, 32 do x[j] = x[j] - carry * L[j] end
  local r = {}
  for j = 1, 32 do
    local v = x[j]
    local lo = v % 256
    x[j + 1] = x[j + 1] + (v - lo) / 256
    r[j] = lo
  end
  return r
end

-- Signed sliding-window digits of the 256-bit number in bytes a[1..32]: r[1..256], each 0 or odd
-- in -15..15, with the sum of r[i] * 2^(i-1) equal to the number. ref10's slide().
local POW2 = { 2, 4, 8, 16, 32, 64 }
local function slide(a)
  local r = {}
  for i = 1, 32 do
    local v = a[i]
    for j = 8 * i - 7, 8 * i do
      local b = v % 2
      r[j] = b
      v = (v - b) / 2
    end
  end
  for i = 1, 256 do
    if r[i] ~= 0 then
      for b = 1, 6 do
        if i + b > 256 then break end
        if r[i + b] ~= 0 then
          local step = r[i + b] * POW2[b]
          if r[i] + step <= 15 then
            r[i] = r[i] + step
            r[i + b] = 0
          elseif r[i] - step >= -15 then
            r[i] = r[i] - step
            for k = i + b, 256 do
              if r[k] == 0 then
                r[k] = 1
                break
              end
              r[k] = 0
            end
          else
            break
          end
        end
      end
    end
  end
  return r
end

-- Work units for one doubling, and for each addition after it, in doubleScalarMult
local COST_DBL, COST_ADD = 7, 10

-- Projective a*P + b*B, where Pt and Bt are oddMultiples of P and B, and a and b are 32 bytes
-- each. One shared run of doublings, adding a table entry wherever a window digit isn't 0.
local function doubleScalarMult(a, Pt, b, Bt, tick)
  local ad, bd = slide(a), slide(b)
  local r = { gf(), gf(ONE), gf(ONE) }   -- the neutral point (0, 1)
  local t, u, t0 = point(), point(), gf()
  local i = 256
  while i > 0 and ad[i] == 0 and bd[i] == 0 do i = i - 1 end
  while i > 0 do
    pdbl(t, r, t0)
    local cost = COST_DBL
    -- digit d > 0 adds table entry (d + 1) / 2, which holds d times the point; d < 0 subtracts
    local da, db = ad[i], bd[i]
    if da ~= 0 then
      toExtended(u, t)
      if da > 0 then
        padd(t, u, Pt[(da + 1) / 2], false, t0)
      else
        padd(t, u, Pt[(1 - da) / 2], true, t0)
      end
      cost = cost + COST_ADD
    end
    if db ~= 0 then
      toExtended(u, t)
      if db > 0 then
        padd(t, u, Bt[(db + 1) / 2], false, t0)
      else
        padd(t, u, Bt[(1 - db) / 2], true, t0)
      end
      cost = cost + COST_ADD
    end
    toProjective(r, t)
    tick(cost)
    i = i - 1
  end
  return r
end

---------------------------------------------------------------------------------------------------
-- Verification (RFC 8032 5.1.7)

local function verifyCore(pub, msg, sig, tick)
  if type(pub) ~= "string" or type(msg) ~= "string" or type(sig) ~= "string"
    or #pub ~= 32 or #sig ~= 64 then
    return false
  end
  local s = { byte(sig, 33, 64) }
  if not belowL(s) then return false end
  local A = point()
  if not decodePoint(A, pub, 0, tick) then return false end
  fsub(A[1], ZERO, A[1])                   -- A becomes -A
  fsub(A[4], ZERO, A[4])
  local At = oddMultiples(A)
  tick(COST_TABLE)
  local Bt = getBaseTable(tick)
  local R = sub(sig, 1, 32)
  local k = modL(sha512bytes(R .. pub .. msg, tick))
  -- [S]B - [k]A must be R. Comparing encodings also turns away an R that isn't a valid,
  -- canonical encoding, since no point encodes to one.
  return encodePoint(doubleScalarMult(k, At, s, Bt, tick), tick) == R
end

function Crypto.verify(publicKey, message, signature)
  return verifyCore(publicKey, message, signature, noop)
end

function Crypto.verifier(publicKey, message, signature)
  local result
  local co = cocreate(function()
    local done = 0
    return verifyCore(publicKey, message, signature, function(units)
      done = done + units
      if done >= Crypto.SLICE then
        done = 0
        yield()
      end
    end)
  end)
  return function()
    if result == nil then
      local ok, value = coresume(co)
      if not ok then
        result = false
        error(value, 0)
      end
      if costatus(co) == "dead" then result = value == true end
    end
    return result
  end
end

---------------------------------------------------------------------------------------------------
-- Hex

function Crypto.hex(bin)
  return (gsub(bin, ".", function(c) return format("%02x", byte(c)) end))
end

function Crypto.unhex(hex)
  if type(hex) ~= "string" or #hex % 2 ~= 0 or find(hex, "%X") then return nil end
  return (gsub(hex, "%x%x", function(cc) return char(tonumber(cc, 16)) end))
end
