-- ============================================================
-- SideKick Settings - Remote Tab
-- ============================================================
-- Remote abilities and cross-character control settings.

local imgui = require('ImGui')
local Settings = require('sidekick-next.ui.settings')

local M = {}

-- Lazy-load RemoteAbilities module
local _RemoteAbilities = nil
local function getRemoteAbilities()
    if not _RemoteAbilities then
        local ok, mod = pcall(require, 'sidekick-next.ui.remote_abilities')
        if ok then _RemoteAbilities = mod end
    end
    return _RemoteAbilities
end

function M.draw(settings, themeNames, onChange)
    local changed
    local RemoteAbilities = getRemoteAbilities()

    imgui.TextColored(0.7, 0.9, 1.0, 1.0, 'Remote Abilities')
    imgui.Separator()

    imgui.TextWrapped('Remote abilities allow you to trigger abilities on other characters running SideKick.')

    imgui.Spacing()

    -- Show remote abilities UI if available
    if RemoteAbilities and RemoteAbilities.draw then
        local ok, err = pcall(function()
            RemoteAbilities.draw(settings, onChange)
        end)
        if not ok then
            imgui.TextColored(1, 0.3, 0.3, 1, 'Error loading remote abilities:')
            imgui.TextWrapped(tostring(err))
        end
    else
        imgui.TextDisabled('Remote abilities module not loaded')

        -- Provide basic info
        imgui.Spacing()
        imgui.Text('Features:')
        imgui.BulletText('Send ability commands to other characters')
        imgui.BulletText('View ability status on remote characters')
        imgui.BulletText('Coordinate cooldowns across your group')
    end

    -- Fallback settings if module not loaded
    if not RemoteAbilities then
        imgui.Separator()
        imgui.Text('Manual Configuration')

        -- This would typically be handled by the RemoteAbilities module
        -- but we provide a fallback for basic settings
        imgui.TextDisabled('Configure remote targets in the RemoteAbilities module')
    end
end

return M
