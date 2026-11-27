--[[---------------------------------------------------------------------------------
  Skilly - by faslkjd56
  WoW Forever 1.60.1 craft advisor
  Cost.lua - material costing and availability
------------------------------------------------------------------------------------]]

Skilly = Skilly or {}
Skilly.Internal = Skilly.Internal or {}
local Internal = Skilly.Internal

-- SB-43: call-site guard. A missing or broken registry never changes advice.
local function featureEnabled(key, default)
  if type(Skilly.FeatureEnabled) ~= "function" then return default end
  local ok, value = pcall(Skilly.FeatureEnabled, key, default)
  if ok and type(value) == "boolean" then return value end
  return default
end

-- SB-07: owned item counts. Skilly reads the player's own bags itself;
-- optional sources only answer for stock outside them.
Skilly.Cost = Skilly.Cost or {}

local itemCountCache = {}
if type(Skilly.RegisterReset) == "function" then
  Skilly.RegisterReset(function() itemCountCache = {} end)
end

-- SB-32: default-on availability flag. Explicit false is the only opt-out.
function Skilly.Cost.AssumePurchasable()
  local db = type(SkillyDB) == "table" and SkillyDB or nil
  if not db then return true end
  return db.assumePurchasable ~= false
end

-- SB-32: a curated free material. Wrong types and non-boolean values are not
-- treated as entries so a corrupt SavedVariable cannot silently change advice.
function Skilly.Cost.IsAsIfOwned(reagentOrKey)
  if not featureEnabled("useAsIfOwned", true) then return false end
  local db = type(SkillyDB) == "table" and SkillyDB.asIfOwned or nil
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

  -- SB-88: only bag counts come from the client. Bank is never inferred from
  -- GetItemCount(..., true); a stale or malformed cache stays unavailable.
  for _, identifier in ipairs(candidates) do
    local results = Internal.SafeResults("GetItemCount", identifier, false)
    local value = results and tonumber(results[1]) or nil
    if value and value > 0 then return math.floor(value) end
  end
  return nil
end

local function countInBags(itemID, name)
  local total = 0
  local ccontainer = _G.C_Container
  if type(ccontainer) ~= "table" then return total end
  for bag = 0, 4 do
    local slots = Internal.CallNumber(ccontainer.GetContainerNumSlots, bag) or 0
    for slot = 1, slots do
      local slotID = Internal.CallNumber(ccontainer.GetContainerItemID, bag, slot)
      if slotID and slotID > 0 then
        local info = Internal.CallResults(ccontainer.GetContainerItemInfo, bag, slot)
        local info = info and info[1] or nil
        local stack = 0
        if type(info) == "table" then
          stack = tonumber(info.stackCount or info[2]) or 0
        end
        if stack > 0 then
          if itemID and slotID == itemID then
            total = total + stack
          elseif not itemID and name then
            local citem = _G.C_Item
            if type(citem) == "table" and type(citem.GetItemNameByID) == "function" then
              local ok, itemName = pcall(citem.GetItemNameByID, slotID)
              if ok and type(itemName) == "string" and string.lower(itemName) == name then
                total = total + stack
              end
            end
          end
        end
      end
    end
  end
  return total
end

local function positiveCount(value)
  local n = tonumber(value)
  if not n or n <= 0 then return 0 end
  return math.floor(n)
end

-- SB-102: a throwing bank helper must never abort costing or advice.
local function bankInfoSafe(includeBank)
  if includeBank ~= true then return nil end
  local bank = Skilly.Bank
  if type(bank) ~= "table" or type(bank.Info) ~= "function" then return nil end
  local ok, info = pcall(bank.Info, bank)
  if not ok or type(info) ~= "table" then return nil end
  return info
end

local function externalCountAllowed()
  return featureEnabled("useAltInventory", false)
end

