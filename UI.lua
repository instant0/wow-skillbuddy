--[[---------------------------------------------------------------------------------
  Skilly - by faslkjd56
  WoW Forever 1.60.1 craft advisor
------------------------------------------------------------------------------------]]

Skilly = Skilly or {}
Skilly.UI = Skilly.UI or {}

-- Every widget call goes through this checked pcall helper. A missing widget or
-- template degrades quietly; it never breaks a chat command.
local function callMethod(object, method, ...)
  if not object then return false end
  local okFn, fn = pcall(function() return object[method] end)
  if not okFn or type(fn) ~= "function" then return false end
  return pcall(fn, object, ...)
end

local function hasMethod(object, method)
  if not object then return false end
  local okFn, fn = pcall(function() return object[method] end)
  return okFn and type(fn) == "function"
end

local function createFrame(kind, name, parent, template)
  if type(_G.CreateFrame) ~= "function" then return nil end
  local ok, frame
  if template then
    ok, frame = pcall(_G.CreateFrame, kind, name, parent, template)
  else
    ok, frame = pcall(_G.CreateFrame, kind, name, parent)
  end
  if ok and frame then return frame end
  return nil
end

local function createFontString(parent, name, font)
  local okFn, factory = pcall(function() return parent.CreateFontString end)
  if not okFn or type(factory) ~= "function" then return nil end
  local ok, text = pcall(factory, parent, name, "OVERLAY", font or "GameFontNormal")
  if ok then return text end
  return nil
end

local function runRecommend()
  if type(Skilly.InitDB) == "function" then pcall(Skilly.InitDB) end
  local recommend = Skilly.Recommend
  if type(recommend) == "function" then
    local ok, err = pcall(recommend, nil, { explicit = true })
    if not ok and type(Skilly.Print) == "function" then
      pcall(Skilly.Print, "Recommendation failed: " .. tostring(err))
    end
    return
  end
  if type(Skilly.Print) == "function" then
    pcall(Skilly.Print, "Recommendation unavailable: missing Skilly.Recommend.")
  end
end

-- SB-19: hidden binding target; OnClick uses the same recommendation path as /skilly next.
local bindingButton = createFrame("Button", "SkillyBindingButton", _G.UIParent)
if bindingButton then
  callMethod(bindingButton, "Hide")
  callMethod(bindingButton, "SetScript", "OnClick", runRecommend)
end

local function chatRecommendationsEnabled()
  if type(Skilly.FeatureEnabled) ~= "function" then return true end
  local ok, value = pcall(Skilly.FeatureEnabled, "showChatRecommendations", true)
  if ok and type(value) == "boolean" then return value end
  return true
end

local function highlightRecommendedEnabled()
  if type(Skilly.FeatureEnabled) ~= "function" then return false end
  local ok, value = pcall(Skilly.FeatureEnabled, "highlightRecommendedRecipe", false)
  return ok and value == true
end

local function safeRecipeID(entry)
  if type(entry) ~= "table" then return nil end
  local r = type(entry.recipe) == "table" and entry.recipe or entry
  local id = tonumber(r.spellID or r.recipeID or r.id)
  if not id or id <= 0 or id ~= math.floor(id) then return nil end
  return math.floor(id)
end

local lastRecommendationSignature = nil
local lastHighlightSignature = nil
local lastHighlightRecipeID = nil

