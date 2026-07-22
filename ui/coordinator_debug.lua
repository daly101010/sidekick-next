-- F:/lua/sidekick-next/ui/coordinator_debug.lua
-- Coordinator state popout for SideKick multi-script system

local mq = require('mq')
local imgui = require('ImGui')
local actors = require('actors')
local lib = require('sidekick-next.sk_lib')
local lazy = require('sidekick-next.utils.lazy_require')

local M = {}

M.open = false
M._showWindow = false
M._initialized = false
M._stateDropbox = nil

local State = {
    last = nil,
    receivedAtMs = 0,
    rezTelemetry = nil,
}
local renderRezTelemetry

-- The coordinated healing runtime belongs exclusively to sk_healing.lua.
-- This UI process reads its persisted config and coordinator diagnostics; it
-- must not initialize a second copy of the healing sensors and event handlers.
local getHealingConfig = lazy('sidekick-next.healing.config')
local _healingConfigLoaded = false
local _healingConfigLoadError = nil
local _lastHealingConfigRefreshMs = 0
local HEALING_CONFIG_REFRESH_MS = 2000

-- Get spell availability info
local function getSpellAvailability(spellName)
    if not spellName or spellName == '' then return nil end
    local me = mq.TLO.Me
    if not me or not me() then return nil end

    local spell = mq.TLO.Spell(spellName)
    if not spell or not spell() then return nil end

    local info = {
        name = spellName,
        memorized = false,
        ready = false,
        manaOk = false,
        manaCost = 0,
        castTimeMs = 0,
    }

    -- Check if memorized (in any gem slot)
    for i = 1, 13 do
        local gem = me.Gem(i)
        if gem and gem() and gem.Name and gem.Name() == spellName then
            info.memorized = true
            break
        end
    end

    -- Check mana
    info.manaCost = tonumber(spell.Mana()) or 0
    local currentMana = tonumber(me.CurrentMana()) or 0
    info.manaOk = currentMana >= info.manaCost

    -- Check if ready (memorized + not on cooldown)
    if info.memorized then
        local ready = me.SpellReady(spellName)
        info.ready = ready and ready() == true
    end

    -- Get cast time
    ---@diagnostic disable-next-line: undefined-field
    local mySpell = me.Spell and me.Spell(spellName)
    if mySpell and mySpell() then
        info.castTimeMs = tonumber(mySpell.MyCastTime()) or tonumber(spell.CastTime()) or 0
    else
        info.castTimeMs = tonumber(spell.CastTime()) or 0
    end

    return info
end

-- Get all heals with their availability
local function getHealAvailability()
    local config = getHealingConfig()
    if not config then return nil end
    local now = mq.gettime()
    if config.load and (now - _lastHealingConfigRefreshMs) >= HEALING_CONFIG_REFRESH_MS then
        local ok, err = pcall(config.load)
        _lastHealingConfigRefreshMs = now
        if ok then
            _healingConfigLoaded = true
            _healingConfigLoadError = nil
        else
            _healingConfigLoadError = tostring(err)
        end
    end
    if not config.spells then return nil end

    local categories = { 'fast', 'small', 'medium', 'large', 'group', 'hot', 'hotLight', 'groupHot', 'promised' }
    local result = {}

    for _, cat in ipairs(categories) do
        local spells = config.spells[cat]
        if spells and #spells > 0 then
            result[cat] = {}
            for _, spellName in ipairs(spells) do
                local avail = getSpellAvailability(spellName)
                if avail then
                    table.insert(result[cat], avail)
                end
            end
        end
    end

    return result
end

local priorityNames = {
    [lib.Priority.EMERGENCY] = 'Emergency',
    [lib.Priority.HEALING] = 'Healing',
    [lib.Priority.RESURRECTION] = 'Resurrection',
    [lib.Priority.TANK_RECOVERY] = 'Tank Recovery',
    [lib.Priority.DEBUFF] = 'Debuff',
    [lib.Priority.TANK_AGGRO] = 'Tank Aggro',
    [lib.Priority.PULL] = 'Pull',
    [lib.Priority.DPS] = 'DPS',
    [lib.Priority.IDLE] = 'Idle',
    [lib.Priority.BUFF] = 'Buff',
    [lib.Priority.MEDITATION] = 'Meditation',
}

