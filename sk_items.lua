-- F:/lua/sidekick-next/sk_items.lua
-- Coordinated owner for configured clickies and queued manual UI actions.

local mq = require('mq')
local lib = require('sidekick-next.sk_lib')
local ModuleBase = require('sidekick-next.sk_module_base')
local ActionExecutor = require('sidekick-next.utils.action_executor')
local Items = require('sidekick-next.utils.items')
local Bandolier = require('sidekick-next.utils.bandolier')
local ActorsCoordinator = require('sidekick-next.utils.actors_coordinator')

local module = ModuleBase.create('items', lib.Priority.DPS)

local MANUAL_REQUEST_TTL_MS = 15000
local AUTO_RETRY_MS = 1000
local CURSOR_HOLD_MS = 5000
local CURSOR_SCAN_MS = 250
local CURSOR_VERIFY_MS = 1500
local CURSOR_ACTION_KIND = 'autoinventory_cursor'
local MAX_MANUAL_QUEUE = 20
local MANUAL_ACTION_KINDS = {
    [lib.ActionKind.CAST_SPELL] = true,
    [lib.ActionKind.USE_AA] = true,
    [lib.ActionKind.USE_DISC] = true,
    [lib.ActionKind.USE_SKILL] = true,
}

local Runtime = {
    manualQueue = {},
    incomingManual = {},
    lastAttemptAt = {},
    selected = nil,
    reason = 'init',
    lastResult = 'none',
    lastItem = '',
    actorCallbacksRegistered = false,
    cursorKey = nil,
    cursorItemId = 0,
    cursorItemName = '',
    cursorOccupiedSinceMs = 0,
    cursorLastScanAtMs = 0,
    cursorSnapshot = nil,
}

local function trim(value)
    return tostring(value or ''):gsub('^%s+', ''):gsub('%s+$', '')
end

local function hasValidV2Envelope(content)
    local envelope = type(content) == 'table'
        and type(content.envelope) == 'table' and content.envelope or nil
    local sequence = envelope and tonumber(envelope.sequence) or 0
    local ttlMs = envelope and tonumber(envelope.ttlMs) or 0
    return envelope ~= nil
        and tonumber(envelope.version) == ActorsCoordinator.ENVELOPE_VERSION
        and tostring(envelope.session or '') ~= ''
        and sequence > 0
        and sequence == math.floor(sequence)
        and ttlMs > 0 and ttlMs <= 30000
        and tonumber(envelope.sentAtMs) ~= nil
end

local function isAllowedUiSender(sender, fromMe)
    if type(sender) ~= 'table' then return false end
    local scripts = type(lib.Scripts.UI) == 'table'
        and lib.Scripts.UI or { lib.Scripts.UI }
    for _, scriptName in ipairs(scripts) do
        if lib.actorSenderMatches(sender, scriptName, 'sidekick') then
            -- ActorsCoordinator has already authenticated remote SideKick
            -- senders against the configured Actor Team before callbacks run.
            return fromMe == true or tostring(sender.character or '') ~= ''
        end
    end
    return false
end

local function receiveManualMessage(content, sender, fromMe)
    local messageId = type(content) == 'table' and tostring(content.id or ''):lower() or ''
    if type(content) ~= 'table'
        or (messageId ~= 'item:manual' and messageId ~= 'action:manual')
        or not hasValidV2Envelope(content)
        or not isAllowedUiSender(sender, fromMe) then
        return true
    end

    local requestId = tostring(content.requestId or '')
    local name = tostring(content.itemName or content.name or '')
    local slotKey = tostring(content.slotKey or '')
    local kind = messageId == 'item:manual'
        and lib.ActionKind.USE_ITEM or tostring(content.kind or ''):lower()
    if trim(name) == '' or #name > 256 or #requestId > 128
        or #slotKey > 128 or (messageId == 'action:manual' and not MANUAL_ACTION_KINDS[kind]) then
        return true
    end
    if #Runtime.incomingManual >= MAX_MANUAL_QUEUE then
        table.remove(Runtime.incomingManual, 1)
    end
    Runtime.incomingManual[#Runtime.incomingManual + 1] = {
        requestId = requestId,
        requestedAtMs = tonumber(content.requestedAtMs),
        kind = kind,
        name = name,
        itemName = messageId == 'item:manual' and name or nil,
        slotKey = slotKey,
        aaId = tonumber(content.aaId),
        targetId = tonumber(content.targetId),
        from = tostring(sender.character or ''),
    }
    return true
end

