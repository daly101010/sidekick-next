-- healing/ui/monitor.lua
local mq = require('mq')
local imgui = require('ImGui')
local Anchor = require('sidekick-next.ui.anchor')
local Helpers = require('sidekick-next.lib.helpers')

local M = {}

local vec2xy = Helpers.vec2xy

local _open = false
local _draw = false
local _compact = false
local _currentTab = 'status'
local _lastSize = { w = 450, h = 400 }

local TargetMonitor = nil
local IncomingHeals = nil
local CombatAssessor = nil
local Analytics = nil
local Config = nil
local HealTracker = nil
local HealSelector = nil
local MobAssessor = nil

-- Helper function to format numbers in 'k' format
local function formatK(value)
    if not value or value == 0 then
        return '0'
    end
    if value >= 1000 then
        return string.format('%.1fk', value / 1000)
    end
    return tostring(math.floor(value))
end

-- Helper function to format duration as MM:SS
local function formatDuration(seconds)
    if not seconds then return '00:00' end
    local mins = math.floor(seconds / 60)
    local secs = seconds % 60
    return string.format('%02d:%02d', mins, secs)
end

-- Helper to get HP bar color (red when low, yellow mid, green when full)
local function getHPColor(pctHP)
    pctHP = pctHP or 100
    if pctHP <= 25 then
        return 0.9, 0.1, 0.1, 1.0  -- Red
    elseif pctHP <= 50 then
        return 0.9, 0.5, 0.1, 1.0  -- Orange
    elseif pctHP <= 75 then
        return 0.9, 0.9, 0.1, 1.0  -- Yellow
    else
        return 0.1, 0.9, 0.1, 1.0  -- Green
    end
end

---@param config table
---@param targetMonitor table
---@param incomingHeals table
---@param combatAssessor table
---@param analytics table
---@param healTracker table
---@param healSelector table
---@param mobAssessor table|nil
function M.init(config, targetMonitor, incomingHeals, combatAssessor, analytics, healTracker, healSelector, mobAssessor)
    Config = config
    TargetMonitor = targetMonitor
    IncomingHeals = incomingHeals
    CombatAssessor = combatAssessor
    Analytics = analytics
    HealTracker = healTracker
    HealSelector = healSelector
    MobAssessor = mobAssessor
end

function M.toggle()
    _open = not _open
end

function M.isOpen()
    return _open
end

function M.setOpen(open)
    _open = open
end

-- Draw the Status tab
local function DrawStatusTab()
    -- Combat state line
    local state = CombatAssessor and CombatAssessor.getState() or {}
    local statusColor = state.survivalMode and { 1, 0.3, 0.3, 1 } or { 0.3, 1, 0.3, 1 }
    imgui.TextColored(statusColor[1], statusColor[2], statusColor[3], statusColor[4],
        string.format('Status: %s | Phase: %s | Survival: %s',
            state.inCombat and 'Active' or 'Idle',
            state.fightPhase or 'none',
            state.survivalMode and 'ON' or 'OFF'))

    imgui.Separator()

    -- Last action display
    local lastAction = HealSelector and HealSelector.getLastAction and HealSelector.getLastAction()
    if lastAction then
        imgui.Text('Last Action:')
        imgui.SameLine()
        if type(lastAction) == 'string' then
            imgui.TextColored(0.5, 0.8, 1.0, 1.0, lastAction)
        elseif type(lastAction) == 'table' then
            imgui.TextColored(0.5, 0.8, 1.0, 1.0, string.format('%s on %s (%s)',
                lastAction.spell or 'Unknown',
                lastAction.target or 'Unknown',
                formatK(lastAction.expected or 0)))
        end
    else
        imgui.TextDisabled('Last Action: None')
    end

    imgui.Separator()

    -- Targets section
    imgui.Text('Targets:')

    if not TargetMonitor then
        imgui.TextDisabled('Target monitor not available')
        return
    end

    local ok, injured = pcall(function() return TargetMonitor.getInjuredTargets(100) end)
    if not ok or not injured or #injured == 0 then
        imgui.TextDisabled('No targets tracked')
        return
    end

    -- Display targets with HP bars
    for _, target in ipairs(injured) do
        local pctHP = target.pctHP or 100
        local r, g, b, a = getHPColor(pctHP)

        -- Role indicator with color
        local roleColor
        local roleLabel = target.role or 'dps'
        if roleLabel == 'tank' then
            roleColor = {1.0, 0.8, 0.2, 1.0}  -- Gold for tank
        elseif roleLabel == 'healer' then
            roleColor = {0.5, 0.8, 1.0, 1.0}  -- Blue for healer
        elseif roleLabel == 'pet' then
            roleColor = {0.6, 0.4, 0.8, 1.0}  -- Purple for pet
        else
            roleColor = {0.8, 0.8, 0.8, 1.0}  -- Gray for dps/other
        end

        local roleIcon = roleLabel == 'tank' and '[T]' or (roleLabel == 'healer' and '[H]' or (roleLabel == 'pet' and '[P]' or '[D]'))
        imgui.TextColored(roleColor[1], roleColor[2], roleColor[3], roleColor[4], roleIcon)
        imgui.SameLine()

        -- Name (truncated)
        local name = target.name or 'Unknown'
        if #name > 12 then name = name:sub(1, 12) end
        imgui.Text(name)
        imgui.SameLine()

        -- HP bar
        imgui.PushStyleColor(ImGuiCol.PlotHistogram, r, g, b, a)
        imgui.ProgressBar(pctHP / 100, 100, 14, string.format('%d%%', pctHP))
        imgui.PopStyleColor()

        imgui.SameLine()

        -- Deficit
        local deficit = target.deficit or 0
        if deficit > 0 then
            imgui.TextColored(1.0, 0.5, 0.5, 1.0, string.format('-%s', formatK(deficit)))
        else
            imgui.TextColored(0.5, 0.8, 0.5, 1.0, 'Full')
        end

        -- Incoming heals and DPS on same line
        imgui.SameLine()
        local incoming = target.incomingTotal or 0
        if incoming > 0 then
            imgui.TextColored(0.3, 0.8, 0.3, 1, string.format('+%s', formatK(incoming)))
        end

        local dps = target.recentDps or 0
        if dps > 0 then
            imgui.SameLine()
            -- Color code DPS
            if dps > 5000 then
                imgui.TextColored(1.0, 0.2, 0.2, 1.0, string.format('%.0f/s', dps))
            elseif dps > 2000 then
                imgui.TextColored(1.0, 0.6, 0.2, 1.0, string.format('%.0f/s', dps))
            else
                imgui.TextColored(0.9, 0.9, 0.2, 1.0, string.format('%.0f/s', dps))
            end
        end
    end