-- SB-97: one external count decision per reagent. Candidates from different
-- adapters can describe the same stock, so at most one combined and at most one
-- alts-only candidate is selected (the first valid one in registry order).
-- A fresh bank snapshot suppresses every combined candidate: an unsplittable
-- combined total can include the bank stock already counted.
local function selectedExternalCount(key, link, itemID, hasFreshBank)
  local result = { alts = 0, combined = 0, altsSource = nil, combinedSource = nil }

  local candidates = type(Skilly.SourceCandidates) == "function"
      and Skilly.SourceCandidates("count", key, link, itemID) or {}
  local firstAlts, firstAltsSource, firstCombined, firstCombinedSource =
      nil, nil, nil, nil

  for _, c in ipairs(candidates) do
    local n = positiveCount(c and c.value)
    if n > 0 then
      local sourceName = tostring(c.name or "external")
      local isCombined = (c.combined == true) or (c.category ~= "alts")
      if isCombined then
        if firstCombined == nil then
          firstCombined, firstCombinedSource = n, sourceName
        end
      elseif firstAlts == nil then
        firstAlts, firstAltsSource = n, sourceName
      end
    end
  end

  if hasFreshBank then
    -- A specifically identified alts-only candidate may still be counted with
    -- the bank (at most one); combined candidates are suppressed.
    result.alts = firstAlts or 0
    result.altsSource = firstAltsSource
  elseif firstCombined ~= nil then
    result.combined = firstCombined
    result.combinedSource = firstCombinedSource
  else
    result.alts = firstAlts or 0
    result.altsSource = firstAltsSource
  end

  return result
end

function Skilly.Cost.ItemCountInfo(reagent)
  if type(reagent) ~= "table" then return { count = 0 } end

  local key = reagent.key
  if type(key) ~= "string" or key == "" then
    key = Internal.ItemKey(reagent.link, reagent.name)
  end
  local link = reagent.link
  local name = type(reagent.name) == "string" and string.lower(reagent.name) or nil
  local itemID = Internal.NumericItemID(key, link, reagent.itemID)
  if key == "" and itemID then key = "item:" .. itemID end
  if key == "" then return { count = 0 } end

  local includeBank = type(SkillyDB) == "table" and SkillyDB.includeBank == true
  local bank = Skilly.Bank
  local bankInfo = bankInfoSafe(includeBank)
  local hasFreshBank = type(bankInfo) == "table" and bankInfo.fresh == true
  local allowExternal = externalCountAllowed()

  local info = {
    count = 0, bags = 0, bank = 0, external = 0, alts = 0, combined = 0,
    altsSources = {}, combinedSources = {}, externalSources = {},
    hasFreshBank = hasFreshBank, bankUnavailable = includeBank and not hasFreshBank,
  }

  local bags = countFromClient(key, link, itemID, name)
  if not bags or bags <= 0 then bags = countInBags(itemID, name) end
  info.bags = positiveCount(bags)

  if hasFreshBank and type(bank.Count) == "function" then
    local okBank, value = pcall(bank.Count, key)
    if okBank then info.bank = positiveCount(value) end
  end

  if allowExternal then
    local ext = selectedExternalCount(key, link, itemID, hasFreshBank)
    info.alts = ext.alts
    info.combined = ext.combined
    if ext.altsSource then info.altsSources = { ext.altsSource } end
    if ext.combinedSource then info.combinedSources = { ext.combinedSource } end
    info.externalSources = ext.combined > 0 and info.combinedSources or info.altsSources
  end

  info.external = info.alts + info.combined
  info.count = info.bags + info.bank + info.external
  return info
end

function Skilly.Cost.ItemCount(reagent)
  if type(reagent) ~= "table" then return 0 end
  local key = reagent.key
  if type(key) ~= "string" or key == "" then
    key = Internal.ItemKey(reagent.link, reagent.name)
  end
  local itemID = Internal.NumericItemID(key, reagent.link, reagent.itemID)
  if key == "" and itemID then key = "item:" .. itemID end
  if key == "" then return 0 end

  local includeBank = type(SkillyDB) == "table" and SkillyDB.includeBank == true
  local allowExternal = externalCountAllowed()
  local bank = Skilly.Bank
  local bankInfo = bankInfoSafe(includeBank)
  local freshBank = type(bankInfo) == "table" and bankInfo.fresh == true
  -- SB-88: a stale bank cache and a fresh one must never share a count.
  local cacheKey = key .. ":" .. (freshBank and "B1" or "B0")
      .. ":" .. (allowExternal and "X1" or "X0")
  local cached = itemCountCache[cacheKey]
  if cached ~= nil then return cached end

  local info = Skilly.Cost.ItemCountInfo(reagent)
  local count = positiveCount(info and info.count)
  itemCountCache[cacheKey] = count
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

