-- F:/lua/sidekick-next/sk_healing.lua
-- Authoritative Healing Intelligence worker for SideKick.
-- Selects both emergency (priority 0) and normal (priority 1) actions so all
-- sensing, incoming-heal state, events, and persistence have one owner.

local mq = require('mq')
local lib = require('sidekick-next.sk_lib')
local ModuleBase = require('sidekick-next.sk_module_base')
local Core = require('sidekick-next.utils.core')
local Healing = require('sidekick-next.healing')
local HealerClasses = require('sidekick-next.utils.healer_classes')

-- Create module instance
local module = ModuleBase.create('healing', lib.Priority.HEALING)

local _coreLoaded = false
local _pendingAction = nil
local _pendingReason = nil
local _pendingKey = nil
local _pendingSinceMs = 0
local _intent = nil
local INTENT_REFRESH_MS = 500
local INTENT_SETTLE_NORMAL_MS = 100
local INTENT_SETTLE_EMERGENCY_MS = 50
local _manaBackoffUntilMs = 0
local _manaBackoffReason = nil

local MANA_BUFFER_FLAT = 5
local MANA_BUFFER_PCT_OF_COST = 0.03
local MANA_RETRY_BACKOFF_MS = 1500
local TELEMETRY_INTERVAL_MS = 1000
local _lastTelemetryAtMs = 0
local _forensicsDamageHooked = false
local _forensicsDamageBatch = {}
local _lastForensicsDamageSendAt = 0
local FORENSICS_DAMAGE_BATCH_MS = 250
local FORENSICS_DAMAGE_BATCH_MAX = 25

local function clearPendingAction()
    _pendingAction = nil
    _pendingKey = nil
    _pendingSinceMs = 0
end

local function commandEcho(fmt, ...)
    local msg
    if select('#', ...) > 0 then
        local ok, formatted = pcall(string.format, fmt, ...)
        msg = ok and formatted or tostring(fmt)
    else
        msg = tostring(fmt)
    end
    pcall(function()
        print(string.format('%s \ag[SK Healing]\ax %s', lib.timestampPrefix(), msg))
    end)
end

local function ensureCoreLoaded()
    if not _coreLoaded then
        Core.load()
        _coreLoaded = true
    end
end

local function isHealerClass()
    local me = mq.TLO.Me
    if not (me and me()) then return false end
    local cls = me.Class and me.Class.ShortName and me.Class.ShortName() or ''
    return HealerClasses.isSupported(cls)
end

local function syncSettings()
    ensureCoreLoaded()
    return Core.Settings or {}
end

local function attachForensicsDamageFeed()
    if _forensicsDamageHooked or not Healing.addIncomingDamageListener then return end
    _forensicsDamageHooked = Healing.addIncomingDamageListener(
        function(targetId, targetName, amount, source, dmgType)
            if Core.Settings and Core.Settings.DeathForensicsEnabled == false then return end
            if #_forensicsDamageBatch >= 200 then
                table.remove(_forensicsDamageBatch, 1)
            end
            _forensicsDamageBatch[#_forensicsDamageBatch + 1] = {
                targetId = tonumber(targetId) or 0,
                targetName = tostring(targetName or ''),
                amount = tonumber(amount) or 0,
                source = tostring(source or ''),
                dmgType = tostring(dmgType or ''),
            }
        end) == true
end

local function flushForensicsDamage(self, force)
    if #_forensicsDamageBatch == 0 or not self or not self.sendToLocalUi then return end
    local now = lib.getTimeMs()
    if not force and #_forensicsDamageBatch < FORENSICS_DAMAGE_BATCH_MAX
        and (now - _lastForensicsDamageSendAt) < FORENSICS_DAMAGE_BATCH_MS then
        return
    end
    local batch = _forensicsDamageBatch
    _forensicsDamageBatch = {}
    _lastForensicsDamageSendAt = now
    self:sendToLocalUi('forensics:damage', { events = batch })
end

