local mq = require('mq')
local actors = require('actors')
local lib = require('sidekick-next.sk_lib')

-- Coordinator-owned cross-character team presence. Actor callbacks only copy
-- packets into _pending; identity discovery, pruning, election, and sends run
-- from tick() in the coordinator coroutine.
local M = {}

local PROTOCOL_VERSION = 1
local ACTOR_ENVELOPE_VERSION = 2
local HEARTBEAT_MS = 1000
local PEER_TTL_MS = 4000
local MAX_REMOTE_TTL_MS = 15000
local SESSION_TOMBSTONE_MS = 60000
local MAX_TOMBSTONES_PER_PEER = 8
local MAX_TRACKED_PEERS = 256
local MAX_PENDING = 256
local MAX_PACKET_DEPTH = 8
local MAX_PACKET_VALUES = 2048
local MAX_PACKET_STRING = 8192

local _dropbox = nil
local _pending = {}
local _pendingKeys = {}
local _peers = {} -- [server:character] = received peer record
local _retiredSessions = {} -- [server:character][session] = expiresAtMs
local _sessionHistory = {} -- [server:character][session] = { sequence, expiresAtMs }
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
    malformed = 0,
    identityRejected = 0,
    expired = 0,
    staleSession = 0,
    duplicate = 0,
    controlRejected = 0,
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

