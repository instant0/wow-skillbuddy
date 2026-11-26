--[[---------------------------------------------------------------------------------
  Skilly - by faslkjd56
  WoW Forever 1.60.1 craft advisor
------------------------------------------------------------------------------------]]

Skilly = Skilly or {}
Skilly.version = "0.4.9"

BINDING_HEADER_SKILLY = "Skilly"
BINDING_NAME_SKILLY_NEXT_CRAFT = "Next craft"

-- SB-16: compartment click uses the same recommendation path as /skilly next.
function Skilly_OnCompartmentClick(...)
  if type(Skilly.InitDB) == "function" then pcall(Skilly.InitDB) end

  local recommend = Skilly.Recommend
  if type(recommend) == "function" then
    local ok, err = pcall(recommend, nil, { explicit = true })
    if not ok and type(Skilly.Print) == "function" then
      pcall(Skilly.Print, "Recommendation failed: " .. tostring(err))
    end
    return
  end

  if type(Skilly.Print) == "function" then
    pcall(Skilly.Print, "Recommendation unavailable: missing Skilly.Recommend.")
  end
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

    local function addSetting(name, variable, defaultValue, getter, setter, group)
      return api.RegisterProxySetting(
        group or category, variable, type(defaultValue), name, defaultValue, getter, setter
      )
    end

    local function addCheckbox(name, variable, defaultValue, getter, setter, tooltip, group)
      local setting = addSetting(name, variable, defaultValue, getter, setter, group)
      api.CreateCheckbox(group or category, setting, tooltip)
    end

    local function addGroup(name)
      if api.CreateVerticalLayoutSubcategory then
        local okSub, sub = pcall(api.CreateVerticalLayoutSubcategory, category, name)
        if okSub and sub then return sub end
      end
      return category
    end

    local general = addGroup("General")
    local prices = addGroup("Prices")
    local ranking = addGroup("Ranking")
    local output = addGroup("Output")
    local window = addGroup("Window / Profession UI")

    addCheckbox(
      "Best skillup mode", "SKILLY_BEST_MODE", false,
      function() return dbGet("mode") == "best" end,
      function(value) dbSet("mode", value == true and "best" or "cheap") end,
      "On: best skillup. Off: cheapest available skillup.",
      general
    )

    addCheckbox(
      "Include bank", "SKILLY_INCLUDE_BANK", false,
      function() return dbGet("includeBank") == true end,
      function(value) dbSet("includeBank", value == true) end,
      "Count reagents in the bank as well as in bags. Requires a fresh bank cache captured while the bank was open.",
      general
    )

    addCheckbox(
      "Show minimap button", "SKILLY_MINIMAP_VISIBLE", false,
      function()
        local m = dbGet("minimap")
        return type(m) == "table" and m.visible == true
      end,
      function(value)
        local m = dbGet("minimap")
        if type(m) ~= "table" then m = {} end
        m.visible = (value == true)
        dbSet("minimap", m)
        if type(Skilly.UI) == "table" and type(Skilly.UI.UpdateMinimapButton) == "function" then
          pcall(Skilly.UI.UpdateMinimapButton)
        end
      end,
      "Show the draggable launcher button near the minimap.",
      general
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
      "Allow missing mats when a real AH or vendor price is known.",
      prices
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
    local sliderOpts = api.CreateSliderOptions(1, 10, 1)
    if type(sliderOpts) == "table" and type(sliderOpts.SetLabelFormatter) == "function" then
      pcall(sliderOpts.SetLabelFormatter, sliderOpts, MinimalSliderWithSteppersMixin and MinimalSliderWithSteppersMixin.Label and MinimalSliderWithSteppersMixin.Label.Right or nil, function(value)
        local n = math.floor(tonumber(value) or 5)
        return tostring(n)
      end)
    end
    local okSlider = pcall(api.CreateSlider, output, countSetting, sliderOpts, "Maximum number of recipes shown (1-10).")
    if not okSlider then
      pcall(api.CreateSlider, category, countSetting, sliderOpts, "Maximum number of recipes shown (1-10).")
    end

    local groupByCategory = { Prices = prices, Ranking = ranking, Output = output, Window = window }
    local features = type(Skilly.Features) == "table" and Skilly.Features or {}
    for _, categoryName in ipairs({ "Prices", "Ranking", "Output", "Window" }) do
      local group = groupByCategory[categoryName] or category
      for _, row in ipairs(features) do
        local f = row
        if type(f) == "table" and f.category == categoryName
            and type(f.key) == "string" and f.key ~= "" then
          local defaultValue = f.default == true
          local label = tostring(f.label or f.key)
          local tooltip = type(f.tooltip) == "string" and f.tooltip or ""
          if f.status == "partial" then
            tooltip = "STATUS: Partial implementation. " .. tooltip
          elseif f.status == "unavailable" then
            tooltip = "STATUS: Wanted but not implemented yet. " .. tooltip
          end
          addCheckbox(
            label,
            "SKILLY_FEATURE_" .. string.upper(f.key),
            defaultValue,
            function() return featureEnabled(f.key, defaultValue) end,
            function(value)
              if type(SkillyDB) ~= "table" then SkillyDB = {} end
              if type(SkillyDB.features) ~= "table" then SkillyDB.features = {} end
              SkillyDB.features[f.key] = (value == true)
              if type(Skilly.ResetSourceCache) == "function" then
                pcall(Skilly.ResetSourceCache)
              end
            end,
            tooltip,
            group
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

-- SB-85: one settings opener. The fallback reads the existing feature registry
-- instead of duplicating it, so modern and fallback surfaces expose the same
-- options and write the same SavedVariables.
local function safeFrameCall(obj, method, ...)
  if obj == nil then return false end
  local fn = obj[method]
  if type(fn) ~= "function" then return false end
  local ok = pcall(fn, obj, ...)
  return ok
end

local function safeCreateFrame(frameType, name, parent, template)
  if type(_G.CreateFrame) ~= "function" then return nil end
  local ok, frame = pcall(_G.CreateFrame, frameType, name, parent, template)
  if ok then return frame end
  return nil
end

local function safeCreateFontString(parent, name, layer, template)
  if parent == nil or type(parent.CreateFontString) ~= "function" then return nil end
  local ok, text = pcall(parent.CreateFontString, parent, name, layer, template)
  if ok then return text end
  return nil
end

local function attachSettingsTooltip(frame, text)
  if frame == nil or type(text) ~= "string" or text == "" then return end
  safeFrameCall(frame, "SetScript", "OnEnter", function(self)
    local tt = _G.GameTooltip
    if not tt or type(tt.SetOwner) ~= "function" then return end
    pcall(tt.SetOwner, tt, self, "ANCHOR_RIGHT")
    pcall(tt.SetText, tt, text)
    pcall(tt.Show, tt)
  end)
  safeFrameCall(frame, "SetScript", "OnLeave", function()
    local tt = _G.GameTooltip
    if tt and type(tt.Hide) == "function" then pcall(tt.Hide, tt) end
  end)
end

local function fallbackSettingRows()
  local rows = {}
  local function add(name, default, getter, setter, tooltip)
    rows[#rows + 1] = { name = name, default = default, get = getter, set = setter, tooltip = tooltip }
  end

  add("Best skillup mode", false,
    function() return dbGet("mode") == "best" end,
    function(value) dbSet("mode", value == true and "best" or "cheap") end,
    "On: best skillup. Off: cheapest available skillup.")

  add("Include bank", false,
    function() return dbGet("includeBank") == true end,
    function(value) dbSet("includeBank", value == true) end,
    "Count reagents in the bank. Requires a fresh bank cache.")

  add("Show minimap button", false,
    function()
      local m = dbGet("minimap")
      return type(m) == "table" and m.visible == true
    end,
    function(value)
      local m = dbGet("minimap")
      if type(m) ~= "table" then m = {} end
      m.visible = (value == true)
      dbSet("minimap", m)
      if type(Skilly.UI) == "table" and type(Skilly.UI.UpdateMinimapButton) == "function" then
        pcall(Skilly.UI.UpdateMinimapButton)
      end
    end,
    "Show the draggable launcher button near the minimap.")

  add("Assume purchasable materials", true,
    function()
      if type(Skilly.Cost.AssumePurchasable) == "function" then
        return Skilly.Cost.AssumePurchasable() == true
      end
      return dbGet("assumePurchasable") ~= false
    end,
    function(value)
      dbSet("assumePurchasable", value == true)
      if type(Skilly.ResetSourceCache) == "function" then pcall(Skilly.ResetSourceCache) end
    end,
    "Allow missing mats when a real AH or vendor price is known.")

  local features = type(Skilly.Features) == "table" and Skilly.Features or {}
  for _, row in ipairs(features) do
    if type(row) == "table" and type(row.key) == "string" and row.key ~= "" then
      local defaultValue = row.default == true
      local label = tostring(row.label or row.key)
      local tooltip = type(row.tooltip) == "string" and row.tooltip or ""
      if row.status == "partial" then
        tooltip = "STATUS: Partial implementation. " .. tooltip
      elseif row.status == "unavailable" then
        tooltip = "STATUS: Wanted but not implemented yet. " .. tooltip
      end
      add(label, defaultValue,
        function() return featureEnabled(row.key, defaultValue) end,
        function(value)
          if type(SkillyDB) ~= "table" then SkillyDB = {} end
          if type(SkillyDB.features) ~= "table" then SkillyDB.features = {} end
          SkillyDB.features[row.key] = (value == true)
          if type(Skilly.ResetSourceCache) == "function" then pcall(Skilly.ResetSourceCache) end
        end,
        tooltip)
    end
  end
  return rows
end

local fallbackSettingsPanel = nil

local function buildFallbackSettingsPanel()
  if fallbackSettingsPanel then return fallbackSettingsPanel end

  local parent = _G.UIParent or _G.WorldFrame
  local panel = safeCreateFrame("Frame", "SkillySettingsFallback", parent)
  if not panel then return nil end
  fallbackSettingsPanel = panel

  safeFrameCall(panel, "SetWidth", 460)
  safeFrameCall(panel, "SetHeight", 640)
  safeFrameCall(panel, "SetPoint", "CENTER", 0, 0)
  safeFrameCall(panel, "SetFrameStrata", "DIALOG")
  safeFrameCall(panel, "SetMovable", true)
  safeFrameCall(panel, "EnableMouse", true)
  safeFrameCall(panel, "RegisterForDrag", "LeftButton")
  safeFrameCall(panel, "SetScript", "OnDragStart", function(self)
    if type(self.StartMoving) == "function" then pcall(self.StartMoving, self) end
  end)
  safeFrameCall(panel, "SetScript", "OnDragStop", function(self)
    if type(self.StopMovingOrSizing) == "function" then pcall(self.StopMovingOrSizing, self) end
  end)

  local title = safeCreateFontString(panel, nil, "ARTWORK", "GameFontNormalLarge")
  if title then
    safeFrameCall(title, "SetPoint", "TOPLEFT", 16, -14)
    safeFrameCall(title, "SetText", "Skilly settings")
  end

  local close = safeCreateFrame("Button", "SkillySettingsFallbackClose", panel, "UIPanelCloseButton")
  if close then
    safeFrameCall(close, "SetPoint", "TOPRIGHT", -6, -6)
    safeFrameCall(close, "SetScript", "OnClick", function() safeFrameCall(panel, "Hide") end)
  end

  local rows = fallbackSettingRows()
  local y = -44
  for index, row in ipairs(rows) do
    local checkbox = safeCreateFrame("CheckButton", "SkillyFallbackSetting" .. index, panel, "UICheckButtonTemplate")
    if checkbox then
      safeFrameCall(checkbox, "SetPoint", "TOPLEFT", 16, y)
      local label = checkbox.Text or checkbox.text
      if not label then
        label = safeCreateFontString(checkbox, nil, "ARTWORK", "GameFontNormal")
        if label then safeFrameCall(label, "SetPoint", "LEFT", checkbox, "RIGHT", 6, 0) end
      end
      if label then safeFrameCall(label, "SetText", row.name) end
      local getter = row.get
      local setter = row.set
      safeFrameCall(checkbox, "SetChecked", getter() == true)
      safeFrameCall(checkbox, "SetScript", "OnShow", function(self)
        safeFrameCall(self, "SetChecked", getter() == true)
      end)
      safeFrameCall(checkbox, "SetScript", "OnClick", function(self)
        local checked = false
        if type(self.GetChecked) == "function" then
          local ok, value = pcall(self.GetChecked, self)
          if ok then checked = (value == true) end
        end
        setter(checked)
        safeFrameCall(self, "SetChecked", getter() == true)
      end)
      attachSettingsTooltip(checkbox, row.tooltip)
      y = y - 22
    end
  end

  local countLabel = safeCreateFontString(panel, nil, "ARTWORK", "GameFontNormal")
  if countLabel then safeFrameCall(countLabel, "SetPoint", "TOPLEFT", 46, y) end
  local minus = safeCreateFrame("Button", "SkillyFallbackCountDown", panel, "UIPanelButtonTemplate")
  local plus = safeCreateFrame("Button", "SkillyFallbackCountUp", panel, "UIPanelButtonTemplate")
  if minus then
    safeFrameCall(minus, "SetWidth", 24)
    safeFrameCall(minus, "SetHeight", 20)
    safeFrameCall(minus, "SetPoint", "TOPLEFT", 16, y)
    safeFrameCall(minus, "SetText", "-")
  end
  if plus then
    safeFrameCall(plus, "SetWidth", 24)
    safeFrameCall(plus, "SetHeight", 20)
    safeFrameCall(plus, "SetPoint", "TOPLEFT", 400, y)
    safeFrameCall(plus, "SetText", "+")
  end
  local function refreshCount()
    local n = math.floor(tonumber(dbGet("resultCount")) or 5)
    if n < 1 then n = 1 elseif n > 10 then n = 10 end
    if countLabel then safeFrameCall(countLabel, "SetText", "Results to show: " .. n) end
    return n
  end
  if minus then
    safeFrameCall(minus, "SetScript", "OnClick", function()
      local n = refreshCount()
      dbSet("resultCount", math.max(1, n - 1))
      refreshCount()
    end)
  end
  if plus then
    safeFrameCall(plus, "SetScript", "OnClick", function()
      local n = refreshCount()
      dbSet("resultCount", math.min(10, n + 1))
      refreshCount()
    end)
  end
  safeFrameCall(panel, "SetScript", "OnShow", refreshCount)
  attachSettingsTooltip(panel, "Results to show: maximum number of recipes printed per recommendation.")

  return panel
end

function Skilly.OpenSettings()
  if type(Skilly.InitSettings) == "function" then pcall(Skilly.InitSettings) end

  local category = Skilly.settingsCategory
  if category and Settings and type(Settings.OpenToCategory) == "function" then
    local id = nil
    if type(category.GetID) == "function" then
      local ok, value = pcall(category.GetID, category)
      if ok then id = value end
    end
    local ok = false
    if id ~= nil then
      ok = pcall(Settings.OpenToCategory, id)
    else
      ok = pcall(Settings.OpenToCategory, category)
    end
    if ok then return true end
  end

  local panel = buildFallbackSettingsPanel()
  if panel then
    safeFrameCall(panel, "Show")
    local legacy = _G.InterfaceOptionsFrame_OpenToCategory
    if type(legacy) == "function" then pcall(legacy, panel) end
    return true
  end

  if type(Skilly.Print) == "function" then
    Skilly.Print("Skilly settings could not be opened in this client.")
  end
  return false
end

-- SB-04/SB-45: one dispatcher for /skilly. Every entry point calls
-- this function; a partial build names the missing piece instead of lying.
local function missingPiece(name)
  Skilly.Print("Recommendation unavailable: missing " .. name .. ".")
end

-- SB-87: accept only snapshots with enough truthful data to rank. Bad rows are
-- dropped; a snapshot with no usable rows is rejected instead of guessed.
local function validReagent(reagent)
  if type(reagent) ~= "table" then return false end
  local internal = type(Skilly.Internal) == "table" and Skilly.Internal or nil
  local key = internal and type(internal.ReagentKey) == "function"
      and internal.ReagentKey(reagent) or reagent.key
  if type(key) ~= "string" or key == "" then return false end
  local count = tonumber(reagent.count)
  if not count or count <= 0 or count ~= math.floor(count) then return false end
  return true
end

local function validRecipe(recipe)
  if type(recipe) ~= "table" then return false end
  if type(recipe.name) ~= "string" or recipe.name == "" then return false end
  if type(recipe.difficulty) ~= "string" or recipe.difficulty == "" then return false end
  if type(recipe.learned) ~= "boolean" then return false end
  if type(recipe.reagents) ~= "table" or #recipe.reagents == 0 then return false end
  for _, reagent in ipairs(recipe.reagents) do
    if not validReagent(reagent) then return false end
  end
  local madeMin = tonumber(recipe.madeMin)
  local madeMax = tonumber(recipe.madeMax) or madeMin
  if not madeMin or madeMin <= 0 or not madeMax or madeMax <= 0 then return false end
  local cooldown = tonumber(recipe.cooldown)
  if not cooldown or cooldown < 0 then return false end
  return true
end

local function usableSnapshot(snapshot)
  if type(snapshot) ~= "table" then
    return nil, "Open a crafting profession window first."
  end
  if type(Skilly.Scan) == "table" and type(Skilly.Scan.UnsupportedView) == "function" then
    local okUnsupported, unsupported = pcall(Skilly.Scan.UnsupportedView)
    if okUnsupported and unsupported == true then
      return nil, "Open your own crafting profession window first."
    end
  end
  if type(snapshot.profession) ~= "string" or snapshot.profession == "" then
    return nil, "Open a crafting profession window first."
  end
  if tonumber(snapshot.skill) == nil or tonumber(snapshot.maxSkill) == nil
      or type(snapshot.recipes) ~= "table" then
    return nil, "Profession data is incomplete; open and refresh the profession window."
  end

  local usable = {}
  for _, recipe in ipairs(snapshot.recipes) do
    if validRecipe(recipe) then usable[#usable + 1] = recipe end
  end
  if #usable == 0 then
    return nil, "Profession data is incomplete; open and refresh the profession window."
  end
  if #usable == #snapshot.recipes then return snapshot end

  local copy = {}
  for key, value in pairs(snapshot) do copy[key] = value end
  copy.recipes = usable
  return copy
end

function Skilly.Recommend(mode, opts)
  local wanted = mode
  if wanted ~= "best" and wanted ~= "cheap" then
    wanted = dbGet("mode") == "best" and "best" or "cheap"
  end
  local explicit = type(opts) == "table" and opts.explicit == true

  local scan = type(Skilly.Scan) == "table" and Skilly.Scan.Current or nil
  if type(scan) ~= "function" then
    missingPiece("Skilly.Scan.Current")
    return
  end
  if type(Skilly.Rank) ~= "table" or type(Skilly.Rank.Best) ~= "function" then
    missingPiece("Skilly.Rank.Best")
    return
  end
  if type(Skilly.Scan) == "table" and type(Skilly.Scan.UnsupportedView) == "function" then
    local okUnsupported, unsupported = pcall(Skilly.Scan.UnsupportedView)
    if okUnsupported and unsupported == true then
      Skilly.Print("Open your own crafting profession window first.")
      return
    end
  end

  local okScan, rawSnapshot = pcall(scan)
  if not okScan then
    Skilly.Print("Could not read the profession window: " .. tostring(rawSnapshot))
    return
  end
  local snapshot, reason = usableSnapshot(rawSnapshot)
  if not snapshot then
    Skilly.Print(reason)
    return
  end
  Skilly.lastSnapshot = snapshot

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
    local okPrint, err = pcall(printResults, entries, fullEntries, { explicit = explicit, mode = wanted })
    if not okPrint then Skilly.Print("Output failed: " .. tostring(err)) end
    return
  end

  if type(Skilly.Rank.Describe) ~= "function" then
    missingPiece("Skilly.Rank.Describe")
    return
  end
  local top = entries[1]
  local resultCount = 5
  if type(SkillyDB) == "table" then resultCount = tonumber(SkillyDB.resultCount) or 5 end
  local maxLines = math.floor(resultCount)
  if maxLines < 1 then maxLines = 1 elseif maxLines > 10 then maxLines = 10 end
  local groupFor = type(Skilly.UI.GroupFor) == "function" and Skilly.UI.GroupFor or nil
  local titles = type(Skilly.UI.GroupTitles) == "table" and Skilly.UI.GroupTitles or {}
  local lastGroup = nil
  Skilly.Print("Skilly recommendations:")
  for i = 1, math.min(#entries, maxLines) do
    local entry = entries[i]
    local group = groupFor and groupFor(entry) or "other"
    if group ~= lastGroup then
      Skilly.Print(titles[group] or titles.other or "Other recommendations")
      lastGroup = group
    end
    local okDescribe, line = pcall(Skilly.Rank.Describe, entry)
    if okDescribe and type(line) == "string" and line ~= "" then
      Skilly.Print(i .. ") " .. line)
    end
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
  Skilly.Recommend(nil, { explicit = true })
end, {
  usage = "/skilly next",
  description = "Show the recommended next craft in the current mode.",
})

Skilly.RegisterCommand("best", function()
  dbSet("mode", "best")
  Skilly.Recommend("best", { explicit = true })
end, {
  usage = "/skilly best",
  description = "Recommend the recipe with the highest skill-up chance.",
})

Skilly.RegisterCommand("cheap", function()
  dbSet("mode", "cheap")
  Skilly.Recommend("cheap", { explicit = true })
end, {
  usage = "/skilly cheap",
  description = "Recommend the cheapest skill-up, counting materials you can buy.",
})

Skilly.RegisterCommand("config", function()
  if type(Skilly.OpenSettings) ~= "function" then
    Skilly.Print("Skilly settings could not be opened in this client.")
    return
  end
  Skilly.OpenSettings()
end, {
  usage = "/skilly config",
  description = "Open the Skilly settings panel.",
})

Skilly.RegisterCommand("version", function()
  Skilly.Print("Skilly " .. tostring(Skilly.version))
end, {
  usage = "/skilly version",
  description = "Show the installed addon version.",
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
local function debugComparatorLine(entry, snapshot, mode, index)
  if type(entry) ~= "table" then return "evidence: n/a" end
  local recipe = type(entry.recipe) == "table" and entry.recipe or {}
  local color = "unknown"
  local detect = Skilly.Difficulty and Skilly.Difficulty.Detect
  if type(detect) == "function" then
    local ok, info = pcall(detect, recipe.difficulty)
    if ok and type(info) == "table" and type(info.color) == "string" and info.color ~= "" then
      color = info.color
    end
  end
  local missing = type(entry.missing) == "table" and entry.missing or {}
  local missingCount, missingOwned, missingNeed = 0, 0, 0
  for _, row in ipairs(missing) do
    if type(row) == "table" then
      local need = tonumber(row.need) or 0
      if need > 0 then
        missingCount = missingCount + 1
        missingNeed = missingNeed + need
        missingOwned = missingOwned + (tonumber(row.owned) or 0)
      end
    end
  end
  local prefix = "evidence:"
  if type(index) == "number" then prefix = "evidence: row=" .. tostring(index) end
  return prefix .. ", mode=" .. tostring(mode or "n/a")
      .. ", profession=" .. tostring(snapshot and snapshot.profession or "n/a")
      .. ", skill=" .. tostring(tonumber(snapshot and snapshot.skill) or "n/a")
      .. "/" .. tostring(tonumber(snapshot and snapshot.maxSkill) or "n/a")
      .. ", name=" .. tostring(recipe.name or "n/a")
      .. ", spellID=" .. tostring(recipe.spellID or recipe.id or recipe.key or "n/a")
      .. ", raw=" .. tostring(recipe.difficulty or "n/a")
      .. ", color=" .. tostring(color)
      .. ", p=" .. tostring(entry.p ~= nil and entry.p or "n/a")
      .. ", thresholdSource=" .. tostring(recipe.thresholdSource or "n/a")
      .. ", expectedCrafts=" .. tostring(entry.expectedCrafts ~= nil and entry.expectedCrafts or "n/a")
      .. ", expectedDenominator=" .. tostring(entry.expectedDenominator ~= nil and entry.expectedDenominator or "n/a")
      .. ", probSource=" .. tostring(entry.probabilitySource or "n/a")
      .. ", observedRate=" .. tostring(entry.observedRate ~= nil and entry.observedRate or "color")
      .. ", sourceGrade=" .. tostring(entry.sourceGrade or "n/a")
      .. ", costBasis=" .. tostring(entry.costBasis or "n/a")
      .. ", estimatedCost=" .. tostring(entry.estimatedCost or 0)
      .. ", estimatedReagents=" .. tostring(entry.estimatedReagents or 0)
      .. ", score=" .. tostring(entry.score ~= nil and entry.score or "n/a")
      .. ", potentialPoints=" .. tostring(entry.potentialPoints ~= nil and entry.potentialPoints or "n/a")
      .. ", craftable=" .. tostring(entry.craftable ~= nil and entry.craftable or "n/a")
      .. ", missingKinds=" .. tostring(missingCount)
      .. ", missingNeed=" .. tostring(missingNeed)
      .. ", missingOwned=" .. tostring(missingOwned)
      .. ", learned=" .. tostring(recipe.learned)
      .. ", learnable=" .. tostring(recipe.learnable)
end

local function printDebugEvidence(entry, snapshot, mode, index)
  Skilly.Print(debugComparatorLine(entry, snapshot, mode, index))
end

local function printDebugEntry(entry, label, snapshot, mode, index)
  if type(entry) ~= "table" then return end
  if type(Skilly.Rank) == "table" and type(Skilly.Rank.Describe) == "function" then
    local ok, line = pcall(Skilly.Rank.Describe, entry)
    if ok and type(line) == "string" and line ~= "" then
      Skilly.Print(label .. ": " .. line)
    end
  end
  printDebugEvidence(entry, snapshot, mode, index)
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
  local mlabel = entry.costBasis == "full"
      and "missing (full material cost)" or "missing"
  local showSource = featureEnabled("showSourceLabels", true)
  for _, row in ipairs(entry.missing) do
    if type(row) == "table" and (tonumber(row.need) or 0) > 0 then
      local name = type(row.name) == "string" and row.name or "material"
      local key = type(row.key) == "string" and row.key or ""
      local itemID = tonumber(string.match(key, "^item:(%d+)$"))
      if (name == "material" or string.match(name, "^Item %d+$") or string.match(name, "^item:%d+$")) and itemID then
        local citem = _G.C_Item
        if type(citem) == "table" then
          if type(citem.GetItemNameByID) == "function" then
            local okN, n2 = pcall(citem.GetItemNameByID, itemID)
            if okN and type(n2) == "string" and n2 ~= "" then name = n2 end
          end
          if (name == "material" or string.match(name, "^Item %d+$") or string.match(name, "^item:%d+$"))
              and type(citem.GetItemInfo) == "function" then
            local okN, n2, link = pcall(citem.GetItemInfo, itemID)
            if okN and type(n2) == "string" and n2 ~= "" then name = n2
            elseif okN and type(link) == "string" then
              local ln = string.match(link, "%[(.+)%]")
              if type(ln) == "string" and ln ~= "" then name = ln end
            end
          end
          if (name == "material" or string.match(name, "^Item %d+$") or string.match(name, "^item:%d+$"))
              and type(citem.RequestLoadItemDataByID) == "function" then
            pcall(citem.RequestLoadItemDataByID, itemID)
          end
        end

      end
      if (name == "material" or string.match(name, "^Item %d+$")) and itemID then name = "item:" .. itemID end
      local sourceText = showSource
          and " (" .. debugSourceLabel(row.source) .. ")" or ""
      Skilly.Print(mlabel .. ": " .. tostring(row.need) .. " x " .. name
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

local function printCacheState()
  local charDB = type(SkillyCharDB) == "table" and SkillyCharDB or nil
  local lr = charDB and charDB.learnedRecipes or nil
  local learnedCount = 0
  local learnedUpdated = nil
  if type(lr) == "table" and type(lr.bySpellID) == "table" then
    for _, row in pairs(lr.bySpellID) do
      if type(row) == "table" and row.learned == true then
        learnedCount = learnedCount + 1
        local u = tonumber(row.updated)
        if u and u > 0 and (not learnedUpdated or u > learnedUpdated) then learnedUpdated = u end
      end
    end
  end
  local age = "never"
  if learnedUpdated and type(_G.time) == "function" then
    local ok, now = pcall(_G.time)
    if ok and type(now) == "number" and now >= learnedUpdated then
      age = tostring(math.floor((now - learnedUpdated) / 60)) .. "m ago"
    end
  end
  Skilly.Print("learned recipe cache: " .. tostring(learnedCount) .. " recipe(s), last update " .. age .. ", schema=" .. tostring(lr and lr.schema or "missing"))

  local db = type(SkillyDB) == "table" and SkillyDB or nil
  local tr = db and db.trainerRecipes or nil
  local ts = db and db.trainerScans or nil
  local trainerCount = 0
  local lastScan = nil
  if type(tr) == "table" then
    for k, v in pairs(tr) do
      if k ~= "schema" and type(v) == "table" then trainerCount = trainerCount + 1 end
    end
  end
  if type(ts) == "table" then
    for k, v in pairs(ts) do
      if k ~= "schema" and type(v) == "number" and v > 0 and (not lastScan or v > lastScan) then lastScan = v end
    end
  end
  local scanAge = "never"
  if lastScan and type(_G.time) == "function" then
    local ok, now = pcall(_G.time)
    if ok and type(now) == "number" and now >= lastScan then
      scanAge = tostring(math.floor((now - lastScan) / 60)) .. "m ago"
    end
  end
  Skilly.Print("trainer cache: " .. tostring(trainerCount) .. " recipe(s), last scan " .. scanAge .. ", schema=" .. tostring(tr and tr.schema or "missing"))
end

local function printDebugReport()
  printBankState()
  printCacheState()

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
    printDebugEntry(cheap[1], "on-hand winner", snapshot, "cheap", 1)
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
      printDebugEvidence(fullTop, snapshot, "cheap-full", 1)
    else
      printDebugEntry(fullTop, "full material cost winner", snapshot, "cheap-full", 1)
    end
  end

  local okBest, best = pcall(Skilly.Rank.Best, snapshot, "best")
  if okBest and type(best) == "table" and best[1] then
    local same = (okCheap and type(cheap) == "table" and cheap[1]
        and cheap[1].recipe == best[1].recipe)
        or (type(fullTop) == "table" and fullTop.recipe == best[1].recipe)
    if not same then printDebugEntry(best[1], "best winner", snapshot, "best", 1) end
  end

  -- SB-68: include bounded per-row comparator evidence for visible NEXT rows.
  local maxRows = 5
  if type(SkillyDB) == "table" then maxRows = tonumber(SkillyDB.resultCount) or 5 end
  maxRows = math.max(1, math.min(10, math.floor(maxRows)))
  if okCheap and type(cheap) == "table" then
    for i = 2, math.min(#cheap, maxRows) do
      printDebugEvidence(cheap[i], snapshot, "cheap", i)
    end
  end
  if okBest and type(best) == "table" then
    for i = 1, math.min(#best, maxRows) do
      local e = best[i]
      local sameCheap = okCheap and type(cheap) == "table" and cheap[i] and cheap[i].recipe == e.recipe
      if not sameCheap then
        printDebugEvidence(e, snapshot, "best", i)
      end
    end
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
    Skilly.Recommend(nil, { explicit = true })
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
  callWidget(frame, "RegisterEvent", "TRADE_SKILL_SHOW")
  callWidget(frame, "RegisterEvent", "TRADE_SKILL_CLOSE")
  callWidget(frame, "RegisterEvent", "TRADE_SKILL_LIST_UPDATE")
  callWidget(frame, "RegisterEvent", "SKILL_LINES_CHANGED")
  callWidget(frame, "SetScript", "OnEvent", function(self, event, arg1)
    if event == "ADDON_LOADED" then
      for _, name in ipairs(Skilly.optionalAddons or {}) do
        if arg1 == name and type(Skilly.InitSources) == "function" then
          pcall(Skilly.InitSources)
        end
      end
      local ui = Skilly.UI
      if type(ui) == "table" and type(ui.TryHookProfessionsFrame) == "function" then
        pcall(ui.TryHookProfessionsFrame)
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
    if event == "TRADE_SKILL_SHOW" or event == "TRADE_SKILL_CLOSE"
        or event == "TRADE_SKILL_LIST_UPDATE" or event == "SKILL_LINES_CHANGED" then
      local ui = Skilly.UI
      if type(ui) == "table" and type(ui.OnProfessionsWindowEvent) == "function" then
        pcall(ui.OnProfessionsWindowEvent, event)
      end
      return
    end
    if event ~= "PLAYER_LOGIN" then return end

    if type(Skilly.InitDB) == "function" then pcall(Skilly.InitDB) end
    if type(Skilly.InitSettings) == "function" then pcall(Skilly.InitSettings) end
    if type(Skilly.InitSources) == "function" then pcall(Skilly.InitSources) end

    if type(Skilly.UI) == "table" and type(Skilly.UI.CheckProfessionAtLogin) == "function" then
      pcall(Skilly.UI.CheckProfessionAtLogin)
    end

    if type(Skilly.UI) == "table" and type(Skilly.UI.UpdateMinimapButton) == "function" then
      pcall(Skilly.UI.UpdateMinimapButton)
    end
    if type(Skilly.Print) == "function" then
      pcall(Skilly.Print, "Skilly " .. tostring(Skilly.version) .. " loaded")
    end
  end)
end
