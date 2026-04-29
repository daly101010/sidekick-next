-- ============================================================
-- SideKick Settings - Healing Tab
-- ============================================================
-- Healing configuration for healer classes (CLR, DRU, SHM, PAL).

local imgui = require('ImGui')
local mq = require('mq')
local Settings = require('sidekick-next.ui.settings')
local Components = require('sidekick-next.ui.components')

local M = {}

-- Lazy-loaded healing modules
local _healingMod = nil
local _healingSettingsUI = nil
local _healingModChecked = false
local _healingLoadError = nil
local _settingsSynced = false

local function initHealingTab()
    if _healingModChecked then return end
    _healingModChecked = true

    local ok, modOrErr = pcall(require, 'sidekick-next.healing')
    if not ok then
        _healingLoadError = tostring(modOrErr)
        return
    end

    local mod = modOrErr
    if not mod then
        _healingLoadError = 'Module returned nil'
        return
    end

    -- Ensure healing module is initialized
    if mod.init then
        local initOk, initErr = pcall(mod.init)
        if not initOk then
            _healingLoadError = 'init() failed: ' .. tostring(initErr)
            return
        end
    end

    if not mod.Config then
        _healingLoadError = 'mod.Config is nil'
        return
    end

    _healingMod = mod

    -- Sync Config.enabled with DoHeals on init (DoHeals is the source of truth)
    -- This will be done in draw() when settings are available

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

    -- Check if this is a healer class
    local isHealer = myClass == 'CLR' or myClass == 'DRU' or myClass == 'SHM' or myClass == 'PAL'

    if not isHealer then
        Components.StatusBadge.neutral('Non-Healer', themeName, { showIcon = false })
        imgui.TextDisabled('Healing settings are for healer classes.')
        imgui.TextDisabled('Current class: ' .. (myClass or 'Unknown'))
        return
    end

    -- Try to load healing module
    initHealingTab()

    -- Healing Intelligence is the only healing system - sync DoHeals with Config.enabled
    local hiConfig = _healingMod and _healingMod.Config or nil

    -- On first draw, sync Config.enabled to match DoHeals (DoHeals is source of truth)
    if not _settingsSynced and hiConfig then
        _settingsSynced = true
        local doHealsValue = settings.DoHeals == true
        if hiConfig.enabled ~= doHealsValue then
            hiConfig.enabled = doHealsValue
            if hiConfig.save then hiConfig.save() end
        end
    end

    local hiEnabled = hiConfig and hiConfig.enabled == true

    -- ========== BASIC HEALING SETTINGS ==========
    Components.SettingGroup.section('Healing', themeName)

    -- Main toggle - controls both DoHeals and Healing Intelligence
    local doHeals = settings.DoHeals == true

    -- Toggle badge for healing (clickable to toggle)
    local healVal, healChanged = Components.StatusBadge.toggle('Healing', doHeals, themeName, {
        enabledText = 'Active',
        disabledText = 'Off',
        tooltip = 'Click to toggle automatic healing',
    })
    if healChanged then
        if onChange then onChange('DoHeals', healVal) end
        -- Sync with Healing Intelligence Config
        if hiConfig then
            hiConfig.enabled = healVal
            if hiConfig.save then hiConfig.save() end
        end
        doHeals = healVal
    end

    -- Sync hiEnabled for conditional display below
    hiEnabled = doHeals and hiConfig ~= nil

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
            local breakInvis = settings.HealBreakInvisOOC == true
            local breakVal, breakChanged = Components.CheckboxRow.draw('Break Invis OOC To Heal', 'HealBreakInvisOOC', breakInvis, nil, {
                tooltip = 'Drop invisibility to heal out of combat',
            })
            if breakChanged and onChange then onChange('HealBreakInvisOOC', breakVal) end
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

    local doPetHeals = settings.DoPetHeals == true
    local petVal, petChanged = Components.CheckboxRow.draw('Enable Pet Heals', 'DoPetHeals', doPetHeals, nil, {
        tooltip = 'Heal group pets',
    })
    if petChanged and onChange then onChange('DoPetHeals', petVal) end
    doPetHeals = petVal

    -- Pet Heal Point (hidden when HI enabled - HI uses its own petHealMinPct)
    if doPetHeals and not hiEnabled then
        local petHealPt = tonumber(settings.PetHealPoint) or 50
        local petPtChanged, newPetPt = Components.SliderRow.percent('Pet Heal Point', 'PetHealPoint', petHealPt, nil, {
            tooltip = 'Heal pets when their HP drops below this',
        })
        if petPtChanged and onChange then onChange('PetHealPoint', newPetPt) end
    end

    -- ========== EXTENDED TARGETS ==========
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
    -- Group-only auto-rez. CLR/DRU/SHM/PAL render here (healer classes); NEC
    -- gets the same Core.Settings keys but without a UI surface — they fall
    -- back to defaults (auto-OOC on, auto-in-combat off, auto-accept on).
    imgui.Spacing()
    Components.SettingGroup.section('Resurrection', themeName)

    local autoRezOOC = settings.AutoRezOOC ~= false
    local oocVal, oocChanged = Components.CheckboxRow.draw('Auto-Rez Out of Combat', 'AutoRezOOC', autoRezOOC, nil, {
        tooltip = 'After combat ends, automatically rez dead group members. Issues /corpse to drag the corpse before casting.',
    })
    if oocChanged and onChange then onChange('AutoRezOOC', oocVal) end

    local autoRezCombat = settings.AutoRezInCombat == true
    local combatVal2, combatChanged2 = Components.CheckboxRow.draw('Auto Battle-Rez (AA only)', 'AutoRezInCombat', autoRezCombat, nil, {
        tooltip = 'During combat, fire the class battle-rez AA (e.g. Blessing of Resurrection). The AA has a real cast time (~5s) and will pause the heal rotation for its duration. Never spell-rezzes during a fight.',
    })
    if combatChanged2 and onChange then onChange('AutoRezInCombat', combatVal2) end

    local autoAcceptRez = settings.AutoAcceptRez ~= false
    local accVal, accChanged = Components.CheckboxRow.draw('Auto-Accept Rez Offers', 'AutoAcceptRez', autoAcceptRez, nil, {
        tooltip = 'When this character receives a rez offer dialog, automatically click Yes.',
    })
    if accChanged and onChange then onChange('AutoAcceptRez', accVal) end

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
