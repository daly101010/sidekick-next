local mq = require('mq')

local function sanitizeId(s)
    s = tostring(s or ''):gsub('%W', ' ')
    s = s:gsub('^%s+', ''):gsub('%s+$', '')
    if s == '' then return 'Disc' end
    local t = {}
    for w in s:gmatch('%S+') do
        table.insert(t, w:sub(1, 1):upper() .. w:sub(2):lower())
    end
    return table.concat(t, '')
end

local function discDef(d)
    local name = tostring(d.name or '')
    local key = 'doDisc' .. sanitizeId(name)
    local icon = 0
    local sp = mq.TLO.Spell(name)
    if sp and sp() and sp.SpellIcon then icon = sp.SpellIcon() or 0 end
    return {
        settingKey = key,
        modeKey = key .. 'Mode',
        kind = 'disc',
        discName = name,
        altName = name,
        icon = icon,
        type = 'offensive',
        visible = true,
        level = tonumber(d.level) or 0,
        timer = (d.timer ~= nil) and tonumber(d.timer) or nil,
        description = tostring(d.desc or ''),
    }
end

-- Source: `data.disciplines.BER_data` (RaidLoot Berserker Timer_01..Timer_22 pages at level 130)
local DISCS = require('data.disciplines.BER_data')

local defs = {}
for _, d in ipairs(DISCS) do
    table.insert(defs, discDef(d))
end

return { disciplines = defs }
