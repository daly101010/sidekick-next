-- Coordinated tank worker.
--
-- Keeps a stable primary kill target for assisters while temporarily using a
-- separate recovery target for loose-mob taunts and hate tools. All target,
-- cast, discipline, AA, melee-skill, attack, and stick side effects occur only
-- after a coordinator ACTION claim.

local mq = require('mq')
local lib = require('sidekick-next.sk_lib')
local ModuleBase = require('sidekick-next.sk_module_base')
local Cache = require('sidekick-next.utils.runtime_cache')
local Targeting = require('sidekick-next.utils.targeting')
local Aggro = require('sidekick-next.utils.aggro')
local Engine = require('sidekick-next.utils.discipline_engine')
local Actors = require('sidekick-next.utils.actors_coordinator')

local module = ModuleBase.create('tank', lib.Priority.DPS)
module:enablePeerActors()

local TANK_CLASSES = { WAR = true, PAL = true, SHD = true }
local PRIMARY_BROADCAST_MS = 1000
local TARGET_SETTLE_MS = 150
local TAUNT_TIMEOUT_MS = 3500

local _settings = {}
local _classConfig = nil
local _classShort = ''
local _primaryId = 0
local _primaryName = ''
local _pending = nil
local _lastReason = 'init'
local _lastBroadcastAt = 0
local _lastEngageAt = 0
local _lastAction = 'none'
-- One recovery cycle per add: taunt, then hate tools until expended, then the
-- primary gets all attention until Taunt is ready again.
local _recovery = { mobId = 0, spent = false }
local _forceEngage = false

local function safe(fn, fallback)
    local ok, value = pcall(fn)
    if not ok or value == nil then return fallback end
    return value
end

local function echo(fmt, ...)
    local ok, text = pcall(string.format, fmt, ...)
    print(string.format('\ag[SK Tank]\ax %s', ok and text or tostring(fmt)))
end

--- Stop navigation only when a path is actually active. Taunts inside melee
--- range never start nav, and an unconditional /nav stop on every taunt exit
--- spams "[Nav] No navigation path currently active".
local function navStop()
    if safe(function() return mq.TLO.Navigation.Active() end, false) == true then
        mq.cmd('/nav stop')
    end
end

local function loadClassConfig()
    local classShort = tostring(safe(function() return mq.TLO.Me.Class.ShortName() end, '') or ''):upper()
    if classShort == _classShort and _classConfig then return end
    _classShort = classShort
    local ok, config = pcall(require, 'data.class_configs.' .. classShort)
    _classConfig = ok and config or nil
end

local function refreshSettings()
    _settings = lib.getSettings() or _settings or {}
    Cache.setSettings(_settings)
    loadClassConfig()
    return tostring(_settings.CombatMode or 'off'):lower() == 'tank'
        and tostring(_settings.AutomationLevel or 'auto'):lower() ~= 'manual'
        and TANK_CLASSES[_classShort] == true
end

local function spawnById(id)
    id = tonumber(id) or 0
    if id <= 0 then return nil end
    local spawn = mq.TLO.Spawn(id)
    if not (spawn and spawn()) then return nil end
    return spawn
end

local function validNpc(id, allowMezzed)
    local spawn = spawnById(id)
    if not spawn then return nil end
    if tostring(safe(function() return spawn.Type() end, '') or ''):lower() ~= 'npc' then return nil end
    if safe(function() return spawn.Dead() end, false) == true then return nil end
    if (tonumber(safe(function() return spawn.PctHPs() end, 0)) or 0) <= 0 then return nil end
    if not allowMezzed and Targeting.isMezzed(spawn) then return nil end
    return spawn
end

local function haterRow(id)
    for _, row in ipairs(Cache.xtarget.haters or {}) do
        if tonumber(row.id) == tonumber(id) then return row end
    end
    return nil
end

