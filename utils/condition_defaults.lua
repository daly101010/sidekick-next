-- F:/lua/sidekick-next/utils/condition_defaults.lua
-- Default Condition Generator - generates sensible default conditions based on spell type
-- Used when spells are added to a spell set; users can customize via condition_builder UI

local mq = require('mq')

local M = {}

--------------------------------------------------------------------------------
-- Dependencies (lazy-loaded)
--------------------------------------------------------------------------------

local _Scanner = nil
local function getScanner()
    if not _Scanner then
        local ok, scanner = pcall(require, 'sidekick-next.utils.spellbook_scanner')
        if ok then _Scanner = scanner end
    end
    return _Scanner
end

--------------------------------------------------------------------------------
-- SPA Constants (imported from spellbook_scanner)
--------------------------------------------------------------------------------

-- Get SPA constants from scanner, with fallback definitions
local function getSPA()
    local scanner = getScanner()
    if scanner and scanner.SPA then
        return scanner.SPA
    end
    -- Fallback SPA constants if scanner not available
    return {
        SNARE = 3,          -- Movement speed reduction
        TASH = 10,          -- Magic resist debuff (Tashani line)
        SLOW = 11,          -- Attack speed reduction
        MEZ = 31,           -- Mesmerize
        CRIPPLE = 96,       -- Stat debuff (Cripple line)
        ROOT = 99,          -- Root (movement prevention)
        RESIST_DEBUFF = 116, -- Resist debuffs (various types)
    }
end

--------------------------------------------------------------------------------
-- SPA to TLO Property Mapping
--------------------------------------------------------------------------------

-- Maps SPA numbers to spawn TLO property names
local SPA_TO_TLO = {
    [11] = "Slowed",   -- SPA.SLOW
    [10] = "Tashed",   -- SPA.TASH
    [116] = "Maloed",  -- SPA.RESIST_DEBUFF (malo-type)
    [3] = "Snared",    -- SPA.SNARE
    [99] = "Rooted",   -- SPA.ROOT
    [31] = "Mezzed",   -- SPA.MEZ
    [96] = "Crippled", -- SPA.CRIPPLE (not available on all spawns, may need different check)
}

--------------------------------------------------------------------------------
-- Debuff Type Detection
--------------------------------------------------------------------------------

--- Detect the debuff type of a spell using HasSPA
-- Returns the TLO property name that can be checked on a spawn (e.g., "Slowed", "Tashed")
---@param spell MQSpell The spell object from mq.TLO.Spell()
---@return string|nil tloProperty The TLO property name, or nil if not a debuff type
function M.detectDebuffType(spell)
    if not spell or not spell() then return nil end
    if not spell.HasSPA then return nil end

    local SPA = getSPA()

    -- Check each debuff SPA in order of priority
    -- Order: Slow, Tash, Malo, Snare, Root, Mez, Cripple
    local spaChecks = {
        { spa = SPA.SLOW, tlo = "Slowed" },
        { spa = SPA.TASH, tlo = "Tashed" },
        { spa = SPA.RESIST_DEBUFF, tlo = "Maloed" },
        { spa = SPA.SNARE, tlo = "Snared" },
        { spa = SPA.ROOT, tlo = "Rooted" },
        { spa = SPA.MEZ, tlo = "Mezzed" },
        { spa = SPA.CRIPPLE, tlo = "Crippled" },
    }

    for _, check in ipairs(spaChecks) do
        local ok, hasSpa = pcall(function()
            return spell.HasSPA(check.spa)()
        end)
        if ok and hasSpa then
            return check.tlo
        end
    end

    return nil
end

--------------------------------------------------------------------------------
-- Spell Type Category Detection
--------------------------------------------------------------------------------

