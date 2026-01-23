-- ============================================================
-- SideKick Status Badge Component
-- ============================================================
-- Compact status indicators for buffs, debuffs, ready states,
-- and other status information.
--
-- Usage:
--   local Badge = require('sidekick-next.ui.components.status_badge')
--   Badge.ready('Ready', 'Classic')
--   Badge.cooldown('5.2s', 'Classic')
--   Badge.buff('Haste', 'Classic')
--   Badge.debuff('Poisoned', 'Classic')
--   Badge.custom('Tanking', { 0.8, 0.6, 0.2 }, 'Classic')

local imgui = require('ImGui')
local Draw = require('sidekick-next.ui.draw_helpers')
local Colors = require('sidekick-next.ui.colors')

local M = {}

-- ============================================================
-- BADGE STYLE DEFINITIONS
-- ============================================================

local BADGE_STYLES = {
    ready = {
        bg = { 0.2, 0.6, 0.3 },
        text = { 0.9, 1.0, 0.9 },
        border = { 0.3, 0.8, 0.4 },
        icon = '+',
    },
    cooldown = {
        bg = { 0.5, 0.3, 0.2 },
        text = { 1.0, 0.9, 0.8 },
        border = { 0.7, 0.4, 0.3 },
        icon = '-',
    },
    buff = {
        bg = { 0.2, 0.4, 0.6 },
        text = { 0.9, 0.95, 1.0 },
        border = { 0.3, 0.5, 0.8 },
        icon = '^',
    },
    debuff = {
        bg = { 0.6, 0.2, 0.2 },
        text = { 1.0, 0.9, 0.9 },
        border = { 0.8, 0.3, 0.3 },
        icon = '!',
    },
    warning = {
        bg = { 0.6, 0.5, 0.2 },
        text = { 1.0, 0.95, 0.85 },
        border = { 0.8, 0.7, 0.3 },
        icon = '!',
    },
    info = {
        bg = { 0.25, 0.35, 0.45 },
        text = { 0.9, 0.95, 1.0 },
        border = { 0.4, 0.5, 0.6 },
        icon = 'i',
    },
    success = {
        bg = { 0.2, 0.5, 0.3 },
        text = { 0.9, 1.0, 0.9 },
        border = { 0.3, 0.7, 0.4 },
        icon = '*',
    },
    error = {
        bg = { 0.55, 0.15, 0.15 },
        text = { 1.0, 0.9, 0.9 },
        border = { 0.8, 0.25, 0.25 },
        icon = 'X',
    },
    neutral = {
        bg = { 0.3, 0.3, 0.3 },
        text = { 0.9, 0.9, 0.9 },
        border = { 0.5, 0.5, 0.5 },
        icon = '-',
    },
}

-- ============================================================
-- HELPER FUNCTIONS
-- ============================================================

local function getStyleColors(styleType)
    return BADGE_STYLES[styleType] or BADGE_STYLES.neutral
end

-- ============================================================
-- CORE BADGE DRAWING
-- ============================================================

function M.draw(text, styleType, themeName, opts)
    opts = opts or {}

    -- Parameters
    local paddingH = opts.paddingH or 6
    local paddingV = opts.paddingV or 2
    local rounding = opts.rounding or 4
    local showIcon = opts.showIcon ~= false
    local minWidth = opts.minWidth or 0
    local pulsing = opts.pulsing == true

    -- Get style
    local style = getStyleColors(styleType)
    local bgColor = opts.bgColor or style.bg
    local textColor = opts.textColor or style.text
    local borderColor = opts.borderColor or style.border
    local icon = opts.icon or style.icon

    -- Build display text
    local displayText = tostring(text or '')
    if showIcon and icon then
        displayText = icon .. ' ' .. displayText
    end

    -- Calculate size
    local textW = imgui.CalcTextSize(displayText)
    if type(textW) == 'table' then textW = textW.x or textW[1] or 0 end
    local textH = imgui.GetTextLineHeight()

    local width = math.max(minWidth, textW + paddingH * 2)
    local height = textH + paddingV * 2

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

    -- Pulsing effect
    local alpha = 1.0
    if pulsing then
        local t = os.clock() * 3
        alpha = 0.7 + 0.3 * math.sin(t)
    end

    -- Background
    local bgCol = Draw.IM_COL32(
        math.floor(bgColor[1] * 255),
        math.floor(bgColor[2] * 255),
        math.floor(bgColor[3] * 255),
        math.floor(alpha * 220)
    )
    Draw.addRectFilled(dl, cx, cy, cx + width, cy + height, bgCol, rounding)

    -- Border
    local borderCol = Draw.IM_COL32(
        math.floor(borderColor[1] * 255),
        math.floor(borderColor[2] * 255),
        math.floor(borderColor[3] * 255),
        math.floor(alpha * 180)
    )
    Draw.addRect(dl, cx, cy, cx + width, cy + height, borderCol, rounding, 0, 1)

    -- Text (centered)
    local textX = cx + (width - textW) / 2
    local textY = cy + paddingV

    local txtCol = Draw.IM_COL32(
        math.floor(textColor[1] * 255),
        math.floor(textColor[2] * 255),
        math.floor(textColor[3] * 255),
        math.floor(alpha * 255)
    )
    Draw.addText(dl, textX, textY, txtCol, displayText)

    -- Reserve space and handle interaction
    imgui.Dummy(width, height)
    local hovered = imgui.IsItemHovered()
    local clicked = imgui.IsItemClicked()

    return clicked, hovered
end

-- ============================================================
-- SPECIALIZED BADGE TYPES
-- ============================================================

function M.ready(text, themeName, opts)
    opts = opts or {}
    opts.pulsing = opts.pulsing == nil and true or opts.pulsing
    return M.draw(text or 'Ready', 'ready', themeName, opts)
