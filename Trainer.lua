--[[---------------------------------------------------------------------------------
  Skilly - by faslkjd56
  WoW Forever 1.60.1 craft advisor
  Trainer.lua - read-only live trainer recipe capture
------------------------------------------------------------------------------------]]

Skilly = Skilly or {}
Skilly.Trainer = Skilly.Trainer or {}
local Internal = Skilly.Internal or {}

-- Bounds keep a bad or spoofed client result from growing SavedVariables.
local MAX_ROWS = 500
local MAX_STORED = 4000
local MAX_SAMPLE = 8
local MAX_TEXT = 160

-- "used"/"available" describe the character's current state, not the recipe,
-- so they are never stored as rank. "header" rows are skipped completely.
local categoryWords = {
  available = true,
  unavailable = true,
  used = true,
  header = true,
}

local function positiveInteger(value, minValue, maxValue)
  local n = tonumber(value)
  if not n or n ~= math.floor(n) then return nil end
  if minValue and n < minValue then return nil end
  if maxValue and n > maxValue then return nil end
  return math.floor(n)
end

local function cleanText(value)
  if type(value) ~= "string" then return nil end
  local text = string.gsub(value, "^%s+", "")
  text = string.gsub(text, "%s+$", "")
  if text == "" or #text > MAX_TEXT then return nil end
  return text
end

