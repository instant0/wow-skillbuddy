--[[---------------------------------------------------------------------------------
  Skilly - by faslkjd56
  WoW Forever 1.60.1 craft advisor
  Rank.lua - recommendation ranking and explanations
------------------------------------------------------------------------------------]]

Skilly = Skilly or {}
Skilly.Internal = Skilly.Internal or {}
local Internal = Skilly.Internal

-- SB-09: per-craft skill-up chance, driven by the client's recipe color.
Skilly.Rank = Skilly.Rank or {}

-- SB-43: every ranking/output toggle goes through the safe registry lookup.
local function featureEnabled(key, default)
  if type(Skilly.FeatureEnabled) ~= "function" then return default end
  local ok, value = pcall(Skilly.FeatureEnabled, key, default)
  if ok and type(value) == "boolean" then return value end
  return default
end

local function learnedThresholds(recipeKey)
  local db = type(SkillyCharDB) == "table" and SkillyCharDB.learned or nil
  if type(db) ~= "table" or type(recipeKey) ~= "string" then return nil end
  local entry = db[recipeKey]
  if type(entry) ~= "table" then return nil end

  local yellow = tonumber(entry.yellow)
  local green = tonumber(entry.green)
  local grey = tonumber(entry.grey)

  -- green is the 50% point: (yellow + grey) / 2. Two values are enough.
  if not yellow or not grey then
    if yellow and green then
      grey = 2 * green - yellow
    elseif green and grey then
      yellow = 2 * green - grey
    end
  end
  if not yellow or not grey or grey <= yellow then return nil end
  return yellow, grey
end

-- SB-37: bundled values are factual game data keyed by the recipe spell ID.
local function bundledThresholds(recipe)
  local tableData = Skilly.Thresholds
  if type(tableData) ~= "table" or type(recipe) ~= "table" then return nil end

  local id = tonumber(recipe.spellID) or Internal.SpellIDFromLink(recipe.link)
  if not id then return nil end
  id = math.floor(id)
  if id <= 0 then return nil end

  local entry = tableData[id]
  if type(entry) ~= "table" then return nil end

  local yellow = tonumber(entry[1])
  local grey = tonumber(entry[2])
  if not yellow or not grey or grey <= yellow then return nil end
  return yellow, grey
end

-- User-learned values win, then build-pinned game data, then band estimates.
local function thresholdsFor(recipe)
  if type(recipe) ~= "table" then return nil, nil, "estimate" end

  local yellow, grey = learnedThresholds(recipe.key)
  if yellow and grey then return yellow, grey, "learned" end

  yellow, grey = bundledThresholds(recipe)
  if yellow and grey then return yellow, grey, "gameData" end

  return nil, nil, "estimate"
end

function Skilly.Rank.Probability(recipe, skill, maxSkill)
  if type(recipe) ~= "table" then return 0 end
  recipe.thresholdSource = "color"

  local current = tonumber(skill) or 0
  local cap = tonumber(maxSkill) or 0
  if cap > 0 and current >= cap then
    recipe.estimate = false
    return 0
  end

  local detect = Skilly.Difficulty and Skilly.Difficulty.Detect
  if type(detect) ~= "function" then
    recipe.estimate = true
    recipe.thresholdSource = "estimate"
    return 0.25
  end

  local ok, info = pcall(detect, recipe.difficulty)
  if not ok or type(info) ~= "table" then
    recipe.estimate = true
    recipe.thresholdSource = "estimate"
    return 0.25
  end

  if info.color == "gray" then
    recipe.estimate = false
    return 0
  end
  if info.color == "orange" then
    recipe.estimate = false
    return 1
  end

  if info.color == "yellow" or info.color == "green" then
    local yellow, grey, source = thresholdsFor(recipe)
    recipe.thresholdSource = source or "estimate"
    if yellow and grey then
      local p = (grey - current) / (grey - yellow)
      if p < 0 then p = 0 elseif p > 1 then p = 1 end
      recipe.estimate = false
      return p
    end
    recipe.estimate = true
    return tonumber(info.base) or 0.25
  end

  recipe.estimate = true
  recipe.thresholdSource = "estimate"
  return tonumber(info.base) or 0.25
end

