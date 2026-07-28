local mq = require('mq')

local M = {}

M.enabled = false
M.state = {
    role = 'none',
    target = '',
    distance = 30,
    userPaused = false,
}

M.ROLES = { 'none', 'ma', 'mt', 'leader', 'raid1', 'raid2', 'raid3', 'byname' }

local _Core = nil
local _lastReason = 'init'
local _lastIntent = nil
local _chaseRoll = nil
local _chaseJitterPct = 0.20

local function nowMs()
    return (mq.gettime and mq.gettime()) or math.floor(os.clock() * 1000)
end

local function trim(value)
    local text = tostring(value or ''):gsub('^%s+', '')
    return (text:gsub('%s+$', ''))
end

local function safeValue(fn, fallback)
    local ok, value = pcall(fn)
    if not ok or value == nil then return fallback end
    return value
end

local function safeBool(fn)
    return safeValue(fn, false) == true
end

local function safeNum(fn, fallback)
    return tonumber(safeValue(fn, fallback)) or fallback
end

local function safeString(fn, fallback)
    local value = safeValue(fn, fallback or '')
    if value == nil then return fallback or '' end
    return tostring(value)
end

local function clearChaseRoll()
    _chaseRoll = nil
end

local function humanizeOn()
    local cfg = _G.SIDEKICK_NEXT_CONFIG
    if not (cfg and cfg.HUMANIZE_BEHAVIOR) then return false end
    local ok, Profiles = pcall(require, 'sidekick-next.humanize.profiles')
    if ok and Profiles and Profiles.subsystemEnabled then
        return Profiles.subsystemEnabled('engagement')
    end
    return true
end

local function effectiveMaxDistance(base)
    if not humanizeOn() or _chaseJitterPct <= 0 then return base end
    if not _chaseRoll then
        local lo = base * (1 - _chaseJitterPct)
        local hi = base * (1 + _chaseJitterPct)
        _chaseRoll = lo + math.random() * (hi - lo)
    end
    return _chaseRoll
end

local function localZone()
    return {
        id = safeNum(function() return mq.TLO.Zone.ID() end, 0),
        shortName = safeString(function() return mq.TLO.Zone.ShortName() end, ''),
        instanceId = safeNum(function() return mq.TLO.Me.Instance() end, 0),
    }
end

local function localServer()
    return safeString(function() return mq.TLO.EverQuest.Server() end, '')
end

local function spawnExists(spawn)
    return spawn ~= nil and safeValue(function() return spawn() end, nil) ~= nil
end

local function sameText(left, right)
    return trim(left):lower() == trim(right):lower()
end

function M.getChaseJitterPct()
    return _chaseJitterPct
end

function M.setChaseJitterPct(value)
    value = tonumber(value) or 0.20
    _chaseJitterPct = math.max(0, math.min(0.5, value))
    clearChaseRoll()
end

function M.endEpisode()
    clearChaseRoll()
end

function M.init(opts)
    opts = opts or {}
    _Core = opts.Core
end

function M.validateDistance(distance)
    distance = tonumber(distance)
    return distance ~= nil and distance >= 15 and distance <= 300
end

function M.applySettings(settings)
    settings = settings or {}
    M.enabled = settings.ChaseEnabled == true
    M.state.role = tostring(settings.ChaseRole or 'ma'):lower()
    M.state.target = trim(settings.ChaseTarget)
    M.state.distance = tonumber(settings.ChaseDistance) or 30
    if M.enabled then M.state.userPaused = false end
    return settings
end

function M.setEnabled(value, opts)
    opts = opts or {}
    M.enabled = value == true
    if _Core and _Core.set then
        _Core.set('ChaseEnabled', M.enabled)
    elseif _Core and _Core.Settings then
        _Core.Settings.ChaseEnabled = M.enabled
    end
    if not M.enabled then clearChaseRoll() end
    if opts.user then
        M.state.userPaused = not M.enabled
    elseif M.enabled then
        M.state.userPaused = false
    end
end

-- Chase movement is worker-owned. This compatibility method deliberately
-- performs no command so the UI host cannot stop another process's movement.
function M.stopNav()
    clearChaseRoll()
    _lastReason = 'worker_owned'
