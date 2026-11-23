--[[---------------------------------------------------------------------------------
  SkillBuddy - by faslkjd56
  WoW Forever 1.60.1 craft advisor
------------------------------------------------------------------------------------]]

SkillBuddy = SkillBuddy or {}
SkillBuddy.version = "0.3.1"

BINDING_HEADER_SKILLBUDDY = "SkillBuddy"
BINDING_NAME_SKILLBUDDY_NEXT_CRAFT = "Next craft"

-- Real compartment action lands in SB-16.
function SkillBuddy_OnCompartmentClick()
end

local function dbGet(key)
  if type(SkillBuddyDB) ~= "table" then return nil end
  return SkillBuddyDB[key]
end

local function dbSet(key, value)
  if type(SkillBuddyDB) ~= "table" then SkillBuddyDB = {} end
  SkillBuddyDB[key] = value
end

-- SB-03: native Settings page. Uses the modern Settings API when present.
function SkillBuddy.InitSettings()
  if SkillBuddy.settingsCategory or SkillBuddy.settingsFailed then return end

  local api = Settings
  if not (api and api.RegisterVerticalLayoutCategory and api.RegisterAddOnCategory
      and api.RegisterProxySetting and api.CreateCheckbox and api.CreateSlider
      and api.CreateSliderOptions) then
    SkillBuddy.settingsFailed = true
    return
  end

  local ok = pcall(function()
    if type(SkillBuddy.InitDB) == "function" then SkillBuddy.InitDB() end

    local category = api.RegisterVerticalLayoutCategory("SkillBuddy")
    api.RegisterAddOnCategory(category)
    SkillBuddy.settingsCategory = category

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
        "Best skillup mode", "SKILLBUDDY_BEST_MODE", false,
        function() return dbGet("mode") == "best" end,
        function(value)
          dbSet("mode", value == true and "best" or "cheap")
        end,
        "On: best skillup. Off: cheapest available skillup."
      )
    end

    local modeSetting = addSetting(
      "Mode", "SKILLBUDDY_MODE", "cheap",
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
      "Include bank", "SKILLBUDDY_INCLUDE_BANK", false,
      function() return dbGet("includeBank") == true end,
      function(value) dbSet("includeBank", value == true) end,
      "Count reagents in the bank as well as in bags."
    )

    addCheckbox(
      "Assume purchasable materials", "SKILLBUDDY_ASSUME_PURCHASABLE", true,
      function()
        if type(SkillBuddy.Cost.AssumePurchasable) == "function" then
          return SkillBuddy.Cost.AssumePurchasable() == true
        end
        return dbGet("assumePurchasable") ~= false
      end,
      function(value)
        dbSet("assumePurchasable", value == true)
        if type(SkillBuddy.ResetSourceCache) == "function" then
          pcall(SkillBuddy.ResetSourceCache)
        end
      end,
      "Allow missing mats when a real AH or vendor price is known."
    )

    local countSetting = addSetting(
      "Results to show", "SKILLBUDDY_RESULT_COUNT", 5,
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
      "Show minimap button", "SKILLBUDDY_MINIMAP_VISIBLE", true,
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
  end)

  if not ok then
    SkillBuddy.settingsCategory = nil
    SkillBuddy.settingsFailed = true
  end
end

-- SB-04/SB-45: one dispatcher for /sb and /skillbuddy. Every entry point calls
-- this function; a partial build names the missing piece instead of lying.
local function missingPiece(name)
  SkillBuddy.Print("Recommendation unavailable: missing " .. name .. ".")
end

