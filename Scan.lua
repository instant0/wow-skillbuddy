--[[---------------------------------------------------------------------------------
  Skilly - by faslkjd56
  WoW Forever 1.60.1 craft advisor
  Scan.lua - profession and trainer snapshots
------------------------------------------------------------------------------------]]

Skilly = Skilly or {}
Skilly.Internal = Skilly.Internal or {}
local Internal = Skilly.Internal

-- SB-06: normalized snapshot of the open trade-skill window.
Skilly.Scan = Skilly.Scan or {}



-- SB-37: recipe links carry the spell/recipe ID used by the threshold table.
-- Never fall back to an item link: an item ID is not a spell ID.

local function numeric(value, fallback)
  local n = tonumber(value)
  if n == nil then return fallback end
  return n
end

-- Shared adapter helpers: never trust external addon data or calls.

-- SB-32: one canonical key for manual prices and the as-if-owned list.
-- Item IDs win; otherwise use the trimmed, lower-case name. Links without an
-- item ID are treated as a name copied from the link text.
function Skilly.NormalizeItemKey(value)
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

  local id = Internal.NumericItemID(value, value, nil)
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


local function positiveInteger(value, fallback)
  local n = tonumber(value)
  if not n or n <= 0 or n ~= math.floor(n) then return fallback end
  return math.floor(n)
end

-- Forever sends difficulty as relativeDifficulty: 0 orange, 1 yellow,
-- 2 green, 3 gray. Keep the classic word model used by Data.lua and Rank.
local function difficultyFromRelative(value)
  if type(value) == "string" then
    local raw = string.lower(value)
    if raw == "optimal" or raw == "orange" then return "optimal" end
    if raw == "medium" or raw == "yellow" then return "medium" end
    if raw == "easy" or raw == "green" then return "easy" end
    if raw == "trivial" or raw == "gray" or raw == "grey" then return "trivial" end
    return nil
  end
  local n = tonumber(value)
  if n == 0 then return "optimal" end
  if n == 1 then return "medium" end
  if n == 2 then return "easy" end
  if n == 3 then return "trivial" end
  return nil
end

local function itemIdentity(itemID)
  local id = positiveInteger(itemID, nil)
  if not id then return nil end
  local key = "item:" .. id
  local name = nil
  local link = nil
  local results = Internal.CallResults(_G.GetItemInfo, id)
  if results then
    if type(results[1]) == "string" and results[1] ~= "" then name = results[1] end
    if type(results[2]) == "string" and results[2] ~= "" then link = results[2] end
  end
  if not link then link = key end
  return { name = name or ("Item " .. id), key = key, link = link, itemID = id }
end

local function reagentsFromSchematic(schematic)
  local reagents = {}
  local slots = type(schematic) == "table" and schematic.reagentSlotSchematics or nil
  if type(slots) ~= "table" then return reagents end

  for _, slot in ipairs(slots) do
    if type(slot) == "table" then
      -- Basic reagents (type 1) are the required baseline. Optional, modifying,
      -- finishing and automatic slots are deliberately excluded: they are not
      -- part of the cheapest "buy what is missing" cost.
      local reagentType = tonumber(slot.reagentType)
      local include = slot.required ~= false
          and (reagentType == nil or reagentType == 1)
      if include then
        local count = positiveInteger(slot.quantityRequired, 0)
        if count > 0 and type(slot.reagents) == "table" then
          for _, reagent in ipairs(slot.reagents) do
            if type(reagent) == "table" then
              local identity = itemIdentity(reagent.itemID)
              if identity then
                reagents[#reagents + 1] = {
                  name = identity.name,
                  key = identity.key,
                  link = identity.link,
                  itemID = identity.itemID,
                  count = count,
                }
              end
            end
          end
        end
      end
    end
  end
  return reagents
end

local function recipeBelongsToProfession(capi, profession, recipeID)
  if type(capi.GetProfessionInfoByRecipeID) ~= "function" then return true end
  local results = Internal.CallResults(capi.GetProfessionInfoByRecipeID, recipeID)
  local info = results and results[1] or nil
  if type(info) ~= "table" then return true end

  local baseID = positiveInteger(profession.professionID, nil)
  local infoID = positiveInteger(info.professionID, nil)
  local parentID = positiveInteger(info.parentProfessionID, nil)
  if baseID and ((infoID and infoID == baseID) or (parentID and parentID == baseID)) then
    return true
  end

  local baseNumber = tonumber(profession.profession)
  local infoNumber = tonumber(info.profession)
  if baseNumber and infoNumber and baseNumber == infoNumber then return true end

  local baseName = profession.professionName
  local infoName = info.parentProfessionName or info.professionName
  if type(baseName) == "string" and type(infoName) == "string"
      and baseName ~= "" and infoName ~= "" then
    return string.lower(baseName) == string.lower(infoName)
  end
  return false
end

-- SB-48: an unlearned recipe enters ranking only when the live trainer capture
-- says it is available at the current skill. The client still supplies the
-- schematic/reagents, so it can be priced like any other recipe.
local function trainerLearnRow(recipeID, skill, professionName)
  local trainer = Skilly.Trainer
  if type(trainer) ~= "table" or type(trainer.Recipe) ~= "function" then return nil end
  local ok, row = pcall(trainer.Recipe, recipeID)
  if not ok or type(row) ~= "table" then return nil end

  local required = positiveInteger(row.skillRequired, 1, 10000)
  if not required or required > skill then return nil end

  local captured = type(row.profession) == "string" and string.lower(row.profession) or nil
  local current = type(professionName) == "string" and string.lower(professionName) or nil
  if captured and current and captured ~= current then return nil end
  return row
end

