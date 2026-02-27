-- ============================================================
-- SideKick UI Components Demo
-- ============================================================
-- Showcase window demonstrating all available UI components.
--
-- Usage:
--   /lua run sidekick-next/ui/components/demo
--
-- Or from within SideKick:
--   local Demo = require('sidekick-next.ui.components.demo')
--   Demo.toggle()

local mq = require('mq')
local imgui = require('ImGui')

-- Protected requires with error reporting
local function safeRequire(modname)
    local ok, result = pcall(require, modname)
    if not ok then
        print('\ar[Demo] Failed to load ' .. modname .. ':\ax ' .. tostring(result))
        return nil
    end
    return result
end

local Components = safeRequire('sidekick-next.ui.components')
local Themes = safeRequire('sidekick-next.themes')
local Colors = safeRequire('sidekick-next.ui.colors')

if not Components or not Themes or not Colors then
    print('\ar[Demo] Required modules missing, cannot continue.\ax')
    return {}
end

local M = {}

-- ============================================================
-- STATE
-- ============================================================

local State = {
    open = true,
    draw = false,
    themeName = 'Classic',
    activeTab = 1,

    -- Demo state for various components
    toggleState = false,
    sliderValue = 50,
    searchText = '',
    selectedTheme = 1,

    -- Icon button states
    playPaused = false,
    lockState = false,
    radioSelection = 1,

    -- Table data
    tableData = {
        { name = 'Fireball', level = 55, class = 'WIZ', ready = true },
        { name = 'Complete Heal', level = 60, class = 'CLR', ready = false },
        { name = 'Torpor', level = 65, class = 'SHM', ready = true },
        { name = 'Mana Burn', level = 70, class = 'WIZ', ready = false },
        { name = 'Divine Aura', level = 45, class = 'CLR', ready = true },
    },

    -- Animation demo
    animStartTime = os.clock(),
    spinnerDemo = true,
}

-- Available themes
local THEME_NAMES = Themes.getThemeNames and Themes.getThemeNames() or {}
if #THEME_NAMES == 0 then
    -- Fallback if getThemeNames not available
    for name, _ in pairs(Themes.presets or {}) do
        table.insert(THEME_NAMES, name)
    end
    table.sort(THEME_NAMES)
end
if #THEME_NAMES == 0 then
    THEME_NAMES = { 'Classic', 'ClassicEQ', 'ClassicEQ Textured', 'Dark', 'Neon', 'Forest', 'Blood', 'Royal', 'Velious', 'Kunark' }
end

-- Tab definitions
local TABS = {
    { name = 'Buttons', icon = '◉' },
    { name = 'Badges', icon = '●' },
    { name = 'Bars', icon = '▬' },
    { name = 'Inputs', icon = '▭' },
    { name = 'Tables', icon = '▦' },
    { name = 'Feedback', icon = '!' },
    { name = 'Layout', icon = '▣' },
    { name = 'Textures', icon = '▤' },
}

-- ============================================================
-- TAB CONTENT RENDERERS
-- ============================================================