-- SB-39: scarcity estimate for one missing unit when no reliable price exists.
-- Runtime item metadata is preferred; the small static table fills gaps when
-- C_Item.GetItemInfo has no cached data. Never errors on bad items or missing APIs.
function Skilly.Rank.UnitPressure(reagent)
  local detail = {
    tier = 2, ease = 1, kind = "unknown", crossSkill = false, sourceSkill = nil,
  }
  if type(reagent) ~= "table" then return 3, detail end

  local key = reagent.key
  if type(key) ~= "string" or key == "" then
    key = Skilly.NormalizeItemKey(reagent.link)
        or Skilly.NormalizeItemKey(reagent.name)
        or ""
  end
  local itemID = Internal.NumericItemID(key, reagent.link, reagent.itemID)

  local fallback = nil
  if itemID and type(Skilly.MaterialPressure) == "table" then
    fallback = Skilly.MaterialPressure[itemID]
    if type(fallback) ~= "table" then fallback = nil end
  end

  local rarity, ilvl, itemType, subType = nil, nil, nil, nil
  local citem = _G.C_Item
  if type(citem) == "table" and type(citem.GetItemInfo) == "function" then
    local identifier = reagent.link or itemID or reagent.name
    local ok, _, _, r, lvl, _, typ, sub = pcall(citem.GetItemInfo, identifier)
    if ok then
      rarity, ilvl, itemType, subType = tonumber(r), tonumber(lvl), typ, sub
    end
  end

  local tier = fallback and tonumber(fallback.tier) or nil
  if not tier then
    local level = ilvl or 10
    if level < 0 then level = 0 elseif level > 150 then level = 150 end
    tier = math.floor(level / 15) + 1
  end
  if tier < 1 then tier = 1 elseif tier > 8 then tier = 8 end
  detail.tier = tier

  local base = featureEnabled("useTierWeight", true) and (2 ^ (tier - 1)) or 1
  local kind = fallback and fallback.kind or nil
  local ease = 1
  if fallback then
    if kind == "gem" then
      ease = 8
    elseif kind == "rare" then
      ease = 12
    elseif kind == "enchanting" then
      ease = 6
    elseif kind == "crafted" then
      ease = 2
    elseif kind == "gathered" then
      ease = 1.5
    end
  else
    local sub = type(subType) == "string" and string.lower(subType) or ""
    local typ = type(itemType) == "string" and string.lower(itemType) or ""
    if string.find(sub, "gem", 1, true) then
      kind, ease = "gem", 8
    elseif string.find(sub, "leather", 1, true) or string.find(sub, "cloth", 1, true)
        or string.find(sub, "herb", 1, true) or string.find(sub, "metal", 1, true)
        or string.find(sub, "stone", 1, true) then
      kind, ease = "gathered", 1.5
    elseif string.find(sub, "potion", 1, true) or string.find(sub, "elixir", 1, true) then
      kind, ease = "consumable", 4
    elseif string.find(sub, "enchant", 1, true) then
      kind, ease = "enchanting", 6
    elseif typ ~= "" then
      kind, ease = "crafted", 2
    end
  end
  detail.kind = kind or "unknown"

  local itemRarity = rarity or (fallback and tonumber(fallback.rarity) or nil)
  if featureEnabled("useRarity", true) and itemRarity and itemRarity >= 2 then
    ease = ease * (itemRarity * 3)
  end

  local sourceSkill = fallback and fallback.sourceSkill or nil
  if not sourceSkill then
    local sub = type(subType) == "string" and string.lower(subType) or ""
    if string.find(sub, "leather", 1, true) then
      sourceSkill = "Leatherworking"
    elseif string.find(sub, "cloth", 1, true) then
      sourceSkill = "Tailoring"
    elseif string.find(sub, "herb", 1, true) then
      sourceSkill = "Herbalism"
    elseif string.find(sub, "metal", 1, true) or string.find(sub, "stone", 1, true) then
      sourceSkill = "Mining"
    elseif string.find(sub, "potion", 1, true) or string.find(sub, "elixir", 1, true) then
      sourceSkill = "Alchemy"
    elseif string.find(sub, "enchant", 1, true) then
      sourceSkill = "Enchanting"
    end
  end

  local profession = Skilly.lastSnapshot and Skilly.lastSnapshot.profession or nil
  if featureEnabled("useCrossSkill", true) and sourceSkill
      and type(profession) == "string" and profession ~= ""
      and string.lower(profession) ~= string.lower(sourceSkill) then
    detail.crossSkill = true
    ease = ease * 3
  end
  detail.sourceSkill = sourceSkill
  detail.ease = ease

  local pressure = math.ceil(base * ease)
  if pressure < 1 then pressure = 1 end
  return pressure, detail
