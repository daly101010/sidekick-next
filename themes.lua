--[[
    Color Themes for Medley
    Provides preset color schemes and theme management
    Designed to sync visually with GroupTarget
]]

local mq = require('mq')

local M = {}

local function normalizeThemeKey(name)
    name = tostring(name or '')
    name = name:lower()
    name = name:gsub('%s+', '')
    name = name:gsub('[^%w]', '')
    return name
end

-- Helper for colors
local function IM_COL32(r, g, b, a)
    local shift = bit32.lshift
    r = math.max(0, math.min(255, math.floor(tonumber(r) or 0)))
    g = math.max(0, math.min(255, math.floor(tonumber(g) or 0)))
    b = math.max(0, math.min(255, math.floor(tonumber(b) or 0)))
    a = math.max(0, math.min(255, math.floor(tonumber(a) or 255)))
    return shift(a, 24) + shift(b, 16) + shift(g, 8) + r
end

-- Theme presets (matching GroupTarget themes for visual consistency)
M.presets = {
    Default = {
        name = 'Default',
        description = 'Standard dark theme',
        -- Window styling (RGBA floats 0-1)
        WindowBg = { 0.1, 0.1, 0.1 },
        ChildBg = { 0.1, 0.1, 0.1 },
        FrameBg = { 0.2, 0.2, 0.2 },
        FrameBgHovered = { 0.3, 0.3, 0.3 },
        FrameBgActive = { 0.35, 0.35, 0.35 },
        Button = { 0.3, 0.3, 0.3 },
        ButtonHovered = { 0.4, 0.4, 0.4 },
        ButtonActive = { 0.5, 0.5, 0.5 },
        Header = { 0.25, 0.25, 0.25 },
        HeaderHovered = { 0.35, 0.35, 0.35 },
        HeaderActive = { 0.4, 0.4, 0.4 },
        Border = { 0.3, 0.3, 0.3 },
        Separator = { 0.3, 0.3, 0.3 },
        ScrollbarBg = { 0.1, 0.1, 0.1 },
        ScrollbarGrab = { 0.3, 0.3, 0.3 },
    },
    
    Classic = {
        name = 'Classic',
        description = 'Classic EQ-style dark theme',
        -- Window styling - dark EQ-style blue-gray
        WindowBg = { 0.05, 0.05, 0.08 },
        ChildBg = { 0.05, 0.05, 0.08 },
        FrameBg = { 0.12, 0.12, 0.16 },
        FrameBgHovered = { 0.18, 0.18, 0.24 },
        FrameBgActive = { 0.22, 0.22, 0.30 },
        Button = { 0.16, 0.16, 0.22 },
        ButtonHovered = { 0.24, 0.24, 0.34 },
        ButtonActive = { 0.30, 0.30, 0.42 },
        Header = { 0.14, 0.14, 0.20 },
        HeaderHovered = { 0.20, 0.20, 0.30 },
        HeaderActive = { 0.26, 0.26, 0.38 },
        Border = { 0.22, 0.22, 0.32 },
        Separator = { 0.22, 0.22, 0.32 },
        ScrollbarBg = { 0.05, 0.05, 0.08 },
        ScrollbarGrab = { 0.20, 0.20, 0.28 },
    },

    ClassicEQ = {
        name = 'ClassicEQ',
        description = 'Classic EverQuest (gold/stone) UI look',
        -- Window styling: dark stone panels + warm gold trim, with EQ-like steel/blue buttons.
        WindowBg = { 0.06, 0.055, 0.05 },
        ChildBg = { 0.06, 0.055, 0.05 },
        FrameBg = { 0.10, 0.095, 0.09 },
        FrameBgHovered = { 0.15, 0.14, 0.13 },
        FrameBgActive = { 0.19, 0.18, 0.17 },
        Button = { 0.12, 0.20, 0.30 },
        ButtonHovered = { 0.16, 0.28, 0.42 },
        ButtonActive = { 0.10, 0.24, 0.38 },
        Header = { 0.10, 0.17, 0.26 },
        HeaderHovered = { 0.14, 0.24, 0.36 },
        HeaderActive = { 0.08, 0.20, 0.32 },
        Border = { 0.78, 0.68, 0.38 },
        Separator = { 0.60, 0.52, 0.30 },
        ScrollbarBg = { 0.06, 0.055, 0.05 },
        ScrollbarGrab = { 0.50, 0.44, 0.26 },
    },
    
    Dark = {
        name = 'Dark',
        description = 'Ultra dark theme',
        -- Window styling - ultra dark
        WindowBg = { 0.03, 0.03, 0.03 },
        ChildBg = { 0.03, 0.03, 0.03 },
        FrameBg = { 0.08, 0.08, 0.08 },
        FrameBgHovered = { 0.12, 0.12, 0.12 },
        FrameBgActive = { 0.15, 0.15, 0.15 },
        Button = { 0.10, 0.10, 0.10 },
        ButtonHovered = { 0.16, 0.16, 0.16 },
        ButtonActive = { 0.20, 0.20, 0.20 },
        Header = { 0.08, 0.08, 0.08 },
        HeaderHovered = { 0.12, 0.12, 0.12 },
        HeaderActive = { 0.16, 0.16, 0.16 },
        Border = { 0.12, 0.12, 0.12 },
        Separator = { 0.12, 0.12, 0.12 },
        ScrollbarBg = { 0.03, 0.03, 0.03 },
        ScrollbarGrab = { 0.12, 0.12, 0.12 },
    },
    
    HighContrast = {
        name = 'HighContrast',
        description = 'High visibility theme',
        -- Window styling - high contrast black
        WindowBg = { 0.0, 0.0, 0.0 },
        ChildBg = { 0.0, 0.0, 0.0 },
        FrameBg = { 0.12, 0.12, 0.12 },
        FrameBgHovered = { 0.22, 0.22, 0.22 },
        FrameBgActive = { 0.28, 0.28, 0.28 },
        Button = { 0.18, 0.18, 0.18 },
        ButtonHovered = { 0.32, 0.32, 0.32 },
        ButtonActive = { 0.42, 0.42, 0.42 },
        Header = { 0.15, 0.15, 0.15 },
        HeaderHovered = { 0.28, 0.28, 0.28 },
        HeaderActive = { 0.38, 0.38, 0.38 },
        Border = { 0.35, 0.35, 0.35 },
        Separator = { 0.35, 0.35, 0.35 },
        ScrollbarBg = { 0.0, 0.0, 0.0 },
        ScrollbarGrab = { 0.25, 0.25, 0.25 },
    },
    
    Neon = {
        name = 'Neon',
        description = 'Bright neon theme',
        -- Window styling - dark with purple tint
        WindowBg = { 0.02, 0.02, 0.05 },
        ChildBg = { 0.02, 0.02, 0.05 },
        FrameBg = { 0.08, 0.04, 0.12 },
        FrameBgHovered = { 0.14, 0.07, 0.20 },
        FrameBgActive = { 0.18, 0.09, 0.26 },
        Button = { 0.12, 0.06, 0.20 },
        ButtonHovered = { 0.22, 0.11, 0.36 },
        ButtonActive = { 0.30, 0.15, 0.48 },
        Header = { 0.10, 0.05, 0.18 },
        HeaderHovered = { 0.18, 0.09, 0.32 },
        HeaderActive = { 0.26, 0.13, 0.42 },
        Border = { 0.35, 0.18, 0.55 },
        Separator = { 0.35, 0.18, 0.55 },
        ScrollbarBg = { 0.02, 0.02, 0.05 },
        ScrollbarGrab = { 0.18, 0.09, 0.30 },
    },
    
    Minimal = {
        name = 'Minimal',
        description = 'Subtle, understated theme',
        -- Window styling - clean gray
        WindowBg = { 0.10, 0.10, 0.10 },
        ChildBg = { 0.10, 0.10, 0.10 },
        FrameBg = { 0.16, 0.16, 0.16 },
        FrameBgHovered = { 0.22, 0.22, 0.22 },
        FrameBgActive = { 0.26, 0.26, 0.26 },
        Button = { 0.20, 0.20, 0.20 },
        ButtonHovered = { 0.28, 0.28, 0.28 },
        ButtonActive = { 0.34, 0.34, 0.34 },
        Header = { 0.18, 0.18, 0.18 },
        HeaderHovered = { 0.26, 0.26, 0.26 },
        HeaderActive = { 0.30, 0.30, 0.30 },
        Border = { 0.22, 0.22, 0.22 },
        Separator = { 0.22, 0.22, 0.22 },
        ScrollbarBg = { 0.10, 0.10, 0.10 },
        ScrollbarGrab = { 0.22, 0.22, 0.22 },
    },

    ['Green'] = {
        name = 'Green',
        description = 'Green-tinted window styling',
        WindowBg = { 0.05, 0.08, 0.05 },
        ChildBg = { 0.05, 0.08, 0.05 },
        FrameBg = { 0.10, 0.16, 0.10 },
        FrameBgHovered = { 0.14, 0.22, 0.14 },
        FrameBgActive = { 0.18, 0.28, 0.18 },
        Button = { 0.12, 0.18, 0.12 },
        ButtonHovered = { 0.18, 0.28, 0.18 },
        ButtonActive = { 0.22, 0.34, 0.22 },
        Header = { 0.10, 0.16, 0.10 },
        HeaderHovered = { 0.16, 0.24, 0.16 },
        HeaderActive = { 0.20, 0.30, 0.20 },
        Border = { 0.18, 0.30, 0.18 },
        Separator = { 0.18, 0.30, 0.18 },
        ScrollbarBg = { 0.05, 0.08, 0.05 },
        ScrollbarGrab = { 0.14, 0.22, 0.14 },
    },

    ['Light Blue'] = {
        name = 'Light Blue',
        description = 'Blue-tinted window styling',
        WindowBg = { 0.05, 0.07, 0.10 },
        ChildBg = { 0.05, 0.07, 0.10 },
        FrameBg = { 0.10, 0.14, 0.20 },
        FrameBgHovered = { 0.14, 0.20, 0.28 },
        FrameBgActive = { 0.18, 0.24, 0.34 },
        Button = { 0.12, 0.16, 0.24 },
        ButtonHovered = { 0.18, 0.24, 0.36 },
        ButtonActive = { 0.22, 0.30, 0.44 },
        Header = { 0.10, 0.14, 0.22 },
        HeaderHovered = { 0.16, 0.22, 0.34 },
        HeaderActive = { 0.20, 0.28, 0.42 },
        Border = { 0.18, 0.26, 0.40 },
        Separator = { 0.18, 0.26, 0.40 },
        ScrollbarBg = { 0.05, 0.07, 0.10 },
        ScrollbarGrab = { 0.14, 0.20, 0.30 },
    },

    ['Blue'] = {
        name = 'Blue',
        description = 'Blue-tinted window styling (darker than Light Blue)',
        WindowBg = { 0.04, 0.05, 0.10 },
        ChildBg = { 0.04, 0.05, 0.10 },
        FrameBg = { 0.08, 0.10, 0.20 },
        FrameBgHovered = { 0.12, 0.16, 0.30 },
        FrameBgActive = { 0.16, 0.20, 0.38 },
        Button = { 0.10, 0.13, 0.26 },
        ButtonHovered = { 0.16, 0.20, 0.40 },
        ButtonActive = { 0.20, 0.25, 0.48 },
        Header = { 0.08, 0.12, 0.24 },
        HeaderHovered = { 0.14, 0.20, 0.36 },
        HeaderActive = { 0.18, 0.26, 0.44 },
        Border = { 0.16, 0.22, 0.40 },
        Separator = { 0.16, 0.22, 0.40 },
        ScrollbarBg = { 0.04, 0.05, 0.10 },
        ScrollbarGrab = { 0.12, 0.16, 0.30 },
    },

    ['Light'] = {
        name = 'Light',
        description = 'Slightly lighter neutral styling',
        WindowBg = { 0.10, 0.10, 0.11 },
        ChildBg = { 0.10, 0.10, 0.11 },
        FrameBg = { 0.18, 0.18, 0.20 },
        FrameBgHovered = { 0.24, 0.24, 0.27 },
        FrameBgActive = { 0.28, 0.28, 0.32 },
        Button = { 0.20, 0.20, 0.23 },
        ButtonHovered = { 0.28, 0.28, 0.32 },
        ButtonActive = { 0.34, 0.34, 0.40 },
        Header = { 0.18, 0.18, 0.22 },
        HeaderHovered = { 0.26, 0.26, 0.32 },
        HeaderActive = { 0.30, 0.30, 0.38 },
        Border = { 0.26, 0.26, 0.30 },
        Separator = { 0.26, 0.26, 0.30 },
        ScrollbarBg = { 0.10, 0.10, 0.11 },
        ScrollbarGrab = { 0.22, 0.22, 0.26 },
    },
}

