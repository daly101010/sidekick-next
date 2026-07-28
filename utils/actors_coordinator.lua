local mq = require('mq')
local lib = require('sidekick-next.sk_lib')
local CoordinationPolicy = require('sidekick-next.utils.coordination_policy')

-- Lazy-loaded so we don't trigger a circular require during actors init.
local _ledger = nil
local function ledger()
    if _ledger == nil then
        local ok, mod = pcall(require, 'sidekick-next.utils.claim_ledger')
        _ledger = ok and mod or false
    end
    return _ledger or nil
end

-- Map an actor message id to a ledger category. Returns nil for messages we
-- don't track in the ledger (status, bounds, mezlist, etc.).
local CLAIM_CATEGORIES = {
    ['cc:claim']        = 'cc_claim',
    ['debuff:claim']    = 'debuff_claim',
    ['debuff:landed']   = 'debuff_landed',
    ['heal:claim']      = 'heal_claim',
    ['heal:landed']     = 'heal_landed',
    ['heal:cancelled']  = 'heal_cancelled',
    ['buff:claim']      = 'buff_claim',
    ['buff:landed']     = 'buff_landed',
    ['cure:claim']      = 'cure_claim',
    ['cure:landed']     = 'cure_landed',
    ['rez:claim']       = 'rez_claim',
    ['rez:completed']   = 'rez_landed',
}

local M = {}

local ACTOR_ENVELOPE_VERSION = 2
M.ENVELOPE_VERSION = ACTOR_ENVELOPE_VERSION
local TELEMETRY_VERSION = 1
local WORKER_COMMAND_VERSION = 1
M.TELEMETRY_VERSION = TELEMETRY_VERSION
M.WORKER_COMMAND_VERSION = WORKER_COMMAND_VERSION
local DEFAULT_MESSAGE_TTL_MS = 8000
local MAX_MESSAGE_TTL_MS = 30000
local SESSION_TOMBSTONE_MS = 60000
local PEER_SESSION_IDLE_MS = 120000
local MAX_TRACKED_ENDPOINTS = 512
local MAX_TOMBSTONES_PER_ENDPOINT = 8
local MAX_TOPICS_PER_ENDPOINT = 128
local MAX_PENDING_MESSAGES = math.max(1,
    tonumber(CoordinationPolicy.MESSAGE_QUEUE.MAX_PENDING) or 256)
local MAX_PACKET_DEPTH = 8
local MAX_PACKET_VALUES = 4096
local MAX_PACKET_STRING = 16384

local _actors = nil
local _dropbox = nil
local _statusDropbox = nil
local _selfName = ''
local _selfServer = ''
local _selfZone = ''
local _selfNameLower = ''
local _selfServerLower = ''
local _trustedTeamId = ''
local _trustedTeamMembers = nil
local _trustedTeamSnapshot = nil
local _teamPresenceHistory = {}

-- Peer publications declare their delivery contract once. Callers never
-- choose between implicit same-script routing and fleet fan-out.
local TOPIC_CONTRACTS = {
    -- Cross-script operational state.
    ['target:primary'] = { scope = 'fleet' },
    ['tank:repositioning'] = { scope = 'fleet' },
    ['tank:settled'] = { scope = 'fleet' },
    ['tank:taunt_run'] = { scope = 'fleet' },
    ['tank:taunt_done'] = { scope = 'fleet' },
    ['tank:mode'] = { scope = 'fleet' }, -- dead: contract reserved for a future tank-mode broadcast (receiver exists at line 1766)
    ['tank:camp_anchor'] = { scope = 'fleet' },
    ['cc:mezlist'] = { scope = 'fleet' },
    ['cc:claim'] = { scope = 'fleet' },
    ['cc:charmpet'] = { scope = 'fleet' },
    ['pull:intent'] = { scope = 'fleet' },
    ['pull:incoming'] = { scope = 'fleet' },
    ['mobhp:update'] = { scope = 'fleet' },
    ['assist:me'] = { scope = 'fleet' },

    -- Same-role coordination between matching worker scripts.
    ['heal:hots'] = { scope = 'same_script' },
    ['heal:incoming'] = { scope = 'same_script' },
    ['heal:landed'] = { scope = 'same_script' },
    ['heal:cancelled'] = { scope = 'same_script' },
    ['heal:claim'] = { scope = 'same_script' },
    ['buff:list'] = { scope = 'same_script' },
    ['buff:blocks'] = { scope = 'same_script' },
    ['buff:claim'] = { scope = 'same_script' },
    ['buff:landed'] = { scope = 'same_script' },
    -- User/UI requests are consumed by the Buff component in Maintenance.
    ['buff:need'] = { scope = 'fleet' },
    ['cure:claim'] = { scope = 'same_script' },
    ['cure:landed'] = { scope = 'same_script' },
    ['cure:capabilities'] = { scope = 'same_script' },
    ['debuff:claim'] = { scope = 'same_script' },
    ['debuff:release'] = { scope = 'same_script' },
    ['debuff:landed'] = { scope = 'same_script' },
    ['rez:claim'] = { scope = 'same_script' },
    ['rez:cancelled'] = { scope = 'same_script' },
    ['rez:completed'] = { scope = 'same_script' },

    -- Explicit presence overlays. Actor Team is the base presence/trust plane.
    ['peer:vitals'] = { scope = 'same_script' }, -- dynamic: published via M.publish(statusTopic, ...) with dynamic topic
    ['peer:capabilities'] = { scope = 'same_script' }, -- dynamic: published via M.publish(statusTopic, ...) with dynamic topic
}
M.TOPIC_CONTRACTS = {}
for topic, contract in pairs(TOPIC_CONTRACTS) do
    M.TOPIC_CONTRACTS[topic] = { scope = contract.scope }
end

-- Sender-identity + monotonic sequence guard for last-write-wins state topics.
-- The topics in GUARDED_TOPICS have historically overwritten each other in
-- receive order regardless of send order; a same-sender packet arriving late
-- (network jitter, MQ delay) could clobber a fresher one. Sequence gating fixes
-- that within a session. sessionId lets peers accept messages again after a
-- sender restart (new session -> reset expected sequence).
--
-- Wire fields: `from` (existing sender-name field on every fleet publication
-- payload), `sessionId`, `sequence`. Old-format messages without sessionId
-- are still accepted — rolling restarts stay safe.
local GUARDED_TOPICS = {
    ['target:primary'] = true,
    ['tank:repositioning'] = true,
    ['tank:settled'] = true,
    ['tank:taunt_run'] = true,
    ['tank:taunt_done'] = true,
    ['tank:mode'] = true,
    ['tank:camp_anchor'] = true,
    ['cc:charmpet'] = true,
    ['pull:intent'] = true,
}
local _mySessionId = ''
local _outgoingSequence = 0
local _topicSeenSeq = {}   -- [topic] = { [sender_key] = { sessionId, sequence } }
-- Session fencing is endpoint-wide, but ordering is topic-local. The sender's
-- envelope sequence is global across topics, so comparing one endpoint-wide
-- high-water mark would reject a valid earlier packet when two different
-- topics arrive out of order.
local _peerSessions = {}
-- [endpoint] = {
--   sessionId, receivedAtMs,
--   topics = { [messageId] = { sequence, seenAtMs } },
-- }
local _retiredSessions = {} -- [endpoint][sessionId] = local expiry ms
local _transportStats = {
    received = 0,
    dropped = 0,
    queueOverflow = 0,
    malformed = 0,
    identityRejected = 0,
    expired = 0,
    duplicate = 0,
    staleSession = 0,
    controlRejected = 0,
    lastDropReason = '',
    byReason = {},
}
local SEND_RATE_WINDOW_MS = 10000
local MAX_SEND_RATE_EVENTS = 4096
local _outboundStats = {
    logical = 0,
    attempts = 0,
    failures = 0,
    estimatedBytes = 0,
    lastFailure = '',
    byTopic = {},
    byScope = {},
    recent = {},
    recentHead = 1,
    recentCount = 0,
}
local _primaryTargetDiag = {
    stage = 'waiting',
    reason = 'no_target_primary_packet',
    updatedAtMs = 0,
    counts = {},
}

local EXTERNAL_MESSAGE_IDS = {
    ['status:req'] = true,
    ['window:bounds'] = true,
    ['gt:settings_open'] = true,
    ['eq_ui:automation:req'] = true,
}

local function monotonicMs()
    if mq.gettime then
        local ok, value = pcall(mq.gettime)
        if ok and tonumber(value) then return tonumber(value) end
    end
    return math.floor(os.clock() * 1000)
end

-- Copy bounded Actor-safe values while the non-yieldable callback is active.
-- This prevents transport-owned tables or unexpectedly large packets from
-- escaping into the main coroutine.
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

local function ensureSessionId()
    if _mySessionId ~= '' then return _mySessionId end
    local server = tostring(_selfServer or ''):gsub('%s+', '')
    local name = tostring(_selfName or ''):gsub('%s+', '')
    if server == '' or name == '' then return '' end
    _mySessionId = string.format('%s:%s:%d:%d', server, name, os.time(), mq.gettime and mq.gettime() or 0)
    return _mySessionId
end

local function nextSeq(topic)
    _outgoingSequence = _outgoingSequence + 1
    return _outgoingSequence
end

