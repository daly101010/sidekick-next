-- F:/lua/SideKick/utils/spell_rotation.lua
-- Spell Rotation - Spell selection and execution for combat rotation

local mq = require('mq')

local M = {}

-- Rotation state
M.state = {
    currentSpell = nil,
    retryCount = 0,
    lastTargetId = 0,
    lastTargetDeathTime = 0,
    resetPending = false,
}

-- Spell categories for layer assignment
M.CATEGORY_TO_LAYER = {
    cc = 'support',
    mez = 'support',
    debuff = 'support',
    slow = 'support',
    malo = 'support',
    tash = 'support',
    cripple = 'support',
    selfheal = 'support',
    groupheal = 'support',
    nuke = 'combat',
    dot = 'combat',
    burn = 'burn',
    buff = 'utility',
}

-- Resist types
M.RESIST_TYPES = {
    'Any', 'Magic', 'Fire', 'Cold', 'Poison', 'Disease', 'Chromatic',
}

-- Debuff categories (no reset delay)
M.DEBUFF_CATEGORIES = {
    debuff = true, slow = true, malo = true, tash = true, cripple = true,
    snare = true, root = true,
}

-- Lazy-load dependencies
local _SpellEngine = nil
local function getSpellEngine()
    if not _SpellEngine then
        local ok, se = pcall(require, 'utils.spell_engine')
        if ok then _SpellEngine = se end
    end
    return _SpellEngine
end

local _SpellEvents = nil
local function getSpellEvents()
    if not _SpellEvents then
        local ok, se = pcall(require, 'utils.spell_events')
        if ok then _SpellEvents = se end
    end
    return _SpellEvents
end

local _ImmuneDB = nil
local function getImmuneDB()
    if not _ImmuneDB then
        local ok, db = pcall(require, 'utils.immune_database')
        if ok then _ImmuneDB = db end
    end
    return _ImmuneDB
end

local _SpellLineup = nil
local function getSpellLineup()
    if not _SpellLineup then
        local ok, sl = pcall(require, 'utils.spell_lineup')
        if ok then _SpellLineup = sl end
    end
    return _SpellLineup
end

local _Cache = nil
local function getCache()
    if not _Cache then
        local ok, c = pcall(require, 'utils.runtime_cache')
        if ok then _Cache = c end
    end
    return _Cache
end

--- Get the layer for a spell based on its category
-- @param category string Spell category
-- @return string Layer name
function M.getLayerForCategory(category)
    if not category then return 'combat' end
    return M.CATEGORY_TO_LAYER[category:lower()] or 'combat'
end

--- Check if a category is a debuff (no reset delay)
-- @param category string Spell category
-- @return boolean
function M.isDebuffCategory(category)
    if not category then return false end
    return M.DEBUFF_CATEGORIES[category:lower()] == true
end

--- Check if spell matches preferred resist type
-- @param spell userdata MQ Spell object
-- @param preferredType string Preferred resist type
-- @return boolean
function M.matchesResistType(spell, preferredType)
    if not spell or not spell() then return false end
    if not preferredType or preferredType == 'Any' then return true end

    local resistType = spell.ResistType and spell.ResistType() or ''
    return resistType:lower() == preferredType:lower()
end

--- Handle target death - reset rotation or continue
-- @param settings table Settings
function M.onTargetDeath(settings)
    M.state.lastTargetDeathTime = os.clock()
    M.state.resetPending = true
    M.state.retryCount = 0
end

--- Check if rotation should reset for new target
-- @param settings table Settings
-- @return boolean True if should reset
function M.shouldResetRotation(settings)
    if not M.state.resetPending then return false end

    local resetWindow = settings and settings.RotationResetWindow or 2
    local elapsed = os.clock() - M.state.lastTargetDeathTime

    if elapsed <= resetWindow then
        -- Within window, check if we have a new target
        local targetId = mq.TLO.Target.ID() or 0
        if targetId > 0 and targetId ~= M.state.lastTargetId then
            M.state.lastTargetId = targetId
            M.state.resetPending = false
            return true
        end
    else
        -- Window expired, reset anyway
        M.state.resetPending = false
        return true
    end

    return false
end

