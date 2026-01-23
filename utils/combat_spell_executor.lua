-- F:/lua/sidekick-next/utils/combat_spell_executor.lua
-- Combat Spell Executor - determines which spell to cast next during combat
-- Handles type-based priority ordering, condition evaluation, and buff targeting

local mq = require('mq')

local M = {}

--------------------------------------------------------------------------------
-- Constants
--------------------------------------------------------------------------------

-- Type-based priority (lower = cast first)
-- Healings are skipped here as healing intelligence handles them
M.TYPE_PRIORITY = {
    debuff = 1,
    buff = 2,
    dot = 3,
    direct_damage = 4,
    heal = 5,  -- Handled by healing intelligence, included for reference
}

-- Multiplier for default priority calculation
local TYPE_PRIORITY_MULTIPLIER = 10

--------------------------------------------------------------------------------
-- Lazy-loaded Dependencies
--------------------------------------------------------------------------------

local _SpellsetPersistence = nil
local function getSpellsetPersistence()
    if not _SpellsetPersistence then
        local ok, mod = pcall(require, 'sidekick-next.utils.spellset_persistence')
        if ok then _SpellsetPersistence = mod end
    end
    return _SpellsetPersistence
end

local _SpellbookScanner = nil
local function getSpellbookScanner()
    if not _SpellbookScanner then
        local ok, mod = pcall(require, 'sidekick-next.utils.spellbook_scanner')
        if ok then _SpellbookScanner = mod end
    end
    return _SpellbookScanner
end

local _ConditionDefaults = nil
local function getConditionDefaults()
    if not _ConditionDefaults then
        local ok, mod = pcall(require, 'sidekick-next.utils.condition_defaults')
        if ok then _ConditionDefaults = mod end
    end
    return _ConditionDefaults
end

local _ConditionBuilder = nil
local function getConditionBuilder()
    if not _ConditionBuilder then
        local ok, mod = pcall(require, 'sidekick-next.ui.condition_builder')
        if ok then _ConditionBuilder = mod end
    end
    return _ConditionBuilder
end

local _ConditionContext = nil
local function getConditionContext()
    if not _ConditionContext then
        local ok, mod = pcall(require, 'sidekick-next.utils.condition_context')
        if ok then _ConditionContext = mod end
    end
    return _ConditionContext
end

--------------------------------------------------------------------------------
-- Sorted Cast List
--------------------------------------------------------------------------------

---@class CastListEntry
---@field slot number Gem slot number (1-13)
---@field config GemConfig The gem configuration from spell set
---@field spellType string Spell type category ("debuff", "buff", "dot", etc.)
---@field priority number Calculated priority for sorting
---@field spellName string|nil Cached spell name for casting
---@field spellId number Spell ID

