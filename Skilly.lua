--[[---------------------------------------------------------------------------------
  Skilly - by faslkjd56
  WoW Forever 1.60.1 craft advisor
------------------------------------------------------------------------------------]]

Skilly = Skilly or {}
Skilly.version = "0.3.1"

BINDING_HEADER_SKILLY = "Skilly"
BINDING_NAME_SKILLY_NEXT_CRAFT = "Next craft"

-- Real compartment action lands in SB-16.
function Skilly_OnCompartmentClick()
end

local function dbGet(key)
  if type(SkillyDB) ~= "table" then return nil end
  return SkillyDB[key]
end

local function dbSet(key, value)
  if type(SkillyDB) ~= "table" then SkillyDB = {} end
  SkillyDB[key] = value
end

-- SB-43: safe registry access for Settings and debug output.
local function featureEnabled(key, default)
  if type(Skilly.FeatureEnabled) ~= "function" then return default end
  local ok, value = pcall(Skilly.FeatureEnabled, key, default)
  if ok and type(value) == "boolean" then return value end
  return default
end

-- SB-03: native Settings page. Uses the modern Settings API when present.
function Skilly.InitSettings()
  if Skilly.settingsCategory or Skilly.settingsFailed then return end

  local api = Settings
  if not (api and api.RegisterVerticalLayoutCategory and api.RegisterAddOnCategory
      and api.RegisterProxySetting and api.CreateCheckbox and api.CreateSlider
      and api.CreateSliderOptions) then
    Skilly.settingsFailed = true
    return
  end

  local ok = pcall(function()
    if type(Skilly.InitDB) == "function" then Skilly.InitDB() end

    local category = api.RegisterVerticalLayoutCategory("Skilly")
    api.RegisterAddOnCategory(category)
    Skilly.settingsCategory = category

    local function addSetting(name, variable, defaultValue, getter, setter)
      return api.RegisterProxySetting(
        category, variable, type(defaultValue), name, defaultValue, getter, setter
      )
    end

    local function addCheckbox(name, variable, defaultValue, getter, setter, tooltip)
      local setting = addSetting(name, variable, defaultValue, getter, setter)
      api.CreateCheckbox(category, setting, tooltip)
    end

    local function addModeCheckbox()
      addCheckbox(
        "Best skillup mode", "SKILLY_BEST_MODE", false,
        function() return dbGet("mode") == "best" end,
        function(value)
          dbSet("mode", value == true and "best" or "cheap")
        end,
        "On: best skillup. Off: cheapest available skillup."
      )
    end

    local modeSetting = addSetting(
      "Mode", "SKILLY_MODE", "cheap",
      function()
        if dbGet("mode") == "best" then return "best" end
        return "cheap"
      end,
      function(value)
        dbSet("mode", value == "best" and "best" or "cheap")
      end
    )

    if api.CreateDropdown then
      local options = {
        { text = "Cheapest available", value = "cheap" },
        { text = "Best skillup", value = "best" },
      }
      if not pcall(api.CreateDropdown, category, modeSetting, options) then
        addModeCheckbox()
      end
    else
      addModeCheckbox()
    end

    addCheckbox(
      "Include bank", "SKILLY_INCLUDE_BANK", false,
      function() return dbGet("includeBank") == true end,
      function(value) dbSet("includeBank", value == true) end,
      "Count reagents in the bank as well as in bags."
    )

    addCheckbox(
      "Assume purchasable materials", "SKILLY_ASSUME_PURCHASABLE", true,
      function()
        if type(Skilly.Cost.AssumePurchasable) == "function" then
          return Skilly.Cost.AssumePurchasable() == true
        end
        return dbGet("assumePurchasable") ~= false
      end,
      function(value)
        dbSet("assumePurchasable", value == true)
        if type(Skilly.ResetSourceCache) == "function" then
          pcall(Skilly.ResetSourceCache)
        end
      end,
      "Allow missing mats when a real AH or vendor price is known."
    )

    local countSetting = addSetting(
      "Results to show", "SKILLY_RESULT_COUNT", 5,
      function()
        local n = math.floor(tonumber(dbGet("resultCount")) or 5)
        if n < 1 then n = 1 elseif n > 10 then n = 10 end
        return n
      end,
      function(value)
        local n = math.floor(tonumber(value) or 5)
        if n < 1 then n = 1 elseif n > 10 then n = 10 end
        dbSet("resultCount", n)
      end
    )
    api.CreateSlider(
      category, countSetting, api.CreateSliderOptions(1, 10, 1),
      "Maximum number of recipes shown."
    )

    addCheckbox(
      "Show minimap button", "SKILLY_MINIMAP_VISIBLE", true,
      function()
        local m = dbGet("minimap")
        return type(m) ~= "table" or m.visible ~= false
      end,
      function(value)
        local m = dbGet("minimap")
        if type(m) ~= "table" then m = {} end
        m.visible = (value == true)
        dbSet("minimap", m)
      end,
      "Show the launcher button near the minimap."
    )

    -- SB-43: generate one checkbox per registry row, grouped by category.
    local categoryOrder = { "Prices", "Ranking", "Output" }
    local features = type(Skilly.Features) == "table"
        and Skilly.Features or {}
    for _, categoryName in ipairs(categoryOrder) do
      for _, row in ipairs(features) do
        local f = row
        if type(f) == "table" and f.category == categoryName
            and type(f.key) == "string" and f.key ~= "" then
          local defaultValue = f.default == true
          addCheckbox(
            categoryName .. ": " .. tostring(f.label or f.key),
            "SKILLY_FEATURE_" .. string.upper(f.key),
            defaultValue,
            function() return featureEnabled(f.key, defaultValue) end,
            function(value)
              if type(SkillyDB) ~= "table" then SkillyDB = {} end
              if type(SkillyDB.features) ~= "table" then
                SkillyDB.features = {}
              end
              SkillyDB.features[f.key] = (value == true)
              if type(Skilly.ResetSourceCache) == "function" then
                pcall(Skilly.ResetSourceCache)
              end
            end,
            type(f.tooltip) == "string" and f.tooltip or nil
          )
        end
      end
    end
  end)

  if not ok then
    Skilly.settingsCategory = nil
    Skilly.settingsFailed = true
  end
