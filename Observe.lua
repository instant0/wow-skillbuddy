--[[---------------------------------------------------------------------------------
  Skilly - by faslkjd56
  WoW Forever 1.60.1 craft advisor
  Observe.lua - bounded crafts-per-point observations
------------------------------------------------------------------------------------]]

Skilly = Skilly or {}
Skilly.Observe = Skilly.Observe or {}

local MAX_RECENT = 5
local MAX_COUNT = 10000
local RECENT_WINDOW = 30

-- In-memory only. A craft is identified by a CHAT_MSG_LOOT item, and its single
-- outcome is attributed to that recipe by the next CHAT_MSG_SKILL. A no-skillup
-- attempt is attributed only when the next different recipe begins before the
-- 30s timeout; an expired or otherwise ambiguous pending attempt is discarded.
local pending = nil

local function positiveInteger(value, minValue, maxValue)
  local n = tonumber(value)
  if not n or n ~= math.floor(n) then return nil end
  if minValue and n < minValue then return nil end
  if maxValue and n > maxValue then return nil end
  return math.floor(n)
end

local function nowClock()
  if type(_G.GetTime) ~= "function" then return nil end
  local ok, value = pcall(_G.GetTime)
  if not ok then return nil end
  return tonumber(value)
end

local function nowStamp()
  if type(_G.time) ~= "function" then return nil end
  local ok, value = pcall(_G.time)
  if not ok then return nil end
  local n = tonumber(value)
  if not n or n <= 0 then return nil end
  return math.floor(n)
end

local function bucketFor(skill)
  -- SB-102: clamp to the first 5-point bucket so skill 0 (and any sub-1 value)
  -- yields a usable bucket (1) instead of -4.
  local n = positiveInteger(skill, 1, 10000) or 1
  return math.floor((n - 1) / 5) * 5 + 1
end

local function validColor(value)
  if type(value) ~= "string" then return nil end
  local color = string.lower(value)
  if color == "optimal" or color == "orange" then return "orange" end
  if color == "medium" or color == "yellow" then return "yellow" end
  if color == "easy" or color == "green" then return "green" end
  if color == "trivial" or color == "gray" or color == "grey" then return "gray" end
  return nil
end

local function observationsDB(create)
  if type(SkillyCharDB) ~= "table" then
    if not create then return nil end
    SkillyCharDB = {}
  end
  local db = SkillyCharDB.observations
  if type(db) ~= "table" then
    if not create then return nil end
    db = {}
    SkillyCharDB.observations = db
  end
  return db
end

-- SB-48: one craft outcome only. skillAfter > skillBefore means a skillup;
-- equal values are an attempt with no point. Orange and gray are never stored.
function Skilly.Observe.Record(recipeKey, skillBefore, skillAfter, color)
  if type(recipeKey) ~= "string" or recipeKey == "" then return false end

  local before = positiveInteger(skillBefore, 0, 10000)
  local after = positiveInteger(skillAfter, 0, 10000)
  if not before or not after or after < before then return false end

  local kind = validColor(color)
  if not kind or kind == "orange" or kind == "gray" then return false end

  local bucket = bucketFor(before)
  local db = observationsDB(true)
  local entry = db[recipeKey]
  if type(entry) ~= "table" then
    entry = {}
    db[recipeKey] = entry
  end

  local attempts = positiveInteger(entry.attempts, 0, MAX_COUNT) or 0
  local skillups = positiveInteger(entry.skillups, 0, MAX_COUNT) or 0
  local gotSkill = after > before
  attempts = attempts + 1
  if attempts > MAX_COUNT then attempts = MAX_COUNT end
  if gotSkill then
    skillups = skillups + 1
    if skillups > MAX_COUNT then skillups = MAX_COUNT end
  end

  -- Keep only the current 5-point bucket so the rolling window cannot mix
  -- difficulty bands as the character levels.
  local recent = {}
  if type(entry.recent) == "table" then
    for _, row in ipairs(entry.recent) do
      if type(row) == "table" and positiveInteger(row.bucket, 1, 10000) == bucket then
        recent[#recent + 1] = {
          bucket = bucket,
          skillup = row.skillup == true,
          at = positiveInteger(row.at, 0, nil),
        }
      end
    end
  end
  recent[#recent + 1] = {
    bucket = bucket,
    skillup = gotSkill,
    at = nowStamp(),
  }
  while #recent > MAX_RECENT do table.remove(recent, 1) end

  entry.attempts = attempts
  entry.skillups = skillups
  entry.bucket = bucket
  entry.lastSkill = before
  entry.lastColor = kind
  entry.recent = recent
  return true
end