local function renderButtonsTab()
    local theme = State.themeName

    -- DIAGNOSTIC: Test DrawList directly
    Components.SettingGroup.section('DrawList Diagnostic', theme)

    -- Load Draw helpers for API info
    local Draw = require('sidekick-next.ui.draw_helpers')
    local apiInfo = Draw.getApiInfo()

    imgui.Text('Draw API State:')
    imgui.Text('  detected: ' .. tostring(apiInfo.detected))
    imgui.Text('  useImVec2: ' .. tostring(apiInfo.useImVec2))
    imgui.Text('  hasImVec2: ' .. tostring(apiInfo.hasImVec2))

    imgui.Spacing()

    local dl = imgui.GetWindowDrawList()
    if dl then
        imgui.Text('DrawList: OK')

        -- Try to get cursor position
        local cx, cy = imgui.GetCursorScreenPos()
        if type(cx) == 'table' then
            imgui.Text('CursorPos: table {x=' .. tostring(cx.x or cx[1]) .. ', y=' .. tostring(cx.y or cx[2]) .. '}')
            cy = cx.y or cx[2]
            cx = cx.x or cx[1]
        else
            imgui.Text('CursorPos: ' .. tostring(cx) .. ', ' .. tostring(cy))
        end

        -- Reserve space for the test boxes
        imgui.Dummy(200, 60)

        -- Test 1: Direct ImVec2 call (what we know works)
        local ImVec2 = ImVec2 or imgui.ImVec2
        local col = 0xFF00FF00  -- Green, ABGR format

        if ImVec2 then
            local ok, err = pcall(function()
                dl:AddRectFilled(ImVec2(cx, cy), ImVec2(cx + 80, cy + 20), col, 4)
            end)
            if ok then
                imgui.Text('Direct ImVec2 call: OK (green box)')
            else
                imgui.TextColored(1, 0.3, 0.3, 1, 'Direct ImVec2: ' .. tostring(err))
            end
        end

        -- Test 2: Through Draw helper
        local colBlue = Draw.IM_COL32(0, 128, 255, 255)
        local result = Draw.addRectFilled(dl, cx + 100, cy, cx + 180, cy + 20, colBlue, 4)
        if result then
            imgui.Text('Draw.addRectFilled: OK (blue box)')
        else
            imgui.TextColored(1, 0.5, 0, 1, 'Draw.addRectFilled: returned false')
        end

        -- Test 3: Draw a circle
        local colRed = Draw.IM_COL32(255, 64, 64, 255)
        local circleResult = Draw.addCircleFilled(dl, cx + 40, cy + 45, 12, colRed, 12)
        if circleResult then
            imgui.Text('Draw.addCircleFilled: OK (red circle)')
        else
            imgui.TextColored(1, 0.5, 0, 1, 'Draw.addCircleFilled: returned false')
        end

        -- Test 4: Draw text
        local colYellow = Draw.IM_COL32(255, 255, 0, 255)
        local textResult = Draw.addText(dl, cx + 100, cy + 40, colYellow, 'Test Text')
        if textResult then
            imgui.Text('Draw.addText: OK (yellow text)')
        else
            imgui.TextColored(1, 0.5, 0, 1, 'Draw.addText: returned false')
        end
    else
        imgui.TextColored(1, 0.3, 0.3, 1, 'DrawList: NIL!')
    end

    imgui.Spacing()
    imgui.Separator()
    imgui.Spacing()

    -- Themed Toggle Buttons (these work - use standard imgui)
    Components.SettingGroup.section('Toggle Buttons', theme)

    imgui.Text('Standard toggles:')
    imgui.SameLine(120)
    State.toggleState = Components.ThemedButton.toggle('Enabled', State.toggleState, theme)
    imgui.SameLine()
    Components.ThemedButton.toggle('Disabled', false, theme)
    imgui.SameLine()
    Components.ThemedButton.toggle('Active', true, theme)

    imgui.Spacing()

    -- Test basic ImGui buttons first
    Components.SettingGroup.section('Basic ImGui Buttons (Test)', theme)

    imgui.Text('Standard ImGui:')
    imgui.SameLine(120)
    if imgui.Button('Test 1') then
        print('Test 1 clicked')
    end
    imgui.SameLine()
    if imgui.Button('Test 2') then
        print('Test 2 clicked')
    end

    imgui.Spacing()

    -- Icon Buttons - wrap in pcall to see errors
    Components.SettingGroup.section('Icon Buttons', theme)

    imgui.Text('Square buttons:')
    imgui.SameLine(120)
    local ok, err = pcall(function()
        if Components.IconButton.draw('S', 'Settings', theme) then
            print('Settings clicked')
        end
    end)
    if not ok then
        imgui.SameLine()
        imgui.TextColored(1, 0.3, 0.3, 1, 'Error: ' .. tostring(err))
    end

    imgui.Spacing()

    -- Keybind badges - simplified
    Components.SettingGroup.section('Keybind Badges', theme)

    imgui.Text('Single key:')
    imgui.SameLine(120)
    local ok2, err2 = pcall(function()
        Components.KeybindBadge.draw('F1', theme)
    end)
    if not ok2 then
        imgui.TextColored(1, 0.3, 0.3, 1, 'Keybind Error: ' .. tostring(err2))
    end

    imgui.Spacing()

    imgui.Text('Key combos:')
    imgui.SameLine(120)
    local ok3, err3 = pcall(function()
        Components.KeybindBadge.combo('Ctrl+S', theme)
    end)
    if not ok3 then
        imgui.TextColored(1, 0.3, 0.3, 1, 'Combo Error: ' .. tostring(err3))
    end

    imgui.Spacing()

    imgui.Text('Action hints:')
    imgui.SameLine(120)
    Components.KeybindBadge.actionHint('F1', 'Target nearest PC', theme)

    imgui.Spacing()

    imgui.Text('Pill style:')
    imgui.SameLine(120)
    Components.KeybindBadge.pill('Tab', theme)
    imgui.SameLine()
    Components.KeybindBadge.pill('Enter', theme)
end

