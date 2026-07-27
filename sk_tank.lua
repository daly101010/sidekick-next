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
local Counters = require('sidekick-next.utils.action_counters')
local Roles = require('sidekick-next.utils.class_roles')

local module = ModuleBase.create('tank', lib.Priority.TANK)
module:enablePeerActors()

local TANK_CLASSES = Roles.TANK_CLASSES
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
-- Mezzed adds we already pre-taunted (hate secured without breaking mez).
local _mezPrepped = {}
-- Peel futility tracking: taunting a mob that refuses to come back (rooted
-- mobs attack by proximity, ignoring hate) just spams Taunt on cooldown.
-- After 2 peels that didn't bring the mob to us, back off for 30s.
local _peelState = {}  -- [mobId] = { count, lastAt, blockedUntil }
local PEEL_MAX_ATTEMPTS = 2
local PEEL_BLOCK_MS = 30000
-- Set when a granted taunt found the ability on true cooldown; suppresses
-- the "pending while casting" pathway briefly so we don't keep interrupting
-- DPS casts for a taunt that cannot fire yet.
local _tauntNotReadyUntil = 0
local MEZ_PREP_TTL_MS = 120000

-- Camp anchor: where the tank idles between fights. Mobs pinned on walls
-- block backstabs; repositioning drags the primary toward this point.
local _anchor = { x = 0, y = 0, z = 0, setAt = 0 }
local _lastAnchorSampleAt = 0
local _lastRepositionAt = 0
local _dragBlocked = {}          -- mobId -> time; mobs that would not follow
local _backHeld = false          -- backpedal key currently held (drag step)
local _cleanupStableSamples = 0
local DRAG_BLOCK_TTL_MS = 30000
local REPO_STEP_SIZE = 15        -- units per drag step toward camp
local REPO_CAMP_RADIUS = 25      -- mob within this of camp = good enough

local function safe(fn, fallback)
    local ok, value = pcall(fn)
    if not ok or value == nil then return fallback end
    return value
end

local function echo(fmt, ...)
    local ok, text = pcall(string.format, fmt, ...)
    print(string.format('\ag[SK Tank]\ax %s', ok and text or tostring(fmt)))
end