end

function M.resolveSpawn(settings)
    settings = settings or M.state
    local role = tostring(settings.ChaseRole or settings.role or 'none'):lower()
    if role == 'none' then return nil, 'role_none' end

    local spawn
    if role == 'ma' then
        spawn = mq.TLO.Group and mq.TLO.Group.MainAssist
    elseif role == 'mt' then
        spawn = mq.TLO.Group and mq.TLO.Group.MainTank
    elseif role == 'leader' then
        spawn = mq.TLO.Group and mq.TLO.Group.Leader
    elseif role == 'raid1' or role == 'raid2' or role == 'raid3' then
        local index = tonumber(role:sub(-1))
        local member = mq.TLO.Raid and mq.TLO.Raid.MainAssist
            and mq.TLO.Raid.MainAssist(index) or nil
        spawn = member and member.Spawn or nil
    elseif role == 'byname' then
        local name = trim(settings.ChaseTarget or settings.target)
        if name == '' then return nil, 'empty_target_name' end
        spawn = mq.TLO.Spawn and mq.TLO.Spawn('pc =' .. name) or nil
    else
        return nil, 'invalid_role:' .. role
    end

    if not spawnExists(spawn) then return nil, 'no_chase_target' end
    return spawn, nil
end

function M.distanceTo(spawn)
    if not spawnExists(spawn) then return nil end
    local meX = safeValue(function() return mq.TLO.Me.X() end, nil)
    local meY = safeValue(function() return mq.TLO.Me.Y() end, nil)
    local meZ = safeValue(function() return mq.TLO.Me.Z() end, nil)
    local targetX = safeValue(function() return spawn.X() end, nil)
    local targetY = safeValue(function() return spawn.Y() end, nil)
    local targetZ = safeValue(function() return spawn.Z() end, nil)
    if not meX or not meY or not targetX or not targetY then return nil end
    local dx = tonumber(meX) - tonumber(targetX)
    local dy = tonumber(meY) - tonumber(targetY)
    local dz = (tonumber(meZ) or 0) - (tonumber(targetZ) or 0)
    return math.sqrt(dx * dx + dy * dy + dz * dz)
end

function M.position()
    return {
        x = safeNum(function() return mq.TLO.Me.X() end, 0),
        y = safeNum(function() return mq.TLO.Me.Y() end, 0),
        z = safeNum(function() return mq.TLO.Me.Z() end, 0),
    }
end

function M.fingerprint(settings)
    settings = settings or M.state
    local spawn, reason = M.resolveSpawn(settings)
    if not spawn then return nil, reason end

    local spawnType = safeString(function() return spawn.Type() end, ''):lower()
    if spawnType ~= 'pc' then return nil, 'target_not_pc' end

    local id = safeNum(function() return spawn.ID() end, 0)
    local selfId = safeNum(function() return mq.TLO.Me.ID() end, 0)
    if id <= 0 then return nil, 'target_missing_id' end
    if id == selfId then return nil, 'target_is_self' end

    local cleanName = safeString(function() return spawn.CleanName() end, '')
    local uniqueName = safeString(function() return spawn.Name() end, '')
    if cleanName == '' then return nil, 'target_missing_name' end

    local zone = localZone()
    return {
        id = id,
        cleanName = cleanName,
        uniqueName = uniqueName,
        type = 'PC',
        source = tostring(settings.ChaseRole or settings.role or 'none'):lower(),
        server = localServer(),
        zoneId = zone.id,
        zoneShortName = zone.shortName,
        instanceId = zone.instanceId,
    }, nil
end

