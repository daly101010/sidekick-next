local mq = require('mq')
local actors = require('actors')
local lib = require('sidekick-next.sk_lib')

-- Coordinator-owned cross-character team presence. Actor callbacks only copy
-- packets into _pending; identity discovery, pruning, election, and sends run
-- from tick() in the coordinator coroutine.
local M = {}

local PROTOCOL_VERSION = 1
local HEARTBEAT_MS = 1000
local PEER_TTL_MS = 4000
local MAX_PENDING = 256

local _dropbox = nil
local _pending = {}
local _peers = {} -- [server:character] = received peer record
local _local = {}
local _teamId = ''
local _teamLabel = ''
local _teamMode = 'auto'
local _teamReason = 'not_initialized'
local _leaderHint = ''
local _leaderKey = ''
local _sessionId = ''
local _sequence = 0
local _lastSendAtMs = 0
local _lastSignature = ''
local _lastError = nil
local _initialized = false
local _enabled = true
local _stats = {
    sent = 0,
    received = 0,
    dropped = 0,
    pruned = 0,
    queueOverflow = 0,
    lastDropReason = '',
    lastDroppedTeamId = '',
}

local function clean(value)
    value = tostring(value or '')
    if value == 'NULL' then return '' end
    return value
end

local function normalize(value)
    return clean(value):lower():gsub('^%s+', ''):gsub('%s+$', '')
end

local function idPart(value)
    value = normalize(value)
    value = value:gsub('[^%w_.%-]+', '_')
    return value:gsub('^_+', ''):gsub('_+$', '')
end

local function memberKey(server, character)
    return normalize(server) .. ':' .. normalize(character)
end

local function safeText(fn)
    local ok, value = pcall(fn)
    if not ok then return '' end
    return clean(value)
end

local function safeNumber(fn)
    local ok, value = pcall(fn)
    if not ok then return 0 end
    return tonumber(value) or 0
end

local function groupLeader()
    return safeText(function() return mq.TLO.Group.Leader.Name() end)
end

local function raidLeader()
    local name = safeText(function() return mq.TLO.Raid.Leader.Name() end)
    if name ~= '' then return name end
    return safeText(function() return mq.TLO.Raid.Leader() end)
end

local function discoverTeam(settings)
    settings = settings or {}
    local configured = settings.ActorsTeamEnabled ~= false
    if not configured then return '', '', 'disabled', '', 'disabled' end

    local server = lib.getMyServer()
    local character = lib.getMyName()
    if server == '' or character == '' then
        return _teamId, _teamLabel, _teamMode, _leaderHint, 'identity_unavailable'
    end
    if not lib.isInGame() and _teamId ~= '' then
        return _teamId, _teamLabel, _teamMode, _leaderHint, 'zoning'
    end

    local mode = normalize(settings.ActorsTeamMode)
    if mode == '' then mode = 'auto' end
    local manualName = clean(settings.ActorsTeamName)
    local scope = mode
    local anchor = ''
    local hint = ''

    if mode == 'manual' then
        anchor = manualName
        -- A manual team may span unrelated EQ groups, so there is no shared
        -- game leader to prefer. All members must use the same lexical vote.
        hint = ''
        if idPart(anchor) == '' then
            return '', '', mode, '', 'manual_name_required'
        end
    elseif mode == 'raid' then
        anchor = raidLeader()
        hint = anchor
        if anchor == '' then
            return '', '', mode, '', 'raid_leader_unavailable'
        end
    elseif mode == 'group' then
        anchor = groupLeader()
        hint = anchor
        if anchor == '' then
            return '', '', mode, '', 'group_leader_unavailable'
        end
    else
        mode = 'auto'
        if safeNumber(function() return mq.TLO.Raid.Members() end) > 0 then
            scope = 'raid'
            anchor = raidLeader()
            hint = anchor
        elseif safeNumber(function() return mq.TLO.Group.Members() end) > 0 then
            scope = 'group'
            anchor = groupLeader()
            hint = anchor
        else
            scope = 'solo'
            anchor = character
            hint = character
        end
        if anchor == '' then
            -- Preserve a stable team during short zone/TLO gaps.
            return _teamId, _teamLabel, mode, _leaderHint, 'identity_degraded'
        end
    end

    local teamId = string.format('skteam:v%d:%s:%s:%s',
        PROTOCOL_VERSION, idPart(server), idPart(scope), idPart(anchor))
    local label = mode == 'manual' and manualName or string.format('%s: %s', scope, anchor)
    return teamId, label, mode, hint, 'active'
end

local function normalizeSender(sender)
    sender = sender or {}
    return {
        character = clean(sender.character or sender.Character),
        server = clean(sender.server or sender.Server),
        script = clean(sender.script or sender.Script),
        mailbox = clean(sender.mailbox or sender.Mailbox),
    }
end

local function enqueue(message)
    local content = message()
    if type(content) ~= 'table' then return end
    if #_pending >= MAX_PENDING then
        table.remove(_pending, 1)
        _stats.queueOverflow = _stats.queueOverflow + 1
    end
    _pending[#_pending + 1] = {
        content = content,
        sender = normalizeSender(message.sender),
    }
