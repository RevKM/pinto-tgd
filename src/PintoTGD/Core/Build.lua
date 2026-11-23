-- Build constants, written by tools/build.py.
local ADDON, ns = ...

ns.Build = {
  version = "0.1.0",
  dataVersion = 1,
  protocolVersion = 1,
  formulaVersion = 1,
  questPack = 2,
  -- The go-live date, in server time. Nothing is recorded before it.
  goLive = "2026-11-23",
  -- Test builds carry their own date and keep their data apart from release data.
  test = true,
  -- The test tools: /pinto test, the test controls and the debug panel. Beta and
  -- release builds don't have them.
  testTools = true,
  important = false,
  -- Ed25519 public key (hex) that release stamps and quest packs must be signed with.
  publicKey = "2f87d75b009b79775c931f82f923e11ea97af9718f22beb60666f4dfc7df4d0f",
  releaseUrl = "https://github.com/RevKM/pinto-tgd/releases/latest",
}
