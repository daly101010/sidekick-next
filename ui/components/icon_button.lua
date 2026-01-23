-- ============================================================
-- SideKick Icon Button Component
-- ============================================================
-- Toolbar-style buttons with icons and optional labels.
-- Supports toggle states, hover effects, and themed styling.
--
-- Usage:
--   local IconButton = require('sidekick-next.ui.components.icon_button')
--   if IconButton.draw('⚙', 'Settings', 'Classic') then
--       -- clicked
--   end
--   local active = IconButton.toggle('▶', 'Play', isPlaying, 'Classic')

local imgui = require('ImGui')
local Draw = require('sidekick-next.ui.draw_helpers')
local Colors = require('sidekick-next.ui.colors')

local M = {}

-- ============================================================
-- ICON DEFINITIONS
-- ============================================================

-- Common icons (ASCII alternatives for cross-platform)
M.ICONS = {
    settings = '⚙',
    play = '▶',
    pause = '⏸',
    stop = '■',
    refresh = '↻',
    close = '×',
    minimize = '−',
    maximize = '□',
    add = '+',
    remove = '-',
    edit = '✎',
    save = '💾',
    load = '📂',
    lock = '🔒',
    unlock = '🔓',
    eye = '👁',
    eyeOff = '◌',
    check = '✓',
    cross = '✗',
    warning = '⚠',
    info = 'ℹ',
    question = '?',
    up = '▲',
    down = '▼',
    left = '◀',
    right = '▶',
    menu = '☰',
    grid = '⊞',
    list = '≡',
    search = '🔍',
    filter = '⧉',
    sort = '↕',
    pin = '📌',
    copy = '⎘',
    paste = '📋',
    undo = '↶',
    redo = '↷',
    zoomIn = '+',
    zoomOut = '-',
    home = '⌂',
    user = '👤',
    group = '👥',
    target = '⊕',
    sword = '⚔',
    shield = '🛡',
    heart = '♥',
    mana = '◆',
    spell = '✦',
    buff = '↑',
    debuff = '↓',
}

-- ============================================================
-- THEME COLORS
-- ============================================================

local function getButtonColors(themeName, isActive, isHovered, isPressed)
    local baseColors = {
        Classic = {
            bg = { 0.20, 0.22, 0.26 },
            bgHover = { 0.28, 0.32, 0.38 },
            bgActive = { 0.25, 0.45, 0.65 },
            bgPressed = { 0.15, 0.35, 0.55 },
            border = { 0.35, 0.38, 0.42 },
            borderActive = { 0.4, 0.6, 0.85 },
            icon = { 0.75, 0.78, 0.82 },
            iconHover = { 0.9, 0.92, 0.95 },
            iconActive = { 1.0, 1.0, 1.0 },
        },
        Dark = {
            bg = { 0.12, 0.14, 0.18 },
            bgHover = { 0.20, 0.24, 0.30 },
            bgActive = { 0.18, 0.38, 0.58 },
            bgPressed = { 0.12, 0.28, 0.48 },
            border = { 0.28, 0.30, 0.35 },
            borderActive = { 0.35, 0.55, 0.80 },
            icon = { 0.70, 0.73, 0.78 },
            iconHover = { 0.85, 0.88, 0.92 },
            iconActive = { 0.95, 0.98, 1.0 },
        },
        Neon = {
            bg = { 0.06, 0.08, 0.12 },
            bgHover = { 0.10, 0.15, 0.20 },
            bgActive = { 0.0, 0.25, 0.30 },
            bgPressed = { 0.0, 0.18, 0.22 },
            border = { 0.0, 0.5, 0.4 },
            borderActive = { 0.0, 1.0, 0.8 },
            icon = { 0.0, 0.8, 0.6 },
            iconHover = { 0.0, 1.0, 0.8 },
            iconActive = { 0.2, 1.0, 0.9 },
        },
        Velious = {
            bg = { 0.12, 0.16, 0.24 },
            bgHover = { 0.18, 0.25, 0.38 },
            bgActive = { 0.20, 0.40, 0.60 },
            bgPressed = { 0.15, 0.32, 0.50 },
            border = { 0.30, 0.45, 0.65 },
            borderActive = { 0.45, 0.70, 0.95 },
            icon = { 0.65, 0.80, 0.95 },
            iconHover = { 0.80, 0.92, 1.0 },
            iconActive = { 0.90, 0.98, 1.0 },
        },
        Kunark = {
            bg = { 0.18, 0.12, 0.08 },
            bgHover = { 0.28, 0.20, 0.14 },
            bgActive = { 0.50, 0.30, 0.15 },
            bgPressed = { 0.40, 0.22, 0.10 },
            border = { 0.55, 0.38, 0.22 },
            borderActive = { 0.85, 0.55, 0.30 },
            icon = { 0.90, 0.75, 0.55 },
            iconHover = { 1.0, 0.88, 0.70 },
            iconActive = { 1.0, 0.92, 0.80 },
        },
    }

    local colors = baseColors[themeName] or baseColors.Classic

    local bg, border, icon

    if isPressed then
        bg = colors.bgPressed
        border = colors.borderActive
        icon = colors.iconActive
    elseif isActive then
        bg = colors.bgActive
        border = colors.borderActive
        icon = colors.iconActive
    elseif isHovered then
        bg = colors.bgHover
        border = colors.border
        icon = colors.iconHover
    else
        bg = colors.bg
        border = colors.border
        icon = colors.icon
    end

    return bg, border, icon