end

-- Draw the Heal Data tab
local function DrawHealDataTab()
    if not Analytics then
        imgui.TextDisabled('Analytics not available')
        return
    end

    local stats = Analytics.getStats()
    local bySpell = stats.bySpell or {}
    local aggregated = {}
    for spellName, data in pairs(bySpell) do
        local baseName = tostring(spellName):gsub('%s+[Rr]k%.?%s*[%w]+$', ''):gsub('%s+[Rr]ank%s*[%w]+$', '')
        aggregated[baseName] = aggregated[baseName] or {
            casts = 0,
            healed = 0,
            overhealed = 0,
            ducked = 0,
            manaSpent = 0,
            hotTicks = 0,
            hotTicksUseless = 0,
            hotTicksMissed = 0,
            minHeal = nil,
            maxHeal = 0,
            critCount = 0,
        }
        local agg = aggregated[baseName]
        agg.casts = agg.casts + (data.casts or 0)
        agg.healed = agg.healed + (data.healed or 0)
        agg.overhealed = agg.overhealed + (data.overhealed or 0)
        agg.ducked = agg.ducked + (data.ducked or 0)
        agg.manaSpent = agg.manaSpent + (data.manaSpent or 0)
        agg.hotTicks = agg.hotTicks + (data.hotTicks or 0)
        agg.hotTicksUseless = agg.hotTicksUseless + (data.hotTicksUseless or 0)
        agg.hotTicksMissed = agg.hotTicksMissed + (data.hotTicksMissed or 0)
        -- Aggregate min/max/crit
        if data.minHeal then
            if not agg.minHeal or data.minHeal < agg.minHeal then
                agg.minHeal = data.minHeal
            end
        end
        if (data.maxHeal or 0) > agg.maxHeal then
            agg.maxHeal = data.maxHeal
        end
        agg.critCount = agg.critCount + (data.critCount or 0)
    end

    -- Count entries
    local count = 0
    for _ in pairs(aggregated) do count = count + 1 end

    if count == 0 then
        imgui.TextDisabled('No heal data tracked yet.')
        imgui.TextDisabled('Cast some heals to start tracking!')
        return
    end

    imgui.Text(string.format('Tracked Spells: %d', count))
    imgui.Separator()

    -- Heal data table
    local tableFlags = bit32.bor(ImGuiTableFlags.Borders, ImGuiTableFlags.RowBg, ImGuiTableFlags.Resizable, ImGuiTableFlags.ScrollX)
    if imgui.BeginTable('HealDataTable', 10, tableFlags) then
        imgui.TableSetupColumn('Spell', ImGuiTableColumnFlags.WidthStretch)
        imgui.TableSetupColumn('Casts', ImGuiTableColumnFlags.WidthFixed, 40)
        imgui.TableSetupColumn('Min', ImGuiTableColumnFlags.WidthFixed, 45)
        imgui.TableSetupColumn('Avg', ImGuiTableColumnFlags.WidthFixed, 45)
        imgui.TableSetupColumn('Max', ImGuiTableColumnFlags.WidthFixed, 45)
        imgui.TableSetupColumn('Crit%', ImGuiTableColumnFlags.WidthFixed, 40)
        imgui.TableSetupColumn('Healed', ImGuiTableColumnFlags.WidthFixed, 50)
        imgui.TableSetupColumn('Overheal', ImGuiTableColumnFlags.WidthFixed, 50)
        imgui.TableSetupColumn('Ducked', ImGuiTableColumnFlags.WidthFixed, 40)
        imgui.TableSetupColumn('HoT', ImGuiTableColumnFlags.WidthFixed, 50)
        imgui.TableHeadersRow()

        for spellName, data in pairs(aggregated) do
            imgui.TableNextRow()

            imgui.TableNextColumn()
            -- Truncate long spell names
            local displayName = spellName
            if #displayName > 18 then
                displayName = displayName:sub(1, 15) .. '...'
            end
            imgui.Text(displayName)
            if imgui.IsItemHovered() and #spellName > 18 then
                imgui.SetTooltip(spellName)
            end

            imgui.TableNextColumn()
            imgui.Text(tostring(data.casts or 0))

            -- Min heal
            imgui.TableNextColumn()
            if data.minHeal then
                imgui.Text(formatK(data.minHeal))
            else
                imgui.TextDisabled('-')
            end

            -- Avg heal using full potential (healed + overhealed) to match min/max
            imgui.TableNextColumn()
            local totalHealEvents = (data.casts or 0) + ((data.hotTicks or 0) - (data.hotTicksUseless or 0))
            local fullPotential = (data.healed or 0) + (data.overhealed or 0)
            if totalHealEvents > 0 and fullPotential > 0 then
                local avgHeal = fullPotential / totalHealEvents
                imgui.Text(formatK(avgHeal))
            else
                imgui.TextDisabled('-')
            end

            -- Max heal
            imgui.TableNextColumn()
            if (data.maxHeal or 0) > 0 then
                imgui.Text(formatK(data.maxHeal))
            else
                imgui.TextDisabled('-')
            end

            -- Crit rate
            imgui.TableNextColumn()
            local totalCastEvents = (data.casts or 0) + (data.hotTicks or 0)
            if totalCastEvents > 0 and (data.critCount or 0) > 0 then
                local critPct = (data.critCount / totalCastEvents) * 100
                if critPct >= 50 then
                    imgui.TextColored(0.3, 0.9, 0.3, 1.0, string.format('%.0f%%', critPct))
                elseif critPct >= 25 then
                    imgui.TextColored(0.9, 0.9, 0.3, 1.0, string.format('%.0f%%', critPct))
                else
                    imgui.Text(string.format('%.0f%%', critPct))
                end
            else
                imgui.TextDisabled('-')
            end

            imgui.TableNextColumn()
            imgui.Text(formatK(data.healed or 0))

            imgui.TableNextColumn()
            local overhealPct = (data.healed or 0) > 0 and ((data.overhealed or 0) / data.healed * 100) or 0
            if overhealPct > 30 then
                imgui.TextColored(0.9, 0.3, 0.3, 1.0, formatK(data.overhealed or 0))
            elseif overhealPct > 15 then
                imgui.TextColored(0.9, 0.9, 0.3, 1.0, formatK(data.overhealed or 0))
            else
                imgui.Text(formatK(data.overhealed or 0))
            end

            imgui.TableNextColumn()
            if (data.ducked or 0) > 0 then
                imgui.TextColored(0.3, 0.9, 0.3, 1.0, tostring(data.ducked))
            else
                imgui.Text('0')
            end

            imgui.TableNextColumn()
            local hotTicks = data.hotTicks or 0
            local hotUseless = data.hotTicksUseless or 0
            local hotMissed = data.hotTicksMissed or 0
            local hotTotal = hotTicks + hotMissed
            local hotUseful = hotTicks - hotUseless
            if hotTotal > 0 then
                local wasted = hotUseless + hotMissed
                if wasted > 0 then
                    -- Format: useful/total (wasted)
                    imgui.TextColored(0.9, 0.7, 0.3, 1.0, string.format('%d/%d', hotUseful, hotTotal))
                    if imgui.IsItemHovered() then
                        imgui.SetTooltip(string.format('%d useful, %d useless ticks, %d missed (target at full)', hotUseful, hotUseless, hotMissed))
                    end
                else
                    imgui.Text(tostring(hotTicks))
                end
            else
                imgui.TextDisabled('-')
            end
        end

        imgui.EndTable()
    end
