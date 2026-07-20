-- Resurrection worker for SideKick-Next.
--
-- Rez v2 owns group-corpse selection, per-state resource policy, optional
-- item use, OOC spell memorization/restoration, optional navigation, and
-- deterministic cross-character intent claims. All yielding work advances in
-- this worker's main coroutine; Actor callbacks only copy message state.

local mq = require('mq')
local lib = require('sidekick-next.sk_lib')
local ModuleBase = require('sidekick-next.sk_module_base')
local lazy = require('sidekick-next.utils.lazy_require')
local RezData = require('sidekick-next.utils.rez_data')

local getCore = lazy('sidekick-next.utils.core')
local getSpellEvents = lazy('sidekick-next.utils.spell_events')
local module = ModuleBase.create('resurrection', lib.Priority.RESURRECTION)

local LAST_ATTEMPT_SUPPRESS_MS = 10000
local INTENT_TTL_SECONDS = 3
local INTENT_SETTLE_MS = 450
local INTENT_REFRESH_MS = 1000
local LEASE_REFRESH_MS = 1000
-- ModuleBase intentionally skips onTick while stunned/mezzed. Keep the shared
-- gem lease alive long enough that a normal control effect cannot make the
-- manual-memorization watcher adopt the temporary rez spell.
local LEASE_TTL_SECONDS = 30
local TARGET_TIMEOUT_MS = 1500
local MEMORIZE_TIMEOUT_MS = 12000
local READY_TIMEOUT_MS = 5000
local NAV_TIMEOUT_MS = 15000
local CAST_START_TIMEOUT_MS = 2500
local CAST_TIMEOUT_MARGIN_MS = 3000
local CLAIM_TTL_MS = 45000

local Runtime = {
    lastAttempt = {},
    peerIntents = {},
    localIntent = nil,
    pendingAction = nil,
    workflow = nil,
    actorCallbacksRegistered = false,
    spellEventsRegistered = false,
    recoveryChecked = false,
    forcedTargetName = nil,
    forceNext = false,
    reason = 'starting',
    target = nil,
    resource = nil,
    winner = nil,
    lastResult = 'none',
    lastTelemetryAtMs = 0,
    runtimeDebug = nil,
    stopAfterCleanup = false,
    lastDebug = {},
}

local function nowMs()
    return lib.getTimeMs()
end

local function trim(value)
    return tostring(value or ''):match('^%s*(.-)%s*$') or ''
end

local function settingBool(key, default)
    local Core = getCore()
    local value = Core and Core.Settings and Core.Settings[key]
    if value == nil then return default end
    return value == true
end

local function settingNumber(key, default)
    local Core = getCore()
    local value = Core and Core.Settings and tonumber(Core.Settings[key])
    return value or default
end

local function settingString(key, default)
    local Core = getCore()
    local value = Core and Core.Settings and Core.Settings[key]
    if value == nil then return default end
    value = trim(value)
    return value ~= '' and value or default
end

local function debugEnabled()
    if Runtime.runtimeDebug ~= nil then return Runtime.runtimeDebug end
    return settingBool('RezDebug', false)
end

local function echo(fmt, ...)
    print(string.format('\aw[SK-Rez]\ax ' .. fmt, ...))
end

local function debugEcho(key, fmt, ...)
    if not debugEnabled() then return end
    local now = nowMs()
    if (now - (Runtime.lastDebug[key] or 0)) < 1500 then return end
    Runtime.lastDebug[key] = now
    echo(fmt, ...)
end

local function setReason(reason)
    reason = tostring(reason or 'unknown')
    if Runtime.reason ~= reason then
        Runtime.reason = reason
        debugEcho('reason:' .. reason, 'reason=%s', reason)
    end
end

local function myName()
    return lib.getMyName() or ''
end

local function myClassShort()
    return lib.safeTLO(function() return mq.TLO.Me.Class.ShortName() end, '') or ''
end

local function zoneShort()
    return lib.safeTLO(function() return mq.TLO.Zone.ShortName() end, '') or ''
end

local function isSpellBookOpen()
    return lib.safeTLO(function()
        local window = mq.TLO.Window('SpellBookWnd')
        return window and window.Open and window.Open() == true
    end, false) == true
end

local function closeSpellBook()
    pcall(function()
        local window = mq.TLO.Window('SpellBookWnd')
        if window and window.Open and window.Open() and window.DoClose then
            window.DoClose()
        end
    end)
end

local function normalizeMethod(value, allowed, fallback)
    local wanted = settingString(value, fallback):lower()
    for _, method in ipairs(allowed) do
        if wanted == method:lower() then return method end
    end
    return fallback
end

local function oocMethod()
    return normalizeMethod('RezOOCMethod', { 'Auto', 'Spell', 'Item' }, 'Auto')
end

local function combatMethod()
    return normalizeMethod('RezCombatMethod', { 'Auto', 'AA', 'Spell', 'Item' }, 'Auto')
end

local function combatClassSet()
    local raw = settingString('RezCombatTargetClasses', 'ALL'):upper()
    if raw == 'ALL' or raw == '*' then return nil end
    local selected = {}
    for token in raw:gmatch('[A-Z]+') do
        selected[token] = true
    end
    return selected
end

local function combatClassAllowed(classShort)
    local selected = combatClassSet()
    return selected == nil or selected[tostring(classShort or ''):upper()] == true
end

local function findExactItem(name)
    name = trim(name)
    if name == '' then return nil end
    local item = mq.TLO.FindItem('=' .. name)
    if item and item() then return item end
    item = mq.TLO.FindItem(name)
    if item and item() then return item end
    return nil
end

local function itemResource(requireReady)
    local configured = settingString('RezItemName', '')
    if configured == '' then return nil, 'rez_item_not_configured' end
    local item = findExactItem(configured)
    if not item then return nil, 'rez_item_not_found' end

    local clickyName = lib.safeTLO(function() return item.Clicky.Spell.Name() end, '') or ''
    if clickyName == '' then return nil, 'rez_item_has_no_clicky' end
    local timer = lib.safeNum(function() return item.TimerReady() end, 0)
    if requireReady and timer ~= 0 then return nil, 'rez_item_not_ready' end

    return {
        kind = 'item',
        name = lib.safeTLO(function() return item.Name() end, configured) or configured,
        clickyName = clickyName,
        range = lib.safeNum(function() return item.Clicky.Spell.MyRange() end,
            lib.safeNum(function() return item.Clicky.Spell.Range() end, 100)),
        castTimeMs = lib.safeNum(function() return item.Clicky.CastTime() end,
            lib.safeNum(function() return item.Clicky.Spell.MyCastTime() end, 0)),
    }, nil