local function ensureHealingInitialized(settings)
    if not settings or settings.DoHeals ~= true then return false end
    if not isHealerClass() then return false end
    if not Healing.isInitialized() then
        Healing.init()
    end
    if Healing.isInitialized() then attachForensicsDamageFeed() end
    return Healing.isInitialized()
end

local function isSpellReady(spellName)
    if not spellName or spellName == '' then return false end
    local me = mq.TLO.Me
    if not (me and me()) then return false end
    return lib.safeTLO(function() return me.SpellReady(spellName)() end, false) == true
end

local function targetId(targetId)
    if targetId <= 0 then return false end
    mq.cmdf('/target id %d', targetId)
    mq.delay(50)
    local currentTarget = lib.safeNum(function() return mq.TLO.Target.ID() end, 0)
    return currentTarget == targetId
end

local function spellManaCost(spellName)
    local spell = spellName and mq.TLO.Spell(spellName) or nil
    if not (spell and spell()) then return 0 end
    return tonumber(spell.Mana()) or 0
end

local function currentMana()
    local me = mq.TLO.Me
    if not (me and me()) then return 0 end
    return lib.safeNum(function() return me.CurrentMana() end, 0)
end

local function manaBufferFor(cost)
    cost = tonumber(cost) or 0
    if cost <= 0 then return 0 end
    return math.max(MANA_BUFFER_FLAT, math.ceil(cost * MANA_BUFFER_PCT_OF_COST))
end

local function manaReadyForSpell(spellName)
    local cost = spellManaCost(spellName)
    if cost <= 0 then return true, 'no_mana_cost', 0, 0, currentMana() end
    local buffer = manaBufferFor(cost)
    local mana = currentMana()
    if mana < (cost + buffer) then
        return false, string.format('mana_wait:%d/%d+%d', mana, cost, buffer), cost, buffer, mana
    end
    return true, 'mana_ready', cost, buffer, mana
end

local function setManaBackoff(reason)
    _manaBackoffUntilMs = lib.getTimeMs() + MANA_RETRY_BACKOFF_MS
    _manaBackoffReason = reason or 'insufficient_mana'
end

local function copyAnalyticsStats(stats)
    local snapshot = {
        totalCasts = tonumber(stats.totalCasts) or 0,
        completedCasts = tonumber(stats.completedCasts) or 0,
        duckedCasts = tonumber(stats.duckedCasts) or 0,
        interruptedCasts = tonumber(stats.interruptedCasts) or 0,
        totalHealed = tonumber(stats.totalHealed) or 0,
        totalOverheal = tonumber(stats.totalOverheal) or 0,
        overHealPct = tonumber(stats.overHealPct) or 0,
        totalManaSpent = tonumber(stats.totalManaSpent) or 0,
        healPerMana = tonumber(stats.healPerMana) or 0,
        duckSavingsEstimate = tonumber(stats.duckSavingsEstimate) or 0,
        incomingHealHonored = tonumber(stats.incomingHealHonored) or 0,
        incomingHealExpired = tonumber(stats.incomingHealExpired) or 0,
        hotTicksLanded = tonumber(stats.hotTicksLanded) or 0,
        hotTicksUseless = tonumber(stats.hotTicksUseless) or 0,
        hotTicksMissed = tonumber(stats.hotTicksMissed) or 0,
        hotTotalHealed = tonumber(stats.hotTotalHealed) or 0,
        bySpell = {},
    }
    for spellName, data in pairs(stats.bySpell or {}) do
        snapshot.bySpell[tostring(spellName)] = {
            casts = tonumber(data.casts) or 0,
            healed = tonumber(data.healed) or 0,
            overhealed = tonumber(data.overhealed) or 0,
            ducked = tonumber(data.ducked) or 0,
            manaSpent = tonumber(data.manaSpent) or 0,
            hotTicks = tonumber(data.hotTicks) or 0,
            hotTicksUseless = tonumber(data.hotTicksUseless) or 0,
            hotTicksMissed = tonumber(data.hotTicksMissed) or 0,
            minHeal = tonumber(data.minHeal),
            maxHeal = tonumber(data.maxHeal) or 0,
            critCount = tonumber(data.critCount) or 0,
        }
    end
    return snapshot
