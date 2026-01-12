local mq = require('mq')
local lip = require('LIP')

local Registry = require('registry')

local Core = {}

Core.Settings = Core.Settings or {}
Core.Ini = Core.Ini or {}

local function iniPath()
    local server = (mq.TLO.EverQuest and mq.TLO.EverQuest.Server and mq.TLO.EverQuest.Server()) or 'Server'
    local name = (mq.TLO.Me and mq.TLO.Me.CleanName and mq.TLO.Me.CleanName()) or 'Character'
    return mq.configDir .. '\\' .. server .. '_' .. name .. '_SideKick.ini'
end

local function toBool(v)
    local t = type(v)
    if t == 'boolean' then return v end
    if t == 'number' then return v ~= 0 end
    if t == 'string' then
        v = v:lower()
        return (v == '1' or v == 'true' or v == 'yes' or v == 'on')
    end
    return false
end

local function writeValue(section, key, value)
    Core.Ini[section] = Core.Ini[section] or {}
    if type(value) == 'boolean' then
        Core.Ini[section][key] = value and '1' or '0'
    else
        Core.Ini[section][key] = tostring(value)
    end
end

local function readSection(section)
    return Core.Ini[section] or {}
end

function Core.load()
    local path = iniPath()
    do
        local ok, res = pcall(lip.load, path)
        if ok and type(res) == 'table' then
            Core.Ini = res
        else
            Core.Ini = {}
        end
    end
    Core.Ini['SideKick'] = Core.Ini['SideKick'] or {}
    Core.Ini['SideKick-Abilities'] = Core.Ini['SideKick-Abilities'] or {}

    -- Migration: older versions incorrectly wrote some global Registry settings
    -- (e.g. AssistMode/CombatMode) into the SideKick-Abilities section because they end with "Mode".
    do
        local side = Core.Ini['SideKick']
        local abil = Core.Ini['SideKick-Abilities']
        for _, key in Registry.iter_all() do
            if abil[key] ~= nil then
                if side[key] == nil then
                    side[key] = abil[key]
                end
                abil[key] = nil
            end
        end
        Core.Ini['SideKick'] = side
        Core.Ini['SideKick-Abilities'] = abil
    end

    for _, key in Registry.iter_all() do
        local meta = Registry.meta(key)
        if meta and Core.Ini['SideKick'][key] == nil and meta.Default ~= nil then
            writeValue('SideKick', key, meta.Default)
        end
        local raw = Core.Ini['SideKick'][key]
        if meta and meta.type == 'bool' then
            Core.Settings[key] = toBool(raw)
        elseif meta and meta.type == 'number' then
            Core.Settings[key] = tonumber(raw) or tonumber(meta.Default) or 0
        else
            Core.Settings[key] = raw
        end
    end

    -- Also load any non-registry keys from SideKick section (e.g., class config settings)
    -- These are dynamic settings like DoMez, DoSlow, SpellLoadout that come from class configs
    local registryKeys = {}
    for _, key in Registry.iter_all() do
        registryKeys[key] = true
    end
    for key, raw in pairs(Core.Ini['SideKick'] or {}) do
        if not registryKeys[key] and Core.Settings[key] == nil then
            -- Infer type from value
            if raw == '0' or raw == '1' or raw == 'true' or raw == 'false' then
                Core.Settings[key] = toBool(raw)
            elseif tonumber(raw) then
                Core.Settings[key] = tonumber(raw)
            else
                Core.Settings[key] = raw
            end
        end
    end

    Core.save()
end

function Core.save()
    local ok, err = pcall(lip.save, iniPath(), Core.Ini)
    if not ok then
        if mq and mq.cmdf then
            mq.cmdf('/echo [SideKick] INI save failed: %s', tostring(err))
        elseif mq and mq.cmd then
            mq.cmd('/echo [SideKick] INI save failed: ' .. tostring(err))
        end
    end
end

function Core.set(key, value)
    if key == nil then return end
    local k = tostring(key)
    Core.Settings[k] = value
    -- Ability toggles/modes/conditions always begin with "do" (e.g. doFoo, doFooMode, doFooCondition).
    -- Global settings like AssistMode/CombatMode must stay in the SideKick section.
    if k:match('^do') then
        writeValue('SideKick-Abilities', k, value)
    else
        writeValue('SideKick', k, value)
    end
    Core.save()
end

function Core.ensureSeeded(abilities, MODE)
    MODE = MODE or {}
    Core.Ini['SideKick'] = Core.Ini['SideKick'] or {}
    Core.Ini['SideKick-Abilities'] = Core.Ini['SideKick-Abilities'] or {}

    local abilitySection = readSection('SideKick-Abilities')
    local dirty = false

    for _, def in ipairs(abilities or {}) do
        if type(def) == 'table' then
            local tKey = def.settingKey
            local mKey = def.modeKey
            if tKey and abilitySection[tKey] == nil then
                abilitySection[tKey] = '0'
                dirty = true
            end
            if mKey and abilitySection[mKey] == nil then
                abilitySection[mKey] = tostring(MODE.ON_DEMAND or 4)
                dirty = true
            end
        end
    end

    for k, v in pairs(abilitySection) do
        if k:match('Mode$') then
            Core.Settings[k] = tonumber(v) or (MODE.ON_DEMAND or 4)
        elseif k:match('Condition$') then
            -- Preserve condition data as deserialized table (not boolean)
            if v and v ~= '' and v ~= '0' and v ~= 'false' then
                local fn, err = load("return " .. tostring(v), "condition", "t", {})
                if fn then
                    local ok, data = pcall(fn)
                    if ok and type(data) == 'table' then
                        Core.Settings[k] = data
                    else
                        Core.Settings[k] = nil  -- Invalid, clear it
                    end
                else
                    Core.Settings[k] = nil  -- Parse error, clear it
                end
            else
                Core.Settings[k] = nil  -- Empty/false, no condition set
            end
        elseif k:match('Layer$') then
            -- Layer metadata is a string (e.g. auto/emergency/aggro/defenses/burn/combat/utility)
            Core.Settings[k] = tostring(v or '')
        else
            Core.Settings[k] = toBool(v)
        end
    end

    Core.Ini['SideKick-Abilities'] = abilitySection
    if dirty then
        Core.save()
    end
end

return Core
