-- F:/lua/SideKick/sk_dps.lua
-- DPS module for SideKick multi-script system
-- Priority 4: Nukes, stuns, meditation when idle

local mq = require('mq')
local lib = require('sidekick.sk_lib')
local ModuleBase = require('sidekick.sk_module_base')
local Spells = require('sk_spells_clr')

-- Create module instance
local module = ModuleBase.create('dps', lib.Priority.DPS)

-------------------------------------------------------------------------------
-- DPS Configuration
-------------------------------------------------------------------------------

local Config = {
    -- Mana threshold to nuke
    minManaPct = 40,

    -- Target HP threshold (don't nuke nearly dead targets)
    minTargetHpPct = 20,

    -- Spell lines (from sk_spells_clr.lua)
    spellLines = {
        nuke = Spells.Damage.Contravention,
        stun = Spells.Stuns.Sound,
        stunSingle = Spells.Stuns.Silent,
    },
}

-------------------------------------------------------------------------------
-- Spell Resolution
-------------------------------------------------------------------------------

local function isSpellMemorized(spellName)
    if not spellName or spellName == '' then return false end
    local me = mq.TLO.Me
    if not (me and me()) then return false end
    local gems = lib.safeNum(function() return me.NumGems() end, 13)
    for i = 1, gems do
        local gem = me.Gem(i)
        if gem and gem() and (gem.Name() or '') == spellName then
            return true
        end
    end
    return false
end

local function resolveSpell(lineKey)
    local line = Config.spellLines[lineKey]
    if not line then return nil end
    for _, name in ipairs(line) do
        if isSpellMemorized(name) then
            return name
        end
    end
    return nil
end

local function isSpellReady(spellName)
    if not spellName then return false end
    local me = mq.TLO.Me
    if not (me and me()) then return false end
    return lib.safeTLO(function() return me.SpellReady(spellName)() end, false) == true
end

local function getSpellCastTime(spellName)
    if not spellName then return 0 end
    local spell = mq.TLO.Spell(spellName)
    if not (spell and spell()) then return 0 end
    return lib.safeNum(function() return spell.MyCastTime() end, 0) / 1000
end

-------------------------------------------------------------------------------
-- Target Selection
-------------------------------------------------------------------------------

local function getMATarget()
    local maId = lib.getMainAssistId()
    if maId <= 0 then return nil end

    local ma = mq.TLO.Spawn(maId)
    if not (ma and ma()) then return nil end

    local targetId = lib.safeNum(function() return ma.TargetOfTarget.ID() end, 0)
    if targetId <= 0 then
        -- Try MA's target directly
        targetId = lib.safeNum(function() return ma.Target.ID() end, 0)
    end

    if targetId <= 0 then return nil end

    local target = mq.TLO.Spawn(targetId)
    if not (target and target()) then return nil end

    local hp = lib.safeNum(function() return target.PctHPs() end, 100)
    local type = lib.safeTLO(function() return target.Type() end, '') or ''

    -- Only attack NPCs
    if type:lower() ~= 'npc' then return nil end

    return { id = targetId, hp = hp }
end

-------------------------------------------------------------------------------
-- Module Callbacks
-------------------------------------------------------------------------------

module.shouldAct = function(self)
    if not self:hasValidState() then return false end

    -- Only DPS in combat
    if not lib.inCombat() then return false end

    -- Check mana
    local mana = lib.safeNum(function() return mq.TLO.Me.PctMana() end, 0)
    if mana < Config.minManaPct then return false end

    -- Check for valid target
    local target = getMATarget()
    if not target then return false end
    if target.hp < Config.minTargetHpPct then return false end

    -- Check if we have a spell ready
    local nuke = resolveSpell('nuke')
    local stun = resolveSpell('stun')
    if not nuke and not stun then return false end
    if nuke and not isSpellReady(nuke) then nuke = nil end
    if stun and not isSpellReady(stun) then stun = nil end

    return nuke or stun
end

module.getAction = function(self)
    local target = getMATarget()
    if not target then return nil end

    -- Prefer nuke, fall back to stun
    local spellName = resolveSpell('nuke')
    local kind = 'nuke'
    if not spellName or not isSpellReady(spellName) then
        spellName = resolveSpell('stun')
        kind = 'stun'
    end

    if not spellName or not isSpellReady(spellName) then
        return nil
    end

    return {
        kind = lib.ActionKind.CAST_SPELL,
        name = spellName,
        targetId = target.id,
        idempotencyKey = string.format('dps:%s:%d', kind, target.id),
        reason = string.format('%s on %d', kind, target.id),
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

    local spellName = action.name
    local targetId = action.targetId

    -- Verify spell is still ready
    if not isSpellReady(spellName) then
        lib.log('debug', self.name, 'Spell no longer ready: %s', spellName)
        return true, 'spell_not_ready'
    end

    -- Target
    lib.log('info', self.name, 'Targeting %d for %s', targetId, spellName)
    mq.cmdf('/target id %d', targetId)
    mq.delay(50)

    -- Verify target
    local currentTarget = lib.safeNum(function() return mq.TLO.Target.ID() end, 0)
    if currentTarget ~= targetId then
        lib.log('warn', self.name, 'Target mismatch: wanted %d, got %d', targetId, currentTarget)
        return true, 'target_failed'
    end

    -- Cast
    lib.log('info', self.name, 'Casting %s on %d', spellName, targetId)
    mq.cmdf('/cast "%s"', spellName)
    mq.delay(100)

    if lib.isCasting() then
        local castTime = getSpellCastTime(spellName)
        lib.log('info', self.name, 'Cast started: %s (%.1fs)', spellName, castTime)

        local startTime = lib.getTimeMs()
        local maxWait = (castTime + 1) * 1000

        while lib.isCasting() do
            mq.delay(50)

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
    else
        lib.log('warn', self.name, 'Cast did not start: %s', spellName)
        return true, 'cast_failed'
    end
end

-------------------------------------------------------------------------------
-- Command Binding
-------------------------------------------------------------------------------

mq.bind('/sk_dps', function(cmd)
    if cmd == 'stop' then
        module:stop()
        lib.log('info', module.name, 'Stop requested')
    elseif cmd == 'status' then
        local target = getMATarget()
        lib.log('info', module.name, 'running=%s, hasState=%s, isMyPriority=%s, target=%s',
            tostring(module.running),
            tostring(module:hasValidState()),
            tostring(module:isMyPriority()),
            target and tostring(target.id) or 'none')
    end
end)

-------------------------------------------------------------------------------
-- Run
-------------------------------------------------------------------------------

module:run(50)

return module
