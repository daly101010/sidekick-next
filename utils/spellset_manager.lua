-- F:/lua/sidekick/utils/spellset_manager.lua
-- Spell Set Manager - Handles spell loadout detection, switching, and custom user loadouts
-- Implements "Option A" - Automatic Detection Mode:
--   When user manually forgets a spell, system detects the change
--   Current loadout switches to "(Custom)" indicator
--   User can "Save As" to preserve changes as a named loadout

local mq = require('mq')

local M = {}

-- State tracking
M.currentLoadout = nil      -- Name of active loadout (or nil if no loadout selected)
M.isCustomMode = false      -- True if user made manual changes
M.lastGems = {}             -- Last known spell gems for change detection {[gem] = spellName}
M.customLoadouts = {}       -- User-saved custom loadouts {[name] = {gems = {[gem] = spellName}, description = ""}}
M.initialized = false       -- Has init() been called
M.detectionEnabled = true   -- Whether to auto-detect manual spell changes
M.lastCheckTime = 0         -- Last time we checked for changes (throttle)
M.checkInterval = 0.5       -- How often to check for changes (seconds)
M.builtInLoadouts = {}      -- Cache of built-in loadouts from class_configs
M.loadoutModified = {}      -- Track which built-in loadouts have INI modifications {[name] = true}

-- Async apply state (for non-blocking memorization)
M._applyState = nil         -- {loadoutName, gems, gemList, currentIdx, lastMemTime, waitingForMem}

-- Runtime settings sync state (keep Core.Settings aligned to current loadout toggles)
M._lastSettingsSync = { loadoutName = nil, at = 0 }

-- Spell Set state (for new Spell Set Editor)
M.spellSets = {}           -- {[name] = SpellSet}
M.activeSetName = nil      -- Name of currently active spell set
M.pendingApply = nil       -- Queued set to apply when OOC
M.lastCapacityCheck = 0    -- Throttle capacity updates
M.rotationCapacity = 12    -- NumGems - 1, updated periodically

-- Lazy-load dependencies
local _Core = nil
local function getCore()
    if not _Core then
        local ok, c = pcall(require, 'utils.core')
        if ok then _Core = c end
    end
    return _Core
end

local _GemManager = nil
local function getGemManager()
    if not _GemManager then
        local ok, gm = pcall(require, 'utils.gem_manager')
        if ok then _GemManager = gm end
    end
    return _GemManager
end

local _ClassConfigLoader = nil
local function getClassConfigLoader()
    if not _ClassConfigLoader then
        local ok, ccl = pcall(require, 'utils.class_config_loader')
        if ok then _ClassConfigLoader = ccl end
    end
    return _ClassConfigLoader
end

-- Lazy-load spell database (for spell set editor)
local _SpellsClr = nil
local function getSpellsClr()
    if not _SpellsClr then
        local ok, s = pcall(require, 'sk_spells_clr')
        if ok then _SpellsClr = s end
    end
    return _SpellsClr
end

-- Lazy-load condition builder (for spell set editor)
local _ConditionBuilder = nil
local function getConditionBuilder()
    if not _ConditionBuilder then
        local ok, cb = pcall(require, 'ui.condition_builder')
        if ok then _ConditionBuilder = cb end
    end
    return _ConditionBuilder
end

-- INI section for custom loadouts
local LOADOUT_SECTION = 'SideKick-SpellLoadouts'

--- Get class short name
local function getClassShort()
    local me = mq.TLO.Me
    if not me or not me() then return nil end
    local class = me.Class
    if not class or not class() then return nil end
    return class.ShortName()
end

--- Get number of spell gems
local function getNumGems()
    local me = mq.TLO.Me
    if not me or not me() then return 0 end
    return tonumber(me.NumGems()) or 0
end

--- Get number of rotation gems (NumGems - 1, reserving last for buff rotation)
local function getRotationGems()
    local numGems = getNumGems()
    if numGems <= 1 then return 0 end
    return numGems - 1
end

--- Serialize a gem table to string for INI storage
-- Format: "1:SpellName|2:SpellName|..."
local function serializeGems(gems)
    local parts = {}
    for gem, spellName in pairs(gems or {}) do
        if spellName and spellName ~= '' then
            table.insert(parts, string.format('%d:%s', gem, spellName))
        end
    end
    table.sort(parts)
    return table.concat(parts, '|')
end

--- Deserialize a gem string from INI
local function deserializeGems(str)
    local gems = {}
    if not str or str == '' then return gems end

    for part in string.gmatch(str, '[^|]+') do
        local gem, spellName = part:match('^(%d+):(.+)$')
        if gem and spellName then
            gems[tonumber(gem)] = spellName
        end
    end
    return gems
end

--- Serialize a CSV list
local function serializeCSV(list)
    if not list or #list == 0 then return '' end
    return table.concat(list, ',')
end

--- Deserialize a CSV list
local function deserializeCSV(str)
    local list = {}
    if not str or str == '' then return list end
    for item in string.gmatch(str, '[^,]+') do
        local trimmed = item:match('^%s*(.-)%s*$')
        if trimmed and trimmed ~= '' then
            table.insert(list, trimmed)
        end
    end
    return list
end

--- Load built-in loadouts from class_configs
local function loadBuiltInLoadouts()
    local classShort = getClassShort()
    if not classShort then return end

    M.builtInLoadouts = {}

    local ClassConfigLoader = getClassConfigLoader()
    if not ClassConfigLoader then return end

    -- Load the class config
    local config = ClassConfigLoader.load(classShort)
    if not config then return end

    -- Get spell loadouts from class config
    local loadouts = ClassConfigLoader.getSpellLoadouts(config)
    if not loadouts or not next(loadouts) then return end

    -- Convert to our format with resolved spells
    for loadoutKey, loadoutData in pairs(loadouts) do
        local resolved = ClassConfigLoader.resolveLoadout(loadoutKey, config)
        if resolved and next(resolved) then
            local displayName = loadoutData.name or loadoutKey
            M.builtInLoadouts[loadoutKey] = {
                gems = resolved,
                description = loadoutData.description or displayName,
                isBuiltIn = true,
                -- Store original gem assignments for reset capability
                _originalGemSets = loadoutData.gems,
            }
        end
    end
end

