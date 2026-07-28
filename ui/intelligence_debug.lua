-- DPS / Resist Intelligence diagnostics.
--
-- Live target decisions arrive from the coordinated sk_dps worker. Larger,
-- persistent learning stores are loaded on the main coroutine and cached for
-- ImGui so drawing this tab never performs file I/O or actor sends.

local mq = require('mq')
local imgui = require('ImGui')
local lazy = require('sidekick-next.utils.lazy_require')
local lib = require('sidekick-next.sk_lib')

local M = {}

local Mods = {
    Actors = lazy('sidekick-next.utils.actors_coordinator'),
    Core = lazy('sidekick-next.utils.core'),
    Dps = lazy('sidekick-next.utils.dps_intelligence'),
    MobHp = lazy('sidekick-next.utils.mob_hp_estimator'),
    MobIntel = lazy('sidekick-next.utils.mob_intel'),
    Paths = lazy('sidekick-next.utils.paths'),
    ResistLog = lazy('sidekick-next.utils.resist_log'),
    ResistTracker = lazy('sidekick-next.utils.resist_tracker'),
    SpellDamage = lazy('sidekick-next.utils.spell_damage_tracker'),
}

local State = {
    initialized = false,
    telemetry = nil,
    telemetryReceivedAt = 0,
    refreshRequested = false,
    lastRefreshAt = 0,
    lastZoneCheckAt = 0,
    lastDrawAt = 0,
    refreshError = nil,
    zone = '',
    zoneRows = {},
    zoneByName = {},
}

local DISK_REFRESH_MS = 30000
local TELEMETRY_STALE_MS = 3500
local ELEMENT_ORDER = {
    magic = 1, fire = 2, cold = 3, poison = 4, disease = 5,
    chromatic = 6, prismatic = 7, physical = 8,
}
local CC_TYPES = { 'slow', 'snare', 'mez', 'charm', 'root', 'stun', 'fear' }

