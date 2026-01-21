-- ============================================================
-- SideKick Settings Coordinator
-- ============================================================
-- Modular settings system with tab-based organization.
-- Each tab is a separate module for maintainability.
--
-- Usage:
--   local Settings = require('sidekick-next.ui.settings')
--   Settings.draw(settings, themeNames, onChange)

local imgui = require('ImGui')
local C = require('sidekick-next.ui.constants')

local M = {}

-- ============================================================
-- LAZY-LOADED TAB MODULES
-- ============================================================

local _tabs = {}
local _tabsLoaded = false

local function loadTabs()
    if _tabsLoaded then return end
    _tabsLoaded = true

    -- Define tabs in order
    local tabDefs = {
        { name = 'UI', module = 'ui.settings.tab_ui' },
        { name = 'Bar', module = 'ui.settings.tab_bar' },
        { name = 'Special', module = 'ui.settings.tab_special' },
        { name = 'Disciplines', module = 'ui.settings.tab_disciplines' },
        { name = 'Items', module = 'ui.settings.tab_items' },
        { name = 'Automation', module = 'ui.settings.tab_automation' },
        { name = 'Buffs', module = 'ui.settings.tab_buffs' },
        { name = 'Integration', module = 'ui.settings.tab_integration' },
        { name = 'Animations', module = 'ui.settings.tab_animations' },
        { name = 'Remote', module = 'ui.settings.tab_remote' },
        { name = 'Healing', module = 'ui.settings.tab_healing' },
    }

    for _, def in ipairs(tabDefs) do
        local ok, mod = pcall(require, def.module)
        if ok and mod then
            table.insert(_tabs, { name = def.name, module = mod })
        else
            -- Create placeholder for failed loads
            table.insert(_tabs, {
                name = def.name,
                module = {
                    draw = function()
                        imgui.TextColored(1, 0.5, 0.5, 1, 'Failed to load: ' .. def.module)
                        if not ok then
                            imgui.TextWrapped(tostring(mod))
                        end
                    end
                }
            })
        end
    end
end

-- ============================================================
-- SHARED UTILITIES
-- ============================================================

function M.safeTooltip(text)
    text = tostring(text or '')
    if text == '' then return end
    text = text:gsub('%%', '%%%%')
    pcall(imgui.SetTooltip, text)
end

function M.comboString(label, current, options)
    current = tostring(current or '')
    options = options or {}

    local currentIdx = 1
    for i, opt in ipairs(options) do
        if opt == current then
            currentIdx = i
            break
        end
    end
    local labelStr = table.concat(options, '\0') .. '\0\0'

    local newIdx = imgui.Combo(label, currentIdx, labelStr)
    if newIdx ~= currentIdx and options[newIdx] then
        return options[newIdx]
    end
    return current
end

function M.comboKeyed(label, currentKey, options)
    currentKey = tostring(currentKey or '')
    options = options or {}

    local labels = {}
    local currentIdx = 1
    for i, opt in ipairs(options) do
        table.insert(labels, opt.label)
        if opt.key == currentKey then
            currentIdx = i
        end
    end
    local labelStr = table.concat(labels, '\0') .. '\0\0'

    local newIdx = imgui.Combo(label, currentIdx, labelStr)
    if newIdx ~= currentIdx and options[newIdx] then
        return options[newIdx].key
    end
    return currentKey
end

-- ============================================================
-- COMMON SETTING PATTERNS
-- ============================================================