end

local function findGemSlot(spellName)
    local total = lib.safeNum(function() return mq.TLO.Me.NumGems() end, 13)
    for slot = 1, total do
        local name = lib.safeTLO(function() return mq.TLO.Me.Gem(slot).Name() end, '') or ''
        if name == spellName then return slot end
    end
    return nil
end

local function learnedRezSpell()
    for _, name in ipairs(RezData.getSpells(myClassShort())) do
        local known = lib.safeTLO(function()
            local spell = mq.TLO.Me.Book(name)
            return spell and spell() and true or false
        end, false)
        if known then return name end
    end
    return nil
end

local function spellResource(inCombat, requireReady)
    local name = learnedRezSpell()
    if not name then return nil, 'no_learned_rez_spell' end
    local slot = findGemSlot(name)
    if not slot and (inCombat or not settingBool('RezAutoMemorize', true)) then
        return nil, inCombat and 'rez_spell_not_memorized_in_combat' or 'rez_spell_not_memorized'
    end

    local spell = mq.TLO.Spell(name)
    local mana = lib.safeNum(function() return spell.Mana() end, 0)
    local currentMana = lib.safeNum(function() return mq.TLO.Me.CurrentMana() end, 0)
    if mana > currentMana then return nil, 'insufficient_mana_for_rez' end

    if slot and requireReady then
        local ready = lib.safeTLO(function()
            local value = mq.TLO.Me.SpellReady(name)
            return value and value() == true
        end, false)
        if not ready then return nil, 'rez_spell_not_ready' end
    end

    return {
        kind = 'spell',
        name = name,
        gemSlot = slot,
        needsMemorize = slot == nil,
        range = lib.safeNum(function() return spell.MyRange() end, 100),
        castTimeMs = lib.safeNum(function() return spell.MyCastTime() end, 6000),
        mana = mana,
    }, nil
end

local function aaResource(requireReady)
    local name = RezData.getAA(myClassShort())
    if not name then return nil, 'no_battle_rez_aa_for_class' end
    local aaId = lib.safeNum(function() return mq.TLO.Me.AltAbility(name).ID() end, 0)
    if aaId <= 0 then return nil, 'battle_rez_aa_not_owned' end
    if requireReady then
        local ready = lib.safeTLO(function() return mq.TLO.Me.AltAbilityReady(name)() end, false)
        if not ready then return nil, 'battle_rez_aa_not_ready' end
    end
    return {
        kind = 'aa',
        name = name,
        aaId = aaId,
        range = lib.safeNum(function() return mq.TLO.Me.AltAbility(name).Spell.MyRange() end, 100),
        castTimeMs = lib.safeNum(function() return mq.TLO.Me.AltAbility(name).Spell.MyCastTime() end, 0),
    }, nil
end

local function selectResource(inCombat)
    local method = inCombat and combatMethod() or oocMethod()
    local resource, itemReason, aaReason, spellReason

    if method == 'Item' then return itemResource(true) end
    if method == 'AA' then return aaResource(true) end
    if method == 'Spell' then return spellResource(inCombat, true) end

    -- Auto prefers the explicitly configured item. In combat it then tries the
    -- class AA and finally an already-memorized spell. OOC falls back directly
    -- to the best learned spell and can memorize it on demand.
    resource, itemReason = itemResource(true)
    if resource then return resource, nil end
    if inCombat then
        resource, aaReason = aaResource(true)
        if resource then return resource, nil end
        resource, spellReason = spellResource(true, true)
        if resource then return resource, nil end
        return nil, string.format('auto_no_combat_resource:item=%s,aa=%s,spell=%s',
            tostring(itemReason), tostring(aaReason), tostring(spellReason))
    end
    resource, spellReason = spellResource(false, true)
    if resource then return resource, nil end
    return nil, string.format('auto_no_ooc_resource:item=%s,spell=%s',
        tostring(itemReason), tostring(spellReason))
end

local function corpseSpawn(corpseId)
    local spawn = mq.TLO.Spawn(tonumber(corpseId) or 0)
    if spawn and spawn() then return spawn end
    return nil
end

local function corpseDistance(corpseId)
    local spawn = corpseSpawn(corpseId)
    if not spawn then return nil end
    return lib.safeNum(function() return spawn.Distance() end, 99999)
end

local function findRezTarget(inCombat)
    local now = nowMs()
    local forced = trim(Runtime.forcedTargetName):lower()
    local groupCount = lib.getGroupCount()
    local sawDead, sawFiltered, sawSuppressed = false, false, false

    for index = 1, groupCount do
        local member = mq.TLO.Group.Member(index)
        if member and member() then
            local dead = lib.safeTLO(function() return member.Dead() end, false) == true
            local offline = lib.safeTLO(function() return member.Offline() end, false) == true
            local otherZone = lib.safeTLO(function() return member.OtherZone() end, false) == true
            if dead and not offline and not otherZone then
                sawDead = true
                local name = lib.safeTLO(function() return member.CleanName() end, '') or ''
                local classShort = lib.safeTLO(function() return member.Class.ShortName() end, '') or ''
                if forced ~= '' and name:lower() ~= forced then goto continue end
                if inCombat and not Runtime.forceNext and not combatClassAllowed(classShort) then
                    sawFiltered = true
                    goto continue
                end

                local spawn = mq.TLO.Spawn(string.format([[pccorpse ="%s's corpse"]], name))
                if spawn and spawn() then
                    local corpseId = lib.safeNum(function() return spawn.ID() end, 0)
                    local spawnType = (lib.safeTLO(function() return spawn.Type() end, '') or ''):lower()
                    if corpseId > 0 and spawnType == 'corpse' then
                        local lastAt = Runtime.lastAttempt[corpseId] or 0
                        if (now - lastAt) >= LAST_ATTEMPT_SUPPRESS_MS then
                            return {
                                corpseId = corpseId,
                                memberName = name,
                                classShort = classShort,
                                distance = lib.safeNum(function() return spawn.Distance() end, 99999),
                            }, nil
                        end
                        sawSuppressed = true
                    end
                end
            end
        end
        ::continue::
    end

    if sawSuppressed then return nil, 'corpse_attempt_suppressed' end
    if sawFiltered then return nil, 'combat_target_class_filtered' end
    if sawDead then return nil, 'dead_member_corpse_not_found' end
    return nil, forced ~= '' and 'requested_member_not_dead_or_present' or 'no_dead_group_member'
