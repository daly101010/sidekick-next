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
require('sidekick-next.ui.imgui_compat')
local C = require('sidekick-next.ui.constants')
local Colors = require('sidekick-next.ui.colors')
local AnimHelpers = require('sidekick-next.ui.animation_helpers')
local Draw = require('sidekick-next.ui.draw_helpers')
local lazy = require('sidekick-next.utils.lazy_require')

local M = {}

-- Lazy-loaded themes module for textured rendering
local getThemes = lazy('sidekick-next.themes')

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

    -- Get cursor position for button
    local cx, cy = imgui.GetCursorPos()
    local screenX, screenY = imgui.GetCursorScreenPos()
    if type(screenX) == 'table' then
        screenY = screenX.y or screenX[2]
        screenX = screenX.x or screenX[1]
    end

    -- Calculate actual button size
    local btnW = width and (width * scale) or nil
    local btnH = height and (height * scale) or nil

    -- Apply scale transform via cursor position offset
    if scale ~= 1.0 and width and height then
        local sw = width * scale
        local sh = height * scale
        local offsetX = (width - sw) / 2
        local offsetY = (height - sh) / 2
        imgui.SetCursorPos(cx + offsetX, cy + offsetY)
        screenX = screenX + offsetX
        screenY = screenY + offsetY
    end

    -- Check if we should use textured rendering (completely isolated)
    local useTextures = false
    pcall(function()
        local Themes = getThemes()
        if not Themes or not Themes.isTexturedTheme then return end
        if not Themes.isTexturedTheme(theme) then return end

        local TextureRenderer = Draw.getTextureRenderer and Draw.getTextureRenderer()
        if not TextureRenderer then return end
        if TextureRenderer.isAvailable and not TextureRenderer.isAvailable() then return end

        if not btnW or not btnH then return end
        local dl = imgui.GetWindowDrawList()
        if not dl then return end

        -- Determine button state and size
        local state = enabled and 'pressed' or 'normal'
        local btnSize = TextureRenderer.getBestButtonSize and TextureRenderer.getBestButtonSize(btnW, btnH) or 'std'

        -- Draw texture behind button
        TextureRenderer.drawClassicButton(dl, screenX, screenY, btnW, btnH, state, btnSize)

        -- Make ImGui button transparent
        imgui.PushStyleColor(ImGuiCol.Button, 0, 0, 0, 0)
        imgui.PushStyleColor(ImGuiCol.ButtonHovered, 1, 1, 1, 0.1)
        imgui.PushStyleColor(ImGuiCol.ButtonActive, 0, 0, 0, 0.1)

        useTextures = true
    end)

    -- Push regular style colors if not using textures
    if not useTextures then
        imgui.PushStyleColor(ImGuiCol.Button, color[1], color[2], color[3], color[4])
        imgui.PushStyleColor(ImGuiCol.ButtonHovered, color[1] * 1.1, color[2] * 1.1, color[3] * 1.1, color[4])
        imgui.PushStyleColor(ImGuiCol.ButtonActive, color[1] * 0.9, color[2] * 0.9, color[3] * 0.9, color[4])
    end

    -- Draw button
    local clicked = false
    if btnW and btnH then
        clicked = imgui.Button(label, btnW, btnH)
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

    -- Get screen position for button
    local screenX, screenY = imgui.GetCursorScreenPos()
    if type(screenX) == 'table' then
        screenY = screenX.y or screenX[2]
        screenX = screenX.x or screenX[1]
    end

    local btnSize = size * scale

    -- Check if we should use textured rendering (completely isolated)
    local useTextures = false
    pcall(function()
        local Themes = getThemes()
        if not Themes or not Themes.isTexturedTheme then return end
        if not Themes.isTexturedTheme(theme) then return end

        local TextureRenderer = Draw.getTextureRenderer and Draw.getTextureRenderer()
        if not TextureRenderer then return end
        if TextureRenderer.isAvailable and not TextureRenderer.isAvailable() then return end

        local dl = imgui.GetWindowDrawList()
        if not dl then return end

        local state = enabled and 'active' or 'normal'
        TextureRenderer.drawIconHolder(dl, screenX, screenY, btnSize, state)

        -- Make ImGui button transparent
        imgui.PushStyleColor(ImGuiCol.Button, 0, 0, 0, 0)
        imgui.PushStyleColor(ImGuiCol.ButtonHovered, 1, 1, 1, 0.1)
        imgui.PushStyleColor(ImGuiCol.ButtonActive, 0, 0, 0, 0.1)

        useTextures = true
    end)

    -- Push regular style if not using textures
    if not useTextures then
        imgui.PushStyleColor(ImGuiCol.Button, color[1], color[2], color[3], color[4])
        imgui.PushStyleColor(ImGuiCol.ButtonHovered, color[1] * 1.1, color[2] * 1.1, color[3] * 1.1, color[4])
        imgui.PushStyleColor(ImGuiCol.ButtonActive, color[1] * 0.9, color[2] * 0.9, color[3] * 0.9, color[4])
    end

    -- Draw button with scaled size
    local clicked = imgui.Button(icon, btnSize, btnSize)

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
-- SIMPLE BUTTON (with texture support)
-- ============================================================

function M.button(label, opts)
    opts = opts or {}
    local theme = opts.theme or 'Classic'
    local width = opts.width
    local height = opts.height
    local onClick = opts.onClick

    -- Get screen position for button
    local screenX, screenY = imgui.GetCursorScreenPos()
    if type(screenX) == 'table' then
        screenY = screenX.y or screenX[2]
        screenX = screenX.x or screenX[1]
    end

    -- Check if we should use textured rendering
    local useTextures = false
    local hovered = false
    pcall(function()
        local Themes = getThemes()
        if not Themes or not Themes.isTexturedTheme then return end
        if not Themes.isTexturedTheme(theme) then return end

        local TextureRenderer = Draw.getTextureRenderer and Draw.getTextureRenderer()
        if not TextureRenderer then return end
        if TextureRenderer.isAvailable and not TextureRenderer.isAvailable() then return end

        if not width or not height then return end
        local dl = imgui.GetWindowDrawList()
        if not dl then return end

        -- We need to check hover state - use invisible button area check
        -- For now, draw normal state; hover will be detected after button
        local btnSize = TextureRenderer.getBestButtonSize and TextureRenderer.getBestButtonSize(width, height) or 'std'

        -- Draw texture behind button (will update state after we know hover)
        TextureRenderer.drawClassicButton(dl, screenX, screenY, width, height, 'normal', btnSize)

        -- Make ImGui button transparent
        imgui.PushStyleColor(ImGuiCol.Button, 0, 0, 0, 0)
        imgui.PushStyleColor(ImGuiCol.ButtonHovered, 1, 1, 1, 0.15)
        imgui.PushStyleColor(ImGuiCol.ButtonActive, 0, 0, 0, 0.2)

        useTextures = true
    end)

    -- Push default style if not using textures
    if not useTextures then
        imgui.PushStyleColor(ImGuiCol.Button, 0.2, 0.4, 0.6, 0.8)
        imgui.PushStyleColor(ImGuiCol.ButtonHovered, 0.3, 0.5, 0.7, 0.9)
        imgui.PushStyleColor(ImGuiCol.ButtonActive, 0.15, 0.35, 0.55, 1.0)
    end

    -- Draw button
    local clicked = false
    if width and height then
        clicked = imgui.Button(label, width, height)
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
    local newValue, changed = imgui.Checkbox(label, enabled)

    if changed and opts.onChange then
        opts.onChange(newValue)
    end

    return newValue, changed
end

return M
