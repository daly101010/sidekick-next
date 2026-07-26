local mq = require('mq')

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

local _actors = nil
local _dropbox = nil
local _statusDropbox = nil
local _selfName = ''
local _selfServer = ''
local _selfZone = ''

-- Sender-identity + monotonic sequence guard for last-write-wins state topics.
-- The topics in GUARDED_TOPICS have historically overwritten each other in
-- receive order regardless of send order; a same-sender packet arriving late
-- (network jitter, MQ delay) could clobber a fresher one. Sequence gating fixes
-- that within a session. sessionId lets peers accept messages again after a
-- sender restart (new session -> reset expected sequence).
--
-- Wire fields: `from` (existing sender-name field on every broadcastFleet
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
}
local _mySessionId = ''
local _topicSeq = {}       -- [topic] = last outgoing sequence
local _topicSeenSeq = {}   -- [topic] = { [sender_key] = { sessionId, sequence } }

local function ensureSessionId()
    if _mySessionId ~= '' then return _mySessionId end
    local server = tostring(_selfServer or ''):gsub('%s+', '')
    local name = tostring(_selfName or ''):gsub('%s+', '')
    if server == '' or name == '' then return '' end
    _mySessionId = string.format('%s:%s:%d:%d', server, name, os.time(), mq.gettime and mq.gettime() or 0)
    return _mySessionId
end

local function nextSeq(topic)
    local n = (_topicSeq[topic] or 0) + 1
    _topicSeq[topic] = n
    return n
end

--- Returns true if the incoming guarded message is stale (same sender, same
--- session, sequence <= last accepted). Missing sessionId/sequence -> accept
--- (backwards compat).
local function isStaleGuardedMessage(topic, content, sender)
    if not GUARDED_TOPICS[topic] then return false end
    local senderKey = tostring((content and content.from) or (sender and sender.character) or ''):lower()
    if senderKey == '' then return false end
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
    table_[senderKey] = { sessionId = sessionId, sequence = sequence }
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
local _processActorMessage = nil

local _lastDockedSendAt = 0
local _lastStatusSendAt = 0
local _remoteCharacters = {}
local _lastStatusPayload = nil

-- Healing coordination state (claims + HoT presence)
local _healClaims = {} -- [targetId][from] = { spellName, tier, expiresAt, claimedAt }
local _hotStates = {}  -- [targetId][from] = { spellName, expiresAt }
local HEAL_CLAIM_TTL = 5.0        -- Default claim lifetime (seconds)
local HOT_DEFAULT_TTL = 18.0      -- Default HoT tracking lifetime
local PRUNE_INTERVAL = 1.0        -- How often to prune stale claims
local _lastPruneAt = 0

-- Forward declaration (defined after message handlers, used in tick)
local pruneHealTables

-- Healing message callbacks (registered by healing module to avoid circular require)
local _healingCallbacks = {}
local _messageCallbacks = {}

-- Tank coordination state
local _tankState = {
    primaryTargetId = nil,
    primaryTargetName = nil,
    currentTargetId = nil,
    tankMode = nil,
    tankId = nil,
    tankName = nil,
    updatedAt = 0,
    campAnchor = nil,   -- { x, y, z, from, updatedAt } from tank:camp_anchor
}

-- Charm-pet protection state. The charming enchanter broadcasts its pet's
-- spawn ID so every worker in the group treats that mob as off-limits: DPS
-- must not kill it (even mid charm-break, when it briefly reappears as a
-- hater) and the tank protects the enchanter with damageless aggro only.
local _charmState = {
    petId = 0,
    petName = '',
    ownerName = '',
    updatedAt = 0,
}

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

local function normalize_sender(sender)
    sender = sender or {}
    return {
        character = sender.character or sender.Character or '',
        server = sender.server or sender.Server or '',
        mailbox = sender.mailbox or sender.Mailbox or '',
        script = sender.script or sender.Script or '',
    }
end

