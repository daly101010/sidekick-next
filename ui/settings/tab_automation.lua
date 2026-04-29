-- ============================================================
-- SideKick Settings - Automation Tab
-- ============================================================
-- Combat mode, chase, assist, and meditation settings.

local imgui = require('ImGui')
local Settings = require('sidekick-next.ui.settings')
local Components = require('sidekick-next.ui.components')

local M = {}

function M.draw(settings, themeNames, onChange)
    local changed
    local themeName = settings.SideKickTheme or 'Classic'

    -- ========== COMBAT MODE SECTION ==========
    Components.SettingGroup.section('Combat Mode', themeName)

    -- Combat Mode dropdown with status indicator
    local combatModes = { 'off', 'assist', 'tank' }
    local combatMode = tostring(settings.CombatMode or 'off')

    -- Show current mode status badge
    if combatMode ~= 'off' then
        Components.StatusBadge.info(combatMode:upper(), themeName, { showIcon = false })
        imgui.SameLine()
    end

    local modeChanged, newMode = Components.ComboRow.byValue('Mode', 'CombatMode', combatMode, combatModes, nil, {
        tooltip = 'Off: Disabled. Tank: Control targeting and aggro. Assist: Follow tank targets.',
        width = 100,
    })
    if modeChanged and onChange then
        onChange('CombatMode', newMode)
        combatMode = newMode
    end

    imgui.Spacing()

    -- Tank-specific settings
    if combatMode == 'tank' then
        Components.SettingGroup.draw('Tank Settings', function()
            local tankTargetModes = { 'auto', 'manual' }
            local tankTargetMode = tostring(settings.TankTargetMode or 'auto')
            local tankModeChanged, newTankMode = Components.ComboRow.byValue('Target Mode', 'TankTargetMode', tankTargetMode, tankTargetModes, nil, {
                tooltip = 'Auto: Automatically select targets by priority. Manual: Use your current target.',
                width = 100,
            })
            if tankModeChanged and onChange then onChange('TankTargetMode', newTankMode) end

            local aoeThreshold = tonumber(settings.TankAoEThreshold) or 3
            local aoeChanged, newAoe = Components.SliderRow.int('AoE Mob Threshold', 'TankAoEThreshold', aoeThreshold, 2, 8)
            if aoeChanged and onChange then onChange('TankAoEThreshold', newAoe) end

            local requireDeficit = settings.TankRequireAggroDeficit ~= false
            local deficitVal, deficitChanged = Components.CheckboxRow.draw('Require Aggro Deficit', 'TankRequireAggroDeficit', requireDeficit)
            if deficitChanged and onChange then onChange('TankRequireAggroDeficit', deficitVal) end

            local safeAE = settings.TankSafeAECheck == true
            local safeVal, safeChanged = Components.CheckboxRow.draw('Safe AE Check', 'TankSafeAECheck', safeAE, nil, {
                tooltip = 'Only use AE abilities when safe',
            })
            if safeChanged and onChange then onChange('TankSafeAECheck', safeVal) end

            local reposition = settings.TankRepositionEnabled == true
            local repoVal, repoChanged = Components.CheckboxRow.draw('Auto Reposition', 'TankRepositionEnabled', reposition)
            if repoChanged and onChange then onChange('TankRepositionEnabled', repoVal) end

            local repoCooldown = tonumber(settings.TankRepositionCooldown) or 5
            local repocdChanged, newRepocd = Components.SliderRow.int('Reposition Cooldown (sec)', 'TankRepositionCooldown', repoCooldown, 2, 15)
            if repocdChanged and onChange then onChange('TankRepositionCooldown', newRepocd) end
        end, { id = 'tank_settings', defaultOpen = true })
    end

    -- Assist-specific settings
    if combatMode == 'assist' then
        Components.SettingGroup.draw('Assist Settings', function()
            local assistTargetModes = { 'sticky', 'follow' }
            local assistTargetMode = tostring(settings.AssistTargetMode or 'sticky')
            local astModeChanged, newAstMode = Components.ComboRow.byValue('Target Mode', 'AssistTargetMode', assistTargetMode, assistTargetModes, nil, {
                tooltip = 'Sticky: Keep target until dead. Follow: Switch with tank.',
                width = 100,
            })
            if astModeChanged and onChange then onChange('AssistTargetMode', newAstMode) end

            local engageConditions = { 'hp', 'tank_aggro' }
            local engageCondition = tostring(settings.AssistEngageCondition or 'hp')
            local engageChanged, newEngage = Components.ComboRow.byValue('Engage Condition', 'AssistEngageCondition', engageCondition, engageConditions, nil, {
                tooltip = 'HP: Engage at HP threshold. Tank Aggro: Wait for tank aggro.',
                width = 100,
            })
            if engageChanged and onChange then onChange('AssistEngageCondition', newEngage) end

            local engageHp = tonumber(settings.AssistEngageHpThreshold) or 97
            local hpChanged, newHp = Components.SliderRow.percent('Engage HP', 'AssistEngageHpThreshold', engageHp, nil, {
                tooltip = 'Start attacking when mob HP drops below this percentage',
            })
            if hpChanged and onChange then onChange('AssistEngageHpThreshold', newHp) end
        end, { id = 'assist_settings', defaultOpen = true })
    end

    -- ========== CHASE SECTION ==========
    imgui.Spacing()
    Components.SettingGroup.section('Chase', themeName)

    local chaseEnabled = settings.ChaseEnabled == true

    -- Toggle badge for chase (clickable to toggle)
    local chaseVal, chaseChanged = Components.StatusBadge.toggle('Chase', chaseEnabled, themeName, {
        enabledText = 'Active',
        disabledText = 'Off',
        tooltip = 'Click to toggle chase mode',
    })
    if chaseChanged and onChange then onChange('ChaseEnabled', chaseVal) end
    chaseEnabled = chaseVal

    if chaseEnabled then
        Components.SettingGroup.draw('Chase Target', function()
            local chaseRoles = { 'none', 'ma', 'mt', 'leader', 'raid1', 'raid2', 'raid3', 'byname' }
            local chaseRole = tostring(settings.ChaseRole or 'ma')
            local roleChanged, newRole = Components.ComboRow.byValue('Chase Role', 'ChaseRole', chaseRole, chaseRoles, nil, {
                tooltip = 'Who to follow: MA, MT, Group Leader, Raid MA, or by name',
                width = 100,
            })
            if roleChanged and onChange then
                onChange('ChaseRole', newRole)
                chaseRole = newRole
            end

            if chaseRole == 'byname' then
                local target = settings.ChaseTarget or ''
                local buf = Settings.labeledInputText('Chase Name', target)
                if buf ~= target and onChange then
                    onChange('ChaseTarget', buf)
                end
            end

            local chaseDistance = tonumber(settings.ChaseDistance) or 30
            local distChanged, newDist = Components.SliderRow.int('Chase Distance', 'ChaseDistance', chaseDistance, 10, 100, nil, {
                tooltip = 'How close to follow (units)',
            })
            if distChanged and onChange then onChange('ChaseDistance', newDist) end
        end, { id = 'chase_target', defaultOpen = true })
    end

    -- ========== ASSIST SECTION ==========
    imgui.Spacing()
    Components.SettingGroup.section('Assist', themeName)

    local assistEnabled = settings.AssistEnabled == true

    -- Toggle badge for assist (clickable to toggle)
    local assistVal, assistChanged = Components.StatusBadge.toggle('Assist', assistEnabled, themeName, {
        enabledText = 'Active',
        disabledText = 'Off',
        tooltip = 'Click to toggle assist mode',
    })
    if assistChanged and onChange then onChange('AssistEnabled', assistVal) end
    assistEnabled = assistVal

    if assistEnabled then
        Components.SettingGroup.draw('Assist Target', function()
            local assistModes = { 'group', 'raid1', 'raid2', 'raid3', 'byname' }
            local assistMode = tostring(settings.AssistMode or 'group')
            local astMdChanged, newAstMd = Components.ComboRow.byValue('Assist Mode', 'AssistMode', assistMode, assistModes, nil, {
                tooltip = 'Group MA, Raid MA 1-3, or by name',
                width = 100,
            })
            if astMdChanged and onChange then
                onChange('AssistMode', newAstMd)
                assistMode = newAstMd
            end

            if assistMode == 'byname' then
                local name = settings.AssistName or ''
                local buf = Settings.labeledInputText('Assist Name', name)
                if buf ~= name and onChange then
                    onChange('AssistName', buf)
                end
            end

            local assistAt = tonumber(settings.AssistAt) or 97
            local atChanged, newAt = Components.SliderRow.percent('Assist At', 'AssistAt', assistAt, nil, {
                tooltip = 'Start assisting when mob HP drops below this percentage',
            })
            if atChanged and onChange then onChange('AssistAt', newAt) end

            local assistRange = tonumber(settings.AssistRange) or 100
            local rangeChanged, newRange = Components.SliderRow.int('Assist Range', 'AssistRange', assistRange, 30, 200, nil, {
                tooltip = 'Maximum distance to assist target (units)',
            })
            if rangeChanged and onChange then onChange('AssistRange', newRange) end
        end, { id = 'assist_target', defaultOpen = true })
    end

    -- ========== MEDITATION SECTION ==========
    imgui.Spacing()
    Components.SettingGroup.section('Meditation', themeName)

    local medModes = { 'off', 'ooc', 'always' }
    local medMode = tostring(settings.MeditationMode or 'off')

    -- Status badge for meditation mode
    if medMode ~= 'off' then
        local badgeText = medMode == 'ooc' and 'OOC' or 'ALWAYS'
        Components.StatusBadge.buff(badgeText, themeName, { showIcon = false })
        imgui.SameLine()
    end

    local medChanged, newMedMode = Components.ComboRow.byValue('Mode', 'MeditationMode', medMode, medModes, nil, {
        tooltip = 'Off: Never meditate. OOC: Only out of combat. Always: Whenever resources are low.',
        width = 100,
    })
    if medChanged and onChange then
        onChange('MeditationMode', newMedMode)
        medMode = newMedMode
    end

    if medMode ~= 'off' then
        Components.SettingGroup.draw('Meditation Options', function()
            local medDelay = tonumber(settings.MeditationAfterCombatDelay) or 2
            local delayChanged, newDelay = Components.SliderRow.int('After Combat Delay (sec)', 'MeditationAfterCombatDelay', medDelay, 0, 10, nil, {
                tooltip = 'Wait this long after combat before sitting',
            })
            if delayChanged and onChange then onChange('MeditationAfterCombatDelay', newDelay) end

            local aggroCheck = settings.MeditationAggroCheck ~= false
            local aggroVal, aggroChanged = Components.CheckboxRow.draw('Aggro Safety Check', 'MeditationAggroCheck', aggroCheck, nil, {
                tooltip = 'Stand up if aggro is detected',
            })
            if aggroChanged and onChange then onChange('MeditationAggroCheck', aggroVal) end

            local aggroPct = tonumber(settings.MeditationAggroPct) or 95
            local aggroPctChanged, newAggroPct = Components.SliderRow.percent('Stand If Aggro >=', 'MeditationAggroPct', aggroPct, nil, {
                tooltip = 'Stand when your aggro percentage reaches this level',
            })
            if aggroPctChanged and onChange then onChange('MeditationAggroPct', newAggroPct) end

            local standDone = settings.MeditationStandWhenDone ~= false
            local standVal, standChanged = Components.CheckboxRow.draw('Stand When Done', 'MeditationStandWhenDone', standDone, nil, {
                tooltip = 'Automatically stand when resources are full',
            })
            if standChanged and onChange then onChange('MeditationStandWhenDone', standVal) end
        end, { id = 'med_options', defaultOpen = true })

        Components.SettingGroup.draw('Resource Thresholds', function()
            local hpStart = tonumber(settings.MeditationHPStartPct) or 70
            local hpStartChanged, newHpStart = Components.SliderRow.percent('HP Start', 'MeditationHPStartPct', hpStart, nil, {
                tooltip = 'Start meditating when HP drops below this percentage',
            })
            if hpStartChanged and onChange then onChange('MeditationHPStartPct', newHpStart) end

            local hpStop = tonumber(settings.MeditationHPStopPct) or 95
            local hpStopChanged, newHpStop = Components.SliderRow.percent('HP Stop', 'MeditationHPStopPct', hpStop, nil, {
                tooltip = 'Stop meditating when HP reaches this percentage',
            })
            if hpStopChanged and onChange then onChange('MeditationHPStopPct', newHpStop) end

            local manaStart = tonumber(settings.MeditationManaStartPct) or 50
            local manaStartChanged, newManaStart = Components.SliderRow.percent('Mana Start', 'MeditationManaStartPct', manaStart, nil, {
                tooltip = 'Start meditating when Mana drops below this percentage',
            })
            if manaStartChanged and onChange then onChange('MeditationManaStartPct', newManaStart) end

            local manaStop = tonumber(settings.MeditationManaStopPct) or 95
            local manaStopChanged, newManaStop = Components.SliderRow.percent('Mana Stop', 'MeditationManaStopPct', manaStop, nil, {
                tooltip = 'Stop meditating when Mana reaches this percentage',
            })
            if manaStopChanged and onChange then onChange('MeditationManaStopPct', newManaStop) end

            local endStart = tonumber(settings.MeditationEndStartPct) or 60
            local endStartChanged, newEndStart = Components.SliderRow.percent('Endurance Start', 'MeditationEndStartPct', endStart, nil, {
                tooltip = 'Start meditating when Endurance drops below this percentage',
            })
            if endStartChanged and onChange then onChange('MeditationEndStartPct', newEndStart) end

            local endStop = tonumber(settings.MeditationEndStopPct) or 95
            local endStopChanged, newEndStop = Components.SliderRow.percent('Endurance Stop', 'MeditationEndStopPct', endStop, nil, {
                tooltip = 'Stop meditating when Endurance reaches this percentage',
            })
            if endStopChanged and onChange then onChange('MeditationEndStopPct', newEndStop) end
        end, { id = 'med_thresholds', defaultOpen = false })
    end

    -- ========== BURN SECTION ==========
    imgui.Spacing()
    Components.SettingGroup.section('Burn', themeName)

    local burnActive = settings.BurnActive == true

    -- Toggle badge for burn (clickable to toggle)
    local burnVal, burnChanged = Components.StatusBadge.toggle('Burn', burnActive, themeName, {
        enabledText = 'BURNING',
        disabledText = 'Off',
        enabledStyle = 'warning',
        tooltip = 'Click to toggle burn mode - use all cooldowns',
    })
    if burnChanged and onChange then onChange('BurnActive', burnVal) end

    local burnDuration = tonumber(settings.BurnDuration) or 30
    local durChanged, newDur = Components.SliderRow.int('Burn Duration (sec)', 'BurnDuration', burnDuration, 5, 120, nil, {
        tooltip = 'How long burn mode stays active',
    })
    if durChanged and onChange then onChange('BurnDuration', newDur) end
end

return M
