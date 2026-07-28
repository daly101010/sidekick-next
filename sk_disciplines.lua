-- F:/lua/sidekick-next/sk_disciplines.lua
-- Discipline / burn-ability priority module.
-- Acts on the DPS priority slot (priority 4). Each tick, builds the
-- predicate ctx, asks discipline_engine for the first ready ability
-- whose condition predicate fires, and claims + executes it.
--
-- Self-gates: the script exits without entering its run loop if the
-- player's class config doesn't define any discLines/aaLines or any
-- defaultConditions. Spell-gem casts are never owned by this worker;
-- casters without a discipline surface silently no-op.
--
-- Coordination with sk_dps: both modules sit at DPS priority. In
-- practice they serve different classes — a CLR has nuke spells and no
-- discipline conditions; a WAR has no caster spells and a full
-- defaultConditions table. If a class supplies both, sk_disciplines
-- runs first by alphabetical module ordering and effectively shares the
-- DPS slot with sk_dps.
--
-- Burn semantics: predicates that gate on `ctx.burn` only fire when the
-- user's BurnActive setting is on. Toggle it with /sk_burn (registered in
-- this module's main loop body).

local mq = require('mq')
local lib = require('sidekick-next.sk_lib')
local ModuleBase = require('sidekick-next.sk_module_base')
local lazy = require('sidekick-next.utils.lazy_require')
local Cache = require('sidekick-next.utils.runtime_cache')

local Engine = require('sidekick-next.utils.discipline_engine')
local getConfigLoader = lazy('sidekick-next.utils.class_config_loader')
local getAbilityLoader = lazy('sidekick-next.abilities.loader')
local getAbilities     = lazy('sidekick-next.utils.abilities')

local module = ModuleBase.create('disciplines', lib.Priority.DPS)

-------------------------------------------------------------------------------
-- Settings access
-------------------------------------------------------------------------------

local loadDynamicAbilities

local function getSettings()
    return lib.getSettings and lib.getSettings() or {}
end

local function disciplinesEnabled()
    local settings = getSettings()
    local v = settings.DisciplinesEnabled
    return v ~= false  -- default true
end

local function setBurn(value)
    mq.cmdf('/sk_next_set_burn %s', value == true and 'on' or 'off')
end

local function getBurn()
    local settings = getSettings()
    return settings.BurnActive == true
end

-------------------------------------------------------------------------------
-- Class config + class gating
-------------------------------------------------------------------------------

local function myClassShort()
    return lib.safeTLO(function() return mq.TLO.Me.Class.ShortName() end, '') or ''
end

local function loadClassConfig()
    local CL = getConfigLoader()
    if not (CL and CL.load) then return nil end
    local cls = myClassShort()
    if cls == '' then return nil end
    return CL.load(cls)
end

-- Default class set — tank and melee classes that benefit from the
-- generic predicate-driven discipline rotation. Caster/healer classes
-- (CLR/DRU/SHM/WIZ/MAG/NEC/ENC) own their rotations through dedicated
-- modules (healing intelligence, sk_dps caster path, sk_resurrection,
-- the upcoming ENC rotation). RNG is excluded by default because its
-- spell-rotation handling overlaps with sk_dps; can be opted in via
-- class config flag.
local DEFAULT_CLASSES = {
    WAR = true, PAL = true, SHD = true,
    BER = true, MNK = true, ROG = true,
}
local TANK_CLASSES = require('sidekick-next.utils.class_roles').TANK_CLASSES

local function shouldRunForClass(cfg, classShort)
    -- Explicit class-config opt-out wins.
    if cfg and cfg.useDisciplineEngine == false then return false end
    -- Explicit class-config opt-in wins next.
    if cfg and cfg.useDisciplineEngine == true then return true end
    -- Otherwise fall back to the default class set.
    return DEFAULT_CLASSES[classShort] == true
end

local function configHasDisciplines(cfg)
    if not cfg then return false end
    local hasConds = cfg.defaultConditions and next(cfg.defaultConditions) ~= nil
    local hasDiscs = cfg.discLines and next(cfg.discLines) ~= nil
    local hasAAs   = cfg.aaLines and next(cfg.aaLines) ~= nil
    -- Need at least one condition to act on AND at least one resolvable
    -- ability table to read from.
    return hasConds and (hasDiscs or hasAAs)
end

-------------------------------------------------------------------------------
-- Pick + cache the action between shouldAct → getAction → executeAction so
-- those callbacks see consistent state from a single ctx evaluation.
-------------------------------------------------------------------------------

