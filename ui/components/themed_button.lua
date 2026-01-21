-- ============================================================
-- SideKick Themed Button Component
-- ============================================================
-- Reusable toggle button with theme-aware colors and animations.
--
-- Usage:
--   local ThemedButton = require('sidekick-next.ui.components.themed_button')
--   local clicked = ThemedButton.toggle('BurnMode', enabled, {
--       theme = 'Classic',
--       uniqueId = 'burn_toggle',
--       onClick = function() enabled = not enabled end
--   })

local imgui = require('ImGui')
local C = require('sidekick-next.ui.constants')
local Colors = require('sidekick-next.ui.colors')
local AnimHelpers = require('sidekick-next.ui.animation_helpers')

local M = {}

-- ============================================================
-- TOGGLE BUTTON
-- ============================================================

function M.toggle(label, enabled, opts)
    opts = opts or {}
    local theme = opts.theme or 'Classic'
    local uniqueId = opts.uniqueId or label
    local onClick = opts.onClick
    local width = opts.width
    local height = opts.height

    -- Get theme-aware colors
    local onColor = Colors.toggleOn(theme)
    local offColor = Colors.toggleOff(theme)

    -- Get animated scale
    local scale = AnimHelpers.getToggleScale(uniqueId, enabled)

    -- Get animated color
    local color = AnimHelpers.getToggleColor(uniqueId, enabled, onColor, offColor)

    -- Push style colors
    imgui.PushStyleColor(ImGuiCol.Button, color[1], color[2], color[3], color[4])
    imgui.PushStyleColor(ImGuiCol.ButtonHovered, color[1] * 1.1, color[2] * 1.1, color[3] * 1.1, color[4])
    imgui.PushStyleColor(ImGuiCol.ButtonActive, color[1] * 0.9, color[2] * 0.9, color[3] * 0.9, color[4])

    -- Apply scale transform via cursor position offset
    local cx, cy = imgui.GetCursorPos()
    if scale ~= 1.0 and width and height then
        local sw = width * scale
        local sh = height * scale
        local offsetX = (width - sw) / 2
        local offsetY = (height - sh) / 2
        imgui.SetCursorPos(cx + offsetX, cy + offsetY)
    end

    -- Draw button
    local clicked = false
    if width and height then
        clicked = imgui.Button(label, width * scale, height * scale)
    else
        clicked = imgui.Button(label)
    end

    imgui.PopStyleColor(3)

    -- Handle click
    if clicked and onClick then
        onClick()
    end

    return clicked
end

-- ============================================================
-- ICON TOGGLE BUTTON
-- ============================================================

function M.iconToggle(icon, enabled, opts)
    opts = opts or {}
    local theme = opts.theme or 'Classic'
    local uniqueId = opts.uniqueId or icon
    local onClick = opts.onClick
    local size = opts.size or C.LAYOUT.ICON_SIZE_SMALL
    local tooltip = opts.tooltip

    -- Get theme-aware colors
    local onColor = Colors.toggleOn(theme)
    local offColor = Colors.toggleOff(theme)

    -- Get animated scale
    local scale = AnimHelpers.getToggleScale(uniqueId, enabled)

    -- Get animated color
    local color = AnimHelpers.getToggleColor(uniqueId, enabled, onColor, offColor)

    -- Push style
    imgui.PushStyleColor(ImGuiCol.Button, color[1], color[2], color[3], color[4])
    imgui.PushStyleColor(ImGuiCol.ButtonHovered, color[1] * 1.1, color[2] * 1.1, color[3] * 1.1, color[4])
    imgui.PushStyleColor(ImGuiCol.ButtonActive, color[1] * 0.9, color[2] * 0.9, color[3] * 0.9, color[4])

    -- Draw button with scaled size
    local clicked = imgui.Button(icon, size * scale, size * scale)

    imgui.PopStyleColor(3)

    -- Tooltip
    if tooltip and imgui.IsItemHovered() then
        imgui.SetTooltip(tooltip)
    end

    -- Handle click
    if clicked and onClick then
        onClick()
    end

    return clicked
end

-- ============================================================
-- SMALL TOGGLE BUTTON (for settings)
-- ============================================================

function M.smallToggle(label, enabled, opts)
    opts = opts or {}
    opts.width = opts.width or 60
    opts.height = opts.height or 20
    return M.toggle(enabled and 'ON' or 'OFF', enabled, opts)
end

-- ============================================================
-- CHECKBOX-STYLE TOGGLE
-- ============================================================

function M.checkbox(label, enabled, opts)
    opts = opts or {}
    local uniqueId = opts.uniqueId or label

    -- Get animated color for the checkmark
    local color = Colors.toggle(opts.theme, enabled)

    -- Use imgui checkbox
    local changed, newValue = imgui.Checkbox(label, enabled)

    if changed and opts.onChange then
        opts.onChange(newValue)
    end

    return changed, newValue
end

return M
