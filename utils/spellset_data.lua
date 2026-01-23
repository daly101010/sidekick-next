-- F:/lua/sidekick-next/utils/spellset_data.lua
-- Spell Set Data Structure - types and functions for spell set management
-- This module defines the new spell set data structure that replaces the old line-based system.

local mq = require('mq')

local M = {}

--------------------------------------------------------------------------------
-- Type Definitions (EmmyLua annotations)
--------------------------------------------------------------------------------

---@class BuffTarget
---@field type string Target type: "self", "group", "raid", "pet", "named", "custom"
---@field value string|nil Custom target value (for "named" or "custom" types)

---@class GemConfig
---@field spellId number The spell ID to memorize in this gem slot
---@field condition table|nil Condition data from condition_builder (nil = always cast)
---@field priority number|nil Priority override (nil = use type-based default from spell category)
---@field buffTarget BuffTarget|nil Target configuration for beneficial spells

---@class OocBuffConfig
---@field spellId number The spell ID for this OOC buff
---@field enabled boolean Whether this buff is currently enabled
---@field priority number Priority order (lower = cast first)
---@field condition table|nil Condition data (nil = use default condition for buff type)
---@field buffTarget BuffTarget|nil Target configuration for this buff

---@class SpellSet
---@field name string The spell set name
---@field gems table<number, GemConfig> Map of gem slot (1-13) to GemConfig
---@field oocBuffs OocBuffConfig[] Array of OOC buff configurations, ordered by priority

--------------------------------------------------------------------------------
-- Constants
--------------------------------------------------------------------------------

-- Default priority values by spell category (lower = higher priority)
M.DEFAULT_PRIORITY = {
    heal = 10,
    cure = 20,
    mez = 30,
    slow = 40,
    tash = 50,
    debuff = 60,
    nuke = 70,
    dot = 80,
    snare = 90,
    root = 100,
    charm = 110,
    fear = 120,
    stun = 130,
    buff = 200,
}

-- Default OOC buff priority start value
M.OOC_BUFF_PRIORITY_START = 100
M.OOC_BUFF_PRIORITY_INCREMENT = 10

--------------------------------------------------------------------------------
-- Utility Functions
--------------------------------------------------------------------------------

--- Get the total number of gem slots available
---@return number Total gem count from Me.NumGems()
function M.getTotalGemCount()
    local me = mq.TLO.Me
    if not me or not me() then return 0 end
    return tonumber(me.NumGems()) or 0
end

--- Get the number of gem slots available for rotation spells
--- Reserves the last gem for buff swapping if OOC buffs are configured
---@param hasOocBuffs boolean Whether the spell set has OOC buffs configured
---@return number Number of gems available for rotation (NumGems or NumGems-1)
function M.getRotationGemCount(hasOocBuffs)
    local total = M.getTotalGemCount()
    if total <= 0 then return 0 end
    if hasOocBuffs then
        return total - 1
    end
    return total
end

--------------------------------------------------------------------------------
-- Spell Set Creation
--------------------------------------------------------------------------------

--- Create a new empty spell set
---@param name string The name for the spell set
---@return SpellSet|nil The new spell set, or nil if name is invalid
function M.newSpellSet(name)
    if not name or name == '' then
        return nil
    end

    ---@type SpellSet
    local set = {
        name = name,
        gems = {},
        oocBuffs = {},
    }

    return set
end

--------------------------------------------------------------------------------
-- Gem Operations
--------------------------------------------------------------------------------

--- Find which gem slot contains a spell ID
---@param spellSet SpellSet The spell set to search
---@param spellId number The spell ID to find
---@return number|nil The gem slot (1-13) or nil if not found
function M.findSpellInGems(spellSet, spellId)
    if not spellSet or not spellId then return nil end
    if not spellSet.gems then return nil end

    for slot, gemConfig in pairs(spellSet.gems) do
        if gemConfig and gemConfig.spellId == spellId then
            return slot
        end
    end

    return nil
end

