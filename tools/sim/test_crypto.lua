-- test_crypto.lua: SHA-512 and Ed25519 signature checks (Sync/Crypto.lua).
-- Run from the project root: lua tools/sim/run.lua crypto (or lua tools/sim/test_crypto.lua)
-- Should pass with any mix of PINTO_FLOATS=1 and PINTO_BIT_SIGNED=1.

package.path = "tools/sim/?.lua;" .. package.path
local H = require("harness")
local ns = H.load({ "Sync/Crypto.lua" })
local C = ns.Crypto

local fixtures = dofile("tools/sim/fixtures/crypto_vectors.lua")

local function unhex(h)
  return H.ok(C.unhex(h), "bad hex in the test data")
end

-- Bytes (i * 37 + 11) % 256 for i = 0 .. n-1, the same pattern as the expected digests below
local function pattern(n)
  local t = {}
  for i = 0, n - 1 do t[i + 1] = string.char((i * 37 + 11) % 256) end
  return table.concat(t)
end

-- Calls step until it answers; returns the answer and the number of calls
local function runSteps(step)
  local n = 0
  while true do
    n = n + 1
    local r = step()
    if r ~= nil then return r, n end
    if n > 100000 then error("the verifier never finished") end
  end
end

-- Runs fn with Crypto.SLICE set to slice, restoring it afterwards even if fn fails
local function withSlice(slice, fn)
  local saved = C.SLICE
  C.SLICE = slice
  local ok, err = pcall(fn)
  C.SLICE = saved
  if not ok then error(err, 0) end
end

-- Checks verify and a stepped verifier against the expected answer
local function check(pub, msg, sig, want)
  H.eq(C.verify(pub, msg, sig), want, "verify")
  local step = C.verifier(pub, msg, sig)
  local got = runSteps(step)
  H.eq(got, want, "verifier")
  H.eq(step(), want, "verifier, called again after finishing")
end

---------------------------------------------------------------------------------------------------
-- SHA-512

H.test("sha512: empty string", function()
  H.eq(C.hex(C.sha512("")), "cf83e1357eefb8bdf1542850d66d8007d620e4050b5715dc83f4a921d36ce9ce"
    .. "47d0d13c5d85f2b0ff8318d2877eec2f63b931bd47417a81a538327af927da3e")
end)

H.test("sha512: \"abc\"", function()
  H.eq(C.hex(C.sha512("abc")), "ddaf35a193617abacc417349ae20413112e6fa4e89a97ea20a9eeee64b55d39a"
    .. "2192992a274fc1a836ba3c23a3feebbd454d4423643ce80e2a9ac94fa54ca49f")
end)

H.test("sha512: 448-bit message", function()
  H.eq(C.hex(C.sha512("abcdbcdecdefdefgefghfghighijhijkijkljklmklmnlmnomnopnopq")),
    "204a8fc6dda82f0a0ced7beb8e08a41657c16ef468b228a8279be331a703c335"
    .. "96fd15c13b1b07f9aa1d3bea57789ca031ad85c7a71dd70354ec631238ca3445")
end)

