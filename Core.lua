--[[---------------------------------------------------------------------------------
  SkillBuddy - by faslkjd56
  WoW Forever 1.60.1 craft advisor
------------------------------------------------------------------------------------]]

SkillBuddy = SkillBuddy or {}

SkillBuddy.Defaults = {
  schema = 1,
  mode = "cheap",
  includeBank = false,
  resultCount = 5,
  minimap = { point = "CENTER", x = 0, y = 0, visible = true },
  prices = {},
  ignored = {},
  assumePurchasable = true,
  asIfOwned = {},
  tsmPriceSource = "dbmarket",
}

local charDefaults = {
  schema = 1,
  learned = {},
  observations = {},
}

-- Fill only nil fields so user values (including false) are never replaced.
local function fillMissing(dst, src)
  if type(dst) ~= "table" then return end
  for key, value in pairs(src) do
    if dst[key] == nil then
      if type(value) == "table" then
        dst[key] = {}
        fillMissing(dst[key], value)
      else
        dst[key] = value
      end
    elseif type(value) == "table" and type(dst[key]) == "table" then
      fillMissing(dst[key], value)
    end
  end
end

function SkillBuddy.InitDB()
  if type(SkillBuddyDB) ~= "table" then SkillBuddyDB = {} end
  if type(SkillBuddyCharDB) ~= "table" then SkillBuddyCharDB = {} end

  fillMissing(SkillBuddyDB, SkillBuddy.Defaults)
  fillMissing(SkillBuddyCharDB, charDefaults)
end

-- Command registry lives here because Core.lua loads before feature modules.
SkillBuddy.commands = SkillBuddy.commands or {}

function SkillBuddy.RegisterCommand(name, fn)
  if type(name) ~= "string" or type(fn) ~= "function" then return end
  SkillBuddy.commands[string.lower(name)] = fn
end

function SkillBuddy.Print(message)
  if DEFAULT_CHAT_FRAME and DEFAULT_CHAT_FRAME.AddMessage then
    DEFAULT_CHAT_FRAME:AddMessage("[SkillBuddy] " .. tostring(message))
  end
end

-- SB-05: read-only trade-skill API diagnostics.
local probeApis = {
  "GetTradeSkillLine",
  "GetNumTradeSkills",
  "GetTradeSkillInfo",
  "GetTradeSkillRecipeLink",
  "GetTradeSkillItemLink",
  "GetTradeSkillNumReagents",
  "GetTradeSkillReagentInfo",
  "GetTradeSkillNumMade",
  "GetTradeSkillCooldown",
  "GetItemCount",
  "GetContainerNumSlots",
  "GetContainerItemID",
}