function M.validateFingerprint(fingerprint)
    if type(fingerprint) ~= 'table' then return nil, 'missing_fingerprint' end

    local zone = localZone()
    if zone.id <= 0 or zone.id ~= tonumber(fingerprint.zoneId) then
        return nil, 'zone_changed'
    end
    if zone.instanceId ~= (tonumber(fingerprint.instanceId) or 0) then
        return nil, 'instance_changed'
    end
    if fingerprint.server and fingerprint.server ~= ''
        and not sameText(localServer(), fingerprint.server)
    then
        return nil, 'server_changed'
    end

    local id = tonumber(fingerprint.id) or 0
    if id <= 0 then return nil, 'target_missing_id' end
    local spawn = mq.TLO.Spawn and mq.TLO.Spawn(id) or nil
    if not spawnExists(spawn) then return nil, 'target_missing' end
    if safeNum(function() return spawn.ID() end, 0) ~= id then
        return nil, 'target_id_changed'
    end
    if safeString(function() return spawn.Type() end, ''):lower() ~= 'pc' then
        return nil, 'target_not_pc'
    end
    if not sameText(safeString(function() return spawn.CleanName() end, ''), fingerprint.cleanName) then
        return nil, 'target_name_changed'
    end
    if fingerprint.uniqueName and fingerprint.uniqueName ~= ''
        and not sameText(safeString(function() return spawn.Name() end, ''), fingerprint.uniqueName)
    then
        return nil, 'target_identity_changed'
    end
    return spawn, nil
end

function M.combatBlockReason(settings, chaseSpawn)
    settings = settings or {}
    if not mq.TLO or not mq.TLO.Me or not safeValue(function() return mq.TLO.Me() end, nil) then
        return 'no_character'
    end
    if safeBool(function() return mq.TLO.Me.Dead() end) then return 'self_dead' end
    if safeBool(function() return mq.TLO.Me.Hovering() end) then return 'hovering' end
    if safeBool(function() return mq.TLO.Me.Combat() end) then return 'melee_combat' end
    if safeBool(function() return mq.TLO.Me.AutoFire() end) then return 'autofire' end

    -- Ranged standoff owns ordinary in-combat positioning. Chase yields only
    -- when standoff is enabled and the tank remains inside a generous leash;
    -- beyond it, keeping up with a tank pursuing a runner takes precedence.
    -- Classes with standoff disabled must continue following during combat.
    if settings.CasterStandoffEnabled == true then
        local combatReason = nil
        if safeString(function() return mq.TLO.Me.CombatState() end, ''):upper() == 'COMBAT' then
            combatReason = 'combat_state'
        elseif safeNum(function() return mq.TLO.Me.XTHaterCount() end, 0) > 0 then
            combatReason = 'active_haters'
        elseif safeValue(function() return mq.TLO.Me.Pet() end, nil)
            and safeBool(function() return mq.TLO.Me.Pet.Combat() end)
        then
            combatReason = 'pet_combat'
        end
        if combatReason then
            local chaseDistance = tonumber(settings.ChaseDistance)
                or tonumber(M.state.distance) or 30
            local leash = math.max(150, chaseDistance * 4)
            local dist = M.distanceTo(chaseSpawn)
            if not dist or dist <= leash then
                return dist
                    and string.format('standoff_%s:%.0f<=%.0f',
                        combatReason, dist, leash)
                    or ('standoff_' .. combatReason)
            end
        end
    end

    local casting = safeString(function() return mq.TLO.Me.Casting() end, '')
    if casting ~= '' and casting:upper() ~= 'NULL' then return 'casting' end
    return nil
end

local function preflight(settings)
    settings = settings or {}
    if settings.ChaseEnabled ~= true then return nil, 'disabled' end
    if M.state.userPaused then return nil, 'user_paused' end
    -- Coordinated workers take global pause exclusively from the coordinator
    -- state enforced by ModuleBase. The persisted settings copy can be stale
    -- across process startup/revision reload and must not veto a resumed fleet.
    if tostring(settings.AutomationLevel or 'auto'):lower() ~= 'auto' then
        return nil, 'movement_not_auto'
    end

    local distance = tonumber(settings.ChaseDistance) or 30
    if not M.validateDistance(distance) then return nil, 'invalid_distance' end

    local fingerprint, reason = M.fingerprint(settings)
    if not fingerprint then return nil, reason end
    local spawn, validateReason = M.validateFingerprint(fingerprint)
    if not spawn then return nil, validateReason end
    local combatReason = M.combatBlockReason(settings, spawn)
    if combatReason then return nil, combatReason end
    return {
        fingerprint = fingerprint,
        spawn = spawn,
        baseDistance = distance,
    }, nil
end