local function ensureActorCallbacks(coordinator)
    if Runtime.actorCallbacksRegistered or not coordinator then return end
    if not coordinator.registerMessageCallback then return end
    coordinator.registerMessageCallback('item:manual', receiveManualMessage)
    coordinator.registerMessageCallback('action:manual', receiveManualMessage)
    Runtime.actorCallbacksRegistered = true
end

local function echo(fmt, ...)
    local ok, message = pcall(string.format, tostring(fmt or ''), ...)
    if not ok then message = tostring(fmt or '') end
    print(string.format('%s \ag[SK Items]\ax %s', lib.timestampPrefix(), message))
end

local function removeManualRequest(requestId)
    requestId = tostring(requestId or '')
    if requestId == '' then return end
    for index = #Runtime.manualQueue, 1, -1 do
        if tostring(Runtime.manualQueue[index].requestId or '') == requestId then
            table.remove(Runtime.manualQueue, index)
        end
    end
end

local function pruneManualQueue()
    local now = lib.getTimeMs()
    for index = #Runtime.manualQueue, 1, -1 do
        local request = Runtime.manualQueue[index]
        local age = now - (tonumber(request.requestedAtMs) or now)
        if age > MANUAL_REQUEST_TTL_MS then
            echo('Expired queued manual action request: %s', tostring(request.name or request.itemName))
            table.remove(Runtime.manualQueue, index)
        end
    end
end

local function configuredEntry(slotKey, itemName)
    slotKey = trim(slotKey)
    itemName = trim(itemName)
    for _, entry in ipairs(Items.collectConfigured()) do
        if (slotKey ~= '' and tostring(entry.slotKey) == slotKey)
            or (itemName ~= '' and tostring(entry.itemName) == itemName) then
            return entry
        end
    end
    return nil
end

local function enqueueManualRequest(content)
    content = type(content) == 'table' and content or {}
    local kind = tostring(content.kind or lib.ActionKind.USE_ITEM):lower()
    local name = trim(content.itemName or content.name)
    if name == '' or (kind ~= lib.ActionKind.USE_ITEM and not MANUAL_ACTION_KINDS[kind]) then
        return true
    end

    local requestId = trim(content.requestId)
    if requestId == '' then
        requestId = string.format('manual:%d:%s', lib.getTimeMs(), name)
    end
    for _, request in ipairs(Runtime.manualQueue) do
        if request.requestId == requestId then return true end
    end

    if #Runtime.manualQueue >= MAX_MANUAL_QUEUE then
        table.remove(Runtime.manualQueue, 1)
    end
    Runtime.manualQueue[#Runtime.manualQueue + 1] = {
        requestId = requestId,
        requestedAtMs = tonumber(content.requestedAtMs) or lib.getTimeMs(),
        kind = kind,
        name = name,
        itemName = kind == lib.ActionKind.USE_ITEM and name or nil,
        slotKey = trim(content.slotKey),
        aaId = tonumber(content.aaId),
        targetId = tonumber(content.targetId),
    }
    echo('Queued manual %s: %s', kind, name)
    return true
end

local function drainManualMessages()
    if #Runtime.incomingManual == 0 then return end
    local incoming = Runtime.incomingManual
    Runtime.incomingManual = {}
    for _, content in ipairs(incoming) do
        enqueueManualRequest(content)
    end
end

local function localContext()
    return {
        inCombat = lib.inCombat(),
        hpPct = lib.safeNum(function() return mq.TLO.Me.PctHPs() end, 100),
    }
end

local function cursorSnapshot(force)
    local now = lib.getTimeMs()
    if force ~= true
        and (now - (tonumber(Runtime.cursorLastScanAtMs) or 0)) < CURSOR_SCAN_MS then
        return Runtime.cursorSnapshot
    end
    Runtime.cursorLastScanAtMs = now
    local itemId = lib.safeNum(function() return mq.TLO.Cursor.ID() end, 0)
    if itemId <= 0 then
        Runtime.cursorSnapshot = nil
        return nil
    end
    local itemName = tostring(lib.safeTLO(
        function() return mq.TLO.Cursor.Name() end, '') or '')
    Runtime.cursorSnapshot = {
        id = itemId,
        name = itemName,
        key = string.format('%d:%s', itemId, itemName),
    }
    return Runtime.cursorSnapshot
end

local function resetCursorObservation()
    Runtime.cursorKey = nil
    Runtime.cursorItemId = 0
    Runtime.cursorItemName = ''
    Runtime.cursorOccupiedSinceMs = 0
end

