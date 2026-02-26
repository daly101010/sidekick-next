-- F:/lua/sidekick-next/utils/ooc_buff_executor.lua
-- OOC (Out of Combat) Buff Executor
-- Handles casting buffs when out of combat, including buff-swap for non-rotation spells

local mq = require('mq')

local M = {}

--------------------------------------------------------------------------------
-- State
--------------------------------------------------------------------------------

local state = {
    lastCast = 0,
    castCooldown = 1.5, -- seconds between buff casts
    savedGemSpell = nil, -- { slot = number, spellId = number, spellName = string }
}

--------------------------------------------------------------------------------
-- Constants
--------------------------------------------------------------------------------

local MEMORIZE_TIMEOUT_MS = 12000   -- Max time to wait for memorization
local CAST_TIMEOUT_MS = 15000       -- Max time to wait for cast completion
local WAIT_POLL_MS = 100            -- Poll interval for wait functions
local GCD_MS = 2250                 -- Global cooldown in milliseconds

--------------------------------------------------------------------------------
-- Lazy-loaded Dependencies
--------------------------------------------------------------------------------

local _Core = nil
local function getCore()
    if not _Core then
        local ok, mod = pcall(require, 'sidekick-next.core')
        if ok then _Core = mod end
    end
    return _Core
end

local _SpellsetPersistence = nil
local function getPersistence()
    if not _SpellsetPersistence then
        local ok, mod = pcall(require, 'sidekick-next.utils.spellset_persistence')
        if ok then _SpellsetPersistence = mod end
    end
    return _SpellsetPersistence
end

local _SpellSetData = nil
local function getSpellSetData()
    if not _SpellSetData then
        local ok, mod = pcall(require, 'sidekick-next.utils.spellset_data')
        if ok then _SpellSetData = mod end
    end
    return _SpellSetData
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

local _SpellbookScanner = nil
local function getSpellbookScanner()
    if not _SpellbookScanner then
        local ok, mod = pcall(require, 'sidekick-next.utils.spellbook_scanner')
        if ok then _SpellbookScanner = mod end
    end
    return _SpellbookScanner
end

--------------------------------------------------------------------------------
-- Internal Helpers
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

--- Check if we're currently casting
---@return boolean True if casting
local function isCasting()
    local me = mq.TLO.Me
    if not me or not me() then return false end

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

--- Get the reserved gem slot for buff swapping
---@param spellSet table The spell set
---@return number|nil The reserved gem slot number (last gem), or nil
local function getReservedGemSlot(spellSet)
    local SpellSetData = getSpellSetData()
    if not SpellSetData then return nil end

    local totalGems = SpellSetData.getTotalGemCount()
    if totalGems <= 0 then return nil end

    return totalGems
end

--- Find if a spell is memorized in any rotation gem
---@param spellId number The spell ID to find
---@return number|nil The gem slot (1-13) if found, or nil
local function findInGems(spellId)
    if not spellId then return nil end

    local Persistence = getPersistence()
    local SpellSetData = getSpellSetData()
    if not Persistence or not SpellSetData then return nil end

    local spellSet = Persistence.getActiveSet()
    if not spellSet then return nil end

    return SpellSetData.findSpellInGems(spellSet, spellId)
end

--- Get the spell name for a spell ID
---@param spellId number The spell ID
---@return string|nil The spell name or nil
local function getSpellName(spellId)
    if not spellId then return nil end

    local spell = mq.TLO.Spell(spellId)
    if spell and spell() and spell.Name() then
        return spell.Name()
    end

    return nil
end

--- Check if target has a buff by name
---@param spawn table The spawn to check
---@param spellName string The spell name to look for
---@return boolean True if buff is present
local function hasBuffByName(spawn, spellName)
    if not spawn or not spawn() or not spellName then return false end

    -- Check via Buff
    local buff = spawn.Buff and spawn.Buff(spellName)
    if buff and buff() then
        return true
    end

    -- Check via Song (for bard songs) - only available on Me
    if spawn.Song then
        local song = spawn.Song(spellName)
        if song and song() then
            return true
        end
    end

    return false
