-- F:/lua/SideKick/sk_healing.lua
-- Healing module for SideKick multi-script system
-- Priority 1: Fast heals, group heals, HoTs

local mq = require('mq')
local lib = require('sidekick.sk_lib')
local ModuleBase = require('sidekick.sk_module_base')
local Spells = require('sidekick.sk_spells_clr')

-------------------------------------------------------------------------------
-- Lazy-load Dependencies
-------------------------------------------------------------------------------

local _SpellsetManager = nil
local function getSpellsetManager()
    if not _SpellsetManager then
        local ok, sm = pcall(require, 'utils.spellset_manager')
        if ok then _SpellsetManager = sm end
    end
    return _SpellsetManager
end

local _ConditionBuilder = nil
local function getConditionBuilder()
    if not _ConditionBuilder then
        local ok, cb = pcall(require, 'ui.condition_builder')
        if ok then _ConditionBuilder = cb end
    end
    return _ConditionBuilder
end

-- Create module instance
local module = ModuleBase.create('healing', lib.Priority.HEALING)

-------------------------------------------------------------------------------
-- Healing Configuration
-------------------------------------------------------------------------------

local Config = {
    -- HP thresholds
    mainHealPct = 80,
    bigHealPct = 50,
    groupHealPct = 75,
    groupInjuredCount = 2,

    -- Spell lines (from sk_spells_clr.lua)
    spellLines = {
        main = Spells.Heals.Remedy,
        big = Spells.Heals.Renewal,
        intervention = Spells.Heals.Intervention,
        group = Spells.GroupHeals.Word,
    },
}

-------------------------------------------------------------------------------
-- Spell Resolution
-------------------------------------------------------------------------------

--- Build context for condition evaluation
-- @param targetId number The heal target ID (optional)
-- @return table Context data for condition evaluation
local function buildHealContext(targetId)
    local target = targetId and mq.TLO.Spawn(targetId)
    local me = mq.TLO.Me

    return {
        targetId = targetId or 0,
        targetHp = target and target() and lib.safeNum(function() return target.PctHPs() end, 100) or 100,
        targetClass = target and target() and lib.safeTLO(function() return target.Class.ShortName() end, '') or '',
        targetType = target and target() and lib.safeTLO(function() return target.Type() end, '') or '',
        myHp = me and me() and lib.safeNum(function() return me.PctHPs() end, 100) or 100,
        myMana = me and me() and lib.safeNum(function() return me.PctMana() end, 100) or 100,
        inCombat = me and me() and lib.safeTLO(function() return me.Combat() end, false) or false,
        groupCount = lib.safeNum(function() return mq.TLO.Group.Members() end, 0),
    }
end

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

--- Map lineKey to spell set category for findBestSpell queries
local lineKeyToCategory = {
    main = 'Heals',
    big = 'Heals',
    intervention = 'Heals',
    group = 'GroupHeals',
}

--- Resolve the best spell for a heal line
-- First tries active spell set, then falls back to hardcoded config
-- @param lineKey string The config line key (main, big, group, etc.)
-- @param targetId number|nil Optional target ID for context building
-- @return string|nil The resolved spell name or nil
local function resolveSpell(lineKey, targetId)
    local SpellsetManager = getSpellsetManager()

    -- Try spell set first
    if SpellsetManager then
        local set = SpellsetManager.getActiveSet()
        if set then
            -- Build context for condition evaluation
            local ctx = buildHealContext(targetId)

            -- Map lineKey to category
            local category = lineKeyToCategory[lineKey]
            if category then
                local spellName = SpellsetManager.findBestSpell(category, ctx)
                if spellName and isSpellMemorized(spellName) then
                    return spellName
                end
            end
        end
    end

    -- Fall back to hardcoded config
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
-- Heal Target Selection
-------------------------------------------------------------------------------

local function getGroupMemberHP(index)
    local member = mq.TLO.Group.Member(index)
    if not (member and member()) then return nil end
    local id = lib.safeNum(function() return member.ID() end, 0)
    if id <= 0 then return nil end
    local hp = lib.safeNum(function() return member.PctHPs() end, 100)
    local name = lib.safeTLO(function() return member.CleanName() end, '') or ''
    return { id = id, hp = hp, name = name, index = index }
end