end

-- SB-39: ranking cost. Known prices stay literal; unknown prices get a
-- scarcity estimate so rare materials no longer look like 1 copper.
function Skilly.Rank.EffectiveCost(recipe)
  local info = { effectiveCost = 0, knownCost = 0, estimatedCost = 0, reagents = {} }
  if type(recipe) ~= "table" then return info end

  if type(recipe.reagents) == "table" then
    for _, reagent in ipairs(recipe.reagents) do
      if type(reagent) == "table" then
        local required = tonumber(reagent.count) or 0
        if required < 0 then required = 0 end
        required = math.floor(required)

        local owned = Skilly.Cost.ItemCount(reagent)
        local need = required - owned
        if need < 0 then need = 0 end

        local price, source, known = Skilly.Cost.PriceInfo(reagent)
        local unitCost, costKind, pressure = price, "known", nil
        if not known then
          if featureEnabled("useScarcity", true) then
            unitCost, pressure = Skilly.Rank.UnitPressure(reagent)
          else
            unitCost, pressure = 1, nil
            source = "default"
          end
          costKind = "estimated"
        end
        unitCost = tonumber(unitCost) or 1
        if unitCost < 0 then unitCost = 0 end

        local contribution = need * unitCost
        info.effectiveCost = info.effectiveCost + contribution
        if known then
          info.knownCost = info.knownCost + contribution
        else
          info.estimatedCost = info.estimatedCost + contribution
        end

        info.reagents[#info.reagents + 1] = {
          name = reagent.name,
          key = Internal.ReagentKey(reagent),
          need = need,
          unitCost = unitCost,
          costKind = costKind,
          source = source,
          tier = pressure and pressure.tier or nil,
          ease = pressure and pressure.ease or nil,
          crossSkill = pressure and pressure.crossSkill or false,
        }
      end
    end
  end

  info.distinctReagents = #info.reagents
  info.estimatedReagents = 0
  info.crossSkillReagents = 0
  for _, entry in ipairs(info.reagents) do
    if entry.costKind == "estimated" then
      info.estimatedReagents = info.estimatedReagents + 1
    end
    if entry.crossSkill then
      info.crossSkillReagents = info.crossSkillReagents + 1
    end
  end

  recipe.rankInfo = info
  return info
end

-- SB-39/SB-48: cost per expected skill point. The optional craftsPerPoint
-- override lets SB-48's bounded observation change the denominator without
-- changing the reported color probability. With no override this is identical
-- to effectiveCost / p, so existing callers are unaffected.
function Skilly.Rank.Score(recipe, skill, maxSkill, craftsPerPoint)
  local info = Skilly.Rank.EffectiveCost(recipe)
  local probability = Skilly.Rank.Probability(recipe, skill, maxSkill)
  info.probability = probability
  if not probability or probability <= 0 then return math.huge, info end

  local crafts = 1
  if featureEnabled("useProbability", true) then
    crafts = tonumber(craftsPerPoint)
    if not crafts or crafts <= 0 then crafts = 1 / probability end
  end
  info.craftsPerPoint = crafts
  return info.effectiveCost * crafts, info
end

-- SB-54: full-material ranking cost. Unlike EffectiveCost, this prices every
-- required unit and refuses to guess when any required reagent has no reliable
-- price. Owned stock is reported, not credited.
function Skilly.Rank.FullEffectiveCost(recipe)
  local info = {
    effectiveCost = 0, knownCost = 0, estimatedCost = 0,
    reagents = {}, invalid = false,
  }

  local rows
  if type(Skilly.Cost.FullMissing) == "function" then
    rows = Skilly.Cost.FullMissing(recipe)
  else
    rows = fullMaterialRows(recipe)
  end
  if type(rows) ~= "table" or #rows == 0 then
    info.invalid = true
    if type(recipe) == "table" then recipe.rankInfo = info end
    return info
  end

  for _, row in ipairs(rows) do
    local price = tonumber(row.price) or 0
    if price < 0 then price = 0 end
    local contribution = row.required * price
    info.effectiveCost = info.effectiveCost + contribution
    info.knownCost = info.knownCost + contribution
    info.reagents[#info.reagents + 1] = {
      name = row.name,
      key = row.key,
      need = row.required,
      owned = row.owned,
      unitCost = price,
      costKind = "known",
      source = row.source,
      fullCostBasis = true,
    }
  end

  info.distinctReagents = #info.reagents
  info.estimatedReagents = 0
  info.crossSkillReagents = 0
  if type(recipe) == "table" then recipe.rankInfo = info end
  return info
