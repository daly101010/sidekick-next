local imgui = require('ImGui')
local mq = require('mq')
local Items = require('utils.items')
local ActorsCoordinator = require('utils.actors_coordinator')
local RemoteAbilities = require('ui.remote_abilities')
local ConditionBuilder = require('ui.condition_builder')
local Core = require('utils.core')

-- Lazy-load class settings
local _ClassSettings = nil
local function getClassSettings()
    if not _ClassSettings then
        local ok, cs = pcall(require, 'ui.class_settings')
        if ok then _ClassSettings = cs end
    end
    return _ClassSettings
end

local M = {}

local function safeTooltip(text)
    text = tostring(text or '')
    if text == '' then return end
    -- MacroQuest's ImGui bindings expose SetTooltip as a printf-style function; escape '%'.
    text = text:gsub('%%', '%%%%')
    pcall(imgui.SetTooltip, text)
end

local function comboString(label, current, options)
    current = tostring(current or '')
    options = options or {}

    -- Build null-separated labels string and find current index
    local currentIdx = 1
    for i, opt in ipairs(options) do
        if opt == current then
            currentIdx = i
            break
        end
    end
    local labelStr = table.concat(options, '\0') .. '\0\0'

    -- Use imgui.Combo which returns new index directly (1-based in MQ)
    local newIdx = imgui.Combo(label, currentIdx, labelStr)
    if newIdx ~= currentIdx and options[newIdx] then
        return options[newIdx]
    end
    return current
end

local function comboKeyed(label, currentKey, options)
    currentKey = tostring(currentKey or '')
    options = options or {}

    -- Build null-separated labels string and find current index
    local labels = {}
    local currentIdx = 1
    for i, opt in ipairs(options) do
        table.insert(labels, opt.label)
        if opt.key == currentKey then
            currentIdx = i
        end
    end
    local labelStr = table.concat(labels, '\0') .. '\0\0'

    -- Use imgui.Combo which returns new index directly (1-based in MQ)
    local newIdx = imgui.Combo(label, currentIdx, labelStr)
    if newIdx ~= currentIdx and options[newIdx] then
        return options[newIdx].key
    end
    return currentKey
end

local ANCHOR_TARGETS = {
    { key = 'grouptarget', label = 'GroupTarget' },
    { key = 'sidekick_main', label = 'SideKick Main' },
    { key = 'sidekick_bar', label = 'SideKick Ability Bar' },
    { key = 'sidekick_special', label = 'SideKick Special Bar' },
    { key = 'sidekick_disc', label = 'SideKick Disc Bar' },
    { key = 'sidekick_items', label = 'SideKick Item Bar' },
}

local function drawUI(settings, themeNames, onChange)
    local theme = comboString('Theme', settings.SideKickTheme or 'Classic', themeNames)
    if theme ~= (settings.SideKickTheme or 'Classic') and onChange then
        onChange('SideKickTheme', theme)
    end

    local sync = settings.SideKickSyncThemeWithGT == true
    local changed
    sync, changed = imgui.Checkbox('Sync theme with GroupTarget', sync)
    if changed and onChange then
        onChange('SideKickSyncThemeWithGT', sync)
    end

    imgui.Separator()
    imgui.Text('Docking')

    local anchors = { 'none', 'left', 'right', 'above', 'below', 'left_bottom', 'right_bottom' }
    local mainTarget = comboKeyed('Main Anchor To', settings.SideKickMainAnchorTarget or 'grouptarget', ANCHOR_TARGETS)
    if mainTarget ~= tostring(settings.SideKickMainAnchorTarget or 'grouptarget') and onChange then
        onChange('SideKickMainAnchorTarget', mainTarget)
    end

    local mainAnchor = tostring(settings.SideKickMainAnchor or 'none')
    mainAnchor = comboString('Main Anchor Mode', mainAnchor, anchors)
    if mainAnchor ~= tostring(settings.SideKickMainAnchor or 'none') and onChange then
        onChange('SideKickMainAnchor', mainAnchor)
    end

    local matchW = settings.SideKickMainMatchGTWidth == true
    matchW, changed = imgui.Checkbox('Match GroupTarget width', matchW)
    if changed and onChange then
        onChange('SideKickMainMatchGTWidth', matchW)
    end

    local gap = tonumber(settings.SideKickMainAnchorGap) or 2
    gap, changed = imgui.SliderInt('Main Anchor Gap', gap, 0, 24)
    if changed and onChange then
        onChange('SideKickMainAnchorGap', gap)
    end
end

local function drawBar(settings, onChange)
    local changed

    local barEnabled = settings.SideKickBarEnabled ~= false
    barEnabled, changed = imgui.Checkbox('Show ability bar', barEnabled)
    if changed and onChange then onChange('SideKickBarEnabled', barEnabled) end

    local cell = tonumber(settings.SideKickBarCell) or 48
    local rows = tonumber(settings.SideKickBarRows) or 2
    local gap = tonumber(settings.SideKickBarGap) or 4
    local alpha = tonumber(settings.SideKickBarBgAlpha) or 0.85
    local pad = tonumber(settings.SideKickBarPad) or 6
    local anchorGap = tonumber(settings.SideKickBarAnchorGap) or 2

    cell, changed = imgui.SliderInt('Cell Size', cell, 36, 120)
    if changed and onChange then onChange('SideKickBarCell', cell) end

    rows, changed = imgui.SliderInt('Rows', rows, 1, 6)
    if changed and onChange then onChange('SideKickBarRows', rows) end

    gap, changed = imgui.SliderInt('Gap', gap, 0, 12)
    if changed and onChange then onChange('SideKickBarGap', gap) end

    pad, changed = imgui.SliderInt('Padding', pad, 0, 24)
    if changed and onChange then onChange('SideKickBarPad', pad) end

    alpha, changed = imgui.SliderFloat('Background Alpha', alpha, 0.2, 1.0)
    if changed and onChange then onChange('SideKickBarBgAlpha', alpha) end

    local anchors = { 'none', 'left', 'right', 'above', 'below', 'left_bottom', 'right_bottom' }
    local target = comboKeyed('Anchor To', settings.SideKickBarAnchorTarget or 'grouptarget', ANCHOR_TARGETS)
    if target ~= tostring(settings.SideKickBarAnchorTarget or 'grouptarget') and onChange then
        onChange('SideKickBarAnchorTarget', target)
    end
    local anchor = tostring(settings.SideKickBarAnchor or 'none')
    anchor = comboString('Anchor Mode', anchor, anchors)
    if anchor ~= tostring(settings.SideKickBarAnchor or 'none') and onChange then
        onChange('SideKickBarAnchor', anchor)
    end

    anchorGap, changed = imgui.SliderInt('Anchor Gap', anchorGap, 0, 24)
    if changed and onChange then onChange('SideKickBarAnchorGap', anchorGap) end
end

local function drawSpecial(settings, onChange)
    local changed

    local specEnabled = settings.SideKickSpecialEnabled ~= false
    specEnabled, changed = imgui.Checkbox('Show special abilities', specEnabled)
    if changed and onChange then onChange('SideKickSpecialEnabled', specEnabled) end

    local specCell = tonumber(settings.SideKickSpecialCell) or 65
    local specRows = tonumber(settings.SideKickSpecialRows) or 1
    local specGap = tonumber(settings.SideKickSpecialGap) or 4
    local specAlpha = tonumber(settings.SideKickSpecialBgAlpha) or 0.85
    local specPad = tonumber(settings.SideKickSpecialPad) or 6
    local specAnchorGap = tonumber(settings.SideKickSpecialAnchorGap) or 2

    specCell, changed = imgui.SliderInt('Cell Size', specCell, 36, 120)
    if changed and onChange then onChange('SideKickSpecialCell', specCell) end

    specRows, changed = imgui.SliderInt('Rows', specRows, 1, 6)
    if changed and onChange then onChange('SideKickSpecialRows', specRows) end

    specGap, changed = imgui.SliderInt('Gap', specGap, 0, 12)
    if changed and onChange then onChange('SideKickSpecialGap', specGap) end

    specPad, changed = imgui.SliderInt('Padding', specPad, 0, 24)
    if changed and onChange then onChange('SideKickSpecialPad', specPad) end

    specAlpha, changed = imgui.SliderFloat('Background Alpha', specAlpha, 0.2, 1.0)
    if changed and onChange then onChange('SideKickSpecialBgAlpha', specAlpha) end

    local anchors = { 'none', 'left', 'right', 'above', 'below', 'left_bottom', 'right_bottom' }
    local target = comboKeyed('Anchor To', settings.SideKickSpecialAnchorTarget or 'grouptarget', ANCHOR_TARGETS)
    if target ~= tostring(settings.SideKickSpecialAnchorTarget or 'grouptarget') and onChange then
        onChange('SideKickSpecialAnchorTarget', target)
    end
    local specAnchor = tostring(settings.SideKickSpecialAnchor or 'none')
    specAnchor = comboString('Anchor Mode', specAnchor, anchors)
    if specAnchor ~= tostring(settings.SideKickSpecialAnchor or 'none') and onChange then
        onChange('SideKickSpecialAnchor', specAnchor)
    end

    specAnchorGap, changed = imgui.SliderInt('Anchor Gap', specAnchorGap, 0, 24)
    if changed and onChange then onChange('SideKickSpecialAnchorGap', specAnchorGap) end
