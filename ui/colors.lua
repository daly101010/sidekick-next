-- ============================================================
-- SideKick Theme-Aware Colors
-- ============================================================
-- Provides theme-aware color functions for consistent UI styling
-- across all SideKick components.
--
-- Usage:
--   local Colors = require('sidekick-next.ui.colors')
--   local readyColor = Colors.ready('Classic')
--   local cdColor = Colors.cooldown('Classic', 0.5)
--   local r, g, b = Colors.cooldownRGB(0.5)

local C = require('sidekick-next.ui.constants')
local Draw = require('sidekick-next.ui.draw_helpers')

local M = {}

-- ============================================================
-- THEME COLOR PALETTES
-- ============================================================

-- Theme-specific accent colors for ready glow
local READY_GLOW_COLORS = {
    Classic = { 80, 200, 255 },      -- Cyan/Blue
    ClassicEQ = { 255, 200, 80 },    -- Gold
    Dark = { 100, 180, 255 },        -- Blue
    HighContrast = { 255, 255, 255 },-- White
    Neon = { 180, 80, 255 },         -- Purple
    Minimal = { 150, 200, 255 },     -- Light blue
    Green = { 80, 255, 120 },        -- Green
    ['Light Blue'] = { 100, 180, 255 }, -- Blue
    Blue = { 80, 140, 255 },         -- Deep blue
    Light = { 120, 180, 255 },       -- Soft blue
    Velious = { 140, 200, 255 },     -- Ice blue
    Kunark = { 255, 140, 60 },       -- Ember orange
    Default = { 80, 200, 255 },      -- Cyan (fallback)
}

-- Theme-specific toggle on colors
local TOGGLE_ON_COLORS = {
    Classic = { 0.3, 0.8, 0.3, 1.0 },
    ClassicEQ = { 0.6, 0.5, 0.2, 1.0 },
    Dark = { 0.2, 0.7, 0.3, 1.0 },
    HighContrast = { 0.2, 0.9, 0.2, 1.0 },
    Neon = { 0.5, 0.2, 0.8, 1.0 },
    Minimal = { 0.4, 0.7, 0.4, 1.0 },
    Green = { 0.2, 0.8, 0.3, 1.0 },
    ['Light Blue'] = { 0.2, 0.5, 0.8, 1.0 },
    Blue = { 0.2, 0.4, 0.8, 1.0 },
    Light = { 0.3, 0.6, 0.3, 1.0 },
    Velious = { 0.3, 0.5, 0.8, 1.0 },    -- Frost blue
    Kunark = { 0.7, 0.4, 0.2, 1.0 },     -- Ember orange
    Default = { 0.3, 0.8, 0.3, 1.0 },
}

-- Theme-specific toggle off colors
local TOGGLE_OFF_COLORS = {
    Classic = { 0.5, 0.5, 0.5, 1.0 },
    ClassicEQ = { 0.4, 0.35, 0.25, 1.0 },
    Dark = { 0.3, 0.3, 0.3, 1.0 },
    HighContrast = { 0.2, 0.2, 0.2, 1.0 },
    Neon = { 0.3, 0.2, 0.4, 1.0 },
    Minimal = { 0.45, 0.45, 0.45, 1.0 },
    Green = { 0.35, 0.4, 0.35, 1.0 },
    ['Light Blue'] = { 0.4, 0.45, 0.5, 1.0 },
    Blue = { 0.35, 0.4, 0.5, 1.0 },
    Light = { 0.5, 0.5, 0.52, 1.0 },
    Velious = { 0.30, 0.35, 0.45, 1.0 },  -- Cold gray-blue
    Kunark = { 0.35, 0.28, 0.22, 1.0 },   -- Volcanic gray-brown
    Default = { 0.5, 0.5, 0.5, 1.0 },
}