--- Set a spell in a gem slot
---@param spellSet SpellSet The spell set to modify
---@param slot number The gem slot (1-13)
---@param spellId number The spell ID to set
---@param condition table|nil Optional condition data
---@param priority number|nil Optional priority override
---@param buffTarget BuffTarget|nil Optional buff target configuration
---@return boolean True if successful
function M.setGem(spellSet, slot, spellId, condition, priority, buffTarget)
    if not spellSet or not slot or not spellId then return false end
    if slot < 1 then return false end

    local totalGems = M.getTotalGemCount()
    if totalGems > 0 and slot > totalGems then return false end

    spellSet.gems = spellSet.gems or {}

    ---@type GemConfig
    spellSet.gems[slot] = {
        spellId = spellId,
        condition = condition,
        priority = priority,
        buffTarget = buffTarget,
    }

    return true
end

--- Clear a gem slot
---@param spellSet SpellSet The spell set to modify
---@param slot number The gem slot to clear
---@return boolean True if a spell was removed, false if slot was already empty
function M.clearGem(spellSet, slot)
    if not spellSet or not slot then return false end
    if not spellSet.gems then return false end

    if spellSet.gems[slot] then
        spellSet.gems[slot] = nil
        return true
    end

    return false
end

--- Get the GemConfig for a slot
---@param spellSet SpellSet The spell set
---@param slot number The gem slot
---@return GemConfig|nil The gem configuration or nil
function M.getGem(spellSet, slot)
    if not spellSet or not slot then return nil end
    if not spellSet.gems then return nil end
    return spellSet.gems[slot]
end

--- Count how many gems are configured in a spell set
---@param spellSet SpellSet The spell set
---@return number The number of configured gems
function M.countGems(spellSet)
    if not spellSet or not spellSet.gems then return 0 end

    local count = 0
    for _, _ in pairs(spellSet.gems) do
        count = count + 1
    end
    return count
end

--------------------------------------------------------------------------------
-- OOC Buff Operations
--------------------------------------------------------------------------------

--- Check if a spell set has any OOC buffs configured
---@param spellSet SpellSet The spell set to check
---@return boolean True if at least one OOC buff is configured
function M.hasOocBuffs(spellSet)
    if not spellSet or not spellSet.oocBuffs then return false end
    return #spellSet.oocBuffs > 0
end

--- Find the index of a spell ID in OOC buffs
---@param spellSet SpellSet The spell set to search
---@param spellId number The spell ID to find
---@return number|nil The index (1-based) or nil if not found
function M.findSpellInOocBuffs(spellSet, spellId)
    if not spellSet or not spellId then return nil end
    if not spellSet.oocBuffs then return nil end

    for i, buffConfig in ipairs(spellSet.oocBuffs) do
        if buffConfig and buffConfig.spellId == spellId then
            return i
        end
    end

    return nil
end

--- Calculate the next available priority for OOC buffs
---@param spellSet SpellSet The spell set
---@return number The next priority value
local function getNextOocBuffPriority(spellSet)
    if not spellSet or not spellSet.oocBuffs or #spellSet.oocBuffs == 0 then
        return M.OOC_BUFF_PRIORITY_START
    end

    local maxPriority = 0
    for _, buffConfig in ipairs(spellSet.oocBuffs) do
        if buffConfig.priority > maxPriority then
            maxPriority = buffConfig.priority
        end
    end

    return maxPriority + M.OOC_BUFF_PRIORITY_INCREMENT
end

--- Add an OOC buff to the spell set
---@param spellSet SpellSet The spell set to modify
---@param spellId number The spell ID to add
---@param enabled boolean|nil Whether the buff is enabled (default true)
---@param condition table|nil Optional condition data
---@param buffTarget BuffTarget|nil Optional buff target configuration
---@return boolean True if added, false if already exists or invalid
function M.addOocBuff(spellSet, spellId, enabled, condition, buffTarget)
    if not spellSet or not spellId then return false end

    -- Check if already exists
    if M.findSpellInOocBuffs(spellSet, spellId) then
        return false
    end

    spellSet.oocBuffs = spellSet.oocBuffs or {}

    ---@type OocBuffConfig
    local buffConfig = {
        spellId = spellId,
        enabled = enabled ~= false, -- Default to true
        priority = getNextOocBuffPriority(spellSet),
        condition = condition,
        buffTarget = buffTarget,
    }

    table.insert(spellSet.oocBuffs, buffConfig)
    return true
end