--- Load user overrides for built-in loadouts from INI
-- Format: <loadout>_modified=1, <loadout>_enabled=DoMez,DoSlow, etc.
local function loadUserOverrides()
    local Core = getCore()
    if not Core or not Core.Ini then return end

    M.loadoutModified = {}

    local section = Core.Ini[LOADOUT_SECTION]
    if not section then return end

    -- Scan for modified built-in loadouts
    for loadoutName, loadout in pairs(M.builtInLoadouts) do
        local modifiedKey = loadoutName .. '_modified'
        if section[modifiedKey] == '1' then
            M.loadoutModified[loadoutName] = true

            -- Apply enabled overrides
            local enabledKey = loadoutName .. '_enabled'
            local enabledStr = section[enabledKey]
            if enabledStr and enabledStr ~= '' then
                loadout.enabledOverrides = deserializeCSV(enabledStr)
            end

            -- Apply disabled overrides
            local disabledKey = loadoutName .. '_disabled'
            local disabledStr = section[disabledKey]
            if disabledStr and disabledStr ~= '' then
                loadout.disabledOverrides = deserializeCSV(disabledStr)
            end

            -- Apply layer overrides (format: setting:layer,setting:layer)
            local layerOverridesKey = loadoutName .. '_layerOverrides'
            local layerOverridesStr = section[layerOverridesKey]
            if layerOverridesStr and layerOverridesStr ~= '' then
                loadout.layerOverrides = {}
                for pair in string.gmatch(layerOverridesStr, '[^,]+') do
                    local setting, layer = pair:match('^([^:]+):(.+)$')
                    if setting and layer then
                        loadout.layerOverrides[setting] = layer
                    end
                end
            end

            -- Apply layer order overrides (format: <loadout>_layerOrder_<layer>=ability1,ability2)
            loadout.layerOrderOverrides = {}
            for key, value in pairs(section) do
                local keyLoadout, layer = key:match('^(.+)_layerOrder_(.+)$')
                if keyLoadout == loadoutName and layer and value and value ~= '' then
                    loadout.layerOrderOverrides[layer] = deserializeCSV(value)
                end
            end

            -- Apply condition overrides (format: <loadout>_conditionOverrides=setting:serialized_data)
            local condOverridesKey = loadoutName .. '_conditionOverrides'
            local condOverridesStr = section[condOverridesKey]
            if condOverridesStr and condOverridesStr ~= '' then
                loadout.conditionOverrides = {}
                for pair in string.gmatch(condOverridesStr, '[^;]+') do
                    local setting, data = pair:match('^([^:]+):(.+)$')
                    if setting and data then
                        loadout.conditionOverrides[setting] = data
                    end
                end
            end

            -- Apply gem overrides (user modified which spells go in which gems)
            local gemsKey = loadoutName .. '_gems'
            local gemsStr = section[gemsKey]
            if gemsStr and gemsStr ~= '' then
                local overrideGems = deserializeGems(gemsStr)
                if next(overrideGems) then
                    -- Merge overrides with base loadout gems
                    for gem, spell in pairs(overrideGems) do
                        loadout.gems[gem] = spell
                    end
                end
            end
        end
    end
end

--- Load custom loadouts from INI (user-created loadouts)
local function loadCustomLoadouts()
    local Core = getCore()
    if not Core or not Core.Ini then return end

    M.customLoadouts = {}

    local section = Core.Ini[LOADOUT_SECTION]
    if not section then return end

    -- Parse entries for custom_ prefix loadouts
    local customData = {}
    for key, value in pairs(section) do
        -- New format: custom_<safename>_<property>
        local safeName, prop = key:match('^custom_([^_]+)_(.+)$')
        if safeName and prop then
            if not customData[safeName] then
                customData[safeName] = {}
            end
            if prop == 'name' then
                customData[safeName].displayName = value
            elseif prop == 'gems' then
                customData[safeName].gems = deserializeGems(value)
            elseif prop == 'desc' then
                customData[safeName].description = value
            elseif prop == 'baseLoadout' then
                customData[safeName].baseLoadout = value
            elseif prop == 'enabled' then
                customData[safeName].enabled = deserializeCSV(value)
            elseif prop == 'disabled' then
                customData[safeName].disabled = deserializeCSV(value)
            elseif prop == 'layerOverrides' then
                customData[safeName].layerOverrides = {}
                for pair in string.gmatch(value, '[^,]+') do
                    local setting, layer = pair:match('^([^:]+):(.+)$')
                    if setting and layer then
                        customData[safeName].layerOverrides[setting] = layer
                    end
                end
            elseif prop:match('^layerOrder_') then
                local layer = prop:match('^layerOrder_(.+)$')
                if layer then
                    customData[safeName].layerOrderOverrides = customData[safeName].layerOrderOverrides or {}
                    customData[safeName].layerOrderOverrides[layer] = deserializeCSV(value)
                end
            end
        end
    end

    -- Also support legacy format: name_gems and name_desc
    local legacyData = {}
    for key, value in pairs(section) do
        -- Skip custom_ prefix entries (handled above)
        if not key:match('^custom_') and not key:match('^_') then
            local name, suffix = key:match('^(.+)_([^_]+)$')
            if name and suffix and not M.builtInLoadouts[name] then
                if not legacyData[name] then
                    legacyData[name] = {}
                end
                if suffix == 'gems' then
                    legacyData[name].gems = deserializeGems(value)
                elseif suffix == 'desc' then
                    legacyData[name].description = value
                end
            end
        end
    end

    -- Build custom loadout entries from new format
    for safeName, data in pairs(customData) do
        if data.gems and next(data.gems) then
            local displayName = data.displayName or safeName
            M.customLoadouts[displayName] = {
                gems = data.gems,
                description = data.description or '',
                isBuiltIn = false,
                baseLoadout = data.baseLoadout,
                enabledOverrides = data.enabled,
                disabledOverrides = data.disabled,
                layerOverrides = data.layerOverrides,
                layerOrderOverrides = data.layerOrderOverrides,
                _safeName = safeName,
            }
        end
    end

    -- Build custom loadout entries from legacy format
    for name, data in pairs(legacyData) do
        if data.gems and next(data.gems) and not M.customLoadouts[name] then
            M.customLoadouts[name] = {
                gems = data.gems,
                description = data.description or '',
                isBuiltIn = false,
            }
        end
    end
end

--- Generate a safe name for INI keys (alphanumeric + dash)
local function makeSafeName(name)
    return name:gsub('[^%w%-]', '-'):gsub('%-+', '-'):gsub('^%-', ''):gsub('%-$', '')
end