-- Should we process a cross-zone-sensitive message? True if sender is in our
-- zone (via content.zone if provided, else via the last known peer status).
-- Fails open (returns true) when we don't know the sender's zone — dropping
-- messages from unknown peers would lock out newly-joined peers before their
-- first status:update lands.
local function senderInSameZone(content, sender)
    local myZone = safeZone()
    if myZone == '' then return true end

    local msgZone = content and content.zone
    if type(msgZone) == 'string' and msgZone ~= '' then
        return msgZone == myZone
    end

    local charName = tostring((content and content.from) or (sender and sender.character) or '')
    if charName ~= '' then
        local peer = _remoteCharacters[charName]
        if peer and peer.zone and peer.zone ~= '' then
            return peer.zone == myZone
        end
    end

    return true
end

-- Send format: try absolute first, fall back to script+mailbox, cache what works
local _sendFormat = nil  -- cached working format (1 = absolute, 2 = script+mailbox)

local _ADDR_ABSOLUTE = { mailbox = 'lua:group:grouptarget', absolute_mailbox = true }
local _ADDR_SCRIPT   = { mailbox = 'grouptarget', script = 'group' }

local function sendToGroupTarget(payload)
    if not _dropbox then return end
    if type(payload) ~= 'table' then return end
    payload.from = payload.from or _selfName
    payload.server = payload.server or _selfServer

    -- Use cached working format if known
    if _sendFormat == 1 then
        local ok, res = pcall(_dropbox.send, _dropbox, _ADDR_ABSOLUTE, payload)
        _lastSendResult = { ok1 = ok, res1 = res }
        if not ok then _lastSendErr = tostring(res) end
        return
    elseif _sendFormat == 2 then
        local ok, res = pcall(_dropbox.send, _dropbox, _ADDR_SCRIPT, payload)
        _lastSendResult = { ok2 = ok, res2 = res }
        if not ok then _lastSendErr = tostring(res) end
        return
    end

    -- Discovery: try both, cache the first that doesn't throw
    local ok1, res1 = pcall(_dropbox.send, _dropbox, _ADDR_ABSOLUTE, payload)
    if ok1 then
        _sendFormat = 1
        _lastSendResult = { ok1 = ok1, res1 = res1 }
        return
    end
    local ok2, res2 = pcall(_dropbox.send, _dropbox, _ADDR_SCRIPT, payload)
    if ok2 then
        _sendFormat = 2
    end
    _lastSendResult = { ok1 = ok1, res1 = res1, ok2 = ok2, res2 = res2 }
    if not ok1 then _lastSendErr = tostring(res1) end
    if not ok2 then _lastSendErr = tostring(res2) end
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
    payload.from = payload.from or _selfName
    payload.server = payload.server or _selfServer
    sendToGroupTarget(payload)
    pcall(function() _dropbox:send(_ADDR_EQUI, payload) end)
end

function M.requestGroupTargetBounds()
    sendToGroupTarget({ id = 'window:bounds:req' })
end