local function renderBadgesTab()
    local theme = State.themeName

    -- Status Badges
    Components.SettingGroup.section('Status Badges', theme)

    imgui.Text('Standard:')
    imgui.SameLine(100)
    Components.StatusBadge.ready('Ready', theme)
    imgui.SameLine()
    Components.StatusBadge.cooldown('5.2s', theme)
    imgui.SameLine()
    Components.StatusBadge.buff('Haste', theme)
    imgui.SameLine()
    Components.StatusBadge.debuff('Slowed', theme)

    imgui.Spacing()

    imgui.Text('Alerts:')
    imgui.SameLine(100)
    Components.StatusBadge.info('Info', theme)
    imgui.SameLine()
    Components.StatusBadge.success('Success', theme)
    imgui.SameLine()
    Components.StatusBadge.warning('Warning', theme)
    imgui.SameLine()
    Components.StatusBadge.error('Error', theme)

    imgui.Spacing()

    imgui.Text('Pill style:')
    imgui.SameLine(100)
    Components.StatusBadge.pill('Online', 'success', theme)
    imgui.SameLine()
    Components.StatusBadge.pill('AFK', 'warning', theme)
    imgui.SameLine()
    Components.StatusBadge.pill('Offline', 'neutral', theme)

    imgui.Spacing()

    imgui.Text('Count:')
    imgui.SameLine(100)
    Components.StatusBadge.count(3, 'info', theme)
    imgui.SameLine()
    Components.StatusBadge.count(42, 'success', theme)
    imgui.SameLine()
    Components.StatusBadge.count(150, 'warning', theme)

    imgui.Spacing()

    -- Status Dots
    Components.SettingGroup.section('Status Dots', theme)

    imgui.Text('Simple:')
    imgui.SameLine(100)
    Components.StatusBadge.dot('ready', theme)
    imgui.SameLine()
    imgui.Text('Ready')
    imgui.SameLine()
    Components.StatusBadge.dot('cooldown', theme)
    imgui.SameLine()
    imgui.Text('Cooldown')
    imgui.SameLine()
    Components.StatusBadge.dot('warning', theme, { pulsing = true })
    imgui.SameLine()
    imgui.Text('Warning')

    imgui.Spacing()

    imgui.Text('Status dot:')
    imgui.SameLine(100)
    Components.StatusBadge.statusDot(true, theme)
    imgui.SameLine()
    imgui.Text('Ready')
    imgui.SameLine()
    Components.StatusBadge.statusDot(false, theme)
    imgui.SameLine()
    imgui.Text('Not Ready')

    imgui.Spacing()

    -- Custom badges
    Components.SettingGroup.section('Custom Badges', theme)

    imgui.Text('Custom colors:')
    imgui.SameLine(100)
    Components.StatusBadge.custom('Tank', { 0.7, 0.5, 0.2 }, theme)
    imgui.SameLine()
    Components.StatusBadge.custom('Healer', { 0.2, 0.7, 0.5 }, theme)
    imgui.SameLine()
    Components.StatusBadge.custom('DPS', { 0.7, 0.2, 0.2 }, theme)
    imgui.SameLine()
    Components.StatusBadge.custom('Support', { 0.5, 0.4, 0.8 }, theme)
end

local function renderBarsTab()
    local theme = State.themeName

    -- Resource Bars
    Components.SettingGroup.section('Resource Bars', theme)

    imgui.Text('Health:')
    imgui.SameLine(80)
    Components.ResourceBar.health(7500, 10000, { width = 200, showPercent = true, theme = theme })

    imgui.Text('Health (low):')
    imgui.SameLine(80)
    Components.ResourceBar.health(2000, 10000, { width = 200, showPercent = true, theme = theme })

    imgui.Text('Mana:')
    imgui.SameLine(80)
    Components.ResourceBar.mana(4500, 8000, { width = 200, showText = true, theme = theme })

    imgui.Text('Endurance:')
    imgui.SameLine(80)
    Components.ResourceBar.endurance(6000, 6000, { width = 200, showPercent = true, theme = theme })

    imgui.Text('Experience:')
    imgui.SameLine(80)
    Components.ResourceBar.experience(35, 100, { width = 200, showPercent = true, theme = theme })

    imgui.Text('Aggro:')
    imgui.SameLine(80)
    Components.ResourceBar.aggro(85, 100, { width = 200, showPercent = true, theme = theme })

    imgui.Spacing()

    -- Cooldown bars
    Components.SettingGroup.section('Cooldown Bars', theme)

    local elapsed = (os.clock() - State.animStartTime) % 10

    imgui.Text('Cooldown:')
    imgui.SameLine(80)
    Components.ResourceBar.cooldown(10 - elapsed, 10, { width = 200, theme = theme })

    imgui.Spacing()

    -- Mini bars
    Components.SettingGroup.section('Mini Bars (Compact)', theme)

    imgui.Text('Mini health:')
    imgui.SameLine(100)
    Components.ResourceBar.miniHealth(8000, 10000, 60)
    imgui.SameLine()
    Components.ResourceBar.miniHealth(5000, 10000, 60)
    imgui.SameLine()
    Components.ResourceBar.miniHealth(2000, 10000, 60)

    imgui.Text('Mini mana:')
    imgui.SameLine(100)
    Components.ResourceBar.miniMana(7000, 8000, 60)
    imgui.SameLine()
    Components.ResourceBar.miniMana(4000, 8000, 60)
    imgui.SameLine()
    Components.ResourceBar.miniMana(1000, 8000, 60)

    imgui.Spacing()

    -- Labeled bars
    Components.SettingGroup.section('Labeled Bars', theme)

    Components.ResourceBar.labeledHealth('Warrior', 9500, 12000, { width = 150, showPercent = true, theme = theme })
    Components.ResourceBar.labeledHealth('Cleric', 6000, 8000, { width = 150, showPercent = true, theme = theme })
    Components.ResourceBar.labeledHealth('Wizard', 3500, 5000, { width = 150, showPercent = true, theme = theme })
