--[[---------------------------------------------------------------------------------
  SkillBuddy - by faslkjd56
  WoW Forever 1.60.1 craft advisor
------------------------------------------------------------------------------------]]

SkillBuddy = SkillBuddy or {}

-- Placeholder binding target for Bindings.xml. Scripts are added in SB-19.
local bindingButton = CreateFrame("Button", "SkillBuddyBindingButton", UIParent)
bindingButton:Hide()