local function callAndPrint(label, fn, ...)
  if type(fn) ~= "function" then return end
  local results = { pcall(fn, ...) }
  local ok = table.remove(results, 1)
  if not ok then
    SkillBuddy.Print(label .. " error: " .. tostring(results[1]))
    return
  end

  local parts = {}
  for i = 1, math.min(#results, 6) do
    parts[i] = tostring(results[i])
  end
  SkillBuddy.Print(label .. " = " .. table.concat(parts, ", "))
end

function SkillBuddy.Probe()
  for _, name in ipairs(probeApis) do
    local state = type(_G[name]) == "function" and "available" or "missing"
    SkillBuddy.Print(name .. ": " .. state)
  end

  local open = false
  if type(_G.GetNumTradeSkills) == "function" then
    local ok, count = pcall(_G.GetNumTradeSkills)
    if ok and type(count) == "number" and count > 0 then open = true end
  end
  if not open and type(_G.GetTradeSkillLine) == "function" then
    local ok, name = pcall(_G.GetTradeSkillLine)
    if ok and name then open = true end
  end

  if open then
    callAndPrint("GetTradeSkillLine()", _G.GetTradeSkillLine)
    callAndPrint("GetTradeSkillInfo(1)", _G.GetTradeSkillInfo, 1)
  else
    SkillBuddy.Print("No profession window detected.")
  end
end

SkillBuddy.RegisterCommand("probe", SkillBuddy.Probe)

-- SB-06: normalized snapshot of the open trade-skill window.
SkillBuddy.Scan = SkillBuddy.Scan or {}

local function safeResults(name, ...)
  local fn = _G[name]
  if type(fn) ~= "function" then return nil end
  local results = { pcall(fn, ...) }
  if not table.remove(results, 1) then return nil end
  return results
end

local function itemKey(link, name)
  local id = link and string.match(link, "item:(%d+)")
  if id then return "item:" .. id end
  if name and name ~= "" then return string.lower(name) end
  return ""
end

-- SB-37: recipe links carry the spell/recipe ID used by the threshold table.
-- Never fall back to an item link: an item ID is not a spell ID.
local function spellIDFromLink(link)
  if type(link) ~= "string" then return nil end
  local id = string.match(link, "spell:(%d+)")
  if not id then id = string.match(link, "trade:[^:]+:(%d+)") end
  if not id then return nil end
  id = tonumber(id)
  if id and id > 0 then return math.floor(id) end
  return nil
end

local function numeric(value, fallback)
  local n = tonumber(value)
  if n == nil then return fallback end
  return n
end

-- Shared adapter helpers: never trust external addon data or calls.
local function numericItemID(itemKey, link, itemID)
  if itemID ~= nil then
    local id = tonumber(itemID)
    if id and id > 0 then return math.floor(id) end
  end
  if type(link) == "string" then
    local id = string.match(link, "item:(%d+)")
    if id then return tonumber(id) end
  end
  if type(itemKey) == "string" then
    local id = string.match(itemKey, "^item:(%d+)$")
    if id then return tonumber(id) end
  end
  return nil
end

-- SB-32: one canonical key for manual prices and the as-if-owned list.
-- Item IDs win; otherwise use the trimmed, lower-case name. Links without an
-- item ID are treated as a name copied from the link text.
function SkillBuddy.NormalizeItemKey(value)
  if type(value) ~= "string" then return nil end
  value = string.gsub(value, "^%s+", "")
  value = string.gsub(value, "%s+$", "")
  if value == "" then return nil end

  -- A spell link is not an item and must not become a name-based key.
  if string.match(value, "spell:(%d+)") and not string.match(value, "item:(%d+)") then
    return nil
  end

  local numericID = tonumber(value)
  if numericID and numericID > 0 then
    return "item:" .. tostring(math.floor(numericID))
  end

  local id = numericItemID(value, value, nil)
  if id and id > 0 then
    return "item:" .. tostring(math.floor(id))
  end

  local name = string.match(value, "|h%[(.-)%]|h")
  if name then value = name end
  value = string.gsub(value, "^%s+", "")
  value = string.gsub(value, "%s+$", "")
  if value == "" then return nil end
  return string.lower(value)
end

local function callNumber(fn, ...)
  if type(fn) ~= "function" then return nil end
  local ok, value = pcall(fn, ...)
  if not ok then return nil end
  return tonumber(value)
end

-- SB-26: ordered, read-only price/count source registry.
SkillBuddy.Sources = {}

local sourceCache = {}
local candidateCache = {}
local itemCountCache = {}
local NO_SOURCE_VALUE = {}

function SkillBuddy.ResetSourceCache()
  sourceCache = {}
  candidateCache = {}
  itemCountCache = {}
end

function SkillBuddy.RegisterSource(name, source)
  if type(name) ~= "string" or name == "" or type(source) ~= "table" then
    return false
  end
  for _, entry in ipairs(SkillBuddy.Sources) do
    if entry.name == name then
      entry.source = source
      SkillBuddy.ResetSourceCache()
      return true
    end
  end
  SkillBuddy.Sources[#SkillBuddy.Sources + 1] = { name = name, source = source }
  SkillBuddy.ResetSourceCache()
  return true
end

-- SB-38: return every positive value from registered sources with its registry
-- name. The cached array is read-only; callers must not mutate it.
function SkillBuddy.SourceCandidates(kind, itemKey, link, itemID)
  if type(kind) ~= "string" or type(itemKey) ~= "string" then return {} end

  local cacheKey = kind .. ":" .. itemKey
  local cached = candidateCache[cacheKey]
  if cached then
    if cached == NO_SOURCE_VALUE then return {} end
    return cached
  end

  local results = {}
  for _, entry in ipairs(SkillBuddy.Sources) do
    local method = entry.source and entry.source[kind]
    if type(method) == "function" then
      local ok, result = pcall(method, itemKey, link, itemID)
      if ok then
        local value = tonumber(result)
        if value and value > 0 then
          results[#results + 1] = { name = entry.name, value = value }
        end
      end
    end
  end

  candidateCache[cacheKey] = #results > 0 and results or NO_SOURCE_VALUE
  return results
end

function SkillBuddy.SourceValue(kind, itemKey, link, itemID)
  if type(kind) ~= "string" or type(itemKey) ~= "string" then return nil end

  local cacheKey = kind .. ":" .. itemKey
  local cached = sourceCache[cacheKey]
  if cached ~= nil then
    if cached == NO_SOURCE_VALUE then return nil end
    return cached
  end

  local value = nil

  if kind == "price" and SkillBuddyDB and type(SkillBuddyDB.prices) == "table" then
    local manual = tonumber(SkillBuddyDB.prices[itemKey])
    if manual and manual >= 0 then value = manual end
  end

  if value == nil then
    local candidates = SkillBuddy.SourceCandidates(kind, itemKey, link, itemID)
    if candidates[1] then value = candidates[1].value end
  end

  sourceCache[cacheKey] = value or NO_SOURCE_VALUE
  return value
end

-- SB-27..SB-29: optional adapters are registered after addons have loaded.
local optionalAddons = {
  "TradeSkillMaster",
  "Auctionator",
  "Carbonite",
  "Carbonite.Warehouse",
  "CarboniteWarehouse",
}
SkillBuddy.optionalAddons = optionalAddons

local function tsmItemString(itemKey, link, itemID)
  local api = _G.TSM_API
  if type(api) ~= "table" or type(api.ToItemString) ~= "function" then return nil end

  local id = numericItemID(itemKey, link, itemID)
  local candidate = link
  if not candidate and id then candidate = "item:" .. id end
  if not candidate and type(itemKey) == "string" and itemKey ~= "" then
    candidate = itemKey
  end
  if not candidate then return nil end

  local ok, result = pcall(api.ToItemString, candidate)
  if ok and type(result) == "string" and result ~= "" then return result end
  return nil
end

local function tsmPriceSourceKnown(api, source)
  if type(api.GetPriceSourceKeys) ~= "function" then return true end
  local ok, keys = pcall(api.GetPriceSourceKeys, {})
  if not ok or type(keys) ~= "table" then return true end
  for _, key in ipairs(keys) do
    if key == source then return true end
  end
  return false
end

local function registerTSMSource()
  local api = _G.TSM_API
  if type(api) ~= "table" then return end
  if type(api.GetCustomPriceValue) ~= "function"
      and type(api.GetPlayerTotals) ~= "function"
      and type(api.GetBagQuantity) ~= "function"
      and type(api.GetBankQuantity) ~= "function"
      and type(api.GetMailQuantity) ~= "function"
      and type(api.GetGuildQuantity) ~= "function" then
    return
  end

  SkillBuddy.RegisterSource("tsm", {
    price = function(itemKey, link, itemID)
      local itemString = tsmItemString(itemKey, link, itemID)
      if not itemString or type(api.GetCustomPriceValue) ~= "function" then return nil end

      local source = SkillBuddyDB and SkillBuddyDB.tsmPriceSource or "dbmarket"
      if type(source) ~= "string" or source == "" then source = "dbmarket" end

      local ok, value, err = pcall(api.GetCustomPriceValue, source, itemString)
      if ok and type(value) == "number" then return value end

      if source ~= "dbmarket" and type(err) == "string"
          and not tsmPriceSourceKnown(api, source) then
        local fallbackOK, fallback = pcall(api.GetCustomPriceValue, "dbmarket", itemString)
        if fallbackOK and type(fallback) == "number" then return fallback end
      end
      return nil
    end,

    count = function(itemKey, link, itemID)
      local itemString = tsmItemString(itemKey, link, itemID)
      if not itemString then return nil end

      -- SkillBuddy reads the player's own bags in SB-07; sources answer for
      -- stock outside them (bank, mail, alts, guild bank).
      local total = nil
      if type(api.GetPlayerTotals) == "function" then
        local ok, player, alts = pcall(api.GetPlayerTotals, itemString)
        if ok then total = (tonumber(player) or 0) + (tonumber(alts) or 0) end
      end

      if total == nil then
        total = 0
        if type(api.GetBankQuantity) == "function" then
          total = total + (callNumber(api.GetBankQuantity, itemString) or 0)
        end
        if type(api.GetMailQuantity) == "function" then
          total = total + (callNumber(api.GetMailQuantity, itemString) or 0)
        end
      end

      if type(api.GetGuildQuantity) == "function" then
        total = total + (callNumber(api.GetGuildQuantity, itemString) or 0)
      end

      if total and total > 0 then return math.floor(total) end
      return nil
    end,
  })
end

local AUCTIONATOR_CALLER = "SkillBuddy"

local function auctionatorHasAgeAPI(v1)
  return type(v1.GetAuctionAgeByItemID) == "function"
    or type(v1.GetAuctionAgeByItemLink) == "function"
end

local function auctionatorAge(v1, id, link)
  local age = nil
  if id and type(v1.GetAuctionAgeByItemID) == "function" then
    age = callNumber(v1.GetAuctionAgeByItemID, AUCTIONATOR_CALLER, id)
  end
  if age == nil and link and type(v1.GetAuctionAgeByItemLink) == "function" then
    age = callNumber(v1.GetAuctionAgeByItemLink, AUCTIONATOR_CALLER, link)
  end
  return age
end

local function registerAuctionatorSource()
  local addon = _G.Auctionator
  if type(addon) ~= "table" or type(addon.API) ~= "table" then return end
  local v1 = addon.API.v1
  if type(v1) ~= "table" then return end
  if type(v1.GetAuctionPriceByItemID) ~= "function"
      and type(v1.GetAuctionPriceByItemLink) ~= "function"
      and type(v1.GetVendorPriceByItemID) ~= "function"
      and type(v1.GetVendorPriceByItemLink) ~= "function" then
    return
  end

  SkillBuddy.RegisterSource("auctionator", {
    price = function(itemKey, link, itemID)
      local id = numericItemID(itemKey, link, itemID)
      local value = nil
      if id and type(v1.GetAuctionPriceByItemID) == "function" then
        value = callNumber(v1.GetAuctionPriceByItemID, AUCTIONATOR_CALLER, id)
      end
      if value == nil and link and type(v1.GetAuctionPriceByItemLink) == "function" then
        value = callNumber(v1.GetAuctionPriceByItemLink, AUCTIONATOR_CALLER, link)
      end
      if not value or value <= 0 then return nil end
      if auctionatorHasAgeAPI(v1) and auctionatorAge(v1, id, link) == nil then
        return nil
      end
      return value
    end,

    vendorPrice = function(itemKey, link, itemID)
      local id = numericItemID(itemKey, link, itemID)
      local value = nil
      if id and type(v1.GetVendorPriceByItemID) == "function" then
        value = callNumber(v1.GetVendorPriceByItemID, AUCTIONATOR_CALLER, id)
      end
      if value == nil and link and type(v1.GetVendorPriceByItemLink) == "function" then
        value = callNumber(v1.GetVendorPriceByItemLink, AUCTIONATOR_CALLER, link)
      end
      if value and value > 0 then return value end
      return nil
    end,
  })
end

local function registerCarboniteSource()
  local addon = _G.Carbonite
  if type(addon) ~= "table" or type(addon.Plugins) ~= "table" then return end
  local warehouse = addon.Plugins.Warehouse
  if type(warehouse) ~= "table" or type(warehouse.CountItem) ~= "function" then
    return
  end

  SkillBuddy.RegisterSource("carbonite", {
    count = function(itemKey, link, itemID)
      local id = numericItemID(itemKey, link, itemID)
      if not id then return nil end
      local value = callNumber(warehouse.CountItem, warehouse, id)
      if value and value > 0 then return math.floor(value) end
      return nil
    end,
  })
end

function SkillBuddy.InitSources()
  -- Rebuild so a source whose public API disappeared is not left registered.
  SkillBuddy.Sources = {}
  SkillBuddy.ResetSourceCache()
  -- SB-38: full-scan AH sources first for readability. Cheapest selection
  -- means registration order no longer changes the chosen price.
  registerAuctionatorSource()
  -- SB-33: registerAuctioneerSource() goes here once SB-30 verifies a public API.
  registerTSMSource()
  registerCarboniteSource()
end

function SkillBuddy.Scan.Current()
  SkillBuddy.ResetSourceCache()
  local countResults = safeResults("GetNumTradeSkills")
  local count = countResults and countResults[1] or 0
  local lineResults = safeResults("GetTradeSkillLine")
  local profession = lineResults and lineResults[1] or nil

  if type(count) ~= "number" or count <= 0 then
    if not profession or profession == "" then return nil end
    count = 0
  end

  local skill = lineResults and numeric(lineResults[2], 0) or 0
  local maxSkill = lineResults and numeric(lineResults[3], 0) or 0

  local snapshot = {
    profession = profession or "",
    skill = skill,
    maxSkill = maxSkill,
    recipes = {},
  }

  for i = 1, count do
    local info = safeResults("GetTradeSkillInfo", i)
    if info then
      local name = info[1]
      local difficulty = info[2]
      if name and name ~= "" and difficulty ~= "header" then
        local linkResults = safeResults("GetTradeSkillRecipeLink", i)
        local link = linkResults and linkResults[1] or nil
        local spellID = spellIDFromLink(link)
        if not link then
          linkResults = safeResults("GetTradeSkillItemLink", i)
          link = linkResults and linkResults[1] or nil
        end

        local reagents = {}
        local numReagents = safeResults("GetTradeSkillNumReagents", i)
        local reagentCount = numReagents and numeric(numReagents[1], 0) or 0
        for j = 1, reagentCount do
          local reagent = safeResults("GetTradeSkillReagentInfo", i, j)
          if reagent then
            local reagentName = reagent[1]
            local reagentCountValue = reagent[2]
            local reagentLink = reagent[3]
            if reagentName and reagentName ~= "" then
              reagents[#reagents + 1] = {
                name = reagentName,
                count = numeric(reagentCountValue, 0),
                link = reagentLink,
                key = itemKey(reagentLink, reagentName),
              }
            end
          end
        end

        if #reagents > 0 then
          local made = safeResults("GetTradeSkillNumMade", i)
          local madeMin = made and numeric(made[1], 1) or 1
          local madeMax = made and numeric(made[2], madeMin) or madeMin
          local cooldownResults = safeResults("GetTradeSkillCooldown", i)
          local cooldown = cooldownResults and numeric(cooldownResults[1], 0) or 0

          snapshot.recipes[#snapshot.recipes + 1] = {
            index = i,
            name = name,
            key = string.lower(name),
            difficulty = difficulty or "",
            link = link,
            spellID = spellID,
            reagents = reagents,
            madeMin = madeMin,
            madeMax = madeMax,
            cooldown = cooldown,
          }
        end
      end
    end
  end

  SkillBuddy.lastSnapshot = snapshot
  return snapshot
end

-- SB-07: owned item counts. SkillBuddy reads the player's own bags itself;
-- optional sources only answer for stock outside them.
SkillBuddy.Cost = SkillBuddy.Cost or {}

-- SB-32: default-on availability flag. Explicit false is the only opt-out.
function SkillBuddy.Cost.AssumePurchasable()
  local db = type(SkillBuddyDB) == "table" and SkillBuddyDB or nil
  if not db then return true end
  return db.assumePurchasable ~= false
end

-- SB-32: a curated free material. Wrong types and non-boolean values are not
-- treated as entries so a corrupt SavedVariable cannot silently change advice.
function SkillBuddy.Cost.IsAsIfOwned(reagentOrKey)
  local db = type(SkillBuddyDB) == "table" and SkillBuddyDB.asIfOwned or nil
  if type(db) ~= "table" then return false end

  local key = reagentOrKey
  if type(reagentOrKey) == "table" then key = reagentOrKey.key end
  if type(key) ~= "string" or key == "" then return false end
  return db[key] == true
end

local function countFromClient(key, link, itemID, name)
  local candidates = {}
  if itemID then candidates[#candidates + 1] = itemID end
  if type(link) == "string" and link ~= "" then candidates[#candidates + 1] = link end
  if type(name) == "string" and name ~= "" then candidates[#candidates + 1] = name end

  local includeBank = SkillBuddyDB and SkillBuddyDB.includeBank == true
  for _, identifier in ipairs(candidates) do
    local results = safeResults("GetItemCount", identifier, includeBank)
    local value = results and tonumber(results[1]) or nil
    if value and value > 0 then return math.floor(value) end
  end
  return nil
end

local function countInBags(itemID, name)
  local total = 0
  for bag = 0, 4 do
    local slots = callNumber(_G.GetContainerNumSlots, bag) or 0
    for slot = 1, slots do
      local slotID = callNumber(_G.GetContainerItemID, bag, slot)
      if slotID and slotID > 0 then
        -- GetContainerItemInfo returns the stack count as its second value.
        local info = safeResults("GetContainerItemInfo", bag, slot)
        local stack = info and tonumber(info[2]) or 0
        if stack > 0 then
          if itemID and slotID == itemID then
            total = total + stack
          elseif not itemID and name and type(_G.GetItemInfo) == "function" then
            local ok, itemName = pcall(_G.GetItemInfo, slotID)
            if ok and type(itemName) == "string" and string.lower(itemName) == name then
              total = total + stack
            end
          end
        end
      end
    end
  end
  return total
end

function SkillBuddy.Cost.ItemCount(reagent)
  if type(reagent) ~= "table" then return 0 end

  local key = reagent.key
  if type(key) ~= "string" or key == "" then
    key = itemKey(reagent.link, reagent.name)
  end
  local link = reagent.link
  local name = type(reagent.name) == "string" and string.lower(reagent.name) or nil
  local itemID = numericItemID(key, link, reagent.itemID)
  if key == "" and itemID then key = "item:" .. itemID end
  if key == "" then return 0 end

  local cached = itemCountCache[key]
  if cached ~= nil then return cached end

  local count = countFromClient(key, link, itemID, name)
  if not count then
    count = SkillBuddy.SourceValue("count", key, link, itemID)
  end
  if not count or count <= 0 then
    count = countInBags(itemID, name)
  end

  count = tonumber(count) or 0
  if count < 0 then count = 0 end
  count = math.floor(count)
  itemCountCache[key] = count
  return count
end

-- SB-10: one canonical key for prices, counts, and explanations.
local function reagentKey(reagent)
  if type(reagent) ~= "table" then return "" end
  if type(reagent.key) == "string" and reagent.key ~= "" then
    return reagent.key
  end
  return SkillBuddy.NormalizeItemKey(reagent.link)
      or SkillBuddy.NormalizeItemKey(reagent.name)
      or ""
end

-- SB-38: cheapest reliable price wins; the source only breaks exact ties.
-- Manual prices are handled first so they always beat automatic candidates.
function SkillBuddy.Cost.PriceFor(reagent)
  if type(reagent) ~= "table" then return 1, "default" end

  local key = reagentKey(reagent)
  local link = reagent.link
  local name = type(reagent.name) == "string" and string.lower(reagent.name) or nil
  local itemID = numericItemID(key, link, reagent.itemID)

  local db = type(SkillBuddyDB) == "table" and SkillBuddyDB or nil
  if db and type(db.prices) == "table" and key ~= "" then
    local manual = tonumber(db.prices[key])
    if manual and manual >= 0 then return manual, "manual" end
  end

  local bestPrice, bestSource, bestRank = nil, nil, nil
  local function consider(price, source, rank)
    price = tonumber(price)
    if not price or price < 0 then return end
    if bestPrice == nil or price < bestPrice
        or (price == bestPrice and rank < bestRank) then
      bestPrice, bestSource, bestRank = price, source, rank
    end
  end

  if SkillBuddy.Cost.IsAsIfOwned(key ~= "" and key or reagent) then
    consider(0, "as-if", 0)
  end

  if itemID and type(SkillBuddy.VendorPrices) == "table" then
    consider(SkillBuddy.VendorPrices[itemID], "vendor", 1)
  end

  if key ~= "" then
    for _, candidate in ipairs(SkillBuddy.SourceCandidates("vendorPrice", key, link, itemID)) do
      consider(candidate.value, "vendor", 1)
    end
    for _, candidate in ipairs(SkillBuddy.SourceCandidates("price", key, link, itemID)) do
      local label = candidate.name
      local rank = 4
      if label == "auctionator" or label == "auctioneer" then
        rank = 2
      elseif label == "tsm" then
        rank = 3
      end
      consider(candidate.value, label, rank)
    end
  end

  if bestPrice then return bestPrice, bestSource end
  return 1, "default"
end

-- SB-39: same lookup plus confidence. "default" means no reliable price was
-- found, so ranking must use a scarcity estimate instead of the copper value.
function SkillBuddy.Cost.PriceInfo(reagent)
  local price, source = SkillBuddy.Cost.PriceFor(reagent)
  return price, source, source ~= "default"
end

-- SB-10: cost for one craft. Only missing units are charged in `total`;
-- `fullCost` prices every required unit for comparison.
function SkillBuddy.Cost.Recipe(recipe)
  local result = { total = 0, fullCost = 0, detail = {} }
  if type(recipe) ~= "table" or type(recipe.reagents) ~= "table" then
    return result
  end

  for _, reagent in ipairs(recipe.reagents) do
    if type(reagent) == "table" then
      local required = tonumber(reagent.count) or 0
      if required < 0 then required = 0 end
      required = math.floor(required)

      local owned = SkillBuddy.Cost.ItemCount(reagent)
      local need = required - owned
      if need < 0 then need = 0 end

      local price, source = SkillBuddy.Cost.PriceFor(reagent)
      price = tonumber(price) or 1
      if price < 0 then price = 0 end

      local subtotal = need * price
      result.total = result.total + subtotal
      result.fullCost = result.fullCost + required * price
      result.detail[#result.detail + 1] = {
        name = reagent.name,
        key = reagentKey(reagent),
        required = required,
        owned = owned,
        need = need,
        price = price,
        subtotal = subtotal,
        source = source,
      }
    end
  end

  return result
end

-- SB-09: per-craft skill-up chance, driven by the client's recipe color.
SkillBuddy.Rank = SkillBuddy.Rank or {}

local function learnedThresholds(recipeKey)
  local db = type(SkillBuddyCharDB) == "table" and SkillBuddyCharDB.learned or nil
  if type(db) ~= "table" or type(recipeKey) ~= "string" then return nil end
  local entry = db[recipeKey]
  if type(entry) ~= "table" then return nil end

  local yellow = tonumber(entry.yellow)
  local green = tonumber(entry.green)
  local grey = tonumber(entry.grey)

  -- green is the 50% point: (yellow + grey) / 2. Two values are enough.
  if not yellow or not grey then
    if yellow and green then
      grey = 2 * green - yellow
    elseif green and grey then
      yellow = 2 * green - grey
    end
  end
  if not yellow or not grey or grey <= yellow then return nil end
  return yellow, grey
end

-- SB-37: bundled values are factual game data keyed by the recipe spell ID.
local function bundledThresholds(recipe)
  local tableData = SkillBuddy.Thresholds
  if type(tableData) ~= "table" or type(recipe) ~= "table" then return nil end

  local id = tonumber(recipe.spellID) or spellIDFromLink(recipe.link)
  if not id then return nil end
  id = math.floor(id)
  if id <= 0 then return nil end

  local entry = tableData[id]
  if type(entry) ~= "table" then return nil end

  local yellow = tonumber(entry[1])
  local grey = tonumber(entry[2])
  if not yellow or not grey or grey <= yellow then return nil end
  return yellow, grey
end

-- User-learned values win, then build-pinned game data, then band estimates.
local function thresholdsFor(recipe)
  if type(recipe) ~= "table" then return nil, nil, "estimate" end

  local yellow, grey = learnedThresholds(recipe.key)
  if yellow and grey then return yellow, grey, "learned" end

  yellow, grey = bundledThresholds(recipe)
  if yellow and grey then return yellow, grey, "gameData" end

  return nil, nil, "estimate"
end

function SkillBuddy.Rank.Probability(recipe, skill, maxSkill)
  if type(recipe) ~= "table" then return 0 end
  recipe.thresholdSource = "color"

  local current = tonumber(skill) or 0
  local cap = tonumber(maxSkill) or 0
  if cap > 0 and current >= cap then
    recipe.estimate = false
    return 0
  end

  local detect = SkillBuddy.Difficulty and SkillBuddy.Difficulty.Detect
  if type(detect) ~= "function" then
    recipe.estimate = true
    recipe.thresholdSource = "estimate"
    return 0.25
  end

  local ok, info = pcall(detect, recipe.difficulty)
  if not ok or type(info) ~= "table" then
    recipe.estimate = true
    recipe.thresholdSource = "estimate"
    return 0.25
  end

  if info.color == "gray" then
    recipe.estimate = false
    return 0
  end
  if info.color == "orange" then
    recipe.estimate = false
    return 1
  end

  if info.color == "yellow" or info.color == "green" then
    local yellow, grey, source = thresholdsFor(recipe)
    recipe.thresholdSource = source or "estimate"
    if yellow and grey then
      local p = (grey - current) / (grey - yellow)
      if p < 0 then p = 0 elseif p > 1 then p = 1 end
      recipe.estimate = false
      return p
    end
    recipe.estimate = true
    return tonumber(info.base) or 0.25
  end

  recipe.estimate = true
  recipe.thresholdSource = "estimate"
  return tonumber(info.base) or 0.25
end

-- SB-39: scarcity estimate for one missing unit when no reliable price exists.
-- Runtime item metadata is preferred; the small static table fills gaps when
-- GetItemInfo has no cached data. Never errors on bad items or missing APIs.
function SkillBuddy.Rank.UnitPressure(reagent)
  local detail = {
    tier = 2, ease = 1, kind = "unknown", crossSkill = false, sourceSkill = nil,
  }
  if type(reagent) ~= "table" then return 3, detail end

  local key = reagent.key
  if type(key) ~= "string" or key == "" then
    key = SkillBuddy.NormalizeItemKey(reagent.link)
        or SkillBuddy.NormalizeItemKey(reagent.name)
        or ""
  end
  local itemID = numericItemID(key, reagent.link, reagent.itemID)

  local fallback = nil
  if itemID and type(SkillBuddy.MaterialPressure) == "table" then
    fallback = SkillBuddy.MaterialPressure[itemID]
    if type(fallback) ~= "table" then fallback = nil end
  end

  local rarity, ilvl, itemType, subType = nil, nil, nil, nil
  if type(_G.GetItemInfo) == "function" then
    local identifier = reagent.link or itemID or reagent.name
    local ok, _, _, r, lvl, _, typ, sub = pcall(_G.GetItemInfo, identifier)
    if ok then
      rarity, ilvl, itemType, subType = tonumber(r), tonumber(lvl), typ, sub
    end
  end

  local tier = fallback and tonumber(fallback.tier) or nil
  if not tier then
    local level = ilvl or 10
    if level < 0 then level = 0 elseif level > 150 then level = 150 end
    tier = math.floor(level / 15) + 1
  end
  if tier < 1 then tier = 1 elseif tier > 8 then tier = 8 end
  detail.tier = tier

  local base = 2 ^ (tier - 1)
  local kind = fallback and fallback.kind or nil
  local ease = 1
  if fallback then
    if kind == "gem" then
      ease = 8
    elseif kind == "rare" then
      ease = 12
    elseif kind == "enchanting" then
      ease = 6
    elseif kind == "crafted" then
      ease = 2
    elseif kind == "gathered" then
      ease = 1.5
    end
  else
    local sub = type(subType) == "string" and string.lower(subType) or ""
    local typ = type(itemType) == "string" and string.lower(itemType) or ""
    if string.find(sub, "gem", 1, true) then
      kind, ease = "gem", 8
    elseif string.find(sub, "leather", 1, true) or string.find(sub, "cloth", 1, true)
        or string.find(sub, "herb", 1, true) or string.find(sub, "metal", 1, true)
        or string.find(sub, "stone", 1, true) then
      kind, ease = "gathered", 1.5
    elseif string.find(sub, "potion", 1, true) or string.find(sub, "elixir", 1, true) then
      kind, ease = "consumable", 4
    elseif string.find(sub, "enchant", 1, true) then
      kind, ease = "enchanting", 6
    elseif typ ~= "" then
      kind, ease = "crafted", 2
    end
  end
  detail.kind = kind or "unknown"

  local itemRarity = rarity or (fallback and tonumber(fallback.rarity) or nil)
  if itemRarity and itemRarity >= 2 then
    ease = ease * (itemRarity * 3)
  end

  local sourceSkill = fallback and fallback.sourceSkill or nil
  if not sourceSkill then
    local sub = type(subType) == "string" and string.lower(subType) or ""
    if string.find(sub, "leather", 1, true) then
      sourceSkill = "Leatherworking"
    elseif string.find(sub, "cloth", 1, true) then
      sourceSkill = "Tailoring"
    elseif string.find(sub, "herb", 1, true) then
      sourceSkill = "Herbalism"
    elseif string.find(sub, "metal", 1, true) or string.find(sub, "stone", 1, true) then
      sourceSkill = "Mining"
    elseif string.find(sub, "potion", 1, true) or string.find(sub, "elixir", 1, true) then
      sourceSkill = "Alchemy"
    elseif string.find(sub, "enchant", 1, true) then
      sourceSkill = "Enchanting"
    end
  end

  local profession = SkillBuddy.lastSnapshot and SkillBuddy.lastSnapshot.profession or nil
  if sourceSkill and type(profession) == "string" and profession ~= ""
      and string.lower(profession) ~= string.lower(sourceSkill) then
    detail.crossSkill = true
    ease = ease * 3
  end
  detail.sourceSkill = sourceSkill
  detail.ease = ease

  local pressure = math.ceil(base * ease)
  if pressure < 1 then pressure = 1 end
  return pressure, detail
end

-- SB-39: ranking cost. Known prices stay literal; unknown prices get a
-- scarcity estimate so rare materials no longer look like 1 copper.
function SkillBuddy.Rank.EffectiveCost(recipe)
  local info = { effectiveCost = 0, knownCost = 0, estimatedCost = 0, reagents = {} }
  if type(recipe) ~= "table" then return info end

  if type(recipe.reagents) == "table" then
    for _, reagent in ipairs(recipe.reagents) do
      if type(reagent) == "table" then
        local required = tonumber(reagent.count) or 0
        if required < 0 then required = 0 end
        required = math.floor(required)

        local owned = SkillBuddy.Cost.ItemCount(reagent)
        local need = required - owned
        if need < 0 then need = 0 end

        local price, source, known = SkillBuddy.Cost.PriceInfo(reagent)
        local unitCost, costKind, pressure = price, "known", nil
        if not known then
          unitCost, pressure = SkillBuddy.Rank.UnitPressure(reagent)
          costKind = "estimated"
        end
        unitCost = tonumber(unitCost) or 1
        if unitCost < 0 then unitCost = 0 end

        local contribution = need * unitCost
        info.effectiveCost = info.effectiveCost + contribution
        if known then
          info.knownCost = info.knownCost + contribution
        else
          info.estimatedCost = info.estimatedCost + contribution
        end

        info.reagents[#info.reagents + 1] = {
          name = reagent.name,
          key = reagentKey(reagent),
          need = need,
          unitCost = unitCost,
          costKind = costKind,
          source = source,
          tier = pressure and pressure.tier or nil,
          ease = pressure and pressure.ease or nil,
          crossSkill = pressure and pressure.crossSkill or false,
        }
      end
    end
  end

  info.distinctReagents = #info.reagents
  info.estimatedReagents = 0
  info.crossSkillReagents = 0
  for _, entry in ipairs(info.reagents) do
    if entry.costKind == "estimated" then
      info.estimatedReagents = info.estimatedReagents + 1
    end
    if entry.crossSkill then
      info.crossSkillReagents = info.crossSkillReagents + 1
    end
  end

  recipe.rankInfo = info
  return info
end

-- SB-39: cheapest skill-up per effective material cost. SB-13 will use this.
function SkillBuddy.Rank.Score(recipe, skill, maxSkill)
  local info = SkillBuddy.Rank.EffectiveCost(recipe)
  local probability = SkillBuddy.Rank.Probability(recipe, skill, maxSkill)
  info.probability = probability
  if not probability or probability <= 0 then return math.huge, info end
  return info.effectiveCost / probability, info
end