end

local function renderInputsTab()
    local theme = State.themeName

    -- Search Input
    Components.SettingGroup.section('Search Input', theme)

    imgui.Text('Standard:')
    imgui.SameLine(100)
    State.searchText = Components.SearchInput.draw('##search1', State.searchText, theme, {
        placeholder = 'Search spells...',
        width = 200,
    })

    imgui.Spacing()

    imgui.Text('Compact:')
    imgui.SameLine(100)
    Components.SearchInput.compact('##search2', State.searchText, theme, {
        placeholder = 'Quick search',
        width = 150,
    })

    imgui.Spacing()

    -- Slider Row
    Components.SettingGroup.section('Slider Row', theme)

    local sliderChanged, newSliderVal = Components.SliderRow.int('Volume', 'demoVolume', State.sliderValue, 0, 100, nil, {
        width = 150,
        format = '%d%%',
    })
    if sliderChanged then State.sliderValue = newSliderVal end

    imgui.Spacing()

    -- Combo Row
    Components.SettingGroup.section('Theme Selector (Combo)', theme)

    local comboChanged, newThemeIdx = Components.ComboRow.draw('Theme', 'demoTheme', State.selectedTheme - 1, THEME_NAMES, nil, {
        width = 150,
    })
    if comboChanged then
        State.selectedTheme = newThemeIdx + 1  -- Convert back to 1-indexed
        if THEME_NAMES[State.selectedTheme] then
            State.themeName = THEME_NAMES[State.selectedTheme]
        end
    end

    imgui.Spacing()

    -- Checkbox Row
    Components.SettingGroup.section('Checkbox Row', theme)

    -- CheckboxRow now returns: newValue, changed
    local newCbVal, cbChanged = Components.CheckboxRow.draw('Show spinners', 'demoSpinner', State.spinnerDemo)
    if cbChanged then State.spinnerDemo = newCbVal end
end

local function renderTablesTab()
    local theme = State.themeName

    -- Data Table
    Components.SettingGroup.section('Data Table (Sortable)', theme)

    local columns = {
        { key = 'name', header = 'Spell Name', width = 120, sortable = true },
        { key = 'level', header = 'Level', width = 50, sortable = true },
        { key = 'class', header = 'Class', width = 50, sortable = true },
        { key = 'ready', header = 'Status', width = 70,
            render = function(value, row, th)
                if value then
                    Components.StatusBadge.dot('ready', th, { pulsing = true })
                else
                    Components.StatusBadge.dot('cooldown', th)
                end
                imgui.SameLine()
                imgui.Text(value and 'Ready' or 'CD')
            end
        },
    }

    local selected, idx = Components.DataTable.draw('##spells', columns, State.tableData, theme, {
        height = 150,
        selectable = true,
    })

    if selected then
        imgui.Text('Selected: ' .. selected.name .. ' (Lv.' .. selected.level .. ')')
    end

    imgui.Spacing()

    -- Simple Table
    Components.SettingGroup.section('Simple Table (Auto-columns)', theme)

    local simpleData = {
        { stat = 'HP', value = 12500 },
        { stat = 'Mana', value = 8000 },
        { stat = 'AC', value = 2500 },
        { stat = 'ATK', value = 1800 },
    }

    Components.DataTable.simple('##stats', simpleData, theme, { height = 100 })
end

local function renderFeedbackTab()
    local theme = State.themeName

    -- Toast Notifications
    Components.SettingGroup.section('Toast Notifications', theme)

    imgui.Text('Click to trigger:')
    imgui.SameLine(120)

    if Components.IconButton.withLabel('ℹ', 'Info', theme) then
        Components.Toast.info('This is an info message')
    end
    imgui.SameLine()
    if Components.IconButton.withLabel('✓', 'Success', theme) then
        Components.Toast.success('Operation completed!')
    end
    imgui.SameLine()
    if Components.IconButton.withLabel('!', 'Warning', theme) then
        Components.Toast.warning('Low mana warning!')
    end
    imgui.SameLine()
    if Components.IconButton.withLabel('✗', 'Error', theme) then
        Components.Toast.error('Target out of range')
    end

    imgui.Spacing()

    imgui.Text('Special:')
    imgui.SameLine(120)
    if Components.IconButton.withLabel('✦', 'Spell', theme) then
        Components.Toast.spell('Complete Heal landed!')
    end
    imgui.SameLine()
    if Components.IconButton.withLabel('⚔', 'Combat', theme) then
        Components.Toast.combat('Entering combat!')
    end

    imgui.Spacing()
    imgui.Spacing()

    -- Loading Spinners
    Components.SettingGroup.section('Loading Spinners', theme)

    if State.spinnerDemo then
        imgui.Text('Circular:')
        imgui.SameLine(100)
        Components.LoadingSpinner.circular('Loading...', theme)

        imgui.Spacing()

        imgui.Text('Dots:')
        imgui.SameLine(100)
        Components.LoadingSpinner.dots('Processing', theme)

        imgui.Spacing()

        imgui.Text('Pulse:')
        imgui.SameLine(100)
        Components.LoadingSpinner.pulse('Waiting', theme)

        imgui.Spacing()

        imgui.Text('Progress:')
        imgui.SameLine(100)
        local progress = ((os.clock() - State.animStartTime) % 5) / 5
        Components.LoadingSpinner.bar(progress, 1, theme, { width = 150, showText = true })

        imgui.Spacing()

        imgui.Text('Indeterminate:')
        imgui.SameLine(100)
        Components.LoadingSpinner.indeterminate('Syncing', theme, { width = 150 })

        imgui.Spacing()

        imgui.Text('Mini (inline):')
        imgui.SameLine(100)
        imgui.Text('Loading data')
        Components.LoadingSpinner.inline(theme)
    else
        imgui.TextColored(0.5, 0.5, 0.5, 1, 'Enable "Show spinners" in Inputs tab')
    end
