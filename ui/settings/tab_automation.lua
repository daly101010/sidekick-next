-- ============================================================
-- SideKick Settings - Automation Tab
-- ============================================================
-- Combat mode, chase, assist, and meditation settings.

local imgui = require('ImGui')
local Settings = require('sidekick-next.ui.settings.init')
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
                tooltip = 'Also suppress AE hate when nearby NPCs are not on XTarget. Active mez is always protected.',
            })
            if safeChanged and onChange then onChange('TankSafeAECheck', safeVal) end

            local reposition = settings.TankRepositionEnabled == true
            local repoVal, repoChanged = Components.CheckboxRow.draw('Drag Mobs To Camp', 'TankRepositionEnabled', reposition, nil, {
                tooltip = 'Use a tank-facing moveback stick so engaged mobs remain in front of the tank.',
            })
            if repoChanged and onChange then onChange('TankRepositionEnabled', repoVal) end

            local repoCooldown = tonumber(settings.TankRepositionCooldown) or 5
            local repocdChanged, newRepocd = Components.SliderRow.int('Position Refresh (sec)', 'TankRepositionCooldown', repoCooldown, 2, 15)
            if repocdChanged and onChange then onChange('TankRepositionCooldown', newRepocd) end

            local tauntRange = tonumber(settings.TankTauntChaseRange) or 60
            local rangeChanged, newRange = Components.SliderRow.int('Taunt Chase Range', 'TankTauntChaseRange', tauntRange, 30, 100)
            if rangeChanged and onChange then onChange('TankTauntChaseRange', newRange) end

            local engageRange = tonumber(settings.TankEngageRange) or 125
            local engChanged, newEngRange = Components.SliderRow.int('Engage Range', 'TankEngageRange', engageRange, 30, 300, nil, {
                tooltip = 'Only haters within this distance can become the primary kill target',
            })
            if engChanged and onChange then onChange('TankEngageRange', newEngRange) end

            local breakMez = settings.TankBreakMez ~= false
            local bmVal, bmChanged = Components.CheckboxRow.draw('Break Mez When Camp Clear', 'TankBreakMez', breakMez, nil, {
                tooltip = 'When no unmezzed haters remain, engage the next mezzed add (one-at-a-time camp consumption)',
            })
            if bmChanged and onChange then onChange('TankBreakMez', bmVal) end

            local holdRadius = tonumber(settings.TankHoldRadius) or 50
            local hrChanged, newHold = Components.SliderRow.int('Hold Radius', 'TankHoldRadius', holdRadius, 15, 125, nil, {
                tooltip = 'Stand and let inbound mobs come to you beyond this distance.\nOnly chase (via nav pathfinding) when the mob stops closing.',
            })
            if hrChanged and onChange then onChange('TankHoldRadius', newHold) end
        end, { id = 'tank_settings', defaultOpen = true })
    end

    -- Assist-specific settings
    if combatMode == 'assist' then
        Components.SettingGroup.draw('Assist Settings', function()
            local assistModes = { 'group', 'raid1', 'raid2', 'raid3', 'byname' }
            local assistMode = tostring(settings.AssistMode or 'group')
            local sourceChanged, newAssistMode = Components.ComboRow.byValue('Assist Source', 'AssistMode', assistMode, assistModes, nil, {
                tooltip = 'Group MA, Raid MA 1-3, or by name. Used when an Actor tank broadcast is unavailable.',
                width = 100,
            })
            if sourceChanged and onChange then
                onChange('AssistMode', newAssistMode)
                assistMode = newAssistMode
            end

            if assistMode == 'byname' then
                local name = settings.AssistName or ''
                local buf = Settings.labeledInputText('Assist Name', name)
                if buf ~= name and onChange then
                    onChange('AssistName', buf)
                end
            end

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

            local engageHp = tonumber(settings.AssistAt) or 97
            local hpChanged, newHp = Components.SliderRow.percent('Engage HP', 'AssistAt', engageHp, nil, {
                tooltip = 'Start attacking when mob HP drops below this percentage',
            })
            if hpChanged and onChange then onChange('AssistAt', newHp) end

            local assistRange = tonumber(settings.AssistRange) or 100
            local rangeChanged, newRange = Components.SliderRow.int('Assist Range', 'AssistRange', assistRange, 30, 200, nil, {
                tooltip = 'Maximum distance to the fallback assist target (units)',
            })
            if rangeChanged and onChange then onChange('AssistRange', newRange) end
        end, { id = 'assist_settings', defaultOpen = true })
    end

    -- Stick commands apply to any combat mode that moves the character
    -- (assist engage stick + soft-pause stick). Melee positioning lives here:
    -- e.g. a rogue needs a "behind" variant for backstabs.
    if combatMode ~= 'off' then
        Components.SettingGroup.draw('Stick Commands', function()
            local stickCmd = tostring(settings.StickCommand or '')
            local stickBuf = Settings.labeledInputText('Engage Stick', stickCmd)
            if stickBuf ~= stickCmd and onChange then
                onChange('StickCommand', stickBuf)
            end
            if imgui.IsItemHovered() then
                imgui.SetTooltip('Full /stick command used when engaging.\nMelee DPS behind mobs: /stick snaproll behind 10 moveback uw\nTank front: /stick front')
            end

            local softStick = tostring(settings.SoftPauseStick or '')
            local softBuf = Settings.labeledInputText('Soft-Pause Stick', softStick)
            if softBuf ~= softStick and onChange then
                onChange('SoftPauseStick', softBuf)
            end
            if imgui.IsItemHovered() then
                imgui.SetTooltip('Stick command applied while the tank repositions (soft pause).')
            end
        end, { id = 'stick_settings', defaultOpen = false })
    end

    -- ========== CROWD CONTROL SECTION ==========
    -- Mez + charm (ENC/BRD). Harmless on non-CC classes: the cc worker
    -- gates on class before acting on any of these.
    imgui.Spacing()
    Components.SettingGroup.section('Crowd Control', themeName)

    Components.SettingGroup.draw('Mez', function()
        local mezOn = settings.MezzingEnabled == true
        local mezVal, mezChanged = Components.CheckboxRow.draw('Mezzing Enabled', 'MezzingEnabled', mezOn, nil, {
            tooltip = 'Automatically mez extra unmezzed adds (ENC/BRD).',
        })
        if mezChanged and onChange then onChange('MezzingEnabled', mezVal) end

        local maxTargets = tonumber(settings.MezMaxTargets) or 3
        local mtChanged, mtVal = Components.SliderRow.int('Max Mobs to Mez', 'MezMaxTargets', maxTargets, 1, 8, nil, {
            tooltip = 'Stop mezzing new adds once this many are already mezzed.',
        })
        if mtChanged and onChange then onChange('MezMaxTargets', mtVal) end

        local fastOn = settings.UseFastMez ~= false
        local fastVal, fastChanged = Components.CheckboxRow.draw('Use Fast Mez', 'UseFastMez', fastOn, nil, {
            tooltip = 'Prefer the short-duration fast mez line over the main line.',
        })
        if fastChanged and onChange then onChange('UseFastMez', fastVal) end

        local aeOn = settings.UseAEMez == true
        local aeVal, aeChanged = Components.CheckboxRow.draw('Use AE Mez', 'UseAEMez', aeOn, nil, {
            tooltip = 'Cast the AE mez line when enough unmezzed adds cluster together.',
        })
        if aeChanged and onChange then onChange('UseAEMez', aeVal) end

        local aeMin = tonumber(settings.AEMezMinTargets) or 3
        local aeMinChanged, aeMinVal = Components.SliderRow.int('AE Mez Min Targets', 'AEMezMinTargets', aeMin, 2, 8, nil, {
            tooltip = 'Minimum unmezzed adds within AE range before AE mez is used.',
        })
        if aeMinChanged and onChange then onChange('AEMezMinTargets', aeMinVal) end

        local refresh = tonumber(settings.MezRefreshWindow) or 6
        local rfChanged, rfVal = Components.SliderRow.int('Mez Refresh Window (sec)', 'MezRefreshWindow', refresh, 2, 15, nil, {
            tooltip = 'Remez a target when its mez has this many seconds left.',
        })
        if rfChanged and onChange then onChange('MezRefreshWindow', rfVal) end
    end, { id = 'cc_mez_settings', defaultOpen = false })

    Components.SettingGroup.draw('Charm Pet', function()
        local charmOn = settings.CharmEnabled == true
        local chVal, chChanged = Components.CheckboxRow.draw('Charm Pet Enabled', 'CharmEnabled', charmOn, nil, {
            tooltip = 'Keep an NPC charmed as a DPS pet (ENC). Target cap comes from the charm spell itself; named mobs are never charmed.',
        })
        if chChanged and onChange then onChange('CharmEnabled', chVal) end

        local blacklist = tostring(settings.CharmClassBlacklist or 'CLR SHM')
        local blBuf = Settings.labeledInputText('Class Blacklist', blacklist)
        if blBuf ~= blacklist and onChange then
            onChange('CharmClassBlacklist', blBuf)
        end
        if imgui.IsItemHovered() then
            imgui.SetTooltip('NPC class short-names never charmed (space/pipe separated).\nHealer pets waste their time healing the camp.')
        end

        local preTashOn = settings.CharmPreTash ~= false
        local ptVal, ptChanged = Components.CheckboxRow.draw('Tash Before First Charm', 'CharmPreTash', preTashOn, nil, {
            tooltip = 'Tash the charm candidate before the first charm attempt (damageless, mez-safe).',
        })
        if ptChanged and onChange then onChange('CharmPreTash', ptVal) end

        local tashOn = settings.CharmBreakTash ~= false
        local tashVal, tashChanged = Components.CheckboxRow.draw('Tash Before Recharm', 'CharmBreakTash', tashOn, nil, {
            tooltip = 'On charm break, tash the loose pet first (if not already tashed).',
        })
        if tashChanged and onChange then onChange('CharmBreakTash', tashVal) end

        local stunOn = settings.CharmBreakStun ~= false
        local stunVal, stunChanged = Components.CheckboxRow.draw('AE Stun On Charm Break', 'CharmBreakStun', stunOn, nil, {
            tooltip = 'Color Stun the loose pet before recharming (damageless — safe near mezzed mobs).',
        })
        if stunChanged and onChange then onChange('CharmBreakStun', stunVal) end

        local holdAt = tonumber(settings.CharmHoldUnmezzed) or 3
        local holdChanged, holdVal = Components.SliderRow.int('Hold Recharm If Unmezzed >', 'CharmHoldUnmezzed', holdAt, 0, 8, nil, {
            tooltip = 'On charm break, defer recharming while more than this many\nunmezzed mobs are in camp — mez gets the camp under control first.',
        })
        if holdChanged and onChange then onChange('CharmHoldUnmezzed', holdVal) end
    end, { id = 'cc_charm_settings', defaultOpen = false })

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
