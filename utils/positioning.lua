local mq = require('mq')
local lazy = require('sidekick-next.utils.lazy_require')

local M = {}

M.repositionCooldown = 5000  -- 5 seconds in milliseconds
M.lastReposition = 0
M.originalStickMode = nil
M.inSoftPause = false

-- Lazy-load Core for settings access (avoid hard dependency cycles)
local getCore = lazy('sidekick-next.utils.core')

local function getSetting(key)
    local Core = getCore()
    if Core and Core.Settings then
        return Core.Settings[key]
    end
    return nil
end

local function getStickCommand()
    local v = getSetting('StickCommand')
    if type(v) == 'string' and v ~= '' then
        return v
    end
    return '/stick snaproll behind 10 moveback uw'
end

local function getSoftPauseStick()
    local v = getSetting('SoftPauseStick')
    if type(v) == 'string' and v ~= '' then
        return v
    end
    return '/stick !front'
end

local _lastCooldownSec = nil
local function refreshCooldownFromSettings()
    local sec = tonumber(getSetting('TankRepositionCooldown'))
    if not sec or sec <= 0 then return end
    if _lastCooldownSec == sec then return end
    _lastCooldownSec = sec
    M.repositionCooldown = math.floor(sec * 1000 + 0.5)
end

--- Calculate the centroid of group members (excluding self)
-- @return number|nil, number|nil X and Y coordinates, or nil if no group
function M.calculateGroupCentroid()
    local x, y, count = 0, 0, 0
    local myId = mq.TLO.Me.ID()

    for i = 1, mq.TLO.Group.Members() or 0 do
        local member = mq.TLO.Group.Member(i)
        if member and member() and member.ID() ~= myId then
            x = x + (member.X() or 0)
            y = y + (member.Y() or 0)
            count = count + 1
        end
    end

    if count == 0 then return nil, nil end
    return x / count, y / count
end

--- Check if enough time has passed since last reposition
-- @return boolean True if reposition is allowed
function M.shouldReposition()
    refreshCooldownFromSettings()
    return (mq.gettime() - M.lastReposition) >= M.repositionCooldown
end

--- Mark that a reposition just happened
function M.markRepositioned()
    M.lastReposition = mq.gettime()
end

--- Enter soft-pause mode (loosen stick for tank movement)
-- @param currentStick string Current stick command to restore later
function M.enterSoftPause(currentStick)
    if M.inSoftPause then return end
    M.originalStickMode = currentStick or getStickCommand()
    M.inSoftPause = true
    mq.cmd(getSoftPauseStick())
end

--- Exit soft-pause mode (restore original stick)
function M.exitSoftPause()
    if not M.inSoftPause then return end
    M.inSoftPause = false
    if M.originalStickMode then
        mq.cmd(M.originalStickMode)
    end
end

--- Check if currently in soft-pause mode
-- @return boolean
function M.isInSoftPause()
    return M.inSoftPause
end

--- Check if a mob is a dragon type (dragons, drakes, wyrms, wyverns)
-- @param mobId number Spawn ID to check
-- @return boolean True if mob is a dragon type
function M.isDragonType(mobId)
    local mob = mq.TLO.Spawn(mobId)
    if not mob or not mob() then return false end

    -- Check body type
    local body = tostring(mob.Body() or ''):lower()
    if body:find('dragon') then return true end

    -- Check name patterns
    local name = tostring(mob.CleanName() or ''):lower()
    local patterns = { 'dragon', 'drake', 'wyrm', 'wyvern' }
    for _, pattern in ipairs(patterns) do
        if name:find(pattern) then return true end
    end

    return false
end

--- Calculate optimal position for fighting dragon-type mobs
-- Dragons have dangerous front cones and tail attacks, so position at flank
-- @param mobId number Spawn ID of the dragon
-- @return table|nil { x, y } coordinates or nil if mob not found
function M.getDragonPosition(mobId)
    -- Get mob spawn
    local mob = mq.TLO.Spawn(mobId)
    if not mob or not mob() then return nil end

    -- Get mob position and heading
    local mobX = mob.X()
    local mobY = mob.Y()
    local mobHeading = mob.Heading.Degrees()

    if not mobX or not mobY or not mobHeading then return nil end

    -- Get dragon position angle from settings (default 135 degrees)
    -- 135 degrees = behind and to the side, avoiding front cone and tail
    local angleOffset = getSetting('DragonPositionAngle') or 135
    local angle = (mobHeading + angleOffset) % 360
    local distance = 10 -- feet behind/beside

    -- Convert to radians and calculate position
    local radians = math.rad(angle)
    local targetX = mobX + math.sin(radians) * distance
    local targetY = mobY + math.cos(radians) * distance

    return { x = targetX, y = targetY }
end

--- Check if dragon positioning is enabled and should be used for target
-- @param mobId number Spawn ID to check
-- @return boolean True if dragon positioning should be used
function M.shouldUseDragonPositioning(mobId)
    local enabled = getSetting('DragonPositioning')
    if not enabled then return false end
    return M.isDragonType(mobId)
end

return M