end

local function sendPacket(id, data, forcedTeamId)
    if not _dropbox then return false end
    local server = lib.getMyServer()
    local character = lib.getMyName()
    local packet = {
        id = id,
        protocolVersion = PROTOCOL_VERSION,
        teamId = forcedTeamId or _teamId,
        sessionId = _sessionId,
        sequence = _sequence,
        from = character,
        server = server,
        sentAtMs = lib.getTimeMs(),
        data = data or {},
    }
    local ok, err = pcall(function()
        -- Route explicitly to the coordinator script's team mailbox. Relying on
        -- the sender's implicit current-script prefix can split peers when MQ2Lua
        -- reports equivalent launch aliases differently.
        _dropbox:send({
            mailbox = lib.Mailbox.TEAM,
            script = lib.Scripts.COORDINATOR,
        }, packet)
    end)
    if ok then
        _stats.sent = _stats.sent + 1
        _lastError = nil
    else
        _lastError = tostring(err)
    end
    return ok
end

local function processPacket(entry, now)
    local content = entry.content or {}
    local function recordDrop(reason)
        _stats.dropped = _stats.dropped + 1
        _stats.lastDropReason = tostring(reason or 'unknown')
        _stats.lastDroppedTeamId = clean(content.teamId)
    end
    if tonumber(content.protocolVersion) ~= PROTOCOL_VERSION then
        recordDrop('protocol_mismatch')
        return
    end

    local id = normalize(content.id)
    if id ~= 'team:state' and id ~= 'team:leave' then
        recordDrop('unknown_message')
        return
    end
    if clean(content.teamId) == '' or clean(content.teamId) ~= _teamId then
        recordDrop('team_id_mismatch')
        return
    end

    local character = clean(content.from or entry.sender.character)
    local server = clean(content.server or entry.sender.server)
    if character == '' or server == '' then
        recordDrop('identity_missing')
        return
    end

    local key = memberKey(server, character)
    if key == memberKey(lib.getMyServer(), lib.getMyName()) then return end
    if id == 'team:leave' then
        _peers[key] = nil
        _stats.received = _stats.received + 1
        return
    end

    local sessionId = clean(content.sessionId)
    local sequence = tonumber(content.sequence) or 0
    local previous = _peers[key]
    if previous and previous.sessionId == sessionId and sequence <= (previous.sequence or 0) then
        recordDrop('stale_sequence')
        return
    end

    local data = type(content.data) == 'table' and content.data or {}
    _peers[key] = {
        key = key,
        character = character,
        server = server,
        sessionId = sessionId,
        sequence = sequence,
        receivedAtMs = now,
        zone = clean(data.zone),
        class = clean(data.class),
        role = clean(data.role),
        leaderHint = clean(data.leaderHint),
        inGame = data.inGame == true,
        inCombat = data.inCombat == true,
        dead = data.dead == true,
        incapacitated = data.incapacitated == true,
        automationPaused = data.automationPaused == true,
        activePriority = tonumber(data.activePriority),
        targetId = tonumber(data.targetId) or 0,
        targetType = clean(data.targetType),
        targetName = clean(data.targetName),
        action = type(data.action) == 'table' and data.action or nil,
        modules = type(data.modules) == 'table' and data.modules or {},
    }
    _stats.received = _stats.received + 1
end

local function drainAndPrune(now)
    local pending = _pending
    _pending = {}
    for _, entry in ipairs(pending) do processPacket(entry, now) end

    for key, peer in pairs(_peers) do
        if (now - (peer.receivedAtMs or 0)) > PEER_TTL_MS then
            _peers[key] = nil
            _stats.pruned = _stats.pruned + 1
        end
    end
end

local function electLeader()
    local candidates = {}
    local selfKey = memberKey(lib.getMyServer(), lib.getMyName())
    if selfKey ~= ':' then candidates[selfKey] = _local end
    for key, peer in pairs(_peers) do candidates[key] = peer end

    local hint = normalize(_leaderHint)
    if hint ~= '' then
        for key, member in pairs(candidates) do
            if normalize(member.character) == hint then return key end
        end
    end

    local winner = ''
    for key in pairs(candidates) do
        if winner == '' or key < winner then winner = key end
    end
    return winner
end

local function stateSignature(data)
    local action = data.action or {}
    return table.concat({
        _teamId,
        clean(data.zone),
        clean(data.class),
        clean(data.role),
        tostring(data.inGame == true),
        tostring(data.inCombat == true),
        tostring(data.dead == true),
        tostring(data.incapacitated == true),
        tostring(data.automationPaused == true),
        tostring(data.activePriority or ''),
        tostring(data.targetId or 0),
        clean(data.targetType),
        clean(data.targetName),
        clean(action.module),
        clean(action.kind),
        clean(action.name),
        clean(action.phase),
    }, '|')
end