local function choosePrimary()
    local mode = tostring(_settings.TankTargetMode or 'auto'):lower()
    if mode == 'manual' then
        local currentId = tonumber(safe(function() return mq.TLO.Target.ID() end, 0)) or 0
        local current = validNpc(currentId, false)
        -- Manual mode still requires a hostile target: a stray click on a
        -- passive NPC must not start a fight.
        if current and (haterRow(currentId)
            or safe(function() return current.Aggressive() end, false) == true) then
            return current
        end
        return validNpc(_primaryId, false)
    end

    local engageRange = tonumber(_settings.TankEngageRange) or 125

    -- RG-style target stability: keep the kill target while it remains a live,
    -- unmezzed hater. Aggro recovery uses a separate target and never replaces
    -- it. Grace of 1.5x engage range so a mob drifting at the boundary doesn't
    -- thrash the primary; beyond that the fight has genuinely moved away.
    local current = validNpc(_primaryId, false)
    if current then
        local row = haterRow(_primaryId)
        if row and (tonumber(row.distance) or 999) <= engageRange * 1.5 then
            return current
        end
    end

    local forced = tostring(_settings.TargetingForcedTargetName or '')
    if forced ~= '' then
        local forcedSpawn = mq.TLO.Spawn('npc =' .. forced)
        if forcedSpawn and forcedSpawn() and not Targeting.isMezzed(forcedSpawn) then
            return forcedSpawn
        end
    end

    local best, bestScore = nil, -math.huge
    for _, row in ipairs(Cache.xtarget.haters or {}) do
        -- Cache.isMobMezzed consults the mezzer's broadcast mez list; the
        -- row.mezzed flag and Spawn.Mezzed only work for the current target.
        -- Engage range keeps the tank from sticking off toward a hater that
        -- aggroed from across the camp.
        if not row.mezzed and not Cache.isMobMezzed(row.id)
            and (tonumber(row.distance) or 999) <= engageRange then
            local spawn = validNpc(row.id, false)
            if spawn then
                local score = (row.targetingMe and 500 or 0) + (100 - (tonumber(row.hp) or 100))
                if safe(function() return spawn.Named() end, false) == true then score = score + 100 end
                if score > bestScore then
                    best, bestScore = spawn, score
                end
            end
        end
    end
    return best
end

local function setPrimary(spawn)
    local id = spawn and tonumber(safe(function() return spawn.ID() end, 0)) or 0
    local name = spawn and tostring(safe(function() return spawn.CleanName() end, '') or '') or ''
    if id == _primaryId then return false end
    _primaryId, _primaryName = id, name
    _lastBroadcastAt = 0
    return true
end

local function broadcastPrimary(force)
    if _primaryId <= 0 then return end
    local now = lib.getTimeMs()
    if not force and (now - _lastBroadcastAt) < PRIMARY_BROADCAST_MS then return end
    _lastBroadcastAt = now
    Actors.broadcastTargetPrimary(_primaryId, _primaryName)
end

local function chooseLooseMob()
    local best, bestScore = nil, -math.huge
    local maxRange = tonumber(_settings.TankTauntChaseRange) or Aggro.TAUNT_CHASE_RANGE
    for _, row in ipairs(Cache.xtarget.haters or {}) do
        -- Loose = NOT targeting me. A mob already on me with a sub-100 aggro
        -- reading is not loose: taunting a mob that's targeting you does
        -- nothing in EQ, and the aggro-tools branch (aggroLeadLow) is the
        -- right response to a shrinking lead on the mob you're fighting.
        -- Cache.isMobMezzed consults the mezzer's broadcast mez list — the
        -- only mez signal that works for non-targeted mobs; taunting a mezzed
        -- mob breaks the mez.
        if not row.mezzed and not row.targetingMe
            and not Cache.isMobMezzed(row.id) then
            local spawn = validNpc(row.id, false)
            local distance = spawn and tonumber(safe(function() return spawn.Distance3D() end,
                safe(function() return spawn.Distance() end, 999))) or 999
            if spawn and distance <= maxRange then
                local attackingOther = tonumber(row.targetId) > 0 and not row.targetingMe
                local score = (attackingOther and 1000 or 0)
                    + (100 - (tonumber(row.aggro) or 100)) * 5
                    - distance
                if score > bestScore then best, bestScore = spawn, score end
            end
        end
    end
    return best
end

local function aoeAction(action)
    local key = tostring(action and (action.condKey or action.setName or action.name) or ''):lower()
    return key:find('ae', 1, true) ~= nil
        or key:find('torrent', 1, true) ~= nil
        or key:find('wave', 1, true) ~= nil
        or key:find('explosion', 1, true) ~= nil
end