local function endsWith(text, suffix)
  if not text or not suffix then return false end
  local a = string.lower(text)
  local b = string.lower(suffix)
  return string.sub(a, -#b) == b
end

local function nowStamp()
  if type(_G.time) ~= "function" then return nil end
  local ok, value = pcall(_G.time)
  if not ok then return nil end
  local n = tonumber(value)
  if not n or n <= 0 then return nil end
  return math.floor(n)
end

local function recipeDB(create)
  if type(SkillyDB) ~= "table" then
    if not create then return nil end
    SkillyDB = {}
  end
  local db = SkillyDB.trainerRecipes
  if type(db) ~= "table" then
    if not create then return nil end
    db = {}
    SkillyDB.trainerRecipes = db
  end
  return db
end

local function scanDB(create)
  if type(SkillyDB) ~= "table" then
    if not create then return nil end
    SkillyDB = {}
  end
  local db = SkillyDB.trainerScans
  if type(db) ~= "table" then
    if not create then return nil end
    db = {}
    SkillyDB.trainerScans = db
  end
  return db
end

-- Parse only fields whose shape the live probe has already demonstrated:
--   GetTrainerServiceInfo(i) -> name, "used"/"available", icon, tier, "", category
--   GetTrainerServiceSkillReq(i) -> profession string, numeric skill, boolean
--   GetTrainerServiceSkillLine(i) -> "Tailoring"
--   tooltip GetSpell() -> positive numeric spell ID
--
-- Tier rows such as "Apprentice Tailoring" and "Journeyman Tailoring" are not
-- recipes. They were observed with a positive skill requirement, so rejecting
-- zero skill alone is not enough; a name ending in the profession is a tier.
local function parseRow(index)
  local info = Internal.CallResults(_G.GetTrainerServiceInfo, index)
  if not info then return nil end

  local name = cleanText(info[1])
  if not name then return nil end

  for i = 1, math.min(#info, 4) do
    if type(info[i]) == "string" and string.lower(info[i]) == "header" then
      return nil
    end
  end

  local line = Internal.CallResults(_G.GetTrainerServiceSkillLine, index)
  local profession = line and cleanText(line[1]) or nil
  if profession and endsWith(name, profession) then return nil end

  local rank = nil
  if type(info[2]) == "string" and not categoryWords[string.lower(info[2])] then
    rank = cleanText(info[2])
  end

  local req = Internal.CallResults(_G.GetTrainerServiceSkillReq, index)
  local skillRequired = req and positiveInteger(req[2], 1, 10000) or nil
  if not skillRequired then return nil end

  local spellID = Internal.TrainerSpellID(index)
  if not spellID then return nil end

  return {
    spellID = spellID,
    name = name,
    rank = rank,
    profession = profession,
    skillRequired = skillRequired,
    updated = nowStamp(),
  }
end

-- quiet=true is used by the event auto-capture. Trainer service rows can be
-- published a moment after TRAINER_SHOW, so an early empty read is not an error
-- and should not print or consume the retry throttle.
function Skilly.Trainer.Capture(quiet)
  quiet = quiet == true
  if not Internal.TrainerWindowOpen() then
    if not quiet then
      Skilly.Print("trainer window closed - no recipes captured")
    end
    return 0, 0
  end

  local serviceCount = Internal.TrainerServiceCount()
  if serviceCount < 1 then
    if not quiet then
      Skilly.Print("trainer has no service rows yet - wait for the window to finish loading, then run /skilly trainer again")
    end
    return 0, 0
  end

  local limit = math.min(serviceCount, MAX_ROWS)
  local db = recipeDB(true)
  local currentCount = 0
  for _ in pairs(db) do currentCount = currentCount + 1 end

  local added, refreshed, unchanged, skipped = 0, 0, 0, 0
  local samples = {}
  local profession = nil

  for i = 1, limit do
    local ok, row = pcall(parseRow, i)
    if not ok or type(row) ~= "table" then
      skipped = skipped + 1
    else
      if row.profession and not profession then profession = row.profession end

      local old = db[row.spellID]
      local isNew = type(old) ~= "table"
      local changed = isNew or old.name ~= row.name
          or old.skillRequired ~= row.skillRequired
          or old.profession ~= row.profession

      if isNew and currentCount >= MAX_STORED then
        skipped = skipped + 1
      elseif changed then
        db[row.spellID] = row
        if isNew then
          currentCount = currentCount + 1
          added = added + 1
        else
          refreshed = refreshed + 1
        end
        if #samples < MAX_SAMPLE then samples[#samples + 1] = row end
      else
        unchanged = unchanged + 1
      end
    end
  end

  local stamp = nowStamp()
  if stamp then
    local scans = scanDB(true)
    scans[profession or "unknown"] = stamp
  end

  if not quiet then
    Skilly.Print("trainer capture: " .. added .. " new, " .. refreshed
        .. " refreshed, " .. unchanged .. " unchanged, " .. skipped .. " skipped (of "
        .. limit .. " rows)")
    for _, row in ipairs(samples) do
      Skilly.Print("  captured " .. tostring(row.name) .. " - skill "
          .. tostring(row.skillRequired) .. ", spellID=" .. tostring(row.spellID)
          .. (row.profession and ", " .. row.profession or ""))
    end
    if added == 0 and refreshed == 0 and unchanged == 0 then
      Skilly.Print("No usable trainer rows. Run /skilly export at a crafting trainer.")
    end
  end

  return added, refreshed
end

-- Read-only accessor for SB-48. Returns a copy so callers cannot mutate the
-- SavedVariable, and rejects corrupt rows instead of trusting them.
function Skilly.Trainer.Recipe(spellID)
  local id = positiveInteger(spellID, 1, nil)
  if not id then return nil end

  local db = recipeDB(false)
  if not db then return nil end
  local row = db[id]
  if type(row) ~= "table" then return nil end

  local name = cleanText(row.name)
  local skill = positiveInteger(row.skillRequired, 1, 10000)
  if not name or not skill then return nil end

  return {
    spellID = id,
    name = name,
    rank = cleanText(row.rank),
    profession = cleanText(row.profession),
    skillRequired = skill,
    updated = positiveInteger(row.updated, 1, nil),
  }
end

function Skilly.Trainer.Count()
  local db = recipeDB(false)
  if not db then return 0 end
  local count = 0
  for _ in pairs(db) do count = count + 1 end
  return count
end

-- SB-50/SB-52: include trainer state in the copyable feedback export. The
-- report is bounded so a corrupt or very large SavedVariable cannot flood it.
function Skilly.Trainer.PrintReport(maxRows)
  local limit = positiveInteger(maxRows, 1, 200) or 60
  local db = recipeDB(false)

  Skilly.Print("trainer capture status: " .. Skilly.Trainer.Count()
      .. " recipe(s) stored")

  local scans = type(SkillyDB) == "table" and SkillyDB.trainerScans or nil
  if type(scans) == "table" then
    local names = {}
    for name, stamp in pairs(scans) do
      if type(name) == "string" and type(stamp) == "number" then
        names[#names + 1] = name .. "=" .. tostring(math.floor(stamp))
      end
    end
    table.sort(names)
    if #names > 0 then
      Skilly.Print("trainer last scan: " .. table.concat(names, ", "))
    end
  end

  local rows = {}
  if db then
    for id, row in pairs(db) do
      if type(row) == "table" then
        local skill = positiveInteger(row.skillRequired, 1, 10000)
        if skill then
          rows[#rows + 1] = {
            id = positiveInteger(id, 1, nil),
            name = cleanText(row.name),
            skill = skill,
            profession = cleanText(row.profession),
          }
        end
      end
    end
  end
  table.sort(rows, function(a, b)
    if a.skill ~= b.skill then return a.skill < b.skill end
    return (a.name or "") < (b.name or "")
  end)

  for i = 1, math.min(#rows, limit) do
    local row = rows[i]
    Skilly.Print("  trainer recipe: " .. tostring(row.name or "recipe")
        .. " - skill " .. tostring(row.skill) .. ", spellID=" .. tostring(row.id)
        .. (row.profession and ", " .. row.profession or ""))
  end
  if #rows > limit then
    Skilly.Print("  ... " .. (#rows - limit) .. " more stored recipe(s)")
  end
  if #rows == 0 then
    Skilly.Print("No trainer recipes stored yet. Open a crafting trainer and run /skilly trainer.")
  end
end

function Skilly.Trainer.Clear()
  if type(SkillyDB) ~= "table" then return end
  SkillyDB.trainerRecipes = {}
  SkillyDB.trainerScans = {}
  Skilly.Print("Trainer capture cleared.")
end

Skilly.RegisterCommand("trainer", function(arg)
  local text = string.gsub(tostring(arg or ""), "^%s+", "")
  text = string.gsub(string.lower(text), "%s+$", "")

  if text == "help" then
    Skilly.Print("Usage: /skilly trainer - read the open crafting trainer and store recipe unlock skills.")
    Skilly.Print("Usage: /skilly trainer clear - remove all captured trainer data.")
    Skilly.Print("Captured trainer recipes: " .. Skilly.Trainer.Count())
    return
  end
  if text == "clear" then
    Skilly.Trainer.Clear()
    return
  end
  Skilly.Trainer.Capture()
end, {
  usage = "/skilly trainer [clear]",
  description = "Read the open crafting trainer and store recipe unlock skills.",
})

-- Auto-capture on trainer events. The same window gate used by the scanner is
-- required here, so a crafting window can never be mistaken for a trainer.
local lastCapture = nil
local function onTrainerEvent(_, event)
  if event ~= "TRAINER_SHOW" and event ~= "TRAINER_UPDATE" then return end
  if not Internal.TrainerWindowOpen() then return end
  if Internal.TrainerServiceCount() < 1 then return end

  local now = Internal.CallNumber(_G.GetTime) or 0
  if lastCapture and (now - lastCapture) < 1 then return end

  local ok, added, refreshed = pcall(Skilly.Trainer.Capture, true)
  if not ok then
    Skilly.Print("Trainer capture failed: " .. tostring(added))
    return
  end
  if (tonumber(added) or 0) + (tonumber(refreshed) or 0) > 0 then
    lastCapture = now
  end
end

if type(_G.CreateFrame) == "function" then
  local ok, frame = pcall(_G.CreateFrame, "Frame")
  if ok and frame then
    local registered = pcall(function()
      frame:RegisterEvent("TRAINER_SHOW")
      frame:RegisterEvent("TRAINER_UPDATE")
      frame:SetScript("OnEvent", onTrainerEvent)
    end)
    if not registered then frame = nil end
  end
end
