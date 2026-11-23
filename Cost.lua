--[[---------------------------------------------------------------------------------
  SkillBuddy - by faslkjd56
  WoW Forever 1.60.1 craft advisor
  Cost.lua - material costing and availability
------------------------------------------------------------------------------------]]

SkillBuddy = SkillBuddy or {}
SkillBuddy.Internal = SkillBuddy.Internal or {}
local Internal = SkillBuddy.Internal

-- SB-07: owned item counts. SkillBuddy reads the player's own bags itself;
-- optional sources only answer for stock outside them.
SkillBuddy.Cost = SkillBuddy.Cost or {}

local itemCountCache = {}
if type(SkillBuddy.RegisterReset) == "function" then
  SkillBuddy.RegisterReset(function() itemCountCache = {} end)
end

-- SB-32: default-on availability flag. Explicit false is the only opt-out.
function SkillBuddy.Cost.AssumePurchasable()
  local db = type(SkillBuddyDB) == "table" and SkillBuddyDB or nil
  if not db then return true end
  return db.assumePurchasable ~= false
end

-- SB-32: a curated free material. Wrong types and non-boolean values are not
-- treated as entries so a corrupt SavedVariable cannot silently change advice.
function SkillBuddy.Cost.IsAsIfOwned(reagentOrKey)
  local db = type(SkillBuddyDB) == "table" and SkillBuddyDB.asIfOwned or nil
  if type(db) ~= "table" then return false end

  local key = reagentOrKey
  if type(reagentOrKey) == "table" then key = reagentOrKey.key end
  if type(key) ~= "string" or key == "" then return false end
  return db[key] == true
end