end

local function copyHealingTargets()
    local rows = {}
    local monitor = Healing.TargetMonitor
    if not monitor or not monitor.getAllTargets then return rows end
    for _, target in pairs(monitor.getAllTargets() or {}) do
        table.insert(rows, {
            id = tonumber(target.id) or 0,
            name = tostring(target.name or ''),
            role = tostring(target.role or ''),
            pctHP = tonumber(target.pctHP) or 100,
            currentHP = tonumber(target.currentHP) or 0,
            maxHP = tonumber(target.maxHP) or 0,
            maxHPKnown = target.maxHPKnown == true,
            maxHPSource = tostring(target.maxHPSource or 'unknown'),
            deficit = tonumber(target.deficit) or 0,
            incomingTotal = tonumber(target.incomingTotal) or 0,
            recentDps = tonumber(target.recentDps) or 0,
        })
    end
    table.sort(rows, function(a, b)
        if a.pctHP ~= b.pctHP then return a.pctHP < b.pctHP end
        return a.name < b.name
    end)
    return rows
end

local function copyLastSelection()
    local selector = Healing.HealSelector
    local selection = selector and selector.getLastTargetScores and selector.getLastTargetScores() or nil
    if type(selection) ~= 'table' then return nil end
    local winnerScore = tonumber(selection.winnerScore) or 0
    if winnerScore ~= winnerScore or winnerScore == math.huge or winnerScore == -math.huge then
        winnerScore = 0
    end
    local copy = {
        kind = tostring(selection.kind or ''),
        targetName = tostring(selection.targetName or ''),
        deficit = tonumber(selection.deficit) or 0,
        pctHP = tonumber(selection.pctHP) or 0,
        maxHP = tonumber(selection.maxHP) or 0,
        maxHPKnown = selection.maxHPKnown == true,
        maxHPSource = tostring(selection.maxHPSource or 'unknown'),
        recentDps = tonumber(selection.recentDps) or 0,
        winner = tostring(selection.winner or ''),
        winnerScore = winnerScore,
        at = tonumber(selection.at) or 0,
        scores = {},
    }
    for _, score in ipairs(selection.scores or {}) do
        table.insert(copy.scores, {
            spell = tostring(score.spell or ''),
            score = tonumber(score.score) or 0,
            category = tostring(score.category or ''),
            expected = tonumber(score.expected) or 0,
            mana = tonumber(score.mana) or 0,
            castTime = tonumber(score.castTime) or 0,
        })
    end
    return copy
end

local function copyCombatState()
    local assessor = Healing.CombatAssessor
    local state = assessor and assessor.getState and assessor.getState() or {}
    return {
        inCombat = state.inCombat == true,
        survivalMode = state.survivalMode == true,
        highPressure = state.highPressure == true,
        fightPhase = tostring(state.fightPhase or 'none'),
        activeMobCount = tonumber(state.activeMobCount) or 0,
        totalIncomingDps = tonumber(state.totalIncomingDps) or 0,
    }
end

local function maybeSendAnalyticsTelemetry(peerActors)
    local now = lib.getTimeMs()
    if (now - _lastTelemetryAtMs) < TELEMETRY_INTERVAL_MS then return end
    if not peerActors or not peerActors.sendTelemetryToScript then return end
    local analytics = Healing.Analytics
    if not analytics or not analytics.getStats then return end

    _lastTelemetryAtMs = now
    peerActors.sendTelemetryToScript('sidekick-next', 'healing', 'heal:telemetry', {
        character = mq.TLO.Me.CleanName() or mq.TLO.Me.Name() or '',
        zone = mq.TLO.Zone and mq.TLO.Zone.ShortName and mq.TLO.Zone.ShortName() or '',
        sentAtMs = now,
        duration = analytics.getSessionDuration and analytics.getSessionDuration() or 0,
        efficiencyPct = analytics.getEfficiencyPct and analytics.getEfficiencyPct() or 100,
        stats = copyAnalyticsStats(analytics.getStats()),
        targets = copyHealingTargets(),
        combatState = copyCombatState(),
        lastSelection = copyLastSelection(),
        lastAction = Healing.HealSelector and Healing.HealSelector.getLastAction
            and Healing.HealSelector.getLastAction() or nil,
    })
