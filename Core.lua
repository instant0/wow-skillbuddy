--[[---------------------------------------------------------------------------------
  Skilly - by faslkjd56
  WoW Forever 1.60.1 craft advisor
------------------------------------------------------------------------------------]]

Skilly = Skilly or {}

Skilly.Defaults = {
  schema = 1,
  mode = "cheap",
  includeBank = false,
  resultCount = 5,
  minimap = { parentKey = "Minimap", point = "CENTER", relativePoint = "TOPRIGHT", x = -18, y = -18, visible = false },
  prices = {},
  ignored = {},
  assumePurchasable = true,
  asIfOwned = {},
  tsmPriceSource = "dbmarket",
  -- SB-50/SB-66: live trainer capture. Written only by a successful trainer scan.
  trainerRecipes = { schema = 1 },
  trainerScans = { schema = 1 },
}

local charDefaults = {
  schema = 1,
  learned = {},
  observations = {},
  bankCache = nil,
  -- SB-66: per-character learned recipe cache, refreshed from safe profession scans.
  learnedRecipes = { schema = 1, bySpellID = {} },
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

local function normalizeLearnedRecipesCache(db)
  if type(db) ~= "table" then return { schema = 1, bySpellID = {} } end
  if db.schema ~= 1 then return { schema = 1, bySpellID = {} } end
  local bySpellID = type(db.bySpellID) == "table" and db.bySpellID or {}
  local out = {}
  for k, v in pairs(bySpellID) do
    local id = tonumber(k)
    if id and id > 0 and id == math.floor(id) and type(v) == "table" and v.learned == true then
      local profession = type(v.profession) == "string" and v.profession or nil
      local updated = tonumber(v.updated)
      if not updated or updated <= 0 then updated = nil else updated = math.floor(updated) end
      out[math.floor(id)] = { learned = true, profession = profession, updated = updated }
    end
  end
  return { schema = 1, bySpellID = out }
end

local function normalizeTrainerCache(db, scans)
  local outDB = { schema = 1 }
  local outScans = { schema = 1 }
  if type(db) == "table" then
    for k, v in pairs(db) do
      local id = tonumber(k)
      if id and id > 0 and id == math.floor(id) and type(v) == "table" then
        local name = type(v.name) == "string" and v.name ~= "" and v.name or nil
        local skill = tonumber(v.skillRequired)
        if name and skill and skill > 0 and skill == math.floor(skill) then
          local row = {
            spellID = math.floor(id),
            name = name,
            rank = type(v.rank) == "string" and v.rank ~= "" and v.rank or nil,
            profession = type(v.profession) == "string" and v.profession ~= "" and v.profession or nil,
            skillRequired = math.floor(skill),
            updated = tonumber(v.updated),
            source = type(v.source) == "string" and v.source ~= "" and v.source or "trainer",
          }
          if not row.updated or row.updated <= 0 then row.updated = nil else row.updated = math.floor(row.updated) end
          outDB[math.floor(id)] = row
        end
      end
    end
  end
  if type(scans) == "table" then
    for k, v in pairs(scans) do
      if type(k) == "string" and k ~= "" then
        local t = tonumber(v)
        if t and t > 0 then outScans[k] = math.floor(t) end
      end
    end
  end
  return outDB, outScans
end

function Skilly.InitDB()
  if type(SkillyDB) ~= "table" then SkillyDB = {} end
  if type(SkillyCharDB) ~= "table" then SkillyCharDB = {} end

  fillMissing(SkillyDB, Skilly.Defaults)
  fillMissing(SkillyCharDB, charDefaults)

  -- SB-66: normalize/migrate caches conservatively; corrupt/unknown shapes ignored.
  SkillyCharDB.learnedRecipes = normalizeLearnedRecipesCache(SkillyCharDB.learnedRecipes)
  SkillyDB.trainerRecipes, SkillyDB.trainerScans = normalizeTrainerCache(SkillyDB.trainerRecipes, SkillyDB.trainerScans)
end

-- Command registry lives here because Core.lua loads before feature modules.
Skilly.commands = Skilly.commands or {}
Skilly.commandInfo = Skilly.commandInfo or {}

-- SB-45: metadata is inert. A missing or malformed description never stops a
-- command from running, and good metadata is never replaced by nil.
function Skilly.RegisterCommand(name, fn, info)
  if type(name) ~= "string" or type(fn) ~= "function" then return end
  name = string.lower(name)
  Skilly.commands[name] = fn

  if type(info) == "table" then
    local entry = Skilly.commandInfo[name] or {}
    if type(info.usage) == "string" and info.usage ~= "" then
      entry.usage = info.usage
    end
    if type(info.description) == "string" and info.description ~= "" then
      entry.description = info.description
    end
    Skilly.commandInfo[name] = entry
  elseif Skilly.commandInfo[name] == nil then
    Skilly.commandInfo[name] = {}
  end
end

-- SB-52: bounded, in-memory copy of what we printed. Never saved to disk.
local MAX_OUTPUT_LINES = 400
local outputLog = {}

function Skilly.ClearOutputLog()
  outputLog = {}
end

function Skilly.OutputLog()
  local copy = {}
  for i = 1, #outputLog do copy[i] = outputLog[i] end
  return copy
end

function Skilly.Print(message)
  local okLine, line = pcall(tostring, message)
  if not okLine or type(line) ~= "string" then line = "<unprintable>" end

  outputLog[#outputLog + 1] = line
  if #outputLog > MAX_OUTPUT_LINES then table.remove(outputLog, 1) end

  local frame = _G.DEFAULT_CHAT_FRAME
  if not frame then return end
  local okFn, addMessage = pcall(function() return frame.AddMessage end)
  if not okFn or type(addMessage) ~= "function" then return end
  pcall(addMessage, frame, "[Skilly] " .. line)
end


-- SB-55: small, safety-checked helpers shared by the split runtime modules.
-- These are internal; public behavior stays on the Skilly.* namespaces.
Skilly.Internal = Skilly.Internal or {}
local Internal = Skilly.Internal

Internal.Unpack = table.unpack or unpack

function Internal.ScalarText(value)
  local kind = type(value)
  if kind == "table" then
    local count = 0
    for _ in pairs(value) do count = count + 1 end
    return "table(" .. count .. ")"
  end
  if kind == "function" or kind == "userdata" or kind == "thread" then return kind end
  local ok, text = pcall(tostring, value)
  if ok and type(text) == "string" then return text end
  return "<unprintable>"
end

function Internal.CallResults(fn, ...)
  if type(fn) ~= "function" then return nil end
  local results = { pcall(fn, ...) }
  if not table.remove(results, 1) then return nil end
  return results
end

function Internal.CallNumber(fn, ...)
  if type(fn) ~= "function" then return nil end
  local ok, value = pcall(fn, ...)
  if not ok then return nil end
  return tonumber(value)
end

function Internal.SafeResults(name, ...)
  local fn = _G[name]
  if type(fn) ~= "function" then return nil end
  local results = { pcall(fn, ...) }
  if not table.remove(results, 1) then return nil end
  return results
end

function Internal.ItemKey(link, name)
  -- SB-101: only strings are parsed; a wrong-type link/name yields an empty key.
  if type(link) == "string" then
    local id = string.match(link, "item:(%d+)")
    if id then return "item:" .. id end
  end
  if type(name) == "string" and name ~= "" then return string.lower(name) end
  return ""
end

function Internal.SpellIDFromLink(link)
  if type(link) ~= "string" then return nil end
  local id = string.match(link, "spell:(%d+)")
  if not id then id = string.match(link, "trade:[^:]+:(%d+)") end
  if not id then return nil end
  id = tonumber(id)
  if id and id > 0 then return math.floor(id) end
  return nil
end

function Internal.NumericItemID(itemKey, link, itemID)
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

-- SB-10: one canonical key for prices, counts, and explanations.
function Internal.ReagentKey(reagent)
  if type(reagent) ~= "table" then return "" end
  if type(reagent.key) == "string" and reagent.key ~= "" then
    return reagent.key
  end
  return Skilly.NormalizeItemKey(reagent.link)
      or Skilly.NormalizeItemKey(reagent.name)
      or ""
end

-- Reset hooks let Cost.lua clear its item-count cache without owning
-- Sources.lua's registry caches.
Internal.ResetHooks = {}

function Skilly.RegisterReset(fn)
  if type(fn) ~= "function" then return end
  Internal.ResetHooks[#Internal.ResetHooks + 1] = fn
end

-- SB-12/SB-46: shared source-grade order, used by Cost and Rank.
Internal.GradeOrder = { onHand = 0, asIf = 1, vendor = 2, market = 3, unknown = 4 }

-- SB-43: one registry for every realistic option. Rows are data only; the safe
-- lookup below handles corrupt saves and unknown keys.
Skilly.Features = {
  { key = "useAuctionator", default = true, category = "Prices",
    label = "Auctionator prices",
    tooltip = "Allow read-only Auctionator price lookups when Auctionator is installed." },
  { key = "useTSM", default = true, category = "Prices",
    label = "TSM prices",
    tooltip = "Allow read-only TradeSkillMaster price lookups when TSM is installed." },
  { key = "useVendorPrices", default = true, category = "Prices",
    label = "Vendor prices",
    tooltip = "Use bundled and addon-provided vendor prices." },
  { key = "useManualPrices", default = true, category = "Prices",
    label = "Manual prices",
    tooltip = "Use /skilly prices overrides. Manual prices always win." },
  { key = "useAsIfOwned", default = true, category = "Prices",
    label = "As-if-owned materials",
    tooltip = "Treat /skilly asif-listed materials as free and available." },

  { key = "allowAHMaterials", default = true, category = "Ranking",
    label = "Recommend AH (market) materials",
    tooltip = "Off: AH/market prices are excluded; vendor-priced, manual, and as-if-owned materials remain eligible." },
  { key = "useAltInventory", default = false, category = "Ranking",
    label = "Include alt/external inventory (opt-in)",
    tooltip = "Opt-in external/alt counts. Default off for correctness: external counts are never described as \"your materials\"." },
  { key = "useScarcity", default = true, category = "Ranking",
    label = "Scarcity estimate",
    tooltip = "Estimate unknown prices by material scarcity instead of 1 copper." },
  { key = "useCrossSkill", default = true, category = "Ranking",
    label = "Cross-skill weight",
    tooltip = "Count other-profession materials as harder to obtain in scarcity estimates." },
  { key = "useRarity", default = true, category = "Ranking",
    label = "Item-rarity weight",
    tooltip = "Count uncommon+ materials as harder to obtain in scarcity estimates." },
  { key = "useTierWeight", default = true, category = "Ranking",
    label = "Material-tier weight",
    tooltip = "Scale scarcity estimates by material tier." },
  { key = "useProbability", default = true, category = "Ranking",
    label = "Skill-up probability",
    tooltip = "Rank by cost per expected skill point instead of raw cost." },
  { key = "useObservedRate", default = true, category = "Ranking",
    label = "Observed craft rate",
    tooltip = "Allow bounded local craft observations to adjust crafts-per-point estimates." },
  { key = "useSynergy", default = false, category = "Ranking",
    label = "Synergy hints (partial)",
    status = "partial",
    tooltip = "Currently implemented as opt-in disenchant/synergy hint text only (e.g. Enchanting dust supply). Broader cross-profession synergy scoring is not implemented." },

  { key = "showSourceLabels", default = true, category = "Output",
    label = "Source labels",
    tooltip = "Show manual/vendor/AH/unknown source labels in missing-material details." },
  { key = "showMissing", default = true, category = "Output",
    label = "Missing materials",
    tooltip = "Show missing-material details in recommendations." },
  { key = "showChatRecommendations", default = true, category = "Output",
    label = "Chat recommendations",
    tooltip = "Print recommendations to chat. Off: only show result window when available; falls back to chat if window cannot be shown." },
  { key = "showEstimates", default = true, category = "Output",
    label = "Estimate markers",
    tooltip = "Show the (estimate) marker when recipe probability is estimated." },
  { key = "showUnlockHints", default = true, category = "Output",
    label = "Unlock hints",
    tooltip = "Show trainer-captured unlock hints in recommendation details." },
  { key = "showResaleWarning", default = false, category = "Output",
    label = "Resale warning",
    tooltip = "Warn when full material cost exceeds the item's reliable sell price." },
  { key = "showFullCostRecommendation", default = true, category = "Output",
    label = "Full-material-cost winner",
    tooltip = "Show the separate full-material-cost recommendation." },

  { key = "useCompanionAnchor", default = false, category = "Window",
    label = "Anchor to Professions window",
    tooltip = "Anchor Skilly results beside the Professions window instead of floating standalone." },
  { key = "useSidebarTab", default = false, category = "Window",
    label = "Dock in Professions sidebar",
    tooltip = "Add a Skilly tab to the Professions window sidebar (opt-in). Falls back to the floating window when the sidebar is unavailable or unsafe." },
  { key = "useElvUISkin", default = true, category = "Window",
    label = "ElvUI-style skin",
    tooltip = "Use a self-contained dark ElvUI-like palette when ElvUI is detected; otherwise the stock WoW look." },
  { key = "useAutoAdviceOnOpen", default = false, category = "Window",
    label = "Auto-advice on profession open",
    tooltip = "Print one Skilly recommendation when a compatible profession window opens." },
  { key = "highlightRecommendedRecipe", default = false, category = "Window",
    label = "Highlight recommended recipe",
    tooltip = "Try to select the recommended recipe in the default Professions UI. Opt-in; guarded no-op if unavailable/unsafe." },
}

function Skilly.Features.IsEnabled(key)
  if type(key) ~= "string" or key == "" then return nil end
  local db = type(SkillyDB) == "table" and SkillyDB or nil
  for _, row in ipairs(Skilly.Features) do
    if type(row) == "table" and row.key == key then
      local stored = nil
      if db and type(db.features) == "table" then stored = db.features[key] end
      if type(stored) == "boolean" then return stored end
      return row.default == true
    end
  end
  return nil
end

-- SB-43: safe lookup used by every call site. Unknown keys and corrupt values
-- fall back to the caller's default without throwing.
function Skilly.FeatureEnabled(key, default)
  if type(key) ~= "string" or key == "" then return default end
  if type(default) ~= "boolean" then default = true end

  local features = Skilly.Features
  if type(features) == "table" then
    if type(features.IsEnabled) == "function" then
      local ok, value = pcall(features.IsEnabled, key)
      if ok and type(value) == "boolean" then return value end
    end
    local value = features[key]
    if type(value) == "boolean" then return value end
  end

  local db = type(SkillyDB) == "table" and SkillyDB or nil
  local stored = nil
  if db and type(db.features) == "table" then stored = db.features[key] end
  if type(stored) == "boolean" then return stored end
  return default
end

-- SB-36/SB-53: read the Forever profession window once, for probe and scan.
function Internal.ProfessionWindowInfo()
  local capi = _G.C_TradeSkillUI
  if type(capi) ~= "table" or type(capi.GetBaseProfessionInfo) ~= "function" then
    return nil
  end
  local results = Internal.CallResults(capi.GetBaseProfessionInfo)
  local info = results and results[1] or nil
  if type(info) ~= "table" then return nil end
  if type(info.professionName) ~= "string" or info.professionName == "" then
    return nil
  end
  return info
end

-- SB-36/SB-50: shared trainer gating. Forever can report "trainer" while a
-- crafting window is open, so a positive flag alone is not enough.
function Internal.TrainerServiceCount()
  local results = Internal.CallResults(_G.GetNumTrainerServices)
  local count = results and tonumber(results[1]) or 0
  if count < 0 or count ~= math.floor(count) then return 0 end
  return count
end

function Internal.TrainerRowHasData(index)
  local info = Internal.CallResults(_G.GetTrainerServiceInfo, index)
  local name = info and info[1] or nil
  if type(name) == "string" and name ~= "" then return true end

  local line = Internal.CallResults(_G.GetTrainerServiceSkillLine, index)
  local skillLine = line and line[1] or nil
  return type(skillLine) == "string" and skillLine ~= ""
end

function Internal.TrainerWindowOpen()
  local reportsTrainer = false
  if type(_G.IsTradeskillTrainer) == "function" then
    local results = Internal.CallResults(_G.IsTradeskillTrainer)
    reportsTrainer = results ~= nil and results[1] == true
  end

  if reportsTrainer then
    local count = Internal.TrainerServiceCount()
    for i = 1, math.min(count, 5) do
      if Internal.TrainerRowHasData(i) then return true end
    end
  end

  for _, name in ipairs({ "ClassTrainerFrame", "TrainerFrame" }) do
    local frame = _G[name]
    if frame then
      local results = Internal.CallResults(frame.IsVisible, frame)
      if results and results[1] == true then return true end
    end
  end
  return false
end

-- SB-50: read a trainer row's spell ID without selecting it or opening UI.
-- All tooltip calls are pcall-wrapped and the tooltip is always hidden again.
function Internal.TrainerSpellID(index)
  local tip = _G.GameTooltip
  if not tip then return nil end

  local results = nil
  local ok = pcall(function()
    tip:SetOwner(_G.UIParent, "ANCHOR_NONE")
    tip:ClearLines()
    if type(tip.SetTrainerService) ~= "function" then return end
    tip:SetTrainerService(index)
    results = { tip:GetSpell() }
  end)
  pcall(function() tip:Hide() end)

  if not ok or type(results) ~= "table" then return nil end
  for _, value in ipairs(results) do
    local n = tonumber(value)
    if n and n > 0 and n == math.floor(n) and n < 2000000 then
      return math.floor(n)
    end
  end
  return nil
end
