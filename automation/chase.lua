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

local function humanizeOn()
    local cfg = _G.SIDEKICK_NEXT_CONFIG
    if not (cfg and cfg.HUMANIZE_BEHAVIOR) then return false end
    local ok, Profiles = pcall(require, 'sidekick-next.humanize.profiles')
    if ok and Profiles and Profiles.subsystemEnabled then
        return Profiles.subsystemEnabled('engagement')
    end
    return true
end

-- Effective trigger distance: configured value with ±20% jitter, fixed for
-- the duration of one chase episode. Clears when caller calls clearChaseRoll().
local function effectiveMaxDist(base)
    if not humanizeOn() then return base end
    if not _chaseRoll then
        local lo = base * 0.8
        local hi = base * 1.2
        _chaseRoll = lo + math.random() * (hi - lo)
    end
    return _chaseRoll
end

local function clearChaseRoll() _chaseRoll = nil end

local _Core = nil

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

    if not M.enabled or M.state.userPaused then return end
    if not mq or not mq.TLO or not mq.TLO.Me or not mq.TLO.Me() then return end

    if mq.TLO.Me.Hovering() or mq.TLO.Me.AutoFire() or mq.TLO.Me.Combat() then return end
    -- me.Casting() returns the spell name when casting OR the literal "NULL"
    -- when idle — must reject both. Treating "NULL" as truthy (the previous
    -- behavior) permanently suppressed chase whenever the player wasn't
    -- actually casting.
    local casting = mq.TLO.Me.Casting()
    if casting and casting ~= '' and casting ~= 'NULL' then return end
    if mq.TLO.Stick and mq.TLO.Stick.Active and mq.TLO.Stick.Active() then return end

    local navActive = (mq.TLO.Nav and mq.TLO.Nav.Active and mq.TLO.Nav.Active())
        or (mq.TLO.Navigation and mq.TLO.Navigation.Active and mq.TLO.Navigation.Active())

    if navActive and not _navState.initiatedNav then
        return
    end
    if not navActive then
        _navState.initiatedNav = false
    end

    local spawn = M.resolveSpawn()
    if not (spawn and spawn()) then
        _navState.stuckCount = 0
        return
    end
    if spawn.Type and spawn.Type() ~= 'PC' then return end

    local dist = M.distanceTo(spawn)
    if not dist then return end
    local baseDist = tonumber(M.state.distance) or 30
    local maxDist = effectiveMaxDist(baseDist)
    if dist <= maxDist then
        if navActive then M.stopNav() end
        _navState.stuckCount = 0
        clearChaseRoll()
        return
    end

    if navActive then
        if checkStuck() then
            doStuckRecovery()
        end
        return
    end

    local cleanName = spawn.CleanName and spawn.CleanName() or ''
    if cleanName == '' then return end

    local now = os.clock()
    if isUnderwater() then
        local id = spawn.ID and spawn.ID()
        if id and id > 0 then
            mq.cmdf('/stick 15 id %d uw moveback', id)
            _navState.lastNavAt = now
        end
        return
    end

    if (now - _navState.lastNavAt) < 2.0 then return end

    local pathOk = navMeshLoaded() and mq.TLO.Navigation and mq.TLO.Navigation.PathExists
        and mq.TLO.Navigation.PathExists(string.format('spawn pc =%s', cleanName))
    if pathOk then
        mq.cmdf('/nav spawn pc =%s | dist=10 log=off', cleanName)
        _navState.initiatedNav = true
        _navState.lastNavAt = now
        return
    end

    local hasMoveTo = mq.TLO.MoveTo and mq.TLO.MoveTo.Moving
    if hasMoveTo then
        local id = spawn.ID and spawn.ID()
        if id and id > 0 then
            mq.cmdf('/moveto id %d uw mdist 10', id)
            _navState.initiatedNav = true
            _navState.lastNavAt = now
        end
        return
    end

    local id = spawn.ID and spawn.ID()
    if id and id > 0 then
        mq.cmdf('/stick 20 id %d uw moveback', id)
        _navState.lastNavAt = now
    end
end

return M