end

-- Draw the Learned Data tab (persisted heal tracking data)
local function DrawLearnedDataTab()
    if not HealTracker then
        imgui.TextDisabled('HealTracker not available')
        return
    end

    local allData = HealTracker.GetAllData and HealTracker.GetAllData() or {}
    local aaData = HealTracker.GetAAModifiers and HealTracker.GetAAModifiers() or {}

    -- AA info
    imgui.Text('AA Modifiers:')
    imgui.SameLine()
    imgui.TextColored(0.5, 0.8, 1.0, 1.0, string.format('Crit %.0f%% | Direct +%.0f%% | HoT +%.0f%%',
        (aaData.critPct or 0),
        (aaData.directHealBonusPct or 0),
        (aaData.hotBonusPct or 0)))

    imgui.Separator()

    -- Count entries
    local count = 0
    for _ in pairs(allData) do count = count + 1 end

    if count == 0 then
        imgui.TextDisabled('No learned heal data yet.')
        imgui.TextDisabled('Cast some heals to start learning!')
        return
    end

    imgui.Text(string.format('Learned Spells: %d', count))

    -- Reset all button
    imgui.SameLine()
    imgui.PushStyleColor(ImGuiCol.Button, 0.6, 0.2, 0.2, 1.0)
    if imgui.SmallButton('Reset All') then
        if HealTracker.Reset then
            HealTracker.Reset()
        end
    end
    imgui.PopStyleColor()
    if imgui.IsItemHovered() then
        imgui.SetTooltip('Clear all learned heal data and start fresh')
    end

    imgui.Separator()

    -- Learned data table
    local tableFlags = bit32.bor(ImGuiTableFlags.Borders, ImGuiTableFlags.RowBg, ImGuiTableFlags.Resizable, ImGuiTableFlags.ScrollY)
    if imgui.BeginTable('LearnedDataTable', 8, tableFlags, 0, 300) then
        imgui.TableSetupColumn('Spell', ImGuiTableColumnFlags.WidthStretch)
        imgui.TableSetupColumn('Samples', ImGuiTableColumnFlags.WidthFixed, 50)
        imgui.TableSetupColumn('Expected', ImGuiTableColumnFlags.WidthFixed, 55)
        imgui.TableSetupColumn('Base', ImGuiTableColumnFlags.WidthFixed, 50)
        imgui.TableSetupColumn('Crit', ImGuiTableColumnFlags.WidthFixed, 50)
        imgui.TableSetupColumn('Crit%', ImGuiTableColumnFlags.WidthFixed, 40)
        imgui.TableSetupColumn('Type', ImGuiTableColumnFlags.WidthFixed, 35)
        imgui.TableSetupColumn('', ImGuiTableColumnFlags.WidthFixed, 35)  -- Reset button
        imgui.TableHeadersRow()

        -- Sort by spell name
        local sortedSpells = {}
        for spellName, data in pairs(allData) do
            table.insert(sortedSpells, { name = spellName, data = data })
        end
        table.sort(sortedSpells, function(a, b) return a.name < b.name end)

        for _, entry in ipairs(sortedSpells) do
            local spellName = entry.name
            local data = entry.data

            imgui.TableNextRow()

            -- Spell name
            imgui.TableNextColumn()
            local displayName = spellName
            if #displayName > 20 then
                displayName = displayName:sub(1, 17) .. '...'
            end

            -- Check for corrupted data (critAvg < baseAvg)
            local isCorrupted = data.critAvg and data.baseAvg and data.critAvg > 0 and data.baseAvg > 0 and data.critAvg < data.baseAvg
            if isCorrupted then
                imgui.TextColored(1.0, 0.5, 0.2, 1.0, displayName)
            else
                imgui.Text(displayName)
            end
            if imgui.IsItemHovered() then
                imgui.BeginTooltip()
                imgui.Text(spellName)
                if isCorrupted then
                    imgui.Separator()
                    imgui.TextColored(1.0, 0.3, 0.3, 1.0, 'WARNING: Corrupted data!')
                    imgui.TextColored(1.0, 0.5, 0.3, 1.0, 'critAvg < baseAvg (should be opposite)')
                    imgui.TextColored(0.8, 0.8, 0.3, 1.0, 'Click Reset to fix')
                end
                imgui.EndTooltip()
            end

            -- Sample count
            imgui.TableNextColumn()
            local samples = (data.baseCount or 0) + (data.critCount or 0)
            if samples >= 10 then
                imgui.TextColored(0.3, 0.9, 0.3, 1.0, tostring(samples))
            elseif samples >= 5 then
                imgui.TextColored(0.9, 0.9, 0.3, 1.0, tostring(samples))
            else
                imgui.TextColored(0.9, 0.5, 0.3, 1.0, tostring(samples))
            end

            -- Expected heal
            imgui.TableNextColumn()
            local expected = HealTracker.GetExpectedHeal and HealTracker.GetExpectedHeal(spellName) or 0
            if expected and expected > 0 then
                if isCorrupted then
                    imgui.TextColored(1.0, 0.5, 0.2, 1.0, formatK(expected))
                else
                    imgui.Text(formatK(expected))
                end
            else
                imgui.TextDisabled('-')
            end

            -- Base avg
            imgui.TableNextColumn()
            if data.baseAvg and data.baseAvg > 0 then
                imgui.Text(formatK(data.baseAvg))
            else
                imgui.TextDisabled('-')
            end

            -- Crit avg
            imgui.TableNextColumn()
            if data.critAvg and data.critAvg > 0 then
                if isCorrupted then
                    imgui.TextColored(1.0, 0.3, 0.3, 1.0, formatK(data.critAvg))
                else
                    imgui.Text(formatK(data.critAvg))
                end
            else
                imgui.TextDisabled('-')
            end

            -- Empirical crit rate
            imgui.TableNextColumn()
            if samples > 0 and (data.critCount or 0) > 0 then
                local critPct = (data.critCount / samples) * 100
                imgui.Text(string.format('%.0f%%', critPct))
            else
                imgui.TextDisabled('-')
            end

            -- Type (HoT or Direct)
            imgui.TableNextColumn()
            if data.isHoT then
                imgui.TextColored(0.3, 0.8, 0.9, 1.0, 'HoT')
            else
                imgui.Text('Dir')
            end

            -- Reset button
            imgui.TableNextColumn()
            imgui.PushID(spellName)
            if imgui.SmallButton('X') then
                if HealTracker.ResetSpell then
                    HealTracker.ResetSpell(spellName)
                end
            end
            imgui.PopID()
            if imgui.IsItemHovered() then
                imgui.SetTooltip('Reset learned data for ' .. spellName)
            end
        end

        imgui.EndTable()
    end

    -- Legend
    imgui.Separator()
    imgui.TextDisabled('Legend:')
    imgui.SameLine()
    imgui.TextColored(1.0, 0.5, 0.2, 1.0, 'Orange')
    imgui.SameLine()
    imgui.TextDisabled('= corrupted data (critAvg < baseAvg), click X to reset')
