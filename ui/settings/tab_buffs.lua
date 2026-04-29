-- ============================================================
-- SideKick Settings - Buffs Tab
-- ============================================================
-- Buffing behavior settings.

local imgui = require('ImGui')
local Settings = require('sidekick-next.ui.settings')
local Components = require('sidekick-next.ui.components')

local M = {}

function M.draw(settings, themeNames, onChange)
    local themeName = settings.SideKickTheme or 'Classic'

    -- Main toggle (clickable badge)
    local buffingEnabled = settings.BuffingEnabled ~= false

    -- Toggle badge for buffing (clickable to toggle)
    local buffVal, buffChanged = Components.StatusBadge.toggle('Buffing', buffingEnabled, themeName, {
        enabledText = 'Active',
        disabledText = 'Off',
        tooltip = 'Click to toggle automatic buffing',
    })
    if buffChanged and onChange then onChange('BuffingEnabled', buffVal) end
    buffingEnabled = buffVal

    if buffingEnabled then
        Components.SettingGroup.draw('Buff Targets', function()
            -- Pets
            local buffPets = settings.BuffPetsEnabled ~= false
            local petVal, petChanged = Components.CheckboxRow.draw('Buff Pets', 'BuffPetsEnabled', buffPets, nil, {
                tooltip = 'Include group pets in buff rotation',
            })
            if petChanged and onChange then onChange('BuffPetsEnabled', petVal) end
        end, { id = 'buff_targets', defaultOpen = true })

        Components.SettingGroup.draw('Buff Behavior', function()
            imgui.TextDisabled('No buff behavior settings available.')
        end, { id = 'buff_behavior', defaultOpen = false })
    end
end

return M
