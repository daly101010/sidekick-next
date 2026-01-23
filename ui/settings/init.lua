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
local mq = require('mq')
require('sidekick-next.ui.imgui_compat')
local C = require('sidekick-next.ui.constants')

local M = {}

-- ============================================================
-- LAZY-LOADED TAB MODULES
-- ============================================================

local _tabs = {}
local _tabsLoaded = false

-- Lazy-loaded UI sub-modules for consolidated UI tab
local _uiSubModules = {}
local _uiSubModulesLoaded = false

local function loadUISubModules()
    if _uiSubModulesLoaded then return end
    _uiSubModulesLoaded = true

    local myClass = mq.TLO.Me.Class.ShortName() or ''

    local subDefs = {
        { name = 'General', module = 'sidekick-next.ui.settings.tab_ui' },
        { name = 'Ability Bar', module = 'sidekick-next.ui.settings.tab_bar' },
        { name = 'Special Bar', module = 'sidekick-next.ui.settings.tab_special' },
        { name = 'Disciplines Bar', module = 'sidekick-next.ui.settings.tab_disciplines', classRestriction = 'BER' },
        { name = 'Item Bar', module = 'sidekick-next.ui.settings.tab_items', uiOnly = true },
    }

    for _, def in ipairs(subDefs) do
        -- Skip class-restricted modules if not the right class
        if def.classRestriction and def.classRestriction ~= myClass then
            -- Skip this module
        else
            local ok, mod = pcall(require, def.module)
            if ok and mod then
                table.insert(_uiSubModules, { name = def.name, module = mod, uiOnly = def.uiOnly })
            end
        end
    end
end

-- Consolidated UI tab that uses collapsing headers
local function drawConsolidatedUITab(settings, themeNames, onChange)
    loadUISubModules()
    local defaultOpenFlag = ImGuiTreeNodeFlags and ImGuiTreeNodeFlags.DefaultOpen or 0

    for i, sub in ipairs(_uiSubModules) do
        local flags = (i == 1) and defaultOpenFlag or 0
        if imgui.CollapsingHeader(sub.name .. '##ui_section_' .. i, flags) then
            -- Push unique ID scope for each section to avoid widget ID conflicts
            imgui.PushID('ui_section_' .. i)
            imgui.Indent()
            local ok, err = pcall(function()
                if sub.uiOnly and sub.module.drawBarUI then
                    -- For Items, only draw the bar UI portion
                    sub.module.drawBarUI(settings, themeNames, onChange)
                elseif sub.module.draw then
                    sub.module.draw(settings, themeNames, onChange)
                end
            end)
            if not ok then
                imgui.TextColored(1, 0.3, 0.3, 1, 'Error: ' .. tostring(err))
            end
            imgui.Unindent()
            imgui.PopID()
        end
    end
end