end

local function actionPriority(action)
    return action and action.tier == 'emergency' and lib.Priority.EMERGENCY or lib.Priority.HEALING
end

local function intentKey(action)
    if not action then return nil end
    return string.format('%s:%s:%d', tostring(action.tier or 'heal'),
        tostring(action.spellName or action.name or ''), tonumber(action.claimTargetId or action.targetId) or 0)
end

local function peerClaimReason(prefix, winner)
    winner = type(winner) == 'table' and winner or {}
    return string.format('%s_%s:peerAge=%sms:lease=%sms',
        tostring(prefix or 'claimed_by'),
        tostring(winner.from or 'peer'),
        tostring(winner.peerAgeMs or '?'),
        tostring(winner.leaseRemainingMs or '?'))
end

local function distributedIntentReady(action, ttlMs)
    if Healing.Config and Healing.Config.broadcastEnabled == false then
        _intent = nil
        return true
    end
    local now = lib.getTimeMs()
    local key = intentKey(action)
    if not key then
        _intent = nil
        return false, 'invalid_intent'
    end

    if not _intent or _intent.key ~= key then
        _intent = { key = key, announcedAt = now, lastBroadcastAt = now }
        Healing.broadcastClaim(action, ttlMs)
        return false, 'claim_settling'
    end

    if (now - _intent.lastBroadcastAt) >= INTENT_REFRESH_MS then
        Healing.broadcastClaim(action, ttlMs)
        _intent.lastBroadcastAt = now
    end

    local settleMs = action.tier == 'emergency' and INTENT_SETTLE_EMERGENCY_MS or INTENT_SETTLE_NORMAL_MS
    if (now - _intent.announcedAt) < settleMs then
        return false, 'claim_settling'
    end

    local won, winner = Healing.isClaimWinner(action)
    if not won then
        return false, peerClaimReason('claimed_by', winner)
    end
    return true
end

local function targetCastable(spellName, id)
    local spawn = mq.TLO.Spawn(id)
    if not spawn or not spawn() then return false, 'target_missing' end
    local dead = lib.safeTLO(function() return spawn.Dead() end, false) == true
    local hp = lib.safeNum(function() return spawn.PctHPs() end, 0)
    if dead or hp <= 0 then return false, 'target_dead' end

    local myId = lib.safeNum(function() return mq.TLO.Me.ID() end, 0)
    if id ~= myId then
        local spell = mq.TLO.Spell(spellName)
        local range = spell and spell() and lib.safeNum(function() return spell.Range() end, 0) or 0
        local distance = lib.safeNum(function() return spawn.Distance3D() end, 0)
        if range > 0 and distance > (range + 5) then return false, 'target_out_of_range' end
        local los = lib.safeTLO(function() return spawn.LineOfSight() end, nil)
        if los == false then return false, 'target_no_los' end
    end
    return true
end

local function interruptAndConfirm(self, castInfo, reason)
    if not self:ownsLease() then return false end
    Healing.cancelHealCast(castInfo, reason)
    local deadline = lib.getTimeMs() + 750
    while lib.getTimeMs() < deadline and lib.isCasting() do
        self:renewLease()
        mq.delay(25)
    end
    if lib.isCasting() then
        lib.log('warn', self.name, 'Interrupt was not confirmed: %s', tostring(reason))
        return false
    end
    return true
end

-------------------------------------------------------------------------------
-- Module Callbacks
-------------------------------------------------------------------------------

