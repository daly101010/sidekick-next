local imgui = require('ImGui')
local Settings = require('sidekick-next.ui.settings.init')
local Components = require('sidekick-next.ui.components')
local Logger = require('sidekick-next.utils.logger')

local M = {}

local LEVEL_NAMES = { 'error', 'warn', 'info', 'debug', 'verbose' }

local function apply(onChange, key, value, settings)
    if onChange then onChange(key, value) end
    Logger.configure(settings)
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

    imgui.TextDisabled('Commands: /skloglevel 1-5, /sklogfilter text|clear, /sklogfile on|off')
end

return M
