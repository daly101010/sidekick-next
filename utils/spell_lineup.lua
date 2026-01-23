-- F:/lua/sidekick/utils/spell_lineup.lua
-- Spell Lineup - Gem scanning and spell categorization

local mq = require('mq')

local M = {}

-- Cached spell list
M.spells = {}
M.lastScanZone = ''
M.lastLoadout = ''

-- Lazy-load class config loader (to map gem slots -> settingKey)
local _ConfigLoader = nil
local function getConfigLoader()
    if not _ConfigLoader then
        local ok, cl = pcall(require, 'sidekick-next.utils.class_config_loader')
        if ok then _ConfigLoader = cl end
    end
    return _ConfigLoader
end

local function buildGemToSettingKey(settings)
    local gemToKey = {}
    settings = settings or {}

    local loadoutName = tostring(settings.SpellLoadout or '')
    if loadoutName == '' then return gemToKey end

    local ConfigLoader = getConfigLoader()
    if not ConfigLoader then return gemToKey end
    if not ConfigLoader.current and ConfigLoader.init then
        ConfigLoader.init()
    end
    if not ConfigLoader.current then return gemToKey end

    local loadouts = ConfigLoader.getSpellLoadouts and ConfigLoader.getSpellLoadouts(ConfigLoader.current) or {}
    local loadout = loadouts[loadoutName] or loadouts[loadoutName:lower()]
    if not loadout or not loadout.gems then return gemToKey end

    -- Build AbilitySet -> settingKey map from DefaultConfig metadata
    local defaultConfig = ConfigLoader.getDefaultConfig and ConfigLoader.getDefaultConfig() or {}
    local setToKey = {}
    for settingKey, meta in pairs(defaultConfig) do
        local setName = meta and meta.AbilitySet
        if setName and setName ~= '' and not setToKey[setName] then
            setToKey[setName] = settingKey
        end
    end

    for gem, setName in pairs(loadout.gems) do
        local gemNum = tonumber(gem)
        if gemNum and setName then
            -- Prefer an explicit Settings key that references this AbilitySet,
            -- but fall back to using the AbilitySet name itself as the settingKey.
            gemToKey[gemNum] = setToKey[setName] or setName
        end
    end

    return gemToKey
end

-- SPA IDs for categorization
M.SPA = {
    HP = 0,
    MOVEMENT_SPEED = 3,
    ATTACK_SPEED = 11,
    STUN = 21,
    CHARM = 22,
    FEAR = 23,
    MESMERIZE = 31,
    RESIST_FIRE = 46,
    RESIST_COLD = 47,
    RESIST_POISON = 48,
    RESIST_DISEASE = 49,
    RESIST_MAGIC = 50,
    HP_OVER_TIME = 79,
    ROOT = 99,
}

-- Category priority (lower = higher priority)
M.CATEGORY_PRIORITY = {
    heal = 1,
    mez = 2,
    slow = 3,
    tash = 4,
    debuff = 5,
    nuke = 6,
    dot = 7,
    snare = 8,
    root = 9,
    charm = 10,
    fear = 11,
    stun = 12,
    buff = 20,
}

--- Categorize a spell based on its SPA effects
-- @param spell userdata MQ Spell object
-- @return string Category name
function M.categorizeSpell(spell)
    if not spell or not spell() then return nil end

    local isDetrimental = spell.SpellType() == 'Detrimental'

    -- Check specific CC/debuff effects first (most specific wins)
    if spell.HasSPA(M.SPA.MESMERIZE)() then return 'mez' end
    if spell.HasSPA(M.SPA.ATTACK_SPEED)() and isDetrimental then return 'slow' end
    if spell.HasSPA(M.SPA.ROOT)() then return 'root' end
    if spell.HasSPA(M.SPA.MOVEMENT_SPEED)() and isDetrimental then return 'snare' end
    if spell.HasSPA(M.SPA.CHARM)() then return 'charm' end
    if spell.HasSPA(M.SPA.FEAR)() then return 'fear' end
    if spell.HasSPA(M.SPA.STUN)() and isDetrimental then return 'stun' end
    if spell.HasSPA(M.SPA.RESIST_MAGIC)() and isDetrimental then return 'tash' end

    -- Resist debuffs (malo-type)
    if isDetrimental then
        for _, spa in ipairs({M.SPA.RESIST_FIRE, M.SPA.RESIST_COLD, M.SPA.RESIST_POISON, M.SPA.RESIST_DISEASE}) do
            if spell.HasSPA(spa)() then return 'debuff' end
        end
    end

    -- HP-based: heal vs nuke/dot
    local hasHP = spell.HasSPA(M.SPA.HP)()
    local hasHPot = spell.HasSPA(M.SPA.HP_OVER_TIME)()
    if hasHP or hasHPot then
        if isDetrimental then
            if hasHPot then return 'dot' end
            return 'nuke'
        else
            return 'heal'
        end
    end

    -- Fallback
    if isDetrimental then return 'debuff' end
    return 'buff'