--- Select the next spell to cast from available spells
-- @param spells table Array of spell definitions
-- @param settings table Settings
-- @param targetId number Current target ID
-- @return table|nil Selected spell definition
function M.selectNextSpell(spells, settings, targetId)
    -- Defensive nil checks
    if not spells or #spells == 0 then return nil end
    settings = settings or {}

    local preferredResist = settings.PreferredResistType or 'Any'
    local ImmuneDB = getImmuneDB()

    -- Get target info for immune check
    local targetName = ''
    if targetId and targetId > 0 then
        local target = mq.TLO.Spawn(targetId)
        if target and target() then
            targetName = target.CleanName and target.CleanName() or ''
        end
    end

    for _, spellDef in ipairs(spells) do
        if type(spellDef) ~= 'table' then goto continue end

        local spellName = spellDef.spellName or spellDef.name
        if not spellName or spellName == '' then goto continue end

        -- Check if enabled
        local enabled = spellDef.settingKey and settings[spellDef.settingKey]
        if enabled == false then goto continue end

        -- Check category condition
        if not M.checkCategoryCondition(spellDef, settings) then
            goto continue
        end

        -- Get spell info
        local spell = mq.TLO.Spell(spellName)
        if not spell or not spell() then goto continue end

        -- Check resist type filter for damage spells
        local category = spellDef.category or ''
        if category == 'nuke' or category == 'dot' then
            if not M.matchesResistType(spell, preferredResist) then
                goto continue
            end
        end

        -- Check immune database
        if ImmuneDB and type(ImmuneDB.isImmune) == 'function' and settings.UseImmuneDatabase and targetName ~= '' then
            local immuneCategory = M.getImmuneCategoryForSpell(spellDef, spell)
            if ImmuneDB.isImmune(targetName, immuneCategory) then
                goto continue
            end
        end

        -- Check if spell is ready (in gem and not on cooldown)
        local gemSlot = mq.TLO.Me.Gem(spellName)
        if not gemSlot or not gemSlot() then goto continue end

        local ready = mq.TLO.Me.SpellReady(spellName)
        if not ready or not ready() then goto continue end

        -- This spell is available
        return spellDef

        ::continue::
    end

    return nil
end

--- Get the immune category for a spell (for database lookup)
-- @param spellDef table Spell definition
-- @param spell userdata MQ Spell object
-- @return string Immune category
function M.getImmuneCategoryForSpell(spellDef, spell)
    local category = spellDef.category or ''
    if category ~= '' then
        return category:lower()
    end

    -- Infer from resist type for damage spells
    if spell and spell() then
        local resistType = spell.ResistType and spell.ResistType() or ''
        if resistType ~= '' then
            return resistType:lower()
        end
    end

    return 'unknown'
end

--- Check if a spell's category conditions are met
-- @param spellEntry table Spell entry from lineup
-- @param settings table Settings
-- @return boolean True if conditions met
function M.checkCategoryCondition(spellEntry, settings)
    local category = spellEntry.category
    if not category then return false end

    local Cache = getCache()
    local inCombat = Cache and Cache.inCombat() or false

    -- Heal: someone below threshold (basic check - self for now)
    if category == 'heal' then
        -- When tiered healing is enabled, healing is handled by automation.healing.
        if settings.DoHeals == true then
            return false
        end
        local threshold = settings.HealThreshold or 80
        local myHp = mq.TLO.Me.PctHPs() or 100
        return myHp < threshold
    end

    -- CC/Debuffs: in combat with valid target
    if category == 'mez' or category == 'slow' or category == 'tash' or category == 'debuff' then
        if not inCombat then return false end
        local targetId = mq.TLO.Target.ID() or 0
        return targetId > 0
    end

    -- Damage: in combat with target
    if category == 'nuke' or category == 'dot' then
        if not inCombat then return false end
        local targetId = mq.TLO.Target.ID() or 0
        return targetId > 0
    end

    -- Root/Snare: in combat
    if category == 'root' or category == 'snare' then
        return inCombat
    end

    -- Charm/Fear/Stun: in combat
    if category == 'charm' or category == 'fear' or category == 'stun' then
        return inCombat
    end

    -- Buff: not in combat (basic)
    if category == 'buff' then
        return not inCombat
    end

    return true
