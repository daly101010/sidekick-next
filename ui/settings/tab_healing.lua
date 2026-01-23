-- ============================================================
-- SideKick Settings - Healing Tab
-- ============================================================
-- Healing configuration for healer classes (CLR, DRU, SHM, PAL).

local imgui = require('ImGui')
local mq = require('mq')
local Settings = require('sidekick-next.ui.settings')

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

    -- Check if this is a healer class
    local isHealer = myClass == 'CLR' or myClass == 'DRU' or myClass == 'SHM' or myClass == 'PAL'

    if not isHealer then
        imgui.TextColored(0.7, 0.7, 0.7, 1.0, 'Healing settings are for healer classes.')
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
    imgui.TextColored(0.7, 0.9, 1.0, 1.0, 'Healing')
    imgui.Separator()

    -- Main toggle - controls both DoHeals and Healing Intelligence
    local doHeals = settings.DoHeals == true
    doHeals, changed = Settings.labeledCheckbox('Enable Heals', doHeals)
    if changed then
        if onChange then onChange('DoHeals', doHeals) end
        -- Sync with Healing Intelligence Config
        if hiConfig then
            hiConfig.enabled = doHeals
            if hiConfig.save then hiConfig.save() end
        end
    end

    -- Sync hiEnabled for conditional display below
    hiEnabled = doHeals and hiConfig ~= nil

    if doHeals then
        imgui.Indent()

        -- Priority healing (hidden when HI enabled - HI has its own priority system)
        if not hiEnabled then
            local priority = settings.PriorityHealing ~= false
            priority, changed = Settings.labeledCheckbox('Priority Healing', priority, 'Heal lowest HP targets first')
            if changed and onChange then onChange('PriorityHealing', priority) end
        end

        -- Break invis OOC
        local breakInvis = settings.HealBreakInvisOOC == true
        breakInvis, changed = Settings.labeledCheckbox('Break Invis OOC To Heal', breakInvis)
        if changed and onChange then onChange('HealBreakInvisOOC', breakInvis) end

        -- Heal Points (hidden when HI enabled - HI uses its own thresholds)
        if not hiEnabled then
            imgui.Separator()
            imgui.Text('Heal Points')

            local mainHeal = tonumber(settings.MainHealPoint) or 80
            mainHeal, changed = Settings.labeledSliderInt('Main Heal Point %', mainHeal, 50, 99)
            if changed and onChange then onChange('MainHealPoint', mainHeal) end

            local bigHeal = tonumber(settings.BigHealPoint) or 50
            bigHeal, changed = Settings.labeledSliderInt('Big Heal Point %', bigHeal, 20, 80)
            if changed and onChange then onChange('BigHealPoint', bigHeal) end

            local groupHeal = tonumber(settings.GroupHealPoint) or 75
            groupHeal, changed = Settings.labeledSliderInt('Group Heal Point %', groupHeal, 50, 95)
            if changed and onChange then onChange('GroupHealPoint', groupHeal) end

            local injureCnt = tonumber(settings.GroupInjureCnt) or 2
            injureCnt, changed = Settings.labeledSliderInt('Group Injured Count', injureCnt, 1, 5)
            if changed and onChange then onChange('GroupInjureCnt', injureCnt) end
        end

        imgui.Unindent()
    end

    -- ========== PET HEALING ==========
    imgui.Spacing()
    imgui.TextColored(0.7, 0.9, 1.0, 1.0, 'Pet Healing')
    imgui.Separator()

    local doPetHeals = settings.DoPetHeals == true
    doPetHeals, changed = Settings.labeledCheckbox('Enable Pet Heals', doPetHeals)
    if changed and onChange then onChange('DoPetHeals', doPetHeals) end

    -- Pet Heal Point (hidden when HI enabled - HI uses its own petHealMinPct)
    if doPetHeals and not hiEnabled then
        local petHealPt = tonumber(settings.PetHealPoint) or 50
        petHealPt, changed = Settings.labeledSliderInt('Pet Heal Point %', petHealPt, 20, 80)
        if changed and onChange then onChange('PetHealPoint', petHealPt) end
    end

    -- ========== EXTENDED TARGETS ==========
    imgui.Spacing()
    imgui.TextColored(0.7, 0.9, 1.0, 1.0, 'Extended Healing')
    imgui.Separator()

    -- Watch MA
    local watchMA = settings.HealWatchMA == true
    watchMA, changed = Settings.labeledCheckbox('Watch Main Assist (OOG OK)', watchMA, 'Heal the MA even if outside group')
    if changed and onChange then onChange('HealWatchMA', watchMA) end

    -- XTarget healing
    local healXT = settings.HealXTargetEnabled == true
    healXT, changed = Settings.labeledCheckbox('Heal XTarget Slots', healXT)
    if changed and onChange then onChange('HealXTargetEnabled', healXT) end

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
        imgui.TextColored(0.7, 0.9, 1.0, 1.0, 'HoTs')
        imgui.Separator()

        local useHoTs = settings.HealUseHoTs ~= false
        useHoTs, changed = Settings.labeledCheckbox('Use HoTs', useHoTs)
        if changed and onChange then onChange('HealUseHoTs', useHoTs) end

        if useHoTs then
            local hotRefresh = tonumber(settings.HealHoTMinSeconds) or 6
            hotRefresh, changed = Settings.labeledSliderInt('HoT Refresh Window (sec)', hotRefresh, 2, 15)
            if changed and onChange then onChange('HealHoTMinSeconds', hotRefresh) end
        end
    end

    -- ========== CURES ==========
    imgui.Spacing()
    imgui.TextColored(0.7, 0.9, 1.0, 1.0, 'Cures')
    imgui.Separator()

    local doCures = settings.DoCures ~= false
    doCures, changed = Settings.labeledCheckbox('Enable Cures', doCures)
    if changed and onChange then onChange('DoCures', doCures) end

    if doCures then
        local cureSelf = settings.CurePrioritySelf == true
        cureSelf, changed = Settings.labeledCheckbox('Cure Self First', cureSelf)
        if changed and onChange then onChange('CurePrioritySelf', cureSelf) end

        local cureInCombat = settings.CureInCombat ~= false
        cureInCombat, changed = Settings.labeledCheckbox('Cure During Combat', cureInCombat)
        if changed and onChange then onChange('CureInCombat', cureInCombat) end
    end

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
