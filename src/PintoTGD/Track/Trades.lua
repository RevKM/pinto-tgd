-- Trades that help a quest: a crafted item, an enchant, materials or a recipe.
-- Items this account crafts are remembered, so giving one away counts as a crafted item.
--
-- PintoTGD_DB.crafted[item id] = { prof = profession name, line = its skill line id (when
--   the client gives one), at = server time }
local ADDON, ns = ...

local Trades = {}
ns.Trades = Trades

local Store, Pieces, Compat, Time, Events, Log, Util = ns.Store, ns.Pieces, ns.Compat, ns.Time, ns.Events, ns.Log, ns.Util
local TRADE = Pieces.TRADE

local partner, snapshot, completed

-- Crafting ---------------------------------------------------------------------------

local createPatterns
local function onLoot(text)
  if not createPatterns then
    createPatterns = {}
    for _, g in ipairs({ LOOT_ITEM_CREATED_SELF_MULTIPLE, LOOT_ITEM_CREATED_SELF }) do
      if g then
        local p = g:gsub("([%(%)%.%+%-%*%?%[%]%^%$])", "%%%1"):gsub("%%s", "(.+)"):gsub("%%d", "(%%d+)")
        createPatterns[#createPatterns + 1] = "^" .. p .. "$"
      end
    end
  end
  for _, p in ipairs(createPatterns) do
    local link = text:match(p)
    if link then
      local id = Compat.ItemID(link)
      if id then
        local prof, line = Compat.TradeSkill()
        PintoTGD_DB.crafted = PintoTGD_DB.crafted or {}
        PintoTGD_DB.crafted[id] = { prof = prof, line = line, at = Time.now() }
      end
      return
    end
  end
end

function Trades.Crafted(itemID)
  return PintoTGD_DB.crafted and PintoTGD_DB.crafted[itemID]
end

-- What an item is, for the quests: tags and the trade kind it counts as.
function Trades.Classify(link, mine)
  local id = Compat.ItemID(link)
  if not id then return nil end
  local tags = {}
  local _, _, _, equipLoc, _, classID, subclassID = Compat.ItemInfoInstant(link)
  local crafted = mine and Trades.Crafted(id)
  if equipLoc == "INVTYPE_BAG" then tags.bag = true end
  if classID == 0 then
    if subclassID == 5 then tags.food = true end
    if subclassID == 1 or subclassID == 2 then tags.potion = true end
    if subclassID == 7 then tags.bandage = true end
  end
  if crafted then
    -- by skill line (Cooking 185, Alchemy 171, First Aid 129), else by name
    local p, line = crafted.prof or "", crafted.line
    if line == 185 or p == (Compat.SpellName(2550) or "Cooking") or p == "Cooking" then tags.food = true end
    if line == 171 or p == (Compat.SpellName(2259) or "Alchemy") or p == "Alchemy" then tags.potion = true end
    if line == 129 or p == (Compat.SpellName(3273) or "First Aid") or p == "First Aid" then tags.bandage = true end
  end
  -- gear: something worn. Newer clients, Forever's among them, give every other item
  -- INVTYPE_NON_EQUIP_IGNORE where older ones gave nothing.
  if equipLoc and equipLoc ~= "" and not equipLoc:find("^INVTYPE_NON_EQUIP")
    and equipLoc ~= "INVTYPE_BAG" and equipLoc ~= "INVTYPE_AMMO" then
    tags.gear = true
    tags.ilvl = Compat.ItemLevel(link)
    tags.equipLoc = equipLoc
  end
  local kind
  if classID == 9 then
    kind = TRADE.recipe
  elseif crafted then
    kind = TRADE.crafted
  elseif ns.Activity.MaterialKind(link) then
    kind = TRADE.materials
    tags.material = ns.Activity.MaterialKind(link)
  end
  return kind, id, tags
end

-- The trade window -------------------------------------------------------------------

-- The enchant shown on the item in the "will not be traded" slot, from that slot's
-- GetTrade*ItemInfo values, or nil. After the name and icon, it's the only text among
-- them: the 6th value for their side (after whether we can use the item), the 5th for
-- ours, on the clients seen so far.
local function slotEnchant(...)
  for i = 3, select("#", ...) do
    local v = select(i, ...)
    if not ns.Secret(v) and type(v) == "string" and v ~= "" then return v end
  end
  return nil
end

local function take()
  local s = { mine = {}, theirs = {} }
  for i = 1, 6 do
    local link = GetTradePlayerItemLink(i)
    if link then
      local _, _, count = GetTradePlayerItemInfo(i)
      s.mine[#s.mine + 1] = { link = link, count = count or 1 }
    end
    link = GetTradeTargetItemLink(i)
    if link then
      local _, _, count = GetTradeTargetItemInfo(i)
      s.theirs[#s.theirs + 1] = { link = link, count = count or 1 }
    end
  end
  -- the "will not be traded" slot: an enchant applied to the other side's item
  s.enchantedTheirs = slotEnchant(GetTradeTargetItemInfo(7)) ~= nil
  s.enchantedMine = slotEnchant(GetTradePlayerItemInfo(7)) ~= nil
  s.enchantTheirItem = GetTradeTargetItemLink(7)
  return s
end

local function record(dir, who, kind, id, count, tags)
  local today = Time.day()
  local giver, receiver = ns.me, who
  if dir == "in" then giver, receiver = who, ns.me end
  Store.AddTrade(today, giver, receiver, kind, id, count, ns.Player.AccountId())
  Log.AddTrade(dir, who, kind, id, count, tags)
end

local function complete()
  if completed or not snapshot or not partner or not Time.isLive() then return end
  completed = true
  if not ns.Roster.Get(partner) then return end
  for _, it in ipairs(snapshot.mine) do
    local kind, id, tags = Trades.Classify(it.link, true)
    if kind then record("out", partner, kind, id, it.count, tags) end
  end
  for _, it in ipairs(snapshot.theirs) do
    local kind, id, tags = Trades.Classify(it.link, false)
    -- the giver's addon reports crafted items; here only what this side can see
    if kind == TRADE.materials or kind == TRADE.recipe then
      record("in", partner, kind, id, it.count, tags)
    elseif id then
      Log.AddTrade("in", partner, nil, id, it.count, tags or {})
    end
  end
  if snapshot.enchantedTheirs then
    local id = Compat.ItemID(snapshot.enchantTheirItem) or 0
    record("out", partner, TRADE.enchant, id, 1, {})
  end
  if snapshot.enchantedMine then
    Log.AddTrade("in", partner, TRADE.enchant, 0, 1, {})
  end
end

local tradeComplete
local function onInfo(_, text)
  tradeComplete = tradeComplete or ERR_TRADE_COMPLETE
  if text == tradeComplete then complete() end
end

function Trades.Init()
  Events.On("TRADE_SHOW", function()
    partner = Compat.UnitFullName("NPC")
    snapshot, completed = take(), false
  end)
  for _, e in ipairs({ "TRADE_PLAYER_ITEM_CHANGED", "TRADE_TARGET_ITEM_CHANGED", "TRADE_ACCEPT_UPDATE" }) do
    Events.On(e, function()
      if partner and not completed then snapshot = take() end
    end)
  end
  Events.On("UI_INFO_MESSAGE", onInfo)
  Events.On("TRADE_CLOSED", function()
    ns.After(0.5, function() partner, snapshot = nil, nil end)
  end)
  Events.On("CHAT_MSG_LOOT", onLoot)
end