end

-- SB-04/SB-45: one dispatcher for /skilly. Every entry point calls
-- this function; a partial build names the missing piece instead of lying.
local function missingPiece(name)
  Skilly.Print("Recommendation unavailable: missing " .. name .. ".")
end

function Skilly.Recommend(mode)
  local wanted = mode
  if wanted ~= "best" and wanted ~= "cheap" then
    wanted = dbGet("mode") == "best" and "best" or "cheap"
  end

  local scan = type(Skilly.Scan) == "table" and Skilly.Scan.Current or nil
  if type(scan) ~= "function" then
    missingPiece("Skilly.Scan.Current")
    return
  end
  if type(Skilly.Rank) ~= "table" or type(Skilly.Rank.Best) ~= "function" then
    missingPiece("Skilly.Rank.Best")
    return
  end

  local okScan, snapshot = pcall(scan)
  if not okScan then
    Skilly.Print("Could not read the profession window: " .. tostring(snapshot))
    return
  end
  if type(snapshot) ~= "table" then
    Skilly.Print("Open a crafting profession window first.")
    return
  end

  local okRank, entries = pcall(Skilly.Rank.Best, snapshot, wanted)
  if not okRank then
    Skilly.Print("Ranking failed: " .. tostring(entries))
    return
  end
  if type(entries) ~= "table" or #entries == 0 then
    Skilly.Print("No recipes qualify in " .. wanted .. " mode.")
    return
  end

  local fullEntries = nil
  if type(Skilly.Rank.BestFull) == "function" then
    local okFull, fullResult = pcall(Skilly.Rank.BestFull, snapshot, wanted)
    if okFull and type(fullResult) == "table" and #fullResult > 0 then
      fullEntries = fullResult
    end
  end

  local printResults = type(Skilly.UI) == "table"
      and Skilly.UI.PrintResults or nil
  if type(printResults) == "function" then
    local okPrint, err = pcall(printResults, entries, fullEntries)
    if not okPrint then Skilly.Print("Output failed: " .. tostring(err)) end
    return
  end

  if type(Skilly.Rank.Describe) ~= "function" then
    missingPiece("Skilly.Rank.Describe")
    return
  end
  local top = entries[1]
  local okDescribe, line = pcall(Skilly.Rank.Describe, top)
  if okDescribe and type(line) == "string" and line ~= "" then
    Skilly.Print("Best craft: with materials on hand - " .. line)
  end

  local fullTop = type(fullEntries) == "table" and fullEntries[1] or nil
  if type(fullTop) == "table" then
    if fullTop.recipe == top.recipe then
      Skilly.Print("Best craft: also best at full material cost.")
    else
      local okFullLine, fullLine = pcall(Skilly.Rank.Describe, fullTop)
      if okFullLine and type(fullLine) == "string" and fullLine ~= "" then
        Skilly.Print("Best craft: at full material cost - " .. fullLine)
      end
    end
  end
