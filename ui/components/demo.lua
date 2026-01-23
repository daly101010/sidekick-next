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
local THEME_NAMES = {}
for name, _ in pairs(Themes.getThemeList and Themes.getThemeList() or {}) do
    table.insert(THEME_NAMES, name)
end
table.sort(THEME_NAMES)
if #THEME_NAMES == 0 then
    THEME_NAMES = { 'Classic', 'Dark', 'Neon', 'Forest', 'Blood', 'Royal', 'Velious', 'Kunark' }
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
}

-- ============================================================
-- TAB CONTENT RENDERERS
-- ============================================================

local function renderButtonsTab()
    local theme = State.themeName

    -- Themed Toggle Buttons
    Components.SettingGroup.section('Toggle Buttons', theme)

    imgui.Text('Standard toggles:')
    imgui.SameLine(120)
    State.toggleState = Components.ThemedButton.toggle('Enabled', State.toggleState, theme)
    imgui.SameLine()
    Components.ThemedButton.toggle('Disabled', false, theme)
    imgui.SameLine()
    Components.ThemedButton.toggle('Active', true, theme)

    imgui.Spacing()

    -- Icon Buttons
    Components.SettingGroup.section('Icon Buttons', theme)

    imgui.Text('Square buttons:')
    imgui.SameLine(120)
    if Components.IconButton.draw('⚙', 'Settings', theme) then
        Components.Toast.info('Settings clicked!')
    end
    imgui.SameLine()
    if Components.IconButton.draw('↻', 'Refresh', theme) then
        Components.Toast.success('Refreshed!')
    end
    imgui.SameLine()
    if Components.IconButton.draw('+', 'Add', theme) then
        Components.Toast.info('Add clicked')
    end
    imgui.SameLine()
    Components.IconButton.draw('×', 'Close (disabled)', theme, { disabled = true })

    imgui.Spacing()

    imgui.Text('Toggle icons:')
    imgui.SameLine(120)
    State.playPaused = Components.IconButton.toggle(
        State.playPaused and '⏸' or '▶',
        State.playPaused and 'Pause' or 'Play',
        State.playPaused, theme
    )
    imgui.SameLine()
    State.lockState = Components.IconButton.toggle(
        State.lockState and '🔒' or '🔓',
        State.lockState and 'Locked' or 'Unlocked',
        State.lockState, theme
    )

    imgui.Spacing()

    imgui.Text('Circular:')
    imgui.SameLine(120)
    Components.IconButton.circular('♥', 'Health', theme)
    imgui.SameLine()
    Components.IconButton.circular('◆', 'Mana', theme)
    imgui.SameLine()
    Components.IconButton.circular('⚔', 'Combat', theme)

    imgui.Spacing()

    imgui.Text('With label:')
    imgui.SameLine(120)
    if Components.IconButton.withLabel('💾', 'Save Settings', theme) then
        Components.Toast.success('Settings saved!')
    end

    imgui.Spacing()

    -- Radio group
    Components.SettingGroup.section('Radio Button Group', theme)

    local radioButtons = {
        { icon = '▤', tooltip = 'List view' },
        { icon = '▦', tooltip = 'Grid view' },
        { icon = '▧', tooltip = 'Compact view' },
    }
    imgui.Text('View mode:')
    imgui.SameLine(120)
    State.radioSelection = Components.IconButton.radio(radioButtons, State.radioSelection, theme)
    imgui.SameLine()
    imgui.Text('  Selected: ' .. State.radioSelection)

    imgui.Spacing()

    -- Keybind badges
    Components.SettingGroup.section('Keybind Badges', theme)

    imgui.Text('Single key:')
    imgui.SameLine(120)
    Components.KeybindBadge.draw('F1', theme)
    imgui.SameLine()
    Components.KeybindBadge.draw('Esc', theme)
    imgui.SameLine()
    Components.KeybindBadge.draw('Space', theme)

    imgui.Spacing()

    imgui.Text('Key combos:')
    imgui.SameLine(120)
    Components.KeybindBadge.combo('Ctrl+S', theme)
    imgui.SameLine()
    Components.KeybindBadge.combo({'Alt', 'F4'}, theme)

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
    Components.ResourceBar.health(7500, 10000, { width = 200, showPercent = true })

    imgui.Text('Health (low):')
    imgui.SameLine(80)
    Components.ResourceBar.health(2000, 10000, { width = 200, showPercent = true })

    imgui.Text('Mana:')
    imgui.SameLine(80)
    Components.ResourceBar.mana(4500, 8000, { width = 200, showText = true })

    imgui.Text('Endurance:')
    imgui.SameLine(80)
    Components.ResourceBar.endurance(6000, 6000, { width = 200, showPercent = true })

    imgui.Text('Experience:')
    imgui.SameLine(80)
    Components.ResourceBar.experience(35, 100, { width = 200, showPercent = true })

    imgui.Text('Aggro:')
    imgui.SameLine(80)
    Components.ResourceBar.aggro(85, 100, { width = 200, showPercent = true })

    imgui.Spacing()

    -- Cooldown bars
    Components.SettingGroup.section('Cooldown Bars', theme)

    local elapsed = (os.clock() - State.animStartTime) % 10

    imgui.Text('Cooldown:')
    imgui.SameLine(80)
    Components.ResourceBar.cooldown(10 - elapsed, 10, { width = 200 })

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

    Components.ResourceBar.labeledHealth('Warrior', 9500, 12000, { width = 150, showPercent = true })
    Components.ResourceBar.labeledHealth('Cleric', 6000, 8000, { width = 150, showPercent = true })
    Components.ResourceBar.labeledHealth('Wizard', 3500, 5000, { width = 150, showPercent = true })
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

    State.sliderValue = Components.SliderRow.int('Volume', State.sliderValue, 0, 100, theme, {
        width = 150,
        format = '%d%%',
    })

    imgui.Spacing()

    -- Combo Row
    Components.SettingGroup.section('Theme Selector (Combo)', theme)

    local themeChanged
    State.selectedTheme, themeChanged = Components.ComboRow.draw('Theme', State.selectedTheme, THEME_NAMES, theme, {
        width = 150,
    })
    if themeChanged and THEME_NAMES[State.selectedTheme] then
        State.themeName = THEME_NAMES[State.selectedTheme]
    end

    imgui.Spacing()

    -- Checkbox Row
    Components.SettingGroup.section('Checkbox Row', theme)

    State.spinnerDemo = Components.CheckboxRow.draw('Show spinners', State.spinnerDemo, theme)
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

    imgui.SetNextWindowSize(550, 500, ImGuiCond.FirstUseEver or 0)

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

return M