function M.init()
    if _initialized then return _dropbox end
    _initialized = true
    _sessionId = string.format('%s:%s:%d:%d',
        idPart(lib.getMyServer()), idPart(lib.getMyName()), os.time(), lib.getTimeMs())
    local ok, result = pcall(function()
        return actors.register(lib.Mailbox.TEAM, enqueue)
    end)
    if ok then
        _dropbox = result
        _lastError = nil
    else
        _lastError = tostring(result)
    end
    return _dropbox
end

function M.tick(snapshot, settings)
    if not _initialized then M.init() end
    snapshot = type(snapshot) == 'table' and snapshot or {}
    settings = type(settings) == 'table' and settings or {}
    local now = lib.getTimeMs()

    local nextTeamId, nextLabel, nextMode, nextHint, reason = discoverTeam(settings)
    _enabled = settings.ActorsTeamEnabled ~= false and nextTeamId ~= ''
    if nextTeamId ~= _teamId then
        local oldTeamId = _teamId
        if oldTeamId ~= '' then sendPacket('team:leave', {}, oldTeamId) end
        _teamId = nextTeamId
        _peers = {}
        _sequence = 0
        _lastSendAtMs = 0
        _lastSignature = ''
    end
    _teamLabel = nextLabel
    _teamMode = nextMode
    _teamReason = reason
    _leaderHint = nextHint

    drainAndPrune(now)

    _local = {
        key = memberKey(lib.getMyServer(), lib.getMyName()),
        character = lib.getMyName(),
        server = lib.getMyServer(),
        sessionId = _sessionId,
        sequence = _sequence,
        receivedAtMs = now,
        zone = clean(snapshot.zone),
        class = clean(snapshot.class),
        role = clean(snapshot.role),
        leaderHint = _leaderHint,
        inGame = snapshot.inGame == true,
        inCombat = snapshot.inCombat == true,
        dead = snapshot.dead == true,
        incapacitated = snapshot.incapacitated == true,
        automationPaused = snapshot.automationPaused == true,
        activePriority = tonumber(snapshot.activePriority),
        targetId = tonumber(snapshot.targetId) or 0,
        targetType = clean(snapshot.targetType),
        targetName = clean(snapshot.targetName),
        action = type(snapshot.action) == 'table' and snapshot.action or nil,
        modules = type(snapshot.modules) == 'table' and snapshot.modules or {},
    }
    _leaderKey = electLeader()

    if not _enabled or not _dropbox then return end
    local signature = stateSignature(_local)
    if signature ~= _lastSignature or (now - _lastSendAtMs) >= HEARTBEAT_MS then
        _sequence = _sequence + 1
        _local.sequence = _sequence
        local payload = {}
        for key, value in pairs(_local) do
            if key ~= 'key' and key ~= 'receivedAtMs' and key ~= 'sessionId' and key ~= 'sequence' then
                payload[key] = value
            end
        end
        if sendPacket('team:state', payload) then
            _lastSendAtMs = now
            _lastSignature = signature
        end
    end
end

function M.getSnapshot()
    local members = {}
    if _local.character and _local.character ~= '' then
        local selfCopy = {}
        for key, value in pairs(_local) do selfCopy[key] = value end
        selfCopy.self = true
        selfCopy.ageMs = 0
        members[#members + 1] = selfCopy
    end
    local now = lib.getTimeMs()
    for _, peer in pairs(_peers) do
        local copy = {}
        for key, value in pairs(peer) do copy[key] = value end
        copy.self = false
        copy.ageMs = math.max(0, now - (peer.receivedAtMs or now))
        members[#members + 1] = copy
    end
    table.sort(members, function(a, b) return clean(a.key) < clean(b.key) end)

    local leaderName = ''
    for _, member in ipairs(members) do
        if member.key == _leaderKey then
            leaderName = member.character or ''
            break
        end
    end
    local selfKey = memberKey(lib.getMyServer(), lib.getMyName())
    return {
        protocolVersion = PROTOCOL_VERSION,
        enabled = _enabled,
        ready = _dropbox ~= nil,
        mode = _teamMode,
        reason = _teamReason,
        teamId = _teamId,
        label = _teamLabel,
        leader = leaderName,
        leaderKey = _leaderKey,
        isLeader = _leaderKey ~= '' and _leaderKey == selfKey,
        peerCount = #members > 0 and (#members - 1) or 0,
        memberCount = #members,
        members = members,
        lastError = _lastError,
        stats = {
            sent = _stats.sent,
            received = _stats.received,
            dropped = _stats.dropped,
            pruned = _stats.pruned,
            queueOverflow = _stats.queueOverflow,
            lastDropReason = _stats.lastDropReason,
            lastDroppedTeamId = _stats.lastDroppedTeamId,
        },
    }
end

function M.shutdown()
    if _teamId ~= '' then sendPacket('team:leave', {}) end
    if _dropbox and _dropbox.unregister then
        pcall(function() _dropbox:unregister() end)
    end
    _dropbox = nil
    _initialized = false
    _pending = {}
    _peers = {}
end

return M
