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
    combatMode = Settings.labeledCombo('Mode', combatMode, combatModes, 'Off: Disabled. Tank: Control targeting and aggro. Assist: Follow tank targets.')
    if combatMode ~= tostring(settings.CombatMode or 'off') and onChange then
        onChange('CombatMode', combatMode)
    end

    imgui.Spacing()

    -- Tank-specific settings
    if combatMode == 'tank' then
        imgui.Indent()
        imgui.TextColored(0.8, 0.8, 0.8, 1.0, 'Tank Settings')

        local tankTargetModes = { 'auto', 'manual' }
        local tankTargetMode = tostring(settings.TankTargetMode or 'auto')
        tankTargetMode = Settings.labeledCombo('Target Mode', tankTargetMode, tankTargetModes, 'Auto: Automatically select targets by priority. Manual: Use your current target.')
        if tankTargetMode ~= tostring(settings.TankTargetMode or 'auto') and onChange then
            onChange('TankTargetMode', tankTargetMode)
        end

        local aoeThreshold = tonumber(settings.TankAoEThreshold) or 3
        aoeThreshold, changed = Settings.labeledSliderInt('AoE Mob Threshold', aoeThreshold, 2, 8)
        if changed and onChange then onChange('TankAoEThreshold', aoeThreshold) end

        local requireDeficit = settings.TankRequireAggroDeficit ~= false
        requireDeficit, changed = Settings.labeledCheckbox('Require Aggro Deficit', requireDeficit)
        if changed and onChange then onChange('TankRequireAggroDeficit', requireDeficit) end

        local safeAE = settings.TankSafeAECheck == true
        safeAE, changed = Settings.labeledCheckbox('Safe AE Check', safeAE)
        if changed and onChange then onChange('TankSafeAECheck', safeAE) end

        local reposition = settings.TankRepositionEnabled == true
        reposition, changed = Settings.labeledCheckbox('Auto Reposition', reposition)
        if changed and onChange then onChange('TankRepositionEnabled', reposition) end

        local repoCooldown = tonumber(settings.TankRepositionCooldown) or 5
        repoCooldown, changed = Settings.labeledSliderInt('Reposition Cooldown (sec)', repoCooldown, 2, 15)
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
        assistTargetMode = Settings.labeledCombo('Target Mode', assistTargetMode, assistTargetModes)
        if assistTargetMode ~= tostring(settings.AssistTargetMode or 'sticky') and onChange then
            onChange('AssistTargetMode', assistTargetMode)
        end

        local engageConditions = { 'hp', 'tank_aggro' }
        local engageCondition = tostring(settings.AssistEngageCondition or 'hp')
        engageCondition = Settings.labeledCombo('Engage Condition', engageCondition, engageConditions)
        if engageCondition ~= tostring(settings.AssistEngageCondition or 'hp') and onChange then
            onChange('AssistEngageCondition', engageCondition)
        end

        local engageHp = tonumber(settings.AssistEngageHpThreshold) or 97
        engageHp, changed = Settings.labeledSliderInt('Engage HP %', engageHp, 50, 100)
        if changed and onChange then onChange('AssistEngageHpThreshold', engageHp) end

        imgui.Unindent()
        imgui.Spacing()
    end

    -- ========== CHASE SECTION ==========
    imgui.Spacing()
    imgui.TextColored(0.7, 0.9, 1.0, 1.0, 'Chase')
    imgui.Separator()

    local chaseEnabled = settings.ChaseEnabled == true
    chaseEnabled, changed = Settings.labeledCheckbox('Enable Chase', chaseEnabled)
    if changed and onChange then onChange('ChaseEnabled', chaseEnabled) end

    if chaseEnabled then
        imgui.Indent()

        local chaseRoles = { 'none', 'ma', 'mt', 'leader', 'raid1', 'raid2', 'raid3', 'byname' }
        local chaseRole = tostring(settings.ChaseRole or 'ma')
        chaseRole = Settings.labeledCombo('Chase Role', chaseRole, chaseRoles)
        if chaseRole ~= tostring(settings.ChaseRole or 'ma') and onChange then
            onChange('ChaseRole', chaseRole)
        end

        if chaseRole == 'byname' then
            local target = settings.ChaseTarget or ''
            local buf = Settings.labeledInputText('Chase Name', target)
            if buf ~= target and onChange then
                onChange('ChaseTarget', buf)
            end
        end

        local chaseDistance = tonumber(settings.ChaseDistance) or 30
        chaseDistance, changed = Settings.labeledSliderInt('Chase Distance', chaseDistance, 10, 100)
        if changed and onChange then onChange('ChaseDistance', chaseDistance) end

        imgui.Unindent()
    end

    -- ========== ASSIST SECTION ==========
    imgui.Spacing()
    imgui.TextColored(0.7, 0.9, 1.0, 1.0, 'Assist')
    imgui.Separator()

    local assistEnabled = settings.AssistEnabled == true
    assistEnabled, changed = Settings.labeledCheckbox('Enable Assist', assistEnabled)
    if changed and onChange then onChange('AssistEnabled', assistEnabled) end

    if assistEnabled then
        imgui.Indent()

        local assistModes = { 'group', 'raid1', 'raid2', 'raid3', 'byname' }
        local assistMode = tostring(settings.AssistMode or 'group')
        assistMode = Settings.labeledCombo('Assist Mode', assistMode, assistModes)
        if assistMode ~= tostring(settings.AssistMode or 'group') and onChange then
            onChange('AssistMode', assistMode)
        end

        if assistMode == 'byname' then
            local name = settings.AssistName or ''
            local buf = Settings.labeledInputText('Assist Name', name)
            if buf ~= name and onChange then
                onChange('AssistName', buf)
            end
        end

        local assistAt = tonumber(settings.AssistAt) or 97
        assistAt, changed = Settings.labeledSliderInt('Assist At %', assistAt, 50, 100)
        if changed and onChange then onChange('AssistAt', assistAt) end

        local assistRange = tonumber(settings.AssistRange) or 100
        assistRange, changed = Settings.labeledSliderInt('Assist Range', assistRange, 30, 200)
        if changed and onChange then onChange('AssistRange', assistRange) end

        imgui.Unindent()
    end

    -- ========== MEDITATION SECTION ==========
    imgui.Spacing()
    imgui.TextColored(0.7, 0.9, 1.0, 1.0, 'Meditation')
    imgui.Separator()

    local medModes = { 'off', 'ooc', 'always' }
    local medMode = tostring(settings.MeditationMode or 'off')
    medMode = Settings.labeledCombo('Meditation Mode', medMode, medModes)
    if medMode ~= tostring(settings.MeditationMode or 'off') and onChange then
        onChange('MeditationMode', medMode)
    end

    if medMode ~= 'off' then
        imgui.Indent()

        local medDelay = tonumber(settings.MeditationAfterCombatDelay) or 2
        medDelay, changed = Settings.labeledSliderInt('After Combat Delay (sec)', medDelay, 0, 10)
        if changed and onChange then onChange('MeditationAfterCombatDelay', medDelay) end

        local aggroCheck = settings.MeditationAggroCheck ~= false
        aggroCheck, changed = Settings.labeledCheckbox('Aggro Safety Check', aggroCheck)
        if changed and onChange then onChange('MeditationAggroCheck', aggroCheck) end

        local aggroPct = tonumber(settings.MeditationAggroPct) or 95
        aggroPct, changed = Settings.labeledSliderInt('Stand If Aggro >=', aggroPct, 50, 100)
        if changed and onChange then onChange('MeditationAggroPct', aggroPct) end

        local standDone = settings.MeditationStandWhenDone ~= false
        standDone, changed = Settings.labeledCheckbox('Stand When Done', standDone)
        if changed and onChange then onChange('MeditationStandWhenDone', standDone) end

        imgui.Separator()
        imgui.Text('Thresholds')

        local hpStart = tonumber(settings.MeditationHPStartPct) or 70
        hpStart, changed = Settings.labeledSliderInt('HP Start %', hpStart, 0, 100)
        if changed and onChange then onChange('MeditationHPStartPct', hpStart) end

        local hpStop = tonumber(settings.MeditationHPStopPct) or 95
        hpStop, changed = Settings.labeledSliderInt('HP Stop %', hpStop, 0, 100)
        if changed and onChange then onChange('MeditationHPStopPct', hpStop) end

        local manaStart = tonumber(settings.MeditationManaStartPct) or 50
        manaStart, changed = Settings.labeledSliderInt('Mana Start %', manaStart, 0, 100)
        if changed and onChange then onChange('MeditationManaStartPct', manaStart) end

        local manaStop = tonumber(settings.MeditationManaStopPct) or 95
        manaStop, changed = Settings.labeledSliderInt('Mana Stop %', manaStop, 0, 100)
        if changed and onChange then onChange('MeditationManaStopPct', manaStop) end

        local endStart = tonumber(settings.MeditationEndStartPct) or 60
        endStart, changed = Settings.labeledSliderInt('Endurance Start %', endStart, 0, 100)
        if changed and onChange then onChange('MeditationEndStartPct', endStart) end

        local endStop = tonumber(settings.MeditationEndStopPct) or 95
        endStop, changed = Settings.labeledSliderInt('Endurance Stop %', endStop, 0, 100)
        if changed and onChange then onChange('MeditationEndStopPct', endStop) end

        imgui.Unindent()
    end

    -- ========== BURN SECTION ==========
    imgui.Spacing()
    imgui.TextColored(0.7, 0.9, 1.0, 1.0, 'Burn')
    imgui.Separator()

    local burnActive = settings.BurnActive == true
    burnActive, changed = Settings.labeledCheckbox('Burn Active', burnActive)
    if changed and onChange then onChange('BurnActive', burnActive) end

    local burnDuration = tonumber(settings.BurnDuration) or 30
    burnDuration, changed = Settings.labeledSliderInt('Burn Duration (sec)', burnDuration, 5, 120)
    if changed and onChange then onChange('BurnDuration', burnDuration) end
end

return M
