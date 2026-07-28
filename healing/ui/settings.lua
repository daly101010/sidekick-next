-- healing/ui/settings.lua
local mq = require('mq')
local imgui = require('ImGui')
local lazy = require('sidekick-next.utils.lazy_require')

-- Lazy-load Logger to avoid circular requires
local getLogger = lazy.once('sidekick-next.healing.logger')

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

        local emergency = Config.getEmergencyPct()
        emergency, changed = imgui.SliderInt('Emergency HP %', emergency, 10, 50)
        if changed then Config.emergencyPct = emergency end

        local minHeal = (Config.minHealPct ~= nil) and Config.minHealPct or 10
        minHeal, changed = imgui.SliderInt('Min Heal HP %', minHeal, 1, 30)
        if changed then Config.minHealPct = minHeal end

        local groupCount = (Config.groupHealMinCount ~= nil) and Config.groupHealMinCount or 3
        groupCount, changed = imgui.SliderInt('Group Heal Min Count', groupCount, 2, 5)
        if changed then Config.groupHealMinCount = groupCount end

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

            local duckHot = (Config.duckHotThreshold ~= nil) and Config.duckHotThreshold or 92
            duckHot, changed = imgui.SliderInt('HoT Duck Threshold %', duckHot, 80, 99)
            if changed then Config.duckHotThreshold = duckHot end

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

        imgui.PushItemWidth(150)

        local incomingTimeout = (Config.incomingHealTimeoutSec ~= nil) and Config.incomingHealTimeoutSec or 10
        incomingTimeout, changed = imgui.SliderInt('Incoming Timeout (sec)', incomingTimeout, 5, 30)
        if changed then Config.incomingHealTimeoutSec = incomingTimeout end

        local dmgWindow = (Config.damageWindowSec ~= nil) and Config.damageWindowSec or 6
        dmgWindow, changed = imgui.SliderInt('Damage Window (sec)', dmgWindow, 3, 15)
        if changed then Config.damageWindowSec = dmgWindow end

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