--- Returns true if the incoming guarded message is stale (same sender, same
--- session, sequence <= last accepted). Missing sessionId/sequence -> accept
--- (backwards compat).
local function isStaleGuardedMessage(topic, content, sender)
    if not GUARDED_TOPICS[topic] then return false end
    local senderKey = table.concat({
        tostring(sender and sender.server or ''):lower(),
        tostring(sender and sender.character or ''):lower(),
        tostring(sender and sender.script or ''):lower(),
    }, ':')
    if senderKey == '::' then return false end
    local sessionId = content and content.sessionId
    local sequence = content and tonumber(content.sequence)
    if not sessionId or not sequence then return false end
    local table_ = _topicSeenSeq[topic]
    if not table_ then
        table_ = {}
        _topicSeenSeq[topic] = table_
    end
    local prev = table_[senderKey]
    if prev and prev.sessionId == sessionId and sequence <= prev.sequence then
        return true
    end
    table_[senderKey] = {
        sessionId = sessionId,
        sequence = sequence,
        seenAtMs = monotonicMs(),
    }
    local entries = {}
    for key, state in pairs(table_) do
        entries[#entries + 1] = { key = key, at = state.seenAtMs or 0 }
    end
    if #entries > MAX_TRACKED_ENDPOINTS then
        table.sort(entries, function(a, b) return a.at < b.at end)
        for index = 1, (#entries - MAX_TRACKED_ENDPOINTS) do
            table_[entries[index].key] = nil
        end
    end
    return false
end
local _actorsInitError = nil
local _lastGroupTargetMsgAt = 0
local _lastGroupTargetMsgId = ''
local _lastBoundsReqAt = 0
local _lastSendErr = nil
local _lastSendResult = nil
local _lastSendDbgAt = 0
local _lastTickDbgAt = 0
local _pendingActorMessages = {}
local _pendingActorKeys = {}
local _processActorMessage = nil

local _lastDockedSendAt = 0
local _lastStatusSendAt = 0
local _remoteCharacters = {}
local _lastStatusPayload = nil
local _lastStatusSignature = nil

-- Healing coordination state (claims + HoT presence)
local _healClaims = {} -- [targetId][from] = { spellName, tier, expiresAt, claimedAt }
local _hotStates = {}  -- [targetId][from] = { spellName, expiresAt }
local HEAL_CLAIM_TTL = 5.0        -- Default claim lifetime (seconds)
local HOT_DEFAULT_TTL = 18.0      -- Default HoT tracking lifetime
local HEAL_CLAIM_MAX_TTL = 15.0
local HOT_MAX_TTL = 600.0
local PRUNE_INTERVAL = 1.0        -- How often to prune stale claims
local _lastPruneAt = 0

-- Forward declaration (defined after message handlers, used in tick)
local pruneHealTables

-- Healing message callbacks (registered by healing module to avoid circular require)
local _healingCallbacks = {}
local _messageCallbacks = {}
local _telemetryCallbacks = {}
local _workerCommandCallbacks = {}
local _telemetrySequence = 0
local _workerCommandSequence = 0

-- Tank coordination state
local _tankState = {
    primaryTargetId = nil,
    primaryTargetName = nil,
    killAuthorized = false,
    primaryRevision = nil,
    currentTargetId = nil,
    tankMode = nil,
    tankId = nil,
    tankName = nil,
    updatedAt = 0,
    campAnchor = nil,   -- { x, y, z, from, updatedAt } from tank:camp_anchor
}

-- Cooperative puller election. Every enabled pull worker periodically
-- broadcasts pull:intent with its startedAt timestamp. Peers with a later
-- startedAt yield to peers with earlier startedAt in the same zone. Not a
-- hard election (no coordinator claim) — just a signal to keep two enabled
-- pull workers from both pulling.
local _pullPeers = {}  -- [sender_key] = { from, startedAt, zone, updatedAt }
local PULLER_TTL_SEC = 6.0  -- broadcast every ~2s; three misses => TTL out

-- Charm-pet protection state. The charming enchanter broadcasts its pet's
-- spawn ID so every worker in the group treats that mob as off-limits: DPS
-- must not kill it (even mid charm-break, when it briefly reappears as a
-- hater) and the tank protects the enchanter with damageless aggro only.
local _charmStates = {} -- [server:owner] = { petId, petName, ownerName, ... }

-- Pull coordination state (tank's pull monitor broadcasts; healers consume)
local _pullState = {
    phase = 'idle',
    mobId = 0,
    mobName = '',
    eta = 0,
    mult = 1.0,
    dist = 0,
    updatedAt = 0,
}

-- Remote mob HP estimates (the damage-observer character broadcasts; others
-- consume so lean-mode characters still get overkill checks)
local _remoteMobHp = {}  -- mobName -> { maxHP, weight, updatedAt }

local function safeMeName()
    if mq.TLO.Me and mq.TLO.Me.CleanName then
        return mq.TLO.Me.CleanName() or ''
    end
    return ''
end

local function safeServer()
    if mq.TLO.EverQuest and mq.TLO.EverQuest.Server then
        return mq.TLO.EverQuest.Server() or ''
    end
    return ''
end

local function safeZone()
    if mq.TLO.Zone and mq.TLO.Zone.ShortName then
        return mq.TLO.Zone.ShortName() or ''
    end
    return ''
end

local function safeZoneId()
    local ok, value = pcall(function() return mq.TLO.Zone.ID() end)
    return ok and (tonumber(value) or 0) or 0
end

local function safeInstanceId()
    local ok, value = pcall(function() return mq.TLO.Me.Instance() end)
    return ok and (tonumber(value) or 0) or 0
end

local function estimatedWireSize(value, depth, seen)
    local kind = type(value)
    if kind == 'nil' then return 1 end
    if kind == 'boolean' then return 1 end
    if kind == 'number' then return 8 end
    if kind == 'string' then return #value end
    if kind ~= 'table' or depth >= 8 then return 0 end
    seen = seen or {}
    if seen[value] then return 0 end
    seen[value] = true
    local size = 4
    for key, child in pairs(value) do
        size = size + estimatedWireSize(key, depth + 1, seen)
            + estimatedWireSize(child, depth + 1, seen) + 4
    end
    seen[value] = nil
    return size
end

local function recordOutbound(topic, scope, payload, attempts, failures, lastError)
    topic = tostring(topic or 'unknown'):lower()
    scope = tostring(scope or 'unknown'):lower()
    attempts = math.max(0, tonumber(attempts) or 0)
    failures = math.max(0, tonumber(failures) or 0)
    local bytes = estimatedWireSize(payload, 0, {}) * attempts
    _outboundStats.logical = _outboundStats.logical + 1
    _outboundStats.attempts = _outboundStats.attempts + attempts
    _outboundStats.failures = _outboundStats.failures + failures
    _outboundStats.estimatedBytes = _outboundStats.estimatedBytes + bytes
    if failures > 0 then _outboundStats.lastFailure = tostring(lastError or '') end
    local topicStats = _outboundStats.byTopic[topic] or {
        logical = 0, attempts = 0, failures = 0, estimatedBytes = 0,
    }
    topicStats.logical = topicStats.logical + 1
    topicStats.attempts = topicStats.attempts + attempts
    topicStats.failures = topicStats.failures + failures
    topicStats.estimatedBytes = topicStats.estimatedBytes + bytes
    _outboundStats.byTopic[topic] = topicStats
    local scopeStats = _outboundStats.byScope[scope] or {
        logical = 0, attempts = 0, failures = 0, estimatedBytes = 0,
    }
    scopeStats.logical = scopeStats.logical + 1
    scopeStats.attempts = scopeStats.attempts + attempts
    scopeStats.failures = scopeStats.failures + failures
    scopeStats.estimatedBytes = scopeStats.estimatedBytes + bytes
    _outboundStats.byScope[scope] = scopeStats
    local recent = _outboundStats.recent
    local index
    if _outboundStats.recentCount < MAX_SEND_RATE_EVENTS then
        index = ((_outboundStats.recentHead
            + _outboundStats.recentCount - 1) % MAX_SEND_RATE_EVENTS) + 1
        _outboundStats.recentCount = _outboundStats.recentCount + 1
    else
        index = _outboundStats.recentHead
        _outboundStats.recentHead =
            (_outboundStats.recentHead % MAX_SEND_RATE_EVENTS) + 1
    end
    recent[index] = {
        atMs = monotonicMs(),
        logical = 1,
        attempts = attempts,
        failures = failures,
        estimatedBytes = bytes,
    }
end

local function outboundSnapshot(includeDetails)
    local now = monotonicMs()
    local cutoff = now - SEND_RATE_WINDOW_MS
    local recent = _outboundStats.recent
    local logical, attempts, failures, bytes = 0, 0, 0, 0
    for offset = 0, _outboundStats.recentCount - 1 do
        local index = ((_outboundStats.recentHead + offset - 1)
            % MAX_SEND_RATE_EVENTS) + 1
        local event = recent[index]
        if event and (tonumber(event.atMs) or 0) >= cutoff then
            logical = logical + (tonumber(event.logical) or 0)
            attempts = attempts + (tonumber(event.attempts) or 0)
            failures = failures + (tonumber(event.failures) or 0)
            bytes = bytes + (tonumber(event.estimatedBytes) or 0)
        end
    end
    local seconds = SEND_RATE_WINDOW_MS / 1000
    local snapshot = {
        logical = _outboundStats.logical,
        attempts = _outboundStats.attempts,
        failures = _outboundStats.failures,
        estimatedBytes = _outboundStats.estimatedBytes,
        logicalPerSecond = logical / seconds,
        attemptsPerSecond = attempts / seconds,
        failuresPerSecond = failures / seconds,
        estimatedBytesPerSecond = bytes / seconds,
        lastFailure = _outboundStats.lastFailure,
        windowSeconds = seconds,
    }
    if includeDetails then
        snapshot.byTopic = boundedCopy(_outboundStats.byTopic) or {}
        snapshot.byScope = boundedCopy(_outboundStats.byScope) or {}
    end
    return snapshot
end

function M.getOutboundMetrics()
    return outboundSnapshot(true)
end

function M.getOutboundSummary()
    return outboundSnapshot(false)
end

-- Raid.MainAssist returns a raidmember, not a spawn. Resolve its Spawn member
-- before reading spawn-only fields, while retaining the direct groupmember
-- path used by Group.MainAssist/MainTank.
local function assignedMemberSnapshot(member)
    local result = { id = 0, name = '' }
    if not member then return result end
    pcall(function()
        if not member() then return end
        result.id = tonumber(member.ID and member.ID() or 0) or 0
        if member.CleanName then result.name = tostring(member.CleanName() or '') end
        if result.name == '' and member.Name then
            result.name = tostring(member.Name() or '')
        end
        local spawn = member.Spawn
        if spawn and spawn() then
            if result.id <= 0 and spawn.ID then
                result.id = tonumber(spawn.ID()) or 0
            end
            if result.name == '' and spawn.CleanName then
                result.name = tostring(spawn.CleanName() or '')
            end
        end
    end)
    return result
end

local function raidMemberCount()
    local count = 0
    pcall(function()
        count = tonumber(mq.TLO.Raid and mq.TLO.Raid.Members
            and mq.TLO.Raid.Members() or 0) or 0
    end)
    return count
end

local _selectedAuthorityCache = nil
local _selectedAuthorityRevision = nil
local _selectedAuthorityCachedAtMs = 0

-- Resolve exactly one fleet kill-intent publisher. Explicit SideKick assist
-- settings win; the default group mode adopts Raid Assist 1 while raided,
-- then Group Main Assist, then Group Main Tank. This prevents two Tank-mode
-- characters from alternately overwriting the fleet's primary target.
local function selectedAssistAuthority()
    local Core = package.loaded['sidekick-next.utils.core']
    local settings = Core and Core.Settings or {}
    local revision = Core and Core.getRevision and Core.getRevision() or 0
    local now = monotonicMs()
    if _selectedAuthorityCache
        and _selectedAuthorityRevision == revision
        and (now - _selectedAuthorityCachedAtMs) < 500 then
        return _selectedAuthorityCache
    end
    local mode = tostring(settings.AssistMode or 'group'):lower()
    local selected

    if mode == 'byname' then
        selected = {
            mode = mode,
            source = 'configured_name',
            id = 0,
            name = tostring(settings.AssistName or ''),
        }
    else
        local raidIndex = tonumber(mode:match('^raid([123])$'))
        if raidIndex then
            selected = assignedMemberSnapshot(
            mq.TLO.Raid and mq.TLO.Raid.MainAssist
                and mq.TLO.Raid.MainAssist(raidIndex) or nil)
            selected.mode = mode
            selected.source = 'raid_assist_' .. tostring(raidIndex)
        elseif raidMemberCount() > 0 then
            local raidAssist = assignedMemberSnapshot(
                mq.TLO.Raid and mq.TLO.Raid.MainAssist
                    and mq.TLO.Raid.MainAssist(1) or nil)
            if raidAssist.name ~= '' then
                selected = raidAssist
                selected.mode = mode
                selected.source = 'raid_assist_1'
            end
        end

        if not selected then
            local groupAssist = assignedMemberSnapshot(
                mq.TLO.Group and mq.TLO.Group.MainAssist or nil)
            if groupAssist.name ~= '' then
                selected = groupAssist
                selected.mode = mode
                selected.source = 'group_main_assist'
            end
        end

        if not selected then
            selected = assignedMemberSnapshot(
                mq.TLO.Group and mq.TLO.Group.MainTank or nil)
            selected.mode = mode
            selected.source = selected.name ~= ''
                and 'group_main_tank' or 'none'
        end
    end

    _selectedAuthorityCache = selected
    _selectedAuthorityRevision = revision
    _selectedAuthorityCachedAtMs = now
    return selected
end

local function isEqAssignedTargetLeader(character, claimedId)
    local selected = selectedAssistAuthority()
    character = tostring(character or ''):lower()
    if character == '' or tostring(selected.name or ''):lower() ~= character then
        return false
    end
    claimedId = tonumber(claimedId) or 0
    if selected.id > 0 then
        return claimedId > 0 and selected.id == claimedId
    end
    -- Explicit by-name authority is bound to the authenticated Actor
    -- transport character because it may be outside local spawn visibility.
    return true
end

local currentTeamId

local function eqAssignmentSnapshots()
    local mainTank = { id = 0, name = '' }
    local mainAssist = { id = 0, name = '' }
    pcall(function()
        mainTank = assignedMemberSnapshot(mq.TLO.Group.MainTank)
    end)
    pcall(function()
        mainAssist = assignedMemberSnapshot(mq.TLO.Group.MainAssist)
    end)
    return mainTank, mainAssist
end

local function recordPrimaryTargetDiag(stage, reason, content, sender)
    content = type(content) == 'table' and content or {}
    sender = type(sender) == 'table' and sender or {}
    local envelope = type(content.envelope) == 'table' and content.envelope or {}
    reason = tostring(reason or 'unknown')
    _primaryTargetDiag.stage = tostring(stage or 'unknown')
    _primaryTargetDiag.reason = reason
    _primaryTargetDiag.updatedAtMs = monotonicMs()
    _primaryTargetDiag.senderCharacter = tostring(sender.character or '')
    _primaryTargetDiag.senderServer = tostring(sender.server or '')
    _primaryTargetDiag.senderScript = tostring(sender.script or '')
    _primaryTargetDiag.senderMailbox = tostring(sender.mailbox or '')
    _primaryTargetDiag.targetId = tonumber(content.targetId) or 0
    _primaryTargetDiag.targetName = tostring(content.targetName or '')
    _primaryTargetDiag.killAuthorized = content.killAuthorized == true
    _primaryTargetDiag.claimedTankId = tonumber(content.tankId) or 0
    _primaryTargetDiag.packetZone = tostring(content.zone or envelope.zone or '')
    _primaryTargetDiag.localZone = safeZone()
    _primaryTargetDiag.packetTeam = tostring(envelope.team or '')
    _primaryTargetDiag.localTeam = currentTeamId()
    _primaryTargetDiag.sessionId = tostring(envelope.session or content.sessionId or '')
    _primaryTargetDiag.sequence = tonumber(envelope.sequence)
        or tonumber(content.sequence) or 0
    _primaryTargetDiag.mainTank, _primaryTargetDiag.mainAssist =
        eqAssignmentSnapshots()
    _primaryTargetDiag.selectedAuthority = selectedAssistAuthority()
    _primaryTargetDiag.counts[reason] =
        (_primaryTargetDiag.counts[reason] or 0) + 1
end

local function normalize_sender(sender)
    sender = sender or {}
    local senderScript = lib.actorSenderEndpoint(sender)
    return {
        character = sender.character or sender.Character or '',
        server = sender.server or sender.Server or '',
        mailbox = sender.mailbox or sender.Mailbox or '',
        script = senderScript or '',
        account = sender.account or sender.Account or '',
        name = sender.name or sender.Name or '',
        uuid = sender.uuid or sender.UUID or '',
        pid = tonumber(sender.pid or sender.PID) or 0,
    }
end

local function peerKey(server, character)
    return string.format('%s:%s',
        tostring(server or ''):lower(),
        tostring(character or ''):lower())
end

local function endpointKey(sender)
    return table.concat({
        tostring(sender.server or ''):lower(),
        tostring(sender.character or ''):lower(),
        tostring(sender.script or ''):lower(),
        tostring(sender.mailbox or ''):lower(),
    }, ':')
end

currentTeamId = function()
    return _trustedTeamId
end

local function currentTeamMember(server, character)
    local key = peerKey(server, character)
    return _trustedTeamMembers ~= nil and _trustedTeamMembers[key] == true
end

local function isCanonicalSidekickScript(script)
    script = tostring(script or ''):lower()
    if script == '' then return false end
    for _, candidate in ipairs(lib.Scripts.WORKERS or {}) do
        if script == tostring(candidate):lower() then return true end
    end
    for _, candidate in ipairs(lib.Scripts.UI or {}) do
        if script == tostring(candidate):lower() then return true end
    end
    return false
end

-- Sender routes are normalized once from MQ's canonical fully-qualified
-- mailbox. Reuse the parsed endpoint for worker-specific authorization instead
-- of combining the normalized script with the still-qualified mailbox field.
local function senderIsWorker(sender, moduleName)
    local spec = lib.getWorkerSpec and lib.getWorkerSpec(moduleName) or nil
    if not spec then return false end
    local script, actor = lib.actorSenderEndpoint(sender)
    return tostring(script or ''):lower() == tostring(spec.script or ''):lower()
        and tostring(actor or ''):lower() == 'sidekick'
end

local function prepareEnvelope(payload, messageId, ttlMs)
    local copied, err = boundedCopy(type(payload) == 'table' and payload or {})
    if not copied then
        _lastSendErr = tostring(err or 'payload_copy_failed')
        return nil
    end
    local sessionId = ensureSessionId()
    if sessionId == '' then
        _lastSendErr = 'actor_identity_unavailable'
        return nil
    end
    local sequence = nextSeq(messageId)
    local teamId = tostring(copied.teamId or currentTeamId() or '')
    local zone = tostring(copied.zone or _selfZone or '')
    copied.id = messageId or copied.id
    copied.from = _selfName
    copied.server = _selfServer
    copied.envelope = {
        version = ACTOR_ENVELOPE_VERSION,
        team = teamId,
        session = sessionId,
        sequence = sequence,
        zone = zone,
        zoneId = safeZoneId(),
        instanceId = safeInstanceId(),
        ttlMs = math.max(1, math.min(tonumber(ttlMs) or DEFAULT_MESSAGE_TTL_MS, MAX_MESSAGE_TTL_MS)),
        sentAtMs = monotonicMs(),
    }
    return copied
end

-- Should we process a cross-zone-sensitive message? True if sender is in our
-- zone (via content.zone if provided, else via the last known peer status).
-- Fails open (returns true) when we don't know the sender's zone — dropping
-- messages from unknown peers would lock out newly-joined peers before their
-- first Actor Team or compatibility status packet lands.
local function senderInSameZone(content, sender)
    local myZone = safeZone()
    if myZone == '' then return false end

    local envelope = content and type(content.envelope) == 'table' and content.envelope or {}
    local msgZone = (content and content.zone) or envelope.zone
    if type(msgZone) == 'string' and msgZone ~= '' then
        if msgZone ~= myZone then return false end
        local myInstance = safeInstanceId()
        local msgInstance = tonumber(envelope.instanceId) or 0
        if myInstance > 0 and msgInstance > 0 and myInstance ~= msgInstance then return false end
        return true
    end

    local charName = tostring(sender and sender.character or '')
    local serverName = tostring(sender and sender.server or '')
    if charName ~= '' and serverName ~= '' then
        local peer = _remoteCharacters[peerKey(serverName, charName)]
        if peer and peer.zone and peer.zone ~= '' then
            if peer.zone ~= myZone then return false end
            local myInstance = safeInstanceId()
            if myInstance > 0 and (tonumber(peer.instanceId) or 0) > 0
                and myInstance ~= tonumber(peer.instanceId) then
                return false
            end
            return true
        end
    end

    return false
end

local function recordTransportDrop(reason, counter)
    reason = tostring(reason or 'unknown')
    _transportStats.dropped = _transportStats.dropped + 1
    _transportStats.lastDropReason = reason
    _transportStats.byReason[reason] =
        (_transportStats.byReason[reason] or 0) + 1
    if counter and _transportStats[counter] ~= nil then
        _transportStats[counter] = _transportStats[counter] + 1
    end
end

local function pruneTransportSessions(nowMs)
    for endpoint, sessions in pairs(_retiredSessions) do
        local any = false
        for sessionId, expiresAtMs in pairs(sessions) do
            if expiresAtMs <= nowMs then
                sessions[sessionId] = nil
            else
                any = true
            end
        end
        if not any then _retiredSessions[endpoint] = nil end
    end
    local active = {}
    for endpoint, state in pairs(_peerSessions) do
        if (nowMs - (state.receivedAtMs or 0)) > PEER_SESSION_IDLE_MS then
            _peerSessions[endpoint] = nil
        else
            active[#active + 1] = { endpoint = endpoint, at = state.receivedAtMs or 0 }
        end
    end
    if #active > MAX_TRACKED_ENDPOINTS then
        table.sort(active, function(a, b) return a.at < b.at end)
        for index = 1, (#active - MAX_TRACKED_ENDPOINTS) do
            _peerSessions[active[index].endpoint] = nil
        end
    end
    local retired = {}
    for endpoint, sessions in pairs(_retiredSessions) do
        local newestExpiry = 0
        for _, expiresAtMs in pairs(sessions) do
            newestExpiry = math.max(newestExpiry, expiresAtMs)
        end
        retired[#retired + 1] = { endpoint = endpoint, at = newestExpiry }
    end
    if #retired > MAX_TRACKED_ENDPOINTS then
        table.sort(retired, function(a, b) return a.at < b.at end)
        for index = 1, (#retired - MAX_TRACKED_ENDPOINTS) do
            _retiredSessions[retired[index].endpoint] = nil
        end
    end
end

local function tombstoneSession(endpoint, sessionId, nowMs)
    if sessionId == '' then return end
    local sessions = _retiredSessions[endpoint] or {}
    sessions[sessionId] = nowMs + SESSION_TOMBSTONE_MS
    _retiredSessions[endpoint] = sessions
    local entries = {}
    for id, expiresAtMs in pairs(sessions) do
        entries[#entries + 1] = { id = id, expiresAtMs = expiresAtMs }
    end
    if #entries > MAX_TOMBSTONES_PER_ENDPOINT then
        table.sort(entries, function(a, b) return a.expiresAtMs < b.expiresAtMs end)
        for index = 1, (#entries - MAX_TOMBSTONES_PER_ENDPOINT) do
            sessions[entries[index].id] = nil
        end
    end
end

local function recordTransportTopicSequence(state, topic, sequence, nowMs)
    state.topics = type(state.topics) == 'table' and state.topics or {}
    state.topics[topic] = {
        sequence = sequence,
        seenAtMs = nowMs,
    }
    local entries = {}
    for messageId, topicState in pairs(state.topics) do
        entries[#entries + 1] = {
            id = messageId,
            at = tonumber(topicState.seenAtMs) or 0,
        }
    end
    if #entries > MAX_TOPICS_PER_ENDPOINT then
        table.sort(entries, function(a, b) return a.at < b.at end)
        for index = 1, (#entries - MAX_TOPICS_PER_ENDPOINT) do
            state.topics[entries[index].id] = nil
        end
    end
end

local function validateInbound(entry)
    local content = entry and entry.content or nil
    local sender = entry and entry.sender or {}
    if type(content) ~= 'table' then
        recordTransportDrop('malformed_content', 'malformed')
        return nil
    end
    local id = tostring(content.id or ''):lower()
    local isPrimary = id == 'target:primary'
    local function reject(reason, counter)
        recordTransportDrop(reason, counter)
        if isPrimary then
            recordPrimaryTargetDiag('transport_rejected', reason, content, sender)
        end
        return nil
    end
    if isPrimary then
        recordPrimaryTargetDiag('transport_received', 'packet_received', content, sender)
    end

    local senderCharacter = tostring(sender.character or '')
    local senderServer = tostring(sender.server or '')
    local senderScript = tostring(sender.script or '')
    if senderCharacter == '' or senderServer == '' or senderScript == '' then
        return reject('incomplete_sender', 'identityRejected')
    end

    local isLocal = senderCharacter:lower() == tostring(_selfName or ''):lower()
        and senderServer:lower() == tostring(_selfServer or ''):lower()
    if tostring(_selfServer or '') ~= ''
        and senderServer:lower() ~= tostring(_selfServer):lower() then
        return reject('server_mismatch', 'identityRejected')
    end
    local senderScriptLower = senderScript:lower()
    local sidekickSender = isCanonicalSidekickScript(senderScriptLower)
    if sidekickSender
        and not lib.actorSenderMatches(sender, senderScript, 'sidekick') then
        return reject('untrusted_sender_mailbox', 'identityRejected')
    end
    if not isLocal and not sidekickSender and not EXTERNAL_MESSAGE_IDS[id] then
        return reject('untrusted_sender_script', 'identityRejected')
    end
    if not isLocal and (id:sub(1, 6) == 'lease:' or id:sub(1, 3) == 'sk:') then
        return reject('remote_control_rejected', 'controlRejected')
    end

    -- Primary kill intent has a second, explicit trust path: an authenticated
    -- Tank worker belonging to EQ's assigned Main Tank/Main Assist. Keep this
    -- exception topic- and route-specific; all other peer state still requires
    -- Actor-Team membership below.
    local tankSpec = id == 'target:primary' and lib.getWorkerSpec
        and lib.getWorkerSpec('tank') or nil
    local assignedTankPrimary = not isLocal
        and tankSpec ~= nil
        and senderIsWorker(sender, 'tank')
        and isEqAssignedTargetLeader(senderCharacter, content.tankId)

    -- Payload identity is never authoritative. Reject contradictory claims,
    -- then overwrite the compatibility fields with the transport identity so
    -- every downstream consumer sees the same trusted source.
    if content.from ~= nil and tostring(content.from) ~= ''
        and tostring(content.from):lower() ~= senderCharacter:lower() then
        return reject('payload_character_mismatch', 'identityRejected')
    end
    if content.server ~= nil and tostring(content.server) ~= ''
        and tostring(content.server):lower() ~= senderServer:lower() then
        return reject('payload_server_mismatch', 'identityRejected')
    end
    content.from = senderCharacter
    content.server = senderServer

    local envelope = type(content.envelope) == 'table' and content.envelope or nil
    local localTeam = currentTeamId()
    local receivedAtMs = tonumber(entry.receivedAtMs) or monotonicMs()
    local nowMs = monotonicMs()
    local queueTtlMs = envelope
        and math.max(1, math.min(tonumber(envelope.ttlMs)
            or DEFAULT_MESSAGE_TTL_MS, MAX_MESSAGE_TTL_MS))
        or DEFAULT_MESSAGE_TTL_MS
    if (nowMs - receivedAtMs) > queueTtlMs then
        return reject('expired_in_inbox', 'expired')
    end
    if sidekickSender and not envelope then
        return reject('missing_sidekick_envelope', 'identityRejected')
    end
    if not isLocal and sidekickSender and not assignedTankPrimary
        and (localTeam == ''
            or not currentTeamMember(senderServer, senderCharacter)) then
        return reject('sender_not_in_trusted_team', 'identityRejected')
    end
    if envelope then
        if tonumber(envelope.version) ~= ACTOR_ENVELOPE_VERSION then
            return reject('envelope_version_mismatch')
        end
        local sessionId = tostring(envelope.session or '')
        local sequence = tonumber(envelope.sequence) or 0
        if sessionId == '' or sequence <= 0 then
            return reject('envelope_incomplete', 'malformed')
        end
        if content.teamId ~= nil and tostring(content.teamId) ~= ''
            and tostring(content.teamId) ~= tostring(envelope.team or '') then
            return reject('envelope_team_mismatch', 'identityRejected')
        end
        if content.zone ~= nil and tostring(content.zone) ~= ''
            and tostring(envelope.zone or '') ~= ''
            and tostring(content.zone):lower() ~= tostring(envelope.zone):lower() then
            return reject('envelope_zone_mismatch', 'identityRejected')
        end

        local packetTeam = tostring(envelope.team or '')
        if not isLocal and sidekickSender and not assignedTankPrimary
            and (localTeam == '' or packetTeam ~= localTeam) then
            return reject('team_mismatch', 'identityRejected')
        end

        local endpoint = endpointKey(sender)
        local tombstones = _retiredSessions[endpoint]
        if tombstones and (tombstones[sessionId] or 0) > nowMs then
            return reject('retired_session', 'staleSession')
        end
        local previous = _peerSessions[endpoint]
        if previous and previous.sessionId == sessionId then
            local topicState = type(previous.topics) == 'table'
                and previous.topics[id] or nil
            if topicState
                and sequence <= (tonumber(topicState.sequence) or 0) then
                return reject('duplicate_or_out_of_order', 'duplicate')
            end
        elseif previous and previous.sessionId ~= '' then
            tombstoneSession(endpoint, previous.sessionId, nowMs)
        end
        local activeSession = previous
        if not activeSession or activeSession.sessionId ~= sessionId then
            activeSession = {
                sessionId = sessionId,
                receivedAtMs = nowMs,
                topics = {},
            }
            _peerSessions[endpoint] = activeSession
        end
        activeSession.receivedAtMs = nowMs
        recordTransportTopicSequence(activeSession, id, sequence, nowMs)
        pruneTransportSessions(nowMs)
    end

    _transportStats.received = _transportStats.received + 1
    if isPrimary then
        recordPrimaryTargetDiag('transport_accepted', 'transport_accepted', content, sender)
    end
    return content, sender, isLocal
end

-- Send format: try absolute first, fall back to script+mailbox, cache what works
local _sendFormat = nil  -- cached working format (1 = absolute, 2 = script+mailbox)

local _ADDR_ABSOLUTE = { mailbox = 'lua:group:grouptarget', absolute_mailbox = true }
local _ADDR_SCRIPT   = { mailbox = 'grouptarget', script = 'group' }

local function sendToGroupTarget(payload)
    if not _dropbox then return end
    if type(payload) ~= 'table' then return end
    payload = prepareEnvelope(payload, payload.id)
    if not payload then return end
    local absoluteAddress = {
        mailbox = _ADDR_ABSOLUTE.mailbox,
        absolute_mailbox = true,
        character = _selfName,
        server = _selfServer,
    }
    local scriptAddress = {
        mailbox = _ADDR_SCRIPT.mailbox,
        script = _ADDR_SCRIPT.script,
        character = _selfName,
        server = _selfServer,
    }

    -- Use cached working format if known
    if _sendFormat == 1 then
        local ok, res = pcall(_dropbox.send, _dropbox, absoluteAddress, payload)
        _lastSendResult = { ok1 = ok, res1 = res }
        if not ok then _lastSendErr = tostring(res) end
        local failed = not ok or res == false
            or (type(res) == 'number' and res < 0)
        recordOutbound(payload.id, 'group_target', payload, 1,
            failed and 1 or 0, failed and tostring(res) or nil)
        return
    elseif _sendFormat == 2 then
        local ok, res = pcall(_dropbox.send, _dropbox, scriptAddress, payload)
        _lastSendResult = { ok2 = ok, res2 = res }
        if not ok then _lastSendErr = tostring(res) end
        local failed = not ok or res == false
            or (type(res) == 'number' and res < 0)
        recordOutbound(payload.id, 'group_target', payload, 1,
            failed and 1 or 0, failed and tostring(res) or nil)
        return
    end

    -- Discovery: try both, cache the first that doesn't throw
    local ok1, res1 = pcall(_dropbox.send, _dropbox, absoluteAddress, payload)
    local failed1 = not ok1 or res1 == false
        or (type(res1) == 'number' and res1 < 0)
    if not failed1 then
        _sendFormat = 1
        _lastSendResult = { ok1 = ok1, res1 = res1 }
        recordOutbound(payload.id, 'group_target_discovery', payload, 1, 0)
        return
    end
    local ok2, res2 = pcall(_dropbox.send, _dropbox, scriptAddress, payload)
    local failed2 = not ok2 or res2 == false
        or (type(res2) == 'number' and res2 < 0)
    if not failed2 then
        _sendFormat = 2
    end
    _lastSendResult = { ok1 = ok1, res1 = res1, ok2 = ok2, res2 = res2 }
    if not ok1 then _lastSendErr = tostring(res1) end
    if not ok2 then _lastSendErr = tostring(res2) end
    recordOutbound(payload.id, 'group_target_discovery', payload, 2,
        (failed1 and 1 or 0) + (failed2 and 1 or 0),
        failed2 and tostring(res2) or tostring(res1))
end

function M.sendToGroupTarget(payload)
    sendToGroupTarget(payload)
end

-- eq_ui_rebuild_classic services its 'medley_remote' mailbox from its main
-- coroutine; script-addressed with no character = broadcast to that script
-- on every connected peer.
local _ADDR_EQUI = { mailbox = 'medley_remote', script = 'eq_ui_rebuild_classic' }

--- Publish consolidated group vitals (tank-side, see utils/vitals_hub.lua).
--- Fan-out is script-addressed because plain { mailbox = 'sidekick' } never
--- crosses script names: GroupTarget HUD + classic UI rebuild.
function M.sendVitalsGroup(payload)
    if not _dropbox or type(payload) ~= 'table' then return end
    sendToGroupTarget(payload)
    local eqPayload = prepareEnvelope(payload, payload.id)
    if eqPayload then
        local ok, result = pcall(function()
            _dropbox:send({
                mailbox = _ADDR_EQUI.mailbox,
                script = _ADDR_EQUI.script,
                server = _selfServer,
            }, eqPayload)
        end)
        local failed = not ok or result == false
            or (type(result) == 'number' and result < 0)
        recordOutbound(payload.id, 'eq_ui', eqPayload, 1,
            failed and 1 or 0, failed and tostring(result) or nil)
    end
end

function M.requestGroupTargetBounds()
    sendToGroupTarget({ id = 'window:bounds:req' })
end

function M.init(opts)
    opts = opts or {}
    if _dropbox then return _dropbox end
    local ok, lib = pcall(require, 'actors')
    if not ok then
        _actorsInitError = tostring(lib)
        return nil
    end
    _actors = lib

    _selfName = safeMeName()
    _selfServer = safeServer()
    _selfZone = safeZone()

    -- Load persisted claim ledger (archives any in-progress session into history).
    local L = ledger()
    if L and L.load then pcall(L.load) end

    -- Actor handlers run with yielding disabled. Load every internal receiver
    -- before registering the mailbox so a first message can never trigger a
    -- module import from inside the callback.
    local receiverModules = {
        'sidekick-next.utils.core',
        'sidekick-next.automation.assist',
        'sidekick-next.utils.positioning',
        'sidekick-next.automation.cc',
        'sidekick-next.automation.debuff',
        'sidekick-next.automation.buff',
        'sidekick-next.utils.buff_requests',
        'sidekick-next.automation.cures',
    }
    for _, moduleName in ipairs(receiverModules) do
        pcall(require, moduleName)
    end
    _selfNameLower = tostring(_selfName or ''):lower()
    _selfServerLower = tostring(_selfServer or ''):lower()

    local function sameLocalCharacter(name, server)
        name = tostring(name or ''):lower()
        server = tostring(server or ''):lower()
        if name == '' or _selfNameLower == '' or name ~= _selfNameLower then return false end
        return _selfServerLower == '' or server == '' or server == _selfServerLower
    end

    -- Primary target facts are trusted only from the single selected assist
    -- authority. Being the receiver's local Tank worker is not sufficient:
    -- that exception was what allowed a second Tank-mode character to replace
    -- the raid assist's kill target.
    local function senderIsAuthorizedTargetLeader(content, sender)
        local senderName = tostring(sender and sender.character or ''):lower()
        if senderName == '' then return false end
        if isEqAssignedTargetLeader(senderName, content and content.tankId) then
            return true
        end
        local selected = selectedAssistAuthority()
        return tostring(selected.name or '') == ''
            and senderName == _selfNameLower
            and tostring(sender and sender.server or ''):lower() == _selfServerLower
    end

    local function senderIsTankWorker(sender)
        return senderIsWorker(sender, 'tank')
    end

    local function processActorMessage(content, sender)
        local id = tostring(content.id or ''):lower()

        local senderCharLower = tostring(sender.character or ''):lower()
        local senderServerLower = tostring(sender.server or ''):lower()
        local fromMe = (senderCharLower ~= '' and senderCharLower == _selfNameLower)
            and (senderServerLower ~= '' and senderServerLower == _selfServerLower)

        local senderMailboxLower = tostring(sender.mailbox or ''):lower()
        local fromGroupTargetMailbox = (senderMailboxLower ~= '' and senderMailboxLower:find('grouptarget', 1, true) ~= nil)
        if fromGroupTargetMailbox then
            _lastGroupTargetMsgAt = os.clock()
            _lastGroupTargetMsgId = id
        end

        -- Tally remote claims into the ledger. Self-fired claims are recorded
        -- in M.publish() instead, so we skip fromMe here to avoid double-counting.
        if not fromMe then
            local cat = CLAIM_CATEGORIES[id]
            if cat then
                local L = ledger()
                if L then
                    local from = tostring(sender.character or '')
                    if from ~= '' then L.record(from, cat) end
                end
            end
        end

        if id == 'worker:telemetry' then
            if not fromMe then
                recordTransportDrop('telemetry_nonlocal')
                return
            end
            if tonumber(content.telemetryVersion) ~= TELEMETRY_VERSION then
                recordTransportDrop('telemetry_version')
                return
            end
            local stream = tostring(content.stream or ''):lower()
            local callbacks = _telemetryCallbacks[stream]
            local streamSequence = tonumber(content.streamSequence) or 0
            if stream == '' or tostring(content.module or '') == ''
                or streamSequence <= 0
                or streamSequence ~= math.floor(streamSequence)
                or type(content.data) ~= 'table' then
                recordTransportDrop('telemetry_malformed')
                return
            end
            if not callbacks then
                recordTransportDrop('telemetry_unhandled_stream')
                return
            end
            for _, cb in ipairs(callbacks) do
                local ok = pcall(cb, content.data, content, sender)
                if not ok then recordTransportDrop('telemetry_callback_error') end
            end
            return
        end

        if id == 'worker:command' then
            if tonumber(content.commandVersion) ~= WORKER_COMMAND_VERSION then
                recordTransportDrop('worker_command_version')
                return
            end
            local component = tostring(content.component or content.module or ''):lower()
            local callbacks = _workerCommandCallbacks[component]
            local command = tostring(content.command or ''):lower()
            local commandSequence = tonumber(content.commandSequence) or 0
            if component == '' or command == ''
                or tostring(content.requestId or '') == ''
                or commandSequence <= 0
                or commandSequence ~= math.floor(commandSequence)
                or type(content.data) ~= 'table' then
                recordTransportDrop('worker_command_malformed')
                return
            end
            if not callbacks then
                recordTransportDrop('worker_command_unhandled_component')
                return
            end
            for _, cb in ipairs(callbacks) do
                local ok, handled = pcall(cb, command,
                    content.data, content, sender, fromMe)
                if not ok then
                    recordTransportDrop('worker_command_callback_error')
                elseif handled == true then
                    return
                end
            end
            recordTransportDrop('worker_command_unhandled_command')
            return
        end

        local callbacks = _messageCallbacks[id]
        if callbacks then
            for _, cb in ipairs(callbacks) do
                local ok, handled = pcall(cb, content, sender, fromMe)
                if ok and handled == true then return end
            end
        end

        -- The dedicated status Actor callback only enqueues. Reply
        -- asynchronously from this tick so the callback never sends, reads a
        -- TLO, or retains an Actor message handle.
        if id == 'eq_ui:automation:req' then
            if not fromMe then return end
            local last = type(_lastStatusPayload) == 'table' and _lastStatusPayload or {}
            local paused, chase = nil, nil
            if type(last.automationPaused) == 'boolean' then paused = last.automationPaused end
            if type(last.chase) == 'boolean' then chase = last.chase end
            local reply = prepareEnvelope({
                id = 'eq_ui:automation:rep',
                script = 'sidekick-next',
                paused = paused,
                chase = chase,
            }, 'eq_ui:automation:rep')
            if reply and _dropbox then
                local address = {
                    character = sender.character,
                    server = sender.server,
                }
                if tostring(sender.uuid or '') ~= '' then address.uuid = sender.uuid end
                if (tonumber(sender.pid) or 0) > 0 then address.pid = sender.pid end
                address.mailbox = tostring(sender.mailbox or '')
                address.absolute_mailbox = true
                local ok, result = pcall(function()
                    return _dropbox:send(address, reply)
                end)
                local failed = not ok or result == false
                    or (type(result) == 'number' and result < 0)
                recordOutbound('eq_ui:automation:rep', 'direct_reply',
                    reply, 1, failed and 1 or 0,
                    failed and tostring(result) or nil)
            end
            return
        end

        -- Respond to GroupTarget pull-style status requests (targeted send).
        -- Note: sender may be our own character (GroupTarget runs on the same client), so do NOT gate on fromMe.
        -- Always send a reply — even before tick() has populated
        -- _lastStatusPayload — so GroupTarget can distinguish "alive but quiet"
        -- from "not responding".
        if id == 'status:req' then
            if tostring(content.script or '') == 'grouptarget'
                and not sameLocalCharacter(content.from, content.server)
                and not fromMe then
                return
            end
            local reply = {}
            if type(_lastStatusPayload) == 'table' then
                for k, v in pairs(_lastStatusPayload) do reply[k] = v end
            end
            reply.id = 'status:rep'
            reply.script = 'sidekick'
            reply.from = reply.from or _selfName
            reply.server = reply.server or _selfServer
            reply.zone = reply.zone or _selfZone
            -- The classic UI asks from its own medley_remote mailbox. Reply
            -- directly so it can display SideKick's internal automation pause
            -- rather than merely MQ2Lua's process status.
            if tostring(sender.mailbox or ''):find('medley_remote', 1, true)
                and tostring(sender.character or '') ~= '' then
                local preparedReply = prepareEnvelope(reply, 'status:rep')
                if preparedReply then
                    local ok, result = pcall(function()
                        return _dropbox:send({
                        mailbox = 'medley_remote',
                        script = tostring(sender.script or '') ~= '' and sender.script
                            or (tostring(content.replyScript or '') ~= ''
                                and content.replyScript or 'eq_ui_rebuild_classic'),
                        character = sender.character,
                        server = sender.server,
                        }, preparedReply)
                    end)
                    local failed = not ok or result == false
                        or (type(result) == 'number' and result < 0)
                    recordOutbound('status:rep', 'direct_reply',
                        preparedReply, 1, failed and 1 or 0,
                        failed and tostring(result) or nil)
                end
            else
                sendToGroupTarget(reply)
            end
            return
        end

        -- GroupTarget broadcasting its settings panel state (used to hide Exit Both button, etc.)
        if id == 'gt:settings_open' then
            if not sameLocalCharacter(content.from, content.server) and not fromMe then return end
            _G.GroupTargetBounds = _G.GroupTargetBounds or {}
            _G.GroupTargetBounds.settingsOpen = content.open == true
            _G.GroupTargetBounds.settingsOpenAt = os.clock()
            return
        end

        -- Receive status updates from other SideKick instances
        if id == 'status:update' or id == 'peer:vitals'
            or id == 'peer:capabilities' then
            if fromMe then return end
            local charName = tostring(sender.character or '')
            local serverName = tostring(sender.server or '')
            if charName == '' or serverName == '' then return end
            local key = peerKey(serverName, charName)

            -- Legacy status packets and the explicit script-local overlays are
            -- merged for compatibility UI consumers. Actor Team remains the
            -- authoritative presence/trust/target plane.
            local previous = _remoteCharacters[key] or {}
            if not next(previous) then
                local peerCount = 0
                for _ in pairs(_remoteCharacters) do peerCount = peerCount + 1 end
                if peerCount >= MAX_TRACKED_ENDPOINTS then return end
            end
            local targetWasIncluded = content.targetId ~= nil
            local envelope = type(content.envelope) == 'table' and content.envelope or {}
            local senderEndpoint = endpointKey(sender)
            local incomingSession = tostring(envelope.session or '')
            local sourceSessions = {}
            for source, sessionId in pairs(previous.sourceSessions or {}) do
                sourceSessions[source] = sessionId
            end
            local priorSourceSession = sourceSessions[senderEndpoint]
            local sourceRestarted = priorSourceSession ~= nil and incomingSession ~= ''
                and priorSourceSession ~= incomingSession
            sourceSessions[senderEndpoint] = incomingSession
            local clearStaleTarget = sourceRestarted
                and previous.targetSourceEndpoint == senderEndpoint
                and not targetWasIncluded
            local function update(value, oldValue)
                if value ~= nil then return value end
                return oldValue
            end
            _remoteCharacters[key] = {
                key = key,
                character = charName,
                server = serverName,
                zone = tostring(content.zone or envelope.zone or previous.zone or ''),
                zoneId = tonumber(envelope.zoneId) or previous.zoneId or 0,
                instanceId = tonumber(envelope.instanceId) or previous.instanceId or 0,
                class = content.class or previous.class or '',
                id = tonumber(content.characterId or content.spawnId or content.charId) or previous.id or 0,
                currentHP = tonumber(content.currentHP) or previous.currentHP or 0,
                maxHP = tonumber(content.maxHP) or previous.maxHP or 0,
                inGame = update(content.inGame, previous.inGame),
                dead = update(content.dead, previous.dead) == true,
                hovering = update(content.hovering, previous.hovering) == true,
                role = content.role or previous.role,
                abilities = content.abilities or previous.abilities or {},
                buffs = content.buffs or previous.buffs or {},  -- What buffs this character currently has
                chase = update(content.chase, previous.chase),
                hp = update(content.hp, previous.hp),
                mana = update(content.mana, previous.mana),
                endur = update(content.endur, previous.endur),
                targetId = targetWasIncluded and (tonumber(content.targetId) or 0)
                    or (clearStaleTarget and 0 or previous.targetId or 0),
                targetType = targetWasIncluded and tostring(content.targetType or '')
                    or (clearStaleTarget and '' or previous.targetType or ''),
                targetName = targetWasIncluded and tostring(content.targetName or '')
                    or (clearStaleTarget and '' or previous.targetName or ''),
                targetUpdatedAt = targetWasIncluded and os.clock()
                    or (clearStaleTarget and nil or previous.targetUpdatedAt),
                targetSourceEndpoint = targetWasIncluded and senderEndpoint
                    or (clearStaleTarget and nil or previous.targetSourceEndpoint),
                targetSessionId = targetWasIncluded and incomingSession
                    or (clearStaleTarget and nil or previous.targetSessionId),
                combat = update(content.combat, previous.combat) == true,
                script = tostring(sender.script or content.script or previous.script or ''),
                sessionId = tostring(envelope.session or previous.sessionId or ''),
                sourceSessions = sourceSessions,
                lastSeen = os.clock(),
            }
            return
        end

        -- Assist Me command: set all peers to assist sender's current target
        if id == 'assist:me' then
            if fromMe then return end
            -- Only respond if we're in the same zone
            local senderZone = tostring(content.zone or '')
            local myZone = safeZone()
            if senderZone == '' or myZone == '' or senderZone ~= myZone then return end

            local targetId = tonumber(content.targetId) or 0
            local targetName = tostring(content.targetName or '')
            if targetId <= 0 then return end

            local fromName = tostring(sender.character or '')

            -- Check if we should accept assists from this source based on settings
            -- Load settings via Core module
            local Core = package.loaded['sidekick-next.utils.core']
            local settings = Core and Core.Settings or {}

            -- Determine if sender is in group, raid, or is a known peer
            local senderSpawn = mq.TLO.Spawn('pc =' .. fromName)
            local senderId = senderSpawn and senderSpawn() and senderSpawn.ID and senderSpawn.ID() or 0

            local isInGroup = false
            local isInRaid = false
            local envelope = type(content.envelope) == 'table' and content.envelope or {}
            local localTeam = currentTeamId()
            local isPeer = localTeam ~= '' and tostring(envelope.team or '') == localTeam

            -- Check if sender is in our group
            if senderId > 0 then
                local groupCount = mq.TLO.Group.Members and mq.TLO.Group.Members() or 0
                for i = 0, groupCount do
                    local member = mq.TLO.Group.Member(i)
                    if member and member() and member.ID and member.ID() == senderId then
                        isInGroup = true
                        break
                    end
                end

                -- Check if sender is in our raid
                if not isInGroup then
                    local raidCount = mq.TLO.Raid.Members and mq.TLO.Raid.Members() or 0
                    for i = 1, raidCount do
                        local raidMember = mq.TLO.Raid.Member(i)
                        if raidMember and raidMember() then
                            local raidSpawn = raidMember.Spawn
                            if raidSpawn and raidSpawn() and raidSpawn.ID and raidSpawn.ID() == senderId then
                                isInRaid = true
                                break
                            end
                        end
                    end
                end
            end

            -- Determine if we should accept based on settings
            local shouldAccept = false
            if isInGroup and settings.AssistOutsideGroup ~= false then
                shouldAccept = true
            elseif isInRaid and settings.AssistOutsideRaid ~= false then
                shouldAccept = true
            elseif isPeer and settings.AssistOutsidePeers ~= false then
                shouldAccept = true
            end

            if not shouldAccept then
                return
            end

            -- Import assist module and set the target
            local Assist = package.loaded['sidekick-next.automation.assist']
            if Assist then
                Assist.primaryTargetId = targetId
                Assist.currentTargetId = targetId
                Assist.tankName = fromName
                Assist.lastTankBroadcast = os.clock()
            end

            -- Echo disabled
            return
        end

        -- Accept GroupTarget bounds for anchoring (only from self or from GroupTarget mailbox).
        if id == 'window:bounds' then
            local accept = fromMe and fromGroupTargetMailbox
            if not accept then
                return
            end
            _G.GroupTargetBounds = {
                x = content.x or 0,
                y = content.y or 0,
                width = content.width or 280,
                height = content.height or 300,
                right = content.right or ((content.x or 0) + (content.width or 0)),
                bottom = content.bottom or ((content.y or 0) + (content.height or 0)),
                mainY = content.mainY,
                mainHeight = content.mainHeight,
                settingsOverlayHeight = content.settingsOverlayHeight,
                locked = content.locked,
                transparency = content.transparency,
                windowRounding = content.windowRounding,
                activeTheme = content.activeTheme,
                -- Command bar bounds for anchoring
                commandBarX = content.commandBarX,
                commandBarY = content.commandBarY,
                commandBarWidth = content.commandBarWidth,
                commandBarHeight = content.commandBarHeight,
                commandBarRight = content.commandBarRight,
                commandBarBottom = content.commandBarBottom,
                loaded = true,
                timestamp = content.timestamp or os.time(),
            }
            return
        end

        -- Tank coordination: primary kill target. NOT gated on fromMe: the
        -- tank's own sibling workers (its sk_dps, sk_cc, ...) receive this
        -- via the fleet fan-out and need it too. Idempotent last-write-wins.
        if id == 'target:primary' then
            if not senderIsTankWorker(sender) then
                recordTransportDrop('target_primary_wrong_worker', 'identityRejected')
                recordPrimaryTargetDiag(
                    'topic_rejected', 'target_primary_wrong_worker', content, sender)
                return
            end
            if not senderIsAuthorizedTargetLeader(content, sender) then
                recordTransportDrop('target_primary_unauthorized_leader', 'identityRejected')
                recordPrimaryTargetDiag(
                    'topic_rejected', 'target_primary_unauthorized_leader', content, sender)
                return
            end
            if not senderInSameZone(content, sender) then
                recordTransportDrop('target_primary_zone_or_instance_mismatch')
                recordPrimaryTargetDiag(
                    'topic_rejected', 'target_primary_zone_or_instance_mismatch',
                    content, sender)
                return
            end
            if isStaleGuardedMessage(id, content, sender) then
                recordTransportDrop('target_primary_stale_topic_sequence', 'duplicate')
                recordPrimaryTargetDiag(
                    'topic_rejected', 'target_primary_stale_topic_sequence',
                    content, sender)
                return
            end

            _tankState.primaryTargetId = tonumber(content.targetId) or 0
            _tankState.primaryTargetName = tostring(content.targetName or '')
            _tankState.killAuthorized = content.killAuthorized == true
                and _tankState.primaryTargetId > 0
            local envelope = type(content.envelope) == 'table' and content.envelope or {}
            _tankState.primaryRevision = tonumber(envelope.sequence)
                or tonumber(content.sequence) or 0
            local senderSpawn = mq.TLO.Spawn('pc =' .. tostring(sender.character or ''))
            local senderId = senderSpawn and senderSpawn() and senderSpawn.ID
                and tonumber(senderSpawn.ID()) or 0
            _tankState.tankId = senderId > 0 and senderId or _tankState.tankId
            _tankState.tankName = tostring(sender.character or '')
            _tankState.updatedAt = os.clock()
            recordPrimaryTargetDiag('accepted', 'primary_state_updated', content, sender)
            return
        end

        -- Tank coordination: aggro cycling target (follow mode uses, sticky ignores)
        if id == 'target:aggro' then
            if fromMe then return end
            if not senderIsTankWorker(sender) then return end
            if not senderIsAuthorizedTargetLeader(content, sender) then return end
            -- Operational tank telemetry only. Coordinated Assist/DPS/Debuff
            -- must consume primaryTargetId and never follow this working target.
            _tankState.currentTargetId = content.targetId
            return
        end

        -- Tank coordination: repositioning / settled / taunt events.
        -- Peer soft-pause on tank movement is intentionally disabled in the
        -- coordinated worker fleet — a wired-up variant lived only behind the
        -- retired monolithic mode. Retained as a no-op so the tank:* handler
        -- blocks below still consume their messages instead of falling through
        -- to unrelated handlers; a follow-up plan can re-enable via a proper
        -- worker if soft-pause is desired.
        local function _callPositioning(_method)
            return
        end

        -- Apply the same explicit assignment/team trust policy to tank state.
        local function senderIsAuthorizedTank(content, sender)
            return senderIsAuthorizedTargetLeader(content, sender)
        end

        -- Pull coordination: the tank's pull monitor announces inbound pulls so
        -- healers don't each run their own XTarget scan
        if id == 'pull:incoming' then
            if fromMe then return end
            local senderZone = tostring(content.zone or '')
            local myZone = safeZone()
            if senderZone ~= '' and myZone ~= '' and senderZone ~= myZone then return end

            _pullState.phase = tostring(content.phase or 'idle')
            _pullState.mobId = tonumber(content.mobId) or 0
            _pullState.mobName = tostring(content.mobName or '')
            _pullState.eta = tonumber(content.eta) or 0
            _pullState.mult = tonumber(content.mult) or 1.0
            _pullState.dist = tonumber(content.dist) or 0
            _pullState.updatedAt = os.clock()
            return
        end

        -- Mob HP estimates from the group's damage observer (usually the tank)
        if id == 'mobhp:update' then
            if fromMe then return end
            local senderZone = tostring(content.zone or '')
            local myZone = safeZone()
            if senderZone ~= '' and myZone ~= '' and senderZone ~= myZone then return end

            if type(content.estimates) == 'table' then
                local now = os.clock()
                for name, est in pairs(content.estimates) do
                    if type(est) == 'table' and tonumber(est.maxHP) then
                        _remoteMobHp[name] = {
                            maxHP = tonumber(est.maxHP),
                            weight = tonumber(est.weight) or 0,
                            updatedAt = now,
                        }
                    end
                end
            end
            return
        end

        -- Tank coordination: repositioning notification
        if id == 'tank:repositioning' then
            if fromMe then return end
            if not senderInSameZone(content, sender) then return end
            if not senderIsAuthorizedTank(content, sender) then return end
            if isStaleGuardedMessage(id, content, sender) then return end
            _callPositioning('enterSoftPause')
            return
        end

        if id == 'tank:settled' then
            if fromMe then return end
            if not senderInSameZone(content, sender) then return end
            if not senderIsAuthorizedTank(content, sender) then return end
            if isStaleGuardedMessage(id, content, sender) then return end
            _callPositioning('exitSoftPause')
            return
        end

        if id == 'tank:taunt_run' then
            if fromMe then return end
            if not senderInSameZone(content, sender) then return end
            if not senderIsAuthorizedTank(content, sender) then return end
            if isStaleGuardedMessage(id, content, sender) then return end
            _callPositioning('enterSoftPause')
            return
        end

        if id == 'tank:taunt_done' then
            if fromMe then return end
            if not senderInSameZone(content, sender) then return end
            if not senderIsAuthorizedTank(content, sender) then return end
            if isStaleGuardedMessage(id, content, sender) then return end
            _callPositioning('exitSoftPause')
            return
        end

        -- Tank coordination: mode change notification
        if id == 'tank:mode' then
            if fromMe then return end
            if not senderInSameZone(content, sender) then return end
            if not senderIsAuthorizedTank(content, sender) then return end
            if isStaleGuardedMessage(id, content, sender) then return end
            _tankState.tankMode = content.mode
            return
        end

        -- Pull coordination: cooperative election. Multiple characters with
        -- Pull_enabled would otherwise race; the earliest-startedAt in each
        -- zone wins, later peers yield (they still tick their sensors and
        -- state, they just skip issuing actual pulls). See automation/pull.lua
        -- for the yield decision.
        if id == 'pull:intent' then
            if not senderInSameZone(content, sender) then return end
            if isStaleGuardedMessage(id, content, sender) then return end
            local senderKey = peerKey(sender.server, sender.character)
            if senderKey == ':' then return end
            _pullPeers[senderKey] = {
                key = senderKey,
                from = tostring(sender.character or ''),
                server = tostring(sender.server or ''),
                startedAt = tonumber(content.startedAt) or 0,
                zone = tostring(content.zone or ''),
                updatedAt = os.clock(),
            }
            return
        end

        -- Tank coordination: live camp anchor. Broadcast by sk_tank whenever
        -- it re-anchors its own idle position. Pull worker prefers this over
        -- its historical setCampHere() coordinate so RETURN_CAMP follows tank
        -- drift instead of returning to the position at first pull.
        if id == 'tank:camp_anchor' then
            if not senderInSameZone(content, sender) then return end
            if not senderIsAuthorizedTank(content, sender) then return end
            if isStaleGuardedMessage(id, content, sender) then return end
            local x = tonumber(content.x)
            local y = tonumber(content.y)
            local z = tonumber(content.z)
            if x and y and z then
                _tankState.campAnchor = {
                    x = x, y = y, z = z,
                    from = tostring(sender.character or ''),
                    updatedAt = os.clock(),
                }
            end
            return
        end

        -- CC coordination: receive mez list from mezzer. NOT gated on fromMe:
        -- the mezzer's own sibling workers (its sk_tank/sk_dps) need mez
        -- state too; in the mezzer's own cc process the entries just mirror
        -- localMezzes (merged by max-expiry — harmless).
        if id == 'cc:mezlist' then
            if not senderInSameZone(content, sender) then return end
            local CC = package.loaded['sidekick-next.automation.cc']
            if CC and CC.receiveMezList then
                CC.receiveMezList(content)
            end
            return
        end

        -- CC coordination: receive mez claim. NOT gated on fromMe — the
        -- claimant's own sk_tank needs it (isMobMezClaimed). The claimant's
        -- own cc process guards against self-poisoning inside receiveClaim
        -- (it skips claims it holds locally).
        if id == 'cc:claim' then
            if not senderInSameZone(content, sender) then return end
            local CC = package.loaded['sidekick-next.automation.cc']
            if CC and CC.receiveClaim then
                CC.receiveClaim(content)
            end
            return
        end

        -- CC coordination: charm-pet protection state from the charming
        -- enchanter. NOT gated on fromMe — sibling workers on the enchanter's
        -- own character (its sk_dps, etc.) need this too, or the enchanter
        -- would nuke its own pet during a charm break. Idempotent last-write-
        -- wins, so accepting our own loopback is harmless.
        if id == 'cc:charmpet' then
            if not senderInSameZone(content, sender) then return end
            if isStaleGuardedMessage(id, content, sender) then return end
            local petId = tonumber(content.petId) or 0
            local owner = tostring(sender.character or '')
            local ownerServer = tostring(sender.server or '')
            local ownerKey = peerKey(ownerServer, owner)
            if ownerKey == ':' then return end
            local envelope = type(content.envelope) == 'table' and content.envelope or {}
            _charmStates[ownerKey] = {
                key = ownerKey,
                petId = petId,
                petName = tostring(content.petName or ''),
                -- Missing on older peers means "active" for fail-closed
                -- compatibility: never keep attacking an ambiguous pet.
                active = petId > 0 and content.active ~= false,
                ownerName = owner,
                ownerServer = ownerServer,
                sessionId = tostring(envelope.session or ''),
                zone = tostring(content.zone or envelope.zone or ''),
                instanceId = tonumber(envelope.instanceId) or 0,
                updatedAt = os.clock(),
            }
            return
        end

        -- Debuff coordination: receive debuff claim from another debuffer
        if id == 'debuff:claim' then
            if fromMe then return end
            if not senderInSameZone(content, sender) then return end
            local Debuff = package.loaded['sidekick-next.automation.debuff']
            if Debuff and Debuff.receiveClaim then
                Debuff.receiveClaim(content)
            end
            return
        end

        if id == 'debuff:release' then
            if fromMe then return end
            if not senderInSameZone(content, sender) then return end
            local Debuff = package.loaded['sidekick-next.automation.debuff']
            if Debuff and Debuff.receiveRelease then
                Debuff.receiveRelease(content)
            end
            return
        end

        -- Debuff coordination: receive debuff landed notification
        if id == 'debuff:landed' then
            if fromMe then return end
            if not senderInSameZone(content, sender) then return end
            local Debuff = package.loaded['sidekick-next.automation.debuff']
            if Debuff and Debuff.receiveDebuffLanded then
                Debuff.receiveDebuffLanded(content)
            end
            return
        end

        -- Healing coordination: incoming heal broadcasts (uses callback to avoid circular require)
        if id == 'heal:incoming' then
            if fromMe then return end
            if not senderInSameZone(content, sender) then return end
            local cb = _healingCallbacks['heal:incoming']
            if cb then
                local senderName = tostring(sender.character or sender.name or 'unknown')
                pcall(cb, content, senderName)
            end
            return
        end

        if id == 'heal:landed' then
            if fromMe then return end
            if not senderInSameZone(content, sender) then return end
            local cb = _healingCallbacks['heal:landed']
            if cb then
                local senderName = tostring(sender.character or sender.name or 'unknown')
                pcall(cb, content, senderName)
            end
            return
        end

        if id == 'heal:cancelled' then
            if fromMe then return end
            if not senderInSameZone(content, sender) then return end
            local cb = _healingCallbacks['heal:cancelled']
            if cb then
                local senderName = tostring(sender.character or sender.name or 'unknown')
                pcall(cb, content, senderName)
            end
            return
        end

        -- Healing coordination: claim that we're healing a target (prevents multi-healer pile-on).
        -- expiresAt arrives as wall-clock epoch seconds (os.time()) so it's comparable across peers.
        if id == 'heal:claim' then
            if fromMe then return end
            if not senderInSameZone(content, sender) then return end
            local tid = tonumber(content.targetId) or 0
            if tid <= 0 then return end
            local from = tostring(sender.character or '')
            if from == '' then return end
            local nowEpoch = os.time()
            _healClaims[tid] = _healClaims[tid] or {}
            _healClaims[tid][from] = {
                spellName = tostring(content.spellName or ''),
                tier = tostring(content.tier or ''),
                priority = tonumber(content.priority),
                expectedAmount = math.max(0, tonumber(content.expectedAmount) or 0),
                castTimeMs = math.max(0, tonumber(content.castTimeMs) or 0),
                projectedNeed = math.max(0, tonumber(content.projectedNeed) or 0),
                coveragePct = math.max(0, tonumber(content.coveragePct) or 0),
                claimKey = tostring(content.claimKey or ''),
                expiresAt = math.max(nowEpoch,
                    math.min(tonumber(content.expiresAt)
                        or (nowEpoch + HEAL_CLAIM_TTL),
                        nowEpoch + HEAL_CLAIM_MAX_TTL)),
                claimedAt = nowEpoch,   -- keep in epoch seconds to match expiresAt
                from = from,
            }
            return
        end

        -- Healing coordination: HoT presence tracking (cannot be queried cross-client, so share it).
        if id == 'heal:hots' then
            if fromMe then return end
            if not senderInSameZone(content, sender) then return end
            local tid = tonumber(content.targetId) or 0
            if tid <= 0 then return end
            local from = tostring(sender.character or '')
            if from == '' then return end
            local spellName = tostring(content.spellName or '')
            if spellName == '' then return end
            local nowEpoch = os.time()
            _hotStates[tid] = _hotStates[tid] or {}
            _hotStates[tid][from] = _hotStates[tid][from] or {}
            -- Per-spell keying: a single healer can stack multiple HoTs on the
            -- same target (e.g. Promised + regular HoT). Without this, the
            -- second cast overwrote the first in tracking.
            _hotStates[tid][from][spellName] = {
                spellName = spellName,
                expiresAt = math.max(nowEpoch,
                    math.min(tonumber(content.expiresAt)
                        or (nowEpoch + HOT_DEFAULT_TTL),
                        nowEpoch + HOT_MAX_TTL)),
                from = from,
            }
            return
        end

        -- Buff coordination: receive buff list from another buffer
        if id == 'buff:list' then
            if fromMe then return end
            if not senderInSameZone(content, sender) then return end
            local Buff = package.loaded['sidekick-next.automation.buff']
            if Buff and Buff.receiveBuffList then
                Buff.receiveBuffList(content)
            end
            return
        end

        -- Buff coordination: receive buff claim from another buffer
        if id == 'buff:claim' then
            if fromMe then return end
            if not senderInSameZone(content, sender) then return end
            local Buff = package.loaded['sidekick-next.automation.buff']
            if Buff and Buff.receiveClaim then
                Buff.receiveClaim(content)
            end
            return
        end

        -- Buff coordination: receive buff landed notification
        if id == 'buff:landed' then
            if not fromMe then
                if not senderInSameZone(content, sender) then return end
                local Buff = package.loaded['sidekick-next.automation.buff']
                if Buff and Buff.receiveBuffLanded then
                    Buff.receiveBuffLanded(content)
                end
            end
            -- Clear any pending buff request that this landing satisfies (also
            -- when fromMe — we may have answered our own request).
            local Reqs = package.loaded['sidekick-next.utils.buff_requests']
            if Reqs and Reqs.clearRequest then
                local tid = tonumber(content.targetId) or 0
                local cat = tostring(content.buffType or content.category or '')
                if tid > 0 and cat ~= '' then Reqs.clearRequest(tid, cat) end
            end
            return
        end

        -- Buff request: peer asks the team for a specific buff category
        if id == 'buff:need' then
            if not senderInSameZone(content, sender) then return end
            local Reqs = package.loaded['sidekick-next.utils.buff_requests']
            if Reqs and Reqs.receiveNeed then
                Reqs.receiveNeed(content)
            end
            return
        end

        -- Buff coordination: receive buff blocks from peer
        if id == 'buff:blocks' then
            if fromMe then return end
            if not senderInSameZone(content, sender) then return end
            local Buff = package.loaded['sidekick-next.automation.buff']
            if Buff and Buff.receiveBlocks then
                Buff.receiveBlocks(content)
            end
            return
        end

        -- Cure coordination: receive cure claim from another curer
        if id == 'cure:claim' then
            if fromMe then return end
            if not senderInSameZone(content, sender) then return end
            local Cures = package.loaded['sidekick-next.automation.cures']
            if Cures and Cures.receiveClaim then
                Cures.receiveClaim(content)
            end
            return
        end

        -- Cure coordination: peer's cure capabilities (for shard splitting).
        if id == 'cure:capabilities' then
            if fromMe then return end
            if not senderInSameZone(content, sender) then return end
            local Cures = package.loaded['sidekick-next.automation.cures']
            if Cures and Cures.receiveCapabilities then
                Cures.receiveCapabilities(content)
            end
            return
        end

        -- Cure coordination: receive cure landed notification
        if id == 'cure:landed' then
            if fromMe then return end
            if not senderInSameZone(content, sender) then return end
            local Cures = package.loaded['sidekick-next.automation.cures']
            if Cures and Cures.receiveCureLanded then
                Cures.receiveCureLanded(content)
            end
            return
        end
    end

    _processActorMessage = processActorMessage
    local function enqueueActorMessage(message, expectedId)
        local okRaw, raw = pcall(function()
            return message and message()
        end)
        if not okRaw then
            recordTransportDrop('callback_read_failed', 'malformed')
            return
        end
        if type(raw) ~= 'table' then
            recordTransportDrop('callback_malformed', 'malformed')
            return
        end
        local id = tostring(raw.id or ''):lower()
        if expectedId and id ~= expectedId then
            recordTransportDrop('callback_unexpected_message_id', 'malformed')
            return
        end
        local sender = normalize_sender(message.sender)
        if tostring(sender.character or '') == ''
            or tostring(sender.server or '') == ''
            or tostring(sender.script or '') == '' then
            recordTransportDrop('callback_incomplete_sender', 'identityRejected')
            return
        end
        local senderCharacter = tostring(sender.character or ''):lower()
        local senderServer = tostring(sender.server or ''):lower()
        local isLocal = senderCharacter ~= '' and senderServer ~= ''
            and senderCharacter == _selfNameLower and senderServer == _selfServerLower
        if not isLocal and (id:sub(1, 6) == 'lease:' or id:sub(1, 3) == 'sk:') then
            recordTransportDrop('callback_remote_control', 'controlRejected')
            return
        end
        local content, copyErr = boundedCopy(raw)
        if not content then
            recordTransportDrop(tostring(copyErr or 'copy_failed'), 'malformed')
            return
        end
        local envelope = type(content.envelope) == 'table' and content.envelope or {}
        local pendingKey = nil
        if tostring(envelope.session or '') ~= '' and tonumber(envelope.sequence) then
            pendingKey = table.concat({
                endpointKey(sender),
                tostring(envelope.session),
                tostring(envelope.sequence),
            }, '|')
            if _pendingActorKeys[pendingKey] then
                recordTransportDrop('callback_duplicate', 'duplicate')
                return
            end
        end
        if #_pendingActorMessages >= MAX_PENDING_MESSAGES then
            recordTransportDrop('callback_queue_overflow', 'queueOverflow')
            return
        end
        if pendingKey then _pendingActorKeys[pendingKey] = true end
        _pendingActorMessages[#_pendingActorMessages + 1] = {
            content = content,
            sender = sender,
            receivedAtMs = monotonicMs(),
            pendingKey = pendingKey,
        }
    end
    _dropbox = _actors.register('sidekick', function(message)
        enqueueActorMessage(message)
    end)

    -- Companion status requests use the same bounded inbox. Responses are
    -- asynchronous Actor messages sent from tick(), not RPC replies from this
    -- non-yieldable callback.
    local okStatus, statusDropbox = pcall(function()
        return _actors.register('sidekick_status', function(message)
            enqueueActorMessage(message, 'eq_ui:automation:req')
        end)
    end)
    if okStatus then _statusDropbox = statusDropbox end

    return _dropbox
end

function M.getDebugState()
    local primaryDiag = {}
    for key, value in pairs(_primaryTargetDiag) do primaryDiag[key] = value end
    primaryDiag.ageMs = _primaryTargetDiag.updatedAtMs > 0
        and math.max(0, monotonicMs() - _primaryTargetDiag.updatedAtMs) or nil
    return {
        actors_loaded = _actors ~= nil,
        dropbox_ready = _dropbox ~= nil,
        init_error = _actorsInitError,
        docked = M._docked == true,
        last_send_err = _lastSendErr,
        last_send_result = _lastSendResult,
        self = { name = _selfName, server = _selfServer, zone = _selfZone },
        last_gt_msg_at = _lastGroupTargetMsgAt or 0,
        last_gt_msg_id = _lastGroupTargetMsgId or '',
        last_bounds_req_at = _lastBoundsReqAt or 0,
        primaryTarget = primaryDiag,
        transport = {
            received = _transportStats.received,
            dropped = _transportStats.dropped,
            queueOverflow = _transportStats.queueOverflow,
            malformed = _transportStats.malformed,
            identityRejected = _transportStats.identityRejected,
            expired = _transportStats.expired,
            duplicate = _transportStats.duplicate,
            staleSession = _transportStats.staleSession,
            controlRejected = _transportStats.controlRejected,
            lastDropReason = _transportStats.lastDropReason,
            byReason = _transportStats.byReason,
            pending = #_pendingActorMessages,
            outbound = outboundSnapshot(true),
        },
    }
end

--- Supply the coordinator-owned Actor Team context to worker-local gateway
--- instances. Passing nil, a disabled snapshot, or an empty team clears trust.
function M.setTeamContext(team)
    if type(team) == 'table' and team.enabled == true then
        _trustedTeamSnapshot = boundedCopy(team)
        _trustedTeamId = tostring(team.teamId or '')
        _trustedTeamMembers = {}
        local now = monotonicMs()
        for _, member in ipairs(team.members or {}) do
            local key = peerKey(member.server, member.character)
            if key ~= ':' then
                _trustedTeamMembers[key] = true
                local copy = boundedCopy(member) or {}
                copy.lastSeenAtMs = now - math.max(0,
                    tonumber(member.ageMs) or 0)
                _teamPresenceHistory[key] = copy
            end
        end
        local retentionMs =
            CoordinationPolicy.PEER_ACTIVITY_RETENTION_SECONDS * 1000
        for key, member in pairs(_teamPresenceHistory) do
            if (now - (tonumber(member.lastSeenAtMs) or 0)) > retentionMs then
                _teamPresenceHistory[key] = nil
            end
        end
    else
        _trustedTeamSnapshot = nil
        _trustedTeamId = ''
        _trustedTeamMembers = nil
        _teamPresenceHistory = {}
    end
end

function M.getTeamSnapshot()
    return boundedCopy(_trustedTeamSnapshot)
end

function M.setDocked(docked)
    local nextDocked = docked == true
    if M._docked == nextDocked then return end
    M._docked = nextDocked
    -- GroupTarget otherwise keeps the previous true value until its staleness
    -- timeout. Send the false edge immediately so disabling or closing the bar
    -- cannot leave the companion command controls oscillating.
    if not nextDocked then
        sendToGroupTarget({ id = 'sidekick:docked', docked = false })
    end
end

local function buildCapabilityOverlay(status)
    local overlay = boundedCopy(status) or {}
    -- Actor Team owns common presence/vitals/target state. Keep this overlay
    -- focused on UI capabilities and controls.
    for _, key in ipairs({
        'zone', 'hp', 'currentHP', 'maxHP', 'dead', 'hovering',
        'mana', 'endur', 'class', 'targetId', 'targetType',
        'targetName', 'combat',
    }) do
        overlay[key] = nil
    end
    return overlay
end

local function stableValueSignature(value, depth)
    depth = depth or 0
    if depth > 8 then return '<depth>' end
    local kind = type(value)
    if kind ~= 'table' then return kind .. ':' .. tostring(value) end
    local keys = {}
    for key in pairs(value) do keys[#keys + 1] = key end
    table.sort(keys, function(a, b) return tostring(a) < tostring(b) end)
    local parts = { '{' }
    for _, key in ipairs(keys) do
        parts[#parts + 1] = tostring(key)
        parts[#parts + 1] = '='
        parts[#parts + 1] = stableValueSignature(value[key], depth + 1)
        parts[#parts + 1] = ';'
    end
    parts[#parts + 1] = '}'
    return table.concat(parts)
end

function M.tick(opts)
    opts = opts or {}
    local now = os.clock()

    -- Refresh cached location before draining so same-zone checks use the
    -- current zone after a zone-in.
    _selfZone = safeZone()

    -- Actor callbacks only enqueue. Process messages here in the yieldable
    -- main coroutine, where receiver code may safely perform normal work.
    if _processActorMessage and #_pendingActorMessages > 0 then
        local pending = _pendingActorMessages
        local remaining = {}
        local maxDrain = math.max(1,
            tonumber(CoordinationPolicy.MESSAGE_QUEUE.MAX_PER_DRAIN) or 64)
        for index, entry in ipairs(pending) do
            if index <= maxDrain then
                if entry.pendingKey then _pendingActorKeys[entry.pendingKey] = nil end
                local content, sender = validateInbound(entry)
                local isLocal = sender
                    and tostring(sender.character or ''):lower()
                        == tostring(_selfName or ''):lower()
                    and tostring(sender.server or ''):lower()
                        == tostring(_selfServer or ''):lower()
                if content and (opts.localOnly ~= true or isLocal) then
                    -- Preserve validated transport provenance for consumers
                    -- that need exact worker-route checks.
                    content._skActorSenderScript = tostring(sender.script or '')
                    content._skActorSenderServer = tostring(sender.server or '')
                    content._skActorReceivedAt = os.clock()
                    pcall(_processActorMessage, content, sender)
                end
            else
                remaining[#remaining + 1] = entry
            end
        end
        _pendingActorMessages = remaining
    end

    -- Keep same-character command/status transport alive when peer Actors are
    -- disabled, without processing peer state or emitting periodic broadcasts.
    if opts.transportOnly == true then return end

    -- Periodic heal-claim pruning (every PRUNE_INTERVAL seconds)
    if (now - _lastPruneAt) >= PRUNE_INTERVAL then
        _lastPruneAt = now
        pruneHealTables()
    end

    -- Claim-ledger throttled save.
    local L = ledger()
    if L and L.tick then L.tick() end

    -- Buff request queue prune.
    local okR, Reqs = pcall(require, 'sidekick-next.utils.buff_requests')
    if okR and Reqs and Reqs.tick then Reqs.tick() end

    -- If docked, broadcast frequently so GT can hide its control column with staleness check.
    if M._docked then
        if (now - _lastDockedSendAt) >= 0.25 then
            _lastDockedSendAt = now
            sendToGroupTarget({ id = 'sidekick:docked', docked = true })
        end
        -- If we're configured to dock but don't yet have GT bounds, request them.
        if (not _G.GroupTargetBounds or not _G.GroupTargetBounds.loaded) and (now - _lastBoundsReqAt) >= 1.0 then
            _lastBoundsReqAt = now
            sendToGroupTarget({ id = 'window:bounds:req' })
        end
    end

    -- Status broadcast — rate limited + dedup (skip if nothing meaningful changed)
    local status = opts.peerVitals or opts.peerCapabilities
    local statusTopic = opts.peerVitals and 'peer:vitals'
        or (opts.peerCapabilities and 'peer:capabilities') or nil
    local peerPayload = opts.peerCapabilities
        and buildCapabilityOverlay(status) or status
    local statusSignature = opts.peerCapabilities
        and stableValueSignature(peerPayload) or nil
    local statusElapsed = now - _lastStatusSendAt
    if status and statusTopic and statusElapsed >= 0.2 then
        local prev = _lastStatusPayload
        local changed
        if opts.peerCapabilities then
            changed = statusSignature ~= _lastStatusSignature
                or statusElapsed >= 2.0
        else
            changed = not prev
                or (status.hp or 0) ~= (prev.hp or 0)
                or (status.currentHP or 0) ~= (prev.currentHP or 0)
                or (status.maxHP or 0) ~= (prev.maxHP or 0)
                or (status.mana or 0) ~= (prev.mana or 0)
                or (status.endur or 0) ~= (prev.endur or 0)
                or (status.inGame == true) ~= (prev.inGame == true)
                or (status.dead == true) ~= (prev.dead == true)
                or (status.hovering == true) ~= (prev.hovering == true)
                or (status.characterId or 0) ~= (prev.characterId or 0)
                or (status.zone or '') ~= (prev.zone or '')
                or (status.targetId or 0) ~= (prev.targetId or 0)
                or (status.combat) ~= (prev.combat)
                or (status.casting or '') ~= (prev.casting or '')
                or (status.automationPaused == true)
                    ~= (prev.automationPaused == true)
                or (status.chase == true) ~= (prev.chase == true)
                or statusElapsed >= 2.0
        end
        if changed then
            _lastStatusSendAt = now
            _lastStatusPayload = boundedCopy(status) or status
            _lastStatusSignature = statusSignature
            if opts.peerCapabilities then sendToGroupTarget(status) end
            M.publish(statusTopic, peerPayload)
        end
    end
end

function M.getRemoteCharacters()
    -- Keep previously-observed peer identity long enough that a crashed sender
    -- cannot become "unknown" and therefore fail open while one of its short
    -- distributed claims is still being considered. Only fresh status rows are
    -- returned to legacy UI consumers.
    local now = os.clock()
    local view = {}
    for key, data in pairs(_remoteCharacters) do
        local age = now - (data.lastSeen or 0)
        if age > CoordinationPolicy.PEER_ACTIVITY_RETENTION_SECONDS then
            _remoteCharacters[key] = nil
        elseif age <= CoordinationPolicy.REMOTE_STATUS_RETENTION_SECONDS then
            local team = _teamPresenceHistory[key]
            if team then
                data.zone = tostring(team.zone or data.zone or '')
                data.class = tostring(team.class or data.class or '')
                data.hp = tonumber(team.hpPct) or data.hp
                data.mana = tonumber(team.manaPct) or data.mana
                data.endur = tonumber(team.endurancePct) or data.endur
                data.dead = team.dead == true
                data.inGame = team.inGame == true
                data.combat = team.inCombat == true
                data.targetId = tonumber(team.targetId) or 0
                data.targetType = tostring(team.targetType or '')
                data.targetName = tostring(team.targetName or '')
            end
            local name = tostring(data.character or '')
            if name == '' or view[name] ~= nil then name = key end
            view[name] = data
        end
    end
    return view
end

--- Describe whether a previously observed trusted SideKick peer is still
--- advancing. Unknown peers fail open for first-contact coordination; once a
--- peer is observed, stale/unavailable/team/zone mismatches fail closed until
--- the bounded activity-retention window expires.
function M.getPeerLiveness(character, expectedZone, expectedServer)
    local wantedName = tostring(character or ''):lower()
    local wantedServer = tostring(expectedServer or ''):lower()
    if wantedName == '' then
        return { known = false, fresh = true, reason = 'identity_unknown' }
    end
    if wantedName == _selfNameLower
        and (wantedServer == '' or wantedServer == _selfServerLower) then
        return {
            known = true,
            fresh = true,
            ageMs = 0,
            reason = 'self',
            name = _selfName,
            server = _selfServer,
            zone = safeZone(),
        }
    end

    local peer = nil
    if wantedServer ~= '' then
        peer = _teamPresenceHistory[peerKey(wantedServer, wantedName)]
    else
        for _, candidate in pairs(_teamPresenceHistory) do
            if tostring(candidate.character or ''):lower() == wantedName then
                if peer then
                    return {
                        known = false,
                        fresh = false,
                        reason = 'server_ambiguous',
                        name = character,
                    }
                end
                peer = candidate
            end
        end
    end
    if not peer then
        return {
            known = false,
            fresh = true,
            reason = 'not_observed',
            name = character,
        }
    end

    local ageSeconds = math.max(0,
        (monotonicMs() - (tonumber(peer.lastSeenAtMs) or 0)) / 1000)
    local peerServer = tostring(peer.server or '')
    local peerZone = tostring(peer.zone or '')
    local wantedZone = tostring(expectedZone or '')
    local fresh, reason = true, 'fresh'
    if not currentTeamMember(peerServer, peer.character) then
        fresh, reason = false, 'team_untrusted'
    elseif wantedServer ~= '' and peerServer:lower() ~= wantedServer then
        fresh, reason = false, 'server_mismatch'
    elseif wantedZone ~= '' and peerZone == '' then
        fresh, reason = false, 'zone_unknown'
    elseif wantedZone ~= '' and peerZone:lower() ~= wantedZone:lower() then
        fresh, reason = false, 'zone_mismatch'
    elseif peer.inGame == false then
        fresh, reason = false, 'peer_unavailable'
    elseif peer.dead == true then
        fresh, reason = false, 'peer_dead'
    elseif ageSeconds > CoordinationPolicy.PEER_STALE_SECONDS then
        fresh, reason = false, 'heartbeat_stale'
    end

    return {
        known = true,
        fresh = fresh,
        ageMs = math.floor(ageSeconds * 1000),
        reason = reason,
        name = tostring(peer.character or character or ''),
        server = peerServer,
        zone = peerZone,
        inGame = peer.inGame,
        dead = peer.dead == true,
        hovering = false,
    }
end

function M.isPeerLeaseFresh(character, expectedZone, expectedServer)
    local info = M.getPeerLiveness(character, expectedZone, expectedServer)
    return info.fresh ~= false, info
end

--- Return the number of live SideKick status peers currently known to this UI.
--- This is the generic Actor network count, not the narrower coordinator-owned
--- Actor Team count used for trusted OOG automation such as resurrection.
function M.getPeerCount(sameZoneOnly)
    local peers = M.getRemoteCharacters()
    local currentZone = sameZoneOnly == true and safeZone() or nil
    local count = 0
    for _, data in pairs(peers) do
        if currentZone == nil or tostring(data.zone or '') == currentZone then
            count = count + 1
        end
    end
    return count
end

pruneHealTables = function()
    -- expiresAt values stored in this module are wall-clock epoch seconds
    -- (os.time()), matching the format senders broadcast. Using os.time()
    -- here means comparisons are valid across peers despite each Lua
    -- interpreter having its own os.clock() baseline.
    local now = os.time()

    -- Remove expired claims only (by their own authoritative TTL).
    for tid, perFrom in pairs(_healClaims) do
        local any = false
        for from, c in pairs(perFrom or {}) do
            if (tonumber(c.expiresAt) or 0) <= now then
                perFrom[from] = nil
            else
                any = true
            end
        end
        if not any then _healClaims[tid] = nil end
    end

    -- _hotStates is now nested [tid][from][spellName] — prune leaves, then
    -- collapse empty parent tables.
    for tid, perFrom in pairs(_hotStates) do
        local anyPeer = false
        for from, perSpell in pairs(perFrom or {}) do
            local anySpell = false
            for spellName, h in pairs(perSpell or {}) do
                if (tonumber(h.expiresAt) or 0) <= now then
                    perSpell[spellName] = nil
                else
                    anySpell = true
                end
            end
            if not anySpell then
                perFrom[from] = nil
            else
                anyPeer = true
            end
        end
        if not anyPeer then _hotStates[tid] = nil end
    end
end

function M.pruneHealState()
    pruneHealTables()
end

function M.getHealClaims()
    pruneHealTables()
    return _healClaims
end

function M.getHoTStates()
    pruneHealTables()
    return _hotStates
end

--- Check if a target is already claimed by another healer.
--- Returns the most recent (winning) claim, or nil if unclaimed.
--- @param targetId number The spawn ID to check
--- @return table|nil The winning claim { from, spellName, tier, claimedAt, expiresAt } or nil
local function healClaimPriority(claim)
    if claim and tonumber(claim.priority) then return tonumber(claim.priority) end
    return claim and tostring(claim.tier or ''):lower() == 'emergency' and 0 or 1
end

local HEAL_REQUIRED_COVERAGE = 0.80

local function claimCoverage(claim)
    local expected = math.max(0, tonumber(claim and claim.expectedAmount) or 0)
    local need = math.max(0, tonumber(claim and claim.projectedNeed) or 0)
    if need <= 0 then return 0, expected, need end
    return expected / need, expected, need
end

local function claimBeats(a, b)
    if not b then return true end
    local ap = healClaimPriority(a)
    local bp = healClaimPriority(b)
    if ap ~= bp then return ap < bp end

    local ac, ae, an = claimCoverage(a)
    local bc, be, bn = claimCoverage(b)
    local aa = ac >= HEAL_REQUIRED_COVERAGE
    local ba = bc >= HEAL_REQUIRED_COVERAGE
    if aa ~= ba then return aa end

    local at = math.max(0, tonumber(a and a.castTimeMs) or 0)
    local bt = math.max(0, tonumber(b and b.castTimeMs) or 0)
    if aa then
        -- Once both heals are sufficient, prefer the one that lands first,
        -- then the one that wastes less healing.
        if at ~= bt then return at < bt end
        local ao = math.max(0, ae - an)
        local bo = math.max(0, be - bn)
        if ao ~= bo then return ao < bo end
    else
        -- If neither heal is sufficient, take the strongest coverage first.
        if ac ~= bc then return ac > bc end
        if at ~= bt then return at < bt end
    end

    -- Final deterministic tie-break; no synchronized clocks are required.
    return tostring(a.from or ''):lower() < tostring(b.from or ''):lower()
end

function M.getWinningClaim(targetId, localClaim)
    pruneHealTables()
    local perFrom = _healClaims[targetId]
    local best = localClaim
    for _, claim in pairs(perFrom or {}) do
        if claim.from ~= _selfName and claimBeats(claim, best) then
            best = claim
        end
    end
    return best
end

--- Determine whether this character wins a distributed heal intent claim.
function M.isHealClaimWinner(targetId, localClaim)
    localClaim = localClaim or {}
    localClaim.from = localClaim.from or _selfName
    pruneHealTables()

    local localName = tostring(localClaim.from or _selfName or ''):lower()
    local claims = { localClaim }
    for _, claim in pairs(_healClaims[targetId] or {}) do
        if tostring(claim.from or ''):lower() ~= localName then
            claims[#claims + 1] = claim
        end
    end
    table.sort(claims, claimBeats)

    local requiredNeed = 0
    local hasExpected = false
    for _, claim in ipairs(claims) do
        requiredNeed = math.max(requiredNeed, tonumber(claim.projectedNeed) or 0)
        hasExpected = hasExpected or (tonumber(claim.expectedAmount) or 0) > 0
    end

    -- Preserve one-winner behavior if no contender has usable coverage data.
    if requiredNeed <= 0 or not hasExpected then
        local winner = claims[1]
        return winner ~= nil and tostring(winner.from or ''):lower() == localName, winner
    end

    local requiredCoverage = requiredNeed * HEAL_REQUIRED_COVERAGE
    local covered = 0
    local first = claims[1]
    for _, claim in ipairs(claims) do
        local accepted = covered < requiredCoverage
        if accepted then
            covered = covered + math.max(0, tonumber(claim.expectedAmount) or 0)
        end
        if tostring(claim.from or ''):lower() == localName then
            return accepted, accepted and claim or first
        end
    end
    return false, first
end

--- Register a callback for healing-related Actor messages
-- @param msgType string One of: 'heal:incoming', 'heal:landed', 'heal:cancelled'
-- @param callback function Called with (content, senderName) when message arrives
function M.registerHealingCallback(msgType, callback)
    _healingCallbacks[msgType] = callback
end

--- Register a callback for a generic Actor message.
-- Callback receives (content, sender, fromMe). Return true to stop further handling.
function M.registerMessageCallback(msgType, callback)
    if not msgType or not callback then return end
    msgType = tostring(msgType):lower()
    _messageCallbacks[msgType] = _messageCallbacks[msgType] or {}
    table.insert(_messageCallbacks[msgType], callback)
end

-- Private same-script transport selected only by TOPIC_CONTRACTS.
local function publishSameScript(msgId, payload)
    local ok, result = pcall(function()
        return _dropbox:send({
            mailbox = 'sidekick',
            server = _selfServer,
        }, payload)
    end)
    local failed = not ok or result == false
        or (type(result) == 'number' and result < 0)
    recordOutbound(msgId, 'same_script', payload, 1, failed and 1 or 0,
        failed and tostring(result) or nil)
    return not failed, failed and tostring(result) or nil
end

--- Register a consumer for a script-local worker telemetry stream.
-- Callback receives (data, envelope, sender).
function M.registerTelemetryCallback(stream, callback)
    if not stream or not callback then return end
    stream = tostring(stream):lower()
    _telemetryCallbacks[stream] = _telemetryCallbacks[stream] or {}
    table.insert(_telemetryCallbacks[stream], callback)
end

--- Register commands owned by one logical worker component.
-- Callback receives (command, data, envelope, sender, fromMe).
function M.registerWorkerCommand(component, callback)
    if not component or not callback then return end
    component = tostring(component):lower()
    _workerCommandCallbacks[component] = _workerCommandCallbacks[component] or {}
    table.insert(_workerCommandCallbacks[component], callback)
end

-- Scripts whose 'sidekick' mailbox should see fleet-wide state. Built lazily
-- from sk_lib's canonical lists.
local _fleetScripts = nil
local function fleetScripts()
    if _fleetScripts then return _fleetScripts end
    local lib = require('sidekick-next.sk_lib')
    local list = {}
    for _, s in ipairs(lib.Scripts.WORKERS or {}) do list[#list + 1] = s end
    local ui = lib.Scripts.UI
    if type(ui) == 'table' then
        for _, s in ipairs(ui) do list[#list + 1] = s end
    elseif type(ui) == 'string' then
        list[#list + 1] = ui
    end
    _fleetScripts = list
    return list
end

--- Broadcast to every registered SideKick script on connected characters.
--- Physical send cost scales with the active worker profile and team size;
--- reserve fleet topics for low-frequency cross-component state.
--- Needed because plain { mailbox = 'sidekick' } never crosses script names.
-- @param msgId string Message ID
-- @param payload table Message payload
local function publishFleet(msgId, payload)
    if not _dropbox then return end
    payload = prepareEnvelope(payload, msgId)
    if not payload then return false end
    if GUARDED_TOPICS[msgId] then
        -- Rolling compatibility for older peers that predate the standard
        -- envelope but already understand guarded session/sequence fields.
        payload.sessionId = payload.envelope.session
        payload.sequence = payload.envelope.sequence
    end
    local sendSummary = {
        attempts = 0,
        failures = 0,
        lastError = '',
        sequence = tonumber(payload.envelope and payload.envelope.sequence) or 0,
    }
    for _, script in ipairs(fleetScripts()) do
        sendSummary.attempts = sendSummary.attempts + 1
        local ok, result = pcall(function()
            return _dropbox:send({
                mailbox = 'sidekick',
                script = script,
                server = _selfServer,
            }, payload)
        end)
        if not ok or result == false
            or (type(result) == 'number' and result < 0) then
            sendSummary.failures = sendSummary.failures + 1
            sendSummary.lastError = tostring(ok and result or result)
        end
    end
    recordOutbound(msgId, 'fleet', payload, sendSummary.attempts,
        sendSummary.failures, sendSummary.lastError)
    return sendSummary
end

--- Publish a registered peer topic using its declared delivery contract.
--- Unknown topics fail closed so every producer has an explicit route.
function M.publish(msgId, payload)
    if not _dropbox then return false, 'actors_unavailable' end
    msgId = tostring(msgId or ''):lower()
    local contract = TOPIC_CONTRACTS[msgId]
    if not contract then
        recordTransportDrop('unregistered_publish_topic')
        return false, 'unregistered_publish_topic:' .. msgId
    end
    local result, err
    if contract.scope == 'fleet' then
        result = publishFleet(msgId, payload)
    elseif contract.scope == 'same_script' then
        local prepared = prepareEnvelope(payload, msgId)
        if not prepared then return false, 'invalid_payload' end
        result, err = publishSameScript(msgId, prepared)
    else
        recordTransportDrop('invalid_publish_scope')
        return false, 'invalid_publish_scope:' .. tostring(contract.scope)
    end
    local cat = CLAIM_CATEGORIES[msgId]
    if cat then
        local L = ledger()
        local from = type(payload) == 'table' and payload.from or _selfName
        if L then L.record(from, cat) end
    end
    return result, err
end

--- Send to another Lua script for this same character only. This avoids
--- broadcasting UI-only telemetry to every connected SideKick peer.
local function sendToLocalScript(scriptName, msgId, payload)
    if not _dropbox or not scriptName or scriptName == '' then return false end
    payload = prepareEnvelope(payload, msgId)
    if not payload then return false end
    local ok, result = pcall(function()
        return _dropbox:send({
            mailbox = 'sidekick',
            script = scriptName,
            character = _selfName,
            server = _selfServer,
        }, payload)
    end)
    local failed = not ok or result == false
        or (type(result) == 'number' and result < 0)
    recordOutbound(msgId, 'local_script', payload, 1, failed and 1 or 0,
        failed and tostring(result) or nil)
    return not failed
end

--- Send to a specific character's logical mailbox for a specific Lua script.
local function sendToCharacter(scriptName, character, server, msgId, payload)
    if not _dropbox or not scriptName or scriptName == ''
        or not character or character == '' then return false end
    server = tostring(server or '')
    if server == '' then server = _selfServer end
    if tostring(_selfServer or '') ~= ''
        and server:lower() ~= tostring(_selfServer):lower() then return false end
    payload = prepareEnvelope(payload, msgId)
    if not payload then return false end
    local ok, result = pcall(function()
        return _dropbox:send({
            mailbox = 'sidekick',
            script = scriptName,
            character = character,
            server = server,
        }, payload)
    end)
    local failed = not ok or result == false
        or (type(result) == 'number' and result < 0)
    recordOutbound(msgId, 'target_character', payload, 1, failed and 1 or 0,
        failed and tostring(result) or nil)
    return not failed
end

--- Send one standardized telemetry envelope to a local UI script.
function M.sendTelemetryToScript(scriptName, sourceModule, stream, data)
    _telemetrySequence = _telemetrySequence + 1
    return sendToLocalScript(scriptName, 'worker:telemetry', {
        telemetryVersion = TELEMETRY_VERSION,
        module = tostring(sourceModule or ''),
        stream = tostring(stream or ''):lower(),
        streamSequence = _telemetrySequence,
        sentAtMs = mq.gettime and mq.gettime() or math.floor(os.clock() * 1000),
        data = type(data) == 'table' and data or {},
    })
end

--- Route a standardized command to the active script that owns a module.
--- `opts.component` identifies a domain inside a consolidated worker.
function M.sendWorkerCommand(moduleName, command, data, opts)
    opts = type(opts) == 'table' and opts or {}
    local lib = require('sidekick-next.sk_lib')
    local spec = lib.getActiveWorkerSpec(moduleName) or lib.getWorkerSpec(moduleName)
    if not spec or not spec.script then return false, 'unknown_worker_module' end
    _workerCommandSequence = _workerCommandSequence + 1
    local payload = {
        commandVersion = WORKER_COMMAND_VERSION,
        module = tostring(moduleName or ''):lower(),
        component = tostring(opts.component or moduleName or ''):lower(),
        command = tostring(command or ''):lower(),
        requestId = tostring(opts.requestId or string.format('%s:%d',
            tostring(moduleName or ''), _workerCommandSequence)),
        commandSequence = _workerCommandSequence,
        sentAtMs = mq.gettime and mq.gettime() or math.floor(os.clock() * 1000),
        data = type(data) == 'table' and data or {},
    }
    if opts.character and tostring(opts.character) ~= '' then
        return sendToCharacter(spec.script, opts.character, opts.server,
            'worker:command', payload)
    end
    return sendToLocalScript(spec.script, 'worker:command', payload)
end

--- Broadcast the tank's declared primary and whether offense is authorized.
-- Includes zone information so receivers can filter by same zone
function M.broadcastTargetPrimary(targetId, targetName, killAuthorized)
    if not _dropbox then return end
    local me = mq.TLO.Me
    local tankId = (me and me() and me.ID and me.ID()) or nil
    -- Update zone before broadcast
    _selfZone = safeZone()
    -- Fleet fan-out: mezzers (sk_cc/sk_disciplines), assisters, and charm
    -- upkeep all live in OTHER scripts; a plain mailbox send would only reach
    -- other characters' sk_tank.
    local content = {
        targetId = tonumber(targetId) or 0,
        targetName = tostring(targetName or ''),
        killAuthorized = killAuthorized == true
            and (tonumber(targetId) or 0) > 0,
        tankId = tankId,
        tankName = _selfName,
        zone = _selfZone,
    }
    local result = M.publish('target:primary', content)
    _primaryTargetDiag.lastSend = {
        atMs = monotonicMs(),
        attempts = tonumber(result and result.attempts) or 0,
        failures = tonumber(result and result.failures) or 0,
        lastError = tostring(result and result.lastError or ''),
        sequence = tonumber(result and result.sequence) or 0,
        targetId = tonumber(targetId) or 0,
        killAuthorized = killAuthorized == true,
        tankId = tonumber(tankId) or 0,
    }
    return result
end

--- Broadcast that tank is repositioning (assisters enter soft-pause)
function M.broadcastTankRepositioning()
    if not _dropbox then return end
    _selfZone = safeZone()
    M.publish('tank:repositioning', { zone = _selfZone })
end

--- Broadcast that tank has settled (assisters exit soft-pause)
function M.broadcastTankSettled()
    if not _dropbox then return end
    _selfZone = safeZone()
    M.publish('tank:settled', { zone = _selfZone })
end

--- Broadcast that tank is doing a taunt run (assisters enter soft-pause)
function M.broadcastTauntRun()
    if not _dropbox then return end
    _selfZone = safeZone()
    M.publish('tank:taunt_run', { zone = _selfZone })
end

--- Broadcast that tank's taunt run completed (assisters exit soft-pause)
function M.broadcastTauntDone()
    if not _dropbox then return end
    _selfZone = safeZone()
    M.publish('tank:taunt_done', { zone = _selfZone })
end

--- Broadcast the tank's live camp anchor. Rate-limited by sk_tank's own 5s
--- refresh cadence; the receiver stores it in _tankState.campAnchor.
function M.broadcastTankCampAnchor(x, y, z)
    if not _dropbox then return end
    if not (x and y and z) then return end
    _selfZone = safeZone()
    M.publish('tank:camp_anchor', {
        x = tonumber(x), y = tonumber(y), z = tonumber(z),
        zone = _selfZone,
    })
end

--- Get the current tank state (for assisters to read)
function M.getTankState()
    local selected = selectedAssistAuthority()
    local selectedName = tostring(selected.name or ''):lower()
    local stateName = tostring(_tankState.tankName or ''):lower()
    local authorityChanged = _tankState.updatedAt > 0
        and selectedName ~= ''
        and stateName ~= selectedName
    if _tankState.updatedAt > 0
        and ((os.clock() - _tankState.updatedAt) > 5 or authorityChanged) then
        _tankState.primaryTargetId = nil
        _tankState.primaryTargetName = nil
        _tankState.killAuthorized = false
        _tankState.primaryRevision = nil
        _tankState.currentTargetId = nil
        _tankState.tankId = nil
        _tankState.tankName = nil
        _tankState.updatedAt = 0
    end
    return _tankState
end

--- Return the Tank's current positive kill authorization.
--- A fresh zero is a deliberate hold, and stale/absent state is not
--- authorization. Callers still validate the spawn immediately before use.
--- @param maxAgeSec number|nil Maximum publication age (default 5 seconds)
--- @return number|nil targetId
--- @return table|nil state
--- @return string reason
function M.getPrimaryKillAuthorization(maxAgeSec)
    local state = M.getTankState()
    local updatedAt = tonumber(state and state.updatedAt) or 0
    local maxAge = math.max(0.1, tonumber(maxAgeSec) or 5)
    if updatedAt <= 0 then return nil, state, 'primary_absent' end
    if (os.clock() - updatedAt) > maxAge then
        return nil, state, 'primary_stale'
    end
    local id = tonumber(state.primaryTargetId) or 0
    if id <= 0 then return nil, state, 'primary_hold' end
    if M.isCharmPet(id) then
        return nil, state, 'primary_charm_protected'
    end
    if state.killAuthorized ~= true then
        return nil, state, 'primary_not_engaged'
    end
    return id, state, 'authorized'
end

--- Get the tank's live camp anchor if one has been broadcast recently, else
--- nil. Consumers should treat nil as "no live anchor available; fall back
--- to your own stored coord."
function M.getTankCampAnchor(maxAgeSec)
    local a = _tankState.campAnchor
    if not a then return nil end
    if maxAgeSec and (os.clock() - (a.updatedAt or 0)) > maxAgeSec then
        return nil
    end
    return a
end

--- Broadcast our own pull intent. Callers pass startedAt (Lua seconds since
--- os.time epoch) — a fixed value that stays constant while this puller is
--- enabled, so earliest-wins comparisons are stable across broadcasts.
function M.broadcastPullIntent(startedAt)
    if not _dropbox then return end
    _selfZone = safeZone()
    M.publish('pull:intent', {
        startedAt = tonumber(startedAt) or os.time(),
        zone = _selfZone,
    })
end

--- Return the earliest-startedAt peer puller in our zone that is NOT us and
--- whose last broadcast is within PULLER_TTL_SEC, else nil. Callers should
--- yield when this returns a peer with startedAt <= self.startedAt.
function M.getEarliestPullPeer()
    local now = os.clock()
    local myKey = peerKey(_selfServer, _selfName)
    local myZone = tostring(_selfZone or ''):lower()
    local best
    for key, peer in pairs(_pullPeers) do
        if key ~= myKey and (now - (peer.updatedAt or 0)) <= PULLER_TTL_SEC then
            local peerZone = tostring(peer.zone or ''):lower()
            if myZone == '' or peerZone == '' or peerZone == myZone then
                if not best or (peer.startedAt or 0) < (best.startedAt or math.huge) then
                    best = peer
                end
            end
        end
    end
    return best
end

--- Get the protected charm-pet state (for target selection to read)
function M.getCharmState()
    local now = os.clock()
    local newest = nil
    for key, state in pairs(_charmStates) do
        if (now - (state.updatedAt or 0)) >= 30 then
            _charmStates[key] = nil
        elseif (tonumber(state.petId) or 0) > 0
            and (not newest or (state.updatedAt or 0) > (newest.updatedAt or 0)) then
            newest = state
        end
    end
    return newest or {
        petId = 0,
        petName = '',
        active = false,
        ownerName = '',
        ownerServer = '',
        updatedAt = 0,
    }
end

--- Return every protected charm pet keyed by server:owner.
function M.getCharmStates()
    M.getCharmState()
    return _charmStates
end

--- True only while the protected spawn is currently in its owner's pet slot.
--- A protected but inactive ID is a just-broken pet under recharm recovery.
function M.isActiveCharmPet(id)
    id = tonumber(id) or 0
    if id <= 0 then return false end
    local now = os.clock()
    for key, state in pairs(_charmStates) do
        if (now - (state.updatedAt or 0)) >= 30 then
            _charmStates[key] = nil
        elseif (tonumber(state.petId) or 0) == id and state.active == true then
            -- Do not return on an inactive match. During a session handoff an
            -- older owner record can briefly overlap the current publication;
            -- any active match must keep this spawn fully protected.
            return true
        end
    end
    return false
end

--- True if this spawn ID is a group charm pet (or a just-broken one still
--- under the owner's recovery window) and must never be attacked.
-- @param id number Spawn ID to check
function M.isCharmPet(id)
    id = tonumber(id) or 0
    if id <= 0 then return false end
    -- The owner rebroadcasts every few seconds while the pet (or its
    -- recovery window) is live; a long-silent entry means the owner's
    -- worker died — fail open so the mob can be killed.
    local now = os.clock()
    for key, state in pairs(_charmStates) do
        if (now - (state.updatedAt or 0)) >= 30 then
            _charmStates[key] = nil
        elseif (tonumber(state.petId) or 0) == id then
            return true
        end
    end
    return false
end

--- Broadcast pull-monitor state (tank-side; healers consume via getPullState)
-- @param state table { phase, mobId, mobName, eta, mult, dist }
function M.broadcastPullState(state)
    if not _dropbox then return end
    if type(state) ~= 'table' then return end
    _selfZone = safeZone()
    return M.publish('pull:incoming', {
        phase = state.phase,
        mobId = state.mobId,
        mobName = state.mobName,
        eta = state.eta,
        mult = state.mult,
        dist = state.dist,
        zone = _selfZone,
    })
end

--- Get the remote pull state from the tank's monitor
-- @return table|nil Pull state, or nil when stale (no fresh broadcast)
function M.getPullState()
    if _pullState.updatedAt == 0 then return nil end
    if (os.clock() - _pullState.updatedAt) > 4 then return nil end
    return _pullState
end

--- Broadcast mob HP estimates (observer-side)
-- @param estimates table mobName -> { maxHP, weight }
function M.broadcastMobHp(estimates)
    if not _dropbox then return end
    if type(estimates) ~= 'table' or not next(estimates) then return end
    _selfZone = safeZone()
    return M.publish('mobhp:update', {
        estimates = estimates,
        zone = _selfZone,
    })
end

--- Get a remote mob HP estimate by mob name (from the group's damage observer)
-- @param mobName string
-- @return number|nil maxHP
-- @return number weight
function M.getRemoteMobHp(mobName)
    local est = mobName and _remoteMobHp[mobName]
    if not est then return nil, 0 end
    if (os.clock() - est.updatedAt) > 30 then
        _remoteMobHp[mobName] = nil
        return nil, 0
    end
    return est.maxHP, est.weight or 0
end

--- Get current zone for comparison
function M.getCurrentZone()
    return safeZone()
end

--- Get peers in the same zone
-- @return table Array of {name, data} for peers in same zone
function M.getPeersInZone()
    local myZone = safeZone()
    if myZone == '' then return {} end

    local peers = {}
    for _, data in pairs(_remoteCharacters) do
        if data.zone == myZone then
            table.insert(peers, { name = data.character or '', key = data.key, data = data })
        end
    end
    return peers
end

--- Broadcast "Assist Me" command to all peers in the same zone
-- This tells all SideKick peers to assist your current target
-- @return boolean True if broadcast was sent
function M.broadcastAssistMe()
    if not _dropbox then return false end

    local target = mq.TLO.Target
    if not target or not target() then
        -- Echo disabled
        return false
    end

    local targetId = target.ID and target.ID() or 0
    local targetName = target.CleanName and target.CleanName() or 'Unknown'
    if targetId <= 0 then
        -- Echo disabled
        return false
    end

    -- Update zone before broadcast
    _selfZone = safeZone()

    local sendSummary = M.publish('assist:me', {
        targetId = targetId,
        targetName = targetName,
        zone = _selfZone,
    })

    -- Count peers in same zone
    local peerCount = 0
    for _, data in pairs(_remoteCharacters) do
        if data.zone == _selfZone then
            peerCount = peerCount + 1
        end
    end

    -- Echo disabled
    return type(sendSummary) == 'table' and sendSummary.attempts > 0
        and sendSummary.failures < sendSummary.attempts
end

--- Update zone on tick (call periodically to track zone changes)
function M.updateZone()
    _selfZone = safeZone()
end

--- Get the last outgoing status payload (what we're broadcasting)
-- @return table|nil The status payload or nil if not yet set
function M.getOutgoingStatus()
    return _lastStatusPayload
end

--- Get self info for debug display
-- @return table { name, server, zone }
function M.getSelfInfo()
    return {
        name = _selfName,
        server = _selfServer,
        zone = _selfZone,
    }
end

--- Get heal claims for debug display (no pruning, raw snapshot)
-- @return table Heal claims table
function M.getHealClaimsRaw()
    return _healClaims
end

--- Get HoT states for debug display (no pruning, raw snapshot)
-- @return table HoT states table
function M.getHoTStatesRaw()
    return _hotStates
end

return M
