-- F:/lua/sidekick-next/ui/coordinator_debug.lua
-- Coordinator state popout for SideKick multi-script system

local mq = require('mq')
local imgui = require('ImGui')
local actors = require('actors')
local lib = require('sidekick-next.sk_lib')
local lazy = require('sidekick-next.utils.lazy_require')
local ActorsCoordinator = require('sidekick-next.utils.actors_coordinator')

local M = {}

M.open = false
M._showWindow = false
M._initialized = false
M._stateDropbox = nil

local State = {
    last = nil,
    receivedAtMs = 0,
    rezTelemetry = nil,
    inbox = {},
    coordinatorBootId = nil,
    lastTickId = 0,
    actionLatest = {},
    actionHistory = {},
    actionSessions = {},
    actionSequences = {},
    statePacketsReceived = 0,
    statePacketsAccepted = 0,
    statePacketsRejected = 0,
    lastStateRejectReason = '',
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
    [lib.Priority.TANK] = 'Tank',
    [lib.Priority.CROWD_CONTROL] = 'Crowd Control',
    [lib.Priority.DEBUFF] = 'Debuff',
    [lib.Priority.PULL] = 'Pull',
    [lib.Priority.DPS] = 'DPS',
    [lib.Priority.BUFF] = 'Buff',
    [lib.Priority.MEDITATION] = 'Meditation',
    [lib.Priority.SCRIBING] = 'Scribing',
    [lib.Priority.AMBIENT] = 'Ambient',
    [lib.Priority.IDLE] = 'Idle',
}

