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
    buffingEnabled, changed = imgui.Checkbox('Enable Buffing', buffingEnabled)
    if changed and onChange then onChange('BuffingEnabled', buffingEnabled) end

    if buffingEnabled then
        imgui.Separator()
        imgui.Text('Buff Targets')

        -- Self only
        local selfOnly = settings.BuffSelfOnly == true
        selfOnly, changed = imgui.Checkbox('Self Buffs Only', selfOnly)
        if changed and onChange then onChange('BuffSelfOnly', selfOnly) end

        if not selfOnly then
            -- Group
            local buffGroup = settings.BuffGroupEnabled ~= false
            buffGroup, changed = imgui.Checkbox('Buff Group Members', buffGroup)
            if changed and onChange then onChange('BuffGroupEnabled', buffGroup) end

            -- Pets
            local buffPets = settings.BuffPetsEnabled ~= false
            buffPets, changed = imgui.Checkbox('Buff Pets', buffPets)
            if changed and onChange then onChange('BuffPetsEnabled', buffPets) end

            -- Raid
            local buffRaid = settings.BuffRaidEnabled == true
            buffRaid, changed = imgui.Checkbox('Buff Raid Members', buffRaid)
            if changed and onChange then onChange('BuffRaidEnabled', buffRaid) end

            -- Fellowship
            local buffFellowship = settings.BuffFellowshipEnabled == true
            buffFellowship, changed = imgui.Checkbox('Buff Fellowship', buffFellowship)
            if changed and onChange then onChange('BuffFellowshipEnabled', buffFellowship) end
        end

        imgui.Separator()
        imgui.Text('Buff Behavior')

        -- Rebuff window
        local rebuffWindow = tonumber(settings.BuffRebuffWindow) or 60
        rebuffWindow, changed = imgui.SliderInt('Rebuff Window (sec)', rebuffWindow, 10, 300)
        if changed and onChange then onChange('BuffRebuffWindow', rebuffWindow) end
        if imgui.IsItemHovered() then
            Settings.safeTooltip('Rebuff when this many seconds remain on existing buff')
        end

        -- Allow in combat
        local allowCombat = settings.BuffAllowInCombat == true
        allowCombat, changed = imgui.Checkbox('Allow Buffing In Combat', allowCombat)
        if changed and onChange then onChange('BuffAllowInCombat', allowCombat) end

        -- Coordinate via Actors
        local coordActors = settings.BuffCoordinateActors ~= false
        coordActors, changed = imgui.Checkbox('Coordinate via Actors', coordActors)
        if changed and onChange then onChange('BuffCoordinateActors', coordActors) end
        if imgui.IsItemHovered() then
            Settings.safeTooltip('Share buff status with other SideKick instances to avoid double-buffing')
        end

        -- Aura selection (if applicable)
        local auraSelection = settings.AuraSelection or ''
        if auraSelection ~= '' or imgui.CollapsingHeader('Aura Settings') then
            local buf = imgui.InputText('Aura Selection', auraSelection, 128)
            if buf ~= auraSelection and onChange then
                onChange('AuraSelection', buf)
            end
            if imgui.IsItemHovered() then
                Settings.safeTooltip('Name of aura to maintain (leave blank for auto-detect)')
            end
        end
    end
end

return M