--- Save custom loadouts to INI
local function saveCustomLoadouts()
    local Core = getCore()
    if not Core or not Core.Ini then return end

    -- Get existing section to preserve built-in modifications
    local section = Core.Ini[LOADOUT_SECTION] or {}

    -- Clear only custom_ entries
    for key in pairs(section) do
        if key:match('^custom_') then
            section[key] = nil
        end
    end

    -- Also clear legacy format entries for non-built-in loadouts
    for key in pairs(section) do
        local name = key:match('^(.+)_gems$') or key:match('^(.+)_desc$')
        if name and not M.builtInLoadouts[name] and not key:match('^_') then
            section[key] = nil
        end
    end

    -- Save each custom loadout with custom_ prefix
    for displayName, loadout in pairs(M.customLoadouts) do
        if not loadout.isBuiltIn then
            local safeName = loadout._safeName or makeSafeName(displayName)

            section['custom_' .. safeName .. '_name'] = displayName
            section['custom_' .. safeName .. '_gems'] = serializeGems(loadout.gems)
            if loadout.description and loadout.description ~= '' then
                section['custom_' .. safeName .. '_desc'] = loadout.description
            end
            if loadout.baseLoadout then
                section['custom_' .. safeName .. '_baseLoadout'] = loadout.baseLoadout
            end
            if loadout.enabledOverrides and #loadout.enabledOverrides > 0 then
                section['custom_' .. safeName .. '_enabled'] = serializeCSV(loadout.enabledOverrides)
            end
            if loadout.disabledOverrides and #loadout.disabledOverrides > 0 then
                section['custom_' .. safeName .. '_disabled'] = serializeCSV(loadout.disabledOverrides)
            end
            if loadout.layerOverrides and next(loadout.layerOverrides) then
                local pairs_list = {}
                for setting, layer in pairs(loadout.layerOverrides) do
                    table.insert(pairs_list, setting .. ':' .. layer)
                end
                section['custom_' .. safeName .. '_layerOverrides'] = table.concat(pairs_list, ',')
            end
            if loadout.layerOrderOverrides then
                for layer, order in pairs(loadout.layerOrderOverrides) do
                    section['custom_' .. safeName .. '_layerOrder_' .. layer] = serializeCSV(order)
                end
            end
        end
    end

    Core.Ini[LOADOUT_SECTION] = section

    -- Save current loadout name
    if M.currentLoadout then
        Core.Ini[LOADOUT_SECTION]['_current'] = M.currentLoadout
    end

    if Core.save then Core.save() end
end

--- Save modifications to a built-in loadout
-- @param name string Loadout name
-- @param loadout table Loadout data with overrides
local function saveBuiltInModifications(name, loadout)
    local Core = getCore()
    if not Core or not Core.Ini then return end

    Core.Ini[LOADOUT_SECTION] = Core.Ini[LOADOUT_SECTION] or {}
    local section = Core.Ini[LOADOUT_SECTION]

    -- Mark as modified
    section[name .. '_modified'] = '1'

    -- Save gem overrides if present
    if loadout.gems then
        section[name .. '_gems'] = serializeGems(loadout.gems)
    end

    -- Save enabled overrides
    if loadout.enabledOverrides and #loadout.enabledOverrides > 0 then
        section[name .. '_enabled'] = serializeCSV(loadout.enabledOverrides)
    else
        section[name .. '_enabled'] = nil
    end

    -- Save disabled overrides
    if loadout.disabledOverrides and #loadout.disabledOverrides > 0 then
        section[name .. '_disabled'] = serializeCSV(loadout.disabledOverrides)
    else
        section[name .. '_disabled'] = nil
    end

    -- Save layer overrides
    if loadout.layerOverrides and next(loadout.layerOverrides) then
        local pairs_list = {}
        for setting, layer in pairs(loadout.layerOverrides) do
            table.insert(pairs_list, setting .. ':' .. layer)
        end
        section[name .. '_layerOverrides'] = table.concat(pairs_list, ',')
    else
        section[name .. '_layerOverrides'] = nil
    end

    -- Save layer order overrides (clear old ones first)
    for key in pairs(section) do
        if key:match('^' .. name .. '_layerOrder_') then
            section[key] = nil
        end
    end
    if loadout.layerOrderOverrides then
        for layer, order in pairs(loadout.layerOrderOverrides) do
            section[name .. '_layerOrder_' .. layer] = serializeCSV(order)
        end
    end

    -- Save condition overrides
    if loadout.conditionOverrides and next(loadout.conditionOverrides) then
        local pairs_list = {}
        for setting, data in pairs(loadout.conditionOverrides) do
            table.insert(pairs_list, setting .. ':' .. data)
        end
        section[name .. '_conditionOverrides'] = table.concat(pairs_list, ';')
    else
        section[name .. '_conditionOverrides'] = nil
    end

    M.loadoutModified[name] = true

    if Core.save then Core.save() end
end

--- Save current loadout selection to INI
local function saveCurrentLoadoutSelection()
    local Core = getCore()
    if not Core or not Core.Ini then return end

    Core.Ini[LOADOUT_SECTION] = Core.Ini[LOADOUT_SECTION] or {}
    Core.Ini[LOADOUT_SECTION]['_current'] = M.currentLoadout or ''
    Core.Ini[LOADOUT_SECTION]['_isCustom'] = M.isCustomMode and '1' or '0'

    if Core.save then Core.save() end
end

--- Initialize the spellset manager
-- Loads saved loadouts from INI and sets up change detection
function M.init()
    if M.initialized then return end

    local Core = getCore()
    if Core and Core.Settings then
        M.detectionEnabled = (Core.Settings.AutoDetectSpellChanges ~= false)
    end

    -- Load built-in loadouts from class_configs
    loadBuiltInLoadouts()

    -- Load user overrides for built-in loadouts
    loadUserOverrides()

    -- Load custom loadouts from INI
    loadCustomLoadouts()

    -- Load current loadout selection
    if Core and Core.Ini and Core.Ini[LOADOUT_SECTION] then
        M.currentLoadout = Core.Ini[LOADOUT_SECTION]['_current']
        if M.currentLoadout == '' then M.currentLoadout = nil end
        M.isCustomMode = Core.Ini[LOADOUT_SECTION]['_isCustom'] == '1'
    end

    -- Sync legacy/global SpellLoadout setting with SpellsetManager's selected loadout.
    -- Source of truth:
    --  - If we have a saved SpellsetManager current loadout, force Core.Settings.SpellLoadout to match it.
    --  - Otherwise, adopt Core.Settings.SpellLoadout (for backward compatibility) and persist it.
    if Core and Core.Settings then
        local settingsLoadout = tostring(Core.Settings.SpellLoadout or '')
        local current = tostring(M.currentLoadout or '')
        if current ~= '' then
            if settingsLoadout ~= current then
                if Core.set then
                    Core.set('SpellLoadout', current)
                else
                    Core.Settings.SpellLoadout = current
                end
                mq.cmdf('/echo [SideKick] Synced SpellLoadout -> %s', current)
            end
        elseif settingsLoadout ~= '' then
            M.currentLoadout = settingsLoadout
            saveCurrentLoadoutSelection()
            mq.cmdf('/echo [SideKick] Loaded SpellLoadout -> %s', settingsLoadout)
        end
    end

    -- Capture initial gem state
    M.captureCurrentGems()

    M.initialized = true
end

--- Tick function - call from main loop to detect manual spell changes
function M.tick()
    if not M.initialized then return end
    if not M.detectionEnabled then return end

    -- Throttle checks
    local now = os.clock()
    if (now - M.lastCheckTime) < M.checkInterval then
        return
    end
    M.lastCheckTime = now

    -- Detect manual changes
    M.detectManualChanges()
end