end

local function drawDisciplines(settings, onChange)
    local changed

    local discBar = settings.SideKickDiscBarEnabled ~= false
    discBar, changed = imgui.Checkbox('Show disciplines bar (BER)', discBar)
    if changed and onChange then onChange('SideKickDiscBarEnabled', discBar) end

    local discCell = tonumber(settings.SideKickDiscBarCell) or 48
    local discRows = tonumber(settings.SideKickDiscBarRows) or 2
    local discGap = tonumber(settings.SideKickDiscBarGap) or 4
    local discAlpha = tonumber(settings.SideKickDiscBarBgAlpha) or 0.85
    local discPad = tonumber(settings.SideKickDiscBarPad) or 6
    local discAnchorGap = tonumber(settings.SideKickDiscBarAnchorGap) or 2

    discCell, changed = imgui.SliderInt('Cell Size', discCell, 36, 120)
    if changed and onChange then onChange('SideKickDiscBarCell', discCell) end

    discRows, changed = imgui.SliderInt('Rows', discRows, 1, 6)
    if changed and onChange then onChange('SideKickDiscBarRows', discRows) end

    discGap, changed = imgui.SliderInt('Gap', discGap, 0, 12)
    if changed and onChange then onChange('SideKickDiscBarGap', discGap) end

    discPad, changed = imgui.SliderInt('Padding', discPad, 0, 24)
    if changed and onChange then onChange('SideKickDiscBarPad', discPad) end

    discAlpha, changed = imgui.SliderFloat('Background Alpha', discAlpha, 0.2, 1.0)
    if changed and onChange then onChange('SideKickDiscBarBgAlpha', discAlpha) end

    local anchors = { 'none', 'left', 'right', 'above', 'below', 'left_bottom', 'right_bottom' }
    local target = comboKeyed('Anchor To', settings.SideKickDiscBarAnchorTarget or 'grouptarget', ANCHOR_TARGETS)
    if target ~= tostring(settings.SideKickDiscBarAnchorTarget or 'grouptarget') and onChange then
        onChange('SideKickDiscBarAnchorTarget', target)
    end
    local discAnchor = tostring(settings.SideKickDiscBarAnchor or 'none')
    discAnchor = comboString('Anchor Mode', discAnchor, anchors)
    if discAnchor ~= tostring(settings.SideKickDiscBarAnchor or 'none') and onChange then
        onChange('SideKickDiscBarAnchor', discAnchor)
    end

    discAnchorGap, changed = imgui.SliderInt('Anchor Gap', discAnchorGap, 0, 24)
    if changed and onChange then onChange('SideKickDiscBarAnchorGap', discAnchorGap) end
end

