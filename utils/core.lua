local mq = require('mq')
local lip = require('LIP')

local Registry = require('sidekick-next.registry')
local Paths = require('sidekick-next.utils.paths')
local ConfigModules = require('sidekick-next.utils.config_modules')
local AtomicIni = require('sidekick-next.utils.atomic_ini')

local Core = {
    Settings = {},
    Ini = {},
}

local _moduleData = {}
local _dirtyModules = {}
local _combinedBaseline = {}
local _owner = 'unknown'
local _dirty = false
local _lastSaveAt = 0
local _revision = 0
local _unregisteredSettings = {}
local _loadValidationErrors = {}
local _registryAudit = nil
local SAVE_DEBOUNCE_MS = 1000

local function copyTable(value)
    if type(value) ~= 'table' then return value end
    local result = {}
    for key, child in pairs(value) do result[key] = copyTable(child) end
    return result
end

local function valuesDiffer(a, b)
    return tostring(a) ~= tostring(b) or type(a) ~= type(b)
end

local function callerLabel(startLevel)
    for level = startLevel or 2, 12 do
        local info = debug and debug.getinfo and debug.getinfo(level, 'Sln') or nil
        if not info then break end
        local source = tostring(info.short_src or info.source or 'unknown'):gsub('\\', '/')
        if not source:find('sidekick%-next/utils/core%.lua') then
            return string.format('%s:%s', source, tostring(info.currentline or '?'))
        end
    end
    return 'unknown'
end

local function isPrimaryWriter()
    local owner = tostring(_owner or ''):gsub('\\', '/'):lower()
    return owner:find('sidekick%-next/sidekick%.lua') ~= nil
end

local function nowMs()
    if mq and mq.gettime then return mq.gettime() end
    return os.time() * 1000
end

local function toBool(v)
    if type(v) == 'boolean' then return v end
    if type(v) == 'number' then return v ~= 0 end
    if type(v) == 'string' then
        v = v:lower()
        return v == '1' or v == 'true' or v == 'yes' or v == 'on'
    end
    return false
end

local function encode(value)
    if type(value) == 'boolean' then return value and '1' or '0' end
    return tostring(value)
end

local function parseValue(raw, meta)
    if meta and meta.type == 'bool' then return toBool(raw) end
    if meta and meta.type == 'number' then return tonumber(raw) or tonumber(meta.Default) or 0 end
    return raw
end

local function moduleTable(name)
    _moduleData[name] = _moduleData[name] or { Settings = {}, Abilities = {} }
    _moduleData[name].Settings = _moduleData[name].Settings or {}
    _moduleData[name].Abilities = _moduleData[name].Abilities or {}
    return _moduleData[name]
end

local function destinationFor(key, section)
    if section ~= 'SideKick' and section ~= 'SideKick-Abilities' then
        return ConfigModules.forSection(section), section
    end
    local meta = Registry.meta(key)
    local registeredOwner = Registry.owner and select(1, Registry.owner(key)) or nil
    local moduleName = registeredOwner or ConfigModules.forKey(key, meta, section)
    local persistedSection = section == 'SideKick-Abilities' and 'Abilities' or 'Settings'
    return moduleName, persistedSection
end

local function setPersisted(key, value, section, markDirty)
    local moduleName, persistedSection = destinationFor(key, section)
    local data = moduleTable(moduleName)
    data[persistedSection] = data[persistedSection] or {}
    data[persistedSection][key] = value
    if markDirty then _dirtyModules[moduleName] = true end
end

local function appendAudit(entries, caller)
    if #entries == 0 then return end
    local path = Paths.getModuleConfigDir() .. '/settings-audit.log'
    local file = io.open(path, 'a')
    if not file then return end
    file:write(string.format('%s mqms=%s owner=%s caller=%s %s\n', os.date('%Y-%m-%d %H:%M:%S'),
        tostring(nowMs()), tostring(_owner), tostring(caller), table.concat(entries, '; ')))
    file:close()
end

function Core.CanQueryItems()
    local tlo = mq.TLO
    if not tlo or not tlo.MacroQuest or not tlo.MacroQuest.GameState then return false end
    if tlo.MacroQuest.GameState() ~= 'INGAME' then return false end
    return not (tlo.Me and tlo.Me.Zoning and tlo.Me.Zoning())
end

local function loadModuleFiles()
    _moduleData = {}
    for _, name in ipairs(ConfigModules.names) do
        local path = Paths.getModuleConfigPath(name)
        local data, loadedFrom = AtomicIni.load(path)
        _moduleData[name] = type(data) == 'table' and data or {}
        moduleTable(name)
        if loadedFrom and loadedFrom ~= path then _dirtyModules[name] = true end
    end
end

