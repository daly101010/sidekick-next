-- Ported from Medley: standalone combat assist / stick / nav logic.
-- No yielding occurs unless called from SideKick main loop (never from ImGui callbacks).

local mq = require('mq')

local _MezHelper = nil
local _mezzedMobs = {}
local _lastMezListClean = 0

mq.event('combatassist_mezzed', '#1# has been mesmerized#*#', function(_, mobName)
    if mobName and mobName ~= '' then
        _mezzedMobs[mobName:lower()] = os.clock() + 60
    end
end)

mq.event('combatassist_mezwoke', '#1# has been awakened by#*#', function(_, mobName)
    if mobName and mobName ~= '' then
        _mezzedMobs[mobName:lower()] = nil
    end
end)

local function isMobMezzed(spawnOrName)
    if not spawnOrName then return false end

    local name, id
    if type(spawnOrName) == 'string' then
        name = spawnOrName
        id = 0
    elseif spawnOrName.CleanName then
        name = spawnOrName.CleanName() or ''
        id = spawnOrName.ID and spawnOrName.ID() or 0
    else
        return false
    end

    if _MezHelper and _MezHelper.is_mob_mezzed then
        local mezzed, remain = _MezHelper.is_mob_mezzed(id, name)
        if mezzed and remain > 0 then return true end
    end

    if name ~= '' then
        local until_t = _mezzedMobs[name:lower()]
        if until_t and os.clock() <= until_t then
            return true
        elseif until_t then
            _mezzedMobs[name:lower()] = nil
        end
    end

    return false
end

local function cleanMezList()
    local now = os.clock()
    if (now - _lastMezListClean) < 10 then return end
    _lastMezListClean = now
    for k, v in pairs(_mezzedMobs) do
        if now > v then _mezzedMobs[k] = nil end
    end
end

local config = {
    assist_at = 97,
    assist_rng = 100,
    use_stick = true,
    stick_cmd = '',
    tick_delay = 200,
    nav_timeout = 10,
    stuck_threshold = 3,
    assist_mode = 'group',
    assist_name = '',
}

local ASSIST_MODES = { 'group', 'raid1', 'raid2', 'raid3', 'byname' }

local _lastStickId = nil
local _lastStickCmd = nil
local _lastStickAt = 0
local _lastNavAt = 0
local _lastNavId = 0
local _lastPosX = 0
local _lastPosY = 0
local _stuckCount = 0
local _navStartTime = 0

local function nav_active()
    return (mq.TLO.Nav and mq.TLO.Nav.Active and mq.TLO.Nav.Active())
        or (mq.TLO.Navigation and mq.TLO.Navigation.Active and mq.TLO.Navigation.Active())
end

local function nav_path_exists(query)
    if not mq.TLO.Navigation or not mq.TLO.Navigation.PathExists then return false end
    local ok, result = pcall(function() return mq.TLO.Navigation.PathExists(query)() end)
    return ok and result
end

local function nav_mesh_loaded()
    if not mq.TLO.Navigation or not mq.TLO.Navigation.MeshLoaded then return false end
    local ok, result = pcall(function() return mq.TLO.Navigation.MeshLoaded() end)
    return ok and result
end

local function stop_nav()
    if nav_active() then
        mq.cmd('/squelch /nav stop')
    end
end

local function stop_stick()
    local ok, status = pcall(function()
        return mq.TLO.Stick and mq.TLO.Stick.Active and mq.TLO.Stick.Active()
    end)
    if ok and status then
        mq.cmd('/squelch /stick off')
    end
end

local function is_underwater()
    local ok, wet = pcall(function() return mq.TLO.Me.FeetWet and mq.TLO.Me.FeetWet() end)
    return ok and wet
end

local function check_stuck()
    local x = mq.TLO.Me.X() or 0
    local y = mq.TLO.Me.Y() or 0
    if math.abs(x - _lastPosX) < 1 and math.abs(y - _lastPosY) < 1 then
        _stuckCount = _stuckCount + 1
    else
        _stuckCount = 0
    end
    _lastPosX = x
    _lastPosY = y
    return _stuckCount >= (config.stuck_threshold or 3)