--- Apply the active loadout's effective boolean defaults to a settings table.
-- This keeps runtime consumers (rotation/spell logic) aligned with SpellLoadouts defaults + user overrides.
-- Note: This updates the provided table in-place and does NOT persist to INI.
-- @param settings table Settings table (e.g., Core.Settings)
function M.applyActiveLoadoutSettings(settings)
    if type(settings) ~= 'table' then return end
    if not M.initialized then
        M.init()
        if not M.initialized then return end
    end

    local now = os.clock()
    local loadoutName = (M.currentLoadout and tostring(M.currentLoadout) ~= '' and tostring(M.currentLoadout))
        or (tostring(settings.SpellLoadout or '') ~= '' and tostring(settings.SpellLoadout))
        or ''
    if loadoutName == '' then return end

    -- Keep settings.SpellLoadout aligned in-memory (persistence is handled in init/setLoadout).
    if settings.SpellLoadout ~= loadoutName then
        settings.SpellLoadout = loadoutName
    end

    -- Throttle; this is called from the main loop.
    if M._lastSettingsSync
        and M._lastSettingsSync.loadoutName == loadoutName
        and (now - (M._lastSettingsSync.at or 0)) < 0.25
    then
        return
    end

    local function listHas(list, key)
        for _, v in ipairs(list or {}) do
            if v == key then return true end
        end
        return false
    end

    local ClassConfigLoader = getClassConfigLoader()
    if not ClassConfigLoader then return end

    local classShort = getClassShort()
    if not classShort or classShort == '' then return end

    local config = ClassConfigLoader.load(classShort) or ClassConfigLoader.current
    if not config then return end

    local loadouts = ClassConfigLoader.getSpellLoadouts(config) or {}
    local baseLoadout = loadouts[loadoutName] or loadouts[loadoutName:lower()]

    local defaultConfig = ClassConfigLoader.getDefaultConfig() or {}
    local overrideLoadout = M.getLoadout(loadoutName)

    for settingKey, meta in pairs(defaultConfig) do
        if type(meta) == 'table' and type(meta.Default) == 'boolean' then
            local effective = meta.Default
            if baseLoadout and baseLoadout.defaults and baseLoadout.defaults[settingKey] ~= nil then
                effective = baseLoadout.defaults[settingKey] == true
            end

            if overrideLoadout then
                local abilitySet = meta and meta.AbilitySet
                if listHas(overrideLoadout.enabledOverrides, settingKey)
                    or (type(abilitySet) == 'string' and abilitySet ~= '' and listHas(overrideLoadout.enabledOverrides, abilitySet))
                then
                    effective = true
                elseif listHas(overrideLoadout.disabledOverrides, settingKey)
                    or (type(abilitySet) == 'string' and abilitySet ~= '' and listHas(overrideLoadout.disabledOverrides, abilitySet))
                then
                    effective = false
                end
            end

            settings[settingKey] = effective
        end
    end

    -- Also sync per-gem AbilitySet toggles (used when UI/rotation keys are the AbilitySet name itself).
    -- Default: enabled if present in the loadout's gem list unless overridden.
    if baseLoadout and baseLoadout.gems then
        local seen = {}
        for _, setName in pairs(baseLoadout.gems) do
            if type(setName) == 'string' and setName ~= '' and not seen[setName] then
                seen[setName] = true
                local effective = true
                if overrideLoadout then
                    if listHas(overrideLoadout.enabledOverrides, setName) then
                        effective = true
                    elseif listHas(overrideLoadout.disabledOverrides, setName) then
                        effective = false
                    end
                end
                settings[setName] = effective
            end
        end
    end

    M._lastSettingsSync = { loadoutName = loadoutName, at = now }
end

--- Get the currently active loadout name
-- Returns "(Custom)" if user made manual changes, or the loadout name
-- @return string|nil The loadout name or "(Custom)" or nil
function M.getCurrentLoadout()
    if M.isCustomMode then
        return '(Custom)'
    end
    return M.currentLoadout
end

--- Get the raw loadout name (without Custom indicator)
-- @return string|nil The actual loadout name
function M.getCurrentLoadoutName()
    return M.currentLoadout
end

--- Check if current state is in custom mode
-- @return boolean True if user made manual changes
function M.isInCustomMode()
    return M.isCustomMode
end

--- Check if a loadout has user modifications
-- @param name string Loadout name
-- @return boolean True if loadout has INI overrides
function M.isModified(name)
    if not name then return false end
    return M.loadoutModified[name] == true
end

--- Switch to a loadout (applies spells to gem bar)
-- @param name string The loadout name to switch to
-- @param applyImmediately boolean If true, immediately memorize spells (default: true)
-- @return boolean True if loadout was found and set
function M.setLoadout(name, applyImmediately)
    if applyImmediately == nil then applyImmediately = true end

    -- Look up loadout (check built-in first, then custom)
    local loadout = M.builtInLoadouts[name] or M.customLoadouts[name]
    if not loadout then
        mq.cmdf('/echo [SpellsetManager] Loadout not found: %s', name)
        return false
    end

    M.currentLoadout = name
    M.isCustomMode = false

    -- Save selection
    saveCurrentLoadoutSelection()

    -- Keep Core.Settings.SpellLoadout aligned so other modules (and UI) don't drift.
    local Core = getCore()
    if Core and Core.set then
        Core.set('SpellLoadout', name)
    elseif Core and Core.Settings then
        Core.Settings.SpellLoadout = name
    end

    if applyImmediately then
        -- Apply the loadout (memorize spells)
        M.applyLoadout(name)
    end

    -- Update lastGems to match expected state (avoid false "manual change" detection)
    M.lastGems = {}
    local rotationGems = getRotationGems()
    for gem, spellName in pairs(loadout.gems) do
        if gem <= rotationGems then
            M.lastGems[gem] = spellName
        end
    end

    return true
end