-- Theme-specific text colors
local TEXT_COLORS = {
    Classic = { 1.0, 1.0, 1.0, 1.0 },
    ClassicEQ = { 0.95, 0.9, 0.8, 1.0 },
    Dark = { 0.9, 0.9, 0.9, 1.0 },
    HighContrast = { 1.0, 1.0, 1.0, 1.0 },
    Neon = { 0.9, 0.8, 1.0, 1.0 },
    Minimal = { 0.85, 0.85, 0.85, 1.0 },
    Green = { 0.9, 1.0, 0.9, 1.0 },
    ['Light Blue'] = { 0.9, 0.95, 1.0, 1.0 },
    Blue = { 0.9, 0.95, 1.0, 1.0 },
    Light = { 0.95, 0.95, 0.95, 1.0 },
    Velious = { 0.88, 0.94, 1.0, 1.0 },   -- Frosty white-blue
    Kunark = { 1.0, 0.95, 0.88, 1.0 },    -- Warm white
    Default = { 1.0, 1.0, 1.0, 1.0 },
}

-- ============================================================
-- HELPER FUNCTIONS
-- ============================================================

local function normalizeThemeName(themeName)
    if not themeName or themeName == '' then return 'Default' end
    return tostring(themeName)
end

local function getFromPalette(palette, themeName)
    themeName = normalizeThemeName(themeName)
    return palette[themeName] or palette.Default
end

-- ============================================================
-- READY STATE COLORS
-- ============================================================

-- Get ready glow color (RGB 0-255) for theme
function M.ready(themeName)
    return getFromPalette(READY_GLOW_COLORS, themeName)
end

-- Get ready glow as packed uint32 with alpha
function M.readyU32(themeName, alpha)
    local rgb = M.ready(themeName)
    alpha = tonumber(alpha) or C.COLORS.READY_GLOW_ALPHA_MAX
    return Draw.IM_COL32(rgb[1], rgb[2], rgb[3], alpha)
end

-- ============================================================
-- COOLDOWN COLORS
-- ============================================================

-- Get target color (0-1 floats) for cooldown percentage
function M.cooldownRGB(pct)
    pct = tonumber(pct) or 1
    if pct > C.COOLDOWN.RED_THRESHOLD then
        return C.COLORS.COOLDOWN_RED[1], C.COLORS.COOLDOWN_RED[2], C.COLORS.COOLDOWN_RED[3]
    elseif pct > C.COOLDOWN.ORANGE_THRESHOLD then
        return C.COLORS.COOLDOWN_ORANGE[1], C.COLORS.COOLDOWN_ORANGE[2], C.COLORS.COOLDOWN_ORANGE[3]
    elseif pct > C.COOLDOWN.YELLOW_THRESHOLD then
        return C.COLORS.COOLDOWN_YELLOW[1], C.COLORS.COOLDOWN_YELLOW[2], C.COLORS.COOLDOWN_YELLOW[3]
    else
        return C.COLORS.COOLDOWN_GREEN[1], C.COLORS.COOLDOWN_GREEN[2], C.COLORS.COOLDOWN_GREEN[3]
    end
end

-- Get cooldown color as packed uint32
function M.cooldownU32(pct, alpha)
    local r, g, b = M.cooldownRGB(pct)
    alpha = tonumber(alpha) or 255
    return Draw.IM_COL32(
        math.floor(r * 255),
        math.floor(g * 255),
        math.floor(b * 255),
        alpha
    )
end

-- Get cooldown overlay color (semi-transparent)
function M.cooldownOverlay(pct)
    return M.cooldownU32(pct, C.COLORS.COOLDOWN_OVERLAY_ALPHA)
end

-- Get cooldown fill color
function M.cooldownFill(pct)
    return M.cooldownU32(pct, C.COLORS.COOLDOWN_FILL_ALPHA)
end

-- Get cooldown border color
function M.cooldownBorder(pct)
    return M.cooldownU32(pct, C.COLORS.COOLDOWN_BORDER_ALPHA)
end

-- ============================================================
-- WARNING COLORS
-- ============================================================