end

local function do_stuck_recovery()
    mq.cmd('/keypress back hold')
    mq.delay(200)
    mq.cmd('/keypress back')
    local strafe = (math.random(2) == 1) and 'strafe_left' or 'strafe_right'
    mq.cmdf('/keypress %s hold', strafe)
    mq.delay(300)
    mq.cmdf('/keypress %s', strafe)
    _stuckCount = 0
    _lastNavAt = 0
end

local function safe_num(fn, fallback)
    local ok, v = pcall(fn)
    if not ok then return fallback end
    return tonumber(v) or fallback
end

local function is_attackable(spawn)
    if not spawn or not spawn() then return false end
    if spawn.Type and spawn.Type() ~= 'NPC' then return false end
    if spawn.Dead and spawn.Dead() then return false end
    if spawn.LineOfSight and spawn.LineOfSight() == false then return false end
    return true
end

local function get_assist_target()
    if config.assist_mode == 'group' then
        local ma = mq.TLO.Group and mq.TLO.Group.MainAssist
        if ma and ma() and ma.ID and ma.ID() and ma.ID() > 0 then
            local maSpawn = mq.TLO.Spawn(string.format('id %d', ma.ID()))
            if maSpawn and maSpawn() and maSpawn.Target and maSpawn.Target() then
                return maSpawn.Target
            end
        end
        return nil
    end

    if config.assist_mode:match('^raid') then
        local idx = tonumber(config.assist_mode:match('raid(%d)'))
        local ma = idx and mq.TLO.Raid and mq.TLO.Raid.MainAssist and mq.TLO.Raid.MainAssist(idx)
        if ma and ma() and ma.ID and ma.ID() and ma.ID() > 0 then
            local maSpawn = mq.TLO.Spawn(string.format('id %d', ma.ID()))
            if maSpawn and maSpawn() and maSpawn.Target and maSpawn.Target() then
                return maSpawn.Target
            end
        end
        return nil
    end

    if config.assist_mode == 'byname' and config.assist_name ~= '' then
        local sp = mq.TLO.Spawn('pc =' .. config.assist_name)
        if sp and sp() and sp.Target and sp.Target() then
            return sp.Target
        end
    end

    return nil
end

local function retarget(id)
    if not id or id <= 0 then return end
    local cur = safe_num(function() return mq.TLO.Target.ID() end, 0)
    if cur ~= id then
        mq.cmdf('/squelch /target id %d', id)
    end
end

local function nav_to_target(id, dist)
    dist = tonumber(dist) or 15
    local now = os.clock()
    if (now - _lastNavAt) < 1.0 and _lastNavId == id then return true end
    _lastNavAt = now
    _lastNavId = id

    if nav_mesh_loaded() and nav_path_exists(string.format('id %d', id)) then
        mq.cmdf('/nav id %d dist=%d log=off', id, dist)
        if _navStartTime == 0 then _navStartTime = now end
        if (now - _navStartTime) > (config.nav_timeout or 10) then
            stop_nav()
            _navStartTime = 0
            return false
        end
        return true
    end

    local hasMoveTo = mq.TLO.MoveTo and mq.TLO.MoveTo.Moving
    if hasMoveTo then
        mq.cmdf('/moveto id %d mdist %d', id, dist)
        return true
    end
    return false
end

local function do_stick(id, spawn)
    if not config.use_stick then return end
    local now = os.clock()
    if (now - _lastStickAt) < 1.0 and _lastStickId == id then return end
    _lastStickAt = now
    _lastStickId = id

    local cmd = tostring(config.stick_cmd or ''):gsub('^%s+', ''):gsub('%s+$', '')
    if cmd == '' then
        cmd = 'hold moveback'
    end

    if is_underwater() then
        cmd = cmd .. ' uw'
    end

    if _lastStickCmd ~= cmd then
        _lastStickCmd = cmd
    end
    mq.cmdf('/squelch /stick id %d %s', id, cmd)
