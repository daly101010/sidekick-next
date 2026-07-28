-- F:/lua/sidekick-next/sk_emergency.lua
-- Emergency module for SideKick multi-script system
-- Priority 0: Divine Arbitration, Celestial Regen, Sanctuary

local mq = require('mq')
local lib = require('sidekick-next.sk_lib')
local ModuleBase = require('sidekick-next.sk_module_base')

-- Create module instance
local module = ModuleBase.create('emergency', lib.Priority.EMERGENCY)

-------------------------------------------------------------------------------
-- Emergency Configuration
-------------------------------------------------------------------------------

local Config = {
    -- Thresholds
    arbitrationThreshold = 3,  -- Number of group members below 25% to trigger
    arbitrationHpPct = 25,
    celestialRegenHpPct = 35,
    sanctuaryHpPct = 20,

    -- AA names
    divineArbitration = 'Divine Arbitration',
    celestialRegen = 'Celestial Regeneration',
    sanctuary = 'Sanctuary',
}

-------------------------------------------------------------------------------
-- AA Readiness
-------------------------------------------------------------------------------

local function isAAReady(aaName)
    if not aaName then return false end
    local me = mq.TLO.Me
    if not (me and me()) then return false end
    return lib.safeTLO(function() return me.AltAbilityReady(aaName)() end, false) == true
end

-------------------------------------------------------------------------------
-- Emergency Detection
-------------------------------------------------------------------------------

local function countCritical(threshold)
    local count = 0

    -- Check self
    local me = mq.TLO.Me
    if me and me() then
        local myHp = lib.safeNum(function() return me.PctHPs() end, 100)
        if myHp < threshold then count = count + 1 end
    end

    -- Check group
    local groupCount = lib.getGroupCount()
    for i = 1, groupCount do
        local member = mq.TLO.Group.Member(i)
        if member and member() then
            local hp = lib.safeNum(function() return member.PctHPs() end, 100)
            if hp < threshold then
                count = count + 1
            end
        end
    end

    return count
end

local function getMyHpPct()
    return lib.safeNum(function() return mq.TLO.Me.PctHPs() end, 100)
end

local function detectEmergency()
    local myHp = getMyHpPct()

    -- Sanctuary: self HP critical
    if myHp < Config.sanctuaryHpPct and isAAReady(Config.sanctuary) then
        return 'sanctuary', Config.sanctuary
    end

    -- Celestial Regen: self HP low
    if myHp < Config.celestialRegenHpPct and isAAReady(Config.celestialRegen) then
        return 'celestial', Config.celestialRegen
    end

    -- Divine Arbitration: multiple critical
    local criticalCount = countCritical(Config.arbitrationHpPct)
    if criticalCount >= Config.arbitrationThreshold and isAAReady(Config.divineArbitration) then
        return 'arbitration', Config.divineArbitration
    end

    return nil, nil
end

-------------------------------------------------------------------------------
-- Module Callbacks
-------------------------------------------------------------------------------

module.shouldAct = function(self)
    local kind, aa = detectEmergency()
    return kind ~= nil
end

module.getAction = function(self)
    local kind, aaName = detectEmergency()
    if not kind or not aaName then return nil end

    local myId = lib.safeNum(function() return mq.TLO.Me.ID() end, 0)

    return {
        kind = lib.ActionKind.USE_AA,
        name = aaName,
        targetId = myId,
        idempotencyKey = string.format('emergency:%s', kind),
        reason = string.format('emergency %s', kind),
        emergencyKind = kind,
    }
end

module.executeAction = function(self)
    if not self:ownsLease() then
        return false, 'no_ownership'
    end

    local action = self:getLeaseAction()
    if not action then
        return false, 'no_action'
    end

    local aaName = action.name

    -- Verify AA is still ready
    if not isAAReady(aaName) then
        lib.log('debug', self.name, 'AA no longer ready: %s', aaName)
        return true, 'aa_not_ready'
    end

    -- Fire the AA
    lib.log('info', self.name, 'EMERGENCY: Using %s', aaName)
    mq.cmdf('/alt activate "%s"', aaName)

    -- Brief delay for activation
    mq.delay(100)

    -- Check if we're casting (some AAs have cast time)
    if lib.isCasting() then
        local startTime = lib.getTimeMs()
        while lib.isCasting() do
            mq.delay(50)
            if (lib.getTimeMs() - startTime) > 5000 then
                lib.log('warn', self.name, 'AA cast timeout')
                break
            end
        end
    end

    lib.log('info', self.name, 'Emergency action completed: %s', aaName)
    return true, 'completed'
end

-- The unified executor fires and monitors the AA without blocking this
-- Quarantine the retired direct callback. All execution now goes through the
-- shared lease-bound executor below.
module.executeAction = nil
module:enableUnifiedExecutor()

module.onTick = function(self)
    if not self:hasValidState() then return end

    local kind, _ = detectEmergency()
    self:setIntent(kind ~= nil, kind and 500 or nil,
        kind and ('emergency_' .. kind) or 'no_emergency')
end

-------------------------------------------------------------------------------
-- Command Binding
-------------------------------------------------------------------------------

mq.bind('/sk_emergency', function(cmd)
    if cmd == 'stop' then
        module:stop()
        lib.log('info', module.name, 'Stop requested')
    elseif cmd == 'status' then
        local kind, aa = detectEmergency()
        lib.log('info', module.name, 'running=%s, hasState=%s, emergency=%s, aa=%s',
            tostring(module.running),
            tostring(module:hasValidState()),
            tostring(kind or 'none'),
            tostring(aa or 'none'))
    end
end)

-------------------------------------------------------------------------------
-- Run
-------------------------------------------------------------------------------

module:run(50)

return module
