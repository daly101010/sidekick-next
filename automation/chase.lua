local mq = require('mq')

local M = {}

M.enabled = false
M.state = {
    role = 'none',
    target = '',
    distance = 30,
    userPaused = false,
}

M.ROLES = { 'none', 'ma', 'mt', 'leader', 'raid1', 'raid2', 'raid3' }

local _navState = {
    lastPosX = 0,
    lastPosY = 0,
    stuckCount = 0,
    lastNavAt = 0,
    initiatedNav = false,
}

-- Per-chase-episode jitter so the trigger distance varies between catches
-- without oscillating mid-chase. Cleared whenever we're in range.
local _chaseRoll = nil
local _chaseJitterPct = 0.20  -- ±20% default

local function humanizeOn()
    local cfg = _G.SIDEKICK_NEXT_CONFIG
    if not (cfg and cfg.HUMANIZE_BEHAVIOR) then return false end
    local ok, Profiles = pcall(require, 'sidekick-next.humanize.profiles')
    if ok and Profiles and Profiles.subsystemEnabled then
        return Profiles.subsystemEnabled('engagement')
    end
    return true
end

-- Effective trigger distance: configured value with ±_chaseJitterPct jitter,
-- fixed for the duration of one chase episode.
local function effectiveMaxDist(base)
    if not humanizeOn() or _chaseJitterPct <= 0 then return base end
    if not _chaseRoll then
        local lo = base * (1 - _chaseJitterPct)
        local hi = base * (1 + _chaseJitterPct)
        _chaseRoll = lo + math.random() * (hi - lo)
    end
    return _chaseRoll
end

local function clearChaseRoll() _chaseRoll = nil end

function M.getChaseJitterPct() return _chaseJitterPct end
function M.setChaseJitterPct(v)
    v = tonumber(v) or 0.20
    if v < 0 then v = 0 end
    if v > 0.5 then v = 0.5 end
    _chaseJitterPct = v
    _chaseRoll = nil
end

local _Core = nil
local _lastReason = 'init'

function M.init(opts)
    opts = opts or {}
    _Core = opts.Core
end

function M.stopNav()
    if mq and mq.cmd then mq.cmd('/squelch /nav stop') end
    _navState.initiatedNav = false
end

local function isUnderwater()
    local ok, wet = pcall(function() return mq.TLO.Me.FeetWet and mq.TLO.Me.FeetWet() end)
    return ok and wet
end

local function navMeshLoaded()
    if not mq.TLO.Navigation or not mq.TLO.Navigation.MeshLoaded then return false end
    local ok, result = pcall(function() return mq.TLO.Navigation.MeshLoaded() end)
    return ok and result
end

local function checkStuck()
    local x = mq.TLO.Me.X() or 0
    local y = mq.TLO.Me.Y() or 0
    if math.abs(x - _navState.lastPosX) < 1 and math.abs(y - _navState.lastPosY) < 1 then
        _navState.stuckCount = _navState.stuckCount + 1
    else
        _navState.stuckCount = 0
    end
    _navState.lastPosX = x
    _navState.lastPosY = y
    return _navState.stuckCount >= 4
end

-- Non-blocking stuck recovery: kicks off the back+strafe hold sequence and
-- schedules releases via module state so the main loop doesn't freeze for
-- 500ms. Releases are drained in tickStuckRecovery() each tick.
local _recovery = nil  -- { stage, releaseAt, strafe }

local function doStuckRecovery()
    if _recovery then return end  -- already in flight

    mq.cmd('/keypress back hold')
    local now = (mq.gettime and mq.gettime()) or (os.clock() * 1000)
    local strafe = (math.random(2) == 1) and 'strafe_left' or 'strafe_right'
    _recovery = { stage = 'back', releaseAt = now + 200, strafe = strafe }

    _navState.stuckCount = 0
    _navState.lastNavAt = 0
end

local function tickStuckRecovery()
    if not _recovery then return end
    local now = (mq.gettime and mq.gettime()) or (os.clock() * 1000)
    if now < _recovery.releaseAt then return end

    if _recovery.stage == 'back' then
        mq.cmd('/keypress back')
        mq.cmdf('/keypress %s hold', _recovery.strafe)
        _recovery.stage = 'strafe'
        _recovery.releaseAt = now + 300
    elseif _recovery.stage == 'strafe' then
        mq.cmdf('/keypress %s', _recovery.strafe)
        _recovery = nil
    end
end

function M.validateDistance(dist)
    dist = tonumber(dist)
    if not dist then return false end
    return dist >= 15 and dist <= 300
end