end

local function engage(spawn)
    if not spawn or not spawn() then return end
    if _MezHelper and _MezHelper.is_busy and _MezHelper.is_busy() then return end

    local id = spawn.ID and spawn.ID() or 0
    if id <= 0 then return end
    retarget(id)
    local tar = mq.TLO.Target
    if not is_attackable(tar) then return end

    if isMobMezzed(tar) then return end

    local pct = tonumber(tar.PctHPs and tar.PctHPs())
    if not pct or pct > (config.assist_at or 97) then return end

    local dist = tonumber(tar.Distance3D and tar.Distance3D()) or 999
    if dist > (config.assist_rng or 100) then return end

    local los = tar.LineOfSight and tar.LineOfSight()
    local maxRange = tar.MaxRangeTo and tar.MaxRangeTo() or 50

    if not los or dist > maxRange then
        if nav_to_target(id, math.min(maxRange - 5, 15)) then
            if check_stuck() then do_stuck_recovery() end
            return
        end
        if not is_underwater() then
            return
        end
    else
        if nav_active() then
            stop_nav()
            _navStartTime = 0
        end
    end

    if mq.TLO.Me.Sitting() then mq.cmd('/stand') end
    do_stick(id, spawn)

    local stickActive = false
    pcall(function() stickActive = mq.TLO.Stick and mq.TLO.Stick.Active and mq.TLO.Stick.Active() end)
    if stickActive and check_stuck() then do_stuck_recovery() end

    if not mq.TLO.Me.Combat() then
        mq.cmd('/attack on')
    end
end

local function clear_engage()
    if mq.TLO.Me.Combat() then
        mq.cmd('/attack off')
    end
    stop_stick()
    _stuckCount = 0
end

local function apply_config(opts)
    if type(opts) ~= 'table' then return end
    if opts.assist_at ~= nil then config.assist_at = tonumber(opts.assist_at) or config.assist_at end
    if opts.assist_rng ~= nil then config.assist_rng = tonumber(opts.assist_rng) or config.assist_rng end
    if opts.use_stick ~= nil then config.use_stick = not not opts.use_stick end
    if opts.stick_cmd ~= nil then
        config.stick_cmd = tostring(opts.stick_cmd):gsub('%%%%', '%%'):gsub('^%s+', ''):gsub('%s+$', '')
        _lastStickCmd = nil
    end
    if opts.tick_delay ~= nil then config.tick_delay = tonumber(opts.tick_delay) or config.tick_delay end
    if opts.nav_timeout ~= nil then config.nav_timeout = tonumber(opts.nav_timeout) or config.nav_timeout end
    if opts.stuck_threshold ~= nil then config.stuck_threshold = tonumber(opts.stuck_threshold) or config.stuck_threshold end
    if opts.assist_mode ~= nil then
        local mode = tostring(opts.assist_mode):lower()
        local valid = false
        for _, m in ipairs(ASSIST_MODES) do
            if m == mode then valid = true break end
        end
        if valid then config.assist_mode = mode end
    end
    if opts.assist_name ~= nil then
        config.assist_name = tostring(opts.assist_name):gsub('^%s+', ''):gsub('%s+$', '')
    end
end

local function init(opts)
    if type(opts) ~= 'table' then return end
    if opts.MezHelper then _MezHelper = opts.MezHelper end
end

local function stop()
    clear_engage()
    stop_nav()
end

local function tick()
    cleanMezList()
    local spawn = get_assist_target()
    if spawn and spawn() then
        engage(spawn)
    else
        clear_engage()
    end
end

return {
    tick = tick,
    config = config,
    stop = stop,
    apply_config = apply_config,
    init = init,
    ASSIST_MODES = ASSIST_MODES,
    isMobMezzed = isMobMezzed,
}