end

-- SB-54: cost per expected skill point on the full-material basis. Uses the
-- same observed/color denominator as Score so only the cost basis changes.
function Skilly.Rank.FullScore(recipe, skill, maxSkill, craftsPerPoint)
  local info = Skilly.Rank.FullEffectiveCost(recipe)
  local probability = Skilly.Rank.Probability(recipe, skill, maxSkill)
  info.probability = probability
  if info.invalid or not probability or probability <= 0 then
    return math.huge, info
  end

  local crafts = 1
  if featureEnabled("useProbability", true) then
    crafts = tonumber(craftsPerPoint)
    if not crafts or crafts <= 0 then crafts = 1 / probability end
  end
  info.craftsPerPoint = crafts
  return info.effectiveCost * crafts, info
end

local function ahMaterialsAllowed()
  return featureEnabled("allowAHMaterials", true)
end

function Skilly.Rank.FullCostEnabled()
  return featureEnabled("showFullCostRecommendation", true)
end

local function knownThresholds(recipe)
  if type(recipe) ~= "table" then return nil, nil end
  local yellow, grey, source = thresholdsFor(recipe)
  if not yellow or not grey or grey <= yellow then return nil, nil end
  if source ~= "learned" and source ~= "gameData" then return nil, nil end
  return yellow, grey
end

-- SB-76: expected skill points from N crafts with declining chance and gray cap.
-- Deterministic expected-value model: at skill s, p(s)=(grey-s)/(grey-yellow),
-- expected points E(s,n)=p(s)*(1+E(s+1,n-1)), capped by remaining points.
local function expectedSkillPoints(recipe, skill, maxSkill, crafts)
  local n = math.floor(tonumber(crafts) or 0)
  if n <= 0 then return 0 end
  local current = math.floor(tonumber(skill) or 0)
  local cap = math.floor(tonumber(maxSkill) or 0)

  local yellow, grey = knownThresholds(recipe)
  if not yellow or not grey then
    local p = Skilly.Rank.Probability(recipe, current, cap)
    if p <= 0 then return 0 end
    local points = n * p
    if cap > 0 then
      local rem = cap - current
      if rem < 0 then rem = 0 end
      if points > rem then points = rem end
    end
    return points
  end

  local limit = grey
  if cap > 0 and cap < limit then limit = cap end
  local remaining = limit - current
  if remaining <= 0 then return 0 end

  -- Iterative DP by remaining crafts to avoid deep recursion in Lua.
  local prev = {}
  for s = current, limit do prev[s] = 0 end
  for _ = 1, n do
    local nextRow = {}
    for s = current, limit do
      if s >= limit then
        nextRow[s] = 0
      else
        local p = (grey - s) / (grey - yellow)
        if p < 0 then p = 0 elseif p > 1 then p = 1 end
        local rem = limit - s
        local gain = 0
        if p > 0 then gain = p * (1 + (prev[s + 1] or 0)) end
        local val = gain + (1 - p) * (prev[s] or 0)
        if val > rem then val = rem end
        nextRow[s] = val
      end
    end
    prev = nextRow
  end
  local val = prev[current] or 0
  if val < 0 then val = 0 end
  if val > remaining then val = remaining end
  return val
end

-- SB-48: the color formula is the default. A bounded observation only changes
-- the crafts-per-point denominator when the optional helper actually reports
-- an intervention (>=2 crafts/point, already validated by SB-48).
local function expectedCraftsFor(recipe, skill, p)
  local display = math.ceil(1 / p)
  local denominator = 1 / p
  local source = "color"

  if not featureEnabled("useObservedRate", true) then
    return display, source, denominator
  end

  local observe = Skilly.Observe
  if p > 0 and p < 1 and type(observe) == "table"
      and type(observe.ExpectedCrafts) == "function" then
    local ok, observed, observedSource = pcall(observe.ExpectedCrafts, recipe, skill, p)
    if ok and observedSource == "observed" then
      observed = tonumber(observed)
      if observed and observed >= 2 then
        if observed > 6 then observed = 6 end
        display = observed
        denominator = observed
        source = "observed"
      end
    end
  end

  return display, source, denominator