function M.drawBarSettings(prefix, settings, onChange, opts)
    opts = opts or {}
    local changed
    local defaults = opts.defaults or {}

    -- Enable checkbox
    local enableKey = prefix .. 'Enabled'
    local enabled = settings[enableKey] ~= false
    enabled, changed = imgui.Checkbox(opts.enableLabel or 'Show', enabled)
    if changed and onChange then onChange(enableKey, enabled) end

    -- Cell size
    local cellKey = prefix .. 'Cell'
    local cell = tonumber(settings[cellKey]) or defaults.cell or 48
    cell, changed = imgui.SliderInt('Cell Size', cell, C.LAYOUT.MIN_CELL_SIZE, C.LAYOUT.MAX_CELL_SIZE)
    if changed and onChange then onChange(cellKey, cell) end

    -- Rows
    local rowsKey = prefix .. 'Rows'
    local rows = tonumber(settings[rowsKey]) or defaults.rows or 2
    rows, changed = imgui.SliderInt('Rows', rows, 1, C.LAYOUT.MAX_ROWS)
    if changed and onChange then onChange(rowsKey, rows) end

    -- Gap
    local gapKey = prefix .. 'Gap'
    local gap = tonumber(settings[gapKey]) or defaults.gap or 4
    gap, changed = imgui.SliderInt('Gap', gap, 0, 12)
    if changed and onChange then onChange(gapKey, gap) end

    -- Padding
    local padKey = prefix .. 'Pad'
    local pad = tonumber(settings[padKey]) or defaults.pad or 6
    pad, changed = imgui.SliderInt('Padding', pad, 0, 24)
    if changed and onChange then onChange(padKey, pad) end

    -- Background Alpha
    local alphaKey = prefix .. 'BgAlpha'
    local alpha = tonumber(settings[alphaKey]) or defaults.alpha or 0.85
    alpha, changed = imgui.SliderFloat('Background Alpha', alpha, 0.2, 1.0)
    if changed and onChange then onChange(alphaKey, alpha) end

    -- Anchor settings
    M.drawAnchorSettings(prefix, settings, onChange)
end

function M.drawAnchorSettings(prefix, settings, onChange)
    local changed

    -- Anchor target
    local targetKey = prefix .. 'AnchorTarget'
    local target = M.comboKeyed('Anchor To', settings[targetKey] or 'grouptarget', C.ANCHOR_TARGETS)
    if target ~= tostring(settings[targetKey] or 'grouptarget') and onChange then
        onChange(targetKey, target)
    end

    -- Anchor mode
    local modeKey = prefix .. 'Anchor'
    local mode = tostring(settings[modeKey] or 'none')
    mode = M.comboString('Anchor Mode', mode, C.ANCHOR_MODES)
    if mode ~= tostring(settings[modeKey] or 'none') and onChange then
        onChange(modeKey, mode)
    end

    -- Anchor gap
    local gapKey = prefix .. 'AnchorGap'
    local gap = tonumber(settings[gapKey]) or 2
    gap, changed = imgui.SliderInt('Anchor Gap', gap, 0, C.LAYOUT.MAX_ANCHOR_GAP)
    if changed and onChange then onChange(gapKey, gap) end
end

-- ============================================================
-- MAIN DRAW FUNCTION
-- ============================================================

function M.draw(settings, themeNames, onChange, opts)
    loadTabs()

    opts = opts or {}
    local width = opts.width or 400
    local height = opts.height or 500

    -- Store context for tab modules
    M._currentSettings = settings
    M._currentThemeNames = themeNames
    M._currentOnChange = onChange

    -- Begin tab bar
    if imgui.BeginTabBar('SideKickSettings') then
        for _, tab in ipairs(_tabs) do
            if imgui.BeginTabItem(tab.name) then
                imgui.BeginChild('##' .. tab.name .. '_content', 0, 0, false)

                -- Draw tab content
                local ok, err = pcall(function()
                    tab.module.draw(settings, themeNames, onChange)
                end)

                if not ok then
                    imgui.TextColored(1, 0.3, 0.3, 1, 'Error in ' .. tab.name .. ':')
                    imgui.TextWrapped(tostring(err))
                end

                imgui.EndChild()
                imgui.EndTabItem()
            end
        end
        imgui.EndTabBar()
    end
end

-- ============================================================
-- ACCESSORS FOR TAB MODULES
-- ============================================================

function M.getSettings()
    return M._currentSettings
end

function M.getThemeNames()
    return M._currentThemeNames
end

function M.getOnChange()
    return M._currentOnChange
end

return M