local function aoeAllowed()
    local count = Cache.unmezzedHaterCount()
    if count < (tonumber(_settings.TankAoEThreshold) or 3) then return false, 'aoe_below_count' end
    if _settings.TankRequireAggroDeficit ~= false
        and (tonumber(Cache.xtarget.aggroDeficitCount) or 0) <= 0 then
        return false, 'aoe_no_aggro_deficit'
    end
    -- Never break active CC. The optional safe-AE setting can add stricter
    -- environmental checks later, but mez safety is unconditional.
    if Cache.hasAnyMezzedOnXTarget() then
        return false, 'aoe_mez_unsafe'
    end
    if _settings.TankSafeAECheck == true then
        local nearbyHaters = 0
        for _, row in ipairs(Cache.xtarget.haters or {}) do
            local spawn = spawnById(row.id)
            local distance = spawn and tonumber(safe(function() return spawn.Distance3D() end,
                safe(function() return spawn.Distance() end, 999))) or 999
            if distance <= 50 then nearbyHaters = nearbyHaters + 1 end
        end
        local nearby = tonumber(safe(function()
            return mq.TLO.SpawnCount('npc nopet targetable radius 50 zradius 30')()
        end, nearbyHaters)) or nearbyHaters
        if nearby > nearbyHaters then
            return false, string.format('aoe_neutral_nearby:%d>%d', nearby, nearbyHaters)
        end
    end
    return true
end

local function pickClassAction(categories)
    if not _classConfig then return nil end
    local ctx = Engine.buildContext()
    if not ctx then return nil end
    local excluded = {}
    for _ = 1, 12 do
        local action = Engine.pickReadyAbility(_classConfig, ctx, {
            allowKinds = { aa = true, disc = true, spell = true },
            includeCategories = categories,
            excludeConditions = excluded,
        })
        if not action then return nil end
        local kindEnabled = (action.kind ~= 'spell' or _settings.UseSpells ~= false)
            and (action.kind ~= 'aa' or _settings.UseAAs ~= false)
            and (action.kind ~= 'disc' or _settings.UseDiscs ~= false)
        if kindEnabled then
            if not aoeAction(action) then return action end
            local allowed = aoeAllowed()
            if allowed then return action end
        end
        excluded[action.condKey] = true
    end
    return nil
end

local function actionTargetId(action, fallback)
    local hostileTargetConditions = {
        doLeech = true,
        doDivineCall = true,
    }
    if hostileTargetConditions[tostring(action.condKey or '')] then
        return tonumber(fallback) or _primaryId
    end
    local category = _classConfig and _classConfig.categoryOverrides
        and _classConfig.categoryOverrides[action.condKey] or ''
    if category == 'emergency' or category == 'defenses' then
        return tonumber(safe(function() return mq.TLO.Me.ID() end, 0)) or 0
    end
    return tonumber(fallback) or _primaryId
end

local function buildAbilityAction(action, targetId, tier)
    local kindMap = {
        aa = lib.ActionKind.USE_AA,
        disc = lib.ActionKind.USE_DISC,
        spell = lib.ActionKind.CAST_SPELL,
    }
    local condKey = tostring(action.condKey or '')
    return {
        kind = kindMap[action.kind] or lib.ActionKind.USE_DISC,
        tankAction = 'ability',
        engineKind = action.kind,
        name = action.name,
        targetId = actionTargetId(action, targetId),
        restorePrimaryId = _primaryId,
        condKey = action.condKey,
        setName = action.setName,
        tier = tier,
        timeoutMs = 12000,
        castStartTimeoutMs = 2000,
        idempotencyKey = string.format('tank:%s:%s:%d', tier, action.setName, lib.getTimeMs()),
        reason = string.format('%s:%s', tier, action.setName),
        requiresSelfTarget = condKey == 'doLayOnHands',
        requiresHostileTarget = condKey == 'doLeech' or condKey == 'doDivineCall',
    }
end

