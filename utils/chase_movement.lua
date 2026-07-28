local mq = require('mq')
local Paths = require('sidekick-next.utils.paths')
local safeWrite = require('sidekick-next.utils.safe_write')

local M = {}

local MARKER_VERSION = 1
local MARKER_TTL_SECONDS = 10
local SAFE_RECOVERY_AGE_SECONDS = 5
local START_CONFIRM_MS = 1000
local STOP_RETRY_MS = 250
local MARKER_REFRESH_MS = 500
local BACKEND_PROBE_MS = 1000

local State = {
    owner = nil,
    orphanChecked = false,
    orphan = nil,
    lastMarkerWriteAt = 0,
    backendProbe = nil,
}

local function nowMs()
    return (mq.gettime and mq.gettime()) or math.floor(os.clock() * 1000)
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

local function sameText(left, right)
    return tostring(left or ''):lower() == tostring(right or ''):lower()
end

local function localIdentity()
    return {
        character = safeString(function() return mq.TLO.Me.CleanName() end, ''),
        server = safeString(function() return mq.TLO.EverQuest.Server() end, ''),
        zoneId = safeNum(function() return mq.TLO.Zone.ID() end, 0),
        instanceId = safeNum(function() return mq.TLO.Me.Instance() end, 0),
    }
end

local function markerPath(identity)
    identity = identity or localIdentity()
    local server = identity.server:gsub('[^%w_%-]', '_')
    local character = identity.character:gsub('[^%w_%-]', '_')
    return string.format('%s/chase_dirty_%s_%s.txt', Paths.getDataDir(), server, character)
end

local function markerValue(value)
    return (tostring(value or ''):gsub('[\r\n]', ' '))
end

local function clearMarker(path)
    path = path or markerPath()
    pcall(os.remove, path)
    pcall(os.remove, path .. '.tmp')
    State.lastMarkerWriteAt = 0
end

local function ownerMarker(owner)
    local heldStrafe = ''
    if owner.held and owner.held.strafe_left then heldStrafe = 'strafe_left' end
    if owner.held and owner.held.strafe_right then heldStrafe = 'strafe_right' end
    return {
        version = MARKER_VERSION,
        updatedAtUnix = os.time(),
        expiresAtUnix = os.time() + MARKER_TTL_SECONDS,
        character = owner.character,
        server = owner.server,
        zoneId = owner.fingerprint and owner.fingerprint.zoneId or 0,
        instanceId = owner.fingerprint and owner.fingerprint.instanceId or 0,
        actionId = owner.actionId or '',
        leaseToken = owner.leaseToken or '',
        workerSessionId = owner.workerSessionId or '',
        coordinatorBootId = owner.coordinatorBootId or '',
        backend = owner.backend or '',
        phase = owner.phase or '',
        targetId = tonumber(owner.fingerprint and owner.fingerprint.id) or 0,
        targetCleanName = owner.fingerprint and owner.fingerprint.cleanName or '',
        targetUniqueName = owner.fingerprint and owner.fingerprint.uniqueName or '',
        heldBack = owner.held and owner.held.back and 1 or 0,
        heldStrafe = heldStrafe,
    }
end

