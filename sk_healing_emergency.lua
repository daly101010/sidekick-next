-- F:/lua/sidekick-next/sk_healing_emergency.lua
-- Emergency Healing Intelligence module for SideKick multi-script system
-- Priority 0: Emergency heals (preempts all lower-priority casts)

local mq = require('mq')
local lib = require('sidekick-next.sk_lib')
local ModuleBase = require('sidekick-next.sk_module_base')
local Core = require('sidekick-next.utils.core')
local Healing = require('sidekick-next.healing')

-- Create module instance
local module = ModuleBase.create('healing_emergency', lib.Priority.EMERGENCY)

local _coreLoaded = false
local _pendingAction = nil
local _pendingReason = nil

local function ensureCoreLoaded()
    if not _coreLoaded then
        Core.load()
        _coreLoaded = true
    end
end

local function isClr()
    local me = mq.TLO.Me
    if not (me and me()) then return false end
    local cls = me.Class and me.Class.ShortName and me.Class.ShortName() or ''
    return tostring(cls):upper() == 'CLR'
end

local function syncSettings()
    ensureCoreLoaded()
    local settings = Core.Settings or {}
    local doHeals = settings.DoHeals == true
    if Healing.Config and Healing.Config.enabled ~= doHeals then
        Healing.Config.enabled = doHeals
    end
    return settings
end

local function ensureHealingInitialized(settings)
    if not settings or settings.DoHeals ~= true then return false end
    if not isClr() then return false end
    if not Healing.isInitialized() then
        Healing.init()
    end
    return Healing.isInitialized()
end

local function isSpellReady(spellName)
    if not spellName or spellName == '' then return false end
    local me = mq.TLO.Me
    if not (me and me()) then return false end
    return lib.safeTLO(function() return me.SpellReady(spellName)() end, false) == true
end

local function targetId(targetId)
    if targetId <= 0 then return false end
    mq.cmdf('/target id %d', targetId)
    mq.delay(50)
    local currentTarget = lib.safeNum(function() return mq.TLO.Target.ID() end, 0)
    return currentTarget == targetId
end

-------------------------------------------------------------------------------
-- Module Callbacks
-------------------------------------------------------------------------------

module.onTick = function(self)
    local settings = syncSettings()
    if not settings then
        _pendingAction = nil
        self:sendNeed(false)
        return
    end

    if settings.UseSpells == false or settings.DoHeals ~= true then
        _pendingAction = nil
        self:sendNeed(false)
        return
    end

    if not ensureHealingInitialized(settings) then
        _pendingAction = nil
        self:sendNeed(false)
        return
    end

    Healing.tickSensors()

    if self:ownsCast() then
        _pendingAction = nil
        local ttlMs = 1000
        local ownerAction = self.state and self.state.castOwner and self.state.castOwner.action
        if ownerAction then
            local castInfo = Healing.prepareHealCast(ownerAction)
            if castInfo and castInfo.castTimeMs then
                ttlMs = castInfo.castTimeMs + 1500
            end
        end
        self:sendNeed(true, ttlMs)
        return
    end

    local action, reason = Healing.buildHealAction({
        onlyEmergency = true,
        ignoreSpellEngine = true,
        skipIfCasting = false,
    })

    _pendingAction = action
    _pendingReason = reason

    local needs = action ~= nil
    local needTtlMs = nil
    if needs then
        local castInfo = Healing.prepareHealCast(action)
        if castInfo and castInfo.castTimeMs then
            needTtlMs = castInfo.castTimeMs + 1500
        else
            needTtlMs = 1000
        end
    end
    self:sendNeed(needs, needTtlMs)

    if needs and self.state and self.state.castBusy and not self:ownsCast() then
        local owner = self.state.castOwner
        local ownerPriority = owner and owner.priority or lib.Priority.IDLE
        if ownerPriority > lib.Priority.EMERGENCY then
            self:requestInterrupt('emergency_heal')
        end
    end
end

module.shouldAct = function(self)
    if not self:hasValidState() then return false end
    return _pendingAction ~= nil