function SkillBuddy.Recommend(mode)
  local wanted = mode
  if wanted ~= "best" and wanted ~= "cheap" then
    wanted = dbGet("mode") == "best" and "best" or "cheap"
  end

  local scan = type(SkillBuddy.Scan) == "table" and SkillBuddy.Scan.Current or nil
  if type(scan) ~= "function" then
    missingPiece("SkillBuddy.Scan.Current")
    return
  end
  if type(SkillBuddy.Rank) ~= "table" or type(SkillBuddy.Rank.Best) ~= "function" then
    missingPiece("SkillBuddy.Rank.Best")
    return
  end

  local okScan, snapshot = pcall(scan)
  if not okScan then
    SkillBuddy.Print("Could not read the profession window: " .. tostring(snapshot))
    return
  end
  if type(snapshot) ~= "table" then
    SkillBuddy.Print("Open a crafting profession window first.")
    return
  end

  local okRank, entries = pcall(SkillBuddy.Rank.Best, snapshot, wanted)
  if not okRank then
    SkillBuddy.Print("Ranking failed: " .. tostring(entries))
    return
  end
  if type(entries) ~= "table" or #entries == 0 then
    SkillBuddy.Print("No recipes qualify in " .. wanted .. " mode.")
    return
  end

  local fullEntries = nil
  if type(SkillBuddy.Rank.BestFull) == "function" then
    local okFull, fullResult = pcall(SkillBuddy.Rank.BestFull, snapshot, wanted)
    if okFull and type(fullResult) == "table" and #fullResult > 0 then
      fullEntries = fullResult
    end
  end

  local printResults = type(SkillBuddy.UI) == "table"
      and SkillBuddy.UI.PrintResults or nil
  if type(printResults) == "function" then
    local okPrint, err = pcall(printResults, entries, fullEntries)
    if not okPrint then SkillBuddy.Print("Output failed: " .. tostring(err)) end
    return
  end

  if type(SkillBuddy.Rank.Describe) ~= "function" then
    missingPiece("SkillBuddy.Rank.Describe")
    return
  end
  local top = entries[1]
  local okDescribe, line = pcall(SkillBuddy.Rank.Describe, top)
  if okDescribe and type(line) == "string" and line ~= "" then
    SkillBuddy.Print("Best craft: with materials on hand - " .. line)
  end

  local fullTop = type(fullEntries) == "table" and fullEntries[1] or nil
  if type(fullTop) == "table" then
    if fullTop.recipe == top.recipe then
      SkillBuddy.Print("Best craft: also best at full material cost.")
    else
      local okFullLine, fullLine = pcall(SkillBuddy.Rank.Describe, fullTop)
      if okFullLine and type(fullLine) == "string" and fullLine ~= "" then
        SkillBuddy.Print("Best craft: at full material cost - " .. fullLine)
      end
    end
  end
end

SkillBuddy.RegisterCommand("next", function()
  SkillBuddy.Recommend()
end, {
  usage = "/sb next",
  description = "Show the recommended next craft in the current mode.",
})

SkillBuddy.RegisterCommand("best", function()
  dbSet("mode", "best")
  SkillBuddy.Recommend("best")
end, {
  usage = "/sb best",
  description = "Recommend the recipe with the highest skill-up chance.",
})

SkillBuddy.RegisterCommand("cheap", function()
  dbSet("mode", "cheap")
  SkillBuddy.Recommend("cheap")
end, {
  usage = "/sb cheap",
  description = "Recommend the cheapest skill-up, counting materials you can buy.",
})

SkillBuddy.RegisterCommand("config", function()
  if SkillBuddy.settingsCategory and Settings and Settings.OpenToCategory then
    pcall(Settings.OpenToCategory, SkillBuddy.settingsCategory:GetID())
  else
    SkillBuddy.Print("Settings panel is not available.")
  end
end, {
  usage = "/sb config",
  description = "Open the SkillBuddy settings panel.",
})

local function asIfDB()
  if type(SkillBuddyDB) ~= "table" then return nil end
  if type(SkillBuddyDB.asIfOwned) ~= "table" then SkillBuddyDB.asIfOwned = {} end
  return SkillBuddyDB.asIfOwned
end

local function asIfUsage()
  SkillBuddy.Print("Usage: /sb asif [itemLink|itemID|name]; /sb asif clear <key>; /sb asif clear all")
end