--- Determine the spell type category from a SpellEntry or spell ID
-- Categories: "heal", "debuff", "dot", "direct_damage", "buff", "pet"
---@param spellEntry SpellEntry|number The SpellEntry table or spell ID
---@return string category The spell category
function M.getSpellTypeCategory(spellEntry)
    local spell = nil
    local entry = nil

    -- Handle both SpellEntry table and raw spell ID
    if type(spellEntry) == 'number' then
        spell = mq.TLO.Spell(spellEntry)
        -- Try to get entry from scanner cache
        local scanner = getScanner()
        if scanner and scanner.byId then
            entry = scanner.byId[spellEntry]
        end
    elseif type(spellEntry) == 'table' then
        entry = spellEntry
        if entry.id then
            spell = mq.TLO.Spell(entry.id)
        elseif entry.name then
            spell = mq.TLO.Spell(entry.name)
        end
    end

    -- Use entry data if available
    if entry then
        local category = (entry.category or ''):lower()
        local subcategory = (entry.subcategory or ''):lower()
        local beneficial = entry.beneficial
        local duration = entry.duration or 0

        -- Check for heal
        if category:find('heal') or subcategory:find('heal') then
            return 'heal'
        end

        -- Check for pet summon spells (before other checks)
        if category:find('pet') or subcategory:find('pet')
            or subcategory:find('summon') or category:find('summon') then
            -- Exclude "pet heal" and "pet buff" type spells
            if not (subcategory:find('heal') or subcategory:find('buff')) then
                return 'pet'
            end
        end

        -- Check for detrimental spells
        if not beneficial then
            -- Check for specific debuff keywords
            if category:find('debuff') or subcategory:find('debuff')
                or subcategory:find('slow') or subcategory:find('tash')
                or subcategory:find('mez') or subcategory:find('root')
                or subcategory:find('snare') or subcategory:find('cripple')
                or subcategory:find('resist') then
                return 'debuff'
            end

            -- Check for DoT
            if duration > 0 or subcategory:find('dot') or subcategory:find('over time') then
                return 'dot'
            end

            -- Default detrimental = direct damage
            return 'direct_damage'
        end

        -- Beneficial = buff
        return 'buff'
    end

    -- Fall back to spell TLO data
    if spell and spell() then
        local beneficial = spell.Beneficial and spell.Beneficial() or false
        local duration = spell.Duration and spell.Duration() or 0
        local category = spell.Category and spell.Category() or ''
        local subcategory = spell.Subcategory and spell.Subcategory() or ''
        local categoryLower = category:lower()
        local subcategoryLower = subcategory:lower()

        -- Check for heal
        if categoryLower:find('heal') or subcategoryLower:find('heal') then
            return 'heal'
        end

        -- Check for pet summon spells (before other checks)
        if categoryLower:find('pet') or subcategoryLower:find('pet')
            or subcategoryLower:find('summon') or categoryLower:find('summon') then
            -- Exclude "pet heal" and "pet buff" type spells
            if not (subcategoryLower:find('heal') or subcategoryLower:find('buff')) then
                return 'pet'
            end
        end

        -- Check for detrimental
        if not beneficial then
            -- Check for debuff via SPA
            local debuffType = M.detectDebuffType(spell)
            if debuffType then
                return 'debuff'
            end

            -- Check category/subcategory for debuff keywords
            if categoryLower:find('debuff') or subcategoryLower:find('debuff') then
                return 'debuff'
            end

            -- Check for DoT
            if duration > 0 or subcategoryLower:find('dot') then
                return 'dot'
            end

            -- Default = direct damage
            return 'direct_damage'
        end

        -- Beneficial = buff
        return 'buff'
    end

    -- Unable to determine, default to buff (safest)
    return 'buff'
end

--------------------------------------------------------------------------------
-- Condition Generation Helpers
--------------------------------------------------------------------------------

--- Create a new condition with the given parameters
---@param condType string "beneficial" or "detrimental"
---@param subject string "Me", "Target", "Group", etc.
---@param property string The property key
---@param operator string The comparison operator
---@param value any The comparison value
---@return table condition A single condition entry
local function newCondition(condType, subject, property, operator, value)
    return {
        type = condType,
        subject = subject,
        property = property,
        operator = operator,
        value = value,
    }
end

--- Create a negated condition (e.g., "is not Slowed")
---@param property string The TLO property to check (e.g., "Slowed")
---@return table condition A negated condition entry
local function newNegatedCondition(property)
    return {
        type = "detrimental",
        subject = "Target",
        property = property,
        operator = "false", -- Negated type uses operator "false" internally
    }
end

--------------------------------------------------------------------------------
-- Combat Condition Generation
--------------------------------------------------------------------------------