end

--- Main tick - called after AA/disc rotation
-- @param opts table Options: settings, targetId
function M.tick(opts)
    opts = opts or {}
    local settings = opts.settings or {}

    -- Get spells from lineup
    local SpellLineup = getSpellLineup()
    local spells = {}
    if SpellLineup then
        SpellLineup.checkZoneChange(settings)
        spells = SpellLineup.getSpells(false, settings)
    end

    -- Check if spell rotation is enabled
    if not settings.SpellRotationEnabled then return end

    -- Get spell engine
    local SpellEngine = getSpellEngine()
    if not SpellEngine then return end

    -- Don't try to cast if spell engine is busy
    if SpellEngine.isBusy and SpellEngine.isBusy() then return end

    -- Check for rotation reset
    if M.shouldResetRotation(settings) then
        M.state.currentSpell = nil
        M.state.retryCount = 0
    end

    -- Select next spell
    local targetId = mq.TLO.Target.ID() or 0
    local spellDef = M.selectNextSpell(spells, settings, targetId)
    if not spellDef then return end

    -- Cast the spell
    local spellName = spellDef.spellName or spellDef.name
    local success = SpellEngine.cast(spellName, targetId, {
        spellCategory = spellDef.category,
    })

    if success then
        M.state.currentSpell = spellDef
    end
end

--- Handle spell cast result
-- @param result number Result code from SpellEvents
-- @param settings table Settings
function M.handleCastResult(result, settings)
    local SpellEvents = getSpellEvents()
    if not SpellEvents then return end

    -- Defensive check for RESULT table
    local RESULT = SpellEvents.RESULT
    if not RESULT then return end

    -- Success - clear current spell
    if result == RESULT.SUCCESS then
        M.state.currentSpell = nil
        M.state.retryCount = 0
        return
    end

    -- Immune - log to database and move on
    if result == RESULT.IMMUNE then
        M.handleImmune()
        M.state.currentSpell = nil
        M.state.retryCount = 0
        return
    end

    -- Check retry settings
    settings = settings or {}
    local shouldRetry = false
    if result == RESULT.FIZZLE and settings.RetryOnFizzle ~= false then
        shouldRetry = true
    elseif result == RESULT.RESISTED and settings.RetryOnResist ~= false then
        shouldRetry = true
    elseif result == RESULT.INTERRUPTED and settings.RetryOnInterrupt ~= false then
        shouldRetry = true
    end

    if shouldRetry then
        M.state.retryCount = M.state.retryCount + 1
        -- Keep currentSpell for retry
        if M.state.retryCount > 3 then
            -- Too many retries, move on
            M.state.currentSpell = nil
            M.state.retryCount = 0
        end
    else
        -- Don't retry, move on
        M.state.currentSpell = nil
        M.state.retryCount = 0
    end
end

--- Handle immune result - log to database
function M.handleImmune()
    local ImmuneDB = getImmuneDB()
    if not ImmuneDB or type(ImmuneDB.addImmune) ~= 'function' then return end

    local targetId = mq.TLO.Target.ID() or 0
    if targetId <= 0 then return end

    local target = mq.TLO.Spawn(targetId)
    if not target or not target() then return end

    local targetName = target.CleanName and target.CleanName() or ''
    if targetName == '' then return end

    local spellDef = M.state.currentSpell
    if not spellDef then return end

    local spell = mq.TLO.Spell(spellDef.spellName or spellDef.name)
    local immuneCategory = M.getImmuneCategoryForSpell(spellDef, spell)

    ImmuneDB.addImmune(targetName, immuneCategory)
end

--- Initialize spell rotation
function M.init()
    M.state = {
        currentSpell = nil,
        retryCount = 0,
        lastTargetId = 0,
        lastTargetDeathTime = 0,
        resetPending = false,
    }

    -- Register for spell result callbacks
    local SpellEvents = getSpellEvents()
    if SpellEvents and type(SpellEvents.setResultCallback) == 'function' then
        SpellEvents.setResultCallback(function(result, extra)
            local Core = require('utils.core')
            local settings = Core and Core.Settings or {}
            M.handleCastResult(result, settings)
        end)
    end
end

return M