end

local function renderLayoutTab()
    local theme = State.themeName

    -- Setting Cards
    Components.SettingGroup.section('Setting Cards', theme)

    if Components.SettingCard.begin('Combat Settings', theme, { icon = '⚔' }) then
        imgui.Text('Enable auto-assist')
        imgui.Text('Enable auto-target')
        imgui.Text('Stick distance: 15')
    end
    Components.SettingCard.finish()

    -- Collapsible card
    local isOpen, finishFn = Components.SettingCard.collapsible('Advanced Options', theme, { icon = '⚙' })
    if isOpen then
        imgui.Text('Debug mode: Off')
        imgui.Text('Log level: Info')
        imgui.Text('Update rate: 100ms')
        finishFn()
    end

    imgui.Spacing()

    -- Tooltips
    Components.SettingGroup.section('Rich Tooltips', theme)

    imgui.Text('Hover over buttons for tooltips:')
    imgui.Spacing()

    imgui.Button('Simple Tooltip')
    if imgui.IsItemHovered() then
        Components.Tooltip.simple('Simple Tooltip', 'This is a basic tooltip with a header and description.', theme)
    end

    imgui.SameLine()

    imgui.Button('Ability Tooltip')
    if imgui.IsItemHovered() then
        Components.Tooltip.ability('Complete Heal', {
            duration = 'Instant',
            reuse = '12s',
            remaining = 5,
            total = 12,
            description = 'Heals your target for 100% of their maximum health.',
        }, theme)
    end

    imgui.SameLine()

    imgui.Button('Stat Tooltip')
    if imgui.IsItemHovered() then
        Components.Tooltip.begin(theme)
        Components.Tooltip.header('Character Stats')
        Components.Tooltip.stat('Level', '70')
        Components.Tooltip.stat('Class', 'Cleric')
        Components.Tooltip.stat('HP', '12,500', { 0.4, 1.0, 0.4 })
        Components.Tooltip.stat('Mana', '8,000', { 0.4, 0.6, 1.0 })
        Components.Tooltip.separator()
        Components.Tooltip.bar('Experience', 65, 100, { 0.6, 0.4, 0.8 })
        Components.Tooltip.finish()
    end
end

-- ============================================================
-- TEXTURES TAB
-- ============================================================

local TextureRenderer = nil
local _textureRendererLoaded = false

local function getTextureRenderer()
    if _textureRendererLoaded then return TextureRenderer end
    _textureRendererLoaded = true
    local ok, tr = pcall(require, 'sidekick-next.ui.texture_renderer')
    if ok and tr then TextureRenderer = tr end
    return TextureRenderer
end

