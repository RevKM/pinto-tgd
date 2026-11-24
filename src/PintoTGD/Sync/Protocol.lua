-- Sync between addons.
--
-- Live updates: new facts go out on the guild channel in batches every ~30 seconds
-- (completions after a few seconds, so witnesses can confirm them).
-- Hellos: each addon announces its exact version and a fingerprint of its whole copy at
-- login and every ~10 minutes. A guildie whose data differs answers privately.
-- Catch-up: whoever announced pulls. It asks one guildie for its list of piece
-- fingerprints, requests the pieces that differ (split across up to three guildies
-- holding the same data), merges them, then pushes back whatever the other side lacks.
-- Merges are joins, so after one exchange both sides hold the same pieces.
local ADDON, ns = ...

local Protocol = {}
ns.Protocol = Protocol

local Comm, Store, Pieces, Bytes, Util, Events = ns.Comm, ns.Store, ns.Pieces, ns.Bytes, ns.Util, ns.Events
local T = Comm.T

local HELLO_EVERY = 600
local FACTS_DELAY = 30
local URGENT_DELAY = 3
local SYNC_COOLDOWN = 300
local SESSION_TIMEOUT = 90
local ALONE_AFTER = 20
local BATCH_BYTES = 6000
local MAX_UNPACKED = 1048576

Protocol.peers = {}          -- name -> { account, version, dv, pv, fp, count, at }
Protocol.state = "waiting"   -- waiting, alone, syncing, synced

local session = nil          -- the catch-up this addon is running
local lastSyncWith = {}
local repliedTo = {}
local pending, flushAt = nil, nil

local function setState(s)
  if Protocol.state ~= s then
    Protocol.state = s
    Events.Fire("PINTO_SYNC_STATE", s)
  end
end

local function sameData(peer)
  return peer.dv == ns.Build.dataVersion and peer.pv == ns.Build.protocolVersion
end