end

--- Check if a spell is an aura spell
---@param spellId number The spell ID to check
---@return boolean True if it's an aura spell
local function isAuraSpell(spellId)
    if not spellId then return false end

    local spell = mq.TLO.Spell(spellId)
    if not spell or not spell() then return false end

    -- Check spell name for "Aura"
    local name = spell.Name and spell.Name() or ""
    if name:lower():find("aura") then return true end

    -- Check category
    local category = spell.Category and spell.Category() or ""
    if category:lower():find("aura") then return true end

    -- Check subcategory
    local subcategory = spell.Subcategory and spell.Subcategory() or ""
    if subcategory:lower():find("aura") then return true end

    -- Check target type
    local targetType = spell.TargetType and spell.TargetType() or ""
    if targetType:lower():find("aura") then return true end

    return false
end

--- Check if Me has an aura active by spell name
---@param spellName string The aura spell name to look for
---@return boolean True if aura is active
local function selfHasAura(spellName)
    if not spellName then return false end

    local me = mq.TLO.Me
    if not me or not me() then return false end

    -- Check Aura slots (typically 1-2 for most classes)
    for i = 1, 5 do
        local aura = me.Aura(i)
        if aura and aura() then
            local auraName = aura.Name and aura.Name() or ""
            -- Check if the aura name matches or contains our spell name
            if auraName ~= "" then
                if auraName:lower() == spellName:lower() then
                    return true
                end
                -- Some auras have "Aura" stripped from name when active
                if auraName:lower():find(spellName:lower():gsub(" aura", ""), 1, true) then
                    return true
                end
                -- Or the spell name might be contained in the aura name
                if spellName:lower():find(auraName:lower(), 1, true) then
                    return true
                end
            end
        end
    end

    return false
end

--- Check if Me has a buff/song/aura by name
---@param spellName string The spell name to look for
---@param spellId number|nil Optional spell ID for aura detection
---@return boolean True if buff is present
local function selfHasBuff(spellName, spellId)
    if not spellName then return false end

    local me = mq.TLO.Me
    if not me or not me() then return false end

    -- Check if this is an aura spell
    if spellId and isAuraSpell(spellId) then
        return selfHasAura(spellName)
    end

    -- Check Buff
    local buff = me.Buff(spellName)
    if buff and buff() then
        return true
    end

    -- Check Song
    local song = me.Song(spellName)
    if song and song() then
        return true
    end

    -- Also check auras just in case (for spells not detected as auras)
    if selfHasAura(spellName) then
        return true
    end

    return false
end

--- Get group members that need a specific buff
---@param spellId number The buff spell ID
---@return table Array of { id = number, name = string } for members missing the buff
local function getGroupMembersNeedingBuff(spellId)
    local members = {}
    local spellName = getSpellName(spellId)
    if not spellName then return members end

    local me = mq.TLO.Me
    if not me or not me() then return members end

    -- For auras, only check self (auras are self-only)
    local isAura = isAuraSpell(spellId)

    -- Check self
    if not selfHasBuff(spellName, spellId) then
        table.insert(members, {
            id = me.ID(),
            name = me.CleanName() or me.Name() or 'Self',
        })
    end

    -- For auras, don't check group members (they're self-only)
    if isAura then
        return members
    end

    -- Check group members 1-5
    local group = mq.TLO.Group
    if group and group() then
        local groupCount = tonumber(group.Members()) or 0
        for i = 1, math.min(5, groupCount) do
            local member = group.Member(i)
            if member and member() then
                local memberId = member.ID()
                if memberId and memberId > 0 then
                    -- Check if member needs the buff
                    local spawn = mq.TLO.Spawn(memberId)
                    if spawn and spawn() and not hasBuffByName(spawn, spellName) then
                        table.insert(members, {
                            id = memberId,
                            name = member.CleanName() or member.Name() or 'Unknown',
                        })
                    end
                end
            end
        end
    end

    return members