M._presetKeyByNormalized = M._presetKeyByNormalized or {}
for key, preset in pairs(M.presets) do
    local nameKey = normalizeThemeKey(preset and preset.name or key)
    M._presetKeyByNormalized[nameKey] = key
    M._presetKeyByNormalized[normalizeThemeKey(key)] = key
end
M._presetKeyByNormalized[normalizeThemeKey('LightBlue')] = 'Light Blue'
M._presetKeyByNormalized[normalizeThemeKey('Light_Blue')] = 'Light Blue'
M._presetKeyByNormalized[normalizeThemeKey('GreenTheme')] = 'Green'
M._presetKeyByNormalized[normalizeThemeKey('BlueTheme')] = 'Blue'
M._presetKeyByNormalized[normalizeThemeKey('LightTheme')] = 'Light'

local function resolvePresetKey(themeName)
    if M.presets[themeName] then
        return themeName
    end
    local norm = normalizeThemeKey(themeName)
    return M._presetKeyByNormalized[norm]
end

-- Get list of theme names
function M.getThemeNames()
    local names = {}
    for name, _ in pairs(M.presets) do
        table.insert(names, name)
    end
    table.sort(names)
    return names
end

-- Get window styling for a theme (returns RGBA float tables)
function M.getWindowStyle(themeName)
    local key = resolvePresetKey(themeName or 'Classic')
    local preset = (key and M.presets[key]) or M.presets.Classic
    if not preset then
        preset = M.presets.Classic
    end
    
    -- Default fallbacks
    local defaults = M.presets.Default
    
    return {
        WindowBg = preset.WindowBg or defaults.WindowBg,
        ChildBg = preset.ChildBg or defaults.ChildBg,
        FrameBg = preset.FrameBg or defaults.FrameBg,
        FrameBgHovered = preset.FrameBgHovered or defaults.FrameBgHovered,
        FrameBgActive = preset.FrameBgActive or defaults.FrameBgActive,
        Button = preset.Button or defaults.Button,
        ButtonHovered = preset.ButtonHovered or defaults.ButtonHovered,
        ButtonActive = preset.ButtonActive or defaults.ButtonActive,
        Header = preset.Header or defaults.Header,
        HeaderHovered = preset.HeaderHovered or defaults.HeaderHovered,
        HeaderActive = preset.HeaderActive or defaults.HeaderActive,
        Border = preset.Border or defaults.Border,
        Separator = preset.Separator or defaults.Separator,
        ScrollbarBg = preset.ScrollbarBg or defaults.ScrollbarBg,
        ScrollbarGrab = preset.ScrollbarGrab or defaults.ScrollbarGrab,
    }