-- Curated list of background/panel textures to display
local TEXTURE_GALLERY = {
    { category = 'Full Backgrounds (Tileable)', items = {
        { name = 'A_Listbox_Background1', label = 'Dark Rock (256x256)', desc = 'wnd_bg_dark_rock.tga' },
        { name = 'A_Listbox_Background2', label = 'Dark Rock Half (128x256)', desc = 'wnd_bg_dark_rock.tga' },
        { name = 'A_LightRockFrameTopBottom', label = 'Light Rock Top/Bottom (256x30)', desc = 'wnd_bg_light_rock.tga' },
        { name = 'A_LightRockFrameSide', label = 'Light Rock Side (30x256)', desc = 'wnd_bg_light_rock.tga' },
    }},
    { category = 'Window Backgrounds', items = {
        { name = 'ACTW_bg_TX', label = 'Action Window (121x173)', desc = 'classic_pieces04.tga' },
        { name = 'GW_bg_TX', label = 'Group Window (95x124)', desc = 'classic_pieces03.tga' },
        { name = 'TW_bgtop_TX', label = 'Target Window Top (121x256)', desc = 'classic_pieces03.tga' },
        { name = 'TW_bgbot_TX', label = 'Target Window Bot (121x29)', desc = 'classic_pieces03.tga' },
        { name = 'PW_bg_stats_TX', label = 'Player Stats (95x82)', desc = 'classic_pieces03.tga' },
        { name = 'IW_bg_stats_TX', label = 'Inventory Stats (114x180)', desc = 'classic_pieces05.tga' },
        { name = 'IW_bg_player_TX', label = 'Inventory Player (95x123)', desc = 'classic_pieces05.tga' },
        { name = 'IW_bg_exp_TX', label = 'Inventory Exp (95x81)', desc = 'classic_pieces03.tga' },
        { name = 'IW_bg_bags_1_TX', label = 'Inventory Bags 1 (103x75)', desc = 'classic_pieces05.tga' },
        { name = 'IW_bg_bags_2_TX', label = 'Inventory Bags 2 (103x123)', desc = 'classic_pieces05.tga' },
        { name = 'IW_bg_autoequip_TX', label = 'Auto Equip (188x63)', desc = 'classic_pieces04.tga' },
        { name = 'BW_bgbot_TX', label = 'Bank Window Bot (121x21)', desc = 'classic_pieces03.tga' },
    }},
    { category = 'Overlap / Side Panels', items = {
        { name = 'LEFTW_Overlap_bg_1_TX', label = 'Left Overlap 1 (119x256)', desc = 'classic_bg_left.tga' },
        { name = 'LEFTW_Overlap_bg_2_TX', label = 'Left Overlap 2 (119x240)', desc = 'classic_bg_left.tga' },
        { name = 'LEFT_bg_top', label = 'Left Top (119x7)', desc = 'classic_pieces01.tga' },
        { name = 'LEFT_bg_bottom', label = 'Left Bottom (119x7)', desc = 'classic_pieces01.tga' },
        { name = 'LEFT_bg_bottomright', label = 'Left Bottom Right (7x153)', desc = 'classic_bg_left.tga' },
        { name = 'SELW_bg_Inv_Normal', label = 'Select Inv Normal (71x175)', desc = 'classic_pieces01.tga' },
    }},
    { category = 'Special Backgrounds', items = {
        { name = 'A_ChatBackground', label = 'Chat Background (172x143)', desc = 'classic_chat01.tga' },
        { name = 'PNW_BackgroundTexture', label = 'Note Background (201x185)', desc = 'note01.tga' },
        { name = 'A_SpellGemBackground', label = 'Spell Gem Bg (36x32)', desc = 'window_pieces02.tga' },
        { name = 'IW_GearSlot_TX', label = 'Gear Slot (49x48)', desc = 'classic_pieces02.tga' },
    }},
    { category = 'Gauge Backgrounds', items = {
        { name = 'A_Classic_GaugeBackground', label = 'Classic Gauge Bg (65x12)', desc = 'classic_pieces02.tga' },
        { name = 'A_GaugeBackground', label = 'Standard Gauge Bg (100x8)', desc = 'window_pieces01.tga' },
    }},
    { category = 'Gauge Fills', items = {
        { name = 'A_Classic_GaugeFill', label = 'Gauge Fill 1 (65x12)', desc = 'Health' },
        { name = 'A_Classic_GaugeFill2', label = 'Gauge Fill 2 (65x12)', desc = 'Endurance' },
        { name = 'A_Classic_GaugeFill3', label = 'Gauge Fill 3 (65x12)', desc = 'Alt Fill' },
        { name = 'A_Classic_GaugeFill4', label = 'Gauge Fill 4 (65x12)', desc = 'Alt Fill' },
        { name = 'A_Classic_GaugeFill5', label = 'Gauge Fill 5 (65x12)', desc = 'Mana' },
        { name = 'A_Classic_GaugeFill6', label = 'Gauge Fill 6 (65x12)', desc = 'Alt Fill' },
    }},
    { category = 'Gauge Parts', items = {
        { name = 'A_Classic_GaugeEndCapLeft', label = 'Endcap Left (10x12)', desc = 'classic_pieces02.tga' },
        { name = 'A_Classic_GaugeEndCapRight', label = 'Endcap Right (10x12)', desc = 'classic_pieces02.tga' },
        { name = 'A_Classic_GaugeLines', label = 'Gauge Lines (65x12)', desc = 'classic_pieces02.tga' },
        { name = 'A_Classic_GaugeLinesFill', label = 'Gauge Lines Fill (65x12)', desc = 'classic_pieces02.tga' },
    }},
    { category = 'Buttons', items = {
        { name = 'A_BtnNormal', label = 'Btn Normal (96x19)', desc = 'window_pieces03.tga' },
        { name = 'A_BtnFlyby', label = 'Btn Hover (96x19)', desc = 'window_pieces03.tga' },
        { name = 'A_BtnPressed', label = 'Btn Pressed (96x19)', desc = 'window_pieces03.tga' },
        { name = 'A_BtnDisabled', label = 'Btn Disabled (96x19)', desc = 'window_pieces03.tga' },
        { name = 'A_BigBtnNormal', label = 'Big Btn Normal (120x24)', desc = 'window_pieces03.tga' },
        { name = 'A_BigBtnFlyby', label = 'Big Btn Hover (120x24)', desc = 'window_pieces03.tga' },
        { name = 'A_BigBtnPressed', label = 'Big Btn Pressed (120x24)', desc = 'window_pieces03.tga' },
        { name = 'A_SmallBtnNormal', label = 'Small Btn Normal (48x19)', desc = 'window_pieces03.tga' },
        { name = 'A_SmallBtnFlyby', label = 'Small Btn Hover (48x19)', desc = 'window_pieces03.tga' },
        { name = 'A_SmallBtnPressed', label = 'Small Btn Pressed (48x19)', desc = 'window_pieces03.tga' },
    }},
    { category = 'Cast Bar Parts', items = {
        { name = 'A_Castbar_bg1a_TX', label = 'Castbar Bg 1a (38x136)', desc = 'window_pieces02.tga' },
        { name = 'A_Castbar_bg1b_TX', label = 'Castbar Bg 1b (38x136)', desc = 'window_pieces02.tga' },
        { name = 'A_Castbar_bg1c_TX', label = 'Castbar Bg 1c (38x59)', desc = 'window_pieces02.tga' },
    }},
    { category = 'Misc Backgrounds', items = {
        { name = 'BRTW_Bg1_TX', label = 'Breath Bg1 (95x7)', desc = 'classic_pieces03.tga' },
        { name = 'BRTW_Bg2_TX', label = 'Breath Bg2 (95x16)', desc = 'classic_pieces03.tga' },
        { name = 'CSTW_Bg1_TX', label = 'Cast Bg1 (95x7)', desc = 'classic_pieces03.tga' },
        { name = 'CSTW_Bg2_TX', label = 'Cast Bg2 (95x16)', desc = 'classic_pieces03.tga' },
        { name = 'BlueIconBackground', label = 'Blue Icon Bg (104x19)', desc = 'classic_debug01.tga' },
        { name = 'RedIconBackground', label = 'Red Icon Bg (104x19)', desc = 'classic_debug01.tga' },
        { name = 'IW_bg_done_TX', label = 'Done Bg (255x36)', desc = 'classic_debug01.tga' },
    }},
    { category = 'Drop Shadows', items = {
        { name = 'ACTW_bg_dropshadow_bottom_TX', label = 'Shadow Bottom (85x5)', desc = 'classic_pieces05.tga' },
        { name = 'ACTW_bg_dropshadow_left_TX', label = 'Shadow Left (5x120)', desc = 'classic_pieces05.tga' },
    }},
}

