--[[---------------------------------------------------------------------------------
  SkillBuddy - by faslkjd56
  WoW Forever 1.60.1 craft advisor
------------------------------------------------------------------------------------]]

SkillBuddy = SkillBuddy or {}
SkillBuddy.UI = SkillBuddy.UI or {}

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
local bindingButton = createFrame("Button", "SkillBuddyBindingButton", _G.UIParent)
if bindingButton then callMethod(bindingButton, "Hide") end

-- SB-18/SB-54: chat is authoritative; a result window (SB-17) is optional.
-- Every external call is type-checked and pcall-wrapped.
function SkillBuddy.UI.PrintResults(entries, fullEntries)
  if type(entries) ~= "table" or type(entries[1]) ~= "table" then
    SkillBuddy.Print("No recipes qualify in this mode.")
    return
  end
  if type(SkillBuddy.Rank) ~= "table" or type(SkillBuddy.Rank.Describe) ~= "function" then
    SkillBuddy.Print("Recommendation unavailable: missing SkillBuddy.Rank.Describe")
    return
  end

  local top = entries[1]
  local ok, line = pcall(SkillBuddy.Rank.Describe, top)
  if ok and type(line) == "string" and line ~= "" then
    SkillBuddy.Print("Best craft: with materials on hand - " .. line)
  end

  local fullTop = type(fullEntries) == "table" and fullEntries[1] or nil
  if type(fullTop) == "table" then
    if fullTop.recipe == top.recipe then
      SkillBuddy.Print("Best craft: also best at full material cost.")
    else
      local okFull, fullLine = pcall(SkillBuddy.Rank.Describe, fullTop)
      if okFull and type(fullLine) == "string" and fullLine ~= "" then
        SkillBuddy.Print("Best craft: at full material cost - " .. fullLine)
      end
    end
  end

  if type(SkillBuddy.Rank.DescribeHints) == "function" then
    local okHints, hints = pcall(SkillBuddy.Rank.DescribeHints, top)
    if okHints and type(hints) == "table" then
      for _, hint in ipairs(hints) do
        if type(hint) == "string" and hint ~= "" then SkillBuddy.Print(hint) end
      end
    end
  end

  for i = 2, math.min(#entries, 4) do
    local okRow, row = pcall(SkillBuddy.Rank.Describe, entries[i])
    if okRow and type(row) == "string" and row ~= "" then
      SkillBuddy.Print(i .. ") " .. row)
    end
  end

  if type(SkillBuddy.UI.ShowResults) == "function" then
    pcall(SkillBuddy.UI.ShowResults, entries)
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
  if type(SkillBuddy.Print) == "function" then
    pcall(SkillBuddy.Print, "Export window unavailable; use /sb probe and /sb debug.")
  end
end

local function buildExportFrame()
  local frame = createFrame("Frame", "SkillBuddyExportFrame", _G.UIParent)
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

  local title = createFontString(frame, "SkillBuddyExportTitle", "GameFontNormalLarge")
  callMethod(title, "SetPoint", "TOPLEFT", 12, -10)
  callMethod(title, "SetText", "SkillBuddy feedback export")

  local hint = createFontString(frame, "SkillBuddyExportHint", "GameFontNormalSmall")
  callMethod(hint, "SetPoint", "TOPLEFT", 12, -30)
  callMethod(hint, "SetText", "Ctrl+C to copy, Esc to close. Drag the edge to move.")

  local close = createFrame("Button", "SkillBuddyExportClose", frame, "UIPanelCloseButton")
  local plainClose = false
  if not close then
    close = createFrame("Button", "SkillBuddyExportClose", frame)
    plainClose = true
  end
  callMethod(close, "SetWidth", 24)
  callMethod(close, "SetHeight", 24)
  callMethod(close, "SetPoint", "TOPRIGHT", -4, -4)
  if plainClose then callMethod(close, "SetText", "x") end
  callMethod(close, "SetScript", "OnClick", function()
    callMethod(frame, "Hide")
  end)

  local scroll = createFrame("ScrollFrame", "SkillBuddyExportScroll", frame,
      "UIPanelScrollFrameTemplate")
  if not scroll then
    scroll = createFrame("ScrollFrame", "SkillBuddyExportScroll", frame)
  end
  if not scroll then
    callMethod(frame, "Hide")
    return nil
  end
  callMethod(scroll, "SetWidth", 600)
  callMethod(scroll, "SetHeight", 420)
  callMethod(scroll, "SetPoint", "TOPLEFT", 12, -50)

  local edit = createFrame("EditBox", "SkillBuddyExportEdit", scroll)
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

function SkillBuddy.UI.ShowExport(text)
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
