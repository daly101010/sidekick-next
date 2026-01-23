---@diagnostic disable: undefined-field
--[[
  combatassist.lua - Combat assist & stick logic for SideKick

  Adapted from medley/utils/combatassist.lua
  Patterns from rgmercs, MuleAssist, and chase.lua
]]

local mq = require('mq')

-- ============================================================================
-- Mez Tracking (MuleAssist pattern)
-- ============================================================================
local _mezzedMobs = {}
local _lastMezListClean = 0

mq.event('sk_combatassist_mezzed', '#1# has been mesmerized#*#', function(_, mobName)
  if mobName and mobName ~= '' then
    _mezzedMobs[mobName:lower()] = os.clock() + 60
  end
end)

mq.event('sk_combatassist_mezwoke', '#1# has been awakened by#*#', function(_, mobName)
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
  if name == '' and id == 0 then return false end

  -- Check spawn's Mezzed buff directly
  if id > 0 then
    local spawn = mq.TLO.Spawn(id)
    if spawn and spawn() then
      local mezzed = spawn.Mezzed and spawn.Mezzed()
      if mezzed and mezzed.ID and mezzed.ID() then
        return true
      end
    end
  end

  -- Fallback to local event-based tracking
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

-- ============================================================================
-- Configuration
-- ============================================================================
local config = {
  enabled         = false, -- Master enable toggle
  assist_at       = 97,    -- % HP to start assisting
  assist_rng      = 100,   -- max distance to assist
  use_stick       = true,  -- issue /stick to stay in range
  stick_cmd       = '',    -- custom stick command (blank = auto tank/dps)
  tick_delay      = 200,   -- ms between checks
  nav_timeout     = 10,    -- seconds before nav gives up
  stuck_threshold = 3,     -- stuck checks before recovery
  -- Assist mode: 'group', 'raid1', 'raid2', 'raid3', or 'byname'
  assist_mode     = 'group',
  assist_name     = '',    -- Player name when assist_mode = 'byname'
}

-- Valid assist modes for reference
local ASSIST_MODES = { 'group', 'raid1', 'raid2', 'raid3', 'byname' }

-- ============================================================================
-- State Tracking
-- ============================================================================
local _lastStickId = nil
local _lastStickCmd = nil
local _lastStickAt = 0
local _lastNavAt = 0
local _lastNavId = 0
local _lastPosX = 0
local _lastPosY = 0
local _stuckCount = 0
local _navStartTime = 0

-- ============================================================================
-- Utility Functions
-- ============================================================================

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
    return mq.TLO.Stick and mq.TLO.Stick.Status and mq.TLO.Stick.Status()
  end)
  if ok and status and status:lower() ~= 'off' then
    mq.cmd('/squelch /stick off')
  end
end

local function is_underwater()
  local ok, wet = pcall(function() return mq.TLO.Me.FeetWet and mq.TLO.Me.FeetWet() end)
  return ok and wet
end

local function is_i_am_ma()
  local meId = mq.TLO.Me.ID() or 0
  local maId = 0
  pcall(function()
    maId = mq.TLO.Group and mq.TLO.Group.MainAssist and mq.TLO.Group.MainAssist.ID and mq.TLO.Group.MainAssist.ID() or 0
  end)
  return meId > 0 and maId > 0 and meId == maId
end

local function get_target_stick_distance(spawn)
  if not spawn then return 15 end
  local ok, height = pcall(function() return spawn.Height and spawn.Height() end)
  if not ok or not height then height = 5 end
  if height > 15 then return 25 end
  if height > 10 then return 20 end
  return 15
end

local function is_attackable(spawn)
  if not spawn then return false end
  local ok, exists = pcall(function() return spawn() end)
  if not ok or not exists then return false end
  local t = spawn.Type and spawn.Type()
  if t ~= 'NPC' and t ~= 'Pet' then return false end
  local dead = spawn.Dead and spawn.Dead()
  if dead then return false end
  return true
end

-- ============================================================================
-- Stuck Detection & Recovery (MuleAssist pattern)
-- ============================================================================

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

  return _stuckCount >= config.stuck_threshold
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
  _lastStickAt = 0
end

-- ============================================================================
-- Navigation
-- ============================================================================

local function nav_to_target(id, distance)
  local now = os.clock()

  if nav_active() and _navStartTime > 0 and (now - _navStartTime) > config.nav_timeout then
    stop_nav()
    _navStartTime = 0
    return false
  end

  if nav_active() and _lastNavId == id and (now - _lastNavAt) < 2.0 then
    return true
  end

  if is_underwater() then
    return false
  end

  distance = distance or 15
  local navQuery = string.format('id %d distance %d', id, distance)

  if nav_mesh_loaded() and nav_path_exists(navQuery) then
    stop_stick()
    mq.cmdf('/nav id %d distance=%d log=off lineofsight=on', id, distance)
    _lastNavAt = now
    _lastNavId = id
    _navStartTime = now
    return true
  end

  local hasMoveTo = mq.TLO.MoveTo and mq.TLO.MoveTo.Moving
  if hasMoveTo then
    stop_stick()
    mq.cmdf('/moveto id %d uw mdist %d', id, distance)
    _lastNavAt = now
    _lastNavId = id
    return true
  end

  return false
