-- This account and its characters: the random account id, the player card (levels,
-- gear per slot, professions, usual play hours, a gold bracket), the daily "played"
-- fact and linking a second WoW license.
--
-- PintoTGD_DB (account-wide, not synced):
--   account   this account's random id
--   linkedTo  the account id of the player's other license, once linked with a code
--   chars     [full name] = { level, slots, prof, cook, aid, fish, copper, guild }
--   hourDays  [hour] = { [day] = true }, the days this account played in each server hour
local ADDON, ns = ...

local Player = {}
ns.Player = Player

local Store, Pieces, Util, Time, Compat, Events = ns.Store, ns.Pieces, ns.Util, ns.Time, ns.Compat, ns.Events

local PROFESSION_SPELLS = { 2259, 2018, 7411, 4036, 2366, 2108, 2575, 8613, 3908 }
local COOKING_SPELL, FIRST_AID_SPELL, FISHING_SPELL = 2550, 3273, 7620

-- Skill names, English and in the client's language: profession number, or "cook",
-- "aid" or "fish".
local skillByName

local function skillNames()
  if skillByName then return end
  skillByName = { Cooking = "cook", ["First Aid"] = "aid", Fishing = "fish" }
  for id, english in ipairs(Pieces.PROFESSIONS) do
    skillByName[english] = id
    local localized = Compat.SpellName(PROFESSION_SPELLS[id])
    if localized then skillByName[localized] = id end
  end
  for kind, spell in pairs({ cook = COOKING_SPELL, aid = FIRST_AID_SPELL, fish = FISHING_SPELL }) do
    local localized = Compat.SpellName(spell)
    if localized then skillByName[localized] = kind end
  end
end

local function db() return PintoTGD_DB end

function Player.AccountId()
  local d = db()
  if not d.account then d.account = Util.randomU32() end
  return d.account
end

-- The player this account belongs to: itself, or the account it was linked to.
function Player.PlayerId()
  return db().linkedTo or Player.AccountId()
end

-- Current character ------------------------------------------------------------------

local function readGear()
  local slots = {}
  for i, slot in ipairs(Pieces.GEAR_SLOTS) do
    local link = GetInventoryItemLink("player", slot)
    slots[i] = link and math.floor(Compat.ItemLevel(link) + 0.5) or 0
  end
  -- a two-handed weapon fills both hand slots
  local main = GetInventoryItemLink("player", 16)
  if main and slots[16] == 0 then
    local _, _, _, equipLoc = Compat.ItemInfoInstant(main)
    if equipLoc == "INVTYPE_2HWEAPON" then slots[16] = slots[15] end
  end
  return slots
end

-- Professions through GetProfessions (by skill line id, then name), or else the
-- skill lines of older clients.
local function readSkills()
  skillNames()
  local prof, other = {}, { cook = 0, aid = 0, fish = 0 }
  local function note(name, rank, skillLine)
    local kind = (skillLine and Compat.SKILL_LINES[skillLine]) or skillByName[name]
    if type(kind) == "number" then
      if #prof < 2 then prof[#prof + 1] = { id = kind, skill = rank or 0 } end
    elseif kind then
      other[kind] = rank or 0
    end
  end
  local list = Compat.Professions()
  if list and #list > 0 then
    for _, p in ipairs(list) do note(p.name, p.rank, p.skillLine) end
  elseif GetNumSkillLines and GetSkillLineInfo then
    for i = 1, GetNumSkillLines() do
      local name, isHeader, _, rank = GetSkillLineInfo(i)
      if name and not isHeader then note(name, rank) end
    end
  end
  table.sort(prof, function(a, b) return a.id < b.id end)
  return prof, other.cook, other.aid, other.fish
end

function Player.Refresh()
  if not ns.me then return end
  local d = db()
  d.chars = d.chars or {}
  local c = d.chars[ns.me] or {}
  c.level = UnitLevel("player") or c.level or 1
  c.slots = readGear()
  c.prof, c.cook, c.aid, c.fish = readSkills()
  c.copper = GetMoney and GetMoney() or c.copper or 0
  c.guild = Store.slotKey()
  d.chars[ns.me] = c
end

function Player.Current()
  local d = db()
  return d.chars and d.chars[ns.me]
end

-- Professions of the current character, as { [profession id] = skill } plus secondary.
function Player.Skills()
  local c = Player.Current()
  local out = { cook = c and c.cook or 0, aid = c and c.aid or 0, fish = c and c.fish or 0 }
  for _, p in ipairs(c and c.prof or {}) do out[p.id] = p.skill end
  return out