end

--- Get resist type for a spell
-- @param spell userdata MQ Spell object
-- @return string|nil Resist type or nil
function M.getResistType(spell)
    if not spell or not spell() then return nil end
    local rt = spell.ResistType and spell.ResistType()
    if rt and rt ~= '' and rt ~= 'Unresistable' then
        return rt
    end
    return nil
end

--- Get target type for a spell
-- @param spell userdata MQ Spell object
-- @return string Target type
function M.getTargetType(spell)
    if not spell or not spell() then return 'Unknown' end
    local tt = spell.TargetType and spell.TargetType()
    return tt or 'Unknown'
end

--- Scan memorized spells and build sorted list
-- @param settings table|nil Settings table (used to map gems to settingKey via active loadout)
-- @return table Array of spell entries
function M.scan(settings)
    local spells = {}
    local numGems = mq.TLO.Me.NumGems() or 8

    local gemToSettingKey = buildGemToSettingKey(settings)
    M.lastLoadout = tostring((settings or {}).SpellLoadout or '')

    -- Scan gems 1 to (NumGems-1), skip utility gem
    for gem = 1, numGems - 1 do
        local spell = mq.TLO.Me.Gem(gem)
        if spell and spell() and spell.ID() and spell.ID() > 0 then
            local category = M.categorizeSpell(spell)
            local entry = {
                gem = gem,
                name = spell.Name(),
                id = spell.ID(),
                category = category,
                resistType = nil,
                targetType = M.getTargetType(spell),
                settingKey = gemToSettingKey[gem],
            }

            -- Store resist type for damage spells
            if category == 'nuke' or category == 'dot' then
                entry.resistType = M.getResistType(spell)
            end

            table.insert(spells, entry)
        end
    end

    -- Sort by category priority, then gem order
    table.sort(spells, function(a, b)
        local prioA = M.CATEGORY_PRIORITY[a.category] or 99
        local prioB = M.CATEGORY_PRIORITY[b.category] or 99
        if prioA ~= prioB then
            return prioA < prioB
        end
        return a.gem < b.gem
    end)

    M.spells = spells
    M.lastScanZone = mq.TLO.Zone.ShortName() or ''

    return spells
end

--- Get cached spells, rescan if needed
-- @param forceRescan boolean Force a rescan
-- @param settings table|nil Settings table (used to map gems to settingKey via active loadout)
-- @return table Array of spell entries
function M.getSpells(forceRescan, settings)
    local loadoutName = tostring((settings or {}).SpellLoadout or '')
    if loadoutName ~= M.lastLoadout then
        forceRescan = true
    end
    if forceRescan or #M.spells == 0 then
        return M.scan(settings)
    end
    return M.spells
end

--- Check if zone changed and rescan if needed
-- @param settings table Settings table
function M.checkZoneChange(settings)
    if not settings or settings.SpellRescanOnZone == false then return end

    local currentZone = mq.TLO.Zone.ShortName() or ''
    if currentZone ~= M.lastScanZone and currentZone ~= '' then
        M.scan(settings)
    end
end

--- Initialize spell lineup
function M.init()
    M.scan()
end

return M