-- In-game announcements for target choices and taunt peels. Change-gated by
-- the callers, so this stays chatty-but-not-spammy; TankAnnounce=false in
-- settings silences it entirely.
local function announce(fmt, ...)
    if _settings.TankAnnounce == false then return end
    echo(fmt, ...)
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
    -- Cache.isMobMezzed here: validNpc's TLO mez check only works reliably
    -- for the current target; the broadcast list is the source of truth for
    -- a mez that landed AFTER we declared this primary (e.g. the enchanter
    -- mezzed our pick) — drop it and re-select rather than break the mez.
    local current = validNpc(_primaryId, false)
    if current and not Cache.isMobMezzed(_primaryId) then
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

    -- Kill-order scoring: enemy healers first (they prolong every fight),
    -- then higher level, then finish what's hurt; named get a bump. No bonus
    -- for mobs targeting the tank — a mob on the tank is the SAFE case, and
    -- mobs beating on squishies are the recovery-taunt branch's job.
    -- Enemy NPC classification: PAL is intentionally excluded because
    -- enemy paladins are hybrids, not pure healers — Roles.HEALER_CLASSES
    -- (which does include PAL) is for own-team healing dispatch.
    local ENEMY_PURE_HEALERS = { CLR = true, DRU = true, SHM = true }
    local best, bestScore = nil, -math.huge
    for _, row in ipairs(Cache.xtarget.haters or {}) do
        -- Cache.isMobMezzed consults the mezzer's broadcast mez list; the
        -- row.mezzed flag and Spawn.Mezzed only work for the current target.
        -- Engage range keeps the tank from sticking off toward a hater that
        -- aggroed from across the camp.
        -- Actors.isCharmPet: the group's charm pet (and a just-broken one in
        -- its recovery window) is never a kill target — the tank protects the
        -- enchanter with damageless aggro only (loose-mob Taunt path).
        -- isMobMezClaimed: a mezzer claimed this mob and the mez is a
        -- cast-bar away — engaging it now just breaks the incoming mez.
        if not row.mezzed and not Cache.isMobMezzed(row.id)
            and not Cache.isMobMezClaimed(row.id)
            and not Actors.isCharmPet(row.id)
            and (tonumber(row.distance) or 999) <= engageRange then
            local spawn = validNpc(row.id, false)
            if spawn then
                local score = (100 - (tonumber(row.hp) or 100))
                    + (tonumber(row.level) or 0) * 3
                if ENEMY_PURE_HEALERS[tostring(row.classShort or ''):upper()] then
                    score = score + 400
                end
                if safe(function() return spawn.Named() end, false) == true then score = score + 100 end
                if score > bestScore then
                    best, bestScore = spawn, score
                end
            end
        end
    end

    -- Declare-only fallback: nothing inside engage range yet, but haters are
    -- inbound (mid-pull). Declare the pick NOW so the broadcast reaches the
    -- mezzer before the mobs cross into its 200-unit mez range — the mezzer
    -- excludes our primary and spends its mezzes on the others. Engage itself
    -- stays gated on TankEngageRange (see computePending's inbound hold), so
    -- this never sends the tank running out to meet the pull.
    if not best then
        local declareRange = math.max(engageRange, 200)
        for _, row in ipairs(Cache.xtarget.haters or {}) do
            if not row.mezzed and not Cache.isMobMezzed(row.id)
                and not Cache.isMobMezClaimed(row.id)
                and not Actors.isCharmPet(row.id)
                and (tonumber(row.distance) or 999) <= declareRange then
                local spawn = validNpc(row.id, false)
                if spawn then
                    local score = (100 - (tonumber(row.hp) or 100))
                        + (tonumber(row.level) or 0) * 3
                    if ENEMY_PURE_HEALERS[tostring(row.classShort or ''):upper()] then
                        score = score + 400
                    end
                    if safe(function() return spawn.Named() end, false) == true then score = score + 100 end
                    if score > bestScore then
                        best, bestScore = spawn, score
                    end
                end
            end
        end
    end

    -- No unmezzed hater left: deliberately break the next mez (one-at-a-time
    -- camp consumption). Without this the tank idles while mezzed adds remain.
    -- Recovery taunts still never touch mezzed mobs.
    if not best and _settings.TankBreakMez ~= false then
        for _, row in ipairs(Cache.xtarget.haters or {}) do
            local spawn = not Actors.isCharmPet(row.id) and validNpc(row.id, true) or nil
            if spawn and (tonumber(row.distance) or 999) <= engageRange then
                local score = (100 - (tonumber(row.hp) or 100)) - (tonumber(row.distance) or 0)
                if not best or score > bestScore then
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
        if row.targetingMe then
            -- Mob is on us: any peel worked (or was never needed) — reset.
            _peelState[tonumber(row.id) or 0] = nil
        end
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

    -- Loose-mob taunt runs BEFORE the no-primary bail: normally any unmezzed
    -- hater becomes the primary, but the group's charm pet is excluded from
    -- primary selection — when a broken pet is the only hater left it's loose
    -- on the enchanter and the tank must still peel it with (damageless) Taunt.
    local loose = chooseLooseMob()
    -- A ready Taunt ends the previous recovery cycle: the add is eligible for
    -- a fresh taunt attempt again.
    if _recovery.mobId > 0 and Aggro.isTauntReady() then
        _recovery.mobId, _recovery.spent = 0, false
    end
    -- NOTE both taunt gates: AbilityReady('Taunt') reads FALSE while we are
    -- casting (ability lockout), so a casting tank would never even advertise
    -- the taunt. Treat "unready only because we're mid-cast" as ready — the
    -- claim path interrupts the cast (see onTick) and dispatch re-verifies.
    local tauntUsable = Aggro.isTauntReady()
        or (lib.isCasting() and lib.getTimeMs() >= _tauntNotReadyUntil)
    if loose and Aggro.canTaunt() and tauntUsable then
        local id = tonumber(safe(function() return loose.ID() end, 0)) or 0
        local nowMs = lib.getTimeMs()
        local peel = _peelState[id]
        -- A mob we're already targeting that's ROOTED cannot be peeled:
        -- rooted mobs attack by proximity regardless of hate. (Root state is
        -- only readable off the current target.)
        local rooted = false
        if id == (tonumber(safe(function() return mq.TLO.Target.ID() end, 0)) or 0) then
            rooted = safe(function()
                local r = mq.TLO.Target.Rooted()
                return r ~= nil and tostring(r) ~= 'NULL' and tostring(r) ~= ''
            end, false) == true
        end
        if peel and peel.blockedUntil and nowMs < peel.blockedUntil then
            loose = nil
        elseif rooted then
            loose = nil
        end
    end
    if loose and Aggro.canTaunt() and tauntUsable then
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

    if _primaryId <= 0 then return nil, lib.Priority.DPS, 'no_target' end

    -- Primary taunt: we're fighting our target but no longer top hate
    -- (PctAggro < 100 — someone outaggroed us or is being handed the mob).
    -- Taunt sets us to top hate +1, so it DOES work here; it's only wasted
    -- at 100%. This was lost when "loose" was redefined to exclude mobs
    -- targeting us — hate discs/AAs covered the gap only while one was
    -- ready. PctAggro is only meaningful for the current target, so require
    -- the primary to actually be targeted.
    if Aggro.canTaunt() and tauntUsable and Cache.inCombat() then
        local currentId = tonumber(safe(function() return mq.TLO.Target.ID() end, 0)) or 0
        local pctAggro = tonumber(Cache.me and Cache.me.pctAggro) or 100
        if currentId == _primaryId and pctAggro < 100 then
            local row = haterRow(_primaryId)
            local dist = row and tonumber(row.distance) or 999
            if dist <= Aggro.TAUNT_RANGE and validNpc(_primaryId, false) then
                return {
                    kind = lib.ActionKind.USE_SKILL,
                    tankAction = 'taunt',
                    name = 'Taunt',
                    abilityName = 'Taunt',
                    targetId = _primaryId,
                    restorePrimaryId = _primaryId,
                    expectsCastStart = false,
                    timeoutMs = TAUNT_TIMEOUT_MS + 1500,
                    idempotencyKey = string.format('tank:taunt:%d:%d', _primaryId, lib.getTimeMs()),
                    reason = 'primary_taunt',
                }, lib.Priority.TANK_RECOVERY, 'primary_taunt:' .. tostring(_primaryId)
            end
        end
    end

    -- Reposition: drag a wall-pinned primary toward the camp anchor so melee
    -- (rogues) can get behind it. Strict safety gates: mob must be glued to
    -- the tank (targeting me at 100% aggro), unmezzed, previously willing to
    -- follow, and the anchor must be fresh. Root is re-checked at dispatch.
    if _settings.TankRepositionEnabled == true and Cache.inCombat() and _primaryId > 0 then
        local nowMs = lib.getTimeMs()
        local cooldownMs = math.max(3, tonumber(_settings.TankRepositionCooldown) or 5) * 1000
        local row = haterRow(_primaryId)
        if row and row.targetingMe and (tonumber(row.aggro) or 0) >= 100
            and not row.mezzed
            and _anchor.setAt > 0
            and (nowMs - _lastRepositionAt) >= cooldownMs
            and (nowMs - (_dragBlocked[_primaryId] or 0)) > DRAG_BLOCK_TTL_MS then
            local spawn = validNpc(_primaryId, false)
            local mobX = spawn and tonumber(safe(function() return spawn.X() end, nil)) or nil
            local mobY = spawn and tonumber(safe(function() return spawn.Y() end, nil)) or nil
            if mobX and mobY then
                local dx, dy = _anchor.x - mobX, _anchor.y - mobY
                local mobDistFromCamp = math.sqrt(dx * dx + dy * dy)
                if mobDistFromCamp > REPO_CAMP_RADIUS then
                    return {
                        kind = 'tank_reposition',
                        tankAction = 'reposition',
                        name = 'Reposition',
                        targetId = _primaryId,
                        restorePrimaryId = _primaryId,
                        expectsCastStart = false,
                        timeoutMs = 8000,
                        idempotencyKey = string.format('tank:repo:%d:%d', _primaryId, nowMs),
                        reason = 'reposition_to_camp',
                    }, lib.Priority.TANK_AGGRO, 'reposition:' .. tostring(_primaryId)
                end
            end
        end
    end

    -- Pre-taunt mezzed adds: Taunt deals no damage so mez holds, but the tank
    -- tops the mob's hate list — the eventual mez-breaking swing brings it to
    -- us instead of the mezzer. Runs mid-fight only within melee taunt range
    -- (never nav away from the current fight); free movement when OOC.
    if _settings.TankBreakMez ~= false and Aggro.canTaunt() and Aggro.isTauntReady() then
        local nowMs = lib.getTimeMs()
        for _, row in ipairs(Cache.xtarget.haters or {}) do
            if (row.mezzed or Cache.isMobMezzed(row.id))
                and (nowMs - (_mezPrepped[row.id] or 0)) > MEZ_PREP_TTL_MS then
                local dist = tonumber(row.distance) or 999
                if (dist <= Aggro.TAUNT_RANGE or not Cache.inCombat())
                    and validNpc(row.id, true) then
                    return {
                        kind = lib.ActionKind.USE_SKILL,
                        tankAction = 'taunt',
                        name = 'Taunt',
                        abilityName = 'Taunt',
                        targetId = row.id,
                        restorePrimaryId = _primaryId,
                        expectsCastStart = false,
                        timeoutMs = TAUNT_TIMEOUT_MS + 1500,
                        idempotencyKey = string.format('tank:mezprep:%d:%d', row.id, nowMs),
                        reason = 'mez_pretaunt',
                    }, lib.Priority.TANK_AGGRO, 'mezprep:' .. tostring(row.id)
                end
            end
        end
    end

    -- The charm pet may be taunted (damageless, handled by the loose-mob
    -- Taunt branch above) but never fed hate discs/AAs — some of those deal
    -- damage, and the recharm is coming.
    local looseId = loose and (tonumber(safe(function() return loose.ID() end, 0)) or 0) or 0
    local loosePet = looseId > 0 and Actors.isCharmPet(looseId)
    if Cache.inCombat() and ((loose and not loosePet) or Cache.aggroLeadLow()) then
        if looseId > 0 and not loosePet and looseId ~= _recovery.mobId then
            _recovery.mobId, _recovery.spent = looseId, false
        end
        local recoveryActive = looseId > 0 and not loosePet and not _recovery.spent
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

    -- Inbound hold: a declare-only primary (picked beyond engage range so the
    -- mezzer gets the exclusion broadcast early) is watched, not chased. The
    -- moment it crosses TankEngageRange the engage below fires on the next
    -- 50ms tick.
    do
        local row = haterRow(_primaryId)
        local primaryDist = row and tonumber(row.distance) or nil
        if not primaryDist then
            local spawn = spawnById(_primaryId)
            primaryDist = spawn and tonumber(safe(function() return spawn.Distance3D() end,
                safe(function() return spawn.Distance() end, nil))) or nil
        end
        local engageRange = tonumber(_settings.TankEngageRange) or 125
        if primaryDist and primaryDist > engageRange then
            return nil, lib.Priority.TANK_ENGAGE, 'primary_inbound'
        end
    end

    local currentId = tonumber(safe(function() return mq.TLO.Target.ID() end, 0)) or 0
    local attacking = safe(function() return mq.TLO.Me.Combat() end, false) == true
    local now = lib.getTimeMs()
    -- Re-engage only when target or attack state drifted (or a taunt
    -- excursion forced a re-stick). Repositioning is its own claim-based
    -- drag action now; no periodic stick refresh needed.
    local needEngage = currentId ~= _primaryId or not attacking or _forceEngage
    if needEngage then
        return {
            kind = 'tank_engage',
            tankAction = 'engage',
            name = 'Tank engage',
            targetId = _primaryId,
            restorePrimaryId = _primaryId,
            expectsCastStart = false,
            settleMs = 75,
            -- Covers hold-for-inbound plus the nav walk: the engage_approach
            -- phase runs its own 12s deadline; the executor's hard deadline
            -- must not kill the job first.
            timeoutMs = 15000,
            idempotencyKey = string.format('tank:engage:%d:%d', _primaryId, math.floor(now / 5000)),
            reason = 'primary_engage',
        }, lib.Priority.TANK_ENGAGE, 'engage:' .. tostring(_primaryId)
    end
    return nil, lib.Priority.DPS, 'holding_primary'
end

local function ensureTarget(id, allowMezzed)
    local spawn = validNpc(id, allowMezzed == true)
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
        if _primaryId > 0 then
            setPrimary(nil)
            broadcastPrimary(true)
        end
        _pending = nil
        _lastReason = TANK_CLASSES[_classShort] and 'mode_off' or 'not_tank_class'
        self:setIntent(false, nil, _lastReason)
        return
    end

    if self.currentRequestId then
        -- Keep the primary broadcast warm while a lease executes (engage
        -- approaches can run 10s+): the mezzer's exclusion has a freshness
        -- window and must not expire mid-fight.
        broadcastPrimary(false)
        self:setIntent(true, nil, _lastReason)
        return
    end

    local campReturnAction = nil
    -- Camp anchor maintenance while idle (no haters, standing still).
    -- Deadband keeps the anchor stable against combat drift (rgmercs solves
    -- this with an explicit /camp; we infer it):
    --   < 30 from anchor: refresh it (fine-tuning position)
    --   30-100:           drift from fighting/drags — walk back to camp
    --   > 100 (or unset): deliberate relocation — re-anchor here
    do
        local nowMs = lib.getTimeMs()
        if (Cache.xtarget.count or 0) == 0 and (nowMs - _lastAnchorSampleAt) >= 5000 then
            _lastAnchorSampleAt = nowMs
            local moving = safe(function() return mq.TLO.Me.Moving() end, false) == true
            local navActive = safe(function() return mq.TLO.Navigation.Active() end, false) == true
            if not moving and not navActive then
                local x = tonumber(safe(function() return mq.TLO.Me.X() end, nil))
                local y = tonumber(safe(function() return mq.TLO.Me.Y() end, nil))
                local z = tonumber(safe(function() return mq.TLO.Me.Z() end, nil))
                if x and y and z then
                    local dx, dy = _anchor.x - x, _anchor.y - y
                    local fromAnchor = _anchor.setAt > 0
                        and math.sqrt(dx * dx + dy * dy) or math.huge
                    if fromAnchor < 30 or fromAnchor > 100 or _anchor.setAt == 0 then
                        _anchor.x, _anchor.y, _anchor.z, _anchor.setAt = x, y, z, nowMs
                        -- Broadcast anchor so the pull worker's RETURN_CAMP
                        -- follows the tank's live position instead of its own
                        -- fixed-at-first-pull coordinate.
                        if Actors.broadcastTankCampAnchor then
                            Actors.broadcastTankCampAnchor(x, y, z)
                        end
                    elseif _settings.TankRepositionEnabled == true
                        and tostring(_settings.AutomationLevel or 'auto'):lower() == 'auto' then
                        campReturnAction = {
                            kind = 'movement',
                            tankAction = 'return_camp',
                            name = 'Return to camp',
                            campX = _anchor.x,
                            campY = _anchor.y,
                            campZ = _anchor.z,
                            skipBoundaryTarget = true,
                            breaksInvis = false,
                            timeoutMs = 15000,
                            idempotencyKey = string.format(
                                'tank:return-camp:%d:%d',
                                math.floor(_anchor.x), math.floor(_anchor.y)),
                            reason = 'return_to_camp',
                        }
                    end
                end
            end
        end
    end

    local primary = choosePrimary()
    local primaryChanged = setPrimary(primary)
    if primaryChanged and _primaryId > 0 then
        local row = haterRow(_primaryId)
        local dist = row and tonumber(row.distance) or nil
        local engageRange = tonumber(_settings.TankEngageRange) or 125
        local cls = row and tostring(row.classShort or '') or ''
        announce('Target: \aw%s\ax (%d)%s%s%s', _primaryName, _primaryId,
            dist and string.format(' dist=%.0f', dist) or '',
            cls ~= '' and (' [' .. cls .. ']') or '',
            (dist and dist > engageRange) and ' \ay- declared inbound, holding\ax' or '')
    elseif primaryChanged and _primaryId <= 0 then
        announce('Target cleared')
    end
    -- A fresh zero is authoritative "do not acquire", not an absent target.
    -- Keep broadcasting it while this worker owns target authority so DPS
    -- cannot fall back to the tank's temporary peel/aggro target.
    broadcastPrimary(primaryChanged)

    local action, priority, reason = computePending()
    if not action and campReturnAction then
        action = campReturnAction
        reason = campReturnAction.reason
    end
    if not action and _primaryId <= 0 then reason = 'no_unmezzed_hater' end
    _pending = action
    _lastReason = reason

    self:setIntent(action ~= nil, nil, reason)
end

module.shouldAct = function()
    return _pending ~= nil
end

module.getAction = function()
    if _pending and tonumber(_pending.targetId) and tonumber(_pending.targetId) > 0 then
        local spawn = spawnById(_pending.targetId)
        if spawn then
            _pending.targetName = tostring(safe(function() return spawn.CleanName() end, '') or '')
            _pending.targetType = tostring(safe(function() return spawn.Type() end, '') or '')
        end
    end
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

-- End a drag step: release the held backpedal key, resume normal combat
-- stick, release assisters from their soft-pause. The key release MUST run
-- on every exit path — a stuck movement key is far worse than any drag.
local function endDragStep(action)
    if _backHeld then
        mq.cmd('/keypress back')
        _backHeld = false
    end
    if tostring(_settings.AutomationLevel or 'auto'):lower() == 'auto'
        and action and tonumber(action.targetId) then
        mq.cmdf('/squelch /stick 10 id %d uw', action.targetId)
    end
    Actors.broadcastTankSettled()
end

module:enableUnifiedExecutor({
    preflight = function(action)
        _pending = nil
        if action.tankAction == 'return_camp' then
            if Cache.inCombat() or (Cache.xtarget.count or 0) > 0 then
                return false, 'combat_resumed'
            end
            return tonumber(action.campX) ~= nil
                and tonumber(action.campY) ~= nil
                and tonumber(action.campZ) ~= nil,
                'camp_anchor_missing'
        end
        if action.tankAction == 'ability' then
            if action.requiresSelfTarget then return ensureSelfTarget(), 'self_target_lost' end
            if action.requiresHostileTarget or action.tier == 'aggro' then
                return ensureTarget(action.targetId), 'target_lost'
            end
            return true
        end
        -- Engage may deliberately target a mezzed primary (break-mez), and a
        -- mez pre-taunt targets a mezzed add by design.
        local allowMezzed = action.tankAction == 'engage' or action.reason == 'mez_pretaunt'
        return ensureTarget(action.targetId, allowMezzed), 'target_lost'
    end,
    dispatch = function(action, _, job)
        if action.tankAction == 'return_camp' then
            module:markDirtyEffects(true)
            mq.cmdf('/nav locyxz %.1f %.1f %.1f',
                tonumber(action.campY), tonumber(action.campX), tonumber(action.campZ))
            job.tank = {
                phase = 'return_camp',
                deadline = lib.getTimeMs() + 12000,
            }
            _lastAction = 'return_camp'
            return true, 'returning_to_camp', 'custom'
        elseif action.tankAction == 'engage' then
            _lastEngageAt = lib.getTimeMs()
            _forceEngage = false
            broadcastPrimary(true)
            _lastAction = 'engage:' .. tostring(action.targetId)
            local dist = tonumber(safe(function() return mq.TLO.Target.Distance3D() end, 999)) or 999
            local melee = tonumber(safe(function() return mq.TLO.Target.MaxRangeTo() end, 14)) or 14
            local los = safe(function() return mq.TLO.Target.LineOfSight() end, false) == true
            if dist <= melee and los then
                if tostring(_settings.AutomationLevel or 'auto'):lower() == 'auto' then
                    mq.cmdf('/stick 10 id %d uw', action.targetId)
                end
                mq.cmd('/attack on')
                return true, 'engaged', 'none'
            end
            -- Not in melee yet: the approach phase decides between waiting
            -- for an inbound mob, pathfinding via nav (LOS-safe), and the
            -- final stick handoff. No blind /stick from range: stick is
            -- straight-line chasing and runs the tank into walls without LOS.
            job.tank = {
                phase = 'engage_approach',
                deadline = lib.getTimeMs() + 12000,
                lastDist = dist,
                progressAt = lib.getTimeMs(),
            }
            return true, 'engage_approach', 'custom'
        elseif action.tankAction == 'reposition' then
            module:markDirtyEffects(true)
            _lastRepositionAt = lib.getTimeMs()
            -- Root check at dispatch time (needs the mob targeted for cached
            -- buffs). Unknown reads as not-rooted; the follow-check below
            -- catches invisible roots anyway.
            local rooted = false
            pcall(function()
                local r = mq.TLO.Target.Rooted()
                rooted = r ~= nil and tostring(r) ~= 'NULL' and tostring(r) ~= ''
            end)
            if rooted then
                _dragBlocked[tonumber(action.targetId) or 0] = lib.getTimeMs()
                return false, 'target_rooted'
            end
            local myX = tonumber(safe(function() return mq.TLO.Me.X() end, nil))
            local myY = tonumber(safe(function() return mq.TLO.Me.Y() end, nil))
            if not (myX and myY) then return false, 'no_position' end
            local mobSpawn = spawnById(action.targetId)
            local mobX = mobSpawn and tonumber(safe(function() return mobSpawn.X() end, nil)) or nil
            local mobY = mobSpawn and tonumber(safe(function() return mobSpawn.Y() end, nil)) or nil
            if not (mobX and mobY) then return false, 'no_mob_position' end

            -- NEVER turn our back on the mob (riposte/parry/block only work
            -- facing). The drag is a BACKPEDAL while facing the mob, so it
            -- only runs when camp lies in the rear cone: the angle between
            -- the mob bearing and the camp bearing must exceed ~115 degrees.
            local toMobX, toMobY = mobX - myX, mobY - myY
            local toCampX, toCampY = _anchor.x - myX, _anchor.y - myY
            local mobLen = math.sqrt(toMobX * toMobX + toMobY * toMobY)
            local campLen = math.sqrt(toCampX * toCampX + toCampY * toCampY)
            if campLen < 5 then return false, 'already_at_camp' end
            if mobLen > 0.1 then
                local dot = (toMobX * toCampX + toMobY * toCampY) / (mobLen * campLen)
                if dot > -0.42 then
                    return false, 'bad_geometry'
                end
            end

            -- Assisters soft-pause their sticks while the tank drags.
            Actors.broadcastTankRepositioning()
            mq.cmd('/squelch /stick off')
            mq.cmdf('/squelch /face fast id %d', action.targetId)
            mq.cmd('/keypress back hold')
            _backHeld = true
            job.tank = {
                phase = 'drag_step',
                deadline = lib.getTimeMs() + 2500,
                startX = myX,
                startY = myY,
                startDist = tonumber(safe(function() return mobSpawn.Distance3D() end, 0)) or 0,
            }
            _lastAction = 'reposition:' .. tostring(action.targetId)
            Counters.bump('reposition_step')
            return true, 'drag_step', 'custom'
        elseif action.tankAction == 'taunt' then
            -- Readiness was checked at decision time, but the claim grant can
            -- lag — and when this taunt preempted a cast (selection treats
            -- our own mid-cast as "usable"), the ability lockout takes a
            -- beat to release after the interrupt. Brief wait, then verdict.
            if not Aggro.isTauntReady() then
                local readyDeadline = lib.getTimeMs() + 1000
                repeat
                    mq.delay(50)
                until Aggro.isTauntReady() or lib.getTimeMs() >= readyDeadline
                if not Aggro.isTauntReady() then
                    _tauntNotReadyUntil = lib.getTimeMs() + 4000
                    return false, 'taunt_not_ready'
                end
            end
            do
                local tSpawn = spawnById(action.targetId)
                local tName = tSpawn and tostring(safe(function() return tSpawn.CleanName() end, '?') or '?') or '?'
                local why = action.reason == 'mez_pretaunt' and 'pre-taunting mezzed add'
                    or action.reason == 'primary_taunt' and 'losing aggro on primary'
                    or 'peeling loose mob'
                announce('Taunt: \aw%s\ax (%d) - %s', tName, tonumber(action.targetId) or 0, why)
            end
            if action.reason == 'mez_pretaunt' then
                -- Hate secured without breaking mez. Never open a recovery
                -- cycle for it: follow-up hate tools would break the mez.
                _mezPrepped[tonumber(action.targetId) or 0] = lib.getTimeMs()
                Counters.bump('mez_pretaunt')
            else
                _recovery.mobId = tonumber(action.targetId) or 0
                _recovery.spent = false
                if action.reason == 'loose_mob_taunt' then
                    local pid = tonumber(action.targetId) or 0
                    local peel = _peelState[pid] or { count = 0 }
                    peel.count = peel.count + 1
                    peel.lastAt = lib.getTimeMs()
                    if peel.count >= PEEL_MAX_ATTEMPTS then
                        -- Two peels and it still won't come to us (rooted, or
                        -- proximity-locked): stop wasting Taunt for a while.
                        peel.blockedUntil = lib.getTimeMs() + PEEL_BLOCK_MS
                        peel.count = 0
                        announce('Peel futile on %d - backing off %ds',
                            pid, math.floor(PEEL_BLOCK_MS / 1000))
                    end
                    _peelState[pid] = peel
                end
            end
            Actors.broadcastTauntRun()
            job.tank = { phase = 'approach', deadline = lib.getTimeMs() + TAUNT_TIMEOUT_MS }
            local spawn = validNpc(action.targetId, action.reason == 'mez_pretaunt')
            local distance = spawn and tonumber(safe(function() return spawn.Distance3D() end,
                safe(function() return spawn.Distance() end, 999))) or 999
            if distance > Aggro.TAUNT_RANGE then
                module:markDirtyEffects(true)
                mq.cmdf('/nav id %d', action.targetId)
            end
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
        if action.tankAction == 'return_camp' then
            local runtime = job.tank or {}
            if Cache.inCombat() or (Cache.xtarget.count or 0) > 0 then
                return true, 'combat_resumed', 'failed'
            end
            local x = tonumber(safe(function() return mq.TLO.Me.X() end, nil))
            local y = tonumber(safe(function() return mq.TLO.Me.Y() end, nil))
            if not (x and y) then return true, 'position_unavailable', 'failed' end
            local dx = x - tonumber(action.campX)
            local dy = y - tonumber(action.campY)
            if (dx * dx + dy * dy) <= 64 then
                navStop()
                return true, 'at_camp', 'completed'
            end
            if lib.getTimeMs() >= (runtime.deadline or 0) then
                return true, 'return_camp_timeout', 'failed'
            end
            return true, 'returning_to_camp'
        end
        if action.tankAction == 'reposition' then
            local runtime = job.tank or {}
            if runtime.phase ~= 'drag_step' then return true end
            local spawn = validNpc(action.targetId, false)
            if not spawn then return true, 'target_lost', 'failed' end
            -- Abort instantly if the mob peels off the tank mid-step.
            local row = haterRow(action.targetId)
            if not (row and row.targetingMe) then
                return true, 'aggro_wobble', 'failed'
            end
            local dist = tonumber(safe(function() return spawn.Distance3D() end, 999)) or 999
            -- Mob not following (unseen root, parked caster): blacklist it so
            -- we stop backing away from our own target.
            if dist > (runtime.startDist or 0) + 12 then
                _dragBlocked[tonumber(action.targetId) or 0] = lib.getTimeMs()
                return true, 'mob_not_following', 'failed'
            end
            -- Step complete once we've backpedaled far enough, or on timeout.
            local myX = tonumber(safe(function() return mq.TLO.Me.X() end, nil))
            local myY = tonumber(safe(function() return mq.TLO.Me.Y() end, nil))
            if myX and myY then
                local dx, dy = myX - (runtime.startX or myX), myY - (runtime.startY or myY)
                if (dx * dx + dy * dy) >= REPO_STEP_SIZE * REPO_STEP_SIZE then
                    return true, 'step_done', 'completed'
                end
            end
            if lib.getTimeMs() >= (runtime.deadline or 0) then
                return true, 'step_done', 'completed'
            end
            return true, 'dragging'
        end
        if action.tankAction == 'engage' then
            local runtime = job.tank or {}
            if runtime.phase ~= 'engage_approach' then return true end
            local now = lib.getTimeMs()
            -- allowMezzed: a break-mez engage approaches a still-mezzed mob.
            local spawn = validNpc(action.targetId, true)
            if not spawn then
                navStop()
                return true, 'target_lost', 'failed'
            end
            local dist = tonumber(safe(function() return spawn.Distance3D() end, 999)) or 999
            local melee = tonumber(safe(function() return mq.TLO.Target.MaxRangeTo() end, 14)) or 14
            local los = safe(function() return spawn.LineOfSight() end, false) == true

            -- Arrived: hand off from nav to stick and start swinging.
            if dist <= melee and los then
                navStop()
                if tostring(_settings.AutomationLevel or 'auto'):lower() == 'auto' then
                    mq.cmdf('/stick 10 id %d uw', action.targetId)
                end
                mq.cmd('/attack on')
                return true, 'engaged', 'completed'
            end

            if now >= (runtime.deadline or 0) then
                -- Couldn't close (pathing, evasive mob). Flip attack so an
                -- arriving mob is met swinging, and let drift detection retry.
                navStop()
                mq.cmd('/attack on')
                return true, 'engage_approach_timeout', 'completed'
            end

            -- Track whether the gap is closing (mob inbound to us).
            if dist < (runtime.lastDist or math.huge) - 1 then
                runtime.progressAt = now
            end
            runtime.lastDist = dist

            -- Hold position while a distant hater is inbound: haters path to
            -- the tank, and standing at camp beats running out to meet them.
            -- Chase only when the gap stops closing (parked caster, rooted
            -- mob) for a moment.
            local holdRadius = tonumber(_settings.TankHoldRadius) or 50
            if dist > holdRadius and (now - (runtime.progressAt or 0)) < 2500 then
                return true, 'waiting_inbound'
            end

            -- Close the gap with NAV (pathfinding, LOS-safe) — never blind
            -- /stick from range. Re-issue at most every 2s.
            if (now - (runtime.navIssuedAt or 0)) >= 2000 then
                runtime.navIssuedAt = now
                module:markDirtyEffects(true)
                mq.cmdf('/nav id %d', action.targetId)
            end
            return true, 'approaching'
        end
        if action.tankAction ~= 'taunt' then return true end
        local runtime = job.tank or {}
        local spawn = validNpc(action.targetId, action.reason == 'mez_pretaunt')
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
            if not ensureTarget(action.targetId, action.reason == 'mez_pretaunt') then
                return true, 'target_lost', 'failed'
            end
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
                local landed = targetOfTarget == myId
                Counters.bump(landed and 'taunt_landed' or 'taunt_missed')
                return true, landed and 'taunt_acquired' or 'taunt_not_confirmed', 'completed'
            end
            -- ToT can resolve NULL on plain spawn references. The mob is still
            -- our current target here, so 100% aggro is an equivalent signal.
            local aggro = tonumber(safe(function() return mq.TLO.Me.PctAggro() end, 0)) or 0
            Counters.bump(aggro >= 100 and 'taunt_landed' or 'taunt_unverified')
            return true, aggro >= 100 and 'taunt_acquired' or 'taunt_unverified', 'completed'
        end
        return true, 'taunt_wait'
    end,
    onComplete = function(action)
        if action.tankAction == 'return_camp' then
            navStop()
        elseif action.tankAction == 'reposition' then
            endDragStep(action)
        end
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
        elseif action and (action.tankAction == 'engage'
            or action.tankAction == 'return_camp') then
            navStop()
        elseif action and action.tankAction == 'reposition' then
            endDragStep(action)
        end
        restorePrimary(action)
    end,
    onCancel = function(action)
        if action and action.tankAction == 'taunt' then
            navStop()
            Actors.broadcastTauntDone()
            _forceEngage = true
        elseif action and (action.tankAction == 'engage'
            or action.tankAction == 'return_camp') then
            navStop()
        elseif action and action.tankAction == 'reposition' then
            endDragStep(action)
        end
        restorePrimary(action)
    end,
})

