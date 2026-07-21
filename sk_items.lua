-- F:/lua/sidekick-next/sk_items.lua
-- Coordinated owner for configured clickies and queued manual item-bar uses.

local mq = require('mq')
local actors = require('actors')
local lib = require('sidekick-next.sk_lib')
local ModuleBase = require('sidekick-next.sk_module_base')
local Items = require('sidekick-next.utils.items')
local Bandolier = require('sidekick-next.utils.bandolier')

local module = ModuleBase.create('items', lib.Priority.DPS)

local MANUAL_REQUEST_TTL_MS = 15000
local AUTO_RETRY_MS = 1000
local MAX_MANUAL_QUEUE = 20

local Runtime = {
    manualQueue = {},
    incomingManual = {},
    lastAttemptAt = {},
    selected = nil,
    reason = 'init',
    lastResult = 'none',
    lastItem = '',
}
local manualDropbox = nil

local function trim(value)
    return tostring(value or ''):gsub('^%s+', ''):gsub('%s+$', '')
end

local function echo(fmt, ...)
    local ok, message = pcall(string.format, tostring(fmt or ''), ...)
    if not ok then message = tostring(fmt or '') end
    print(string.format('\ag[SK Items]\ax %s', message))
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
            echo('Expired queued manual item request: %s', tostring(request.itemName))
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
    local itemName = trim(content.itemName or content.name)
    if itemName == '' then return true end

    local requestId = trim(content.requestId)
    if requestId == '' then
        requestId = string.format('manual:%d:%s', lib.getTimeMs(), itemName)
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
        itemName = itemName,
        slotKey = trim(content.slotKey),
    }
    echo('Queued manual item: %s', itemName)
    return true
end

local function drainManualMessages()
    if #Runtime.incomingManual == 0 then return end
    local incoming = Runtime.incomingManual
    Runtime.incomingManual = {}
    local myName = trim(lib.getMyName()):lower()
    for _, content in ipairs(incoming) do
        local senderName = trim(content.from):lower()
        if senderName == '' or senderName == myName then
            enqueueManualRequest(content)
        end
    end
end

local function localContext()
    return {
        inCombat = lib.inCombat(),
        hpPct = lib.safeNum(function() return mq.TLO.Me.PctHPs() end, 100),
    }
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
        type = lib.ClaimType.CAST,
        wants = { 'cast' },
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
        claimTtlMs = math.max(5000, castTimeMs + 5000),
        idempotencyKey = requestId or string.format('item:%s:%d', slotKey, math.floor(lib.getTimeMs() / 1000)),
        reason = string.format('%s item %s', manualRequest and 'manual' or 'automatic', itemName),
    }
end

local function selectItem()
    pruneManualQueue()

    local manual = Runtime.manualQueue[1]
    while manual do
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
        echo('Manual item %s: %s', Runtime.lastItem, Runtime.lastResult)
    end
end

module.onTick = function(self)
    drainManualMessages()

    -- Conditional bandolier swapping lives in this worker (equipment domain).
    -- Weapon swaps are instant and claim-free; skip while the pull module
    -- owns the character so its forced pull set is never fought over.
    local pullOwns = self.state and self.state.targetOwner
        and self.state.targetOwner.module == 'pull'
    Bandolier.tick(lib.getSettings(), pullOwns == true)

    local action, reason = selectItem()
    Runtime.selected = action
    self.priority = action and tonumber(action.itemPriority) or lib.Priority.DPS
    Runtime.reason = action and string.format('ready:%s', tostring(action.itemName)) or tostring(reason or 'none')
    self:sendNeed(action ~= nil, action and 1000 or nil, Runtime.reason)
end

module.shouldAct = function(self)
    return self:hasValidState() and Runtime.selected ~= nil
end

module.getAction = function()
    return Runtime.selected
end

module:enableUnifiedExecutor({
    preflight = function(action)
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
        local standing = lib.safeTLO(function() return mq.TLO.Me.Standing() end, true)
        if standing ~= true then
            mq.cmd('/stand')
            mq.delay(250, function()
                return lib.safeTLO(function() return mq.TLO.Me.Standing() end, false) == true
            end)
            if lib.safeTLO(function() return mq.TLO.Me.Standing() end, false) ~= true then
                return false, 'stand_failed'
            end
        end
        return true
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

-- This mailbox is addressed as sidekick-next/sk_items:sidekick by the UI host.
-- Actor callbacks are non-yieldable, so copy only serializable scalar fields;
-- the worker validates and processes them from module.onTick.
manualDropbox = actors.register('sidekick', function(message)
    local content = message()
    if type(content) ~= 'table' or tostring(content.id or ''):lower() ~= 'item:manual' then return end
    if #Runtime.incomingManual >= MAX_MANUAL_QUEUE then
        table.remove(Runtime.incomingManual, 1)
    end
    Runtime.incomingManual[#Runtime.incomingManual + 1] = {
        requestId = tostring(content.requestId or ''),
        requestedAtMs = tonumber(content.requestedAtMs),
        itemName = tostring(content.itemName or content.name or ''),
        slotKey = tostring(content.slotKey or ''),
        from = tostring(content.from or ''),
    }
end)

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
        local pullOwns = module.state and module.state.targetOwner
            and module.state.targetOwner.module == 'pull'
        Bandolier.debugDump(lib.getSettings(), pullOwns == true)
    elseif cmd == '' or cmd == 'status' then
        local owner = module.state and module.state.castOwner or nil
        echo('reason=%s queue=%d selected=%s owner=%s last=%s/%s',
            tostring(Runtime.reason), #Runtime.manualQueue,
            tostring(Runtime.selected and Runtime.selected.itemName or 'none'),
            tostring(owner and owner.module or 'none'),
            tostring(Runtime.lastItem ~= '' and Runtime.lastItem or 'none'),
            tostring(Runtime.lastResult))
    else
        echo('Usage: /sk_items status|list|bando|stop')
    end
end)

module:run(50)

return module
