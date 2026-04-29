-- F:/lua/sidekick-next/sk_disciplines.lua
-- Discipline / burn-ability priority module.
-- Acts on the DPS priority slot (priority 4). Each tick, builds the
-- predicate ctx, asks discipline_engine for the first ready ability
-- whose condition predicate fires, and claims + executes it.
--
-- Self-gates: the script exits without entering its run loop if the
-- player's class config doesn't define any discLines/aaLines or any
-- defaultConditions. That means casters with no disciplines (no class
-- config disc surface) silently no-op; tank/melee classes get auto-
-- discipline rotation.
--
-- Coordination with sk_dps: both modules sit at DPS priority. In
-- practice they serve different classes — a CLR has nuke spells and no
-- discipline conditions; a WAR has no caster spells and a full
-- defaultConditions table. If a class supplies both, sk_disciplines
-- runs first by alphabetical module ordering and effectively shares the
-- DPS slot with sk_dps.
--
-- Burn semantics: predicates that gate on `ctx.burn` only fire when the
-- user's BurnNow setting is on. Toggle it with /sk_burn (registered in
-- this module's main loop body).

local mq = require('mq')
local lib = require('sidekick-next.sk_lib')
local ModuleBase = require('sidekick-next.sk_module_base')
local lazy = require('sidekick-next.utils.lazy_require')

local Engine = require('sidekick-next.utils.discipline_engine')
local getConfigLoader = lazy('sidekick-next.utils.class_config_loader')
local getCore         = lazy('sidekick-next.utils.core')

local module = ModuleBase.create('disciplines', lib.Priority.DPS)

-------------------------------------------------------------------------------
-- Settings access
-------------------------------------------------------------------------------

local function disciplinesEnabled()
    local Core = getCore()
    if not (Core and Core.Settings) then return true end
    local v = Core.Settings.DisciplinesEnabled
    return v ~= false  -- default true
end

local function setBurn(value)
    local Core = getCore()
    if not Core then return end
    if Core.set then
        Core.set('BurnNow', value == true)
    elseif Core.Settings then
        Core.Settings.BurnNow = value == true
        if Core.save then pcall(Core.save) end
    end
end

local function getBurn()
    local Core = getCore()
    return Core and Core.Settings and Core.Settings.BurnNow == true or false
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
local _pendingAction = nil
local _pendingComputedAt = 0
local PENDING_TTL_MS = 250  -- accept a freshly-picked action for this long

-- Default: restrict picks to disciplines and AAs so we never steal
-- heal/nuke ownership from the heal-intelligence module or sk_dps. A
-- class config can override by setting `M.allowKindsInRotation` —
-- e.g., ENC wants {'aa','disc','spell'} since its rotation is
-- predominantly spells (mez/tash/slow/nukes) and there is no
-- competing ENC nuke module.
local DEFAULT_ALLOW_KINDS = { aa = true, disc = true }

local function classAllowKinds(cfg)
    if not (cfg and cfg.allowKindsInRotation) then return DEFAULT_ALLOW_KINDS end
    local set = {}
    for _, k in ipairs(cfg.allowKindsInRotation) do set[k] = true end
    if not next(set) then return DEFAULT_ALLOW_KINDS end
    return set
end

local function pickPendingAction()
    if not disciplinesEnabled() then return nil end
    if not _classConfig then return nil end
    local ctx = Engine.buildContext()
    if not ctx then return nil end
    return Engine.pickReadyAbility(_classConfig, ctx,
        { allowKinds = classAllowKinds(_classConfig) })
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
    -- Send need hints so the coordinator knows whether disciplines can act.
    if not disciplinesEnabled() then
        self:sendNeed(false, nil, 'disabled')
        return
    end
    local action = refreshPending(self)
    if action then
        self:sendNeed(true, 500, string.format('%s:%s', action.kind, action.setName))
    else
        self:sendNeed(false, nil, 'no_ready_ability')
    end
end