end

module.getAction = function(self)
    local action = _pendingAction
    if not action then return nil end

    local spellName = action.spellName
    local targetIdVal = tonumber(action.targetId) or 0

    if not spellName or targetIdVal <= 0 then
        return nil
    end

    return {
        kind = lib.ActionKind.CAST_SPELL,
        name = spellName,
        spellName = spellName,
        targetId = targetIdVal,
        targetName = action.targetName,
        tier = action.tier or 'emergency',
        isHoT = action.isHoT == true,
        expected = action.expected,
        details = action.details,
        groupHotTargets = action.groupHotTargets,
        idempotencyKey = string.format('heal_emergency:%s:%d', action.tier or 'emergency', targetIdVal),
        reason = action.reason or _pendingReason or 'emergency_heal',
    }
end

module.executeAction = function(self)
    if not self:ownsAction() then
        return false, 'no_ownership'
    end

    local action = self.state and self.state.castOwner and self.state.castOwner.action
    if not action then
        return false, 'no_action'
    end

    local settings = syncSettings()
    if not settings or settings.UseSpells == false or settings.DoHeals ~= true then
        return true, 'disabled'
    end

    if not ensureHealingInitialized(settings) then
        return true, 'not_ready'
    end

    local spellName = action.spellName or action.name
    local targetIdVal = tonumber(action.targetId) or 0
    if not spellName or targetIdVal <= 0 then
        return true, 'invalid_action'
    end

    if not isSpellReady(spellName) then
        lib.log('debug', self.name, 'Spell not ready: %s', spellName)
        return true, 'spell_not_ready'
    end

    local castInfo = Healing.prepareHealCast(action)
    if not castInfo then
        return true, 'cast_info_failed'
    end

    Healing.setCastInfo(castInfo)

    if not targetId(targetIdVal) then
        Healing.clearCastInfo()
        lib.log('warn', self.name, 'Target mismatch for %s (%d)', spellName, targetIdVal)
        return true, 'target_failed'
    end

    lib.log('info', self.name, 'Casting %s on %d', spellName, targetIdVal)
    mq.cmdf('/cast "%s"', spellName)
    mq.delay(100)

    if not lib.isCasting() then
        Healing.clearCastInfo()
        lib.log('warn', self.name, 'Cast did not start: %s', spellName)
        return true, 'cast_failed'
    end

    Healing.registerHealCast(castInfo)

    local startTime = lib.getTimeMs()
    local maxWait = (castInfo.castTimeMs or 2000) + 1500

    while lib.isCasting() do
        mq.delay(50)

        local ducked = Healing.checkDucking({
            onDuck = function(_, reason)
                self:requestInterrupt(string.format('duck_%s', tostring(reason or 'heal')))
            end,
        })
        if ducked then
            return true, 'ducked'
        end

        if not self:ownsAction() then
            lib.log('warn', self.name, 'Lost ownership during cast')
            return true, 'ownership_lost'
        end

        if (lib.getTimeMs() - startTime) > maxWait then
            lib.log('warn', self.name, 'Cast timeout')
            break
        end
    end

    lib.log('info', self.name, 'Cast completed: %s', spellName)
    return true, 'completed'
end

-------------------------------------------------------------------------------
-- Command Binding
-------------------------------------------------------------------------------

mq.bind('/sk_healing_emergency', function(cmd)
    if cmd == 'stop' then
        module:stop()
        lib.log('info', module.name, 'Stop requested')
    elseif cmd == 'status' then
        local settings = Core.Settings or {}
        lib.log('info', module.name, 'running=%s, hasState=%s, isMyPriority=%s, ownsAction=%s, useSpells=%s, doHeals=%s',
            tostring(module.running),
            tostring(module:hasValidState()),
            tostring(module:isMyPriority()),
            tostring(module:ownsAction()),
            tostring(settings.UseSpells ~= false),
            tostring(settings.DoHeals == true))
    end
end)

-------------------------------------------------------------------------------
-- Run
-------------------------------------------------------------------------------

module:run(50)

return module
