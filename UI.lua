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

-- Placeholder binding target for Bindings.xml. Scripts are added in SB-19.
local bindingButton = createFrame("Button", "SkillyBindingButton", _G.UIParent)
if bindingButton then callMethod(bindingButton, "Hide") end

-- SB-18/SB-54: chat is authoritative; a result window (SB-17) is optional.
-- Every external call is type-checked and pcall-wrapped.
function Skilly.UI.PrintResults(entries, fullEntries)
  if type(entries) ~= "table" or type(entries[1]) ~= "table" then
    Skilly.Print("No recipes qualify in this mode.")
    return
  end
  if type(Skilly.Rank) ~= "table" or type(Skilly.Rank.Describe) ~= "function" then
    Skilly.Print("Recommendation unavailable: missing Skilly.Rank.Describe")
    return
  end

  local top = entries[1]
  local ok, line = pcall(Skilly.Rank.Describe, top)
  if ok and type(line) == "string" and line ~= "" then
    Skilly.Print("Best craft: with materials on hand - " .. line)
  end

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

  for i = 2, math.min(#entries, 4) do
    local okRow, row = pcall(Skilly.Rank.Describe, entries[i])
    if okRow and type(row) == "string" and row ~= "" then
      Skilly.Print(i .. ") " .. row)
    end
  end

  if type(Skilly.UI.ShowResults) == "function" then
    pcall(Skilly.UI.ShowResults, entries)
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
  callMethod(frame, "SetWidth", 660)
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

  callMethod(frame, "SetScript", "OnDragStart", function()
    callMethod(frame, "StartMoving")
  end)
  callMethod(frame, "SetScript", "OnDragStop", function()
    callMethod(frame, "StopMovingOrSizing")
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

  for i = 1, RESULTS_MAX_ROWS do
    local name = createFontString(frame, "SkillyResultName" .. i,
        "GameFontNormal")
    local detail = createFontString(frame, "SkillyResultDetail" .. i,
        "GameFontNormalSmall")
    resultsRows[i] = { name = name, detail = detail }
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

local function placeRow(row, y, name, detail, recipe)
  if not row or not row.name or not row.detail then return y end
  callMethod(row.name, "SetText", name)
  local r, g, b = clientDifficultyColor(recipe)
  if r and g and b then callMethod(row.name, "SetTextColor", r, g, b, 1) end
  callMethod(row.name, "SetPoint", "TOPLEFT", 14, -y)
  callMethod(row.name, "Show")

  callMethod(row.detail, "SetText", detail)
  callMethod(row.detail, "SetPoint", "TOPLEFT", 14, -(y + 14))
  callMethod(row.detail, "Show")

  local lines = math.ceil(#detail / 90)
  if lines < 1 then lines = 1 elseif lines > 4 then lines = 4 end
  return y + 16 + lines * 12 + 6
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
  for i = 1, RESULTS_MAX_ROWS do
    local row = resultsRows[i]
    local entry = i <= count and entries[i] or nil
    if not entry then
      if row then
        callMethod(row.name, "Hide")
        callMethod(row.detail, "Hide")
      end
    else
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
      y = placeRow(row, y, name, detail, recipe)
    end
  end

  callMethod(resultsFrame, "SetHeight", math.max(120, y + 16))
  callMethod(resultsFrame, "Show")
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
  callMethod(frame, "SetBackdropColor", 0.05, 0.05, 0.08, 0.95)
  callMethod(frame, "SetBackdropBorderColor", 0.6, 0.6, 0.6, 1)
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
