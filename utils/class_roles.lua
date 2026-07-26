-- utils/class_roles.lua
-- Canonical class role/category tables. One source of truth for who is a
-- tank, a pure caster, a hybrid melee, or a pure melee. Domain-specific
-- capability matrices (per-cure-type coverage, per-slow spell coverage,
-- per-taunt-ability coverage) live with their own module because they are
-- capability maps rather than flat role sets:
--   utils/aggro.lua              M.TAUNT_CLASSES (includes RNG for Taunt AA)
--   automation/cures.lua         M.CURE_CLASSES (per-cure-type matrix)
--   automation/debuff.lua        DEBUFFER_CLASSES (per-slow-line matrix)
--   utils/rez_data.lua           M.rezClasses / M.isRezClass()
--
-- Healer classification lives in utils/healer_classes.lua because it needs
-- long-name-vs-short-name normalization (isSupported accepts both). This
-- module re-exports the short-name view as HEALER_CLASSES for tight-loop
-- callers that already hold a trusted short name.

local M = {}

M.TANK_CLASSES = { WAR = true, PAL = true, SHD = true }

M.PURE_CASTERS = {
    CLR = true, DRU = true, SHM = true,
    ENC = true, WIZ = true, MAG = true, NEC = true,
}

M.HYBRID_MELEE = {
    PAL = true, SHD = true, RNG = true, BST = true, BRD = true,
}

M.PURE_MELEE = {
    WAR = true, MNK = true, ROG = true, BER = true,
}

M.HEALER_CLASSES = {
    CLR = true, DRU = true, SHM = true, PAL = true,
}

return M