end

-- Usual play hours --------------------------------------------------------------------
-- An hour counts as usual when this account played in it on 2 of the last 28 days.

local function notePlayHour()
  local d = db()
  d.hourDays = d.hourDays or {}
  local h = Time.hour()
  local today = Time.day()
  local days = d.hourDays[h] or {}
  days[today] = true
  for day in pairs(days) do
    if day < today - 27 then days[day] = nil end
  end
  d.hourDays[h] = days
end

local function hoursMask()
  local d = db()
  local mask, bit = 0, 1
  for h = 0, 23 do
    local n = 0
    for _ in pairs((d.hourDays or {})[h] or {}) do n = n + 1 end
    if n >= 2 then mask = mask + bit end
    bit = bit * 2
  end
  return mask
end

function Player.UsualHours(mask)
  local hours = {}
  local v = mask or 0
  for h = 0, 23 do
    hours[h] = v % 2 == 1
    v = math.floor(v / 2)
  end
  return hours
end

-- Gold bracket ----------------------------------------------------------------------
-- The player's gold over all their characters in the guild, as a rough bracket:
-- 0 under 1 gold, then 1 + floor(log2(gold)).

local function goldBracket()
  local d = db()
  local copper = 0
  for _, c in pairs(d.chars or {}) do
    if c.guild == Store.slotKey() then copper = copper + (c.copper or 0) end
  end
  local gold = copper / 10000
  if gold < 1 then return 0 end
  return math.min(254, 1 + math.floor(math.log(gold) / math.log(2) + 1e-9))
end

function Player.BracketGold(b)
  if not b or b == 255 or b == 0 then return 0 end
  return 1.5 * 2 ^ (b - 1)
end

-- The card ----------------------------------------------------------------------------

local lastPublished

function Player.BuildCard()
  local d = db()
  local chars = {}
  for name, c in pairs(d.chars or {}) do
    if c.guild == Store.slotKey() then
      chars[#chars + 1] = { name = name, level = c.level or 1, slots = c.slots or {},
        prof = c.prof or {}, cook = c.cook or 0, aid = c.aid or 0, fish = c.fish or 0 }
    end
  end
  table.sort(chars, function(a, b) return Util.byteLess(a.name, b.name) end)
  return { updated = Time.now(), player = Player.PlayerId(), version = ns.Build.version,
    dataVersion = ns.Build.dataVersion, hours = hoursMask(), gold = goldBracket(), chars = chars }
end

-- Shares the card when something on it changed.
function Player.Publish()
  if ns.disabled or not Time.isLive() then return end
  local card = Player.BuildCard()
  local w = ns.Bytes.writer()
  local probe = Util.copy(card)
  probe.updated = 0
  Pieces.writeCard(w, Player.AccountId(), probe)
  local enc = w:result()
  if enc == lastPublished then return end
  lastPublished = enc
  Store.SetCard(Player.AccountId(), card)
end

local publishPending = false
function Player.Changed(delay)
  if publishPending then return end
  publishPending = true
  ns.After(delay or 10, function()
    publishPending = false
    Player.Refresh()
    Player.Publish()
  end)
end

-- Played today ------------------------------------------------------------------------

local playedDay
function Player.NotePlayed()
  if not Time.isLive() or not ns.me then return end
  notePlayHour()
  local today = Time.day()
  if playedDay ~= today then
    playedDay = today
    Store.AddPlayed(today, ns.me)
    Player.Publish()
  end
end

-- A second license ----------------------------------------------------------------------

function Player.LinkCode()
  return Util.linkCode(Player.AccountId())
end

function Player.Link(code)
  local id = Util.parseLinkCode(code)
  if not id then return false end
  if id == Player.AccountId() then return false end
  db().linkedTo = id
  lastPublished = nil
  Player.Publish()
  return true
end

function Player.Unlink()
  db().linkedTo = nil
  lastPublished = nil
  Player.Publish()
end

function Player.Init()
  Player.AccountId()
  Player.Refresh()
  Player.NotePlayed()
  Player.Publish()
  ns.Every(60, Player.NotePlayed)
  Events.On("PLAYER_LEVEL_UP", function() Player.Changed(3) end)
  Events.On("PLAYER_EQUIPMENT_CHANGED", function() Player.Changed(10) end)
  Events.On("SKILL_LINES_CHANGED", function() Player.Changed(10) end)
  Events.On("PLAYER_MONEY", function() Player.Changed(60) end)
  Events.On("PLAYER_LOGOUT", function() Player.Refresh() end)
end