local function countFromClient(key, link, itemID, name)
  local candidates = {}
  if itemID then candidates[#candidates + 1] = itemID end
  if type(link) == "string" and link ~= "" then candidates[#candidates + 1] = link end
  if type(name) == "string" and name ~= "" then candidates[#candidates + 1] = name end

  local includeBank = SkillBuddyDB and SkillBuddyDB.includeBank == true
  for _, identifier in ipairs(candidates) do
    local results = Internal.SafeResults("GetItemCount", identifier, includeBank)
    local value = results and tonumber(results[1]) or nil
    if value and value > 0 then return math.floor(value) end
  end
  return nil
end

local function countInBags(itemID, name)
  local total = 0
  for bag = 0, 4 do
    local slots = Internal.CallNumber(_G.GetContainerNumSlots, bag) or 0
    for slot = 1, slots do
      local slotID = Internal.CallNumber(_G.GetContainerItemID, bag, slot)
      if slotID and slotID > 0 then
        -- GetContainerItemInfo returns the stack count as its second value.
        local info = Internal.SafeResults("GetContainerItemInfo", bag, slot)
        local stack = info and tonumber(info[2]) or 0
        if stack > 0 then
          if itemID and slotID == itemID then
            total = total + stack
          elseif not itemID and name and type(_G.GetItemInfo) == "function" then
            local ok, itemName = pcall(_G.GetItemInfo, slotID)
            if ok and type(itemName) == "string" and string.lower(itemName) == name then
              total = total + stack
            end
          end
        end
      end
    end
  end
  return total
end

function SkillBuddy.Cost.ItemCount(reagent)
  if type(reagent) ~= "table" then return 0 end

  local key = reagent.key
  if type(key) ~= "string" or key == "" then
    key = Internal.ItemKey(reagent.link, reagent.name)
  end
  local link = reagent.link
  local name = type(reagent.name) == "string" and string.lower(reagent.name) or nil
  local itemID = Internal.NumericItemID(key, link, reagent.itemID)
  if key == "" and itemID then key = "item:" .. itemID end
  if key == "" then return 0 end

  local cached = itemCountCache[key]
  if cached ~= nil then return cached end

  local count = countFromClient(key, link, itemID, name)
  if not count then
    count = SkillBuddy.SourceValue("count", key, link, itemID)
  end
  if not count or count <= 0 then
    count = countInBags(itemID, name)
  end

  count = tonumber(count) or 0
  if count < 0 then count = 0 end
  count = math.floor(count)
  itemCountCache[key] = count
  return count
end


-- SB-12/SB-46: how certainly a missing unit can be obtained.
local function worstGrade(a, b)
  if not a then return b end
  if not b then return a end
  return (Internal.GradeOrder[b] or 4) > (Internal.GradeOrder[a] or 4) and b or a
end

local function hasReliablePrice(source)
  return source == "manual" or source == "vendor" or source == "as-if"
      or source == "auctionator" or source == "auctioneer" or source == "tsm"
end

local function gradeForPrice(source)
  if source == "vendor" or source == "manual" then return "vendor" end
  if source == "auctionator" or source == "auctioneer" or source == "tsm" then
    return "market"
  end
  return "unknown"
end

-- Real bag/bank count, upgraded to "fully covered" for as-if entries.
local function ownedForAvailability(reagent, key, required)
  local owned = tonumber(SkillBuddy.Cost.ItemCount(reagent)) or 0
  if owned < 0 then owned = 0 end
  owned = math.floor(owned)

  local asIf = key ~= "" and SkillBuddy.Cost.IsAsIfOwned(key) == true
  if asIf and owned < required then owned = required end
  return owned, asIf
end

local function analyzeReagents(recipe)
  local rows = {}
  local unknown = false
  local worst = "onHand"

  if type(recipe) ~= "table" or type(recipe.reagents) ~= "table" then
    return rows, true, "unknown"
  end

  for _, reagent in ipairs(recipe.reagents) do
    if type(reagent) ~= "table" then
      unknown = true
      worst = worstGrade(worst, "unknown")
    else
      local key = Internal.ReagentKey(reagent)
      local required = tonumber(reagent.count) or 0
      if required < 0 or required ~= math.floor(required) then required = 0 end
      required = math.floor(required)

      if key == "" or required <= 0 then
        unknown = true
        worst = worstGrade(worst, "unknown")
      else
        local owned, asIf = ownedForAvailability(reagent, key, required)
        local need = required - owned
        if need < 0 then need = 0 end

        local price, source = SkillBuddy.Cost.PriceFor(reagent)
        price = tonumber(price)
        if not price or price < 0 then price = 0 end
        local reliable = hasReliablePrice(source)

        local grade
        if asIf then
          grade = "asIf"
        elseif need <= 0 then
          grade = "onHand"
        elseif reliable then
          grade = gradeForPrice(source)
        else
          grade = "unknown"
        end
        worst = worstGrade(worst, grade)

        rows[#rows + 1] = {
          name = reagent.name,
          key = key,
          required = required,
          owned = owned,
          need = need,
          price = price,
          source = source,
          hasPrice = reliable,
          grade = grade,
        }
      end
    end
  end

  if #rows == 0 then unknown = true end
  return rows, unknown, worst
end

-- SB-54: full-material basis. Every required unit must have a reliable price,
-- even when some units are already owned. Real owned counts stay in the rows so
-- the output can explain why the two recommendations differ.
local function fullMaterialRows(recipe)
  local rows, unknown, worst = analyzeReagents(recipe)
  if unknown or #rows == 0 then return nil end

  local full = {}
  for _, row in ipairs(rows) do
    if row.required <= 0 or not row.hasPrice then return nil end
    full[#full + 1] = {
      name = row.name,
      key = row.key,
      required = row.required,
      owned = row.owned,
      need = row.required,
      price = row.price,
      source = row.source,
      hasPrice = true,
      grade = row.grade,
      fullCostBasis = true,
    }
  end
  return full, worst
end

function SkillBuddy.Cost.FullMissing(recipe)
  local rows, worst = fullMaterialRows(recipe)
  if type(recipe) == "table" then
    if rows and type(worst) == "string" then recipe.sourceGrade = worst end
    if not rows then recipe.unknownReagent = true end
  end
  return rows
end

-- SB-38: cheapest reliable price wins; the source only breaks exact ties.
-- Manual prices are handled first so they always beat automatic candidates.
function SkillBuddy.Cost.PriceFor(reagent)
  if type(reagent) ~= "table" then return 1, "default" end

  local key = Internal.ReagentKey(reagent)
  local link = reagent.link
  local name = type(reagent.name) == "string" and string.lower(reagent.name) or nil
  local itemID = Internal.NumericItemID(key, link, reagent.itemID)

  local db = type(SkillBuddyDB) == "table" and SkillBuddyDB or nil
  if db and type(db.prices) == "table" and key ~= "" then
    local manual = tonumber(db.prices[key])
    if manual and manual >= 0 then return manual, "manual" end
  end

  local bestPrice, bestSource, bestRank = nil, nil, nil
  local function consider(price, source, rank)
    price = tonumber(price)
    if not price or price < 0 then return end
    if bestPrice == nil or price < bestPrice
        or (price == bestPrice and rank < bestRank) then
      bestPrice, bestSource, bestRank = price, source, rank
    end
  end

  if SkillBuddy.Cost.IsAsIfOwned(key ~= "" and key or reagent) then
    consider(0, "as-if", 0)
  end

  if itemID and type(SkillBuddy.VendorPrices) == "table" then
    consider(SkillBuddy.VendorPrices[itemID], "vendor", 1)
  end

  if key ~= "" then
    for _, candidate in ipairs(SkillBuddy.SourceCandidates("vendorPrice", key, link, itemID)) do
      consider(candidate.value, "vendor", 1)
    end
    for _, candidate in ipairs(SkillBuddy.SourceCandidates("price", key, link, itemID)) do
      local label = candidate.name
      local rank = 4
      if label == "auctionator" or label == "auctioneer" then
        rank = 2
      elseif label == "tsm" then
        rank = 3
      end
      consider(candidate.value, label, rank)
    end
  end

  if bestPrice then return bestPrice, bestSource end
  return 1, "default"
end

-- SB-39: same lookup plus confidence. "default" means no reliable price was
-- found, so ranking must use a scarcity estimate instead of the copper value.
function SkillBuddy.Cost.PriceInfo(reagent)
  local price, source = SkillBuddy.Cost.PriceFor(reagent)
  return price, source, source ~= "default"
end

-- SB-10: cost for one craft. Only missing units are charged in `total`;
-- `fullCost` prices every required unit for comparison.
function SkillBuddy.Cost.Recipe(recipe)
  local result = { total = 0, fullCost = 0, detail = {} }
  if type(recipe) ~= "table" or type(recipe.reagents) ~= "table" then
    return result
  end

  for _, reagent in ipairs(recipe.reagents) do
    if type(reagent) == "table" then
      local required = tonumber(reagent.count) or 0
      if required < 0 then required = 0 end
      required = math.floor(required)

      local key = Internal.ReagentKey(reagent)
      local owned = ownedForAvailability(reagent, key, required)
      local need = required - owned
      if need < 0 then need = 0 end

      local price, source = SkillBuddy.Cost.PriceFor(reagent)
      price = tonumber(price) or 1
      if price < 0 then price = 0 end

      local subtotal = need * price
      result.total = result.total + subtotal
      result.fullCost = result.fullCost + required * price
      result.detail[#result.detail + 1] = {
        name = reagent.name,
        key = Internal.ReagentKey(reagent),
        required = required,
        owned = owned,
        need = need,
        price = price,
        subtotal = subtotal,
        source = source,
      }
    end
  end

  return result
end

-- SB-12: how many complete crafts the player can do with materials already
-- available (real stock plus as-if entries). Output quantity is not applied.
function SkillBuddy.Cost.Craftable(recipe)
  if type(recipe) ~= "table" or type(recipe.reagents) ~= "table" then
    if type(recipe) == "table" then recipe.unknownReagent = true end
    return 0
  end

  local limit = nil
  local unknown = false
  for _, reagent in ipairs(recipe.reagents) do
    if type(reagent) ~= "table" then
      unknown = true
    else
      local key = Internal.ReagentKey(reagent)
      local required = tonumber(reagent.count) or 0
      if required < 0 or required ~= math.floor(required) then required = 0 end
      required = math.floor(required)

      if key == "" or required <= 0 then
        unknown = true
      else
        local owned = ownedForAvailability(reagent, key, required)
        local crafts = math.floor(owned / required)
        if limit == nil or crafts < limit then limit = crafts end
      end
    end
  end

  if unknown then recipe.unknownReagent = true end
  if limit == nil then return 0 end
  return limit
end

-- SB-12/SB-46: only reagents with a real shortfall are "missing"; sourceGrade
-- summarizes the whole recipe so SB-13 can prefer vendor/on-hand materials.
function SkillBuddy.Cost.Missing(recipe)
  local rows, unknown, worst = analyzeReagents(recipe)
  if type(recipe) == "table" then
    recipe.sourceGrade = worst
    if unknown then recipe.unknownReagent = true end
  end

  local missing = {}
  for _, row in ipairs(rows) do
    if row.need > 0 then missing[#missing + 1] = row end
  end
  return missing
end

-- SB-12: on-hand, as-if, and purchasable-with-a-real-price all count when the
-- assumePurchasable setting is on. A fallback price of 1 never counts.
function SkillBuddy.Cost.Obtainable(recipe)
  local rows, unknown, worst = analyzeReagents(recipe)
  if type(recipe) == "table" then
    recipe.sourceGrade = worst
    if unknown then recipe.unknownReagent = true end
  end
  if unknown or #rows == 0 then return false end

  local assume = SkillBuddy.Cost.AssumePurchasable()
  for _, row in ipairs(rows) do
    if row.need > 0 and (not assume or not row.hasPrice) then
      return false
    end
  end
  return true
end