local function computePending()
    local defensive = pickClassAction({ emergency = true })
    if defensive then
        return buildAbilityAction(defensive, _primaryId, 'emergency'), lib.Priority.EMERGENCY,
            'emergency:' .. defensive.setName
    end
    defensive = pickClassAction({ defenses = true })
    if defensive then
        return buildAbilityAction(defensive, _primaryId, 'defense'), lib.Priority.EMERGENCY,
            'defense:' .. defensive.setName
    end

    if _primaryId <= 0 then return nil, lib.Priority.DPS, 'no_target' end

    local loose = chooseLooseMob()
    -- A ready Taunt ends the previous recovery cycle: the add is eligible for
    -- a fresh taunt attempt again.
    if _recovery.mobId > 0 and Aggro.isTauntReady() then
        _recovery.mobId, _recovery.spent = 0, false
    end
    if loose and Aggro.canTaunt() and Aggro.isTauntReady() then
        local id = tonumber(safe(function() return loose.ID() end, 0)) or 0
        return {
            kind = lib.ActionKind.USE_SKILL,
            tankAction = 'taunt',
            name = 'Taunt',
            abilityName = 'Taunt',
            targetId = id,
            restorePrimaryId = _primaryId,
            expectsCastStart = false,
            timeoutMs = TAUNT_TIMEOUT_MS + 1500,
            idempotencyKey = string.format('tank:taunt:%d:%d', id, lib.getTimeMs()),
            reason = 'loose_mob_taunt',
        }, lib.Priority.TANK_RECOVERY, 'taunt:' .. tostring(id)
    end

    if Cache.inCombat() and (loose or Cache.aggroLeadLow()) then
        local looseId = loose and (tonumber(safe(function() return loose.ID() end, 0)) or 0) or 0
        if looseId > 0 and looseId ~= _recovery.mobId then
            _recovery.mobId, _recovery.spent = looseId, false
        end
        local recoveryActive = looseId > 0 and not _recovery.spent
        local hate = pickClassAction({ aggro = true })
        if hate then
            local targetId = recoveryActive and looseId or _primaryId
            return buildAbilityAction(hate, targetId, 'aggro'), lib.Priority.TANK_AGGRO,
                'aggro:' .. hate.setName
        elseif recoveryActive then
            -- Hate tools expended for this add's cycle. Attention returns to
            -- the primary until Taunt is ready again.
            _recovery.spent = true
        end
    end

    local currentId = tonumber(safe(function() return mq.TLO.Target.ID() end, 0)) or 0
    local attacking = safe(function() return mq.TLO.Me.Combat() end, false) == true
    local now = lib.getTimeMs()
    -- Re-engage only when target or attack state drifted. The periodic refresh
    -- exists solely to reapply the moveback stick, so it runs only while
    -- repositioning is enabled; otherwise a healthy engaged state claims no
    -- action resource and issues no /stick spam.
    local engageRefreshMs = math.max(1000, (tonumber(_settings.TankRepositionCooldown) or 5) * 1000)
    local needEngage = currentId ~= _primaryId or not attacking or _forceEngage
    if not needEngage and _settings.TankRepositionEnabled == true then
        needEngage = (now - _lastEngageAt) >= engageRefreshMs
    end
    if needEngage then
        return {
            kind = 'tank_engage',
            tankAction = 'engage',
            name = 'Tank engage',
            targetId = _primaryId,
            restorePrimaryId = _primaryId,
            expectsCastStart = false,
            settleMs = 75,
            timeoutMs = 2000,
            idempotencyKey = string.format('tank:engage:%d:%d', _primaryId, math.floor(now / engageRefreshMs)),
            reason = 'primary_engage',
        }, lib.Priority.DPS, 'engage:' .. tostring(_primaryId)
    end
    return nil, lib.Priority.DPS, 'holding_primary'
end

local function ensureTarget(id)
    local spawn = validNpc(id, false)
    if not spawn then return false end
    local currentId = tonumber(safe(function() return mq.TLO.Target.ID() end, 0)) or 0
    if currentId == tonumber(id) then return true end
    mq.cmdf('/target id %d', id)
    mq.delay(TARGET_SETTLE_MS, function()
        return (tonumber(safe(function() return mq.TLO.Target.ID() end, 0)) or 0) == tonumber(id)
    end)
    return (tonumber(safe(function() return mq.TLO.Target.ID() end, 0)) or 0) == tonumber(id)
end

local function ensureSelfTarget()
    local myId = tonumber(safe(function() return mq.TLO.Me.ID() end, 0)) or 0
    if myId <= 0 then return false end
    local currentId = tonumber(safe(function() return mq.TLO.Target.ID() end, 0)) or 0
    if currentId == myId then return true end
    mq.cmdf('/target id %d', myId)
    mq.delay(TARGET_SETTLE_MS, function()
        return (tonumber(safe(function() return mq.TLO.Target.ID() end, 0)) or 0) == myId
    end)
    return (tonumber(safe(function() return mq.TLO.Target.ID() end, 0)) or 0) == myId