end

--- Get buff targets based on buff config
---@param config OocBuffConfig The buff configuration
---@return table Array of { id = number, name = string }
local function getBuffTargets(config)
    if not config or not config.spellId then return {} end

    local buffTarget = config.buffTarget

    -- If no specific target configured, default to group members needing buff
    if not buffTarget or not buffTarget.type then
        return getGroupMembersNeedingBuff(config.spellId)
    end

    local targetType = buffTarget.type
    local targetValue = buffTarget.value
    local targets = {}
    local spellName = getSpellName(config.spellId)

    if targetType == 'self' then
        -- Self only
        local me = mq.TLO.Me
        if me and me() and not selfHasBuff(spellName, config.spellId) then
            table.insert(targets, {
                id = me.ID(),
                name = me.CleanName() or me.Name() or 'Self',
            })
        end

    elseif targetType == 'group' then
        -- All group members
        return getGroupMembersNeedingBuff(config.spellId)

    elseif targetType == 'role' then
        -- Role-based targeting: MainTank, MainAssist, Puller
        local group = mq.TLO.Group
        if group and group() then
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
                if id and id > 0 and not hasBuffByName(spawn, spellName) then
                    table.insert(targets, {
                        id = id,
                        name = spawn.CleanName() or spawn.Name() or 'Unknown',
                    })
                end
            end
        end

    elseif targetType == 'class' then
        -- Class-based targeting: find first group member of that class
        local targetClass = (targetValue or ''):upper()
        if targetClass ~= '' then
            local group = mq.TLO.Group
            if group and group() then
                local groupCount = tonumber(group.Members()) or 0

                -- Check self first
                local me = mq.TLO.Me
                if me and me() then
                    local myClass = me.Class and me.Class.ShortName and me.Class.ShortName()
                    if myClass and myClass:upper() == targetClass then
                        if not selfHasBuff(spellName) then
                            table.insert(targets, {
                                id = me.ID(),
                                name = me.CleanName() or me.Name() or 'Self',
                            })
                        end
                    end
                end

                -- Check group members
                for i = 1, math.min(5, groupCount) do
                    local member = group.Member(i)
                    if member and member() then
                        local cls = member.Class and member.Class.ShortName and member.Class.ShortName()
                        if cls and cls:upper() == targetClass then
                            local memberId = member.ID()
                            if memberId and memberId > 0 then
                                local spawn = mq.TLO.Spawn(memberId)
                                if spawn and spawn() and not hasBuffByName(spawn, spellName) then
                                    table.insert(targets, {
                                        id = memberId,
                                        name = member.CleanName() or member.Name() or 'Unknown',
                                    })
                                end
                            end
                        end
                    end
                end
            end
        end

    elseif targetType == 'name' or targetType == 'named' then
        -- Name-based targeting
        local targetName = targetValue or ''
        if targetName ~= '' then
            local spawn = mq.TLO.Spawn(string.format('pc ="%s"', targetName))
            if not spawn or not spawn() then
                spawn = mq.TLO.Spawn(string.format('="%s"', targetName))
            end
            if spawn and spawn() then
                local id = spawn.ID()
                if id and id > 0 and not hasBuffByName(spawn, spellName) then
                    table.insert(targets, {
                        id = id,
                        name = spawn.CleanName() or spawn.Name() or targetName,
                    })
                end
            end
        end

    elseif targetType == 'pet' then
        -- Pet targeting
        local pet = mq.TLO.Me.Pet
        if pet and pet() and pet.ID() > 0 then
            if not hasBuffByName(pet, spellName) then
                table.insert(targets, {
                    id = pet.ID(),
                    name = pet.CleanName() or pet.Name() or 'Pet',
                })
            end
        end
    end

    return targets
end