--- Apply a loadout's spells to the gem bar (queues for async processing)
-- @param name string The loadout name to apply
-- @return boolean True if application was queued
function M.applyLoadout(name)
    local loadout = M.builtInLoadouts[name] or M.customLoadouts[name]
    if not loadout or not loadout.gems then
        return false
    end

    local me = mq.TLO.Me
    if not me or not me() then return false end

    local rotationGems = getRotationGems()
    if rotationGems <= 0 then
        mq.cmdf('/echo [SpellsetManager] Cannot apply loadout: no rotation gems available')
        return false
    end

    -- Build list of gems that need memorizing
    local gemList = {}
    for gem, spellName in pairs(loadout.gems) do
        -- Never apply to the last gem (reserved for rotating buff slot)
        if gem > rotationGems then
            goto continue_gem
        end
        if spellName and spellName ~= '' then
            local currentSpell = me.Gem(gem)
            local currentName = currentSpell and currentSpell.Name and currentSpell.Name() or ''
            if currentName ~= spellName then
                table.insert(gemList, { gem = gem, spellName = spellName })
            end
        end
        ::continue_gem::
    end

    if #gemList == 0 then
        mq.cmdf('/echo [SpellsetManager] Loadout %s already applied', name)
        return true
    end

    -- Sort by gem number for consistent ordering
    table.sort(gemList, function(a, b) return a.gem < b.gem end)

    -- Queue the apply operation
    M._applyState = {
        loadoutName = name,
        gems = loadout.gems,
        gemList = gemList,
        currentIdx = 1,
        lastMemTime = 0,
        waitingForMem = false,
    }

    mq.cmdf('/echo [SpellsetManager] Applying loadout: %s (%d spells to memorize)', name, #gemList)
    return true
end

--- Check if a loadout is currently being applied
-- @return boolean True if applying
function M.isApplying()
    return M._applyState ~= nil
end

--- Process pending memorization (call from main loop)
-- Handles one spell at a time with delays between
function M.processPending()
    if not M._applyState then return end

    local state = M._applyState
    local me = mq.TLO.Me
    if not me or not me() then return end

    local now = os.clock()

    -- If waiting for memorization, check if complete
    if state.waitingForMem then
        local entry = state.gemList[state.currentIdx]
        if entry then
            local currentSpell = me.Gem(entry.gem)
            local currentName = currentSpell and currentSpell.Name and currentSpell.Name() or ''

            -- Check if spell is now memorized or if we've waited long enough (10s timeout)
            if currentName == entry.spellName then
                -- Spell memorized, move to next
                state.currentIdx = state.currentIdx + 1
                state.waitingForMem = false
                state.lastMemTime = now
            elseif (now - state.lastMemTime) > 10 then
                -- Timeout, skip this spell
                mq.cmdf('/echo [SpellsetManager] Timeout memorizing %s, skipping', entry.spellName)
                state.currentIdx = state.currentIdx + 1
                state.waitingForMem = false
                state.lastMemTime = now
            end
        end
    else
        -- Wait 100ms between memorizations
        if (now - state.lastMemTime) < 0.1 then
            return
        end

        -- Check if we're done
        if state.currentIdx > #state.gemList then
            mq.cmdf('/echo [SpellsetManager] Loadout %s applied', state.loadoutName)
            M._applyState = nil
            return
        end

        -- Start memorizing next spell
        local entry = state.gemList[state.currentIdx]
        if entry then
            -- Double-check it still needs memorizing
            local currentSpell = me.Gem(entry.gem)
            local currentName = currentSpell and currentSpell.Name and currentSpell.Name() or ''

            if currentName ~= entry.spellName then
                mq.cmdf('/memspell %d "%s"', entry.gem, entry.spellName)
                state.waitingForMem = true
                state.lastMemTime = now
            else
                -- Already memorized, move to next
                state.currentIdx = state.currentIdx + 1
            end
        end
    end
end

--- Cancel any pending loadout application
function M.cancelApply()
    if M._applyState then
        mq.cmdf('/echo [SpellsetManager] Loadout application cancelled')
        M._applyState = nil
    end
end

--- Save current gem bar state as a loadout (or save modifications to built-in)
-- For built-in loadouts, saves modifications to INI without overwriting class_config
-- For custom loadouts, saves the full loadout
-- @param name string The name for the loadout
-- @param description string Optional description
-- @return boolean True if saved successfully
function M.saveLoadout(name, description)
    if not name or name == '' then
        mq.cmd('/echo [SpellsetManager] Cannot save loadout: name required')
        return false
    end

    -- Check if this is a built-in loadout
    if M.builtInLoadouts[name] then
        -- Save modifications for built-in loadout
        local loadout = M.builtInLoadouts[name]

        -- Capture current gem state (rotation gems only; last gem reserved for buffs)
        local currentGems = M.captureCurrentGems()

        -- Store gem modifications
        loadout.gems = currentGems

        -- Save to INI as modifications
        saveBuiltInModifications(name, loadout)

        -- Update state
        M.currentLoadout = name
        M.isCustomMode = false
        M.lastGems = {}
        for gem, spellName in pairs(currentGems) do
            M.lastGems[gem] = spellName
        end

        mq.cmdf('/echo [SpellsetManager] Saved modifications to built-in loadout: %s', name)
        return true
    end

    -- Custom loadout - save full state
    local gems = M.captureCurrentGems()

    M.customLoadouts[name] = {
        gems = gems,
        description = description or '',
        isBuiltIn = false,
    }

    -- Update state
    M.currentLoadout = name
    M.isCustomMode = false
    M.lastGems = {}
    for gem, spellName in pairs(gems) do
        M.lastGems[gem] = spellName
    end

    -- Save to INI
    saveCustomLoadouts()

    mq.cmdf('/echo [SpellsetManager] Saved loadout: %s', name)
    return true
end

--- Save current state as a new custom loadout
-- Creates a new loadout from current state, optionally based on a built-in
-- @param name string Display name for the new loadout
-- @param baseLoadoutName string|nil Optional base loadout to inherit settings from
-- @param description string|nil Optional description
-- @return boolean True if saved successfully
function M.saveLoadoutAs(name, baseLoadoutName, description)
    if not name or name == '' then
        mq.cmd('/echo [SpellsetManager] Cannot save loadout: name required')
        return false
    end

    -- Don't allow overwriting built-in loadouts
    if M.builtInLoadouts[name] then
        mq.cmdf('/echo [SpellsetManager] Cannot use built-in loadout name: %s', name)
        return false
    end

    -- Capture current gem state (rotation gems only; last gem reserved for buffs)
    local gems = M.captureCurrentGems()

    local newLoadout = {
        gems = gems,
        description = description or '',
        isBuiltIn = false,
        _safeName = makeSafeName(name),
    }

    -- If based on a built-in loadout, inherit its overrides
    if baseLoadoutName and M.builtInLoadouts[baseLoadoutName] then
        local base = M.builtInLoadouts[baseLoadoutName]
        newLoadout.baseLoadout = baseLoadoutName
        if base.enabledOverrides then
            newLoadout.enabledOverrides = {}
            for _, v in ipairs(base.enabledOverrides) do
                table.insert(newLoadout.enabledOverrides, v)
            end
        end
        if base.disabledOverrides then
            newLoadout.disabledOverrides = {}
            for _, v in ipairs(base.disabledOverrides) do
                table.insert(newLoadout.disabledOverrides, v)
            end
        end
        if base.layerOverrides then
            newLoadout.layerOverrides = {}
            for k, v in pairs(base.layerOverrides) do
                newLoadout.layerOverrides[k] = v
            end
        end
        if base.layerOrderOverrides then
            newLoadout.layerOrderOverrides = {}
            for k, v in pairs(base.layerOrderOverrides) do
                newLoadout.layerOrderOverrides[k] = {}
                for _, item in ipairs(v) do
                    table.insert(newLoadout.layerOrderOverrides[k], item)
                end
            end
        end
    elseif baseLoadoutName and M.customLoadouts[baseLoadoutName] then
        -- Based on another custom loadout
        local base = M.customLoadouts[baseLoadoutName]
        newLoadout.baseLoadout = base.baseLoadout
        if base.enabledOverrides then
            newLoadout.enabledOverrides = {}
            for _, v in ipairs(base.enabledOverrides) do
                table.insert(newLoadout.enabledOverrides, v)
            end
        end
        if base.disabledOverrides then
            newLoadout.disabledOverrides = {}
            for _, v in ipairs(base.disabledOverrides) do
                table.insert(newLoadout.disabledOverrides, v)
            end
        end
        if base.layerOverrides then
            newLoadout.layerOverrides = {}
            for k, v in pairs(base.layerOverrides) do
                newLoadout.layerOverrides[k] = v
            end
        end
        if base.layerOrderOverrides then
            newLoadout.layerOrderOverrides = {}
            for k, v in pairs(base.layerOrderOverrides) do
                newLoadout.layerOrderOverrides[k] = {}
                for _, item in ipairs(v) do
                    table.insert(newLoadout.layerOrderOverrides[k], item)
                end
            end
        end
    end

    M.customLoadouts[name] = newLoadout

    -- Update state
    M.currentLoadout = name
    M.isCustomMode = false
    M.lastGems = {}
    for gem, spellName in pairs(gems) do
        M.lastGems[gem] = spellName
    end

    -- Save to INI
    saveCustomLoadouts()

    mq.cmdf('/echo [SpellsetManager] Saved new loadout: %s', name)
    return true
end

--- Reset a built-in loadout to its default state
-- Clears all INI overrides and reloads from class_config
-- @param name string Loadout name
-- @return boolean True if reset successfully
function M.resetToDefault(name)
    if not name or name == '' then
        return false
    end

    -- Only built-in loadouts can be reset
    if not M.builtInLoadouts[name] then
        mq.cmdf('/echo [SpellsetManager] %s is not a built-in loadout', name)
        return false
    end

    local Core = getCore()
    if not Core or not Core.Ini then return false end

    local section = Core.Ini[LOADOUT_SECTION]
    if section then
        -- Clear all INI entries for this loadout
        section[name .. '_modified'] = nil
        section[name .. '_gems'] = nil
        section[name .. '_enabled'] = nil
        section[name .. '_disabled'] = nil
        section[name .. '_layerOverrides'] = nil
        section[name .. '_conditionOverrides'] = nil

        -- Clear layer order entries
        for key in pairs(section) do
            if key:match('^' .. name .. '_layerOrder_') then
                section[key] = nil
            end
        end
    end

    -- Clear modified flag
    M.loadoutModified[name] = nil

    -- Save INI
    if Core.save then Core.save() end

    -- Reload built-in loadouts to get fresh data
    loadBuiltInLoadouts()

    -- If this was the current loadout, refresh its state
    if M.currentLoadout == name then
        local loadout = M.builtInLoadouts[name]
        if loadout then
            M.lastGems = {}
            for gem, spellName in pairs(loadout.gems) do
                M.lastGems[gem] = spellName
            end
        end
    end

    mq.cmdf('/echo [SpellsetManager] Reset %s to default', name)
    return true
end

--- Delete a saved loadout
-- @param name string The loadout name to delete
-- @return boolean True if deleted successfully
function M.deleteLoadout(name)
    if not name or name == '' then
        return false
    end

    -- Can't delete built-in loadouts (but can reset them)
    if M.builtInLoadouts[name] then
        mq.cmdf('/echo [SpellsetManager] Cannot delete built-in loadout: %s (use resetToDefault instead)', name)
        return false
    end

    if not M.customLoadouts[name] then
        return false
    end

    M.customLoadouts[name] = nil

    -- If we deleted the current loadout, clear selection
    if M.currentLoadout == name then
        M.currentLoadout = nil
        M.isCustomMode = true
    end

    -- Save changes
    saveCustomLoadouts()

    mq.cmdf('/echo [SpellsetManager] Deleted loadout: %s', name)
    return true
end

--- Get list of all available loadouts (built-in + custom)
-- @return table Array of {name, description, isBuiltIn, isModified}
function M.getAvailableLoadouts()
    local loadouts = {}

    -- Add built-in loadouts
    for name, data in pairs(M.builtInLoadouts) do
        table.insert(loadouts, {
            name = name,
            description = data.description or name,
            isBuiltIn = true,
            isModified = M.loadoutModified[name] == true,
        })
    end

    -- Add custom loadouts
    for name, data in pairs(M.customLoadouts) do
        table.insert(loadouts, {
            name = name,
            description = data.description or name,
            isBuiltIn = false,
            isModified = false,
            baseLoadout = data.baseLoadout,
        })
    end

    -- Sort: built-in first, then alphabetically
    table.sort(loadouts, function(a, b)
        if a.isBuiltIn ~= b.isBuiltIn then
            return a.isBuiltIn
        end
        return a.name < b.name
    end)

    return loadouts
end

--- Get the gem assignments for a specific loadout
-- @param name string The loadout name
-- @return table|nil {[gem] = spellName} or nil if not found
function M.getLoadoutGems(name)
    local loadout = M.builtInLoadouts[name] or M.customLoadouts[name]
    if loadout then
        return loadout.gems
    end
    return nil
end

--- Get the full loadout data
-- @param name string The loadout name
-- @return table|nil Full loadout data or nil if not found
function M.getLoadout(name)
    return M.builtInLoadouts[name] or M.customLoadouts[name]
end

--- Capture current spell bar state
-- @return table {[gem] = spellName}
function M.captureCurrentGems()
    local gems = {}
    local me = mq.TLO.Me
    if not me or not me() then return gems end

    local rotationGems = getRotationGems()
    for i = 1, rotationGems do
        local spell = me.Gem(i)
        if spell and spell() then
            local name = spell.Name and spell.Name() or ''
            if name ~= '' then
                gems[i] = name
            end
        end
    end

    -- Update lastGems
    M.lastGems = {}
    for gem, spellName in pairs(gems) do
        M.lastGems[gem] = spellName
    end

    return gems
end

--- Detect if user manually changed spells
-- Sets isCustomMode = true if changes detected
-- @return boolean True if changes were detected
function M.detectManualChanges()
    local me = mq.TLO.Me
    if not me or not me() then return false end

    -- Don't detect during memorization
    local GemManager = getGemManager()
    if GemManager and GemManager.isMemorizing and GemManager.isMemorizing() then
        return false
    end

    local rotationGems = getRotationGems()
    local changesDetected = false

    for i = 1, rotationGems do
        local spell = me.Gem(i)
        local currentName = ''
        if spell and spell() then
            currentName = spell.Name and spell.Name() or ''
        end

        local lastName = M.lastGems[i] or ''

        if currentName ~= lastName then
            changesDetected = true
            -- Update our tracking
            if currentName == '' then
                M.lastGems[i] = nil
            else
                M.lastGems[i] = currentName
            end
        end
    end

    if changesDetected and not M.isCustomMode then
        M.isCustomMode = true
        saveCurrentLoadoutSelection()
    end

    return changesDetected
end

--- Reset custom mode (after saving, etc.)
function M.clearCustomMode()
    M.isCustomMode = false
    saveCurrentLoadoutSelection()
end

--- Check if a loadout exists
-- @param name string The loadout name
-- @return boolean True if loadout exists
function M.loadoutExists(name)
    return M.builtInLoadouts[name] ~= nil or M.customLoadouts[name] ~= nil
end

--- Check if a loadout is built-in
-- @param name string The loadout name
-- @return boolean True if loadout is built-in
function M.isBuiltInLoadout(name)
    return M.builtInLoadouts[name] ~= nil
end

--- Rename a custom loadout
-- @param oldName string Current name
-- @param newName string New name
-- @return boolean True if renamed successfully
function M.renameLoadout(oldName, newName)
    if not oldName or not newName or oldName == '' or newName == '' then
        return false
    end

    if M.builtInLoadouts[oldName] then
        mq.cmd('/echo [SpellsetManager] Cannot rename built-in loadout')
        return false
    end

    if not M.customLoadouts[oldName] then
        return false
    end

    if M.loadoutExists(newName) then
        mq.cmdf('/echo [SpellsetManager] Loadout already exists: %s', newName)
        return false
    end

    -- Copy to new name
    M.customLoadouts[newName] = M.customLoadouts[oldName]
    M.customLoadouts[newName]._safeName = makeSafeName(newName)
    M.customLoadouts[oldName] = nil

    -- Update current if needed
    if M.currentLoadout == oldName then
        M.currentLoadout = newName
    end

    saveCustomLoadouts()
    return true
end

--- Refresh built-in loadouts (e.g., after class change)
function M.refreshBuiltInLoadouts()
    loadBuiltInLoadouts()
    loadUserOverrides()
end

--- Get comparison between current gems and a loadout
-- @param name string The loadout name to compare
-- @return table Array of {gem, expected, current, matches}
function M.compareToLoadout(name)
    local loadout = M.builtInLoadouts[name] or M.customLoadouts[name]
    if not loadout then return {} end

    local results = {}
    local me = mq.TLO.Me
    if not me or not me() then return results end

    local rotationGems = getRotationGems()
    for i = 1, rotationGems do
        local expected = loadout.gems[i] or ''
        local spell = me.Gem(i)
        local current = ''
        if spell and spell() then
            current = spell.Name and spell.Name() or ''
        end

        table.insert(results, {
            gem = i,
            expected = expected,
            current = current,
            matches = (expected == current) or (expected == '' and current ~= ''),
        })
    end

    return results
end

--- Set whether auto-detection is enabled
-- @param enabled boolean True to enable detection
function M.setDetectionEnabled(enabled)
    M.detectionEnabled = enabled

    -- Save to settings
    local Core = getCore()
    if Core and Core.set then
        Core.set('AutoDetectSpellChanges', enabled)
    end
end

--- Check if detection is enabled
-- @return boolean
function M.isDetectionEnabled()
    return M.detectionEnabled
end

--- Update settings override for a loadout
-- @param loadoutName string Loadout name
-- @param settingKey string Setting key (e.g., "DoMez")
-- @param enabled boolean|nil True to enable, false to disable, nil to remove override
function M.setLoadoutSetting(loadoutName, settingKey, enabled)
    local loadout = M.builtInLoadouts[loadoutName] or M.customLoadouts[loadoutName]
    if not loadout then return false end

    -- Initialize override lists if needed
    loadout.enabledOverrides = loadout.enabledOverrides or {}
    loadout.disabledOverrides = loadout.disabledOverrides or {}

    -- Remove from both lists first
    for i = #loadout.enabledOverrides, 1, -1 do
        if loadout.enabledOverrides[i] == settingKey then
            table.remove(loadout.enabledOverrides, i)
        end
    end
    for i = #loadout.disabledOverrides, 1, -1 do
        if loadout.disabledOverrides[i] == settingKey then
            table.remove(loadout.disabledOverrides, i)
        end
    end

    -- Add to appropriate list
    if enabled == true then
        table.insert(loadout.enabledOverrides, settingKey)
    elseif enabled == false then
        table.insert(loadout.disabledOverrides, settingKey)
    end
    -- enabled == nil means remove override (already done above)

    -- Save changes
    if M.builtInLoadouts[loadoutName] then
        saveBuiltInModifications(loadoutName, loadout)
    else
        saveCustomLoadouts()
    end

    return true
end

--- Update layer override for a loadout
-- @param loadoutName string Loadout name
-- @param settingKey string Setting key
-- @param layer string|nil Layer name, or nil to remove override
function M.setLoadoutLayer(loadoutName, settingKey, layer)
    local loadout = M.builtInLoadouts[loadoutName] or M.customLoadouts[loadoutName]
    if not loadout then return false end

    loadout.layerOverrides = loadout.layerOverrides or {}

    if layer then
        loadout.layerOverrides[settingKey] = layer
    else
        loadout.layerOverrides[settingKey] = nil
    end

    -- Save changes
    if M.builtInLoadouts[loadoutName] then
        saveBuiltInModifications(loadoutName, loadout)
    else
        saveCustomLoadouts()
    end

    return true
end

--- Update layer order for a loadout
-- @param loadoutName string Loadout name
-- @param layer string Layer name
-- @param order table Array of setting keys in priority order
function M.setLoadoutLayerOrder(loadoutName, layer, order)
    local loadout = M.builtInLoadouts[loadoutName] or M.customLoadouts[loadoutName]
    if not loadout then return false end

    loadout.layerOrderOverrides = loadout.layerOrderOverrides or {}

    if order and #order > 0 then
        loadout.layerOrderOverrides[layer] = order
    else
        loadout.layerOrderOverrides[layer] = nil
    end

    -- Save changes
    if M.builtInLoadouts[loadoutName] then
        saveBuiltInModifications(loadoutName, loadout)
    else
        saveCustomLoadouts()
    end

    return true
end

--- Get condition override for a setting in a loadout
-- @param loadoutName string Loadout name
-- @param settingKey string Setting key
-- @return string|nil Serialized condition data, or nil if no override
function M.getConditionOverride(loadoutName, settingKey)
    local loadout = M.builtInLoadouts[loadoutName] or M.customLoadouts[loadoutName]
    if not loadout or not loadout.conditionOverrides then return nil end
    return loadout.conditionOverrides[settingKey]
end

--- Set condition override for a setting in a loadout
-- @param loadoutName string Loadout name
-- @param settingKey string Setting key
-- @param serializedData string|nil Serialized condition data (from ConditionBuilder.serialize), or nil to remove
function M.setConditionOverride(loadoutName, settingKey, serializedData)
    local loadout = M.builtInLoadouts[loadoutName] or M.customLoadouts[loadoutName]
    if not loadout then return false end

    loadout.conditionOverrides = loadout.conditionOverrides or {}

    if serializedData and serializedData ~= '' then
        loadout.conditionOverrides[settingKey] = serializedData
    else
        loadout.conditionOverrides[settingKey] = nil
    end

    -- Save changes
    if M.builtInLoadouts[loadoutName] then
        saveBuiltInModifications(loadoutName, loadout)
    else
        saveCustomLoadouts()
    end

    return true
end

--- Clear all condition overrides for a setting across all loadouts
-- Useful for "Reset to Default" functionality
-- @param settingKey string Setting key to clear
function M.clearConditionOverride(loadoutName, settingKey)
    return M.setConditionOverride(loadoutName, settingKey, nil)
end

--------------------------------------------------------------------------------
-- Spell Set Editor Support Functions
--------------------------------------------------------------------------------

--- Update rotation capacity from NumGems (call periodically)
function M.updateCapacity()
    local now = os.clock()
    if (now - M.lastCapacityCheck) < 30 then return end  -- Every 30s
    M.lastCapacityCheck = now

    local me = mq.TLO.Me
    if not me or not me() then return end

    local numGems = tonumber(me.NumGems()) or 8
    M.rotationCapacity = numGems - 1  -- Last gem reserved for buff swap
end

--- Get current rotation capacity
-- @return number Available rotation gem slots
function M.getRotationCapacity()
    M.updateCapacity()
    return M.rotationCapacity
end

--- Resolve the best spell from a line (highest level in spellbook)
-- @param lineName string The spell line name
-- @return string|nil The resolved spell name or nil
function M.resolveSpellFromLine(lineName)
    local SpellsClr = getSpellsClr()
    if not SpellsClr then return nil end

    local lineData = SpellsClr.getLine(lineName)
    if not lineData or not lineData.spells then return nil end

    local me = mq.TLO.Me
    if not me or not me() then return nil end

    -- Spells are ordered highest to lowest, return first one in spellbook
    for _, spellName in ipairs(lineData.spells) do
        local inBook = me.Book(spellName)
        if inBook and inBook() then
            return spellName
        end
    end

    return nil
end

--------------------------------------------------------------------------------
-- Spell Set CRUD Operations
--------------------------------------------------------------------------------

--- Create a new spell set
-- @param name string The spell set name
-- @return table|nil The new spell set or nil if invalid
function M.createSet(name)
    if not name or name == '' then return nil end
    if M.spellSets[name] then return M.spellSets[name] end

    local set = {
        name = name,
        lines = {},  -- {[lineName] = {enabled, slotType, condition, priority}}
    }

    M.spellSets[name] = set
    M.saveSpellSets()
    return set
end

--- Delete a spell set
-- @param name string The spell set name
-- @return boolean True if deleted
function M.deleteSet(name)
    if not name or not M.spellSets[name] then return false end

    M.spellSets[name] = nil

    if M.activeSetName == name then
        M.activeSetName = nil
    end

    M.saveSpellSets()
    return true
end

--- Get a spell set by name
-- @param name string The spell set name
-- @return table|nil The spell set or nil
function M.getSet(name)
    return M.spellSets[name]
end

--- Get the active spell set
-- @return table|nil The active spell set or nil
function M.getActiveSet()
    if not M.activeSetName then return nil end
    return M.spellSets[M.activeSetName]
end

--- Get list of all spell set names
-- @return table Array of spell set names
function M.getSetNames()
    local names = {}
    for name, _ in pairs(M.spellSets) do
        table.insert(names, name)
    end
    table.sort(names)
    return names
end

--------------------------------------------------------------------------------
-- Spell Line Enable/Disable Operations
--------------------------------------------------------------------------------

--- Enable a spell line in a set
-- @param setName string The spell set name
-- @param lineName string The spell line name
-- @param slotType string 'rotation' or 'buff_swap' (optional, defaults to line's defaultSlotType)
-- @return boolean True if enabled, false if at capacity or invalid
function M.enableLine(setName, lineName, slotType)
    local set = M.getSet(setName)
    if not set then return false end

    -- Get default slot type only if not specified
    if not slotType then
        local SpellsClr = getSpellsClr()
        local lineData = SpellsClr and SpellsClr.getLine(lineName)
        slotType = (lineData and lineData.defaultSlotType) or 'rotation'
    end

    -- Check capacity for rotation lines (now using the final slotType)
    if slotType == 'rotation' then
        local count = M.countEnabledRotation(setName)
        if count >= M.getRotationCapacity() then
            return false  -- At capacity
        end
    end

    set.lines[lineName] = set.lines[lineName] or {}
    set.lines[lineName].enabled = true
    set.lines[lineName].slotType = slotType
    set.lines[lineName].priority = set.lines[lineName].priority or 999
    set.lines[lineName].resolved = M.resolveSpellFromLine(lineName)

    M.saveSpellSets()
    return true
end

--- Disable a spell line in a set
-- @param setName string The spell set name
-- @param lineName string The spell line name
function M.disableLine(setName, lineName)
    local set = M.getSet(setName)
    if not set or not set.lines[lineName] then return end

    set.lines[lineName].enabled = false
    M.saveSpellSets()
end

--- Count enabled rotation lines in a set
-- @param setName string The spell set name
-- @return number Count of enabled rotation lines
function M.countEnabledRotation(setName)
    local set = M.getSet(setName)
    if not set then return 0 end

    local count = 0
    for _, lineData in pairs(set.lines) do
        if lineData.enabled and lineData.slotType == 'rotation' then
            count = count + 1
        end
    end
    return count
end

--- Set the slot type for a line
-- @param setName string The spell set name
-- @param lineName string The spell line name
-- @param slotType string 'rotation' or 'buff_swap'
-- @return boolean True if successful
function M.setLineSlotType(setName, lineName, slotType)
    local set = M.getSet(setName)
    if not set or not set.lines[lineName] then return false end

    -- If moving to rotation, check capacity
    if slotType == 'rotation' and set.lines[lineName].slotType ~= 'rotation' then
        if set.lines[lineName].enabled then
            local count = M.countEnabledRotation(setName)
            if count >= M.getRotationCapacity() then
                return false  -- At capacity
            end
        end
    end

    set.lines[lineName].slotType = slotType
    M.saveSpellSets()
    return true
end

--- Set condition for a line
-- @param setName string The spell set name
-- @param lineName string The spell line name
-- @param conditionData table The condition data (from ConditionBuilder)
function M.setLineCondition(setName, lineName, conditionData)
    local set = M.getSet(setName)
    if not set or not set.lines[lineName] then return end

    set.lines[lineName].condition = conditionData
    M.saveSpellSets()
end

--- Set priority for a line
-- @param setName string The spell set name
-- @param lineName string The spell line name
-- @param priority number The priority (lower = higher priority)
function M.setLinePriority(setName, lineName, priority)
    local set = M.getSet(setName)
    if not set or not set.lines[lineName] then return end

    set.lines[lineName].priority = priority
    M.saveSpellSets()
end

--- Placeholder for spell set persistence (implemented in Task 5)
-- @private
function M.saveSpellSets()
    -- Will be implemented in Task 5
end

return M