end

-- SB-13/SB-54: one ranker for both modes and both cost bases. Entries never
-- mutate saved variables.
function Skilly.Rank.Best(snapshot, mode, costBasis)
  local results = {}
  local meta = {}
  local full = costBasis == "full"
  if full and type(Skilly.Rank.FullCostEnabled) == "function"
      and Skilly.Rank.FullCostEnabled() ~= true then
    return results
  end
  if type(snapshot) ~= "table" or type(snapshot.recipes) ~= "table" then
    return results
  end

  local skill = tonumber(snapshot.skill) or 0
  local maxSkill = tonumber(snapshot.maxSkill) or 0
  local cheap = mode ~= "best"
  local allowAH = ahMaterialsAllowed()

  local db = type(SkillyDB) == "table" and SkillyDB or nil
  local ignored = db and type(db.ignored) == "table" and db.ignored or nil
  local limit = db and tonumber(db.resultCount) or 5
  limit = math.floor(limit)
  if limit < 1 then limit = 1 elseif limit > 10 then limit = 10 end

  for _, recipe in ipairs(snapshot.recipes) do
    if type(recipe) == "table" and type(recipe.name) == "string" and recipe.name ~= "" then
      local key = type(recipe.key) == "string" and recipe.key or string.lower(recipe.name)
      local skip = ignored and ignored[key] == true
      if (tonumber(recipe.cooldown) or 0) > 0 then skip = true end

      if not skip then
        local p = 0
        if type(Skilly.Rank.Probability) == "function" then
          p = tonumber(Skilly.Rank.Probability(recipe, skill, maxSkill)) or 0
        end
        if p <= 0 then skip = true end

        if not skip and cheap then
          if type(Skilly.Cost.Obtainable) ~= "function"
              or Skilly.Cost.Obtainable(recipe) ~= true then
            skip = true
          end
        end

        local fullRows = nil
        if not skip and full then
          if type(Skilly.Cost.FullMissing) == "function" then
            fullRows = Skilly.Cost.FullMissing(recipe)
          end
          if type(fullRows) ~= "table" or #fullRows == 0 then skip = true end
        end

        if not skip then
          local missing = fullRows or {}
          if not full and type(Skilly.Cost.Missing) == "function" then
            local rows = Skilly.Cost.Missing(recipe)
            if type(rows) == "table" then missing = rows end
          end
          local grade = type(recipe.sourceGrade) == "string"
              and recipe.sourceGrade or "unknown"
          if cheap and (grade == "unknown" or (not allowAH and grade == "market")) then
            skip = true
          end

          if not skip then
            local costInfo = {}
            if type(Skilly.Cost.Recipe) == "function" then
              local info = Skilly.Cost.Recipe(recipe)
              if type(info) == "table" then costInfo = info end
            end
            local craftable = 0
            if type(Skilly.Cost.Craftable) == "function" then
              craftable = tonumber(Skilly.Cost.Craftable(recipe)) or 0
            end
            if craftable < 0 then craftable = 0 end
            craftable = math.floor(craftable)

            local display, source, denominator = expectedCraftsFor(recipe, skill, p)
            local override = source == "observed" and denominator or nil
            local score, info = math.huge, {}
            if full then
              if type(Skilly.Rank.FullScore) == "function" then
                local value, details = Skilly.Rank.FullScore(
                    recipe, skill, maxSkill, override)
                score = tonumber(value) or math.huge
                if type(details) == "table" then info = details end
              end
              if score == math.huge then
                local crafts = tonumber(denominator) or 1
                if crafts <= 0 then crafts = 1 end
                score = (tonumber(costInfo.fullCost) or 0) * crafts
              end
            elseif type(Skilly.Rank.Score) == "function" then
              local value, details = Skilly.Rank.Score(recipe, skill, maxSkill, override)
              score = tonumber(value) or math.huge
              if type(details) == "table" then info = details end
            end

            local outOfPocket = tonumber(costInfo.total) or 0
            local fullCost = tonumber(costInfo.fullCost) or 0
            if full then
              fullCost = tonumber(info.effectiveCost) or fullCost
            end

            local potentialPoints = 0
            if not full and craftable > 0 and p > 0 then
              potentialPoints = expectedSkillPoints(recipe, skill, maxSkill, craftable)
              local remainingCap = maxSkill > 0 and (maxSkill - skill) or craftable
              if remainingCap < 0 then remainingCap = 0 end
              local _, grey = knownThresholds(recipe)
              if grey then
                local remGrey = grey - math.floor(tonumber(skill) or 0)
                if remGrey < 0 then remGrey = 0 end
                remainingCap = math.min(remainingCap, remGrey)
              end
              if potentialPoints > remainingCap then potentialPoints = remainingCap end
            end

            local entry = {
              recipe = recipe,
              p = p,
              cost = full and fullCost or outOfPocket,
              fullCost = fullCost,
              outOfPocketCost = outOfPocket,
              costBasis = full and "full" or "onHand",
              craftable = full and 0 or craftable,
              missing = missing,
              onHandOnly = not full and craftable > 0,
              potentialPoints = potentialPoints,
              score = score,
              expectedCrafts = display,
              probabilitySource = source,
            }
            results[#results + 1] = entry
            meta[entry] = {
              key = key,
              grade = Internal.GradeOrder[grade] or 4,
              estimated = tonumber(info.estimatedReagents) or 0,
              crossSkill = tonumber(info.crossSkillReagents) or 0,
              madeMax = tonumber(recipe.madeMax) or 1,
            }
          end
        end
      end
    end
  end

  local compare
  if cheap then
    compare = function(a, b)
      if a.score ~= b.score then return a.score < b.score end
      if a.p ~= b.p then return a.p > b.p end
      local ap = tonumber(a.potentialPoints) or 0
      local bp = tonumber(b.potentialPoints) or 0
      if ap ~= bp then return ap > bp end
      local ma, mb = meta[a], meta[b]
      if ma.grade ~= mb.grade then return ma.grade < mb.grade end
      local aComplex = ma.estimated + ma.crossSkill
      local bComplex = mb.estimated + mb.crossSkill
      if aComplex ~= bComplex then return aComplex < bComplex end
      if a.craftable ~= b.craftable then return a.craftable > b.craftable end
      return ma.key < mb.key
    end
  else
    compare = function(a, b)
      local ap = tonumber(a.potentialPoints) or 0
      local bp = tonumber(b.potentialPoints) or 0
      if ap ~= bp then return ap > bp end
      if a.p ~= b.p then return a.p > b.p end
      if a.score ~= b.score then return a.score < b.score end
      if a.cost ~= b.cost then return a.cost < b.cost end
      local ma, mb = meta[a], meta[b]
      if ma.madeMax ~= mb.madeMax then return ma.madeMax > mb.madeMax end
      return ma.key < mb.key
    end
  end

  table.sort(results, compare)
  while #results > limit do results[#results] = nil end
  return results
end

-- SB-54: a separate entry point so partial builds cannot mistake the primary
-- result for a full-material-cost result.
function Skilly.Rank.BestFull(snapshot, mode)
  if type(Skilly.Rank.FullCostEnabled) == "function"
      and Skilly.Rank.FullCostEnabled() ~= true then
    return {}
  end
  if type(Skilly.Rank.Best) ~= "function" then return {} end

  local ok, results = pcall(Skilly.Rank.Best, snapshot, mode, "full")
  if ok and type(results) == "table" then return results end
  return {}
end

-- SB-14: plain ASCII, no localization. Every path returns a non-empty string
-- for a real entry and an empty string for junk data.
local function formatMoney(value)
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

local function formatCount(value)
  local n = tonumber(value) or 0
  if n < 0 then n = 0 end
  if n == math.floor(n) then return tostring(math.floor(n)) end
  return string.format("%.1f", n)
end

-- SB-42: informational phase 1. These helpers never touch the rank score,
-- SavedVariables, or any other addon's data.
local function normalizedItemName(value)
  if type(value) ~= "string" then return nil end
  local name = string.lower(value)
  name = string.gsub(name, "^%s+", "")
  name = string.gsub(name, "%s+$", "")
  if name == "" then return nil end
  return name
end

local function disenchantHint(recipe)
  if not featureEnabled("useSynergy", false) then return nil end
  if type(recipe) ~= "table" then return nil end
  local targets = Skilly.DisenchantTargets
  if type(targets) ~= "table" then return nil end
  local name = normalizedItemName(recipe.name)
  if not name then return nil end
  local dust = targets[name]
  if type(dust) ~= "string" or dust == "" then return nil end
  return "synergy: can supply " .. dust .. " for Enchanting"
end

local function itemSellPrice(recipe)
  if type(recipe) ~= "table" then return nil end
  local explicit = tonumber(recipe.sellPrice)
  if explicit and explicit > 0 then return math.floor(explicit) end

  local itemID = Internal.NumericItemID(
      Internal.ReagentKey(recipe), recipe.link, recipe.itemID)
  if not itemID or itemID <= 0 then return nil end
  local citem = _G.C_Item
  if type(citem) ~= "table" or type(citem.GetItemInfo) ~= "function" then return nil end
  local ok, _, _, _, _, _, _, _, _, _, sell = pcall(citem.GetItemInfo, itemID)
  sell = tonumber(sell)
  if not ok or not sell or sell <= 0 then return nil end
  return math.floor(sell)
end

local function materialCostForWarning(entry, recipe)
  if type(entry) ~= "table" then return nil end
  local cost = tonumber(entry.fullCost)
  if not cost or cost <= 0 then cost = tonumber(entry.cost) end
  if (not cost or cost <= 0) and type(Skilly.Cost.Recipe) == "function" then
    local ok, info = pcall(Skilly.Cost.Recipe, recipe)
    if ok and type(info) == "table" then
      cost = tonumber(info.fullCost) or tonumber(info.total)
    end
  end
  cost = tonumber(cost)
  if not cost or cost <= 0 then return nil end
  return math.floor(cost)
end

local function resaleWarning(entry)
  if not featureEnabled("showResaleWarning", false) then return nil end
  if type(entry) ~= "table" then return nil end
  local recipe = type(entry.recipe) == "table" and entry.recipe or nil
  if not recipe then return nil end

  local sell = itemSellPrice(recipe)
  if not sell then return nil end
  local cost = materialCostForWarning(entry, recipe)
  if not cost or cost <= sell then return nil end

  return "costs more than the item sells for (full material cost "
      .. formatMoney(cost) .. ", resale " .. formatMoney(sell) .. ")"
end

function Skilly.Rank.SynergyHint(recipe)
  local ok, hint = pcall(disenchantHint, recipe)
  if ok and type(hint) == "string" and hint ~= "" then return hint end
  return nil
end

function Skilly.Rank.ResaleWarning(entry)
  local ok, warning = pcall(resaleWarning, entry)
  if ok and type(warning) == "string" and warning ~= "" then return warning end
  return nil
end

local function sourceLabel(source)
  if source == "auctionator" or source == "auctioneer" or source == "tsm" then
    return "AH"
  end
  if source == "as-if" or source == "vendor" or source == "manual" then
    return source
  end
  return "unknown"
end

local function resolveMissingName(row)
  local name = type(row.name) == "string" and row.name or nil
  local key = type(row.key) == "string" and row.key or ""
  local itemID = tonumber(string.match(key, "^item:(%d+)$"))
  local needsResolve = not name or name == "" or name == "material"
      or string.match(name, "^Item %d+$") or string.match(name, "^item:%d+$")
  if needsResolve and itemID then
    local citem = _G.C_Item
    if type(citem) == "table" then
      if type(citem.GetItemNameByID) == "function" then
        local ok, n2 = pcall(citem.GetItemNameByID, itemID)
        if ok and type(n2) == "string" and n2 ~= "" then name = n2 end
      end
      if needsResolve and (not name or string.match(name, "^Item %d+$") or string.match(name, "^item:%d+$"))
          and type(citem.GetItemInfo) == "function" then
        local ok, infoName, link = pcall(citem.GetItemInfo, itemID)
        if ok and type(infoName) == "string" and infoName ~= "" then name = infoName end
        if (not name or name == "" or string.match(name, "^Item %d+$")) and type(link) == "string" then
          local linkName = string.match(link, "%[(.+)%]")
          if type(linkName) == "string" and linkName ~= "" then name = linkName end
        end
      end
      if (not name or string.match(name, "^Item %d+$") or string.match(name, "^item:%d+$"))
          and type(citem.RequestLoadItemDataByID) == "function" then
        pcall(citem.RequestLoadItemDataByID, itemID)
      end
    end

  end
  if not name or name == "" then
    if itemID then name = "item:" .. itemID else name = "material" end
  end
  return name
end

local function describeMissing(missing)
  local parts = {}
  if type(missing) ~= "table" then return "" end
  local showSource = featureEnabled("showSourceLabels", true)
  for _, row in ipairs(missing) do
    if type(row) == "table" and (tonumber(row.need) or 0) > 0 then
      local name = resolveMissingName(row)
      local text = formatCount(row.need) .. " x " .. name
      if showSource then text = text .. " (" .. sourceLabel(row.source) .. ")" end
      parts[#parts + 1] = text
    end
  end
  return table.concat(parts, " + ")
end

function Skilly.Rank.Describe(entry)
  if type(entry) ~= "table" then return "" end

  local recipe = type(entry.recipe) == "table" and entry.recipe or {}
  local name = type(recipe.name) == "string" and recipe.name or "Unknown recipe"
  if recipe.learnable then name = "Learn first: " .. name end
  local p = tonumber(entry.p) or 0
  local crafts = tonumber(entry.expectedCrafts) or 1
  if crafts < 1 then crafts = 1 end

  local color = "Unknown"
  local detect = Skilly.Difficulty and Skilly.Difficulty.Detect
  if type(detect) == "function" then
    local ok, info = pcall(detect, recipe.difficulty)
    if ok and type(info) == "table" and type(info.color) == "string" then
      local known = {
        orange = "Orange", yellow = "Yellow", green = "Green", gray = "Gray",
      }
      color = known[info.color] or "Unknown"
    end
  end

  local header
  if color == "Orange" then
    header = "Orange - guaranteed +1"
  elseif color == "Gray" then
    header = "Gray - no skillup"
  else
    header = color .. " ~" .. math.floor(p * 100 + 0.5) .. "%"
    if entry.probabilitySource == "observed" then
      header = header .. " (observed " .. formatCount(crafts) .. " crafts/point)"
    end
  end
  if recipe.estimate and featureEnabled("showEstimates", true) then
    header = header .. " (estimate)"
  end

  local parts = { header }
  if entry.probabilitySource ~= "observed" then
    parts[#parts + 1] = "~" .. formatCount(crafts)
        .. (crafts == 1 and " craft" or " crafts")
  end

  local cost = tonumber(entry.cost) or 0
  if cost > 0 then
    parts[#parts + 1] = formatMoney(cost * crafts) .. " per point"
  else
    parts[#parts + 1] = "free per point"
  end

  local craftable = tonumber(entry.craftable) or 0
  if craftable > 0 then
    parts[#parts + 1] = formatCount(craftable)
        .. (recipe.learnable and " craftable after learning"
            or " craftable with your materials")
  end
  if recipe.learnable then
    parts[#parts + 1] = "learn at skill "
        .. tostring(tonumber(recipe.learnRequired) or 0)
  end

  local missingText = ""
  if featureEnabled("showMissing", true) then
    missingText = describeMissing(entry.missing)
  end
  if missingText ~= "" then
    parts[#parts + 1] = "Buy " .. missingText
  elseif craftable <= 0 then
    parts[#parts + 1] = recipe.learnable
        and "all materials on hand after learning"
        or "all materials on hand"
  end

  local synergy = Skilly.Rank.SynergyHint(recipe)
  if synergy then parts[#parts + 1] = synergy end
  local resale = Skilly.Rank.ResaleWarning(entry)
  if resale then parts[#parts + 1] = resale end

  return name .. ": " .. table.concat(parts, ", ") .. "."
end

-- SB-48: unlock hints are a separate line and only come from a live trainer
-- capture. With no SB-48 hook, there is nothing to say.
function Skilly.Rank.DescribeHints(entry)
  local lines = {}
  local hints = Skilly.Hints
  if type(hints) ~= "table" or type(hints.Lines) ~= "function" then return lines end
  local ok, result = pcall(hints.Lines, entry)
  if not ok or type(result) ~= "table" then return lines end
  for _, line in ipairs(result) do
    if type(line) == "string" and line ~= "" then lines[#lines + 1] = line end
  end
  return lines
end
