-- ============================================================
-- SideKick Settings - Buffs Tab
-- ============================================================
-- Buffing behavior settings.

local imgui = require('ImGui')
local Settings = require('sidekick-next.ui.settings')

local M = {}

function M.draw(settings, themeNames, onChange)
    local changed

    -- Main toggle
    local buffingEnabled = settings.BuffingEnabled ~= false
    buffingEnabled, changed = Settings.labeledCheckbox('Enable Buffing', buffingEnabled)
    if changed and onChange then onChange('BuffingEnabled', buffingEnabled) end

    if buffingEnabled then
        imgui.Separator()
        imgui.Text('Buff Targets')

        -- Pets
        local buffPets = settings.BuffPetsEnabled ~= false
        buffPets, changed = Settings.labeledCheckbox('Buff Pets', buffPets)
        if changed and onChange then onChange('BuffPetsEnabled', buffPets) end

        imgui.Separator()
        imgui.Text('Buff Behavior')
        imgui.TextDisabled('No buff behavior settings available.')
    end
end

return M
