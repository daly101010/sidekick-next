-- ============================================================
-- SideKick Settings - Integration Tab
-- ============================================================
-- Actors, autostart, and external system integration settings.

local imgui = require('ImGui')
local Settings = require('sidekick-next.ui.settings')

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
    local changed

    -- ========== ACTORS SECTION ==========
    imgui.TextColored(0.7, 0.9, 1.0, 1.0, 'Actors (Cross-Character Communication)')
    imgui.Separator()

    local actorsEnabled = settings.ActorsEnabled ~= false
    actorsEnabled, changed = Settings.labeledCheckbox('Enable Actors', actorsEnabled, 'Enable message passing between SideKick instances')
    if changed and onChange then onChange('ActorsEnabled', actorsEnabled) end

    if actorsEnabled then
        imgui.Indent()

        -- Show connected peers
        local ActorsCoordinator = getActorsCoordinator()
        if ActorsCoordinator and ActorsCoordinator.getPeerCount then
            local peerCount = ActorsCoordinator.getPeerCount() or 0
            imgui.Text('Connected Peers: ' .. peerCount)
        end

        -- Coordinate healing
        local healCoord = settings.HealCoordinateActors ~= false
        healCoord, changed = Settings.labeledCheckbox('Coordinate Heals', healCoord)
        if changed and onChange then onChange('HealCoordinateActors', healCoord) end

        -- Coordinate debuffs
        local debuffCoord = settings.DebuffCoordinateActors ~= false
        debuffCoord, changed = Settings.labeledCheckbox('Coordinate Debuffs', debuffCoord)
        if changed and onChange then onChange('DebuffCoordinateActors', debuffCoord) end

        -- Coordinate CC
        local ccCoord = settings.CCCoordinateActors ~= false
        ccCoord, changed = Settings.labeledCheckbox('Coordinate CC', ccCoord)
        if changed and onChange then onChange('CCCoordinateActors', ccCoord) end

        -- Track HoTs via actors
        local hotTrack = settings.HealTrackHoTsViaActors ~= false
        hotTrack, changed = Settings.labeledCheckbox('Track HoTs via Actors', hotTrack)
        if changed and onChange then onChange('HealTrackHoTsViaActors', hotTrack) end

        -- Cure coordination
        local cureCoord = settings.CureCoordinateActors ~= false
        cureCoord, changed = Settings.labeledCheckbox('Coordinate Cures', cureCoord)
        if changed and onChange then onChange('CureCoordinateActors', cureCoord) end

        imgui.Unindent()
    end

    -- ========== SAFE TARGETING SECTION ==========
    imgui.Spacing()
    imgui.TextColored(0.7, 0.9, 1.0, 1.0, 'Safe Targeting (KS Prevention)')
    imgui.Separator()

    local safeTargeting = settings.SafeTargetingEnabled ~= false
    safeTargeting, changed = Settings.labeledCheckbox('Enable Safe Targeting', safeTargeting, 'Avoid targeting mobs already engaged by others')
    if changed and onChange then onChange('SafeTargetingEnabled', safeTargeting) end

    if safeTargeting then
        imgui.Indent()

        local checkRaid = settings.SafeTargetingCheckRaid ~= false
        checkRaid, changed = Settings.labeledCheckbox('Check Raid Members', checkRaid)
        if changed and onChange then onChange('SafeTargetingCheckRaid', checkRaid) end

        local checkPeers = settings.SafeTargetingCheckPeers ~= false
        checkPeers, changed = Settings.labeledCheckbox('Check Actor Peers', checkPeers)
        if changed and onChange then onChange('SafeTargetingCheckPeers', checkPeers) end

        imgui.Unindent()
    end

    -- ========== ASSIST OUTSIDE GROUP SECTION ==========
    imgui.Spacing()
    imgui.TextColored(0.7, 0.9, 1.0, 1.0, 'Assist Outside Group')
    imgui.Separator()

    local assistGroup = settings.AssistOutsideGroup ~= false
    assistGroup, changed = Settings.labeledCheckbox('Assist Group Members', assistGroup)
    if changed and onChange then onChange('AssistOutsideGroup', assistGroup) end

    local assistRaid = settings.AssistOutsideRaid ~= false
    assistRaid, changed = Settings.labeledCheckbox('Assist Raid Members', assistRaid)
    if changed and onChange then onChange('AssistOutsideRaid', assistRaid) end

    local assistPeers = settings.AssistOutsidePeers ~= false
    assistPeers, changed = Settings.labeledCheckbox('Assist Actor Peers (Same Zone)', assistPeers)
    if changed and onChange then onChange('AssistOutsidePeers', assistPeers) end

    -- ========== MISC INTEGRATION ==========
    imgui.Spacing()
    imgui.TextColored(0.7, 0.9, 1.0, 1.0, 'Miscellaneous')
    imgui.Separator()

    -- Ignore PC Pets
    local ignorePets = settings.IgnorePCPets ~= false
    ignorePets, changed = Settings.labeledCheckbox('Ignore PC Pets on XTarget', ignorePets)
    if changed and onChange then onChange('IgnorePCPets', ignorePets) end
end

return M