module.onTick = function(self)
    local settings = syncSettings()
    if not settings then
        clearPendingAction()
        self:setIntent(false, nil, 'no_settings')
        return
    end

    if settings.UseSpells == false then
        clearPendingAction()
        self:setIntent(false, nil, 'spells_disabled')
        return
    end

    if settings.DoHeals ~= true then
        clearPendingAction()
        self:setIntent(false, nil, 'heals_disabled')
        return
    end

    if not isHealerClass() then
        clearPendingAction()
        self:setIntent(false, nil, 'not_healer')
        return
    end

    if not ensureHealingInitialized(settings) then
        clearPendingAction()
        self:setIntent(false, nil, 'init_failed')
        return
    end

    Healing.tickSensors({ readOnly = true })
    flushForensicsDamage(self, false)
    maybeSendAnalyticsTelemetry(self.peerActors)

    if self:ownsLease() then
        clearPendingAction()
        self:setIntent(true, 5000, 'owns_lease')
        return
    end

    local action, reason = Healing.buildHealAction({
        ignoreSpellEngine = true,
        skipIfCasting = false,
    })

    local needs = action ~= nil
    local intentTtlMs = nil
    if needs then
        if lib.getTimeMs() < (_manaBackoffUntilMs or 0) then
            clearPendingAction()
            _pendingReason = _manaBackoffReason or 'mana_backoff'
            self:setIntent(false, nil, _pendingReason)
            return
        end
        local manaOk, manaReason = manaReadyForSpell(action.spellName or action.name)
        if not manaOk then
            clearPendingAction()
            _pendingReason = manaReason
            self:setIntent(false, nil, manaReason)
            return
        end
        local castInfo = Healing.prepareHealCast(action)
        if castInfo and castInfo.castTimeMs then
            intentTtlMs = castInfo.castTimeMs + 1500
        else
            intentTtlMs = 1000
        end
        local ready, intentReason = distributedIntentReady(action, intentTtlMs)
        if not ready then
            clearPendingAction()
            _pendingReason = intentReason
            self:setIntent(false, nil, intentReason)
            return
        end
    else
        _intent = nil
    end
    local nextPendingKey = action and intentKey(action) or nil
    if nextPendingKey ~= _pendingKey then
        _pendingKey = nextPendingKey
        _pendingSinceMs = nextPendingKey and lib.getTimeMs() or 0
    end
    _pendingAction = action
    _pendingReason = reason
    self:setIntent(needs, intentTtlMs, reason or 'no_action')
end

module.shouldAct = function(self)
    if not self:hasValidState() then return false end
    return _pendingAction ~= nil
end

module.getAction = function(self)
    local action = _pendingAction
    if not action then return nil end

    local spellName = action.spellName
    local targetIdVal = tonumber(action.targetId) or 0

    if not spellName or targetIdVal <= 0 then
        _pendingReason = not spellName and 'invalid_action_spell' or 'invalid_action_target_id'
        clearPendingAction()
        self:setIntent(false, nil, _pendingReason)
        return nil
    end

    return {
        kind = lib.ActionKind.CAST_SPELL,
        name = spellName,
        spellName = spellName,
        targetId = targetIdVal,
        targetName = action.targetName,
        tier = action.tier or 'heal',
        isHoT = action.isHoT == true,
        expected = action.expected,
        details = action.details,
        groupHotTargets = action.groupHotTargets,
        groupHotTargetIds = action.groupHotTargetIds,
        claimTargetId = action.claimTargetId,
        idempotencyKey = string.format('heal:%s:%d', action.tier or 'heal', targetIdVal),
        reason = action.reason or _pendingReason or 'heal',
        castStartTimeoutMs = 4000,
        timeoutMs = 20000,
        castOptions = {
            spellCategory = 'heal',
            sourceLayer = 'healing',
            urgency = action.tier == 'emergency' and 'emergency' or nil,
            priority = action.tier == 'emergency' and lib.Priority.EMERGENCY or lib.Priority.HEALING,
            maxRetries = 0,
        },
    }
end

module.getDiagnosticAction = function(self)
    local action = _pendingAction
    if not action then return nil end
    local phase = 'waiting_priority'
    if self.requestPending then
        phase = 'lease_pending'
    elseif self:canRequestLease() then
        phase = 'awaiting_lease'
    end
    return {
        active = false,
        phase = phase,
        kind = lib.ActionKind.CAST_SPELL,
        name = action.spellName or action.name or '?',
        targetId = tonumber(action.targetId) or 0,
        reason = _pendingReason or action.reason or 'heal',
        elapsedMs = _pendingSinceMs > 0 and (lib.getTimeMs() - _pendingSinceMs) or 0,
    }