local function listAsIf()
  local db = asIfDB()
  if not db then
    SkillBuddy.Print("As-if list is unavailable.")
    return
  end
  local keys = {}
  for key, value in pairs(db) do
    if value == true then keys[#keys + 1] = key end
  end
  table.sort(keys)
  if #keys == 0 then
    SkillBuddy.Print("As-if list is empty.")
  else
    SkillBuddy.Print("As-if owned (" .. #keys .. "): " .. table.concat(keys, ", "))
  end
end

local function resetSourceCaches()
  if type(SkillBuddy.ResetSourceCache) == "function" then
    pcall(SkillBuddy.ResetSourceCache)
  end
end

SkillBuddy.RegisterCommand("asif", function(arg)
  local text = string.gsub(tostring(arg or ""), "^%s+", "")
  text = string.gsub(text, "%s+$", "")
  local lower = string.lower(text)

  if lower == "" then
    listAsIf()
    return
  end

  local db = asIfDB()
  if not db then
    SkillBuddy.Print("As-if list is unavailable.")
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
      SkillBuddy.Print("Cleared " .. removed .. " as-if entries.")
      return
    end

    local normalized = type(SkillBuddy.NormalizeItemKey) == "function"
        and SkillBuddy.NormalizeItemKey(clearKey) or nil
    if not normalized or db[normalized] ~= true then
      SkillBuddy.Print("No as-if entry for: " .. clearKey)
      return
    end
    db[normalized] = nil
    resetSourceCaches()
    SkillBuddy.Print("Removed as-if entry: " .. normalized)
    return
  end

  if lower == "clear" or lower == "help" then
    asIfUsage()
    return
  end

  local normalized = type(SkillBuddy.NormalizeItemKey) == "function"
      and SkillBuddy.NormalizeItemKey(text) or nil
  if not normalized then
    asIfUsage()
    return
  end

  db[normalized] = true
  resetSourceCaches()
  SkillBuddy.Print("Added as-if entry: " .. normalized)
end, {
  usage = "/sb asif <itemLink|itemID|name>; /sb asif clear <key>; /sb asif clear all",
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
  if type(SkillBuddyDB) ~= "table" then return nil end
  if type(SkillBuddyDB.prices) ~= "table" then SkillBuddyDB.prices = {} end
  return SkillBuddyDB.prices
end

local function pricesUsage()
  SkillBuddy.Print("Usage: /sb prices; /sb prices <itemLink|itemID|name> <copper>; /sb prices clear <key>; /sb prices clear all")
end

local function listPrices()
  local db = pricesDB()
  if not db then
    SkillBuddy.Print("Price overrides are unavailable.")
    return
  end
  local keys = {}
  for key, value in pairs(db) do
    if type(value) == "number" and value >= 0 then keys[#keys + 1] = key end
  end
  table.sort(keys)
  if #keys == 0 then
    SkillBuddy.Print("No manual prices set.")
    return
  end
  SkillBuddy.Print("Manual prices (" .. #keys .. "):")
  for _, key in ipairs(keys) do
    SkillBuddy.Print("  " .. key .. " = " .. formatCopper(db[key]) .. " (" .. tostring(db[key]) .. "c)")
  end
end

SkillBuddy.RegisterCommand("prices", function(arg)
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
    SkillBuddy.Print("Price overrides are unavailable.")
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
      SkillBuddy.Print("Cleared " .. removed .. " manual price(s).")
      return
    end

    local normalized = type(SkillBuddy.NormalizeItemKey) == "function"
        and SkillBuddy.NormalizeItemKey(clearKey) or nil
    if not normalized or db[normalized] == nil then
      SkillBuddy.Print("No manual price for: " .. clearKey)
      return
    end
    db[normalized] = nil
    resetSourceCaches()
    SkillBuddy.Print("Removed manual price: " .. normalized)
    return
  end

  local keyText, copperText = string.match(text, "^(.*)%s+(%d+)$")
  if not keyText or not copperText then
    pricesUsage()
    return
  end
  keyText = string.gsub(keyText, "^%s+", "")
  keyText = string.gsub(keyText, "%s+$", "")
  local normalized = type(SkillBuddy.NormalizeItemKey) == "function"
      and SkillBuddy.NormalizeItemKey(keyText) or nil
  local copper = tonumber(copperText)
  if not normalized or not copper or copper < 0 or copper ~= math.floor(copper) then
    pricesUsage()
    return
  end

  db[normalized] = math.floor(copper)
  resetSourceCaches()
  SkillBuddy.Print("Manual price set: " .. normalized .. " = " .. formatCopper(db[normalized]) .. " (" .. tostring(db[normalized]) .. "c)")
end, {
  usage = "/sb prices <itemLink|itemID|name> <copper>; /sb prices clear <key>; /sb prices clear all",
  description = "Set or list manual material prices. Manual prices always win.",
})

-- SB-45: real help with one-line summaries and per-command detail.
local function helpFor(target)
  local info = type(SkillBuddy.commandInfo) == "table" and SkillBuddy.commandInfo or {}
  local entry = info[target]
  if type(entry) ~= "table" or (not entry.usage and not entry.description) then
    SkillBuddy.Print("Unknown command: " .. target .. ". Use /sb help.")
    return
  end
  SkillBuddy.Print(entry.usage or ("/sb " .. target))
  if entry.description then SkillBuddy.Print(entry.description) end
end

SkillBuddy.RegisterCommand("help", function(arg)
  local target = string.lower(string.gsub(tostring(arg or ""), "^%s+(.-)%s*$", "%1"))
  if target ~= "" then
    helpFor(target)
    return
  end

  local names = {}
  for name in pairs(SkillBuddy.commands) do
    names[#names + 1] = name
  end
  table.sort(names)
  local info = type(SkillBuddy.commandInfo) == "table" and SkillBuddy.commandInfo or {}
  for _, name in ipairs(names) do
    local entry = type(info[name]) == "table" and info[name] or {}
    local usage = entry.usage or ("/sb " .. name)
    local description = entry.description or "no description available."
    SkillBuddy.Print(usage .. " - " .. description)
  end
end, {
  usage = "/sb help [command]",
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

-- SB-52: factual, copyable evidence for feedback. It never changes ranking.
local function printDebugEvidence(entry, snapshot)
  local recipe = type(entry.recipe) == "table" and entry.recipe or nil
  if not recipe then return end

  local color = "unknown"
  local detect = SkillBuddy.Difficulty and SkillBuddy.Difficulty.Detect
  if type(detect) == "function" then
    local ok, info = pcall(detect, recipe.difficulty)
    if ok and type(info) == "table" and type(info.color) == "string" then
      color = info.color
    end
  end

  SkillBuddy.Print("evidence: " .. tostring(recipe.name or "recipe")
      .. " - skill=" .. tostring(tonumber(snapshot and snapshot.skill) or "?")
      .. "/" .. tostring(tonumber(snapshot and snapshot.maxSkill) or "?")
      .. ", spellID=" .. tostring(recipe.spellID or "unknown")
      .. ", raw=" .. tostring(recipe.difficulty or "unknown")
      .. ", color=" .. color
      .. ", p=" .. tostring(entry.p or 0)
      .. ", threshold=" .. tostring(recipe.thresholdSource or "unknown"))
end

local function printDebugEntry(entry, label, snapshot)
  if type(entry) ~= "table" then return end
  if type(SkillBuddy.Rank) == "table" and type(SkillBuddy.Rank.Describe) == "function" then
    local ok, line = pcall(SkillBuddy.Rank.Describe, entry)
    if ok and type(line) == "string" and line ~= "" then
      SkillBuddy.Print(label .. ": " .. line)
    end
  end
  printDebugEvidence(entry, snapshot)
  if type(SkillBuddy.Rank) == "table" and type(SkillBuddy.Rank.DescribeHints) == "function" then
    local ok, lines = pcall(SkillBuddy.Rank.DescribeHints, entry)
    if ok and type(lines) == "table" then
      for _, hint in ipairs(lines) do
        if type(hint) == "string" and hint ~= "" then SkillBuddy.Print(hint) end
      end
    end
  end
  if type(entry.missing) ~= "table" then return end
  local label = entry.costBasis == "full"
      and "missing (full material cost)" or "missing"
  for _, row in ipairs(entry.missing) do
    if type(row) == "table" and (tonumber(row.need) or 0) > 0 then
      local name = type(row.name) == "string" and row.name or "material"
      SkillBuddy.Print(label .. ": " .. tostring(row.need) .. " x " .. name
          .. " - need " .. tostring(row.need)
          .. ", owned " .. tostring(row.owned or 0)
          .. ", price " .. formatCopper(row.price)
          .. " (" .. debugSourceLabel(row.source) .. ")")
    end
  end
end

local function printNearMisses(snapshot, limit)
  if type(snapshot) ~= "table" or type(snapshot.recipes) ~= "table" then return end
  if type(SkillBuddy.Cost) ~= "table" or type(SkillBuddy.Cost.Missing) ~= "function" then
    return
  end
  local db = type(SkillBuddyDB) == "table" and SkillBuddyDB or nil
  local ignored = db and type(db.ignored) == "table" and db.ignored or nil
  local found = 0
  for _, recipe in ipairs(snapshot.recipes) do
    if found >= limit then break end
    if type(recipe) == "table" and not (ignored and ignored[recipe.key] == true)
        and (tonumber(recipe.cooldown) or 0) <= 0 then
      local p = 0
      if type(SkillBuddy.Rank) == "table" and type(SkillBuddy.Rank.Probability) == "function" then
        local ok, value = pcall(SkillBuddy.Rank.Probability, recipe,
            tonumber(snapshot.skill) or 0, tonumber(snapshot.maxSkill) or 0)
        if ok then p = tonumber(value) or 0 end
      end
      if p > 0 then
        local okRows, rows = pcall(SkillBuddy.Cost.Missing, recipe)
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
            SkillBuddy.Print("near miss: " .. tostring(recipe.name or "recipe")
                .. " - unpriced: " .. table.concat(mats, ", "))
          end
        end
      end
    end
  end
end

local function printDebugReport()
  local scan = type(SkillBuddy.Scan) == "table" and SkillBuddy.Scan.Current or nil
  if type(scan) ~= "function" then
    missingPiece("SkillBuddy.Scan.Current")
    return
  end
  if type(SkillBuddy.Rank) ~= "table" or type(SkillBuddy.Rank.Best) ~= "function" then
    missingPiece("SkillBuddy.Rank.Best")
    return
  end

  local okScan, snapshot = pcall(scan)
  if not okScan then
    SkillBuddy.Print("Could not read the profession window: " .. tostring(snapshot))
    return
  end
  if type(snapshot) ~= "table" then
    SkillBuddy.Print("Open a crafting profession window first.")
    return
  end

  local okCheap, cheap = pcall(SkillBuddy.Rank.Best, snapshot, "cheap")
  if okCheap and type(cheap) == "table" and cheap[1] then
    printDebugEntry(cheap[1], "on-hand winner", snapshot)
  else
    SkillBuddy.Print("No recipes qualify in cheap mode.")
  end

  -- SB-48: explain silence in the copyable debug/export only. Normal /sb next
  -- output stays unchanged.
  if okCheap and type(cheap) == "table" and cheap[1]
      and type(SkillBuddy.Hints) == "table"
      and type(SkillBuddy.Hints.Status) == "function" then
    local okStatus, status = pcall(SkillBuddy.Hints.Status, cheap[1])
    if okStatus and type(status) == "string" and status ~= "" then
      SkillBuddy.Print(status)
    end
  end

  local fullTop = nil
  if type(SkillBuddy.Rank.BestFull) == "function" then
    local okFull, full = pcall(SkillBuddy.Rank.BestFull, snapshot, "cheap")
    if okFull and type(full) == "table" and full[1] then fullTop = full[1] end
  end
  if type(fullTop) == "table" then
    local sameAsCheap = okCheap and type(cheap) == "table" and cheap[1]
        and cheap[1].recipe == fullTop.recipe
    if sameAsCheap then
      SkillBuddy.Print("full material cost winner: same as on-hand winner ("
          .. tostring(fullTop.recipe and fullTop.recipe.name or "recipe") .. ")")
    else
      printDebugEntry(fullTop, "full material cost winner", snapshot)
    end
  end

  local okBest, best = pcall(SkillBuddy.Rank.Best, snapshot, "best")
  if okBest and type(best) == "table" and best[1] then
    local same = (okCheap and type(cheap) == "table" and cheap[1]
        and cheap[1].recipe == best[1].recipe)
        or (type(fullTop) == "table" and fullTop.recipe == best[1].recipe)
    if not same then printDebugEntry(best[1], "best winner", snapshot) end
  end

  printNearMisses(snapshot, 3)
end

SkillBuddy.RegisterCommand("debug", function()
  printDebugReport()
  SkillBuddy.Print("Tip: /sb export opens a copyable window with this report and /sb probe.")
end, {
  usage = "/sb debug",
  description = "Explain the current recommendation and list unpriced materials.",
})

-- SB-52: collect the same text the commands print into one selectable window.
local function exportFeedback()
  if type(SkillBuddy.ClearOutputLog) == "function" then
    pcall(SkillBuddy.ClearOutputLog)
  end

  SkillBuddy.Print("SkillBuddy feedback export - version " .. tostring(SkillBuddy.version))
  SkillBuddy.Print("Select all text in this window and press Ctrl+C to copy it.")

  if type(SkillBuddy.Probe) == "function" then
    local okProbe, probeErr = pcall(SkillBuddy.Probe)
    if not okProbe then SkillBuddy.Print("probe failed: " .. tostring(probeErr)) end
  else
    SkillBuddy.Print("probe unavailable")
  end

  -- SB-50/SB-52: the export must be context aware. If a trainer is open its
  -- rows are captured, and the stored trainer data is always reported, so one
  -- paste contains probe, trainer state, and recommendation evidence.
  local trainer = SkillBuddy.Trainer
  if type(trainer) == "table" then
    if type(trainer.Capture) == "function" then
      local okCap, capErr = pcall(trainer.Capture)
      if not okCap then SkillBuddy.Print("trainer capture failed: " .. tostring(capErr)) end
    end
    if type(trainer.PrintReport) == "function" then
      local okReport, reportErr = pcall(trainer.PrintReport, 60)
      if not okReport then
        SkillBuddy.Print("trainer report failed: " .. tostring(reportErr))
      end
    end
  end

  local okDebug, debugErr = pcall(printDebugReport)
  if not okDebug then SkillBuddy.Print("debug report failed: " .. tostring(debugErr)) end

  local lines = {}
  if type(SkillBuddy.OutputLog) == "function" then
    local okLog, result = pcall(SkillBuddy.OutputLog)
    if okLog and type(result) == "table" then lines = result end
  end
  local text = table.concat(lines, "\n")

  local show = type(SkillBuddy.UI) == "table" and SkillBuddy.UI.ShowExport or nil
  if type(show) ~= "function" then
    SkillBuddy.Print("Export window unavailable.")
    return
  end
  local okShow, showErr = pcall(show, text)
  if not okShow then
    SkillBuddy.Print("Export window failed: " .. tostring(showErr))
  end
end

SkillBuddy.RegisterCommand("export", exportFeedback, {
  usage = "/sb export",
  description = "Open a copyable window with probe and debug output for feedback.",
})

function SkillBuddy.Command(msg)
  msg = string.lower(string.gsub(tostring(msg or ""), "^%s+(.-)%s*$", "%1"))

  if type(SkillBuddy.InitDB) == "function" then
    pcall(SkillBuddy.InitDB)
  end

  local cmd = string.match(msg, "^%S+")
  if not cmd then
    SkillBuddy.Recommend()
    return
  end

  local handler = SkillBuddy.commands[cmd]
  if not handler then
    SkillBuddy.Print("Unknown command: " .. cmd .. ". Use /sb help.")
    return
  end

  local arg = string.match(msg, "^%S+%s*(.*)$") or ""
  local ok, err = pcall(handler, arg)
  if not ok then
    SkillBuddy.Print("Command failed: " .. tostring(err))
  end
end

SLASH_SKILLBUDDY1 = "/sb"
SLASH_SKILLBUDDY2 = "/skillbuddy"
_G.SlashCmdList = _G.SlashCmdList or {}
_G.SlashCmdList["SKILLBUDDY"] = SkillBuddy.Command

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
  callWidget(frame, "SetScript", "OnEvent", function(self, event, arg1)
    if event == "ADDON_LOADED" then
      for _, name in ipairs(SkillBuddy.optionalAddons or {}) do
        if arg1 == name and type(SkillBuddy.InitSources) == "function" then
          pcall(SkillBuddy.InitSources)
        end
      end
      return
    end
    if event ~= "PLAYER_LOGIN" then return end

    if type(SkillBuddy.InitDB) == "function" then pcall(SkillBuddy.InitDB) end
    if type(SkillBuddy.InitSettings) == "function" then pcall(SkillBuddy.InitSettings) end
    if type(SkillBuddy.InitSources) == "function" then pcall(SkillBuddy.InitSources) end

    if type(SkillBuddy.Print) == "function" then
      pcall(SkillBuddy.Print, "SkillBuddy " .. tostring(SkillBuddy.version) .. " loaded")
    end
  end)
end