local _classConfig = nil
local _dynamicAbilities = nil
local _dynamicClass = nil
local _pendingAction = nil
local _pendingComputedAt = 0
local PENDING_TTL_MS = 250  -- accept a freshly-picked action for this long

-- Hard ownership boundary: this worker may use disciplines, AAs, and trained
-- skills only. Class configuration cannot widen this set to spell-gem casts;
-- those belong to the dedicated DPS, CC, healing, buff, and support workers.
local ALLOWED_ACTION_KINDS = { aa = true, disc = true, skill = true }

local function isAllowedActionKind(kind)
    return ALLOWED_ACTION_KINDS[tostring(kind or ''):lower()] == true
end

-- Defense in depth for legacy condition names that belong to sk_cc.
local COORDINATOR_OWNED_CONDITIONS = {
    doSingleMez = true,
    doFastMez = true,
    doAEMez = true,
    doPBAEMez = true,
}

local function ownedTankConditions(cfg)
    local excluded = {}
    for key, value in pairs(COORDINATOR_OWNED_CONDITIONS) do excluded[key] = value end
    local settings = getSettings()
    if tostring(settings.CombatMode or 'off'):lower() == 'tank'
        and TANK_CLASSES[myClassShort()] == true
        and cfg and type(cfg.categoryOverrides) == 'table' then
        for condKey, category in pairs(cfg.categoryOverrides) do
            category = tostring(category or ''):lower()
            if category == 'emergency' or category == 'defenses' or category == 'aggro' then
                excluded[condKey] = true
            end
        end
    end
    return excluded
end

function loadDynamicAbilities()
    local cls = myClassShort()
    if cls == '' then return {} end
    if _dynamicAbilities and _dynamicClass == cls then return _dynamicAbilities end

    local Loader = getAbilityLoader()
    local Abilities = getAbilities()
    local list = (Loader and Loader.loadForClass and Loader.loadForClass(cls)) or {}
    if Abilities and Abilities.filterAvailable then
        list = Abilities.filterAvailable(list)
    end
    _dynamicClass = cls
    _dynamicAbilities = list or {}
    return _dynamicAbilities
end

local function hasDynamicDisciplines()
    for _, def in ipairs(loadDynamicAbilities()) do
        if type(def) == 'table' then
            local kind = tostring(def.kind or ''):lower()
            if kind == 'disc' or kind == 'aa' then return true end
        end
    end
    return false
end

local function dynamicAbilityReady(def)
    if type(def) ~= 'table' then return nil end
    local me = mq.TLO.Me
    if not (me and me()) then return nil end

    local kind = tostring(def.kind or 'aa'):lower()
    if kind == 'aa' then
        if def.altID and me.AltAbilityReady then
            local ok, ready = pcall(function() return me.AltAbilityReady(tonumber(def.altID))() == true end)
            if ok and ready then return def.altName, 'aa' end
        end
        if def.altName and me.AltAbilityReady then
            local ok, ready = pcall(function() return me.AltAbilityReady(def.altName)() == true end)
            if ok and ready then return def.altName, 'aa' end
        end
    elseif kind == 'disc' then
        local Helpers = require('sidekick-next.lib.helpers')
        local discName = tostring(def.discName or def.altName or '')
        for _, candidate in ipairs(Helpers.discNameCandidates(discName)) do
            local ok, ready = pcall(function() return me.CombatAbilityReady(candidate)() == true end)
            if ok and ready then return candidate, 'disc' end
        end
    end

    return nil
end

local function pickDynamicCooldownAction(ctx)
    local settings = getSettings()
    local Abilities = getAbilities()
    if not (Abilities and Abilities.MODE and Abilities.CONTEXT) then return nil end

    local inCombat = ctx and ctx.combat == true
    for _, def in ipairs(loadDynamicAbilities()) do
        if type(def) == 'table' then
            local kind = tostring(def.kind or ''):lower()
            if kind == 'disc' or kind == 'aa' then
                local mode = def.modeKey and tonumber(settings[def.modeKey]) or Abilities.MODE.ON_DEMAND
                local enabled = def.settingKey and settings[def.settingKey] == true
                if enabled and mode == Abilities.MODE.ON_COOLDOWN then
                    local contextKey = tostring(def.settingKey) .. 'Context'
                    local context = tonumber(settings[contextKey]) or Abilities.CONTEXT.COMBAT
                    local contextOk = context == Abilities.CONTEXT.ANYTIME
                        or (context == Abilities.CONTEXT.COMBAT and inCombat)
                        or (context == Abilities.CONTEXT.OUT_OF_COMBAT and not inCombat)
                    if contextOk then
                        if Abilities.hasActiveBuffSongOrAura and Abilities.hasActiveBuffSongOrAura(def) then
                            goto dynamic_continue
                        end
                        local name, resolvedKind = dynamicAbilityReady(def)
                        if name then
                            return {
                                name = name,
                                kind = resolvedKind,
                                setName = def.settingKey or name,
                                condKey = def.modeKey or def.settingKey,
                                targetId = lib.safeNum(function() return mq.TLO.Me.ID() end, 0),
                                dynamic = true,
                            }
                        end
                    end
                end
            end
        end
        ::dynamic_continue::
    end
    return nil