end

module.executeAction = function(self)
    if not self:ownsLease() then
        return false, 'no_ownership'
    end

    local action = self:getLeaseAction()
    if not action then
        return false, 'no_action'
    end

    local settings = syncSettings()
    if not settings or settings.UseSpells == false or settings.DoHeals ~= true then
        return true, 'disabled'
    end

    if not ensureHealingInitialized(settings) then
        return true, 'not_ready'
    end

    local spellName = action.spellName or action.name
    local targetIdVal = tonumber(action.targetId) or 0
    if not spellName or targetIdVal <= 0 then
        return true, 'invalid_action'
    end

    if not isSpellReady(spellName) then
        lib.log('debug', self.name, 'Spell not ready: %s', spellName)
        -- Release and re-evaluate instead of pinning healing during a GCD.
        return true, 'spell_not_ready'
    end

    local manaOk, manaReason, manaCost, manaBuffer, mana = manaReadyForSpell(spellName)
    if not manaOk then
        setManaBackoff(manaReason)
        lib.log('debug', self.name, 'Mana not stable for %s: current=%d cost=%d buffer=%d',
            tostring(spellName), mana or 0, manaCost or 0, manaBuffer or 0)
        return true, manaReason
    end

    local stillWinner, winner = Healing.isClaimWinner(action)
    if not stillWinner then
        return true, peerClaimReason('claim_lost_to', winner)
    end

    local castInfo = Healing.prepareHealCast(action)
    if not castInfo then
        return true, 'cast_info_failed'
    end

    local castable, castableReason = targetCastable(spellName, targetIdVal)
    if not castable then
        lib.log('debug', self.name, 'Cannot cast %s on %d: %s', spellName, targetIdVal, castableReason)
        return true, castableReason
    end

    Healing.broadcastClaim(action, (castInfo.castTimeMs or 2000) + 1500)
    Healing.setCastInfo(castInfo)

    if not targetId(targetIdVal) then
        Healing.clearCastInfo()
        lib.log('warn', self.name, 'Target mismatch for %s (%d)', spellName, targetIdVal)
        return true, 'target_failed'
    end

    lib.log('info', self.name, 'Casting %s on %d', spellName, targetIdVal)
    mq.cmdf('/cast "%s"', spellName)
    mq.delay(100)

    if not lib.isCasting() then
        Healing.clearCastInfo()
        local postMana = currentMana()
        local cost = spellManaCost(spellName)
        if cost > 0 and postMana < (cost + manaBufferFor(cost)) then
            setManaBackoff('insufficient_mana_after_cast_request')
            lib.log('warn', self.name, 'Cast did not start due to unstable mana: %s mana=%d cost=%d',
                tostring(spellName), postMana, cost)
            return true, 'insufficient_mana'
        end
        lib.log('warn', self.name, 'Cast did not start: %s', spellName)
        return true, 'cast_failed'
    end

    Healing.registerHealCast(castInfo)

    local startTime = lib.getTimeMs()
    local maxWait = (castInfo.castTimeMs or 2000) + 1500

    while lib.isCasting() do
        mq.delay(50)

        -- Keep the single healing brain current while it owns the casting
        -- coroutine. This preserves emergency preemption without a second VM.
        Healing.tickSensors({ readOnly = true })
        maybeSendAnalyticsTelemetry(self.peerActors)

        if castInfo.tier ~= 'emergency' then
            local emergencyAction = Healing.buildHealAction({
                onlyEmergency = true,
                ignoreSpellEngine = true,
                skipIfCasting = false,
            })
            if emergencyAction and interruptAndConfirm(self, castInfo, 'emergency_switch') then
                return true, 'preempted_for_emergency'
            end
        end

        local ducked, duckReason = Healing.checkDucking({ deferCancel = true })
        if ducked then
            if interruptAndConfirm(self, castInfo, string.format('duck_%s', tostring(duckReason or 'heal'))) then
                return true, 'ducked'
            end
        end

        self:renewLease()
        if not self:ownsLease() then
            lib.log('warn', self.name, 'Lost ownership during cast')
            if not lib.isCasting() then break end
        end

        if (lib.getTimeMs() - startTime) > maxWait then
            lib.log('warn', self.name, 'Cast timeout')
            if interruptAndConfirm(self, castInfo, 'cast_timeout') then
                return true, 'cast_timeout'
            end
            maxWait = maxWait + 1000
        end
    end

    -- The cast bar ending does not distinguish a landing from a fizzle.
    lib.log('info', self.name, 'Cast ended: %s', spellName)
    return true, 'cast_ended'