end

Skilly.RegisterCommand("next", function()
  Skilly.Recommend()
end, {
  usage = "/skilly next",
  description = "Show the recommended next craft in the current mode.",
})

Skilly.RegisterCommand("best", function()
  dbSet("mode", "best")
  Skilly.Recommend("best")
end, {
  usage = "/skilly best",
  description = "Recommend the recipe with the highest skill-up chance.",
})

Skilly.RegisterCommand("cheap", function()
  dbSet("mode", "cheap")
  Skilly.Recommend("cheap")
end, {
  usage = "/skilly cheap",
  description = "Recommend the cheapest skill-up, counting materials you can buy.",
})

Skilly.RegisterCommand("config", function()
  if Skilly.settingsCategory and Settings and Settings.OpenToCategory then
    pcall(Settings.OpenToCategory, Skilly.settingsCategory:GetID())
  else
    Skilly.Print("Settings panel is not available.")
  end
end, {
  usage = "/skilly config",
  description = "Open the Skilly settings panel.",
})

local function asIfDB()
  if type(SkillyDB) ~= "table" then return nil end
  if type(SkillyDB.asIfOwned) ~= "table" then SkillyDB.asIfOwned = {} end
  return SkillyDB.asIfOwned
end

local function asIfUsage()
  Skilly.Print("Usage: /skilly asif [itemLink|itemID|name]; /skilly asif clear <key>; /skilly asif clear all")
end

