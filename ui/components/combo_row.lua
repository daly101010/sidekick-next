-- ============================================================
-- SideKick Combo Row Component
-- ============================================================
-- Label + Combo dropdown pattern for settings.
--
-- Usage:
--   local ComboRow = require('sidekick-next.ui.components.combo_row')
--   local changed, newIndex = ComboRow.draw('Theme', 'SideKickTheme', currentIndex, themes)
--   local changed, newValue = ComboRow.byValue('Anchor', 'SideKickBarAnchor', currentValue, anchorModes)

local imgui = require('ImGui')
local C = require('sidekick-next.ui.constants')

local M = {}

-- ============================================================
-- STANDARD COMBO ROW (index-based)
-- ============================================================

function M.draw(label, settingKey, currentIndex, items, onChange, opts)
    opts = opts or {}
    local tooltip = opts.tooltip
    local width = opts.width or 150
    local previewValue = items[currentIndex + 1] or ''  -- 0-indexed to 1-indexed

    -- Label
    imgui.Text(label)
    if tooltip and imgui.IsItemHovered() then
        imgui.SetTooltip(tooltip)
    end

    imgui.SameLine()

    -- Combo
    imgui.SetNextItemWidth(width)
    local changed = false
    local newIndex = currentIndex

    if imgui.BeginCombo('##' .. settingKey, previewValue) then
        for i, item in ipairs(items) do
            local isSelected = (i - 1) == currentIndex
            if imgui.Selectable(item, isSelected) then
                newIndex = i - 1  -- Back to 0-indexed
                changed = true
            end
            if isSelected then
                imgui.SetItemDefaultFocus()
            end
        end
        imgui.EndCombo()
    end

    -- Callback
    if changed and onChange then
        onChange(newIndex)
    end

    return changed, newIndex
end

-- ============================================================
-- VALUE-BASED COMBO ROW (finds index by value)
-- ============================================================

function M.byValue(label, settingKey, currentValue, items, onChange, opts)
    opts = opts or {}

    -- Find current index
    local currentIndex = 0
    for i, item in ipairs(items) do
        if item == currentValue then
            currentIndex = i - 1
            break
        end
    end

    local changed, newIndex = M.draw(label, settingKey, currentIndex, items, nil, opts)

    if changed then
        local newValue = items[newIndex + 1]
        if onChange then
            onChange(newValue)
        end
        return true, newValue
    end

    return false, currentValue
end

-- ============================================================
-- KEY-VALUE COMBO ROW (items are {key, label} pairs)
-- ============================================================

function M.keyValue(label, settingKey, currentKey, items, onChange, opts)
    opts = opts or {}
    local tooltip = opts.tooltip
    local width = opts.width or 150

    -- Find current index and build labels
    local labels = {}
    local currentIndex = 0
    for i, item in ipairs(items) do
        labels[i] = item.label or item.key or tostring(item)
        if item.key == currentKey then
            currentIndex = i - 1
        end
    end

    local previewValue = labels[currentIndex + 1] or ''

    -- Label
    imgui.Text(label)
    if tooltip and imgui.IsItemHovered() then
        imgui.SetTooltip(tooltip)
    end

    imgui.SameLine()

    -- Combo
    imgui.SetNextItemWidth(width)
    local changed = false
    local newKey = currentKey

    if imgui.BeginCombo('##' .. settingKey, previewValue) then
        for i, item in ipairs(items) do
            local isSelected = item.key == currentKey
            if imgui.Selectable(labels[i], isSelected) then
                newKey = item.key
                changed = true
            end
            if isSelected then
                imgui.SetItemDefaultFocus()
            end
        end
        imgui.EndCombo()
    end

    -- Callback
    if changed and onChange then
        onChange(newKey)
    end

    return changed, newKey
end

-- ============================================================
-- ANCHOR MODE COMBO
-- ============================================================

function M.anchorMode(label, settingKey, currentValue, onChange, opts)
    opts = opts or {}
    opts.tooltip = opts.tooltip or 'How this bar anchors to its target'
    return M.byValue(label, settingKey, currentValue, C.ANCHOR_MODES, onChange, opts)
end

-- ============================================================
-- ANCHOR TARGET COMBO
-- ============================================================

function M.anchorTarget(label, settingKey, currentValue, onChange, opts)
    opts = opts or {}
    opts.tooltip = opts.tooltip or 'Which window to anchor this bar to'
    return M.keyValue(label, settingKey, currentValue, C.ANCHOR_TARGETS, onChange, opts)
end

-- ============================================================
-- THEME COMBO (convenience function)
-- ============================================================

function M.theme(label, settingKey, currentValue, themes, onChange, opts)
    opts = opts or {}
    opts.tooltip = opts.tooltip or 'Visual theme for this window'
    return M.byValue(label, settingKey, currentValue, themes, onChange, opts)
end

return M