local function drawAutomation(settings, onChange)
    local changed
    -- Combat Mode vs Chase & Assist: These are complementary systems, not competing ones.
    -- - Combat Mode (tank/assist): Controls HOW targeting and aggro work
    --   Tank mode: auto-target selection, aggro management, positioning
    --   Assist mode: follow tank targets with sticky/follow targeting
    -- - Chase & Assist toggles: Control WHETHER automation is enabled
    --   Chase: Follow the designated role (MA/MT/leader)
    --   Assist: Enable combat assist functionality
    -- Both systems work together - Combat Mode defines behavior, toggles enable/disable it.

    -- ========== COMBAT MODE SECTION ==========
    imgui.TextColored(0.7, 0.9, 1.0, 1.0, 'Combat Mode')
    imgui.Separator()

    -- Combat Mode dropdown
    local combatModes = { 'off', 'assist', 'tank' }
    local combatMode = tostring(settings.CombatMode or 'off')
    combatMode = comboString('Mode', combatMode, combatModes)
    if combatMode ~= tostring(settings.CombatMode or 'off') and onChange then
        onChange('CombatMode', combatMode)
    end
    if imgui.IsItemHovered() then
        safeTooltip('Off: Disabled. Tank: Control targeting and aggro. Assist: Follow tank targets.')
    end

    imgui.Spacing()

    -- Tank-specific settings (only show when tank mode)
    if combatMode == 'tank' then
        imgui.Indent()
        imgui.TextColored(0.8, 0.8, 0.8, 1.0, 'Tank Settings')

        local tankTargetModes = { 'auto', 'manual' }
        local tankTargetMode = tostring(settings.TankTargetMode or 'auto')
        tankTargetMode = comboString('Target Mode', tankTargetMode, tankTargetModes)
        if tankTargetMode ~= tostring(settings.TankTargetMode or 'auto') and onChange then
            onChange('TankTargetMode', tankTargetMode)
        end
        if imgui.IsItemHovered() then
            safeTooltip('Auto: Automatically select targets by priority. Manual: Use your current target.')
        end

        local aoeThreshold = tonumber(settings.TankAoEThreshold) or 3
        aoeThreshold, changed = imgui.SliderInt('AoE Mob Threshold', aoeThreshold, 2, 8)
        if changed and onChange then onChange('TankAoEThreshold', aoeThreshold) end
        if imgui.IsItemHovered() then
            safeTooltip('Use AoE hate abilities when this many mobs are in range.')
        end

        local requireDeficit = settings.TankRequireAggroDeficit ~= false
        requireDeficit, changed = imgui.Checkbox('Require Aggro Deficit', requireDeficit)
        if changed and onChange then onChange('TankRequireAggroDeficit', requireDeficit) end
        if imgui.IsItemHovered() then
            safeTooltip('Only use AoE hate when mobs have aggro on others.')
        end

        local safeAE = settings.TankSafeAECheck == true
        safeAE, changed = imgui.Checkbox('Safe AE Check', safeAE)
        if changed and onChange then onChange('TankSafeAECheck', safeAE) end
        if imgui.IsItemHovered() then
            safeTooltip('Skip AoE if any mezzed mob is detected on XTarget (CC/Actors-aware).')
        end

        local reposition = settings.TankRepositionEnabled == true
        reposition, changed = imgui.Checkbox('Auto Reposition', reposition)
        if changed and onChange then onChange('TankRepositionEnabled', reposition) end
        if imgui.IsItemHovered() then
            safeTooltip('Periodically reposition to face mobs away from group.')
        end

        local repoCooldown = tonumber(settings.TankRepositionCooldown) or 5
        repoCooldown, changed = imgui.SliderInt('Reposition Cooldown (sec)', repoCooldown, 2, 15)
        if changed and onChange then onChange('TankRepositionCooldown', repoCooldown) end

        imgui.Unindent()
        imgui.Spacing()
    end

    -- Assist-specific settings (only show when assist mode)
    if combatMode == 'assist' then
        imgui.Indent()
        imgui.TextColored(0.8, 0.8, 0.8, 1.0, 'Assist Settings')

        local assistTargetModes = { 'sticky', 'follow' }
        local assistTargetMode = tostring(settings.AssistTargetMode or 'sticky')
        assistTargetMode = comboString('Target Mode', assistTargetMode, assistTargetModes)
        if assistTargetMode ~= tostring(settings.AssistTargetMode or 'sticky') and onChange then
            onChange('AssistTargetMode', assistTargetMode)
        end
        if imgui.IsItemHovered() then
            safeTooltip('Sticky: Stay on target until dead. Follow: Match tank target always.')
        end

        local engageConditions = { 'hp', 'tank_aggro' }
        local engageCondition = tostring(settings.AssistEngageCondition or 'hp')
        engageCondition = comboString('Engage Condition', engageCondition, engageConditions)
        if engageCondition ~= tostring(settings.AssistEngageCondition or 'hp') and onChange then
            onChange('AssistEngageCondition', engageCondition)
        end
        if imgui.IsItemHovered() then
            safeTooltip('HP: Engage when target HP drops below threshold. Tank Aggro: Engage when tank has aggro.')
        end

        local engageHp = tonumber(settings.AssistEngageHpThreshold) or 97
        engageHp, changed = imgui.SliderInt('Engage HP %', engageHp, 50, 100)
        if changed and onChange then onChange('AssistEngageHpThreshold', engageHp) end
        if imgui.IsItemHovered() then
            safeTooltip('Engage when target HP drops to this percent (HP mode only).')
        end

        imgui.Unindent()
        imgui.Spacing()
    end

    -- Positioning settings (both modes)
    imgui.TextColored(0.8, 0.8, 0.8, 1.0, 'Positioning')
    imgui.SetNextItemWidth(300)
    local stickCmd = tostring(settings.StickCommand or '/stick snaproll behind 10 moveback uw')
    stickCmd, changed = imgui.InputText('Stick Command', stickCmd, 256)
    if changed and onChange then onChange('StickCommand', stickCmd) end
    if imgui.IsItemHovered() then
        safeTooltip('MQ2MoveUtils /stick command for combat positioning.')
    end

    imgui.Spacing()
    imgui.Separator()
    imgui.Spacing()

    -- ========== TARGET BROADCASTING ==========
    imgui.TextColored(0.7, 0.9, 1.0, 1.0, 'Target Broadcasting')
    imgui.Separator()

    -- AssistMe button
    imgui.PushStyleColor(ImGuiCol.Button, 0.6, 0.3, 0.1, 0.9)
    imgui.PushStyleColor(ImGuiCol.ButtonHovered, 0.7, 0.4, 0.2, 1.0)
    imgui.PushStyleColor(ImGuiCol.ButtonActive, 0.5, 0.25, 0.1, 1.0)
    if imgui.Button('Assist Me!') then
        ActorsCoordinator.broadcastAssistMe()
    end
    imgui.PopStyleColor(3)
    if imgui.IsItemHovered() then
        safeTooltip('Broadcast to all SideKick peers in the same zone to assist your current target. Also: /sidekick assistme or /skassistme')
    end

    imgui.Spacing()
    imgui.TextColored(0.8, 0.8, 0.8, 1.0, 'Assist Outside Settings')

    local assistGroup = settings.AssistOutsideGroup ~= false
    assistGroup, changed = imgui.Checkbox('Assist Group Members', assistGroup)
    if changed and onChange then onChange('AssistOutsideGroup', assistGroup) end
    if imgui.IsItemHovered() then
        safeTooltip('Allow assisting targets engaged with group members.')
    end

    local assistRaid = settings.AssistOutsideRaid ~= false
    assistRaid, changed = imgui.Checkbox('Assist Raid Members', assistRaid)
    if changed and onChange then onChange('AssistOutsideRaid', assistRaid) end
    if imgui.IsItemHovered() then
        safeTooltip('Allow assisting targets engaged with raid members.')
    end

    local assistPeers = settings.AssistOutsidePeers ~= false
    assistPeers, changed = imgui.Checkbox('Assist Actor Peers (Same Zone)', assistPeers)
    if changed and onChange then onChange('AssistOutsidePeers', assistPeers) end
    if imgui.IsItemHovered() then
        safeTooltip('Allow assisting targets engaged with other SideKick instances in the same zone.')
    end

    imgui.Spacing()
    imgui.TextColored(0.8, 0.8, 0.8, 1.0, 'Scan Settings')

    local zRange = tonumber(settings.MAScanZRange) or 100
    zRange, changed = imgui.SliderInt('MA Scan Z Range', zRange, 10, 500)
    if changed and onChange then onChange('MAScanZRange', zRange) end
    if imgui.IsItemHovered() then
        safeTooltip('Z-axis range for scanning MA targets (vertical distance).')
    end

    imgui.Spacing()
    imgui.Separator()
    imgui.Spacing()

    -- ========== AUTOMATION TOGGLES ==========
    -- These toggles enable/disable the automation features configured above.
    imgui.TextColored(0.7, 0.9, 1.0, 1.0, 'Auto Actions')
    imgui.Separator()

    local playStyle = tostring(settings.AutomationLevel or 'auto')
    playStyle = comboString('Play Style', playStyle, { 'manual', 'hybrid', 'auto' })
    if playStyle ~= tostring(settings.AutomationLevel or 'auto') and onChange then
        onChange('AutomationLevel', playStyle)
    end
    if imgui.IsItemHovered() then
        safeTooltip('Manual: UI only (no automation). Hybrid: auto abilities/items only. Auto: enable movement/targeting automation (chase/tank/assist) in addition to abilities/items.')
    end

    local autoAbilities = settings.AutoAbilitiesEnabled ~= false
    autoAbilities, changed = imgui.Checkbox('Auto Abilities', autoAbilities)
    if changed and onChange then onChange('AutoAbilitiesEnabled', autoAbilities) end
    if imgui.IsItemHovered() then
        safeTooltip('Enable automatic AA/Disc execution for abilities set to auto modes (On Cooldown/Burn/Named/Condition).')
    end

    local autoItems = settings.AutoItemsEnabled ~= false
    autoItems, changed = imgui.Checkbox('Auto Items', autoItems)
    if changed and onChange then onChange('AutoItemsEnabled', autoItems) end
    if imgui.IsItemHovered() then
        safeTooltip('Enable automatic item clicking for item slots set to Combat/OOC/On Condition.')
    end

    imgui.Spacing()
    imgui.Separator()
    imgui.Spacing()

    imgui.TextColored(0.7, 0.9, 1.0, 1.0, 'Meditation')
    imgui.Separator()

    local medMode = tostring(settings.MeditationMode or 'off')
    medMode = comboString('Meditation Mode', medMode, { 'off', 'ooc', 'in combat' })
    if medMode ~= tostring(settings.MeditationMode or 'off') and onChange then
        onChange('MeditationMode', medMode)
    end
    if imgui.IsItemHovered() then
        safeTooltip('Off: never sit/stand. OOC: sit only when not in combat. In Combat: allow sitting during combat (still uses aggro + movement safety checks).')
    end

    if tostring(medMode):lower() ~= 'off' then
        imgui.Indent()

        local afterDelay = tonumber(settings.MeditationAfterCombatDelay) or 2
        afterDelay, changed = imgui.SliderFloat('After Combat Delay (sec)', afterDelay, 0.0, 10.0)
        if changed and onChange then onChange('MeditationAfterCombatDelay', afterDelay) end
        if imgui.IsItemHovered() then
            safeTooltip('Wait this long after combat ends before sitting (plus small random jitter).')
        end

        local standDone = settings.MeditationStandWhenDone ~= false
        standDone, changed = imgui.Checkbox('Stand When Done', standDone)
        if changed and onChange then onChange('MeditationStandWhenDone', standDone) end

        local minHold = tonumber(settings.MeditationMinStateSeconds) or 1
        minHold, changed = imgui.SliderFloat('Min Sit/Stand Hold (sec)', minHold, 0.0, 5.0)
        if changed and onChange then onChange('MeditationMinStateSeconds', minHold) end
        if imgui.IsItemHovered() then
            safeTooltip('Prevents sit/stand spam when other automation momentarily stands you (casting, stick/nav, etc.).')
        end

        local aggroCheck = settings.MeditationAggroCheck ~= false
        aggroCheck, changed = imgui.Checkbox('Aggro Safety Check', aggroCheck)
        if changed and onChange then onChange('MeditationAggroCheck', aggroCheck) end

        local aggroPct = tonumber(settings.MeditationAggroPct) or 95
        aggroPct, changed = imgui.SliderInt('Aggro % Threshold', aggroPct, 1, 100)
        if changed and onChange then onChange('MeditationAggroPct', aggroPct) end
        if imgui.IsItemHovered() then
            safeTooltip('Stand (and do not sit) when your aggro is at or above this percent, or when a hater is targeting you.')
        end

        imgui.Spacing()
        imgui.TextColored(0.8, 0.8, 0.8, 1.0, 'Thresholds (Start/Stop)')

        local hpStart = tonumber(settings.MeditationHPStartPct) or 70
        hpStart, changed = imgui.SliderInt('HP Start %', hpStart, 1, 100)
        if changed and onChange then onChange('MeditationHPStartPct', hpStart) end
        local hpStop = tonumber(settings.MeditationHPStopPct) or 95
        hpStop, changed = imgui.SliderInt('HP Stop %', hpStop, 1, 100)
        if changed and onChange then onChange('MeditationHPStopPct', hpStop) end

        local manaStart = tonumber(settings.MeditationManaStartPct) or 50
        manaStart, changed = imgui.SliderInt('Mana Start %', manaStart, 1, 100)
        if changed and onChange then onChange('MeditationManaStartPct', manaStart) end
        local manaStop = tonumber(settings.MeditationManaStopPct) or 95
        manaStop, changed = imgui.SliderInt('Mana Stop %', manaStop, 1, 100)
        if changed and onChange then onChange('MeditationManaStopPct', manaStop) end

        local endStart = tonumber(settings.MeditationEndStartPct) or 60
        endStart, changed = imgui.SliderInt('Endurance Start %', endStart, 1, 100)
        if changed and onChange then onChange('MeditationEndStartPct', endStart) end
        local endStop = tonumber(settings.MeditationEndStopPct) or 95
        endStop, changed = imgui.SliderInt('Endurance Stop %', endStop, 1, 100)
        if changed and onChange then onChange('MeditationEndStopPct', endStop) end

        imgui.Unindent()
    end

    imgui.Spacing()
    imgui.Separator()
    imgui.Spacing()

    imgui.TextColored(0.7, 0.9, 1.0, 1.0, 'Chase & Assist')
    imgui.Separator()

    local chase = settings.ChaseEnabled == true
    chase, changed = imgui.Checkbox('Chase', chase)
    if changed and onChange then onChange('ChaseEnabled', chase) end

    local chaseRole = tostring(settings.ChaseRole or 'ma')
    chaseRole = comboString('Chase Role', chaseRole, { 'none', 'ma', 'mt', 'leader', 'raid1', 'raid2', 'raid3' })
    if chaseRole ~= tostring(settings.ChaseRole or 'ma') and onChange then onChange('ChaseRole', chaseRole) end

    local chaseDist = tonumber(settings.ChaseDistance) or 30
    chaseDist, changed = imgui.SliderInt('Chase Distance', chaseDist, 15, 300)
    if changed and onChange then onChange('ChaseDistance', chaseDist) end

    local assist = settings.AssistEnabled == true
    assist, changed = imgui.Checkbox('Assist', assist)
    if changed and onChange then onChange('AssistEnabled', assist) end

    local assistMode = tostring(settings.AssistMode or 'group')
    assistMode = comboString('Assist Mode', assistMode, { 'group', 'raid1', 'raid2', 'raid3', 'byname' })
    if assistMode ~= tostring(settings.AssistMode or 'group') and onChange then onChange('AssistMode', assistMode) end

    local assistAt = tonumber(settings.AssistAt) or 97
    assistAt, changed = imgui.SliderInt('Assist At %', assistAt, 1, 100)
    if changed and onChange then onChange('AssistAt', assistAt) end

    local assistRange = tonumber(settings.AssistRange) or 100
    assistRange, changed = imgui.SliderInt('Assist Range', assistRange, 10, 300)
    if changed and onChange then onChange('AssistRange', assistRange) end

    imgui.Spacing()
    imgui.Separator()
    imgui.Spacing()

    imgui.TextColored(0.7, 0.9, 1.0, 1.0, 'Burn')
    imgui.Separator()

    local burn = settings.BurnActive == true
    burn, changed = imgui.Checkbox('Burn (phase active)', burn)
    if changed and onChange then onChange('BurnActive', burn) end

    local burnDur = tonumber(settings.BurnDuration) or 30
    burnDur, changed = imgui.SliderInt('Burn Duration (sec)', burnDur, 5, 120)
    if changed and onChange then onChange('BurnDuration', burnDur) end

    imgui.Spacing()
    imgui.Separator()
    imgui.Spacing()

    -- ========== CASTER ASSIST SECTION ==========
    imgui.TextColored(0.7, 0.9, 1.0, 1.0, 'Caster Assist')
    imgui.Separator()

    local casterUseStick = settings.CasterUseStick == true
    casterUseStick, changed = imgui.Checkbox('Use Stick (melee mode)', casterUseStick)
    if changed and onChange then onChange('CasterUseStick', casterUseStick) end
    if imgui.IsItemHovered() then
        safeTooltip('When enabled, casters will use stick commands like melee classes instead of staying at range.')
    end

    local casterEscapeRange = tonumber(settings.CasterEscapeRange) or 30
    casterEscapeRange, changed = imgui.SliderInt('Escape Range', casterEscapeRange, 10, 100)
    if changed and onChange then onChange('CasterEscapeRange', casterEscapeRange) end
    if imgui.IsItemHovered() then
        safeTooltip('Distance to move away when mob gets too close.')
    end

    local casterSafeZoneRadius = tonumber(settings.CasterSafeZoneRadius) or 30
    casterSafeZoneRadius, changed = imgui.SliderInt('Safe Zone Radius', casterSafeZoneRadius, 10, 100)
    if changed and onChange then onChange('CasterSafeZoneRadius', casterSafeZoneRadius) end
    if imgui.IsItemHovered() then
        safeTooltip('Radius around tank/group to stay within while escaping.')
    end

    -- Resist type dropdown
    local resistTypes = { 'Any', 'Magic', 'Fire', 'Cold', 'Poison', 'Disease', 'Chromatic' }
    local currentResist = tostring(settings.PreferredResistType or 'Any')
    currentResist = comboString('Preferred Resist', currentResist, resistTypes)
    if currentResist ~= tostring(settings.PreferredResistType or 'Any') and onChange then
        onChange('PreferredResistType', currentResist)
    end
    if imgui.IsItemHovered() then
        safeTooltip('Preferred resist type for spell selection when multiple options exist.')
    end

    imgui.Spacing()
    imgui.Separator()
    imgui.Spacing()

    -- ========== SPELL ROTATION SECTION ==========
    imgui.TextColored(0.7, 0.9, 1.0, 1.0, 'Spell Rotation')
    imgui.Separator()

    local spellRotationEnabled = settings.SpellRotationEnabled == true
    spellRotationEnabled, changed = imgui.Checkbox('Enable Spell Rotation', spellRotationEnabled)
    if changed and onChange then onChange('SpellRotationEnabled', spellRotationEnabled) end
    if imgui.IsItemHovered() then
        safeTooltip('Enable automatic spell rotation system for casters.')
    end

    local rotationResetWindow = tonumber(settings.RotationResetWindow) or 2
    rotationResetWindow, changed = imgui.SliderInt('Reset Window (sec)', rotationResetWindow, 0, 10)
    if changed and onChange then onChange('RotationResetWindow', rotationResetWindow) end
    if imgui.IsItemHovered() then
        safeTooltip('Seconds of no casting before rotation resets to first spell.')
    end

    imgui.Spacing()
    imgui.Text('Retry Settings')
    imgui.Indent()

    local retryOnFizzle = settings.RetryOnFizzle ~= false
    retryOnFizzle, changed = imgui.Checkbox('Retry on Fizzle', retryOnFizzle)
    if changed and onChange then onChange('RetryOnFizzle', retryOnFizzle) end
    if imgui.IsItemHovered() then
        safeTooltip('Automatically retry the spell if it fizzles.')
    end

    local retryOnResist = settings.RetryOnResist ~= false
    retryOnResist, changed = imgui.Checkbox('Retry on Resist', retryOnResist)
    if changed and onChange then onChange('RetryOnResist', retryOnResist) end
    if imgui.IsItemHovered() then
        safeTooltip('Automatically retry the spell if the target resists.')
    end

    local retryOnInterrupt = settings.RetryOnInterrupt ~= false
    retryOnInterrupt, changed = imgui.Checkbox('Retry on Interrupt', retryOnInterrupt)
    if changed and onChange then onChange('RetryOnInterrupt', retryOnInterrupt) end
    if imgui.IsItemHovered() then
        safeTooltip('Automatically retry the spell if casting is interrupted.')
    end

    imgui.Unindent()

    imgui.Spacing()
    local useImmuneDatabase = settings.UseImmuneDatabase ~= false
    useImmuneDatabase, changed = imgui.Checkbox('Use Immune Database', useImmuneDatabase)
    if changed and onChange then onChange('UseImmuneDatabase', useImmuneDatabase) end
    if imgui.IsItemHovered() then
        safeTooltip('Track and remember mob immunities to avoid casting ineffective spells.')
    end

    imgui.Separator()
    imgui.TextColored(0.6, 0.8, 1.0, 1.0, 'Spell Lineup')

    local spellRescanOnZone = settings.SpellRescanOnZone ~= false
    spellRescanOnZone, changed = imgui.Checkbox('Rescan Gems on Zone', spellRescanOnZone)
    if changed and onChange then onChange('SpellRescanOnZone', spellRescanOnZone) end
    if imgui.IsItemHovered() then
        safeTooltip('Automatically rescan memorized spells when changing zones')
    end

    local healThreshold = tonumber(settings.HealThreshold) or 80
    healThreshold, changed = imgui.SliderInt('Heal HP Threshold', healThreshold, 10, 100)
    if changed and onChange then onChange('HealThreshold', healThreshold) end
    if imgui.IsItemHovered() then
        safeTooltip('HP percentage below which healing spells will trigger')
    end

    local healPetsEnabled = settings.HealPetsEnabled == true
    healPetsEnabled, changed = imgui.Checkbox('Heal Pets', healPetsEnabled)
    if changed and onChange then onChange('HealPetsEnabled', healPetsEnabled) end
    if imgui.IsItemHovered() then
        safeTooltip('Include group pets as valid heal targets')
    end

    imgui.Spacing()
    imgui.Separator()
    imgui.Spacing()

    -- ========== MEZ SECTION (ENC/BRD only) ==========
    local mezClasses = { ENC = true, BRD = true }
    local meClass = mq.TLO.Me and mq.TLO.Me.Class and mq.TLO.Me.Class.ShortName and mq.TLO.Me.Class.ShortName() or ''
    if mezClasses[tostring(meClass):upper()] then
        imgui.TextColored(0.7, 0.9, 1.0, 1.0, 'Mezzing')
        imgui.Separator()

        local mezzingEnabled = settings.MezzingEnabled == true
        mezzingEnabled, changed = imgui.Checkbox('Enable Mezzing', mezzingEnabled)
        if changed and onChange then onChange('MezzingEnabled', mezzingEnabled) end
        if imgui.IsItemHovered() then
            safeTooltip('Enable automatic mez casting on XTarget haters.')
        end

        if mezzingEnabled then
            imgui.Indent()

            local mezMinLevel = tonumber(settings.MezMinLevel) or 0
            mezMinLevel, changed = imgui.SliderInt('Min Mob Level', mezMinLevel, 0, 130)
            if changed and onChange then onChange('MezMinLevel', mezMinLevel) end
            if imgui.IsItemHovered() then
                safeTooltip('Skip mobs below this level (0 = no minimum). Use to skip grey cons.')
            end

            local mezMaxTargets = tonumber(settings.MezMaxTargets) or 3
            mezMaxTargets, changed = imgui.SliderInt('Max Mez Targets', mezMaxTargets, 1, 10)
            if changed and onChange then onChange('MezMaxTargets', mezMaxTargets) end
            if imgui.IsItemHovered() then
                safeTooltip('Maximum number of mobs to keep mezzed at once.')
            end

            local mezRefreshWindow = tonumber(settings.MezRefreshWindow) or 6
            mezRefreshWindow, changed = imgui.SliderInt('Refresh Window (sec)', mezRefreshWindow, 1, 15)
            if changed and onChange then onChange('MezRefreshWindow', mezRefreshWindow) end
            if imgui.IsItemHovered() then
                safeTooltip('Refresh mez when this many seconds remain.')
            end

            local useFastMez = settings.UseFastMez ~= false
            useFastMez, changed = imgui.Checkbox('Use Fast Mez', useFastMez)
            if changed and onChange then onChange('UseFastMez', useFastMez) end
            if imgui.IsItemHovered() then
                safeTooltip('Prefer fast/flash mez spells when available.')
            end

            local useAEMez = settings.UseAEMez == true
            useAEMez, changed = imgui.Checkbox('Use AE Mez', useAEMez)
            if changed and onChange then onChange('UseAEMez', useAEMez) end
            if imgui.IsItemHovered() then
                safeTooltip('Use AE mez when enough targets are in range.')
            end

            if useAEMez then
                local aeMezMinTargets = tonumber(settings.AEMezMinTargets) or 3
                aeMezMinTargets, changed = imgui.SliderInt('AE Min Targets', aeMezMinTargets, 2, 8)
                if changed and onChange then onChange('AEMezMinTargets', aeMezMinTargets) end
                if imgui.IsItemHovered() then
                    safeTooltip('Minimum targets in range to use AE mez.')
                end
            end

            imgui.Unindent()
        end

        imgui.Spacing()
        imgui.Separator()
    end

    imgui.TextColored(0.6, 0.8, 1.0, 1.0, 'Heals (Tiered)')

    local doHeals = settings.DoHeals == true
    doHeals, changed = imgui.Checkbox('Enable Heals', doHeals)
    if changed and onChange then onChange('DoHeals', doHeals) end
    if imgui.IsItemHovered() then
        safeTooltip('Enable tiered healing logic (Main/Big/Group/Pet). Paladins are excluded.')
    end

    if doHeals then
        imgui.Indent()

        local priorityHealing = settings.PriorityHealing == true
        priorityHealing, changed = imgui.Checkbox('Priority Healing', priorityHealing)
        if changed and onChange then onChange('PriorityHealing', priorityHealing) end

        local breakInvis = settings.HealBreakInvisOOC == true
        breakInvis, changed = imgui.Checkbox('Break Invis OOC To Heal', breakInvis)
        if changed and onChange then onChange('HealBreakInvisOOC', breakInvis) end

        local mainPoint = tonumber(settings.MainHealPoint) or 80
        mainPoint, changed = imgui.SliderInt('Main Heal Point (HP %)', mainPoint, 1, 100)
        if changed and onChange then onChange('MainHealPoint', mainPoint) end

        local bigPoint = tonumber(settings.BigHealPoint) or 50
        bigPoint, changed = imgui.SliderInt('Big Heal Point (HP %)', bigPoint, 1, 100)
        if changed and onChange then onChange('BigHealPoint', bigPoint) end

        local groupPoint = tonumber(settings.GroupHealPoint) or 75
        groupPoint, changed = imgui.SliderInt('Group Heal Point (HP %)', groupPoint, 1, 100)
        if changed and onChange then onChange('GroupHealPoint', groupPoint) end

        local injCnt = tonumber(settings.GroupInjureCnt) or 2
        injCnt, changed = imgui.SliderInt('Group Injured Count', injCnt, 1, 6)
        if changed and onChange then onChange('GroupInjureCnt', injCnt) end

        imgui.Spacing()

        local doPetHeals = settings.DoPetHeals == true
        doPetHeals, changed = imgui.Checkbox('Enable Pet Heals', doPetHeals)
        if changed and onChange then onChange('DoPetHeals', doPetHeals) end

        local petPoint = tonumber(settings.PetHealPoint) or 50
        petPoint, changed = imgui.SliderInt('Pet Heal Point (HP %)', petPoint, 1, 100)
        if changed and onChange then onChange('PetHealPoint', petPoint) end

        imgui.Spacing()

        local watchMA = settings.HealWatchMA == true
        watchMA, changed = imgui.Checkbox('Watch Main Assist (OOG OK)', watchMA)
        if changed and onChange then onChange('HealWatchMA', watchMA) end

        local xtHeal = settings.HealXTargetEnabled == true
        xtHeal, changed = imgui.Checkbox('Heal XTarget Slots', xtHeal)
        if changed and onChange then onChange('HealXTargetEnabled', xtHeal) end

        local xtSlots = tostring(settings.HealXTargetSlots or '')
        xtSlots, changed = imgui.InputText('XTarget Slots (e.g. 1|2|3)', xtSlots, 64)
        if changed and onChange then onChange('HealXTargetSlots', xtSlots) end

        imgui.Spacing()

        local useHoTs = settings.HealUseHoTs ~= false
        useHoTs, changed = imgui.Checkbox('Use HoTs (when available)', useHoTs)
        if changed and onChange then onChange('HealUseHoTs', useHoTs) end

        local hotWin = tonumber(settings.HealHoTMinSeconds) or 6
        hotWin, changed = imgui.SliderInt('HoT Refresh Window (sec)', hotWin, 0, 30)
        if changed and onChange then onChange('HealHoTMinSeconds', hotWin) end

        imgui.Spacing()

        local coordActors = settings.HealCoordinateActors ~= false
        coordActors, changed = imgui.Checkbox('Coordinate Heals via Actors', coordActors)
        if changed and onChange then onChange('HealCoordinateActors', coordActors) end

        local trackHots = settings.HealTrackHoTsViaActors ~= false
        trackHots, changed = imgui.Checkbox('Track HoTs via Actors', trackHots)
        if changed and onChange then onChange('HealTrackHoTsViaActors', trackHots) end

        imgui.Spacing()
        imgui.TextColored(0.8, 0.8, 0.8, 1.0, 'Emergency & Rez')

        local emergencyPct = tonumber(settings.EmergencyHealPct) or 25
        emergencyPct, changed = imgui.SliderInt('Emergency Heal Pct', emergencyPct, 1, 50)
        if changed and onChange then onChange('EmergencyHealPct', emergencyPct) end
        if imgui.IsItemHovered() then
            safeTooltip('HP threshold for emergency abilities (panic heals, defensive cooldowns).')
        end

        local doCombatRez = settings.DoCombatRez == true
        doCombatRez, changed = imgui.Checkbox('Combat Rez Enabled', doCombatRez)
        if changed and onChange then onChange('DoCombatRez', doCombatRez) end
        if imgui.IsItemHovered() then
            safeTooltip('Allow rezzing during combat (if you have combat rez capability).')
        end

        local doOocRez = settings.DoOutOfCombatRez ~= false
        doOocRez, changed = imgui.Checkbox('Out of Combat Rez Enabled', doOocRez)
        if changed and onChange then onChange('DoOutOfCombatRez', doOocRez) end
        if imgui.IsItemHovered() then
            safeTooltip('Allow rezzing out of combat.')
        end

        imgui.Unindent()
    end

    imgui.Spacing()
    imgui.TextColored(0.6, 0.8, 1.0, 1.0, 'Class Specific')

    -- FD Classes: Auto stand from Feign Death
    local fdClasses = { MNK = true, NEC = true, SHD = true }
    local meClass = mq.TLO.Me and mq.TLO.Me.Class and mq.TLO.Me.Class.ShortName and mq.TLO.Me.Class.ShortName() or ''
    if fdClasses[tostring(meClass):upper()] then
        local autoStandFD = settings.AutoStandFD == true
        autoStandFD, changed = imgui.Checkbox('Auto Stand from FD', autoStandFD)
        if changed and onChange then onChange('AutoStandFD', autoStandFD) end
        if imgui.IsItemHovered() then
            safeTooltip('Automatically stand from Feign Death when safe (no aggro on you).')
        end
    end
