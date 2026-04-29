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
}

local M = {}

local _actors = nil
local _dropbox = nil
local _selfName = ''
local _selfServer = ''
local _selfZone = ''
local _actorsInitError = nil
local _lastGroupTargetMsgAt = 0
local _lastGroupTargetMsgId = ''
local _lastBoundsReqAt = 0
local _lastSendErr = nil
local _lastSendResult = nil
local _lastSendDbgAt = 0
local _lastTickDbgAt = 0

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
}

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
    local _selfNameLower = tostring(_selfName or ''):lower()
    local _selfServerLower = tostring(_selfServer or ''):lower()

    _dropbox = _actors.register('sidekick', function(message)
        local content = message()
        if type(content) ~= 'table' then return end
        local id = tostring(content.id or ''):lower()
        local sender = normalize_sender(message.sender)

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
            local reply = {}
            if type(_lastStatusPayload) == 'table' then
                for k, v in pairs(_lastStatusPayload) do reply[k] = v end
            end
            reply.id = 'status:rep'
            reply.script = 'sidekick'
            reply.from = reply.from or _selfName
            reply.server = reply.server or _selfServer
            reply.zone = reply.zone or _selfZone
            sendToGroupTarget(reply)
            return
        end

        -- GroupTarget broadcasting its settings panel state (used to hide Exit Both button, etc.)
        if id == 'gt:settings_open' then
            if not fromMe and not fromGroupTargetMailbox then return end
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

            _remoteCharacters[charName] = {
                server = tostring(content.server or sender.server or ''),
                zone = tostring(content.zone or ''),
                class = content.class or '',
                abilities = content.abilities or {},
                buffs = content.buffs or {},  -- What buffs this character currently has
                chase = content.chase,
                hp = content.hp,
                mana = content.mana,
                endur = content.endur,
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
            local okCore, Core = pcall(require, 'sidekick-next.utils.core')
            local settings = okCore and Core and Core.Settings or {}

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
            local ok, Assist = pcall(require, 'sidekick-next.automation.assist')
            if ok and Assist then
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

        -- Tank coordination: primary kill target
        if id == 'target:primary' then
            if fromMe then return end
            -- Only respond if we're in the same zone (if zone info provided)
            local senderZone = tostring(content.zone or '')
            local myZone = safeZone()
            if senderZone ~= '' and myZone ~= '' and senderZone ~= myZone then return end

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
        -- A raw `require` here used to crash the whole actors mailbox handler
        -- for the session if positioning.lua failed to load; wrap with pcall
        -- to match the pattern used by other handlers in this file.
        local function _callPositioning(method)
            local ok, Positioning = pcall(require, 'sidekick-next.utils.positioning')
            if not ok or not Positioning or not Positioning[method] then return end
            Positioning[method]()
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

        if id == 'tank:repositioning' then
            if fromMe then return end
            if not senderInSameZone(content, sender) then return end
            if not senderIsAuthorizedTank(content, sender) then return end
            _callPositioning('enterSoftPause')
            return
        end

        if id == 'tank:settled' then
            if fromMe then return end
            if not senderInSameZone(content, sender) then return end
            if not senderIsAuthorizedTank(content, sender) then return end
            _callPositioning('exitSoftPause')
            return
        end

        if id == 'tank:taunt_run' then
            if fromMe then return end
            if not senderInSameZone(content, sender) then return end
            if not senderIsAuthorizedTank(content, sender) then return end
            _callPositioning('enterSoftPause')
            return
        end

        if id == 'tank:taunt_done' then
            if fromMe then return end
            if not senderInSameZone(content, sender) then return end
            if not senderIsAuthorizedTank(content, sender) then return end
            _callPositioning('exitSoftPause')
            return
        end

        -- Tank coordination: mode change notification
        if id == 'tank:mode' then
            if fromMe then return end
            if not senderInSameZone(content, sender) then return end
            if not senderIsAuthorizedTank(content, sender) then return end
            _tankState.tankMode = content.mode
            return
        end

        -- CC coordination: receive mez list from mezzer
        if id == 'cc:mezlist' then
            if fromMe then return end
            if not senderInSameZone(content, sender) then return end
            local ok, CC = pcall(require, 'sidekick-next.automation.cc')
            if ok and CC and CC.receiveMezList then
                CC.receiveMezList(content)
            end
            return
        end

        -- CC coordination: receive mez claim from another mezzer
        if id == 'cc:claim' then
            if fromMe then return end
            if not senderInSameZone(content, sender) then return end
            local ok, CC = pcall(require, 'sidekick-next.automation.cc')
            if ok and CC and CC.receiveClaim then
                CC.receiveClaim(content)
            end
            return
        end

        -- Debuff coordination: receive debuff claim from another debuffer
        if id == 'debuff:claim' then
            if fromMe then return end
            if not senderInSameZone(content, sender) then return end
            local ok, Debuff = pcall(require, 'sidekick-next.automation.debuff')
            if ok and Debuff and Debuff.receiveClaim then
                Debuff.receiveClaim(content)
            end
            return
        end

        -- Debuff coordination: receive debuff landed notification
        if id == 'debuff:landed' then
            if fromMe then return end
            if not senderInSameZone(content, sender) then return end
            local ok, Debuff = pcall(require, 'sidekick-next.automation.debuff')
            if ok and Debuff and Debuff.receiveDebuffLanded then
                Debuff.receiveDebuffLanded(content)
            end
            return
        end

        -- Healing coordination: incoming heal broadcasts (uses callback to avoid circular require)
        if id == 'heal:incoming' then
            if fromMe then return end
            local cb = _healingCallbacks['heal:incoming']
            if cb then
                local senderName = tostring(sender.character or sender.name or 'unknown')
                pcall(cb, content, senderName)
            end
            return
        end

        if id == 'heal:landed' then
            if fromMe then return end
            local cb = _healingCallbacks['heal:landed']
            if cb then
                local senderName = tostring(sender.character or sender.name or 'unknown')
                pcall(cb, content, senderName)
            end
            return
        end

        if id == 'heal:cancelled' then
            if fromMe then return end
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
            local ok, Buff = pcall(require, 'sidekick-next.automation.buff')
            if ok and Buff and Buff.receiveBuffList then
                Buff.receiveBuffList(content)
            end
            return
        end

        -- Buff coordination: receive buff claim from another buffer
        if id == 'buff:claim' then
            if fromMe then return end
            if not senderInSameZone(content, sender) then return end
            local ok, Buff = pcall(require, 'sidekick-next.automation.buff')
            if ok and Buff and Buff.receiveClaim then
                Buff.receiveClaim(content)
            end
            return
        end

        -- Buff coordination: receive buff landed notification
        if id == 'buff:landed' then
            if not fromMe then
                if not senderInSameZone(content, sender) then return end
                local ok, Buff = pcall(require, 'sidekick-next.automation.buff')
                if ok and Buff and Buff.receiveBuffLanded then
                    Buff.receiveBuffLanded(content)
                end
            end
            -- Clear any pending buff request that this landing satisfies (also
            -- when fromMe — we may have answered our own request).
            local okR, Reqs = pcall(require, 'sidekick-next.utils.buff_requests')
            if okR and Reqs and Reqs.clearRequest then
                local tid = tonumber(content.targetId) or 0
                local cat = tostring(content.buffType or content.category or '')
                if tid > 0 and cat ~= '' then Reqs.clearRequest(tid, cat) end
            end
            return
        end

        -- Buff request: peer asks the team for a specific buff category
        if id == 'buff:need' then
            if not senderInSameZone(content, sender) then return end
            local okR, Reqs = pcall(require, 'sidekick-next.utils.buff_requests')
            if okR and Reqs and Reqs.receiveNeed then
                Reqs.receiveNeed(content)
            end
            return
        end

        -- Buff coordination: receive buff blocks from peer
        if id == 'buff:blocks' then
            if fromMe then return end
            if not senderInSameZone(content, sender) then return end
            local ok, Buff = pcall(require, 'sidekick-next.automation.buff')
            if ok and Buff and Buff.receiveBlocks then
                Buff.receiveBlocks(content)
            end
            return
        end

        -- Cure coordination: receive cure claim from another curer
        if id == 'cure:claim' then
            if fromMe then return end
            if not senderInSameZone(content, sender) then return end
            local ok, Cures = pcall(require, 'sidekick-next.automation.cures')
            if ok and Cures and Cures.receiveClaim then
                Cures.receiveClaim(content)
            end
            return
        end

        -- Cure coordination: peer's cure capabilities (for shard splitting).
        if id == 'cure:capabilities' then
            if fromMe then return end
            if not senderInSameZone(content, sender) then return end
            local ok, Cures = pcall(require, 'sidekick-next.automation.cures')
            if ok and Cures and Cures.receiveCapabilities then
                Cures.receiveCapabilities(content)
            end
            return
        end

        -- Cure coordination: receive cure landed notification
        if id == 'cure:landed' then
            if fromMe then return end
            if not senderInSameZone(content, sender) then return end
            local ok, Cures = pcall(require, 'sidekick-next.automation.cures')
            if ok and Cures and Cures.receiveCureLanded then
                Cures.receiveCureLanded(content)
            end
            return
        end
    end)

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
            or (opts.status.mana or 0) ~= (prev.mana or 0)
            or (opts.status.endur or 0) ~= (prev.endur or 0)
            or (opts.status.targetId or 0) ~= (prev.targetId or 0)
            or (opts.status.combat) ~= (prev.combat)
            or (opts.status.casting or '') ~= (prev.casting or '')
            or (now - _lastStatusSendAt) >= 2.0  -- Force send every 2s as heartbeat
        if changed then
            _lastStatusSendAt = now
            _lastStatusPayload = opts.status
            sendToGroupTarget(opts.status)
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
function M.getWinningClaim(targetId)
    pruneHealTables()
    local perFrom = _healClaims[targetId]
    if not perFrom then return nil end
    local best = nil
    for _, claim in pairs(perFrom) do
        -- Skip our own claims
        if claim.from ~= _selfName then
            if not best or (claim.claimedAt or 0) > (best.claimedAt or 0) then
                best = claim
            end
        end
    end
    return best
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

--- Generic broadcast to all SideKick instances
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

--- Broadcast the primary kill target to assisters
-- Includes zone information so receivers can filter by same zone
function M.broadcastTargetPrimary(targetId, targetName)
    if not _dropbox then return end
    local me = mq.TLO.Me
    local tankId = (me and me() and me.ID and me.ID()) or nil
    -- Update zone before broadcast
    _selfZone = safeZone()
    pcall(function()
        _dropbox:send({ mailbox = 'sidekick' }, {
            id = 'target:primary',
            targetId = targetId,
            targetName = targetName,
            tankId = tankId,
            tankName = _selfName,
            zone = _selfZone,
            from = _selfName,
        })
    end)
end

--- Broadcast that tank is repositioning (assisters enter soft-pause)
function M.broadcastTankRepositioning()
    if not _dropbox then return end
    _selfZone = safeZone()
    pcall(function()
        _dropbox:send({ mailbox = 'sidekick' }, {
            id = 'tank:repositioning',
            from = _selfName,
            zone = _selfZone,
        })
    end)
end

--- Broadcast that tank has settled (assisters exit soft-pause)
function M.broadcastTankSettled()
    if not _dropbox then return end
    _selfZone = safeZone()
    pcall(function()
        _dropbox:send({ mailbox = 'sidekick' }, {
            id = 'tank:settled',
            from = _selfName,
            zone = _selfZone,
        })
    end)
end

--- Broadcast that tank is doing a taunt run (assisters enter soft-pause)
function M.broadcastTauntRun()
    if not _dropbox then return end
    _selfZone = safeZone()
    pcall(function()
        _dropbox:send({ mailbox = 'sidekick' }, {
            id = 'tank:taunt_run',
            from = _selfName,
            zone = _selfZone,
        })
    end)
end

--- Broadcast that tank's taunt run completed (assisters exit soft-pause)
function M.broadcastTauntDone()
    if not _dropbox then return end
    _selfZone = safeZone()
    pcall(function()
        _dropbox:send({ mailbox = 'sidekick' }, {
            id = 'tank:taunt_done',
            from = _selfName,
            zone = _selfZone,
        })
    end)
end

--- Get the current tank state (for assisters to read)
function M.getTankState()
    return _tankState
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