end

function M.cooldown(text, themeName, opts)
    return M.draw(text or 'CD', 'cooldown', themeName, opts)
end

function M.buff(text, themeName, opts)
    return M.draw(text or 'Buff', 'buff', themeName, opts)
end

function M.debuff(text, themeName, opts)
    opts = opts or {}
    opts.pulsing = opts.pulsing == nil and true or opts.pulsing
    return M.draw(text or 'Debuff', 'debuff', themeName, opts)
end

function M.warning(text, themeName, opts)
    opts = opts or {}
    opts.pulsing = opts.pulsing == nil and true or opts.pulsing
    return M.draw(text or 'Warning', 'warning', themeName, opts)
end

function M.info(text, themeName, opts)
    return M.draw(text or 'Info', 'info', themeName, opts)
end

function M.success(text, themeName, opts)
    return M.draw(text or 'Success', 'success', themeName, opts)
end

function M.error(text, themeName, opts)
    opts = opts or {}
    opts.pulsing = opts.pulsing == nil and true or opts.pulsing
    return M.draw(text or 'Error', 'error', themeName, opts)
end

function M.neutral(text, themeName, opts)
    return M.draw(text or '', 'neutral', themeName, opts)
end

-- Custom badge with specified color
function M.custom(text, color, themeName, opts)
    opts = opts or {}
    opts.bgColor = color
    opts.textColor = { 1, 1, 1 }
    opts.borderColor = {
        math.min(1, color[1] * 1.3),
        math.min(1, color[2] * 1.3),
        math.min(1, color[3] * 1.3),
    }
    return M.draw(text, 'neutral', themeName, opts)
end

-- ============================================================
-- BADGE GROUP (multiple badges in a row)
-- ============================================================

function M.group(badges, themeName, opts)
    opts = opts or {}
    local spacing = opts.spacing or 4

    local results = {}
    for i, badge in ipairs(badges) do
        if i > 1 then
            imgui.SameLine(0, spacing)
        end

        local text = badge.text or badge[1]
        local styleType = badge.style or badge[2] or 'neutral'
        local badgeOpts = badge.opts or badge[3] or {}

        local clicked, hovered = M.draw(text, styleType, themeName, badgeOpts)
        table.insert(results, { clicked = clicked, hovered = hovered })
    end

    return results
end

-- ============================================================
-- INLINE BADGE (draws next to current item)
-- ============================================================

function M.inline(text, styleType, themeName, opts)
    imgui.SameLine()
    return M.draw(text, styleType, themeName, opts)
end

-- ============================================================
-- PILL-STYLE BADGES (more rounded)
-- ============================================================

function M.pill(text, styleType, themeName, opts)
    opts = opts or {}
    opts.rounding = opts.rounding or 10
    opts.paddingH = opts.paddingH or 10
    return M.draw(text, styleType, themeName, opts)
end

function M.pillReady(text, themeName, opts)
    opts = opts or {}
    opts.rounding = opts.rounding or 10
    opts.paddingH = opts.paddingH or 10
    return M.ready(text, themeName, opts)
end

-- ============================================================
-- COUNT BADGE (for notification counts)
-- ============================================================

function M.count(number, styleType, themeName, opts)
    opts = opts or {}
    local num = tonumber(number) or 0

    -- Format number
    local text
    if num > 99 then
        text = '99+'
    else
        text = tostring(num)
    end

    opts.showIcon = false
    opts.minWidth = 20
    opts.rounding = 10
    opts.paddingH = 4

    return M.draw(text, styleType or 'info', themeName, opts)
end

-- ============================================================
-- DOT INDICATOR (minimal status dot)
-- ============================================================

function M.dot(styleType, themeName, opts)
    opts = opts or {}
    local size = opts.size or 8
    local pulsing = opts.pulsing == true

    local style = getStyleColors(styleType or 'neutral')
    local color = opts.color or style.bg

    -- Get cursor position
    local cx, cy = imgui.GetCursorScreenPos()
    if type(cx) == 'table' then
        cy = cx.y or cx[2]
        cx = cx.x or cx[1]
    end

    local dl = imgui.GetWindowDrawList()
    if not dl then
        imgui.Dummy(size, size)
        return false
    end

    -- Calculate center
    local centerX = cx + size / 2
    local centerY = cy + size / 2

    -- Pulsing effect
    local alpha = 1.0
    local radius = size / 2
    if pulsing then
        local t = os.clock() * 3
        alpha = 0.7 + 0.3 * math.sin(t)
        radius = radius * (0.9 + 0.1 * math.sin(t))
    end

    -- Draw dot
    local dotCol = Draw.IM_COL32(
        math.floor(color[1] * 255),
        math.floor(color[2] * 255),
        math.floor(color[3] * 255),
        math.floor(alpha * 255)
    )
    Draw.addCircleFilled(dl, centerX, centerY, radius, dotCol, 12)

    -- Draw glow ring when pulsing
    if pulsing then
        local glowCol = Draw.IM_COL32(
            math.floor(color[1] * 255),
            math.floor(color[2] * 255),
            math.floor(color[3] * 255),
            math.floor(alpha * 0.3 * 255)
        )
        Draw.addCircle(dl, centerX, centerY, radius + 2, glowCol, 12, 2)
    end

    imgui.Dummy(size, size)
    return imgui.IsItemHovered()
end

-- ============================================================
-- STATUS DOTS (ready/cooldown indicator)
-- ============================================================

function M.statusDot(isReady, themeName, opts)
    opts = opts or {}
    if isReady then
        opts.pulsing = true
        return M.dot('ready', themeName, opts)
    else
        return M.dot('cooldown', themeName, opts)
    end
end

return M
