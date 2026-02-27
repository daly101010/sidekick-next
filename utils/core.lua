local mq = require('mq')
local lip = require('LIP')

local Registry = require('sidekick-next.registry')
local Paths = require('sidekick-next.utils.paths')

local _TL = nil
local function TL()
    if _TL ~= nil then return _TL end
    local ok, tl = pcall(require, 'sidekick-next.utils.throttled_log')
    if ok then _TL = tl else _TL = false end
    return _TL
end

local function debugEcho(fmt, ...)
    -- Debug logging disabled
end

local Core = {}

Core.Settings = Core.Settings or {}
Core.Ini = Core.Ini or {}

local function iniPath()
    return Paths.getMainConfigPath()
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

function Core.CanQueryItems()
    local mqTLO = mq.TLO
    if not mqTLO or not mqTLO.MacroQuest or not mqTLO.MacroQuest.GameState then
        return false
    end
    local gs = mqTLO.MacroQuest.GameState()
    if gs ~= 'INGAME' then
        return false
    end
    if mqTLO.Me and mqTLO.Me.Zoning and mqTLO.Me.Zoning() then
        return false
    end
    return true
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

    local side = Core.Ini['SideKick']
    local abil = Core.Ini['SideKick-Abilities']
    local registryKeys = {}
    local migrated = false
    local defaultsWritten = false

    -- Single pass over Registry: migrate stale keys, apply defaults, parse values
    for _, key in Registry.iter_all() do
        registryKeys[key] = true

        -- Migration: older versions wrote global settings into SideKick-Abilities
        if abil[key] ~= nil then
            if side[key] == nil then
                side[key] = abil[key]
            end
            abil[key] = nil
            migrated = true
        end

        -- Apply defaults for missing keys
        local meta = Registry.meta(key)
        if meta and side[key] == nil and meta.Default ~= nil then
            writeValue('SideKick', key, meta.Default)
            defaultsWritten = true
        end

        -- Parse value into Settings
        local raw = Core.Ini['SideKick'][key]
        if meta and meta.type == 'bool' then
            Core.Settings[key] = toBool(raw)
        elseif meta and meta.type == 'number' then
            Core.Settings[key] = tonumber(raw) or tonumber(meta.Default) or 0
        else
            Core.Settings[key] = raw
        end
    end

    -- Load dynamic (non-registry) keys from SideKick section
    for key, raw in pairs(side) do
        if not registryKeys[key] and Core.Settings[key] == nil then
            if raw == '0' or raw == '1' or raw == 'true' or raw == 'false' then
                Core.Settings[key] = toBool(raw)
            elseif tonumber(raw) then
                Core.Settings[key] = tonumber(raw)
            else
                Core.Settings[key] = raw
            end
        end
    end

    -- Only write INI back if migrations or new defaults changed data
    if migrated or defaultsWritten then
        Core.save()
    end
end

local _dirty = false
local _lastSaveAt = 0
local SAVE_DEBOUNCE_SEC = 1.0  -- Don't write INI more than once per second

function Core.save()
    local ok, err = pcall(lip.save, iniPath(), Core.Ini)
    _dirty = false
    _lastSaveAt = os.clock()
end

--- Flush pending saves if debounce period elapsed.  Call from main loop.
function Core.flush()
    if not _dirty then return end
    if (os.clock() - _lastSaveAt) < SAVE_DEBOUNCE_SEC then return end
    Core.save()
end

--- Force save immediately (for shutdown).
function Core.forceSave()
    if _dirty then Core.save() end
end

function Core.set(key, value)
    if key == nil then return end
    local k = tostring(key)

    local debug = Core.Settings and Core.Settings.SideKickDebugSettings == true
    if debug then
        local prev = Core.Settings[k]
        debugEcho('Core.set(%s): %s -> %s', k, tostring(prev), tostring(value))
    end
    Core.Settings[k] = value

    -- Ability toggles/modes/conditions always begin with "do" (e.g. doFoo, doFooMode, doFooCondition).
    -- Global settings like AssistMode/CombatMode must stay in the SideKick section.
    if k:match('^do') then
        writeValue('SideKick-Abilities', k, value)
    else
        writeValue('SideKick', k, value)
    end
    if debug then
        local sec = k:match('^do') and 'SideKick-Abilities' or 'SideKick'
        local stored = Core.Ini and Core.Ini[sec] and Core.Ini[sec][k]
        debugEcho('INI[%s].%s=%s', sec, k, tostring(stored))
    end
    _dirty = true
end

function Core.ensureSeeded(abilities, MODE)
    MODE = MODE or {}
    -- Hardcode ON_DEMAND = 1 as fallback to avoid invalid mode values (like 4)
    local ON_DEMAND_DEFAULT = MODE.ON_DEMAND or 1
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
                abilitySection[mKey] = tostring(ON_DEMAND_DEFAULT)
                dirty = true
            end
        end
    end

    for k, v in pairs(abilitySection) do
        if k:match('Mode$') then
            Core.Settings[k] = tonumber(v) or ON_DEMAND_DEFAULT
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
