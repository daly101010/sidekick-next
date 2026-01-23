-- ============================================================
-- SideKick Keybind Badge Component
-- ============================================================
-- Stylized keyboard shortcut indicators showing hotkeys
-- in a keyboard-key visual style.
--
-- Usage:
--   local Keybind = require('sidekick-next.ui.components.keybind_badge')
--   Keybind.draw('F1', 'Classic')
--   Keybind.combo({'Ctrl', 'S'}, 'Classic')
--   Keybind.inline('Esc', 'to cancel', 'Classic')

local imgui = require('ImGui')
local Draw = require('sidekick-next.ui.draw_helpers')
local Colors = require('sidekick-next.ui.colors')

local M = {}

-- ============================================================
-- KEY STYLING
-- ============================================================

-- Common key abbreviations
local KEY_ALIASES = {
    ['control'] = 'Ctrl',
    ['ctrl'] = 'Ctrl',
    ['shift'] = 'Shift',
    ['alt'] = 'Alt',
    ['escape'] = 'Esc',
    ['enter'] = 'Enter',
    ['return'] = 'Enter',
    ['space'] = 'Space',
    ['backspace'] = 'Bksp',
    ['delete'] = 'Del',
    ['insert'] = 'Ins',
    ['home'] = 'Home',
    ['end'] = 'End',
    ['pageup'] = 'PgUp',
    ['pagedown'] = 'PgDn',
    ['uparrow'] = '↑',
    ['downarrow'] = '↓',
    ['leftarrow'] = '←',
    ['rightarrow'] = '→',
    ['up'] = '↑',
    ['down'] = '↓',
    ['left'] = '←',
    ['right'] = '→',
    ['tab'] = 'Tab',
    ['capslock'] = 'Caps',
}

-- Key width multipliers for special keys
local KEY_WIDTHS = {
    ['Space'] = 2.5,
    ['Enter'] = 1.5,
    ['Shift'] = 1.3,
    ['Ctrl'] = 1.2,
    ['Backspace'] = 1.5,
    ['Tab'] = 1.2,
}

-- ============================================================
-- HELPER FUNCTIONS
-- ============================================================

local function normalizeKey(key)
    if not key then return '' end
    local lower = string.lower(tostring(key))
    return KEY_ALIASES[lower] or tostring(key)
end

local function getKeyWidth(key, baseWidth)
    local multiplier = KEY_WIDTHS[key] or 1.0
    return baseWidth * multiplier
end

local function getThemeColors(themeName)
    -- Key cap colors
    local keyColors = {
        Classic = {
            bg = { 0.18, 0.20, 0.24 },
            top = { 0.25, 0.28, 0.32 },
            border = { 0.35, 0.38, 0.42 },
            text = { 0.9, 0.92, 0.95 },
            shadow = { 0.08, 0.08, 0.10 },
        },
        Dark = {
            bg = { 0.12, 0.14, 0.18 },
            top = { 0.18, 0.20, 0.24 },
            border = { 0.28, 0.30, 0.35 },
            text = { 0.85, 0.88, 0.92 },
            shadow = { 0.05, 0.05, 0.07 },
        },
        Neon = {
            bg = { 0.08, 0.12, 0.15 },
            top = { 0.12, 0.18, 0.22 },
            border = { 0.0, 0.8, 0.6 },
            text = { 0.0, 1.0, 0.8 },
            shadow = { 0.02, 0.06, 0.08 },
        },
        Velious = {
            bg = { 0.15, 0.18, 0.25 },
            top = { 0.20, 0.25, 0.35 },
            border = { 0.35, 0.50, 0.70 },
            text = { 0.8, 0.9, 1.0 },
            shadow = { 0.05, 0.08, 0.12 },
        },
        Kunark = {
            bg = { 0.20, 0.15, 0.10 },
            top = { 0.28, 0.20, 0.14 },
            border = { 0.60, 0.40, 0.25 },
            text = { 1.0, 0.9, 0.8 },
            shadow = { 0.10, 0.06, 0.04 },
        },
    }
    return keyColors[themeName] or keyColors.Classic
end

-- ============================================================
-- SINGLE KEY DRAWING
-- ============================================================