function M.init(opts)
    opts = opts or {}
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
    local _selfNameLower = tostring(_selfName or ''):lower()
    local _selfServerLower = tostring(_selfServer or ''):lower()

    local function sameLocalCharacter(name, server)
        name = tostring(name or ''):lower()
        server = tostring(server or ''):lower()
        if name == '' or _selfNameLower == '' or name ~= _selfNameLower then return false end
        return _selfServerLower == '' or server == '' or server == _selfServerLower
    end

    local function processActorMessage(content, sender)
        local id = tostring(content.id or ''):lower()

        local senderCharLower = tostring(sender.character or ''):lower()
        local senderServerLower = tostring(sender.server or ''):lower()
        local fromMe = (senderCharLower ~= '' and senderCharLower == _selfNameLower)
            and (_selfServerLower == '' or senderServerLower == '' or senderServerLower == _selfServerLower)

        local senderMailboxLower = tostring(sender.mailbox or ''):lower()
        local fromGroupTargetMailbox = (senderMailboxLower ~= '' and senderMailboxLower:find('grouptarget', 1, true) ~= nil)
        if fromGroupTargetMailbox then
            _lastGroupTargetMsgAt = os.clock()
            _lastGroupTargetMsgId = id
        end

        -- Tally remote claims into the ledger. Self-fired claims are recorded
        -- in M.broadcast() instead, so we skip fromMe here to avoid double-counting.
        if not fromMe then
            local cat = CLAIM_CATEGORIES[id]
            if cat then
                local L = ledger()
                if L then
                    local from = tostring(content.from or sender.character or '')
                    if from ~= '' then L.record(from, cat) end
                end
            end
        end

        local callbacks = _messageCallbacks[id]
        if callbacks then
            for _, cb in ipairs(callbacks) do
                local ok, handled = pcall(cb, content, sender, fromMe)
                if ok and handled == true then return end
            end
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
                pcall(function()
                    _dropbox:send({
                        mailbox = 'medley_remote',
                        script = tostring(sender.script or '') ~= '' and sender.script
                            or (tostring(content.replyScript or '') ~= ''
                                and content.replyScript or 'eq_ui_rebuild_classic'),
                        character = sender.character,
                        server = sender.server,
                    }, reply)
                end)
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
        if id == 'status:update' then
            if fromMe then return end
            local charName = tostring(content.from or sender.character or '')
            if charName == '' then return end

            -- Several workers on one character can publish status:update. Merge
            -- partial payloads so the lightweight healing heartbeat cannot erase
            -- target telemetry sent by the primary SideKick process.
            local previous = _remoteCharacters[charName] or {}
            local targetWasIncluded = content.targetId ~= nil
            local function update(value, oldValue)
                if value ~= nil then return value end
                return oldValue
            end
            _remoteCharacters[charName] = {
                server = tostring(content.server or sender.server or ''),
                zone = tostring(content.zone or previous.zone or ''),
                class = content.class or previous.class or '',
                id = tonumber(content.characterId or content.spawnId or content.charId) or previous.id or 0,
                currentHP = tonumber(content.currentHP) or previous.currentHP or 0,
                maxHP = tonumber(content.maxHP) or previous.maxHP or 0,
                dead = update(content.dead, previous.dead) == true,
                hovering = update(content.hovering, previous.hovering) == true,
                role = content.role or previous.role,
                abilities = content.abilities or previous.abilities or {},
                buffs = content.buffs or previous.buffs or {},  -- What buffs this character currently has
                chase = update(content.chase, previous.chase),
                hp = update(content.hp, previous.hp),
                mana = update(content.mana, previous.mana),
                endur = update(content.endur, previous.endur),
                targetId = targetWasIncluded and (tonumber(content.targetId) or 0) or previous.targetId or 0,
                targetType = targetWasIncluded and tostring(content.targetType or '') or previous.targetType or '',
                targetName = targetWasIncluded and tostring(content.targetName or '') or previous.targetName or '',
                targetUpdatedAt = targetWasIncluded and os.clock() or previous.targetUpdatedAt,
                combat = update(content.combat, previous.combat) == true,
                script = tostring(content.script or previous.script or ''),
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

            local fromName = tostring(content.from or sender.character or '')

            -- Check if we should accept assists from this source based on settings
            -- Load settings via Core module
            local Core = package.loaded['sidekick-next.utils.core']
            local settings = Core and Core.Settings or {}

            -- Determine if sender is in group, raid, or is a known peer
            local senderSpawn = mq.TLO.Spawn('pc =' .. fromName)
            local senderId = senderSpawn and senderSpawn() and senderSpawn.ID and senderSpawn.ID() or 0

            local isInGroup = false
            local isInRaid = false
            local isPeer = true -- Actor peers always qualify (they sent via actors)

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
            local accept = fromMe or fromGroupTargetMailbox
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
            -- Only respond if we're in the same zone (if zone info provided)
            local senderZone = tostring(content.zone or '')
            local myZone = safeZone()
            if senderZone ~= '' and myZone ~= '' and senderZone ~= myZone then return end
            if isStaleGuardedMessage(id, content, sender) then return end

            _tankState.primaryTargetId = content.targetId
            _tankState.primaryTargetName = content.targetName
            _tankState.tankId = content.tankId or _tankState.tankId
            _tankState.tankName = tostring(content.tankName or content.from or sender.character or '')
            _tankState.updatedAt = os.clock()
            return
        end

        -- Tank coordination: aggro cycling target (follow mode uses, sticky ignores)
        if id == 'target:aggro' then
            if fromMe then return end
            -- Only update currentTargetId if in follow mode (checked by consumer)
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

        -- Only accept tank:* from the currently designated tank (the most
        -- recent `target:primary` sender) or, as a fallback, from a sender
        -- in our group or raid. Prevents random peers from soft-pausing all
        -- followers by broadcasting tank:repositioning.
        local function senderIsAuthorizedTank(content, sender)
            local fromName = tostring((content and content.from) or (sender and sender.character) or '')
            if fromName == '' then return false end

            -- Primary gate: currently-known tank (set by target:primary).
            if _tankState.tankName and _tankState.tankName ~= '' and fromName == _tankState.tankName then
                return true
            end

            -- Fallback: sender in our group or raid.
            local senderSpawn = mq.TLO.Spawn('pc =' .. fromName)
            local senderId = senderSpawn and senderSpawn() and senderSpawn.ID and senderSpawn.ID() or 0
            if senderId <= 0 then return false end

            local groupCount = mq.TLO.Group.Members and mq.TLO.Group.Members() or 0
            for i = 0, groupCount do
                local member = mq.TLO.Group.Member(i)
                if member and member() and member.ID and member.ID() == senderId then
                    return true
                end
            end

            local raidCount = mq.TLO.Raid.Members and mq.TLO.Raid.Members() or 0
            for i = 1, raidCount do
                local raidMember = mq.TLO.Raid.Member(i)
                if raidMember and raidMember() then
                    local raidSpawn = raidMember.Spawn
                    if raidSpawn and raidSpawn() and raidSpawn.ID and raidSpawn.ID() == senderId then
                        return true
                    end
                end
            end
            return false
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
                    from = tostring(content.from or ''),
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
            local owner = tostring(content.owner or '')
            -- petId == 0 is an explicit release; only honor it from the same
            -- owner that set the current pet (a second enchanter's release
            -- must not clear the first one's protection).
            if petId == 0 and owner ~= '' and owner ~= _charmState.ownerName then
                return
            end
            _charmState.petId = petId
            _charmState.petName = tostring(content.petName or '')
            _charmState.ownerName = owner
            _charmState.updatedAt = os.clock()
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
            local from = tostring(content.from or sender.character or '')
            if from == '' then return end
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
                expiresAt = tonumber(content.expiresAt) or (os.time() + HEAL_CLAIM_TTL),
                claimedAt = os.time(),   -- keep in epoch seconds to match expiresAt
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
            local from = tostring(content.from or sender.character or '')
            if from == '' then return end
            local spellName = tostring(content.spellName or '')
            if spellName == '' then return end
            _hotStates[tid] = _hotStates[tid] or {}
            _hotStates[tid][from] = _hotStates[tid][from] or {}
            -- Per-spell keying: a single healer can stack multiple HoTs on the
            -- same target (e.g. Promised + regular HoT). Without this, the
            -- second cast overwrote the first in tracking.
            _hotStates[tid][from][spellName] = {
                spellName = spellName,
                expiresAt = tonumber(content.expiresAt) or (os.time() + HOT_DEFAULT_TTL),
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
    _dropbox = _actors.register('sidekick', function(message)
        local content = message()
        if type(content) ~= 'table' then return end
        if #_pendingActorMessages >= 500 then
            table.remove(_pendingActorMessages, 1)
        end
        _pendingActorMessages[#_pendingActorMessages + 1] = {
            content = content,
            sender = normalize_sender(message.sender),
        }
    end)

    -- Stable request/response endpoint for companion UIs. The main SideKick
    -- mailbox deliberately queues messages for the yieldable tick, which loses
    -- the original RPC reply handle. This small endpoint only reads the cached
    -- status payload and replies directly from the actor callback.
    local okStatus, statusDropbox = pcall(function()
        return _actors.register('sidekick_status', function(message)
            local content = message and message()
            if type(content) ~= 'table' or content.id ~= 'eq_ui:automation:req' then return end
            local last = type(_lastStatusPayload) == 'table' and _lastStatusPayload or {}
            local paused, chase = nil, nil
            if type(last.automationPaused) == 'boolean' then paused = last.automationPaused end
            if type(last.chase) == 'boolean' then chase = last.chase end
            message:reply(0, {
                id = 'eq_ui:automation:rep',
                script = 'sidekick-next',
                from = _selfName,
                server = _selfServer,
                paused = paused,
                chase = chase,
            })
        end)
    end)
    if okStatus then _statusDropbox = statusDropbox end

    return _dropbox
end

function M.getDebugState()
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
    }
end

function M.setDocked(docked)
    M._docked = docked == true
end

function M.tick(opts)
    opts = opts or {}
    local now = os.clock()

    -- Actor callbacks only enqueue. Process messages here in the yieldable
    -- main coroutine, where receiver code may safely perform normal work.
    if _processActorMessage and #_pendingActorMessages > 0 then
        local pending = _pendingActorMessages
        _pendingActorMessages = {}
        for _, entry in ipairs(pending) do
            pcall(_processActorMessage, entry.content, entry.sender)
        end
    end

    -- Refresh our cached zone every tick so outbound replies and the
    -- senderInSameZone fallback never use a stale value across zone-ins.
    -- Previously _selfZone only updated at init and inside specific
    -- broadcast helpers, so status:rep / docked broadcasts could carry the
    -- old zone for several seconds after zoning.
    _selfZone = safeZone()

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
    if opts.status and (now - _lastStatusSendAt) >= 0.2 then
        local prev = _lastStatusPayload
        local changed = not prev
            or (opts.status.hp or 0) ~= (prev.hp or 0)
            or (opts.status.currentHP or 0) ~= (prev.currentHP or 0)
            or (opts.status.maxHP or 0) ~= (prev.maxHP or 0)
            or (opts.status.mana or 0) ~= (prev.mana or 0)
            or (opts.status.endur or 0) ~= (prev.endur or 0)
            or (opts.status.dead == true) ~= (prev.dead == true)
            or (opts.status.hovering == true) ~= (prev.hovering == true)
            or (opts.status.characterId or 0) ~= (prev.characterId or 0)
            or (opts.status.zone or '') ~= (prev.zone or '')
            or (opts.status.targetId or 0) ~= (prev.targetId or 0)
            or (opts.status.combat) ~= (prev.combat)
            or (opts.status.casting or '') ~= (prev.casting or '')
            or (opts.status.automationPaused == true) ~= (prev.automationPaused == true)
            or (opts.status.chase == true) ~= (prev.chase == true)
            or (now - _lastStatusSendAt) >= 2.0  -- Force send every 2s as heartbeat
        if changed then
            _lastStatusSendAt = now
            _lastStatusPayload = opts.status
            if not opts.peerOnly then sendToGroupTarget(opts.status) end
            -- Also broadcast to other SideKick instances for remote abilities
            if _dropbox then
                pcall(function()
                    _dropbox:send({ mailbox = 'sidekick' }, opts.status)
                end)
            end
        end
    end
end

function M.getRemoteCharacters()
    -- Prune stale entries (not seen in 10 seconds)
    local now = os.clock()
    for name, data in pairs(_remoteCharacters) do
        if (now - (data.lastSeen or 0)) > 10 then
            _remoteCharacters[name] = nil
        end
    end
    return _remoteCharacters
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

--- Generic broadcast to all SideKick instances.
-- IMPORTANT addressing caveat: an address of { mailbox = 'sidekick' } with no
-- script routes to "currentScript:sidekick" — it reaches the SAME script on
-- other characters only. Same-script fan-out is correct for intra-role
-- coordination (healer<->healer claims, mezzer<->mezzer claims). For state
-- that OTHER scripts must see (tank primary, mez list, charm pet), use
-- M.broadcastFleet instead.
-- @param msgId string Message ID (e.g., 'cc:mezlist')
-- @param payload table Message payload
function M.broadcast(msgId, payload)
    if not _dropbox then return end
    payload = payload or {}
    payload.id = msgId
    payload.from = payload.from or _selfName
    pcall(function()
        _dropbox:send({ mailbox = 'sidekick' }, payload)
    end)
    -- Tally self-fired claims into the ledger.
    local cat = CLAIM_CATEGORIES[msgId]
    if cat then
        local L = ledger()
        if L then L.record(payload.from, cat) end
    end
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

--- Broadcast to EVERY SideKick script on every connected character (~16
--- sends, ≈1ms each — reserve for low-frequency state, not per-tick data).
--- Needed because plain { mailbox = 'sidekick' } never crosses script names.
-- @param msgId string Message ID
-- @param payload table Message payload
function M.broadcastFleet(msgId, payload)
    if not _dropbox then return end
    payload = payload or {}
    payload.id = msgId
    payload.from = payload.from or _selfName
    if GUARDED_TOPICS[msgId] then
        local sid = ensureSessionId()
        if sid ~= '' then
            payload.sessionId = payload.sessionId or sid
            payload.sequence = payload.sequence or nextSeq(msgId)
        end
    end
    for _, script in ipairs(fleetScripts()) do
        pcall(function()
            _dropbox:send({ mailbox = 'sidekick', script = script }, payload)
        end)
    end
    local cat = CLAIM_CATEGORIES[msgId]
    if cat then
        local L = ledger()
        if L then L.record(payload.from, cat) end
    end
end

--- Send to a logical mailbox owned by a specific Lua script. Omitting a
--- character intentionally broadcasts to that script on connected peers.
function M.sendToScript(scriptName, msgId, payload)
    if not _dropbox or not scriptName or scriptName == '' then return false end
    payload = payload or {}
    payload.id = msgId
    payload.from = payload.from or _selfName
    return pcall(function()
        _dropbox:send({ mailbox = 'sidekick', script = scriptName }, payload)
    end)
end

--- Send to another Lua script for this same character only. This avoids
--- broadcasting UI-only telemetry to every connected SideKick peer.
function M.sendToLocalScript(scriptName, msgId, payload)
    if not _dropbox or not scriptName or scriptName == '' then return false end
    payload = payload or {}
    payload.id = msgId
    payload.from = payload.from or _selfName
    payload.server = payload.server or _selfServer
    return pcall(function()
        _dropbox:send({
            mailbox = 'sidekick',
            script = scriptName,
            character = _selfName,
            server = _selfServer,
        }, payload)
    end)
end

--- Send to a specific character's logical mailbox for a specific Lua script.
function M.sendToCharacter(scriptName, character, server, msgId, payload)
    if not _dropbox or not scriptName or scriptName == ''
        or not character or character == '' then return false end
    payload = payload or {}
    payload.id = msgId
    payload.from = payload.from or _selfName
    payload.server = payload.server or _selfServer
    return pcall(function()
        _dropbox:send({
            mailbox = 'sidekick',
            script = scriptName,
            character = character,
            server = server,
        }, payload)
    end)
end

--- Broadcast the primary kill target to assisters
-- Includes zone information so receivers can filter by same zone
function M.broadcastTargetPrimary(targetId, targetName)
    if not _dropbox then return end
    local me = mq.TLO.Me
    local tankId = (me and me() and me.ID and me.ID()) or nil
    -- Update zone before broadcast
    _selfZone = safeZone()
    -- Fleet fan-out: mezzers (sk_cc/sk_disciplines), assisters, and charm
    -- upkeep all live in OTHER scripts; a plain mailbox send would only reach
    -- other characters' sk_tank.
    M.broadcastFleet('target:primary', {
        targetId = targetId,
        targetName = targetName,
        tankId = tankId,
        tankName = _selfName,
        zone = _selfZone,
    })
end

--- Broadcast that tank is repositioning (assisters enter soft-pause)
function M.broadcastTankRepositioning()
    if not _dropbox then return end
    _selfZone = safeZone()
    M.broadcastFleet('tank:repositioning', { zone = _selfZone })
end

--- Broadcast that tank has settled (assisters exit soft-pause)
function M.broadcastTankSettled()
    if not _dropbox then return end
    _selfZone = safeZone()
    M.broadcastFleet('tank:settled', { zone = _selfZone })
end

--- Broadcast that tank is doing a taunt run (assisters enter soft-pause)
function M.broadcastTauntRun()
    if not _dropbox then return end
    _selfZone = safeZone()
    M.broadcastFleet('tank:taunt_run', { zone = _selfZone })
end

--- Broadcast that tank's taunt run completed (assisters exit soft-pause)
function M.broadcastTauntDone()
    if not _dropbox then return end
    _selfZone = safeZone()
    M.broadcastFleet('tank:taunt_done', { zone = _selfZone })
end

--- Broadcast the tank's live camp anchor. Rate-limited by sk_tank's own 5s
--- refresh cadence; the receiver stores it in _tankState.campAnchor.
function M.broadcastTankCampAnchor(x, y, z)
    if not _dropbox then return end
    if not (x and y and z) then return end
    _selfZone = safeZone()
    M.broadcastFleet('tank:camp_anchor', {
        x = tonumber(x), y = tonumber(y), z = tonumber(z),
        zone = _selfZone,
    })
end

--- Get the current tank state (for assisters to read)
function M.getTankState()
    return _tankState
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

--- Get the protected charm-pet state (for target selection to read)
function M.getCharmState()
    return _charmState
end

--- True if this spawn ID is a group charm pet (or a just-broken one still
--- under the owner's recovery window) and must never be attacked.
-- @param id number Spawn ID to check
function M.isCharmPet(id)
    id = tonumber(id) or 0
    if id <= 0 or _charmState.petId <= 0 then return false end
    if id ~= _charmState.petId then return false end
    -- The owner rebroadcasts every few seconds while the pet (or its
    -- recovery window) is live; a long-silent entry means the owner's
    -- worker died — fail open so the mob can be killed.
    return (os.clock() - (_charmState.updatedAt or 0)) < 30
end

--- Broadcast pull-monitor state (tank-side; healers consume via getPullState)
-- @param state table { phase, mobId, mobName, eta, mult, dist }
function M.broadcastPullState(state)
    if not _dropbox then return end
    if type(state) ~= 'table' then return end
    _selfZone = safeZone()
    pcall(function()
        _dropbox:send({ mailbox = 'sidekick' }, {
            id = 'pull:incoming',
            phase = state.phase,
            mobId = state.mobId,
            mobName = state.mobName,
            eta = state.eta,
            mult = state.mult,
            dist = state.dist,
            zone = _selfZone,
            from = _selfName,
        })
    end)
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
    pcall(function()
        _dropbox:send({ mailbox = 'sidekick' }, {
            id = 'mobhp:update',
            estimates = estimates,
            zone = _selfZone,
            from = _selfName,
        })
    end)
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
    for name, data in pairs(_remoteCharacters) do
        if data.zone == myZone then
            table.insert(peers, { name = name, data = data })
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

    pcall(function()
        _dropbox:send({ mailbox = 'sidekick' }, {
            id = 'assist:me',
            targetId = targetId,
            targetName = targetName,
            zone = _selfZone,
            from = _selfName,
        })
    end)

    -- Count peers in same zone
    local peerCount = 0
    for _, data in pairs(_remoteCharacters) do
        if data.zone == _selfZone then
            peerCount = peerCount + 1
        end
    end

    -- Echo disabled
    return true
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
