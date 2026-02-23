-- ============================================================
-- SideKick Resource Bar Component
-- ============================================================
-- Reusable health/mana/endurance bars with theme support,
-- gradients, and optional text overlays.
--
-- Usage:
--   local ResourceBar = require('sidekick-next.ui.components.resource_bar')
--   ResourceBar.health(currentHP, maxHP, { width = 100, height = 12 })
--   ResourceBar.mana(currentMana, maxMana, { showPercent = true })
--   ResourceBar.custom(value, max, { color = { 0.8, 0.5, 0.2 } })

local imgui = require('ImGui')
local Draw = require('sidekick-next.ui.draw_helpers')
local Colors = require('sidekick-next.ui.colors')
local AnimHelpers = require('sidekick-next.ui.animation_helpers')

local M = {}

-- Lazy-loaded themes module for textured rendering
local _Themes = nil
local function getThemes()
    if not _Themes then
        local ok, t = pcall(require, 'sidekick-next.themes')
        if ok then _Themes = t end
    end
    return _Themes
end

-- ============================================================
-- COLOR DEFINITIONS
-- ============================================================

-- Health bar colors by percentage
local HEALTH_COLORS = {
    { threshold = 0.75, color = { 0.2, 0.8, 0.2 } },   -- Green (healthy)
    { threshold = 0.50, color = { 0.7, 0.8, 0.2 } },   -- Yellow-green
    { threshold = 0.25, color = { 0.9, 0.6, 0.2 } },   -- Orange
    { threshold = 0.00, color = { 0.9, 0.2, 0.2 } },   -- Red (critical)
}

-- Resource type colors
local RESOURCE_COLORS = {
    health = nil,  -- Uses gradient based on percentage
    mana = { 0.2, 0.4, 0.9 },      -- Blue
    endurance = { 0.9, 0.7, 0.2 }, -- Yellow/gold
    experience = { 0.6, 0.2, 0.8 }, -- Purple
    aggro = nil,  -- Uses gradient based on percentage
}

-- Aggro colors by percentage
local AGGRO_COLORS = {
    { threshold = 0.80, color = { 0.9, 0.2, 0.2 } },   -- Red (high aggro)
    { threshold = 0.50, color = { 0.9, 0.6, 0.2 } },   -- Orange
    { threshold = 0.00, color = { 0.5, 0.5, 0.5 } },   -- Gray (safe)
}

-- ============================================================
-- HELPER FUNCTIONS
-- ============================================================

