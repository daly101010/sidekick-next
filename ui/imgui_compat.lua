-- Compatibility shim for MacroQuest's ImGui Lua bindings.
-- Ensures widgets return (value, changed) where changed = (newValue ~= oldValue).
-- Simple approach: ignore the binding's changed flag and compute it ourselves.

local imgui = require('ImGui')

if imgui.__sidekick_imgui_compat_v2 then
    return imgui
end
imgui.__sidekick_imgui_compat_v2 = true

-- Store original functions
local origCheckbox = imgui.Checkbox
local origSliderInt = imgui.SliderInt
local origSliderFloat = imgui.SliderFloat
local origInputText = imgui.InputText
local origInputInt = imgui.InputInt
local origInputFloat = imgui.InputFloat
local origCombo = imgui.Combo

-- Checkbox: (label, checked) -> (newChecked, changed)
imgui.Checkbox = function(label, checked)
    local oldVal = checked
    local result = origCheckbox(label, checked)
    -- Handle both single-return and multi-return bindings
    local newVal = result
    if type(result) == 'boolean' then
        newVal = result
    end
    local changed = (newVal ~= oldVal)
    return newVal, changed
end

-- SliderInt: (label, value, min, max, ...) -> (newValue, changed)
imgui.SliderInt = function(label, value, min, max, ...)
    local oldVal = value
    local result = origSliderInt(label, value, min, max, ...)
    local newVal = tonumber(result) or value
    local changed = (newVal ~= oldVal)
    return newVal, changed
end

-- SliderFloat: (label, value, min, max, ...) -> (newValue, changed)
imgui.SliderFloat = function(label, value, min, max, ...)
    local oldVal = value
    local result = origSliderFloat(label, value, min, max, ...)
    local newVal = tonumber(result) or value
    -- Use tolerance for float comparison
    local changed = math.abs((newVal or 0) - (oldVal or 0)) > 0.0001
    return newVal, changed
end

-- InputText: (label, text, ...) -> (newText, changed)
if origInputText then
    imgui.InputText = function(label, text, ...)
        local oldVal = text or ''
        local result = origInputText(label, text, ...)
        local newVal = tostring(result or '')
        local changed = (newVal ~= oldVal)
        return newVal, changed
    end
end

-- InputInt: (label, value, ...) -> (newValue, changed)
if origInputInt then
    imgui.InputInt = function(label, value, ...)
        local oldVal = value
        local result = origInputInt(label, value, ...)
        local newVal = tonumber(result) or value
        local changed = (newVal ~= oldVal)
        return newVal, changed
    end
end

-- InputFloat: (label, value, ...) -> (newValue, changed)
if origInputFloat then
    imgui.InputFloat = function(label, value, ...)
        local oldVal = value
        local result = origInputFloat(label, value, ...)
        local newVal = tonumber(result) or value
        local changed = math.abs((newVal or 0) - (oldVal or 0)) > 0.0001
        return newVal, changed
    end
end

-- Combo: (label, currentIdx, items, ...) -> (newIdx, changed)
if origCombo then
    imgui.Combo = function(label, currentIdx, ...)
        local oldVal = currentIdx
        local result = origCombo(label, currentIdx, ...)
        local newVal = tonumber(result) or currentIdx
        local changed = (newVal ~= oldVal)
        return newVal, changed
    end
end

return imgui
