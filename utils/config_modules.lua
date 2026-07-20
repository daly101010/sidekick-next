-- Compatibility routing for unregistered settings and legacy INI sections.
-- Registered settings carry an explicit `Module` owner in registry.lua; do
-- not add new key-name heuristics here.

local M = {}

M.names = {
    'main', 'ui', 'chase', 'meditation', 'assist', 'resources', 'healing',
    'cures', 'buffs', 'dps', 'combat', 'cc', 'debuff', 'spells', 'items',
    'resurrection', 'disciplines', 'integration', 'pull', 'humanize', 'abilities',
}

local CATEGORY_MODULE = {
    UI = 'ui', Bar = 'ui', Special = 'ui', Animations = 'ui',
    Buffs = 'buffs', ['Heal/Rez'] = 'healing', CC = 'cc', Debuff = 'debuff',
    Spells = 'spells', Items = 'items', Disciplines = 'disciplines',
    Integration = 'integration', Combat = 'combat',
}

function M.forKey(key, meta, section)
    key = tostring(key or '')
    if meta and meta.Module and tostring(meta.Module) ~= '' then
        return tostring(meta.Module):lower()
    end
    if section == 'SideKick-Abilities' or key:match('^do') then return 'abilities' end

    if key:match('^Meditation') or key == 'MedOn' then return 'meditation' end
    if key:match('^Chase') then return 'chase' end
    if key:match('^Assist') then return 'assist' end
    if key:match('^Resource') then return 'resources' end
    if key:match('^Rez') or key:match('^AutoRez') or key == 'AutoAcceptRez' then return 'resurrection' end
    if key:match('^Buff') or key:match('^OOC') then return 'buffs' end
    if key:match('^Heal') or key == 'DoHeals' then
        return 'healing'
    end
    if key:match('^Burn') or key:match('^DPS') then return 'dps' end

    local category = meta and meta.Category
    if category == 'Automation' then return 'main' end
    return CATEGORY_MODULE[category] or 'main'
end

function M.forSection(section)
    section = tostring(section or '')
    if section == 'SideKick' then return 'main' end
    if section == 'SideKick-Abilities' then return 'abilities' end
    if section == 'SideKick-Items' then return 'items' end
    if section == 'SideKick-Layout' or section == 'AggroWarning' then return 'ui' end
    if section == 'RemoteAbilities' then return 'integration' end
    if section:lower():find('spell', 1, true) then return 'spells' end
    return 'main'
end

return M