-- Real bag count, upgraded to "fully covered" for as-if entries. Bank is
-- counted separately from the fresh cache in ItemCountInfo.
local function ownedForAvailability(reagent, key, required)
  local owned = tonumber(Skilly.Cost.ItemCount(reagent)) or 0
  if owned < 0 then owned = 0 end
  owned = math.floor(owned)

  local asIf = key ~= "" and Skilly.Cost.IsAsIfOwned(key) == true
  if asIf and owned < required then owned = required end
  return owned, asIf
end

local function analyzeReagents(recipe, allowMarket)
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

        local price, source = Skilly.Cost.PriceFor(reagent, allowMarket)
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
local function fullMaterialRows(recipe, allowMarket)
  local rows, unknown, worst = analyzeReagents(recipe, allowMarket)
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

function Skilly.Cost.FullMissing(recipe, allowMarket)
  local rows, worst = fullMaterialRows(recipe, allowMarket)
  if type(recipe) == "table" then
    if rows and type(worst) == "string" then recipe.sourceGrade = worst end
    if not rows then recipe.unknownReagent = true end
  end
  return rows
end

-- SB-38: cheapest reliable price wins; the source only breaks exact ties.
-- Manual prices are handled first so they always beat automatic candidates.
function Skilly.Cost.PriceFor(reagent, allowMarket)
  if type(reagent) ~= "table" then return 1, "default" end
  if allowMarket == nil then allowMarket = true end

  local key = Internal.ReagentKey(reagent)
  local link = reagent.link
  local name = type(reagent.name) == "string" and string.lower(reagent.name) or nil
  local itemID = Internal.NumericItemID(key, link, reagent.itemID)

  local db = type(SkillyDB) == "table" and SkillyDB or nil
  if featureEnabled("useManualPrices", true)
      and db and type(db.prices) == "table" and key ~= "" then
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

  if Skilly.Cost.IsAsIfOwned(key ~= "" and key or reagent) then
    consider(0, "as-if", 0)
  end

  if featureEnabled("useVendorPrices", true)
      and itemID and type(Skilly.VendorPrices) == "table" then
    consider(Skilly.VendorPrices[itemID], "vendor", 1)
  end

  if key ~= "" then
    for _, candidate in ipairs(Skilly.SourceCandidates("vendorPrice", key, link, itemID)) do
      consider(candidate.value, "vendor", 1)
    end
    -- SB-105: filter market/AH candidates before choosing the cheapest price,
    -- so a disallowed market price cannot shadow a still-eligible vendor price.
    if allowMarket then
      for _, candidate in ipairs(Skilly.SourceCandidates("price", key, link, itemID)) do
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
  end

  if bestPrice then return bestPrice, bestSource end
  return 1, "default"
end

-- SB-39: same lookup plus confidence. "default" means no reliable price was
-- found, so ranking must use a scarcity estimate instead of the copper value.
function Skilly.Cost.PriceInfo(reagent, allowMarket)
  local price, source = Skilly.Cost.PriceFor(reagent, allowMarket)
  return price, source, source ~= "default"
end