-- CombatMode is now the sole assist on/off control. Capture the two retired
-- split-assist values before tombstone filtering, remove them from every
-- module file, and return their last-writer values for one-time migration.
local function retireSplitAssistSettings()
    local legacyEnabled = nil
    local legacyEngageHp = nil
    for _, name in ipairs(ConfigModules.names) do
        local data = moduleTable(name)
        for _, sectionName in ipairs({ 'Settings', 'SideKick' }) do
            local settings = data[sectionName]
            if type(settings) == 'table' then
                if settings.AssistEnabled ~= nil then
                    legacyEnabled = settings.AssistEnabled
                    settings.AssistEnabled = nil
                    _dirtyModules[name] = true
                end
                if settings.AssistEngageHpThreshold ~= nil then
                    legacyEngageHp = settings.AssistEngageHpThreshold
                    settings.AssistEngageHpThreshold = nil
                    _dirtyModules[name] = true
                end
            end
        end
    end
    return legacyEnabled, legacyEngageHp
end

-- Move every registered setting to its one authoritative module before the
-- files are overlaid. This removes the old "last file wins" behavior and
-- turns prior heuristic routing into a one-time migration.
local function canonicalizeModuleSettings()
    for _, sourceName in ipairs(ConfigModules.names) do
        local source = moduleTable(sourceName)
        local settings = source.Settings or {}
        local keys = {}
        for key in pairs(settings) do keys[#keys + 1] = key end
        for _, key in ipairs(keys) do
            local owner = Registry.owner and select(1, Registry.owner(key)) or nil
            if owner and owner ~= sourceName then
                local target = moduleTable(owner)
                target.Settings = target.Settings or {}
                if target.Settings[key] == nil then
                    target.Settings[key] = settings[key]
                    _dirtyModules[owner] = true
                end
                settings[key] = nil
                _dirtyModules[sourceName] = true
            end
        end
    end
end

local function overlayModuleFiles()
    for _, name in ipairs(ConfigModules.names) do
        local data = moduleTable(name)
        for section, values in pairs(data) do
            if type(values) == 'table' then
                local targetSection = section == 'Settings' and 'SideKick'
                    or (section == 'Abilities' and 'SideKick-Abilities' or section)
                Core.Ini[targetSection] = Core.Ini[targetSection] or {}
                for key, value in pairs(values) do
                    if targetSection ~= 'SideKick' or not Registry.is_removed(key) then
                        Core.Ini[targetSection][key] = value
                    end
                end
            end
        end
    end
end

function Core.load()
    _owner = callerLabel(3)
    _dirtyModules = {}
    _dirty = false
    _unregisteredSettings = {}
    _loadValidationErrors = {}
    _registryAudit = Registry.audit and Registry.audit() or nil
    Core.Settings = {}
    if _revision == 0 then _revision = 1 end

    -- The combined file is now migration input only. Paths repairs a zero-byte
    -- legacy copy from production before this read.
    local legacyPath = Paths.getMainConfigPath()
    local ok, legacy = pcall(lip.load, legacyPath)
    Core.Ini = ok and type(legacy) == 'table' and legacy or {}
    Core.Ini['SideKick'] = Core.Ini['SideKick'] or {}
    Core.Ini['SideKick-Abilities'] = Core.Ini['SideKick-Abilities'] or {}

    loadModuleFiles()
    local legacyAssistEnabled, legacyAssistEngageHp = retireSplitAssistSettings()
    canonicalizeModuleSettings()
    overlayModuleFiles()

    local side = Core.Ini['SideKick']
    local abilities = Core.Ini['SideKick-Abilities']
    local registryKeys = {}

    if legacyAssistEnabled == nil then legacyAssistEnabled = side.AssistEnabled end
    if legacyAssistEngageHp == nil then legacyAssistEngageHp = side.AssistEngageHpThreshold end

    -- Preserve the effective behavior of existing characters while collapsing
    -- the old two-switch UI onto CombatMode and the old dual HP sliders onto
    -- AssistAt. Registered-setting persistence below writes the migrated values
    -- to their authoritative module files.
    if toBool(legacyAssistEnabled) and tostring(side.CombatMode or 'off'):lower() == 'off' then
        side.CombatMode = 'assist'
    end
    if legacyAssistEngageHp ~= nil then
        side.AssistAt = legacyAssistEngageHp
    end

    for _, key in Registry.iter_all() do
        registryKeys[key] = true
        local meta = Registry.meta(key)

        if abilities[key] ~= nil and side[key] == nil then side[key] = abilities[key] end
        abilities[key] = nil

        local raw = side[key]
        if raw == nil and meta and meta.Default ~= nil then raw = encode(meta.Default) end
        local valid, normalized, validationError = Registry.normalize(key, raw)
        if not valid then
            normalized = meta and meta.Default or raw
            _loadValidationErrors[key] = validationError or 'invalid value'
        end
        local encoded = encode(normalized)
        side[key] = encoded
        Core.Settings[key] = normalized

        local moduleName, persistedSection = destinationFor(key, 'SideKick')
        local data = moduleTable(moduleName)
        if data[persistedSection][key] == nil or valuesDiffer(data[persistedSection][key], encoded) then
            data[persistedSection][key] = encoded
            _dirtyModules[moduleName] = true
        end
    end

    -- Tombstoned options may still exist in migration-source files. Remove
    -- them from the runtime snapshot so UI/debug consumers cannot mistake
    -- their old values for supported behavior.
    for key in pairs(Registry.removed or {}) do side[key] = nil end

    -- Preserve and migrate dynamic global keys.
    for key, raw in pairs(side) do
        if not registryKeys[key] and not Registry.is_removed(key) then
            local registrationKind = 'unregistered'
            if Registry.owner then
                local _, kind = Registry.owner(key)
                registrationKind = kind or registrationKind
            end
            if registrationKind == 'unregistered' then
                _unregisteredSettings[key] = 'SideKick'
            end
            if raw == '0' or raw == '1' or raw == 'true' or raw == 'false' then
                Core.Settings[key] = toBool(raw)
            elseif tonumber(raw) then
                Core.Settings[key] = tonumber(raw)
            else
                Core.Settings[key] = raw
            end
            local moduleName, persistedSection = destinationFor(key, 'SideKick')
            local data = moduleTable(moduleName)
            if data[persistedSection][key] == nil then
                data[persistedSection][key] = raw
                _dirtyModules[moduleName] = true
            end
        end
    end

    -- Ability settings are isolated from all global/module settings.
    local abilityData = moduleTable('abilities').Abilities
    for key, raw in pairs(abilities) do
        if abilityData[key] == nil then
            abilityData[key] = raw
            _dirtyModules.abilities = true
        end
    end
    for key, raw in pairs(abilityData) do abilities[key] = raw end

    -- Migrate arbitrary compatibility sections (layouts, item conditions,
    -- remote abilities, spell-set metadata) to their owning module file.
    for section, values in pairs(Core.Ini) do
        if section ~= 'SideKick' and section ~= 'SideKick-Abilities' and type(values) == 'table' then
            local moduleName = ConfigModules.forSection(section)
            local data = moduleTable(moduleName)
            data[section] = data[section] or {}
            for key, raw in pairs(values) do
                if data[section][key] == nil then
                    data[section][key] = raw
                    _dirtyModules[moduleName] = true
                end
            end
        end
    end

    _combinedBaseline = copyTable(Core.Ini)
    if isPrimaryWriter() and _registryAudit and _registryAudit.ok == false then
        print(string.format('\ar[SideKick Settings]\ax Registry audit failed with %d error(s). Use /sk config audit.',
            #(_registryAudit.errors or {})))
    end
    if isPrimaryWriter() and next(_loadValidationErrors) then
        local count = 0
        for _ in pairs(_loadValidationErrors) do count = count + 1 end
        print(string.format('\ay[SideKick Settings]\ax Replaced %d invalid persisted value(s) with schema defaults. Use /sk config audit.', count))
    end
    if next(_dirtyModules) then Core.save() end
end

local function captureDirectChanges()
    local sections = {}
    for section in pairs(Core.Ini) do sections[section] = true end
    for section in pairs(_combinedBaseline) do sections[section] = true end
    for section in pairs(sections) do
        local current = Core.Ini[section] or {}
        local baseline = _combinedBaseline[section] or {}
        local keys = {}
        for key in pairs(current) do keys[key] = true end
        for key in pairs(baseline) do keys[key] = true end
        for key in pairs(keys) do
            if valuesDiffer(current[key], baseline[key]) then
                setPersisted(key, current[key], section, true)
            end
        end
    end
end

function Core.save()
    if not isPrimaryWriter() then
        _dirty = false
        _dirtyModules = {}
        return false, 'non_primary_writer'
    end

    captureDirectChanges()
    local caller = callerLabel(3)
    local audit = {}
    local allOk = true
    local firstError = nil
    local wroteAny = false

    for _, name in ipairs(ConfigModules.names) do
        if _dirtyModules[name] then
            local path = Paths.getModuleConfigPath(name)
            local ok, err = AtomicIni.save(path, moduleTable(name))
            if ok then
                wroteAny = true
                if name == 'meditation' or name == 'chase' then
                    audit[#audit + 1] = string.format('%s saved=%s', name, path:gsub('\\', '/'))
                end
                _dirtyModules[name] = nil
            else
                allOk = false
                firstError = firstError or string.format('%s: %s', name, tostring(err))
            end
        end
    end

    _lastSaveAt = nowMs()
    _dirty = not allOk or next(_dirtyModules) ~= nil
    -- Publish only committed disk state. Incrementing in Core.set() allowed a
    -- worker to observe the revision during the save debounce and reload the
    -- old file, then miss the eventual write because the revision stayed put.
    if allOk and wroteAny then _revision = _revision + 1 end
    if allOk then _combinedBaseline = copyTable(Core.Ini) end
    appendAudit(audit, caller)

    if not allOk then
        print(string.format('\ar[SideKick]\ax Failed to save module settings: %s', tostring(firstError)))
    end
    return allOk, firstError
end

function Core.flush()
    if not _dirty then return end
    if (nowMs() - _lastSaveAt) < SAVE_DEBOUNCE_MS then return end
    Core.save()
end

function Core.forceSave()
    return Core.save()
end

function Core.setMany(changes, opts)
    if type(changes) ~= 'table' then return false, 'changes must be a table' end
    opts = opts or {}

    -- Validate the entire batch before mutating anything.
    local prepared = {}
    for key, value in pairs(changes) do
        local k = Registry.resolveKey and Registry.resolveKey(key) or tostring(key or '')
        local valid, normalized, validationError = Registry.normalize(k, value)
        if not valid then return false, validationError end
        local owner, registrationKind = Registry.owner(k)
        prepared[#prepared + 1] = {
            key = k,
            value = normalized,
            owner = owner,
            registrationKind = registrationKind,
        }
    end

    for _, change in ipairs(prepared) do
        local k = change.key
        local oldValue = Core.Settings[k]
        local section = change.owner == 'abilities' and 'SideKick-Abilities' or 'SideKick'
        local encoded = encode(change.value)
        Core.Settings[k] = change.value
        Core.Ini[section] = Core.Ini[section] or {}
        Core.Ini[section][k] = encoded
        setPersisted(k, encoded, section, true)
        if change.registrationKind == 'unregistered' then
            _unregisteredSettings[k] = section
        end
        if valuesDiffer(oldValue, change.value) and Registry.notifyChanged then
            Registry.notifyChanged(k, change.value, oldValue, opts.source or callerLabel(3))
        end
    end

    if #prepared > 0 then _dirty = true end
    if opts.save == true then
        local ok, err = Core.save()
        if not ok then return false, err end
    end
    return true
end

function Core.set(key, value, opts)
    if key == nil then return false, 'setting key is required' end
    return Core.setMany({ [tostring(key)] = value }, opts)
end

function Core.getRevision()
    return _revision
end

function Core.getRegistryDiagnostics()
    local unknown = {}
    for key, section in pairs(_unregisteredSettings) do
        unknown[#unknown + 1] = { key = key, section = section }
    end
    table.sort(unknown, function(a, b) return a.key < b.key end)

    local invalid = {}
    for key, reason in pairs(_loadValidationErrors) do
        invalid[#invalid + 1] = { key = key, reason = reason }
    end
    table.sort(invalid, function(a, b) return a.key < b.key end)

    return {
        registry = _registryAudit or (Registry.audit and Registry.audit()) or {},
        unregistered = unknown,
        invalid = invalid,
    }
end

function Core.ensureSeeded(abilities, MODE)
    MODE = MODE or {}
    local defaultMode = MODE.ON_DEMAND or 1
    Core.Ini['SideKick-Abilities'] = Core.Ini['SideKick-Abilities'] or {}
    local section = Core.Ini['SideKick-Abilities']
    local changed = false

    for _, def in ipairs(abilities or {}) do
        if type(def) == 'table' then
            if def.settingKey and section[def.settingKey] == nil then
                section[def.settingKey] = '0'
                changed = true
            end
            if def.modeKey and section[def.modeKey] == nil then
                section[def.modeKey] = tostring(defaultMode)
                changed = true
            end
        end
    end

    for key, raw in pairs(section) do
        if key:match('Mode$') then
            Core.Settings[key] = tonumber(raw) or defaultMode
        elseif key:match('Condition$') then
            if raw and raw ~= '' and raw ~= '0' and raw ~= 'false' then
                local fn = load('return ' .. tostring(raw), 'condition', 't', {})
                if fn then
                    local ok, value = pcall(fn)
                    Core.Settings[key] = ok and type(value) == 'table' and value or nil
                else
                    Core.Settings[key] = nil
                end
            else
                Core.Settings[key] = nil
            end
        elseif key:match('Context$') then
            Core.Settings[key] = tonumber(raw) or 1
        elseif key:match('Layer$') then
            Core.Settings[key] = tostring(raw or '')
        else
            Core.Settings[key] = toBool(raw)
        end
    end

    if changed then
        _dirty = true
        captureDirectChanges()
        Core.save()
    end
end

function Core.getModuleConfigPath(name)
    return Paths.getModuleConfigPath(name)
end

return Core