end

local function pickPendingAction()
    if not disciplinesEnabled() then return nil end
    local ctx = Engine.buildContext()
    if not ctx then return nil end

    local dynamic = pickDynamicCooldownAction(ctx)
    if dynamic then return dynamic end

    if not _classConfig then return nil end
    local excluded = ownedTankConditions(_classConfig)
    -- The engine also serves sk_tank, where spell kinds are valid. Keep this
    -- worker's boundary explicit and reject anything outside it even if a
    -- class config or future engine change attempts to return one.
    local action = Engine.pickReadyAbility(_classConfig, ctx, {
        allowKinds = ALLOWED_ACTION_KINDS,
        excludeConditions = excluded,
    })
    if not action then return nil end
    if not isAllowedActionKind(action.kind) then
        lib.log('error', module.name,
            'rejected non-discipline action from picker: %s (%s)',
            tostring(action.name or '?'), tostring(action.kind or '?'))
        return nil
    end
    return action
end

local function refreshPending(self)
    local now = lib.getTimeMs()
    if _pendingAction and (now - _pendingComputedAt) < PENDING_TTL_MS then
        return _pendingAction
    end
    _pendingAction = pickPendingAction()
    _pendingComputedAt = now
    return _pendingAction
end

-------------------------------------------------------------------------------
-- Module callbacks
-------------------------------------------------------------------------------

module.onTick = function(self)
    -- Per-process runtime cache: the 'mez_target' selector resolves through
    -- CC.getBestMezTarget, which reads Cache.xtarget.haters in THIS process
    -- — empty forever unless someone ticks it.
    if not self.componentMode then Cache.tick() end
    if self.componentMode and self.domainKillAuthorized ~= true then
        _pendingAction = nil
        _pendingComputedAt = 0
        self:setIntent(false, nil,
            self.domainKillGateReason or 'kill_not_authorized')
        return
    end
    if not disciplinesEnabled() then
        self:setIntent(false, nil, 'disabled')
        return
    end
    local action = refreshPending(self)
    if action then
        self:setIntent(true, nil, string.format('%s:%s', action.kind, action.setName))
    else
        self:setIntent(false, nil, 'no_ready_ability')
    end
end

module.shouldAct = function(self)
    if not self:hasValidState() then return false end
    if self.componentMode and self.domainKillAuthorized ~= true then return false end
    if not disciplinesEnabled() then return false end
    return refreshPending(self) ~= nil
end

-- Per-class config can declare a special target selector for a given
-- condition key. Recognized values:
--   'mez_target' -> ask automation/cc.lua for the next best mez target
--                   (claimed via cc.claimTarget so other mezzers back off).
--   'current_target' / nil -> use the current EQ target as-is.
-- Future: 'ma_target', 'lowest_hp_xtarget', etc.
local getCC = lazy('sidekick-next.automation.cc')

local function selectorFor(condKey)
    if not (_classConfig and _classConfig.targetSelector) then return nil end
    return _classConfig.targetSelector[condKey]
end

--- Acquire a target for the action. Returns (targetId, claimed) where
--- `claimed` indicates we placed a CC claim that should be released on
--- failure paths. nil targetId means "skip this action — no valid target".
local function acquireTargetFor(action)
    if action and action.targetId and action.targetId > 0 then
        return action.targetId, false, 'explicit'
    end
    local sel = selectorFor(action.condKey)
    if sel == 'mez_target' then
        local CC = getCC()
        if not (CC and CC.getBestMezTarget) then return nil, false, 'control' end
        local id, name = CC.getBestMezTarget()
        if not id or id <= 0 then return nil, false, 'control' end
        if CC.claimTarget then CC.claimTarget(id, name) end
        if CC.broadcastClaim then pcall(CC.broadcastClaim, id, name) end
        return id, true, 'control'
    end
    -- In the consolidated Combat host, Tank authorization names the exact
    -- kill target. Never let a temporary peel/manual/heal target leak into a
    -- discipline just because some positive primary exists elsewhere.
    if module.componentMode and module.domainKillAuthorized == true then
        local id = tonumber(module.domainKillTargetId) or 0
        if id > 0 then return id, false, 'kill' end
        return nil, false, 'kill'
    end
    -- Default: use current target.
    local target = mq.TLO.Target
    if target and target() then
        local id = lib.safeNum(function() return target.ID() end, 0)
        if id > 0 then return id, false, 'legacy_current' end
    end
    -- Fall back to self for self-targeted abilities (runes, self-buffs).
    local me = mq.TLO.Me
    return lib.safeNum(function() return me.ID() end, 0), false, 'self'