function M.resolveSpawn()
    local role = tostring(M.state.role or 'none'):lower()
    if role == 'ma' then
        return mq.TLO.Group and mq.TLO.Group.MainAssist
    elseif role == 'mt' then
        return mq.TLO.Group and mq.TLO.Group.MainTank
    elseif role == 'leader' then
        return mq.TLO.Group and mq.TLO.Group.Leader
    elseif role == 'raid1' then
        return mq.TLO.Raid and mq.TLO.Raid.MainAssist and mq.TLO.Raid.MainAssist(1)
    elseif role == 'raid2' then
        return mq.TLO.Raid and mq.TLO.Raid.MainAssist and mq.TLO.Raid.MainAssist(2)
    elseif role == 'raid3' then
        return mq.TLO.Raid and mq.TLO.Raid.MainAssist and mq.TLO.Raid.MainAssist(3)
    end

    local name = tostring(M.state.target or ''):gsub('^%s+', ''):gsub('%s+$', '')
    if name == '' then return nil end
    return mq.TLO.Spawn and mq.TLO.Spawn('pc =' .. name) or nil
end

function M.distanceTo(spawn)
    local meX, meY = mq.TLO.Me.X(), mq.TLO.Me.Y()
    local tx, ty = spawn.X(), spawn.Y()
    if not meX or not meY or not tx or not ty then return nil end
    local dx, dy = meX - tx, meY - ty
    return math.sqrt(dx * dx + dy * dy)
end

function M.setEnabled(val, opts)
    opts = opts or {}
    M.enabled = val and true or false

    if _Core and _Core.set then
        _Core.set('ChaseEnabled', M.enabled)
    elseif _Core and _Core.Settings then
        _Core.Settings.ChaseEnabled = M.enabled
    end

    if not M.enabled then
        M.stopNav()
        clearChaseRoll()
    end

    if opts.user then
        M.state.userPaused = not M.enabled
    elseif M.enabled then
        M.state.userPaused = false
    end
end