end

-- ============================================================================
-- Stick Logic
-- ============================================================================

local function build_stick_command(id, spawn)
  local cmd = (config.stick_cmd or ''):gsub('%%%%', '%%'):gsub('^%s+', ''):gsub('%s+$', '')

  if cmd ~= '' and cmd:lower() ~= 'off' then
    if cmd:sub(1,6):lower() == '/stick' then
      cmd = cmd:sub(7):gsub('^%s+', '')
    end

    if cmd:find('%%d') then
      cmd = string.format(cmd, id)
    elseif not cmd:lower():find('id%s') then
      cmd = cmd .. string.format(' id %d', id)
    end
  else
    local dist = get_target_stick_distance(spawn)

    if is_i_am_ma() then
      cmd = string.format('%d id %d moveback', dist, id)
    else
      cmd = string.format('%d id %d behindonce moveback', dist, id)
    end
  end

  if is_underwater() and not cmd:lower():find('uw') then
    cmd = cmd .. ' uw'
  end

  return '/stick ' .. cmd
end

local function do_stick(id, spawn)
  if not config.use_stick then return end

  local now = os.clock()

  local stickActive = false
  local stickTarget = 0
  pcall(function()
    stickActive = mq.TLO.Stick and mq.TLO.Stick.Active and mq.TLO.Stick.Active()
    stickTarget = mq.TLO.Stick and mq.TLO.Stick.StickTarget and mq.TLO.Stick.StickTarget() or 0
  end)

  local sameTarget = stickTarget == id
  if stickActive and sameTarget and (now - _lastStickAt) < 1.0 then
    return
  end

  if not stickActive or not sameTarget or (now - _lastStickAt) > 3.0 then
    if (now - _lastStickAt) > 0.5 then
      stop_nav()
      local cmd = build_stick_command(id, spawn)
      mq.cmd(cmd)
      _lastStickId = id
      _lastStickCmd = cmd
      _lastStickAt = now
    end
  end
end

-- ============================================================================
-- Main Assist Target Resolution
-- ============================================================================

local function get_main_assist_spawn()
  local mode = (config.assist_mode or 'group'):lower()

  if mode == 'group' then
    local ma
    pcall(function() ma = mq.TLO.Group and mq.TLO.Group.MainAssist end)
    return ma
  elseif mode == 'raid1' then
    local ma
    pcall(function() ma = mq.TLO.Raid and mq.TLO.Raid.MainAssist and mq.TLO.Raid.MainAssist(1) end)
    return ma
  elseif mode == 'raid2' then
    local ma
    pcall(function() ma = mq.TLO.Raid and mq.TLO.Raid.MainAssist and mq.TLO.Raid.MainAssist(2) end)
    return ma
  elseif mode == 'raid3' then
    local ma
    pcall(function() ma = mq.TLO.Raid and mq.TLO.Raid.MainAssist and mq.TLO.Raid.MainAssist(3) end)
    return ma
  elseif mode == 'byname' then
    local name = config.assist_name or ''
    if name == '' then return nil end
    local spawn
    pcall(function() spawn = mq.TLO.Spawn and mq.TLO.Spawn('pc =' .. name) end)
    return spawn
  end

  return nil
end

local function get_assist_target()
  local mode = (config.assist_mode or 'group'):lower()

  if mode == 'group' then
    local tar = mq.TLO.Me.GroupAssistTarget
    if tar and is_attackable(tar) then
      local id = tar.ID and tar.ID() or 0
      local dist = tar.Distance3D and tar.Distance3D() or 0
      if id > 0 then return id, dist, tar end
    end
  end

  if mode == 'raid1' then
    local tar
    pcall(function() tar = mq.TLO.Me.RaidAssistTarget and mq.TLO.Me.RaidAssistTarget(1) end)
    if tar and is_attackable(tar) then
      local id = tar.ID and tar.ID() or 0
      local dist = tar.Distance3D and tar.Distance3D() or 0
      if id > 0 then return id, dist, tar end
    end
  elseif mode == 'raid2' then
    local tar
    pcall(function() tar = mq.TLO.Me.RaidAssistTarget and mq.TLO.Me.RaidAssistTarget(2) end)
    if tar and is_attackable(tar) then
      local id = tar.ID and tar.ID() or 0
      local dist = tar.Distance3D and tar.Distance3D() or 0
      if id > 0 then return id, dist, tar end
    end
  elseif mode == 'raid3' then
    local tar
    pcall(function() tar = mq.TLO.Me.RaidAssistTarget and mq.TLO.Me.RaidAssistTarget(3) end)
    if tar and is_attackable(tar) then
      local id = tar.ID and tar.ID() or 0
      local dist = tar.Distance3D and tar.Distance3D() or 0
      if id > 0 then return id, dist, tar end
    end
  end

  -- Fallback: Get MA spawn's current target directly
  local ma = get_main_assist_spawn()
  if ma and ma() and ma.ID and ma.ID() > 0 then
    local maSpawn = mq.TLO.Spawn(string.format('id %d', ma.ID()))
    if maSpawn and maSpawn() and maSpawn.Target then
      local maTar = maSpawn.Target
      if maTar and is_attackable(maTar) then
        local id = maTar.ID and maTar.ID() or 0
        local dist = maTar.Distance3D and maTar.Distance3D() or 0
        if id > 0 then return id, dist, maTar end
      end
    end
  end

  return nil, nil, nil