end

local function restorePrimary(action)
    local id = tonumber(action and action.restorePrimaryId) or _primaryId
    if id > 0 and validNpc(id, false) then mq.cmdf('/target id %d', id) end
end

module.onTick = function(self)
    Cache.tick()
    local enabled = refreshSettings()
    if not enabled then
        _pending = nil
        _lastReason = TANK_CLASSES[_classShort] and 'mode_off' or 'not_tank_class'
        self:sendNeed(false, nil, _lastReason)
        return
    end

    if self.currentClaimId or self.claimPending then
        self:sendNeed(true, 1000, _lastReason)
        return
    end

    local primary = choosePrimary()
    setPrimary(primary)
    if _primaryId > 0 then broadcastPrimary(false) end

    local action, priority, reason = computePending()
    if not action and _primaryId <= 0 then reason = 'no_unmezzed_hater' end
    _pending = action
    self.priority = priority
    _lastReason = reason
    self:sendNeed(action ~= nil, action and 500 or nil, reason)
end

module.shouldAct = function()
    return _pending ~= nil
end

module.getAction = function()
    return _pending
end

module.getDiagnosticAction = function()
    return {
        active = _pending ~= nil,
        phase = _pending and 'ready' or 'idle',
        kind = _pending and _pending.kind or '',
        name = _pending and _pending.name or '',
        targetId = _pending and _pending.targetId or _primaryId,
        reason = _lastReason,
    }
end

module:enableUnifiedExecutor({
    preflight = function(action)
        _pending = nil
        if action.tankAction == 'ability' then
            if action.requiresSelfTarget then return ensureSelfTarget(), 'self_target_lost' end
            if action.requiresHostileTarget or action.tier == 'aggro' then
                return ensureTarget(action.targetId), 'target_lost'
            end
            return true
        end
        return ensureTarget(action.targetId), 'target_lost'
    end,
    dispatch = function(action, _, job)
        if action.tankAction == 'engage' then
            _lastEngageAt = lib.getTimeMs()
            _forceEngage = false
            mq.cmd('/attack on')
            if tostring(_settings.AutomationLevel or 'auto'):lower() == 'auto' then
                local moveback = _settings.TankRepositionEnabled == true and ' moveback' or ''
                mq.cmdf('/stick 10 id %d%s uw', action.targetId, moveback)
            end
            broadcastPrimary(true)
            _lastAction = 'engage:' .. tostring(action.targetId)
            return true, 'engaged', 'none'
        elseif action.tankAction == 'taunt' then
            -- Readiness was checked at decision time, but the claim grant can
            -- lag; never start the approach unless Taunt is usable right now.
            if not Aggro.isTauntReady() then return false, 'taunt_not_ready' end
            _recovery.mobId = tonumber(action.targetId) or 0
            _recovery.spent = false
            Actors.broadcastTauntRun()
            job.tank = { phase = 'approach', deadline = lib.getTimeMs() + TAUNT_TIMEOUT_MS }
            local spawn = validNpc(action.targetId, false)
            local distance = spawn and tonumber(safe(function() return spawn.Distance3D() end,
                safe(function() return spawn.Distance() end, 999))) or 999
            if distance > Aggro.TAUNT_RANGE then mq.cmdf('/nav id %d', action.targetId) end
            _lastAction = 'taunt:' .. tostring(action.targetId)
            return true, 'taunt_approach', 'custom'
        elseif action.tankAction == 'ability' then
            local fired = Engine.fireAbility({ kind = action.engineKind, name = action.name })
            if not fired then return false, 'fire_refused' end
            _lastAction = string.format('%s:%s', tostring(action.tier), tostring(action.name))
            if action.engineKind == 'spell' then return true, 'spell_issued', 'cast' end
            if action.engineKind == 'aa' then return true, 'aa_issued', 'cast_or_settle' end
            return true, 'disc_issued', 'settle'
        end
        return false, 'unsupported_tank_action'
    end,
    onTick = function(action, _, job)
        if action.tankAction ~= 'taunt' then return true end
        local runtime = job.tank or {}
        local spawn = validNpc(action.targetId, false)
        if not spawn then return true, 'target_lost', 'failed' end
        if lib.getTimeMs() >= (runtime.deadline or 0) then
            navStop()
            return true, 'taunt_timeout', 'failed'
        end
        local distance = tonumber(safe(function() return spawn.Distance3D() end,
            safe(function() return spawn.Distance() end, 999))) or 999
        if runtime.phase == 'approach' then
            if distance > Aggro.TAUNT_RANGE then return true, 'approaching' end
            navStop()
            if not ensureTarget(action.targetId) then return true, 'target_lost', 'failed' end
            if not Aggro.isTauntReady() then return true, 'taunt_not_ready', 'failed' end
            mq.cmd('/doability "Taunt"')
            runtime.phase = 'verify'
            runtime.verifyAt = lib.getTimeMs() + 500
            return true, 'taunt_issued'
        end
        if runtime.phase == 'verify' and lib.getTimeMs() >= (runtime.verifyAt or 0) then
            local myId = tonumber(safe(function() return mq.TLO.Me.ID() end, 0)) or 0
            local targetOfTarget = tonumber(safe(function() return spawn.TargetOfTarget.ID() end, 0)) or 0
            if targetOfTarget > 0 then
                return true, targetOfTarget == myId and 'taunt_acquired' or 'taunt_not_confirmed', 'completed'
            end
            -- ToT can resolve NULL on plain spawn references. The mob is still
            -- our current target here, so 100% aggro is an equivalent signal.
            local aggro = tonumber(safe(function() return mq.TLO.Me.PctAggro() end, 0)) or 0
            return true, aggro >= 100 and 'taunt_acquired' or 'taunt_unverified', 'completed'
        end
        return true, 'taunt_wait'
    end,
    onComplete = function(action)
        if action.tankAction == 'taunt' then
            navStop()
            Actors.broadcastTauntDone()
            -- The approach moved us off the primary; force a full re-engage
            -- (attack + stick), not just a retarget.
            _forceEngage = true
        end
        if action.tankAction == 'taunt'
            or (action.tankAction == 'ability'
                and (action.tier == 'aggro' or action.requiresSelfTarget or action.requiresHostileTarget)) then
            restorePrimary(action)
        end
    end,
    onFailure = function(action)
        if action and action.tankAction == 'taunt' then
            navStop()
            Actors.broadcastTauntDone()
            _forceEngage = true
        end
        restorePrimary(action)
    end,
    onCancel = function(action)
        if action and action.tankAction == 'taunt' then
            navStop()
            Actors.broadcastTauntDone()
            _forceEngage = true
        end
        restorePrimary(action)
    end,
})