--- Build a sorted list of spells to cast based on the active spell set
--- Skips heals (handled by healing intelligence)
---@param spellSet SpellSet|nil The spell set to process (uses active if nil)
---@return CastListEntry[] Sorted array of spells to potentially cast
function M.getSortedCastList(spellSet)
    -- Get spell set if not provided
    if not spellSet then
        local Persistence = getSpellsetPersistence()
        if Persistence then
            spellSet = Persistence.getActiveSet()
        end
    end

    if not spellSet or not spellSet.gems then
        return {}
    end

    local Scanner = getSpellbookScanner()
    local ConditionDefaults = getConditionDefaults()

    -- Ensure scanner has run
    if Scanner and Scanner.scan then
        Scanner.scan()
    end

    local castList = {}

    -- Iterate through all configured gems
    for slot, config in pairs(spellSet.gems) do
        if config and config.spellId and config.spellId > 0 then
            -- Get spell entry from scanner cache
            local spellEntry = nil
            if Scanner and Scanner.getSpellById then
                spellEntry = Scanner.getSpellById(config.spellId)
            end

            -- Determine spell type category
            local spellType = 'buff'  -- Default fallback
            if ConditionDefaults and ConditionDefaults.getSpellTypeCategory then
                if spellEntry then
                    spellType = ConditionDefaults.getSpellTypeCategory(spellEntry)
                else
                    spellType = ConditionDefaults.getSpellTypeCategory(config.spellId)
                end
            end

            -- Skip heals - healing intelligence handles them
            if spellType ~= 'heal' then
                -- Calculate priority
                local priority
                if config.priority and config.priority > 0 then
                    -- Use config priority override
                    priority = config.priority
                else
                    -- Use type-based default priority
                    local typePriority = M.TYPE_PRIORITY[spellType] or M.TYPE_PRIORITY.direct_damage
                    priority = typePriority * TYPE_PRIORITY_MULTIPLIER
                end

                -- Get spell name for casting
                local spellName = nil
                if spellEntry and spellEntry.name then
                    spellName = spellEntry.name
                else
                    -- Fallback: get name from TLO
                    local spell = mq.TLO.Spell(config.spellId)
                    if spell and spell() and spell.Name then
                        spellName = spell.Name()
                    end
                end

                ---@type CastListEntry
                local entry = {
                    slot = slot,
                    config = config,
                    spellType = spellType,
                    priority = priority,
                    spellName = spellName,
                    spellId = config.spellId,
                }

                table.insert(castList, entry)
            end
        end
    end

    -- Sort by priority (lower = earlier)
    table.sort(castList, function(a, b)
        if a.priority ~= b.priority then
            return a.priority < b.priority
        end
        -- Tie-breaker: lower gem slot first
        return a.slot < b.slot
    end)

    return castList
end

--------------------------------------------------------------------------------
-- Condition Evaluation
--------------------------------------------------------------------------------

--- Evaluate a spell's condition to determine if it should be cast
---@param config GemConfig The gem configuration with condition data
---@param ctx table|nil Condition context (built if nil)
---@return boolean True if condition passes (or no conditions defined)
function M.evaluateCondition(config, ctx)
    -- No condition = always true
    if not config or not config.condition then
        return true
    end

    -- Empty conditions array = always true
    if config.condition.conditions and #config.condition.conditions == 0 then
        return true
    end

    local ConditionBuilder = getConditionBuilder()
    if not ConditionBuilder or not ConditionBuilder.evaluateWithContext then
        -- Cannot evaluate, default to true
        return true
    end

    -- Build context if not provided
    if not ctx then
        local ConditionContext = getConditionContext()
        if ConditionContext and ConditionContext.build then
            ctx = ConditionContext.build()
        else
            ctx = {}
        end
    end

    -- Evaluate the condition
    local ok, result = pcall(ConditionBuilder.evaluateWithContext, config.condition, ctx)
    if not ok then
        -- Evaluation error, default to false for safety
        return false
    end

    return result == true
end

--------------------------------------------------------------------------------
-- Buff Targeting
--------------------------------------------------------------------------------