function M.tick()
    -- Always advance any in-flight stuck-recovery release sequence so the
    -- back/strafe hold gets cleared even if chase is paused mid-recovery.
    tickStuckRecovery()

    if not M.enabled then _lastReason = 'disabled'; return end
    if M.state.userPaused then _lastReason = 'user_paused'; return end
    if not mq or not mq.TLO or not mq.TLO.Me or not mq.TLO.Me() then _lastReason = 'no_character'; return end

    if mq.TLO.Me.Hovering() then _lastReason = 'hovering'; return end
    if mq.TLO.Me.AutoFire() then _lastReason = 'autofire'; return end
    if mq.TLO.Me.Combat() then _lastReason = 'melee_combat'; return end

    -- Ranged standoff owns in-combat positioning: while it's enabled and
    -- combat is active, chase yields entirely. Otherwise the two movement
    -- systems tug-of-war — standoff parks 35-60 units from the mob, chase
    -- notices we're beyond ChaseDistance of the tank and drags us back in,
    -- and the character ping-pongs between the two forever.
    do
        local okCore, Core = pcall(require, 'sidekick-next.utils.core')
        if okCore and Core and Core.Settings
            and Core.Settings.CasterStandoffEnabled == true
            and tostring(mq.TLO.Me.CombatState() or '') == 'COMBAT' then
            -- Leash exception: if the chase target has run a SUBSTANTIAL
            -- distance away (tank chasing a fleeing mob out of camp),
            -- keeping up matters more than the standoff spot — fall
            -- through and let chase run. Inside the leash, chase yields
            -- so casts are never movement-interrupted mid-fight.
            local leash = math.max(150, (tonumber(M.state.distance) or 30) * 4)
            local spawn = M.resolveSpawn()
            local dist = (spawn and spawn()) and M.distanceTo(spawn) or nil
            if not dist or dist <= leash then
                if _navState.initiatedNav then
                    local navActive = (mq.TLO.Nav and mq.TLO.Nav.Active and mq.TLO.Nav.Active())
                        or (mq.TLO.Navigation and mq.TLO.Navigation.Active and mq.TLO.Navigation.Active())
                    if navActive then M.stopNav() end
                end
                _lastReason = dist and string.format('standoff_combat:%.0f<=%d', dist, leash) or 'standoff_combat'
                return
            end
        end
    end
    -- me.Casting() returns the spell name when casting OR the literal "NULL"
    -- when idle — must reject both. Treating "NULL" as truthy (the previous
    -- behavior) permanently suppressed chase whenever the player wasn't
    -- actually casting.
    local casting = mq.TLO.Me.Casting()
    if casting and casting ~= '' and casting ~= 'NULL' then
        -- A cast that starts mid-chase must WIN. Returning with our own nav
        -- still running keeps the character moving, and the client cancels
        -- the cast on the first step — mez/charm died at cast start every
        -- time the enchanter was chasing. Only stop nav WE initiated;
        -- external nav (standoff, tank engage) manages its own casts.
        if _navState.initiatedNav then
            local navActive = (mq.TLO.Nav and mq.TLO.Nav.Active and mq.TLO.Nav.Active())
                or (mq.TLO.Navigation and mq.TLO.Navigation.Active and mq.TLO.Navigation.Active())
            if navActive then M.stopNav() end
        end
        _lastReason = 'casting'
        return
    end
    if mq.TLO.Stick and mq.TLO.Stick.Active and mq.TLO.Stick.Active() then _lastReason = 'stick_active'; return end

    local navActive = (mq.TLO.Nav and mq.TLO.Nav.Active and mq.TLO.Nav.Active())
        or (mq.TLO.Navigation and mq.TLO.Navigation.Active and mq.TLO.Navigation.Active())

    if navActive and not _navState.initiatedNav then
        _lastReason = 'external_nav_active'
        return
    end
    if not navActive then
        _navState.initiatedNav = false
    end

    local spawn = M.resolveSpawn()
    if not (spawn and spawn()) then
        _navState.stuckCount = 0
        _lastReason = 'no_chase_target'
        return
    end
    if spawn.Type and spawn.Type() ~= 'PC' then _lastReason = 'target_not_pc'; return end

    local dist = M.distanceTo(spawn)
    if not dist then _lastReason = 'no_distance'; return end
    local baseDist = tonumber(M.state.distance) or 30
    local maxDist = effectiveMaxDist(baseDist)
    if dist <= maxDist then
        if navActive then M.stopNav() end
        _navState.stuckCount = 0
        clearChaseRoll()
        _lastReason = string.format('in_range:%.1f<=%.1f', dist, maxDist)
        return
    end

    if navActive then
        if checkStuck() then
            doStuckRecovery()
            _lastReason = 'stuck_recovery'
        else
            _lastReason = string.format('nav_active:%.1f>%.1f', dist, maxDist)
        end
        return
    end

    local cleanName = spawn.CleanName and spawn.CleanName() or ''
    if cleanName == '' then _lastReason = 'empty_target_name'; return end

    local now = os.clock()
    if isUnderwater() then
        local id = spawn.ID and spawn.ID()
        if id and id > 0 then
            mq.cmdf('/stick 15 id %d uw moveback', id)
            _navState.lastNavAt = now
            _lastReason = string.format('stick_underwater:%s', cleanName)
        end
        return
    end

    if (now - _navState.lastNavAt) < 2.0 then _lastReason = 'nav_cooldown'; return end

    local pathOk = navMeshLoaded() and mq.TLO.Navigation and mq.TLO.Navigation.PathExists
        and mq.TLO.Navigation.PathExists(string.format('spawn pc =%s', cleanName))
    if pathOk then
        mq.cmdf('/nav spawn pc =%s | dist=10 log=off', cleanName)
        _navState.initiatedNav = true
        _navState.lastNavAt = now
        _lastReason = string.format('nav_to:%s dist=%.1f', cleanName, dist)
        return
    end

    local hasMoveTo = mq.TLO.MoveTo and mq.TLO.MoveTo.Moving
    if hasMoveTo then
        local id = spawn.ID and spawn.ID()
        if id and id > 0 then
            mq.cmdf('/moveto id %d uw mdist 10', id)
            _navState.initiatedNav = true
            _navState.lastNavAt = now
            _lastReason = string.format('moveto:%s dist=%.1f', cleanName, dist)
        end
        return
    end

    local id = spawn.ID and spawn.ID()
    if id and id > 0 then
        mq.cmdf('/stick 20 id %d uw moveback', id)
        _navState.lastNavAt = now
        _lastReason = string.format('stick:%s dist=%.1f', cleanName, dist)
    end
end

function M.status()
    local spawn = M.resolveSpawn()
    local name = nil
    local id = 0
    local dist = nil
    if spawn and spawn() then
        name = spawn.CleanName and spawn.CleanName() or tostring(spawn.Name and spawn.Name() or '')
        id = spawn.ID and spawn.ID() or 0
        dist = M.distanceTo(spawn)
    end
    local navActive = (mq.TLO.Nav and mq.TLO.Nav.Active and mq.TLO.Nav.Active())
        or (mq.TLO.Navigation and mq.TLO.Navigation.Active and mq.TLO.Navigation.Active())
    return {
        enabled = M.enabled == true,
        userPaused = M.state.userPaused == true,
        role = M.state.role,
        target = M.state.target,
        distance = M.state.distance,
        resolvedName = name,
        resolvedId = id,
        resolvedDistance = dist,
        navActive = navActive == true,
        initiatedNav = _navState.initiatedNav == true,
        reason = _lastReason,
    }
end

return M
