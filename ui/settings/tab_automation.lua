-- ============================================================
-- SideKick Settings - Automation Tab
-- ============================================================
-- Combat mode, chase, assist, and meditation settings.

local imgui = require('ImGui')
local Settings = require('sidekick-next.ui.settings')

local M = {}

function M.draw(settings, themeNames, onChange)
    local changed

    -- ========== COMBAT MODE SECTION ==========
    imgui.TextColored(0.7, 0.9, 1.0, 1.0, 'Combat Mode')
    imgui.Separator()

    -- Combat Mode dropdown
    local combatModes = { 'off', 'assist', 'tank' }
    local combatMode = tostring(settings.CombatMode or 'off')
    combatMode = Settings.comboString('Mode', combatMode, combatModes)
    if combatMode ~= tostring(settings.CombatMode or 'off') and onChange then
        onChange('CombatMode', combatMode)
    end
    if imgui.IsItemHovered() then
        Settings.safeTooltip('Off: Disabled. Tank: Control targeting and aggro. Assist: Follow tank targets.')
    end

    imgui.Spacing()

    -- Tank-specific settings
    if combatMode == 'tank' then
        imgui.Indent()
        imgui.TextColored(0.8, 0.8, 0.8, 1.0, 'Tank Settings')

        local tankTargetModes = { 'auto', 'manual' }
        local tankTargetMode = tostring(settings.TankTargetMode or 'auto')
        tankTargetMode = Settings.comboString('Target Mode', tankTargetMode, tankTargetModes)
        if tankTargetMode ~= tostring(settings.TankTargetMode or 'auto') and onChange then
            onChange('TankTargetMode', tankTargetMode)
        end
        if imgui.IsItemHovered() then
            Settings.safeTooltip('Auto: Automatically select targets by priority. Manual: Use your current target.')
        end

        local aoeThreshold = tonumber(settings.TankAoEThreshold) or 3
        aoeThreshold, changed = imgui.SliderInt('AoE Mob Threshold', aoeThreshold, 2, 8)
        if changed and onChange then onChange('TankAoEThreshold', aoeThreshold) end

        local requireDeficit = settings.TankRequireAggroDeficit ~= false
        requireDeficit, changed = imgui.Checkbox('Require Aggro Deficit', requireDeficit)
        if changed and onChange then onChange('TankRequireAggroDeficit', requireDeficit) end

        local safeAE = settings.TankSafeAECheck == true
        safeAE, changed = imgui.Checkbox('Safe AE Check', safeAE)
        if changed and onChange then onChange('TankSafeAECheck', safeAE) end

        local reposition = settings.TankRepositionEnabled == true
        reposition, changed = imgui.Checkbox('Auto Reposition', reposition)
        if changed and onChange then onChange('TankRepositionEnabled', reposition) end

        local repoCooldown = tonumber(settings.TankRepositionCooldown) or 5
        repoCooldown, changed = imgui.SliderInt('Reposition Cooldown (sec)', repoCooldown, 2, 15)
        if changed and onChange then onChange('TankRepositionCooldown', repoCooldown) end

        imgui.Unindent()
        imgui.Spacing()
    end

    -- Assist-specific settings
    if combatMode == 'assist' then
        imgui.Indent()
        imgui.TextColored(0.8, 0.8, 0.8, 1.0, 'Assist Settings')

        local assistTargetModes = { 'sticky', 'follow' }
        local assistTargetMode = tostring(settings.AssistTargetMode or 'sticky')
        assistTargetMode = Settings.comboString('Target Mode', assistTargetMode, assistTargetModes)
        if assistTargetMode ~= tostring(settings.AssistTargetMode or 'sticky') and onChange then
            onChange('AssistTargetMode', assistTargetMode)
        end

        local engageConditions = { 'hp', 'tank_aggro' }
        local engageCondition = tostring(settings.AssistEngageCondition or 'hp')
        engageCondition = Settings.comboString('Engage Condition', engageCondition, engageConditions)
        if engageCondition ~= tostring(settings.AssistEngageCondition or 'hp') and onChange then
            onChange('AssistEngageCondition', engageCondition)
        end

        local engageHp = tonumber(settings.AssistEngageHpThreshold) or 97
        engageHp, changed = imgui.SliderInt('Engage HP %%', engageHp, 50, 100)
        if changed and onChange then onChange('AssistEngageHpThreshold', engageHp) end

        imgui.Unindent()
        imgui.Spacing()
    end

    -- ========== CHASE SECTION ==========
    imgui.Spacing()
    imgui.TextColored(0.7, 0.9, 1.0, 1.0, 'Chase')
    imgui.Separator()

    local chaseEnabled = settings.ChaseEnabled == true
    chaseEnabled, changed = imgui.Checkbox('Enable Chase', chaseEnabled)
    if changed and onChange then onChange('ChaseEnabled', chaseEnabled) end

    if chaseEnabled then
        imgui.Indent()

        local chaseRoles = { 'none', 'ma', 'mt', 'leader', 'raid1', 'raid2', 'raid3', 'byname' }
        local chaseRole = tostring(settings.ChaseRole or 'ma')
        chaseRole = Settings.comboString('Chase Role', chaseRole, chaseRoles)
        if chaseRole ~= tostring(settings.ChaseRole or 'ma') and onChange then
            onChange('ChaseRole', chaseRole)
        end

        if chaseRole == 'byname' then
            local target = settings.ChaseTarget or ''
            local buf = imgui.InputText('Chase Name', target, 64)
            if buf ~= target and onChange then
                onChange('ChaseTarget', buf)
            end
        end

        local chaseDistance = tonumber(settings.ChaseDistance) or 30
        chaseDistance, changed = imgui.SliderInt('Chase Distance', chaseDistance, 10, 100)
        if changed and onChange then onChange('ChaseDistance', chaseDistance) end

        imgui.Unindent()
    end

    -- ========== ASSIST SECTION ==========
    imgui.Spacing()
    imgui.TextColored(0.7, 0.9, 1.0, 1.0, 'Assist')
    imgui.Separator()

    local assistEnabled = settings.AssistEnabled == true
    assistEnabled, changed = imgui.Checkbox('Enable Assist', assistEnabled)
    if changed and onChange then onChange('AssistEnabled', assistEnabled) end

    if assistEnabled then
        imgui.Indent()

        local assistModes = { 'group', 'raid1', 'raid2', 'raid3', 'byname' }
        local assistMode = tostring(settings.AssistMode or 'group')
        assistMode = Settings.comboString('Assist Mode', assistMode, assistModes)
        if assistMode ~= tostring(settings.AssistMode or 'group') and onChange then
            onChange('AssistMode', assistMode)
        end

        if assistMode == 'byname' then
            local name = settings.AssistName or ''
            local buf = imgui.InputText('Assist Name', name, 64)
            if buf ~= name and onChange then
                onChange('AssistName', buf)
            end
        end

        local assistAt = tonumber(settings.AssistAt) or 97
        assistAt, changed = imgui.SliderInt('Assist At %%', assistAt, 50, 100)
        if changed and onChange then onChange('AssistAt', assistAt) end

        local assistRange = tonumber(settings.AssistRange) or 100
        assistRange, changed = imgui.SliderInt('Assist Range', assistRange, 30, 200)
        if changed and onChange then onChange('AssistRange', assistRange) end

        imgui.Unindent()
    end

    -- ========== MEDITATION SECTION ==========
    imgui.Spacing()
    imgui.TextColored(0.7, 0.9, 1.0, 1.0, 'Meditation')
    imgui.Separator()

    local medModes = { 'off', 'ooc', 'always' }
    local medMode = tostring(settings.MeditationMode or 'off')
    medMode = Settings.comboString('Meditation Mode', medMode, medModes)
    if medMode ~= tostring(settings.MeditationMode or 'off') and onChange then
        onChange('MeditationMode', medMode)
    end

    if medMode ~= 'off' then
        imgui.Indent()

        local medDelay = tonumber(settings.MeditationAfterCombatDelay) or 2
        medDelay, changed = imgui.SliderInt('After Combat Delay (sec)', medDelay, 0, 10)
        if changed and onChange then onChange('MeditationAfterCombatDelay', medDelay) end

        local aggroCheck = settings.MeditationAggroCheck ~= false
        aggroCheck, changed = imgui.Checkbox('Aggro Safety Check', aggroCheck)
        if changed and onChange then onChange('MeditationAggroCheck', aggroCheck) end

        local aggroPct = tonumber(settings.MeditationAggroPct) or 95
        aggroPct, changed = imgui.SliderInt('Stand If Aggro >=', aggroPct, 50, 100)
        if changed and onChange then onChange('MeditationAggroPct', aggroPct) end

        local standDone = settings.MeditationStandWhenDone ~= false
        standDone, changed = imgui.Checkbox('Stand When Done', standDone)
        if changed and onChange then onChange('MeditationStandWhenDone', standDone) end

        imgui.Separator()
        imgui.Text('Thresholds')

        local hpStart = tonumber(settings.MeditationHPStartPct) or 70
        hpStart, changed = imgui.SliderInt('HP Start %%', hpStart, 0, 100)
        if changed and onChange then onChange('MeditationHPStartPct', hpStart) end

        local hpStop = tonumber(settings.MeditationHPStopPct) or 95
        hpStop, changed = imgui.SliderInt('HP Stop %%', hpStop, 0, 100)
        if changed and onChange then onChange('MeditationHPStopPct', hpStop) end

        local manaStart = tonumber(settings.MeditationManaStartPct) or 50
        manaStart, changed = imgui.SliderInt('Mana Start %%', manaStart, 0, 100)
        if changed and onChange then onChange('MeditationManaStartPct', manaStart) end

        local manaStop = tonumber(settings.MeditationManaStopPct) or 95
        manaStop, changed = imgui.SliderInt('Mana Stop %%', manaStop, 0, 100)
        if changed and onChange then onChange('MeditationManaStopPct', manaStop) end

        local endStart = tonumber(settings.MeditationEndStartPct) or 60
        endStart, changed = imgui.SliderInt('Endurance Start %%', endStart, 0, 100)
        if changed and onChange then onChange('MeditationEndStartPct', endStart) end

        local endStop = tonumber(settings.MeditationEndStopPct) or 95
        endStop, changed = imgui.SliderInt('Endurance Stop %%', endStop, 0, 100)
        if changed and onChange then onChange('MeditationEndStopPct', endStop) end

        imgui.Unindent()
    end

    -- ========== BURN SECTION ==========
    imgui.Spacing()
    imgui.TextColored(0.7, 0.9, 1.0, 1.0, 'Burn')
    imgui.Separator()

    local burnActive = settings.BurnActive == true
    burnActive, changed = imgui.Checkbox('Burn Active', burnActive)
    if changed and onChange then onChange('BurnActive', burnActive) end

    local burnDuration = tonumber(settings.BurnDuration) or 30
    burnDuration, changed = imgui.SliderInt('Burn Duration (sec)', burnDuration, 5, 120)
    if changed and onChange then onChange('BurnDuration', burnDuration) end
end

return M