local function selectCursorCleanup()
    local now = lib.getTimeMs()
    local cursor = cursorSnapshot()
    if not cursor then
        resetCursorObservation()
        return nil, 'cursor_empty'
    end

    if Runtime.cursorKey ~= cursor.key then
        Runtime.cursorKey = cursor.key
        Runtime.cursorItemId = cursor.id
        Runtime.cursorItemName = cursor.name
        Runtime.cursorOccupiedSinceMs = now
        return nil, 'cursor_grace'
    end

    local occupiedMs = now - (tonumber(Runtime.cursorOccupiedSinceMs) or now)
    if occupiedMs < CURSOR_HOLD_MS then
        return nil, string.format('cursor_grace:%dms', occupiedMs)
    end

    return {
        kind = CURSOR_ACTION_KIND,
        name = cursor.name ~= '' and cursor.name or ('item_' .. tostring(cursor.id)),
        cursorItemId = cursor.id,
        cursorItemName = cursor.name,
        cursorKey = cursor.key,
        skipBoundaryTarget = true,
        breaksInvis = false,
        settleMs = 100,
        timeoutMs = CURSOR_VERIFY_MS + 1000,
        idempotencyKey = string.format('cursor:%s:%d',
            cursor.key, Runtime.cursorOccupiedSinceMs),
        reason = string.format('cursor occupied for %dms', occupiedMs),
    }, 'cursor_autoinventory_ready'
end

local function ensureStanding()
    local standing = lib.safeTLO(function() return mq.TLO.Me.Standing() end, true)
    if standing == true then return true end
    mq.cmd('/stand')
    mq.delay(250, function()
        return lib.safeTLO(function() return mq.TLO.Me.Standing() end, false) == true
    end)
    return lib.safeTLO(function() return mq.TLO.Me.Standing() end, false) == true
end

local function actionFor(entry, manualRequest, context)
    local itemName = trim(entry and entry.itemName or manualRequest and manualRequest.itemName)
    local info = entry and entry.info or nil
    local castTimeMs = tonumber(info and info.castTimeMs) or 0
    local slotKey = trim(entry and entry.slotKey or manualRequest and manualRequest.slotKey)
    if slotKey == '' then slotKey = itemName end
    local requestId = manualRequest and manualRequest.requestId or nil
    local mode = manualRequest and 'manual' or tostring(entry and entry.mode or '')
    local priority = lib.Priority.DPS
    if not manualRequest and context and context.inCombat ~= true then
        priority = lib.Priority.BUFF
    end

    return {
        kind = lib.ActionKind.USE_ITEM,
        name = itemName,
        itemName = itemName,
        itemSlot = entry and entry.slot or nil,
        itemSlotKey = slotKey,
        itemMode = mode,
        itemPriority = priority,
        manual = manualRequest ~= nil,
        manualRequestId = requestId,
        expectsCastStart = false,
        settleMs = castTimeMs > 0 and 500 or 200,
        timeoutMs = math.max(5000, castTimeMs + 5000),
        idempotencyKey = requestId or string.format('item:%s:%d', slotKey, math.floor(lib.getTimeMs() / 1000)),
        reason = string.format('%s item %s', manualRequest and 'manual' or 'automatic', itemName),
    }
end

local function manualActionFor(request)
    local kind = tostring(request and request.kind or '')
    local name = trim(request and (request.name or request.itemName))
    return {
        kind = kind,
        name = name,
        spellName = kind == lib.ActionKind.CAST_SPELL and name or nil,
        aaId = kind == lib.ActionKind.USE_AA and request.aaId or nil,
        discName = kind == lib.ActionKind.USE_DISC and name or nil,
        abilityName = kind == lib.ActionKind.USE_SKILL and name or nil,
        targetId = request.targetId,
        manual = true,
        manualRequestId = request.requestId,
        expectsCastStart = false,
        settleMs = 250,
        timeoutMs = 15000,
        idempotencyKey = request.requestId,
        reason = string.format('manual %s %s', kind, name),
    }
end