local function recommendationSignature(entries, fullEntries, mode)
  if type(entries) ~= "table" or type(entries[1]) ~= "table" then return nil end
  local function entryKey(entry)
    if type(entry) ~= "table" then return "nil" end
    local r = type(entry.recipe) == "table" and entry.recipe or {}
    local id = r.spellID or r.id or r.key or r.name or "?"
    local p = tonumber(entry.p) or 0
    local c = tonumber(entry.craftable) or 0
    local s = tonumber(entry.score) or 0
    local pp = math.floor((tonumber(entry.potentialPoints) or 0) * 1000 + 0.5)
    return table.concat({ tostring(id), string.format("%.4f", p), tostring(c), string.format("%.4f", s), tostring(pp) }, ":")
  end
  local parts = { tostring(mode or ""), entryKey(entries[1]), entryKey(type(fullEntries) == "table" and fullEntries[1] or nil) }
  local limit = math.min(#entries, 3)
  for i = 2, limit do parts[#parts + 1] = entryKey(entries[i]) end
  return table.concat(parts, "|")
end

-- SB-90: one grouping rule for chat and the result window. Rank order is kept
-- inside each group because entries arrive already sorted.
local RESULT_GROUP_TITLES = {
  now = "Make now (materials on hand)",
  buy = "Buy from AH / missing materials",
  other = "Other recommendations",
}

local function resultGroup(entry)
  if type(entry) ~= "table" then return "other" end
  local craftable = tonumber(entry.craftable) or 0
  if craftable > 0 then return "now" end
  local missing = type(entry.missing) == "table" and entry.missing or nil
  if missing and #missing > 0 then return "buy" end
  return "other"
end

Skilly.UI.GroupFor = resultGroup
Skilly.UI.GroupTitles = RESULT_GROUP_TITLES

local function printGroupedChatEntries(entries, maxLines)
  local lastGroup = nil
  local shown = 0
  for i = 1, math.min(#entries, maxLines) do
    local entry = entries[i]
    local group = resultGroup(entry)
    if group ~= lastGroup then
      Skilly.Print(RESULT_GROUP_TITLES[group] or RESULT_GROUP_TITLES.other)
      lastGroup = group
    end
    local ok, line = pcall(Skilly.Rank.Describe, entry)
    if ok and type(line) == "string" and line ~= "" then
      Skilly.Print(i .. ") " .. line)
      shown = shown + 1
    end
  end
  return shown
end

local maybeHighlightRecommended



-- SB-18/SB-54/SB-71/SB-72: chat is authoritative/fallback; a result window (SB-17) is optional.
-- Automatic calls suppress unchanged recommendations; explicit commands always print.
function Skilly.UI.PrintResults(entries, fullEntries, opts)
  if type(entries) ~= "table" or type(entries[1]) ~= "table" then
    Skilly.Print("No recipes qualify in this mode.")
    return
  end
  if type(Skilly.Rank) ~= "table" or type(Skilly.Rank.Describe) ~= "function" then
    Skilly.Print("Recommendation unavailable: missing Skilly.Rank.Describe")
    return
  end

  local explicit = type(opts) == "table" and opts.explicit == true
  local mode = type(opts) == "table" and opts.mode or nil
  local sig = recommendationSignature(entries, fullEntries, mode)
  if not explicit and sig and sig == lastRecommendationSignature then
    local shown = false
    if type(Skilly.UI.ShowResults) == "function" then
      local okShow, result = pcall(Skilly.UI.ShowResults, entries)
      shown = okShow and result == true
    end
    if shown then return end
  end

  local showWindow = type(Skilly.UI.ShowResults) == "function"
  local windowShown = false
  if showWindow then
    local okShow, shown = pcall(Skilly.UI.ShowResults, entries)
    windowShown = okShow and shown == true
  end
  pcall(maybeHighlightRecommended, entries)
  local chatEnabled = chatRecommendationsEnabled()
  -- SB-103: suppress chat only for implicit triggers. Explicit /skilly, next,
  -- best, and cheap always print chat regardless of the setting or window state.
  if not explicit and not chatEnabled and windowShown then
    lastRecommendationSignature = sig
    return
  end

  lastRecommendationSignature = sig

  local top = entries[1]
  local resultCount = 5
  if type(SkillyDB) == "table" then resultCount = tonumber(SkillyDB.resultCount) or 5 end
  local maxLines = math.floor(resultCount)
  if maxLines < 1 then maxLines = 1 elseif maxLines > 10 then maxLines = 10 end

  Skilly.Print("Skilly recommendations:")
  printGroupedChatEntries(entries, maxLines)

  local fullTop = type(fullEntries) == "table" and fullEntries[1] or nil
  if type(fullTop) == "table" then
    if fullTop.recipe == top.recipe then
      Skilly.Print("Best craft: also best at full material cost.")
    else
      local okFull, fullLine = pcall(Skilly.Rank.Describe, fullTop)
      if okFull and type(fullLine) == "string" and fullLine ~= "" then
        Skilly.Print("Best craft: at full material cost - " .. fullLine)
      end
    end
  end

  if type(Skilly.Rank.DescribeHints) == "function" then
    local okHints, hints = pcall(Skilly.Rank.DescribeHints, top)
    if okHints and type(hints) == "table" then
      for _, hint in ipairs(hints) do
        if type(hint) == "string" and hint ~= "" then Skilly.Print(hint) end
      end
    end
  end
end

-- SB-17: session-only result window. Built from stock Blizzard frames, fonts,
-- and textures. Chat is authoritative; this is a display surface only. SB-58
-- owns future skinning, so keep every visual constant here rather than copying
-- a palette into this file.
local RESULTS_MAX_ROWS = 10
local resultsFrame = nil
local resultsBuildFailed = false
local resultsRows = {}
local lastEntries = nil
local inSpecialFrames = false
local resultsDefaultPoint = { point = "CENTER", rel = "UIParent", relPoint = "CENTER", x = 0, y = 0 }
local resultsAnchored = false
local resultsAnchorEnabledAtShow = false
local professionsHooked = false
local autoAdviceOpen = false
local autoAdviceSignature = nil
local autoAdviceAt = 0
local minimapButton = nil
local minimapBuildFailed = false

local function tradeSkillLinkedOrGuild()
  if type(Skilly.Scan) == "table" and type(Skilly.Scan.UnsupportedView) == "function" then
    local ok, unsupported = pcall(Skilly.Scan.UnsupportedView)
    if ok then return unsupported == true end
  end
  return false
end

maybeHighlightRecommended = function(entries)
  if not highlightRecommendedEnabled() then return end
  if not autoAdviceOpen then return end
  if tradeSkillLinkedOrGuild() then return end
  if type(entries) ~= "table" or type(entries[1]) ~= "table" then return end
  local top = entries[1]
  local recipeID = safeRecipeID(top)
  if not recipeID then return end
  local sig = recommendationSignature(entries, nil, nil)
  if sig and sig == lastHighlightSignature and recipeID == lastHighlightRecipeID then return end

  local api = _G.C_TradeSkillUI
  if type(api) ~= "table" then return end
  local openRecipe = api.OpenRecipe
  if type(openRecipe) ~= "function" then return end
  local ok = pcall(openRecipe, recipeID)
  if ok then
    lastHighlightSignature = sig
    lastHighlightRecipeID = recipeID
  end
end
local RESULTS_FRAME_WIDTH = 420
local RESULTS_ANCHOR_GAP = 8

local function autoAdviceEnabled()
  if type(Skilly.FeatureEnabled) ~= "function" then return false end
  local ok, value = pcall(Skilly.FeatureEnabled, "useAutoAdviceOnOpen", false)
  return ok and value == true
end

local function nowSeconds()
  if type(_G.GetTime) == "function" then
    local ok, t = pcall(_G.GetTime)
    if ok and type(t) == "number" then return t end
  end
  if type(_G.time) == "function" then
    local ok, t = pcall(_G.time)
    if ok and type(t) == "number" then return t end
  end
  return 0
end



local function snapshotSignature(snapshot)
  if type(snapshot) ~= "table" then return nil end
  local profession = type(snapshot.profession) == "string" and snapshot.profession or ""
  local skill = tonumber(snapshot.skill) or 0
  local maxSkill = tonumber(snapshot.maxSkill) or 0
  local count = type(snapshot.recipes) == "table" and #snapshot.recipes or 0
  local sourceCounter = tonumber(snapshot.sourceCounter) or 0
  return table.concat({ profession, skill, maxSkill, count, sourceCounter }, ":")
end

local function autoAdviceSignatureForSnapshot(snapshot)
  if type(snapshot) ~= "table" then return nil end
  local profession = type(snapshot.profession) == "string" and snapshot.profession or ""
  local skill = tonumber(snapshot.skill) or 0
  local maxSkill = tonumber(snapshot.maxSkill) or 0
  local count = type(snapshot.recipes) == "table" and #snapshot.recipes or 0
  -- sourceCounter excluded: benign refreshes can bump it and cause spam.
  return table.concat({ profession, skill, maxSkill, count }, ":")
end

local function applyAutoAdvice(snapshot)
  if not autoAdviceEnabled() then return end
  if not autoAdviceOpen then return end
  if tradeSkillLinkedOrGuild() then return end
  if type(snapshot) ~= "table" or type(snapshot.profession) ~= "string"
      or snapshot.profession == "" then return end

  local sig = autoAdviceSignatureForSnapshot(snapshot)
  if not sig or sig == autoAdviceSignature then return end

  autoAdviceSignature = sig
  autoAdviceAt = nowSeconds()
  if type(Skilly.Recommend) == "function" then
    pcall(Skilly.Recommend)
  end
end

local function maybeAutoAdvice(event)
  if not autoAdviceEnabled() or not autoAdviceOpen or tradeSkillLinkedOrGuild() then return end

  local scan = Skilly.Scan
  if type(scan) ~= "table" or type(scan.Current) ~= "function" then return end
  local ok, snapshot = pcall(scan.Current)
  if not ok or type(snapshot) ~= "table" then return end
  applyAutoAdvice(snapshot)
end

-- SB-87: if the profession window was already open before addon load, the show
-- event is already gone. Scan once on login and reuse the same signature gate.
function Skilly.UI.CheckProfessionAtLogin()
  if not autoAdviceEnabled() then return end
  if tradeSkillLinkedOrGuild() then return end

  local scan = Skilly.Scan
  if type(scan) ~= "table" or type(scan.Current) ~= "function" then return end
  local ok, snapshot = pcall(scan.Current)
  if not ok or type(snapshot) ~= "table" then return end
  if type(snapshot.profession) ~= "string" or snapshot.profession == "" then return end

  autoAdviceOpen = true
  applyAutoAdvice(snapshot)
end

local function companionAnchorEnabled()
  if type(Skilly.FeatureEnabled) ~= "function" then return false end
  local ok, value = pcall(Skilly.FeatureEnabled, "useCompanionAnchor", false)
  return ok and value == true
end

local function professionsFrameVisible()
  local frame = _G.ProfessionsFrame
  if not frame then return nil end
  local ok, shown = pcall(function() return frame:IsShown() end)
  if ok and shown == true then return frame end
  return nil
end

local function safeFrameWidth(frame)
  if not frame then return nil end
  local ok, w = pcall(function() return frame:GetWidth() end)
  if ok and type(w) == "number" and w > 0 then return w end
  return nil
end

local function anchorTargetForProfessionsFrame(prof)
  if not prof then return nil, nil end
  local sidebar = _G.ProfessionsFrameTabSideBar
  if sidebar then
    local okShown, shown = pcall(function() return sidebar:IsShown() end)
    if okShown and shown == true then
      local w = safeFrameWidth(sidebar)
      if w then return sidebar, w + RESULTS_ANCHOR_GAP end
    end
  end
  local w = safeFrameWidth(prof)
  return prof, (w or 700) + RESULTS_ANCHOR_GAP
end

local function applyResultsLayout()
  if not resultsFrame then return end
  local enabled = companionAnchorEnabled()
  local prof = enabled and professionsFrameVisible() or nil
  local anchorTarget, offsetX = anchorTargetForProfessionsFrame(prof)
  local anchored = prof ~= nil

  pcall(function() resultsFrame:SetWidth(RESULTS_FRAME_WIDTH) end)
  pcall(function()
    resultsFrame:ClearAllPoints()
    if anchored and anchorTarget then
      resultsFrame:SetPoint("TOPLEFT", anchorTarget, "TOPLEFT", offsetX, 0)
    else
      local rel = _G[resultsDefaultPoint.rel] or _G.UIParent
      resultsFrame:SetPoint(resultsDefaultPoint.point, rel, resultsDefaultPoint.relPoint, resultsDefaultPoint.x, resultsDefaultPoint.y)
    end
  end)
  resultsAnchored = anchored

  local contentWidth = RESULTS_FRAME_WIDTH - 32
  for _, row in ipairs(resultsRows) do
    if row then
      for _, fs in ipairs({ row.name, row.detail }) do
        if fs then
          pcall(function() fs:SetWidth(contentWidth) end)
          if hasMethod(fs, "SetWordWrap") then pcall(function() fs:SetWordWrap(true) end) end
          if hasMethod(fs, "SetNonSpaceWrap") then pcall(function() fs:SetNonSpaceWrap(true) end) end
        end
      end
    end
  end
end

local function restoreResultsDefaultPoint()
  if not resultsFrame then return end
  pcall(function()
    resultsFrame:ClearAllPoints()
    local rel = _G[resultsDefaultPoint.rel] or _G.UIParent
    resultsFrame:SetPoint(resultsDefaultPoint.point, rel, resultsDefaultPoint.relPoint, resultsDefaultPoint.x, resultsDefaultPoint.y)
  end)
  resultsAnchored = false
end

function Skilly.UI.UpdateCompanionAnchor()
  if not resultsFrame then return false end
  local enabled = companionAnchorEnabled()
  local prof = enabled and professionsFrameVisible() or nil
  if enabled and prof then
    applyResultsLayout()
    return true
  end
  if resultsAnchored then restoreResultsDefaultPoint() end
  return false
end

function Skilly.UI.TryHookProfessionsFrame()
  if professionsHooked then return true end
  local frame = _G.ProfessionsFrame
  if not frame then return false end
  local okHook, hook = pcall(function() return frame.HookScript end)
  if not okHook or type(hook) ~= "function" then return false end
  local ok1 = pcall(hook, frame, "OnShow", function()
    pcall(Skilly.UI.UpdateCompanionAnchor)
  end)
  local ok2 = pcall(hook, frame, "OnHide", function()
    pcall(Skilly.UI.UpdateCompanionAnchor)
  end)
  professionsHooked = ok1 or ok2
  return professionsHooked
end

function Skilly.UI.OnProfessionsWindowEvent(event)
  pcall(Skilly.UI.TryHookProfessionsFrame)

  if event == "TRADE_SKILL_SHOW" then
    autoAdviceOpen = true
    autoAdviceSignature = nil
    autoAdviceAt = 0
    pcall(Skilly.UI.UpdateCompanionAnchor)
    pcall(Skilly.UI.TryAddSidebarTab)
    pcall(maybeAutoAdvice, event)
    return
  end

  if event == "TRADE_SKILL_CLOSE" then
    autoAdviceOpen = false
    autoAdviceSignature = nil
    autoAdviceAt = 0
    lastHighlightSignature = nil
    lastHighlightRecipeID = nil
    if resultsFrame then
      local okShown, shown = pcall(function() return resultsFrame:IsShown() end)
      local shouldHide = okShown and shown and (resultsAnchored or (companionAnchorEnabled() and resultsAnchorEnabledAtShow))
      if shouldHide then
        pcall(function() resultsFrame:Hide() end)
      end
    end
    if resultsAnchored then restoreResultsDefaultPoint() end
    return
  end

  if event == "TRADE_SKILL_LIST_UPDATE" or event == "SKILL_LINES_CHANGED" then
    pcall(Skilly.UI.UpdateCompanionAnchor)
    pcall(maybeAutoAdvice, event)
    return
  end

  pcall(Skilly.UI.UpdateCompanionAnchor)
end

-- Colour comes from the client when it provides one; never invent a palette.
local function clientDifficultyColor(recipe)
  if type(recipe) ~= "table" then return nil end
  local raw = recipe.difficulty or recipe.skillType
  if type(raw) ~= "string" then return nil end
  local fn = _G.GetTradeSkillDifficultyColor
  if type(fn) ~= "function" then return nil end
  local ok, r, g, b = pcall(fn, raw)
  if not ok then return nil end
  if type(r) ~= "number" or type(g) ~= "number" or type(b) ~= "number" then
    return nil
  end
  return r, g, b
end

-- SB-108: one visual style resolution. Stock WoW by default; a self-contained
-- dark ElvUI-like palette when ElvUI is detected and the toggle is on. Never
-- reads ElvUI SavedVariables or calls its APIs.
local function useElvUISkinEnabled()
  if type(Skilly.FeatureEnabled) ~= "function" then return true end
  local ok, value = pcall(Skilly.FeatureEnabled, "useElvUISkin", true)
  return ok and value == true
end

local function elvUIPresent()
  local addon = _G.C_AddOns
  if type(addon) ~= "table" or type(addon.IsAddOnLoaded) ~= "function" then return false end
  local ok, loaded = pcall(addon.IsAddOnLoaded, "ElvUI")
  return ok and loaded == true
end

function Skilly.UI.Style()
  if useElvUISkinEnabled() and elvUIPresent() then
    return {
      name = "elvui",
      headerColor = { 0.35, 0.85, 0.4, 1 },
      backdropColor = { 0.06, 0.06, 0.07, 0.96 },
      borderColor = { 0.25, 0.25, 0.28, 1 },
    }
  end
  return {
    name = "stock",
    headerColor = { 1, 0.82, 0, 1 },
    backdropColor = nil,
    borderColor = nil,
  }
end

-- SB-108: guarded, opt-in sidebar tab. Appends a Skilly tab to the shared
-- Professions sidebar when present; never reparents Blizzard tabs or assumes an
-- index. Falls back to the floating companion anchor otherwise.
local function sidebarTabEnabled()
  if type(Skilly.FeatureEnabled) ~= "function" then return false end
  local ok, value = pcall(Skilly.FeatureEnabled, "useSidebarTab", false)
  return ok and value == true
end

local sidebarTab = nil
local sidebarTabTried = false

function Skilly.UI.TryAddSidebarTab()
  if sidebarTabTried then return sidebarTab end
  sidebarTabTried = true
  if not sidebarTabEnabled() then return nil end

  local sidebar = _G.ProfessionsFrameTabSideBar
  if type(sidebar) ~= "table" then return nil end
  if type(sidebar.Tabs) ~= "table" then return nil end

  local tab = createFrame("Button", "SkillySidebarTab", sidebar, "QuestLogTabButtonTemplate")
  if not tab then
    tab = createFrame("Button", "SkillySidebarTab", sidebar, "UIPanelButtonTemplate")
  end
  if not tab then return nil end

  callMethod(tab, "SetText", "Skilly")
  callMethod(tab, "SetScript", "OnClick", function()
    if type(Skilly.UI.ToggleResults) == "function" then
      pcall(Skilly.UI.ToggleResults)
    end
  end)
  local okInsert = pcall(table.insert, sidebar.Tabs, tab)
  if not okInsert then
    callMethod(tab, "Hide")
    return nil
  end
  callMethod(tab, "Show")
  sidebarTab = tab
  return tab
end

local function buildResultsFrame()
  local frame = createFrame("Frame", "SkillyResultsFrame", _G.UIParent,
      "BasicFrameTemplate")
  local plain = not frame
  if plain then
    frame = createFrame("Frame", "SkillyResultsFrame", _G.UIParent)
  end
  if not frame then return nil end

  callMethod(frame, "SetFrameStrata", "DIALOG")
  callMethod(frame, "SetToplevel", true)
  callMethod(frame, "SetMovable", true)
  callMethod(frame, "EnableMouse", true)
  callMethod(frame, "RegisterForDrag", "LeftButton")
  callMethod(frame, "SetWidth", RESULTS_FRAME_WIDTH)
  callMethod(frame, "SetHeight", 180)
  callMethod(frame, "SetPoint", "CENTER", 0, 0)
  if plain then
    callMethod(frame, "SetBackdrop", {
      bgFile = "Interface/Tooltips/UI-Tooltip-Background",
      edgeFile = "Interface/Tooltips/UI-Tooltip-Border",
      tile = true,
      tileSize = 16,
      edgeSize = 16,
      insets = { left = 4, right = 4, top = 4, bottom = 4 },
    })
  end

  local style = Skilly.UI.Style()
  if style.backdropColor then
    callMethod(frame, "SetBackdropColor", style.backdropColor[1],
        style.backdropColor[2], style.backdropColor[3], style.backdropColor[4])
  end
  if style.borderColor then
    callMethod(frame, "SetBackdropBorderColor", style.borderColor[1],
        style.borderColor[2], style.borderColor[3], style.borderColor[4])
  end

  callMethod(frame, "SetScript", "OnDragStart", function()
    if resultsAnchored then return end
    callMethod(frame, "StartMoving")
  end)
  callMethod(frame, "SetScript", "OnDragStop", function()
    callMethod(frame, "StopMovingOrSizing")
  end)
  callMethod(frame, "SetScript", "OnShow", function()
    resultsAnchorEnabledAtShow = companionAnchorEnabled()
    pcall(applyResultsLayout)
  end)

  local title = createFontString(frame, "SkillyResultsTitle", "GameFontNormalLarge")
  callMethod(title, "SetPoint", "TOPLEFT", 14, -10)
  callMethod(title, "SetText", "Skilly - next craft")

  local hint = createFontString(frame, "SkillyResultsHint", "GameFontNormalSmall")
  callMethod(hint, "SetPoint", "TOPLEFT", 14, -30)
  callMethod(hint, "SetText", "Esc to close. Drag to move.")

  local close = createFrame("Button", "SkillyResultsClose", frame,
      "UIPanelCloseButton")
  if not close then
    close = createFrame("Button", "SkillyResultsClose", frame)
    if close then callMethod(close, "SetText", "x") end
  end
  if close then
    callMethod(close, "SetWidth", 24)
    callMethod(close, "SetHeight", 24)
    callMethod(close, "SetPoint", "TOPRIGHT", -4, -4)
    callMethod(close, "SetScript", "OnClick", function()
      callMethod(frame, "Hide")
    end)
  end

  local contentWidth = RESULTS_FRAME_WIDTH - 32
  for i = 1, RESULTS_MAX_ROWS do
    local header = createFontString(frame, "SkillyResultHeader" .. i,
        "GameFontNormal")
    local name = createFontString(frame, "SkillyResultName" .. i,
        "GameFontNormal")
    local detail = createFontString(frame, "SkillyResultDetail" .. i,
        "GameFontNormalSmall")
    if header then
      callMethod(header, "SetWidth", contentWidth)
      callMethod(header, "SetJustifyH", "LEFT")
      callMethod(header, "SetTextColor", style.headerColor[1],
          style.headerColor[2], style.headerColor[3], style.headerColor[4])
    end
    if name then
      callMethod(name, "SetWidth", contentWidth)
      callMethod(name, "SetJustifyH", "LEFT")
      if hasMethod(name, "SetWordWrap") then callMethod(name, "SetWordWrap", true) end
      if hasMethod(name, "SetNonSpaceWrap") then callMethod(name, "SetNonSpaceWrap", true) end
    end
    if detail then
      callMethod(detail, "SetWidth", contentWidth)
      callMethod(detail, "SetJustifyH", "LEFT")
      if hasMethod(detail, "SetWordWrap") then callMethod(detail, "SetWordWrap", true) end
      if hasMethod(detail, "SetNonSpaceWrap") then callMethod(detail, "SetNonSpaceWrap", true) end
    end
    resultsRows[i] = { header = header, name = name, detail = detail }
    callMethod(header, "Hide")
    callMethod(name, "Hide")
    callMethod(detail, "Hide")
  end

  -- UISpecialFrames is the stock Escape-to-close mechanism for windows.
  if type(_G.UISpecialFrames) == "table" and not inSpecialFrames then
    local okInsert = pcall(table.insert, _G.UISpecialFrames, "SkillyResultsFrame")
    if okInsert then inSpecialFrames = true end
  end

  callMethod(frame, "Hide")
  resultsFrame = frame
  return frame
end

local function fontStringHeight(fs, fallback)
  if not fs then return fallback end
  local ok, h = pcall(function() return fs:GetStringHeight() end)
  if ok and type(h) == "number" and h > 0 then return h end
  return fallback
end

local function placeRow(row, y, headerText, name, detail, recipe)
  if not row or not row.name or not row.detail then return y end
  if row.header then
    if type(headerText) == "string" and headerText ~= "" then
      callMethod(row.header, "SetText", headerText)
      callMethod(row.header, "ClearAllPoints")
      callMethod(row.header, "SetPoint", "TOPLEFT", 14, -y)
      callMethod(row.header, "Show")
      y = y + fontStringHeight(row.header, 14) + 4
    else
      callMethod(row.header, "Hide")
    end
  end

  callMethod(row.name, "SetText", name)
  local r, g, b = clientDifficultyColor(recipe)
  if r and g and b then callMethod(row.name, "SetTextColor", r, g, b, 1) end
  callMethod(row.name, "ClearAllPoints")
  callMethod(row.name, "SetPoint", "TOPLEFT", 14, -y)
  callMethod(row.name, "Show")
  local nameH = fontStringHeight(row.name, 14)

  callMethod(row.detail, "SetText", detail)
  callMethod(row.detail, "ClearAllPoints")
  callMethod(row.detail, "SetPoint", "TOPLEFT", 14, -(y + nameH + 2))
  callMethod(row.detail, "Show")
  local detailH = fontStringHeight(row.detail, 12)

  return y + nameH + 2 + detailH + 8
end

function Skilly.UI.ShowResults(entries)
  if type(entries) ~= "table" or type(entries[1]) ~= "table" then return false end
  if not resultsFrame and not resultsBuildFailed then
    local okBuild, frame = pcall(buildResultsFrame)
    if not okBuild or not frame then
      resultsBuildFailed = true
      return false
    end
  end
  if not resultsFrame then return false end

  lastEntries = entries
  local count = math.min(#entries, RESULTS_MAX_ROWS)
  local y = 50
  local lastGroup = nil
  for i = 1, RESULTS_MAX_ROWS do
    local row = resultsRows[i]
    local entry = i <= count and entries[i] or nil
    if not entry then
      if row then
        if row.header then callMethod(row.header, "Hide") end
        callMethod(row.name, "Hide")
        callMethod(row.detail, "Hide")
      end
    else
      local group = resultGroup(entry)
      local headerText = nil
      if group ~= lastGroup then
        headerText = RESULT_GROUP_TITLES[group] or RESULT_GROUP_TITLES.other
        lastGroup = group
      end
      local recipe = type(entry.recipe) == "table" and entry.recipe or {}
      local name = type(recipe.name) == "string" and recipe.name
          or "Unknown recipe"
      local detail = ""
      if type(Skilly.Rank) == "table"
          and type(Skilly.Rank.Describe) == "function" then
        local ok, line = pcall(Skilly.Rank.Describe, entry)
        if ok and type(line) == "string" then
          detail = line
          local prefix = name .. ": "
          if string.sub(detail, 1, #prefix) == prefix then
            detail = string.sub(detail, #prefix + 1)
          end
        end
      end
      y = placeRow(row, y, headerText, i .. ". " .. name, detail, recipe)
    end
  end

  local okHeight = callMethod(resultsFrame, "SetHeight", math.max(120, y + 16))
  local okShow = callMethod(resultsFrame, "Show")
  resultsAnchorEnabledAtShow = companionAnchorEnabled()
  pcall(applyResultsLayout)

  -- SB-103: success is proven visibility, not a best-effort Show(). Missing
  -- methods, failed pcalls, or an unshown frame leave chat as the fallback.
  if not okHeight or not okShow then return false end
  local okShown, shown = pcall(function() return resultsFrame:IsShown() end)
  if not okShown or shown ~= true then return false end
  return true
end

function Skilly.UI.ToggleResults()
  if resultsFrame then
    local okShown, shown = pcall(function() return resultsFrame:IsShown() end)
    if okShown and shown then
      callMethod(resultsFrame, "Hide")
      return false
    end
  end
  if type(lastEntries) == "table" then
    return Skilly.UI.ShowResults(lastEntries)
  end
  return false
end

-- SB-15/SB-86: opt-in draggable launcher, no LibDBIcon. The saved DB value is
-- the exact SetPoint tuple; a drop is normalized only for parent scale.
local MINIMAP_DEFAULTS = {
  parentKey = "Minimap",
  point = "CENTER",
  relativePoint = "TOPRIGHT",
  x = -18,
  y = -18,
  visible = false,
}

local MINIMAP_POINTS = {
  TOPLEFT = true, TOP = true, TOPRIGHT = true,
  LEFT = true, CENTER = true, RIGHT = true,
  BOTTOMLEFT = true, BOTTOM = true, BOTTOMRIGHT = true,
}

local function finiteNumber(value, fallback)
  local n = tonumber(value)
  if n == nil or n ~= n or n == math.huge or n == -math.huge then return fallback end
  return n
end

local function minimapSettings()
  if type(Skilly.InitDB) == "function" then pcall(Skilly.InitDB) end
  if type(SkillyDB) ~= "table" then SkillyDB = {} end
  local m = SkillyDB.minimap
  if type(m) ~= "table" then
    m = {}
    SkillyDB.minimap = m
  end
  if m.parentKey ~= "Minimap" and m.parentKey ~= "UIParent" then
    m.parentKey = MINIMAP_DEFAULTS.parentKey
  end
  if type(m.point) ~= "string" or not MINIMAP_POINTS[m.point] then
    m.point = MINIMAP_DEFAULTS.point
  end
  if type(m.relativePoint) ~= "string" or not MINIMAP_POINTS[m.relativePoint] then
    m.relativePoint = MINIMAP_DEFAULTS.relativePoint
  end
  m.x = finiteNumber(m.x, MINIMAP_DEFAULTS.x)
  m.y = finiteNumber(m.y, MINIMAP_DEFAULTS.y)
  if type(m.visible) ~= "boolean" then m.visible = MINIMAP_DEFAULTS.visible end
  return m
end

local function minimapParent(m)
  if m and m.parentKey == "UIParent" then return _G.UIParent end
  return _G.Minimap or _G.UIParent
end

local function updateMinimapButtonPosition()
  if not minimapButton then return end
  local m = minimapSettings()
  local parent = minimapParent(m)
  if not parent then return end
  callMethod(minimapButton, "ClearAllPoints")
  callMethod(minimapButton, "SetPoint", m.point, parent, m.relativePoint, m.x, m.y)
end

local function saveMinimapDrop(self)
  local m = minimapSettings()
  local parent = minimapParent(m)
  if not parent then return false end

  local okSelf, sx, sy = pcall(function() return self:GetCenter() end)
  local okParent, px, py = pcall(function() return parent:GetCenter() end)
  sx = finiteNumber(sx, nil)
  sy = finiteNumber(sy, nil)
  px = finiteNumber(px, nil)
  py = finiteNumber(py, nil)
  if not okSelf or not okParent or sx == nil or sy == nil or px == nil or py == nil then
    return false
  end

  local okScale, scale = pcall(function() return parent:GetEffectiveScale() end)
  scale = finiteNumber(scale, 1)
  -- GetCenter() is in screen pixels; SetPoint offsets are in parent-local units.
  if not okScale or scale <= 0 then scale = 1 end

  m.parentKey = parent == _G.UIParent and "UIParent" or "Minimap"
  m.point = "CENTER"
  m.relativePoint = "CENTER"
  m.x = (sx - px) / scale
  m.y = (sy - py) / scale
  updateMinimapButtonPosition()
  return true
end

local function buildMinimapButton()
  local parent = minimapParent(minimapSettings())
  local btn = createFrame("Button", "SkillyMinimapButton", parent)
  if not btn then return nil end
  callMethod(btn, "SetWidth", 31)
  callMethod(btn, "SetHeight", 31)
  callMethod(btn, "SetFrameStrata", "MEDIUM")
  callMethod(btn, "SetFrameLevel", 8)
  callMethod(btn, "SetMovable", true)
  callMethod(btn, "EnableMouse", true)
  callMethod(btn, "RegisterForClicks", "LeftButtonUp", "RightButtonUp")
  callMethod(btn, "RegisterForDrag", "LeftButton")

  local bg = nil
  if hasMethod(btn, "CreateTexture") then
    local ok, tex = pcall(btn.CreateTexture, btn, nil, "BACKGROUND")
    if ok then bg = tex end
  end
  if bg then
    callMethod(bg, "SetAllPoints", btn)
    callMethod(bg, "SetTexture", "Interface\\Minimap\\UI-Minimap-Background")
  end

  local label = createFontString(btn, "SkillyMinimapLabel", "GameFontNormalSmall")
  if label then
    callMethod(label, "SetPoint", "CENTER", 0, 0)
    callMethod(label, "SetText", "S")
  end

  callMethod(btn, "SetScript", "OnDragStart", function(self)
    if hasMethod(self, "StartMoving") then pcall(self.StartMoving, self) end
  end)
  callMethod(btn, "SetScript", "OnDragStop", function(self)
    if hasMethod(self, "StopMovingOrSizing") then pcall(self.StopMovingOrSizing, self) end
    saveMinimapDrop(self)
  end)
  callMethod(btn, "SetScript", "OnClick", function(_, button)
    if button == "RightButton" then
      if type(Skilly.OpenSettings) == "function" then pcall(Skilly.OpenSettings) end
      return
    end
    runRecommend()
  end)
  callMethod(btn, "SetScript", "OnEnter", function(self)
    local tt = _G.GameTooltip
    if tt and hasMethod(tt, "SetOwner") then
      pcall(tt.SetOwner, tt, self, "ANCHOR_LEFT")
      pcall(tt.SetText, tt, "Skilly")
      pcall(tt.AddLine, tt, "Left-click: recommend and show results", 1, 1, 1)
      pcall(tt.AddLine, tt, "Right-click: settings", 1, 1, 1)
      pcall(tt.AddLine, tt, "Drag: save position", 1, 1, 1)
      pcall(tt.Show, tt)
    end
  end)
  callMethod(btn, "SetScript", "OnLeave", function()
    local tt = _G.GameTooltip
    if tt and hasMethod(tt, "Hide") then pcall(tt.Hide, tt) end
  end)

  minimapButton = btn
  updateMinimapButtonPosition()
  return btn
end

function Skilly.UI.UpdateMinimapButton()
  local m = minimapSettings()
  local visible = m.visible == true
  if not visible then
    if minimapButton then callMethod(minimapButton, "Hide") end
    return
  end
  if not minimapButton and not minimapBuildFailed then
    local ok, btn = pcall(buildMinimapButton)
    if not ok or not btn then minimapBuildFailed = true end
  end
  if minimapButton then
    updateMinimapButtonPosition()
    callMethod(minimapButton, "Show")
  end
end

-- SB-52: copyable feedback window. WoW cannot write the OS clipboard from Lua,
-- so the text is shown in a multiline EditBox, pre-highlighted and focused.
-- The user presses Ctrl+C. No other addon's UI is touched.
local MAX_EXPORT_CHARS = 20000
local exportFrame = nil
local exportEdit = nil
local exportBuildFailed = false

local function exportUnavailable()
  if type(Skilly.Print) == "function" then
    pcall(Skilly.Print, "Export window unavailable; use /skilly probe and /skilly debug.")
  end
end

local function buildExportFrame()
  local frame = createFrame("Frame", "SkillyExportFrame", _G.UIParent)
  if not frame then return nil end

  callMethod(frame, "SetFrameStrata", "DIALOG")
  callMethod(frame, "SetToplevel", true)
  callMethod(frame, "SetMovable", true)
  callMethod(frame, "EnableMouse", true)
  callMethod(frame, "RegisterForDrag", "LeftButton")
  callMethod(frame, "SetWidth", 640)
  callMethod(frame, "SetHeight", 500)
  callMethod(frame, "SetPoint", "CENTER", 0, 0)
  callMethod(frame, "SetBackdrop", {
    bgFile = "Interface/Tooltips/UI-Tooltip-Background",
    edgeFile = "Interface/Tooltips/UI-Tooltip-Border",
    tile = true,
    tileSize = 16,
    edgeSize = 16,
    insets = { left = 4, right = 4, top = 4, bottom = 4 },
  })
  local style = Skilly.UI.Style()
  local bc = style.backdropColor or { 0.05, 0.05, 0.08, 0.95 }
  local bd = style.borderColor or { 0.6, 0.6, 0.6, 1 }
  callMethod(frame, "SetBackdropColor", bc[1], bc[2], bc[3], bc[4])
  callMethod(frame, "SetBackdropBorderColor", bd[1], bd[2], bd[3], bd[4])
  callMethod(frame, "SetScript", "OnDragStart", function()
    callMethod(frame, "StartMoving")
  end)
  callMethod(frame, "SetScript", "OnDragStop", function()
    callMethod(frame, "StopMovingOrSizing")
  end)
  callMethod(frame, "SetScript", "OnHide", function()
    callMethod(exportEdit, "ClearFocus")
  end)

  local title = createFontString(frame, "SkillyExportTitle", "GameFontNormalLarge")
  callMethod(title, "SetPoint", "TOPLEFT", 12, -10)
  callMethod(title, "SetText", "Skilly feedback export")

  local hint = createFontString(frame, "SkillyExportHint", "GameFontNormalSmall")
  callMethod(hint, "SetPoint", "TOPLEFT", 12, -30)
  callMethod(hint, "SetText", "Ctrl+C to copy, Esc to close. Drag the edge to move.")

  local close = createFrame("Button", "SkillyExportClose", frame, "UIPanelCloseButton")
  local plainClose = false
  if not close then
    close = createFrame("Button", "SkillyExportClose", frame)
    plainClose = true
  end
  callMethod(close, "SetWidth", 24)
  callMethod(close, "SetHeight", 24)
  callMethod(close, "SetPoint", "TOPRIGHT", -4, -4)
  if plainClose then callMethod(close, "SetText", "x") end
  callMethod(close, "SetScript", "OnClick", function()
    callMethod(frame, "Hide")
  end)

  local scroll = createFrame("ScrollFrame", "SkillyExportScroll", frame,
      "UIPanelScrollFrameTemplate")
  if not scroll then
    scroll = createFrame("ScrollFrame", "SkillyExportScroll", frame)
  end
  if not scroll then
    callMethod(frame, "Hide")
    return nil
  end
  callMethod(scroll, "SetWidth", 600)
  callMethod(scroll, "SetHeight", 420)
  callMethod(scroll, "SetPoint", "TOPLEFT", 12, -50)

  local edit = createFrame("EditBox", "SkillyExportEdit", scroll)
  if not edit or not hasMethod(edit, "SetText")
      or not hasMethod(edit, "HighlightText") or not hasMethod(edit, "SetFocus") then
    callMethod(frame, "Hide")
    return nil
  end
  callMethod(edit, "SetMultiLine", true)
  callMethod(edit, "SetAutoFocus", false)
  callMethod(edit, "SetMaxLetters", MAX_EXPORT_CHARS)
  callMethod(edit, "SetWidth", 570)
  callMethod(edit, "SetHeight", 300)
  callMethod(edit, "SetTextInsets", 6, 6, 6, 6)
  callMethod(edit, "SetJustifyH", "LEFT")
  callMethod(edit, "SetFontObject", _G.ChatFontNormal or _G.GameFontNormal or "GameFontNormal")
  callMethod(edit, "SetScript", "OnEscapePressed", function()
    callMethod(frame, "Hide")
  end)
  callMethod(scroll, "SetScrollChild", edit)
  callMethod(frame, "SetScript", "OnShow", function()
    callMethod(edit, "SetFocus")
    callMethod(edit, "HighlightText")
  end)
  callMethod(frame, "Hide")

  exportFrame = frame
  exportEdit = edit
  return frame, edit
end

function Skilly.UI.ShowExport(text)
  local okText, content = pcall(tostring, text)
  if not okText or type(content) ~= "string" then content = "" end
  if #content > MAX_EXPORT_CHARS then content = string.sub(content, 1, MAX_EXPORT_CHARS) end

  if not exportFrame and not exportBuildFailed then
    local okBuild, frame = pcall(buildExportFrame)
    if not okBuild or not frame then
      exportBuildFailed = true
      exportUnavailable()
      return false
    end
  end
  if not exportFrame then
    exportUnavailable()
    return false
  end

  if not callMethod(exportEdit, "SetText", content) then
    exportUnavailable()
    return false
  end

  local lines = 1
  for _ in string.gmatch(content, "\n") do lines = lines + 1 end
  local height = lines * 14 + 30
  if height < 300 then height = 300 elseif height > 8000 then height = 8000 end
  callMethod(exportEdit, "SetHeight", height)
  callMethod(exportFrame, "Show")
  callMethod(exportEdit, "SetFocus")
  callMethod(exportEdit, "HighlightText")
  return true
end