--- Evaluate a buff's condition
---@param config OocBuffConfig The buff configuration
---@param ctx table|nil Condition context
---@return boolean True if condition passes
local function evaluateCondition(config, ctx)
    if not config or not config.condition then
        return true
    end

    -- Empty conditions = always true
    if config.condition.conditions and #config.condition.conditions == 0 then
        return true
    end

    local ConditionBuilder = getConditionBuilder()
    if not ConditionBuilder or not ConditionBuilder.evaluateWithContext then
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

    local ok, result = pcall(ConditionBuilder.evaluateWithContext, config.condition, ctx)
    if not ok then
        return false
    end

    return result == true
end

--- Wait until a spell is memorized in a gem slot
---@param slot number The gem slot to check
---@param spellId number The expected spell ID
---@param timeout number Timeout in milliseconds
---@return boolean True if spell is memorized
local function waitForMemorize(slot, spellId, timeout)
    if not slot or slot < 1 or not spellId then return false end
    timeout = timeout or MEMORIZE_TIMEOUT_MS

    local elapsed = 0
    while elapsed < timeout do
        local gem = mq.TLO.Me.Gem(slot)
        if gem and gem() and gem.ID() == spellId then
            return true
        end

        mq.delay(WAIT_POLL_MS)
        elapsed = elapsed + WAIT_POLL_MS

        -- Check for combat interrupt
        if inCombat() then
            return false
        end
    end

    return false
end

--- Wait for cast to complete
---@param timeout number Timeout in milliseconds
---@return boolean True if cast completed
local function waitForCastComplete(timeout)
    timeout = timeout or CAST_TIMEOUT_MS

    -- Wait for casting to start
    mq.delay(100)

    local elapsed = 0
    while elapsed < timeout do
        if not isCasting() then
            return true
        end

        mq.delay(WAIT_POLL_MS)
        elapsed = elapsed + WAIT_POLL_MS

        -- Check for combat interrupt
        if inCombat() then
            return false
        end
    end

    return false
end

--- Cast a buff on a target
---@param config OocBuffConfig The buff configuration
---@param targetId number The target spawn ID
---@return boolean True if cast was successful
local function castBuff(config, targetId)
    if not config or not config.spellId or not targetId then return false end

    local spellName = getSpellName(config.spellId)
    if not spellName then return false end

    local me = mq.TLO.Me
    if not me or not me() then return false end

    -- Check if spell is already in a rotation gem
    local existingGem = findInGems(config.spellId)

    if existingGem then
        -- Cast from existing gem
        if not me.SpellReady(existingGem)() then
            return false -- Spell not ready
        end

        -- Target the spawn
        if targetId ~= me.ID() then
            mq.cmdf('/target id %d', targetId)
            mq.delay(200)
        end

        -- Cast from gem
        mq.cmdf('/cast %d', existingGem)
        waitForCastComplete()
        return true
    end

    -- Need to buff-swap
    local Persistence = getPersistence()
    local SpellSetData = getSpellSetData()
    if not Persistence or not SpellSetData then return false end

    local spellSet = Persistence.getActiveSet()
    if not spellSet then return false end

    local reservedGem = getReservedGemSlot(spellSet)
    if not reservedGem then return false end

    -- Save current spell in reserved gem (if any)
    local currentGem = me.Gem(reservedGem)
    local savedSpellId = nil
    local savedSpellName = nil
    if currentGem and currentGem() and currentGem.ID() then
        savedSpellId = currentGem.ID()
        savedSpellName = currentGem.Name()
    end

    -- Memorize the buff spell
    mq.cmdf('/memspell %d "%s"', reservedGem, spellName)
    if not waitForMemorize(reservedGem, config.spellId, MEMORIZE_TIMEOUT_MS) then
        -- Memorization failed or combat started
        return false
    end

    -- Wait for gem to be ready (includes memorization recovery time)
    local readyWait = 0
    while readyWait < 5000 and not me.SpellReady(reservedGem)() do
        if inCombat() then
            return false
        end
        mq.delay(100)
        readyWait = readyWait + 100
    end

    if not me.SpellReady(reservedGem)() then
        return false
    end

    -- Target the spawn
    if targetId ~= me.ID() then
        mq.cmdf('/target id %d', targetId)
        mq.delay(200)
    end

    -- Cast the buff
    mq.cmdf('/cast %d', reservedGem)
    waitForCastComplete()

    -- Restore the original spell (if any)
    if savedSpellName and savedSpellId then
        mq.cmdf('/memspell %d "%s"', reservedGem, savedSpellName)
        waitForMemorize(reservedGem, savedSpellId, MEMORIZE_TIMEOUT_MS)
    end

    return true
