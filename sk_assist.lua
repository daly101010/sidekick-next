-- Coordinated melee-assist worker.
-- Owns only the target resource; cast-capable workers can continue to own the
-- cast resource at the same priority without racing healing/cure targets.

local mq = require('mq')
local lib = require('sidekick-next.sk_lib')
local ModuleBase = require('sidekick-next.sk_module_base')
local CombatAssist = require('sidekick-next.utils.combatassist')
local Assist = require('sidekick-next.automation.assist')
local CasterAssist = require('sidekick-next.automation.caster_assist')
local Actors = require('sidekick-next.utils.actors_coordinator')

local module = ModuleBase.create('assist', lib.Priority.DPS)
module:enablePeerActors()

local ACTOR_TARGET_TTL_SECONDS = 5
local _settings = nil
local _selectedTarget = nil
local _stickyActorTargetId = nil
local _lastReason = 'init'
local _wasEnabled = false

local function commandEcho(fmt, ...)
    local ok, message = pcall(string.format, fmt, ...)
    print(string.format('\ag[SK Assist]\ax %s', ok and message or tostring(fmt)))
end

local function applySettings()
    _settings = lib.getSettings() or _settings or {}
    local enabled = tostring(_settings.CombatMode or 'off'):lower() == 'assist'
    local engageCondition = tostring(_settings.AssistEngageCondition or 'hp'):lower()
    CombatAssist.apply_config({
        enabled = enabled,
        assist_at = engageCondition == 'tank_aggro' and 100 or _settings.AssistAt,
        assist_rng = _settings.AssistRange,
        assist_mode = _settings.AssistMode,
        assist_name = _settings.AssistName,
        stick_cmd = _settings.StickCommand,
    })
    if _wasEnabled and not enabled then
        CombatAssist.stop()
        _stickyActorTargetId = nil
    end
    _wasEnabled = enabled
    return _settings, enabled
end

local function validateTarget(targetId, source, settings)
    targetId = tonumber(targetId) or 0
    if targetId <= 0 then return nil, 'no_target' end

    local spawn = mq.TLO.Spawn(targetId)
    if not (spawn and spawn()) then return nil, 'target_missing' end
    local targetType = tostring(lib.safeTLO(function() return spawn.Type() end, '') or ''):lower()
    if targetType ~= 'npc' then return nil, 'target_not_npc' end
    if lib.safeTLO(function() return spawn.Dead() end, false) == true then
        return nil, 'target_dead'
    end

    -- Hard engagement radius: after a wipe/rez, sticky targets and stale
    -- tank broadcasts can still name mobs that RESET across the zone —
    -- spawn-valid, alive, often still damaged. Never navigate to a mob
    -- beyond AssistRange; if it isn't near camp, it isn't our fight.
    local dist = lib.safeNum(function() return spawn.Distance3D() end, 999)
    local maxRange = tonumber(settings.AssistRange) or 100
    if dist > maxRange then
        return nil, string.format('beyond_assist_range:%d>%d', math.floor(dist), maxRange)
    end

    local hp = lib.safeNum(function() return spawn.PctHPs() end, 100)
    local engageAt = tonumber(settings.AssistAt) or 97
    local engageCondition = tostring(settings.AssistEngageCondition or 'hp'):lower()
    if engageCondition == 'hp' and hp > engageAt then
        return nil, string.format('above_assist_at:%d>%d', hp, engageAt)
    elseif engageCondition == 'tank_aggro' then
        local tankId = 0
        if tostring(source or ''):find('actor_', 1, true) == 1 then
            tankId = tonumber(Assist.tankId) or 0
        else
            local mainAssist = CombatAssist.get_main_assist_spawn()
            tankId = lib.safeNum(function() return mainAssist.ID() end, 0)
        end
        local targetOfTargetId = lib.safeNum(function() return spawn.TargetOfTarget.ID() end, 0)
        if tankId <= 0 or targetOfTargetId ~= tankId then
            return nil, 'waiting_tank_aggro'
        end
    end

    return {
        id = targetId,
        source = source or 'unknown',
        hp = hp,
    }, nil
end