end


-- The legacy callback above is retained only as migration reference and must
-- never be selected by ModuleBase.
module.executeAction = nil
module:enableUnifiedExecutor({
    preflight = function(action)
        local settings = syncSettings()
        if not settings or settings.UseSpells == false or settings.DoHeals ~= true then
            return false, 'disabled'
        end
        if not ensureHealingInitialized(settings) then return false, 'not_ready' end

        local spellName = action.spellName or action.name
        local targetIdVal = tonumber(action.targetId) or 0
        if not spellName or targetIdVal <= 0 then return false, 'invalid_action' end
        if not isSpellReady(spellName) then return false, 'spell_not_ready' end

        local manaOk, manaReason = manaReadyForSpell(spellName)
        if not manaOk then
            setManaBackoff(manaReason)
            return false, manaReason
        end

        local stillWinner, winner = Healing.isClaimWinner(action)
        if not stillWinner then
            return false, peerClaimReason('claim_lost_to', winner)
        end

        local castInfo = Healing.prepareHealCast(action)
        if not castInfo then return false, 'cast_info_failed' end
        local castable, castableReason = targetCastable(spellName, targetIdVal)
        if not castable then return false, castableReason end

        action._executorCastInfo = castInfo
        action._healRegistered = false
        Healing.broadcastClaim(action, (castInfo.castTimeMs or 2000) + 1500)
        Healing.setCastInfo(castInfo)
        return true
    end,
    onTick = function(action, self, job)
        local castInfo = action._executorCastInfo
        if job.phase ~= 'running' or not castInfo then return true end

        if action._healRegistered ~= true then
            Healing.registerHealCast(castInfo)
            action._healRegistered = true
        end

        Healing.tickSensors({ readOnly = true })
        maybeSendAnalyticsTelemetry(self and self.peerActors)

        if castInfo.tier ~= 'emergency' then
            local emergencyAction = Healing.buildHealAction({
                onlyEmergency = true,
                ignoreSpellEngine = true,
                skipIfCasting = false,
            })
            if emergencyAction and action._interruptRequested ~= true then
                action._interruptRequested = true
                Healing.cancelHealCast(castInfo, 'preempted_for_emergency')
                return true, 'preempted_for_emergency', 'interrupting'
            end
        end

        local ducked, duckReason = Healing.checkDucking({ deferCancel = true })
        if ducked and action._interruptRequested ~= true then
            local reason = 'duck_' .. tostring(duckReason or 'heal')
            action._interruptRequested = true
            Healing.cancelHealCast(castInfo, reason)
            return true, reason, 'interrupting'
        end
        return true
    end,
    onComplete = function(action)
        lib.log('info', module.name, 'Cast ended: %s', tostring(action.spellName or action.name))
    end,
    onFailure = function(action, _, _, result)
        local castInfo = action and action._executorCastInfo
        if castInfo and action._healRegistered then
            Healing.cancelHealCast(castInfo, result and result.reason or 'executor_failed')
        elseif castInfo then
            Healing.clearCastInfo()
        end
    end,
    onCancel = function(action, _, _, result)
        local castInfo = action and action._executorCastInfo
        if castInfo and action._healRegistered then
            Healing.cancelHealCast(castInfo, result and result.reason or 'executor_cancelled')
        elseif castInfo then
            Healing.clearCastInfo()
        end
    end,
})

-------------------------------------------------------------------------------
-- Command Binding
-------------------------------------------------------------------------------

