--[[---------------------------------------------------------------------------------
  Skilly - by faslkjd56
  WoW Forever 1.60.1 craft advisor
  Probe.lua - read-only API diagnostics
------------------------------------------------------------------------------------]]

Skilly = Skilly or {}
Skilly.Internal = Skilly.Internal or {}
local Internal = Skilly.Internal

-- SB-05/SB-36/SB-50: read-only API diagnostics.
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
  "C_Container.GetContainerNumSlots",
  "C_Container.GetContainerItemID",
  "C_Container.GetContainerItemInfo",
  "GetNumTrainerServices",
  "GetTrainerServiceInfo",
  "GetTrainerServiceSkillReq",
  "GetTrainerServiceSkillLine",
  "IsTradeskillTrainer",
}



-- One checked call wrapper shared by probe and scanner. Errors, wrong types,
-- zero and stale values are handled by callers, never by erroring here.

local function callAndPrint(label, fn, ...)
  if type(fn) ~= "function" then return end
  local results = { pcall(fn, ...) }
  local ok = table.remove(results, 1)
  if not ok then
    Skilly.Print(label .. " error: " .. tostring(results[1]))
    return
  end

  local parts = {}
  for i = 1, math.min(#results, 6) do
    parts[#parts + 1] = Internal.ScalarText(results[i])
  end
  Skilly.Print(label .. " = " .. table.concat(parts, ", "))
end

-- Unlike callAndPrint, this keeps the value type visible. Empty strings and
-- nils look identical in chat, so the trainer return shape needs this form.
local function callAndDescribe(label, fn, ...)
  if type(fn) ~= "function" then return end
  local results = { pcall(fn, ...) }
  local ok = table.remove(results, 1)
  if not ok then
    Skilly.Print(label .. " error: " .. tostring(results[1]))
    return
  end

  local parts = {}
  for i = 1, math.min(#results, 8) do
    local value = results[i]
    parts[#parts + 1] = Internal.ScalarText(value) .. "(" .. type(value) .. ")"
  end
  Skilly.Print(label .. " = " .. table.concat(parts, ", "))
end

local function apiState(value)
  return type(value) == "function" and "available" or "missing"
end

local function printTableFields(label, value, maxFields)
  if type(value) ~= "table" then
    Skilly.Print(label .. " returned " .. type(value))
    return
  end
  local keys = {}
  for key in pairs(value) do
    if type(key) == "string" then keys[#keys + 1] = key end
  end
  table.sort(keys)
  Skilly.Print(label .. " fields = " .. #keys)
  local limit = math.min(#keys, maxFields or 40)
  for i = 1, limit do
    Skilly.Print("  " .. keys[i] .. " = " .. Internal.ScalarText(value[keys[i]]))
  end
  if #keys > limit then
    Skilly.Print("  ... " .. (#keys - limit) .. " more fields")
  end
end

local function firstPositiveNumber(values)
  if type(values) ~= "table" then return nil end
  for _, value in pairs(values) do
    local n = tonumber(value)
    if n and n > 0 and n == math.floor(n) then return n end
  end
  return nil
end

local function printRecipeInfo(info)
  printTableFields("  GetRecipeInfo", info, 40)
end

-- Forward declaration: probeTradeSkillUI calls this before its definition.
local probeRecipeAPIs

local function probeTradeSkillUI()
  local capi = _G.C_TradeSkillUI
  Skilly.Print("C_TradeSkillUI: " .. (type(capi) == "table" and "available" or "missing"))
  if type(capi) ~= "table" then return nil end

  Skilly.Print("C_TradeSkillUI.GetAllRecipeIDs: " .. apiState(capi.GetAllRecipeIDs))
  Skilly.Print("C_TradeSkillUI.GetRecipeInfo: " .. apiState(capi.GetRecipeInfo))
  if type(capi.GetAllRecipeIDs) ~= "function" then return nil end

  local ok, ids = pcall(capi.GetAllRecipeIDs)
  if not ok then
    Skilly.Print("C_TradeSkillUI.GetAllRecipeIDs error: " .. tostring(ids))
    return nil
  end
  if type(ids) ~= "table" then
    Skilly.Print("C_TradeSkillUI.GetAllRecipeIDs returned " .. type(ids))
    return nil
  end

  local count = 0
  for _ in pairs(ids) do count = count + 1 end
  Skilly.Print("C_TradeSkillUI recipe IDs = " .. count)
  local sampleID = firstPositiveNumber(ids)
  if sampleID and type(capi.GetRecipeInfo) == "function" then
    local okInfo, info = pcall(capi.GetRecipeInfo, sampleID)
    if okInfo then
      Skilly.Print("C_TradeSkillUI.GetRecipeInfo(" .. sampleID .. "):")
      printRecipeInfo(info)
    else
      Skilly.Print("C_TradeSkillUI.GetRecipeInfo error: " .. tostring(info))
    end
    probeRecipeAPIs(capi, sampleID)
  end
  return count
end

-- The Forever client exposes the modern API family. Probe the exact calls a
-- scanner would need, but never craft, select, learn, or write data.
probeRecipeAPIs = function(capi, recipeID)
  if not recipeID then return end
  local calls = {
    { name = "GetBaseProfessionInfo", args = {} },
    { name = "GetProfessionInfoByRecipeID", args = { recipeID } },
    { name = "GetRecipeSchematic", args = { recipeID, false } },
    { name = "GetRecipeRequirements", args = { recipeID } },
    { name = "GetRecipeOutputItemData", args = { recipeID } },
    { name = "GetRecipeQualityItemIDs", args = { recipeID } },
    { name = "IsRecipeProfessionLearned", args = { recipeID } },
  }

  for _, call in ipairs(calls) do
    local fn = capi[call.name]
    Skilly.Print("C_TradeSkillUI." .. call.name .. ": " .. apiState(fn))
    if type(fn) == "function" then
      local ok, value = pcall(fn, Internal.Unpack(call.args))
      if not ok then
        Skilly.Print("C_TradeSkillUI." .. call.name .. " error: " .. tostring(value))
      elseif type(value) == "table" then
        printTableFields("C_TradeSkillUI." .. call.name .. "(" .. recipeID .. ")", value, 30)
        local reagentKeys = {
          "reagentSlotSchematics", "reagents", "reagentSlots", "reagentsOfQuality",
        }
        for _, key in ipairs(reagentKeys) do
          local list = value[key]
          if type(list) == "table" then
            for i = 1, math.min(#list, 5) do
              if type(list[i]) == "table" then
                printTableFields("  " .. key .. "[" .. i .. "]", list[i], 14)
                local nested = list[i].reagents
                if type(nested) == "table" then
                  for j = 1, math.min(#nested, 3) do
                    if type(nested[j]) == "table" then
                      printTableFields("    " .. key .. "[" .. i .. "].reagents["
                          .. j .. "]", nested[j], 10)
                    end
                  end
                end
              end
            end
          end
        end
      else
        Skilly.Print("C_TradeSkillUI." .. call.name .. " = "
            .. Internal.ScalarText(value) .. "(" .. type(value) .. ")")
      end
    end
  end
end

local function probeTrainer()
  local tip = _G.GameTooltip
  local okFn, setService = pcall(function() return tip and tip.SetTrainerService end)
  Skilly.Print("GameTooltip.SetTrainerService: "
      .. (okFn and apiState(setService) or "missing"))

  if not Internal.TrainerWindowOpen() then
    Skilly.Print("trainer window closed - no rows read")
    return
  end

  Skilly.Print("trainer window open - reading up to 5 sample rows")
  local serviceCount = Internal.TrainerServiceCount()
  if serviceCount < 1 then serviceCount = 1 end
  Skilly.Print("GetNumTrainerServices() = " .. serviceCount)

  for i = 1, math.min(serviceCount, 5) do
    callAndDescribe("GetTrainerServiceInfo(" .. i .. ")", _G.GetTrainerServiceInfo, i)
    callAndDescribe("GetTrainerServiceSkillReq(" .. i .. ")",
        _G.GetTrainerServiceSkillReq, i)
    callAndDescribe("GetTrainerServiceSkillLine(" .. i .. ")",
        _G.GetTrainerServiceSkillLine, i)
    local spellID = Internal.TrainerSpellID(i)
    Skilly.Print("trainer spellID(" .. i .. ") = " .. tostring(spellID or "unknown"))
  end
end

function Skilly.Probe()
  for _, name in ipairs(probeApis) do
    Skilly.Print(name .. ": " .. apiState(_G[name]))
  end
  probeTradeSkillUI()

  local modern = Internal.ProfessionWindowInfo()
  if modern then
    Skilly.Print("Profession window detected: " .. modern.professionName
        .. ", skill " .. tostring(tonumber(modern.skillLevel) or 0) .. "/"
        .. tostring(tonumber(modern.maxSkillLevel) or 0))
  else
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
      callAndPrint("GetTradeSkillRecipeLink(1)", _G.GetTradeSkillRecipeLink, 1)
    else
      Skilly.Print("No profession window detected.")
    end
  end

  probeTrainer()
end

Skilly.RegisterCommand("probe", Skilly.Probe, {
  usage = "/skilly probe",
  description = "Report available game APIs, the profession window, and trainer state.",
})