end

-- ============================================================
-- CORE BUTTON DRAWING
-- ============================================================

function M.draw(icon, tooltip, themeName, opts)
    opts = opts or {}

    local size = opts.size or 28
    local rounding = opts.rounding or 4
    local iconScale = opts.iconScale or 1.0
    local disabled = opts.disabled == true
    local active = opts.active == true

    -- Get cursor position
    local cx, cy = imgui.GetCursorScreenPos()
    if type(cx) == 'table' then
        cy = cx.y or cx[2]
        cx = cx.x or cx[1]
    end

    -- Create invisible button for interaction
    local uniqueId = '##iconbtn_' .. tostring(icon) .. '_' .. tostring(cx) .. '_' .. tostring(cy)
    local clicked = imgui.InvisibleButton(uniqueId, size, size)
    local hovered = imgui.IsItemHovered()
    local held = imgui.IsItemActive()

    if disabled then
        hovered = false
        held = false
        clicked = false
    end

    local dl = imgui.GetWindowDrawList()
    if dl then
        local bgColor, borderColor, iconColor = getButtonColors(themeName, active, hovered, held)

        if disabled then
            -- Dim colors for disabled state
            bgColor = { bgColor[1] * 0.5, bgColor[2] * 0.5, bgColor[3] * 0.5 }
            iconColor = { iconColor[1] * 0.4, iconColor[2] * 0.4, iconColor[3] * 0.4 }
        end

        -- Background
        local bgCol = Draw.IM_COL32(
            math.floor(bgColor[1] * 255),
            math.floor(bgColor[2] * 255),
            math.floor(bgColor[3] * 255),
            220
        )
        Draw.addRectFilled(dl, cx, cy, cx + size, cy + size, bgCol, rounding)

        -- Border
        local borderCol = Draw.IM_COL32(
            math.floor(borderColor[1] * 255),
            math.floor(borderColor[2] * 255),
            math.floor(borderColor[3] * 255),
            180
        )
        Draw.addRect(dl, cx, cy, cx + size, cy + size, borderCol, rounding, 0, 1)

        -- Active indicator (glow)
        if active and not disabled then
            local glowCol = Draw.IM_COL32(
                math.floor(borderColor[1] * 255),
                math.floor(borderColor[2] * 255),
                math.floor(borderColor[3] * 255),
                60
            )
            Draw.addRect(dl, cx - 1, cy - 1, cx + size + 1, cy + size + 1, glowCol, rounding + 1, 0, 2)
        end

        -- Icon
        local iconText = tostring(icon or '?')
        local textW = imgui.CalcTextSize(iconText)
        if type(textW) == 'table' then textW = textW.x or textW[1] or 0 end
        local textH = imgui.GetTextLineHeight()

        local iconX = cx + (size - textW) / 2
        local iconY = cy + (size - textH) / 2

        local iconCol = Draw.IM_COL32(
            math.floor(iconColor[1] * 255),
            math.floor(iconColor[2] * 255),
            math.floor(iconColor[3] * 255),
            disabled and 100 or 255
        )
        Draw.addText(dl, iconX, iconY, iconCol, iconText)
    end

    -- Tooltip
    if hovered and tooltip and tooltip ~= '' then
        imgui.SetTooltip(tostring(tooltip))
    end

    return clicked and not disabled