end

local function drawIntegration(settings, onChange)
    local actors = settings.ActorsEnabled ~= false
    local changed
    actors, changed = imgui.Checkbox('Enable Actors (GroupTarget integration)', actors)
    if changed and onChange then onChange('ActorsEnabled', actors) end

    imgui.Spacing()
    imgui.Separator()
    imgui.Spacing()

    -- Autostart Configuration
    imgui.TextColored(0.7, 0.7, 0.7, 1.0, 'Autostart:')
    imgui.Spacing()

    do
        local server = mq.TLO.EverQuest.Server():gsub(" ", "_") or 'Unknown'
        local charName = mq.TLO.Me.CleanName() or 'Unknown'
        local autostartPath = string.format('%s/%s_%s.cfg', mq.configDir, server, charName)

        -- Read current autostart file contents
        local currentContents = {}
        local fileHandle = io.open(autostartPath, 'r')
        if fileHandle then
            for line in fileHandle:lines() do
                currentContents[#currentContents + 1] = line
            end
            fileHandle:close()
        end

        -- Check if sidekick is in autostart
        local hasSidekickAutostart = false
        for _, line in ipairs(currentContents) do
            if line:lower():find('/lua run sidekick', 1, true) then
                hasSidekickAutostart = true
                break
            end
        end

        -- Checkbox to toggle autostart
        local newAutostart = imgui.Checkbox('Autostart SideKick on login##SidekickAutostart', hasSidekickAutostart)
        if newAutostart ~= hasSidekickAutostart then
            -- Build new config contents
            local newLines = {}

            -- Keep existing lines except /lua run sidekick
            for _, line in ipairs(currentContents) do
                if not line:lower():find('/lua run sidekick', 1, true) then
                    newLines[#newLines + 1] = line
                end
            end

            -- Add the command if enabling
            if newAutostart then
                newLines[#newLines + 1] = '/lua run sidekick'
            end

            -- Write the file
            local outFile = io.open(autostartPath, 'w')
            if outFile then
                for _, line in ipairs(newLines) do
                    outFile:write(line .. '\n')
                end
                outFile:close()
                if newAutostart then
                    mq.cmd('/echo \\ag[SideKick]\\aw Added to autostart: ' .. autostartPath)
                else
                    mq.cmd('/echo \\ag[SideKick]\\aw Removed from autostart: ' .. autostartPath)
                end
            else
                mq.cmd('/echo \\ar[SideKick]\\aw Failed to write autostart config')
            end
        end
        if imgui.IsItemHovered() then
            safeTooltip('Adds /lua run sidekick to ' .. server .. '_' .. charName .. '.cfg')
        end
    end
end

local function drawAnimations(settings, onChange)
    local changed

    imgui.Text('Animation Settings')
    imgui.Separator()

    -- Master animation toggle
    local animEnabled = settings.AnimationsEnabled ~= false
    animEnabled, changed = imgui.Checkbox('Enable Animations', animEnabled)
    if changed and onChange then onChange('AnimationsEnabled', animEnabled) end
    if imgui.IsItemHovered() then
        safeTooltip('Master toggle for all UI animations (springs, pulses, glows)')
    end

    if not animEnabled then
        imgui.TextDisabled('Animations are disabled')
        return
    end

    imgui.Spacing()
    imgui.Text('Ability Bar Animations')
    imgui.Indent()

    local readyPulse = settings.ReadyPulseEnabled ~= false
    readyPulse, changed = imgui.Checkbox('Ready Pulse', readyPulse)
    if changed and onChange then onChange('ReadyPulseEnabled', readyPulse) end
    if imgui.IsItemHovered() then
        safeTooltip('Pulsing glow on abilities that are ready to use')
    end

    local cooldownSweep = settings.CooldownSweepEnabled ~= false
    cooldownSweep, changed = imgui.Checkbox('Cooldown Overlay', cooldownSweep)
    if changed and onChange then onChange('CooldownSweepEnabled', cooldownSweep) end
    if imgui.IsItemHovered() then
        safeTooltip('Color-coded cooldown overlay that fills from bottom')
    end

    local hoverScale = settings.HoverScaleEnabled ~= false
    hoverScale, changed = imgui.Checkbox('Hover Scale', hoverScale)
    if changed and onChange then onChange('HoverScaleEnabled', hoverScale) end
    if imgui.IsItemHovered() then
        safeTooltip('Buttons scale up slightly when hovered')
    end

    local clickBounce = settings.ClickBounceEnabled ~= false
    clickBounce, changed = imgui.Checkbox('Click Bounce', clickBounce)
    if changed and onChange then onChange('ClickBounceEnabled', clickBounce) end
    if imgui.IsItemHovered() then
        safeTooltip('Spring animation when clicking abilities')
    end

    imgui.Unindent()

    imgui.Spacing()
    imgui.Text('Resource Warnings')
    imgui.Indent()

    local lowResWarning = settings.LowResourceWarningEnabled ~= false
    lowResWarning, changed = imgui.Checkbox('Low Resource Warning', lowResWarning)
    if changed and onChange then onChange('LowResourceWarningEnabled', lowResWarning) end
    if imgui.IsItemHovered() then
        safeTooltip('Pulsing red warning when HP/Mana/End is low')
    end

    local threshold = tonumber(settings.LowResourceThreshold) or 20
    threshold, changed = imgui.SliderInt('Warning Threshold %', threshold, 5, 50)
    if changed and onChange then onChange('LowResourceThreshold', threshold) end
    if imgui.IsItemHovered() then
        safeTooltip('Show warning when resource drops below this percentage')
    end

    local damageFlash = settings.DamageFlashEnabled ~= false
    damageFlash, changed = imgui.Checkbox('Damage Flash', damageFlash)
    if changed and onChange then onChange('DamageFlashEnabled', damageFlash) end
    if imgui.IsItemHovered() then
        safeTooltip('Brief red flash when taking significant damage (>5% HP drop)')
    end

    imgui.Unindent()

    imgui.Spacing()
    imgui.Text('Toggle Buttons')
    imgui.Indent()

    local togglePop = settings.TogglePopEnabled ~= false
    togglePop, changed = imgui.Checkbox('Activation Pop', togglePop)
    if changed and onChange then onChange('TogglePopEnabled', togglePop) end
    if imgui.IsItemHovered() then
        safeTooltip('Pop animation when toggling Assist/Chase/Burn on')
    end

    local toggleColorTween = settings.ToggleColorTweenEnabled ~= false
    toggleColorTween, changed = imgui.Checkbox('Color Transition', toggleColorTween)
    if changed and onChange then onChange('ToggleColorTweenEnabled', toggleColorTween) end
    if imgui.IsItemHovered() then
        safeTooltip('Smooth color transition between on/off states')
    end

    imgui.Unindent()
end

local function drawItems(settings, onChange)
    local changed

    local enabled = settings.SideKickItemBarEnabled ~= false
    enabled, changed = imgui.Checkbox('Show item bar', enabled)
    if changed and onChange then onChange('SideKickItemBarEnabled', enabled) end

    local cell = tonumber(settings.SideKickItemBarCell) or 40
    local rows = tonumber(settings.SideKickItemBarRows) or 1
    local gap = tonumber(settings.SideKickItemBarGap) or 4
    local alpha = tonumber(settings.SideKickItemBarBgAlpha) or 0.85
    local pad = tonumber(settings.SideKickItemBarPad) or 6
    local anchorGap = tonumber(settings.SideKickItemBarAnchorGap) or 2

    cell, changed = imgui.SliderInt('Cell Size', cell, 32, 120)
    if changed and onChange then onChange('SideKickItemBarCell', cell) end

    rows, changed = imgui.SliderInt('Rows', rows, 1, 6)
    if changed and onChange then onChange('SideKickItemBarRows', rows) end

    gap, changed = imgui.SliderInt('Gap', gap, 0, 12)
    if changed and onChange then onChange('SideKickItemBarGap', gap) end

    pad, changed = imgui.SliderInt('Padding', pad, 0, 24)
    if changed and onChange then onChange('SideKickItemBarPad', pad) end

    alpha, changed = imgui.SliderFloat('Background Alpha', alpha, 0.2, 1.0)
    if changed and onChange then onChange('SideKickItemBarBgAlpha', alpha) end

    local anchors = { 'none', 'left', 'right', 'above', 'below', 'left_bottom', 'right_bottom' }
    local target = comboKeyed('Anchor To', settings.SideKickItemBarAnchorTarget or 'grouptarget', ANCHOR_TARGETS)
    if target ~= tostring(settings.SideKickItemBarAnchorTarget or 'grouptarget') and onChange then
        onChange('SideKickItemBarAnchorTarget', target)
    end
    local anchor = tostring(settings.SideKickItemBarAnchor or 'none')
    anchor = comboString('Anchor Mode', anchor, anchors)
    if anchor ~= tostring(settings.SideKickItemBarAnchor or 'none') and onChange then
        onChange('SideKickItemBarAnchor', anchor)
    end

    anchorGap, changed = imgui.SliderInt('Anchor Gap', anchorGap, 0, 24)
    if changed and onChange then onChange('SideKickItemBarAnchorGap', anchorGap) end

    imgui.Separator()
    imgui.Text('Item Slots')
    imgui.TextWrapped('Drag an item onto a slot (or pick it up and click the slot icon) to assign it. Hover the bar icons for clicky details.')

    local slots = Items.getSlots()
    local iconSize = 32
    local animItems = mq.FindTextureAnimation and mq.FindTextureAnimation('A_DragItem') or nil
    local configured = Items.collectConfigured() or {}
    local configuredByIndex = {}
    for _, e in ipairs(configured) do
        if e and e.slot then
            configuredByIndex[tonumber(e.slot) or 0] = e
        end
    end

    local function iconCellFromIconId(iconId)
        local iconIdx = tonumber(iconId) or 0
        local cell0 = (iconIdx > 0) and (iconIdx - 500) or 0
        if cell0 < 0 then cell0 = 0 end
        return cell0
    end

    local function drawAnimIcon(iconId, size)
        if not (animItems and imgui.DrawTextureAnimation) then return false end
        local okCell = pcall(function() animItems:SetTextureCell(iconCellFromIconId(iconId)) end)
        if not okCell then return false end
        local okDraw = pcall(imgui.DrawTextureAnimation, animItems, size, size)
        return okDraw == true
    end

    local function isMouseReleasedLeft()
        if not imgui.IsMouseReleased then return false end
        local ok, v = pcall(imgui.IsMouseReleased, 0)
        if ok and v == true then return true end
        local mb = rawget(_G, 'ImGuiMouseButton')
        if mb and mb.Left ~= nil then
            ok, v = pcall(imgui.IsMouseReleased, mb.Left)
            if ok and v == true then return true end
        end
        return false
    end

    local modes = {
        { key = 'on_demand', label = 'On Demand' },
        { key = 'combat', label = 'Combat (Auto)' },
        { key = 'ooc', label = 'Out of Combat (Auto)' },
        { key = 'on_condition', label = 'On Condition' },
    }

    for _, slot in ipairs(slots) do
        imgui.PushID(slot.key)
        local label = string.format('Slot %d', slot.index)
        imgui.AlignTextToFramePadding()
        imgui.Text(label)
        imgui.SameLine()

        local entry = configuredByIndex[tonumber(slot.index) or 0]
        local slotIcon = entry and entry.info and tonumber(entry.info.icon) or 0
        local cursorName = ''
        local cursorIcon = 0
        if mq and mq.TLO and mq.TLO.Cursor and mq.TLO.Cursor() then
            cursorName = mq.TLO.Cursor.Name() or ''
            cursorIcon = tonumber((mq.TLO.Cursor.Icon and mq.TLO.Cursor.Icon()) or 0) or 0
        end

        -- Slot icon button acts as a drag/drop target.
        if imgui.Button('##slot_icon', iconSize, iconSize) then
            if cursorName ~= '' then
                Items.setSlot(slot.index, cursorName)
                if mq.cmd then mq.cmd('/autoinv') end
            end
        end

        local hovered = imgui.IsItemHovered()
        if hovered and cursorName ~= '' and isMouseReleasedLeft() then
            Items.setSlot(slot.index, cursorName)
            if mq.cmd then mq.cmd('/autoinv') end
        end

        -- Draw the icon on top of the button (preview cursor icon while hovering).
        do
            local pos = imgui.GetItemRectMin and imgui.GetItemRectMin() or nil
            local x, y
            if type(pos) == 'table' then
                x = pos.x or pos[1]
                y = pos.y or pos[2]
            elseif type(pos) == 'number' then
                x = pos
                y = select(2, imgui.GetItemRectMin())
            end
            if x and y then
                imgui.SetCursorScreenPos(x, y)
                local showIcon = (hovered and cursorIcon and cursorIcon > 0) and cursorIcon or slotIcon
                if showIcon and showIcon > 0 then
                    drawAnimIcon(showIcon, iconSize)
                end
                imgui.SetCursorScreenPos(x, y)
            end
        end

        if hovered then
            if cursorName ~= '' then
                safeTooltip('Drop: ' .. tostring(cursorName))
            else
                safeTooltip('Click or drop an item here')
            end
        end

        imgui.SameLine()
        if imgui.SmallButton('Clear') then
            Items.clearSlot(slot.index)
        end

        if slot.name ~= '' then
            imgui.SameLine()
            imgui.Text(slot.name)
        else
            imgui.SameLine()
            imgui.TextDisabled('(empty)')
        end

        -- Per-slot activation mode
        imgui.SameLine()
        imgui.SetNextItemWidth(160)
        local curMode = tostring(slot.mode or 'on_demand')
        local function modeLabel(k)
            for _, m in ipairs(modes) do
                if m.key == k then return m.label end
            end
            return tostring(k)
        end
        local preview = modeLabel(curMode)
        local picked = curMode
        if imgui.BeginCombo('##mode', preview) then
            local doFocus = false
            if imgui.IsWindowAppearing then
                local ok, v = pcall(imgui.IsWindowAppearing)
                doFocus = ok and v == true
            end
            for _, m in ipairs(modes) do
                local selected = (m.key == curMode)
                if imgui.Selectable(m.label, selected) then
                    picked = m.key
                end
                if doFocus and selected then imgui.SetItemDefaultFocus() end
            end
            imgui.EndCombo()
        end
        if picked ~= curMode then
            Items.setSlotMode(slot.index, picked)
            curMode = picked
        end
        if imgui.IsItemHovered() then
            safeTooltip('Choose how this item activates.')
        end

        if curMode == 'combat' then
            imgui.SameLine()
            imgui.SetNextItemWidth(140)
            local hpGate = tonumber(slot.combatHpPct) or 0
            local newHp = hpGate
            newHp, changed = imgui.SliderInt('HP% <=##hpGate', newHp, 0, 100)
            if changed then
                Items.setSlotCombatHpPct(slot.index, newHp)
            end
            if imgui.IsItemHovered() then
                safeTooltip('Only auto-use in combat when current HP% is at or below this value. 0 disables the HP gate.')
            end
        end

        -- Show condition builder when mode is On Condition
        if curMode == 'on_condition' then
            local condKey = string.format('ItemSlot%dCondition', slot.index)
            local condData = Core.Settings[condKey]
            if not condData and Core.Ini and Core.Ini['SideKick-Items'] then
                local serialized = Core.Ini['SideKick-Items'][condKey]
                if serialized and ConditionBuilder.deserialize then
                    condData = ConditionBuilder.deserialize(serialized)
                end
            end

            imgui.Indent(20)
            ConditionBuilder.drawInline(condKey, condData, function(newData)
                Core.Settings[condKey] = newData
                if Core.Ini and ConditionBuilder.serialize then
                    Core.Ini['SideKick-Items'] = Core.Ini['SideKick-Items'] or {}
                    Core.Ini['SideKick-Items'][condKey] = ConditionBuilder.serialize(newData)
                end
                if Core.save then Core.save() end
            end)
            imgui.Unindent(20)
        end

        imgui.PopID()
    end
end

local function drawClass(settings, onChange)
    local ClassSettings = getClassSettings()
    if not ClassSettings then
        imgui.TextColored(0.6, 0.6, 0.6, 1, "Class settings module not loaded")
        return
    end

    -- Render loadout selector first
    ClassSettings.renderLoadoutSelector(settings, onChange)
    imgui.Spacing()
    imgui.Separator()
    imgui.Spacing()

    -- Render class-specific settings
    ClassSettings.render(settings, onChange)
end

local function drawBuffs(settings, onChange)
    local changed

    -- ========== BUFFING ENABLED ==========
    imgui.TextColored(0.7, 0.9, 1.0, 1.0, 'Buffing')
    imgui.Separator()

    local buffEnabled = settings.BuffingEnabled ~= false
    buffEnabled, changed = imgui.Checkbox('Enable Buffing', buffEnabled)
    if changed and onChange then onChange('BuffingEnabled', buffEnabled) end
    if imgui.IsItemHovered() then
        safeTooltip('Enable automatic buff casting for group members.')
    end

    if not buffEnabled then
        imgui.TextDisabled('Buffing is disabled')
        return
    end

    imgui.Spacing()

    -- ========== BUFF TARGETS ==========
    imgui.TextColored(0.8, 0.8, 0.8, 1.0, 'Buff Targets')

    local buffSelf = settings.BuffSelfOnly == true
    buffSelf, changed = imgui.Checkbox('Self Only', buffSelf)
    if changed and onChange then onChange('BuffSelfOnly', buffSelf) end
    if imgui.IsItemHovered() then
        safeTooltip('Only buff yourself, ignore group members.')
    end

    if not buffSelf then
        local buffGroup = settings.BuffGroupEnabled ~= false
        buffGroup, changed = imgui.Checkbox('Buff Group Members', buffGroup)
        if changed and onChange then onChange('BuffGroupEnabled', buffGroup) end

        local buffPets = settings.BuffPetsEnabled ~= false
        buffPets, changed = imgui.Checkbox('Buff Pets', buffPets)
        if changed and onChange then onChange('BuffPetsEnabled', buffPets) end

        local buffRaid = settings.BuffRaidEnabled == true
        buffRaid, changed = imgui.Checkbox('Buff Raid Members (OOG)', buffRaid)
        if changed and onChange then onChange('BuffRaidEnabled', buffRaid) end
        if imgui.IsItemHovered() then
            safeTooltip('Buff raid members outside your group.')
        end

        local buffFellowship = settings.BuffFellowshipEnabled == true
        buffFellowship, changed = imgui.Checkbox('Buff Fellowship Members', buffFellowship)
        if changed and onChange then onChange('BuffFellowshipEnabled', buffFellowship) end
    end

    imgui.Spacing()
    imgui.Separator()
    imgui.Spacing()

    -- ========== BUFF TIMING ==========
    imgui.TextColored(0.8, 0.8, 0.8, 1.0, 'Timing')

    local rebuffWindow = tonumber(settings.BuffRebuffWindow) or 60
    rebuffWindow, changed = imgui.SliderInt('Rebuff Window (sec)', rebuffWindow, 15, 300)
    if changed and onChange then onChange('BuffRebuffWindow', rebuffWindow) end
    if imgui.IsItemHovered() then
        safeTooltip('Start rebuffing when buff has this many seconds remaining.')
    end

    local allowCombat = settings.BuffAllowInCombat == true
    allowCombat, changed = imgui.Checkbox('Allow Buffing In Combat', allowCombat)
    if changed and onChange then onChange('BuffAllowInCombat', allowCombat) end
    if imgui.IsItemHovered() then
        safeTooltip('Allow casting buffs during combat (individual buff settings may override).')
    end

    imgui.Spacing()
    imgui.Separator()
    imgui.Spacing()

    -- ========== COORDINATION ==========
    imgui.TextColored(0.8, 0.8, 0.8, 1.0, 'Coordination')

    local coordActors = settings.BuffCoordinateActors ~= false
    coordActors, changed = imgui.Checkbox('Coordinate via Actors', coordActors)
    if changed and onChange then onChange('BuffCoordinateActors', coordActors) end
    if imgui.IsItemHovered() then
        safeTooltip('Use actors to coordinate with other SideKick instances to prevent duplicate buffs.')
    end

    imgui.Spacing()
    imgui.Separator()
    imgui.Spacing()

    -- ========== AURA SELECTION ==========
    -- Only show for aura classes
    local auraClasses = { BRD = true, ENC = true, PAL = true, RNG = true, SHD = true, NEC = true }
    local meClass = mq.TLO.Me and mq.TLO.Me.Class and mq.TLO.Me.Class.ShortName and mq.TLO.Me.Class.ShortName() or ''
    if auraClasses[tostring(meClass):upper()] then
        imgui.TextColored(0.8, 0.8, 0.8, 1.0, 'Aura')

        imgui.SetNextItemWidth(200)
        local auraSelection = tostring(settings.AuraSelection or '')
        auraSelection, changed = imgui.InputText('Aura Selection', auraSelection, 128)
        if changed and onChange then onChange('AuraSelection', auraSelection) end
        if imgui.IsItemHovered() then
            safeTooltip('Name of the aura to maintain. Leave blank to disable aura management.')
        end
    end

    imgui.Spacing()
    imgui.Separator()
    imgui.Spacing()

    -- ========== BUFF BLOCKING ==========
    imgui.TextColored(0.7, 0.9, 1.0, 1.0, 'Buff Blocking')
    imgui.Separator()
    imgui.TextWrapped('Block specific buff types from being cast on you by other SideKick instances.')
    imgui.Spacing()

    -- Get buff definitions from Buff module
    local ok, Buff = pcall(require, 'automation.buff')
    if ok and Buff and Buff.getBuffDefinitions then
        local defs = Buff.getBuffDefinitions()
        if defs and next(defs) then
            for category, def in pairs(defs) do
                local blockKey = 'BuffBlock_' .. category
                local blocked = settings[blockKey] == true
                local label = def.category or category
                blocked, changed = imgui.Checkbox('Block: ' .. label, blocked)
                if changed and onChange then onChange(blockKey, blocked) end
            end
        else
            imgui.TextDisabled('No buff definitions loaded for this class.')
        end
    else
        imgui.TextDisabled('Buff module not available.')
    end
end

local function drawRemote(settings, onChange)
    -- Get remote characters from ActorsCoordinator
    local remoteChars = {}
    if ActorsCoordinator.getRemoteCharacters then
        remoteChars = ActorsCoordinator.getRemoteCharacters() or {}
    end

    if not next(remoteChars) then
        imgui.Spacing()
        imgui.TextColored(1.0, 0.8, 0.3, 1.0, 'No remote SideKick instances detected.')
        imgui.TextWrapped('Make sure SideKick is running on other characters and Actors integration is enabled.')
        imgui.Spacing()
        return
    end

    imgui.Text('Select abilities to show on the Remote Bar:')
    imgui.Spacing()

    -- Get the shared state from RemoteAbilities module
    local selectedAbilities = RemoteAbilities.getSelectedAbilities()

    for charName, data in pairs(remoteChars) do
        local headerLabel = charName
        if data.class and data.class ~= '' then
            headerLabel = charName .. ' (' .. data.class .. ')'
        end

        if imgui.CollapsingHeader(headerLabel) then
            selectedAbilities[charName] = selectedAbilities[charName] or {}

            if data.abilities and next(data.abilities) then
                -- Sort abilities alphabetically
                local sortedAbilities = {}
                for abilityName, ability in pairs(data.abilities) do
                    table.insert(sortedAbilities, { name = abilityName, data = ability })
                end
                table.sort(sortedAbilities, function(a, b) return a.name < b.name end)

                imgui.Indent()
                for _, item in ipairs(sortedAbilities) do
                    local abilityName = item.name
                    local ability = item.data
                    local enabled = selectedAbilities[charName][abilityName] == true
                    local displayName = ability.shortName or abilityName

                    local wasChanged
                    enabled, wasChanged = imgui.Checkbox(displayName .. '##remote_' .. charName .. '_' .. abilityName, enabled)
                    if wasChanged then
                        -- Use RemoteAbilities function to set and save immediately
                        RemoteAbilities.setAbilitySelected(charName, abilityName, enabled)
                        -- Auto-open the bar if we just selected something
                        RemoteAbilities.autoOpen()
                    end

                    if imgui.IsItemHovered() then
                        safeTooltip(abilityName)
                    end
                end
                imgui.Unindent()
            else
                imgui.Indent()
                imgui.TextDisabled('No abilities detected')
                imgui.Unindent()
            end
        end
    end
end

function M.draw(ctx)
    ctx = ctx or {}
    local settings = ctx.settings or {}
    local themeNames = ctx.themeNames or {}
    local onChange = ctx.onChange

    local function withTabScrollChild(childId, fn)
        if not (imgui and imgui.BeginChild and imgui.EndChild) then
            fn()
            return
        end
        local started = imgui.BeginChild(childId)
        if started then
            fn()
        end
        imgui.EndChild()
    end

    if imgui.BeginTabBar('##sk_settings_tabs') then
        if imgui.BeginTabItem('UI') then
            withTabScrollChild('##sk_settings_ui_scroll', function()
                drawUI(settings, themeNames, onChange)
            end)
            imgui.EndTabItem()
        end
        if imgui.BeginTabItem('Bar') then
            withTabScrollChild('##sk_settings_bar_scroll', function()
                drawBar(settings, onChange)
            end)
            imgui.EndTabItem()
        end
        if imgui.BeginTabItem('Special') then
            withTabScrollChild('##sk_settings_special_scroll', function()
                drawSpecial(settings, onChange)
            end)
            imgui.EndTabItem()
        end
        if imgui.BeginTabItem('Disciplines') then
            withTabScrollChild('##sk_settings_disc_scroll', function()
                drawDisciplines(settings, onChange)
            end)
            imgui.EndTabItem()
        end
        if imgui.BeginTabItem('Items') then
            withTabScrollChild('##sk_settings_items_scroll', function()
                drawItems(settings, onChange)
            end)
            imgui.EndTabItem()
        end
        if imgui.BeginTabItem('Automation') then
            withTabScrollChild('##sk_settings_automation_scroll', function()
                drawAutomation(settings, onChange)
            end)
            imgui.EndTabItem()
        end
        if imgui.BeginTabItem('Buffs') then
            withTabScrollChild('##sk_settings_buffs_scroll', function()
                drawBuffs(settings, onChange)
            end)
            imgui.EndTabItem()
        end
        if imgui.BeginTabItem('Class') then
            withTabScrollChild('##sk_settings_class_scroll', function()
                drawClass(settings, onChange)
            end)
            imgui.EndTabItem()
        end
        if imgui.BeginTabItem('Integration') then
            withTabScrollChild('##sk_settings_integration_scroll', function()
                drawIntegration(settings, onChange)
            end)
            imgui.EndTabItem()
        end
        if imgui.BeginTabItem('Remote') then
            withTabScrollChild('##sk_settings_remote_scroll', function()
                drawRemote(settings, onChange)
            end)
            imgui.EndTabItem()
        end
        if imgui.BeginTabItem('Animations') then
            withTabScrollChild('##sk_settings_animations_scroll', function()
                drawAnimations(settings, onChange)
            end)
            imgui.EndTabItem()
        end
        imgui.EndTabBar()
    end
end

return M