local moduleOrder = {
    healing_emergency = 10,
    emergency = 20,
    pull = 52,
    healing = 30,
    cures = 35,
    resurrection = 40,
    cc = 45,
    disciplines = 50,
    tank = 53,
    assist = 55,
    dps = 60,
    items = 62,
    resources = 65,
    buffs = 70,
    spell_memorize = 80,
    fidget = 85,
    meditation = 90,
    next_meditation = 90,
}

local function formatBool(v)
    if v == true then return 'true' end
    if v == false then return 'false' end
    return 'nil'
end

local function formatValue(v)
    if v == nil then return 'nil' end
    if type(v) == 'boolean' then return formatBool(v) end
    if type(v) == 'number' then return string.format('%.2f', v) end
    if type(v) == 'string' then return v end
    return tostring(v)
end

local function renderRow(label, value)
    imgui.TableNextRow()
    imgui.TableNextColumn()
    imgui.Text(label)
    imgui.TableNextColumn()
    imgui.Text(value)
end

local function renderTable(tableId, rows)
    local flags = 0
    if ImGuiTableFlags and bit32 and bit32.bor then
        flags = bit32.bor(
            ImGuiTableFlags.Borders,
            ImGuiTableFlags.RowBg,
            ImGuiTableFlags.Resizable
        )
    end
    if imgui.BeginTable(tableId, 2, flags) then
        imgui.TableSetupColumn('Key', ImGuiTableColumnFlags.WidthFixed, 140)
        imgui.TableSetupColumn('Value', ImGuiTableColumnFlags.WidthStretch)
        imgui.TableHeadersRow()
        for _, row in ipairs(rows) do
            renderRow(row[1], row[2])
        end
        imgui.EndTable()
    end
end

local function renderOwnerBlock(title, owner)
    imgui.Text(title)
    if not owner then
        imgui.SameLine()
        imgui.TextColored(0.6, 0.6, 0.6, 1, 'none')
        return
    end

    local rows = {
        { 'Module', tostring(owner.module or '?') },
        { 'Priority', tostring(priorityNames[owner.priority] or owner.priority or '?') },
        { 'Claim ID', tostring(owner.claimId or '?') },
        { 'TTL (ms)', tostring(owner.ttlMs or '?') },
        { 'Expects Cast Start', formatBool(owner.expectsCastStart) },
        { 'Cast Started', formatBool(owner.castStartedAtMs ~= nil) },
    }
    renderTable('##' .. title .. '_owner', rows)

    local action = owner.action
    if action and type(action) == 'table' then
        if imgui.TreeNode(title .. '_action', 'Action') then
            local arows = {
                { 'Kind', tostring(action.kind or '?') },
                { 'Name', tostring(action.name or action.spellName or '?') },
                { 'Target ID', tostring(action.targetId or '?') },
                { 'Reason', tostring(action.reason or '') },
            }
            renderTable('##' .. title .. '_action_table', arows)
            imgui.TreePop()
        end
    end
end

local categoryLabels = {
    fast = 'Fast/Quick',
    small = 'Small',
    medium = 'Medium',
    large = 'Large',
    group = 'Group',
    hot = 'HoT',
    hotLight = 'Light HoT',
    groupHot = 'Group HoT',
    promised = 'Promised',
}

-------------------------------------------------------------------------------
-- Module Diagnostics
-------------------------------------------------------------------------------