mq.bind('/sk_healing', function(cmd)
    cmd = tostring(cmd or ''):lower():match('^%s*(.-)%s*$')
    if cmd == 'stop' then
        module:stop()
        lib.log('info', module.name, 'Stop requested')
        commandEcho('Stop requested')
    elseif cmd == 'status' then
        local settings = Core.Settings or {}
        local action = _pendingAction
        commandEcho('running=%s hasState=%s tier=%s leasePending=%s requestId=%s requestSend=%s requestSendError=%s requestAge=%dms ownsLease=%s useSpells=%s doHeals=%s pending=%s target=%s targetId=%s actionTier=%s pendingMs=%d reason=%s manaBackoffMs=%d',
            tostring(module.running),
            tostring(module:hasValidState()),
            tostring(module.priority),
            tostring(module.requestPending),
            tostring(module.currentRequestId or 'none'),
            tostring(module.lastRequestSendOk),
            tostring(module.lastRequestSendError or '-'),
            module.requestLastSentAt > 0 and math.max(0, lib.getTimeMs() - module.requestLastSentAt) or 0,
            tostring(module:ownsLease()),
            tostring(settings.UseSpells ~= false),
            tostring(settings.DoHeals == true),
            tostring(action and action.spellName or 'none'),
            tostring(action and (action.targetName or action.targetId) or 'none'),
            tostring(action and action.targetId or 'none'),
            tostring(action and action.tier or 'none'),
            _pendingSinceMs > 0 and math.max(0, lib.getTimeMs() - _pendingSinceMs) or 0,
            tostring(_pendingReason),
            math.max(0, (_manaBackoffUntilMs or 0) - lib.getTimeMs()))
        local selector = Healing.HealSelector
        local selection = selector and selector.getLastTargetScores and selector.getLastTargetScores() or nil
        if selection then
            commandEcho('selection=%s target=%s hp=%d%% maxHP=%d known=%s source=%s deficit=%d dps=%.0f score=%.2f',
                tostring(selection.winner or 'none'), tostring(selection.targetName or 'none'),
                tonumber(selection.pctHP) or 0, tonumber(selection.maxHP) or 0,
                tostring(selection.maxHPKnown == true), tostring(selection.maxHPSource or 'unknown'),
                tonumber(selection.deficit) or 0, tonumber(selection.recentDps) or 0,
                tonumber(selection.winnerScore) or 0)
        end
    elseif cmd == 'rescan' then
        local config = Healing.Config
        if not config then
            local ok, loaded = pcall(require, 'sidekick-next.healing.config')
            if ok then
                config = loaded
                config.load()
            end
        end

        if not config or not config.mergeFromSpellBar then
            commandEcho('Rescan unavailable: healing configuration failed to load')
            return
        end

        local added, additions, scanned, persisted, observed = config.mergeFromSpellBar()
        if added > 0 then
            local labels = {}
            for _, addition in ipairs(additions) do
                table.insert(labels, string.format('%s -> %s', addition.name, addition.category))
            end
            if persisted then
                commandEcho('Rescan checked %d gems and added %d heal(s): %s',
                    scanned, added, table.concat(labels, ', '))
            else
                commandEcho('Rescan added %d heal(s) in memory but could not save the profile: %s',
                    added, table.concat(labels, ', '))
            end
        else
            local details = {}
            for _, spell in ipairs(observed or {}) do
                local status = spell.status == 'configured' and 'already configured'
                    or spell.status == 'not_heal' and 'not recognized as heal'
                    or tostring(spell.status)
                table.insert(details, string.format('%s=%s', spell.name, status))
            end
            commandEcho('Rescan checked %d gems; nothing added (%s)',
                scanned, table.concat(details, ', '))
        end
    else
        commandEcho('Usage: /sk_healing status|rescan|stop')
    end
end)

-------------------------------------------------------------------------------
-- Run
-------------------------------------------------------------------------------

module:enablePeerActors()
module:run(50)
if not module.componentMode then
    flushForensicsDamage(module, true)
    if Healing and Healing.shutdown then
        Healing.shutdown()
    end
end

return module