-- SB-13/SB-48: return craftsPerPoint, source. The ranker ignores anything that
-- is not "observed", so thin, corrupt, or stale data falls back to color.
function Skilly.Observe.ExpectedCrafts(recipe, skill, p)
  local chance = tonumber(p)
  if not chance or chance <= 0 or chance >= 1 then return nil, "color" end

  local base = math.ceil(1 / chance)
  if type(recipe) ~= "table" then return base, "color" end

  local key = type(recipe.key) == "string" and recipe.key
      or string.lower(tostring(recipe.name or ""))
  if key == "" then return base, "color" end

  local current = positiveInteger(skill, 0, 10000)
  if not current then return base, "color" end
  local bucket = bucketFor(current)

  local db = observationsDB(false)
  local entry = db and db[key]
  if type(entry) ~= "table" then return base, "color" end
  if positiveInteger(entry.bucket, 1, 10000) ~= bucket then return base, "color" end

  -- The rolling last-5 window is the only intervention evidence. Lifetime
  -- counters are stored for feedback, but must not resurrect an old rate.
  local attempts, skillups = 0, 0
  if type(entry.recent) == "table" then
    for _, row in ipairs(entry.recent) do
      if type(row) == "table" and positiveInteger(row.bucket, 1, 10000) == bucket then
        attempts = attempts + 1
        if row.skillup == true then skillups = skillups + 1 end
      end
    end
  end
  if attempts < 3 or skillups < 1 then return base, "color" end

  local rate = attempts / skillups
  if rate < 2 then return base, "color" end
  if rate > 6 then rate = 6 end
  local crafts = math.ceil(rate)
  if crafts < 1 then crafts = 1 elseif crafts > 6 then crafts = 6 end
  return crafts, "observed"
end

local function snapshot()
  local snap = Skilly.lastSnapshot
  if type(snap) ~= "table" or type(snap.recipes) ~= "table" then return nil end
  return snap
end

local function recipeForItemID(itemID)
  local snap = snapshot()
  if not snap then return nil end
  for _, recipe in ipairs(snap.recipes) do
    if type(recipe) == "table" and tonumber(recipe.itemID) == itemID then
      local key = type(recipe.key) == "string" and recipe.key
          or string.lower(tostring(recipe.name or ""))
      if key ~= "" then return recipe, key end
    end
  end
  return nil
end

local function expired(craft, now)
  return craft and craft.at and now and (now - craft.at) > RECENT_WINDOW
end

local function flushNoSkillup(now)
  if not pending then return end
  local craft = pending
  pending = nil
  if expired(craft, now) then return end
  pcall(Skilly.Observe.Record, craft.key, craft.skill, craft.skill, craft.color)
end

local function onLoot(message)
  if type(message) ~= "string" or not string.find(message, "^You ", 1) then return end
  local itemID = tonumber(string.match(message, "item:(%d+)"))
  if not itemID or itemID <= 0 then return end

  local recipe, key = recipeForItemID(itemID)
  if not recipe then return end
  local kind = validColor(recipe.difficulty)
  if not kind or kind == "orange" or kind == "gray" then return end

  local now = nowClock()
  if pending and pending.key ~= key then flushNoSkillup(now) end

  -- More than one loot line for the same output is still one craft attempt.
  if pending and pending.key == key and not expired(pending, now) then return end

  local snap = snapshot()
  local skill = tonumber(snap and snap.skill) or 0
  pending = { key = key, skill = skill, color = recipe.difficulty, at = now }
end

local function onSkill(message)
  if type(message) ~= "string" then return end
  local n = tonumber(string.match(message, "(%d+)"))
  if not n or n <= 0 then return end
  local newSkill = math.floor(n)

  local snap = snapshot()
  local profession = snap and type(snap.profession) == "string" and snap.profession or nil
  if profession and profession ~= "" and not string.find(message, profession, 1, true) then
    return
  end

  local craft = pending
  pending = nil
  if not craft then return end
  if expired(craft, nowClock()) then return end
  if newSkill <= craft.skill then return end

  pcall(Skilly.Observe.Record, craft.key, craft.skill, newSkill, craft.color)
end

local function onProfessionUpdate()
  local now = nowClock()
  if expired(pending, now) then pending = nil end
end

if type(_G.CreateFrame) == "function" then
  local okCreate, frame = pcall(_G.CreateFrame, "Frame")
  if okCreate and frame then
    local ok = pcall(function()
      frame:RegisterEvent("CHAT_MSG_LOOT")
      frame:RegisterEvent("CHAT_MSG_SKILL")
      frame:RegisterEvent("TRADE_SKILL_UPDATE")
      frame:RegisterEvent("SKILL_LINES_CHANGED")
      frame:SetScript("OnEvent", function(_, event, arg1)
        if event == "CHAT_MSG_LOOT" then
          pcall(onLoot, arg1)
        elseif event == "CHAT_MSG_SKILL" then
          pcall(onSkill, arg1)
        else
          pcall(onProfessionUpdate)
        end
      end)
    end)
    if not ok then frame = nil end
  end
end
