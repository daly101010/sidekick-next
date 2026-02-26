-- ============================================================
-- SideKick Settings - Integration Tab
-- ============================================================
-- Actors, autostart, and external system integration settings.

local imgui = require('ImGui')
local Settings = require('sidekick-next.ui.settings')
local Components = require('sidekick-next.ui.components')

local M = {}

-- Lazy-load ActorsCoordinator
local _ActorsCoordinator = nil
local function getActorsCoordinator()
    if not _ActorsCoordinator then
        local ok, mod = pcall(require, 'sidekick-next.utils.actors_coordinator')
        if ok then _ActorsCoordinator = mod end
    end
    return _ActorsCoordinator
end

function M.draw(settings, themeNames, onChange)
    local themeName = settings.Theme or 'Classic'

    -- ========== ACTORS SECTION ==========
    Components.SettingGroup.section('Actors (Cross-Character Communication)', themeName)

    local actorsEnabled = settings.ActorsEnabled ~= false

    -- Get peer count for badge display
    local ActorsCoordinator = getActorsCoordinator()
    local peerCount = (ActorsCoordinator and ActorsCoordinator.getPeerCount and ActorsCoordinator.getPeerCount()) or 0

    -- Toggle badge with peer count (clickable to toggle)
    local actorsVal, actorsChanged = Components.StatusBadge.togglePeers(peerCount, actorsEnabled, themeName, {
        tooltip = 'Click to toggle cross-character communication',
    })
    if actorsChanged and onChange then onChange('ActorsEnabled', actorsVal) end
    actorsEnabled = actorsVal

    if actorsEnabled then
        Components.SettingGroup.draw('Actor Coordination', function()
            -- Coordinate healing
            local healCoord = settings.HealCoordinateActors ~= false
            local healVal, healChanged = Components.CheckboxRow.draw('Coordinate Heals', 'HealCoordinateActors', healCoord, nil, {
                tooltip = 'Share healing assignments with other characters',
            })
            if healChanged and onChange then onChange('HealCoordinateActors', healVal) end

            -- Coordinate debuffs
            local debuffCoord = settings.DebuffCoordinateActors ~= false
            local debuffVal, debuffChanged = Components.CheckboxRow.draw('Coordinate Debuffs', 'DebuffCoordinateActors', debuffCoord, nil, {
                tooltip = 'Share debuff tracking with other characters',
            })
            if debuffChanged and onChange then onChange('DebuffCoordinateActors', debuffVal) end

            -- Coordinate CC
            local ccCoord = settings.CCCoordinateActors ~= false
            local ccVal, ccChanged = Components.CheckboxRow.draw('Coordinate CC', 'CCCoordinateActors', ccCoord, nil, {
                tooltip = 'Share crowd control assignments',
            })
            if ccChanged and onChange then onChange('CCCoordinateActors', ccVal) end

            -- Track HoTs via actors
            local hotTrack = settings.HealTrackHoTsViaActors ~= false
            local hotVal, hotChanged = Components.CheckboxRow.draw('Track HoTs via Actors', 'HealTrackHoTsViaActors', hotTrack, nil, {
                tooltip = 'Share HoT tracking data between characters',
            })
            if hotChanged and onChange then onChange('HealTrackHoTsViaActors', hotVal) end

            -- Cure coordination
            local cureCoord = settings.CureCoordinateActors ~= false
            local cureVal, cureChanged = Components.CheckboxRow.draw('Coordinate Cures', 'CureCoordinateActors', cureCoord, nil, {
                tooltip = 'Share cure assignments between characters',
            })
            if cureChanged and onChange then onChange('CureCoordinateActors', cureVal) end
        end, { id = 'actor_coord', defaultOpen = true })
    end

    -- ========== SAFE TARGETING SECTION ==========
    imgui.Spacing()
    Components.SettingGroup.section('Safe Targeting (KS Prevention)', themeName)

    local safeTargeting = settings.SafeTargetingEnabled ~= false
    local safeVal, safeChanged = Components.CheckboxRow.draw('Enable Safe Targeting', 'SafeTargetingEnabled', safeTargeting, nil, {
        tooltip = 'Avoid targeting mobs already engaged by others',
    })
    if safeChanged and onChange then onChange('SafeTargetingEnabled', safeVal) end
    safeTargeting = safeVal

    if safeTargeting then
        Components.SettingGroup.draw('Safe Target Checks', function()
            local checkRaid = settings.SafeTargetingCheckRaid ~= false
            local raidVal, raidChanged = Components.CheckboxRow.draw('Check Raid Members', 'SafeTargetingCheckRaid', checkRaid, nil, {
                tooltip = 'Check if raid members are targeting the mob',
            })
            if raidChanged and onChange then onChange('SafeTargetingCheckRaid', raidVal) end

            local checkPeers = settings.SafeTargetingCheckPeers ~= false
            local peersVal, peersChanged = Components.CheckboxRow.draw('Check Actor Peers', 'SafeTargetingCheckPeers', checkPeers, nil, {
                tooltip = 'Check if other SideKick instances are targeting the mob',
            })
            if peersChanged and onChange then onChange('SafeTargetingCheckPeers', peersVal) end
        end, { id = 'safe_target_checks', defaultOpen = true })
    end

    -- ========== ASSIST OUTSIDE GROUP SECTION ==========
    imgui.Spacing()
    Components.SettingGroup.section('Assist Outside Group', themeName)

    Components.SettingGroup.draw('Assist Targets', function()
        local assistGroup = settings.AssistOutsideGroup ~= false
        local agVal, agChanged = Components.CheckboxRow.draw('Assist Group Members', 'AssistOutsideGroup', assistGroup, nil, {
            tooltip = 'Assist group members outside your group',
        })
        if agChanged and onChange then onChange('AssistOutsideGroup', agVal) end

        local assistRaid = settings.AssistOutsideRaid ~= false
        local arVal, arChanged = Components.CheckboxRow.draw('Assist Raid Members', 'AssistOutsideRaid', assistRaid, nil, {
            tooltip = 'Assist raid members outside your group',
        })
        if arChanged and onChange then onChange('AssistOutsideRaid', arVal) end

        local assistPeers = settings.AssistOutsidePeers ~= false
        local apVal, apChanged = Components.CheckboxRow.draw('Assist Actor Peers (Same Zone)', 'AssistOutsidePeers', assistPeers, nil, {
            tooltip = 'Assist other SideKick instances in the same zone',
        })
        if apChanged and onChange then onChange('AssistOutsidePeers', apVal) end
    end, { id = 'assist_outside', defaultOpen = true })

    -- ========== MISC INTEGRATION ==========
    imgui.Spacing()
    Components.SettingGroup.section('Miscellaneous', themeName)

    -- Ignore PC Pets
    local ignorePets = settings.IgnorePCPets ~= false
    local petsVal, petsChanged = Components.CheckboxRow.draw('Ignore PC Pets on XTarget', 'IgnorePCPets', ignorePets, nil, {
        tooltip = 'Skip player pets when scanning XTarget slots',
    })
    if petsChanged and onChange then onChange('IgnorePCPets', petsVal) end
end

return M