module.shouldAct = function(self)
    if not self:hasValidState() then return false end
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
    local sel = selectorFor(action.condKey)
    if sel == 'mez_target' then
        local CC = getCC()
        if not (CC and CC.getBestMezTarget) then return nil, false end
        local id, name = CC.getBestMezTarget()
        if not id or id <= 0 then return nil, false end
        if CC.claimTarget then CC.claimTarget(id, name) end
        if CC.broadcastClaim then pcall(CC.broadcastClaim, id, name) end
        return id, true
    end
    -- Default: use current target.
    local target = mq.TLO.Target
    if target and target() then
        local id = lib.safeNum(function() return target.ID() end, 0)
        if id > 0 then return id, false end
    end
    -- Fall back to self for self-targeted abilities (runes, self-buffs).
    local me = mq.TLO.Me
    return lib.safeNum(function() return me.ID() end, 0), false
end

module.getAction = function(self)
    local action = refreshPending(self)
    if not action then return nil end

    local targetId, claimedTarget = acquireTargetFor(action)
    if not targetId or targetId <= 0 then
        -- Couldn't get a valid target (e.g., mez selector found no haters).
        -- Drop the pending pick so onTick re-evaluates next cycle.
        _pendingAction = nil
        return nil
    end

    local kindMap = {
        aa    = lib.ActionKind.USE_AA,
        disc  = 'use_disc',
        spell = lib.ActionKind.CAST_SPELL,
    }

    return {
        kind           = kindMap[action.kind] or 'use_disc',
        name           = action.name,
        setName        = action.setName,
        condKey        = action.condKey,
        targetId       = targetId,
        claimedTarget  = claimedTarget,
        idempotencyKey = string.format('disc:%s:%d:%d', action.setName, targetId, lib.getTimeMs()),
        reason         = string.format('%s %s', action.kind, action.setName),
        -- Echo the engine's classification so executeAction can fire the
        -- right slash command without re-classifying.
        engineKind = action.kind,
    }
end

local function awaitNotCasting(maxMs)
    local start = lib.getTimeMs()
    mq.delay(150)
    while lib.isCasting() do
        mq.delay(50)
        if (lib.getTimeMs() - start) > maxMs then break end
    end
end

--- Ensure /target id <id> locks in the requested target before we cast.
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
    if not self:ownsAction() then return false, 'no_ownership' end
    local action = self.state.castOwner and self.state.castOwner.action
    if not action then return false, 'no_action' end

    -- Discard the cached pick now that we've committed to it; the next
    -- tick will recompute fresh.
    _pendingAction = nil
    _pendingComputedAt = 0

    -- Lock the chosen target before casting. For mez/cc selectors this
    -- is critical — the engine's predicate may have evaluated against a
    -- different live target than the one we should cast on.
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

    -- AAs and spells start a cast bar; disciplines are instant. Wait for
    -- the cast bar where applicable so we don't immediately try to fire
    -- another ability on top of an in-progress one.
    if action.engineKind == 'aa' or action.engineKind == 'spell' then
        awaitNotCasting(8000)
    else
        -- Disciplines fire instantly; tiny settle delay so ActiveDisc
        -- updates before the next tick's predicate evaluation.
        mq.delay(100)
    end

    -- For successful mez casts, automation/cc.lua's mq.event handler
    -- ('sidekick_cc_mezzed') fires asynchronously and releases the claim
    -- itself. We don't release here unconditionally — that would create
    -- a window where another mezzer could double-cast on the same mob
    -- while our mez is still resolving.

    return true, 'completed'
end

-------------------------------------------------------------------------------
-- /sk_burn slash command — toggles BurnNow.
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
    -- bind anyway so the user can flip BurnNow on any character — it's
    -- consumed by clickies and other features beyond just disciplines.
    registerBurnBind()
    return module
end

if not configHasDisciplines(_classConfig) then
    -- Class is opted in but the class config has no disciplines/AAs/
    -- conditions defined yet. Bind /sk_burn for consistency, exit run.
    registerBurnBind()
    return module
end

registerBurnBind()
module:run(50)

return module