end

-- Push theme colors into the current ImGui style stack.
-- Returns the number of colors pushed (for PopStyleColor).
function M.pushWindowTheme(imgui, themeName, opts)
    if not imgui or not imgui.PushStyleColor or not imgui.PopStyleColor then return 0 end
    opts = opts or {}
    local ImGuiCol = opts.ImGuiCol or rawget(_G, 'ImGuiCol') or rawget(imgui, 'ImGuiCol')
    if not ImGuiCol then return 0 end

    local style = M.getWindowStyle(themeName)

    local winA = tonumber(opts.windowAlpha) or 1.0
    local childA = tonumber(opts.childAlpha)
    if childA == nil then childA = winA * 0.6 end
    local frameA = tonumber(opts.frameAlpha)
    if frameA == nil then frameA = math.max(0.7, winA) end
    local buttonA = tonumber(opts.buttonAlpha)
    if buttonA == nil then buttonA = 0.90 end
    local headerA = tonumber(opts.headerAlpha)
    if headerA == nil then headerA = 0.90 end
    local borderA = tonumber(opts.borderAlpha)
    if borderA == nil then borderA = 0.60 end
    local popupA = tonumber(opts.popupAlpha)
    if popupA == nil then popupA = math.max(0.85, winA) end

    local pushed = 0
    local function push(colEnum, rgb, a)
        if colEnum == nil or rgb == nil then return end
        local ok = pcall(imgui.PushStyleColor, colEnum, rgb[1], rgb[2], rgb[3], a)
        if ok then pushed = pushed + 1 end
    end

    -- Window + popup backgrounds
    push(ImGuiCol.WindowBg, style.WindowBg, winA)
    if ImGuiCol.PopupBg ~= nil then
        push(ImGuiCol.PopupBg, style.WindowBg, popupA)
    end
    push(ImGuiCol.ChildBg, style.ChildBg, childA)

    -- Frames + widgets
    push(ImGuiCol.FrameBg, style.FrameBg, frameA)
    push(ImGuiCol.FrameBgHovered, style.FrameBgHovered, 1.0)
    push(ImGuiCol.FrameBgActive, style.FrameBgActive, 1.0)

    push(ImGuiCol.Button, style.Button, buttonA)
    push(ImGuiCol.ButtonHovered, style.ButtonHovered, 1.0)
    push(ImGuiCol.ButtonActive, style.ButtonActive, 1.0)

    push(ImGuiCol.Header, style.Header, headerA)
    push(ImGuiCol.HeaderHovered, style.HeaderHovered, 1.0)
    push(ImGuiCol.HeaderActive, style.HeaderActive, 1.0)

    -- Tabs (derived from headers/buttons)
    if ImGuiCol.Tab ~= nil then
        push(ImGuiCol.Tab, style.Header, headerA)
    end
    if ImGuiCol.TabHovered ~= nil then
        push(ImGuiCol.TabHovered, style.HeaderHovered, 1.0)
    end
    if ImGuiCol.TabActive ~= nil then
        push(ImGuiCol.TabActive, style.HeaderActive, 1.0)
    end
    if ImGuiCol.TabUnfocused ~= nil then
        push(ImGuiCol.TabUnfocused, style.FrameBg, frameA)
    end
    if ImGuiCol.TabUnfocusedActive ~= nil then
        push(ImGuiCol.TabUnfocusedActive, style.Header, headerA)
    end

    -- Borders, separators, scrollbars
    push(ImGuiCol.Border, style.Border, borderA)
    push(ImGuiCol.Separator, style.Separator, borderA)

    push(ImGuiCol.ScrollbarBg, style.ScrollbarBg, 0.50)
    push(ImGuiCol.ScrollbarGrab, style.ScrollbarGrab, 0.80)
    if ImGuiCol.ScrollbarGrabHovered ~= nil then
        push(ImGuiCol.ScrollbarGrabHovered, style.ScrollbarGrab, 1.0)
    end
    if ImGuiCol.ScrollbarGrabActive ~= nil then
        push(ImGuiCol.ScrollbarGrabActive, style.ScrollbarGrab, 1.0)
    end

    return pushed
end

return M