end

module.getAction = function(self)
    local action = refreshPending(self)
    if not action then return nil end
    if not isAllowedActionKind(action.kind) then
        lib.log('error', module.name,
            'rejected non-discipline action before claim: %s (%s)',
            tostring(action.name or '?'), tostring(action.kind or '?'))
        _pendingAction = nil
        _pendingComputedAt = 0
        return nil
    end

    local targetId, claimedTarget, targetRole = acquireTargetFor(action)
    if not targetId or targetId <= 0 then
        -- Couldn't get a valid target (e.g., mez selector found no haters).
        -- Drop the pending pick so onTick re-evaluates next cycle.
        _pendingAction = nil
        return nil
    end

    local kindMap = {
        aa    = lib.ActionKind.USE_AA,
        disc  = 'use_disc',
        skill = lib.ActionKind.USE_SKILL,
    }

    return {
        kind           = kindMap[action.kind],
        name           = action.name,
        setName        = action.setName,
        condKey        = action.condKey,
        targetId       = targetId,
        claimedTarget  = claimedTarget,
        requiresKillTarget = targetRole == 'kill',
        idempotencyKey = string.format('disc:%s:%d:%d', action.setName, targetId, lib.getTimeMs()),
        reason         = string.format('%s %s', action.kind, action.setName),
        -- Echo the engine's classification so executeAction can fire the
        -- right slash command without re-classifying.
        engineKind = action.kind,
    }
end

local function awaitNotCasting(self, maxMs)
    local start = lib.getTimeMs()
    mq.delay(150)
    while lib.isCasting() do
        mq.delay(50)
        if not self:ownsLease() then return false end
        self:renewLease()
        if (lib.getTimeMs() - start) > maxMs then break end
    end
    return true
end

--- Ensure /target id <id> locks in the requested target before the action.
--- Returns true if locked, false if the spawn no longer exists.
local function ensureTarget(targetId)
    if not targetId or targetId <= 0 then return false end
    local current = mq.TLO.Target
    if current and current() and lib.safeNum(function() return current.ID() end, 0) == targetId then
        return true
    end
    mq.cmdf('/target id %d', targetId)
    mq.delay(150, function()
        local t = mq.TLO.Target
        return t and t() and lib.safeNum(function() return t.ID() end, 0) == targetId
    end)
    local t = mq.TLO.Target
    return t and t() and lib.safeNum(function() return t.ID() end, 0) == targetId
end

module.executeAction = function(self)
    if not self:ownsLease() then return false, 'no_lease' end
    local action = self:getLeaseAction()
    if not action then return false, 'no_action' end

    -- Discard the cached pick now that we've committed to it; the next
    -- tick will recompute fresh.
    _pendingAction = nil
    _pendingComputedAt = 0

    if not isAllowedActionKind(action.engineKind) then
        lib.log('error', module.name,
            'rejected non-discipline action before execution: %s (%s)',
            tostring(action.name or '?'), tostring(action.engineKind or '?'))
        if action.claimedTarget then
            local CC = getCC()
            if CC and CC.releaseClaim then CC.releaseClaim(action.targetId) end
        end
        return true, 'invalid_action_kind'
    end

    -- Lock the chosen target before firing the discipline/AA/skill. For
    -- selectors this is critical — the predicate may have evaluated against a
    -- different live target than the one the action should affect.
    if not ensureTarget(action.targetId) then
        if action.claimedTarget then
            local CC = getCC()
            if CC and CC.releaseClaim then CC.releaseClaim(action.targetId) end
        end
        return true, 'target_lost'
    end

    local fired = Engine.fireAbility({ kind = action.engineKind, name = action.name })
    if not fired then
        lib.log('warn', module.name, 'fireAbility refused: %s (%s)', tostring(action.name), tostring(action.engineKind))
        if action.claimedTarget then
            local CC = getCC()
            if CC and CC.releaseClaim then CC.releaseClaim(action.targetId) end
        end
        return true, 'fire_refused'
    end

    -- Some AAs start a cast bar; disciplines are instant. Wait for
    -- the cast bar where applicable so we don't immediately try to fire
    -- another ability on top of an in-progress one.
    if action.engineKind == 'aa' or action.engineKind == 'spell' then
        if not awaitNotCasting(self, 8000) then return true, 'lease_lost' end
    else
        -- Disciplines and trained skills fire instantly; tiny settle delay so
        -- ActiveDisc/readiness updates before the next predicate evaluation.
        mq.delay(100)
    end

    -- Claimed target cleanup is handled by failure/cancel callbacks below.

    return true, 'completed'