end

local function prunePeerIntents()
    local nowEpoch = os.time()
    for corpseId, perRezzer in pairs(Runtime.peerIntents) do
        for rezzer, intent in pairs(perRezzer) do
            if (tonumber(intent.expiresAt) or 0) < nowEpoch then
                perRezzer[rezzer] = nil
            end
        end
        if not next(perRezzer) then Runtime.peerIntents[corpseId] = nil end
    end
end

local function clearLocalIntent(reason, broadcast)
    local intent = Runtime.localIntent
    if broadcast ~= false and intent and module.peerActors and module.peerActors.broadcast then
        module.peerActors.broadcast('rez:cancelled', {
            corpseId = intent.corpseId,
            zone = zoneShort(),
            reason = reason or 'no_longer_needed',
        })
    end
    Runtime.localIntent = nil
    Runtime.winner = nil
end

local function receivePeerIntent(content, sender, fromMe)
    if fromMe then return true end
    if tostring(content.zone or '') ~= '' and tostring(content.zone) ~= zoneShort() then return true end
    local corpseId = tonumber(content.corpseId) or 0
    local rezzer = trim(content.from or (sender and sender.character)):lower()
    if corpseId <= 0 or rezzer == '' then return true end
    Runtime.peerIntents[corpseId] = Runtime.peerIntents[corpseId] or {}
    Runtime.peerIntents[corpseId][rezzer] = {
        corpseId = corpseId,
        from = trim(content.from or (sender and sender.character)),
        priority = tonumber(content.priority) or 50,
        resourceKind = tostring(content.resourceKind or ''),
        expiresAt = tonumber(content.expiresAt) or (os.time() + INTENT_TTL_SECONDS),
    }
    local workflow = Runtime.workflow
    if workflow and workflow.targetId == corpseId and settingBool('RezCoordinateActors', true) then
        local peerPriority = tonumber(content.priority) or 50
        local localPriority = math.max(0, math.floor(settingNumber('RezPriority', 50)))
        local peerName = trim(content.from or (sender and sender.character))
        if peerPriority < localPriority
            or (peerPriority == localPriority and peerName:lower() < myName():lower()) then
            Runtime.winner = peerName
            if workflow.phase ~= 'cast_start_wait' and workflow.phase ~= 'cast_wait'
                and workflow.phase ~= 'restore_send' and workflow.phase ~= 'restore_wait' then
                workflow.cancelReason = 'higher_priority_peer:' .. peerName
            end
        end
    end
    return true
end

local function receivePeerCancelled(content, sender, fromMe)
    if fromMe then return true end
    local corpseId = tonumber(content.corpseId) or 0
    local rezzer = trim(content.from or (sender and sender.character)):lower()
    if Runtime.peerIntents[corpseId] then Runtime.peerIntents[corpseId][rezzer] = nil end
    return true
end

local function receivePeerCompleted(content, sender, fromMe)
    if fromMe then return true end
    if tostring(content.zone or '') ~= '' and tostring(content.zone) ~= zoneShort() then return true end
    local corpseId = tonumber(content.corpseId) or 0
    if corpseId <= 0 then return true end
    Runtime.lastAttempt[corpseId] = nowMs()
    Runtime.peerIntents[corpseId] = nil
    if Runtime.workflow and Runtime.workflow.targetId == corpseId then
        local phase = Runtime.workflow.phase
        -- Once the command has been issued, changing winners can interrupt a
        -- valid rez and leave both rezzers uncertain about the outcome.
        if phase ~= 'cast_start_wait' and phase ~= 'cast_wait'
            and phase ~= 'restore_send' and phase ~= 'restore_wait' then
            Runtime.workflow.cancelReason = 'peer_rez_completed'
        end
    end
    return true
end

local function ensureActorCallbacks(self)
    if Runtime.actorCallbacksRegistered or not self.peerActors then return end
    if not self.peerActors.registerMessageCallback then return end
    self.peerActors.registerMessageCallback('rez:claim', receivePeerIntent)
    self.peerActors.registerMessageCallback('rez:cancelled', receivePeerCancelled)
    self.peerActors.registerMessageCallback('rez:completed', receivePeerCompleted)
    Runtime.actorCallbacksRegistered = true
end

local function ensureSpellEvents()
    if Runtime.spellEventsRegistered then return end
    local SpellEvents = getSpellEvents()
    if SpellEvents and SpellEvents.registerEvents then
        SpellEvents.registerEvents()
        Runtime.spellEventsRegistered = true
    end
end

local function castFailureReason(workflow)
    local SpellEvents = getSpellEvents()
    if not (SpellEvents and SpellEvents.getLastResult and SpellEvents.isFailed) then return nil end
    local result, resultAt = SpellEvents.getLastResult()
    if tonumber(resultAt) and tonumber(resultAt) >= tonumber(workflow.castResultResetAt or math.huge)
        and SpellEvents.isFailed(result) then
        local name = SpellEvents.getResultName and SpellEvents.getResultName(result) or tostring(result)
        return 'rez_cast_failed:' .. tostring(name):lower()
    end
    return nil
end