local function selectItem()
    pruneManualQueue()

    -- Cursor cleanup is independent of configured automatic items and manual
    -- automation mode. It remains lease-coordinated because /autoinventory is
    -- an inventory mutation.
    local cursorAction, cursorReason = selectCursorCleanup()
    if cursorAction then return cursorAction, cursorReason end

    local manual = Runtime.manualQueue[1]
    while manual do
        if manual.kind ~= lib.ActionKind.USE_ITEM then
            return manualActionFor(manual), 'manual_action_ready'
        end
        local entry = configuredEntry(manual.slotKey, manual.itemName)
            or { itemName = manual.itemName, slotKey = manual.slotKey }
        if Items.itemReady(manual.itemName) then
            return actionFor(entry, manual), 'manual_ready'
        end
        echo('Manual item not ready; request dropped: %s', tostring(manual.itemName))
        table.remove(Runtime.manualQueue, 1)
        manual = Runtime.manualQueue[1]
    end

    local settings = lib.getSettings() or {}
    if settings.AutoItemsEnabled == false then return nil, 'auto_items_off' end
    if tostring(settings.AutomationLevel or 'auto'):lower() == 'manual' then
        return nil, 'manual_automation_mode'
    end

    local context = localContext()
    local fallbackReason = 'no_configured_items'
    for _, entry in ipairs(Items.collectConfigured()) do
        local key = tostring(entry.slotKey or entry.itemName)
        local elapsed = lib.getTimeMs() - (Runtime.lastAttemptAt[key] or 0)
        if elapsed < AUTO_RETRY_MS then
            fallbackReason = 'item_throttled:' .. key
        else
            local ready, reason = Items.evaluateAutoEntry(entry, context)
            if ready then return actionFor(entry, nil, context), 'auto_ready' end
            fallbackReason = tostring(reason or 'not_ready') .. ':' .. key
        end
    end
    return nil, fallbackReason
end

local function finishAction(action, result, removeManual)
    action = action or {}
    local now = lib.getTimeMs()
    if action.kind == CURSOR_ACTION_KIND then
        local cursor = cursorSnapshot(true)
        if not cursor then
            resetCursorObservation()
        elseif cursor.key ~= Runtime.cursorKey then
            Runtime.cursorKey = cursor.key
            Runtime.cursorItemId = cursor.id
            Runtime.cursorItemName = cursor.name
            Runtime.cursorOccupiedSinceMs = now
        elseif result and result.phase ~= 'cancelled' then
            -- Inventory-full and similar failures retain the item. Give the
            -- client another full grace interval before retrying.
            Runtime.cursorOccupiedSinceMs = now
        end
    end
    local key = tostring(action.itemSlotKey or action.itemName or action.name or '')
    if key ~= '' then Runtime.lastAttemptAt[key] = now end
    if removeManual == true and action.manualRequestId then
        removeManualRequest(action.manualRequestId)
    end

    Runtime.lastItem = tostring(action.itemName or action.name or '')
    Runtime.lastResult = string.format('%s:%s',
        tostring(result and result.phase or 'unknown'),
        tostring(result and result.reason or 'unknown'))
    if action.manual == true then
        echo('Manual %s %s: %s', tostring(action.kind), Runtime.lastItem, Runtime.lastResult)
    end
end

module.onTick = function(self)
    ensureActorCallbacks(self.peerActors)
    drainManualMessages()

    local lease = self.state and self.state.lease
    local pullOwns = lease and lease.holderModule == 'pull'
    local bandolierSet = Bandolier.selectSet(lib.getSettings(), pullOwns == true)

    local action, reason = selectItem()
    if bandolierSet and not (action and (action.manual == true
        or action.kind == CURSOR_ACTION_KIND)) then
        action = {
            kind = 'bandolier',
            name = bandolierSet,
            bandolierSet = bandolierSet,
            breaksInvis = false,
            idempotencyKey = 'bandolier:' .. bandolierSet,
            reason = 'conditional_bandolier',
        }
        reason = 'bandolier_ready'
    end
    Runtime.selected = action
    Runtime.reason = action
        and string.format('ready:%s',
            tostring(action.itemName or action.bandolierSet or action.name))
        or tostring(reason or 'none')
    self:setIntent(action ~= nil, nil, Runtime.reason)
end

module.shouldAct = function(self)
    return self:hasValidState() and Runtime.selected ~= nil
end

module.getAction = function()
    return Runtime.selected
end