local function tombstoneSession(key, sessionId, now)
    if sessionId == '' then return end
    local sessions = _retiredSessions[key] or {}
    sessions[sessionId] = now + SESSION_TOMBSTONE_MS
    _retiredSessions[key] = sessions
    local entries = {}
    for id, expiresAtMs in pairs(sessions) do
        entries[#entries + 1] = { id = id, expiresAtMs = expiresAtMs }
    end
    if #entries > MAX_TOMBSTONES_PER_PEER then
        table.sort(entries, function(a, b) return a.expiresAtMs < b.expiresAtMs end)
        for index = 1, (#entries - MAX_TOMBSTONES_PER_PEER) do
            sessions[entries[index].id] = nil
        end
    end
end

local function rememberSessionSequence(key, sessionId, sequence, now)
    if sessionId == '' then return end
    local sessions = _sessionHistory[key] or {}
    sessions[sessionId] = {
        sequence = tonumber(sequence) or 0,
        expiresAtMs = now + SESSION_TOMBSTONE_MS,
    }
    _sessionHistory[key] = sessions
end

local function monotonicMs()
    if mq.gettime then
        local ok, value = pcall(mq.gettime)
        if ok and tonumber(value) then return tonumber(value) end
    end
    return math.floor(os.clock() * 1000)
end

-- Actor callbacks run with yielding disabled. Copy only bounded serializable
-- values into the coroutine-owned inbox; never retain the Actor message or a
-- table owned by the transport.
local function copyPacket(value, state, depth)
    local kind = type(value)
    if kind == 'nil' or kind == 'boolean' or kind == 'number' then return value end
    if kind == 'string' then
        if #value > MAX_PACKET_STRING then return nil, 'string_too_large' end
        return value
    end
    if kind ~= 'table' then return nil, 'unsupported_value' end
    if depth >= MAX_PACKET_DEPTH then return nil, 'packet_too_deep' end
    if state.seen[value] then return nil, 'cyclic_packet' end
    state.seen[value] = true
    local result = {}
    for key, child in pairs(value) do
        local keyType = type(key)
        if keyType ~= 'string' and keyType ~= 'number' then
            state.seen[value] = nil
            return nil, 'unsupported_key'
        end
        state.values = state.values + 1
        if state.values > MAX_PACKET_VALUES then
            state.seen[value] = nil
            return nil, 'packet_too_large'
        end
        local copied, err = copyPacket(child, state, depth + 1)
        if err then
            state.seen[value] = nil
            return nil, err
        end
        result[key] = copied
    end
    state.seen[value] = nil
    return result
end

local function boundedCopy(value)
    return copyPacket(value, { seen = {}, values = 0 }, 0)
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
    local senderScript = lib.actorSenderEndpoint(sender)
    if lib.actorSenderMatches(sender,
        lib.Scripts.COORDINATOR, lib.Mailbox.TEAM) then
        senderScript = lib.Scripts.COORDINATOR
    end
    return {
        character = clean(sender.character or sender.Character),
        server = clean(sender.server or sender.Server),
        script = clean(senderScript),
        mailbox = clean(sender.mailbox or sender.Mailbox),
        account = clean(sender.account or sender.Account),
        name = clean(sender.name or sender.Name),
        uuid = clean(sender.uuid or sender.UUID),
        pid = tonumber(sender.pid or sender.PID) or 0,
    }
end

local function enqueue(message)
    local raw = message and message()
    if type(raw) ~= 'table' then
        _stats.malformed = _stats.malformed + 1
        return
    end
    local sender = normalizeSender(message.sender)
    -- Team traffic is cross-character by definition, so require the fully
    -- qualified transport identity rather than trusting payload fields.
    if sender.character == '' or sender.server == '' or sender.script == '' then
        _stats.identityRejected = _stats.identityRejected + 1
        return
    end
    if not lib.actorSenderMatches(sender,
        lib.Scripts.COORDINATOR, lib.Mailbox.TEAM) then
        _stats.identityRejected = _stats.identityRejected + 1
        return
    end
    local rawId = normalize(raw.id)
    if rawId:sub(1, 6) == 'lease:' or rawId:sub(1, 3) == 'sk:' then
        _stats.controlRejected = _stats.controlRejected + 1
        return
    end
    local content, copyErr = boundedCopy(raw)
    if not content then
        _stats.malformed = _stats.malformed + 1
        _stats.lastDropReason = copyErr or 'copy_failed'
        return
    end
    local envelope = type(content.envelope) == 'table' and content.envelope or {}
    local sessionId = clean(envelope.session or content.session or content.sessionId)
    local sequence = tonumber(envelope.sequence or content.seq or content.sequence)
    local pendingKey = nil
    if sessionId ~= '' and sequence then
        pendingKey = table.concat({
            memberKey(sender.server, sender.character),
            normalize(sender.script),
            normalize(sender.mailbox),
            sessionId,
            tostring(sequence),
        }, '|')
        if _pendingKeys[pendingKey] then
            _stats.duplicate = _stats.duplicate + 1
            return
        end
    end
    if #_pending >= MAX_PENDING then
        _stats.queueOverflow = _stats.queueOverflow + 1
        return
    end
    if pendingKey then _pendingKeys[pendingKey] = true end
    _pending[#_pending + 1] = {
        content = content,
        sender = sender,
        receivedAtMs = monotonicMs(),
        pendingKey = pendingKey,
    }
end

local function sendPacket(id, data, forcedTeamId)
    if not _dropbox then return false end
    local server = lib.getMyServer()
    local character = lib.getMyName()
    _sequence = _sequence + 1
    local zone = clean(type(data) == 'table' and data.zone or lib.getZone())
    local zoneId = safeNumber(function() return mq.TLO.Zone.ID() end)
    local instanceId = safeNumber(function() return mq.TLO.Me.Instance() end)
    local teamId = forcedTeamId or _teamId
    local sentAtMs = lib.getTimeMs()
    local envelope = {
        version = ACTOR_ENVELOPE_VERSION,
        team = teamId,
        session = _sessionId,
        sequence = _sequence,
        zone = zone,
        zoneId = zoneId,
        instanceId = instanceId,
        ttlMs = PEER_TTL_MS,
        sentAtMs = sentAtMs,
    }
    local packet = {
        id = id,
        version = ACTOR_ENVELOPE_VERSION,
        protocolVersion = PROTOCOL_VERSION,
        envelope = envelope,
        team = teamId,
        teamId = teamId,
        session = _sessionId,
        sessionId = _sessionId,
        seq = _sequence,
        sequence = _sequence,
        zone = zone,
        zoneId = zoneId,
        instanceId = instanceId,
        ttlMs = PEER_TTL_MS,
        from = character,
        server = server,
        sentAtMs = sentAtMs,
        data = data or {},
    }
    local ok, err = pcall(function()
        -- Route explicitly to the coordinator script's team mailbox. Relying on
        -- the sender's implicit current-script prefix can split peers when MQ2Lua
        -- reports equivalent launch aliases differently.
        _dropbox:send({
            mailbox = lib.Mailbox.TEAM,
            script = lib.Scripts.COORDINATOR,
            server = server,
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
    local envelope = type(content.envelope) == 'table' and content.envelope or {}
    local function recordDrop(reason)
        _stats.dropped = _stats.dropped + 1
        _stats.lastDropReason = tostring(reason or 'unknown')
        _stats.lastDroppedTeamId = clean(content.teamId)
    end
    if next(envelope) == nil then
        recordDrop('missing_envelope')
        return
    end
    if tonumber(envelope.version) ~= ACTOR_ENVELOPE_VERSION then
        recordDrop('envelope_version_mismatch')
        return
    end
    local protocolVersion = tonumber(content.protocolVersion)
    if protocolVersion ~= PROTOCOL_VERSION then
        recordDrop('protocol_mismatch')
        return
    end
    if next(envelope) ~= nil then
        if clean(content.teamId) ~= '' and clean(content.teamId) ~= clean(envelope.team) then
            recordDrop('envelope_team_mismatch')
            return
        end
        if clean(content.zone) ~= '' and clean(envelope.zone) ~= ''
            and normalize(content.zone) ~= normalize(envelope.zone) then
            recordDrop('envelope_zone_mismatch')
            return
        end
    end

    local id = normalize(content.id)
    if id:sub(1, 6) == 'lease:' or id:sub(1, 3) == 'sk:' then
        _stats.controlRejected = _stats.controlRejected + 1
        recordDrop('remote_control_rejected')
        return
    end
    if id ~= 'team:state' and id ~= 'team:leave' then
        recordDrop('unknown_message')
        return
    end
    local packetTeam = clean(envelope.team or content.team or content.teamId)
    if packetTeam == '' or packetTeam ~= _teamId then
        recordDrop('team_id_mismatch')
        return
    end

    -- Payload identity is informational only. The Actor post office supplies a
    -- fully qualified sender address; use it as the authority and reject
    -- contradictory claims.
    local character = clean(entry.sender.character)
    local server = clean(entry.sender.server)
    local senderScript = clean(entry.sender.script)
    if character == '' or server == '' then
        _stats.identityRejected = _stats.identityRejected + 1
        recordDrop('identity_missing')
        return
    end
    if normalize(senderScript) ~= normalize(lib.Scripts.COORDINATOR) then
        _stats.identityRejected = _stats.identityRejected + 1
        recordDrop('wrong_sender_script')
        return
    end
    if normalize(server) ~= normalize(lib.getMyServer()) then
        _stats.identityRejected = _stats.identityRejected + 1
        recordDrop('server_mismatch')
        return
    end
    if clean(content.from) ~= '' and normalize(content.from) ~= normalize(character) then
        _stats.identityRejected = _stats.identityRejected + 1
        recordDrop('payload_character_mismatch')
        return
    end
    if clean(content.server) ~= '' and normalize(content.server) ~= normalize(server) then
        _stats.identityRejected = _stats.identityRejected + 1
        recordDrop('payload_server_mismatch')
        return
    end

    local ttlMs = tonumber(envelope.ttlMs or content.ttlMs) or PEER_TTL_MS
    ttlMs = math.max(1, math.min(ttlMs, MAX_REMOTE_TTL_MS))
    local receivedAtMs = tonumber(entry.receivedAtMs) or now
    if (now - receivedAtMs) > ttlMs then
        _stats.expired = _stats.expired + 1
        recordDrop('expired_in_inbox')
        return
    end

    local key = memberKey(server, character)
    if key == memberKey(lib.getMyServer(), lib.getMyName()) then return end

    local sessionId = clean(envelope.session or content.session or content.sessionId)
    local sequence = tonumber(envelope.sequence or content.seq or content.sequence) or 0
    if sessionId == '' or sequence <= 0 then
        recordDrop('envelope_incomplete')
        return
    end

    local tombstones = _retiredSessions[key]
    if tombstones and sessionId ~= '' and (tombstones[sessionId] or 0) > now then
        _stats.staleSession = _stats.staleSession + 1
        recordDrop('retired_session')
        return
    end

    local previous = _peers[key]
    if not previous and id == 'team:state' then
        local peerCount = 0
        for _ in pairs(_peers) do peerCount = peerCount + 1 end
        if peerCount >= MAX_TRACKED_PEERS then
            recordDrop('peer_limit')
            return
        end
    end
    if previous and previous.sessionId == sessionId and sequence <= (previous.sequence or 0) then
        recordDrop('stale_sequence')
        return
    end
    local history = _sessionHistory[key]
    local historical = history and history[sessionId] or nil
    if not previous and historical then
        if sequence <= (historical.sequence or 0) then
            recordDrop('stale_sequence')
            return
        end
        history[sessionId] = nil
    elseif not previous and history and sessionId ~= '' then
        -- A genuinely new session supersedes any recently expired session,
        -- while a resumed session with a higher sequence was handled above.
        for oldSessionId in pairs(history) do
            if oldSessionId ~= sessionId then
                tombstoneSession(key, oldSessionId, now)
            end
        end
        _sessionHistory[key] = nil
    end
    if previous and previous.sessionId ~= '' and previous.sessionId ~= sessionId then
        tombstoneSession(key, previous.sessionId, now)
    end

    if id == 'team:leave' then
        if previous and previous.sessionId == sessionId then
            _peers[key] = nil
        end
        if sessionId ~= '' then
            tombstoneSession(key, sessionId, now)
        end
        if _sessionHistory[key] then _sessionHistory[key][sessionId] = nil end
        _stats.received = _stats.received + 1
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
        expiresAtMs = now + ttlMs,
        zone = clean(envelope.zone or content.zone or data.zone),
        zoneId = tonumber(envelope.zoneId or content.zoneId) or 0,
        instanceId = tonumber(envelope.instanceId or content.instanceId) or 0,
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
        lease = type(data.lease) == 'table' and data.lease or nil,
        modules = type(data.modules) == 'table' and data.modules or {},
    }
    _stats.received = _stats.received + 1
end

local function drainAndPrune(now)
    local pending = _pending
    _pending = {}
    for _, entry in ipairs(pending) do
        if entry.pendingKey then _pendingKeys[entry.pendingKey] = nil end
        processPacket(entry, now)
    end

    for key, peer in pairs(_peers) do
        if now > (peer.expiresAtMs or ((peer.receivedAtMs or 0) + PEER_TTL_MS)) then
            if peer.sessionId and peer.sessionId ~= '' then
                rememberSessionSequence(key, peer.sessionId, peer.sequence, now)
            end
            _peers[key] = nil
            _stats.pruned = _stats.pruned + 1
        end
    end
    for key, sessions in pairs(_retiredSessions) do
        local any = false
        for sessionId, expiresAtMs in pairs(sessions) do
            if expiresAtMs <= now then
                sessions[sessionId] = nil
            else
                any = true
            end
        end
        if not any then _retiredSessions[key] = nil end
    end
    for key, sessions in pairs(_sessionHistory) do
        local any = false
        for sessionId, state in pairs(sessions) do
            if (state.expiresAtMs or 0) <= now then
                sessions[sessionId] = nil
            else
                any = true
            end
        end
        if not any then _sessionHistory[key] = nil end
    end
    local function trimKeys(map, timestamp)
        local entries = {}
        for key, value in pairs(map) do
            entries[#entries + 1] = { key = key, at = timestamp(value) }
        end
        if #entries <= MAX_TRACKED_PEERS then return end
        table.sort(entries, function(a, b) return a.at < b.at end)
        for index = 1, (#entries - MAX_TRACKED_PEERS) do
            map[entries[index].key] = nil
        end
    end
    trimKeys(_retiredSessions, function(sessions)
        local latest = 0
        for _, expiresAtMs in pairs(sessions) do latest = math.max(latest, expiresAtMs) end
        return latest
    end)
    trimKeys(_sessionHistory, function(sessions)
        local latest = 0
        for _, state in pairs(sessions) do
            latest = math.max(latest, state.expiresAtMs or 0)
        end
        return latest
    end)
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
    local lease = data.lease or {}
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
        clean(lease.holderModule),
        clean(lease.requestId),
        clean(lease.status),
        tostring(lease.tier or ''),
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
    local now = monotonicMs()

    local nextTeamId, nextLabel, nextMode, nextHint, reason = discoverTeam(settings)
    _enabled = settings.ActorsTeamEnabled ~= false and nextTeamId ~= ''
    if nextTeamId ~= _teamId then
        local oldTeamId = _teamId
        if oldTeamId ~= '' then sendPacket('team:leave', {}, oldTeamId) end
        _teamId = nextTeamId
        _peers = {}
        _retiredSessions = {}
        _sessionHistory = {}
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
        lease = type(snapshot.lease) == 'table' and snapshot.lease or nil,
        modules = type(snapshot.modules) == 'table' and snapshot.modules or {},
    }
    _leaderKey = electLeader()

    if not _enabled or not _dropbox then return end
    local signature = stateSignature(_local)
    if signature ~= _lastSignature or (now - _lastSendAtMs) >= HEARTBEAT_MS then
        local payload = {}
        for key, value in pairs(_local) do
            if key ~= 'key' and key ~= 'receivedAtMs' and key ~= 'sessionId' and key ~= 'sequence' then
                payload[key] = value
            end
        end
        if sendPacket('team:state', payload) then
            _local.sequence = _sequence
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
    local now = monotonicMs()
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
        envelopeVersion = ACTOR_ENVELOPE_VERSION,
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
            malformed = _stats.malformed,
            identityRejected = _stats.identityRejected,
            expired = _stats.expired,
            staleSession = _stats.staleSession,
            duplicate = _stats.duplicate,
            controlRejected = _stats.controlRejected,
            lastDropReason = _stats.lastDropReason,
            lastDroppedTeamId = _stats.lastDroppedTeamId,
        },
    }
end

function M.getTeamId()
    if not _enabled then return '' end
    return _teamId
end

--- Pure local team discovery for gateway instances that do not own the team
--- mailbox (for example the UI and worker scripts). This does not register,
--- send, elect, or mutate peer state.
function M.discoverTeamId(settings)
    local teamId = discoverTeam(settings)
    return teamId
end

function M.isMember(server, character)
    if not _enabled then return false end
    local key = memberKey(server, character)
    if key == memberKey(lib.getMyServer(), lib.getMyName()) then return true end
    return _peers[key] ~= nil
end

function M.shutdown()
    if _teamId ~= '' then sendPacket('team:leave', {}) end
    if _dropbox and _dropbox.unregister then
        pcall(function() _dropbox:unregister() end)
    end
    _dropbox = nil
    _initialized = false
    _pending = {}
    _pendingKeys = {}
    _peers = {}
    _retiredSessions = {}
    _sessionHistory = {}
end

return M