H.test("sha512: 896-bit two-block message", function()
  local msg = "abcdefghbcdefghicdefghijdefghijkefghijklfghijklmghijklmnhijklmno"
    .. "ijklmnopjklmnopqklmnopqrlmnopqrsmnopqrstnopqrstu"
  H.eq(#msg, 112)
  H.eq(C.hex(C.sha512(msg)), "8e959b75dae313da8cf4f72814fc143f8f7779c6eb9f7fa17299aeadb6889018"
    .. "501d289e4900f7e4331b99dec4b5433ac7d329eeb6dd26545e96e55b874be909")
end)

-- Lengths around the padding boundaries: the length field fits after 111 bytes but not 112,
-- and 128 fills a block exactly. Digests from Python's hashlib.
local BOUNDARY = {
  { 55, "2fd061a12ae849786141611e02a18ad9dad5d1cf6980f67fd4021fe369e4fef874548e9e5146e53622a919b3dcbd652f9abdd9578c4bd0c8e28d38008ea922b5" },
  { 56, "78ade6b0c755effd2b093d02bbeb8354d57c3e0c36457f941b47e2b384bc0a279c4cdaae1f9968e47bfa1e94438c33af1253067677087890f35f944a6fb8693e" },
  { 63, "853d2f48b4e8c74aa7c547ad831787b4f2bb85aa2851241a7fd1a38f651c2eb5816990092a4cd336d86dba73f0191f69a8825c7f5f2991bdcc2fb9661af22f46" },
  { 64, "be7cccdacc7551d40828f4f3568f741a224ec5e5274ca547e06ad5dc8313456706033259aa46937a061bc30f9913597e0b591c6492da5334e9148bbb91ce805b" },
  { 111, "4d1db900250c96436052fbca79c13acbf378aad9c35b87d94c3803264df61fd22cbd327c8938d024db372abf4208934ee09367d571d6c670bf74ee07b83e7506" },
  { 112, "dfb715ca3478a894302ace39c42d1d6646e1044f2247a6274d8b42d155d2fdbe7017195e85cfba96bedc51f84c44638978a540039ff09c64cef6c0c5ccc8f7b6" },
  { 113, "604b00570a65f49111782330fd36bef680bcc58e13288cbec1b8554e81de17b05f53e1293d33673872d0d48a57aba35f539643a3b8210d2bef35531f2b441451" },
  { 127, "f93a0e7465b294188e8aa2b1cc2e98bc8d5115d46f51c7a9ec599b9d9f96a80fef6a4f226b648c89bd9eac23b3d64264898b568d915c66666c44cd0319e2ef56" },
  { 128, "0b4815d35f9d07b1a30de2790e1be2a720234295cd7b4d9e9af51719ff90019f1fe6d4e402a7dcc4177085023dc460ab743dad9b2c1dda42662bda5d3b2e155b" },
  { 129, "1809db04d02717483e04bc4333a14308bd2d0213ba7bf2c63f11eb1b8a0af8252e67fd104fd466fb95f945539824d8e4183155fa5ced0bee3dad46d9384a0bd5" },
  { 239, "e7d76d3071c75958d9ad998aaef85cc6aed7239af8624555fab079b97f83b71895080a8fc394fc4f084dcb3851351d9f68db41dc899898fae64c55471adf13e3" },
  { 240, "4093151dceded504178ee4106aa5e15c02989d297d0916f78a9e3bc43d1a4419f00b1e007b1c309f45331e427095f0c1253057e52bbd08dbda7fe4e8827f92f4" },
  { 241, "ad208764b192610e0925e8c9977c234b20fb1a9cbc045fd69a171ca96f18ffcc108966cd5146929fbb4c259732639f636dad3011ea613559181b06bfafcc7af9" },
  { 255, "e5ce8d678c35050eb39bff5152607d2efac48ce297cf6fcafc70512af8089c1cc2f5a660d86d43f7474b7bb77a4145c60ff29dc5ee48287b34c481ff955c2acc" },
  { 256, "00086aa6fcb4bb59f284fe8079038293aa2c430c4c635663cc04239e5c13d38d97eaf425edf0aab91cfaec9915a6e297efe64dbda38d3886862ab5232b1e7160" },
  { 1000, "bef824658455c75d8ed438db9b1c2c26c705f5f0423c3b42834e0a5aded3123efc6be2da589e55e43f3d1d03e6a83134bb9781333bc63f72a0e2559d1263209d" },
}

for _, case in ipairs(BOUNDARY) do
  H.test(string.format("sha512: %d-byte message (padding boundaries)", case[1]), function()
    H.eq(C.hex(C.sha512(pattern(case[1]))), case[2])
  end)
end

for _, case in ipairs(fixtures.sha512) do
  local msg = unhex(case.msg)
  H.test(string.format("sha512: random %d-byte message (hashlib)", #msg), function()
    H.eq(C.sha512(msg), unhex(case.digest))
  end)
end

---------------------------------------------------------------------------------------------------
-- Hex

H.test("hex: every byte value, and back", function()
  local t = {}
  for i = 0, 255 do t[i + 1] = string.char(i) end
  local bin = table.concat(t)
  local h = C.hex(bin)
  H.eq(#h, 512)
  H.eq(h:sub(1, 8), "00010203")
  H.eq(h:sub(-8), "fcfdfeff")
  H.eq(C.unhex(h), bin)
  H.eq(C.unhex(h:upper()), bin)
  H.eq(C.hex(""), "")
  H.eq(C.unhex(""), "")
end)

H.test("unhex: odd length or non-hex characters give nil", function()
  H.eq(C.unhex("abc"), nil)
  H.eq(C.unhex("zz"), nil)
  H.eq(C.unhex("0g"), nil)
  H.eq(C.unhex("00 1"), nil)
  H.eq(C.unhex(nil), nil)
end)

---------------------------------------------------------------------------------------------------
-- Ed25519: RFC 8032 section 7.1

local RFC = {
  {
    name = "TEST 1",
    pub = "d75a980182b10ab7d54bfed3c964073a0ee172f3daa62325af021a68f707511a",
    msg = "",
    sig = "e5564300c360ac729086e2cc806e828a84877f1eb8e5d974d873e065224901555fb8821590a33bacc61e39701cf9b46bd25bf5f0595bbe24655141438e7a100b",
  },
  {
    name = "TEST 2",
    pub = "3d4017c3e843895a92b70aa74d1b7ebc9c982ccf2ec4968cc0cd55f12af4660c",
    msg = "72",
    sig = "92a009a9f0d4cab8720e820b5f642540a2b27b5416503f8fb3762223ebdb69da085ac1e43e15996e458f3613d0f11d8c387b2eaeb4302aeeb00d291612bb0c00",
  },
  {
    name = "TEST 3",
    pub = "fc51cd8e6218a1a38da47ed00230f0580816ed13ba3303ac5deb911548908025",
    msg = "af82",
    sig = "6291d657deec24024827e69c3abe01a30ce548a284743a445e3680d7db5ac3ac18ff9b538d16f290ae67f760984dc6594a7c15e9716ed28dc027beceea1ec40a",
  },
  {
    name = "TEST 1024",
    pub = "278117fc144c72340f67d0f2316e8386ceffbf2b2428c9c51fef7c597f1d426e",
    msg = "08b8b2b733424243760fe426a4b54908632110a66c2f6591eabd3345e3e4eb98fa6e264bf09efe12ee50f8f54e9f77b1"
      .. "e355f6c50544e23fb1433ddf73be84d879de7c0046dc4996d9e773f4bc9efe5738829adb26c81b37c93a1b270b20329d"
      .. "658675fc6ea534e0810a4432826bf58c941efb65d57a338bbd2e26640f89ffbc1a858efcb8550ee3a5e1998bd177e93a"
      .. "7363c344fe6b199ee5d02e82d522c4feba15452f80288a821a579116ec6dad2b3b310da903401aa62100ab5d1a36553e"
      .. "06203b33890cc9b832f79ef80560ccb9a39ce767967ed628c6ad573cb116dbefefd75499da96bd68a8a97b928a8bbc10"
      .. "3b6621fcde2beca1231d206be6cd9ec7aff6f6c94fcd7204ed3455c68c83f4a41da4af2b74ef5c53f1d8ac70bdcb7ed1"
      .. "85ce81bd84359d44254d95629e9855a94a7c1958d1f8ada5d0532ed8a5aa3fb2d17ba70eb6248e594e1a2297acbbb39d"
      .. "502f1a8c6eb6f1ce22b3de1a1f40cc24554119a831a9aad6079cad88425de6bde1a9187ebb6092cf67bf2b13fd65f270"
      .. "88d78b7e883c8759d2c4f5c65adb7553878ad575f9fad878e80a0c9ba63bcbcc2732e69485bbc9c90bfbd62481d9089b"
      .. "eccf80cfe2df16a2cf65bd92dd597b0707e0917af48bbb75fed413d238f5555a7a569d80c3414a8d0859dc65a46128ba"
      .. "b27af87a71314f318c782b23ebfe808b82b0ce26401d2e22f04d83d1255dc51addd3b75a2b1ae0784504df543af8969b"
      .. "e3ea7082ff7fc9888c144da2af58429ec96031dbcad3dad9af0dcbaaaf268cb8fcffead94f3c7ca495e056a9b47acdb7"
      .. "51fb73e666c6c655ade8297297d07ad1ba5e43f1bca32301651339e22904cc8c42f58c30c04aafdb038dda0847dd988d"
      .. "cda6f3bfd15c4b4c4525004aa06eeff8ca61783aacec57fb3d1f92b0fe2fd1a85f6724517b65e614ad6808d6f6ee34df"
      .. "f7310fdc82aebfd904b01e1dc54b2927094b2db68d6f903b68401adebf5a7e08d78ff4ef5d63653a65040cf9bfd4aca7"
      .. "984a74d37145986780fc0b16ac451649de6188a7dbdf191f64b5fc5e2ab47b57f7f7276cd419c17a3ca8e1b939ae49e4"
      .. "88acba6b965610b5480109c8b17b80e1b7b750dfc7598d5d5011fd2dcc5600a32ef5b52a1ecc820e308aa342721aac09"
      .. "43bf6686b64b2579376504ccc493d97e6aed3fb0f9cd71a43dd497f01f17c0e2cb3797aa2a2f256656168e6c496afc5f"
      .. "b93246f6b1116398a346f1a641f3b041e989f7914f90cc2c7fff357876e506b50d334ba77c225bc307ba537152f3f161"
      .. "0e4eafe595f6d9d90d11faa933a15ef1369546868a7f3a45a96768d40fd9d03412c091c6315cf4fde7cb68606937380d"
      .. "b2eaaa707b4c4185c32eddcdd306705e4dc1ffc872eeee475a64dfac86aba41c0618983f8741c5ef68d3a101e8a3b8ca"
      .. "c60c905c15fc910840b94c00a0b9d0",
    sig = "0aab4c900501b3e24d7cdf4663326a3a87df5e4843b2cbdb67cbf6e460fec350aa5371b1508f9f4528ecea23c436d94b5e8fcd4f681e30a6ac00a9704a188a03",
  },
  {
    name = "TEST SHA(abc)",
    pub = "ec172b93ad5e563bf4932c70e1245034c35467ef2efd4d64ebf819683467e2bf",
    msg = "ddaf35a193617abacc417349ae20413112e6fa4e89a97ea20a9eeee64b55d39a2192992a274fc1a836ba3c23a3feebbd454d4423643ce80e2a9ac94fa54ca49f",
    sig = "dc2a4459e7369633a52b1bf277839a00201009a3efbf3ecb69bea2186c26b58909351fc9ac90b3ecfdfbc7c66431e0303dca179c138ac17ad9bef1177331a704",
  },
}

for _, v in ipairs(RFC) do
  local pub, msg, sig = unhex(v.pub), unhex(v.msg), unhex(v.sig)
  H.test("ed25519: RFC 8032 " .. v.name .. " verifies", function()
    check(pub, msg, sig, true)
  end)
  H.test("ed25519: RFC 8032 " .. v.name .. " with a flipped signature bit fails", function()
    local last = sig:byte(64)
    check(pub, msg, sig:sub(1, 63) .. string.char((last - last % 2) + (1 - last % 2)), false)
  end)
end

H.test("ed25519: RFC 8032 TEST 1024 message is 1023 bytes", function()
  H.eq(#unhex(RFC[4].msg), 1023)
  H.eq(unhex(RFC[5].msg), C.sha512("abc"))
end)

---------------------------------------------------------------------------------------------------
-- Ed25519: signatures made by tools/ed25519.py, good and tampered

for _, case in ipairs(fixtures.ed25519) do
  H.test("ed25519 cross-check: " .. case.name, function()
    check(unhex(case.pub), unhex(case.msg), unhex(case.sig), case.ok)
  end)
end

---------------------------------------------------------------------------------------------------
-- Bad input and the stepped verifier

local function fixture(name)
  for _, case in ipairs(fixtures.ed25519) do
    if case.name == name then
      H.eq(case.ok, true, name)
      return unhex(case.pub), unhex(case.msg), unhex(case.sig)
    end
  end
  error("no fixture named " .. name)
end

local gpub, gmsg, gsig = fixture("key 1, 64-byte message")

H.test("ed25519: non-string arguments give false, not an error", function()
  for _, args in ipairs({
    { nil, gmsg, gsig }, { gpub, nil, gsig }, { gpub, gmsg, nil },
    { 42, gmsg, gsig }, { gpub, {}, gsig }, { gpub, gmsg, true },
  }) do
    H.eq(C.verify(args[1], args[2], args[3]), false, "verify")
    H.eq(runSteps(C.verifier(args[1], args[2], args[3])), false, "verifier")
  end
end)

H.test("verifier: SLICE is a number", function()
  H.eq(type(C.SLICE), "number")
  H.ok(C.SLICE > 0)
end)

H.test("verifier: the default SLICE spreads a check over several steps", function()
  local result, steps = runSteps(C.verifier(gpub, gmsg, gsig))
  H.eq(result, true)
  H.ok(steps >= 2, string.format("expected several steps, got %d", steps))
end)

H.test("verifier: same answers with a tiny SLICE and with a huge one", function()
  local bad = gsig:sub(1, 40) .. string.char((gsig:byte(41) + 1) % 256) .. gsig:sub(42)
  local manySteps, oneStep
  withSlice(1, function()
    H.eq(runSteps(C.verifier(gpub, gmsg, gsig)), true)
    local result
    result, manySteps = runSteps(C.verifier(gpub, gmsg, bad))
    H.eq(result, false)
  end)
  withSlice(1e9, function()
    local result
    result, oneStep = runSteps(C.verifier(gpub, gmsg, gsig))
    H.eq(result, true)
    H.eq(runSteps(C.verifier(gpub, gmsg, bad)), false)
  end)
  H.eq(oneStep, 1, "a huge SLICE finishes in one step")
  H.ok(manySteps > 100, string.format("a tiny SLICE takes many steps, got %d", manySteps))
end)

H.test("verifier: checks running side by side don't disturb each other", function()
  local opub, omsg, osig = fixture("key 2, 64-byte message")
  local bad = gsig:sub(1, 63) .. string.char((gsig:byte(64) + 1) % 256)
  local steps = {
    { step = C.verifier(gpub, gmsg, gsig), want = true },
    { step = C.verifier(opub, omsg, osig), want = true },
    { step = C.verifier(gpub, gmsg, bad), want = false },
    { step = C.verifier(opub, gmsg, gsig), want = false },
  }
  withSlice(50, function()
    local pending = #steps
    local rounds = 0
    while pending > 0 do
      rounds = rounds + 1
      H.ok(rounds < 10000, "never finished")
      pending = 0
      for _, s in ipairs(steps) do
        if s.got == nil then
          s.got = s.step()
          if s.got == nil then pending = pending + 1 end
        end
      end
      -- a one-go check in between must not disturb the suspended ones
      if rounds == 3 then H.eq(C.verify(opub, omsg, osig), true) end
    end
  end)
  for i, s in ipairs(steps) do
    H.eq(s.got, s.want, string.format("verifier %d", i))
    H.eq(s.step(), s.want, string.format("verifier %d, called again", i))
  end
end)

H.finish()