module.onLeaseFinalizing = function(self, action, reason)
    if _backHeld then
        endDragStep(action)
    end

    local navActive = safe(function() return mq.TLO.Navigation.Active() end, false) == true
    if navActive then
        navStop()
        _cleanupStableSamples = 0
        return false, 'stopping_navigation'
    end

    if self.dirtyEffects or reason == 'orphan_recovery' then
        _cleanupStableSamples = _cleanupStableSamples + 1
        if _cleanupStableSamples < 2 then
            return false, 'confirming_navigation_stopped'
        end
    end

    _cleanupStableSamples = 0
    self:markDirtyEffects(false)
    return true
end

mq.bind('/sk_tank', function(command)
    command = tostring(command or 'status'):lower()
    if command == 'stop' then
        navStop()
        module:stop()
        echo('Stop requested')
        return
    end
    local owner = module.state and module.state.lease
    echo('running=%s class=%s mode=%s tier=%s ownsLease=%s pending=%s reason=%s',
        tostring(module.running), tostring(_classShort), tostring(_settings.CombatMode or 'off'),
        tostring(module.priority), tostring(module:ownsLease()),
        tostring(_pending and _pending.name or '-'), tostring(_lastReason))
    echo('primary=%s(%d) coordinatorLeaseHolder=%s last=%s haters=%d deficits=%d',
        _primaryName ~= '' and _primaryName or '-', _primaryId,
        tostring(owner and owner.holderModule or '-'), tostring(_lastAction),
        tonumber(Cache.xtarget.count) or 0, tonumber(Cache.xtarget.aggroDeficitCount) or 0)
    local stateAge = (module.stateReceivedAt and module.stateReceivedAt > 0)
        and (lib.getTimeMs() - module.stateReceivedAt) or -1
    local result = module.lastActionResult or {}
    echo('stateValid=%s stateAgeMs=%d boot=%s leasePending=%s lastRequestOk=%s requestErr=%s lastResult=%s:%s',
        tostring(module:hasValidState()), stateAge, tostring(module.coordinatorBootId or '-'),
        tostring(module.currentRequestId ~= nil and not module:ownsLease()),
        tostring(module.lastRequestSendOk),
        tostring(module.lastRequestSendError or '-'),
        tostring(result.phase or '-'), tostring(result.reason or '-'))
end)

Cache.init()
module:run(50)

return module
