-- F:/lua/sidekick-next/automation/caster_assist.lua
-- Caster-specific assist logic: stay-put casting with optional ranged standoff

local mq = require('mq')
local lazy = require('sidekick-next.utils.lazy_require')
local Roles = require('sidekick-next.utils.class_roles')
local log = require('sidekick-next.utils.logger').new('assist')
local SkLib = require('sidekick-next.sk_lib')

local M = {}

-- Class categorization (re-exported from utils/class_roles.lua so external
-- callers can still read caster_assist.PURE_CASTERS, but the source of
-- truth lives in one file).
M.PURE_CASTERS = Roles.PURE_CASTERS
M.HYBRID_MELEE = Roles.HYBRID_MELEE
M.PURE_MELEE = Roles.PURE_MELEE

-- State
M.enabled = false

-- Standoff state (keep ranged distance from the target so rains/AEs on the mob
-- don't clip the caster)
M.standoffState = {
    phase = 'idle',  -- idle, moving
    startTime = 0,
    startX = 0,
    startY = 0,
    outwardX = 0,
    outwardY = 0,
    startDistance = 0,
    targetId = 0,
    moveKind = '',
    destinationX = 0,
    destinationY = 0,
    positionedTargetId = 0,
    holdUntilMs = 0,
    retryAfterMs = 0,
}
-- MuleAssist's StayAwayMoveTimer prevents its range controller from firing
-- again immediately after movement. Use a slightly longer plant window here
-- because SideKick evaluates positioning and spell readiness in separate Lua
-- processes.
M.standoffCooldownMs = 6000
M.lastStandoffMove = 0
M.coordinatedTarget = {
    id = 0,
    name = '',
    combatActive = false,
    lastCombatActiveAtMs = 0,
    actionReady = false,
    reason = '',
    receivedAtMs = 0,
}
-- Worker telemetry normally arrives every second, but coordinator/debug load
-- and foreground scheduling can create multi-second gaps. Keep a live,
-- locally-resolvable NPC authoritative long enough that Chase cannot steal
-- movement between standoff updates.
local COORDINATED_TARGET_TTL_MS = 12000
-- Briefly retain ownership through a missed/contradictory worker sample. A
-- dead or despawned target still releases immediately.
local COORDINATED_COMBAT_GRACE_MS = 2500
-- Once encounter evidence is observed, keep caster movement fenced for a few
-- seconds so the end of a cast cannot hand control back to Chase between
-- worker telemetry samples. This lease controls movement only; it never makes
-- a target eligible for DPS.
local STANDOFF_MOVEMENT_LEASE_MS = 5000
M.combatMovementLease = {
    untilMs = 0,
    targetId = 0,
    reason = '',
}

-------------------------------------------------------------------------------
-- Standoff positioning (ranged casting distance with desynced random spots)
-------------------------------------------------------------------------------

-- Per-character deterministic angle offset + RNG seed. Three boxed characters
-- get different base directions from the name hash alone, and the per-move
-- jitter comes from an RNG seeded per character - so they never pick the same
-- spot in sync even when they reposition at the same moment.
local _standoffSeeded = false
local _nameAngleOffset = 0

local function ensureStandoffSeed()
    if _standoffSeeded then return end
    local name = tostring(mq.TLO.Me.CleanName() or 'unknown')
    local h = 0
    for i = 1, #name do
        h = (h * 31 + name:byte(i)) % 1000003
    end
    math.randomseed((os.time() % 100000) + h)
    _nameAngleOffset = (h % 90) - 45  -- degrees, spread characters across +/-45
    _standoffSeeded = true
end

--- Validate a candidate standoff spot: reachable and keeps line of sight to the mob
local function isValidStandoffSpot(x, y, z, mobX, mobY, mobZ)
    -- Reachable via nav mesh?
    local nav = mq.TLO.Navigation
    if nav and nav.PathExists then
        local ok, exists = pcall(function()
            return nav.PathExists(string.format('locxyz %.2f %.2f %.2f', x, y, z))()
        end)
        if ok and exists == false then return false end
    end

    -- Line of sight from the spot to the mob (so casting can continue)
    -- LineOfSight TLO uses EQ loc order: y,x,z:y,x,z
    local ok2, los = pcall(function()
        return mq.TLO.LineOfSight(string.format('%.2f,%.2f,%.2f:%.2f,%.2f,%.2f',
            y, x, z, mobY, mobX, mobZ))()
    end)
    if ok2 and los == false then return false end

    return true
end

--- Pick a randomized standoff spot on MY side of the mob
-- @param target userdata Target spawn
-- @param minD number Minimum distance from the mob
-- @param maxD number Maximum distance from the mob
-- @return number, number, number x, y, z
local function pickStandoffSpot(target, minD, maxD)
    ensureStandoffSeed()

    local mobX = target.X() or 0
    local mobY = target.Y() or 0
    local mobZ = target.Z() or 0
    local myX = mq.TLO.Me.X() or 0
    local myY = mq.TLO.Me.Y() or 0
    local myZ = mq.TLO.Me.Z() or mobZ

    -- Base direction: from the mob toward me (stay on my own side and never
    -- choose a retreat destination across the mob).
    local dx, dy = myX - mobX, myY - mobY
    local base
    if (dx * dx + dy * dy) < 1 then
        base = math.random() * 2 * math.pi
    else
        base = math.atan2(dx, dy)
    end
    for _ = 1, 8 do
        -- Keep every candidate inside a 50-degree outward cone. The previous
        -- widening search could reach the far side of the target after several
        -- failed candidates, making a "retreat" visibly run at the mob.
        local personalOffset = math.max(-25, math.min(25, _nameAngleOffset))
        local jitter = math.random(-25, 25)
        local offset = math.max(-50, math.min(50, personalOffset + jitter))
        local angle = base + math.rad(offset)
        local dist = minD + (maxD - minD) * math.random()
        local x = mobX + math.sin(angle) * dist
        local y = mobY + math.cos(angle) * dist
        if isValidStandoffSpot(x, y, myZ, mobX, mobY, mobZ) then
            return x, y, myZ
        end
    end

    -- Fallback: straight away from the mob at mid distance
    local len = math.max(math.sqrt(dx * dx + dy * dy), 1)
    local dist = (minD + maxD) / 2
    return mobX + (dx / len) * dist, mobY + (dy / len) * dist, myZ
end

--- Is the standoff reposition currently moving us? (spell_engine defers timed casts)
-- @return boolean
function M.isRepositioning()
    return M.standoffState.phase == 'moving'
end

--- Stop movement backends that can continue steering toward the MA or target
--- while MQ2Nav is trying to execute a standoff retreat.
---@return string stopped Comma-separated movement backends stopped
local function stopCompetingNonNavMovement()
    local stopped = {}
    local stickActive = mq.TLO.Stick and mq.TLO.Stick.Active
        and mq.TLO.Stick.Active()
    if stickActive then
        mq.cmd('/squelch /stick off')
        stopped[#stopped + 1] = 'stick'
    end

    local moveToActive = mq.TLO.MoveTo and mq.TLO.MoveTo.Moving
        and mq.TLO.MoveTo.Moving()
    if moveToActive then
        mq.cmd('/squelch /moveto off')
        stopped[#stopped + 1] = 'moveto'
    end

    local advFollowing = mq.TLO.AdvPath and mq.TLO.AdvPath.Following
        and mq.TLO.AdvPath.Following()
    if advFollowing then
        mq.cmd('/squelch /afollow off')
        stopped[#stopped + 1] = 'afollow'
    end

    local followingId = mq.TLO.Me.Following and mq.TLO.Me.Following.ID
        and tonumber(mq.TLO.Me.Following.ID()) or 0
    if followingId > 0 then
        mq.cmd('/squelch /follow off')
        stopped[#stopped + 1] = 'follow'
    end
    return table.concat(stopped, ',')
end

local function stopAllPluginMovement()
    local stopped = stopCompetingNonNavMovement()
    local navActive = (mq.TLO.Nav and mq.TLO.Nav.Active and mq.TLO.Nav.Active())
        or (mq.TLO.Navigation and mq.TLO.Navigation.Active
            and mq.TLO.Navigation.Active())
    if navActive then
        mq.cmd('/squelch /nav stop')
        stopped = stopped ~= '' and (stopped .. ',nav') or 'nav'
    end
    return stopped
end

local function isPureCasterClass()
    local class = tostring(mq.TLO.Me.Class.ShortName() or ''):upper()
    return M.PURE_CASTERS[class] == true
end

--- Pure casters always own their combat movement fence. Rangers participate
--- only when ranged standoff is explicitly enabled.
local function isCasterMovementClass(settings)
    if isPureCasterClass() then return true end
    local class = tostring(mq.TLO.Me.Class.ShortName() or ''):upper()
    return settings and settings.CasterStandoffEnabled == true and class == 'RNG'
end

local function isStandoffClass(settings)
    return isCasterMovementClass(settings)
        and settings and settings.CasterStandoffEnabled == true
end

--- Return locally observable encounter evidence. CombatState is deliberately
--- excluded: it describes OOC-rest eligibility, not whether a hostile is
--- presently engaged.
---@param settings table
---@param spawn userdata|nil
---@return boolean active
---@return string reason
---@return number targetId
local function getLocalCombatEvidence(settings, spawn)
    -- Any hater means combat for a caster, regardless of its current range.
    -- Restricting this to AssistRange let Chase wake when the tank moved a mob
    -- outside the local standoff vicinity.
    local aggressive, hostileId = SkLib.hasNearbyAggressiveXTarget()
    if aggressive then
        return true, 'local_xtarget', tonumber(hostileId) or 0
    end

    -- The cast itself bridges the exact handoff that used to let Chase wake:
    -- sk_dps has targeted an NPC and begun a detrimental spell, but its next
    -- telemetry sample (or the damage event) may not have arrived yet.
    local casting = mq.TLO.Me.Casting
    local castingName = casting and tostring(casting() or '') or ''
    if castingName ~= '' and castingName ~= 'NULL' then
        local detrimental = false
        pcall(function()
            local spellId = tonumber(casting.ID and casting.ID()) or 0
            local spell = spellId > 0 and mq.TLO.Spell(spellId)
                or mq.TLO.Spell(castingName)
            detrimental = spell and spell()
                and tostring(spell.SpellType and spell.SpellType() or ''):lower()
                    == 'detrimental'
        end)
        if detrimental then
            local current = mq.TLO.Target
            if current and current() and tostring(current.Type() or '') == 'NPC'
                and not (current.Dead and current.Dead())
            then
                return true, 'detrimental_cast', tonumber(current.ID()) or 0
            end
        end
    end

    if spawn and spawn() and tostring(spawn.Type() or '') == 'NPC'
        and not (spawn.Dead and spawn.Dead())
    then
        local spawnId = tonumber(spawn.ID()) or 0
        local hp = tonumber(spawn.PctHPs and spawn.PctHPs()) or 100
        if hp > 0 and hp < 100 then
            return true, 'damaged_target', spawnId
        end

        local targetType = tostring(
            spawn.Target and spawn.Target.Type and spawn.Target.Type() or ''):lower()
        if targetType == 'pc' or targetType == 'pet' or targetType == 'mercenary' then
            return true, 'engaged_target', spawnId
        end
    end

    return false, '', 0
end

local function rememberCombatMovementLease(reason, targetId)
    M.combatMovementLease.untilMs = mq.gettime() + STANDOFF_MOVEMENT_LEASE_MS
    M.combatMovementLease.targetId = tonumber(targetId) or 0
    M.combatMovementLease.reason = tostring(reason or 'combat')
end

local function clearCombatMovementLease()
    M.combatMovementLease.untilMs = 0
    M.combatMovementLease.targetId = 0
    M.combatMovementLease.reason = ''
end

--- Accept the local sk_dps intelligence snapshot. Actor callbacks only store
--- data; all navigation remains in the yieldable SideKick main loop.
---@param content table
function M.setCoordinatedTarget(content)
    local target = type(content) == 'table' and content.target or nil
    local action = type(content) == 'table' and content.action or nil
    local now = mq.gettime()
    local targetId = tonumber(target and target.id) or 0
    local combatActive = target and target.combatActive == true or false
    local lastCombatActiveAtMs = 0
    if combatActive then
        lastCombatActiveAtMs = now
    elseif targetId > 0 and targetId == (tonumber(M.coordinatedTarget.id) or 0) then
        lastCombatActiveAtMs = tonumber(M.coordinatedTarget.lastCombatActiveAtMs) or 0
    end
    M.coordinatedTarget = {
        id = targetId,
        name = tostring(target and target.name or ''),
        combatActive = combatActive,
        lastCombatActiveAtMs = lastCombatActiveAtMs,
        actionReady = type(action) == 'table'
            and tostring(action.spellName or '') ~= '',
        reason = tostring(type(content) == 'table' and content.reason or ''),
        receivedAtMs = now,
    }
end

--- Stop only navigation started by the standoff controller.
function M.stopStandoff()
    if M.standoffState.phase == 'moving' then
        stopAllPluginMovement()
        log.debug('standoff stopped externally target=%d',
            tonumber(M.standoffState.targetId) or 0)
    end
    M.standoffState.phase = 'idle'
    M.standoffState.startTime = 0
    M.standoffState.startX = 0
    M.standoffState.startY = 0
    M.standoffState.outwardX = 0
    M.standoffState.outwardY = 0
    M.standoffState.startDistance = 0
    M.standoffState.targetId = 0
    M.standoffState.moveKind = ''
    M.standoffState.destinationX = 0
    M.standoffState.destinationY = 0
    M.standoffState.positionedTargetId = 0
    M.standoffState.holdUntilMs = 0
    M.standoffState.retryAfterMs = 0
end

--- Should assist routing send this (non-pure-caster) class through CasterAssist?
-- Rangers use standoff positioning when enabled.
-- @param settings table Settings
-- @return boolean
function M.shouldRouteStandoff(settings)
    if not settings or settings.CasterStandoffEnabled ~= true then return false end
    local class = mq.TLO.Me.Class.ShortName()
    return class == 'RNG'
end

--- Side-effect-free standoff eligibility for the leased assist worker.
--- `combatAuthorized` is the consolidated Combat host's fresh Tank-primary
--- authorization. It permits initial positioning before this client's
--- CombatState changes after its first detrimental cast.
function M.getStandoffNeed(settings, targetId, combatAuthorized)
    if not settings or settings.CasterStandoffEnabled ~= true then
        return false, 'standoff_disabled'
    end
    local class = tostring(mq.TLO.Me.Class.ShortName() or ''):upper()
    if M.PURE_CASTERS[class] ~= true and class ~= 'RNG' then
        return false, 'unsupported_class'
    end
    targetId = tonumber(targetId) or 0
    local target = targetId > 0 and mq.TLO.Spawn(targetId) or nil
    if not (target and target()) or tostring(target.Type() or '') ~= 'NPC'
        or (target.Dead and target.Dead()) then
        return false, 'target_invalid'
    end
    if M.standoffState.phase == 'moving' then
        return M.standoffState.targetId == targetId,
            M.standoffState.targetId == targetId and 'moving' or 'different_target'
    end
    if combatAuthorized ~= true
        and tostring(mq.TLO.Me.CombatState() or '') ~= 'COMBAT' then
        return false, 'not_in_combat'
    end
    local casting = tostring(mq.TLO.Me.Casting() or '')
    if casting ~= '' and casting ~= 'NULL' then return false, 'casting' end
    local minD = tonumber(settings.CasterStandoffMin) or 35
    local distance = tonumber(target.Distance()) or 999

    -- A new coordinated target gets one leased positioning turn. The mutation
    -- path either retreats to the configured radius or, if already farther
    -- away, records the target as planted without moving inward.
    if tonumber(M.standoffState.positionedTargetId) ~= targetId then
        return true, 'initial_position'
    end

    -- StayAway semantics have only an inner trigger. Once safely outside it,
    -- never run toward a distant mob merely to satisfy a maximum distance.
    if distance >= minD then return false, 'outside_minimum' end
    if (mq.gettime() - M.lastStandoffMove) < M.standoffCooldownMs then
        return false, 'cooldown'
    end
    local navActive = mq.TLO.Navigation and mq.TLO.Navigation.Active
        and mq.TLO.Navigation.Active() == true
    if navActive and combatAuthorized ~= true then
        return false, 'external_navigation_active'
    end
    return true, string.format('inside_minimum:%.1f', distance)
end

function M.startStandoff(settings, targetId, combatAuthorized)
    local needed, reason =
        M.getStandoffNeed(settings, targetId, combatAuthorized)
    if not needed then return false, reason end
    M.tickStandoff(settings, targetId, reason == 'initial_position')
    return M.isRepositioning(),
        M.isRepositioning() and 'standoff_started'
            or (M.standoffState.positionedTargetId == targetId
                and 'standoff_planted' or 'standoff_not_started')
end

function M.advanceStandoff(settings, targetId)
    M.tickStandoff(settings, targetId)
    return not M.isRepositioning(),
        M.isRepositioning() and 'standoff_moving' or 'standoff_complete'
end

--- Standoff tick: establish the initial casting spot or retreat when too close.
-- @param settings table Settings
-- @param targetId number|nil Coordinated DPS target; current target is the legacy fallback
-- @param forceInitial boolean|nil Establish the retreat-radius spot for a new combat target
function M.tickStandoff(settings, targetId, forceInitial)
    if not settings or settings.CasterStandoffEnabled ~= true then return end
    local state = M.standoffState

    targetId = tonumber(targetId) or 0
    local target = targetId > 0 and mq.TLO.Spawn(targetId) or mq.TLO.Target
    local haveTarget = target and target() and (target.Type and target.Type() or '') == 'NPC'
        and not (target.Dead and target.Dead())
    local minD = tonumber(settings.CasterStandoffMin) or 35
    local retreatD = tonumber(settings.CasterStandoffMax) or 60
    -- Keep a real hysteresis band between the retreat trigger and destination.
    -- Nav may finish several feet short of the requested point; a five-foot
    -- gap could therefore leave the caster back inside the trigger and make
    -- the next spell cooldown look like a request to move again. MuleAssist
    -- similarly retreats to 40 from a 30-foot trigger.
    if retreatD < minD + 10 then retreatD = minD + 10 end
    local dist = haveTarget and (tonumber(target.Distance()) or 999) or 999

    if state.phase == 'moving' then
        -- `/stick` and `/moveto` can remain active independently of Nav. Chase
        -- used to leave those fallbacks behind when yielding, which pulled the
        -- caster toward the MA while this retreat Nav stayed active.
        local stopped = stopCompetingNonNavMovement()
        if stopped ~= '' then
            log.warn('standoff suppressed competing movement target=%d backends=%s',
                tonumber(state.targetId) or 0, stopped)
        end

        local navActive = mq.TLO.Navigation and mq.TLO.Navigation.Active and mq.TLO.Navigation.Active()
        local elapsed = os.clock() - state.startTime
        local myX = tonumber(mq.TLO.Me.X()) or state.startX
        local myY = tonumber(mq.TLO.Me.Y()) or state.startY
        local outwardProgress = (myX - state.startX) * state.outwardX
            + (myY - state.startY) * state.outwardY
        -- A valid retreat route can begin sideways around geometry, but it
        -- must never carry the caster materially toward the mob. Abort quickly
        -- instead of allowing the old eight-second timeout to run inward.
        local wrongWay = navActive and elapsed >= 0.5 and outwardProgress < -2
        if wrongWay then
            mq.cmd('/squelch /nav stop')
            local completedTargetId = tonumber(state.targetId) or 0
            log.warn('standoff movement aborted target=%d reason=wrong_direction startDistance=%.1f distance=%.1f outwardProgress=%.1f destination=%.1f,%.1f',
                completedTargetId, tonumber(state.startDistance) or 0, dist,
                outwardProgress, tonumber(state.destinationX) or 0,
                tonumber(state.destinationY) or 0)
            state.phase = 'idle'
            state.startTime = 0
            state.targetId = 0
            state.moveKind = ''
            state.retryAfterMs = mq.gettime() + 2000
            M.lastStandoffMove = mq.gettime()
            return
        end

        -- A retreat is one bounded movement, not a continuously recomputed
        -- orbit. MuleAssist's StayAwayToCast follows the same pattern: finish
        -- the selected retreat location, then plant and cast.
        if not haveTarget or (targetId > 0 and state.targetId ~= targetId)
            or not navActive or elapsed > 8
        then
            local completedTargetId = tonumber(state.targetId) or 0
            local completedKind = tostring(state.moveKind or '')
            local stopReason = not haveTarget and 'target_invalid'
                or ((targetId > 0 and state.targetId ~= targetId) and 'target_changed')
                or (not navActive and 'destination_reached')
                or 'timeout'
            if navActive then mq.cmd('/squelch /nav stop') end
            log.info('standoff %s ended target=%d reason=%s distance=%.1f',
                completedKind ~= '' and completedKind or 'movement',
                tonumber(state.targetId) or 0, stopReason, dist)
            state.phase = 'idle'
            state.startTime = 0
            state.startX = 0
            state.startY = 0
            state.outwardX = 0
            state.outwardY = 0
            state.startDistance = 0
            state.targetId = 0
            state.moveKind = ''
            state.destinationX = 0
            state.destinationY = 0
            local completedAtMs = mq.gettime()
            if completedKind == 'initial'
                and stopReason ~= 'target_invalid' and stopReason ~= 'target_changed'
            then
                state.positionedTargetId = completedTargetId
            end
            -- MuleAssist starts StayAwayMoveTimer after its blocking Nav
            -- finishes. Mirror that timing so a long route cannot consume the
            -- entire cooldown and immediately trigger another retreat.
            M.lastStandoffMove = completedAtMs
            if stopReason == 'destination_reached' then
                state.holdUntilMs = completedAtMs + M.standoffCooldownMs
                state.retryAfterMs = 0
                log.info('standoff planted target=%d hold=%dms distance=%.1f',
                    completedTargetId, M.standoffCooldownMs, dist)
            else
                state.holdUntilMs = 0
                state.retryAfterMs = completedAtMs + 2000
            end
        end
        return
    end

    if not haveTarget then return end

    -- Once Nav reaches the selected casting spot, remain planted for a full
    -- hold window. Casts are allowed during this phase; only another movement
    -- decision is suppressed. A target change bypasses the old target's hold
    -- so initial positioning for the new fight still happens immediately.
    local nowMs = mq.gettime()
    if (tonumber(state.retryAfterMs) or 0) > nowMs then return end
    state.retryAfterMs = 0
    if (tonumber(state.holdUntilMs) or 0) > nowMs then
        local heldTargetId = tonumber(state.positionedTargetId) or 0
        local currentTargetId = targetId > 0 and targetId
            or (tonumber(target.ID()) or 0)
        if heldTargetId == 0 or heldTargetId == currentTargetId then
            return
        end
        state.holdUntilMs = 0
    elseif (tonumber(state.holdUntilMs) or 0) > 0 then
        state.holdUntilMs = 0
    end

    -- Coordinated callers already provide a target marked combatActive by
    -- sk_dps, which can establish the casting spot before this client gains
    -- aggro. The legacy/current-target path accepts either a damaged NPC or a
    -- nearby hater XTarget; CombatState is only an OOC-rest state and is too
    -- late for initial positioning.
    if targetId <= 0 then
        local hp = tonumber(target.PctHPs and target.PctHPs()) or 100
        local damaged = hp > 0 and hp < 100
        local assistRange = tonumber(settings.AssistRange) or 100
        local retreatRange = tonumber(settings.CasterStandoffMax) or 60
        local vicinity = math.max(assistRange, retreatRange + 20)
        local aggressive = SkLib.hasNearbyAggressiveXTarget(vicinity)
        if not damaged and not aggressive then return end
    end

    -- StayAwayToCast semantics: the minimum is the retreat trigger, not the
    -- inner edge of a min/max orbit. Once safely outside it, remain planted no
    -- matter how far the mob moves away. This prevents repeated inward/outward
    -- repositioning while the tank and target move during combat. In
    -- particular, loss of line of sight is never permission to run toward an
    -- incoming or distant mob; DPS simply waits for a castable target.
    if forceInitial == true and dist >= retreatD then
        stopAllPluginMovement()
        state.positionedTargetId = targetId > 0
            and targetId or (tonumber(target.ID()) or 0)
        return
    end

    if forceInitial ~= true and dist >= minD then
        -- Stop a Chase route that began immediately before standoff acquired
        -- the coordinated combat target.
        stopAllPluginMovement()
        return
    end

    -- Never interrupt an in-progress cast; we'll move as soon as it finishes.
    -- Some MQ builds return the literal "NULL" while idle.
    local casting = tostring(mq.TLO.Me.Casting() or '')
    if casting ~= '' and casting ~= 'NULL' then return end

    -- Cooldown prevents dancing when mobs chase
    if forceInitial ~= true
        and (nowMs - M.lastStandoffMove) < M.standoffCooldownMs
    then
        return
    end
    M.lastStandoffMove = nowMs

    -- Retreat to one configured destination radius. The cooldown plus the
    -- min/retreat gap provides hysteresis if the mob follows.
    local x, y, z = pickStandoffSpot(target, retreatD, retreatD)
    local myX = tonumber(mq.TLO.Me.X()) or 0
    local myY = tonumber(mq.TLO.Me.Y()) or 0
    local mobX = tonumber(target.X()) or myX
    local mobY = tonumber(target.Y()) or myY
    local outwardDX = myX - mobX
    local outwardDY = myY - mobY
    local outwardLen = math.sqrt(outwardDX * outwardDX + outwardDY * outwardDY)
    if outwardLen < 0.001 then
        local destinationDX = x - mobX
        local destinationDY = y - mobY
        outwardLen = math.max(math.sqrt(destinationDX * destinationDX
            + destinationDY * destinationDY), 0.001)
        outwardDX, outwardDY = destinationDX, destinationDY
    end
    local moveKind = forceInitial == true and 'initial' or 'retreat'
    local moveReason = forceInitial == true and 'combat_target_acquired' or 'too_close'
    local stopped = stopAllPluginMovement()
    log.info('standoff %s starting target=%d reason=%s distance=%.1f trigger=%.1f destinationRadius=%.1f destination=%.1f,%.1f cleared=%s',
        moveKind, tonumber(targetId) or 0, moveReason, dist, minD, retreatD,
        x, y, stopped ~= '' and stopped or 'none')
    state.phase = 'moving'
    state.startTime = os.clock()
    state.startX = myX
    state.startY = myY
    state.outwardX = outwardDX / outwardLen
    state.outwardY = outwardDY / outwardLen
    state.startDistance = dist
    state.targetId = targetId > 0 and targetId or (tonumber(target.ID()) or 0)
    state.moveKind = moveKind
    state.destinationX = x
    state.destinationY = y
    mq.cmdf('/squelch /nav locxyz %.2f %.2f %.2f', x, y, z)
end

--- Resolve a fresh coordinated target backed by worker or local encounter
--- evidence. Movement ownership itself may outlive this snapshot briefly so
--- Chase cannot resume on the cast-completion boundary.
---@param settings table
---@return boolean ownsMovement
local function resolveCoordinatedMovementTarget(settings)
    if not isCasterMovementClass(settings) then return nil, nil end

    local target = M.coordinatedTarget
    local now = mq.gettime()
    local ageMs = now - (tonumber(target.receivedAtMs) or 0)
    if ageMs < 0 or ageMs > COORDINATED_TARGET_TTL_MS
        or (tonumber(target.id) or 0) <= 0
    then
        return nil, nil
    end

    local spawn = mq.TLO.Spawn(target.id)
    if not (spawn and spawn()) or tostring(spawn.Type() or '') ~= 'NPC'
        or (spawn.Dead and spawn.Dead())
    then
        return nil, nil
    end

    local lastActiveAt = tonumber(target.lastCombatActiveAtMs) or 0
    local combatActive = target.combatActive == true
        or (lastActiveAt > 0 and (now - lastActiveAt) <= COORDINATED_COMBAT_GRACE_MS)
    local localActive = getLocalCombatEvidence(settings, spawn)
    if not combatActive and not localActive then
        return nil, nil
    end
    return target, spawn
end

--- Return whether a caster has exclusive local combat-movement ownership.
--- Ownership survives cast completion and brief telemetry gaps while the
--- encounter is still locally observable; a dead/despawned leased target
--- releases at once. Standoff may move during this lease when enabled;
--- otherwise the caster remains planted.
---@param settings table
---@return boolean
function M.wantsCoordinatedMovement(settings)
    if not isCasterMovementClass(settings) then
        clearCombatMovementLease()
        return false
    end

    local target = resolveCoordinatedMovementTarget(settings)
    if target then
        local reason = target.combatActive == true
            and 'coordinated_target' or 'coordinated_target_local'
        rememberCombatMovementLease(reason, target.id)
        return true
    end

    -- Current-target evidence covers monolithic/telemetry-gap combat. Merely
    -- selecting an undamaged idle NPC is not enough; the helper requires a
    -- hater, detrimental cast, damage, or an NPC actively targeting a player.
    local active, reason, targetId = getLocalCombatEvidence(settings, mq.TLO.Target)
    if active then
        rememberCombatMovementLease(reason, targetId)
        return true
    end

    if M.standoffState.phase == 'moving' then
        rememberCombatMovementLease('standoff_moving', M.standoffState.targetId)
        return true
    end

    local now = mq.gettime()
    local leaseTargetId = tonumber(M.combatMovementLease.targetId) or 0
    if leaseTargetId > 0 then
        local leasedSpawn = mq.TLO.Spawn(leaseTargetId)
        if not (leasedSpawn and leasedSpawn())
            or tostring(leasedSpawn.Type() or '') ~= 'NPC'
            or (leasedSpawn.Dead and leasedSpawn.Dead())
        then
            clearCombatMovementLease()
            return false
        end
    end
    if now < (tonumber(M.combatMovementLease.untilMs) or 0) then
        return true
    end

    clearCombatMovementLease()
    return false
end

function M.tickCoordinated(settings)
    local ownsMovement = M.wantsCoordinatedMovement(settings)
    local target, spawn = resolveCoordinatedMovementTarget(settings)
    if ownsMovement and M.standoffState.phase ~= 'moving' then
        -- Enforce the fence before evaluating cooldown/hold branches. Those
        -- branches intentionally do not start standoff Nav, but another worker
        -- could otherwise keep steering the caster during their early return.
        local stopped = stopAllPluginMovement()
        if stopped ~= '' then
            log.warn('caster combat fence suppressed movement reason=%s backends=%s',
                tostring(M.combatMovementLease.reason or 'combat'), stopped)
        end
    end

    -- Pure casters are always planted during combat. Disabling standoff turns
    -- positioning off; it does not hand combat movement back to Chase/follow.
    if not isStandoffClass(settings) then
        if M.standoffState.phase == 'moving' then M.stopStandoff() end
        return ownsMovement
    end

    if not target then
        -- A standoff route already in flight remains the one permitted combat
        -- movement even if its worker snapshot briefly disappears.
        if ownsMovement and M.standoffState.phase == 'moving'
            and (tonumber(M.standoffState.targetId) or 0) > 0
        then
            M.tickStandoff(settings, M.standoffState.targetId)
            return true
        end

        if ownsMovement then
            -- The combat fence above planted the caster. Without a selected
            -- coordinated target there is no standoff route to start.
            return true
        end

        M.stopStandoff()
        return false
    end

    -- Establish the casting spot as soon as an engaged target is known. This
    -- is driven by combat-target telemetry (including a 99%-HP engage), not by
    -- whether a spell currently satisfies its condition.
    if M.standoffState.positionedTargetId ~= target.id then
        M.tickStandoff(settings, target.id, true)
        return true
    end

    -- Spell selection and movement run in separate Lua processes. When the
    -- worker advertises a ready spell, keep this frame planted so standoff
    -- cannot start Nav before the cast claim arrives. Only an immediately
    -- dangerous mob (roughly half the configured minimum, capped at 15) may
    -- override a ready cast and force a retreat.
    if target.actionReady == true and M.standoffState.phase ~= 'moving' then
        local minD = tonumber(settings.CasterStandoffMin) or 35
        local emergencyD = math.min(15, math.max(5, minD * 0.5))
        local dist = tonumber(spawn.Distance()) or 999
        if dist > emergencyD then
            stopAllPluginMovement()
            return true
        end
    end

    M.tickStandoff(settings, target.id)
    return true
end

--- Check if current class is a pure caster
-- @return boolean
function M.isPureCaster()
    local class = mq.TLO.Me.Class.ShortName()
    return M.PURE_CASTERS[class] == true
end

--- Check if current class is a hybrid melee
-- @return boolean
function M.isHybridMelee()
    local class = mq.TLO.Me.Class.ShortName()
    return M.HYBRID_MELEE[class] == true
end

--- Check if current class is pure melee
-- @return boolean
function M.isPureMelee()
    local class = mq.TLO.Me.Class.ShortName()
    return M.PURE_MELEE[class] == true
end

--- Initialize caster assist
-- @param opts table Options
function M.init(_opts)
    M.enabled = false
end

--- Enable/disable caster assist
-- @param val boolean
function M.setEnabled(val)
    M.enabled = val and true or false
end

--- Main tick function
-- @param settings table Settings table
function M.tick(settings)
    if not M.enabled then return end

    local standoffEnabled = settings and settings.CasterStandoffEnabled == true
    local isCaster = M.isPureCaster()
    if not isCaster and not (standoffEnabled and M.shouldRouteStandoff(settings)) then return end

    -- Standoff positioning: keep ranged distance from the target
    if standoffEnabled then
        M.tickStandoff(settings)
    end
end

return M