-- Get low resource warning color (0-1 floats)
function M.lowResource(severity)
    severity = tonumber(severity) or 1
    local base = C.COLORS.LOW_RESOURCE_WARNING
    return { base[1], base[2], base[3], severity }
end

-- Get damage flash color (0-1 floats)
function M.damageFlash(intensity)
    intensity = tonumber(intensity) or 1
    local base = C.COLORS.DAMAGE_FLASH
    return { base[1], base[2], base[3], intensity * 0.5 }
end

-- ============================================================
-- TOGGLE COLORS
-- ============================================================

-- Get toggle on color (0-1 floats) for theme
function M.toggleOn(themeName)
    return getFromPalette(TOGGLE_ON_COLORS, themeName)
end

-- Get toggle off color (0-1 floats) for theme
function M.toggleOff(themeName)
    return getFromPalette(TOGGLE_OFF_COLORS, themeName)
end

-- Get toggle color based on state (0-1 floats)
function M.toggle(themeName, isActive)
    if isActive then
        return M.toggleOn(themeName)
    else
        return M.toggleOff(themeName)
    end
end

-- ============================================================
-- TEXT COLORS
-- ============================================================

-- Get text color (0-1 floats) for theme
function M.text(themeName)
    return getFromPalette(TEXT_COLORS, themeName)
end

-- Get dimmed text color for theme
function M.textDim(themeName)
    local c = M.text(themeName)
    return { c[1] * 0.6, c[2] * 0.6, c[3] * 0.6, c[4] or 1.0 }
end

-- ============================================================
-- AGGRO/WARNING COLORS
-- ============================================================

-- Get aggro warning color based on percentage
function M.aggro(aggroPct)
    aggroPct = tonumber(aggroPct) or 0
    if aggroPct >= 100 then
        return { 1.0, 0.2, 0.2, 1.0 }  -- Red - you have aggro
    elseif aggroPct >= 80 then
        return { 1.0, 0.5, 0.2, 1.0 }  -- Orange - high aggro
    elseif aggroPct >= 50 then
        return { 1.0, 0.8, 0.2, 1.0 }  -- Yellow - moderate
    else
        return { 0.5, 0.5, 0.5, 1.0 }  -- Gray - safe
    end
end

-- ============================================================
-- HEALTH BAR COLORS
-- ============================================================

-- Get health bar color based on percentage
function M.healthBar(hpPct)
    hpPct = tonumber(hpPct) or 100
    if hpPct <= 25 then
        return { 0.8, 0.2, 0.2, 1.0 }  -- Red
    elseif hpPct <= 50 then
        return { 0.9, 0.6, 0.2, 1.0 }  -- Orange
    elseif hpPct <= 75 then
        return { 0.9, 0.9, 0.3, 1.0 }  -- Yellow
    else
        return { 0.3, 0.8, 0.3, 1.0 }  -- Green
    end
end

-- ============================================================
-- UTILITY
-- ============================================================

-- Interpolate between two colors (0-1 floats)
function M.lerp(c1, c2, t)
    t = math.max(0, math.min(1, tonumber(t) or 0))
    return {
        c1[1] + (c2[1] - c1[1]) * t,
        c1[2] + (c2[2] - c1[2]) * t,
        c1[3] + (c2[3] - c1[3]) * t,
        (c1[4] or 1) + ((c2[4] or 1) - (c1[4] or 1)) * t,
    }
end

-- Convert 0-1 float RGBA to 0-255 RGBA
function M.toRGB255(color)
    return {
        math.floor(color[1] * 255),
        math.floor(color[2] * 255),
        math.floor(color[3] * 255),
        math.floor((color[4] or 1) * 255),
    }
end

-- Convert 0-255 RGBA to 0-1 float RGBA
function M.toRGBFloat(color)
    return {
        color[1] / 255,
        color[2] / 255,
        color[3] / 255,
        (color[4] or 255) / 255,
    }
end

return M