function M.draw(key, themeName, opts)
    opts = opts or {}

    local minWidth = opts.minWidth or 24
    local height = opts.height or 22
    local paddingH = opts.paddingH or 6
    local rounding = opts.rounding or 4
    local depthOffset = opts.depthOffset or 3

    -- Normalize key name
    key = normalizeKey(key)
    if key == '' then
        imgui.Dummy(minWidth, height)
        return false
    end

    -- Calculate width
    local textW = imgui.CalcTextSize(key)
    if type(textW) == 'table' then textW = textW.x or textW[1] or 0 end
    local width = math.max(minWidth, textW + paddingH * 2)
    width = getKeyWidth(key, width)

    -- Get colors
    local colors = getThemeColors(themeName or 'Classic')

    -- Get cursor position
    local cx, cy = imgui.GetCursorScreenPos()
    if type(cx) == 'table' then
        cy = cx.y or cx[2]
        cx = cx.x or cx[1]
    end

    local dl = imgui.GetWindowDrawList()
    if not dl then
        imgui.Dummy(width, height)
        return false
    end

    -- Shadow (bottom of key)
    local shadowCol = Draw.IM_COL32(
        math.floor(colors.shadow[1] * 255),
        math.floor(colors.shadow[2] * 255),
        math.floor(colors.shadow[3] * 255),
        200
    )
    Draw.addRectFilled(dl,
        cx + 1, cy + depthOffset,
        cx + width - 1, cy + height,
        shadowCol, rounding
    )

    -- Key base (sides)
    local bgCol = Draw.IM_COL32(
        math.floor(colors.bg[1] * 255),
        math.floor(colors.bg[2] * 255),
        math.floor(colors.bg[3] * 255),
        255
    )
    Draw.addRectFilled(dl,
        cx, cy,
        cx + width, cy + height - depthOffset,
        bgCol, rounding
    )

    -- Key top (lighter)
    local topCol = Draw.IM_COL32(
        math.floor(colors.top[1] * 255),
        math.floor(colors.top[2] * 255),
        math.floor(colors.top[3] * 255),
        255
    )
    Draw.addRectFilled(dl,
        cx + 2, cy + 2,
        cx + width - 2, cy + height - depthOffset - 2,
        topCol, rounding - 1
    )

    -- Border
    local borderCol = Draw.IM_COL32(
        math.floor(colors.border[1] * 255),
        math.floor(colors.border[2] * 255),
        math.floor(colors.border[3] * 255),
        150
    )
    Draw.addRect(dl,
        cx, cy,
        cx + width, cy + height - depthOffset,
        borderCol, rounding, 0, 1
    )

    -- Text (centered on top face)
    local textCol = Draw.IM_COL32(
        math.floor(colors.text[1] * 255),
        math.floor(colors.text[2] * 255),
        math.floor(colors.text[3] * 255),
        255
    )
    local textX = cx + (width - textW) / 2
    local textY = cy + (height - depthOffset - imgui.GetTextLineHeight()) / 2
    Draw.addText(dl, textX, textY, textCol, key)

    -- Reserve space
    imgui.Dummy(width, height)

    return imgui.IsItemHovered()
end

-- ============================================================
-- KEY COMBINATION
-- ============================================================

function M.combo(keys, themeName, opts)
    opts = opts or {}
    local separator = opts.separator or '+'
    local spacing = opts.spacing or 4

    if type(keys) == 'string' then
        -- Parse string like "Ctrl+S"
        keys = {}
        for part in string.gmatch(keys, '[^+]+') do
            table.insert(keys, part:match('^%s*(.-)%s*$'))  -- Trim whitespace
        end
    end

    if not keys or #keys == 0 then return end

    local results = {}
    for i, key in ipairs(keys) do
        if i > 1 then
            imgui.SameLine(0, spacing)

            -- Draw separator
            local textCol = Colors.textDim(themeName)
            imgui.TextColored(textCol[1], textCol[2], textCol[3], 1, separator)
            imgui.SameLine(0, spacing)
        end

        local hovered = M.draw(key, themeName, opts)
        table.insert(results, hovered)
    end

    return results
end