function M.selectIntent(settings, opts)
    opts = opts or {}
    M.applySettings(settings)
    local candidate, reason = preflight(settings)
    if not candidate then
        clearChaseRoll()
        _lastIntent = nil
        _lastReason = tostring(reason or 'not_ready')
        return nil, _lastReason
    end

    if opts.externalMovementReason then
        _lastIntent = nil
        _lastReason = tostring(opts.externalMovementReason)
        return nil, _lastReason
    end

    local distance = M.distanceTo(candidate.spawn)
    if not distance then
        _lastIntent = nil
        _lastReason = 'no_distance'
        return nil, _lastReason
    end

    local triggerDistance = effectiveMaxDistance(candidate.baseDistance)
    if distance <= triggerDistance then
        clearChaseRoll()
        _lastIntent = nil
        _lastReason = string.format('in_range:%.1f<=%.1f', distance, triggerDistance)
        return nil, _lastReason
    end

    local arrivalDistance = math.max(10, math.min(candidate.baseDistance - 2, candidate.baseDistance * 0.8))
    local intent = {
        kind = 'chase_slice',
        name = 'Out-of-combat chase',
        fingerprint = candidate.fingerprint,
        baseDistance = candidate.baseDistance,
        triggerDistance = triggerDistance,
        arrivalDistance = arrivalDistance,
        observedDistance = distance,
        createdAtMs = nowMs(),
    }
    _lastIntent = intent
    _lastReason = string.format('ready:%s:%.1f>%.1f',
        candidate.fingerprint.cleanName, distance, triggerDistance)
    return intent, nil
end

function M.revalidateIntent(intent, settings)
    if type(intent) ~= 'table' or type(intent.fingerprint) ~= 'table' then
        return nil, nil, 'missing_intent'
    end

    local candidate, reason = preflight(settings)
    if not candidate then return nil, nil, reason end
    local expected = intent.fingerprint
    local current = candidate.fingerprint
    if tonumber(expected.id) ~= tonumber(current.id)
        or not sameText(expected.cleanName, current.cleanName)
        or not sameText(expected.uniqueName, current.uniqueName)
        or tonumber(expected.zoneId) ~= tonumber(current.zoneId)
        or tonumber(expected.instanceId) ~= tonumber(current.instanceId)
    then
        return nil, nil, 'configured_target_changed'
    end
    if tonumber(intent.baseDistance) ~= tonumber(candidate.baseDistance) then
        return nil, nil, 'distance_setting_changed'
    end

    local spawn, validateReason = M.validateFingerprint(expected)
    if not spawn then return nil, nil, validateReason end
    local distance = M.distanceTo(spawn)
    if not distance then return nil, nil, 'no_distance' end
    return spawn, distance, nil
end

-- Kept as a sensor-only compatibility entry point until all callers have
-- migrated to the dedicated worker.
function M.tick()
    local settings = (_Core and _Core.Settings) or {
        ChaseEnabled = M.enabled,
        ChaseRole = M.state.role,
        ChaseTarget = M.state.target,
        ChaseDistance = M.state.distance,
        AutomationLevel = 'auto',
    }
    M.selectIntent(settings, { externalMovementReason = 'worker_owned' })
end

function M.status()
    local settings = (_Core and _Core.Settings) or {
        ChaseEnabled = M.enabled,
        ChaseRole = M.state.role,
        ChaseTarget = M.state.target,
        ChaseDistance = M.state.distance,
    }
    M.applySettings(settings)
    local fingerprint = M.fingerprint(settings)
    local spawn = fingerprint and mq.TLO.Spawn(fingerprint.id) or nil
    local distance = spawn and M.distanceTo(spawn) or nil
    local navActive = safeBool(function()
        return mq.TLO.Navigation and mq.TLO.Navigation.Active
            and mq.TLO.Navigation.Active()
    end)
    return {
        enabled = M.enabled == true,
        userPaused = M.state.userPaused == true,
        role = M.state.role,
        target = M.state.target,
        distance = M.state.distance,
        resolvedName = fingerprint and fingerprint.cleanName or nil,
        resolvedId = fingerprint and fingerprint.id or 0,
        resolvedDistance = distance,
        navActive = navActive,
        initiatedNav = false,
        reason = _lastReason,
        intent = _lastIntent,
    }
end

return M