-- SB-81/SB-88: summarize where counted materials come from. Bank is counted
-- only from a fresh cache; alts are opt-in; combined external sources keep
-- their own label.
function Skilly.Cost.OwnershipSummary(recipe)
  local summary = {
    bags = 0, bank = 0, alts = 0, combined = 0, external = 0,
    asIf = 0, unknown = 0, craftable = 0,
  }
  if type(recipe) ~= "table" or type(recipe.reagents) ~= "table" then
    summary.unknown = 1
    return summary
  end
  local limit = nil
  local includeBank = type(SkillyDB) == "table" and SkillyDB.includeBank == true
  local bank = Skilly.Bank
  local bankInfo = bankInfoSafe(includeBank)
  local hasFreshBank = type(bankInfo) == "table" and bankInfo.fresh == true
  for _, reagent in ipairs(recipe.reagents) do
    if type(reagent) ~= "table" then
      summary.unknown = summary.unknown + 1
    else
      local key = Internal.ReagentKey(reagent)
      local required = math.floor(tonumber(reagent.count) or 0)
      if key == "" or required <= 0 then
        summary.unknown = summary.unknown + 1
      else
        local asIf = Skilly.Cost.IsAsIfOwned(key)
        local info = Skilly.Cost.ItemCountInfo(reagent)
        local bags = positiveCount(info.bags)
        local bnk = positiveCount(info.bank)
        local alts = positiveCount(info.alts)
        local combined = positiveCount(info.combined)
        local effectiveBags, effectiveBank, effectiveAlts = 0, 0, 0
        local effectiveCombined, effectiveAsIf = 0, 0
        local remaining = required
        local takeBags = math.min(bags, remaining); effectiveBags = takeBags; remaining = remaining - takeBags
        local takeBank = math.min(bnk, remaining); effectiveBank = takeBank; remaining = remaining - takeBank
        if asIf and remaining > 0 then effectiveAsIf = remaining; remaining = 0 end
        local takeAlts = math.min(alts, remaining); effectiveAlts = takeAlts; remaining = remaining - takeAlts
        local takeCombined = math.min(combined, remaining); effectiveCombined = takeCombined
        summary.bags = summary.bags + effectiveBags
        summary.bank = summary.bank + effectiveBank
        summary.alts = summary.alts + effectiveAlts
        summary.combined = summary.combined + effectiveCombined
        summary.external = summary.external + effectiveAlts + effectiveCombined
        summary.asIf = summary.asIf + effectiveAsIf
        local owned = effectiveBags + effectiveBank + effectiveAlts
            + effectiveCombined + effectiveAsIf
        local crafts = math.floor(owned / required)
        if limit == nil or crafts < limit then limit = crafts end
      end
    end
  end
  summary.craftable = limit or 0
  summary.includeBank = includeBank
  summary.hasFreshBank = hasFreshBank
  summary.bankUnavailable = includeBank and not hasFreshBank
  return summary
end

