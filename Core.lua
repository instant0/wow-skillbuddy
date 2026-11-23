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
  -- SB-50: live trainer capture. Written only by a successful trainer scan.
  trainerRecipes = {},
  trainerScans = {},
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
SkillBuddy.commandInfo = SkillBuddy.commandInfo or {}

-- SB-45: metadata is inert. A missing or malformed description never stops a
-- command from running, and good metadata is never replaced by nil.
function SkillBuddy.RegisterCommand(name, fn, info)
  if type(name) ~= "string" or type(fn) ~= "function" then return end
  name = string.lower(name)
  SkillBuddy.commands[name] = fn

  if type(info) == "table" then
    local entry = SkillBuddy.commandInfo[name] or {}
    if type(info.usage) == "string" and info.usage ~= "" then
      entry.usage = info.usage
    end
    if type(info.description) == "string" and info.description ~= "" then
      entry.description = info.description
    end
    SkillBuddy.commandInfo[name] = entry
  elseif SkillBuddy.commandInfo[name] == nil then
    SkillBuddy.commandInfo[name] = {}
  end
end

-- SB-52: bounded, in-memory copy of what we printed. Never saved to disk.
local MAX_OUTPUT_LINES = 400
local outputLog = {}

function SkillBuddy.ClearOutputLog()
  outputLog = {}
end

function SkillBuddy.OutputLog()
  local copy = {}
  for i = 1, #outputLog do copy[i] = outputLog[i] end
  return copy
end

function SkillBuddy.Print(message)
  local okLine, line = pcall(tostring, message)
  if not okLine or type(line) ~= "string" then line = "<unprintable>" end

  outputLog[#outputLog + 1] = line
  if #outputLog > MAX_OUTPUT_LINES then table.remove(outputLog, 1) end

  local frame = _G.DEFAULT_CHAT_FRAME
  if not frame then return end
  local okFn, addMessage = pcall(function() return frame.AddMessage end)
  if not okFn or type(addMessage) ~= "function" then return end
  pcall(addMessage, frame, "[SkillBuddy] " .. line)
end


-- SB-55: small, safety-checked helpers shared by the split runtime modules.
-- These are internal; public behavior stays on the SkillBuddy.* namespaces.
SkillBuddy.Internal = SkillBuddy.Internal or {}
local Internal = SkillBuddy.Internal

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
  local id = link and string.match(link, "item:(%d+)")
  if id then return "item:" .. id end
  if name and name ~= "" then return string.lower(name) end
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
  return SkillBuddy.NormalizeItemKey(reagent.link)
      or SkillBuddy.NormalizeItemKey(reagent.name)
      or ""
end

-- Reset hooks let Cost.lua clear its item-count cache without owning
-- Sources.lua's registry caches.
Internal.ResetHooks = {}

function SkillBuddy.RegisterReset(fn)
  if type(fn) ~= "function" then return end
  Internal.ResetHooks[#Internal.ResetHooks + 1] = fn
end

-- SB-12/SB-46: shared source-grade order, used by Cost and Rank.
Internal.GradeOrder = { onHand = 0, asIf = 1, vendor = 2, market = 3, unknown = 4 }

-- SB-48/SB-43: forward-compatible feature lookup. SB-43 may later replace this
-- with a full registry; until then a stored boolean or the safe default wins.
function SkillBuddy.FeatureEnabled(key, default)
  if type(key) ~= "string" or key == "" then return default end
  if type(default) ~= "boolean" then default = true end

  local features = SkillBuddy.Features
  if type(features) == "table" then
    if type(features.IsEnabled) == "function" then
      local ok, value = pcall(features.IsEnabled, key)
      if ok and type(value) == "boolean" then return value end
    end
    local value = features[key]
    if type(value) == "boolean" then return value end
  end

  local db = type(SkillBuddyDB) == "table" and SkillBuddyDB or nil
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