end

--------------------------------------------------------------------------------
-- Public Functions
--------------------------------------------------------------------------------

--- Process OOC buffs - main routine called from automation loop
---@return boolean True if a buff was cast, false otherwise
function M.process()
    -- Check if automation is paused
    local Core = getCore()
    if Core and Core.Settings and Core.Settings.AutomationPaused == true then
        return false
    end

    -- Check if in combat
    if inCombat() then
        return false
    end

    -- Check if casting
    if isCasting() then
        return false
    end

    -- Check cooldown
    local now = os.time()
    if now - state.lastCast < state.castCooldown then
        return false
    end

    -- Get active spell set
    local Persistence = getPersistence()
    local SpellSetData = getSpellSetData()
    if not Persistence or not SpellSetData then
        return false
    end

    local spellSet = Persistence.getActiveSet()
    if not spellSet then
        return false
    end

    -- Check if set has OOC buffs
    if not SpellSetData.hasOocBuffs(spellSet) then
        return false
    end

    -- Build condition context once
    local ctx = nil
    local ConditionContext = getConditionContext()
    if ConditionContext and ConditionContext.build then
        ctx = ConditionContext.build()
    end

    -- Get enabled OOC buffs sorted by priority
    local enabledBuffs = SpellSetData.getEnabledOocBuffs(spellSet)

    -- Iterate in priority order
    for _, buffConfig in ipairs(enabledBuffs) do
        -- Check for combat
        if inCombat() then
            return false
        end

        -- Evaluate condition
        if evaluateCondition(buffConfig, ctx) then
            -- Get targets that need this buff
            local targets = getBuffTargets(buffConfig)

            -- Cast on first valid target
            if #targets > 0 then
                local target = targets[1]
                if castBuff(buffConfig, target.id) then
                    state.lastCast = os.time()
                    return true
                end
            end
        end
    end

    return false
end

--- Get the cast cooldown setting
---@return number Cooldown in seconds
function M.getCooldown()
    return state.castCooldown
end

--- Set the cast cooldown
---@param seconds number Cooldown in seconds
function M.setCooldown(seconds)
    if seconds and seconds >= 0 then
        state.castCooldown = seconds
    end
end

--- Reset state (useful for testing)
function M.reset()
    state.lastCast = 0
    state.savedGemSpell = nil
end

--- Debug: Print current OOC buff status
function M.debugPrint()
    local Persistence = getPersistence()
    local SpellSetData = getSpellSetData()
    if not Persistence or not SpellSetData then
        print('\ar[OocBuffExecutor]\ax Failed to load dependencies')
        return
    end

    local spellSet = Persistence.getActiveSet()
    if not spellSet then
        print('\ay[OocBuffExecutor]\ax No active spell set')
        return
    end

    local enabled = SpellSetData.getEnabledOocBuffs(spellSet)
    print(string.format('\ay[OocBuffExecutor]\ax %d enabled OOC buffs:', #enabled))

    for i, buffConfig in ipairs(enabled) do
        local spellName = getSpellName(buffConfig.spellId) or 'Unknown'
        local inGem = findInGems(buffConfig.spellId)
        local gemStr = inGem and string.format(' (in gem %d)', inGem) or ' (swap required)'
        local targets = getBuffTargets(buffConfig)

        print(string.format('  %d. %s - Priority %d - %d targets needing buff%s',
            i, spellName, buffConfig.priority, #targets, gemStr))
    end
end

return M