local function writeMarker(owner, force)
    if not owner then return false end
    local now = nowMs()
    if not force and (now - State.lastMarkerWriteAt) < MARKER_REFRESH_MS then
        return true
    end

    local marker = ownerMarker(owner)
    local keys = {
        'version', 'updatedAtUnix', 'expiresAtUnix', 'character', 'server',
        'zoneId', 'instanceId', 'actionId', 'leaseToken', 'workerSessionId',
        'coordinatorBootId', 'backend', 'phase', 'targetId', 'targetCleanName',
        'targetUniqueName', 'heldBack', 'heldStrafe',
    }
    local lines = {}
    for _, key in ipairs(keys) do
        lines[#lines + 1] = string.format('%s=%s', key, markerValue(marker[key]))
    end
    local ok = safeWrite(owner.markerPath or markerPath(), table.concat(lines, '\n') .. '\n')
    if ok then State.lastMarkerWriteAt = now end
    return ok == true
end

local function loadMarker()
    local file = io.open(markerPath(), 'r')
    if not file then return nil end
    local marker = {}
    for line in file:lines() do
        local key, value = line:match('^([%w_]+)=(.*)$')
        if key then marker[key] = value end
    end
    file:close()
    for _, key in ipairs({
        'version', 'updatedAtUnix', 'expiresAtUnix', 'zoneId', 'instanceId',
        'targetId', 'heldBack',
    }) do
        marker[key] = tonumber(marker[key])
    end
    return marker
end

local function navActive()
    return safeBool(function()
        if mq.TLO.Navigation and mq.TLO.Navigation.Active then
            return mq.TLO.Navigation.Active()
        end
        return mq.TLO.Nav and mq.TLO.Nav.Active and mq.TLO.Nav.Active()
    end)
end

local function moveToActive()
    return safeBool(function()
        return mq.TLO.MoveTo and mq.TLO.MoveTo.Moving and mq.TLO.MoveTo.Moving()
    end)
end

local function stickActive()
    return safeBool(function()
        return mq.TLO.Stick and mq.TLO.Stick.Active and mq.TLO.Stick.Active()
    end)
end

local function stickTargetId()
    return safeNum(function()
        return mq.TLO.Stick and mq.TLO.Stick.StickTarget and mq.TLO.Stick.StickTarget()
    end, 0)
end

local function backendState(backend, targetId)
    if backend == 'nav' then
        return navActive(), true
    elseif backend == 'moveto' then
        return moveToActive(), true
    elseif backend == 'stick' then
        local active = stickActive()
        if not active then return false, true end
        local observedId = stickTargetId()
        return true, observedId <= 0 or observedId == tonumber(targetId)
    end
    return false, false
end

local function advPathActive()
    return safeBool(function()
        if not mq.TLO.AdvPath then return false end
        if mq.TLO.AdvPath.Following and mq.TLO.AdvPath.Following() then return true end
        if mq.TLO.AdvPath.Playing and mq.TLO.AdvPath.Playing() then return true end
        if mq.TLO.AdvPath.Recording and mq.TLO.AdvPath.Recording() then return true end
        return mq.TLO.AdvPath.State and (tonumber(mq.TLO.AdvPath.State()) or 0) > 0
    end)
end

local function nativeFollowActive()
    local following = safeValue(function()
        return mq.TLO.Me.Following and mq.TLO.Me.Following()
    end, nil)
    if following == nil or following == false then return false end
    local text = tostring(following)
    return text ~= '' and text:upper() ~= 'NULL'
end

local function isUnderwater()
    return safeBool(function() return mq.TLO.Me.FeetWet() end)
end

local function navMeshLoaded()
    return safeBool(function()
        return mq.TLO.Navigation and mq.TLO.Navigation.MeshLoaded
            and mq.TLO.Navigation.MeshLoaded()
    end)
end

local function navPathExists(targetId)
    if not navMeshLoaded() or not mq.TLO.Navigation
        or not mq.TLO.Navigation.PathExists
    then
        return false
    end
    return safeBool(function()
        -- PathExists returns an MQ datatype; the final call evaluates it to a
        -- Lua boolean.
        return mq.TLO.Navigation.PathExists('id ' .. tostring(targetId))()
    end)
end

local function moveToAvailable()
    return mq.TLO.MoveTo ~= nil and mq.TLO.MoveTo.Moving ~= nil
end

local function stickAvailable()
    return mq.TLO.Stick ~= nil and mq.TLO.Stick.Active ~= nil
end

local function chooseBackend(fingerprint)
    if isUnderwater() and stickAvailable() then return 'stick' end
    if navPathExists(fingerprint.id) then return 'nav' end
    if moveToAvailable() then return 'moveto' end
    if stickAvailable() then return 'stick' end
    return nil
end

--- Resolve a usable movement backend without issuing any movement command.
--- Chase calls this during its sensor pass so an unavailable backend never
--- becomes a lease request that can only fail and requeue.
---@param fingerprint table
---@return string|nil backend
---@return string|nil reason
function M.resolveBackend(fingerprint, force)
    if type(fingerprint) ~= 'table'
        or (tonumber(fingerprint.id) or 0) <= 0 then
        return nil, 'target_missing_id'
    end
    local targetId = tonumber(fingerprint.id)
    local now = nowMs()
    local probe = State.backendProbe
    if force ~= true and probe and probe.targetId == targetId
        and (now - probe.atMs) < BACKEND_PROBE_MS then
        return probe.backend, probe.reason
    end
    local backend = chooseBackend(fingerprint)
    local reason
    if not backend then reason = 'no_movement_backend' end
    State.backendProbe = {
        targetId = targetId,
        atMs = now,
        backend = backend,
        reason = reason,
    }
    return backend, reason
end

--- Read-only backend diagnostics for the Chase worker status command.
function M.backendSnapshot(fingerprint)
    local navMesh = navMeshLoaded()
    local navPath = false
    if navMesh and type(fingerprint) == 'table'
        and (tonumber(fingerprint.id) or 0) > 0 then
        navPath = navPathExists(fingerprint.id)
    end
    local backend, reason = M.resolveBackend(fingerprint)
    return {
        selected = backend,
        reason = reason,
        navMeshLoaded = navMesh,
        navPathExists = navPath,
        moveToAvailable = moveToAvailable(),
        stickAvailable = stickAvailable(),
    }
end

local function issueStart(owner)
    local id = tonumber(owner.fingerprint and owner.fingerprint.id) or 0
    if id <= 0 then return false, 'target_missing_id' end
    local arrival = math.max(5, tonumber(owner.arrivalDistance) or 20)
    if owner.backend == 'nav' then
        mq.cmdf('/nav id %d distance=%.0f log=off', id, arrival)
    elseif owner.backend == 'moveto' then
        -- MQ2MoveUtils requires mdist before id when both are inline.
        mq.cmdf('/moveto mdist %.0f id %d uw', arrival, id)
    elseif owner.backend == 'stick' then
        mq.cmdf('/stick %.0f id %d uw moveback', arrival, id)
    else
        return false, 'backend_unavailable'
    end
    owner.phase = 'starting'
    owner.issuedAtMs = nowMs()
    owner.inactiveSamples = 0
    writeMarker(owner, true)
    return true
end

local function issueStop(backend, targetId)
    local active, matching = backendState(backend, targetId)
    if not active or not matching then return false, matching end
    if backend == 'nav' then
        mq.cmd('/squelch /nav stop')
    elseif backend == 'moveto' then
        mq.cmd('/squelch /moveto off')
    elseif backend == 'stick' then
        mq.cmd('/squelch /stick off')
    else
        return false, false
    end
    return true, true
end

local function releaseHeldKeys(owner)
    if not owner or not owner.held then return end
    if owner.held.back then
        mq.cmd('/keypress back')
        owner.held.back = false
    end
    if owner.held.strafe_left then
        mq.cmd('/keypress strafe_left')
        owner.held.strafe_left = false
    end
    if owner.held.strafe_right then
        mq.cmd('/keypress strafe_right')
        owner.held.strafe_right = false
    end
    writeMarker(owner, true)
end

local function validateOwnerTarget(owner)
    if not owner or type(owner.fingerprint) ~= 'table' then
        return false, 'missing_fingerprint'
    end
    local identity = localIdentity()
    if identity.zoneId ~= tonumber(owner.fingerprint.zoneId) then
        return false, 'zone_changed'
    end
    if identity.instanceId ~= (tonumber(owner.fingerprint.instanceId) or 0) then
        return false, 'instance_changed'
    end

    local id = tonumber(owner.fingerprint.id) or 0
    local spawn = id > 0 and mq.TLO.Spawn and mq.TLO.Spawn(id) or nil
    if not spawn or safeValue(function() return spawn() end, nil) == nil then
        return false, 'target_missing'
    end
    if safeString(function() return spawn.Type() end, ''):lower() ~= 'pc' then
        return false, 'target_not_pc'
    end
    if not sameText(safeString(function() return spawn.CleanName() end, ''),
            owner.fingerprint.cleanName)
    then
        return false, 'target_name_changed'
    end
    if owner.fingerprint.uniqueName and owner.fingerprint.uniqueName ~= ''
        and not sameText(safeString(function() return spawn.Name() end, ''),
            owner.fingerprint.uniqueName)
    then
        return false, 'target_identity_changed'
    end
    return true
end

local function ownerConflictReason(owner)
    if advPathActive() then return 'external_advpath_active' end
    if nativeFollowActive() then return 'external_follow_active' end
    if owner.backend ~= 'nav' and navActive() then return 'external_nav_active' end
    if owner.backend ~= 'moveto' and moveToActive() then return 'external_moveto_active' end
    if owner.backend ~= 'stick' and stickActive() then return 'external_stick_active' end
    return nil
end

function M.externalMovementReason()
    if advPathActive() then return 'external_advpath_active' end
    if nativeFollowActive() then return 'external_follow_active' end
    if navActive() then return 'external_nav_active' end
    if moveToActive() then return 'external_moveto_active' end
    if stickActive() then return 'external_stick_active' end
    if safeBool(function() return mq.TLO.Me.Moving() end) then
        return 'manual_movement_active'
    end
    return nil
end

function M.requestStand()
    if not safeBool(function() return mq.TLO.Me.Sitting() end) then return true end
    mq.cmd('/stand')
    return false
end

function M.begin(fingerprint, arrivalDistance, actionId, ownership)
    if State.owner then return false, 'movement_already_owned' end
    local externalReason = M.externalMovementReason()
    if externalReason then return false, externalReason end

    ownership = ownership or {}
    local identity = localIdentity()
    local owner = {
        actionId = tostring(actionId or ''),
        leaseToken = tostring(ownership.token or ''),
        workerSessionId = tostring(ownership.workerSessionId or ''),
        coordinatorBootId = tostring(ownership.coordinatorBootId or ''),
        fingerprint = fingerprint,
        arrivalDistance = tonumber(arrivalDistance) or 20,
        backend = M.resolveBackend(fingerprint, true),
        phase = 'preparing',
        held = {},
        startedAtMs = nowMs(),
        inactiveSamples = 0,
        lastStopAtMs = 0,
        backendOwned = true,
        character = identity.character,
        server = identity.server,
        markerPath = markerPath(identity),
    }
    if not owner.backend then return false, 'no_movement_backend' end

    local valid, reason = validateOwnerTarget(owner)
    if not valid then return false, reason end
    State.owner = owner
    if not writeMarker(owner, true) then
        State.owner = nil
        return false, 'dirty_marker_write_failed'
    end
    local started, startReason = issueStart(owner)
    if not started then
        clearMarker(owner.markerPath)
        State.owner = nil
        return false, startReason
    end
    return true, owner.backend
end

function M.beginRecovery()
    local owner = State.owner
    if not owner then return false, 'no_owned_movement' end
    if owner.phase == 'cleanup' then return false, 'cleanup_active' end
    releaseHeldKeys(owner)
    owner.phase = 'recovery_stop'
    owner.inactiveSamples = 0
    owner.lastStopAtMs = 0
    writeMarker(owner, true)
    return true
end

local function tickRecovery(owner)
    local now = nowMs()
    if owner.phase == 'recovery_stop' then
        local active, matching = backendState(owner.backend, owner.fingerprint.id)
        if active and matching and (now - owner.lastStopAtMs) >= STOP_RETRY_MS then
            issueStop(owner.backend, owner.fingerprint.id)
            owner.lastStopAtMs = now
        elseif active and not matching then
            owner.backendOwned = false
        end
        if not active or not matching then
            owner.inactiveSamples = owner.inactiveSamples + 1
        else
            owner.inactiveSamples = 0
        end
        if owner.inactiveSamples < 2 then return 'recovering_stop' end

        owner.held.back = true
        owner.phase = 'recovery_back'
        owner.releaseAtMs = now + 200
        if not writeMarker(owner, true) then
            owner.held.back = false
            return 'recovery_failed:dirty_marker_write_failed'
        end
        mq.cmd('/keypress back hold')
        return 'recovering_back'
    end

    if owner.phase == 'recovery_back' then
        if now < owner.releaseAtMs then return 'recovering_back' end
        mq.cmd('/keypress back')
        owner.held.back = false
        local strafe = math.random(2) == 1 and 'strafe_left' or 'strafe_right'
        owner.held[strafe] = true
        owner.recoveryStrafe = strafe
        owner.phase = 'recovery_strafe'
        owner.releaseAtMs = now + 300
        if not writeMarker(owner, true) then
            owner.held[strafe] = false
            owner.recoveryStrafe = nil
            return 'recovery_failed:dirty_marker_write_failed'
        end
        mq.cmdf('/keypress %s hold', strafe)
        return 'recovering_strafe'
    end

    if owner.phase == 'recovery_strafe' then
        if now < owner.releaseAtMs then return 'recovering_strafe' end
        local strafe = owner.recoveryStrafe
        if strafe and owner.held[strafe] then mq.cmdf('/keypress %s', strafe) end
        if strafe then owner.held[strafe] = false end
        owner.recoveryStrafe = nil
        owner.phase = 'recovery_restart'
        owner.releaseAtMs = now + 50
        writeMarker(owner, true)
        return 'recovering_restart'
    end

    if owner.phase == 'recovery_restart' then
        if now < owner.releaseAtMs then return 'recovering_restart' end
        local valid, reason = validateOwnerTarget(owner)
        if not valid then return 'recovery_failed:' .. tostring(reason) end

        -- Never replace movement that appeared while recovery keys were held.
        local externalReason
        if advPathActive() then externalReason = 'external_advpath_active' end
        if not externalReason and nativeFollowActive() then externalReason = 'external_follow_active' end
        if not externalReason and navActive() then externalReason = 'external_nav_active' end
        if not externalReason and moveToActive() then externalReason = 'external_moveto_active' end
        if not externalReason and stickActive() then externalReason = 'external_stick_active' end
        if externalReason then return 'recovery_failed:' .. externalReason end

        owner.backend = chooseBackend(owner.fingerprint)
        owner.backendOwned = true
        if not owner.backend then return 'recovery_failed:no_movement_backend' end
        local started, reason = issueStart(owner)
        if not started then return 'recovery_failed:' .. tostring(reason) end
        return 'recovery_restarted'
    end
    return nil
end

function M.tick()
    local owner = State.owner
    if not owner then return { phase = 'idle', active = false } end
    writeMarker(owner, false)

    if owner.phase:find('^recovery_') then
        local recoveryStatus = tickRecovery(owner)
        return {
            phase = owner.phase,
            active = backendState(owner.backend, owner.fingerprint.id),
            status = recoveryStatus,
            backend = owner.backend,
        }
    end

    local conflictReason = ownerConflictReason(owner)
    if conflictReason then
        return {
            phase = owner.phase,
            active = backendState(owner.backend, owner.fingerprint.id),
            backend = owner.backend,
            status = conflictReason,
        }
    end

    local active, matching = backendState(owner.backend, owner.fingerprint.id)
    if active and not matching then
        owner.backendOwned = false
        return {
            phase = owner.phase,
            active = false,
            backend = owner.backend,
            status = 'backend_replaced',
        }
    end
    if owner.phase == 'starting' then
        if active then
            owner.phase = 'active'
            writeMarker(owner, true)
            return { phase = 'active', active = true, backend = owner.backend, status = 'started' }
        end
        if (nowMs() - owner.issuedAtMs) >= START_CONFIRM_MS then
            return {
                phase = owner.phase,
                active = false,
                backend = owner.backend,
                status = 'backend_start_failed',
            }
        end
        return { phase = owner.phase, active = false, backend = owner.backend, status = 'starting' }
    end
    return {
        phase = owner.phase,
        active = active and matching,
        backend = owner.backend,
        status = active and 'active' or 'backend_inactive',
    }
end

function M.beginCleanup(reason, requireInRange)
    local owner = State.owner
    if not owner then return true end
    if owner.phase ~= 'cleanup' then
        owner.phase = 'cleanup'
        owner.cleanupReason = tostring(reason or 'cleanup')
        owner.requireInRange = requireInRange == true
        owner.rangeLost = false
        owner.inactiveSamples = 0
        owner.lastStopAtMs = 0
        writeMarker(owner, true)
    elseif reason and owner.cleanupReason == '' then
        owner.cleanupReason = tostring(reason)
    end
    return false
end

function M.tickCleanup(distance)
    local owner = State.owner
    if not owner then return true, 'clean' end
    if owner.phase ~= 'cleanup' then M.beginCleanup('cleanup', false) end
    releaseHeldKeys(owner)

    local now = nowMs()
    local active, matching = backendState(owner.backend, owner.fingerprint.id)
    if active and matching and owner.backendOwned ~= false
        and (now - owner.lastStopAtMs) >= STOP_RETRY_MS
    then
        issueStop(owner.backend, owner.fingerprint.id)
        owner.lastStopAtMs = now
    elseif active and not matching then
        -- The observable stick target changed, so Chase no longer owns that
        -- backend. Do not stop the replacement command.
        owner.backendOwned = false
    end

    active, matching = backendState(owner.backend, owner.fingerprint.id)
    local ownedActive = active and matching and owner.backendOwned ~= false
    local keysHeld = owner.held.back or owner.held.strafe_left or owner.held.strafe_right

    if owner.requireInRange then
        local observed = tonumber(distance)
        if not observed or observed > owner.arrivalDistance then
            owner.rangeLost = true
        end
    end
    local rangeStable = not owner.requireInRange or not owner.rangeLost
    if not ownedActive and not keysHeld and rangeStable then
        owner.inactiveSamples = owner.inactiveSamples + 1
    elseif not ownedActive and not keysHeld and owner.rangeLost then
        -- The target moved during the stop handshake. Do not claim arrival,
        -- but release cleanly so a later slice can re-evaluate it.
        owner.inactiveSamples = owner.inactiveSamples + 1
    else
        owner.inactiveSamples = 0
    end

    writeMarker(owner, false)
    if owner.inactiveSamples < 2 then
        return false, ownedActive and 'waiting_backend_stop' or 'waiting_stable_inactive'
    end

    local reason = owner.rangeLost and 'arrival_unstable' or owner.cleanupReason
    clearMarker(owner.markerPath)
    State.owner = nil
    return true, reason
end

function M.cleanup(reason, requireInRange, distance)
    M.beginCleanup(reason, requireInRange)
    return M.tickCleanup(distance)
end

function M.hasOwnedEffects()
    return State.owner ~= nil
end

local function validOrphanMarker(marker)
    if type(marker) ~= 'table' then return false, 'no_marker' end
    if marker.version ~= MARKER_VERSION then return false, 'marker_version' end
    if (tonumber(marker.expiresAtUnix) or 0) < os.time() then
        return false, 'marker_expired'
    end
    if (os.time() - (tonumber(marker.updatedAtUnix) or 0)) > SAFE_RECOVERY_AGE_SECONDS then
        return false, 'marker_too_old'
    end
    local identity = localIdentity()
    if not sameText(marker.character, identity.character)
        or not sameText(marker.server, identity.server)
    then
        return false, 'marker_identity_changed'
    end
    if tonumber(marker.zoneId) ~= identity.zoneId then return false, 'marker_zone_changed' end
    if (tonumber(marker.instanceId) or 0) ~= identity.instanceId then
        return false, 'marker_instance_changed'
    end
    if marker.backend ~= 'nav' and marker.backend ~= 'moveto' and marker.backend ~= 'stick' then
        return false, 'marker_backend_invalid'
    end
    return true
end

local function orphanHasConflictingMovement(marker)
    if advPathActive() or nativeFollowActive() then return true end
    if marker.backend ~= 'nav' and navActive() then return true end
    if marker.backend ~= 'moveto' and moveToActive() then return true end
    if marker.backend ~= 'stick' and stickActive() then return true end
    if marker.backend == 'stick' and stickActive() then
        local targetId = stickTargetId()
        if targetId > 0 and targetId ~= tonumber(marker.targetId) then return true end
    end
    return false
end

--- Inspect and stage an orphan marker without issuing movement commands.
--- This is safe from the worker sensor pass; cleanup itself remains leased.
---@return boolean pending
---@return string reason
function M.inspectOrphanRecovery()
    if not State.orphanChecked then
        State.orphanChecked = true
        local marker = loadMarker()
        if not marker then return false, 'no_dirty_marker' end
        local valid, reason = validOrphanMarker(marker)
        if not valid then
            State.orphan = {
                marker = marker,
                terminalReason = reason,
            }
            return true, reason
        end
        local conflict = orphanHasConflictingMovement(marker)
        State.orphan = {
            marker = marker,
            inactiveSamples = 0,
            lastStopAtMs = 0,
            keysReleased = false,
            terminalReason = conflict and 'orphan_conflicting_movement' or nil,
        }
    end
    if not State.orphan then return false, 'orphan_clean' end
    return true, State.orphan.terminalReason or 'orphan_recovery_pending'
end

function M.tickOrphanRecovery()
    local pending, inspectReason = M.inspectOrphanRecovery()
    if not pending then return true, inspectReason, false end

    local orphan = State.orphan
    if not orphan then return true, 'orphan_clean', false end
    local marker = orphan.marker
    if orphan.terminalReason then
        -- Stale, wrong-zone, wrong-instance, and conflicting markers may be
        -- deleted, but never used to stop movement. Marker deletion happens
        -- under the recovery lease along with every other recovery effect.
        clearMarker()
        local reason = orphan.terminalReason
        State.orphan = nil
        return true, reason, true
    end
    if not orphan.keysReleased then
        if tonumber(marker.heldBack) == 1 then mq.cmd('/keypress back') end
        if marker.heldStrafe == 'strafe_left' or marker.heldStrafe == 'strafe_right' then
            mq.cmdf('/keypress %s', marker.heldStrafe)
        end
        orphan.keysReleased = true
    end

    local active, matching = backendState(marker.backend, marker.targetId)
    if active and matching and (nowMs() - orphan.lastStopAtMs) >= STOP_RETRY_MS then
        issueStop(marker.backend, marker.targetId)
        orphan.lastStopAtMs = nowMs()
    elseif active and not matching then
        matching = false
    end
    if not active or not matching then
        orphan.inactiveSamples = orphan.inactiveSamples + 1
    else
        orphan.inactiveSamples = 0
    end
    if orphan.inactiveSamples < 2 then return false, 'orphan_draining', true end

    clearMarker()
    State.orphan = nil
    return true, 'orphan_recovered', true
end

function M.resetOrphanCheck()
    State.orphanChecked = false
    State.orphan = nil
end

function M.rebaseTimers(deltaMs)
    deltaMs = tonumber(deltaMs) or 0
    if deltaMs <= 0 then return end
    local owner = State.owner
    if owner then
        for _, key in ipairs({
            'startedAtMs', 'issuedAtMs', 'releaseAtMs', 'lastStopAtMs',
        }) do
            if tonumber(owner[key]) then owner[key] = owner[key] + deltaMs end
        end
    end
    local orphan = State.orphan
    if orphan and tonumber(orphan.lastStopAtMs) then
        orphan.lastStopAtMs = orphan.lastStopAtMs + deltaMs
    end
end

function M.snapshot()
    local owner = State.owner
    if not owner then
        return {
            owned = false,
            orphanRecovery = State.orphan ~= nil,
        }
    end
    local active, matching = backendState(owner.backend, owner.fingerprint.id)
    return {
        owned = true,
        actionId = owner.actionId,
        backend = owner.backend,
        phase = owner.phase,
        active = active and matching and owner.backendOwned ~= false,
        targetId = owner.fingerprint.id,
        targetName = owner.fingerprint.cleanName,
        cleanupReason = owner.cleanupReason,
        heldBack = owner.held.back == true,
        heldStrafe = owner.held.strafe_left and 'strafe_left'
            or (owner.held.strafe_right and 'strafe_right' or nil),
    }
end

return M
