--[[---------------------------------------------------------------------------------
  SkillBuddy - by faslkjd56
  WoW Forever 1.60.1 craft advisor
------------------------------------------------------------------------------------]]

SkillBuddy = SkillBuddy or {}
SkillBuddy.version = "0.1.0"

BINDING_HEADER_SKILLBUDDY = "SkillBuddy"
BINDING_NAME_SKILLBUDDY_NEXT_CRAFT = "Next craft"

-- Real compartment action lands in SB-16.
function SkillBuddy_OnCompartmentClick()
end

local function dbGet(key)
  if type(SkillBuddyDB) ~= "table" then return nil end
  return SkillBuddyDB[key]
end

local function dbSet(key, value)
  if type(SkillBuddyDB) ~= "table" then SkillBuddyDB = {} end
  SkillBuddyDB[key] = value
end

-- SB-03: native Settings page. Uses the modern Settings API when present.
function SkillBuddy.InitSettings()
  if SkillBuddy.settingsCategory or SkillBuddy.settingsFailed then return end

  local api = Settings
  if not (api and api.RegisterVerticalLayoutCategory and api.RegisterAddOnCategory
      and api.RegisterProxySetting and api.CreateCheckbox and api.CreateSlider
      and api.CreateSliderOptions) then
    SkillBuddy.settingsFailed = true
    return
  end

  local ok = pcall(function()
    if type(SkillBuddy.InitDB) == "function" then SkillBuddy.InitDB() end

    local category = api.RegisterVerticalLayoutCategory("SkillBuddy")
    api.RegisterAddOnCategory(category)
    SkillBuddy.settingsCategory = category

    local function addSetting(name, variable, defaultValue, getter, setter)
      return api.RegisterProxySetting(
        category, variable, type(defaultValue), name, defaultValue, getter, setter
      )
    end

    local function addCheckbox(name, variable, defaultValue, getter, setter, tooltip)
      local setting = addSetting(name, variable, defaultValue, getter, setter)
      api.CreateCheckbox(category, setting, tooltip)
    end

    local function addModeCheckbox()
      addCheckbox(
        "Best skillup mode", "SKILLBUDDY_BEST_MODE", false,
        function() return dbGet("mode") == "best" end,
        function(value)
          dbSet("mode", value == true and "best" or "cheap")
        end,
        "On: best skillup. Off: cheapest available skillup."
      )
    end

    local modeSetting = addSetting(
      "Mode", "SKILLBUDDY_MODE", "cheap",
      function()
        if dbGet("mode") == "best" then return "best" end
        return "cheap"
      end,
      function(value)
        dbSet("mode", value == "best" and "best" or "cheap")
      end
    )

    if api.CreateDropdown then
      local options = {
        { text = "Cheapest available", value = "cheap" },
        { text = "Best skillup", value = "best" },
      }
      if not pcall(api.CreateDropdown, category, modeSetting, options) then
        addModeCheckbox()
      end
    else
      addModeCheckbox()
    end

    addCheckbox(
      "Include bank", "SKILLBUDDY_INCLUDE_BANK", false,
      function() return dbGet("includeBank") == true end,
      function(value) dbSet("includeBank", value == true) end,
      "Count reagents in the bank as well as in bags."
    )

    local countSetting = addSetting(
      "Results to show", "SKILLBUDDY_RESULT_COUNT", 5,
      function()
        local n = math.floor(tonumber(dbGet("resultCount")) or 5)
        if n < 1 then n = 1 elseif n > 10 then n = 10 end
        return n
      end,
      function(value)
        local n = math.floor(tonumber(value) or 5)
        if n < 1 then n = 1 elseif n > 10 then n = 10 end
        dbSet("resultCount", n)
      end
    )
    api.CreateSlider(
      category, countSetting, api.CreateSliderOptions(1, 10, 1),
      "Maximum number of recipes shown."
    )

    addCheckbox(
      "Show minimap button", "SKILLBUDDY_MINIMAP_VISIBLE", true,
      function()
        local m = dbGet("minimap")
        return type(m) ~= "table" or m.visible ~= false
      end,
      function(value)
        local m = dbGet("minimap")
        if type(m) ~= "table" then m = {} end
        m.visible = (value == true)
        dbSet("minimap", m)
      end,
      "Show the launcher button near the minimap."
    )
  end)

  if not ok then
    SkillBuddy.settingsCategory = nil
    SkillBuddy.settingsFailed = true
  end
