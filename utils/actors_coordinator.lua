local mq = require('mq')

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
local _healClaims = {} -- [targetId][from] = { spellName, tier, expiresAt }
local _hotStates = {}  -- [targetId][from] = { spellName, expiresAt }

-- Healing message callbacks (registered by healing module to avoid circular require)
local _healingCallbacks = {}

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

local function sendToGroupTarget(payload)
    if not _dropbox then return end
    if type(payload) ~= 'table' then return end
    payload.from = payload.from or _selfName
    payload.server = payload.server or _selfServer
    -- Try multiple send formats for compatibility
    local ok1, res1 = pcall(function()
        return _dropbox:send({ mailbox = 'lua:group:grouptarget', absolute_mailbox = true }, payload)
    end)
    local ok2, res2 = pcall(function()
        return _dropbox:send({ mailbox = 'lua:group:GroupTarget', absolute_mailbox = true }, payload)
    end)
    -- Also try script+mailbox format
    local ok3, res3 = pcall(function()
        return _dropbox:send({ mailbox = 'grouptarget', script = 'group' }, payload)
    end)
    _lastSendResult = { ok1 = ok1, res1 = res1, ok2 = ok2, res2 = res2, ok3 = ok3, res3 = res3 }
    if not ok1 then _lastSendErr = tostring(res1) end
    if not ok2 then _lastSendErr = tostring(res2) end
    if not ok3 then _lastSendErr = tostring(res3) end
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

        -- Respond to GroupTarget pull-style status requests (targeted send).
        -- Note: sender may be our own character (GroupTarget runs on the same client), so do NOT gate on fromMe.
        if id == 'status:req' then
            if type(_lastStatusPayload) == 'table' then
                local reply = {}
                for k, v in pairs(_lastStatusPayload) do reply[k] = v end
                reply.id = 'status:rep'
                reply.script = 'sidekick'
                sendToGroupTarget(reply)
            end
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
                loaded = true,
                timestamp = content.timestamp or os.clock(),
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

        -- Tank coordination: repositioning notification
        if id == 'tank:repositioning' then
            if fromMe then return end
            local Positioning = require('sidekick-next.utils.positioning')
            Positioning.enterSoftPause()
            return
        end

        -- Tank coordination: settled after repositioning
        if id == 'tank:settled' then
            if fromMe then return end
            local Positioning = require('sidekick-next.utils.positioning')
            Positioning.exitSoftPause()
            return
        end

        -- Tank coordination: taunt run started
        if id == 'tank:taunt_run' then
            if fromMe then return end
            local Positioning = require('sidekick-next.utils.positioning')
            Positioning.enterSoftPause()
            return
        end

        -- Tank coordination: taunt run completed
        if id == 'tank:taunt_done' then
            if fromMe then return end
            local Positioning = require('sidekick-next.utils.positioning')
            Positioning.exitSoftPause()
            return
        end

        -- Tank coordination: mode change notification
        if id == 'tank:mode' then
            if fromMe then return end
            _tankState.tankMode = content.mode
            return
        end

        -- CC coordination: receive mez list from mezzer
        if id == 'cc:mezlist' then
            if fromMe then return end
            local ok, CC = pcall(require, 'sidekick-next.automation.cc')
            if ok and CC and CC.receiveMezList then
                CC.receiveMezList(content)
            end
            return
        end

        -- CC coordination: receive mez claim from another mezzer
        if id == 'cc:claim' then
            if fromMe then return end
            local ok, CC = pcall(require, 'sidekick-next.automation.cc')
            if ok and CC and CC.receiveClaim then
                CC.receiveClaim(content)
            end
            return
        end

        -- Debuff coordination: receive debuff claim from another debuffer
        if id == 'debuff:claim' then
            if fromMe then return end
            local ok, Debuff = pcall(require, 'sidekick-next.automation.debuff')
            if ok and Debuff and Debuff.receiveClaim then
                Debuff.receiveClaim(content)
            end
            return
        end

        -- Debuff coordination: receive debuff landed notification
        if id == 'debuff:landed' then
            if fromMe then return end
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

        -- Healing coordination: claim that we're healing a target (prevents multi-healer pile-on)
        if id == 'heal:claim' then
            if fromMe then return end
            local tid = tonumber(content.targetId) or 0
            if tid <= 0 then return end
            local from = tostring(content.from or sender.character or '')
            if from == '' then return end
            _healClaims[tid] = _healClaims[tid] or {}
            _healClaims[tid][from] = {
                spellName = tostring(content.spellName or ''),
                tier = tostring(content.tier or ''),
                expiresAt = tonumber(content.expiresAt) or (os.clock() + 3.0),
                from = from,
            }
            return
        end

        -- Healing coordination: HoT presence tracking (cannot be queried cross-client, so share it)
        if id == 'heal:hots' then
            if fromMe then return end
            local tid = tonumber(content.targetId) or 0
            if tid <= 0 then return end
            local from = tostring(content.from or sender.character or '')
            if from == '' then return end
            local spellName = tostring(content.spellName or '')
            if spellName == '' then return end
            _hotStates[tid] = _hotStates[tid] or {}
            _hotStates[tid][from] = {
                spellName = spellName,
                expiresAt = tonumber(content.expiresAt) or (os.clock() + 18.0),
                from = from,
            }
            return
        end

        -- Buff coordination: receive buff list from another buffer
        if id == 'buff:list' then
            if fromMe then return end
            local ok, Buff = pcall(require, 'sidekick-next.automation.buff')
            if ok and Buff and Buff.receiveBuffList then
                Buff.receiveBuffList(content)
            end
            return
        end

        -- Buff coordination: receive buff claim from another buffer
        if id == 'buff:claim' then
            if fromMe then return end
            local ok, Buff = pcall(require, 'sidekick-next.automation.buff')
            if ok and Buff and Buff.receiveClaim then
                Buff.receiveClaim(content)
            end
            return
        end

        -- Buff coordination: receive buff landed notification
        if id == 'buff:landed' then
            if fromMe then return end
            local ok, Buff = pcall(require, 'sidekick-next.automation.buff')
            if ok and Buff and Buff.receiveBuffLanded then
                Buff.receiveBuffLanded(content)
            end
            return
        end

        -- Buff coordination: receive buff blocks from peer
        if id == 'buff:blocks' then
            if fromMe then return end
            local ok, Buff = pcall(require, 'sidekick-next.automation.buff')
            if ok and Buff and Buff.receiveBlocks then
                Buff.receiveBlocks(content)
            end
            return
        end

        -- Cure coordination: receive cure claim from another curer
        if id == 'cure:claim' then
            if fromMe then return end
            local ok, Cures = pcall(require, 'sidekick-next.automation.cures')
            if ok and Cures and Cures.receiveClaim then
                Cures.receiveClaim(content)
            end
            return
        end

        -- Cure coordination: receive cure landed notification
        if id == 'cure:landed' then
            if fromMe then return end
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

    -- Status broadcast (hp/mana/end + selected ability readiness) ~5 Hz
    if opts.status and (now - _lastStatusSendAt) >= 0.2 then
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

