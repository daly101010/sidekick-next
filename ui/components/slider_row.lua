-- ============================================================
-- SideKick Slider Row Component
-- ============================================================
-- Label + SliderInt/Float + tooltip pattern for settings.
--
-- Usage:
--   local SliderRow = require('sidekick-next.ui.components.slider_row')
--   local changed, newValue = SliderRow.int('Cell Size', 'SideKickBarCell', current, 32, 120)
--   local changed, newValue = SliderRow.float('Opacity', 'SideKickBgAlpha', current, 0, 1)

local imgui = require('ImGui')
require('sidekick-next.ui.imgui_compat')
local C = require('sidekick-next.ui.constants')

local M = {}

-- ============================================================
-- INTEGER SLIDER ROW
-- ============================================================

function M.int(label, settingKey, current, min, max, onChange, opts)
    opts = opts or {}
    local tooltip = opts.tooltip
    local format = opts.format or '%d'
    local width = opts.width or -1

    -- Label
    imgui.Text(label)
    if tooltip and imgui.IsItemHovered() then
        imgui.SetTooltip(tooltip)
    end

    imgui.SameLine()

    -- Slider
    if width > 0 then
        imgui.SetNextItemWidth(width)
    end

    local newValue, changed = imgui.SliderInt('##' .. settingKey, current, min, max, format)

    -- Tooltip on slider
    if tooltip and imgui.IsItemHovered() then
        imgui.SetTooltip(tooltip)
    end

    -- Callback
    if changed and onChange then
        onChange(newValue)
    end

    return changed, newValue
end

-- ============================================================
-- FLOAT SLIDER ROW
-- ============================================================

function M.float(label, settingKey, current, min, max, onChange, opts)
    opts = opts or {}
    local tooltip = opts.tooltip
    local format = opts.format or '%.2f'
    local width = opts.width or -1

    -- Label
    imgui.Text(label)
    if tooltip and imgui.IsItemHovered() then
        imgui.SetTooltip(tooltip)
    end

    imgui.SameLine()

    -- Slider
    if width > 0 then
        imgui.SetNextItemWidth(width)
    end

    local newValue, changed = imgui.SliderFloat('##' .. settingKey, current, min, max, format)

    -- Tooltip on slider
    if tooltip and imgui.IsItemHovered() then
        imgui.SetTooltip(tooltip)
    end

    -- Callback
    if changed and onChange then
        onChange(newValue)
    end

    return changed, newValue
end

-- ============================================================
-- LABELED SLIDER ROW (label on left, slider on right)
-- ============================================================

function M.labeled(label, settingKey, current, min, max, isFloat, onChange, opts)
    opts = opts or {}
    local tooltip = opts.tooltip
    local labelWidth = opts.labelWidth or 150
    local sliderWidth = opts.sliderWidth or 150
    local format = opts.format or (isFloat and '%.2f' or '%d')

    -- Label column
    imgui.Text(label)
    if tooltip and imgui.IsItemHovered() then
        imgui.SetTooltip(tooltip)
    end

    -- Align slider to right
    imgui.SameLine(labelWidth)
    imgui.SetNextItemWidth(sliderWidth)

    -- Slider
    local changed, newValue
    if isFloat then
        newValue, changed = imgui.SliderFloat('##' .. settingKey, current, min, max, format)
    else
        newValue, changed = imgui.SliderInt('##' .. settingKey, current, min, max, format)
    end

    -- Callback
    if changed and onChange then
        onChange(newValue)
    end

    return changed, newValue
end

-- ============================================================
-- PERCENTAGE SLIDER (0-100 with % suffix)
-- ============================================================

function M.percent(label, settingKey, current, onChange, opts)
    opts = opts or {}
    opts.format = opts.format or '%d%%'
    return M.int(label, settingKey, current, 0, 100, onChange, opts)
end

-- ============================================================
-- ALPHA SLIDER (0-1 with 2 decimals)
-- ============================================================

function M.alpha(label, settingKey, current, onChange, opts)
    opts = opts or {}
    opts.format = opts.format or '%.2f'
    opts.tooltip = opts.tooltip or 'Transparency (0 = invisible, 1 = opaque)'
    return M.float(label, settingKey, current, 0, 1, onChange, opts)
end

-- ============================================================
-- ANCHOR GAP SLIDER
-- ============================================================

function M.anchorGap(label, settingKey, current, onChange, opts)
    opts = opts or {}
    opts.tooltip = opts.tooltip or 'Gap between anchored windows (pixels)'
    return M.int(label, settingKey, current, 0, C.LAYOUT.MAX_ANCHOR_GAP, onChange, opts)
end

-- ============================================================
-- CELL SIZE SLIDER
-- ============================================================

function M.cellSize(label, settingKey, current, onChange, opts)
    opts = opts or {}
    opts.tooltip = opts.tooltip or 'Size of each ability cell (pixels)'
    return M.int(label, settingKey, current, C.LAYOUT.MIN_CELL_SIZE, C.LAYOUT.MAX_CELL_SIZE, onChange, opts)
end

-- ============================================================
-- ROWS SLIDER
-- ============================================================

function M.rows(label, settingKey, current, onChange, opts)
    opts = opts or {}
    opts.tooltip = opts.tooltip or 'Number of rows in the bar'
    return M.int(label, settingKey, current, 1, C.LAYOUT.MAX_ROWS, onChange, opts)
end

return M
