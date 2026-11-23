--[[---------------------------------------------------------------------------------
  Skilly - by faslkjd56
  WoW Forever 1.60.1 craft advisor
  Bank.lua - read-only per-character bank reagent cache
------------------------------------------------------------------------------------]]

Skilly = Skilly or {}
Skilly.Internal = Skilly.Internal or {}
local Internal = Skilly.Internal

Skilly.Bank = Skilly.Bank or {}
local Bank = Skilly.Bank

local SCHEMA = 1
local MAX_KEYS = 1000
local MAX_AGE = 24 * 60 * 60
local BANK_BAGS = { -1, 5, 6, 7, 8, 9, 10, 11 }

local function safeCall(fn, ...)
  if type(fn) ~= "function" then return false end
  return pcall(fn, ...)
end

local function safeNumber(fn, ...)
  local ok, value = safeCall(fn, ...)
  if not ok then return nil, false end
  return tonumber(value), true
end

local function positiveInt(value)
  local n = tonumber(value)
  if not n or n <= 0 or n ~= math.floor(n) then return nil end
  return math.floor(n)
end

local function charDB()
  if type(SkillyCharDB) ~= "table" then return nil end
  return SkillyCharDB
end

local function bankFrameOpen()
  local frame = _G.BankFrame
  if not frame then return false end
  local ok, visible = safeCall(frame.IsVisible, frame)
  return ok and visible == true
end

local function normalizeCache(cache)
  if type(cache) ~= "table" then return nil end
  if cache.schema ~= SCHEMA then return nil end
  local capturedAt = tonumber(cache.capturedAt)
  if not capturedAt or capturedAt <= 0 then return nil end
  if type(cache.counts) ~= "table" then return nil end

  local counts = {}
  local n = 0
  for key, value in pairs(cache.counts) do
    if type(key) == "string" and string.match(key, "^item:%d+$") then
      local count = positiveInt(value)
      if count then
        counts[key] = count
        n = n + 1
        if n >= MAX_KEYS then break end
      end
    end
  end

  return {
    schema = SCHEMA,
    counts = counts,
    capturedAt = math.floor(capturedAt),
  }
end

local function ensureCache()
  local db = charDB()
  if not db then return nil end
  local normalized = normalizeCache(db.bankCache)
  if normalized then
    db.bankCache = normalized
    return normalized
  end
  -- Malformed/old schema/wrong-type data is no data; do not fabricate zero stock.
  if db.bankCache ~= nil then db.bankCache = nil end
  return nil
end

function Bank.Info()
  local cache = ensureCache()
  if not cache then
    return { fresh = false, capturedAt = nil, age = nil, keys = 0 }
  end
  local now = tonumber(type(_G.time) == "function" and _G.time() or nil)
  local age = nil
  if now and now >= cache.capturedAt then age = math.floor(now - cache.capturedAt) end
  local keys = 0
  for _ in pairs(cache.counts) do keys = keys + 1 end
  local includeBank = type(SkillyDB) == "table" and SkillyDB.includeBank == true
  local fresh = includeBank and type(age) == "number" and age >= 0 and age <= MAX_AGE
  return {
    fresh = fresh,
    capturedAt = cache.capturedAt,
    age = age,
    keys = keys,
    includeBank = includeBank,
  }
end

function Bank.IsFresh()
  local info = Bank.Info()
  return type(info) == "table" and info.fresh == true
end

function Bank.Count(key)
  if type(key) ~= "string" or key == "" then return nil end
  local info = Bank.Info()
  if not info.fresh then return nil end
  local cache = ensureCache()
  if not cache then return nil end
  local count = cache.counts[key]
  count = positiveInt(count)
  if not count then return nil end
  return count
end

function Bank.Clear()
  local db = charDB()
  if not db then return false end
  db.bankCache = nil
  if type(Skilly.ResetSourceCache) == "function" then
    pcall(Skilly.ResetSourceCache)
  end
  return true
end

local function captureCounts()
  local counts = {}
  local keyCount = 0

  for _, bag in ipairs(BANK_BAGS) do
    local slots, slotsOk = safeNumber(_G.GetContainerNumSlots, bag)
    if not slotsOk then
      return nil, "container slots unreadable"
    end
    slots = positiveInt(slots) or 0
    for slot = 1, slots do
      local okSlot = pcall(function()
        local itemID = Internal.CallNumber(_G.GetContainerItemID, bag, slot)
        if not itemID or itemID <= 0 or itemID ~= math.floor(itemID) then return end
        itemID = math.floor(itemID)

        local info = Internal.SafeResults("GetContainerItemInfo", bag, slot)
        local stack = info and positiveInt(info[2]) or nil
        if not stack then return end

        local key = "item:" .. itemID
        if counts[key] == nil and keyCount >= MAX_KEYS then return end
        if counts[key] == nil then keyCount = keyCount + 1 end
        counts[key] = (counts[key] or 0) + stack
      end)
      if not okSlot then
        -- A failed/throwing container API skips that slot only.
      end
    end
  end

  return counts, nil
end

function Bank.Capture(reason)
  local db = charDB()
  if not db then return false, "character database unavailable" end
  if not bankFrameOpen() then return false, "bank closed" end

  local counts, err = captureCounts()
  if type(counts) ~= "table" then
    return false, err or "capture failed"
  end

  local now = tonumber(type(_G.time) == "function" and _G.time() or nil)
  now = positiveInt(now)
  if not now then
    return false, "time unavailable"
  end

  db.bankCache = {
    schema = SCHEMA,
    counts = counts,
    capturedAt = now,
  }

  if type(Skilly.ResetSourceCache) == "function" then
    pcall(Skilly.ResetSourceCache)
  end
  return true, reason or "captured"
end