--- Remove an OOC buff from the spell set and renumber priorities
---@param spellSet SpellSet The spell set to modify
---@param spellId number The spell ID to remove
---@return boolean True if removed, false if not found
function M.removeOocBuff(spellSet, spellId)
    if not spellSet or not spellId then return false end
    if not spellSet.oocBuffs then return false end

    local idx = M.findSpellInOocBuffs(spellSet, spellId)
    if not idx then return false end

    table.remove(spellSet.oocBuffs, idx)

    -- Renumber priorities to keep them sequential
    M.renumberOocBuffPriorities(spellSet)

    return true
end

--- Toggle the enabled state of an OOC buff
---@param spellSet SpellSet The spell set to modify
---@param spellId number The spell ID to toggle
---@return boolean|nil The new enabled state, or nil if not found
function M.toggleOocBuff(spellSet, spellId)
    if not spellSet or not spellId then return nil end
    if not spellSet.oocBuffs then return nil end

    local idx = M.findSpellInOocBuffs(spellSet, spellId)
    if not idx then return nil end

    local buffConfig = spellSet.oocBuffs[idx]
    buffConfig.enabled = not buffConfig.enabled

    return buffConfig.enabled
end

--- Get an OOC buff configuration by spell ID
---@param spellSet SpellSet The spell set
---@param spellId number The spell ID
---@return OocBuffConfig|nil The buff configuration or nil
function M.getOocBuff(spellSet, spellId)
    if not spellSet or not spellId then return nil end

    local idx = M.findSpellInOocBuffs(spellSet, spellId)
    if not idx then return nil end

    return spellSet.oocBuffs[idx]
end

--- Get an OOC buff configuration by index
---@param spellSet SpellSet The spell set
---@param index number The 1-based index
---@return OocBuffConfig|nil The buff configuration or nil
function M.getOocBuffByIndex(spellSet, index)
    if not spellSet or not index then return nil end
    if not spellSet.oocBuffs then return nil end
    return spellSet.oocBuffs[index]
end

--- Renumber OOC buff priorities to be sequential
---@param spellSet SpellSet The spell set to modify
function M.renumberOocBuffPriorities(spellSet)
    if not spellSet or not spellSet.oocBuffs then return end

    -- Sort by current priority first
    table.sort(spellSet.oocBuffs, function(a, b)
        return (a.priority or 999) < (b.priority or 999)
    end)

    -- Reassign sequential priorities
    for i, buffConfig in ipairs(spellSet.oocBuffs) do
        buffConfig.priority = M.OOC_BUFF_PRIORITY_START + (i - 1) * M.OOC_BUFF_PRIORITY_INCREMENT
    end
end

--- Set the priority of an OOC buff
---@param spellSet SpellSet The spell set to modify
---@param spellId number The spell ID
---@param priority number The new priority value
---@return boolean True if successful
function M.setOocBuffPriority(spellSet, spellId, priority)
    if not spellSet or not spellId or not priority then return false end

    local buffConfig = M.getOocBuff(spellSet, spellId)
    if not buffConfig then return false end

    buffConfig.priority = priority
    return true
end

--- Move an OOC buff up in priority (lower priority number = earlier in list)
---@param spellSet SpellSet The spell set to modify
---@param spellId number The spell ID to move
---@return boolean True if moved, false if already at top or not found
function M.moveOocBuffUp(spellSet, spellId)
    if not spellSet or not spellId then return false end
    if not spellSet.oocBuffs or #spellSet.oocBuffs < 2 then return false end

    -- Sort first to ensure consistent ordering
    table.sort(spellSet.oocBuffs, function(a, b)
        return (a.priority or 999) < (b.priority or 999)
    end)

    local idx = M.findSpellInOocBuffs(spellSet, spellId)
    if not idx or idx <= 1 then return false end

    -- Swap with previous
    local temp = spellSet.oocBuffs[idx]
    spellSet.oocBuffs[idx] = spellSet.oocBuffs[idx - 1]
    spellSet.oocBuffs[idx - 1] = temp

    -- Renumber to keep priorities clean
    M.renumberOocBuffPriorities(spellSet)

    return true
end

