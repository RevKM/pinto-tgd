-- Quest packs and release stamps: signature checks, the copies this build carries, and
-- whether a newer release is out.
--
-- A pack or stamp from another addon is only merged once its Ed25519 signature checks
-- out against the public key in this build. Checks run one at a time, a slice per frame,
-- so the game never stutters.
local ADDON, ns = ...

local Release = {}
ns.Release = Release

local Store, Pieces, Util, Events = ns.Store, ns.Pieces, ns.Util, ns.Events

local queue, current = {}, nil
local results = {} -- key -> true/false, so the same thing is only checked once
local frame

local function publicKey()
  if not Release.key then Release.key = ns.Crypto.unhex(ns.Build.publicKey) end
  return Release.key
end

-- The bytes a signature covers, or nil if the data contradicts itself.
local function signedBytes(job)
  if job.kind == "pack" then
    local d = job.obj.data
    if #d < 12 or d:sub(1, 9) ~= "PintoPack" then return nil end
    if d:byte(10) * 256 + d:byte(11) ~= job.num then return nil end
    return d
  end
  return Pieces.stampBody(job.obj)
end

local function accept(job)
  if job.kind == "pack" then
    Store.AddPack(job.num, job.obj.data, job.obj.sig, "remote")
  else
    Store.SetStamp(job.obj, "remote")
  end
end

local function step()
  local job = current
  if not job then
    job = table.remove(queue, 1)
    if not job then
      frame:Hide()
      return
    end
    local msg = signedBytes(job)
    if not msg then return end
    job.key = Util.hash(msg) .. ":" .. Util.hex(job.obj.sig)
    local known = results[job.key]
    if known ~= nil then
      if known then accept(job) end
      return
    end
    job.step = ns.Crypto.verifier(publicKey(), msg, job.obj.sig)
    current = job
  end
  local ok = job.step()
  if ok ~= nil then
    current = nil
    results[job.key] = ok
    if ok then
      accept(job)
    else
      ns.Debug("a %s from %s failed its signature check", job.kind, job.from or "?")
    end
  end
end

local function enqueue(job)
  for _, q in ipairs(queue) do
    if q.kind == job.kind and q.obj.sig == job.obj.sig then return end
  end
  queue[#queue + 1] = job
  frame:Show()
end

-- A "k" piece from another addon: check whatever is new in it.
function Release.Incoming(piece, sender)
  local mine = Store.get("k")
  for num, pk in pairs(piece.packs) do
    local have = mine and mine.packs[num]
    if not have or have.data ~= pk.data or have.sig ~= pk.sig then
      enqueue({ kind = "pack", num = num, obj = pk, from = sender })
    end
  end
  local st = piece.stamp
  if st then
    local have = mine and mine.stamp
    if not have or have.sig ~= st.sig then enqueue({ kind = "stamp", obj = st, from = sender }) end
  end
end

-- The pack and stamp that came with this build.
function Release.LoadEmbedded()
  local pd = ns.QuestPackData
  if pd and pd.data and pd.sig then
    Store.AddPack(pd.num, pd.data, ns.Crypto.unhex(pd.sig), "embedded")
  end
  local sig = ns.Build.stampSig
  if sig then
    Store.SetStamp({ version = ns.Build.version, dataVersion = ns.Build.dataVersion,
      protocolVersion = ns.Build.protocolVersion, pack = ns.Build.questPack,
      important = ns.Build.important or false, sig = ns.Crypto.unhex(sig) }, "embedded")
  end
end

-- "needed" when the newest release can't share data with this one or is an important
-- fix, "available" when it's just newer, nil when this is the newest.
function Release.Status()
  local k = Store.get("k")
  local st = k and k.stamp
  if not st then return nil end
  if Pieces.versionNumber(st.version) <= Pieces.versionNumber(ns.Build.version) then return nil end
  if st.important or st.dataVersion > ns.Build.dataVersion
    or st.protocolVersion > ns.Build.protocolVersion then
    return "needed", st
  end
  return "available", st
end

function Release.Busy()
  return current ~= nil or #queue > 0
end

function Release.Init()
  frame = CreateFrame("Frame")
  frame:Hide()
  frame:SetScript("OnUpdate", step)
  Release.LoadEmbedded()
end
