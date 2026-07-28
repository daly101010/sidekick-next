local imgui = require('ImGui')
local Settings = require('sidekick-next.ui.settings.init')
local Components = require('sidekick-next.ui.components')
local Logger = require('sidekick-next.utils.logger')

local M = {}

local LEVEL_NAMES = { 'error', 'warn', 'info', 'debug', 'verbose' }
local MODULE_LEVELS = {
    { label = 'Inherit', value = nil },
    { label = 'Off', value = 0 },
    { label = 'Error', value = 1 },
    { label = 'Warn', value = 2 },
    { label = 'Info', value = 3 },
    { label = 'Debug', value = 4 },
    { label = 'Verbose', value = 5 },
}

local function apply(onChange, key, value, settings)
    settings[key] = value
    if onChange then onChange(key, value) end
    Logger.configure(settings)
end

local function moduleLevelLabel(value)
    if value == nil then return 'Inherit' end
    for _, option in ipairs(MODULE_LEVELS) do
        if option.value == value then return option.label end
    end
    return tostring(value)
end

local function selectableClicked(label, selected)
    local first, second = imgui.Selectable(label, selected)
    if second == nil then return first == true end
    return second == true
end

function M.draw(settings, themeNames, onChange)
    local themeName = settings.SideKickTheme or 'Classic'
    Components.SettingGroup.section('Process-wide Diagnostics', themeName)
    imgui.TextWrapped('These settings are persisted by the UI process and applied by the coordinator and every worker after the next settings revision.')
    imgui.Spacing()

    Components.SettingGroup.draw('General Logger', function()
        local level = math.max(1, math.min(5, tonumber(settings.SideKickLogLevel) or 3))
        local selected = Settings.labeledCombo('Level', LEVEL_NAMES[level], LEVEL_NAMES,
            'Info is the normal default. Debug and verbose can be noisy during combat.')
        local selectedLevel = level
        for i, name in ipairs(LEVEL_NAMES) do
            if selected == name then selectedLevel = i break end
        end
        if selectedLevel ~= level then
            apply(onChange, 'SideKickLogLevel', selectedLevel, settings)
        end

        local fileEnabled = settings.SideKickLogFile == true
        local fileValue, fileChanged = Components.CheckboxRow.draw('Write General Log File', 'SideKickLogFile', fileEnabled, nil, {
            tooltip = 'Writes the general SideKick logger for the UI, coordinator, and workers. Healing Intelligence has its own detailed healing log.',
        })
        if fileChanged then apply(onChange, 'SideKickLogFile', fileValue, settings) end

        local filter = tostring(settings.SideKickLogFilter or '')
        local newFilter = Settings.labeledInputText('Filter', filter,
            'Optional case-insensitive text filter. Separate alternatives with |, for example heal|buff.')
        if newFilter ~= filter then apply(onChange, 'SideKickLogFilter', newFilter, settings) end
    end, { id = 'general_logger', defaultOpen = true })

    Components.SettingGroup.draw('Per-Module Detail', function()
        imgui.TextWrapped('Override only the workers being diagnosed. Debug logs decisions and claims; Verbose also emits a one-second state snapshot. Off suppresses that module even when the global level is higher.')
        imgui.Spacing()

        local levels = Logger.decodeModuleLevels(settings.SideKickModuleLogLevels)
        local changed = false
        if imgui.BeginTable('##module_log_levels', 2,
            bit32.bor(ImGuiTableFlags.RowBg, ImGuiTableFlags.BordersInnerH)) then
            imgui.TableSetupColumn('Module', ImGuiTableColumnFlags.WidthStretch)
            imgui.TableSetupColumn('Level', ImGuiTableColumnFlags.WidthFixed, 120)
            imgui.TableHeadersRow()
            for _, moduleInfo in ipairs(Logger.getKnownModules()) do
                imgui.PushID(moduleInfo.key)
                imgui.TableNextRow()
                imgui.TableNextColumn()
                imgui.Text(moduleInfo.label)
                imgui.TableNextColumn()
                local current = levels[moduleInfo.key]
                if imgui.BeginCombo('##level', moduleLevelLabel(current)) then
                    for _, option in ipairs(MODULE_LEVELS) do
                        if selectableClicked(option.label, current == option.value) then
                            levels[moduleInfo.key] = option.value
                            changed = true
                        end
                        if current == option.value then imgui.SetItemDefaultFocus() end
                    end
                    imgui.EndCombo()
                end
                imgui.PopID()
            end
            imgui.EndTable()
        end

        if changed then
            apply(onChange, 'SideKickModuleLogLevels', Logger.encodeModuleLevels(levels), settings)
        end
        if imgui.SmallButton('Reset All to Inherit##module_logs_reset') then
            apply(onChange, 'SideKickModuleLogLevels', '', settings)
        end
        imgui.TextDisabled('The text filter still applies. Enable "Write General Log File" above to retain the trace.')
    end, { id = 'module_logger', defaultOpen = true })

    imgui.TextDisabled('Commands: /skloglevel 1-5, /sklogmodule <module> <level|inherit>, /sklogfilter text|clear, /sklogfile on|off')
end

return M