end

-- Draw the Analytics tab
local function DrawAnalyticsTab()
    if not Analytics then
        imgui.TextDisabled('Analytics not available')
        return
    end

    local stats = Analytics.getStats()
    local duration = Analytics.getSessionDuration() or 0

    -- Duration
    imgui.Text('Session Duration:')
    imgui.SameLine()
    imgui.TextColored(0.5, 0.8, 1.0, 1.0, formatDuration(duration))

    imgui.Separator()

    -- Two-column layout for stats
    if imgui.BeginTable('AnalyticsTable', 2, ImGuiTableFlags.None) then
        imgui.TableNextRow()
        imgui.TableNextColumn()
        imgui.Text('Total Casts:')
        imgui.TableNextColumn()
        imgui.Text(tostring(stats.totalCasts or 0))

        imgui.TableNextRow()
        imgui.TableNextColumn()
        imgui.Text('Completed:')
        imgui.TableNextColumn()
        imgui.Text(tostring(stats.completedCasts or 0))

        imgui.TableNextRow()
        imgui.TableNextColumn()
        imgui.Text('Ducked:')
        imgui.TableNextColumn()
        local duckedPct = (stats.totalCasts or 0) > 0 and ((stats.duckedCasts or 0) / stats.totalCasts * 100) or 0
        if (stats.duckedCasts or 0) > 0 then
            imgui.TextColored(0.3, 0.9, 0.3, 1.0, string.format('%d (%.0f%%)', stats.duckedCasts or 0, duckedPct))
        else
            imgui.Text('0')
        end

        imgui.TableNextRow()
        imgui.TableNextColumn()
        imgui.Text('Total Healing:')
        imgui.TableNextColumn()
        imgui.Text(formatK(stats.totalHealed or 0))

        imgui.TableNextRow()
        imgui.TableNextColumn()
        imgui.Text('Overheal:')
        imgui.TableNextColumn()
        local overhealPct = stats.overHealPct or 0
        if overhealPct > 30 then
            imgui.TextColored(0.9, 0.3, 0.3, 1.0, string.format('%s (%.1f%%)', formatK(stats.totalOverheal or 0), overhealPct))
        elseif overhealPct > 15 then
            imgui.TextColored(0.9, 0.9, 0.3, 1.0, string.format('%s (%.1f%%)', formatK(stats.totalOverheal or 0), overhealPct))
        else
            imgui.TextColored(0.3, 0.9, 0.3, 1.0, string.format('%s (%.1f%%)', formatK(stats.totalOverheal or 0), overhealPct))
        end

        -- HoT ticks
        imgui.TableNextRow()
        imgui.TableNextColumn()
        imgui.Text('HoT Ticks:')
        imgui.TableNextColumn()
        local hotLanded = stats.hotTicksLanded or 0
        local hotUseless = stats.hotTicksUseless or 0
        local hotMissed = stats.hotTicksMissed or 0
        local hotTotal = hotLanded + hotMissed
        local hotUseful = hotLanded - hotUseless
        if hotTotal > 0 then
            local hotUsefulPct = (hotUseful / hotTotal) * 100
            local wasted = hotUseless + hotMissed
            local display = string.format('%d/%d useful', hotUseful, hotTotal)
            if hotUsefulPct < 70 then
                imgui.TextColored(0.9, 0.5, 0.3, 1.0, display)
            else
                imgui.Text(display)
            end
            if imgui.IsItemHovered() then
                imgui.SetTooltip(string.format('%d landed, %d useless, %d missed (target at full)', hotLanded, hotUseless, hotMissed))
            end
        else
            imgui.TextDisabled('0')
        end

        imgui.EndTable()
    end

    -- Efficiency bar
    imgui.Separator()
    imgui.Text('Efficiency:')
    local efficiency = (Analytics.getEfficiencyPct() or 100) / 100
    local effR, effG, effB = 0.3, 0.9, 0.3
    if efficiency < 0.7 then
        effR, effG, effB = 0.9, 0.3, 0.3
    elseif efficiency < 0.85 then
        effR, effG, effB = 0.9, 0.9, 0.3
    end
    imgui.PushStyleColor(ImGuiCol.PlotHistogram, effR, effG, effB, 1.0)
    imgui.ProgressBar(efficiency, -1, 20, string.format('%.1f%%', Analytics.getEfficiencyPct() or 100))
    imgui.PopStyleColor()

    imgui.Separator()

    -- Per-spell efficiency
    imgui.Text('Spell Efficiency:')
    local bySpell = stats.bySpell or {}
    local spellList = {}
    for name, data in pairs(bySpell) do
        if (data.casts or 0) > 0 then
            local healed = data.healed or 0
            local overhealed = data.overhealed or 0
            local potential = healed + overhealed
            local spellEff = potential > 0 and (healed / potential * 100) or 100
            table.insert(spellList, {
                name = name,
                casts = data.casts or 0,
                healed = healed,
                overhealed = overhealed,
                potential = potential,
                efficiency = spellEff,
                manaSpent = data.manaSpent or 0,
            })
        end
    end

    -- Sort by total healed descending
    table.sort(spellList, function(a, b) return a.healed > b.healed end)

    if #spellList == 0 then
        imgui.TextDisabled('No spell data yet')
    else
        for _, spell in ipairs(spellList) do
            -- Spell name (truncated)
            local displayName = spell.name
            if #displayName > 20 then
                displayName = displayName:sub(1, 17) .. '...'
            end

            -- Color based on efficiency
            local spellEff = spell.efficiency / 100
            local sR, sG, sB = 0.3, 0.9, 0.3
            if spellEff < 0.7 then
                sR, sG, sB = 0.9, 0.3, 0.3
            elseif spellEff < 0.85 then
                sR, sG, sB = 0.9, 0.9, 0.3
            end

            imgui.Text(displayName)
            imgui.SameLine(140)
            imgui.PushStyleColor(ImGuiCol.PlotHistogram, sR, sG, sB, 1.0)
            imgui.ProgressBar(spellEff, 100, 14, string.format('%.0f%%', spell.efficiency))
            imgui.PopStyleColor()

            -- Tooltip with details
            if imgui.IsItemHovered() then
                imgui.BeginTooltip()
                imgui.Text(spell.name)
                imgui.Separator()
                imgui.Text(string.format('Efficiency: %.1f%%', spell.efficiency))
                imgui.Text(string.format('Actual: %s  Potential: %s', formatK(spell.healed), formatK(spell.potential)))
                imgui.Text(string.format('Overheal: %s (%.1f%%)', formatK(spell.overhealed), spell.potential > 0 and (spell.overhealed / spell.potential * 100) or 0))
                imgui.Text(string.format('Casts: %d', spell.casts))
                if spell.manaSpent > 0 then
                    local hpm = spell.healed / spell.manaSpent
                    imgui.Text(string.format('Healing/Mana: %.1f', hpm))
                end
                imgui.EndTooltip()
            end

            imgui.SameLine()
            imgui.TextDisabled(string.format('%s/%s (%d)', formatK(spell.healed), formatK(spell.potential), spell.casts))
        end
    end

    imgui.Separator()

    -- Mana efficiency
    imgui.Text('Mana Efficiency:')
    local totalMana = stats.totalManaSpent or 0
    local totalHealed = stats.totalHealed or 0
    local totalOverheal = stats.totalOverheal or 0

    if totalMana > 0 then
        local actualHPM = totalHealed / totalMana
        local potentialHPM = (totalHealed + totalOverheal) / totalMana
        local wastedMana = totalOverheal > 0 and (totalOverheal / potentialHPM) or 0
        local manaEffPct = totalHealed / (totalHealed + totalOverheal) * 100

        -- Mana efficiency bar
        local manaEff = manaEffPct / 100
        local mR, mG, mB = 0.3, 0.9, 0.3
        if manaEff < 0.7 then
            mR, mG, mB = 0.9, 0.3, 0.3
        elseif manaEff < 0.85 then
            mR, mG, mB = 0.9, 0.9, 0.3
        end
        imgui.PushStyleColor(ImGuiCol.PlotHistogram, mR, mG, mB, 1.0)
        imgui.ProgressBar(manaEff, -1, 16, string.format('%.0f%% Mana Eff', manaEffPct))
        imgui.PopStyleColor()

        if imgui.BeginTable('ManaTable', 2, ImGuiTableFlags.None) then
            imgui.TableNextRow()
            imgui.TableNextColumn()
            imgui.Text('Healing/Mana:')
            imgui.TableNextColumn()
            imgui.Text(string.format('%.1f HPM', actualHPM))

            imgui.TableNextRow()
            imgui.TableNextColumn()
            imgui.Text('Potential HPM:')
            imgui.TableNextColumn()
            imgui.TextDisabled(string.format('%.1f (if no overheal)', potentialHPM))

            imgui.TableNextRow()
            imgui.TableNextColumn()
            imgui.Text('Mana Spent:')
            imgui.TableNextColumn()
            imgui.Text(formatK(totalMana))

            imgui.TableNextRow()
            imgui.TableNextColumn()
            imgui.Text('Mana Wasted:')
            imgui.TableNextColumn()
            if wastedMana > 1000 then
                imgui.TextColored(0.9, 0.5, 0.3, 1.0, formatK(wastedMana))
            else
                imgui.Text(formatK(wastedMana))
            end

            imgui.TableNextRow()
            imgui.TableNextColumn()
            imgui.Text('Duck Savings:')
            imgui.TableNextColumn()
            local savings = stats.duckSavingsEstimate or 0
            if savings > 0 then
                imgui.TextColored(0.3, 0.9, 0.3, 1.0, string.format('~%s', formatK(savings)))
            else
                imgui.Text('0')
            end

            imgui.EndTable()
        end
    else
        imgui.TextDisabled('No mana data yet')
    end

    imgui.Separator()

    -- Coordination stats
    imgui.Text('Coordination:')
    if imgui.BeginTable('CoordTable', 2, ImGuiTableFlags.None) then
        imgui.TableNextRow()
        imgui.TableNextColumn()
        imgui.Text('Incoming Honored:')
        imgui.TableNextColumn()
        imgui.Text(tostring(stats.incomingHealHonored or 0))

        imgui.TableNextRow()
        imgui.TableNextColumn()
        imgui.Text('Incoming Expired:')
        imgui.TableNextColumn()
        local expired = stats.incomingHealExpired or 0
        if expired > 0 then
            imgui.TextColored(0.9, 0.9, 0.3, 1.0, tostring(expired))
        else
            imgui.Text('0')
        end

        imgui.EndTable()
    end

    -- Heals per minute
    local healsPerMin = duration > 0 and ((stats.completedCasts or 0) / (duration / 60)) or 0
    imgui.Separator()
    imgui.Text(string.format('Heals/Min: %.1f', healsPerMin))