local function renderModuleDiagnostics(moduleDiag)
    if not moduleDiag or type(moduleDiag) ~= 'table' then
        imgui.TextColored(0.6, 0.6, 0.6, 1, 'No module data in state broadcast')
        return
    end

    -- Count modules
    local moduleCount = 0
    for _ in pairs(moduleDiag) do moduleCount = moduleCount + 1 end

    if moduleCount == 0 then
        imgui.TextColored(0.6, 0.6, 0.6, 1, 'No modules registered')
        return
    end

    -- Sort modules by stable module order. Sorting by current need priority
    -- makes rows jump whenever needs expire or reappear.
    local sorted = {}
    for name, diag in pairs(moduleDiag) do
        table.insert(sorted, { name = name, diag = diag })
    end
    table.sort(sorted, function(a, b)
        local pa = moduleOrder[a.name] or 999
        local pb = moduleOrder[b.name] or 999
        if pa ~= pb then return pa < pb end
        return a.name < b.name
    end)

    local flags = 0
    if ImGuiTableFlags and bit32 and bit32.bor then
        flags = bit32.bor(
            ImGuiTableFlags.Borders,
            ImGuiTableFlags.RowBg,
            ImGuiTableFlags.Resizable
        )
    end

    if imgui.BeginTable('##module_diag', 7, flags) then
        imgui.TableSetupColumn('Module', ImGuiTableColumnFlags.WidthFixed, 130)
        imgui.TableSetupColumn('HB', ImGuiTableColumnFlags.WidthFixed, 55)
        imgui.TableSetupColumn('Needs', ImGuiTableColumnFlags.WidthFixed, 50)
        imgui.TableSetupColumn('Priority', ImGuiTableColumnFlags.WidthFixed, 70)
        imgui.TableSetupColumn('Action', ImGuiTableColumnFlags.WidthFixed, 150)
        imgui.TableSetupColumn('Age', ImGuiTableColumnFlags.WidthFixed, 60)
        imgui.TableSetupColumn('Reason', ImGuiTableColumnFlags.WidthStretch)
        imgui.TableHeadersRow()

        for _, entry in ipairs(sorted) do
            local name = entry.name
            local diag = entry.diag
            imgui.PushID(name)

            imgui.TableNextRow()

            -- Module name
            imgui.TableNextColumn()
            if diag.needValid then
                imgui.TextColored(0.3, 1.0, 0.3, 1, name)  -- Green = active need
            elseif diag.ready then
                imgui.Text(name)  -- White = alive, no need
            else
                imgui.TextColored(0.6, 0.6, 0.6, 1, name)  -- Gray = not ready
            end

            -- Heartbeat age
            imgui.TableNextColumn()
            local hbAge = diag.heartbeatAge or 0
            if diag.stale then
                imgui.TextColored(0.6, 0.6, 0.6, 1, 'stale')
            elseif hbAge < 500 then
                imgui.TextColored(0.3, 1.0, 0.3, 1, string.format('%dms', hbAge))
            elseif hbAge < 2000 then
                imgui.TextColored(1.0, 1.0, 0.3, 1, string.format('%dms', hbAge))
            else
                imgui.TextColored(1.0, 0.3, 0.3, 1, string.format('%.1fs', hbAge / 1000))
            end

            -- Needs action
            imgui.TableNextColumn()
            if diag.needValid then
                imgui.TextColored(0.3, 1.0, 0.3, 1, 'YES')
            elseif diag.needsAction then
                imgui.TextColored(1.0, 0.5, 0.3, 1, 'exp')  -- Sent need but expired
            else
                imgui.TextColored(0.6, 0.6, 0.6, 1, 'no')
            end

            -- Need priority
            imgui.TableNextColumn()
            if diag.needPriority then
                local pName = priorityNames[diag.needPriority] or tostring(diag.needPriority)
                imgui.Text(pName)
            else
                imgui.TextColored(0.6, 0.6, 0.6, 1, '-')
            end

            -- Unified executor lifecycle (active action or most recent result)
            imgui.TableNextColumn()
            local action = diag.action
            if action and action.phase then
                local label = string.format('%s: %s', tostring(action.phase), tostring(action.name or '?'))
                if action.active then
                    imgui.TextColored(0.3, 1.0, 0.3, 1, label)
                elseif action.phase == 'failed' or action.phase == 'cancelled' then
                    imgui.TextColored(1.0, 0.5, 0.3, 1, label)
                else
                    imgui.TextDisabled(label)
                end
                if imgui.IsItemHovered() then
                    local tooltip = string.format('reason=%s elapsed=%dms',
                        tostring(action.reason or '-'), tonumber(action.elapsedMs) or 0)
                    imgui.SetTooltip(tooltip:gsub('%%', '%%%%'))
                end
            else
                imgui.TextColored(0.6, 0.6, 0.6, 1, '-')
            end

            -- Need age
            imgui.TableNextColumn()
            if diag.needsAction or diag.needValid then
                local age = diag.needAge or 0
                local ttl = diag.needTtl or 250
                local pct = ttl > 0 and (age / ttl) or 0
                if pct < 0.5 then
                    imgui.Text(string.format('%d/%d', age, ttl))
                elseif pct < 1.0 then
                    imgui.TextColored(1.0, 1.0, 0.3, 1, string.format('%d/%d', age, ttl))
                else
                    imgui.TextColored(1.0, 0.3, 0.3, 1, string.format('%d/%d', age, ttl))
                end
            else
                imgui.TextColored(0.6, 0.6, 0.6, 1, '-')
            end

            -- Reason (diagnostic - why module does/doesn't need action)
            imgui.TableNextColumn()
            local reason = diag.reason
            if reason and reason ~= '' then
                -- Color code common reasons
                if reason == 'no_action' or reason == 'no_emergency' or reason == 'no_emergency_action' then
                    imgui.TextColored(0.6, 0.6, 0.6, 1, reason)
                elseif reason == 'heals_disabled' or reason == 'spells_disabled'
                    or reason == 'not_healer' or reason == 'not_clr' then
                    imgui.TextColored(1.0, 0.3, 0.3, 1, reason)  -- Red = config/class problem
                elseif reason == 'init_failed' or reason == 'no_settings' then
                    imgui.TextColored(1.0, 0.5, 0.3, 1, reason)  -- Orange = init problem
                elseif reason == 'owns_cast' or reason == 'action found' then
                    imgui.TextColored(0.3, 1.0, 0.3, 1, reason)  -- Green = working
                else
                    imgui.Text(reason)
                end
            else
                imgui.TextColored(0.6, 0.6, 0.6, 1, '-')
            end

            imgui.PopID()
        end

        imgui.EndTable()
    end
end

local function renderTeamDiagnostics(team)
    if not team or type(team) ~= 'table' then
        imgui.TextDisabled('No Actor team data in coordinator state')
        return
    end

    local stats = team.stats or {}
    renderTable('##actor_team_summary', {
        { 'Enabled / Ready', string.format('%s / %s', formatBool(team.enabled), formatBool(team.ready)) },
        { 'Mode', tostring(team.mode or '-') },
        { 'Team', tostring(team.label ~= '' and team.label or team.teamId or '-') },
        { 'Leader', tostring(team.leader ~= '' and team.leader or '-') },
        { 'Members / Peers', string.format('%d / %d', tonumber(team.memberCount) or 0, tonumber(team.peerCount) or 0) },
        { 'Reason', tostring(team.reason or '-') },
        { 'Packets S/R/D', string.format('%d / %d / %d', tonumber(stats.sent) or 0,
            tonumber(stats.received) or 0, tonumber(stats.dropped) or 0) },
        { 'Last Dropped Packet', string.format('%s / %s',
            tostring(stats.lastDropReason ~= '' and stats.lastDropReason or '-'),
            tostring(stats.lastDroppedTeamId ~= '' and stats.lastDroppedTeamId or '-')) },
        { 'Last Error', tostring(team.lastError or '-') },
    })

    local members = type(team.members) == 'table' and team.members or {}
    if #members == 0 then return end

    local flags = 0
    if ImGuiTableFlags and bit32 and bit32.bor then
        flags = bit32.bor(ImGuiTableFlags.Borders, ImGuiTableFlags.RowBg, ImGuiTableFlags.Resizable)
    end
    if imgui.BeginTable('##actor_team_members', 7, flags) then
        imgui.TableSetupColumn('Character', ImGuiTableColumnFlags.WidthFixed, 110)
        imgui.TableSetupColumn('Class / Role', ImGuiTableColumnFlags.WidthFixed, 95)
        imgui.TableSetupColumn('Zone', ImGuiTableColumnFlags.WidthFixed, 90)
        imgui.TableSetupColumn('State', ImGuiTableColumnFlags.WidthFixed, 75)
        imgui.TableSetupColumn('Priority', ImGuiTableColumnFlags.WidthFixed, 75)
        imgui.TableSetupColumn('Action', ImGuiTableColumnFlags.WidthStretch)
        imgui.TableSetupColumn('Age', ImGuiTableColumnFlags.WidthFixed, 55)
        imgui.TableHeadersRow()
        for _, member in ipairs(members) do
            local action = member.action or {}
            local state = member.dead and 'dead'
                or member.incapacitated and 'blocked'
                or member.automationPaused and 'paused'
                or member.inCombat and 'combat'
                or member.inGame and 'idle'
                or 'zoning'
            imgui.TableNextRow()
            imgui.TableNextColumn()
            local name = tostring(member.character or '?')
            if member.self then name = name .. ' (you)' end
            if member.key == team.leaderKey then name = name .. ' *' end
            imgui.Text(name)
            imgui.TableNextColumn()
            imgui.Text(string.format('%s / %s', tostring(member.class or '-'), tostring(member.role or '-')))
            imgui.TableNextColumn()
            imgui.Text(tostring(member.zone or '-'))
            imgui.TableNextColumn()
            imgui.Text(state)
            imgui.TableNextColumn()
            imgui.Text(tostring(priorityNames[member.activePriority] or member.activePriority or '-'))
            imgui.TableNextColumn()
            if action.name and action.name ~= '' then
                imgui.Text(string.format('%s: %s', tostring(action.phase or 'claimed'), tostring(action.name)))
            else
                imgui.TextDisabled('-')
            end
            imgui.TableNextColumn()
            imgui.Text(member.self and '-' or string.format('%.1fs', (tonumber(member.ageMs) or 0) / 1000))
        end
        imgui.EndTable()
    end
end

-------------------------------------------------------------------------------
-- Healing Decision Diagnostics
-------------------------------------------------------------------------------

-- Cache for healing decision to avoid calling every frame
local _healDiagCache = {
    lastCheckAt = 0,
    result = nil,
    reason = nil,
    emergencyResult = nil,
    emergencyReason = nil,
}

local function getHealingDecision()
    local now = mq.gettime()
    -- Refresh every 250ms
    if (now - _healDiagCache.lastCheckAt) < 250 then
        return _healDiagCache
    end
    _healDiagCache.lastCheckAt = now

    local state = State.last
    local moduleDiag = state and state.moduleDiag or nil
    local worker = moduleDiag and moduleDiag.healing or nil
    if not worker then
        _healDiagCache.result = nil
        _healDiagCache.reason = 'worker not registered'
        _healDiagCache.emergencyResult = nil
        _healDiagCache.emergencyReason = 'worker not registered'
        return _healDiagCache
    end

    if worker.stale or worker.ready == false then
        local reason = worker.stale and 'worker heartbeat stale' or 'worker not ready'
        _healDiagCache.result = nil
        _healDiagCache.reason = reason
        _healDiagCache.emergencyResult = nil
        _healDiagCache.emergencyReason = reason
        return _healDiagCache
    end

    -- The claimed action is the authoritative decision made by the worker.
    -- Before a claim is granted, the need reason still explains its state.
    local owner = state and state.castOwner or nil
    local action = owner and owner.module == 'healing' and owner.action or nil
    local reason = tostring(worker.reason or (worker.needValid and 'awaiting claim' or 'no action needed'))
    if action and action.tier == 'emergency' then
        _healDiagCache.result = nil
        _healDiagCache.reason = reason
        _healDiagCache.emergencyResult = action
        _healDiagCache.emergencyReason = 'action claimed'
    elseif action then
        _healDiagCache.result = action
        _healDiagCache.reason = 'action claimed'
        _healDiagCache.emergencyResult = nil
        _healDiagCache.emergencyReason = reason
    else
        _healDiagCache.result = nil
        _healDiagCache.reason = reason
        _healDiagCache.emergencyResult = nil
        _healDiagCache.emergencyReason = reason
    end

    return _healDiagCache
end

local function renderHealingDecision()
    local diag = getHealingDecision()
    if not diag then
        imgui.TextColored(0.6, 0.6, 0.6, 1, 'No healing data')
        return
    end

    -- Emergency section
    imgui.Text('Emergency:')
    imgui.SameLine()
    if diag.emergencyResult then
        local a = diag.emergencyResult
        imgui.TextColored(1.0, 0.3, 0.3, 1, string.format('%s on %s (id:%s)',
            tostring(a.spellName or a.name or '?'),
            tostring(a.targetName or '?'),
            tostring(a.targetId or '?')))
    else
        imgui.TextColored(0.6, 0.6, 0.6, 1, tostring(diag.emergencyReason or 'none'))
    end

    -- Normal heal section
    imgui.Text('Heal:')
    imgui.SameLine()
    if diag.result then
        local a = diag.result
        imgui.TextColored(0.3, 1.0, 0.3, 1, string.format('%s on %s (id:%s) [%s]',
            tostring(a.spellName or a.name or '?'),
            tostring(a.targetName or '?'),
            tostring(a.targetId or '?'),
            tostring(a.tier or '?')))
    else
        imgui.TextColored(0.6, 0.6, 0.6, 1, tostring(diag.reason or 'none'))
    end

    -- Show details if action exists
    local action = diag.result or diag.emergencyResult
    if action and type(action) == 'table' then
        local flags = 0
        if ImGuiTableFlags and bit32 and bit32.bor then
            flags = bit32.bor(
                ImGuiTableFlags.Borders,
                ImGuiTableFlags.RowBg,
                ImGuiTableFlags.Resizable
            )
        end
        if imgui.BeginTable('##heal_decision_detail', 2, flags) then
            imgui.TableSetupColumn('Key', ImGuiTableColumnFlags.WidthFixed, 100)
            imgui.TableSetupColumn('Value', ImGuiTableColumnFlags.WidthStretch)
            imgui.TableHeadersRow()

            local details = {
                { 'Spell', tostring(action.spellName or action.name or '?') },
                { 'Target', string.format('%s (id:%s)', tostring(action.targetName or '?'), tostring(action.targetId or '?')) },
                { 'Tier', tostring(action.tier or '?') },
                { 'Reason', tostring(action.reason or '?') },
            }
            if action.expected then
                table.insert(details, { 'Expected Heal', tostring(action.expected) })
            end
            if action.isHoT then
                table.insert(details, { 'Is HoT', 'true' })
            end
            if action.details and type(action.details) == 'string' then
                table.insert(details, { 'Details', action.details })
            end

            for _, row in ipairs(details) do
                renderRow(row[1], row[2])
            end
            imgui.EndTable()
        end
    end
end

local function renderHealAvailability()
    local avail = getHealAvailability()
    if not avail then
        local message = _healingConfigLoadError
            and ('Healing configuration failed to load: ' .. tostring(_healingConfigLoadError))
            or 'Healing configuration unavailable'
        imgui.TextColored(0.8, 0.5, 0.3, 1, message)
        return
    end

    local hasAny = false
    for _, spells in pairs(avail) do
        if #spells > 0 then
            hasAny = true
            break
        end
    end

    if not hasAny then
        imgui.TextColored(0.6, 0.6, 0.6, 1, 'No heals configured')
        return
    end

    local flags = 0
    if ImGuiTableFlags and bit32 and bit32.bor then
        flags = bit32.bor(
            ImGuiTableFlags.Borders,
            ImGuiTableFlags.RowBg,
            ImGuiTableFlags.Resizable
        )
    end

    local categoryOrder = { 'fast', 'small', 'medium', 'large', 'group', 'hot', 'hotLight', 'groupHot', 'promised' }

    for _, cat in ipairs(categoryOrder) do
        local spells = avail[cat]
        if spells and #spells > 0 then
            local label = categoryLabels[cat] or cat
            if imgui.TreeNode('heal_cat_' .. cat, label .. ' (' .. #spells .. ')') then
                if imgui.BeginTable('##heals_' .. cat, 4, flags) then
                    imgui.TableSetupColumn('Spell', ImGuiTableColumnFlags.WidthStretch)
                    imgui.TableSetupColumn('Ready', ImGuiTableColumnFlags.WidthFixed, 50)
                    imgui.TableSetupColumn('Mana', ImGuiTableColumnFlags.WidthFixed, 50)
                    imgui.TableSetupColumn('Cast', ImGuiTableColumnFlags.WidthFixed, 50)
                    imgui.TableHeadersRow()

                    for _, spell in ipairs(spells) do
                        imgui.TableNextRow()
                        imgui.TableNextColumn()

                        -- Spell name with color based on availability
                        if spell.ready and spell.manaOk then
                            imgui.TextColored(0.3, 1.0, 0.3, 1, spell.name)  -- Green = ready
                        elseif spell.memorized then
                            imgui.TextColored(1.0, 1.0, 0.3, 1, spell.name)  -- Yellow = memorized but not ready
                        else
                            imgui.TextColored(0.6, 0.6, 0.6, 1, spell.name)  -- Gray = not memorized
                        end

                        imgui.TableNextColumn()
                        if spell.ready then
                            imgui.TextColored(0.3, 1.0, 0.3, 1, 'Yes')
                        elseif spell.memorized then
                            imgui.TextColored(1.0, 0.5, 0.3, 1, 'CD')  -- On cooldown
                        else
                            imgui.TextColored(0.6, 0.6, 0.6, 1, 'No')
                        end

                        imgui.TableNextColumn()
                        if spell.manaOk then
                            imgui.Text(tostring(spell.manaCost))
                        else
                            imgui.TextColored(1.0, 0.3, 0.3, 1, tostring(spell.manaCost))  -- Red = not enough mana
                        end

                        imgui.TableNextColumn()
                        imgui.Text(string.format('%.1fs', spell.castTimeMs / 1000))
                    end

                    imgui.EndTable()
                end
                imgui.TreePop()
            end
        end
    end
end

--- Latest coordinator state snapshot received by the UI process. Shared with
--- other diagnostic tabs (Activity) so they don't need their own receive path.
function M.getLastState()
    return State.last
end

function M.init()
    if M._initialized then return end
    M._initialized = true

    local config = getHealingConfig()
    if config and config.load and not _healingConfigLoaded then
        local ok, err = pcall(config.load)
        if ok then
            _healingConfigLoaded = true
            _healingConfigLoadError = nil
        else
            _healingConfigLoadError = tostring(err)
        end
    elseif not config then
        _healingConfigLoadError = 'config module unavailable'
    end

    M._stateDropbox = actors.register(lib.Mailbox.STATE, function(message)
        local content = message()
        if type(content) ~= 'table' then return end
        if tostring(content.ownerName or '') ~= tostring(lib.getMyName() or '') then return end
        if tostring(content.ownerServer or '') ~= tostring(lib.getMyServer() or '') then return end
        if content.tickId and content.epoch then
            State.last = content
            State.receivedAtMs = mq.gettime()
        end
    end)
end

--- Render the coordinator debug content (no window wrapper).
--- Can be embedded inside another window or settings tab.
function M.drawContent()
    -- Ensure Actor listener is registered
    M.init()

    if not State.last then
        imgui.TextColored(0.7, 0.7, 0.7, 1, 'Waiting for coordinator state...')
        return
    end

    local nowMs = mq.gettime()
    local sentAt = State.last.sentAtMs or State.receivedAtMs
    local ageMs = nowMs - (sentAt or nowMs)
    local ttlMs = State.last.ttlMs or 0
    local stale = ttlMs > 0 and ageMs > ttlMs

    local rows = {
        { 'Active Priority', tostring(priorityNames[State.last.activePriority] or State.last.activePriority or '?') },
        { 'Cast Busy', formatBool(State.last.castBusy) },
        { 'Automation Paused', formatBool(State.last.automationPaused) },
        { 'Settings Revision', tostring(State.last.settingsRevision or 0) },
        { 'Epoch', tostring(State.last.epoch or '?') },
        { 'Tick ID', tostring(State.last.tickId or '?') },
        { 'Age (s)', string.format('%.2f', ageMs / 1000) },
        { 'Stale', formatBool(stale) },
    }

    renderTable('##coord_summary', rows)

    imgui.Spacing()
    imgui.Separator()

    renderOwnerBlock('Cast Owner', State.last.castOwner)
    imgui.Spacing()
    renderOwnerBlock('Target Owner', State.last.targetOwner)

    imgui.Spacing()
    imgui.Separator()

    imgui.Text('World State')
    local ws = State.last.worldState or {}
    local wrows = {
        { 'In Combat', formatBool(ws.inCombat) },
        { 'My HP %', tostring(ws.myHpPct or '?') },
        { 'My Mana %', tostring(ws.myManaPct or '?') },
        { 'Group Needs Healing', formatBool(ws.groupNeedsHealing) },
        { 'Emergency Active', formatBool(ws.emergencyActive) },
        { 'Incapacitated', formatBool(ws.incapacitated) },
        { 'Control Reason', tostring(ws.incapacitationReason or '-') },
        { 'Stunned / Mezzed', string.format('%s / %s', formatBool(ws.stunned), formatBool(ws.mezzed)) },
        { 'Silenced / Feared', string.format('%s / %s', formatBool(ws.silenced), formatBool(ws.feared)) },
        { 'Dead Count', tostring(ws.deadCount or '?') },
        { 'Main Assist ID', tostring(ws.mainAssistId or '?') },
    }
    renderTable('##coord_world', wrows)

    imgui.Spacing()
    imgui.Separator()

    -- Module Status (always visible - key diagnostic)
    if imgui.CollapsingHeader('Module Status##modules') then
        renderModuleDiagnostics(State.last.moduleDiag)
    end

    if imgui.CollapsingHeader('Actor Team##actorteam') then
        renderTeamDiagnostics(State.last.team)
    end

    if imgui.CollapsingHeader('Resurrection Status##rezstatus') then
        renderRezTelemetry()
    end

    imgui.Spacing()
    imgui.Separator()

    -- Healing Decision (what HI thinks we should do right now)
    if imgui.CollapsingHeader('Healing Decision##healdecision') then
        renderHealingDecision()
    end

    imgui.Spacing()
    imgui.Separator()

    if imgui.CollapsingHeader('Heals Available##healavail') then
        renderHealAvailability()
    end
end

--- Render the standalone coordinator debug window.
function M.render()
    if not M.open then return end

    M.open, M._showWindow = imgui.Begin('SideKick Coordinator', M.open)
    if M._showWindow then
        M.drawContent()
    end
    imgui.End()
end

function M.toggle()
    M.open = not M.open
end

function M.show()
    M.open = true
end

function M.hide()
    M.open = false
end

renderRezTelemetry = function()
    local rez = State.rezTelemetry
    if type(rez) ~= 'table' then
        imgui.TextDisabled('No resurrection worker telemetry received')
        return
    end
    renderTable('##rez_telemetry', {
        { 'Reason', tostring(rez.reason or '-') },
        { 'Phase', tostring(rez.phase or 'idle') },
        { 'Target', string.format('%s (%s)', tostring(rez.targetName or '-'), tostring(rez.targetClass or '-')) },
        { 'Target Source', tostring(rez.targetSource or '-') },
        { 'Corpse ID', tostring(rez.corpseId or 0) },
        { 'Resource', string.format('%s: %s', tostring(rez.resourceKind or '-'), tostring(rez.resourceName or '-')) },
        { 'Actor Winner', tostring(rez.winner or '-') },
        { 'OOC Policy', string.format('%s / %s', formatBool(rez.oocEnabled), tostring(rez.oocMethod or '-')) },
        { 'Combat Policy', string.format('%s / %s', formatBool(rez.combatEnabled), tostring(rez.combatMethod or '-')) },
        { 'Configured Item', tostring(rez.itemName or '-') },
        { 'Last Result', tostring(rez.lastResult or '-') },
    })
end

function M.setRezTelemetry(telemetry)
    if type(telemetry) == 'table' then
        State.rezTelemetry = telemetry
    end
end

function M.getLastState()
    M.init()
    return State.last, State.receivedAtMs
end

return M