-- Full raw texture files to display
local RAW_TEXTURES = {
    { name = 'wnd_bg_dark_rock.tga', label = 'Dark Rock (full 256x256)', w = 256, h = 256 },
    { name = 'wnd_bg_light_rock.tga', label = 'Light Rock (full 256x256)', w = 256, h = 256 },
    { name = 'classic_bg_left.tga', label = 'Classic Left (full 128x256)', w = 128, h = 256 },
    { name = 'classic_bg_right.tga', label = 'Classic Right (full 128x256)', w = 128, h = 256 },
}

local function renderTexturesTab()
    local TR = getTextureRenderer()

    if not TR then
        imgui.TextColored(1, 0.3, 0.3, 1, 'TextureRenderer not available')
        return
    end

    if not TR.isAvailable or not TR.isAvailable() then
        imgui.TextColored(1, 0.3, 0.3, 1, 'Texture data not loaded')
        return
    end

    local dl = imgui.GetWindowDrawList()
    if not dl then
        imgui.TextColored(1, 0.3, 0.3, 1, 'DrawList not available')
        return
    end

    -- Render full raw texture files first
    if imgui.CollapsingHeader('Raw Texture Files (Full)') then
        imgui.Indent(8)
        for _, entry in ipairs(RAW_TEXTURES) do
            local tex = TR.getTexture(entry.name)
            if tex then
                local texId = tex:GetTextureID()
                if texId then
                    imgui.Text(entry.label)

                    -- Draw at half scale to fit
                    local scale = 0.5
                    local drawW = entry.w * scale
                    local drawH = entry.h * scale

                    local sx, sy = imgui.GetCursorScreenPos()
                    if type(sx) == 'table' then
                        sy = sx.y or sx[2]
                        sx = sx.x or sx[1]
                    end

                    imgui.Dummy(drawW, drawH)

                    pcall(function()
                        local ImVec2 = ImVec2 or imgui.ImVec2
                        if ImVec2 then
                            dl:AddImage(texId, ImVec2(sx, sy), ImVec2(sx + drawW, sy + drawH),
                                       ImVec2(0, 0), ImVec2(1, 1))
                        else
                            dl:AddImage(texId, sx, sy, sx + drawW, sy + drawH, 0, 0, 1, 1)
                        end
                    end)

                    imgui.Spacing()
                end
            else
                imgui.TextColored(0.5, 0.5, 0.5, 1, entry.label .. ' (not found)')
            end
        end
        imgui.Unindent(8)
        imgui.Spacing()
    end

    -- Render animation-based textures by category
    for _, cat in ipairs(TEXTURE_GALLERY) do
        if imgui.CollapsingHeader(cat.category) then
            imgui.Indent(8)
            for _, entry in ipairs(cat.items) do
                local uv = TR.getAnimUV(entry.name)
                if uv then
                    -- Scale: show at native size, but cap height at 150
                    local drawW = uv.srcW
                    local drawH = uv.srcH
                    local maxH = 150
                    if drawH > maxH then
                        local s = maxH / drawH
                        drawW = drawW * s
                        drawH = maxH
                    end

                    imgui.Text(entry.label)
                    imgui.SameLine(250)
                    imgui.TextColored(0.6, 0.6, 0.6, 1, entry.name)

                    local sx, sy = imgui.GetCursorScreenPos()
                    if type(sx) == 'table' then
                        sy = sx.y or sx[2]
                        sx = sx.x or sx[1]
                    end

                    imgui.Dummy(drawW, drawH)

                    pcall(function()
                        TR.drawAnim(dl, entry.name, sx, sy, drawW, drawH)
                    end)

                    imgui.Spacing()
                else
                    imgui.TextColored(0.5, 0.5, 0.5, 1, entry.label .. ' (' .. entry.name .. ') - not found')
                end
            end
            imgui.Unindent(8)
            imgui.Spacing()
        end
    end
