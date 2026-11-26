--[[---------------------------------------------------------------------------------
  Skilly - by faslkjd56
  WoW Forever 1.60.1 craft advisor
  Sources.lua - price and count source registry
------------------------------------------------------------------------------------]]

Skilly = Skilly or {}
Skilly.Internal = Skilly.Internal or {}
local Internal = Skilly.Internal

-- SB-43: a disabled source is never called, not merely ignored by callers.
local function featureEnabled(key, default)
  if type(Skilly.FeatureEnabled) ~= "function" then return default end
  local ok, value = pcall(Skilly.FeatureEnabled, key, default)
  if ok and type(value) == "boolean" then return value end
  return default
end

-- SB-26: ordered, read-only price/count source registry.
Skilly.Sources = {}

local sourceCache = {}
local candidateCache = {}
local NO_SOURCE_VALUE = {}

function Skilly.ResetSourceCache()
  sourceCache = {}
  candidateCache = {}

  local hooks = Internal and Internal.ResetHooks or nil
  if type(hooks) ~= "table" then return end
  for _, fn in ipairs(hooks) do
    if type(fn) == "function" then pcall(fn) end
  end
end

function Skilly.RegisterSource(name, source)
  if type(name) ~= "string" or name == "" or type(source) ~= "table" then
    return false
  end
  for _, entry in ipairs(Skilly.Sources) do
    if entry.name == name then
      entry.source = source
      Skilly.ResetSourceCache()
      return true
    end
  end
  Skilly.Sources[#Skilly.Sources + 1] = { name = name, source = source }
  Skilly.ResetSourceCache()
  return true
end

-- SB-38: return every positive value from registered sources with its registry
-- name. The cached array is read-only; callers must not mutate it.
function Skilly.SourceCandidates(kind, itemKey, link, itemID)
  if type(kind) ~= "string" or type(itemKey) ~= "string" then return {} end

  local cacheKey = kind .. ":" .. itemKey
  local cached = candidateCache[cacheKey]
  if cached then
    if cached == NO_SOURCE_VALUE then return {} end
    return cached
  end

  local results = {}
  local allowVendorPrice = featureEnabled("useVendorPrices", true)
  for _, entry in ipairs(Skilly.Sources) do
    local method = entry.source and entry.source[kind]
    if type(method) == "function"
        and (kind ~= "vendorPrice" or allowVendorPrice) then
      local ok, result = pcall(method, itemKey, link, itemID)
      if ok then
        if type(result) == "table" then
          for _, row in ipairs(result) do
            if type(row) == "table" then
              local value = tonumber(row.value or row[1])
              if value and value > 0 then
                results[#results + 1] = {
                  name = entry.name,
                  value = value,
                  category = type(row.category) == "string" and row.category or nil,
                  combined = row.combined == true,
                }
              end
            end
          end
        else
          local value = tonumber(result)
          if value and value > 0 then
            results[#results + 1] = { name = entry.name, value = value }
          end
        end
      end
    end
  end

  candidateCache[cacheKey] = #results > 0 and results or NO_SOURCE_VALUE
  return results
end

function Skilly.SourceValue(kind, itemKey, link, itemID)
  if type(kind) ~= "string" or type(itemKey) ~= "string" then return nil end

  local cacheKey = kind .. ":" .. itemKey
  local cached = sourceCache[cacheKey]
  if cached ~= nil then
    if cached == NO_SOURCE_VALUE then return nil end
    return cached
  end

  local value = nil

  if kind == "price" and SkillyDB and type(SkillyDB.prices) == "table" then
    local manual = tonumber(SkillyDB.prices[itemKey])
    if manual and manual >= 0 then value = manual end
  end

  if value == nil then
    local candidates = Skilly.SourceCandidates(kind, itemKey, link, itemID)
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
Skilly.optionalAddons = optionalAddons

local function tsmItemString(itemKey, link, itemID)
  local api = _G.TSM_API
  if type(api) ~= "table" or type(api.ToItemString) ~= "function" then return nil end

  local id = Internal.NumericItemID(itemKey, link, itemID)
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

  Skilly.RegisterSource("tsm", {
    price = function(itemKey, link, itemID)
      local itemString = tsmItemString(itemKey, link, itemID)
      if not itemString or type(api.GetCustomPriceValue) ~= "function" then return nil end

      local source = SkillyDB and SkillyDB.tsmPriceSource or "dbmarket"
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

      -- SB-88: Skilly counts the player's own bags separately. Only the alts
      -- component can be claimed as alts; the player component would overlap
      -- bags, and bank/mail/guild cannot be split from the alts figure.
      if type(api.GetPlayerTotals) == "function" then
        local ok, _, alts = pcall(api.GetPlayerTotals, itemString)
        if ok then
          local altCount = tonumber(alts)
          if altCount and altCount > 0 then
            return { { value = math.floor(altCount), category = "alts" } }
          end
          return nil
        end
      end

      local total = 0
      if type(api.GetBankQuantity) == "function" then
        total = total + (Internal.CallNumber(api.GetBankQuantity, itemString) or 0)
      end
      if type(api.GetMailQuantity) == "function" then
        total = total + (Internal.CallNumber(api.GetMailQuantity, itemString) or 0)
      end
      if type(api.GetGuildQuantity) == "function" then
        total = total + (Internal.CallNumber(api.GetGuildQuantity, itemString) or 0)
      end

      if total > 0 then
        return { { value = math.floor(total), combined = true } }
      end
      return nil
    end,
  })
end

local AUCTIONATOR_CALLER = "Skilly"

local function auctionatorHasAgeAPI(v1)
  return type(v1.GetAuctionAgeByItemID) == "function"
    or type(v1.GetAuctionAgeByItemLink) == "function"
end

local function auctionatorAge(v1, id, link)
  local age = nil
  if id and type(v1.GetAuctionAgeByItemID) == "function" then
    age = Internal.CallNumber(v1.GetAuctionAgeByItemID, AUCTIONATOR_CALLER, id)
  end
  if age == nil and link and type(v1.GetAuctionAgeByItemLink) == "function" then
    age = Internal.CallNumber(v1.GetAuctionAgeByItemLink, AUCTIONATOR_CALLER, link)
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

  Skilly.RegisterSource("auctionator", {
    price = function(itemKey, link, itemID)
      local id = Internal.NumericItemID(itemKey, link, itemID)
      local value = nil
      if id and type(v1.GetAuctionPriceByItemID) == "function" then
        value = Internal.CallNumber(v1.GetAuctionPriceByItemID, AUCTIONATOR_CALLER, id)
      end
      if value == nil and link and type(v1.GetAuctionPriceByItemLink) == "function" then
        value = Internal.CallNumber(v1.GetAuctionPriceByItemLink, AUCTIONATOR_CALLER, link)
      end
      if not value or value <= 0 then return nil end
      if auctionatorHasAgeAPI(v1) and auctionatorAge(v1, id, link) == nil then
        return nil
      end
      return value
    end,

    vendorPrice = function(itemKey, link, itemID)
      local id = Internal.NumericItemID(itemKey, link, itemID)
      local value = nil
      if id and type(v1.GetVendorPriceByItemID) == "function" then
        value = Internal.CallNumber(v1.GetVendorPriceByItemID, AUCTIONATOR_CALLER, id)
      end
      if value == nil and link and type(v1.GetVendorPriceByItemLink) == "function" then
        value = Internal.CallNumber(v1.GetVendorPriceByItemLink, AUCTIONATOR_CALLER, link)
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

  Skilly.RegisterSource("carbonite", {
    count = function(itemKey, link, itemID)
      local id = Internal.NumericItemID(itemKey, link, itemID)
      if not id then return nil end
      local value = Internal.CallNumber(warehouse.CountItem, warehouse, id)
      if value and value > 0 then
        return { { value = math.floor(value), combined = true } }
      end
      return nil
    end,
  })
end

function Skilly.InitSources()
  -- Rebuild so a source whose public API disappeared is not left registered.
  Skilly.Sources = {}
  Skilly.ResetSourceCache()
  -- SB-38: full-scan AH sources first for readability. Cheapest selection
  -- means registration order no longer changes the chosen price.
  -- SB-43: a disabled adapter is never registered, so it cannot be called.
  if featureEnabled("useAuctionator", true) then registerAuctionatorSource() end
  -- SB-33: guarded registerAuctioneerSource() goes here once SB-30 verifies an API.
  if featureEnabled("useAuctioneer", true) then
    -- no adapter registered yet
  end
  if featureEnabled("useTSM", true) then registerTSMSource() end
  registerCarboniteSource()
end