module:enableUnifiedExecutor({
    preflight = function(action)
        if action.kind == CURSOR_ACTION_KIND then
            local cursor = cursorSnapshot(true)
            if not cursor then return false, 'cursor_empty' end
            if cursor.key ~= tostring(action.cursorKey or '') then
                return false, 'cursor_item_changed'
            end
            return true
        end
        if action.kind == 'bandolier' then
            local name = trim(action.bandolierSet or action.name)
            if name == '' then return false, 'bandolier_name_missing' end
            return not Bandolier.isSetWorn(name), 'bandolier_already_worn'
        end
        if action.manualRequestId and action.kind ~= lib.ActionKind.USE_ITEM then
            local found = false
            for _, request in ipairs(Runtime.manualQueue) do
                if request.requestId == action.manualRequestId then found = true break end
            end
            if not found then return false, 'manual_request_expired' end
            if not MANUAL_ACTION_KINDS[action.kind] then return false, 'manual_kind_invalid' end
            if trim(action.name) == '' then return false, 'manual_name_missing' end
            if not ensureStanding() then return false, 'stand_failed' end
            return true
        end
        local itemName = trim(action and (action.itemName or action.name))
        if itemName == '' then return false, 'item_name_missing' end
        if action.manualRequestId then
            local found = false
            for _, request in ipairs(Runtime.manualQueue) do
                if request.requestId == action.manualRequestId then found = true break end
            end
            if not found then return false, 'manual_request_expired' end
        else
            local entry = configuredEntry(action.itemSlotKey, itemName)
            if not entry then return false, 'item_config_changed' end
            local ready, reason = Items.evaluateAutoEntry(entry, localContext())
            if not ready then return false, reason or 'item_no_longer_eligible' end
        end
        if not Items.itemReady(itemName) then return false, 'item_not_ready' end

        -- Meditation may have left us sitting immediately before this higher
        -- priority lease was granted. Stand under the item worker's cast lease
        -- so the subsequent /useitem is not rejected by the client.
        if not ensureStanding() then return false, 'stand_failed' end
        return true
    end,
    dispatch = function(action)
        if action.kind == CURSOR_ACTION_KIND then
            mq.cmd('/autoinventory')
            return true, 'autoinventory_issued', 'custom'
        end
        if action.kind == 'bandolier' then
            local issued = Bandolier.activateSet(action.bandolierSet or action.name)
            return issued, issued and 'issued' or 'bandolier_not_changed', 'none'
        end
        if action.kind ~= lib.ActionKind.USE_ITEM then
            return nil, ActionExecutor.USE_DEFAULT_DISPATCH
        end
        local issued = ActionExecutor.executeItem(action.itemName or action.name)
        return issued, issued and 'issued' or 'item_not_ready', 'cast_or_settle'
    end,
    onTick = function(action, _, job)
        if action.kind ~= CURSOR_ACTION_KIND then return true end
        local cursor = cursorSnapshot()
        if not cursor or cursor.key ~= tostring(action.cursorKey or '') then
            return true, 'cursor_cleared', 'completed'
        end
        if (lib.getTimeMs() - (tonumber(job and job.phaseAtMs) or 0))
            >= CURSOR_VERIFY_MS then
            return true, 'cursor_not_cleared', 'failed'
        end
        return true, 'waiting_cursor_clear'
    end,
    onComplete = function(action, _, _, result)
        finishAction(action, result, true)
    end,
    onFailure = function(action, _, _, result)
        finishAction(action, result, true)
    end,
    onCancel = function(action, _, _, result)
        -- Preemption or a transient stun releases ownership but preserves a
        -- still-live manual request. It can safely retry after the higher
        -- priority work/control effect clears.
        finishAction(action, result, false)
    end,
})

module:enablePeerActors()
-- Register before ModuleBase initializes the Actor mailbox so a click sent
-- during worker startup cannot be validated and drained before this receiver exists.
ensureActorCallbacks(ActorsCoordinator)

mq.bind('/sk_items', function(cmd)
    cmd = trim(cmd):lower()
    if cmd == 'stop' then
        module:stop()
        echo('Stop requested')
    elseif cmd == 'list' then
        local context = localContext()
        local configured = Items.collectConfigured()
        echo('Configured items: %d', #configured)
        for _, entry in ipairs(configured) do
            local ready, reason = Items.evaluateAutoEntry(entry, context)
            echo('%s %s mode=%s ready=%s reason=%s', tostring(entry.slotKey),
                tostring(entry.itemName), tostring(entry.mode), tostring(ready), tostring(reason))
        end
    elseif cmd == 'bando' then
        local lease = module.state and module.state.lease
        local pullOwns = lease and lease.holderModule == 'pull'
        Bandolier.debugDump(lib.getSettings(), pullOwns == true)
    elseif cmd == '' or cmd == 'status' then
        local owner = module.state and module.state.lease or nil
        local cursorAgeMs = Runtime.cursorOccupiedSinceMs > 0
            and math.max(0, lib.getTimeMs() - Runtime.cursorOccupiedSinceMs) or 0
        echo('reason=%s queue=%d selected=%s owner=%s cursor=%s age=%dms last=%s/%s',
            tostring(Runtime.reason), #Runtime.manualQueue,
            tostring(Runtime.selected and Runtime.selected.itemName or 'none'),
            tostring(owner and owner.holderModule or 'none'),
            tostring(Runtime.cursorItemName ~= '' and Runtime.cursorItemName or 'empty'),
            cursorAgeMs,
            tostring(Runtime.lastItem ~= '' and Runtime.lastItem or 'none'),
            tostring(Runtime.lastResult))
    else
        echo('Usage: /sk_items status|list|bando|stop')
    end
end)

module:run(50)

return module
