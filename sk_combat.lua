local mq = require('mq')
local lib = require('sidekick-next.sk_lib')
local Domain = require('sidekick-next.utils.domain_orchestrator')
local Cache = require('sidekick-next.utils.runtime_cache')
local Actors = require('sidekick-next.utils.actors_coordinator')
local ActionExecutor = require('sidekick-next.utils.action_executor')
local CombatAssist = require('sidekick-next.utils.combatassist')

local OFFENSIVE_COMPONENTS = {
    debuff = true,
    assist = true,
    disciplines = true,
    dps = true,
}

local module = Domain.create({
    name = 'combat',
    priority = lib.Priority.CROWD_CONTROL,
    components = { 'cc', 'feign', 'debuff', 'assist', 'disciplines', 'dps' },
    cache = true,
    prepareTick = function(host, components)
        local targetId, _, reason =
            Actors.getPrimaryKillAuthorization(5)
        -- A selected main assist need not be a Tank-mode character. When no
        -- fresh Tank publication exists, resolve the configured Group/Raid/
        -- by-name assist target directly. A fresh zero publication remains an
        -- authoritative hold because CombatAssist deliberately will not fall
        -- through while that state is fresh.
        if (tonumber(targetId) or 0) <= 0 then
            local settings = lib.getSettings() or {}
            local assistMode = tostring(settings.AssistMode or 'group'):lower()
            local raidMembers = lib.safeNum(function()
                return mq.TLO.Raid.Members()
            end, 0)
            if assistMode == 'group' and raidMembers > 0 then
                assistMode = 'raid1'
            end
            CombatAssist.apply_config({
                enabled = tostring(settings.CombatMode or 'off'):lower() == 'assist',
                assist_at = settings.AssistAt,
                assist_rng = settings.AssistRange,
                assist_mode = assistMode,
                assist_name = settings.AssistName,
                stick_cmd = settings.StickCommand,
            })
            local fallbackId = CombatAssist.get_assist_target()
            if (tonumber(fallbackId) or 0) > 0 then
                targetId = tonumber(fallbackId)
                reason = 'assist_source:' .. assistMode
            end
        end
        local hostileActivity = Cache.hasAutoHaterActivity()
        local authorized = (tonumber(targetId) or 0) > 0
        -- A positive Tank primary is already the group's explicit kill
        -- declaration. Requiring this character's local Auto-Hater slot too
        -- deadlocks DPS clients whose aggro list has not populated before
        -- they begin acting.
        local combatActivity = hostileActivity or authorized

        host.domainHostileActivity = combatActivity
        host.domainKillAuthorized = authorized
        host.domainKillTargetId = authorized and tonumber(targetId) or 0
        host.domainKillGateReason = tostring(reason or 'primary_absent')
        host.domainCacheEnabled = combatActivity

        -- CC/charm housekeeping and managed-feign safety use their own narrow
        -- observations. The shared self/target/group/XTarget snapshot sleeps
        -- completely until the Auto-Hater sentinel opens it.
        Cache.setHeavyScanEnabled(combatActivity)

        for _, component in ipairs(components) do
            component.domainHostileActivity = combatActivity
            component.domainKillAuthorized = authorized
            component.domainKillTargetId = host.domainKillTargetId
            component.domainKillGateReason = host.domainKillGateReason
        end
    end,
    getIdleReason = function(host)
        if host.domainKillAuthorized ~= true then
            return 'kill_gate:' .. tostring(host.domainKillGateReason or 'primary_absent')
        end
        return 'idle'
    end,
    selectCandidate = function(_, candidates)
        if not Domain.feignManaged() then return candidates[1] end
        for _, candidate in ipairs(candidates) do
            if candidate.component.componentName == 'feign' then return candidate end
        end
        -- While managed feign is active, suppress every combat candidate even
        -- when it is not yet safe to stand.
        return false
    end,
    shouldSuppressActive = function(host, active)
        if Domain.feignManaged() and active ~= 'feign' then return true end
        if not OFFENSIVE_COMPONENTS[active] then return false end
        local action = host.currentAction or {}
        -- Stopping a previously-owned assist episode is cleanup, not new
        -- offensive work, and must remain possible after authorization ends.
        if active == 'assist' and action.kind == 'assist_stop' then return false end
        if host.domainKillAuthorized ~= true then return true end
        local actionTarget = tonumber(action.targetId) or 0
        return actionTarget > 0 and actionTarget ~= host.domainKillTargetId
    end,
    shouldInterrupt = function(host, active, winner)
        if winner == 'feign' and Domain.feignManaged() then return true end
        if winner ~= 'cc' or active == 'cc' then return false end

        -- CC owns the next Combat turn, but it must not repeatedly stop a
        -- spell that has already crossed the mutation boundary. WAITING_START
        -- covers the short interval between /cast and MQ exposing the cast
        -- bar; RUNNING covers the observed cast. Queued work remains safely
        -- preemptible because no command has been issued yet.
        local current = host.currentAction or {}
        local executor = ActionExecutor.getStatus and ActionExecutor.getStatus() or nil
        local phase = tostring(executor and executor.phase or '')
        local castInFlight = tostring(current.kind or '') == lib.ActionKind.CAST_SPELL
            and (phase == ActionExecutor.PHASE.WAITING_START
                or phase == ActionExecutor.PHASE.RUNNING)
        if castInFlight then
            host.domainDeferredInterrupt = 'cc_after_cast'
            return false
        end
        return true
    end,
})