local function getColorForPercent(pct, colorTable)
    pct = math.max(0, math.min(1, pct or 0))
    for _, entry in ipairs(colorTable) do
        if pct >= entry.threshold then
            return entry.color
        end
    end
    return colorTable[#colorTable].color
end

local function lerpColor(c1, c2, t)
    t = math.max(0, math.min(1, t))
    return {
        c1[1] + (c2[1] - c1[1]) * t,
        c1[2] + (c2[2] - c1[2]) * t,
        c1[3] + (c2[3] - c1[3]) * t,
    }
end

local function getHealthColor(pct)
    pct = math.max(0, math.min(1, pct or 0))

    -- Find the two colors to interpolate between
    local upper, lower
    for i, entry in ipairs(HEALTH_COLORS) do
        if pct >= entry.threshold then
            upper = entry
            lower = HEALTH_COLORS[i + 1] or entry
            break
        end
    end

    if not upper then
        return HEALTH_COLORS[#HEALTH_COLORS].color
    end

    -- Interpolate
    local range = upper.threshold - lower.threshold
    if range <= 0 then return upper.color end
    local t = (pct - lower.threshold) / range
    return lerpColor(lower.color, upper.color, t)
end

local function getAggroColor(pct)
    return getColorForPercent(pct, AGGRO_COLORS)
end

-- ============================================================
-- CORE BAR DRAWING
-- ============================================================

function M.draw(current, max, opts)
    opts = opts or {}

    -- Parameters
    local width = opts.width or 100
    local height = opts.height or 12
    local color = opts.color
    local bgColor = opts.bgColor or { 0.15, 0.15, 0.15 }
    local borderColor = opts.borderColor
    local rounding = opts.rounding or 2
    local showText = opts.showText
    local showPercent = opts.showPercent
    local textColor = opts.textColor or { 1, 1, 1 }
    local gradient = opts.gradient ~= false
    local vertical = opts.vertical == true
    local reversed = opts.reversed == true  -- Fill from right/top
    local themeName = opts.theme
    local barType = opts.barType or 'health'

    -- Calculate percentage
    current = tonumber(current) or 0
    max = tonumber(max) or 1
    local pct = max > 0 and (current / max) or 0
    pct = math.max(0, math.min(1, pct))

    -- Default color if not provided
    if not color then
        color = { 0.4, 0.7, 0.4 }
    end

    -- Get cursor position
    local cx, cy = imgui.GetCursorScreenPos()
    if type(cx) == 'table' then
        cy = cx.y or cx[2]
        cx = cx.x or cx[1]
    end

    -- Apply shake offset if provided (for damage shake on HP bars)
    local shakeX = opts.shakeX or 0
    local shakeY = opts.shakeY or 0
    cx = cx + shakeX
    cy = cy + shakeY

    local dl = imgui.GetWindowDrawList()
    if not dl then
        imgui.Dummy(width, height)
        return
    end

    -- Try textured rendering if theme supports it (completely isolated in pcall)
    local texturedSuccess = false
    pcall(function()
        if not themeName or vertical then return end
        local Themes = getThemes()
        if not Themes or not Themes.isTexturedTheme then return end
        if not Themes.isTexturedTheme(themeName) then return end

        local TextureRenderer = Draw.getTextureRenderer and Draw.getTextureRenderer()
        if not TextureRenderer then return end
        if TextureRenderer.isAvailable and not TextureRenderer.isAvailable() then return end

        local drawResult = TextureRenderer.drawClassicGauge(dl, cx, cy, width, height, pct, barType)
        if not drawResult then return end

        -- Reserve space
        imgui.Dummy(width, height)

        -- Draw text overlay if needed
        if showText or showPercent then
            local text
            if showPercent then
                text = string.format('%d%%', math.floor(pct * 100))
            elseif showText == true then
                text = string.format('%d/%d', math.floor(current), math.floor(max))
            else
                text = tostring(showText)
            end

            local textW = imgui.CalcTextSize(text)
            if type(textW) == 'table' then textW = textW.x or textW[1] or 0 end
            local textX = cx + (width - textW) / 2
            local textY = cy + (height - imgui.GetTextLineHeight()) / 2

            Draw.addText(dl, textX + 1, textY + 1, Draw.IM_COL32(0, 0, 0, 200), text)
            Draw.addText(dl, textX, textY, Draw.IM_COL32(
                math.floor(textColor[1] * 255),
                math.floor(textColor[2] * 255),
                math.floor(textColor[3] * 255),
                255
            ), text)
        end

        texturedSuccess = true
    end)

    if texturedSuccess then
        return
    end

    -- Background
    local bgCol = Draw.IM_COL32(
        math.floor(bgColor[1] * 255),
        math.floor(bgColor[2] * 255),
        math.floor(bgColor[3] * 255),
        200
    )
    Draw.addRectFilled(dl, cx, cy, cx + width, cy + height, bgCol, rounding)

    -- Fill bar
    if pct > 0 then
        local fillCol = Draw.IM_COL32(
            math.floor(color[1] * 255),
            math.floor(color[2] * 255),
            math.floor(color[3] * 255),
            230
        )

        if vertical then
            local fillH = height * pct
            if reversed then
                Draw.addRectFilled(dl, cx, cy, cx + width, cy + fillH, fillCol, rounding)
            else
                Draw.addRectFilled(dl, cx, cy + height - fillH, cx + width, cy + height, fillCol, rounding)
            end
        else
            local fillW = width * pct
            if reversed then
                Draw.addRectFilled(dl, cx + width - fillW, cy, cx + width, cy + height, fillCol, rounding)
            else
                Draw.addRectFilled(dl, cx, cy, cx + fillW, cy + height, fillCol, rounding)
            end
        end

        -- Gradient highlight (lighter at top)
        if gradient and height >= 6 then
            local highlightH = math.floor(height * 0.4)
            local highlightCol = Draw.IM_COL32(255, 255, 255, 30)
            if vertical then
                local fillH = height * pct
                if reversed then
                    Draw.addRectFilled(dl, cx, cy, cx + math.floor(width * 0.4), cy + fillH, highlightCol, rounding)
                else
                    Draw.addRectFilled(dl, cx, cy + height - fillH, cx + math.floor(width * 0.4), cy + height, highlightCol, rounding)
                end
            else
                local fillW = width * pct
                if reversed then
                    Draw.addRectFilled(dl, cx + width - fillW, cy, cx + width, cy + highlightH, highlightCol, rounding)
                else
                    Draw.addRectFilled(dl, cx, cy, cx + fillW, cy + highlightH, highlightCol, rounding)
                end
            end
        end
    end

    -- Border
    if borderColor then
        local borderCol = Draw.IM_COL32(
            math.floor(borderColor[1] * 255),
            math.floor(borderColor[2] * 255),
            math.floor(borderColor[3] * 255),
            180
        )
        Draw.addRect(dl, cx, cy, cx + width, cy + height, borderCol, rounding, 0, 1)
    end

    -- Reserve space
    imgui.Dummy(width, height)

    -- Text overlay
    if showText or showPercent then
        local text
        if showPercent then
            text = string.format('%d%%', math.floor(pct * 100))
        elseif showText == true then
            text = string.format('%d/%d', math.floor(current), math.floor(max))
        else
            text = tostring(showText)
        end

        -- Center text on bar
        local textW = imgui.CalcTextSize(text)
        if type(textW) == 'table' then textW = textW.x or textW[1] or 0 end
        local textX = cx + (width - textW) / 2
        local textY = cy + (height - imgui.GetTextLineHeight()) / 2

        -- Draw with outline for readability
        Draw.addText(dl, textX + 1, textY + 1, Draw.IM_COL32(0, 0, 0, 200), text)
        Draw.addText(dl, textX, textY, Draw.IM_COL32(
            math.floor(textColor[1] * 255),
            math.floor(textColor[2] * 255),
            math.floor(textColor[3] * 255),
            255
        ), text)
    end
end

-- ============================================================
-- SPECIALIZED BARS
-- ============================================================

-- Health bar with gradient color and damage shake
function M.health(current, max, opts)
    opts = opts or {}
    current = tonumber(current) or 0
    max = tonumber(max) or 1
    local pct = max > 0 and (current / max) or 0

    -- Use OKLAB gradient sampling for smooth color (with fallback to stepped)
    if not opts.color then
        local ok, gradColor = pcall(Colors.healthBarGradient, pct)
        opts.color = (ok and gradColor) or getHealthColor(pct)
    end
    opts.borderColor = opts.borderColor or { 0.3, 0.1, 0.1 }
    opts.barType = opts.barType or 'health'

    -- HP damage shake (offset bar on significant HP drop)
    if not opts.noShake then
        local hpPct = pct * 100
        local shakeX, shakeY = AnimHelpers.getHpBarShake('hpbar_' .. (opts.id or 'default'), hpPct)
        opts.shakeX = shakeX
        opts.shakeY = shakeY
    end

    M.draw(current, max, opts)
end

-- Mana bar (blue)
function M.mana(current, max, opts)
    opts = opts or {}
    opts.color = opts.color or RESOURCE_COLORS.mana
    opts.borderColor = opts.borderColor or { 0.1, 0.15, 0.3 }
    opts.barType = opts.barType or 'mana'

    M.draw(current, max, opts)
end

-- Endurance bar (yellow)
function M.endurance(current, max, opts)
    opts = opts or {}
    opts.color = opts.color or RESOURCE_COLORS.endurance
    opts.borderColor = opts.borderColor or { 0.3, 0.25, 0.1 }
    opts.barType = opts.barType or 'endurance'

    M.draw(current, max, opts)
end

-- Experience bar (purple)
function M.experience(current, max, opts)
    opts = opts or {}
    opts.color = opts.color or RESOURCE_COLORS.experience
    opts.borderColor = opts.borderColor or { 0.2, 0.1, 0.3 }
    opts.height = opts.height or 8  -- Thinner by default
    opts.barType = opts.barType or 'experience'

    M.draw(current, max, opts)
end

-- Aggro bar with automatic color
function M.aggro(current, max, opts)
    opts = opts or {}
    current = tonumber(current) or 0
    max = tonumber(max) or 100
    local pct = max > 0 and (current / max) or 0

    opts.color = opts.color or getAggroColor(pct)
    opts.borderColor = opts.borderColor or { 0.25, 0.25, 0.25 }
    opts.barType = opts.barType or 'aggro'

    M.draw(current, max, opts)
end

-- Cooldown bar (time-based, fills as cooldown completes)
function M.cooldown(remaining, total, opts)
    opts = opts or {}
    remaining = tonumber(remaining) or 0
    total = tonumber(total) or 1

    -- Cooldown shows time elapsed (total - remaining)
    local elapsed = total - remaining
    local pct = total > 0 and (elapsed / total) or 1

    -- Color based on remaining percentage
    local remPct = total > 0 and (remaining / total) or 0
    if remPct > 0.66 then
        opts.color = { 0.9, 0.3, 0.3 }  -- Red
    elseif remPct > 0.33 then
        opts.color = { 0.9, 0.6, 0.3 }  -- Orange
    elseif remPct > 0.10 then
        opts.color = { 0.9, 0.9, 0.3 }  -- Yellow
    else
        opts.color = { 0.3, 0.9, 0.3 }  -- Green
    end

    opts.borderColor = opts.borderColor or { 0.25, 0.25, 0.25 }
    opts.barType = opts.barType or 'cooldown'

    M.draw(elapsed, total, opts)
end

-- Custom bar with any color
function M.custom(current, max, opts)
    M.draw(current, max, opts)
end

-- ============================================================
-- MINI BARS (for compact displays)
-- ============================================================

function M.mini(current, max, color, width)
    width = width or 40
    M.draw(current, max, {
        width = width,
        height = 4,
        color = color,
        gradient = false,
        rounding = 1,
    })
end

function M.miniHealth(current, max, width)
    local pct = (max or 1) > 0 and ((current or 0) / max) or 0
    M.mini(current, max, getHealthColor(pct), width)
end

function M.miniMana(current, max, width)
    M.mini(current, max, RESOURCE_COLORS.mana, width)
end

-- ============================================================
-- LABELED BARS
-- ============================================================

function M.labeled(label, current, max, opts)
    opts = opts or {}
    local labelWidth = opts.labelWidth or 60

    imgui.Text(tostring(label or ''))
    imgui.SameLine(labelWidth)

    M.draw(current, max, opts)
end

function M.labeledHealth(label, current, max, opts)
    opts = opts or {}
    local labelWidth = opts.labelWidth or 60
    local pct = (max or 1) > 0 and ((current or 0) / max) or 0

    imgui.Text(tostring(label or ''))
    imgui.SameLine(labelWidth)

    opts.color = opts.color or getHealthColor(pct)
    M.draw(current, max, opts)
end

return M
