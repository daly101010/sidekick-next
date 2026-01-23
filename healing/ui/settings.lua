-- healing/ui/settings.lua
local mq = require('mq')
local imgui = require('ImGui')

-- Lazy-load Logger to avoid circular requires
local Logger = nil
local function getLogger()
    if Logger == nil then
        local ok, l = pcall(require, 'sidekick-next.healing.logger')
        Logger = ok and l or false
    end
    return Logger or nil
end

local M = {}

local Config = nil
local _toggleMonitorCallback = nil

function M.init(config)
    Config = config
end

function M.setToggleMonitorCallback(callback)
    _toggleMonitorCallback = callback
end

function M.draw()
    if not Config then return end

    local changed

    -- Thresholds
    if imgui.CollapsingHeader('Thresholds') then
        imgui.PushItemWidth(150)

        local emergency = (Config.emergencyPct ~= nil) and Config.emergencyPct or 25
        emergency, changed = imgui.SliderInt('Emergency HP %', emergency, 10, 50)
        if changed then Config.emergencyPct = emergency end

        local minHeal = (Config.minHealPct ~= nil) and Config.minHealPct or 10
        minHeal, changed = imgui.SliderInt('Min Heal HP %', minHeal, 1, 30)
        if changed then Config.minHealPct = minHeal end

        local groupCount = (Config.groupHealMinCount ~= nil) and Config.groupHealMinCount or 3
        groupCount, changed = imgui.SliderInt('Group Heal Min Count', groupCount, 2, 5)
        if changed then Config.groupHealMinCount = groupCount end

        local squishyCoverage = (Config.squishyCoveragePct ~= nil) and Config.squishyCoveragePct or 70
        squishyCoverage, changed = imgui.SliderInt('Squishy Coverage %', squishyCoverage, 50, 90)
        if changed then Config.squishyCoveragePct = squishyCoverage end

        imgui.PopItemWidth()
    end

    -- Ducking
    if imgui.CollapsingHeader('Spell Ducking') then
        local duckEnabled = Config.duckEnabled ~= false
        duckEnabled, changed = imgui.Checkbox('Enable Ducking', duckEnabled)
        if changed then Config.duckEnabled = duckEnabled end

        if imgui.IsItemHovered() then
            imgui.SetTooltip('Cancel heals if target is already healed')
        end

        if duckEnabled then
            imgui.PushItemWidth(150)

            local duckThresh = (Config.duckHpThreshold ~= nil) and Config.duckHpThreshold or 85
            duckThresh, changed = imgui.SliderInt('Duck Threshold %', duckThresh, 70, 95)
            if changed then Config.duckHpThreshold = duckThresh end

            local duckEmergency = (Config.duckEmergencyThreshold ~= nil) and Config.duckEmergencyThreshold or 70
            duckEmergency, changed = imgui.SliderInt('Emergency Duck %', duckEmergency, 50, 90)
            if changed then Config.duckEmergencyThreshold = duckEmergency end

            local duckHot = (Config.duckHotThreshold ~= nil) and Config.duckHotThreshold or 92
            duckHot, changed = imgui.SliderInt('HoT Duck Threshold %', duckHot, 80, 99)
            if changed then Config.duckHotThreshold = duckHot end

            local duckBuffer = (Config.duckBufferPct ~= nil) and Config.duckBufferPct or 0.5
            duckBuffer, changed = imgui.SliderFloat('Duck Buffer %', duckBuffer, 0.0, 5.0, '%.1f')
            if changed then Config.duckBufferPct = duckBuffer end

            local considerHot = Config.considerIncomingHot ~= false
            considerHot, changed = imgui.Checkbox('Consider Incoming HoTs', considerHot)
            if changed then Config.considerIncomingHot = considerHot end

            imgui.PopItemWidth()
        end
    end

    -- HoT Behavior
    if imgui.CollapsingHeader('HoT Behavior') then
        local hotEnabled = Config.hotEnabled ~= false
        hotEnabled, changed = imgui.Checkbox('Enable Proactive HoTs', hotEnabled)
        if changed then Config.hotEnabled = hotEnabled end

        if imgui.IsItemHovered() then
            imgui.SetTooltip('Apply HoTs preemptively based on combat state')
        end

        if hotEnabled then
            imgui.PushItemWidth(150)

            local minRatio = (Config.hotMinCoverageRatio ~= nil) and Config.hotMinCoverageRatio or 0.3
            minRatio, changed = imgui.SliderFloat('Min Coverage Ratio', minRatio, 0.1, 1.0, '%.2f')
            if changed then Config.hotMinCoverageRatio = minRatio end

            if imgui.IsItemHovered() then
                imgui.SetTooltip('HoT must cover this fraction of expected damage')
            end

            local refreshBuffer = (Config.hotRefreshBufferSec ~= nil) and Config.hotRefreshBufferSec or 3
            refreshBuffer, changed = imgui.SliderInt('Refresh Buffer (sec)', refreshBuffer, 1, 10)
            if changed then Config.hotRefreshBufferSec = refreshBuffer end

            local tankOnly = Config.hotTankOnly ~= false
            tankOnly, changed = imgui.Checkbox('Big HoT Tank Only', tankOnly)
            if changed then Config.hotTankOnly = tankOnly end

            imgui.PopItemWidth()
        end
    end

    -- Logging
    if imgui.CollapsingHeader('Logging') then
        local fileLogging = Config.fileLogging == true
        fileLogging, changed = imgui.Checkbox('Enable File Logging', fileLogging)
        if changed then Config.fileLogging = fileLogging end

        if imgui.IsItemHovered() then
            local configDir = mq.configDir or 'config'
            imgui.SetTooltip('Logs to: ' .. configDir .. '/HealingLogs/')
        end

        if fileLogging then
            imgui.PushItemWidth(100)

            local levels = { 'debug', 'info', 'warn', 'error' }
            local currentLevel = Config.fileLogLevel or 'info'
            local currentIdx = 1
            for i, level in ipairs(levels) do
                if level == currentLevel then
                    currentIdx = i
                    break
                end
            end

            -- Use null-separated string format for Combo (consistent with rest of codebase)
            local labelStr = table.concat(levels, '\0') .. '\0\0'
            local newIdx = imgui.Combo('Log Level', currentIdx, labelStr)
            if newIdx ~= currentIdx and levels[newIdx] then
                Config.fileLogLevel = levels[newIdx]
            end

            imgui.PopItemWidth()

            -- Log categories
            imgui.Text('Log Categories:')
            if not Config.logCategories then Config.logCategories = {} end

            local categories = {
                { key = 'targetSelection', label = 'Target Selection' },
                { key = 'spellSelection', label = 'Spell Selection' },
                { key = 'spellScoring', label = 'Spell Scoring (verbose)' },
                { key = 'ducking', label = 'Ducking Decisions' },
                { key = 'hotDecisions', label = 'HoT Decisions' },
                { key = 'incomingHeals', label = 'Incoming Heals' },
                { key = 'combatState', label = 'Combat State' },
                { key = 'analytics', label = 'Analytics' },
            }

            for _, cat in ipairs(categories) do
                local enabled = Config.logCategories[cat.key] ~= false
                enabled, changed = imgui.Checkbox(cat.label, enabled)
                if changed then Config.logCategories[cat.key] = enabled end
            end
        end
    end

    -- Advanced
    if imgui.CollapsingHeader('Advanced') then
        local broadcast = Config.broadcastEnabled ~= false
        broadcast, changed = imgui.Checkbox('Broadcast to Other Healers', broadcast)
        if changed then Config.broadcastEnabled = broadcast end

        if imgui.IsItemHovered() then
            imgui.SetTooltip('Share incoming heal info via Actors')
        end

        local debug = Config.debugLogging == true
        debug, changed = imgui.Checkbox('Debug Logging', debug)
        if changed then Config.debugLogging = debug end

        imgui.Separator()

        imgui.PushItemWidth(150)

        local incomingTimeout = (Config.incomingHealTimeoutSec ~= nil) and Config.incomingHealTimeoutSec or 10
        incomingTimeout, changed = imgui.SliderInt('Incoming Timeout (sec)', incomingTimeout, 5, 30)
        if changed then Config.incomingHealTimeoutSec = incomingTimeout end

        local dmgWindow = (Config.damageWindowSec ~= nil) and Config.damageWindowSec or 6
        dmgWindow, changed = imgui.SliderInt('Damage Window (sec)', dmgWindow, 3, 15)
        if changed then Config.damageWindowSec = dmgWindow end

        local burstThresh = (Config.burstThresholdSigma ~= nil) and Config.burstThresholdSigma or 2.0
        burstThresh, changed = imgui.SliderFloat('Burst Threshold (sigma)', burstThresh, 1.0, 4.0, '%.1f')
        if changed then Config.burstThresholdSigma = burstThresh end

        imgui.PopItemWidth()
    end

    imgui.Separator()

    if imgui.Button('Save Config') then
        if Config.save then Config.save() end
        local log = getLogger()
        if log then log.info('config', 'Config saved via UI') end
    end

    imgui.SameLine()

    if imgui.Button('Reset to Defaults') then
        if Config.resetDefaults then Config.resetDefaults() end
    end

    imgui.SameLine()

    if imgui.Button('Open Heal Monitor') then
        if _toggleMonitorCallback then
            _toggleMonitorCallback()
        end
    end
end

return M