local moduleOrder = {
    emergency = 1,
    support = 2,
    tank = 3,
    combat = 4,
    pull = 5,
    chase = 6,
    maintenance = 7,
    items = 8,
    meditation = 9,
    scribing = 10,
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

local function renderLeaseBlock(title, lease)
    imgui.Text(title)
    if not lease then
        imgui.SameLine()
        imgui.TextColored(0.6, 0.6, 0.6, 1, 'none')
        return
    end

    local now = mq.gettime()
    local renewedAt = tonumber(lease.renewedAtMs) or tonumber(lease.grantedAtMs) or now
    local ttlMs = tonumber(lease.ttlMs) or 0
    local rows = {
        { 'Holder', tostring(lease.holderModule or '?') },
        { 'Tier', tostring(priorityNames[lease.tier] or lease.tier or '?') },
        { 'Status', tostring(lease.status or '?') },
        { 'Request ID', tostring(lease.requestId or '?') },
        { 'Worker Session', tostring(lease.workerSessionId or '?') },
        { 'Lease Age (ms)', tostring(math.max(0, now - (tonumber(lease.grantedAtMs) or now))) },
        { 'Renew Age / TTL', string.format('%d / %d',
            math.max(0, now - renewedAt), ttlMs) },
        { 'Revocation Reason', tostring(lease.revokeReason or '-') },
    }
    renderTable('##' .. title .. '_owner', rows)
end

local function copyStateValue(value, depth)
    depth = depth or 0
    local valueType = type(value)
    if valueType == 'nil' or valueType == 'boolean'
        or valueType == 'number' or valueType == 'string' then
        return value
    end
    if valueType ~= 'table' or depth >= 7 then return nil end
    local copied = {}
    for key, item in pairs(value) do
        local copiedKey = copyStateValue(key, depth + 1)
        local copiedValue = copyStateValue(item, depth + 1)
        if copiedKey ~= nil and copiedValue ~= nil then copied[copiedKey] = copiedValue end
    end
    return copied
end

local function drainStateInbox()
    if #State.inbox == 0 then return end
    local inbox = State.inbox
    State.inbox = {}
    local myName = tostring(lib.getMyName() or '')
    local myServer = tostring(lib.getMyServer() or '')
    for _, entry in ipairs(inbox) do
        local content = entry.content
        local sender = entry.sender or {}
        local transportValid = tostring(sender.character or '') == myName
            and tostring(sender.server or '') == myServer
            and lib.actorSenderMatches(sender,
                lib.Scripts.COORDINATOR, 'coordinator')
        local bootId = tostring(content and content.coordinatorBootId or '')
        local tickId = tonumber(content and content.tickId) or 0
        if transportValid and bootId ~= ''
            and bootId ~= tostring(State.coordinatorBootId or '') then
            State.coordinatorBootId = bootId
            State.lastTickId = 0
        end
        local rejectReason = nil
        if not transportValid then
            rejectReason = 'sender_route'
        elseif tostring(content.ownerName or '') ~= myName
            or tostring(content.ownerServer or '') ~= myServer then
            rejectReason = 'owner_identity'
        elseif tonumber(content.version) ~= tonumber(lib.LEASE_PROTOCOL_VERSION) then
            rejectReason = 'protocol_version'
        elseif tickId <= State.lastTickId then
            rejectReason = 'stale_tick'
        elseif not content.epoch then
            rejectReason = 'missing_epoch'
        end
        if not rejectReason
            and tostring(content.ownerName or '') == myName
            and tostring(content.ownerServer or '') == myServer
            and transportValid
            and tonumber(content.version) == tonumber(lib.LEASE_PROTOCOL_VERSION)
            and tickId > State.lastTickId
            and content.epoch then
            State.last = content
            State.lastTickId = tickId
            State.receivedAtMs = mq.gettime()
            State.statePacketsAccepted = State.statePacketsAccepted + 1
        else
            State.statePacketsRejected = State.statePacketsRejected + 1
            State.lastStateRejectReason = tostring(rejectReason or 'unknown')
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

    if imgui.BeginTable('##module_diag', 9, flags) then
        imgui.TableSetupColumn('Module', ImGuiTableColumnFlags.WidthFixed, 130)
        imgui.TableSetupColumn('HB', ImGuiTableColumnFlags.WidthFixed, 55)
        imgui.TableSetupColumn('Active', ImGuiTableColumnFlags.WidthFixed, 55)
        imgui.TableSetupColumn('Queued', ImGuiTableColumnFlags.WidthFixed, 55)
        imgui.TableSetupColumn('Tier', ImGuiTableColumnFlags.WidthFixed, 95)
        imgui.TableSetupColumn('Order', ImGuiTableColumnFlags.WidthFixed, 45)
        imgui.TableSetupColumn('Request Age', ImGuiTableColumnFlags.WidthFixed, 90)
        imgui.TableSetupColumn('Reason', ImGuiTableColumnFlags.WidthFixed, 150)
        imgui.TableSetupColumn('Worker Session', ImGuiTableColumnFlags.WidthStretch)
        imgui.TableHeadersRow()

        for _, entry in ipairs(sorted) do
            local name = entry.name
            local diag = entry.diag
            imgui.PushID(name)

            imgui.TableNextRow()

            -- Module name
            imgui.TableNextColumn()
            if diag.requestId then
                imgui.TextColored(0.3, 1.0, 0.3, 1, name)
            elseif diag.ready then
                imgui.Text(name)
            else
                imgui.TextColored(0.6, 0.6, 0.6, 1, name)
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

            -- Current worker intent. A worker process can be healthy while its
            -- feature is disabled; heartbeat freshness is not activation.
            imgui.TableNextColumn()
            if diag.intentActive then
                imgui.TextColored(0.3, 1.0, 0.3, 1, 'YES')
            else
                imgui.TextColored(0.6, 0.6, 0.6, 1, 'no')
            end

            -- Pending lease request
            imgui.TableNextColumn()
            if diag.requestId then
                imgui.TextColored(0.3, 1.0, 0.3, 1, 'YES')
            else
                imgui.TextColored(0.6, 0.6, 0.6, 1, 'no')
            end

            -- Fixed registered tier
            imgui.TableNextColumn()
            imgui.Text(tostring(priorityNames[diag.tier] or diag.tier or '-'))

            -- Stable deterministic tiebreak order
            imgui.TableNextColumn()
            imgui.Text(tostring(diag.order or '-'))

            -- Request age / TTL
            imgui.TableNextColumn()
            if diag.requestId then
                local age = tonumber(diag.requestAge) or 0
                local ttl = tonumber(diag.requestTtl) or 0
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

            -- Last intent reason reported by the worker. For example, Tank on
            -- a non-tank displays mode_off/not_tank_class rather than looking
            -- active merely because its supervised process is healthy.
            imgui.TableNextColumn()
            local intentReason = tostring(diag.intentReason or '')
            if intentReason ~= '' then
                imgui.Text(intentReason)
            else
                imgui.TextColored(0.6, 0.6, 0.6, 1, '-')
            end

            -- Worker process identity. Actions intentionally never cross this
            -- boundary, so the coordinator UI cannot display spell/target.
            imgui.TableNextColumn()
            local session = tostring(diag.workerSessionId or '')
            if session ~= '' then
                imgui.Text(session)
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
        imgui.TableSetupColumn('Lease', ImGuiTableColumnFlags.WidthStretch)
        imgui.TableSetupColumn('Age', ImGuiTableColumnFlags.WidthFixed, 55)
        imgui.TableHeadersRow()
        for _, member in ipairs(members) do
            local lease = member.lease or {}
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
            if lease.holderModule and lease.holderModule ~= '' then
                imgui.Text(string.format('%s: %s',
                    tostring(lease.status or 'active'),
                    tostring(lease.holderModule)))
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
    local worker = moduleDiag
        and (moduleDiag.support or moduleDiag.healing) or nil
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

    -- The coordinator remains action-blind; transition detail arrives on the
    -- direct worker-to-UI action trace channel.
    local lease = state and state.lease or nil
    local reason = worker.requestId and 'lease requested'
        or (lease and (lease.holderModule == 'support'
            or lease.holderModule == 'healing') and 'lease active')
        or 'no support lease request'
    _healDiagCache.result = nil
    _healDiagCache.reason = reason
    _healDiagCache.emergencyResult = nil
    _healDiagCache.emergencyReason =
        'See Action Trace for emergency and support transitions'

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
        State.statePacketsReceived = State.statePacketsReceived + 1
        local copied = copyStateValue(content)
        if not copied then return end
        local sender = message.sender or {}
        local senderScript = lib.actorSenderEndpoint(sender)
        local entry = {
            content = copied,
            sender = {
                character = tostring(sender.character or ''),
                server = tostring(sender.server or ''),
                script = tostring(senderScript or ''),
                mailbox = tostring(sender.mailbox or ''),
            },
        }
        if #State.inbox >= 4 then table.remove(State.inbox, 1) end
        State.inbox[#State.inbox + 1] = entry
    end)
end

--- Render the coordinator debug content (no window wrapper).
--- Can be embedded inside another window or settings tab.
function M.drawContent()
    -- Ensure Actor listener is registered
    M.init()
    drainStateInbox()

    if not State.last then
        imgui.TextColored(0.7, 0.7, 0.7, 1, 'Waiting for coordinator state...')
        imgui.Text(string.format('Coordinator process: %s',
            tostring(lib.getLuaScriptStatus(lib.Scripts.COORDINATOR) or 'UNKNOWN')))
        imgui.Text(string.format('State packets: %d received, %d rejected',
            State.statePacketsReceived, State.statePacketsRejected))
        if State.lastStateRejectReason ~= '' then
            imgui.TextColored(1.0, 0.55, 0.3, 1,
                'Last rejection: ' .. State.lastStateRejectReason)
        end
        return
    end

    local nowMs = mq.gettime()
    local sentAt = State.last.sentAtMs or State.receivedAtMs
    local ageMs = nowMs - (sentAt or nowMs)
    local ttlMs = State.last.ttlMs or 0
    local stale = ttlMs > 0 and ageMs > ttlMs

    local priorityName =
        tostring(priorityNames[State.last.activePriority] or State.last.activePriority or '?')
    local schedulingState
    if State.last.lease then
        schedulingState = 'Lease: ' .. priorityName
    elseif (tonumber(State.last.recoveryRequestCount) or 0) > 0 then
        schedulingState = 'Recovery pending: ' .. priorityName
    elseif (tonumber(State.last.requestCount) or 0) > 0 then
        schedulingState = 'Pending: ' .. priorityName
    else
        schedulingState = 'Idle'
    end
    local actorOutbound = State.last.transportDiag
        and State.last.transportDiag.actorOutbound or {}
    local rows = {
        { 'Scheduling Priority', schedulingState },
        { 'Lifecycle', tostring(State.last.lifecycle or '?') },
        { 'Lease Requests', tostring(State.last.requestCount or 0) },
        { 'Recovery Requests', tostring(State.last.recoveryRequestCount or 0) },
        { 'Preemption Enabled', formatBool(State.last.leasePreemptionEnabled) },
        { 'Scheduler Available', formatBool(State.last.schedulerAvailable) },
        { 'Cast Busy', formatBool(State.last.worldState and State.last.worldState.castBusy) },
        { 'Automation Paused', formatBool(State.last.automationPaused) },
        { 'Settings Revision', tostring(State.last.settingsRevision or 0) },
        { 'Epoch', tostring(State.last.epoch or '?') },
        { 'Tick ID', tostring(State.last.tickId or '?') },
        { 'Counted Drops', tostring(State.last.transportDiag
            and State.last.transportDiag.totalDrops or 0) },
        { 'Actor Sends / s', string.format('%.1f',
            tonumber(actorOutbound.attemptsPerSecond) or 0) },
        { 'Actor Publications / s', string.format('%.1f',
            tonumber(actorOutbound.logicalPerSecond) or 0) },
        { 'Actor Send Failures', tostring(
            tonumber(actorOutbound.failures) or 0) },
        { 'Actor Wire Estimate / s', string.format('%.1f KB',
            (tonumber(actorOutbound.estimatedBytesPerSecond) or 0) / 1024) },
        { 'Request TTL Expiries', tostring(State.last.schedulerMetrics
            and State.last.schedulerMetrics.requestExpiries or 0) },
        { 'Age (s)', string.format('%.2f', ageMs / 1000) },
        { 'Stale', formatBool(stale) },
    }

    renderTable('##coord_summary', rows)

    imgui.Spacing()
    imgui.Separator()

    renderLeaseBlock('Current Lease', State.last.lease)

    imgui.Spacing()
    imgui.Separator()

    imgui.Text('World State')
    local ws = State.last.worldState or {}
    local killTargetId, _, killReason =
        ActorsCoordinator.getPrimaryKillAuthorization(5)
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
        { 'Main Assist Character ID', tostring(ws.mainAssistId or '?') },
        { 'Authorized Kill Target ID', tostring(killTargetId or 'none') },
        { 'Kill Authorization', tostring(killReason or 'unknown') },
    }
    renderTable('##coord_world', wrows)

    imgui.Spacing()
    imgui.Separator()

    if imgui.CollapsingHeader('Primary Target Transport##primarytransport') then
        local actorDebug = ActorsCoordinator.getDebugState
            and ActorsCoordinator.getDebugState() or {}
        local primary = actorDebug.primaryTarget or {}
        local mainTank = primary.mainTank or {}
        local mainAssist = primary.mainAssist or {}
        local selectedAuthority = primary.selectedAuthority or {}
        local lastSend = primary.lastSend or {}
        local reasonCounts = {}
        for reason, count in pairs(primary.counts or {}) do
            reasonCounts[#reasonCounts + 1] =
                string.format('%s=%d', tostring(reason), tonumber(count) or 0)
        end
        table.sort(reasonCounts)
        renderTable('##coord_primary_transport', {
            { 'Stage', tostring(primary.stage or 'waiting') },
            { 'Reason', tostring(primary.reason or 'no_target_primary_packet') },
            { 'Age', primary.ageMs
                and string.format('%.2fs', primary.ageMs / 1000) or 'never' },
            { 'Sender', string.format('%s @ %s',
                tostring(primary.senderCharacter or '-'),
                tostring(primary.senderServer or '-')) },
            { 'Sender Route', string.format('%s:%s',
                tostring(primary.senderScript or '-'),
                tostring(primary.senderMailbox or '-')) },
            { 'Target', string.format('%s (%d)',
                tostring(primary.targetName or '-'),
                tonumber(primary.targetId) or 0) },
            { 'Claimed Tank ID', tostring(primary.claimedTankId or 0) },
            { 'EQ Main Tank', string.format('%s (%d)',
                tostring(mainTank.name or '-'), tonumber(mainTank.id) or 0) },
            { 'EQ Main Assist', string.format('%s (%d)',
                tostring(mainAssist.name or '-'), tonumber(mainAssist.id) or 0) },
            { 'Selected Assist Authority', string.format('%s (%d) via %s',
                tostring(selectedAuthority.name or '-'),
                tonumber(selectedAuthority.id) or 0,
                tostring(selectedAuthority.source or '-')) },
            { 'Zone (packet / local)', string.format('%s / %s',
                tostring(primary.packetZone or '-'),
                tostring(primary.localZone or '-')) },
            { 'Team (packet / local)', string.format('%s / %s',
                tostring(primary.packetTeam or '-'),
                tostring(primary.localTeam or '-')) },
            { 'Session / Sequence', string.format('%s / %d',
                tostring(primary.sessionId or '-'),
                tonumber(primary.sequence) or 0) },
            { 'Local Send Attempts / Failures', string.format('%d / %d',
                tonumber(lastSend.attempts) or 0,
                tonumber(lastSend.failures) or 0) },
            { 'Local Send Error', tostring(
                lastSend.lastError ~= '' and lastSend.lastError or '-') },
            { 'Event Counts', #reasonCounts > 0
                and table.concat(reasonCounts, ', ') or '-' },
        })
    end

    if imgui.CollapsingHeader('Local Actor Send Budget##actorsends') then
        local actorDebug = ActorsCoordinator.getDebugState
            and ActorsCoordinator.getDebugState() or {}
        local outbound = actorDebug.transport
            and actorDebug.transport.outbound or {}
        renderTable('##coord_actor_sends', {
            { 'Logical Publications', tostring(outbound.logical or 0) },
            { 'Physical Send Attempts', tostring(outbound.attempts or 0) },
            { 'Failures', tostring(outbound.failures or 0) },
            { 'Publications / s', string.format('%.1f',
                tonumber(outbound.logicalPerSecond) or 0) },
            { 'Sends / s', string.format('%.1f',
                tonumber(outbound.attemptsPerSecond) or 0) },
            { 'Wire Estimate / s', string.format('%.1f KB',
                (tonumber(outbound.estimatedBytesPerSecond) or 0) / 1024) },
            { 'Rate Window', string.format('%.0fs',
                tonumber(outbound.windowSeconds) or 0) },
            { 'Last Failure', tostring(outbound.lastFailure or '-') },
        })
    end

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

    if imgui.CollapsingHeader('Action Trace##actiontrace') then
        local workers = {}
        for worker in pairs(State.actionLatest) do workers[#workers + 1] = worker end
        table.sort(workers, function(a, b)
            return (moduleOrder[a] or 99) < (moduleOrder[b] or 99)
        end)
        if #workers == 0 then
            imgui.TextDisabled('No worker action transitions received')
        else
            for _, worker in ipairs(workers) do
                local trace = State.actionLatest[worker]
                local blocker = tostring(trace.blockedByModule or '')
                if blocker ~= '' and tostring(trace.blockedByStatus or '') ~= '' then
                    blocker = blocker .. '/' .. tostring(trace.blockedByStatus)
                end
                if blocker == '' then blocker = 'none' end
                imgui.BulletText(string.format(
                    '%s / %s: %s %s -> %s (%s, queue=%dms hold=%dms)',
                    worker, tostring(trace.component or worker),
                    tostring(trace.kind or ''), tostring(trace.name or ''),
                    tostring(trace.phase or '?'), tostring(trace.reason or '-'),
                    tonumber(trace.queueMs) or 0,
                    tonumber(trace.holdMs) or 0))
                imgui.TextDisabled(string.format(
                    '    Queue: scheduler=%dms  transport+observe=%dms  blocker=%s  refreshes=%d',
                    tonumber(trace.schedulerWaitMs) or 0,
                    tonumber(trace.transportObserveMs) or 0,
                    blocker,
                    tonumber(trace.requestRefreshes) or 0))
            end
        end
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
        { 'Candidates', tostring(rez.candidateCount or 0) },
        { 'Range Rejected', tostring(rez.rangeRejectedCount or 0) },
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

function M.setActionTrace(trace)
    if type(trace) ~= 'table' or tonumber(trace.version) ~= 1 then return false end
    local worker = tostring(trace.worker or '')
    local session = tostring(trace.workerSessionId or '')
    local sequence = tonumber(trace.sequence)
    if worker == '' or session == '' or not sequence then return false end
    if State.actionSessions[worker] ~= session then
        State.actionSessions[worker] = session
        State.actionSequences[worker] = 0
    end
    if sequence <= (State.actionSequences[worker] or 0) then return false end
    State.actionSequences[worker] = sequence
    State.actionLatest[worker] = trace
    local history = State.actionHistory[worker] or {}
    history[#history + 1] = trace
    while #history > 100 do table.remove(history, 1) end
    State.actionHistory[worker] = history
    return true
end

function M.getActionTraces()
    return State.actionLatest, State.actionHistory
end

--- Latest coordinator snapshot for any UI consumer. Draining here keeps
--- dashboards current even when the coordinator debug panel is never drawn.
function M.getLastState()
    M.init()
    drainStateInbox()
    return State.last, State.receivedAtMs
end

return M
