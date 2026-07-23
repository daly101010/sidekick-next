-- F:/lua/SideKick/automation/caster_assist.lua
-- Caster-specific assist logic: stay-put casting with rooted-mob escape

local mq = require('mq')
local lazy = require('sidekick-next.utils.lazy_require')

local M = {}

-- Class categorization
M.PURE_CASTERS = {
    ENC = true, WIZ = true, MAG = true,
    NEC = true, CLR = true, DRU = true, SHM = true,
}

M.HYBRID_MELEE = {
    PAL = true, SHD = true, RNG = true, BST = true, BRD = true,
}

M.PURE_MELEE = {
    WAR = true, MNK = true, ROG = true, BER = true,
}

-- State
M.enabled = false
M.escapeState = {
    phase = 'idle',  -- idle, finding_safe, navigating, kiting
    targetGroupmateId = nil,
    kiteDirection = nil,
    rootedMobId = nil,
    startTime = 0,
}

-- Standoff state (keep ranged distance from the target so rains/AEs on the mob
-- don't clip the caster)
M.standoffState = {
    phase = 'idle',  -- idle, moving
    startTime = 0,
}
M.standoffCooldownMs = 4000
M.lastStandoffMove = 0

-- Lazy-load dependencies
local getCore = lazy('sidekick-next.utils.core')
local getCombatAssist = lazy('sidekick-next.utils.combatassist')

--- Check if a spawn is targeting me
-- @param spawn userdata Spawn to check
-- @return boolean
local function isTargetingMe(spawn)
    if not spawn or not spawn() then return false end
    local myId = mq.TLO.Me.ID()
    local targetId = spawn.TargetOfTarget and spawn.TargetOfTarget.ID and spawn.TargetOfTarget.ID()
    return targetId == myId
end

--- Check if a spawn is rooted
-- @param spawn userdata Spawn to check
-- @return boolean
local function isRooted(spawn)
    if not spawn or not spawn() then return false end
    local rooted = spawn.Rooted and spawn.Rooted()
    return rooted and rooted ~= ''
end

--- Check if I'm on a mob's hate list (via XTarget)
-- @param spawnId number Spawn ID to check
-- @return boolean
local function isOnHateList(spawnId)
    if not spawnId or spawnId <= 0 then return false end
    local xtCount = mq.TLO.Me.XTarget() or 0
    for i = 1, xtCount do
        local xt = mq.TLO.Me.XTarget(i)
        if xt and xt() and xt.ID() == spawnId then
            return true
        end
    end
    return false
end

--- Find a rooted mob that's hitting me
-- @return userdata|nil Rooted mob spawn, or nil
local function findRootedMobHittingMe()
    local xtCount = mq.TLO.Me.XTarget() or 0
    for i = 1, xtCount do
        local xt = mq.TLO.Me.XTarget(i)
        if xt and xt() and xt.ID() and xt.ID() > 0 then
            -- Check if this mob is targeting me and is rooted
            if isTargetingMe(xt) and isRooted(xt) then
                return xt
            end
        end
    end
    return nil
end

--- Count hostile mobs near a location
-- @param x number X coordinate
-- @param y number Y coordinate
-- @param radius number Search radius
-- @return number Count of hostile NPCs
local function countHostilesNear(x, y, radius)
    local count = 0
    local xtCount = mq.TLO.Me.XTarget() or 0
    for i = 1, xtCount do
        local xt = mq.TLO.Me.XTarget(i)
        if xt and xt() and xt.ID() and xt.ID() > 0 then
            local mobX = xt.X() or 0
            local mobY = xt.Y() or 0
            local dist = math.sqrt((x - mobX)^2 + (y - mobY)^2)
            if dist <= radius then
                count = count + 1
            end
        end
    end
    return count
end

--- Find the nearest safe groupmate (no hostiles nearby)
-- @param safeRadius number Radius to check for hostiles
-- @return number|nil Spawn ID of safe groupmate, or nil
local function findSafeGroupmate(safeRadius)
    local myId = mq.TLO.Me.ID()
    local myX = mq.TLO.Me.X() or 0
    local myY = mq.TLO.Me.Y() or 0

    local bestId = nil
    local bestDist = math.huge

    local groupCount = mq.TLO.Group.Members() or 0
    for i = 1, groupCount do
        local member = mq.TLO.Group.Member(i)
        if member and member() and member.ID() ~= myId then
            local memberId = member.ID()
            local memberX = member.X() or 0
            local memberY = member.Y() or 0

            -- Check if this groupmate has no hostiles near them
            local hostileCount = countHostilesNear(memberX, memberY, safeRadius)
            if hostileCount == 0 then
                -- Calculate distance to me
                local dist = math.sqrt((myX - memberX)^2 + (myY - memberY)^2)
                if dist < bestDist then
                    bestDist = dist
                    bestId = memberId
                end
            end
        end
    end

    return bestId
end

--- Calculate a position X units away from a mob
-- @param mobId number Mob spawn ID
-- @param distance number Distance to move away
-- @return number, number New X, Y coordinates
local function calculateKitePosition(mobId, distance)
    local mob = mq.TLO.Spawn(mobId)
    if not mob or not mob() then
        return mq.TLO.Me.X(), mq.TLO.Me.Y()
    end

    local myX = mq.TLO.Me.X() or 0
    local myY = mq.TLO.Me.Y() or 0
    local mobX = mob.X() or 0
    local mobY = mob.Y() or 0

    -- Calculate direction away from mob
    local dx = myX - mobX
    local dy = myY - mobY
    local len = math.sqrt(dx^2 + dy^2)

    if len < 1 then
        -- Too close, pick a random direction
        local angle = math.random() * 2 * math.pi
        dx = math.cos(angle)
        dy = math.sin(angle)
        len = 1
    end

    -- Normalize and extend
    local newX = myX + (dx / len) * distance
    local newY = myY + (dy / len) * distance

    return newX, newY
end

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

    -- Base direction: from the mob toward me (stay on my own side, don't cross
    -- the camp), then rotate by this character's personal offset
    local dx, dy = myX - mobX, myY - mobY
    local base
    if (dx * dx + dy * dy) < 1 then
        base = math.random() * 2 * math.pi
    else
        base = math.atan2(dx, dy)
    end
    base = base + math.rad(_nameAngleOffset)

    for attempt = 1, 8 do
        -- Jitter widens with each failed attempt to find valid ground
        local spreadDeg = 20 + attempt * 10
        local angle = base + math.rad(math.random(-spreadDeg, spreadDeg))
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

--- Should assist routing send this (non-pure-caster) class through CasterAssist?
-- Rangers use standoff positioning when enabled.
-- @param settings table Settings
-- @return boolean
function M.shouldRouteStandoff(settings)
    if not settings or settings.CasterStandoffEnabled ~= true then return false end
    local class = mq.TLO.Me.Class.ShortName()
    return class == 'RNG'
end

--- Standoff tick: move to a randomized ranged spot when too close to the target
-- @param settings table Settings
function M.tickStandoff(settings)
    if not settings or settings.CasterStandoffEnabled ~= true then return end
    local state = M.standoffState

    local target = mq.TLO.Target
    local haveTarget = target and target() and (target.Type and target.Type() or '') == 'NPC'
        and not (target.Dead and target.Dead())

    if state.phase == 'moving' then
        local navActive = mq.TLO.Navigation and mq.TLO.Navigation.Active and mq.TLO.Navigation.Active()
        if not haveTarget or not navActive or (os.clock() - state.startTime) > 8 then
            if navActive then mq.cmd('/squelch /nav stop') end
            state.phase = 'idle'
        end
        return
    end

    if not haveTarget then return end

    -- Only reposition during combat
    local combatState = tostring(mq.TLO.Me.CombatState() or '')
    if combatState ~= 'COMBAT' then return end

    local minD = tonumber(settings.CasterStandoffMin) or 35
    local maxD = tonumber(settings.CasterStandoffMax) or 60
    if maxD < minD + 5 then maxD = minD + 5 end

    local dist = tonumber(target.Distance()) or 999
    if dist >= minD then return end

    -- Never interrupt an in-progress cast; we'll move as soon as it finishes
    if mq.TLO.Me.Casting() then return end

    -- Cooldown prevents dancing when mobs chase
    if (mq.gettime() - M.lastStandoffMove) < M.standoffCooldownMs then return end
    M.lastStandoffMove = mq.gettime()

    local x, y, z = pickStandoffSpot(target, minD, maxD)
    state.phase = 'moving'
    state.startTime = os.clock()
    mq.cmdf('/squelch /nav locxyz %.2f %.2f %.2f', x, y, z)
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
function M.init(opts)
    opts = opts or {}
    M.enabled = false
    M.escapeState.phase = 'idle'
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

    -- Check if user wants stick mode (behave like melee).
    -- Standoff takes precedence - sticking to the mob defeats ranged casting.
    local useStick = isCaster and settings and settings.CasterUseStick and not standoffEnabled
    if useStick then
        -- Delegate to CombatAssist for melee-like behavior
        local ca = getCombatAssist()
        if ca and ca.tick then
            ca.tick()
        end
        return
    end

    -- Stay-put caster mode: check for escape conditions
    M.checkEscapeCondition(settings)

    -- Handle ongoing escape navigation (takes priority over standoff)
    if M.escapeState.phase ~= 'idle' then
        M.tickEscape(settings)
        return
    end

    -- Standoff positioning: keep ranged distance from the target
    if standoffEnabled then
        M.tickStandoff(settings)
    end
end

--- Check if we need to escape from a rooted mob
-- @param settings table Settings
function M.checkEscapeCondition(settings)
    -- Already escaping? Don't re-check
    if M.escapeState.phase ~= 'idle' then return end

    -- Check if currently casting a mez or heal (don't interrupt these)
    local casting = mq.TLO.Me.Casting
    if casting and casting() then
        local spellName = casting.Name and casting.Name() or ''
        local targetType = casting.TargetType and casting.TargetType() or ''
        local category = casting.Category and casting.Category() or ''

        -- Check for mez (category or spell name patterns)
        local isMez = category:lower():find('mesmerize') or
                      spellName:lower():find('mez') or
                      spellName:lower():find('mesmer')

        -- Check for heal (beneficial + HP-related)
        local isHeal = (targetType == 'Single' or targetType == 'Group') and
                       (category:lower():find('heal') or spellName:lower():find('heal'))

        if isMez or isHeal then
            -- Let the cast complete
            return
        end
    end

    -- Find a rooted mob hitting me
    local rootedMob = findRootedMobHittingMe()
    if not rootedMob then return end

    -- Start escape sequence
    M.escapeState = {
        phase = 'finding_safe',
        targetGroupmateId = nil,
        kiteDirection = nil,
        rootedMobId = rootedMob.ID(),
        startTime = os.clock(),
    }

    -- Interrupt current cast (if any, and not mez/heal - already checked above)
    if mq.TLO.Me.Casting() then
        mq.cmd('/stopcast')
    end
end

--- Tick the escape state machine
-- @param settings table Settings
function M.tickEscape(settings)
    local state = M.escapeState
    local safeRadius = settings and settings.CasterSafeZoneRadius or 30
    local escapeRange = settings and settings.CasterEscapeRange or 30

    -- Timeout after 10 seconds
    if (os.clock() - state.startTime) > 10 then
        M.escapeState.phase = 'idle'
        mq.cmd('/squelch /nav stop')
        return
    end

    -- Check if rooted mob is dead or no longer a threat
    if state.rootedMobId then
        local mob = mq.TLO.Spawn(state.rootedMobId)
        if not mob or not mob() or (mob.Dead and mob.Dead()) then
            -- Threat gone, stop escaping
            M.escapeState.phase = 'idle'
            mq.cmd('/squelch /nav stop')
            return
        end

        -- Check if we're now out of range
        local dist = mob.Distance() or 0
        if dist > escapeRange then
            -- Safe now
            M.escapeState.phase = 'idle'
            mq.cmd('/squelch /nav stop')
            return
        end
    end

    -- State machine
    if state.phase == 'finding_safe' then
        -- Try to find a safe groupmate
        local safeId = findSafeGroupmate(safeRadius)
        if safeId then
            state.targetGroupmateId = safeId
            state.phase = 'navigating'
            mq.cmdf('/nav id %d', safeId)
        else
            -- No safe groupmate, kite away from mob
            local kiteX, kiteY = calculateKitePosition(state.rootedMobId, escapeRange)
            state.kiteDirection = { x = kiteX, y = kiteY }
            state.phase = 'kiting'
            mq.cmdf('/nav loc %f %f', kiteX, kiteY)
        end

    elseif state.phase == 'navigating' then
        -- Check if nav is complete
        local navActive = mq.TLO.Navigation and mq.TLO.Navigation.Active and mq.TLO.Navigation.Active()
        if not navActive then
            -- Arrived at safe groupmate
            mq.cmd('/squelch /nav stop')
            M.escapeState.phase = 'idle'
        end

    elseif state.phase == 'kiting' then
        -- Check if nav is complete
        local navActive = mq.TLO.Navigation and mq.TLO.Navigation.Active and mq.TLO.Navigation.Active()
        if not navActive then
            -- Arrived at kite position
            mq.cmd('/squelch /nav stop')
            M.escapeState.phase = 'idle'
        end
    end
end

return M