mq.bind('/sk_tank', function(command)
    command = tostring(command or 'status'):lower()
    if command == 'stop' then
        navStop()
        module:stop()
        echo('Stop requested')
        return
    end
    local owner = module.state and module.state.targetOwner
    echo('running=%s class=%s mode=%s priority=%s ownsTarget=%s ownsCast=%s pending=%s reason=%s',
        tostring(module.running), tostring(_classShort), tostring(_settings.CombatMode or 'off'),
        tostring(module.priority), tostring(module:ownsTarget()), tostring(module:ownsCast()),
        tostring(_pending and _pending.name or '-'), tostring(_lastReason))
    echo('primary=%s(%d) coordinatorTargetOwner=%s last=%s haters=%d deficits=%d',
        _primaryName ~= '' and _primaryName or '-', _primaryId,
        tostring(owner and owner.module or '-'), tostring(_lastAction),
        tonumber(Cache.xtarget.count) or 0, tonumber(Cache.xtarget.aggroDeficitCount) or 0)
    local stateAge = (module.stateReceivedAt and module.stateReceivedAt > 0)
        and (lib.getTimeMs() - module.stateReceivedAt) or -1
    local result = module.lastActionResult or {}
    echo('stateValid=%s stateAgeMs=%d boot=%s claimPending=%s lastClaimOk=%s claimErr=%s lastResult=%s:%s',
        tostring(module:hasValidState()), stateAge, tostring(module.coordinatorBootId or '-'),
        tostring(module.claimPending), tostring(module.lastClaimSendOk),
        tostring(module.lastClaimSendError or '-'),
        tostring(result.phase or '-'), tostring(result.reason or '-'))
end)

Cache.init()
module:run(50)

return module