end

-- ============================================================
-- MAIN RENDER FUNCTION
-- ============================================================

local function renderDemoWindow()
    if not State.open then return end

    -- Apply theme
    local style = Themes.getWindowStyle(State.themeName)
    local colorsPushed = 0

    if imgui.PushStyleColor and ImGuiCol and style then
        if style.WindowBg then
            pcall(function()
                imgui.PushStyleColor(ImGuiCol.WindowBg, style.WindowBg[1], style.WindowBg[2], style.WindowBg[3], 0.98)
                colorsPushed = colorsPushed + 1
            end)
        end
        if style.Border then
            pcall(function()
                imgui.PushStyleColor(ImGuiCol.Border, style.Border[1], style.Border[2], style.Border[3], 0.8)
                colorsPushed = colorsPushed + 1
            end)
        end
    end

    imgui.SetNextWindowSize(650, 550, ImGuiCond.FirstUseEver or 0)

    State.open, State.draw = imgui.Begin('SideKick UI Components Demo##ComponentsDemo', State.open)

    if State.draw then
        -- Theme selector at top
        imgui.Text('Active Theme:')
        imgui.SameLine()
        imgui.PushItemWidth(120)
        if imgui.BeginCombo('##theme_select', State.themeName) then
            for _, name in ipairs(THEME_NAMES) do
                if imgui.Selectable(name, name == State.themeName) then
                    State.themeName = name
                    for i, n in ipairs(THEME_NAMES) do
                        if n == name then State.selectedTheme = i break end
                    end
                end
            end
            imgui.EndCombo()
        end
        imgui.PopItemWidth()

        imgui.Separator()
        imgui.Spacing()

        -- Tab bar
        if imgui.BeginTabBar('##demo_tabs') then
            for i, tab in ipairs(TABS) do
                local tabLabel = tab.icon .. ' ' .. tab.name
                if imgui.BeginTabItem(tabLabel) then
                    State.activeTab = i
                    imgui.Spacing()

                    -- Render tab content
                    if i == 1 then renderButtonsTab()
                    elseif i == 2 then renderBadgesTab()
                    elseif i == 3 then renderBarsTab()
                    elseif i == 4 then renderInputsTab()
                    elseif i == 5 then renderTablesTab()
                    elseif i == 6 then renderFeedbackTab()
                    elseif i == 7 then renderLayoutTab()
                    elseif i == 8 then renderTexturesTab()
                    end

                    imgui.EndTabItem()
                end
            end
            imgui.EndTabBar()
        end
    end

    imgui.End()

    -- Pop colors
    if colorsPushed > 0 then
        pcall(imgui.PopStyleColor, colorsPushed)
    end

    -- Render toasts (must be outside window)
    Components.Toast.render(State.themeName)
end

-- ============================================================
-- PUBLIC API
-- ============================================================

function M.toggle()
    State.open = not State.open
end

function M.show()
    State.open = true
end

function M.hide()
    State.open = false
end

function M.isOpen()
    return State.open
end

-- ============================================================
-- STANDALONE EXECUTION
-- ============================================================

M.render = renderDemoWindow

-- For standalone execution, call M.run()
function M.run()
    mq.imgui.init('SideKickComponentsDemo', renderDemoWindow)

    print('\ay[SideKick]\ax UI Components Demo loaded.')
    print('\ay[SideKick]\ax Close the window or /lua stop to exit.')

    while State.open do
        mq.delay(100)
    end

    print('\ay[SideKick]\ax UI Components Demo closed.')
end

-- Auto-run when executed standalone via /lua run
-- (require passes a dotted module name as ..., /lua run does not)
local _loadedAs = ...
if not _loadedAs or not tostring(_loadedAs):find('%.') then
    M.run()
end

return M