end

local function main_assist_target()
  return get_assist_target()
end

-- ============================================================================
-- Engagement Logic
-- ============================================================================

local function retarget(id)
  local curId = mq.TLO.Target and mq.TLO.Target.ID and mq.TLO.Target.ID()
  if not curId or curId ~= id then
    mq.cmdf('/squelch /mqtar id %d', id)
    mq.delay(50, function()
      local t = mq.TLO.Target
      return t and t.ID and t.ID() == id
    end)
  end
end

local function engage(id, dist, spawn)
  -- Skip engagement while invisible
  if mq.TLO.Me.Invis() then
    return
  end

  retarget(id)
  local tar = mq.TLO.Target
  if not is_attackable(tar) then return end

  -- Don't wake mezzed mobs unless we're MA
  if not is_i_am_ma() then
    local mezzed = tar.Mezzed and tar.Mezzed() and tar.Mezzed.ID and tar.Mezzed.ID()
    if mezzed or isMobMezzed(tar) then
      return
    end
  end

  local pct = tonumber(tar.PctHPs and tar.PctHPs())
  if not pct or pct > config.assist_at then return end

  dist = dist or tonumber(tar.Distance3D and tar.Distance3D()) or 999
  if dist > config.assist_rng then return end

  local los = tar.LineOfSight and tar.LineOfSight()
  local maxRange = tar.MaxRangeTo and tar.MaxRangeTo() or 50

  if not los or dist > maxRange then
    if nav_to_target(id, math.min(maxRange - 5, 15)) then
      if check_stuck() then
        do_stuck_recovery()
      end
      return
    end
    if is_underwater() then
      -- Fall through to stick logic
    else
      return
    end
  else
    if nav_active() then
      stop_nav()
      _navStartTime = 0
    end
  end

  if mq.TLO.Me.Sitting() then
    mq.cmd('/stand')
  end

  do_stick(id, spawn or tar)

  local stickActive = false
  pcall(function() stickActive = mq.TLO.Stick and mq.TLO.Stick.Active and mq.TLO.Stick.Active() end)
  if stickActive and check_stuck() then
    do_stuck_recovery()
  end

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

-- ============================================================================
-- Config & Lifecycle
-- ============================================================================

local function apply_config(opts)
  if type(opts) ~= 'table' then return end
  if opts.enabled ~= nil then config.enabled = not not opts.enabled end
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
      if m == mode then valid = true; break end
    end
    if valid then config.assist_mode = mode end
  end
  if opts.assist_name ~= nil then
    config.assist_name = tostring(opts.assist_name):gsub('^%s+', ''):gsub('%s+$', '')
  end
end

local function stop()
  clear_engage()
  stop_nav()
end

local function tick()
  if not config.enabled then return end

  cleanMezList()

  local id, dist, spawn = main_assist_target()
  if id and id > 0 then
    engage(id, dist, spawn)
  else
    clear_engage()
  end
end

local function run()
  while true do
    tick()
    mq.delay(config.tick_delay)
  end
end

local function setEnabled(val)
  local wasEnabled = config.enabled
  config.enabled = val and true or false

  if wasEnabled and not config.enabled then
    stop()
  end
end

local function isEnabled()
  return config.enabled
end

-- ============================================================================
-- Module Export
-- ============================================================================

return {
  run = run,
  tick = tick,
  config = config,
  stop = stop,
  apply_config = apply_config,
  setEnabled = setEnabled,
  isEnabled = isEnabled,
  -- Expose helpers for external use
  is_i_am_ma = is_i_am_ma,
  is_underwater = is_underwater,
  nav_to_target = nav_to_target,
  isMobMezzed = isMobMezzed,
  -- Assist mode helpers
  ASSIST_MODES = ASSIST_MODES,
  get_main_assist_spawn = get_main_assist_spawn,
  get_assist_target = get_assist_target,
}