--- Get the target ID for a single-target buff based on buffTarget configuration
---@param config GemConfig The gem configuration with buffTarget data
---@return number|nil Target spawn ID, or nil if no specific target
function M.getBuffTarget(config)
    if not config or not config.buffTarget then
        return nil
    end

    local buffTarget = config.buffTarget
    local targetType = buffTarget.type
    local targetValue = buffTarget.value

    if not targetType or targetType == 'self' then
        -- Self target - return own ID
        local myId = mq.TLO.Me.ID()
        return myId and myId > 0 and myId or nil
    end

    if targetType == 'role' then
        -- Role-based targeting: MainTank, MainAssist, Puller
        local group = mq.TLO.Group
        if not group or not group() then return nil end

        local roleValue = (targetValue or ''):lower()
        local spawn = nil

        if roleValue == 'maintank' or roleValue == 'tank' then
            spawn = group.MainTank
        elseif roleValue == 'mainassist' or roleValue == 'assist' then
            spawn = group.MainAssist
        elseif roleValue == 'puller' then
            spawn = group.Puller
        end

        if spawn and spawn() then
            local id = spawn.ID()
            if id and id > 0 then
                return id
            end
        end

        return nil
    end

    if targetType == 'class' then
        -- Class-based targeting: find first group member of that class
        local targetClass = (targetValue or ''):upper()
        if targetClass == '' then return nil end

        local group = mq.TLO.Group
        if not group or not group() then return nil end

        local members = tonumber(group.Members()) or 0

        -- Check group members (including self at index 0)
        for i = 0, members do
            local member
            if i == 0 then
                member = mq.TLO.Me
            else
                member = group.Member(i)
            end

            if member and member() then
                local cls = member.Class and member.Class.ShortName and member.Class.ShortName()
                if cls and cls:upper() == targetClass then
                    local id = member.ID()
                    if id and id > 0 then
                        return id
                    end
                end
            end
        end

        return nil
    end

    if targetType == 'name' or targetType == 'named' then
        -- Name-based targeting: spawn lookup by name
        local targetName = targetValue or ''
        if targetName == '' then return nil end

        local spawn = mq.TLO.Spawn(string.format('pc ="%s"', targetName))
        if spawn and spawn() then
            local id = spawn.ID()
            if id and id > 0 then
                return id
            end
        end

        -- Try without PC restriction
        spawn = mq.TLO.Spawn(string.format('="%s"', targetName))
        if spawn and spawn() then
            local id = spawn.ID()
            if id and id > 0 then
                return id
            end
        end

        return nil
    end

    if targetType == 'group' then
        -- Group targeting (for group buffs) - no specific target needed
        return nil
    end

    if targetType == 'pet' then
        -- Pet targeting
        local pet = mq.TLO.Me.Pet
        if pet and pet() and pet.ID() > 0 then
            return pet.ID()
        end
        return nil
    end

    if targetType == 'npc' or targetType == 'npc_target' or targetType == 'current_npc' then
        -- Current NPC target - for beneficial spells cast on enemies (reverse DS, etc.)
        local target = mq.TLO.Target
        if target and target() and target.ID() and target.ID() > 0 then
            local tType = target.Type and target.Type() or ""
            local targetDead = target.Dead and target.Dead() or false
            if tType == "NPC" and not targetDead then
                return target.ID()
            end
        end
        return nil
    end

    -- Unknown type
    return nil
end

--------------------------------------------------------------------------------
-- Next Spell Selection
--------------------------------------------------------------------------------

--- Check if a spell is ready to cast (memorized and not on cooldown)
---@param slot number Gem slot number
---@param spellName string|nil Spell name
---@return boolean True if ready
local function isSpellReady(slot, spellName)
    local me = mq.TLO.Me
    if not me or not me() then return false end

    -- Check if spell is memorized in the expected slot
    local gem = me.Gem(slot)
    if not gem or not gem() then return false end

    local gemId = gem.ID and gem.ID() or 0

    -- Check if spell is ready (not on cooldown)
    if spellName then
        return me.SpellReady(spellName)() == true
    else
        return me.SpellReady(slot)() == true
    end
end

--- Check if we're currently casting or global cooldown active
---@return boolean True if busy
local function isCastingBusy()
    local me = mq.TLO.Me
    if not me or not me() then return true end

    -- Check if casting
    local casting = me.Casting()
    if casting and casting ~= '' then
        return true
    end

    -- Check casting window
    if mq.TLO.Window("CastingWindow").Open() then
        return true
    end

    return false
end

--- Check if a spell can be resisted based on its ResistType
---@param spellId number The spell ID
---@return boolean True if the spell can be resisted (has Magic/Fire/etc resist type)
local function canBeResisted(spellId)
    if not spellId or spellId <= 0 then return true end  -- Assume yes if unknown

    local spell = mq.TLO.Spell(spellId)
    if not spell or not spell() then return true end

    local resistType = spell.ResistType and spell.ResistType() or ""
    if resistType == "" then return true end

    -- These resist types mean the spell cannot be resisted
    local unresistableTypes = {
        ["Beneficial"] = true,
        ["Beneficial(Blockable)"] = true,
        ["Unresistable"] = true,
        [""] = false,  -- Unknown, assume resistable
    }

    if unresistableTypes[resistType] then
        return false  -- Cannot be resisted
    end

    -- Has a resist type like Magic, Fire, Cold, etc. - can be resisted
    return true
