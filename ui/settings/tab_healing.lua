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

    -- ========== BASIC HEALING SETTINGS ==========
    imgui.TextColored(0.7, 0.9, 1.0, 1.0, 'Healing')
    imgui.Separator()

    -- Main toggle
    local doHeals = settings.DoHeals == true
    doHeals, changed = imgui.Checkbox('Enable Heals', doHeals)
    if changed and onChange then onChange('DoHeals', doHeals) end

    if doHeals then
        imgui.Indent()

        -- Priority healing
        local priority = settings.PriorityHealing ~= false
        priority, changed = imgui.Checkbox('Priority Healing', priority)
        if changed and onChange then onChange('PriorityHealing', priority) end
        if imgui.IsItemHovered() then
            Settings.safeTooltip('Heal lowest HP targets first')
        end

        -- Break invis OOC
        local breakInvis = settings.HealBreakInvisOOC == true
        breakInvis, changed = imgui.Checkbox('Break Invis OOC To Heal', breakInvis)
        if changed and onChange then onChange('HealBreakInvisOOC', breakInvis) end

        imgui.Separator()
        imgui.Text('Heal Points')

        local mainHeal = tonumber(settings.MainHealPoint) or 80
        mainHeal, changed = imgui.SliderInt('Main Heal Point %%', mainHeal, 50, 99)
        if changed and onChange then onChange('MainHealPoint', mainHeal) end

        local bigHeal = tonumber(settings.BigHealPoint) or 50
        bigHeal, changed = imgui.SliderInt('Big Heal Point %%', bigHeal, 20, 80)
        if changed and onChange then onChange('BigHealPoint', bigHeal) end

        local groupHeal = tonumber(settings.GroupHealPoint) or 75
        groupHeal, changed = imgui.SliderInt('Group Heal Point %%', groupHeal, 50, 95)
        if changed and onChange then onChange('GroupHealPoint', groupHeal) end

        local injureCnt = tonumber(settings.GroupInjureCnt) or 2
        injureCnt, changed = imgui.SliderInt('Group Injured Count', injureCnt, 1, 5)
        if changed and onChange then onChange('GroupInjureCnt', injureCnt) end

        local emergencyPct = tonumber(settings.EmergencyHealPct) or 20
        emergencyPct, changed = imgui.SliderInt('Emergency Heal %%', emergencyPct, 10, 40)
        if changed and onChange then onChange('EmergencyHealPct', emergencyPct) end

        imgui.Unindent()
    end

    -- ========== PET HEALING ==========
    imgui.Spacing()
    imgui.TextColored(0.7, 0.9, 1.0, 1.0, 'Pet Healing')
    imgui.Separator()

    local doPetHeals = settings.DoPetHeals == true
    doPetHeals, changed = imgui.Checkbox('Enable Pet Heals', doPetHeals)
    if changed and onChange then onChange('DoPetHeals', doPetHeals) end

    if doPetHeals then
        local petHealPt = tonumber(settings.PetHealPoint) or 50
        petHealPt, changed = imgui.SliderInt('Pet Heal Point %%', petHealPt, 20, 80)
        if changed and onChange then onChange('PetHealPoint', petHealPt) end
    end

    -- ========== EXTENDED TARGETS ==========
    imgui.Spacing()
    imgui.TextColored(0.7, 0.9, 1.0, 1.0, 'Extended Healing')
    imgui.Separator()

    -- Watch MA
    local watchMA = settings.HealWatchMA == true
    watchMA, changed = imgui.Checkbox('Watch Main Assist (OOG OK)', watchMA)
    if changed and onChange then onChange('HealWatchMA', watchMA) end
    if imgui.IsItemHovered() then
        Settings.safeTooltip('Heal the MA even if outside group')
    end

    -- XTarget healing
    local healXT = settings.HealXTargetEnabled == true
    healXT, changed = imgui.Checkbox('Heal XTarget Slots', healXT)
    if changed and onChange then onChange('HealXTargetEnabled', healXT) end

    if healXT then
        local xtSlots = settings.HealXTargetSlots or ''
        local buf = imgui.InputText('XTarget Slots (e.g. 1|2|3)', xtSlots, 64)
        if buf ~= xtSlots and onChange then
            onChange('HealXTargetSlots', buf)
        end
    end

    -- ========== HOTS ==========
    imgui.Spacing()
    imgui.TextColored(0.7, 0.9, 1.0, 1.0, 'HoTs')
    imgui.Separator()

    local useHoTs = settings.HealUseHoTs ~= false
    useHoTs, changed = imgui.Checkbox('Use HoTs', useHoTs)
    if changed and onChange then onChange('HealUseHoTs', useHoTs) end

    if useHoTs then
        local hotRefresh = tonumber(settings.HealHoTMinSeconds) or 6
        hotRefresh, changed = imgui.SliderInt('HoT Refresh Window (sec)', hotRefresh, 2, 15)
        if changed and onChange then onChange('HealHoTMinSeconds', hotRefresh) end
    end

    -- ========== REZ ==========
    imgui.Spacing()
    imgui.TextColored(0.7, 0.9, 1.0, 1.0, 'Resurrection')
    imgui.Separator()

    local combatRez = settings.DoCombatRez == true
    combatRez, changed = imgui.Checkbox('Combat Rez', combatRez)
    if changed and onChange then onChange('DoCombatRez', combatRez) end

    local oocRez = settings.DoOutOfCombatRez ~= false
    oocRez, changed = imgui.Checkbox('Out of Combat Rez', oocRez)
    if changed and onChange then onChange('DoOutOfCombatRez', oocRez) end

    -- ========== CURES ==========
    imgui.Spacing()
    imgui.TextColored(0.7, 0.9, 1.0, 1.0, 'Cures')
    imgui.Separator()

    local doCures = settings.DoCures ~= false
    doCures, changed = imgui.Checkbox('Enable Cures', doCures)
    if changed and onChange then onChange('DoCures', doCures) end

    if doCures then
        local cureSelf = settings.CurePrioritySelf == true
        cureSelf, changed = imgui.Checkbox('Cure Self First', cureSelf)
        if changed and onChange then onChange('CurePrioritySelf', cureSelf) end

        local cureInCombat = settings.CureInCombat ~= false
        cureInCombat, changed = imgui.Checkbox('Cure During Combat', cureInCombat)
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