local function localWinsIntent(target, resource)
    if not settingBool('RezCoordinateActors', true) or not module.peerActors then
        Runtime.winner = myName()
        return true, nil
    end

    local now = nowMs()
    local priority = math.max(0, math.floor(settingNumber('RezPriority', 50)))
    local intent = Runtime.localIntent
    if not intent or intent.corpseId ~= target.corpseId or intent.resourceKind ~= resource.kind then
        clearLocalIntent('candidate_changed')
        intent = {
            corpseId = target.corpseId,
            targetName = target.memberName,
            resourceKind = resource.kind,
            resourceName = resource.name,
            priority = priority,
            firstAtMs = now,
            lastSentAtMs = 0,
        }
        Runtime.localIntent = intent
    end

    if (now - intent.lastSentAtMs) >= INTENT_REFRESH_MS then
        intent.lastSentAtMs = now
        module.peerActors.broadcast('rez:claim', {
            corpseId = target.corpseId,
            targetName = target.memberName,
            targetClass = target.classShort,
            resourceKind = resource.kind,
            resourceName = resource.name,
            priority = priority,
            zone = zoneShort(),
            expiresAt = os.time() + INTENT_TTL_SECONDS,
        })
    end

    prunePeerIntents()
    local candidates = {
        { from = myName(), priority = priority, localCandidate = true },
    }
    for _, peer in pairs(Runtime.peerIntents[target.corpseId] or {}) do
        candidates[#candidates + 1] = peer
    end
    table.sort(candidates, function(a, b)
        local ap, bp = tonumber(a.priority) or 50, tonumber(b.priority) or 50
        if ap ~= bp then return ap < bp end
        return tostring(a.from or ''):lower() < tostring(b.from or ''):lower()
    end)

    local winner = candidates[1]
    Runtime.winner = winner and winner.from or myName()
    if not winner or winner.localCandidate ~= true then
        return false, 'peer_rez_claim:' .. tostring(Runtime.winner or 'unknown')
    end
    if (now - intent.firstAtMs) < INTENT_SETTLE_MS then
        return false, 'actor_claim_settling'
    end
    return true, nil
end

local function leasePath()
    return string.format('%s/SideKick_buff_gem_lease.txt', tostring(mq.configDir or 'config'))
end

local function recoveryPath()
    return string.format('%s/SideKick_rez_gem_restore.txt', tostring(mq.configDir or 'config'))
end

local function writeLease(workflow)
    if not workflow or not workflow.tempGem then return end
    local now = nowMs()
    if (now - (workflow.lastLeaseAtMs or 0)) < LEASE_REFRESH_MS then return end
    workflow.lastLeaseAtMs = now
    local file = io.open(leasePath(), 'w')
    if file then
        file:write(string.format('%d rez_hotswap\n', os.time() + LEASE_TTL_SECONDS))
        file:close()
    end
end

local function clearRezLeaseAndRecovery()
    -- The lease file is shared with buff hot-swaps. Remove it only when this
    -- workflow owns it; a rez cleanup must never release the buff worker's
    -- lease.
    local ownsLease = false
    local file = io.open(leasePath(), 'r')
    if file then
        ownsLease = tostring(file:read('*a') or ''):find('rez_hotswap', 1, true) ~= nil
        file:close()
    end
    if ownsLease then pcall(os.remove, leasePath()) end
    pcall(os.remove, recoveryPath())
end

local function writeRecovery(workflow)
    local file = io.open(recoveryPath(), 'w')
    if not file then return false end
    file:write(string.format('%d\n%d\n%d\n%s\n%s\n',
        os.time() + 300,
        tonumber(workflow.tempGemSlot) or 0,
        tonumber(workflow.originalGemId) or 0,
        tostring(workflow.originalGemName or ''),
        tostring(workflow.resource and workflow.resource.name or '')))
    file:close()
    return true
end

local function gemName(slot)
    return lib.safeTLO(function() return mq.TLO.Me.Gem(slot).Name() end, '') or ''
end

local function gemId(slot)
    return lib.safeNum(function() return mq.TLO.Me.Gem(slot).ID() end, 0)
end

local function requestedRezGem()
    local total = lib.safeNum(function() return mq.TLO.Me.NumGems() end, 0)
    if total <= 0 then return nil end
    local configured = math.floor(settingNumber('RezGem', 0))
    if configured <= 0 then return total end
    return math.max(1, math.min(total, configured))
end

local function stopWorkflowNav(workflow)
    if workflow and workflow.navStarted then
        mq.cmd('/squelch /nav stop')
        workflow.navStarted = false
    end
end

local function navActive()
    return lib.safeTLO(function()
        return (mq.TLO.Nav and mq.TLO.Nav.Active and mq.TLO.Nav.Active())
            or (mq.TLO.Navigation and mq.TLO.Navigation.Active and mq.TLO.Navigation.Active())
    end, false) == true
end

local function navPathExists(corpseId)
    return lib.safeTLO(function()
        if not (mq.TLO.Navigation and mq.TLO.Navigation.MeshLoaded and mq.TLO.Navigation.MeshLoaded()) then
            return false
        end
        local result = mq.TLO.Navigation.PathExists('id ' .. tostring(corpseId))
        return result and result() == true
    end, false) == true
end

local function targetIs(corpseId)
    return lib.safeNum(function() return mq.TLO.Target.ID() end, 0) == corpseId
end

local function resourceReady(resource)
    if resource.kind == 'item' then
        local current = select(1, itemResource(true))
        return current ~= nil
    elseif resource.kind == 'aa' then
        local current = select(1, aaResource(true))
        return current ~= nil
    elseif resource.kind == 'spell' then
        local slot = findGemSlot(resource.name)
        if not slot then return false end
        resource.gemSlot = slot
        return lib.safeTLO(function()
            local ready = mq.TLO.Me.SpellReady(resource.name)
            return ready and ready() == true
        end, false) == true
    end
    return false
end

local function actionFor(target, resource)
    local kind = lib.ActionKind.USE_ITEM
    if resource.kind == 'spell' then kind = lib.ActionKind.CAST_SPELL end
    if resource.kind == 'aa' then kind = lib.ActionKind.USE_AA end
    return {
        kind = kind,
        type = lib.ClaimType.ACTION,
        wants = { 'target', 'cast' },
        name = resource.name,
        targetId = target.corpseId,
        targetName = target.memberName,
        targetClass = target.classShort,
        resourceKind = resource.kind,
        resourceName = resource.name,
        resourceRange = resource.range,
        resourceCastTimeMs = resource.castTimeMs,
        resourceGemSlot = resource.gemSlot,
        needsMemorize = resource.needsMemorize == true,
        aaId = resource.aaId,
        claimTtlMs = CLAIM_TTL_MS,
        timeoutMs = CLAIM_TTL_MS,
        castStartTimeoutMs = 30000,
        idempotencyKey = string.format('rez:%s:%d', resource.kind, target.corpseId),
        reason = string.format('rez %s with %s', target.memberName, resource.name),
    }
end

local function cleanupAction(workflow)
    return {
        kind = lib.ActionKind.USE_ITEM,
        type = lib.ClaimType.CAST,
        wants = { 'cast' },
        name = 'restore rez gem',
        targetId = nil,
        resourceKind = 'restore',
        claimTtlMs = 30000,
        timeoutMs = 30000,
        idempotencyKey = string.format('rez:restore:%d', tonumber(workflow.tempGemSlot) or 0),
        reason = 'restore temporary rez gem',
    }
end

local function finishWorkflow(success, reason)
    local workflow = Runtime.workflow
    if not workflow then return true, reason or 'completed' end
    stopWorkflowNav(workflow)
    if workflow.tempGem then clearRezLeaseAndRecovery() end
    closeSpellBook()

    if workflow.targetId and workflow.targetId > 0 then
        Runtime.lastAttempt[workflow.targetId] = nowMs()
        if module.peerActors and module.peerActors.broadcast and not workflow.completionBroadcast then
            module.peerActors.broadcast(success and 'rez:completed' or 'rez:cancelled', {
                corpseId = workflow.targetId,
                targetName = workflow.targetName,
                resourceKind = workflow.resource and workflow.resource.kind or '',
                resourceName = workflow.resource and workflow.resource.name or '',
                zone = zoneShort(),
                reason = reason,
            })
        end
    end

    Runtime.lastResult = tostring(reason or (success and 'completed' or 'failed'))
    Runtime.workflow = nil
    Runtime.pendingAction = nil
    Runtime.forcedTargetName = nil
    Runtime.forceNext = false
    -- A completed intent has already been replaced by rez:completed. Avoid
    -- immediately following that success broadcast with rez:cancelled.
    clearLocalIntent(reason, not workflow.completionBroadcast)
    echo('%s: %s', success and '\agCompleted\ax' or '\arStopped\ax', Runtime.lastResult)
    if Runtime.stopAfterCleanup then
        Runtime.stopAfterCleanup = false
        module:stop()
    end
    return true, Runtime.lastResult
end

local function beginRestore(success, reason)
    local workflow = Runtime.workflow
    if not workflow then return true, reason end
    workflow.terminalSuccess = success == true
    workflow.terminalReason = reason or (success and 'completed' or 'failed')
    stopWorkflowNav(workflow)

    -- Tell peers as soon as the rez command/cast completes. Gem restoration can
    -- take several more seconds and must not make another rezzer think the
    -- corpse intent expired during that cleanup window.
    if workflow.terminalSuccess and workflow.targetId and workflow.targetId > 0
        and not workflow.completionBroadcast then
        workflow.completionBroadcast = true
        Runtime.lastAttempt[workflow.targetId] = nowMs()
        if module.peerActors and module.peerActors.broadcast then
            module.peerActors.broadcast('rez:completed', {
                corpseId = workflow.targetId,
                targetName = workflow.targetName,
                resourceKind = workflow.resource and workflow.resource.kind or '',
                resourceName = workflow.resource and workflow.resource.name or '',
                zone = zoneShort(),
                reason = workflow.terminalReason,
            })
        end
    end

    if not workflow.tempGem or not settingBool('RezRestoreGem', true) then
        return finishWorkflow(workflow.terminalSuccess, workflow.terminalReason)
    end
    workflow.phase = 'restore_send'
    return false, 'restoring_gem'
end

local function loadRecoveryWorkflow()
    if Runtime.recoveryChecked then return end
    Runtime.recoveryChecked = true
    local file = io.open(recoveryPath(), 'r')
    if not file then return end
    local expiresAt = tonumber(file:read('*l')) or 0
    local slot = tonumber(file:read('*l')) or 0
    local originalId = tonumber(file:read('*l')) or 0
    local originalName = file:read('*l') or ''
    local rezName = file:read('*l') or ''
    file:close()

    if expiresAt < os.time() or slot <= 0 or gemName(slot) ~= rezName then
        clearRezLeaseAndRecovery()
        return
    end

    Runtime.workflow = {
        phase = 'restore_send',
        cleanupOnly = true,
        tempGem = true,
        tempGemSlot = slot,
        originalGemId = originalId,
        originalGemName = originalName,
        resource = { kind = 'restore', name = rezName },
        terminalSuccess = true,
        terminalReason = 'recovered_temporary_gem',
    }
    Runtime.workflow.action = cleanupAction(Runtime.workflow)
    echo('Recovered an interrupted rez gem swap; restoring gem %d', slot)
end

local function startWorkflow(action)
    local resource = {
        kind = action.resourceKind,
        name = action.resourceName or action.name,
        range = tonumber(action.resourceRange) or 100,
        castTimeMs = tonumber(action.resourceCastTimeMs) or 0,
        gemSlot = tonumber(action.resourceGemSlot),
        needsMemorize = action.needsMemorize == true,
        aaId = tonumber(action.aaId),
    }
    Runtime.workflow = {
        action = action,
        phase = 'target_send',
        targetId = tonumber(action.targetId) or 0,
        targetName = tostring(action.targetName or ''),
        targetClass = tostring(action.targetClass or ''),
        resource = resource,
        startedAtMs = nowMs(),
    }
    echo('Starting %s rez on %s using %s', lib.inCombat() and 'combat' or 'OOC',
        Runtime.workflow.targetName, resource.name)
end

local function stepWorkflow()
    local workflow = Runtime.workflow
    if not workflow then return true, 'no_workflow' end
    local now = nowMs()
    writeLease(workflow)

    if workflow.cancelReason and workflow.phase ~= 'restore_send' and workflow.phase ~= 'restore_wait' then
        return beginRestore(false, workflow.cancelReason)
    end

    if workflow.phase == 'restore_send' then
        writeLease(workflow)
        local slot = workflow.tempGemSlot
        local current = gemName(slot)
        local rezName = workflow.resource and workflow.resource.name or ''
        if current ~= rezName and current ~= workflow.originalGemName then
            return finishWorkflow(workflow.terminalSuccess,
                workflow.terminalReason .. ':restore_skipped_manual_change')
        end
        if current == workflow.originalGemName
            or (workflow.originalGemName == '' and gemId(slot) == 0) then
            return finishWorkflow(workflow.terminalSuccess, workflow.terminalReason)
        end
        if workflow.originalGemName ~= '' then
            mq.cmdf('/memspell %d "%s"', slot, workflow.originalGemName)
        else
            mq.cmdf('/nomodkey /notify CastSpellWnd CSPW_Spell%d rightmouseup', slot - 1)
        end
        workflow.deadlineMs = now + MEMORIZE_TIMEOUT_MS
        workflow.phase = 'restore_wait'
        return false, 'restore_sent'
    end

    if workflow.phase == 'restore_wait' then
        local restored = workflow.originalGemName ~= '' and gemName(workflow.tempGemSlot) == workflow.originalGemName
            or workflow.originalGemName == '' and gemId(workflow.tempGemSlot) == 0
        if restored then
            return finishWorkflow(workflow.terminalSuccess, workflow.terminalReason)
        end
        if now >= workflow.deadlineMs then
            return finishWorkflow(false, workflow.terminalReason .. ':restore_timeout')
        end
        return false, 'restoring_gem'
    end

    local spawn = corpseSpawn(workflow.targetId)
    if not spawn then return beginRestore(false, 'corpse_gone') end

    if workflow.phase == 'target_send' then
        mq.cmdf('/target id %d', workflow.targetId)
        workflow.deadlineMs = now + TARGET_TIMEOUT_MS
        workflow.phase = 'target_wait'
        return false, 'targeting_corpse'
    end

    if workflow.phase == 'target_wait' then
        if targetIs(workflow.targetId) then
            workflow.phase = 'drag_send'
        elseif now >= workflow.deadlineMs then
            return beginRestore(false, 'target_failed')
        end
        return false, 'targeting_corpse'
    end

    if workflow.phase == 'drag_send' then
        mq.cmd('/corpse')
        workflow.deadlineMs = now + 300
        workflow.phase = 'drag_wait'
        return false, 'dragging_corpse'
    end

    if workflow.phase == 'drag_wait' then
        if now < workflow.deadlineMs then return false, 'dragging_corpse' end
        local distance = corpseDistance(workflow.targetId) or 99999
        if distance <= (workflow.resource.range or 100) then
            workflow.phase = 'prepare_resource'
            return false, 'corpse_in_range'
        end
        if lib.inCombat() or not settingBool('RezNavigate', false) then
            return beginRestore(false, string.format('corpse_out_of_range:%.1f', distance))
        end
        if distance > settingNumber('RezNavMaxDistance', 250) then
            return beginRestore(false, string.format('corpse_beyond_nav_limit:%.1f', distance))
        end
        if not navPathExists(workflow.targetId) then
            return beginRestore(false, 'no_navigation_path')
        end
        mq.cmdf('/squelch /nav id %d distance=15 lineofsight=on log=off', workflow.targetId)
        workflow.navStarted = true
        workflow.deadlineMs = now + NAV_TIMEOUT_MS
        workflow.phase = 'nav_wait'
        return false, 'navigating_to_corpse'
    end

    if workflow.phase == 'nav_wait' then
        local distance = corpseDistance(workflow.targetId) or 99999
        if distance <= (workflow.resource.range or 100) then
            stopWorkflowNav(workflow)
            mq.cmdf('/target id %d', workflow.targetId)
            mq.cmd('/corpse')
            workflow.deadlineMs = now + 300
            workflow.phase = 'nav_drag_wait'
        elseif now >= workflow.deadlineMs or not navActive() then
            return beginRestore(false, 'navigation_failed_or_timed_out')
        end
        return false, 'navigating_to_corpse'
    end

    if workflow.phase == 'nav_drag_wait' then
        if now < workflow.deadlineMs then return false, 'dragging_after_navigation' end
        if (corpseDistance(workflow.targetId) or 99999) > (workflow.resource.range or 100) then
            return beginRestore(false, 'corpse_still_out_of_range')
        end
        workflow.phase = 'prepare_resource'
        return false, 'corpse_in_range'
    end

    if workflow.phase == 'prepare_resource' then
        if workflow.resource.kind == 'spell' and not findGemSlot(workflow.resource.name) then
            if lib.inCombat() then return beginRestore(false, 'cannot_memorize_rez_in_combat') end
            local slot = requestedRezGem()
            if not slot then return beginRestore(false, 'no_rez_gem_available') end
            workflow.tempGem = true
            workflow.tempGemSlot = slot
            workflow.originalGemId = gemId(slot)
            workflow.originalGemName = gemName(slot)
            workflow.lastLeaseAtMs = 0
            writeLease(workflow)
            writeRecovery(workflow)
            mq.cmdf('/memspell %d "%s"', slot, workflow.resource.name)
            workflow.deadlineMs = now + MEMORIZE_TIMEOUT_MS
            workflow.phase = 'memorize_wait'
            return false, 'memorizing_rez_spell'
        end
        workflow.phase = 'ready_wait'
        workflow.deadlineMs = now + READY_TIMEOUT_MS
        return false, 'waiting_for_resource'
    end

    if workflow.phase == 'memorize_wait' then
        if gemName(workflow.tempGemSlot) == workflow.resource.name then
            workflow.resource.gemSlot = workflow.tempGemSlot
            closeSpellBook()
            workflow.phase = 'ready_wait'
            workflow.deadlineMs = now + READY_TIMEOUT_MS
        elseif now >= workflow.deadlineMs then
            return beginRestore(false, 'memorize_timeout')
        end
        return false, 'memorizing_rez_spell'
    end

    if workflow.phase == 'ready_wait' then
        if resourceReady(workflow.resource) then
            mq.cmdf('/target id %d', workflow.targetId)
            workflow.deadlineMs = now + TARGET_TIMEOUT_MS
            workflow.phase = 'cast_target_wait'
        elseif now >= workflow.deadlineMs then
            return beginRestore(false, 'rez_resource_not_ready')
        end
        return false, 'waiting_for_resource'
    end

    if workflow.phase == 'cast_target_wait' then
        if not targetIs(workflow.targetId) then
            if now >= workflow.deadlineMs then return beginRestore(false, 'cast_target_failed') end
            return false, 'targeting_for_cast'
        end

        local SpellEvents = getSpellEvents()
        if SpellEvents and SpellEvents.resetResult then SpellEvents.resetResult() end
        workflow.castResultResetAt = os.clock()
        if workflow.resource.kind == 'spell' then
            local slot = findGemSlot(workflow.resource.name)
            if not slot then return beginRestore(false, 'rez_spell_missing_before_cast') end
            mq.cmdf('/cast %d', slot)
        elseif workflow.resource.kind == 'aa' then
            mq.cmdf('/alt activate %d', tonumber(workflow.resource.aaId) or 0)
        else
            mq.cmdf('/useitem "%s"', workflow.resource.name)
        end
        workflow.castIssuedAtMs = now
        workflow.deadlineMs = now + CAST_START_TIMEOUT_MS
        workflow.phase = 'cast_start_wait'
        return false, 'rez_command_sent'
    end

    if workflow.phase == 'cast_start_wait' then
        local failure = castFailureReason(workflow)
        if failure then return beginRestore(false, failure) end
        if lib.isCasting() then
            workflow.castObserved = true
            workflow.deadlineMs = now + math.max(3000,
                (workflow.resource.castTimeMs or 0) + CAST_TIMEOUT_MARGIN_MS)
            workflow.phase = 'cast_wait'
            return false, 'casting_rez'
        end
        if (workflow.resource.castTimeMs or 0) <= 250 and (now - workflow.castIssuedAtMs) >= 600 then
            return beginRestore(true, 'instant_rez_command_completed')
        end
        if now >= workflow.deadlineMs then
            return beginRestore(false, 'rez_cast_did_not_start')
        end
        return false, 'waiting_for_rez_cast_start'
    end

    if workflow.phase == 'cast_wait' then
        local failure = castFailureReason(workflow)
        if failure then return beginRestore(false, failure) end
        if not lib.isCasting() then
            return beginRestore(true, 'rez_cast_completed')
        end
        if now >= workflow.deadlineMs then
            mq.cmd('/stopcast')
            return beginRestore(false, 'rez_cast_timeout')
        end
        return false, 'casting_rez'
    end

    return beginRestore(false, 'unknown_workflow_phase:' .. tostring(workflow.phase))
end

local function sendTelemetry(self, force)
    if not self.peerActors or not self.peerActors.sendToLocalScript then return end
    local now = nowMs()
    if not force and (now - Runtime.lastTelemetryAtMs) < 500 then return end
    Runtime.lastTelemetryAtMs = now
    local workflow = Runtime.workflow
    self.peerActors.sendToLocalScript('sidekick-next', 'rez:telemetry', {
        reason = Runtime.reason,
        inCombat = lib.inCombat(),
        oocEnabled = settingBool('AutoRezOOC', true),
        combatEnabled = settingBool('AutoRezInCombat', false),
        oocMethod = oocMethod(),
        combatMethod = combatMethod(),
        targetName = workflow and workflow.targetName or Runtime.target and Runtime.target.memberName or '',
        targetClass = workflow and workflow.targetClass or Runtime.target and Runtime.target.classShort or '',
        corpseId = workflow and workflow.targetId or Runtime.target and Runtime.target.corpseId or 0,
        resourceKind = workflow and workflow.resource and workflow.resource.kind or Runtime.resource and Runtime.resource.kind or '',
        resourceName = workflow and workflow.resource and workflow.resource.name or Runtime.resource and Runtime.resource.name or '',
        phase = workflow and workflow.phase or 'idle',
        winner = Runtime.winner or '',
        lastResult = Runtime.lastResult,
        itemName = settingString('RezItemName', ''),
        updatedAt = os.time(),
    })
end

module.onTick = function(self)
    ensureActorCallbacks(self)
    ensureSpellEvents()
    pcall(mq.doevents)
    loadRecoveryWorkflow()
    prunePeerIntents()

    if Runtime.workflow then
        writeLease(Runtime.workflow)
        if Runtime.workflow.targetId and Runtime.workflow.targetId > 0
            and Runtime.workflow.resource and Runtime.workflow.phase ~= 'restore_send'
            and Runtime.workflow.phase ~= 'restore_wait'
            and not Runtime.workflow.cancelReason then
            local stillWins, coordinationReason = localWinsIntent({
                corpseId = Runtime.workflow.targetId,
                memberName = Runtime.workflow.targetName,
                classShort = Runtime.workflow.targetClass,
            }, Runtime.workflow.resource)
            local phase = Runtime.workflow.phase
            if phase ~= 'cast_start_wait' and phase ~= 'cast_wait'
                and not stillWins and coordinationReason
                and coordinationReason:find('peer_rez_claim:', 1, true) == 1 then
                Runtime.workflow.cancelReason = coordinationReason
            end
        end
        setReason('workflow:' .. tostring(Runtime.workflow.phase))
        self:sendNeed(true, 5000, Runtime.reason)
        sendTelemetry(self)
        return
    end

    Runtime.target = nil
    Runtime.resource = nil
    Runtime.pendingAction = nil

    local inCombat = lib.inCombat()
    if not Runtime.forceNext and inCombat and not settingBool('AutoRezInCombat', false) then
        clearLocalIntent('combat_rez_disabled')
        setReason('combat_rez_disabled')
        self:sendNeed(false, nil, Runtime.reason)
        sendTelemetry(self)
        return
    end
    if not Runtime.forceNext and not inCombat and not settingBool('AutoRezOOC', true) then
        clearLocalIntent('ooc_rez_disabled')
        setReason('ooc_rez_disabled')
        self:sendNeed(false, nil, Runtime.reason)
        sendTelemetry(self)
        return
    end

    local target, targetReason = findRezTarget(inCombat)
    if not target then
        clearLocalIntent(targetReason)
        setReason(targetReason)
        self:sendNeed(false, nil, Runtime.reason)
        sendTelemetry(self)
        return
    end
    Runtime.target = target

    local resource, resourceReason = selectResource(inCombat)
    if not resource then
        clearLocalIntent(resourceReason)
        setReason(resourceReason)
        self:sendNeed(false, nil, Runtime.reason)
        sendTelemetry(self)
        return
    end
    if resource.needsMemorize and isSpellBookOpen() then
        clearLocalIntent('manual_spellbook_open')
        setReason('manual_spellbook_open')
        self:sendNeed(false, nil, Runtime.reason)
        sendTelemetry(self)
        return
    end
    Runtime.resource = resource

    local wins, coordinationReason = localWinsIntent(target, resource)
    if not wins then
        setReason(coordinationReason)
        self:sendNeed(false, nil, Runtime.reason)
        sendTelemetry(self)
        return
    end

    Runtime.pendingAction = actionFor(target, resource)
    setReason(string.format('ready:%s:%s', resource.kind, target.memberName))
    self:sendNeed(true, 5000, Runtime.reason)
    sendTelemetry(self)
end

module.shouldAct = function()
    return Runtime.workflow ~= nil or Runtime.pendingAction ~= nil
end

module.getAction = function()
    if Runtime.workflow then return Runtime.workflow.action end
    return Runtime.pendingAction
end

module.executeAction = function(self)
    if not self:ownsClaim() then return false, 'no_ownership' end
    if not Runtime.workflow then
        -- Selection is recomputed every tick before execution. If settings,
        -- corpse state, or Actor election changed after the coordinator grant,
        -- release the now-stale claim without performing side effects.
        if not Runtime.pendingAction then
            return true, 'rez_action_stale:' .. tostring(Runtime.reason or 'unknown')
        end
        local owner = self.state and self.state.castOwner
        local action = owner and owner.action or Runtime.pendingAction
        if not action then return true, 'missing_rez_action' end
        startWorkflow(action)
    end
    return stepWorkflow()
end


module:enableUnifiedExecutor({
    dispatch = function(_, self)
        local completed, reason = self.executeAction(self)
        if completed then return true, reason or 'completed', 'none' end
        return true, reason or 'rez_workflow_started', 'custom'
    end,
    onTick = function(_, self)
        local completed, reason = self.executeAction(self)
        if completed then return true, reason or 'completed', 'completed' end
        return true, reason
    end,
    onFailure = function(_, _, _, result)
        if Runtime.workflow then
            Runtime.workflow.cancelReason = tostring(result and result.reason or 'executor_failed')
        end
    end,
    onCancel = function(_, _, _, result)
        if Runtime.workflow then
            Runtime.workflow.cancelReason = tostring(result and result.reason or 'executor_cancelled')
        end
    end,
})

module:enablePeerActors()

mq.bind('/sk_rez', function(cmd, arg)
    cmd = trim(cmd):lower()
    arg = trim(arg)
    if arg == '' and cmd:find('%s') then
        local first, rest = cmd:match('^(%S+)%s+(.+)$')
        cmd, arg = tostring(first or ''):lower(), trim(rest)
    end

    if cmd == '' or cmd == 'status' then
        local workflow = Runtime.workflow
        echo('running=%s priority=%s owns=%s reason=%s phase=%s target=%s(%s) resource=%s:%s winner=%s last=%s',
            tostring(module.running), tostring(module:isMyPriority()), tostring(module:ownsClaim()),
            Runtime.reason, workflow and workflow.phase or 'idle',
            workflow and workflow.targetName or Runtime.target and Runtime.target.memberName or '-',
            workflow and workflow.targetClass or Runtime.target and Runtime.target.classShort or '-',
            workflow and workflow.resource and workflow.resource.kind or Runtime.resource and Runtime.resource.kind or '-',
            workflow and workflow.resource and workflow.resource.name or Runtime.resource and Runtime.resource.name or '-',
            tostring(Runtime.winner or '-'), Runtime.lastResult)
        echo('OOC=%s/%s combat=%s/%s combatClasses=%s item="%s" autoMem=%s gem=%d restore=%s actors=%s nav=%s/%d debug=%s',
            tostring(settingBool('AutoRezOOC', true)), oocMethod(),
            tostring(settingBool('AutoRezInCombat', false)), combatMethod(),
            settingString('RezCombatTargetClasses', 'ALL'), settingString('RezItemName', ''),
            tostring(settingBool('RezAutoMemorize', true)), settingNumber('RezGem', 0),
            tostring(settingBool('RezRestoreGem', true)), tostring(settingBool('RezCoordinateActors', true)),
            tostring(settingBool('RezNavigate', false)), settingNumber('RezNavMaxDistance', 250),
            tostring(debugEnabled()))
    elseif cmd == 'debug' then
        local wanted = arg:lower()
        Runtime.runtimeDebug = wanted == 'on' or wanted == '1' or wanted == 'true'
        echo('Debug logging %s for this run', Runtime.runtimeDebug and 'enabled' or 'disabled')
    elseif cmd == 'retry' then
        Runtime.lastAttempt = {}
        Runtime.peerIntents = {}
        Runtime.pendingAction = nil
        clearLocalIntent('manual_retry')
        echo('Cleared rez suppression and Actor intent caches')
    elseif cmd == 'now' or cmd == 'rez' then
        Runtime.forcedTargetName = arg ~= '' and arg or nil
        Runtime.forceNext = true
        Runtime.lastAttempt = {}
        clearLocalIntent('manual_rez_request')
        echo('Manual rez requested%s', Runtime.forcedTargetName and (' for ' .. Runtime.forcedTargetName) or '')
    elseif cmd == 'stop' then
        if Runtime.workflow then
            Runtime.stopAfterCleanup = true
            Runtime.workflow.cancelReason = 'manual_stop'
            echo('Stop requested; restoring any temporary rez gem first')
        else
            module:stop()
            echo('Stop requested')
        end
    else
        echo('Usage: /sk_rez status | debug on|off | retry | now [group member] | stop')
    end
end)

if not RezData.isRezClass(myClassShort()) then
    return module
end

module:run(50)
return module