end


-- The legacy callback above is retained only as migration reference and must
-- never be selected by ModuleBase.
module.executeAction = nil
module:enableUnifiedExecutor({
    preflight = function(action)
        _pendingAction = nil
        _pendingComputedAt = 0
        if not isAllowedActionKind(action and action.engineKind) then
            lib.log('error', module.name,
                'rejected non-discipline action in preflight: %s (%s)',
                tostring(action and action.name or '?'),
                tostring(action and action.engineKind or '?'))
            return false, 'invalid_action_kind'
        end
        if action.requiresKillTarget == true
            and (module.domainKillAuthorized ~= true
                or tonumber(action.targetId) ~= tonumber(module.domainKillTargetId)) then
            return false, 'kill_authorization_changed'
        end
        if ensureTarget(tonumber(action.targetId) or 0) then return true end
        if action.claimedTarget then
            local CC = getCC()
            if CC and CC.releaseClaim then CC.releaseClaim(action.targetId) end
        end
        return false, 'target_lost'
    end,
    dispatch = function(action)
        if not isAllowedActionKind(action and action.engineKind) then
            lib.log('error', module.name,
                'rejected non-discipline action at dispatch: %s (%s)',
                tostring(action and action.name or '?'),
                tostring(action and action.engineKind or '?'))
            return false, 'invalid_action_kind'
        end
        local fired = Engine.fireAbility({ kind = action.engineKind, name = action.name })
        if not fired then return false, 'fire_refused' end
        if action.engineKind == 'aa' then return true, nil, 'cast_or_settle' end
        return true, nil, 'settle'
    end,
    onFailure = function(action)
        if action and action.claimedTarget then
            local CC = getCC()
            if CC and CC.releaseClaim then CC.releaseClaim(action.targetId) end
        end
    end,
    onCancel = function(action)
        if action and action.claimedTarget then
            local CC = getCC()
            if CC and CC.releaseClaim then CC.releaseClaim(action.targetId) end
        end
    end,
})

-------------------------------------------------------------------------------
-- /sk_burn slash command — toggles BurnActive.
-------------------------------------------------------------------------------

local function registerBurnBind()
    pcall(function()
        if mq.unbind then pcall(mq.unbind, '/sk_burn') end
    end)
    mq.bind('/sk_burn', function(arg)
        local a = tostring(arg or ''):lower()
        if a == 'on' or a == '1' or a == 'true' then
            setBurn(true)
            mq.cmd('/echo \ag[sk_burn]\ax burn ON')
        elseif a == 'off' or a == '0' or a == 'false' then
            setBurn(false)
            mq.cmd('/echo \ay[sk_burn]\ax burn OFF')
        elseif a == 'status' or a == '' then
            mq.cmdf('/echo [sk_burn] status: %s', getBurn() and 'ON' or 'OFF')
        else
            -- Toggle on any other arg (e.g., 'toggle')
            local newVal = not getBurn()
            setBurn(newVal)
            mq.cmdf('/echo [sk_burn] toggled %s', newVal and 'ON' or 'OFF')
        end
    end)
end

-------------------------------------------------------------------------------
-- Run (gated on class config having disciplines)
-------------------------------------------------------------------------------

_classConfig = loadClassConfig()

if not shouldRunForClass(_classConfig, myClassShort()) then
    -- This class is handled by other modules (healers / casters / pet
    -- classes own their rotations elsewhere). Register the /sk_burn
    -- bind anyway so the user can flip BurnActive on any character — it's
    -- consumed by clickies and other features beyond just disciplines.
    registerBurnBind()
    module.componentDisabled = true
    return module
end

if not configHasDisciplines(_classConfig) and not hasDynamicDisciplines() then
    -- Class is opted in but the class config has no disciplines/AAs/
    -- conditions defined yet. Bind /sk_burn for consistency, exit run.
    registerBurnBind()
    module.componentDisabled = true
    return module
end

registerBurnBind()
module:run(50)

return module