local function loadTabs()
    if _tabsLoaded then return end
    _tabsLoaded = true

    -- Consolidated UI tab (General, Ability Bar, Special Bar, Disciplines Bar, Item Bar)
    table.insert(_tabs, {
        name = 'UI',
        module = {
            draw = drawConsolidatedUITab
        }
    })

    -- Remaining tabs
    -- Note: Healing tab moved to main UI Healing tab for healer classes
    -- Note: Items and Buffs tabs moved to top-level tabs
    local tabDefs = {
        { name = 'Automation', module = 'sidekick-next.ui.settings.tab_automation' },
        { name = 'Integration', module = 'sidekick-next.ui.settings.tab_integration' },
        { name = 'Animations', module = 'sidekick-next.ui.settings.tab_animations' },
        { name = 'Remote', module = 'sidekick-next.ui.settings.tab_remote' },
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

-- Label-before-control helper functions
-- These put the label text on the left and control on the right

-- Column position for controls (after label)
local LABEL_WIDTH = 180

-- Extract display text and ID from a label
-- "Cell Size##itembar" -> displayText="Cell Size", id="##Cell Size##itembar"
local function parseLabel(label)
    local displayText = label
    local hashPos = label:find('##')
    if hashPos then
        displayText = label:sub(1, hashPos - 1)
    end
    return displayText, '##' .. label
end

function M.labeledCheckbox(label, value, tooltip)
    local displayText, id = parseLabel(label)
    imgui.Text(displayText)
    imgui.SameLine(LABEL_WIDTH)
    local newVal, changed = imgui.Checkbox(id, value)
    if tooltip and imgui.IsItemHovered() then
        M.safeTooltip(tooltip)
    end
    return newVal, changed
end

function M.labeledSliderInt(label, value, min, max, tooltip)
    local displayText, id = parseLabel(label)
    imgui.Text(displayText)
    imgui.SameLine(LABEL_WIDTH)
    imgui.PushItemWidth(-1)
    local newVal, changed = imgui.SliderInt(id, value, min, max)
    imgui.PopItemWidth()
    if tooltip and imgui.IsItemHovered() then
        M.safeTooltip(tooltip)
    end
    return newVal, changed
end

function M.labeledSliderFloat(label, value, min, max, tooltip)
    local displayText, id = parseLabel(label)
    imgui.Text(displayText)
    imgui.SameLine(LABEL_WIDTH)
    imgui.PushItemWidth(-1)
    local newVal, changed = imgui.SliderFloat(id, value, min, max)
    imgui.PopItemWidth()
    if tooltip and imgui.IsItemHovered() then
        M.safeTooltip(tooltip)
    end
    return newVal, changed
end

function M.labeledCombo(label, current, options, tooltip)
    local displayText, id = parseLabel(label)
    imgui.Text(displayText)
    imgui.SameLine(LABEL_WIDTH)
    imgui.PushItemWidth(-1)
    local newVal = M.comboString(id, current, options)
    imgui.PopItemWidth()
    if tooltip and imgui.IsItemHovered() then
        M.safeTooltip(tooltip)
    end
    return newVal
end

function M.labeledComboKeyed(label, currentKey, options, tooltip)
    local displayText, id = parseLabel(label)
    imgui.Text(displayText)
    imgui.SameLine(LABEL_WIDTH)
    imgui.PushItemWidth(-1)
    local newVal = M.comboKeyed(id, currentKey, options)
    imgui.PopItemWidth()
    if tooltip and imgui.IsItemHovered() then
        M.safeTooltip(tooltip)
    end
    return newVal
end

function M.labeledInputText(label, value, tooltip)
    local displayText, id = parseLabel(label)
    imgui.Text(displayText)
    imgui.SameLine(LABEL_WIDTH)
    imgui.PushItemWidth(-1)
    local newVal = imgui.InputText(id, value, 256)
    imgui.PopItemWidth()
    if tooltip and imgui.IsItemHovered() then
        M.safeTooltip(tooltip)
    end
    return newVal
end

function M.safeTooltip(text)
    text = tostring(text or '')
    if text == '' then return end
    text = text:gsub('%%', '%%%%')
    pcall(imgui.SetTooltip, text)
end

function M.comboString(label, current, options)
    current = tostring(current or '')
    options = options or {}

    -- Extract display name from label (strip ## suffix)
    local displayLabel = label
    local hashPos = label:find('##')
    if hashPos then
        displayLabel = label:sub(1, hashPos - 1)
    end
    -- Strip leading ## if present (from labeled helpers)
    if displayLabel:sub(1, 2) == '##' then
        displayLabel = displayLabel:sub(3)
    end

    if #options == 0 then
        imgui.Text(displayLabel .. ':')
        imgui.SameLine()
        imgui.TextDisabled(current ~= '' and current or '(none)')
        return current
    end

    local preview = current
    if preview == '' then preview = '(none)' end
    if imgui.BeginCombo(label, preview) then
        for _, opt in ipairs(options) do
            local v = tostring(opt or '')
            local selected = (v == current)
            if imgui.Selectable(v, selected) then
                current = v
            end
            if selected then imgui.SetItemDefaultFocus() end
        end
        imgui.EndCombo()
    end
    return current
end

function M.comboKeyed(label, currentKey, options)
    currentKey = tostring(currentKey or '')
    options = options or {}

    -- Extract display name from label (strip ## suffix)
    local displayLabel = label
    local hashPos = label:find('##')
    if hashPos then
        displayLabel = label:sub(1, hashPos - 1)
    end
    -- Strip leading ## if present (from labeled helpers)
    if displayLabel:sub(1, 2) == '##' then
        displayLabel = displayLabel:sub(3)
    end

    if #options == 0 then
        imgui.Text(displayLabel .. ':')
        imgui.SameLine()
        imgui.TextDisabled(currentKey ~= '' and currentKey or '(none)')
        return currentKey
    end

    local preview = currentKey
    for _, opt in ipairs(options) do
        if tostring(opt.key) == currentKey then
            preview = tostring(opt.label or opt.key or currentKey)
            break
        end
    end
    if preview == '' then preview = '(none)' end
    if imgui.BeginCombo(label, preview) then
        for _, opt in ipairs(options) do
            local k = tostring(opt.key or '')
            local v = tostring(opt.label or k)
            local selected = (k == currentKey)
            if imgui.Selectable(v, selected) then
                currentKey = k
            end
            if selected then imgui.SetItemDefaultFocus() end
        end
        imgui.EndCombo()
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
    enabled, changed = M.labeledCheckbox(opts.enableLabel or 'Show', enabled)
    if changed and onChange then onChange(enableKey, enabled) end

    -- Cell size
    local cellKey = prefix .. 'Cell'
    local cell = tonumber(settings[cellKey]) or defaults.cell or 48
    cell, changed = M.labeledSliderInt('Cell Size', cell, C.LAYOUT.MIN_CELL_SIZE, C.LAYOUT.MAX_CELL_SIZE)
    if changed and onChange then onChange(cellKey, cell) end

    -- Rows
    local rowsKey = prefix .. 'Rows'
    local rows = tonumber(settings[rowsKey]) or defaults.rows or 2
    rows, changed = M.labeledSliderInt('Rows', rows, 1, C.LAYOUT.MAX_ROWS)
    if changed and onChange then onChange(rowsKey, rows) end

    -- Gap
    local gapKey = prefix .. 'Gap'
    local gap = tonumber(settings[gapKey]) or defaults.gap or 4
    gap, changed = M.labeledSliderInt('Gap', gap, 0, 12)
    if changed and onChange then onChange(gapKey, gap) end

    -- Padding
    local padKey = prefix .. 'Pad'
    local pad = tonumber(settings[padKey]) or defaults.pad or 6
    pad, changed = M.labeledSliderInt('Padding', pad, 0, 24)
    if changed and onChange then onChange(padKey, pad) end

    -- Background Alpha
    local alphaKey = prefix .. 'BgAlpha'
    local alpha = tonumber(settings[alphaKey]) or defaults.alpha or 0.85
    alpha, changed = M.labeledSliderFloat('Background Alpha', alpha, 0.2, 1.0)
    if changed and onChange then onChange(alphaKey, alpha) end

    -- Anchor settings
    M.drawAnchorSettings(prefix, settings, onChange)
end

function M.drawAnchorSettings(prefix, settings, onChange)
    local changed

    -- Anchor target
    local targetKey = prefix .. 'AnchorTarget'
    local target = M.labeledComboKeyed('Anchor To', settings[targetKey] or 'grouptarget', C.ANCHOR_TARGETS)
    if target ~= tostring(settings[targetKey] or 'grouptarget') and onChange then
        onChange(targetKey, target)
    end

    -- Anchor mode
    local modeKey = prefix .. 'Anchor'
    local mode = tostring(settings[modeKey] or 'none')
    mode = M.labeledCombo('Anchor Mode', mode, C.ANCHOR_MODES)
    if mode ~= tostring(settings[modeKey] or 'none') and onChange then
        onChange(modeKey, mode)
    end

    -- Anchor gap
    local gapKey = prefix .. 'AnchorGap'
    local gap = tonumber(settings[gapKey]) or 2
    gap, changed = M.labeledSliderInt('Anchor Gap', gap, 0, C.LAYOUT.MAX_ANCHOR_GAP)
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
