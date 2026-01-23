local mq = require('mq')

local M = {}

local function sanitizeId(s)
    s = tostring(s or '')
    s = s:gsub('[^%w]+', ' ')
    s = s:gsub('^%s+', ''):gsub('%s+$', '')
    if s == '' then return 'Ability' end
    local out = {}
    for w in s:gmatch('%S+') do
        table.insert(out, w:sub(1, 1):upper() .. w:sub(2):lower())
    end
    return table.concat(out, '')
end

local function makeSettingKey(name)
    return 'do' .. sanitizeId(name)
end

local function encodeLua(val, indent)
    indent = indent or ''
    local t = type(val)
    if t == 'string' then
        return string.format('%q', val)
    elseif t == 'number' or t == 'boolean' then
        return tostring(val)
    elseif t == 'table' then
        local parts = { '{' }
        local nextIndent = indent .. '  '
        local isArray = true
        local maxIdx = 0
        for k, _ in pairs(val) do
            if type(k) ~= 'number' then isArray = false break end
            if k > maxIdx then maxIdx = k end
        end
        if isArray then
            for i = 1, maxIdx do
                table.insert(parts, string.format('\n%s%s,', nextIndent, encodeLua(val[i], nextIndent)))
            end
        else
            local keys = {}
            for k, _ in pairs(val) do table.insert(keys, k) end
            table.sort(keys, function(a, b) return tostring(a) < tostring(b) end)
            for _, k in ipairs(keys) do
                local keyTxt = type(k) == 'string' and string.format('[%q]', k) or string.format('[%s]', tostring(k))
                table.insert(parts, string.format('\n%s%s = %s,', nextIndent, keyTxt, encodeLua(val[k], nextIndent)))
            end
        end
        table.insert(parts, '\n' .. indent .. '}')
        return table.concat(parts)
    end
    return 'nil'
end

local function writeFile(path, contents)
    local f = assert(io.open(path, 'wb'))
    f:write(contents)
    f:close()
end

local function discover(maxId)
    maxId = tonumber(maxId) or 15000
    local out = {}

    local excludedById = {}
    local excludedByName = {}
    do
        local ok, spec = pcall(require, 'sidekick-next.utils.special_abilities')
        if ok and spec and spec.excludedAltIDs and spec.excludedNames then
            excludedById = spec.excludedAltIDs() or {}
            excludedByName = spec.excludedNames() or {}
        end
    end

    for id = 1, maxId do
        local aa = mq.TLO.AltAbility(id)
        if aa and aa() then
            -- Only include AAs this character actually has trained.
            local myAA = mq.TLO.Me and mq.TLO.Me.AltAbility and mq.TLO.Me.AltAbility(id) or nil
            if not (myAA and myAA()) then
                goto continue
            end

            -- Exclude "special abilities" (these belong in a separate window, not the settings ability list).
            local nm = aa.Name and aa.Name() or nil
            if excludedById[tonumber(id)] or (nm and excludedByName[tostring(nm):lower()]) then
                goto continue
            end

            local isPassive = false
            if aa.Passive then
                local ok, v = pcall(function() return aa.Passive() end)
                if ok and v == true then isPassive = true end
            end

            if not isPassive then
                local reuseTime = aa.MyReuseTime()
                if reuseTime and type(reuseTime) == 'number' then
                    local spellName = nil
                    local icon = 0
                    if aa.Spell and aa.Spell() then
                        spellName = aa.Spell.Name()
                        icon = aa.Spell.SpellIcon() or 0
                    end
                    table.insert(out, {
                        id = id,
                        name = aa.Name(),
                        reuseTime = reuseTime,
                        spell = spellName,
                        icon = icon,
                    })
                end
            end
        end

        ::continue::
        if (id % 200) == 0 then
            mq.delay(1)
        end
    end

    table.sort(out, function(a, b) return tostring(a.name) < tostring(b.name) end)
    return out
end

local function toAbilityDefs(discovered)
    local defs = {}
    for _, aa in ipairs(discovered or {}) do
        local settingKey = makeSettingKey(aa.name)
        table.insert(defs, {
            settingKey = settingKey,
            modeKey = settingKey .. 'Mode',
            altID = aa.id,
            altName = aa.name,
            kind = 'aa',
            icon = aa.icon or 0,
            type = 'offensive',
            visible = true,
            reuseTime = aa.reuseTime,
            spell = aa.spell,
        })
    end
    return defs
end

local function main(...)
    local args = { ... }
    local classShort = tostring(args[1] or (mq.TLO.Me.Class.ShortName and mq.TLO.Me.Class.ShortName()) or ''):upper()
    local maxId = tonumber(args[2]) or 15000

    if classShort == '' then
        mq.cmd('/echo [SideKick] Usage: /lua run aa_discovery <CLASS> [maxId]')
        return
    end

    mq.cmdf('/echo [SideKick] Discovering AAs for %s (1..%d)...', classShort, maxId)
    local discovered = discover(maxId)
    local defs = toAbilityDefs(discovered)

    local lua = {}
    table.insert(lua, string.format('return %s\n', encodeLua({ abilities = defs })))

    local outPath = mq.TLO.Lua.Dir() .. string.format('\\SideKick\\data\\classes\\%s.lua', classShort)
    writeFile(outPath, table.concat(lua))
    mq.cmdf('/echo [SideKick] Wrote %d abilities to %s', #defs, outPath)
end

M.main = main

local modname = ...
if modname == 'tools.aa_discovery' then
    return M
end

main(...)