-- Guildies running a compatible addon who are online now.
function Protocol.OnlinePeers()
  local list = {}
  for name, peer in pairs(Protocol.peers) do
    if sameData(peer) and ns.Roster.IsOnline(name) then list[#list + 1] = name end
  end
  return list
end

-- Compression for big transfers, when the client has it ------------------------------

local function deflate()
  return Enum and Enum.CompressionMethod and Enum.CompressionMethod.Deflate
end

local function pack(s)
  if #s > 200 and C_EncodingUtil and C_EncodingUtil.CompressString and deflate() then
    local ok, z = pcall(C_EncodingUtil.CompressString, s, deflate())
    if ok and type(z) == "string" and #z < #s then return "\1" .. z end
  end
  return "\0" .. s
end

local function unpackData(s)
  local flag = s:byte(1)
  if flag == 0 then return s:sub(2) end
  if flag == 1 and C_EncodingUtil and C_EncodingUtil.DecompressString and deflate() then
    local ok, raw = pcall(C_EncodingUtil.DecompressString, s:sub(2), deflate())
    if ok and type(raw) == "string" and #raw <= MAX_UNPACKED then return raw end
  end
  return nil
end

-- Receiving pieces -----------------------------------------------------------------

-- Merges one encoded piece from another addon. Packs and stamps get their signatures
-- checked first. Returns the decoded result, or nil for bad data.
function Protocol.Receive(bin, sender)
  local res = Pieces.decode(bin)
  if not res then return nil end
  if Store.inWindow(res.id) then
    if res.piece.letter == "k" then
      ns.Release.Incoming(res.piece, sender)
    else
      Store.merge(res.id, res.piece, "remote")
    end
  end
  return res
end

-- Live facts -----------------------------------------------------------------------

local function onLocalDelta(id, delta)
  pending = pending or {}
  local p = pending[id]
  if not p then
    p = Pieces.new(id)
    pending[id] = p
  end
  Pieces.codec[p.letter].merge(p, delta)
  local at = GetTime() + (p.letter == "w" and URGENT_DELAY or FACTS_DELAY)
  if not flushAt or at < flushAt then flushAt = at end
end

function Protocol.FlushFacts()
  if not pending then return end
  local ids = Util.sortedKeys(pending, Util.byteLess)
  local list, size = {}, 0
  local function send()
    if #list == 0 then return end
    local w = Bytes.writer()
    w:varint(#list)
    for _, bin in ipairs(list) do w:str(bin) end
    Comm.Send(T.FACTS, w:result(), "GUILD", nil, 1)
    list, size = {}, 0
  end
  for _, id in ipairs(ids) do
    local bin = Pieces.encode(id, pending[id])
    if size + #bin > BATCH_BYTES then send() end
    list[#list + 1] = bin
    size = size + #bin
  end
  send()
  pending, flushAt = nil, nil
end

Comm.handlers[T.FACTS] = function(r, sender)
  Protocol.receiving = "live"
  for _ = 1, r:count(64) do
    Protocol.Receive(r:str(65535), sender)
  end
  Protocol.receiving = nil
end

-- Hellos ---------------------------------------------------------------------------

-- Every version reads hellos (Comm.lua), so this never changes; a later version may only
-- add to its end.
local function helloPayload()
  local w = Bytes.writer()
  w:u32(ns.account)
  w:str(ns.Build.version)
  w:u8(ns.Build.dataVersion)
  w:u8(ns.Build.protocolVersion)
  w:u32(Store.wholeFingerprint())
  w:u16(math.min(65535, #Store.ids()))
  return w:result()
end

function Protocol.Hello(target)
  if target then
    Comm.Send(T.HELLO, helloPayload(), "WHISPER", target, 2)
  else
    Comm.Send(T.HELLO, helloPayload(), "GUILD", nil, 2)
  end
end

Comm.handlers[T.HELLO] = function(r, sender, channel)
  local peer = { account = r:u32(), version = r:str(16), dv = r:u8(), pv = r:u8(),
    fp = r:u32(), count = r:u16(), at = GetTime() }
  Protocol.peers[sender] = peer
  Events.Fire("PINTO_PEER", sender, peer)
  -- on another version, no sync: just the newest release, if they're behind
  if not sameData(peer) then
    ns.Release.Offer(sender, peer)
    return
  end
  local mine = Store.wholeFingerprint()
  if peer.fp == mine or Protocol.state == "alone" then
    if not session then setState("synced") end
    if peer.fp == mine then return end
  end
  if channel == "GUILD" then
    -- they announced themselves and our data differs: answer privately so they pull.
    -- The same announcement against the same data is only answered once a minute.
    local last = repliedTo[sender]
    if not last or last.theirs ~= peer.fp or last.mine ~= mine or GetTime() - last.at > 60 then
      repliedTo[sender] = { at = GetTime(), theirs = peer.fp, mine = mine }
      ns.After(0.5 + math.random() * 3.5, function()
        local p = Protocol.peers[sender]
        if p and p.fp ~= Store.wholeFingerprint() then Protocol.Hello(sender) end
      end)
    end
  else
    if session then session.others = true end
    Protocol.MaybeSync(sender)
  end
end

-- Catch-up -------------------------------------------------------------------------

function Protocol.MaybeSync(partner)
  if session then return end
  local last = lastSyncWith[partner]
  if last and GetTime() - last < SYNC_COOLDOWN then return end
  lastSyncWith[partner] = GetTime()
  session = { partner = partner, state = "list", progressAt = GetTime(), startFp = Store.wholeFingerprint() }
  setState("syncing")
  Comm.Send(T.LIST_REQ, "", "WHISPER", partner, 3)
end

local function listPayload()
  local w = Bytes.writer()
  local ids = Store.ids()
  w:varint(#ids)
  for _, id in ipairs(ids) do
    Pieces.writeId(w, id)
    w:u32(Store.fingerprint(id))
  end
  return w:result()
end

Comm.handlers[T.LIST_REQ] = function(_, sender)
  Comm.Send(T.LIST, listPayload(), "WHISPER", sender, 3)
end

function Protocol.SendPieces(target, ids)
  local batch, size = {}, 0
  local function flush()
    if #batch == 0 then return end
    local w = Bytes.writer()
    w:varint(#batch)
    for _, bin in ipairs(batch) do w:str(bin) end
    Comm.Send(T.PIECES, pack(w:result()), "WHISPER", target, 3)
    batch, size = {}, 0
  end
  for _, id in ipairs(ids) do
    if Store.get(id) then
      local bin = Store.encoded(id)
      if size + #bin > BATCH_BYTES then flush() end
      batch[#batch + 1] = bin
      size = size + #bin
    end
  end
  flush()
end

local lastRehello = -1000
local rehelloAt = nil

-- Announces again soon, at most once every 30 seconds.
local function rehello()
  local at = math.max(GetTime() + 2, lastRehello + 30)
  if rehelloAt and rehelloAt <= at then return end
  rehelloAt = at
  ns.After(at - GetTime(), function()
    rehelloAt = nil
    lastRehello = GetTime()
    Protocol.Hello()
  end)
end

function Protocol.EndSession(ok)
  local s = session
  session = nil
  if ok or #Protocol.OnlinePeers() > 0 then setState("synced") else setState("alone") end
  Events.Fire("PINTO_SYNCED", ok)
  -- others told us their data differed while we were busy, or we learned something new
  -- they may lack: announce again, and whoever still differs answers
  if s and (s.others or Store.wholeFingerprint() ~= s.startFp) then rehello() end
end

-- Sends the other side everything it lacks or holds differently, then finishes.
function Protocol.Push()
  local s = session
  if not s then return end
  local push = {}
  for _, id in ipairs(Store.ids()) do
    if s.theirs[id] ~= Store.fingerprint(id) then push[#push + 1] = id end
  end
  if #push > 0 then Protocol.SendPieces(s.partner, push) end
  Protocol.EndSession(true)
end

Comm.handlers[T.LIST] = function(r, sender)
  local s = session
  if not s or s.partner ~= sender or s.state ~= "list" then return end
  local theirs = {}
  for _ = 1, r:count(5000) do
    local id = Pieces.readId(r)
    theirs[id] = r:u32()
  end
  s.theirs = theirs
  s.progressAt = GetTime()
  local want = {}
  for id, fp in pairs(theirs) do
    if Store.inWindow(id) and (not Store.get(id) or Store.fingerprint(id) ~= fp) then
      want[#want + 1] = id
    end
  end
  table.sort(want, Util.byteLess)
  s.want = {}
  for _, id in ipairs(want) do s.want[id] = true end
  s.state = "pull"
  if #want == 0 then
    Protocol.Push()
    return
  end
  -- like a torrent: split the pieces across up to three guildies with the partner's data
  local helpers = { sender }
  local partner = Protocol.peers[sender]
  local helperNames = Util.sortedKeys(Protocol.peers)
  for _, name in ipairs(helperNames) do
    local p = Protocol.peers[name]
    if #helpers < 3 and name ~= sender and partner and p.fp == partner.fp and sameData(p)
      and GetTime() - p.at < 120 and ns.Roster.IsOnline(name) then
      helpers[#helpers + 1] = name
    end
  end
  local asks = {}
  for i, id in ipairs(want) do
    local h = helpers[(i - 1) % #helpers + 1]
    asks[h] = asks[h] or {}
    table.insert(asks[h], id)
  end
  for h, ids in pairs(asks) do
    local w = Bytes.writer()
    w:varint(#ids)
    for _, id in ipairs(ids) do Pieces.writeId(w, id) end
    Comm.Send(T.PIECES_REQ, w:result(), "WHISPER", h, 3)
  end
end

Comm.handlers[T.PIECES_REQ] = function(r, sender)
  local ids = {}
  for _ = 1, r:count(5000) do ids[#ids + 1] = Pieces.readId(r) end
  Protocol.SendPieces(sender, ids)
end

Comm.handlers[T.PIECES] = function(r, sender)
  local raw = unpackData(r:rest())
  if not raw then return end
  local pr = Bytes.reader(raw)
  local s = session
  Protocol.receiving = "catchup"
  for _ = 1, pr:count(1000) do
    local bin = pr:str(65535)
    local res = Protocol.Receive(bin, sender)
    if res and s and s.want and s.want[res.id] then
      s.want[res.id] = nil
      s.progressAt = GetTime()
      if s.theirs[res.id] ~= Util.hash(bin) then
        ns.Debug("piece %s from %s doesn't match the list", res.id, sender)
      end
    end
  end
  Protocol.receiving = nil
  if s and session == s and s.state == "pull" and not next(s.want) then Protocol.Push() end
end

local function checkSession()
  local s = session
  if not s then return end
  if Comm.HoldWhispers() then
    s.progressAt = GetTime()
    return
  end
  if GetTime() - s.progressAt > SESSION_TIMEOUT then
    if s.state == "pull" then
      Protocol.Push()
    else
      Protocol.EndSession(false)
    end
  end
end

function Protocol.IsSyncing() return session ~= nil end

function Protocol.Init()
  Events.On("PINTO_LOCAL_DELTA", onLocalDelta)
  ns.Every(1, function()
    if flushAt and GetTime() >= flushAt then Protocol.FlushFacts() end
    checkSession()
  end)
  ns.After(6 + math.random() * 4, function()
    Protocol.Hello()
    ns.After(ALONE_AFTER, function()
      if Protocol.state == "waiting" then setState("alone") end
    end)
  end)
  ns.Every(HELLO_EVERY, function()
    ns.After(math.random() * 60, Protocol.Hello)
  end)
  -- a guildie who comes online pulls from us after their own hello
end
