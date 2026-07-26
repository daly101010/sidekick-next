-- ============================================================
-- SideKick Settings - Healing Tab
-- ============================================================
-- Healing configuration for healer classes (CLR, DRU, SHM, PAL).

local imgui = require('ImGui')
local mq = require('mq')
local Settings = require('sidekick-next.ui.settings.init')
local Components = require('sidekick-next.ui.components')
local HealerClasses = require('sidekick-next.utils.healer_classes')
local RezData = require('sidekick-next.utils.rez_data')

local M = {}

-- Lazy-loaded healing modules
local _healingMod = nil
local _healingSettingsUI = nil
local _healingModChecked = false
local _healingLoadError = nil
local _settingsSynced = false

local REZ_CLASSES = {
    'WAR', 'CLR', 'PAL', 'RNG', 'SHD', 'DRU', 'MNK', 'BRD',
    'ROG', 'SHM', 'NEC', 'WIZ', 'MAG', 'ENC', 'BST', 'BER',
}

local function parseRezClasses(raw)
    raw = tostring(raw or 'ALL'):upper()
    local selected = {}
    if raw == 'ALL' or raw == '*' or raw == '' then
        for _, code in ipairs(REZ_CLASSES) do selected[code] = true end
        return selected
    end
    for code in raw:gmatch('[A-Z]+') do selected[code] = true end
    return selected
end