local function pruneHealTables()
    local now = os.clock()

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

    for tid, perFrom in pairs(_hotStates) do
        local any = false
        for from, h in pairs(perFrom or {}) do
            if (tonumber(h.expiresAt) or 0) <= now then
                perFrom[from] = nil
            else
                any = true
            end
        end
        if not any then _hotStates[tid] = nil end
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

--- Register a callback for healing-related Actor messages
-- @param msgType string One of: 'heal:incoming', 'heal:landed', 'heal:cancelled'
-- @param callback function Called with (content, senderName) when message arrives
function M.registerHealingCallback(msgType, callback)
    _healingCallbacks[msgType] = callback
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
    pcall(function()
        _dropbox:send({ mailbox = 'sidekick' }, {
            id = 'tank:repositioning',
            from = _selfName,
        })
    end)
end

--- Broadcast that tank has settled (assisters exit soft-pause)
function M.broadcastTankSettled()
    if not _dropbox then return end
    pcall(function()
        _dropbox:send({ mailbox = 'sidekick' }, {
            id = 'tank:settled',
            from = _selfName,
        })
    end)
end

--- Broadcast that tank is doing a taunt run (assisters enter soft-pause)
function M.broadcastTauntRun()
    if not _dropbox then return end
    pcall(function()
        _dropbox:send({ mailbox = 'sidekick' }, {
            id = 'tank:taunt_run',
            from = _selfName,
        })
    end)
end

--- Broadcast that tank's taunt run completed (assisters exit soft-pause)
function M.broadcastTauntDone()
    if not _dropbox then return end
    pcall(function()
        _dropbox:send({ mailbox = 'sidekick' }, {
            id = 'tank:taunt_done',
            from = _selfName,
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

--- Get heal claims for debug display
-- @return table Heal claims table
function M.getHealClaimsRaw()
    return _healClaims
end

--- Get heal claims (alias)
function M.getHealClaims()
    return _healClaims
end

--- Get HoT states for debug display
-- @return table HoT states table
function M.getHoTStatesRaw()
    return _hotStates
end

--- Get HoT states (alias)
function M.getHoTStates()
    return _hotStates
end

return M
