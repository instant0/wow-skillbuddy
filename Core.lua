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

local function callNumber(fn, ...)
  if type(fn) ~= "function" then return nil end
  local ok, value = pcall(fn, ...)
  if not ok then return nil end
  return tonumber(value)
end

-- SB-26: ordered, read-only price/count source registry.
SkillBuddy.Sources = {}

local sourceCache = {}
local NO_SOURCE_VALUE = {}

function SkillBuddy.ResetSourceCache()
  sourceCache = {}
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
    value = tonumber(SkillBuddyDB.prices[itemKey])
  end

  if value == nil then
    for _, entry in ipairs(SkillBuddy.Sources) do
      local method = entry.source and entry.source[kind]
      if type(method) == "function" then
        local ok, result = pcall(method, itemKey, link, itemID)
        if ok then
          value = tonumber(result)
          if value ~= nil then break end
        end
      end
    end
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
  registerTSMSource()
  registerAuctionatorSource()
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