end

--- Check if a debuff/DoT is already on the target
---@param spellName string The spell name to check
---@param spellId number The spell ID
---@return boolean True if the effect is already on target (should skip casting)
local function isEffectOnTarget(spellName, spellId)
    local target = mq.TLO.Target
    if not target or not target() then return false end

    -- Check if this exact spell is on the target as a buff/debuff
    -- Note: In EQ, even debuffs show up in Target.Buff()
    if spellName then
        local buff = target.Buff(spellName)
        if buff and buff() and buff.ID() then
            -- Check if it has meaningful duration remaining (more than 3 seconds)
            local duration = buff.Duration()
            if duration and duration > 3000 then
                return true
            end
        end
    end

    -- Also check by spell ID
    if spellId and spellId > 0 then
        local buff = target.Buff(spellId)
        if buff and buff() and buff.ID() then
            local duration = buff.Duration()
            if duration and duration > 3000 then
                return true
            end
        end
    end

    -- Check if the spell would stack on target (returns false if it won't stack)
    -- This catches spells that share the same slot/effect
    if spellName then
        local spell = mq.TLO.Spell(spellName)
        if spell and spell() and spell.StacksTarget then
            local stacks = spell.StacksTarget()
            if stacks == false then
                -- Spell won't stack, meaning something similar is already on target
                return true
            end
        end
    end

    return false
end

--- Get the next spell to cast based on priority and conditions
---@return number|nil gemSlot The gem slot to cast from (1-13)
---@return number|nil targetId The target spawn ID (nil for self/PB)
function M.getNextSpell()
    -- Don't return anything if already casting
    if isCastingBusy() then
        return nil, nil
    end

    -- Get active spell set
    local Persistence = getSpellsetPersistence()
    if not Persistence then
        return nil, nil
    end

    local spellSet = Persistence.getActiveSet()
    if not spellSet then
        return nil, nil
    end

    -- Build condition context once for all evaluations
    local ctx = nil
    local ConditionContext = getConditionContext()
    if ConditionContext and ConditionContext.build then
        ctx = ConditionContext.build()
    end

    -- Get sorted cast list
    local castList = M.getSortedCastList(spellSet)

    -- Iterate in priority order, find first that passes conditions and is ready
    for _, entry in ipairs(castList) do
        -- Check if spell is ready
        if isSpellReady(entry.slot, entry.spellName) then
            -- Evaluate conditions
            if M.evaluateCondition(entry.config, ctx) then
                -- Get target for buff spells
                local targetId = nil
                local shouldSkip = false

                if entry.spellType == 'buff' then
                    -- Check if this buff has a specific target configured
                    if entry.config.buffTarget then
                        local buffTargetType = entry.config.buffTarget.type or ''
                        targetId = M.getBuffTarget(entry.config)

                        -- For NPC targets (beneficial spells on enemies like reverse DS), check stacking
                        if buffTargetType == 'npc' or buffTargetType == 'npc_target' or buffTargetType == 'current_npc' then
                            if targetId then
                                -- Check if effect already on target
                                if isEffectOnTarget(entry.spellName, entry.spellId) then
                                    shouldSkip = true
                                    targetId = nil
                                end
                            else
                                -- No valid NPC target
                                shouldSkip = true
                            end
                        end
                    end
                elseif entry.spellType == 'debuff' or entry.spellType == 'dot' then
                    -- Use current target for detrimental spells
                    local target = mq.TLO.Target
                    if target and target() and target.ID() and target.ID() > 0 then
                        -- Ensure target is an NPC and alive
                        local targetType = target.Type and target.Type() or ""
                        local targetDead = target.Dead and target.Dead() or false
                        if targetType == "NPC" and not targetDead then
                            -- Check if this debuff/DoT is already on the target
                            if isEffectOnTarget(entry.spellName, entry.spellId) then
                                -- Effect already on target, skip this spell
                                shouldSkip = true
                            else
                                targetId = target.ID()
                            end
                        else
                            -- Skip this spell - no valid target
                            shouldSkip = true
                        end
                    else
                        -- No target at all for detrimental spell
                        shouldSkip = true
                    end
                elseif entry.spellType == 'direct_damage' then
                    -- Use current target for direct damage (no stacking check needed)
                    local target = mq.TLO.Target
                    if target and target() and target.ID() and target.ID() > 0 then
                        -- Ensure target is an NPC and alive
                        local targetType = target.Type and target.Type() or ""
                        local targetDead = target.Dead and target.Dead() or false
                        if targetType == "NPC" and not targetDead then
                            targetId = target.ID()
                        else
                            -- Skip this spell - no valid target
                            shouldSkip = true
                        end
                    else
                        -- No target at all for detrimental spell
                        shouldSkip = true
                    end
                end

                if not shouldSkip then
                    return entry.slot, targetId
                end
            end
        end
    end

    -- No spell ready/available
    return nil, nil
end

--------------------------------------------------------------------------------
-- Combat Processing
--------------------------------------------------------------------------------

--- Check if player is in combat
---@return boolean True if in combat
local function inCombat()
    local me = mq.TLO.Me
    if not me or not me() then return false end

    -- Check Me.Combat() boolean
    local combat = me.Combat()
    if combat then return true end

    -- Check Me.CombatState() string
    local combatState = me.CombatState()
    if combatState and tostring(combatState):upper() == 'COMBAT' then
        return true
    end

    return false
end

--- Cast a spell from a gem slot at an optional target
---@param gemSlot number The gem slot to cast from
---@param targetId number|nil Optional target spawn ID
---@return boolean True if cast was initiated
local function castSpell(gemSlot, targetId)
    if not gemSlot or gemSlot < 1 then return false end

    local me = mq.TLO.Me
    if not me or not me() then return false end

    -- Target if needed
    if targetId and targetId > 0 then
        local currentTarget = mq.TLO.Target
        local currentTargetId = currentTarget and currentTarget() and currentTarget.ID() or 0
        if currentTargetId ~= targetId then
            mq.cmdf('/target id %d', targetId)
            mq.delay(100)
        end
    end

    -- Cast the spell
    mq.cmdf('/cast %d', gemSlot)
    return true
end

--- Process combat spells - main routine called from automation loop
--- Returns true if a spell cast was initiated
---@return boolean True if a spell was cast
function M.process()
    -- Only cast in combat
    if not inCombat() then
        return false
    end

    -- Check if already casting
    if isCastingBusy() then
        return false
    end

    -- Get next spell to cast
    local gemSlot, targetId = M.getNextSpell()
    if not gemSlot then
        return false
    end

    -- Cast the spell
    return castSpell(gemSlot, targetId)
end

--------------------------------------------------------------------------------
-- Utility Functions
--------------------------------------------------------------------------------

--- Get spell info for a gem slot
---@param slot number Gem slot number
---@return table|nil Spell info with name, id, type, priority
function M.getSpellInfo(slot)
    local Persistence = getSpellsetPersistence()
    if not Persistence then return nil end

    local spellSet = Persistence.getActiveSet()
    if not spellSet or not spellSet.gems or not spellSet.gems[slot] then
        return nil
    end

    local config = spellSet.gems[slot]
    local Scanner = getSpellbookScanner()
    local ConditionDefaults = getConditionDefaults()

    local spellEntry = nil
    if Scanner and Scanner.getSpellById then
        spellEntry = Scanner.getSpellById(config.spellId)
    end

    local spellType = 'buff'
    if ConditionDefaults and ConditionDefaults.getSpellTypeCategory then
        spellType = ConditionDefaults.getSpellTypeCategory(config.spellId)
    end

    local spellName = nil
    if spellEntry and spellEntry.name then
        spellName = spellEntry.name
    else
        local spell = mq.TLO.Spell(config.spellId)
        if spell and spell() and spell.Name then
            spellName = spell.Name()
        end
    end

    return {
        slot = slot,
        spellId = config.spellId,
        spellName = spellName,
        spellType = spellType,
        priority = config.priority or (M.TYPE_PRIORITY[spellType] or 4) * TYPE_PRIORITY_MULTIPLIER,
        hasCondition = config.condition ~= nil and config.condition.conditions and #config.condition.conditions > 0,
        hasBuffTarget = config.buffTarget ~= nil,
    }
end

--- Check if a specific spell type is available and ready
---@param spellType string Type to check ("debuff", "buff", "dot", "direct_damage")
---@return boolean True if at least one spell of this type is ready
function M.hasReadySpellOfType(spellType)
    local castList = M.getSortedCastList()

    for _, entry in ipairs(castList) do
        if entry.spellType == spellType then
            if isSpellReady(entry.slot, entry.spellName) then
                return true
            end
        end
    end

    return false
end

--- Debug: Print the current cast list with priorities
function M.debugPrintCastList()
    local castList = M.getSortedCastList()

    print('\ay[CombatSpellExecutor]\ax Cast list:')
    if #castList == 0 then
        print('  (empty - all spells may be heals which are skipped)')
    end
    for i, entry in ipairs(castList) do
        local readyStr = isSpellReady(entry.slot, entry.spellName) and '\agReady\ax' or '\arCooldown\ax'
        print(string.format('  %d. Gem %d: %s (%s) - Priority %d - %s',
            i, entry.slot, entry.spellName or 'Unknown', entry.spellType, entry.priority, readyStr))
    end
end

--- Debug: Print ALL configured gems including heals
function M.debugPrintAllGems()
    local Persistence = getSpellsetPersistence()
    if not Persistence then
        print('\ar[CombatSpellExecutor]\ax Failed to load persistence')
        return
    end

    local spellSet = Persistence.getActiveSet()
    if not spellSet or not spellSet.gems then
        print('\ar[CombatSpellExecutor]\ax No active spell set or no gems')
        return
    end

    local ConditionDefaults = getConditionDefaults()

    print('\ay[CombatSpellExecutor]\ax ALL configured gems (including heals):')
    for slot, config in pairs(spellSet.gems) do
        if config and config.spellId then
            local spell = mq.TLO.Spell(config.spellId)
            local spellName = spell and spell() and spell.Name() or 'Unknown'
            local resistType = spell and spell() and spell.ResistType and spell.ResistType() or 'Unknown'
            local resistable = canBeResisted(config.spellId) and 'Yes' or 'No'
            local spellType = 'unknown'
            if ConditionDefaults and ConditionDefaults.getSpellTypeCategory then
                spellType = ConditionDefaults.getSpellTypeCategory(config.spellId)
            end
            local skipped = (spellType == 'heal') and ' \ar(SKIPPED - heal)\ax' or ''
            local buffTarget = config.buffTarget and config.buffTarget.type or 'none'
            print(string.format('  Gem %d: %s (ID: %d)', slot, spellName, config.spellId))
            print(string.format('         Type: %s | Resist: %s (Resistable: %s) | BuffTarget: %s%s',
                spellType, resistType, resistable, buffTarget, skipped))
        end
    end
end

--- Debug: Print combat state
function M.debugPrintState()
    local me = mq.TLO.Me
    local target = mq.TLO.Target

    print('\ay[CombatSpellExecutor]\ax Combat state:')
    print(string.format('  In Combat: %s', inCombat() and '\agYes\ax' or '\arNo\ax'))
    print(string.format('  Casting Busy: %s', isCastingBusy() and '\arYes\ax' or '\agNo\ax'))

    if target and target() then
        local targetType = target.Type and target.Type() or 'Unknown'
        local targetDead = target.Dead and target.Dead() or false
        print(string.format('  Target: %s (Type: %s, Dead: %s)',
            target.CleanName() or 'None', targetType, tostring(targetDead)))
    else
        print('  Target: \arNone\ax')
    end
end

return M
