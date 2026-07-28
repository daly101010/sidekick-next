-- Smart automatic-stand policy for Monk and Necromancer feign death.
--
-- Feign serves two different purposes:
--   * aggro clear: a healthy character may stand again promptly;
--   * survival: remain down until HP and group support make standing safe.
--
-- This module is the sole automatic stand owner while a managed class is
-- feigning. Worker modules must treat managed feign as a protected state and
-- let the SideKick UI host call tick().

local mq = require('mq')
local SkLib = require('sidekick-next.sk_lib')
local log = require('sidekick-next.utils.logger').new('feign')

local M = {}

local MANAGED_CLASSES = { MNK = true, NEC = true }
local HEALER_CLASSES = { CLR = true, DRU = true, SHM = true }
local TANK_CLASSES = { WAR = true, PAL = true, SHD = true }
local DEFAULT_RECOVERY_HP = 35
local STAND_RETRY_MS = 750

local State = {
    active = false,
    class = '',
    entryHp = 100,
    survival = false,
    lastDecision = '',
    lastStandAt = 0,
}

local function safe(fn, fallback)
    local ok, value = pcall(fn)
    if not ok or value == nil then return fallback end
    return value
end

local function safeNum(fn, fallback)
    return tonumber(safe(fn, fallback)) or fallback
end

local function sharedSettings(settings)
    if type(settings) == 'table' and settings.EmergencyHpThreshold ~= nil then
        return settings
    end
    local loaded = SkLib.getSettings and SkLib.getSettings() or nil
    return type(loaded) == 'table' and loaded or (settings or {})
end

local function recoveryThreshold(settings)
    settings = sharedSettings(settings)
    local threshold = tonumber(settings.EmergencyHpThreshold)
        or DEFAULT_RECOVERY_HP
    return math.max(1, math.min(100, threshold))
end

local function classShort()
    return tostring(safe(function()
        return mq.TLO.Me.Class.ShortName()
    end, '') or ''):upper()
end

local function isFeigning()
    return safe(function()
        return mq.TLO.Me.Feigning()
    end, false) == true
end

local function resetState()
    State.active = false
    State.class = ''
    State.entryHp = 100
    State.survival = false
    State.lastDecision = ''
end

--- Observe the current feign edge and retain whether it began as survival FD.
---@param settings table|nil
---@return boolean managedFeign
function M.observe(settings)
    local class = classShort()
    local managed = MANAGED_CLASSES[class] == true and isFeigning()
    if not managed then
        if State.active then resetState() end
        return false
    end

    local hp = safeNum(function() return mq.TLO.Me.PctHPs() end, 100)
    local threshold = recoveryThreshold(settings)
    if not State.active or State.class ~= class then
        State.active = true
        State.class = class
        State.entryHp = hp
        State.survival = hp < threshold
    elseif hp < threshold then
        -- A healthy aggro-clear FD can become a survival FD if damage lands
        -- while the character is down.
        State.survival = true
    end
    return true
end

function M.isManagedFeign(settings)
    return M.observe(settings)
end

local function memberSnapshot(member, mainTankId)
    if not (member and member()) then return nil end
    local hp = safeNum(function() return member.PctHPs() end, -1)
    local dead = safe(function() return member.Dead() end, false) == true
        or safe(function() return member.Hovering() end, false) == true
        or hp == 0
    local alive = hp > 0 and not dead
    local class = tostring(safe(function()
        return member.Class.ShortName()
    end, '') or ''):upper()
    local id = safeNum(function() return member.ID() end, 0)
    local support = HEALER_CLASSES[class] == true
        or TANK_CLASSES[class] == true
        or (mainTankId > 0 and id == mainTankId)
    return {
        alive = alive,
        support = support,
    }
end

local function groupSafety()
    local count = safeNum(function() return mq.TLO.Group.Members() end, 0)
    if count <= 0 then
        return {
            memberCount = 0,
            knownCount = 0,
            livingCount = 0,
            supportCount = 0,
            livingSupportCount = 0,
            allGroupDead = false,
        }
    end

    local mainTankId = safeNum(function()
        return mq.TLO.Group.MainTank.ID()
    end, 0)
    local result = {
        memberCount = count,
        knownCount = 0,
        livingCount = 0,
        supportCount = 0,
        livingSupportCount = 0,
        allGroupDead = false,
    }
    for i = 1, count do
        local snapshot = memberSnapshot(mq.TLO.Group.Member(i), mainTankId)
        if snapshot then
            result.knownCount = result.knownCount + 1
            if snapshot.alive then result.livingCount = result.livingCount + 1 end
            if snapshot.support then
                result.supportCount = result.supportCount + 1
                if snapshot.alive then
                    result.livingSupportCount = result.livingSupportCount + 1
                end
            end
        end
    end
    -- Unknown/out-of-zone members are not assumed dead. A wipe hold requires
    -- positive evidence that every other listed group member is dead.
    result.allGroupDead = result.knownCount == count and result.livingCount == 0
    return result