--- Generate default combat conditions based on spell type
-- Returns a condition group suitable for the condition_builder
---@param spellEntry SpellEntry|number The SpellEntry table or spell ID
---@return table|nil conditionGroup The condition group, or nil for no conditions
function M.generateCombatCondition(spellEntry)
    local category = M.getSpellTypeCategory(spellEntry)

    -- Get spell for additional checks
    local spell = nil
    if type(spellEntry) == 'number' then
        spell = mq.TLO.Spell(spellEntry)
    elseif type(spellEntry) == 'table' and spellEntry.id then
        spell = mq.TLO.Spell(spellEntry.id)
    elseif type(spellEntry) == 'table' and spellEntry.name then
        spell = mq.TLO.Spell(spellEntry.name)
    end

    if category == 'heal' then
        -- Healing spells: no conditions (healing intelligence handles targeting)
        return nil
    end

    if category == 'direct_damage' then
        -- Direct damage: InCombat + Target is NPC + Target HP < 90%
        return {
            conditions = {
                newCondition("beneficial", "Me", "Combat", "true", nil),
                newCondition("detrimental", "Target", "Type", "==", "NPC"),
                newCondition("detrimental", "Target", "PctHPs", "<", 90),
            },
            logic = { "AND", "AND" },
        }
    end

    if category == 'dot' then
        -- DoT: same as direct damage (SpellStacks check happens at cast time)
        -- User can add SpellStacks condition via UI if desired
        return {
            conditions = {
                newCondition("beneficial", "Me", "Combat", "true", nil),
                newCondition("detrimental", "Target", "Type", "==", "NPC"),
                newCondition("detrimental", "Target", "PctHPs", "<", 90),
            },
            logic = { "AND", "AND" },
        }
    end

    if category == 'debuff' then
        -- Debuff: base conditions + specific debuff check
        local conditions = {
            newCondition("beneficial", "Me", "Combat", "true", nil),
            newCondition("detrimental", "Target", "Type", "==", "NPC"),
        }
        local logic = { "AND" }

        -- Try to detect which debuff type and add appropriate condition
        if spell and spell() then
            local debuffType = M.detectDebuffType(spell)
            if debuffType and (debuffType == "Slowed" or debuffType == "Rooted"
                or debuffType == "Mezzed" or debuffType == "Snared") then
                -- These are available as negated conditions in condition_builder
                table.insert(conditions, newNegatedCondition(debuffType))
                table.insert(logic, "AND")
            end
            -- Note: Tashed, Maloed, Crippled would need to be added to condition_builder
            -- For now, those spells just get the base combat conditions
        end

        return {
            conditions = conditions,
            logic = logic,
        }
    end

    if category == 'buff' then
        -- Buffs in combat rotation: no conditions by default
        -- User should set specific conditions if needed
        return nil
    end

    if category == 'pet' then
        -- Pet summon spells: only cast if we don't already have a pet
        return {
            conditions = {
                newCondition("beneficial", "Me", "Pet", "false", nil),
            },
            logic = {},
        }
    end

    -- Unknown category: no conditions
    return nil
end

--------------------------------------------------------------------------------
-- OOC (Out of Combat) Condition Generation
--------------------------------------------------------------------------------

--- Generate default OOC conditions
-- OOC buffs use empty conditions (always attempt when OOC)
-- The buff system handles checking if target already has the buff
---@return table|nil conditionGroup The condition group, or nil (always true)
function M.generateOocCondition()
    -- Empty conditions = always passes
    -- Buff presence checking is handled by the buff executor, not conditions
    return nil
end

--------------------------------------------------------------------------------
-- Convenience Functions
--------------------------------------------------------------------------------

--- Generate appropriate default conditions based on spell and context
---@param spellEntry SpellEntry|number The SpellEntry or spell ID
---@param context string "combat" or "ooc"
---@return table|nil conditionGroup The condition group
function M.generateDefaultCondition(spellEntry, context)
    if context == 'ooc' then
        return M.generateOocCondition()
    else
        return M.generateCombatCondition(spellEntry)
    end
end

--- Check if a spell should have default conditions auto-generated
-- Returns true for spells that benefit from default conditions
---@param spellEntry SpellEntry|number The SpellEntry or spell ID
---@return boolean shouldGenerate True if defaults should be generated
function M.shouldGenerateDefaults(spellEntry)
    local category = M.getSpellTypeCategory(spellEntry)

    -- Heals can have conditions set (healing intelligence will use them)
    -- But don't auto-generate defaults - let user set them explicitly
    if category == 'heal' then
        return false
    end

    -- Buffs in combat slots don't get defaults (user should set specific conditions)
    if category == 'buff' then
        return false
    end

    -- Pet spells get default conditions (check for no existing pet)
    if category == 'pet' then
        return true
    end

    -- Everything else gets default conditions
    return true
end

--- Get a human-readable description of the spell type
---@param spellEntry SpellEntry|number The SpellEntry or spell ID
---@return string description Human-readable category description
function M.getSpellTypeDescription(spellEntry)
    local category = M.getSpellTypeCategory(spellEntry)

    local descriptions = {
        heal = "Heal",
        direct_damage = "Direct Damage",
        dot = "Damage over Time",
        debuff = "Debuff",
        buff = "Buff",
        pet = "Pet Summon",
    }

    return descriptions[category] or "Unknown"
end

--- Get the detected debuff type description
---@param spellEntry SpellEntry|number The SpellEntry or spell ID
---@return string|nil description The debuff type (e.g., "Slow", "Mez"), or nil
function M.getDebuffTypeDescription(spellEntry)
    local spell = nil
    if type(spellEntry) == 'number' then
        spell = mq.TLO.Spell(spellEntry)
    elseif type(spellEntry) == 'table' and spellEntry.id then
        spell = mq.TLO.Spell(spellEntry.id)
    elseif type(spellEntry) == 'table' and spellEntry.name then
        spell = mq.TLO.Spell(spellEntry.name)
    end

    if not spell or not spell() then return nil end

    local debuffType = M.detectDebuffType(spell)
    if not debuffType then return nil end

    -- Convert TLO property to description
    local descriptions = {
        Slowed = "Slow",
        Tashed = "Tash",
        Maloed = "Malo",
        Snared = "Snare",
        Rooted = "Root",
        Mezzed = "Mez",
        Crippled = "Cripple",
    }

    return descriptions[debuffType]
end

return M