-- ============================================================
-- INLINE WITH DESCRIPTION
-- ============================================================

function M.inline(keys, description, themeName, opts)
    opts = opts or {}

    -- Draw key(s)
    if type(keys) == 'table' then
        M.combo(keys, themeName, opts)
    else
        M.draw(keys, themeName, opts)
    end

    -- Draw description
    if description and description ~= '' then
        imgui.SameLine(0, 8)
        local textCol = Colors.text(themeName)
        imgui.TextColored(textCol[1], textCol[2], textCol[3], 1, tostring(description))
    end
end

-- ============================================================
-- COMPACT BADGE STYLE
-- ============================================================

function M.badge(key, themeName, opts)
    opts = opts or {}
    opts.height = opts.height or 18
    opts.minWidth = opts.minWidth or 18
    opts.paddingH = opts.paddingH or 4
    opts.depthOffset = opts.depthOffset or 2
    opts.rounding = opts.rounding or 3

    return M.draw(key, themeName, opts)
end

-- ============================================================
-- SMALL PILL STYLE
-- ============================================================

function M.pill(key, themeName, opts)
    opts = opts or {}

    key = normalizeKey(key)
    if key == '' then return false end

    local paddingH = opts.paddingH or 6
    local paddingV = opts.paddingV or 2

    -- Calculate size
    local textW = imgui.CalcTextSize(key)
    if type(textW) == 'table' then textW = textW.x or textW[1] or 0 end
    local textH = imgui.GetTextLineHeight()

    local width = textW + paddingH * 2
    local height = textH + paddingV * 2
    local rounding = height / 2

    local colors = getThemeColors(themeName or 'Classic')

    -- Get cursor position
    local cx, cy = imgui.GetCursorScreenPos()
    if type(cx) == 'table' then
        cy = cx.y or cx[2]
        cx = cx.x or cx[1]
    end

    local dl = imgui.GetWindowDrawList()
    if not dl then
        imgui.Dummy(width, height)
        return false
    end

    -- Background
    local bgCol = Draw.IM_COL32(
        math.floor(colors.bg[1] * 255),
        math.floor(colors.bg[2] * 255),
        math.floor(colors.bg[3] * 255),
        220
    )
    Draw.addRectFilled(dl, cx, cy, cx + width, cy + height, bgCol, rounding)

    -- Border
    local borderCol = Draw.IM_COL32(
        math.floor(colors.border[1] * 255),
        math.floor(colors.border[2] * 255),
        math.floor(colors.border[3] * 255),
        150
    )
    Draw.addRect(dl, cx, cy, cx + width, cy + height, borderCol, rounding, 0, 1)

    -- Text
    local textCol = Draw.IM_COL32(
        math.floor(colors.text[1] * 255),
        math.floor(colors.text[2] * 255),
        math.floor(colors.text[3] * 255),
        255
    )
    local textX = cx + paddingH
    local textY = cy + paddingV
    Draw.addText(dl, textX, textY, textCol, key)

    imgui.Dummy(width, height)
    return imgui.IsItemHovered()
end

-- ============================================================
-- ACTION HINT (key + action description)
-- ============================================================

function M.actionHint(key, action, themeName, opts)
    opts = opts or {}

    -- Smaller key style for hints
    opts.height = opts.height or 18
    opts.minWidth = opts.minWidth or 20
    opts.depthOffset = opts.depthOffset or 2

    M.draw(key, themeName, opts)
    imgui.SameLine(0, 6)

    local textCol = Colors.textDim(themeName)
    imgui.TextColored(textCol[1], textCol[2], textCol[3], 1, tostring(action or ''))
end

-- ============================================================
-- MOUSE BUTTON INDICATORS
-- ============================================================

function M.mouseLeft(themeName, opts)
    return M.draw('LMB', themeName, opts)
end

function M.mouseRight(themeName, opts)
    return M.draw('RMB', themeName, opts)
end

function M.mouseMiddle(themeName, opts)
    return M.draw('MMB', themeName, opts)
end

function M.mouseWheel(direction, themeName, opts)
    direction = direction or 'up'
    local text = direction == 'up' and '⊛↑' or '⊛↓'
    return M.draw(text, themeName, opts)
end

return M