local function actorTarget(settings)
    local state = Actors.getTankState and Actors.getTankState() or nil
    if type(state) ~= 'table' or tonumber(state.updatedAt) == nil
        or (os.clock() - tonumber(state.updatedAt)) > ACTOR_TARGET_TTL_SECONDS then
        _stickyActorTargetId = nil
        return nil, 'actor_target_stale'
    end

    local mode = tostring(settings.AssistTargetMode or 'sticky'):lower()
    local primaryId = tonumber(state.primaryTargetId) or 0
    Assist.tankId = tonumber(state.tankId) or Assist.tankId
    Assist.tankName = tostring(state.tankName or Assist.tankName or '')
    local targetId
    if mode == 'follow' then
        targetId = tonumber(state.currentTargetId) or 0
        if targetId <= 0 then targetId = primaryId end
    else
        local sticky = validateTarget(_stickyActorTargetId, 'actor_sticky', settings)
        if sticky then return sticky, nil end
        _stickyActorTargetId = primaryId > 0 and primaryId or nil
        targetId = _stickyActorTargetId
    end

    return validateTarget(targetId, 'actor_' .. mode, settings)
end

local function selectTarget(settings)
    local target, actorReason = actorTarget(settings)
    if target then return target, nil end

    local id = CombatAssist.get_assist_target()
    local fallback, fallbackReason = validateTarget(id, 'assist_' .. tostring(settings.AssistMode or 'group'), settings)
    if fallback then return fallback, nil end
    return nil, fallbackReason or actorReason or 'no_target'
end

module.onTick = function(self)
    local settings, enabled = applySettings()
    if not enabled then
        _selectedTarget = nil
        _lastReason = 'mode_off'
        self:sendNeed(false, nil, _lastReason)
        return
    end
    if CasterAssist.isPureCaster() then
        _selectedTarget = nil
        _lastReason = 'pure_caster'
        self:sendNeed(false, nil, _lastReason)
        return
    end

    local hadTarget = _selectedTarget ~= nil
    local target, reason = selectTarget(settings)
    _selectedTarget = target
    if hadTarget and not target then CombatAssist.stop() end
    _lastReason = target and ('ready:' .. tostring(target.source)) or tostring(reason or 'no_target')
    self:sendNeed(target ~= nil, target and 500 or nil, _lastReason)
end

module.shouldAct = function()
    return _wasEnabled and _selectedTarget ~= nil
end

module.getAction = function()
    local target = _selectedTarget
    if not target then return nil end
    return {
        kind = 'assist_target',
        type = lib.ClaimType.TARGET,
        name = 'Melee assist',
        targetId = target.id,
        expectsCastStart = false,
        claimTtlMs = 2000,
        idempotencyKey = string.format('assist:%d', target.id),
        reason = string.format('%s hp=%d', tostring(target.source), tonumber(target.hp) or 0),
    }
end

module.executeAction = function(self)
    local settings, enabled = applySettings()
    if not enabled then
        CombatAssist.stop()
        return true, 'mode_off'
    end
    if CasterAssist.isPureCaster() then
        CombatAssist.stop()
        return true, 'pure_caster'
    end

    local owner = self.state and self.state.targetOwner
    local claimedId = tonumber(owner and owner.targetId) or 0
    local target, reason = selectTarget(settings)
    if not target then
        CombatAssist.stop()
        return true, reason or 'target_lost'
    end
    if target.id ~= claimedId then
        return true, 'target_changed'
    end

    if tostring(target.source):find('actor_', 1, true) == 1 then
        Assist.currentTargetId = target.id
        if Assist.shouldEngage(settings) then
            Assist.engageTarget(target.id, settings)
        else
            CombatAssist.stop()
        end
    else
        CombatAssist.tick()
    end

    -- Retain the target lease until it expires, changes, or a higher-priority
    -- module causes the coordinator to revoke it.
    return false, 'holding_target'
end

mq.bind('/sk_assist', function(cmd)
    cmd = tostring(cmd or 'status'):lower()
    if cmd == 'stop' then
        CombatAssist.stop()
        module:stop()
        commandEcho('Stop requested')
    elseif cmd == 'status' or cmd == '' then
        local settings, enabled = applySettings()
        local target, reason = selectTarget(settings)
        local owner = module.state and module.state.targetOwner
        commandEcho(
            'enabled=%s priority=%s statePrio=%s ownsTarget=%s targetOwner=%s target=%s source=%s hp=%s reason=%s last=%s',
            tostring(enabled), tostring(module:isMyPriority()),
            tostring(module.state and module.state.activePriority), tostring(module:ownsTarget()),
            tostring(owner and owner.module or 'nil'), tostring(target and target.id or 'none'),
            tostring(target and target.source or 'none'), tostring(target and target.hp or 'none'),
            tostring(reason or 'ready'), tostring(_lastReason))
    else
        commandEcho('Usage: /sk_assist status|stop')
    end
end)

Assist.init({ CombatAssist = CombatAssist })
module:run(50)
CombatAssist.stop()

return module