end

-- ============================================================
-- TOGGLE BUTTON
-- ============================================================

function M.toggle(icon, tooltip, isActive, themeName, opts)
    opts = opts or {}
    opts.active = isActive

    local clicked = M.draw(icon, tooltip, themeName, opts)

    if clicked then
        return not isActive, true  -- new state, changed
    end
    return isActive, false
end

-- ============================================================
-- BUTTON WITH LABEL
-- ============================================================

function M.withLabel(icon, label, themeName, opts)
    opts = opts or {}

    local iconSize = opts.iconSize or 24
    local spacing = opts.spacing or 6
    local rounding = opts.rounding or 4

    -- Calculate total width
    local labelW = imgui.CalcTextSize(label)
    if type(labelW) == 'table' then labelW = labelW.x or labelW[1] or 0 end
    local totalWidth = iconSize + spacing + labelW + 12

    local height = iconSize

    -- Get cursor position
    local cx, cy = imgui.GetCursorScreenPos()
    if type(cx) == 'table' then
        cy = cx.y or cx[2]
        cx = cx.x or cx[1]
    end

    -- Invisible button for interaction
    local uniqueId = '##iconlblbtn_' .. tostring(icon) .. '_' .. tostring(label)
    local clicked = imgui.InvisibleButton(uniqueId, totalWidth, height)
    local hovered = imgui.IsItemHovered()
    local held = imgui.IsItemActive()

    local dl = imgui.GetWindowDrawList()
    if dl then
        local active = opts.active == true
        local bgColor, borderColor, iconColor = getButtonColors(themeName, active, hovered, held)

        -- Background
        local bgCol = Draw.IM_COL32(
            math.floor(bgColor[1] * 255),
            math.floor(bgColor[2] * 255),
            math.floor(bgColor[3] * 255),
            220
        )
        Draw.addRectFilled(dl, cx, cy, cx + totalWidth, cy + height, bgCol, rounding)

        -- Border
        local borderCol = Draw.IM_COL32(
            math.floor(borderColor[1] * 255),
            math.floor(borderColor[2] * 255),
            math.floor(borderColor[3] * 255),
            180
        )
        Draw.addRect(dl, cx, cy, cx + totalWidth, cy + height, borderCol, rounding, 0, 1)

        -- Icon
        local iconText = tostring(icon or '?')
        local iconW = imgui.CalcTextSize(iconText)
        if type(iconW) == 'table' then iconW = iconW.x or iconW[1] or 0 end
        local textH = imgui.GetTextLineHeight()

        local iconX = cx + 6
        local iconY = cy + (height - textH) / 2

        local iconCol = Draw.IM_COL32(
            math.floor(iconColor[1] * 255),
            math.floor(iconColor[2] * 255),
            math.floor(iconColor[3] * 255),
            255
        )
        Draw.addText(dl, iconX, iconY, iconCol, iconText)

        -- Label
        local labelX = cx + 6 + iconW + spacing
        local labelY = cy + (height - textH) / 2

        local textCol = Colors.text(themeName)
        local labelCol = Draw.IM_COL32(
            math.floor(textCol[1] * 255),
            math.floor(textCol[2] * 255),
            math.floor(textCol[3] * 255),
            255
        )
        Draw.addText(dl, labelX, labelY, labelCol, tostring(label))
    end

    return clicked
end