end

-- SB-04: one dispatcher for /sb and /skillbuddy.
SkillBuddy.Recommend = SkillBuddy.Recommend or function()
  SkillBuddy.Print("Recommendation not ready yet.")
end

SkillBuddy.RegisterCommand("next", function()
  SkillBuddy.Recommend()
end)

SkillBuddy.RegisterCommand("best", function()
  dbSet("mode", "best")
  SkillBuddy.Recommend()
end)

SkillBuddy.RegisterCommand("cheap", function()
  dbSet("mode", "cheap")
  SkillBuddy.Recommend()
end)

SkillBuddy.RegisterCommand("config", function()
  if SkillBuddy.settingsCategory and Settings and Settings.OpenToCategory then
    pcall(Settings.OpenToCategory, SkillBuddy.settingsCategory:GetID())
  else
    SkillBuddy.Print("Settings panel is not available.")
  end
end)

SkillBuddy.RegisterCommand("help", function()
  local names = {}
  for name in pairs(SkillBuddy.commands) do
    names[#names + 1] = name
  end
  table.sort(names)
  SkillBuddy.Print("Commands: /sb " .. table.concat(names, ", /sb "))
end)

function SkillBuddy.Command(msg)
  msg = string.lower(string.gsub(tostring(msg or ""), "^%s+(.-)%s*$", "%1"))

  if type(SkillBuddy.InitDB) == "function" then
    pcall(SkillBuddy.InitDB)
  end

  local cmd = string.match(msg, "^%S+")
  if not cmd then
    SkillBuddy.Recommend()
    return
  end

  local handler = SkillBuddy.commands[cmd]
  if not handler then
    handler = SkillBuddy.commands["help"]
  end

  if handler then
    local arg = string.match(msg, "^%S+%s*(.*)$") or ""
    local ok, err = pcall(handler, arg)
    if not ok then
      SkillBuddy.Print("Command failed: " .. tostring(err))
    end
  end
end

SLASH_SKILLBUDDY1 = "/sb"
SLASH_SKILLBUDDY2 = "/skillbuddy"
SlashCmdList["SKILLBUDDY"] = SkillBuddy.Command

-- Bootstrap: init saved variables (SB-02) once, then announce the version.
local frame = CreateFrame("Frame")
frame:RegisterEvent("PLAYER_LOGIN")
frame:RegisterEvent("ADDON_LOADED")
frame:SetScript("OnEvent", function(self, event, arg1)
  if event == "ADDON_LOADED" then
    for _, name in ipairs(SkillBuddy.optionalAddons or {}) do
      if arg1 == name and type(SkillBuddy.InitSources) == "function" then
        pcall(SkillBuddy.InitSources)
      end
    end
    return
  end
  if event ~= "PLAYER_LOGIN" then return end

  if type(SkillBuddy.InitDB) == "function" then
    pcall(SkillBuddy.InitDB)
  end
  if type(SkillBuddy.InitSettings) == "function" then
    pcall(SkillBuddy.InitSettings)
  end
  if type(SkillBuddy.InitSources) == "function" then
    pcall(SkillBuddy.InitSources)
  end

  if DEFAULT_CHAT_FRAME and DEFAULT_CHAT_FRAME.AddMessage then
    DEFAULT_CHAT_FRAME:AddMessage("SkillBuddy " .. SkillBuddy.version .. " loaded")
  end
end)