end

--- Decide whether the managed feigner is safe to stand.
---@param settings table|nil
---@return boolean canStand
---@return string reason
---@return table snapshot
function M.evaluate(settings)
    if not M.observe(settings) then
        return true, 'not_managed_feign', {}
    end

    local hp = safeNum(function() return mq.TLO.Me.PctHPs() end, 100)
    local threshold = recoveryThreshold(settings)
    local group = groupSafety()
    local combat = SkLib.inCombat and SkLib.inCombat() == true

    local snapshot = {
        class = State.class,
        hp = hp,
        recoveryHp = threshold,
        survival = State.survival == true,
        combat = combat,
        memberCount = group.memberCount,
        livingCount = group.livingCount,
        supportCount = group.supportCount,
        livingSupportCount = group.livingSupportCount,
        allGroupDead = group.allGroupDead,
    }

    if group.allGroupDead then
        return false, 'group_wipe_hold', snapshot
    end

    if State.survival then
        if hp < threshold then
            return false, 'survival_hp_low', snapshot
        end
        if combat and group.supportCount > 0 and group.livingSupportCount == 0 then
            return false, 'survival_no_living_support', snapshot
        end
        return true, 'survival_recovered', snapshot
    end

    return true, 'aggro_clear_safe', snapshot
end

local function logDecision(canStand, reason, snapshot)
    local key = string.format('%s:%s:%s:%s:%s',
        tostring(canStand), tostring(reason), tostring(snapshot.combat == true),
        tostring(snapshot.livingCount or '?'),
        tostring(snapshot.livingSupportCount or '?'))
    if key == State.lastDecision then return end
    State.lastDecision = key

    local message = 'auto-stand decision allow=%s reason=%s hp=%s threshold=%s '
        .. 'combat=%s living=%s/%s support=%s/%s'
    local logger = canStand and log.info or log.warn
    logger(message, tostring(canStand), tostring(reason),
        tostring(snapshot.hp or '?'), tostring(snapshot.recoveryHp or '?'),
        tostring(snapshot.combat == true),
        tostring(snapshot.livingCount or '?'), tostring(snapshot.memberCount or '?'),
        tostring(snapshot.livingSupportCount or '?'),
        tostring(snapshot.supportCount or '?'))
end

--- Read-only controller tick retained for diagnostic callers. Automatic
--- standing is performed only by the leased sk_feign worker.
---@param settings table|nil
---@return boolean managedFeign
---@return string reason
function M.tick(settings)
    local canStand, reason, snapshot = M.evaluate(settings)
    if reason == 'not_managed_feign' then return false, reason end

    logDecision(canStand, reason, snapshot)
    return true, reason, canStand
end

--- Issue the automatic stand after the caller has obtained the coordinator
--- lease. The safety decision is rechecked immediately before mutation.
---@param settings table|nil
---@return boolean issued
---@return string reason
function M.performStand(settings)
    local canStand, reason, snapshot = M.evaluate(settings)
    if reason == 'not_managed_feign' then return false, reason end
    logDecision(canStand, reason, snapshot)
    if not canStand then return false, reason end

    local now = mq.gettime()
    if (now - State.lastStandAt) < STAND_RETRY_MS then
        return false, 'stand_retry_throttled'
    end
    State.lastStandAt = now
    mq.cmd('/squelch /stand')
    return true, reason
end

--- Guard for legacy/direct stand call sites. While MNK/NEC is feigning,
--- automatic stand belongs exclusively to tick().
function M.canExternalAutoStand(settings)
    if not M.observe(settings) then return true, 'not_managed_feign' end
    return false, 'managed_by_feign_controller'
end

function M.getState()
    return {
        active = State.active == true,
        class = State.class,
        entryHp = State.entryHp,
        survival = State.survival == true,
        lastDecision = State.lastDecision,
    }
end

return M