function Skilly.Cost.OwnershipLabel(recipe)
  local s = Skilly.Cost.OwnershipSummary(recipe)
  local parts = {}
  if (tonumber(s.bags) or 0) > 0 then parts[#parts+1] = "bags" end
  if (tonumber(s.bank) or 0) > 0 then parts[#parts+1] = "fresh bank" end
  if (tonumber(s.alts) or 0) > 0 then parts[#parts+1] = "alts" end
  if (tonumber(s.combined) or 0) > 0 then parts[#parts+1] = "alt/external (combined)" end
  if (tonumber(s.asIf) or 0) > 0 then parts[#parts+1] = "as-if" end
  if #parts == 0 then return "your materials" end
  local hasExternal = (tonumber(s.external) or 0) > 0
  local hasOnlyBags = #parts == 1 and parts[1] == "bags"
  if hasOnlyBags then return "your bags" end
  if hasExternal then return table.concat(parts, "+") .. " materials" end
  -- bags/fresh bank/as-if are the player's own counted materials.
  return "your materials (" .. table.concat(parts, "+") .. ")"
end

-- SB-88: compact four-category availability summary for text output. All
-- counts are complete crafts from that category alone, not owned-unit totals.
local function availableMoney()
  local results = Internal.SafeResults("GetMoney")
  local value = results and tonumber(results[1]) or nil
  if not value or value < 0 then return nil end
  return math.floor(value)
end

local function purchaseSourceLabel(grades)
  local hasAH, hasVendor = false, false
  for _, grade in ipairs(grades) do
    if grade == "market" then hasAH = true else hasVendor = true end
  end
  if hasAH and hasVendor then return "AH/vendor" end
  if hasAH then return "AH" end
  return "vendor"
end

-- SB-98: total purchase spend for n complete crafts across every missing
-- reagent line, accounting for already-owned partial stacks.
local function purchaseSpend(reagents, n)
  local total = 0
  for _, r in ipairs(reagents) do
    local units = n * r.required - r.owned
    if units < 0 then units = 0 end
    total = total + units * r.price
  end
  return total
end

-- SB-98: greatest complete-craft count whose combined purchase spend fits the
-- wallet. The per-reagent one-wallet bound is only a search ceiling, never the
-- reported answer.
local function maxAffordableCrafts(reagents, money)
  local ceiling = nil
  for _, r in ipairs(reagents) do
    if r.price and r.price > 0 then
      local bound = math.floor((r.owned + math.floor(money / r.price)) / r.required)
      if ceiling == nil or bound < ceiling then ceiling = bound end
    end
  end
  if ceiling == nil then ceiling = 0 end
  if ceiling < 0 then ceiling = 0 end

  local lo, hi = 0, ceiling
  while lo < hi do
    local mid = math.floor((lo + hi + 1) / 2)
    if purchaseSpend(reagents, mid) <= money then
      lo = mid
    else
      hi = mid - 1
    end
  end
  return lo
end

function Skilly.Cost.ProvenanceSummary(recipe)
  local summary = {
    self = 0, bank = 0, alts = 0, combined = 0, ah = 0,
    includeBank = false, bankFresh = false, altsAllowed = externalCountAllowed(),
    purchaseAllowed = false, marketAllowed = false, hasCombined = false,
    money = nil, moneyBounded = false, unknown = 0, text = "",
  }
  if type(recipe) ~= "table" or type(recipe.reagents) ~= "table" then
    summary.unknown = 1
    return summary
  end

  local includeBank = type(SkillyDB) == "table" and SkillyDB.includeBank == true
  local bank = Skilly.Bank
  local bankInfo = bankInfoSafe(includeBank)
  local hasFreshBank = type(bankInfo) == "table" and bankInfo.fresh == true
  summary.includeBank = includeBank
  summary.bankFresh = hasFreshBank
  summary.purchaseAllowed = Skilly.Cost.AssumePurchasable()
  summary.marketAllowed = featureEnabled("allowAHMaterials", true)
  summary.money = availableMoney()

  local selfLimit, bankLimit, altsLimit, combinedLimit = nil, nil, nil, nil
  local buyGrades = {}
  local buyReagents = {}
  local buyBlocked = false

  for _, reagent in ipairs(recipe.reagents) do
    if type(reagent) ~= "table" then
      summary.unknown = summary.unknown + 1
    else
      local key = Internal.ReagentKey(reagent)
      local required = math.floor(tonumber(reagent.count) or 0)
      if key == "" or required <= 0 then
        summary.unknown = summary.unknown + 1
      else
        local info = Skilly.Cost.ItemCountInfo(reagent)
        local selfCount = positiveCount(info.bags)
        local bankCount = hasFreshBank and positiveCount(info.bank) or 0
        local altCount = summary.altsAllowed and positiveCount(info.alts) or 0
        local combinedCount = summary.altsAllowed and positiveCount(info.combined) or 0
        if combinedCount > 0 then summary.hasCombined = true end
        local need = required - selfCount - bankCount - altCount - combinedCount
        if need < 0 then need = 0 end

        local selfCrafts = math.floor(selfCount / required)
        if selfLimit == nil or selfCrafts < selfLimit then selfLimit = selfCrafts end
        if hasFreshBank then
          local bankCrafts = math.floor(bankCount / required)
          if bankLimit == nil or bankCrafts < bankLimit then bankLimit = bankCrafts end
        end
        if summary.altsAllowed then
          local altCrafts = math.floor(altCount / required)
          if altsLimit == nil or altCrafts < altsLimit then altsLimit = altCrafts end
          local combinedCrafts = math.floor(combinedCount / required)
          if combinedLimit == nil or combinedCrafts < combinedLimit then
            combinedLimit = combinedCrafts
          end
        end

        if summary.purchaseAllowed and need > 0 then
          local price, source = Skilly.Cost.PriceFor(reagent, summary.marketAllowed)
          price = tonumber(price)
          local grade = gradeForPrice(source)
          local canBuy = price and price > 0 and hasReliablePrice(source)
              and (grade ~= "market" or summary.marketAllowed)
          if canBuy then
            buyGrades[#buyGrades + 1] = grade
            buyReagents[#buyReagents + 1] = {
              required = required,
              owned = selfCount + bankCount + altCount + combinedCount,
              price = price,
            }
          else
            buyBlocked = true
          end
        end
      end
    end
  end

  summary.self = selfLimit or 0
  summary.bank = bankLimit or 0
  summary.alts = altsLimit or 0
  summary.combined = combinedLimit or 0

  -- SB-98: one shared wallet across all missing reagent lines. A blocked
  -- (unpriced/invalid/unpurchasable) missing reagent forbids claiming a
  -- verified purchase-complete craft.
  local purchaseCrafts = 0
  local hasPurchase = false
  if summary.purchaseAllowed and summary.money then
    if #buyReagents > 0 or buyBlocked then hasPurchase = true end
    if #buyReagents > 0 and not buyBlocked then
      purchaseCrafts = maxAffordableCrafts(buyReagents, summary.money)
    end
  end
  summary.ah = purchaseCrafts
  summary.moneyBounded = summary.money ~= nil and hasPurchase

  local parts = { tostring(summary.self) .. " self" }
  if hasFreshBank then parts[#parts + 1] = tostring(summary.bank) .. " bank" end
  if summary.hasCombined then
    parts[#parts + 1] = tostring(summary.combined) .. " external (combined)"
  elseif summary.altsAllowed then
    parts[#parts + 1] = tostring(summary.alts) .. " alts"
  end
  if hasPurchase then
    local partial = summary.unknown > 0 or buyBlocked
    local suffix = partial and " (money-bounded, partial)" or " (money-bounded)"
    parts[#parts + 1] = tostring(summary.ah) .. " "
        .. purchaseSourceLabel(buyGrades) .. suffix
  end
  summary.text = table.concat(parts, ", ")
  return summary
end

-- SB-88: only a reliable missing-unit price enters the literal out-of-pocket
-- total. The 1-copper fallback stays visible as an estimate.
function Skilly.Cost.Recipe(recipe, allowMarket)
  local result = {
    total = 0, fullCost = 0, estimatedCost = 0, estimated = 0, detail = {},
  }
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

      local price, source = Skilly.Cost.PriceFor(reagent, allowMarket)
      price = tonumber(price) or 1
      if price < 0 then price = 0 end
      local reliable = hasReliablePrice(source)

      local subtotal = need * price
      if reliable then
        result.total = result.total + subtotal
        result.fullCost = result.fullCost + required * price
      elseif need > 0 then
        result.estimatedCost = result.estimatedCost + subtotal
        result.estimated = result.estimated + 1
      end
      result.detail[#result.detail + 1] = {
        name = reagent.name,
        key = Internal.ReagentKey(reagent),
        required = required,
        owned = owned,
        need = need,
        price = price,
        subtotal = subtotal,
        source = source,
        hasPrice = reliable,
        estimated = need > 0 and not reliable or false,
      }
    end
  end

  return result
end

-- SB-12: how many complete crafts the player can do with materials already
-- available (real stock plus as-if entries). Output quantity is not applied.
function Skilly.Cost.Craftable(recipe)
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
function Skilly.Cost.Missing(recipe, allowMarket)
  local rows, unknown, worst = analyzeReagents(recipe, allowMarket)
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
function Skilly.Cost.Obtainable(recipe, allowMarket)
  local rows, unknown, worst = analyzeReagents(recipe, allowMarket)
  if type(recipe) == "table" then
    recipe.sourceGrade = worst
    if unknown then recipe.unknownReagent = true end
  end
  if unknown or #rows == 0 then return false end

  local assume = Skilly.Cost.AssumePurchasable()
  if allowMarket == nil then allowMarket = true end
  for _, row in ipairs(rows) do
    if row.need > 0 and (not assume or not row.hasPrice) then
      return false
    end
    if row.need > 0 and not allowMarket and row.grade == "market" then
      return false
    end
  end
  return true
end