end

-- Draw compact mode
local function DrawCompact()
    -- Combat state
    local state = CombatAssessor and CombatAssessor.getState() or {}
    if state.survivalMode then
        imgui.TextColored(1.0, 0.3, 0.3, 1.0, 'SURVIVAL')
    elseif state.inCombat then
        imgui.TextColored(0.9, 0.9, 0.1, 1.0, 'ACTIVE')
    else
        imgui.TextColored(0.1, 0.9, 0.1, 1.0, 'IDLE')
    end

    imgui.SameLine()

    -- Last action (compact)
    local lastAction = HealSelector and HealSelector.getLastAction and HealSelector.getLastAction()
    if lastAction then
        if type(lastAction) == 'string' then
            imgui.TextDisabled(string.format('| %s', lastAction))
        elseif type(lastAction) == 'table' then
            imgui.TextDisabled(string.format('| %s', lastAction.spell or ''))
        end
    end

    -- Priority targets with HP bars
    if TargetMonitor then
        local ok, injured = pcall(function() return TargetMonitor.getInjuredTargets(80) end)
        if ok and injured then
            local maxShow = math.min(#injured, 4)
            for i = 1, maxShow do
                local target = injured[i]
                local pctHP = target.pctHP or 100
                local r, g, b, a = getHPColor(pctHP)

                local roleIcon = target.role == 'tank' and '[T]' or (target.role == 'healer' and '[H]' or '')
                local name = (target.name or 'Unknown')
                if #name > 10 then name = name:sub(1, 10) end

                imgui.Text(string.format('%s %s', roleIcon, name))
                imgui.SameLine()
                imgui.PushStyleColor(ImGuiCol.PlotHistogram, r, g, b, a)
                imgui.ProgressBar(pctHP / 100, 80, 12, string.format('%d%%', pctHP))
                imgui.PopStyleColor()
            end

            if #injured == 0 then
                imgui.TextDisabled('No priority targets')
            end
        end
    end
end

--- Draw the content without window wrapper (for embedding as a tab)
--- @return boolean True if initialized and content was drawn
function M.drawContent()
    -- Check if we have the required dependencies
    if not TargetMonitor and not CombatAssessor and not HealSelector then
        imgui.TextDisabled('Healing monitor not initialized')
        imgui.TextDisabled('(Only available for CLR class)')
        return false
    end

    -- Tab bar (nested tabs within the Healing tab)
        if imgui.BeginTabBar('HealingMonitorTabs##Embedded') then
            if imgui.BeginTabItem('Status') then
                _currentTab = 'status'
                DrawStatusTab()
                imgui.EndTabItem()
            end

            if imgui.BeginTabItem('Heal Data') then
                _currentTab = 'healdata'
                DrawHealDataTab()
                imgui.EndTabItem()
            end

            if imgui.BeginTabItem('Learned') then
                _currentTab = 'learned'
                DrawLearnedDataTab()
                imgui.EndTabItem()
            end

            if imgui.BeginTabItem('Analytics') then
                _currentTab = 'analytics'
                DrawAnalyticsTab()
                imgui.EndTabItem()
            end

            if imgui.BeginTabItem('Named Mobs') then
                _currentTab = 'namedmobs'
                if MobAssessor and MobAssessor.drawTab then
                    MobAssessor.drawTab()
                else
                    imgui.TextDisabled('MobAssessor not available')
                end
                imgui.EndTabItem()
            end

            imgui.EndTabBar()
        end

    return true
end

--- Check if the monitor has been initialized with dependencies
function M.isInitialized()
    return TargetMonitor ~= nil or CombatAssessor ~= nil or HealSelector ~= nil
end

function M.draw()
    if not _open then return end

    local okCore, Core = pcall(require, 'sidekick-next.utils.core')
    local settings = (okCore and Core and Core.Settings) or {}
    local mainAnchor = tostring(settings.SideKickMainAnchor or 'none'):lower()
    local mainAnchorTarget = Anchor and Anchor.normalizeTargetKey and Anchor.normalizeTargetKey(settings.SideKickMainAnchorTarget or 'grouptarget')
        or tostring(settings.SideKickMainAnchorTarget or 'grouptarget'):lower()
    local anchorGap = tonumber(settings.SideKickMainAnchorGap) or 2
    local matchGTW = settings.SideKickMainMatchGTWidth == true

    local estW = tonumber(_lastSize.w) or 450
    local estH = tonumber(_lastSize.h) or 400

    if matchGTW and tostring(mainAnchorTarget or '') == 'grouptarget' then
        local gt = Anchor and Anchor.getTargetBounds and Anchor.getTargetBounds('grouptarget') or _G.GroupTargetBounds
        local gtW = gt and tonumber(gt.width) or nil
        if gtW and gtW > 50 and imgui.SetNextWindowSizeConstraints then
            imgui.SetNextWindowSizeConstraints(gtW, 10, gtW, 10000)
            estW = gtW
        end
    end

    local anchorX, anchorY = nil, nil
    if Anchor and Anchor.getAnchorPos then
        anchorX, anchorY = Anchor.getAnchorPos(mainAnchorTarget, mainAnchor, estW, estH, anchorGap)
    end
    if anchorX and anchorY and imgui.SetNextWindowPos then
        imgui.SetNextWindowPos(anchorX, anchorY, (ImGuiCond and ImGuiCond.Always) or 0)
    end

    imgui.SetNextWindowSize(estW, estH, ImGuiCond.FirstUseEver)

    _open, _draw = imgui.Begin('Healing Monitor##HealMon', _open)
    if _draw then
        local w, h = vec2xy(imgui.GetWindowSize())
        if w and h and w > 0 and h > 0 then
            _lastSize.w = w
            _lastSize.h = h
        end
        if Anchor and Anchor.updateWindowBounds then
            Anchor.updateWindowBounds('sidekick_heal', imgui)
        end

        -- Use the shared drawContent function
        M.drawContent()
    end
    imgui.End()
end

return M