--- Move an OOC buff down in priority (higher priority number = later in list)
---@param spellSet SpellSet The spell set to modify
---@param spellId number The spell ID to move
---@return boolean True if moved, false if already at bottom or not found
function M.moveOocBuffDown(spellSet, spellId)
    if not spellSet or not spellId then return false end
    if not spellSet.oocBuffs or #spellSet.oocBuffs < 2 then return false end

    -- Sort first to ensure consistent ordering
    table.sort(spellSet.oocBuffs, function(a, b)
        return (a.priority or 999) < (b.priority or 999)
    end)

    local idx = M.findSpellInOocBuffs(spellSet, spellId)
    if not idx or idx >= #spellSet.oocBuffs then return false end

    -- Swap with next
    local temp = spellSet.oocBuffs[idx]
    spellSet.oocBuffs[idx] = spellSet.oocBuffs[idx + 1]
    spellSet.oocBuffs[idx + 1] = temp

    -- Renumber to keep priorities clean
    M.renumberOocBuffPriorities(spellSet)

    return true
end

--- Get all enabled OOC buffs sorted by priority
---@param spellSet SpellSet The spell set
---@return OocBuffConfig[] Array of enabled buffs sorted by priority
function M.getEnabledOocBuffs(spellSet)
    if not spellSet or not spellSet.oocBuffs then return {} end

    local enabled = {}
    for _, buffConfig in ipairs(spellSet.oocBuffs) do
        if buffConfig.enabled then
            table.insert(enabled, buffConfig)
        end
    end

    -- Sort by priority
    table.sort(enabled, function(a, b)
        return (a.priority or 999) < (b.priority or 999)
    end)

    return enabled
end

--------------------------------------------------------------------------------
-- Validation
--------------------------------------------------------------------------------

--- Validate a spell set structure
---@param spellSet SpellSet The spell set to validate
---@return boolean, string True if valid, false with error message if invalid
function M.validate(spellSet)
    if not spellSet then
        return false, "Spell set is nil"
    end

    if not spellSet.name or spellSet.name == '' then
        return false, "Spell set has no name"
    end

    if type(spellSet.gems) ~= 'table' then
        return false, "Spell set gems is not a table"
    end

    if type(spellSet.oocBuffs) ~= 'table' then
        return false, "Spell set oocBuffs is not a table"
    end

    -- Validate gems
    for slot, gemConfig in pairs(spellSet.gems) do
        if type(slot) ~= 'number' or slot < 1 then
            return false, string.format("Invalid gem slot: %s", tostring(slot))
        end
        if not gemConfig.spellId or type(gemConfig.spellId) ~= 'number' then
            return false, string.format("Gem slot %d has invalid spellId", slot)
        end
    end

    -- Validate OOC buffs
    for i, buffConfig in ipairs(spellSet.oocBuffs) do
        if not buffConfig.spellId or type(buffConfig.spellId) ~= 'number' then
            return false, string.format("OOC buff %d has invalid spellId", i)
        end
        if type(buffConfig.enabled) ~= 'boolean' then
            return false, string.format("OOC buff %d has invalid enabled flag", i)
        end
        if not buffConfig.priority or type(buffConfig.priority) ~= 'number' then
            return false, string.format("OOC buff %d has invalid priority", i)
        end
    end

    return true, nil
end

--- Create a deep copy of a spell set
---@param spellSet SpellSet The spell set to copy
---@return SpellSet|nil A new copy of the spell set
function M.clone(spellSet)
    if not spellSet then return nil end

    local copy = M.newSpellSet(spellSet.name)
    if not copy then return nil end

    -- Copy gems
    for slot, gemConfig in pairs(spellSet.gems or {}) do
        copy.gems[slot] = {
            spellId = gemConfig.spellId,
            condition = gemConfig.condition, -- Note: shallow copy of condition table
            priority = gemConfig.priority,
            buffTarget = gemConfig.buffTarget and {
                type = gemConfig.buffTarget.type,
                value = gemConfig.buffTarget.value,
            } or nil,
        }
    end

    -- Copy OOC buffs
    for _, buffConfig in ipairs(spellSet.oocBuffs or {}) do
        table.insert(copy.oocBuffs, {
            spellId = buffConfig.spellId,
            enabled = buffConfig.enabled,
            priority = buffConfig.priority,
            condition = buffConfig.condition, -- Note: shallow copy of condition table
            buffTarget = buffConfig.buffTarget and {
                type = buffConfig.buffTarget.type,
                value = buffConfig.buffTarget.value,
            } or nil,
        })
    end

    return copy
end

return M
