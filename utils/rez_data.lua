-- utils/rez_data.lua
-- Per-class resurrection spell + AA tables.
-- Spell lists are ordered best-XP-return first; the rez module walks the
-- list and picks the first entry where mq.TLO.Spell(name).Stacks() is true
-- (i.e. learned and currently usable).

local M = {}

-- Best->worst rez spell lines per class. Source for CLR mirrors
-- data/class_configs/CLR.lua's RezSpell + AERezSpell tables.
M.spells = {
    -- Cleric: AE rez line (covers multi-death scenarios at top tiers),
    -- then single-target rez line.
    CLR = {
        -- AE rez (best when multiple bodies are likely; still works on one)
        'Superior Reviviscence',
        'Eminent Reviviscence',
        'Greater Reviviscence',
        'Larger Reviviscence',
        -- Single-target progression
        'Reviviscence',
        'Resurrection',
        'Restoration',
        'Resuscitate',
        'Renewal',
        'Reparation',
        'Reconstitution',
        'Revive',
        'Reanimation',
    },
    -- Druid: Reviviscence 90%, Reanimation 0%.
    DRU = {
        'Reviviscence',
        'Reanimation',
    },
    -- Shaman: Incarnate Anew (96%), Renewal of Life (90%), Reviviscence.
    SHM = {
        'Incarnate Anew',
        'Renewal of Life',
        'Reviviscence',
    },
    -- Paladin: Wake the Dead (top tier), Reviviscence (lower).
    PAL = {
        'Wake the Dead',
        'Reviviscence',
    },
    -- Necromancer: Convergence (0% XP), Reanimation.
    NEC = {
        'Convergence',
        'Reanimation',
    },
}

-- Instant-cast rez AAs per class (used for battle-rez).
-- Classes without an entry here cannot battle-rez.
M.aas = {
    CLR = 'Blessing of Resurrection',
}

-- Class short-names that have any rez capability. Used to gate auto-launch
-- of the sk_resurrection module.
M.rezClasses = { CLR = true, DRU = true, SHM = true, PAL = true, NEC = true }

--- Get the ordered rez spell list for a class.
---@param classShort string  EQ short class name ('CLR', 'DRU', etc.)
---@return string[]
function M.getSpells(classShort)
    return M.spells[classShort] or {}
end

--- Get the battle-rez AA name for a class, or nil if class has none.
---@param classShort string
---@return string|nil
function M.getAA(classShort)
    return M.aas[classShort]
end

--- True if the class has any rez capability.
---@param classShort string
---@return boolean
function M.isRezClass(classShort)
    return M.rezClasses[classShort] == true
end

return M