local function scanCurrentModern()
  local profession = Internal.ProfessionWindowInfo()
  if not profession then return nil end
  if Internal.TrainerWindowOpen() then return nil end

  local capi = _G.C_TradeSkillUI
  if type(capi) ~= "table" then return nil end
  if type(capi.GetAllRecipeIDs) ~= "function" or type(capi.GetRecipeInfo) ~= "function" then
    return nil
  end

  local idResults = Internal.CallResults(capi.GetAllRecipeIDs)
  if not idResults or type(idResults[1]) ~= "table" then return nil end

  local recipeIDs = {}
  for _, value in pairs(idResults[1]) do
    local id = positiveInteger(value, nil)
    if id then recipeIDs[#recipeIDs + 1] = id end
  end
  table.sort(recipeIDs)

  local snapshot = {
    profession = profession.professionName,
    skill = tonumber(profession.skillLevel) or 0,
    maxSkill = tonumber(profession.maxSkillLevel) or 0,
    recipes = {},
  }

  for _, recipeID in ipairs(recipeIDs) do
    if recipeBelongsToProfession(capi, profession, recipeID) then
      local infoResults = Internal.CallResults(capi.GetRecipeInfo, recipeID)
      local info = infoResults and infoResults[1] or nil
      if type(info) == "table" and type(info.name) == "string" and info.name ~= "" then
        local learnRow = nil
        if info.learned == false then
          learnRow = trainerLearnRow(recipeID, snapshot.skill, snapshot.profession)
        end
        local include = (info.learned ~= false or learnRow ~= nil)
            and info.disabled ~= true and info.isDummyRecipe ~= true
        if include then
          local difficulty = difficultyFromRelative(info.relativeDifficulty)
          if difficulty and type(capi.GetRecipeSchematic) == "function" then
            local schematicResults = Internal.CallResults(capi.GetRecipeSchematic, recipeID, false)
            local schematic = schematicResults and schematicResults[1] or nil
            if type(schematic) == "table" then
              local reagents = reagentsFromSchematic(schematic)
              if #reagents > 0 then
                local outputID = positiveInteger(schematic.outputItemID, nil)
                local link = nil
                if type(capi.GetRecipeOutputItemData) == "function" then
                  local outputResults = Internal.CallResults(capi.GetRecipeOutputItemData, recipeID)
                  local output = outputResults and outputResults[1] or nil
                  if type(output) == "table" then
                    outputID = positiveInteger(output.itemID, nil) or outputID
                    if type(output.hyperlink) == "string" and output.hyperlink ~= "" then
                      link = output.hyperlink
                    end
                  end
                end
                if not link then
                  local identity = itemIdentity(outputID)
                  link = identity and identity.link or nil
                end

                local madeMin = positiveInteger(schematic.quantityMin, 1)
                snapshot.recipes[#snapshot.recipes + 1] = {
                  index = #snapshot.recipes + 1,
                  name = info.name,
                  key = string.lower(info.name),
                  difficulty = difficulty,
                  link = link,
                  -- Forever's recipeID is the SkillLineAbility `Spell` value,
                  -- which is the key used by Skilly.Thresholds.
                  spellID = recipeID,
                  reagents = reagents,
                  madeMin = madeMin,
                  madeMax = positiveInteger(schematic.quantityMax, madeMin),
                  cooldown = 0,
                  itemID = outputID,
                  learned = info.learned == true,
                  learnable = learnRow ~= nil,
                  learnRequired = learnRow and learnRow.skillRequired or nil,
                }
              end
            end
          end
        end
      end
    end
  end

  return snapshot
end

local function scanCurrentClassic()
  local countResults = Internal.SafeResults("GetNumTradeSkills")
  local count = countResults and countResults[1] or 0
  local lineResults = Internal.SafeResults("GetTradeSkillLine")
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
    local info = Internal.SafeResults("GetTradeSkillInfo", i)
    if info then
      local name = info[1]
      local difficulty = info[2]
      if name and name ~= "" and difficulty ~= "header" then
        local linkResults = Internal.SafeResults("GetTradeSkillRecipeLink", i)
        local link = linkResults and linkResults[1] or nil
        local spellID = Internal.SpellIDFromLink(link)
        if not link then
          linkResults = Internal.SafeResults("GetTradeSkillItemLink", i)
          link = linkResults and linkResults[1] or nil
        end

        local reagents = {}
        local numReagents = Internal.SafeResults("GetTradeSkillNumReagents", i)
        local reagentCount = numReagents and numeric(numReagents[1], 0) or 0
        for j = 1, reagentCount do
          local reagent = Internal.SafeResults("GetTradeSkillReagentInfo", i, j)
          if reagent then
            local reagentName = reagent[1]
            local reagentCountValue = reagent[2]
            local reagentLink = reagent[3]
            if reagentName and reagentName ~= "" then
              reagents[#reagents + 1] = {
                name = reagentName,
                count = numeric(reagentCountValue, 0),
                link = reagentLink,
                key = Internal.ItemKey(reagentLink, reagentName),
              }
            end
          end
        end

        if #reagents > 0 then
          local made = Internal.SafeResults("GetTradeSkillNumMade", i)
          local madeMin = made and numeric(made[1], 1) or 1
          local madeMax = made and numeric(made[2], madeMin) or madeMin
          local cooldownResults = Internal.SafeResults("GetTradeSkillCooldown", i)
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

  return snapshot
end

function Skilly.Scan.Current()
  Skilly.ResetSourceCache()

  local modern = scanCurrentModern()
  if modern then
    Skilly.lastSnapshot = modern
    return modern
  end

  local classic = scanCurrentClassic()
  if classic then Skilly.lastSnapshot = classic end
  return classic
end