local function sortedKeys(t)
    local keys = {}
    for key in pairs(type(t) == 'table' and t or {}) do
        keys[#keys + 1] = key
    end
    table.sort(keys, function(a, b)
        return tostring(a):lower() < tostring(b):lower()
    end)
    return keys
end

local function commaNumber(value)
    local n = tonumber(value)
    if not n then return 'unknown' end
    local rounded = math.floor(n + 0.5)
    local sign = rounded < 0 and '-' or ''
    local text = tostring(math.abs(rounded))
    while true do
        local changed
        text, changed = text:gsub('^(%d+)(%d%d%d)', '%1,%2')
        if changed == 0 then break end
    end
    return sign .. text
end

local function formatPct(value)
    local n = tonumber(value)
    return n and string.format('%.1f%%', n) or '-'
end

local function formatSeconds(value)
    local n = tonumber(value)
    return n and string.format('%.1fs', n) or 'unknown'
end

local function boolText(value)
    if value == nil then return 'unknown' end
    return value == true and 'YES' or 'no'
end

local function drawBool(value)
    if value == nil then
        imgui.TextDisabled('unknown')
    elseif value == true then
        imgui.TextColored(0.35, 1.0, 0.45, 1.0, 'YES')
    else
        imgui.TextColored(1.0, 0.55, 0.35, 1.0, 'no')
    end
end

local function drawKeyValue(label, value)
    imgui.TextDisabled(tostring(label))
    imgui.SameLine(190)
    imgui.TextWrapped(tostring(value))
end

local function settings()
    local Core = Mods.Core()
    return Core and Core.Settings or {}
end

local function currentZone()
    local ok, zone = pcall(function()
        return mq.TLO.Zone and mq.TLO.Zone.ShortName and mq.TLO.Zone.ShortName() or ''
    end)
    return ok and tostring(zone or '') or ''
end

local function telemetryFresh()
    return State.telemetry ~= nil
        and (mq.gettime() - State.telemetryReceivedAt) <= TELEMETRY_STALE_MS
end

local function currentTargetName()
    if telemetryFresh() and type(State.telemetry.target) == 'table' then
        return tostring(State.telemetry.target.name or '')
    end
    local ok, name = pcall(function()
        local target = mq.TLO.Target
        return target and target() and target.CleanName and target.CleanName() or ''
    end)
    return ok and tostring(name or '') or ''
end

local function summarizeClasses(classes)
    local result = sortedKeys(classes)
    return #result > 0 and table.concat(result, ', ') or '-'
end

local function ccStatus(data)
    if type(data) ~= 'table' then return 'unknown' end
    if data.immune == true then return 'immune' end
    if (tonumber(data.landed) or 0) > 0 then return 'lands' end
    if (tonumber(data.resisted) or 0) > 0 then return 'resists' end
    return 'unknown'
end

local function summarizeCC(cc)
    local result = {}
    for _, kind in ipairs(CC_TYPES) do
        local status = ccStatus(type(cc) == 'table' and cc[kind] or nil)
        if status ~= 'unknown' then result[#result + 1] = kind .. ':' .. status end
    end
    return #result > 0 and table.concat(result, '  ') or '-'
end

local function summarizeElements(elements)
    local result = {}
    for _, element in ipairs(sortedKeys(elements)) do
        local rec = elements[element]
        if type(rec) == 'table' then
            local landed = tonumber(rec.landed) or 0
            local resisted = tonumber(rec.resisted) or 0
            local samples = landed + resisted
            local rate = samples > 0 and (resisted / samples * 100) or nil
            local effCount = tonumber(rec.effCount) or 0
            local efficiency = effCount > 0
                and ((tonumber(rec.effSum) or 0) / effCount * 100) or nil
            local detail = element
            if rate then detail = detail .. string.format(' %.0f%%R', rate) end
            if efficiency then detail = detail .. string.format('/%.0f%%E', efficiency) end
            result[#result + 1] = detail
        end
    end
    return #result > 0 and table.concat(result, '  ') or '-'
end

local function summarizeNpcCasts(casts)
    local result = {}
    for _, spell in ipairs(sortedKeys(casts)) do
        result[#result + 1] = string.format('%s x%d', spell, tonumber(casts[spell]) or 0)
    end
    return #result > 0 and table.concat(result, ', ') or '-'
end

local function rebuildZoneCache()
    State.zone = currentZone()
    State.zoneRows = {}
    State.zoneByName = {}

    local MobIntel = Mods.MobIntel()
    if not MobIntel or not MobIntel.buildConsolidated then return end
    local ok, consolidated = pcall(MobIntel.buildConsolidated)
    if not ok or type(consolidated) ~= 'table' then
        State.refreshError = ok and 'invalid consolidated intelligence data' or tostring(consolidated)
        return
    end

    local zoneData = consolidated[State.zone] or {}
    State.zoneByName = zoneData
    for name, record in pairs(zoneData) do
        if type(record) == 'table' then
            State.zoneRows[#State.zoneRows + 1] = {
                name = tostring(name),
                level = tonumber(record.level),
                classes = summarizeClasses(record.classes),
                maxHp = tonumber(record.maxHP),
                hpWeight = tonumber(record.hpWeight) or 0,
                resists = summarizeElements(record.resists),
                cc = summarizeCC(record.cc),
                casts = summarizeNpcCasts(record.casts),
            }
        end
    end
    table.sort(State.zoneRows, function(a, b)
        return a.name:lower() < b.name:lower()
    end)
end

local function reloadPersistedData()
    State.refreshError = nil
    local coordinated = not (_G.SIDEKICK_NEXT_CONFIG
        and _G.SIDEKICK_NEXT_CONFIG.COORDINATED_MODE == false)

    -- In coordinated mode these are read-only mirrors of worker-owned files.
    -- Never reload them over live monolithic-process learning.
    if coordinated then
        local loaders = {
            { Mods.ResistTracker(), 'loadDatabase', 'loadZone' },
            { Mods.MobHp(), 'loadDatabase', 'loadZone' },
            { Mods.MobIntel(), 'loadDatabase', 'loadZone' },
            { Mods.SpellDamage(), 'load' },
            { Mods.ResistLog(), 'load' },
        }
        for _, spec in ipairs(loaders) do
            local module = spec[1]
            if module then
                for index = 2, #spec do
                    local fn = module[spec[index]]
                    if type(fn) == 'function' then
                        local ok, err = pcall(fn)
                        if not ok then
                            State.refreshError = string.format('%s: %s',
                                tostring(spec[index]), tostring(err))
                        end
                    end
                end
            end
        end
    end

    rebuildZoneCache()
    State.lastRefreshAt = mq.gettime()
    State.refreshRequested = false
end

function M.setTelemetry(content)
    if type(content) ~= 'table' then return end
    if content.spellDamage == nil and type(State.telemetry) == 'table' then
        content.spellDamage = State.telemetry.spellDamage
    end
    State.telemetry = content
    State.telemetryReceivedAt = mq.gettime()
end

function M.init()
    if State.initialized then return end
    State.initialized = true
    -- Resolve every diagnostics dependency from the normal Lua coroutine.
    -- The draw callback may inspect these caches but must never import modules.
    for _, getter in pairs(Mods) do
        if type(getter) == 'function' then pcall(getter) end
    end
    local Actors = Mods.Actors()
    if Actors and Actors.registerTelemetryCallback then
        Actors.registerTelemetryCallback('intel:telemetry', function(content, _, sender)
            local trusted = lib.actorSenderMatches(
                sender, 'sidekick-next/sk_dps', 'sidekick')
                or lib.actorSenderMatches(
                    sender, 'sidekick-next/sk_combat', 'sidekick')
            if not trusted then return end
            M.setTelemetry(content)
        end)
    end
end

function M.tick()
    M.init()
    local now = mq.gettime()
    if State.lastDrawAt <= 0 or (now - State.lastDrawAt) > 5000 then return end
    if not State.refreshRequested and (now - State.lastZoneCheckAt) < 1000 then return end
    State.lastZoneCheckAt = now
    if State.refreshRequested or (now - State.lastRefreshAt) >= DISK_REFRESH_MS
        or State.zone ~= currentZone() then
        reloadPersistedData()
    end
end

local function drawLiveTarget()
    local telemetry = telemetryFresh() and State.telemetry or nil
    if not telemetry then
        imgui.TextColored(1.0, 0.65, 0.25, 1.0,
            'No fresh sk_dps telemetry. Start/restart the DPS worker to see live decisions.')
        if State.telemetry then
            imgui.TextDisabled(string.format('Last snapshot %.1fs ago',
                (mq.gettime() - State.telemetryReceivedAt) / 1000))
        end
        return
    end

    local target = type(telemetry.target) == 'table' and telemetry.target or nil
    drawKeyValue('Worker snapshot age',
        string.format('%.2fs', (mq.gettime() - State.telemetryReceivedAt) / 1000))
    drawKeyValue('Damage observer', telemetry.observerScope ~= '' and telemetry.observerScope or 'unknown')
    drawKeyValue('DPS decision reason', telemetry.reason ~= '' and telemetry.reason or '-')
    if telemetry.action then
        drawKeyValue('Selected action', string.format('%s (gem %d, %s)',
            tostring(telemetry.action.spellName or '?'),
            tonumber(telemetry.action.slot) or 0,
            tostring(telemetry.action.spellType or '?')))
        drawKeyValue('Active spell set', tostring(telemetry.action.activeSet or '-'))
    else
        drawKeyValue('Selected action', 'none')
    end

    imgui.Separator()
    imgui.Text('Intelligence Modules')
    if imgui.BeginTable('##intel_modules', 2, 0) then
        imgui.TableSetupColumn('Module')
        imgui.TableSetupColumn('Loaded in DPS worker')
        imgui.TableHeadersRow()
        for _, key in ipairs({ 'dps', 'damageEvents', 'mobHp', 'spellDamage', 'resist' }) do
            imgui.TableNextRow()
            imgui.TableNextColumn(); imgui.Text(key)
            imgui.TableNextColumn(); drawBool(telemetry.modules and telemetry.modules[key])
        end
        imgui.EndTable()
    end

    imgui.Separator()
    imgui.Text('Current DPS Target')
    if not target then
        imgui.TextDisabled('No target selected by the DPS worker.')
        return
    end

    drawKeyValue('Target', string.format('%s (%d) via %s',
        tostring(target.name or '?'), tonumber(target.id) or 0, tostring(target.source or '?')))
    drawKeyValue('Target HP', formatPct(target.pctHp))
    drawKeyValue('Combat active', boolText(target.combatActive))
    drawKeyValue('Actor combat evidence', boolText(target.coordinatedCombat))
    drawKeyValue('Time to die', string.format('%s (%s)',
        formatSeconds(target.ttd), tostring(target.ttdSource or 'unknown')))
    drawKeyValue('Estimated max HP', commaNumber(target.maxHp))
    drawKeyValue('Estimated remaining HP', commaNumber(target.remainingHp))
    drawKeyValue('HP evidence weight', string.format('%.1f HP percentage-points observed',
        tonumber(target.hpWeight) or 0))

    imgui.Spacing()
    if imgui.BeginTable('##intel_viability', 2, 0) then
        imgui.TableSetupColumn('Decision gate')
        imgui.TableSetupColumn('Result')
        imgui.TableHeadersRow()
        local decisions = {
            { 'Default nuke can land', target.nukeViable },
            { 'Default DoT can pay off', target.dotViable },
            { 'Rain waves can pay off', target.rainViable },
            { 'Rain is mez-safe', target.rainSafe },
        }
        for _, row in ipairs(decisions) do
            imgui.TableNextRow()
            imgui.TableNextColumn(); imgui.Text(row[1])
            imgui.TableNextColumn(); drawBool(row[2])
        end
        imgui.EndTable()
    end

    imgui.Separator()
    imgui.Text('Spell Candidate Evaluation')
    local candidates = type(telemetry.candidates) == 'table' and telemetry.candidates or {}
    if #candidates == 0 then
        imgui.TextDisabled('No candidates were evaluated for this snapshot.')
    elseif imgui.BeginTable('##intel_candidates', 8, 0) then
        for _, heading in ipairs({
            'Gem', 'Spell', 'Type', 'Priority', 'Ready', 'Condition', 'Intelligence', 'Result',
        }) do
            imgui.TableSetupColumn(heading)
        end
        imgui.TableHeadersRow()
        for _, row in ipairs(candidates) do
            imgui.TableNextRow()
            imgui.TableNextColumn(); imgui.Text(tostring(row.slot or '-'))
            imgui.TableNextColumn(); imgui.Text(tostring(row.spellName or '?'))
            imgui.TableNextColumn(); imgui.Text(tostring(row.spellType or '?'))
            imgui.TableNextColumn(); imgui.Text(tostring(row.priority or '-'))
            imgui.TableNextColumn(); drawBool(row.ready)
            imgui.TableNextColumn(); drawBool(row.condition)
            imgui.TableNextColumn(); imgui.Text(tostring(
                row.intelligenceError and ('error: ' .. row.intelligenceError)
                or row.intelligence or '-'))
            imgui.TableNextColumn()
            if row.selected then
                imgui.TextColored(0.35, 1.0, 0.35, 1.0, 'selected')
            elseif row.allowed then
                imgui.TextColored(0.55, 0.85, 1.0, 1.0, tostring(row.reason or 'eligible'))
            else
                imgui.Text(tostring(row.reason or 'rejected'))
            end
        end
        imgui.EndTable()
    end
end

local function fallbackElementRows(targetName)
    local record = State.zoneByName[targetName]
    local result = {}
    local s = settings()
    for element, stats in pairs(record and record.resists or {}) do
        local landed = tonumber(stats.landed) or 0
        local resisted = tonumber(stats.resisted) or 0
        local samples = landed + resisted
        local effSamples = tonumber(stats.effCount) or 0
        local resistPct = samples > 0 and resisted / samples * 100 or nil
        local efficiencyPct = effSamples > 0
            and (tonumber(stats.effSum) or 0) / effSamples * 100 or nil
        local avoid = samples >= (tonumber(s.ResistMinSamples) or 4)
            and resistPct and resistPct >= (tonumber(s.ResistAvoidPct) or 50)
        avoid = avoid or (effSamples >= (tonumber(s.ResistMinSamples) or 4)
            and efficiencyPct and efficiencyPct <= (tonumber(s.ResistMinEfficiencyPct) or 35))
        result[#result + 1] = {
            element = tostring(element),
            landed = landed,
            resisted = resisted,
            samples = samples,
            resistPct = resistPct,
            efficiencyPct = efficiencyPct,
            efficiencySamples = effSamples,
            avoid = avoid == true,
        }
    end
    return result
end

local function sortElementRows(rows)
    table.sort(rows, function(a, b)
        local aName, bName = tostring(a.element or ''), tostring(b.element or '')
        local aOrder = ELEMENT_ORDER[aName:lower()] or 100
        local bOrder = ELEMENT_ORDER[bName:lower()] or 100
        if aOrder ~= bOrder then return aOrder < bOrder end
        return aName:lower() < bName:lower()
    end)
end

local function fallbackSpellResists(targetName)
    local result = {}
    local ResistLog = Mods.ResistLog()
    if not ResistLog or not ResistLog.iterZone then return result end
    for mob, spell, record in ResistLog.iterZone() do
        if tostring(mob):lower() == tostring(targetName):lower() then
            local skip, reason = false, nil
            if ResistLog.shouldSkip then skip, reason = ResistLog.shouldSkip(spell, targetName) end
            local consecutive = 0
            if ResistLog.getConsecutiveResists then
                consecutive = tonumber(ResistLog.getConsecutiveResists(nil, targetName, spell)) or 0
            end
            result[#result + 1] = {
                spellName = tostring(spell),
                casts = tonumber(record and record.casts) or 0,
                resists = tonumber(record and record.resists) or 0,
                lastResistAt = tonumber(record and record.lastResistAt) or 0,
                consecutiveResists = consecutive,
                skip = skip == true,
                skipReason = tostring(reason or ''),
            }
        end
    end
    return result
end

local function drawResists()
    local targetName = currentTargetName()
    if targetName == '' then
        imgui.TextDisabled('No current DPS target.')
        return
    end
    drawKeyValue('Mob', targetName)

    local telemetry = telemetryFresh() and State.telemetry or nil
    local elementRows = telemetry and telemetry.elementResists or fallbackElementRows(targetName)
    elementRows = type(elementRows) == 'table' and elementRows or {}
    sortElementRows(elementRows)

    imgui.Text('Per-Element Learning')
    if #elementRows == 0 then
        imgui.TextDisabled('No landed/resisted or partial-resist samples for this mob.')
    elseif imgui.BeginTable('##intel_element_resists', 7, 0) then
        for _, label in ipairs({
            'Element', 'Landed', 'Resisted', 'Full Resist', 'Efficiency',
            'Eff Samples', 'Decision',
        }) do imgui.TableSetupColumn(label) end
        imgui.TableHeadersRow()
        for _, row in ipairs(elementRows) do
            imgui.TableNextRow()
            imgui.TableNextColumn(); imgui.Text(tostring(row.element or '?'))
            imgui.TableNextColumn(); imgui.Text(tostring(row.landed or 0))
            imgui.TableNextColumn(); imgui.Text(tostring(row.resisted or 0))
            imgui.TableNextColumn(); imgui.Text(formatPct(row.resistPct))
            imgui.TableNextColumn(); imgui.Text(formatPct(row.efficiencyPct))
            imgui.TableNextColumn(); imgui.Text(tostring(row.efficiencySamples or 0))
            imgui.TableNextColumn()
            if row.avoid then
                imgui.TextColored(1.0, 0.4, 0.3, 1.0, 'AVOID')
            else
                imgui.TextColored(0.4, 1.0, 0.5, 1.0, 'allowed')
            end
        end
        imgui.EndTable()
    end

    imgui.Separator()
    imgui.Text('Per-Spell Adaptive Resist Log')
    local spellRows = telemetry and telemetry.spellResists or fallbackSpellResists(targetName)
    spellRows = type(spellRows) == 'table' and spellRows or {}
    table.sort(spellRows, function(a, b)
        return tostring(a.spellName or ''):lower() < tostring(b.spellName or ''):lower()
    end)
    if #spellRows == 0 then
        imgui.TextDisabled('No spell-specific history for this mob.')
    elseif imgui.BeginTable('##intel_spell_resists', 7, 0) then
        for _, label in ipairs({
            'Spell', 'Casts', 'Resists', 'Streak', 'Rate', 'Last Resist', 'Decision',
        }) do
            imgui.TableSetupColumn(label)
        end
        imgui.TableHeadersRow()
        for _, row in ipairs(spellRows) do
            local casts = tonumber(row.casts) or 0
            local resists = tonumber(row.resists) or 0
            imgui.TableNextRow()
            imgui.TableNextColumn(); imgui.Text(tostring(row.spellName or '?'))
            imgui.TableNextColumn(); imgui.Text(tostring(casts))
            imgui.TableNextColumn(); imgui.Text(tostring(resists))
            imgui.TableNextColumn(); imgui.Text(tostring(row.consecutiveResists or 0))
            imgui.TableNextColumn(); imgui.Text(casts > 0 and formatPct(resists / casts * 100) or '-')
            imgui.TableNextColumn()
            imgui.Text(row.lastResistAt and row.lastResistAt > 0
                and os.date('%H:%M:%S', row.lastResistAt) or '-')
            imgui.TableNextColumn()
            if row.skip then
                imgui.TextColored(1.0, 0.4, 0.3, 1.0,
                    row.skipReason ~= '' and row.skipReason or 'SKIP')
            else
                imgui.TextDisabled('-')
            end
        end
        imgui.EndTable()
    end

    local mob = State.zoneByName[targetName]
    imgui.Separator()
    imgui.Text('CC Susceptibility')
    if imgui.BeginTable('##intel_cc', 5, 0) then
        for _, label in ipairs({ 'Type', 'Status', 'Landed', 'Resisted', 'Immune' }) do
            imgui.TableSetupColumn(label)
        end
        imgui.TableHeadersRow()
        for _, kind in ipairs(CC_TYPES) do
            local rec = mob and mob.cc and mob.cc[kind] or nil
            imgui.TableNextRow()
            imgui.TableNextColumn(); imgui.Text(kind)
            imgui.TableNextColumn(); imgui.Text(ccStatus(rec))
            imgui.TableNextColumn(); imgui.Text(tostring(rec and rec.landed or 0))
            imgui.TableNextColumn(); imgui.Text(tostring(rec and rec.resisted or 0))
            imgui.TableNextColumn(); drawBool(rec and rec.immune)
        end
        imgui.EndTable()
    end

    imgui.Text('Observed NPC Spells')
    if not mob or not mob.casts or next(mob.casts) == nil then
        imgui.TextDisabled('None observed.')
    else
        for _, spell in ipairs(sortedKeys(mob.casts)) do
            imgui.BulletText(string.format('%s (seen %d)', spell, tonumber(mob.casts[spell]) or 0))
        end
    end
end

local function drawDamageLearning()
    local telemetry = telemetryFresh() and State.telemetry or nil
    local rows = telemetry and telemetry.spellDamage or nil
    if type(rows) ~= 'table' then
        rows = {}
        local SpellDamage = Mods.SpellDamage()
        for name, record in pairs(SpellDamage and SpellDamage.data or {}) do
            rows[#rows + 1] = {
                spellName = tostring(name),
                count = tonumber(record.count) or 0,
                expected = tonumber(record.ema) or 0,
                maxSeen = tonumber(record.maxSeen) or 0,
                baseline = SpellDamage.getBaseline and SpellDamage.getBaseline(name) or nil,
            }
        end
    end
    table.sort(rows, function(a, b)
        return tostring(a.spellName or ''):lower() < tostring(b.spellName or ''):lower()
    end)

    local target = telemetry and telemetry.target or nil
    if target then
        drawKeyValue('Target', tostring(target.name or '?'))
        drawKeyValue('Estimated max HP', commaNumber(target.maxHp))
        drawKeyValue('Estimated remaining HP', commaNumber(target.remainingHp))
        drawKeyValue('HP evidence weight', string.format('%.1f HP percentage-points observed',
            tonumber(target.hpWeight) or 0))
        drawKeyValue('Overkill allowance', string.format('expected hit <= remaining HP x %.2f',
            tonumber(settings().DpsOverkillFactor) or 1.5))
        imgui.Separator()
    end

    imgui.Text('Learned Spell Damage')
    if #rows == 0 then
        imgui.TextDisabled('No direct-damage samples learned yet.')
        local diagnostics = telemetry and telemetry.spellDamageDiagnostics or nil
        if type(diagnostics) == 'table' then
            drawKeyValue('Own nuke events', tostring(tonumber(diagnostics.ownNukeEvents) or 0))
            drawKeyValue('Matched / unmatched', string.format('%d / %d',
                tonumber(diagnostics.matched) or 0,
                tonumber(diagnostics.unmatched) or 0))
            drawKeyValue('Correlation state', tostring(diagnostics.lastReason or 'unknown'))
        end
        return
    end
    if imgui.BeginTable('##intel_spell_damage', 6, 0) then
        for _, label in ipairs({ 'Spell', 'Samples', 'Expected', 'Max Seen', 'Baseline', 'Overkill OK' }) do
            imgui.TableSetupColumn(label)
        end
        imgui.TableHeadersRow()
        for _, row in ipairs(rows) do
            local overkillOk = nil
            if target and tonumber(target.remainingHp) and tonumber(row.expected) then
                overkillOk = tonumber(row.expected)
                    <= tonumber(target.remainingHp) * (tonumber(settings().DpsOverkillFactor) or 1.5)
            end
            imgui.TableNextRow()
            imgui.TableNextColumn(); imgui.Text(tostring(row.spellName or '?'))
            imgui.TableNextColumn(); imgui.Text(tostring(row.count or 0))
            imgui.TableNextColumn(); imgui.Text(commaNumber(row.expected))
            imgui.TableNextColumn(); imgui.Text(commaNumber(row.maxSeen))
            imgui.TableNextColumn(); imgui.Text(commaNumber(row.baseline))
            imgui.TableNextColumn(); drawBool(overkillOk)
        end
        imgui.EndTable()
    end
end

local function drawZoneKnowledge()
    imgui.TextWrapped(
        'Consolidated persisted knowledge from mob HP estimation, element resists, CC results, and observed NPC casts.')
    if imgui.SmallButton('Reload Persisted Data##intel_reload') then
        State.refreshRequested = true
    end
    imgui.SameLine()
    imgui.TextDisabled(string.format('Zone: %s | refreshed %.1fs ago | %d mobs',
        State.zone ~= '' and State.zone or '?',
        State.lastRefreshAt > 0 and (mq.gettime() - State.lastRefreshAt) / 1000 or 0,
        #State.zoneRows))
    if State.refreshRequested then
        imgui.TextDisabled('Refresh queued; it will run on the next main-loop tick.')
    end
    if State.refreshError then
        imgui.TextColored(1.0, 0.35, 0.3, 1.0, 'Refresh error: ' .. State.refreshError)
    end

    if #State.zoneRows == 0 then
        imgui.TextDisabled('No persisted intelligence for this zone.')
        return
    end

    if imgui.BeginTable('##intel_zone', 8, 0) then
        for _, label in ipairs({
            'Mob', 'Level', 'Classes', 'Max HP', 'HP Weight', 'Elements', 'CC', 'NPC Casts',
        }) do imgui.TableSetupColumn(label) end
        imgui.TableHeadersRow()
        for _, row in ipairs(State.zoneRows) do
            imgui.TableNextRow()
            imgui.TableNextColumn(); imgui.Text(row.name)
            imgui.TableNextColumn(); imgui.Text(row.level and tostring(row.level) or '-')
            imgui.TableNextColumn(); imgui.TextWrapped(row.classes)
            imgui.TableNextColumn(); imgui.Text(commaNumber(row.maxHp))
            imgui.TableNextColumn(); imgui.Text(string.format('%.1f', row.hpWeight))
            imgui.TableNextColumn(); imgui.TextWrapped(row.resists)
            imgui.TableNextColumn(); imgui.TextWrapped(row.cc)
            imgui.TableNextColumn(); imgui.TextWrapped(row.casts)
        end
        imgui.EndTable()
    end
end

local SETTING_ROWS = {
    { 'UseDpsIntelligence', 'Master TTD, payoff, and overkill gating' },
    { 'DpsNukeLandMargin', 'Extra seconds required beyond nuke cast time' },
    { 'DpsDefaultNukeCastTime', 'Fallback nuke cast duration' },
    { 'DpsDotBreakevenPct', 'Required percentage of a DoT duration' },
    { 'DpsDefaultDotDuration', 'Fallback DoT duration' },
    { 'DpsOverkillFactor', 'Maximum expected-hit multiple of remaining HP' },
    { 'DpsRainPayoffSec', 'Additional survival window for rain waves' },
    { 'DpsRainSafetyMode', 'Mez footprint policy: mezzed, solo, or off' },
    { 'DpsRainSafetyRadius', 'Fallback rain footprint radius' },
    { 'UseResistTracker', 'Master per-element learning toggle' },
    { 'ResistMinSamples', 'Evidence required before avoiding an element' },
    { 'ResistAvoidPct', 'Full-resist percentage that triggers avoidance' },
    { 'ResistMinEfficiencyPct', 'Partial-resist efficiency floor' },
    { 'AdaptiveResistSkip', 'Enable per-spell adaptive skip decisions' },
    { 'RetryOnResist', 'Retry rotation entries after a resist' },
    { 'PreferredResistType', 'Configured element preference' },
    { 'DamageObserver', 'Own-only or full group damage observation scope' },
}

local function drawSettingsAndSources()
    local s = settings()
    imgui.Text('Effective Intelligence Settings')
    if imgui.BeginTable('##intel_settings', 3, 0) then
        imgui.TableSetupColumn('Setting')
        imgui.TableSetupColumn('Value')
        imgui.TableSetupColumn('Effect')
        imgui.TableHeadersRow()
        for _, row in ipairs(SETTING_ROWS) do
            imgui.TableNextRow()
            imgui.TableNextColumn(); imgui.Text(row[1])
            imgui.TableNextColumn(); imgui.Text(tostring(s[row[1]]))
            imgui.TableNextColumn(); imgui.TextWrapped(row[2])
        end
        imgui.EndTable()
    end

    local policy = telemetryFresh() and State.telemetry.resistPolicy or nil
    if type(policy) ~= 'table' then
        local ResistLog = Mods.ResistLog()
        policy = ResistLog and ResistLog.getPolicy and ResistLog.getPolicy() or {}
    end
    imgui.Text('Per-Spell Adaptive Skip Policy')
    drawKeyValue('Minimum casts', tostring(policy.minCasts or 'unknown'))
    drawKeyValue('Skip resist rate', formatPct(policy.skipRatePct))
    drawKeyValue('Consecutive resist limit', tostring(policy.consecutiveLimit or 'unknown'))
    drawKeyValue('Fight-streak expiry', policy.sessionTtlSec
        and string.format('%ds', policy.sessionTtlSec) or 'unknown')

    imgui.Separator()
    imgui.Text('Data Sources')
    local Paths = Mods.Paths()
    if not Paths then
        imgui.TextDisabled('Path helper unavailable.')
        return
    end
    local sources = {
        { 'Element resist learning', Paths.getResistTrackerPath },
        { 'Mob HP estimates', Paths.getMobHpEstimatorPath },
        { 'Spell damage learning', Paths.getSpellDamagePath },
        { 'Mob / CC intelligence', Paths.getMobIntelPath },
        { 'Exports', Paths.getExportDir },
    }
    for _, source in ipairs(sources) do
        local ok, path = pcall(source[2])
        drawKeyValue(source[1], ok and tostring(path or '?') or 'unavailable')
    end
    local ResistLog = Mods.ResistLog()
    if ResistLog and ResistLog.getStoragePath then
        local ok, path = pcall(ResistLog.getStoragePath)
        drawKeyValue('Per-spell resist log', ok and tostring(path or '?') or 'unavailable')
    end
    imgui.TextWrapped(
        'Live target data is sent by sk_dps once per second. Persistent worker-owned databases are reloaded here every 15 seconds.')
end

function M.drawContent()
    M.init()
    State.lastDrawAt = mq.gettime()
    if State.lastRefreshAt <= 0 then State.refreshRequested = true end

    if imgui.BeginTabBar('##dps_intelligence_tabs') then
        if imgui.BeginTabItem('Live Target') then
            drawLiveTarget()
            imgui.EndTabItem()
        end
        if imgui.BeginTabItem('Resists / CC') then
            drawResists()
            imgui.EndTabItem()
        end
        if imgui.BeginTabItem('Damage / HP') then
            drawDamageLearning()
            imgui.EndTabItem()
        end
        if imgui.BeginTabItem('Zone Knowledge') then
            drawZoneKnowledge()
            imgui.EndTabItem()
        end
        if imgui.BeginTabItem('Settings / Sources') then
            drawSettingsAndSources()
            imgui.EndTabItem()
        end
        imgui.EndTabBar()
    end
end

return M
