-- F:/lua/SideKick/sk_emergency.lua
-- Emergency module for SideKick multi-script system
-- Priority 0: Divine Arbitration, Celestial Regen, Sanctuary

local mq = require('mq')
local lib = require('sk_lib')
local ModuleBase = require('sk_module_base')

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
    if not self:ownsAction() then
        return false, 'no_ownership'
    end

    local action = self.state.castOwner and self.state.castOwner.action
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

-- Emergency module should also request interrupt when it detects emergency
module.onTick = function(self)
    if not self:hasValidState() then return end

    -- If we detect an emergency and someone else is casting, request interrupt
    local kind, _ = detectEmergency()
    if kind and self.state.castBusy and not self:ownsCast() then
        if self.state.castOwner and self.state.castOwner.priority > lib.Priority.EMERGENCY then
            self:requestInterrupt(string.format('emergency_%s', kind))
        end
    end
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