-- ============================================================
-- BUTTON GROUP (toolbar)
-- ============================================================

function M.group(buttons, themeName, opts)
    opts = opts or {}
    local spacing = opts.spacing or 2
    local vertical = opts.vertical == true

    local results = {}

    for i, btn in ipairs(buttons) do
        if i > 1 then
            if vertical then
                -- Vertical spacing handled by imgui
            else
                imgui.SameLine(0, spacing)
            end
        end

        local icon = btn.icon or btn[1]
        local tooltip = btn.tooltip or btn[2]
        local btnOpts = btn.opts or btn[3] or {}

        -- Merge group opts with button opts
        for k, v in pairs(opts) do
            if btnOpts[k] == nil then
                btnOpts[k] = v
            end
        end

        local clicked = M.draw(icon, tooltip, themeName, btnOpts)
        table.insert(results, { clicked = clicked, icon = icon })
    end

    return results
end

-- ============================================================
-- RADIO BUTTON GROUP
-- ============================================================

function M.radio(buttons, selectedIndex, themeName, opts)
    opts = opts or {}
    local spacing = opts.spacing or 2

    local newIndex = selectedIndex

    for i, btn in ipairs(buttons) do
        if i > 1 then
            imgui.SameLine(0, spacing)
        end

        local icon = btn.icon or btn[1]
        local tooltip = btn.tooltip or btn[2]
        local btnOpts = btn.opts or {}

        btnOpts.active = (i == selectedIndex)

        if M.draw(icon, tooltip, themeName, btnOpts) then
            newIndex = i
        end
    end

    return newIndex, newIndex ~= selectedIndex
end

-- ============================================================
-- CIRCULAR BUTTON
-- ============================================================

function M.circular(icon, tooltip, themeName, opts)
    opts = opts or {}

    local radius = opts.radius or 14
    local size = radius * 2
    local disabled = opts.disabled == true
    local active = opts.active == true

    -- Get cursor position
    local cx, cy = imgui.GetCursorScreenPos()
    if type(cx) == 'table' then
        cy = cx.y or cx[2]
        cx = cx.x or cx[1]
    end

    -- Invisible button
    local uniqueId = '##circbtn_' .. tostring(icon)
    local clicked = imgui.InvisibleButton(uniqueId, size, size)
    local hovered = imgui.IsItemHovered()
    local held = imgui.IsItemActive()

    if disabled then
        hovered = false
        held = false
        clicked = false
    end

    local dl = imgui.GetWindowDrawList()
    if dl then
        local bgColor, borderColor, iconColor = getButtonColors(themeName, active, hovered, held)

        local centerX = cx + radius
        local centerY = cy + radius

        -- Background circle
        local bgCol = Draw.IM_COL32(
            math.floor(bgColor[1] * 255),
            math.floor(bgColor[2] * 255),
            math.floor(bgColor[3] * 255),
            220
        )
        Draw.addCircleFilled(dl, centerX, centerY, radius, bgCol, 16)

        -- Border
        local borderCol = Draw.IM_COL32(
            math.floor(borderColor[1] * 255),
            math.floor(borderColor[2] * 255),
            math.floor(borderColor[3] * 255),
            180
        )
        Draw.addCircle(dl, centerX, centerY, radius, borderCol, 16, 1)

        -- Icon
        local iconText = tostring(icon or '?')
        local textW = imgui.CalcTextSize(iconText)
        if type(textW) == 'table' then textW = textW.x or textW[1] or 0 end
        local textH = imgui.GetTextLineHeight()

        local iconX = centerX - textW / 2
        local iconY = centerY - textH / 2

        local iconCol = Draw.IM_COL32(
            math.floor(iconColor[1] * 255),
            math.floor(iconColor[2] * 255),
            math.floor(iconColor[3] * 255),
            disabled and 100 or 255
        )
        Draw.addText(dl, iconX, iconY, iconCol, iconText)
    end

    -- Tooltip
    if hovered and tooltip then
        imgui.SetTooltip(tostring(tooltip))
    end

    return clicked and not disabled
end

return M