local function findHealTarget()
    local candidates = {}

    -- Check self (index 0)
    local me = mq.TLO.Me
    if me and me() then
        local myHp = lib.safeNum(function() return me.PctHPs() end, 100)
        local myId = lib.safeNum(function() return me.ID() end, 0)
        if myHp < Config.mainHealPct and myId > 0 then
            table.insert(candidates, { id = myId, hp = myHp, name = lib.getMyName(), index = 0 })
        end
    end

    -- Check group members
    local groupCount = lib.getGroupCount()
    for i = 1, groupCount do
        local member = getGroupMemberHP(i)
        if member and member.hp < Config.mainHealPct then
            table.insert(candidates, member)
        end
    end

    -- Sort by HP (lowest first)
    table.sort(candidates, function(a, b) return a.hp < b.hp end)

    return candidates[1]
end

local function countInjured(threshold)
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
        local member = getGroupMemberHP(i)
        if member and member.hp < threshold then
            count = count + 1
        end
    end

    return count
end

-------------------------------------------------------------------------------
-- Module Callbacks
-------------------------------------------------------------------------------

-- Called each tick to check if we should act
module.shouldAct = function(self)
    if not self:hasValidState() then return false end

    -- Check if anyone needs healing
    local target = findHealTarget()
    if target then return true end

    -- Check for group heal need
    local injured = countInjured(Config.groupHealPct)
    if injured >= Config.groupInjuredCount then return true end

    return false
end

-- Returns action details for claim request
module.getAction = function(self)
    -- Determine heal type needed
    local target = findHealTarget()
    local injured = countInjured(Config.groupHealPct)
    local needGroup = injured >= Config.groupInjuredCount

    local spellName = nil
    local targetId = 0
    local tier = 'main'

    if needGroup then
        targetId = lib.safeNum(function() return mq.TLO.Me.ID() end, 0)
        spellName = resolveSpell('group', targetId)
        tier = 'group'
    elseif target then
        targetId = target.id
        if target.hp < Config.bigHealPct then
            spellName = resolveSpell('big', targetId) or resolveSpell('main', targetId)
            tier = 'big'
        else
            spellName = resolveSpell('main', targetId)
            tier = 'main'
        end
    end

    if not spellName or targetId <= 0 then
        return nil
    end

    if not isSpellReady(spellName) then
        lib.log('debug', self.name, 'Spell not ready: %s', spellName)
        return nil
    end

    return {
        kind = lib.ActionKind.CAST_SPELL,
        name = spellName,
        targetId = targetId,
        idempotencyKey = string.format('heal:%s:%s', tier, targetId),
        reason = string.format('%s heal on %d', tier, targetId),
        tier = tier,
    }
end

-- Executes the action after claim is granted
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

    -- Target the heal target
    lib.log('info', self.name, 'Targeting %d for %s', targetId, spellName)
    mq.cmdf('/target id %d', targetId)
    mq.delay(50) -- Brief delay for target to update

    -- Verify target
    local currentTarget = lib.safeNum(function() return mq.TLO.Target.ID() end, 0)
    if currentTarget ~= targetId then
        lib.log('warn', self.name, 'Target mismatch: wanted %d, got %d', targetId, currentTarget)
        return true, 'target_failed'
    end

    -- Cast the spell
    lib.log('info', self.name, 'Casting %s on %d', spellName, targetId)
    mq.cmdf('/cast "%s"', spellName)

    -- Wait for cast to start (brief)
    mq.delay(100)

    -- Check if cast started
    if lib.isCasting() then
        local castTime = getSpellCastTime(spellName)
        lib.log('info', self.name, 'Cast started: %s (%.1fs)', spellName, castTime)

        -- Wait for cast to complete (with periodic ownership checks)
        local startTime = lib.getTimeMs()
        local maxWait = (castTime + 1) * 1000

        while lib.isCasting() do
            mq.delay(50)

            -- Check if we still own the action
            if not self:ownsAction() then
                lib.log('warn', self.name, 'Lost ownership during cast')
                return true, 'ownership_lost'
            end

            -- Timeout safety
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

mq.bind('/sk_healing', function(cmd)
    if cmd == 'stop' then
        module:stop()
        lib.log('info', module.name, 'Stop requested')
    elseif cmd == 'status' then
        lib.log('info', module.name, 'running=%s, hasState=%s, isMyPriority=%s, ownsAction=%s',
            tostring(module.running),
            tostring(module:hasValidState()),
            tostring(module:isMyPriority()),
            tostring(module:ownsAction()))
    end
end)

-------------------------------------------------------------------------------
-- Run
-------------------------------------------------------------------------------

module:run(50)

return module
