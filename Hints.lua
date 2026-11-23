--[[---------------------------------------------------------------------------------
  SkillBuddy - by faslkjd56
  WoW Forever 1.60.1 craft advisor
  Hints.lua - unlock hints from live trainer capture only
------------------------------------------------------------------------------------]]

SkillBuddy = SkillBuddy or {}
SkillBuddy.Hints = SkillBuddy.Hints or {}

local MAX_HINTS = 2

local function positiveInteger(value, minValue, maxValue)
  local n = tonumber(value)
  if not n or n ~= math.floor(n) then return nil end
  if minValue and n < minValue then return nil end
  if maxValue and n > maxValue then return nil end
  return math.floor(n)
end

local function featureEnabled(key)
  if type(SkillBuddy.FeatureEnabled) == "function" then
    local ok, value = pcall(SkillBuddy.FeatureEnabled, key, true)
    if ok and type(value) == "boolean" then return value end
  end
  return true
end

local function cleanText(value)
  if type(value) ~= "string" then return nil end
  local text = string.gsub(value, "^%s+", "")
  text = string.gsub(text, "%s+$", "")
  if text == "" or #text > 160 then return nil end
  return text
end

local function lower(value)
  local text = cleanText(value)
  return text and string.lower(text) or nil
end

local function professionMatches(snapshot, recipe)
  local current = lower(snapshot and snapshot.profession)
  local captured = lower(recipe and recipe.profession)
  if not current or not captured then return true end
  return current == captured
end

-- SB-48: any captured, unpriced recipe is worth surfacing. Rankable learnable
-- recipes now enter the snapshot, so these hints cover only rows the client
-- could not price. The current winner's color no longer suppresses them.
local function entryIsUsable(entry)
  return type(entry) == "table" and type(entry.recipe) == "table"
      and type(entry.recipe.name) == "string"
end

local function topLine(entry)
  local recipe = type(entry.recipe) == "table" and entry.recipe or {}
  local name = cleanText(recipe.name) or "current best"
  local color = "not guaranteed"
  local detect = SkillBuddy.Difficulty and SkillBuddy.Difficulty.Detect
  if type(detect) == "function" then
    local ok, info = pcall(detect, recipe.difficulty)
    if ok and type(info) == "table" and type(info.color) == "string" then
      local known = {
        orange = "orange", yellow = "yellow", green = "green", gray = "gray",
      }
      color = known[string.lower(info.color)] or color
    end
  end

  local p = tonumber(entry.p) or 0
  if p < 0 then p = 0 elseif p > 1 then p = 1 end
  local line = "Current best, " .. name .. ", is " .. color
      .. " (~" .. math.floor(p * 100 + 0.5) .. "%)."
  if entry.probabilitySource == "observed" then
    local crafts = positiveInteger(entry.expectedCrafts, 1, 6)
    if crafts then
      line = line .. " Observed " .. crafts .. " crafts/point."
    end
  end
  return line
end

local function bundledWillBeOrange(spellID, skill)
  local thresholds = SkillBuddy.Thresholds
  if type(thresholds) ~= "table" then return false end
  local row = thresholds[spellID]
  if type(row) ~= "table" then return false end

  local yellow = tonumber(row[1])
  local grey = tonumber(row[2])
  if not yellow or not grey or grey <= yellow then return false end
  return yellow > skill
end

local function candidates(snapshot, skill)
  local found = {}
  local db = type(SkillBuddyDB) == "table" and SkillBuddyDB.trainerRecipes or nil
  if type(db) ~= "table" then return found end

  local knownSpell = {}
  local knownName = {}
  for _, recipe in ipairs(snapshot.recipes) do
    if type(recipe) == "table" then
      local id = positiveInteger(recipe.spellID, 1, nil)
      if id then knownSpell[id] = true end
      local name = lower(recipe.name)
      if name then knownName[name] = true end
    end
  end

  for id, _ in pairs(db) do
    local spellID = positiveInteger(id, 1, nil)
    if spellID and not knownSpell[spellID] then
      local ok, row = pcall(SkillBuddy.Trainer.Recipe, spellID)
      if ok and type(row) == "table" then
        local name = cleanText(row.name)
        local required = positiveInteger(row.skillRequired, 1, 10000)
        if name and required and required <= skill
            and not knownName[string.lower(name)]
            and professionMatches(snapshot, row)
            and bundledWillBeOrange(spellID, skill) then
          found[#found + 1] = { name = name, required = required, spellID = spellID }
        end
      end
    end
  end

  table.sort(found, function(a, b)
    if a.required ~= b.required then return a.required > b.required end
    return a.name < b.name
  end)
  while #found > MAX_HINTS do found[#found] = nil end
  return found
end

-- SB-48: debug-only explanation. It never appears in /sb next, and it stays
-- silent when no trainer data exists, so it is not a "check a trainer" nag.
function SkillBuddy.Hints.Status(entry)
  local db = type(SkillBuddyDB) == "table" and SkillBuddyDB.trainerRecipes or nil
  if type(db) ~= "table" then return nil end
  local stored = 0
  for _ in pairs(db) do stored = stored + 1 end
  if stored == 0 then return nil end

  if not featureEnabled("showUnlockHints") then
    return "unlock hints: disabled by showUnlockHints"
  end

  local snapshot = SkillBuddy.lastSnapshot
  if type(snapshot) ~= "table" or type(snapshot.recipes) ~= "table" then return nil end
  local skill = positiveInteger(snapshot.skill, 0, 10000)
  if not skill then return nil end

  if not entryIsUsable(entry) then return nil end

  if type(SkillBuddy.Trainer) ~= "table"
      or type(SkillBuddy.Trainer.Recipe) ~= "function" then
    return nil
  end

  if #candidates(snapshot, skill) == 0 then
    return "unlock hints: no unpriced unlearned captured recipe at skill " .. skill
  end
  return nil
end

-- SB-48/SB-54: called by Rank.DescribeHints from /sb next, /sb debug, and the
-- copyable export. With no trainer data, no toggle, or no snapshot it is silent.
function SkillBuddy.Hints.Lines(entry)
  local lines = {}
  if not featureEnabled("showUnlockHints") then return lines end
  if not entryIsUsable(entry) then return lines end

  local snapshot = SkillBuddy.lastSnapshot
  if type(snapshot) ~= "table" or type(snapshot.recipes) ~= "table" then return lines end
  if type(SkillBuddy.Trainer) ~= "table"
      or type(SkillBuddy.Trainer.Recipe) ~= "function" then
    return lines
  end

  local skill = positiveInteger(snapshot.skill, 0, 10000)
  if not skill then return lines end

  local rows = candidates(snapshot, skill)
  for _, row in ipairs(rows) do
    lines[#lines + 1] = "Unlock hint: at " .. row.required .. " " .. row.name
        .. " becomes available and would be orange."
  end
  if #rows > 0 then
    lines[#lines + 1] = topLine(entry)
    lines[#lines + 1] = "Check a trainer - SkillBuddy does not buy or learn recipes."
  end
  return lines
end