local function serializeRezClasses(selected)
    local values = {}
    for _, code in ipairs(REZ_CLASSES) do
        if selected[code] then values[#values + 1] = code end
    end
    if #values == #REZ_CLASSES then return 'ALL' end
    return table.concat(values, '|')
end

local function drawResurrection(settings, themeName, onChange)
    imgui.Spacing()
    Components.SettingGroup.section('Resurrection', themeName)

    local autoRezOOC = settings.AutoRezOOC ~= false
    local oocVal, oocChanged = Components.CheckboxRow.draw('Auto-Rez Out of Combat', 'AutoRezOOC', autoRezOOC, nil, {
        tooltip = 'Automatically rez dead group members and fresh same-zone Actor Team peers after combat.',
    })
    if oocChanged and onChange then onChange('AutoRezOOC', oocVal) end
    local oocMethod = Settings.labeledCombo('OOC Method##RezOOCMethod', settings.RezOOCMethod or 'Auto',
        { 'Auto', 'Spell', 'Item' },
        'Auto tries the configured item first, then the best learned rez spell.')
    if oocMethod ~= settings.RezOOCMethod and onChange then onChange('RezOOCMethod', oocMethod) end

    local autoRezCombat = settings.AutoRezInCombat == true
    local combatVal, combatChanged = Components.CheckboxRow.draw('Auto-Rez In Combat', 'AutoRezInCombat', autoRezCombat, nil, {
        tooltip = 'Allow rez actions during combat. The class filter below controls eligible recipients.',
    })
    if combatChanged and onChange then onChange('AutoRezInCombat', combatVal) end
    local combatMethod = Settings.labeledCombo('Combat Method##RezCombatMethod', settings.RezCombatMethod or 'Auto',
        { 'Auto', 'AA', 'Spell', 'Item' },
        'Auto tries the configured item, then a battle-rez AA, then an already-memorized spell. Combat never auto-memorizes.')
    if combatMethod ~= settings.RezCombatMethod and onChange then onChange('RezCombatMethod', combatMethod) end

    local autoAcceptRez = settings.AutoAcceptRez ~= false
    local acceptVal, acceptChanged = Components.CheckboxRow.draw('Auto-Accept Rez Offers', 'AutoAcceptRez', autoAcceptRez, nil, {
        tooltip = 'Automatically click Yes only when the confirmation dialog is identified as a resurrection offer.',
    })
    if acceptChanged and onChange then onChange('AutoAcceptRez', acceptVal) end

    Components.SettingGroup.draw('Resources', function()
        local itemName = Settings.labeledInputText('Rez Item Name##RezItemName', settings.RezItemName or '',
            'Exact inventory item name. Auto mode prefers this item when it exists and is ready.')
        if itemName ~= (settings.RezItemName or '') and onChange then onChange('RezItemName', itemName) end

        local autoMem = settings.RezAutoMemorize ~= false
        local memVal, memChanged = Components.CheckboxRow.draw('Auto-Memorize OOC Rez Spell', 'RezAutoMemorize', autoMem, nil, {
            tooltip = 'Temporarily use the selected gem when the best learned rez spell is not memorized. Never memorizes during combat.',
        })
        if memChanged and onChange then onChange('RezAutoMemorize', memVal) end

        if memVal then
            local gem = tonumber(settings.RezGem) or 0
            local gemChanged, newGem = Components.SliderRow.int('Temporary Gem (0 = Last)', 'RezGem', gem, 0, 13, nil, {
                tooltip = 'Gem used for temporary rez memorization. Zero selects the character\'s final gem.',
            })
            if gemChanged and onChange then onChange('RezGem', newGem) end

            local restore = settings.RezRestoreGem ~= false
            local restoreVal, restoreChanged = Components.CheckboxRow.draw('Restore Replaced Gem', 'RezRestoreGem', restore, nil, {
                tooltip = 'Restore the prior gem after the rez attempt. Crash recovery also restores an interrupted swap.',
            })
            if restoreChanged and onChange then onChange('RezRestoreGem', restoreVal) end
        end
    end, { id = 'rez_resources', defaultOpen = true })

    Components.SettingGroup.draw('Combat Target Classes', function()
        if not combatVal then
            imgui.TextDisabled('Preconfigure the class filter here; it is applied when combat rez is enabled.')
        else
            imgui.TextDisabled('Only checked classes are eligible for an in-combat rez.')
        end
        local selected = parseRezClasses(settings.RezCombatTargetClasses)

        if imgui.SmallButton('All Classes##rez_all_classes') and onChange then
            onChange('RezCombatTargetClasses', 'ALL')
        end
        imgui.SameLine()
        if imgui.SmallButton('Tanks + Healers##rez_critical_classes') and onChange then
            onChange('RezCombatTargetClasses', 'WAR|PAL|SHD|CLR|DRU|SHM')
        end

        for index, code in ipairs(REZ_CLASSES) do
            local value, changed = imgui.Checkbox(code .. '##rez_class_' .. code, selected[code] == true)
            if changed then
                selected[code] = value
                if onChange then onChange('RezCombatTargetClasses', serializeRezClasses(selected)) end
            end
            if index % 4 ~= 0 then imgui.SameLine() end
        end
    end, { id = 'rez_combat_classes', defaultOpen = true })

    Components.SettingGroup.draw('Coordination and Movement', function()
        local actorsEnabled = settings.RezCoordinateActors ~= false
        local actorsVal, actorsChanged = Components.CheckboxRow.draw('Coordinate via Actors', 'RezCoordinateActors', actorsEnabled, nil, {
            tooltip = 'Rez-capable characters exchange short-lived corpse intents; lowest priority number wins, with character name as the tie-breaker.',
        })
        if actorsChanged and onChange then onChange('RezCoordinateActors', actorsVal) end

        if actorsVal then
            local priority = tonumber(settings.RezPriority) or 50
            local priorityChanged, newPriority = Components.SliderRow.int('Rezzer Priority', 'RezPriority', priority, 0, 100, nil, {
                tooltip = 'Lower numbers win Actor coordination. Use this to prefer a primary rezzer.',
            })
            if priorityChanged and onChange then onChange('RezPriority', newPriority) end
        end

        local navigate = settings.RezNavigate == true
        local navVal, navChanged = Components.CheckboxRow.draw('Navigate to OOC Corpses', 'RezNavigate', navigate, nil, {
            tooltip = 'Use MQ2Nav to approach an out-of-range corpse. Navigation is never started during combat.',
        })
        if navChanged and onChange then onChange('RezNavigate', navVal) end
        if navVal then
            local maxDistance = tonumber(settings.RezNavMaxDistance) or 250
            local distanceChanged, newDistance = Components.SliderRow.int('Maximum Nav Distance', 'RezNavMaxDistance', maxDistance, 25, 1000, nil, {
                tooltip = 'Do not navigate to corpses farther away than this.',
            })
            if distanceChanged and onChange then onChange('RezNavMaxDistance', newDistance) end
        end

        local debug = settings.RezDebug == true
        local debugVal, debugChanged = Components.CheckboxRow.draw('Rez Debug Logging', 'RezDebug', debug, nil, {
            tooltip = 'Echo throttled selection and workflow transitions to the MacroQuest console.',
        })
        if debugChanged and onChange then onChange('RezDebug', debugVal) end
    end, { id = 'rez_coordination', defaultOpen = false })
end

-- Shared by the dedicated Options > Resurrection tab. Keeping the renderer in
-- one place prevents the two entry points from drifting or persisting settings
-- differently.
M.drawResurrection = drawResurrection

local function initHealingTab()
    if _healingModChecked then return end
    _healingModChecked = true

    -- The coordinated worker is the sole owner of the healing runtime. The UI
    -- only needs the persistent configuration; initializing the full healing
    -- module here would duplicate events, sensors, and heal-data writes.
    local ok, configOrErr = pcall(require, 'sidekick-next.healing.config')
    if not ok then
        _healingLoadError = tostring(configOrErr)
        return
    end

    local config = configOrErr
    if not config then
        _healingLoadError = 'Config module returned nil'
        return
    end

    if config.load then
        local initOk, initErr = pcall(config.load)
        if not initOk then
            _healingLoadError = 'Config load failed: ' .. tostring(initErr)
            return
        end
    end

    _healingMod = { Config = config }

    local ok2, uiOrErr = pcall(require, 'sidekick-next.healing.ui.settings')
    if ok2 and uiOrErr then
        _healingSettingsUI = uiOrErr
        if _healingSettingsUI.init then
            _healingSettingsUI.init(_healingMod.Config)
        end
    else
        _healingLoadError = 'UI load failed: ' .. tostring(uiOrErr)
    end
end

function M.draw(settings, themeNames, onChange)
    local changed
    local myClass = mq.TLO.Me.Class.ShortName()
    local themeName = settings.SideKickTheme or 'Classic'

    -- Rez classes such as NEC get the resurrection surface without loading a
    -- second healing runtime.
    local isHealer = HealerClasses.isSupported(myClass)
    local isRezClass = RezData.isRezClass(myClass)

    if not isHealer then
        if isRezClass then
            Components.StatusBadge.neutral('Rez Utility', themeName, { showIcon = false })
            imgui.TextDisabled('This class has resurrection utility but does not run Healing Intelligence.')
            drawResurrection(settings, themeName, onChange)
        else
            Components.StatusBadge.neutral('Non-Healer', themeName, { showIcon = false })
            imgui.TextDisabled('Healing and resurrection settings are not available for this class.')
            imgui.TextDisabled('Current class: ' .. (myClass or 'Unknown'))
        end
        return
    end

    -- Try to load healing module
    initHealingTab()

    local hiConfig = _healingMod and _healingMod.Config or nil

    -- One-time migration: rescue former Core toggles into the healing config.
    -- Runs once per session per class.
    if not _settingsSynced and hiConfig then
        _settingsSynced = true
        local changedConfig = false
        if (settings.DoPetHeals == true or settings.HealPetsEnabled == true)
            and hiConfig.healPetsEnabled ~= true then
            hiConfig.healPetsEnabled = true
            changedConfig = true
        end
        if settings.HealBreakInvisOOC == true and hiConfig.breakInvisOOC ~= true then
            hiConfig.breakInvisOOC = true
            changedConfig = true
        end
        if changedConfig and hiConfig.save then hiConfig.save() end
    end

    -- ========== BASIC HEALING SETTINGS ==========
    Components.SettingGroup.section('Healing', themeName)

    -- Main toggle — DoHeals is the sole authority.
    local doHeals = settings.DoHeals == true

    local healVal, healChanged = Components.StatusBadge.toggle('Healing', doHeals, themeName, {
        enabledText = 'Active',
        disabledText = 'Off',
        tooltip = 'Click to toggle automatic healing',
    })
    if healChanged then
        if onChange then onChange('DoHeals', healVal) end
        doHeals = healVal
    end

    local hiEnabled = doHeals and hiConfig ~= nil

    if doHeals then
        Components.SettingGroup.draw('Healing Options', function()
            -- Priority healing (hidden when HI enabled - HI has its own priority system)
            if not hiEnabled then
                local priority = settings.PriorityHealing ~= false
                local prioVal, prioChanged = Components.CheckboxRow.draw('Priority Healing', 'PriorityHealing', priority, nil, {
                    tooltip = 'Heal lowest HP targets first',
                })
                if prioChanged and onChange then onChange('PriorityHealing', prioVal) end
            end

            -- Break invis OOC
            local breakInvis = hiConfig and hiConfig.breakInvisOOC == true
            local breakVal, breakChanged = Components.CheckboxRow.draw('Break Invis OOC To Heal', 'HealBreakInvisOOC', breakInvis, nil, {
                tooltip = 'Drop invisibility to heal out of combat',
            })
            if breakChanged and hiConfig then
                hiConfig.breakInvisOOC = breakVal
                if hiConfig.save then hiConfig.save() end
            end
        end, { id = 'heal_options', defaultOpen = true })

        -- Heal Points (hidden when HI enabled - HI uses its own thresholds)
        if not hiEnabled then
            Components.SettingGroup.draw('Heal Points', function()
                local mainHeal = tonumber(settings.MainHealPoint) or 80
                local mainChanged, newMain = Components.SliderRow.percent('Main Heal Point', 'MainHealPoint', mainHeal, nil, {
                    tooltip = 'Start main heal when HP drops below this',
                })
                if mainChanged and onChange then onChange('MainHealPoint', newMain) end

                local bigHeal = tonumber(settings.BigHealPoint) or 50
                local bigChanged, newBig = Components.SliderRow.percent('Big Heal Point', 'BigHealPoint', bigHeal, nil, {
                    tooltip = 'Use big/emergency heal when HP drops below this',
                })
                if bigChanged and onChange then onChange('BigHealPoint', newBig) end

                local groupHeal = tonumber(settings.GroupHealPoint) or 75
                local grpChanged, newGrp = Components.SliderRow.percent('Group Heal Point', 'GroupHealPoint', groupHeal, nil, {
                    tooltip = 'Consider group heal when HP drops below this',
                })
                if grpChanged and onChange then onChange('GroupHealPoint', newGrp) end

                local injureCnt = tonumber(settings.GroupInjureCnt) or 2
                local cntChanged, newCnt = Components.SliderRow.int('Group Injured Count', 'GroupInjureCnt', injureCnt, 1, 5, nil, {
                    tooltip = 'Number of injured group members to trigger group heal',
                })
                if cntChanged and onChange then onChange('GroupInjureCnt', newCnt) end
            end, { id = 'heal_points', defaultOpen = true })
        end
    end

    -- ========== PET HEALING ==========
    imgui.Spacing()
    Components.SettingGroup.section('Pet Healing', themeName)

    local doPetHeals = hiConfig and hiConfig.healPetsEnabled == true
    local petVal, petChanged = Components.CheckboxRow.draw('Enable Pet Heals', 'healPetsEnabled', doPetHeals, nil, {
        tooltip = 'Heal group pets',
    })
    if petChanged and hiConfig then
        hiConfig.healPetsEnabled = petVal
        if hiConfig.save then hiConfig.save() end
    end
    doPetHeals = petVal

    if doPetHeals and hiConfig then
        local petHealPt = tonumber(hiConfig.petHealMinPct) or 40
        local petPtChanged, newPetPt = Components.SliderRow.percent('Pet Heal Point', 'petHealMinPct', petHealPt, nil, {
            tooltip = 'Heal pets when their HP drops below this',
        })
        if petPtChanged then
            hiConfig.petHealMinPct = newPetPt
            if hiConfig.save then hiConfig.save() end
        end
    end

    -- ========== EXTENDED TARGETS ==========
    if not hiEnabled then
        imgui.Spacing()
        Components.SettingGroup.section('Extended Healing', themeName)

    -- Watch MA
    local watchMA = settings.HealWatchMA == true
    local maVal, maChanged = Components.CheckboxRow.draw('Watch Main Assist (OOG OK)', 'HealWatchMA', watchMA, nil, {
        tooltip = 'Heal the MA even if outside group',
    })
    if maChanged and onChange then onChange('HealWatchMA', maVal) end

    -- XTarget healing
    local healXT = settings.HealXTargetEnabled == true
    local xtVal, xtChanged = Components.CheckboxRow.draw('Heal XTarget Slots', 'HealXTargetEnabled', healXT, nil, {
        tooltip = 'Heal targets in specific XTarget slots',
    })
    if xtChanged and onChange then onChange('HealXTargetEnabled', xtVal) end
    healXT = xtVal

    if healXT then
        local xtSlots = settings.HealXTargetSlots or ''
        local buf = Settings.labeledInputText('XTarget Slots (e.g. 1|2|3)', xtSlots)
        if buf ~= xtSlots and onChange then
            onChange('HealXTargetSlots', buf)
        end
    end
    end

    -- ========== HOTS (hidden when HI enabled - HI has its own HoT logic) ==========
    if not hiEnabled then
        imgui.Spacing()
        Components.SettingGroup.section('HoTs', themeName)

        local useHoTs = settings.HealUseHoTs ~= false
        local hotVal, hotChanged = Components.CheckboxRow.draw('Use HoTs', 'HealUseHoTs', useHoTs, nil, {
            tooltip = 'Use heal over time spells',
        })
        if hotChanged and onChange then onChange('HealUseHoTs', hotVal) end

        if hotVal then
            local hotRefresh = tonumber(settings.HealHoTMinSeconds) or 6
            local refreshChanged, newRefresh = Components.SliderRow.int('HoT Refresh Window (sec)', 'HealHoTMinSeconds', hotRefresh, 2, 15, nil, {
                tooltip = 'Recast HoT when remaining duration is below this',
            })
            if refreshChanged and onChange then onChange('HealHoTMinSeconds', newRefresh) end
        end
    end

    -- ========== CURES ==========
    imgui.Spacing()
    Components.SettingGroup.section('Cures', themeName)

    local doCures = settings.DoCures ~= false

    -- Toggle badge for cures (clickable to toggle)
    local cureVal, cureChanged = Components.StatusBadge.toggle('Cures', doCures, themeName, {
        enabledText = 'Active',
        disabledText = 'Off',
        enabledStyle = 'buff',
        tooltip = 'Click to toggle automatic curing',
    })
    if cureChanged and onChange then onChange('DoCures', cureVal) end
    doCures = cureVal

    if doCures then
        Components.SettingGroup.draw('Cure Options', function()
            local cureSelf = settings.CurePrioritySelf == true
            local selfVal, selfChanged = Components.CheckboxRow.draw('Cure Self First', 'CurePrioritySelf', cureSelf, nil, {
                tooltip = 'Prioritize curing yourself over others',
            })
            if selfChanged and onChange then onChange('CurePrioritySelf', selfVal) end

            local cureInCombat = settings.CureInCombat ~= false
            local combatVal, combatChanged = Components.CheckboxRow.draw('Cure During Combat', 'CureInCombat', cureInCombat, nil, {
                tooltip = 'Cast cures while in combat',
            })
            if combatChanged and onChange then onChange('CureInCombat', combatVal) end
        end, { id = 'cure_options', defaultOpen = true })
    end

    -- ========== RESURRECTION ==========
    drawResurrection(settings, themeName, onChange)

    -- ========== ADVANCED (Healing Module) ==========
    if _healingSettingsUI and _healingSettingsUI.draw then
        imgui.Spacing()
        if imgui.CollapsingHeader('Advanced Healing Settings') then
            local ok, err = pcall(_healingSettingsUI.draw)
            if not ok then
                imgui.TextColored(1, 0.3, 0.3, 1, 'Error: ' .. tostring(err))
            end
        end
    elseif _healingLoadError then
        imgui.Spacing()
        imgui.TextColored(0.7, 0.5, 0.5, 1.0, 'Advanced healing module not loaded:')
        imgui.TextDisabled(_healingLoadError)
    end
end

return M
