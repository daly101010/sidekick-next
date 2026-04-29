-- F:/lua/SideKick/utils/class_config_loader.lua
-- Class Config Loader - Load and resolve class configurations
-- Supports both old format (AbilitySets/SpellLoadouts/DefaultConfig)
-- and new format (spellLines/aaLines/discLines/gemLoadouts/Settings)

local mq = require('mq')

local M = {}

-- Cached configs by class
M.configs = {}

-- Current class config
M.current = nil

--- Load class config for specified class
-- @param classShort string Class short name (ENC, WAR, etc.)
-- @return table|nil Class config or nil
function M.load(classShort)
    if not classShort or classShort == '' then return nil end

    -- Normalize to uppercase for consistent file naming
    classShort = classShort:upper()

    -- Check cache
    if M.configs[classShort] then
        M.current = M.configs[classShort]
        return M.current
    end

    -- Try to load
    local path = 'data.class_configs.' .. classShort
    local ok, config = pcall(require, path)
    if ok and config then
        M.configs[classShort] = config
        M.current = config
        return config
    end

    return nil
end

--- Get ability sets (supports both old and new format)
-- @param config table Optional specific config
-- @return table AbilitySets table
function M.getAbilitySets(config)
    config = config or M.current
    if not config then return {} end

    -- Old format: AbilitySets
    if config.AbilitySets then
        return config.AbilitySets
    end

    -- New format: merge spellLines, aaLines, discLines
    local sets = {}
    if config.spellLines then
        for name, line in pairs(config.spellLines) do
            sets[name] = line
        end
    end
    if config.aaLines then
        for name, line in pairs(config.aaLines) do
            sets[name] = line
        end
    end
    if config.discLines then
        for name, line in pairs(config.discLines) do
            sets[name] = line
        end
    end

    return sets
end

--- Resolve an AbilitySet (spellLine/aaLine/discLine) to the best available ability
-- Checks spellbook for spells, AltAbility for AAs, CombatAbility for discs
-- Uses proper resolution order: iterate through the line (best to worst) and return first found
-- @param setName string AbilitySet/spellLine name
-- @param config table Optional specific config (uses current if nil)
-- @return string|nil Best available ability name
function M.resolveAbilitySet(setName, config)
    config = config or M.current
    if not config then return nil end

    local sets = M.getAbilitySets(config)
    local set = sets[setName]
    if not set or type(set) ~= 'table' then return nil end

    local me = mq.TLO.Me
    if not me or not me() then return nil end

    -- Iterate through the ability line (ordered best to worst)
    -- Return the first one found in spellbook/AA/disc list. The spellbook
    -- check uses both an exact match and a SpellGroup lookup so unranked
    -- config names ("Avowed Light") match scribed ranks ("Avowed Light Rk. II").
    for _, name in ipairs(set) do
        -- Check spellbook (exact name)
        local spell = me.Book(name)
        if spell and spell() then
            return name
        end

        -- Check spellbook via SpellGroup substring (catches Rk. II / Rk. III)
        local sgSpell = me.Spell(name)
        if sgSpell and sgSpell() then
            return name
        end

        -- Check AAs (for AA lines)
        local aa = me.AltAbility(name)
        if aa and aa() then
            return name
        end

        -- Check combat abilities/discs (for disc lines)
        local disc = me.CombatAbility(name)
        if disc and disc() then
            return name
        end
    end

    return nil
end

--- Get spell loadouts (supports both old and new format)
-- @param config table Optional specific config
-- @return table SpellLoadouts table
function M.getSpellLoadouts(config)
    config = config or M.current
    if not config then return {} end

    -- Old format: SpellLoadouts
    if config.SpellLoadouts then
        return config.SpellLoadouts
    end

    -- New format: gemLoadouts (convert to SpellLoadouts format)
    if config.gemLoadouts then
        local loadouts = {}
        for name, gems in pairs(config.gemLoadouts) do
            loadouts[name:lower()] = {
                name = name,
                description = name .. " loadout",
                gems = gems,
            }
        end
        return loadouts
    end

    return {}
end

--- Get all resolved abilities for a loadout
-- @param loadoutName string Loadout role name
-- @param config table Optional specific config
-- @return table Gem -> spell name mapping
function M.resolveLoadout(loadoutName, config)
    config = config or M.current
    if not config then return {} end

    local loadouts = M.getSpellLoadouts(config)

    -- Try exact match first, then lowercase
    local loadout = loadouts[loadoutName] or loadouts[loadoutName:lower()]
    if not loadout or not loadout.gems then return {} end

    local resolved = {}
    for gem, setName in pairs(loadout.gems) do
        local spell = M.resolveAbilitySet(setName, config)
        if spell then
            resolved[tonumber(gem)] = spell
        end
    end

    return resolved
end

--- Get available loadout names for current config
-- @return table Array of loadout names
function M.getLoadoutNames()
    if not M.current then return {} end

    local loadouts = M.getSpellLoadouts(M.current)
    local names = {}

    for key, loadout in pairs(loadouts) do
        table.insert(names, {
            key = key,
            name = loadout.name or key,
            description = loadout.description or '',
        })
    end

    return names
end

--- Get DefaultConfig for current class (supports both old and new format)
-- @return table DefaultConfig or empty table
function M.getDefaultConfig()
    if not M.current then return {} end

    -- Old format: DefaultConfig
    if M.current.DefaultConfig then
        return M.current.DefaultConfig
    end

    -- New format: Settings
    if M.current.Settings then
        return M.current.Settings
    end

    return {}
end

--- Get default conditions for current class
-- @return table defaultConditions or empty table
function M.getDefaultConditions()
    if not M.current then return {} end
    return M.current.defaultConditions or {}
end

--- Get category overrides for current class
-- @return table categoryOverrides or empty table
function M.getCategoryOverrides()
    if not M.current then return {} end
    return M.current.categoryOverrides or {}
end

--- Get spell lines for current class
-- @return table spellLines or empty table
function M.getSpellLines()
    if not M.current then return {} end
    return M.current.spellLines or {}
end

--- Get AA lines for current class
-- @return table aaLines or empty table
function M.getAALines()
    if not M.current then return {} end
    return M.current.aaLines or {}
end

--- Get disc lines for current class
-- @return table discLines or empty table
function M.getDiscLines()
    if not M.current then return {} end
    return M.current.discLines or {}
end

--- Initialize loader for current character
function M.init()
    local classShort = mq.TLO.Me.Class.ShortName() or ''
    if classShort ~= '' then
        M.load(classShort)
    end
end

return M