local function listAsIf()
  local db = asIfDB()
  if not db then
    Skilly.Print("As-if list is unavailable.")
    return
  end
  local keys = {}
  for key, value in pairs(db) do
    if value == true then keys[#keys + 1] = key end
  end
  table.sort(keys)
  if #keys == 0 then
    Skilly.Print("As-if list is empty.")
  else
    Skilly.Print("As-if owned (" .. #keys .. "): " .. table.concat(keys, ", "))
  end
end

local function resetSourceCaches()
  if type(Skilly.ResetSourceCache) == "function" then
    pcall(Skilly.ResetSourceCache)
  end
end

Skilly.RegisterCommand("asif", function(arg)
  local text = string.gsub(tostring(arg or ""), "^%s+", "")
  text = string.gsub(text, "%s+$", "")
  local lower = string.lower(text)

  if lower == "" then
    listAsIf()
    return
  end

  local db = asIfDB()
  if not db then
    Skilly.Print("As-if list is unavailable.")
    return
  end

  local clearKey = string.match(lower, "^clear%s+(.+)$")
  if clearKey then
    clearKey = string.gsub(clearKey, "^%s+", "")
    clearKey = string.gsub(clearKey, "%s+$", "")
    if clearKey == "all" then
      local removed = 0
      for key in pairs(db) do
        db[key] = nil
        removed = removed + 1
      end
      resetSourceCaches()
      Skilly.Print("Cleared " .. removed .. " as-if entries.")
      return
    end

    local normalized = type(Skilly.NormalizeItemKey) == "function"
        and Skilly.NormalizeItemKey(clearKey) or nil
    if not normalized or db[normalized] ~= true then
      Skilly.Print("No as-if entry for: " .. clearKey)
      return
    end
    db[normalized] = nil
    resetSourceCaches()
    Skilly.Print("Removed as-if entry: " .. normalized)
    return
  end

  if lower == "clear" or lower == "help" then
    asIfUsage()
    return
  end

  local normalized = type(Skilly.NormalizeItemKey) == "function"
      and Skilly.NormalizeItemKey(text) or nil
  if not normalized then
    asIfUsage()
    return
  end

  db[normalized] = true
  resetSourceCaches()
  Skilly.Print("Added as-if entry: " .. normalized)
end, {
  usage = "/skilly asif <itemLink|itemID|name>; /skilly asif clear <key>; /skilly asif clear all",
  description = "Treat a material as already owned, so it counts as free.",
})

-- SB-11: authoritative manual prices. Keys match Cost.PriceFor's lookup.
local function formatCopper(value)
  local amount = math.floor(tonumber(value) or 0)
  if amount < 0 then amount = 0 end
  local gold = math.floor(amount / 10000)
  local silver = math.floor((amount % 10000) / 100)
  local copper = amount % 100
  local parts = {}
  if gold > 0 then parts[#parts + 1] = gold .. "g" end
  if silver > 0 or gold > 0 then parts[#parts + 1] = silver .. "s" end
  parts[#parts + 1] = copper .. "c"
  return table.concat(parts)
end

local function pricesDB()
  if type(SkillyDB) ~= "table" then return nil end
  if type(SkillyDB.prices) ~= "table" then SkillyDB.prices = {} end
  return SkillyDB.prices
end

local function pricesUsage()
  Skilly.Print("Usage: /skilly prices; /skilly prices <itemLink|itemID|name> <copper>; /skilly prices clear <key>; /skilly prices clear all")
end

local function listPrices()
  local db = pricesDB()
  if not db then
    Skilly.Print("Price overrides are unavailable.")
    return
  end
  local keys = {}
  for key, value in pairs(db) do
    if type(value) == "number" and value >= 0 then keys[#keys + 1] = key end
  end
  table.sort(keys)
  if #keys == 0 then
    Skilly.Print("No manual prices set.")
    return
  end
  Skilly.Print("Manual prices (" .. #keys .. "):")
  for _, key in ipairs(keys) do
    Skilly.Print("  " .. key .. " = " .. formatCopper(db[key]) .. " (" .. tostring(db[key]) .. "c)")
  end
end

Skilly.RegisterCommand("prices", function(arg)
  local text = string.gsub(tostring(arg or ""), "^%s+", "")
  text = string.gsub(text, "%s+$", "")
  if text == "" then
    listPrices()
    return
  end
  if string.lower(text) == "help" then
    pricesUsage()
    return
  end

  local db = pricesDB()
  if not db then
    Skilly.Print("Price overrides are unavailable.")
    return
  end

  local lower = string.lower(text)
  if lower == "clear" or string.match(lower, "^clear%s*$") then
    pricesUsage()
    return
  end

  local clearKey = string.match(lower, "^clear%s+(.+)$")
  if clearKey then
    clearKey = string.gsub(clearKey, "^%s+", "")
    clearKey = string.gsub(clearKey, "%s+$", "")
    if clearKey == "all" then
      local removed = 0
      for key in pairs(db) do
        db[key] = nil
        removed = removed + 1
      end
      resetSourceCaches()
      Skilly.Print("Cleared " .. removed .. " manual price(s).")
      return
    end

    local normalized = type(Skilly.NormalizeItemKey) == "function"
        and Skilly.NormalizeItemKey(clearKey) or nil
    if not normalized or db[normalized] == nil then
      Skilly.Print("No manual price for: " .. clearKey)
      return
    end
    db[normalized] = nil
    resetSourceCaches()
    Skilly.Print("Removed manual price: " .. normalized)
    return
  end

  local keyText, copperText = string.match(text, "^(.*)%s+(%d+)$")
  if not keyText or not copperText then
    pricesUsage()
    return
  end
  keyText = string.gsub(keyText, "^%s+", "")
  keyText = string.gsub(keyText, "%s+$", "")
  local normalized = type(Skilly.NormalizeItemKey) == "function"
      and Skilly.NormalizeItemKey(keyText) or nil
  local copper = tonumber(copperText)
  if not normalized or not copper or copper < 0 or copper ~= math.floor(copper) then
    pricesUsage()
    return
  end

  db[normalized] = math.floor(copper)
  resetSourceCaches()
  Skilly.Print("Manual price set: " .. normalized .. " = " .. formatCopper(db[normalized]) .. " (" .. tostring(db[normalized]) .. "c)")
end, {
  usage = "/skilly prices <itemLink|itemID|name> <copper>; /skilly prices clear <key>; /skilly prices clear all",
  description = "Set or list manual material prices. Manual prices always win.",
})

-- SB-45: real help with one-line summaries and per-command detail.
local function helpFor(target)
  local info = type(Skilly.commandInfo) == "table" and Skilly.commandInfo or {}
  local entry = info[target]
  if type(entry) ~= "table" or (not entry.usage and not entry.description) then
    Skilly.Print("Unknown command: " .. target .. ". Use /skilly help.")
    return
  end
  Skilly.Print(entry.usage or ("/skilly " .. target))
  if entry.description then Skilly.Print(entry.description) end
end

Skilly.RegisterCommand("help", function(arg)
  local target = string.lower(string.gsub(tostring(arg or ""), "^%s+(.-)%s*$", "%1"))
  if target ~= "" then
    helpFor(target)
    return
  end

  local names = {}
  for name in pairs(Skilly.commands) do
    names[#names + 1] = name
  end
  table.sort(names)
  local info = type(Skilly.commandInfo) == "table" and Skilly.commandInfo or {}
  for _, name in ipairs(names) do
    local entry = type(info[name]) == "table" and info[name] or {}
    local usage = entry.usage or ("/skilly " .. name)
    local description = entry.description or "no description available."
    Skilly.Print(usage .. " - " .. description)
  end
end, {
  usage = "/skilly help [command]",
  description = "List all commands, or explain one command.",
})

-- SB-31: read-only explanation of the current recommendation.
local function debugSourceLabel(source)
  if source == "auctionator" or source == "auctioneer" or source == "tsm" then
    return "AH"
  end
  if source == "as-if" or source == "vendor" or source == "manual" then
    return source
  end
  return "unknown"
end

local function bankFrameOpen()
  local frame = _G.BankFrame
  if not frame then return false end
  local ok, visible = pcall(frame.IsVisible, frame)
  return ok and visible == true
end

local function bankStateLine()
  local bank = Skilly.Bank
  local info = type(bank) == "table" and type(bank.Info) == "function"
      and bank.Info() or nil
  local includeBank = type(SkillyDB) == "table" and SkillyDB.includeBank == true
  local age = info and tonumber(info.age) or nil
  local keys = info and tonumber(info.keys) or 0
  local capturedAt = info and tonumber(info.capturedAt) or nil

  local ageText = "no cache"
  if capturedAt and capturedAt > 0 then
    if type(age) == "number" and age >= 0 then
      ageText = tostring(math.floor(age)) .. "s old"
    else
      ageText = "age unknown"
    end
  end

  local freshness = "no fresh cache"
  if info and info.fresh == true then
    freshness = "fresh"
  elseif capturedAt and capturedAt > 0 then
    freshness = "stale or disabled"
  end

  return "bank cache: " .. ageText
      .. ", keys=" .. tostring(math.floor(keys))
      .. ", includeBank=" .. tostring(includeBank)
      .. ", state=" .. freshness
      .. " (cached; not live while bank closed)"
end

local function printBankState()
  Skilly.Print(bankStateLine())
end

Skilly.RegisterCommand("bank", function(arg)
  local text = string.lower(string.gsub(tostring(arg or ""), "^%s+(.-)%s*$", "%1"))
  local bank = Skilly.Bank
  if text == "clear" then
    if type(bank) == "table" and type(bank.Clear) == "function" then
      local ok, cleared = pcall(bank.Clear)
      if ok and cleared == true then
        Skilly.Print("Bank cache cleared.")
      else
        Skilly.Print("Bank cache unavailable.")
      end
    else
      Skilly.Print("Bank cache unavailable.")
    end
    printBankState()
    return
  end

  if text ~= "" then
    Skilly.Print("Usage: /skilly bank | /skilly bank clear")
    printBankState()
    return
  end

  if bankFrameOpen() and type(bank) == "table" and type(bank.Capture) == "function" then
    local ok, captured, reason = pcall(bank.Capture, "command")
    if ok and captured == true then
      Skilly.Print("Bank cache captured (cached snapshot; refreshes when bank opens).")
    else
      Skilly.Print("Bank cache not captured: " .. tostring(reason or "unavailable"))
    end
  else
    Skilly.Print("Bank is closed; reporting cached bank age only (no bank opened).")
  end
  printBankState()
end, {
  usage = "/skilly bank [clear]",
  description = "Capture bank reagent cache when open, report age when closed, or clear it.",
})

-- SB-52: factual, copyable evidence for feedback. It never changes ranking.
local function printDebugEvidence(entry, snapshot)
  local recipe = type(entry.recipe) == "table" and entry.recipe or nil
  if not recipe then return end

  local color = "unknown"
  local detect = Skilly.Difficulty and Skilly.Difficulty.Detect
  if type(detect) == "function" then
    local ok, info = pcall(detect, recipe.difficulty)
    if ok and type(info) == "table" and type(info.color) == "string" then
      color = info.color
    end
  end

  Skilly.Print("evidence: " .. tostring(recipe.name or "recipe")
      .. " - skill=" .. tostring(tonumber(snapshot and snapshot.skill) or "?")
      .. "/" .. tostring(tonumber(snapshot and snapshot.maxSkill) or "?")
      .. ", spellID=" .. tostring(recipe.spellID or "unknown")
      .. ", raw=" .. tostring(recipe.difficulty or "unknown")
      .. ", color=" .. color
      .. ", p=" .. tostring(entry.p or 0)
      .. ", threshold=" .. tostring(recipe.thresholdSource or "unknown")
      .. ", learned=" .. tostring(recipe.learned)
      .. ", learnable=" .. tostring(recipe.learnable))
end

local function printDebugEntry(entry, label, snapshot)
  if type(entry) ~= "table" then return end
  if type(Skilly.Rank) == "table" and type(Skilly.Rank.Describe) == "function" then
    local ok, line = pcall(Skilly.Rank.Describe, entry)
    if ok and type(line) == "string" and line ~= "" then
      Skilly.Print(label .. ": " .. line)
    end
  end
  printDebugEvidence(entry, snapshot)
  if type(Skilly.Rank) == "table" and type(Skilly.Rank.DescribeHints) == "function" then
    local ok, lines = pcall(Skilly.Rank.DescribeHints, entry)
    if ok and type(lines) == "table" then
      for _, hint in ipairs(lines) do
        if type(hint) == "string" and hint ~= "" then Skilly.Print(hint) end
      end
    end
  end
  if type(entry.missing) ~= "table" then return end
  if not featureEnabled("showMissing", true) then return end
  local label = entry.costBasis == "full"
      and "missing (full material cost)" or "missing"
  local showSource = featureEnabled("showSourceLabels", true)
  for _, row in ipairs(entry.missing) do
    if type(row) == "table" and (tonumber(row.need) or 0) > 0 then
      local name = type(row.name) == "string" and row.name or "material"
      local sourceText = showSource
          and " (" .. debugSourceLabel(row.source) .. ")" or ""
      Skilly.Print(label .. ": " .. tostring(row.need) .. " x " .. name
          .. " - need " .. tostring(row.need)
          .. ", owned " .. tostring(row.owned or 0)
          .. ", price " .. formatCopper(row.price)
          .. sourceText)
    end
  end
end

local function printNearMisses(snapshot, limit)
  if type(snapshot) ~= "table" or type(snapshot.recipes) ~= "table" then return end
  if type(Skilly.Cost) ~= "table" or type(Skilly.Cost.Missing) ~= "function" then
    return
  end
  local db = type(SkillyDB) == "table" and SkillyDB or nil
  local ignored = db and type(db.ignored) == "table" and db.ignored or nil
  local found = 0
  for _, recipe in ipairs(snapshot.recipes) do
    if found >= limit then break end
    if type(recipe) == "table" and not (ignored and ignored[recipe.key] == true)
        and (tonumber(recipe.cooldown) or 0) <= 0 then
      local p = 0
      if type(Skilly.Rank) == "table" and type(Skilly.Rank.Probability) == "function" then
        local ok, value = pcall(Skilly.Rank.Probability, recipe,
            tonumber(snapshot.skill) or 0, tonumber(snapshot.maxSkill) or 0)
        if ok then p = tonumber(value) or 0 end
      end
      if p > 0 then
        local okRows, rows = pcall(Skilly.Cost.Missing, recipe)
        if okRows and type(rows) == "table" then
          local mats = {}
          for _, row in ipairs(rows) do
            if type(row) == "table" and (tonumber(row.need) or 0) > 0
                and row.hasPrice ~= true then
              mats[#mats + 1] = tostring(row.name or "material")
            end
          end
          if #mats > 0 then
            found = found + 1
            Skilly.Print("near miss: " .. tostring(recipe.name or "recipe")
                .. " - unpriced: " .. table.concat(mats, ", "))
          end
        end
      end
    end
  end
end

local function printDebugReport()
  printBankState()

  local scan = type(Skilly.Scan) == "table" and Skilly.Scan.Current or nil
  if type(scan) ~= "function" then
    missingPiece("Skilly.Scan.Current")
    return
  end
  if type(Skilly.Rank) ~= "table" or type(Skilly.Rank.Best) ~= "function" then
    missingPiece("Skilly.Rank.Best")
    return
  end

  local okScan, snapshot = pcall(scan)
  if not okScan then
    Skilly.Print("Could not read the profession window: " .. tostring(snapshot))
    return
  end
  if type(snapshot) ~= "table" then
    Skilly.Print("Open a crafting profession window first.")
    return
  end

  local okCheap, cheap = pcall(Skilly.Rank.Best, snapshot, "cheap")
  if okCheap and type(cheap) == "table" and cheap[1] then
    printDebugEntry(cheap[1], "on-hand winner", snapshot)
  else
    Skilly.Print("No recipes qualify in cheap mode.")
  end

  -- SB-48: explain silence in the copyable debug/export only. Normal /skilly next
  -- output stays unchanged.
  if okCheap and type(cheap) == "table" and cheap[1]
      and type(Skilly.Hints) == "table"
      and type(Skilly.Hints.Status) == "function" then
    local okStatus, status = pcall(Skilly.Hints.Status, cheap[1])
    if okStatus and type(status) == "string" and status ~= "" then
      Skilly.Print(status)
    end
  end

  local fullTop = nil
  if type(Skilly.Rank.BestFull) == "function" then
    local okFull, full = pcall(Skilly.Rank.BestFull, snapshot, "cheap")
    if okFull and type(full) == "table" and full[1] then fullTop = full[1] end
  end
  if type(fullTop) == "table" then
    local sameAsCheap = okCheap and type(cheap) == "table" and cheap[1]
        and cheap[1].recipe == fullTop.recipe
    if sameAsCheap then
      Skilly.Print("full material cost winner: same as on-hand winner ("
          .. tostring(fullTop.recipe and fullTop.recipe.name or "recipe") .. ")")
    else
      printDebugEntry(fullTop, "full material cost winner", snapshot)
    end
  end

  local okBest, best = pcall(Skilly.Rank.Best, snapshot, "best")
  if okBest and type(best) == "table" and best[1] then
    local same = (okCheap and type(cheap) == "table" and cheap[1]
        and cheap[1].recipe == best[1].recipe)
        or (type(fullTop) == "table" and fullTop.recipe == best[1].recipe)
    if not same then printDebugEntry(best[1], "best winner", snapshot) end
  end

  printNearMisses(snapshot, 3)
end

Skilly.RegisterCommand("debug", function()
  printDebugReport()
  Skilly.Print("Tip: /skilly export opens a copyable window with this report and /skilly probe.")
end, {
  usage = "/skilly debug",
  description = "Explain the current recommendation and list unpriced materials.",
})

-- SB-52: collect the same text the commands print into one selectable window.
local function exportFeedback()
  if type(Skilly.ClearOutputLog) == "function" then
    pcall(Skilly.ClearOutputLog)
  end

  Skilly.Print("Skilly feedback export - version " .. tostring(Skilly.version))
  Skilly.Print("Select all text in this window and press Ctrl+C to copy it.")

  if type(Skilly.Probe) == "function" then
    local okProbe, probeErr = pcall(Skilly.Probe)
    if not okProbe then Skilly.Print("probe failed: " .. tostring(probeErr)) end
  else
    Skilly.Print("probe unavailable")
  end

  -- SB-50/SB-52: the export must be context aware. If a trainer is open its
  -- rows are captured, and the stored trainer data is always reported, so one
  -- paste contains probe, trainer state, and recommendation evidence.
  local trainer = Skilly.Trainer
  if type(trainer) == "table" then
    if type(trainer.Capture) == "function" then
      local okCap, capErr = pcall(trainer.Capture)
      if not okCap then Skilly.Print("trainer capture failed: " .. tostring(capErr)) end
    end
    if type(trainer.PrintReport) == "function" then
      local okReport, reportErr = pcall(trainer.PrintReport, 60)
      if not okReport then
        Skilly.Print("trainer report failed: " .. tostring(reportErr))
      end
    end
  end

  local okDebug, debugErr = pcall(printDebugReport)
  if not okDebug then Skilly.Print("debug report failed: " .. tostring(debugErr)) end

  local lines = {}
  if type(Skilly.OutputLog) == "function" then
    local okLog, result = pcall(Skilly.OutputLog)
    if okLog and type(result) == "table" then lines = result end
  end
  local text = table.concat(lines, "\n")

  local show = type(Skilly.UI) == "table" and Skilly.UI.ShowExport or nil
  if type(show) ~= "function" then
    Skilly.Print("Export window unavailable.")
    return
  end
  local okShow, showErr = pcall(show, text)
  if not okShow then
    Skilly.Print("Export window failed: " .. tostring(showErr))
  end
end

Skilly.RegisterCommand("export", exportFeedback, {
  usage = "/skilly export",
  description = "Open a copyable window with probe and debug output for feedback.",
})

function Skilly.Command(msg)
  msg = string.lower(string.gsub(tostring(msg or ""), "^%s+(.-)%s*$", "%1"))

  if type(Skilly.InitDB) == "function" then
    pcall(Skilly.InitDB)
  end

  local cmd = string.match(msg, "^%S+")
  if not cmd then
    Skilly.Recommend()
    return
  end

  local handler = Skilly.commands[cmd]
  if not handler then
    Skilly.Print("Unknown command: " .. cmd .. ". Use /skilly help.")
    return
  end

  local arg = string.match(msg, "^%S+%s*(.*)$") or ""
  local ok, err = pcall(handler, arg)
  if not ok then
    Skilly.Print("Command failed: " .. tostring(err))
  end
end

SLASH_SKILLY1 = "/skilly"
_G.SlashCmdList = _G.SlashCmdList or {}
_G.SlashCmdList["SKILLY"] = Skilly.Command

-- Bootstrap: init saved variables (SB-02) once, then announce the version.
local function callWidget(object, method, ...)
  if not object then return false end
  local okFn, fn = pcall(function() return object[method] end)
  if not okFn or type(fn) ~= "function" then return false end
  return pcall(fn, object, ...)
end

local okCreate, frame = pcall(_G.CreateFrame, "Frame")
if okCreate and frame then
  callWidget(frame, "RegisterEvent", "PLAYER_LOGIN")
  callWidget(frame, "RegisterEvent", "ADDON_LOADED")
  callWidget(frame, "RegisterEvent", "BANKFRAME_OPENED")
  callWidget(frame, "SetScript", "OnEvent", function(self, event, arg1)
    if event == "ADDON_LOADED" then
      for _, name in ipairs(Skilly.optionalAddons or {}) do
        if arg1 == name and type(Skilly.InitSources) == "function" then
          pcall(Skilly.InitSources)
        end
      end
      return
    end
    if event == "BANKFRAME_OPENED" then
      local bank = Skilly.Bank
      if type(bank) == "table" and type(bank.Capture) == "function" then
        pcall(bank.Capture, "BANKFRAME_OPENED")
      end
      return
    end
    if event ~= "PLAYER_LOGIN" then return end

    if type(Skilly.InitDB) == "function" then pcall(Skilly.InitDB) end
    if type(Skilly.InitSettings) == "function" then pcall(Skilly.InitSettings) end
    if type(Skilly.InitSources) == "function" then pcall(Skilly.InitSources) end

    if type(Skilly.Print) == "function" then
      pcall(Skilly.Print, "Skilly " .. tostring(Skilly.version) .. " loaded")
    end
  end)
end