local function echo(fmt, ...)
    local ok, text = pcall(string.format, fmt, ...)
    print(string.format('%s \ag[SK Combat]\ax %s',
        lib.timestampPrefix(), ok and text or tostring(fmt)))
end

mq.bind('/sk_combat', function()
    local targetId, _, authorization =
        Actors.getPrimaryKillAuthorization(5)
    local actorDebug = Actors.getDebugState and Actors.getDebugState() or {}
    local primary = actorDebug.primaryTarget or {}
    local mainTank = primary.mainTank or {}
    local mainAssist = primary.mainAssist or {}
    local selected = primary.selectedAuthority or {}
    echo('killTarget=%s authorization=%s stage=%s reason=%s ageMs=%s',
        tostring(targetId or 'none'), tostring(authorization or 'unknown'),
        tostring(primary.stage or 'waiting'),
        tostring(primary.reason or 'no_target_primary_packet'),
        tostring(primary.ageMs or 'never'))
    echo('sender=%s@%s route=%s:%s target=%s(%d) claimedTankId=%d seq=%d',
        tostring(primary.senderCharacter or '-'),
        tostring(primary.senderServer or '-'),
        tostring(primary.senderScript or '-'),
        tostring(primary.senderMailbox or '-'),
        tostring(primary.targetName or '-'),
        tonumber(primary.targetId) or 0,
        tonumber(primary.claimedTankId) or 0,
        tonumber(primary.sequence) or 0)
    echo('eqMainTank=%s(%d) eqMainAssist=%s(%d) zone=%s/%s team=%s/%s',
        tostring(mainTank.name or '-'), tonumber(mainTank.id) or 0,
        tostring(mainAssist.name or '-'), tonumber(mainAssist.id) or 0,
        tostring(primary.packetZone or '-'), tostring(primary.localZone or '-'),
        tostring(primary.packetTeam or '-'), tostring(primary.localTeam or '-'))
    echo('selectedAssist=%s(%d) mode=%s source=%s',
        tostring(selected.name or '-'), tonumber(selected.id) or 0,
        tostring(selected.mode or '-'), tostring(selected.source or '-'))

    local current = module.currentAction or {}
    local candidate = module.domainCandidate or {}
    local lease = module.state and module.state.lease or nil
    echo('domain=%s ownsLease=%s request=%s holder=%s current=%s/%s/%s candidate=%s/%s/%s',
        tostring(module.domainReason or 'unknown'),
        tostring(module:ownsLease()),
        tostring(module.currentRequestId or 'none'),
        tostring(lease and lease.holderModule or '-'),
        tostring(current.component or '-'), tostring(current.kind or '-'),
        tostring(current.name or current.spellName or '-'),
        tostring(candidate.component or '-'), tostring(candidate.kind or '-'),
        tostring(candidate.name or candidate.spellName or '-'))

    local executor = ActionExecutor.getStatus and ActionExecutor.getStatus() or nil
    if executor then
        echo('executor phase=%s reason=%s kind=%s name=%s target=%d monitor=%s castSeen=%s elapsedMs=%d',
            tostring(executor.phase or '-'), tostring(executor.reason or '-'),
            tostring(executor.kind or '-'), tostring(executor.name or '-'),
            tonumber(executor.targetId) or 0, tostring(executor.monitor or '-'),
            tostring(executor.observedCast == true),
            tonumber(executor.elapsedMs) or 0)
    else
        echo('executor idle')
    end

    local okEngine, SpellEngine =
        pcall(require, 'sidekick-next.utils.spell_engine')
    if okEngine and SpellEngine then
        local _, engineState = SpellEngine.getState()
        local cast = SpellEngine.getCastInfo and SpellEngine.getCastInfo() or nil
        echo('spellEngine state=%s spell=%s target=%s retries=%s mqCasting=%s',
            tostring(engineState or '-'),
            tostring(cast and cast.spellName or '-'),
            tostring(cast and cast.targetId or '-'),
            tostring(cast and cast.retriesLeft or '-'),
            tostring(lib.safeTLO(function()
                return mq.TLO.Me.Casting() or ''
            end, '')))
    end

    for _, component in ipairs(module.components or {}) do
        local intent = component.componentIntent or {}
        if intent.active == true or component.componentName == 'dps'
            or component.componentName == 'assist'
            or component.componentName == 'disciplines' then
            echo('component=%s intent=%s reason=%s suspended=%s',
                tostring(component.componentName or '-'),
                tostring(intent.active == true),
                tostring(intent.reason or '-'),
                tostring(component.componentSuspended == true))
        end
    end
end)

module:run(50)
mq.unbind('/sk_combat')
return module
