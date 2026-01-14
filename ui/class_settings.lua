-- F:/lua/SideKick/ui/class_settings.lua
-- Class Settings UI - Auto-generates per-loadout settings from DefaultConfig
-- Extended with SpellsetManager integration for custom loadout management

local mq = require('mq')
local imgui = require('ImGui')

local M = {}

-- Safe DrawList wrapper functions
-- Per CLAUDE.md: ImVec2() may return Lua table instead of C++ userdata in some MQ builds, causing crashes
-- These functions use pcall with multiple fallback attempts for different API signatures

local function dlAddRectFilled(dl, x1, y1, x2, y2, col, rounding, flags)
    if not dl then return false end
    rounding = tonumber(rounding) or 0
    flags = tonumber(flags) or 0
    local ImVec2 = _G.ImVec2 or imgui.ImVec2
    local tries = {
        function() dl:AddRectFilled(x1, y1, x2, y2, col, rounding, flags) end,
        function() dl:AddRectFilled(x1, y1, x2, y2, col, rounding) end,
        function() dl:AddRectFilled(x1, y1, x2, y2, col) end,
    }
    if ImVec2 then
        table.insert(tries, function() dl:AddRectFilled(ImVec2(x1, y1), ImVec2(x2, y2), col, rounding, flags) end)
        table.insert(tries, function() dl:AddRectFilled(ImVec2(x1, y1), ImVec2(x2, y2), col, rounding) end)
        table.insert(tries, function() dl:AddRectFilled(ImVec2(x1, y1), ImVec2(x2, y2), col) end)
    end
    for _, fn in ipairs(tries) do
        if pcall(fn) then return true end
    end
    return false
end

local function dlAddRect(dl, x1, y1, x2, y2, col, rounding, flags, thickness)
    if not dl then return false end
    rounding = tonumber(rounding) or 0
    flags = tonumber(flags) or 0
    thickness = tonumber(thickness) or 1
    local ImVec2 = _G.ImVec2 or imgui.ImVec2
    local tries = {
        function() dl:AddRect(x1, y1, x2, y2, col, rounding, flags, thickness) end,
        function() dl:AddRect(x1, y1, x2, y2, col, rounding, flags) end,
        function() dl:AddRect(x1, y1, x2, y2, col, rounding) end,
        function() dl:AddRect(x1, y1, x2, y2, col) end,
    }
    if ImVec2 then
        table.insert(tries, function() dl:AddRect(ImVec2(x1, y1), ImVec2(x2, y2), col, rounding, flags, thickness) end)
        table.insert(tries, function() dl:AddRect(ImVec2(x1, y1), ImVec2(x2, y2), col, rounding, flags) end)
        table.insert(tries, function() dl:AddRect(ImVec2(x1, y1), ImVec2(x2, y2), col, rounding) end)
        table.insert(tries, function() dl:AddRect(ImVec2(x1, y1), ImVec2(x2, y2), col) end)
    end
    for _, fn in ipairs(tries) do
        if pcall(fn) then return true end
    end
    return false
end

local function dlAddText(dl, x, y, col, text)
    if not dl then return false end
    local ImVec2 = _G.ImVec2 or imgui.ImVec2
    local tries = {
        function() dl:AddText(x, y, col, text) end,
    }
    if ImVec2 then
        table.insert(tries, function() dl:AddText(ImVec2(x, y), col, text) end)
    end
    for _, fn in ipairs(tries) do
        if pcall(fn) then return true end
    end
    return false
end

local function dlAddLine(dl, x1, y1, x2, y2, col, thickness)
    if not dl then return false end
    thickness = tonumber(thickness) or 1
    local ImVec2 = _G.ImVec2 or imgui.ImVec2
    local tries = {
        function() dl:AddLine(x1, y1, x2, y2, col, thickness) end,
        function() dl:AddLine(x1, y1, x2, y2, col) end,
    }
    if ImVec2 then
        table.insert(tries, function() dl:AddLine(ImVec2(x1, y1), ImVec2(x2, y2), col, thickness) end)
        table.insert(tries, function() dl:AddLine(ImVec2(x1, y1), ImVec2(x2, y2), col) end)
    end
    for _, fn in ipairs(tries) do
        if pcall(fn) then return true end
    end
    return false
end

-- Spell icon texture animation (for rendering actual spell icons)
local animSpellIcons = mq.FindTextureAnimation('A_SpellIcons')

-- Log whether spell icon texture was found
if animSpellIcons then
    mq.cmdf('/echo [SideKick] Spell icon texture animation loaded: A_SpellIcons')
else
    mq.cmdf('/echo [SideKick] WARNING: Failed to load spell icon texture animation (A_SpellIcons)')
end

-- Lazy-load throttled logging for icon debugging
local _ThrottledLog = nil
local function getThrottledLog()
    if not _ThrottledLog then
        local ok, tl = pcall(require, 'utils.throttled_log')
        if ok then _ThrottledLog = tl end
    end
    return _ThrottledLog
end

-- Enable/disable debug logging for icon rendering
M.debugIconLogging = false  -- Set to true to enable icon rendering logs

-- Enable/disable debug logging for heal line mapping + UI actions
M.debugHealLayerLogging = true

--- Get the spell icon ID from a spell name
-- @param spellName string The spell name to look up
-- @return number Icon ID, or 0 if not found
local function getSpellIconId(spellName)
    local TL = getThrottledLog()
    if not spellName or spellName == '' then
        if M.debugIconLogging and TL then
            TL.log('icon_empty', 10, 'getSpellIconId: empty spell name')
        end
        return 0
    end
    local spell = mq.TLO.Spell(spellName)
    if spell and spell() then
        -- Try SpellIcon first (correct property), then Icon as fallback
        if spell.SpellIcon then
            local iconId = tonumber(spell.SpellIcon()) or 0
            if M.debugIconLogging and TL then
                TL.log('icon_resolved_' .. spellName, 30, 'getSpellIconId: %s -> SpellIcon=%d', spellName, iconId)
            end
            return iconId
        elseif spell.Icon then
            local iconId = tonumber(spell.Icon()) or 0
            if M.debugIconLogging and TL then
                TL.log('icon_fallback_' .. spellName, 30, 'getSpellIconId: %s -> Icon (fallback)=%d', spellName, iconId)
            end
            return iconId
        end
    end
    if M.debugIconLogging and TL then
        TL.log('icon_notfound_' .. spellName, 30, 'getSpellIconId: spell not found: %s', spellName)
    end
    return 0
end

--- Safe wrapper for AddTextureAnimation
-- Accepts x, y coordinates and constructs ImVec2 internally
-- @param dl DrawList The draw list
-- @param anim TextureAnimation The texture animation
-- @param x number X position (screen coordinates)
-- @param y number Y position (screen coordinates)
-- @param size number Icon size
-- @return boolean True if successful
local function dlAddTextureAnimation(dl, anim, x, y, size)
    if not dl or not anim then return false end
    local ImVec2 = _G.ImVec2 or imgui.ImVec2
    if not ImVec2 then return false end

    local posVec = ImVec2(x, y)
    local sizeVec = ImVec2(size, size)
    local tries = {
        function() dl:AddTextureAnimation(anim, posVec, sizeVec) end,
        function() dl:AddTextureAnimation(anim, posVec, size) end,
    }
    for _, fn in ipairs(tries) do
        if pcall(fn) then return true end
    end
    return false
end

-- Lazy-load dependencies
local _ConfigLoader = nil
local function getConfigLoader()
    if not _ConfigLoader then
        local ok, cl = pcall(require, 'utils.class_config_loader')
        if ok then _ConfigLoader = cl end
    end
    return _ConfigLoader
end

local _ConditionBuilder = nil
local function getConditionBuilder()
    if not _ConditionBuilder then
        local ok, cb = pcall(require, 'ui.condition_builder')
        if ok then _ConditionBuilder = cb end
    end
    return _ConditionBuilder
end

local _Core = nil
local function getCore()
    if not _Core then
        local ok, c = pcall(require, 'utils.core')
        if ok then _Core = c end
    end
    return _Core
end

local _SpellsetManager = nil
local function getSpellsetManager()
    if not _SpellsetManager then
        local ok, sm = pcall(require, 'utils.spellset_manager')
        if ok then _SpellsetManager = sm end
    end
    return _SpellsetManager
end

local _IniImporter = nil
local function getIniImporter()
    if not _IniImporter then
        local ok, ii = pcall(require, 'utils.ini_importer')
        if ok then _IniImporter = ii end
    end
    return _IniImporter
end

local _RotationEngine = nil
local function getRotationEngine()
    if not _RotationEngine then
        local ok, re = pcall(require, 'utils.rotation_engine')
        if ok then _RotationEngine = re end
    end
    return _RotationEngine
end

--- Check if a setting is temporarily disabled
-- @param settingKey string The setting key
-- @return boolean True if temporarily disabled
function M.isTemporarilyDisabled(settingKey)
    return M._temporarilyDisabled[settingKey] == true
end

--- Set temporarily disabled state for a setting
-- @param settingKey string The setting key
-- @param disabled boolean True to disable, false to re-enable
function M.setTemporarilyDisabled(settingKey, disabled)
    if disabled then
        M._temporarilyDisabled[settingKey] = true
    else
        M._temporarilyDisabled[settingKey] = nil
    end
end

--- Toggle temporarily disabled state for a setting
-- @param settingKey string The setting key
-- @return boolean New disabled state
function M.toggleTemporarilyDisabled(settingKey)
    local newState = not M._temporarilyDisabled[settingKey]
    M.setTemporarilyDisabled(settingKey, newState)
    return newState
end

--- Clear all temporarily disabled states (e.g., on reload)
function M.clearAllTemporarilyDisabled()
    M._temporarilyDisabled = {}
end

--- Get list of all temporarily disabled setting keys
-- @return table Array of setting keys
function M.getTemporarilyDisabledList()
    local list = {}
    for key, _ in pairs(M._temporarilyDisabled) do
        table.insert(list, key)
    end
    return list
end

--- Build a per-loadout key
local function loadoutKey(baseKey, loadout)
    return baseKey .. '_' .. loadout
end

--- Build a condition key for a setting
local function conditionKey(baseKey, loadout)
    return baseKey .. '_' .. loadout .. '_Condition'
end

local function prettySetName(name)
    name = tostring(name or '')
    if name == '' then return name end
    -- Insert spaces between camel-case transitions.
    name = name:gsub('([a-z0-9])([A-Z])', '%1 %2')
    -- Make some common acronyms nicer.
    name = name:gsub('AA$', 'AA')
    name = name:gsub('AESpell', 'AE Spell')
    name = name:gsub('PBAE', 'PBAE')
    return name
end

local function isSpellMemorized(spellName)
    spellName = tostring(spellName or '')
    if spellName == '' then return false, nil end
    local me = mq.TLO.Me
    if not (me and me()) then return false, nil end
    local gems = tonumber(me.NumGems()) or 0
    for i = 1, gems do
        local gem = me.Gem(i)
        if gem and gem() and (gem.Name() or '') == spellName then
            return true, i
        end
    end
    return false, nil
end

local function resolveBestSpellFromBookForLine(lineName)
    local ConfigLoader = getConfigLoader()
    if not ConfigLoader or not ConfigLoader.current then return nil end
    local classConfig = ConfigLoader.current

    -- Check spellLines first, then AbilitySets
    local line = classConfig.spellLines and classConfig.spellLines[lineName]
    if type(line) ~= 'table' then
        line = classConfig.AbilitySets and classConfig.AbilitySets[lineName]
    end
    if type(line) ~= 'table' then return nil end

    local me = mq.TLO.Me
    if not (me and me()) then return nil end

    for _, abilityName in ipairs(line) do
        -- Check spellbook first (most common case for spells)
        local inBook = me.Book(abilityName)
        if inBook and inBook() then
            return abilityName
        end

        -- Check AAs (for AA lines like DivineArbitrationAA)
        local aa = me.AltAbility(abilityName)
        if aa and aa() then
            return abilityName
        end

        -- Check combat abilities/discs
        local disc = me.CombatAbility(abilityName)
        if disc and disc() then
            return abilityName
        end
    end
    return nil
end

local function isHealSpell(spellName)
    spellName = tostring(spellName or '')
    if spellName == '' then return false end
    local spell = mq.TLO.Spell(spellName)
    if not (spell and spell()) then return false end

    local okType, st = pcall(function() return spell.SpellType and spell.SpellType() end)
    if okType and st and tostring(st) ~= 'Beneficial' then
        return false
    end

    local function hasSpa(id)
        if not spell.HasSPA then return false end
        local ok, v = pcall(function() return spell.HasSPA(id)() end)
        return ok and v == true
    end

    -- SPA 0 = HP, SPA 79 = HP over time
    return hasSpa(0) or hasSpa(79)
end

local function getHealLineEnabled(settings, lineName)
    local key = 'HealLine_' .. tostring(lineName or '')
    if key == 'HealLine_' then return true end
    return (settings or {})[key] ~= false
end

local function setHealLineEnabled(setFunc, lineName, enabled)
    if not setFunc then return end
    local key = 'HealLine_' .. tostring(lineName or '')
    if key == 'HealLine_' then return end
    setFunc(key, enabled == true)
end

local function getSpellUseGem(settings)
    local me = mq.TLO.Me
    local numGems = (me and me() and tonumber(me.NumGems())) or 0
    local rotationGems = (numGems and numGems > 1) and (numGems - 1) or 0
    local fallback = (rotationGems > 0) and rotationGems or 1
    local v = tonumber((settings or {}).SpellUseGem)
    if v and v >= 1 then
        if rotationGems > 0 and v > rotationGems then
            return rotationGems
        end
        return v
    end
    return fallback
end

local function renderHealLayer(settings, setFunc)
    local ConfigLoader = getConfigLoader()
    if not (ConfigLoader and ConfigLoader.current and ConfigLoader.current.spellLines) then return end

    if not imgui.CollapsingHeader('Heal') then
        return
    end

    settings = settings or {}
    local TL = getThrottledLog()
    local me = mq.TLO.Me
    if not (me and me()) then
        imgui.TextDisabled('Character not loaded')
        return
    end

    local classShort = tostring(me.Class.ShortName() or ''):upper()
    local useGem = getSpellUseGem(settings)

    local autoMem = settings.HealLineAutoMem ~= false
    do
        local newVal, changed = imgui.Checkbox('Auto-memorize enabled heal lines', autoMem)
        if changed and setFunc then
            setFunc('HealLineAutoMem', newVal)
            settings.HealLineAutoMem = newVal
            autoMem = newVal
        end
        if imgui.IsItemHovered() then
            imgui.SetTooltip(string.format('When enabled, checking a heal line will /memspell the best spell into your UseGem (%d).', useGem))
        end
    end
    imgui.Separator()

    local healLines = {}
    local totalLines = 0
    for lineName, _ in pairs(ConfigLoader.current.spellLines) do
        totalLines = totalLines + 1
        local best = resolveBestSpellFromBookForLine(lineName)
        if best and isHealSpell(best) then
            table.insert(healLines, lineName)
        end
    end

    table.sort(healLines)

    if M.debugHealLayerLogging and TL then
        TL.log('heal_ui_summary', 10, 'Heal UI: class=%s spellLines=%d healLines=%d useGem=%d',
            classShort, totalLines, #healLines, useGem)
    end

    if #healLines == 0 then
        imgui.TextDisabled('No heal spell lines detected in this class config.')
        return
    end

    imgui.TextDisabled('Enable spell lines; Healing automation will only consider enabled lines.')
    imgui.Separator()

    for _, lineName in ipairs(healLines) do
        imgui.PushID('heal_line_' .. lineName)

        local enabled = getHealLineEnabled(settings, lineName)
        local label = prettySetName(lineName)
        local newVal, changed = imgui.Checkbox(label, enabled)

        local bestBook = resolveBestSpellFromBookForLine(lineName)
        local memorized, gem = isSpellMemorized(bestBook)

        imgui.SameLine()
        if bestBook then
            local memStr = memorized and string.format(' (mem %d)', gem or 0) or ' (not mem)'
            imgui.TextColored(0.7, 0.7, 0.7, 1, tostring(bestBook) .. memStr)
        else
            imgui.TextColored(0.8, 0.5, 0.3, 1, '(not in book)')
        end

        if changed then
            setHealLineEnabled(setFunc, lineName, newVal)
            settings['HealLine_' .. lineName] = newVal

            if M.debugHealLayerLogging and TL then
                TL.log('heal_ui_toggle_' .. lineName, 0, 'Heal UI: %s -> %s (best=%s useGem=%d)',
                    tostring(lineName), tostring(newVal), tostring(bestBook), useGem)
            end

            if autoMem and newVal == true and bestBook and (not memorized) then
                -- Try to ensure it is memorized so the healer can actually use it.
                mq.cmdf('/memspell %d "%s"', useGem, bestBook)
                if M.debugHealLayerLogging and TL then
                    TL.log('heal_ui_mem_' .. lineName, 0, 'Heal UI: memorizing %s to gem %d', tostring(bestBook), useGem)
                end
            end
        end

        if imgui.IsItemHovered() then
            imgui.BeginTooltip()
            imgui.Text(string.format('Setting: HealLine_%s', lineName))
            imgui.Text(string.format('UseGem: %d', useGem))
            if bestBook then
                imgui.Text(string.format('Best in book: %s', bestBook))
            else
                imgui.Text('Best in book: (none)')
            end
            imgui.EndTooltip()
        end

        imgui.PopID()
    end

    imgui.Spacing()
    imgui.Separator()
end

-- State for async spell memorization
M._applyState = nil

-- State for condition editor visibility
M._showCondition = {}

-- State for UI
M._saveAsName = ''
M._showSaveAsPopup = false
M._deleteConfirmName = nil
M._showResetConfirm = false
M._resetConfirmLoadout = nil

-- State for INI Import
M._showIniImportPopup = false
M._iniImportPath = ''
M._iniImportType = 'kissassist'  -- 'kissassist' or 'muleassist'
M._iniImportPreview = nil
M._iniImportError = nil
M._iniImportMerge = true  -- true = merge, false = replace

-- State for swap modal (when enabling spell exceeds gem limit)
M._showSwapModal = false
M._swapModalSpell = nil  -- {key = settingKey, name = displayName, abilitySet = setName}
M._swapSelectedIdx = nil  -- Index of the spell selected to swap out

--- Find which gem slot has a specific AbilitySet in the current loadout
local function findGemForAbilitySet(abilitySetName, loadoutName)
    local ConfigLoader = getConfigLoader()
    if not ConfigLoader or not ConfigLoader.current then return nil end

    -- Use getSpellLoadouts to support both old and new format
    local loadouts = ConfigLoader.getSpellLoadouts()
    local loadout = loadouts[loadoutName] or loadouts[loadoutName:lower()]
    if not loadout then return nil end

    local gems = loadout.gems
    if not gems then return nil end

    for gem, setName in pairs(gems) do
        if setName == abilitySetName then
            return tonumber(gem)
        end
    end
    return nil
end

--- Get the AbilitySet name for a setting key
-- @param settingKey string The setting key (e.g., "DoMez")
-- @param loadoutName string|nil Optional loadout name (allows AbilitySet-name keys)
-- @return string|nil The AbilitySet name or nil if no gem required
local function getAbilitySetForSetting(settingKey, loadoutName)
    local ConfigLoader = getConfigLoader()
    if not ConfigLoader or not ConfigLoader.current then return nil end

    local defaultConfig = ConfigLoader.getDefaultConfig()
    if not defaultConfig then return nil end

    local meta = defaultConfig[settingKey]
    if meta and meta.AbilitySet then
        return meta.AbilitySet
    end

    -- Support configs that use AbilitySet names directly as the "settingKey".
    if loadoutName and findGemForAbilitySet(settingKey, loadoutName) then
        return settingKey
    end

    return nil
end

--- Resolve the spell name for a setting key
-- Uses the spellLines pattern (like healing.lua) to find the best spell in the spellbook
-- @param settingKey string The setting key (e.g., "DoMez", "DoCripple")
-- @param loadoutName string|nil Optional loadout name (allows setName keys)
-- @return string|nil The resolved spell name (e.g., "Incapacitate") or nil if not resolvable
local function resolveSpellNameForSetting(settingKey, loadoutName)
    local ConfigLoader = getConfigLoader()
    if not ConfigLoader or not ConfigLoader.current then return nil end

    -- Get the AbilitySet (spellLine name) for this setting
    local spellLineName = getAbilitySetForSetting(settingKey, loadoutName)
    if not spellLineName then return nil end

    -- Use the correct pattern: look up the spellLine and find best in spellbook
    -- This matches the working pattern in resolveBestSpellFromBookForLine and healing.lua
    return resolveBestSpellFromBookForLine(spellLineName)
end

--- Check if a setting requires a gem slot (has an AbilitySet with a gem assignment)
-- @param settingKey string The setting key
-- @param loadoutName string Current loadout name
-- @return boolean True if the setting uses a gem slot
local function settingUsesGem(settingKey, loadoutName)
    local abilitySet = getAbilitySetForSetting(settingKey, loadoutName)
    if not abilitySet then
        return false
    end
    local gem = findGemForAbilitySet(abilitySet, loadoutName)
    return gem ~= nil
end

--- Get all enabled spells that use gem slots for a loadout
-- Note: This function uses forward declarations and will be populated after getLoadoutDefault is defined
-- @param loadoutName string Current loadout name
-- @return table Array of {key, name, gem, abilitySet} for enabled spells with gems
local getEnabledSpellsWithGems  -- forward declaration

-- Actual implementation (defined later, after getLoadoutDefault exists)
local function _getEnabledSpellsWithGemsImpl(loadoutName, getLoadoutDefaultFn)
    local ConfigLoader = getConfigLoader()
    if not ConfigLoader or not ConfigLoader.current then return {} end

    local defaultConfig = ConfigLoader.getDefaultConfig()
    if not defaultConfig then return {} end

    local loadouts = ConfigLoader.getSpellLoadouts()
    local loadout = loadouts[loadoutName] or loadouts[loadoutName:lower()]
    if not loadout then return {} end

    local gems = loadout.gems or {}

    -- Build reverse map: abilitySet -> gem
    local abilitySetToGem = {}
    for gem, setName in pairs(gems) do
        abilitySetToGem[setName] = tonumber(gem)
    end

    local result = {}

    for key, meta in pairs(defaultConfig) do
        if type(meta.Default) == 'boolean' and meta.AbilitySet then
            local abilitySet = meta.AbilitySet
            local gem = abilitySetToGem[abilitySet]

            if gem then
                -- Use the centralized getLoadoutDefault function for consistency
                local isEnabled = getLoadoutDefaultFn(loadoutName, key)

                if isEnabled then
                    table.insert(result, {
                        key = key,
                        name = meta.DisplayName or key,
                        gem = gem,
                        abilitySet = abilitySet,
                    })
                end
            end
        end
    end

    -- Sort by gem number for consistent ordering
    table.sort(result, function(a, b) return a.gem < b.gem end)

    return result
end

--- Count enabled spells that use gem slots
-- @param loadoutName string Current loadout name
-- @return number Count of enabled spells using gems
local function countEnabledSpellsWithGems(loadoutName)
    return #getEnabledSpellsWithGems(loadoutName)
end

--- Get the max allowed gem count (NumGems - 1, reserving last for buff rotation)
-- @return number Maximum gems to use
local function getMaxGems()
    local me = mq.TLO.Me
    local numGems = (me and me() and tonumber(me.NumGems())) or 0
    return math.max(0, (numGems or 0) - 1) -- Reserve last gem for rotating buff slot
end

--- Memorize a single spell by AbilitySet name
function M.memorizeAbilitySet(abilitySetName, loadoutName)
    local TL = getThrottledLog()
    local ConfigLoader = getConfigLoader()
    if not ConfigLoader or not ConfigLoader.current then
        if M.debugHealLayerLogging and TL then
            TL.log('mem_no_config_' .. tostring(abilitySetName), 5, 'memorizeAbilitySet: No ConfigLoader for %s', tostring(abilitySetName))
        end
        return false
    end

    local gemNum = findGemForAbilitySet(abilitySetName, loadoutName)
    if not gemNum then
        if M.debugHealLayerLogging and TL then
            TL.log('mem_no_gem_' .. tostring(abilitySetName), 5, 'memorizeAbilitySet: No gem found for %s in loadout %s', tostring(abilitySetName), tostring(loadoutName))
        end
        return false
    end

    local spellName = ConfigLoader.resolveAbilitySet(abilitySetName)
    if not spellName then
        if M.debugHealLayerLogging and TL then
            TL.log('mem_no_resolve_' .. tostring(abilitySetName), 5, 'memorizeAbilitySet: Could not resolve %s to a spell', tostring(abilitySetName))
        end
        mq.cmdf('/echo [SideKick] Could not resolve %s to a known spell', abilitySetName)
        return false
    end

    if M.debugHealLayerLogging and TL then
        TL.log('mem_start_' .. tostring(abilitySetName), 5, 'memorizeAbilitySet: %s -> spell=%s, gem=%d', tostring(abilitySetName), tostring(spellName), gemNum)
    end

    local currentSpell = mq.TLO.Me.Gem(gemNum)
    local currentName = currentSpell and currentSpell.Name and currentSpell.Name() or ''
    if currentName == spellName then
        return false
    end

    M._applyState = {
        gems = {{ gem = gemNum, spell = spellName }},
        idx = 1,
        phase = 'ready',
        waitUntil = 0,
        onComplete = nil,
        loadoutName = loadoutName,
        isSingleSpell = true,
    }

    mq.cmdf('/echo [SideKick] Memorizing %s in gem %d...', spellName, gemNum)
    return true
end

--- Apply a spell loadout (memorize spells to gem bar)
function M.applyLoadout(loadoutName, onComplete)
    local SpellsetManager = getSpellsetManager()
    if SpellsetManager and SpellsetManager.initialized and SpellsetManager.setLoadout then
        return SpellsetManager.setLoadout(loadoutName, true)
    end

    local ConfigLoader = getConfigLoader()
    if not ConfigLoader or not ConfigLoader.current then
        mq.cmd('/echo [SideKick] No class config loaded')
        return false
    end

    local resolved = ConfigLoader.resolveLoadout(loadoutName)
    if not resolved or not next(resolved) then
        mq.cmd('/echo [SideKick] No spells resolved for loadout: ' .. tostring(loadoutName))
        return false
    end

    local gems = {}
    for gem, spellName in pairs(resolved) do
        table.insert(gems, { gem = tonumber(gem), spell = spellName })
    end
    table.sort(gems, function(a, b) return a.gem < b.gem end)

    mq.cmdf('/echo [SideKick] Applying %s loadout (%d spells)...', loadoutName, #gems)

    M._applyState = {
        gems = gems,
        idx = 1,
        phase = 'ready',
        waitUntil = 0,
        onComplete = onComplete,
        loadoutName = loadoutName,
    }

    return true
end

--- Check if currently applying a loadout
function M.isApplying()
    return M._applyState ~= nil
end

--- Process pending loadout application (call from main loop)
function M.processPending()
    local state = M._applyState
    if not state then return end

    local now = os.clock()

    if state.phase == 'waiting' then
        if now < state.waitUntil then
            return
        end
        state.phase = 'ready'
        state.idx = state.idx + 1
    end

    if state.phase == 'memorizing' then
        local entry = state.gems[state.idx]
        local currentSpell = mq.TLO.Me.Gem(entry.gem)
        local currentName = currentSpell and currentSpell.Name and currentSpell.Name() or ''

        if currentName == entry.spell then
            state.phase = 'waiting'
            state.waitUntil = now + 0.2
        elseif now > state.waitUntil then
            state.phase = 'waiting'
            state.waitUntil = now + 0.1
        end
        return
    end

    if state.phase == 'ready' then
        if state.idx > #state.gems then
            if not state.isSingleSpell then
                mq.cmd('/echo [SideKick] Loadout applied!')
            end
            if state.onComplete then state.onComplete() end
            M._applyState = nil
            return
        end

        local entry = state.gems[state.idx]
        local currentSpell = mq.TLO.Me.Gem(entry.gem)
        local currentName = currentSpell and currentSpell.Name and currentSpell.Name() or ''

        if currentName == entry.spell then
            state.idx = state.idx + 1
            return
        end

        mq.cmdf('/memspell %d "%s"', entry.gem, entry.spell)
        state.phase = 'memorizing'
        state.waitUntil = now + 5.0
    end
end

--- Group settings by category
local function groupByCategory(defaultConfig)
    local categories = {}
    local categoryOrder = {}

    for key, meta in pairs(defaultConfig) do
        local cat = meta.Category or "General"

        if not categories[cat] then
            categories[cat] = {}
            table.insert(categoryOrder, cat)
        end

        table.insert(categories[cat], {
            key = key,
            meta = meta,
        })
    end

    table.sort(categoryOrder)

    for _, cat in ipairs(categoryOrder) do
        table.sort(categories[cat], function(a, b)
            return (a.meta.DisplayName or a.key) < (b.meta.DisplayName or b.key)
        end)
    end

    return categories, categoryOrder
end

--- Render the loadout management UI (dropdown, save, save as, delete)
function M.renderLoadoutManager(settings, setFunc)
    local SpellsetManager = getSpellsetManager()
    local Core = getCore()

    if not SpellsetManager then
        imgui.TextColored(0.9, 0.3, 0.3, 1, "SpellsetManager not available")
        return settings.SpellLoadout or ''
    end

    if not SpellsetManager.initialized then
        SpellsetManager.init()
    end

    local loadouts = SpellsetManager.getAvailableLoadouts()
    local currentLoadoutName = SpellsetManager.getCurrentLoadoutName() or ''
    local isCustom = SpellsetManager.isInCustomMode()
    local isApplying = M.isApplying()

    local displayName = currentLoadoutName
    if isCustom then
        displayName = currentLoadoutName ~= '' and (currentLoadoutName .. ' (Modified)') or '(Custom)'
    end

    imgui.Text("Spell Loadout:")
    imgui.SameLine()

    local comboItems = {}
    local currentIdx = 1
    for i, l in ipairs(loadouts) do
        local label = l.name
        if l.isBuiltIn then
            label = label .. ' [Built-in]'
        end
        table.insert(comboItems, label)
        if l.name == currentLoadoutName then
            currentIdx = i
        end
    end

    if isCustom then
        table.insert(comboItems, 1, displayName)
        currentIdx = 1
    end

    imgui.SetNextItemWidth(180)
    local newIdx = imgui.Combo("##loadout_selector", currentIdx, comboItems, #comboItems)

    if newIdx ~= currentIdx then
        local adjustedIdx = isCustom and (newIdx - 1) or newIdx
        if adjustedIdx >= 1 and adjustedIdx <= #loadouts then
            local selectedLoadout = loadouts[adjustedIdx]
            SpellsetManager.setLoadout(selectedLoadout.name, false)
            if setFunc then
                setFunc('SpellLoadout', selectedLoadout.name)
            end
        end
    end

    if currentLoadoutName ~= '' then
        local loadout = SpellsetManager.builtInLoadouts[currentLoadoutName] or SpellsetManager.customLoadouts[currentLoadoutName]
        if loadout and loadout.description and loadout.description ~= '' then
            imgui.SameLine()
            imgui.TextColored(0.6, 0.6, 0.6, 1, "- " .. loadout.description)
        end
    end

    imgui.Spacing()

    if isApplying then
        imgui.PushStyleColor(ImGuiCol.Button, 0.5, 0.5, 0.2, 1.0)
        imgui.PushStyleColor(ImGuiCol.ButtonHovered, 0.6, 0.6, 0.3, 1.0)
        imgui.PushStyleColor(ImGuiCol.ButtonActive, 0.4, 0.4, 0.1, 1.0)
    end
    local applyLabel = isApplying and "Applying..." or "Apply"
    if imgui.Button(applyLabel .. "##apply_loadout") then
        if not isApplying and currentLoadoutName ~= '' then
            SpellsetManager.setLoadout(currentLoadoutName, true)
        end
    end
    if isApplying then
        imgui.PopStyleColor(3)
    end
    if imgui.IsItemHovered() then
        imgui.SetTooltip(isApplying and "Memorizing spells..." or "Memorize spells for this loadout")
    end

    imgui.SameLine()
    local canSave = currentLoadoutName ~= '' and not SpellsetManager.isBuiltInLoadout(currentLoadoutName) and isCustom
    if not canSave then
        imgui.PushStyleColor(ImGuiCol.Button, 0.3, 0.3, 0.3, 0.5)
        imgui.PushStyleColor(ImGuiCol.ButtonHovered, 0.3, 0.3, 0.3, 0.5)
        imgui.PushStyleColor(ImGuiCol.ButtonActive, 0.3, 0.3, 0.3, 0.5)
    end
    if imgui.Button("Save##save_loadout") then
        if canSave then
            local loadout = SpellsetManager.customLoadouts[currentLoadoutName]
            local desc = loadout and loadout.description or ''
            SpellsetManager.saveLoadout(currentLoadoutName, desc)
        end
    end
    if not canSave then
        imgui.PopStyleColor(3)
    end
    if imgui.IsItemHovered() then
        if SpellsetManager.isBuiltInLoadout(currentLoadoutName) then
            imgui.SetTooltip("Cannot overwrite built-in loadout. Use 'Save As' instead.")
        elseif not isCustom then
            imgui.SetTooltip("No changes to save")
        else
            imgui.SetTooltip("Save current spell bar to this loadout")
        end
    end

    imgui.SameLine()
    if imgui.Button("Save As...##saveas_loadout") then
        M._showSaveAsPopup = true
        M._saveAsName = ''
    end
    if imgui.IsItemHovered() then
        imgui.SetTooltip("Save current spell bar as a new custom loadout")
    end

    imgui.SameLine()
    local canDelete = currentLoadoutName ~= '' and not SpellsetManager.isBuiltInLoadout(currentLoadoutName)
    if not canDelete then
        imgui.PushStyleColor(ImGuiCol.Button, 0.3, 0.3, 0.3, 0.5)
        imgui.PushStyleColor(ImGuiCol.ButtonHovered, 0.3, 0.3, 0.3, 0.5)
        imgui.PushStyleColor(ImGuiCol.ButtonActive, 0.3, 0.3, 0.3, 0.5)
    else
        imgui.PushStyleColor(ImGuiCol.Button, 0.6, 0.2, 0.2, 0.8)
        imgui.PushStyleColor(ImGuiCol.ButtonHovered, 0.8, 0.3, 0.3, 1.0)
        imgui.PushStyleColor(ImGuiCol.ButtonActive, 0.5, 0.1, 0.1, 1.0)
    end
    if imgui.Button("Delete##delete_loadout") then
        if canDelete then
            M._deleteConfirmName = currentLoadoutName
        end
    end
    imgui.PopStyleColor(3)
    if imgui.IsItemHovered() then
        imgui.SetTooltip(canDelete and "Delete this custom loadout" or "Cannot delete built-in loadout")
    end

    -- Reset to Default button (only for modified built-in loadouts)
    local canReset = currentLoadoutName ~= '' and SpellsetManager.isBuiltInLoadout(currentLoadoutName) and SpellsetManager.isModified(currentLoadoutName)
    if canReset then
        imgui.SameLine()
        imgui.PushStyleColor(ImGuiCol.Button, 0.5, 0.4, 0.2, 0.8)
        imgui.PushStyleColor(ImGuiCol.ButtonHovered, 0.6, 0.5, 0.3, 1.0)
        imgui.PushStyleColor(ImGuiCol.ButtonActive, 0.4, 0.3, 0.1, 1.0)
        if imgui.Button("Reset##reset_loadout") then
            M._showResetConfirm = true
            M._resetConfirmLoadout = currentLoadoutName
        end
        imgui.PopStyleColor(3)
        if imgui.IsItemHovered() then
            imgui.SetTooltip("Reset this loadout to its default state (removes all customizations)")
        end
    end

    imgui.SameLine()
    imgui.Text("  ")
    imgui.SameLine()
    local autoDetect = SpellsetManager.isDetectionEnabled()
    local newAutoDetect, changed = imgui.Checkbox("Auto-Detect##autodetect", autoDetect)
    if changed then
        SpellsetManager.setDetectionEnabled(newAutoDetect)
        if setFunc then
            setFunc('AutoDetectSpellChanges', newAutoDetect)
        end
    end
    if imgui.IsItemHovered() then
        imgui.SetTooltip("Automatically detect manual spell changes and mark loadout as modified")
    end

    if M._showSaveAsPopup then
        imgui.OpenPopup("Save As##saveas_popup")
    end

    local popupOpen = imgui.BeginPopupModal("Save As##saveas_popup", nil, ImGuiWindowFlags.AlwaysAutoResize)
    if popupOpen then
        imgui.Text("Enter a name for the new loadout:")
        imgui.Spacing()
        imgui.SetNextItemWidth(200)
        M._saveAsName = imgui.InputText("##saveas_name", M._saveAsName or '', 64)
        imgui.Spacing()
        imgui.Separator()
        imgui.Spacing()

        local nameValid = M._saveAsName and M._saveAsName ~= ''
        local nameExists = nameValid and SpellsetManager.loadoutExists(M._saveAsName)

        if not nameValid then
            imgui.PushStyleColor(ImGuiCol.Button, 0.3, 0.3, 0.3, 0.5)
            imgui.PushStyleColor(ImGuiCol.ButtonHovered, 0.3, 0.3, 0.3, 0.5)
            imgui.PushStyleColor(ImGuiCol.ButtonActive, 0.3, 0.3, 0.3, 0.5)
        elseif nameExists then
            imgui.PushStyleColor(ImGuiCol.Button, 0.7, 0.5, 0.2, 0.8)
            imgui.PushStyleColor(ImGuiCol.ButtonHovered, 0.8, 0.6, 0.3, 1.0)
            imgui.PushStyleColor(ImGuiCol.ButtonActive, 0.6, 0.4, 0.1, 1.0)
        else
            imgui.PushStyleColor(ImGuiCol.Button, 0.2, 0.6, 0.2, 0.8)
            imgui.PushStyleColor(ImGuiCol.ButtonHovered, 0.3, 0.7, 0.3, 1.0)
            imgui.PushStyleColor(ImGuiCol.ButtonActive, 0.1, 0.5, 0.1, 1.0)
        end

        local saveLabel = nameExists and "Overwrite" or "Save"
        if imgui.Button(saveLabel .. "##saveas_confirm") then
            if nameValid then
                SpellsetManager.saveLoadout(M._saveAsName)
                if setFunc then
                    setFunc('SpellLoadout', M._saveAsName)
                end
                M._showSaveAsPopup = false
                imgui.CloseCurrentPopup()
            end
        end
        imgui.PopStyleColor(3)

        imgui.SameLine()
        if imgui.Button("Cancel##saveas_cancel") then
            M._showSaveAsPopup = false
            imgui.CloseCurrentPopup()
        end

        imgui.EndPopup()
    else
        M._showSaveAsPopup = false
    end

    if M._deleteConfirmName then
        imgui.OpenPopup("Confirm Delete##delete_popup")
    end

    local deletePopupOpen = imgui.BeginPopupModal("Confirm Delete##delete_popup", nil, ImGuiWindowFlags.AlwaysAutoResize)
    if deletePopupOpen then
        imgui.Text("Are you sure you want to delete this loadout?")
        imgui.Spacing()
        imgui.TextColored(0.9, 0.6, 0.3, 1, M._deleteConfirmName or '')
        imgui.Spacing()
        imgui.Separator()
        imgui.Spacing()

        imgui.PushStyleColor(ImGuiCol.Button, 0.6, 0.2, 0.2, 0.8)
        imgui.PushStyleColor(ImGuiCol.ButtonHovered, 0.8, 0.3, 0.3, 1.0)
        imgui.PushStyleColor(ImGuiCol.ButtonActive, 0.5, 0.1, 0.1, 1.0)
        if imgui.Button("Delete##delete_confirm") then
            SpellsetManager.deleteLoadout(M._deleteConfirmName)
            M._deleteConfirmName = nil
            imgui.CloseCurrentPopup()
        end
        imgui.PopStyleColor(3)

        imgui.SameLine()
        if imgui.Button("Cancel##delete_cancel") then
            M._deleteConfirmName = nil
            imgui.CloseCurrentPopup()
        end

        imgui.EndPopup()
    else
        M._deleteConfirmName = nil
    end

    -- Reset to Default confirmation popup
    if M._showResetConfirm then
        imgui.OpenPopup("Confirm Reset##reset_popup")
    end

    local resetPopupOpen = imgui.BeginPopupModal("Confirm Reset##reset_popup", nil, ImGuiWindowFlags.AlwaysAutoResize)
    if resetPopupOpen then
        imgui.Text("Are you sure you want to reset this loadout to default?")
        imgui.Spacing()
        imgui.TextColored(0.9, 0.6, 0.3, 1, M._resetConfirmLoadout or '')
        imgui.Spacing()
        imgui.TextColored(0.7, 0.7, 0.7, 1, "This will remove all customizations (enabled/disabled abilities,")
        imgui.TextColored(0.7, 0.7, 0.7, 1, "layer assignments, conditions, etc.) and restore defaults.")
        imgui.Spacing()
        imgui.Separator()
        imgui.Spacing()

        imgui.PushStyleColor(ImGuiCol.Button, 0.5, 0.4, 0.2, 0.8)
        imgui.PushStyleColor(ImGuiCol.ButtonHovered, 0.6, 0.5, 0.3, 1.0)
        imgui.PushStyleColor(ImGuiCol.ButtonActive, 0.4, 0.3, 0.1, 1.0)
        if imgui.Button("Reset to Default##reset_confirm") then
            if M._resetConfirmLoadout and SpellsetManager.resetToDefault then
                SpellsetManager.resetToDefault(M._resetConfirmLoadout)
            end
            M._showResetConfirm = false
            M._resetConfirmLoadout = nil
            imgui.CloseCurrentPopup()
        end
        imgui.PopStyleColor(3)

        imgui.SameLine()
        if imgui.Button("Cancel##reset_cancel") then
            M._showResetConfirm = false
            M._resetConfirmLoadout = nil
            imgui.CloseCurrentPopup()
        end

        imgui.EndPopup()
    else
        M._showResetConfirm = false
        M._resetConfirmLoadout = nil
    end

    return currentLoadoutName
end

--- Render INI Import section
function M.renderIniImport(settings, setFunc)
    local IniImporter = getIniImporter()
    local ConfigLoader = getConfigLoader()
    local Core = getCore()

    if not IniImporter then
        return
    end

    imgui.Spacing()
    imgui.Separator()
    imgui.Text("Import Configuration")
    imgui.Spacing()

    -- Import buttons
    if imgui.Button("Import KissAssist INI##import_kiss") then
        M._showIniImportPopup = true
        M._iniImportType = 'kissassist'
        M._iniImportPath = ''
        M._iniImportPreview = nil
        M._iniImportError = nil
    end
    if imgui.IsItemHovered() then
        imgui.SetTooltip("Import spell conditions from a KissAssist INI file")
    end

    imgui.SameLine()

    if imgui.Button("Import MuleAssist INI##import_mule") then
        M._showIniImportPopup = true
        M._iniImportType = 'muleassist'
        M._iniImportPath = ''
        M._iniImportPreview = nil
        M._iniImportError = nil
    end
    if imgui.IsItemHovered() then
        imgui.SetTooltip("Import spell conditions from a MuleAssist INI file")
    end

    -- Import popup
    if M._showIniImportPopup then
        imgui.OpenPopup("Import INI##ini_import_popup")
    end

    local popupFlags = bit32.bor(ImGuiWindowFlags.AlwaysAutoResize)
    local popupOpen = imgui.BeginPopupModal("Import INI##ini_import_popup", nil, popupFlags)
    if popupOpen then
        local typeLabel = M._iniImportType == 'kissassist' and 'KissAssist' or 'MuleAssist'
        imgui.Text(string.format("Import %s Configuration", typeLabel))
        imgui.Separator()
        imgui.Spacing()

        -- Path input
        imgui.Text("INI File Path:")
        imgui.SetNextItemWidth(400)
        M._iniImportPath = imgui.InputText("##ini_path", M._iniImportPath or '', 512)

        imgui.Spacing()

        -- Merge vs Replace
        local mergeSelected = M._iniImportMerge
        if imgui.RadioButton("Merge with existing##merge", mergeSelected) then
            M._iniImportMerge = true
        end
        if imgui.IsItemHovered() then
            imgui.SetTooltip("Keep existing conditions, add new ones from INI")
        end
        imgui.SameLine()
        if imgui.RadioButton("Replace all##replace", not mergeSelected) then
            M._iniImportMerge = false
        end
        if imgui.IsItemHovered() then
            imgui.SetTooltip("Replace all conditions with ones from INI")
        end

        imgui.Spacing()

        -- Preview button
        if imgui.Button("Preview##preview_import") then
            if M._iniImportPath and M._iniImportPath ~= '' then
                local ok, result
                if M._iniImportType == 'kissassist' then
                    ok, result = pcall(IniImporter.parseKissAssist, M._iniImportPath)
                else
                    ok, result = pcall(IniImporter.parseMuleAssist, M._iniImportPath)
                end

                if ok and result then
                    M._iniImportPreview = result
                    M._iniImportError = nil
                else
                    M._iniImportPreview = nil
                    M._iniImportError = tostring(result) or "Failed to parse INI file"
                end
            else
                M._iniImportError = "Please enter a file path"
            end
        end

        imgui.SameLine()

        -- Import button
        local canImport = M._iniImportPreview ~= nil
        if not canImport then
            imgui.PushStyleColor(ImGuiCol.Button, 0.3, 0.3, 0.3, 0.5)
            imgui.PushStyleColor(ImGuiCol.ButtonHovered, 0.3, 0.3, 0.3, 0.5)
            imgui.PushStyleColor(ImGuiCol.ButtonActive, 0.3, 0.3, 0.3, 0.5)
        else
            imgui.PushStyleColor(ImGuiCol.Button, 0.2, 0.6, 0.2, 0.8)
            imgui.PushStyleColor(ImGuiCol.ButtonHovered, 0.3, 0.7, 0.3, 1.0)
            imgui.PushStyleColor(ImGuiCol.ButtonActive, 0.1, 0.5, 0.1, 1.0)
        end

        if imgui.Button("Import##do_import") then
            if canImport and Core then
                -- Apply imported conditions to settings
                local imported = M._iniImportPreview
                local count = 0

                if imported.conditions then
                    for key, condFunc in pairs(imported.conditions) do
                        if M._iniImportMerge and settings[key] then
                            -- Skip if merging and already exists
                        else
                            if setFunc then
                                setFunc(key, condFunc)
                            end
                            count = count + 1
                        end
                    end
                end

                if imported.spells then
                    for _, spell in ipairs(imported.spells) do
                        if spell.condition then
                            local key = 'do' .. (spell.spell or ''):gsub('%s+', '')
                            if M._iniImportMerge and settings[key] then
                                -- Skip
                            else
                                if setFunc then
                                    setFunc(key .. '_Condition', spell.condition)
                                end
                                count = count + 1
                            end
                        end
                    end
                end

                mq.cmdf('/echo [SideKick] Imported %d conditions from %s', count, typeLabel)

                M._showIniImportPopup = false
                M._iniImportPreview = nil
                imgui.CloseCurrentPopup()
            end
        end
        imgui.PopStyleColor(3)

        imgui.SameLine()

        if imgui.Button("Cancel##cancel_import") then
            M._showIniImportPopup = false
            M._iniImportPreview = nil
            M._iniImportError = nil
            imgui.CloseCurrentPopup()
        end

        -- Error display
        if M._iniImportError then
            imgui.Spacing()
            imgui.TextColored(0.9, 0.3, 0.3, 1, "Error: " .. M._iniImportError)
        end

        -- Preview display
        if M._iniImportPreview then
            imgui.Spacing()
            imgui.Separator()
            imgui.Text("Preview:")

            if imgui.BeginChild("##preview_scroll", 400, 200, true) then
                local preview = M._iniImportPreview

                if preview.spells and #preview.spells > 0 then
                    imgui.TextColored(0.3, 0.8, 0.3, 1, string.format("Spells: %d", #preview.spells))
                    for i, spell in ipairs(preview.spells) do
                        if i <= 10 then
                            local condText = spell.condition and " [has cond]" or ""
                            imgui.BulletText(string.format("%s (%s)%s",
                                spell.spell or "?",
                                spell.category or "?",
                                condText))
                        elseif i == 11 then
                            imgui.TextColored(0.6, 0.6, 0.6, 1, string.format("  ... and %d more", #preview.spells - 10))
                        end
                    end
                end

                if preview.conditions then
                    local condCount = 0
                    for _ in pairs(preview.conditions) do condCount = condCount + 1 end
                    if condCount > 0 then
                        imgui.Spacing()
                        imgui.TextColored(0.3, 0.8, 0.3, 1, string.format("Conditions: %d", condCount))
                    end
                end

                if preview.burns and #preview.burns > 0 then
                    imgui.Spacing()
                    imgui.TextColored(0.8, 0.6, 0.3, 1, string.format("Burns: %d", #preview.burns))
                end

                if preview.settings then
                    local setCount = 0
                    for _ in pairs(preview.settings) do setCount = setCount + 1 end
                    if setCount > 0 then
                        imgui.Spacing()
                        imgui.TextColored(0.6, 0.6, 0.8, 1, string.format("Settings: %d", setCount))
                    end
                end
            end
            imgui.EndChild()
        end

        imgui.EndPopup()
    else
        M._showIniImportPopup = false
    end
end

--- Render the swap modal (shown when enabling a spell would exceed max gems)
-- @param loadoutName string Current loadout name
function M.renderSwapModal(loadoutName)
    local SpellsetManager = getSpellsetManager()

    if M._showSwapModal then
        imgui.OpenPopup("Spell Bar Full##swap_modal")
    end

    local modalFlags = bit32.bor(ImGuiWindowFlags.AlwaysAutoResize)
    local modalOpen = imgui.BeginPopupModal("Spell Bar Full##swap_modal", nil, modalFlags)

    if modalOpen then
        local newSpell = M._swapModalSpell
        if not newSpell then
            imgui.Text("Error: No spell selected")
            if imgui.Button("Close##swap_close") then
                M._showSwapModal = false
                M._swapModalSpell = nil
                M._swapSelectedIdx = nil
                imgui.CloseCurrentPopup()
            end
            imgui.EndPopup()
            return
        end

        -- Header text
        imgui.TextWrapped("All spell gem slots are in use. Select a spell to replace:")
        imgui.Spacing()
        imgui.Separator()
        imgui.Spacing()

        -- Get enabled spells with gems
        local enabledSpells = getEnabledSpellsWithGems(loadoutName)
        local maxGems = getMaxGems()

        -- Show the spell user wants to enable
        imgui.TextColored(0.3, 0.8, 0.3, 1, "Enable: " .. (newSpell.name or newSpell.key))
        imgui.Spacing()

        -- Show current usage
        imgui.TextColored(0.7, 0.7, 0.7, 1, string.format("(%d/%d gems in use, last gem reserved for buffs)", #enabledSpells, maxGems))
        imgui.Spacing()

        -- Radio buttons for each enabled spell
        imgui.Text("Currently enabled spells:")
        imgui.Spacing()

        for i, spell in ipairs(enabledSpells) do
            imgui.PushID("swap_radio_" .. i)

            local isSelected = (M._swapSelectedIdx == i)
            local label = string.format("Gem %d: %s", spell.gem, spell.name)

            if imgui.RadioButton(label, isSelected) then
                M._swapSelectedIdx = i
            end

            imgui.PopID()
        end

        imgui.Spacing()
        imgui.Separator()
        imgui.Spacing()

        -- Buttons
        local canReplace = M._swapSelectedIdx ~= nil and M._swapSelectedIdx >= 1 and M._swapSelectedIdx <= #enabledSpells

        -- Cancel button
        if imgui.Button("Cancel##swap_cancel") then
            M._showSwapModal = false
            M._swapModalSpell = nil
            M._swapSelectedIdx = nil
            imgui.CloseCurrentPopup()
        end

        imgui.SameLine()

        -- Replace button
        if not canReplace then
            imgui.PushStyleColor(ImGuiCol.Button, 0.3, 0.3, 0.3, 0.5)
            imgui.PushStyleColor(ImGuiCol.ButtonHovered, 0.3, 0.3, 0.3, 0.5)
            imgui.PushStyleColor(ImGuiCol.ButtonActive, 0.3, 0.3, 0.3, 0.5)
        else
            imgui.PushStyleColor(ImGuiCol.Button, 0.2, 0.6, 0.2, 0.8)
            imgui.PushStyleColor(ImGuiCol.ButtonHovered, 0.3, 0.7, 0.3, 1.0)
            imgui.PushStyleColor(ImGuiCol.ButtonActive, 0.1, 0.5, 0.1, 1.0)
        end

        if imgui.Button("Replace Selected##swap_confirm") then
            if canReplace then
                local oldSpell = enabledSpells[M._swapSelectedIdx]

                -- Disable the old spell
                if SpellsetManager and SpellsetManager.setLoadoutSetting then
                    SpellsetManager.setLoadoutSetting(loadoutName, oldSpell.key, false)
                end

                -- Enable the new spell
                if SpellsetManager and SpellsetManager.setLoadoutSetting then
                    SpellsetManager.setLoadoutSetting(loadoutName, newSpell.key, true)
                end

                -- Trigger auto-memorize for the new spell
                local abilitySet = newSpell.abilitySet or getAbilitySetForSetting(newSpell.key, loadoutName)
                if abilitySet then
                    M.memorizeAbilitySet(abilitySet, loadoutName)
                end

                -- Clear state
                M._showSwapModal = false
                M._swapModalSpell = nil
                M._swapSelectedIdx = nil
                imgui.CloseCurrentPopup()
            end
        end

        imgui.PopStyleColor(3)

        if not canReplace and imgui.IsItemHovered() then
            imgui.SetTooltip("Select a spell to replace first")
        end

        imgui.EndPopup()
    else
        -- Modal closed, clear state
        M._showSwapModal = false
        M._swapModalSpell = nil
        M._swapSelectedIdx = nil
    end
end

--- Check if enabling a spell would exceed the gem limit and show swap modal if needed
-- @param settingKey string The setting key to enable
-- @param displayName string The display name of the setting
-- @param loadoutName string Current loadout name
-- @return boolean True if swap modal was shown (caller should NOT enable the spell), false if enable can proceed
function M.checkAndShowSwapModal(settingKey, displayName, loadoutName)
    -- Check if this setting uses a gem
    local abilitySet = getAbilitySetForSetting(settingKey, loadoutName)
    if not abilitySet then
        return false  -- No gem needed, enable can proceed
    end

    local gem = findGemForAbilitySet(abilitySet, loadoutName)
    if not gem then
        return false  -- No gem assignment in this loadout, enable can proceed
    end

    -- Count current enabled spells with gems
    local enabledCount = countEnabledSpellsWithGems(loadoutName)
    local maxGems = getMaxGems()

    if enabledCount >= maxGems then
        -- At or over limit, show swap modal
        M._showSwapModal = true
        M._swapModalSpell = {
            key = settingKey,
            name = displayName,
            abilitySet = abilitySet,
        }
        M._swapSelectedIdx = nil
        return true  -- Caller should NOT enable the spell yet
    end

    return false  -- Under limit, enable can proceed
end

-- Layer order and display names
M._layerOrder = { "emergency", "heal", "aggro", "defenses", "support", "combat", "burn", "utility", "buff" }
M._layerDisplayNames = {
    emergency = "Emergency",
    heal = "Heal",
    aggro = "Aggro",
    defenses = "Defenses",
    support = "Support",
    combat = "Combat",
    burn = "Burn",
    utility = "Utility",
    buff = "Buff (OOC)",
}

local function inferLayerFromMeta(meta)
    local cat = tostring((meta and meta.Category) or ''):lower()
    if cat == '' then return 'utility' end
    if cat:find('emerg') then return 'emergency' end
    if cat:find('heal') then return 'heal' end
    if cat:find('aggro') or cat:find('hate') or cat:find('tank') then return 'aggro' end
    if cat:find('defen') or cat:find('mitig') then return 'defenses' end
    if cat == 'cc' or cat:find('debuff') or cat:find('support') or cat:find('mez') or cat:find('slow') then return 'support' end
    if cat:find('burn') then return 'burn' end
    if cat:find('combat') or cat:find('dps') then return 'combat' end
    if cat:find('buff') then return 'buff' end
    return 'utility'
end

-- State for drag-drop
M._dragPayload = nil  -- {settingKey, sourceLayer}

-- State for collapsed layers
M._collapsedLayers = {}

-- State for temporarily disabled abilities (not persisted, cleared on script reload)
-- This is a runtime-only flag that makes conditions return false
M._temporarilyDisabled = {}  -- {[settingKey] = true}

-- State for right-click context menu
M._contextMenuTarget = nil  -- {settingKey, layer, displayName} for the spell being right-clicked
M._contextMenuOpenRequested = false

--- Get layer assignments for current loadout from SpellsetManager or class config
-- Returns {settingKey = layer} mapping
local function getLayerAssignments(loadoutName)
    local SpellsetManager = getSpellsetManager()
    local ConfigLoader = getConfigLoader()

    local assignments = {}

    -- First get base assignments from class config
    if ConfigLoader and ConfigLoader.current then
        local loadouts = ConfigLoader.getSpellLoadouts()
        local loadout = loadouts[loadoutName] or loadouts[loadoutName:lower()]
        if loadout and loadout.layerAssignments then
            for key, layer in pairs(loadout.layerAssignments) do
                assignments[key] = layer
            end
        end
    end

    -- Apply overrides from SpellsetManager
    if SpellsetManager and SpellsetManager.initialized then
        local loadout = SpellsetManager.getLoadout(loadoutName)
        if loadout and loadout.layerOverrides then
            for key, layer in pairs(loadout.layerOverrides) do
                assignments[key] = layer
            end
        end
    end

    return assignments
end

--- Get layer order for current loadout
-- Returns {layer = {settingKey1, settingKey2, ...}} mapping
local function getLayerOrder(loadoutName)
    local SpellsetManager = getSpellsetManager()
    local ConfigLoader = getConfigLoader()

    local layerOrder = {}

    -- First get base order from class config
    if ConfigLoader and ConfigLoader.current then
        local loadouts = ConfigLoader.getSpellLoadouts()
        local loadout = loadouts[loadoutName] or loadouts[loadoutName:lower()]
        if loadout and loadout.layerOrder then
            for layer, order in pairs(loadout.layerOrder) do
                layerOrder[layer] = {}
                for _, key in ipairs(order) do
                    table.insert(layerOrder[layer], key)
                end
            end
        end
    end

    -- Apply overrides from SpellsetManager
    if SpellsetManager and SpellsetManager.initialized then
        local loadout = SpellsetManager.getLoadout(loadoutName)
        if loadout and loadout.layerOrderOverrides then
            for layer, order in pairs(loadout.layerOrderOverrides) do
                layerOrder[layer] = {}
                for _, key in ipairs(order) do
                    table.insert(layerOrder[layer], key)
                end
            end
        end
    end

    return layerOrder
end

--- Get default enabled state for a setting in a loadout
local function getLoadoutDefault(loadoutName, settingKey)
    local SpellsetManager = getSpellsetManager()
    local ConfigLoader = getConfigLoader()

    local defaultConfig = ConfigLoader and ConfigLoader.getDefaultConfig and ConfigLoader.getDefaultConfig() or {}
    local meta = defaultConfig and defaultConfig[settingKey] or nil
    local abilitySet = meta and meta.AbilitySet

    -- Check SpellsetManager overrides first
    if SpellsetManager and SpellsetManager.initialized then
        local loadout = SpellsetManager.getLoadout(loadoutName)
        if loadout then
            -- Check enabled overrides
            if loadout.enabledOverrides then
                for _, key in ipairs(loadout.enabledOverrides) do
                    if key == settingKey then return true end
                    if type(abilitySet) == 'string' and abilitySet ~= '' and key == abilitySet then return true end
                end
            end
            -- Check disabled overrides
            if loadout.disabledOverrides then
                for _, key in ipairs(loadout.disabledOverrides) do
                    if key == settingKey then return false end
                    if type(abilitySet) == 'string' and abilitySet ~= '' and key == abilitySet then return false end
                end
            end
        end
    end

    -- Fall back to class config defaults
    if ConfigLoader and ConfigLoader.current then
        local loadouts = ConfigLoader.getSpellLoadouts()
        local loadout = loadouts[loadoutName] or loadouts[loadoutName:lower()]
        if loadout and loadout.defaults and loadout.defaults[settingKey] ~= nil then
            return loadout.defaults[settingKey]
        end
    end

    -- Fall back to DefaultConfig
    if meta and meta.Default ~= nil then
        return meta.Default
    end

    -- If this key is an AbilitySet present in the loadout's gem list, default it to enabled.
    if loadoutName and findGemForAbilitySet(settingKey, loadoutName) then
        return true
    end

    return false
end

-- Now that getLoadoutDefault is defined, wire up the forward declaration
getEnabledSpellsWithGems = function(loadoutName)
    return _getEnabledSpellsWithGemsImpl(loadoutName, getLoadoutDefault)
end

--- Group settings by layer for a loadout
-- Returns {layer = {enabled = {...}, disabled = {...}}}
local function groupSettingsByLayer(loadoutName, settings)
    local ConfigLoader = getConfigLoader()
    if not ConfigLoader or not ConfigLoader.current then return {} end

    local defaultConfig = ConfigLoader.getDefaultConfig()
    if not defaultConfig then return {} end

    -- Build AbilitySet -> settingKey map from DefaultConfig metadata to avoid creating duplicate "synthetic"
    -- entries that don't actually control the rotation.
    local abilitySetToKey = {}
    for settingKey, meta in pairs(defaultConfig) do
        local setName = meta and meta.AbilitySet
        if type(setName) == 'string' and setName ~= '' and not abilitySetToKey[setName] then
            abilitySetToKey[setName] = settingKey
        end
    end

    local layerAssignments = getLayerAssignments(loadoutName)
    local layerOrder = getLayerOrder(loadoutName)

    -- Build map of all settings in each layer
    local layers = {}
    for _, layer in ipairs(M._layerOrder) do
        layers[layer] = { enabled = {}, disabled = {} }
    end

    -- Assign each boolean setting to its layer
    for key, meta in pairs(defaultConfig) do
        if type(meta.Default) == 'boolean' then
            local layer = layerAssignments[key] or inferLayerFromMeta(meta)
            if not layers[layer] then layer = 'utility' end
            if layers[layer] then
                local isEnabled = getLoadoutDefault(loadoutName, key)
                local entry = {
                    key = key,
                    meta = meta,
                    displayName = meta.DisplayName or key,
                }
                if isEnabled then
                    table.insert(layers[layer].enabled, entry)
                else
                    table.insert(layers[layer].disabled, entry)
                end
            end
        end
    end

    -- Add synthetic entries for the current loadout's gem AbilitySets (useful for classes where Settings
    -- don't provide AbilitySet metadata, e.g., CLR).
    do
        local loadouts = ConfigLoader.getSpellLoadouts and ConfigLoader.getSpellLoadouts() or {}
        local loadout = loadouts[loadoutName] or loadouts[loadoutName:lower()]
        local seen = {}
        if loadout and loadout.gems then
            for _, setName in pairs(loadout.gems) do
                if type(setName) == 'string' and setName ~= '' and not seen[setName] then
                    seen[setName] = true

                    -- If this AbilitySet already maps to a real setting key, do NOT create a synthetic entry.
                    -- Otherwise, the UI can "disable" something visually while the rotation still runs using
                    -- the mapped settingKey.
                    local mappedKey = abilitySetToKey[setName]
                    if not mappedKey and defaultConfig[setName] == nil then
                        local resolved = resolveSpellNameForSetting(setName, loadoutName)
                        local layer = layerAssignments[setName]
                        if not layer then
                            if resolved and isHealSpell(resolved) then
                                layer = 'heal'
                            else
                                layer = 'support'
                            end
                        end
                        if not layers[layer] then layer = 'support' end

                        local isEnabled = getLoadoutDefault(loadoutName, setName)
                        local entry = {
                            key = setName,
                            meta = {
                                Default = true,
                                Category = 'SpellLine',
                                DisplayName = prettySetName(setName),
                                Tooltip = 'Spell line: ' .. setName,
                                AbilitySet = setName,
                            },
                            displayName = prettySetName(setName),
                        }
                        if isEnabled then
                            table.insert(layers[layer].enabled, entry)
                        else
                            table.insert(layers[layer].disabled, entry)
                        end
                    end
                end
            end
        end
    end

    -- Sort enabled by layer order, disabled alphabetically
    for layer, data in pairs(layers) do
        local order = layerOrder[layer] or {}
        local orderMap = {}
        for i, key in ipairs(order) do
            orderMap[key] = i
        end

        table.sort(data.enabled, function(a, b)
            local aOrder = orderMap[a.key] or 9999
            local bOrder = orderMap[b.key] or 9999
            if aOrder ~= bOrder then
                return aOrder < bOrder
            end
            return a.displayName < b.displayName
        end)

        table.sort(data.disabled, function(a, b)
            return a.displayName < b.displayName
        end)
    end

    -- Move enabled entries that don't resolve (no spell in book/AA/disc) to disabled as "not available"
    for layer, data in pairs(layers) do
        local available = {}
        for _, entry in ipairs(data.enabled) do
            local resolved = resolveSpellNameForSetting(entry.key, loadoutName)
            if resolved then
                table.insert(available, entry)
            else
                -- Mark as unavailable and add to disabled
                entry.unavailable = true
                entry.displayName = entry.displayName .. " (not available)"
                table.insert(data.disabled, entry)
            end
        end
        data.enabled = available

        -- Re-sort disabled to include newly added unavailable entries
        table.sort(data.disabled, function(a, b)
            -- Put unavailable entries at the end
            if a.unavailable ~= b.unavailable then
                return not a.unavailable
            end
            return a.displayName < b.displayName
        end)
    end

    return layers
end

--- Render a single spell icon box
-- @param entry table {key, meta, displayName}
-- @param loadoutName string Current loadout name
-- @param layer string Layer this spell belongs to
-- @param index number Position in the layer (1-based)
-- @param settings table Current settings
-- @param setFunc function Setter function
-- @return boolean True if this entry should be removed (disabled)
local function renderSpellIconBox(entry, loadoutName, layer, index, settings, setFunc)
    local SpellsetManager = getSpellsetManager()
    local ConfigLoader = getConfigLoader()
    local shouldRemove = false

    if not animSpellIcons then
        animSpellIcons = mq.FindTextureAnimation('A_SpellIcons')
    end

    local iconSize = 48
    local boxPadding = 4
    local totalWidth = iconSize + boxPadding * 2
    local totalHeight = iconSize + boxPadding * 2  -- icon only, full name shown on hover

    -- Check if temporarily disabled
    local isTempDisabled = M.isTemporarilyDisabled(entry.key)

    imgui.PushID(entry.key .. "_icon")

    -- Get drawList and cursor position BEFORE any drawing
    local drawList = imgui.GetWindowDrawList()

    -- Get screen position as ImVec2 (matching remote_abilities.lua pattern)
    local cursorScreenPos = imgui.GetCursorScreenPosVec()
    local cursorX = cursorScreenPos and cursorScreenPos.x or 0
    local cursorY = cursorScreenPos and cursorScreenPos.y or 0

    -- Fallback if GetCursorScreenPosVec doesn't work
    if cursorX == 0 and cursorY == 0 then
        cursorX, cursorY = imgui.GetCursorScreenPos()
    end

    local iconX = cursorX + boxPadding
    local iconY = cursorY + boxPadding

    -- Pre-resolve the spell so we can draw icon properly
    local resolvedSpell = resolveSpellNameForSetting(entry.key, loadoutName)
    local spellDisplayName = resolvedSpell or entry.displayName
    local iconId = getSpellIconId(resolvedSpell)

    -- Box colors - dim if temporarily disabled
    local bgColor = isTempDisabled and 0xFF1A1A1A or 0xFF2A2A2A
    local borderColor = isTempDisabled and 0xFF3A3A3A or 0xFF4A4A4A

    -- DRAW EVERYTHING BEFORE InvisibleButton (matching remote_abilities.lua pattern)
    -- Draw background
    dlAddRectFilled(drawList, cursorX, cursorY, cursorX + totalWidth, cursorY + totalHeight, bgColor, 4, 0)
    dlAddRect(drawList, cursorX, cursorY, cursorX + totalWidth, cursorY + totalHeight, borderColor, 4, 0, 1)

    -- Draw spell icon using drawList (not imgui.DrawTextureAnimation which moves cursor)
    local iconDrawn = false
    local TL = getThrottledLog()

    if animSpellIcons and iconId > 0 then
        animSpellIcons:SetTextureCell(iconId)
        iconDrawn = dlAddTextureAnimation(drawList, animSpellIcons, iconX, iconY, iconSize)

        if M.debugIconLogging and TL then
            if iconDrawn then
                TL.log('render_icon_success_' .. entry.key, 30, 'renderSpellIconBox: %s icon drawn', entry.key)
            else
                TL.log('render_icon_error_' .. entry.key, 10, 'renderSpellIconBox: %s icon FAILED (anim=%s iconId=%d spell=%s)',
                    entry.key, tostring(animSpellIcons ~= nil), iconId, tostring(resolvedSpell))
            end
        end
    end

    -- Fallback: draw colored rectangle with first 2 letters if icon not available
    if not iconDrawn then
        local fallbackBg = isTempDisabled and 0xFF1A3A1A or 0xFF2A4A2A
        dlAddRectFilled(drawList, iconX, iconY, iconX + iconSize, iconY + iconSize, fallbackBg, 4, 0)

        -- Draw 2-letter abbreviation as fallback using drawList
        local iconText = spellDisplayName:sub(1, 2):upper()
        local textW, textH = imgui.CalcTextSize(iconText)
        local textX = iconX + (iconSize - (textW or 0)) / 2
        local textY = iconY + (iconSize - (textH or 0)) / 2
        local textColor = isTempDisabled and 0xFF666666 or 0xFFD9D9D9
        dlAddText(drawList, textX, textY, textColor, iconText)
    end

    -- Dim overlay if temporarily disabled
    if isTempDisabled then
        dlAddRectFilled(drawList, iconX, iconY, iconX + iconSize, iconY + iconSize, 0x80000000, 4, 0)
        local lineColor = 0xCC993333
        dlAddLine(drawList, cursorX + 4, cursorY + 4, cursorX + totalWidth - 4, cursorY + totalHeight - 4, lineColor, 2)
        local badgeX = cursorX + totalWidth - 12
        local badgeY = cursorY + 2
        dlAddRectFilled(drawList, badgeX - 2, badgeY - 1, badgeX + 10, badgeY + 11, 0xCC993333, 2, 0)
        dlAddText(drawList, badgeX, badgeY, 0xFFFFFFFF, "P")
    end

    -- NOW call InvisibleButton AFTER all drawing (this advances the cursor for layout)
    imgui.InvisibleButton("##iconbtn", totalWidth, totalHeight)

    -- Capture hover/click state IMMEDIATELY after InvisibleButton
    local isHovered = imgui.IsItemHovered()
    local isClicked = imgui.IsItemClicked(0)  -- Left click
    local isRightClicked = imgui.IsItemClicked(1)  -- Right click

    -- Handle drag/drop IMMEDIATELY (while InvisibleButton is still "last item")
    -- Drag source
    if imgui.BeginDragDropSource(ImGuiDragDropFlags.None) then
        M._dragPayload = { settingKey = entry.key, sourceLayer = layer, sourceIndex = index }
        imgui.SetDragDropPayload("SPELL_REORDER", entry.key)
        imgui.Text(entry.displayName)
        imgui.EndDragDropSource()
    end

    -- Drop target for reordering within layer
    if imgui.BeginDragDropTarget() then
        local payload = imgui.AcceptDragDropPayload("SPELL_REORDER")
        if payload and M._dragPayload then
            local dragKey = M._dragPayload.settingKey
            local sourceLayer = M._dragPayload.sourceLayer
            local sourceIndex = M._dragPayload.sourceIndex

            if sourceLayer == layer and sourceIndex ~= index then
                -- Reorder within same layer
                local layerOrder = getLayerOrder(loadoutName)
                local order = layerOrder[layer] or {}

                -- Remove from old position, insert at new
                local newOrder = {}
                local dragEntry = nil
                for i, key in ipairs(order) do
                    if key == dragKey then
                        dragEntry = key
                    else
                        table.insert(newOrder, key)
                    end
                end

                -- Insert at target position
                if dragEntry then
                    local insertPos = index
                    if sourceIndex < index then
                        insertPos = insertPos - 1
                    end
                    table.insert(newOrder, insertPos, dragEntry)

                    if SpellsetManager and SpellsetManager.setLoadoutLayerOrder then
                        SpellsetManager.setLoadoutLayerOrder(loadoutName, layer, newOrder)
                    end
                end
            end

            M._dragPayload = nil
        end
        imgui.EndDragDropTarget()
    end

    -- Tooltip
    if isHovered then
        imgui.BeginTooltip()
        -- Show setting name and resolved spell (if different)
        if resolvedSpell and resolvedSpell ~= entry.displayName then
            imgui.Text(entry.displayName .. " - " .. resolvedSpell)
        else
            imgui.Text(entry.displayName)
        end
        if isTempDisabled then
            imgui.TextColored(0.9, 0.6, 0.3, 1, "[TEMPORARILY DISABLED]")
        end
        if entry.meta.Tooltip then
            imgui.TextColored(0.7, 0.7, 0.7, 1, entry.meta.Tooltip)
        end
        imgui.Separator()
        imgui.TextColored(0.5, 0.7, 0.9, 1, "Left-click: Edit conditions")
        imgui.TextColored(0.5, 0.7, 0.9, 1, "Right-click: Context menu")
        imgui.TextColored(0.5, 0.7, 0.9, 1, "Drag: Reorder / Change layer")
        imgui.EndTooltip()
    end

    -- Handle clicks
    if isClicked then
        -- Toggle condition editor visibility inline below this spell's layer
        local condKey = conditionKey(entry.key, loadoutName)
        M._showCondition = M._showCondition or {}
        M._showCondition[condKey] = not M._showCondition[condKey]
    end

    if isRightClicked then
        -- Open context menu instead of directly disabling
        M._contextMenuTarget = {
            settingKey = entry.key,
            layer = layer,
            displayName = entry.displayName,
            loadoutName = loadoutName,
        }
        M._contextMenuOpenRequested = true
    end

    imgui.PopID()

    return shouldRemove
end

--- Render the right-click context menu for spells
-- Must be called once per frame, outside of individual spell rendering
-- @param loadoutName string Current loadout name
-- @return string|nil New layer if "Move to" was selected, nil otherwise
local function renderSpellContextMenu(loadoutName)
    local SpellsetManager = getSpellsetManager()
    local newLayerForKey = nil

    if imgui.BeginPopup("spell_context_menu") then
        local target = M._contextMenuTarget
        if target then
            -- Header showing which spell
            imgui.TextColored(0.8, 0.8, 0.3, 1, target.displayName)
            imgui.Separator()

            -- Temporarily Disable toggle
            local isTempDisabled = M.isTemporarilyDisabled(target.settingKey)
            local disableLabel = isTempDisabled and "Re-enable (until reload)" or "Temporarily Disable"
            if imgui.MenuItem(disableLabel) then
                M.toggleTemporarilyDisabled(target.settingKey)
            end
            if imgui.IsItemHovered() then
                if isTempDisabled then
                    imgui.SetTooltip("Re-enable this ability (state is lost on script reload)")
                else
                    imgui.SetTooltip("Temporarily disable - condition will return false until script reload")
                end
            end

            imgui.Separator()

            -- Permanent Disable option
            if imgui.MenuItem("Disable Permanently") then
                if SpellsetManager and SpellsetManager.setLoadoutSetting then
                    SpellsetManager.setLoadoutSetting(target.loadoutName, target.settingKey, false)
                end
                -- Clear temp disabled state too if it was set
                M.setTemporarilyDisabled(target.settingKey, false)
            end
            if imgui.IsItemHovered() then
                imgui.SetTooltip("Disable this ability in loadout settings (persisted)")
            end

            imgui.Separator()

            -- Move to submenu
            if imgui.BeginMenu("Move to...") then
                for _, layerName in ipairs(M._layerOrder) do
                    local displayName = M._layerDisplayNames[layerName] or layerName
                    local isCurrentLayer = (layerName == target.layer)

                    -- Show checkmark for current layer
                    if isCurrentLayer then
                        imgui.MenuItem(displayName .. " (current)", nil, true, false)
                    else
                        if imgui.MenuItem(displayName) then
                            -- Move spell to new layer
                            if SpellsetManager and SpellsetManager.setLoadoutLayer then
                                SpellsetManager.setLoadoutLayer(target.loadoutName, target.settingKey, layerName)
                            end
                            newLayerForKey = { key = target.settingKey, layer = layerName }
                        end
                    end
                end
                imgui.EndMenu()
            end
        end
        imgui.EndPopup()
    else
        -- Popup closed, clear target
        M._contextMenuTarget = nil
    end

    return newLayerForKey
end

--- Render enabled spells row for a layer
local function renderEnabledSpellsRow(layerName, enabledSpells, loadoutName, settings, setFunc)
    if #enabledSpells == 0 then
        imgui.TextColored(0.5, 0.5, 0.5, 1, "(No enabled abilities)")
        return
    end

    local iconSize = 48
    local boxPadding = 4
    local totalWidth = iconSize + boxPadding * 2
    local spacing = 4

    local availWidth = imgui.GetContentRegionAvail()
    local itemsPerRow = math.floor((availWidth + spacing) / (totalWidth + spacing))
    if itemsPerRow < 1 then itemsPerRow = 1 end

    local toRemove = {}

    for i, entry in ipairs(enabledSpells) do
        if i > 1 then
            if (i - 1) % itemsPerRow ~= 0 then
                imgui.SameLine(0, spacing)
            end
        end

        if renderSpellIconBox(entry, loadoutName, layerName, i, settings, setFunc) then
            table.insert(toRemove, i)
        end
    end

    -- Remove disabled spells (in reverse order to maintain indices)
    for i = #toRemove, 1, -1 do
        table.remove(enabledSpells, toRemove[i])
    end
end

--- Render disabled spells checkbox list for a layer
local function renderDisabledSpellsList(layerName, disabledSpells, loadoutName, settings, setFunc)
    local SpellsetManager = getSpellsetManager()

    if #disabledSpells == 0 then
        return
    end

    imgui.Indent(8)

    local toEnable = {}

    for i, entry in ipairs(disabledSpells) do
        imgui.PushID(entry.key .. "_disabled")

        -- Check if this is an unavailable entry (no spell in book/AA/disc)
        if entry.unavailable then
            -- Show as gray text only, no checkbox (can't enable something that's not available)
            imgui.TextColored(0.5, 0.5, 0.5, 1, "  " .. entry.displayName)
            if entry.meta.Tooltip and imgui.IsItemHovered() then
                imgui.SetTooltip(entry.meta.Tooltip .. "\n\n(Spell/AA not found in spellbook)")
            end
            imgui.PopID()
            goto continue
        end

        -- Resolve the actual spell name for this setting
        local resolvedSpell = resolveSpellNameForSetting(entry.key, loadoutName)
        local displayLabel = entry.displayName
        if resolvedSpell and resolvedSpell ~= '' then
            displayLabel = entry.displayName .. " - " .. resolvedSpell
        end

        local checked = false
        local newChecked, changed = imgui.Checkbox(displayLabel, checked)

        if entry.meta.Tooltip and imgui.IsItemHovered() then
            imgui.SetTooltip(entry.meta.Tooltip)
        end

        if changed and newChecked then
            local TL = getThrottledLog()
            if M.debugHealLayerLogging and TL then
                TL.log('enable_spell_' .. entry.key, 0, 'Enabling spell %s in loadout %s', entry.key, loadoutName or 'nil')
            end

            -- Check if enabling would exceed gem limit
            local showedModal = M.checkAndShowSwapModal(entry.key, entry.displayName, loadoutName)
            if not showedModal then
                -- Enable this setting (under limit or no gem needed)
                if SpellsetManager and SpellsetManager.setLoadoutSetting then
                    SpellsetManager.setLoadoutSetting(loadoutName, entry.key, true)
                end
                table.insert(toEnable, i)

                -- Trigger auto-memorize if this spell uses a gem
                local abilitySet = getAbilitySetForSetting(entry.key, loadoutName)
                if M.debugHealLayerLogging and TL then
                    TL.log('enable_ability_set_' .. entry.key, 0, 'getAbilitySetForSetting(%s, %s) = %s', entry.key, loadoutName or 'nil', tostring(abilitySet))
                end
                if abilitySet then
                    local memResult = M.memorizeAbilitySet(abilitySet, loadoutName)
                    if M.debugHealLayerLogging and TL then
                        TL.log('enable_mem_result_' .. entry.key, 0, 'memorizeAbilitySet result: %s', tostring(memResult))
                    end
                end
            else
                if M.debugHealLayerLogging and TL then
                    TL.log('enable_modal_' .. entry.key, 0, 'Showed swap modal for %s', entry.key)
                end
            end
            -- If modal was shown, don't enable yet - user must select swap target
        end

        -- Drag source for layer reassignment
        if imgui.BeginDragDropSource(ImGuiDragDropFlags.None) then
            M._dragPayload = { settingKey = entry.key, sourceLayer = layerName, isDisabled = true }
            imgui.SetDragDropPayload("SPELL_LAYER_CHANGE", entry.key)
            imgui.Text(entry.displayName)
            imgui.EndDragDropSource()
        end

        imgui.PopID()
        ::continue::
    end

    -- Remove enabled spells from disabled list (in reverse order)
    for i = #toEnable, 1, -1 do
        table.remove(disabledSpells, toEnable[i])
    end

    imgui.Unindent(8)
end

--- Render layer header with drop target
local function renderLayerHeader(layerName, enabledCount, totalCount, loadoutName)
    local SpellsetManager = getSpellsetManager()
    local displayName = M._layerDisplayNames[layerName] or layerName

    local headerText = string.format("%s (%d/%d enabled)", displayName, enabledCount, totalCount)

    -- Check if collapsed
    M._collapsedLayers = M._collapsedLayers or {}
    local isCollapsed = M._collapsedLayers[layerName]

    local flags = ImGuiTreeNodeFlags.DefaultOpen
    if isCollapsed then
        flags = 0
    end

    local isOpen = imgui.CollapsingHeader(headerText .. "##" .. layerName, flags)
    M._collapsedLayers[layerName] = not isOpen

    -- Drop target for layer reassignment
    if imgui.BeginDragDropTarget() then
        local payload = imgui.AcceptDragDropPayload("SPELL_REORDER")
        if not payload then
            payload = imgui.AcceptDragDropPayload("SPELL_LAYER_CHANGE")
        end

        if payload and M._dragPayload then
            local dragKey = M._dragPayload.settingKey
            local sourceLayer = M._dragPayload.sourceLayer

            if sourceLayer ~= layerName then
                -- Change layer assignment
                if SpellsetManager and SpellsetManager.setLoadoutLayer then
                    SpellsetManager.setLoadoutLayer(loadoutName, dragKey, layerName)
                end
            end

            M._dragPayload = nil
        end
        imgui.EndDragDropTarget()
    end

    return isOpen
end

--- Render inline condition editor for a specific setting
-- @param settingKey string The setting key (e.g., "doMez")
-- @param displayName string The display name for the setting
-- @param loadoutName string The current loadout name
-- @param settings table Current settings table
-- @param setFunc function Setter function for saving settings
local function renderInlineConditionEditor(settingKey, displayName, loadoutName, settings, setFunc)
    local ConditionBuilder = getConditionBuilder()
    local SpellsetManager = getSpellsetManager()
    local ConfigLoader = getConfigLoader()

    if not ConditionBuilder then
        imgui.TextColored(0.8, 0.4, 0.4, 1, "Condition builder not available")
        return  -- Early return to prevent nil access to ConditionBuilder.drawInline()
    end

    local condKey = conditionKey(settingKey, loadoutName)

    -- Load condition data from:
    -- 1. SpellsetManager condition overrides (user customizations)
    -- 2. Default conditions from class config
    local condData = nil
    local hasOverride = false

    -- Check for user override in SpellsetManager
    if SpellsetManager and SpellsetManager.getConditionOverride then
        local serialized = SpellsetManager.getConditionOverride(loadoutName, settingKey)
        if serialized and serialized ~= '' then
            condData = ConditionBuilder.deserialize(serialized)
            hasOverride = true
        end
    end

    -- Fall back to default condition from class config if no override
    if not condData and ConfigLoader and ConfigLoader.current then
        local defaultConditions = ConfigLoader.current.defaultConditions
        if defaultConditions and defaultConditions[settingKey] then
            -- Default conditions are function references, not serialized data
            -- We need to check if there's a serialized default condition
            local defaultConfig = ConfigLoader.getDefaultConfig()
            if defaultConfig and defaultConfig[settingKey] and defaultConfig[settingKey].DefaultCondition then
                condData = defaultConfig[settingKey].DefaultCondition
            end
        end
    end

    -- Condition editor container with subtle background
    imgui.PushStyleColor(ImGuiCol.ChildBg, 0.12, 0.12, 0.15, 0.95)
    imgui.PushStyleVar(ImGuiStyleVar.ChildRounding, 4)

    -- Estimate height based on condition count (each condition ~25px, header ~30px, buttons ~25px)
    local numConditions = 1
    if condData and condData.conditions then
        numConditions = math.max(1, #condData.conditions)
    end
    local estimatedHeight = 60 + (numConditions * 28)

    local childFlags = bit32.bor(ImGuiWindowFlags.NoScrollbar, ImGuiWindowFlags.NoScrollWithMouse)
    if imgui.BeginChild("cond_editor_" .. condKey, -1, estimatedHeight, true, childFlags) then
        -- Header row with title and buttons
        imgui.TextColored(0.6, 0.8, 1.0, 1, "Condition:")
        imgui.SameLine()
        imgui.Text(displayName)

        -- Buttons on the right side
        local buttonAreaWidth = hasOverride and 100 or 50
        imgui.SameLine(imgui.GetContentRegionAvail() - buttonAreaWidth + imgui.GetCursorPosX())

        -- Reset button (only show if there's an override)
        if hasOverride then
            imgui.PushStyleColor(ImGuiCol.Button, 0.5, 0.3, 0.2, 1.0)
            imgui.PushStyleColor(ImGuiCol.ButtonHovered, 0.6, 0.4, 0.3, 1.0)
            if imgui.SmallButton("Reset##" .. condKey) then
                -- Clear the override
                if SpellsetManager and SpellsetManager.clearConditionOverride then
                    SpellsetManager.clearConditionOverride(loadoutName, settingKey)
                end
                ConditionBuilder.clearCache(condKey)
                M._showCondition[condKey] = false
            end
            imgui.PopStyleColor(2)
            if imgui.IsItemHovered() then
                imgui.SetTooltip("Reset to default condition")
            end
            imgui.SameLine()
        end

        -- Close button
        imgui.PushStyleColor(ImGuiCol.Button, 0.4, 0.2, 0.2, 1.0)
        imgui.PushStyleColor(ImGuiCol.ButtonHovered, 0.5, 0.3, 0.3, 1.0)
        if imgui.SmallButton("X##close_" .. condKey) then
            M._showCondition[condKey] = false
        end
        imgui.PopStyleColor(2)

        imgui.Spacing()
        imgui.Separator()
        imgui.Spacing()

        -- Render the condition builder inline
        ConditionBuilder.drawInline(condKey, condData, function(newData)
            -- Save to SpellsetManager condition overrides
            if SpellsetManager and SpellsetManager.setConditionOverride then
                local serialized = ConditionBuilder.serialize(newData)
                SpellsetManager.setConditionOverride(loadoutName, settingKey, serialized)
            end
        end)
    end
    imgui.EndChild()
    imgui.PopStyleVar(1)
    imgui.PopStyleColor(1)
end

--- Render inline condition editors for expanded entries in a layer
-- @param enabledSpells table Array of enabled spell entries
-- @param loadoutName string Current loadout name
-- @param settings table Current settings table
-- @param setFunc function Setter function
local function renderLayerConditionEditors(enabledSpells, loadoutName, settings, setFunc)
    M._showCondition = M._showCondition or {}

    for _, entry in ipairs(enabledSpells) do
        local condKey = conditionKey(entry.key, loadoutName)
        if M._showCondition[condKey] then
            imgui.Spacing()
            renderInlineConditionEditor(entry.key, entry.displayName, loadoutName, settings, setFunc)
        end
    end
end

--- Render a single layer section
local function renderLayerSection(layerName, layerData, loadoutName, settings, setFunc)
    local enabledCount = #layerData.enabled
    local disabledCount = #layerData.disabled
    local totalCount = enabledCount + disabledCount

    if totalCount == 0 then
        return  -- Skip empty layers
    end

    local isOpen = renderLayerHeader(layerName, enabledCount, totalCount, loadoutName)

    if isOpen then
        imgui.Indent(8)

        -- Render enabled spells as icon row
        renderEnabledSpellsRow(layerName, layerData.enabled, loadoutName, settings, setFunc)

        -- Render inline condition editors for any expanded entries in this layer
        renderLayerConditionEditors(layerData.enabled, loadoutName, settings, setFunc)

        -- Render disabled spells as checkbox list
        if #layerData.disabled > 0 then
            imgui.Spacing()
            imgui.TextColored(0.6, 0.6, 0.6, 1, "Disabled:")
            renderDisabledSpellsList(layerName, layerData.disabled, loadoutName, settings, setFunc)
        end

        imgui.Unindent(8)
        imgui.Spacing()
    end
end

--- Render condition editor inline if shown (legacy - called after all layers)
-- This is now mostly handled by renderLayerConditionEditors, but kept for compatibility
local function renderConditionEditors(loadoutName, settings, setFunc)
    -- Condition editors are now rendered inline within each layer section
    -- This function is kept for backward compatibility but does nothing
    -- The actual rendering happens in renderLayerConditionEditors
end

--- Render non-boolean settings (sliders, numbers, text) in a separate section
local function renderNonBooleanSettings(loadoutName, settings, setFunc)
    local ConfigLoader = getConfigLoader()
    if not ConfigLoader or not ConfigLoader.current then return end

    local defaultConfig = ConfigLoader.getDefaultConfig()
    if not defaultConfig then return end

    -- Group non-boolean settings by category
    local categories = {}
    local categoryOrder = {}

    for key, meta in pairs(defaultConfig) do
        if type(meta.Default) ~= 'boolean' then
            local cat = meta.Category or "General"
            if not categories[cat] then
                categories[cat] = {}
                table.insert(categoryOrder, cat)
            end
            table.insert(categories[cat], { key = key, meta = meta })
        end
    end

    if #categoryOrder == 0 then return end

    table.sort(categoryOrder)
    for _, cat in ipairs(categoryOrder) do
        table.sort(categories[cat], function(a, b)
            return (a.meta.DisplayName or a.key) < (b.meta.DisplayName or b.key)
        end)
    end

    imgui.Spacing()
    if imgui.CollapsingHeader("Additional Settings") then
        for _, catName in ipairs(categoryOrder) do
            imgui.Text(catName .. ":")
            imgui.Indent(8)

            for _, s in ipairs(categories[catName]) do
                local baseKey = s.key
                local meta = s.meta
                local displayName = meta.DisplayName or baseKey
                local settingKey = loadoutKey(baseKey, loadoutName)
                local currentValue = settings[settingKey]
                if currentValue == nil then
                    currentValue = meta.Default
                end

                imgui.PushID(settingKey)

                local changed = false
                local newValue = currentValue

                if meta.Min ~= nil and meta.Max ~= nil then
                    imgui.SetNextItemWidth(150)
                    newValue, changed = imgui.SliderInt(displayName, currentValue or meta.Default, meta.Min, meta.Max)
                elseif type(meta.Default) == 'number' then
                    imgui.SetNextItemWidth(100)
                    newValue, changed = imgui.InputInt(displayName, currentValue or 0)
                else
                    imgui.SetNextItemWidth(200)
                    newValue, changed = imgui.InputText(displayName, currentValue or '', 256)
                end

                if meta.Tooltip and imgui.IsItemHovered() then
                    imgui.SetTooltip(meta.Tooltip)
                end

                if changed and setFunc then
                    setFunc(settingKey, newValue)
                end

                imgui.PopID()
            end

            imgui.Unindent(8)
        end
    end
end

--- Render class-specific settings for current loadout (Layer-based UI)
function M.render(settings, setFunc, currentLoadout)
    local ConfigLoader = getConfigLoader()
    if not ConfigLoader or not ConfigLoader.current then
        imgui.TextColored(0.6, 0.6, 0.6, 1, "No class config loaded")
        return
    end

    local defaultConfig = ConfigLoader.getDefaultConfig()
    if not defaultConfig or next(defaultConfig) == nil then
        imgui.TextColored(0.6, 0.6, 0.6, 1, "No class settings available")
        return
    end

    do
        local SpellsetManager = getSpellsetManager()
        if SpellsetManager then
            if not SpellsetManager.initialized then
                SpellsetManager.init()
            end
            local sm = SpellsetManager.getCurrentLoadoutName and SpellsetManager.getCurrentLoadoutName() or ''
            if sm and sm ~= '' then
                currentLoadout = sm
            end
        end
    end
    currentLoadout = currentLoadout or settings.SpellLoadout or 'cc'

    local classShort = mq.TLO.Me.Class.ShortName() or 'Unknown'
    local className = mq.TLO.Me.Class.Name() or 'Unknown'
    imgui.Text(string.format("%s (%s) - %s Loadout", className, classShort, currentLoadout:upper()))

    -- Display current layer state
    local RotationEngine = getRotationEngine()
    if RotationEngine and RotationEngine.getActiveLayerState then
        local layerState = RotationEngine.getActiveLayerState(settings)
        imgui.SameLine()
        imgui.TextDisabled(" | ")
        imgui.SameLine()

        -- Combat state indicator
        if layerState.inCombat then
            imgui.TextColored(0.9, 0.3, 0.3, 1, "IN COMBAT")
        else
            imgui.TextColored(0.5, 0.8, 0.5, 1, "Out of Combat")
        end

        -- Active layers display
        imgui.SameLine()
        imgui.TextDisabled(" | Active: ")
        imgui.SameLine()

        local activeList = {}
        local layerColors = {
            emergency = {1.0, 0.2, 0.2, 1},  -- Red
            heal = {0.2, 1.0, 0.4, 1},       -- Green (heals)
            aggro = {1.0, 0.6, 0.2, 1},      -- Orange
            defenses = {0.2, 0.6, 1.0, 1},   -- Blue
            support = {0.6, 0.8, 0.2, 1},    -- Yellow-green
            burn = {1.0, 0.4, 0.8, 1},       -- Pink
            combat = {0.8, 0.8, 0.8, 1},     -- White
            utility = {0.6, 0.6, 0.6, 1},    -- Gray
            buff = {0.4, 0.8, 1.0, 1},       -- Cyan (out of combat buffs)
        }
        local layerOrder = {'emergency', 'heal', 'aggro', 'defenses', 'support', 'burn', 'combat', 'utility', 'buff'}
        local first = true
        for _, name in ipairs(layerOrder) do
            if layerState.active[name] then
                if not first then
                    imgui.SameLine(0, 2)
                    imgui.TextDisabled(",")
                    imgui.SameLine(0, 2)
                end
                local col = layerColors[name] or {0.8, 0.8, 0.8, 1}
                imgui.TextColored(col[1], col[2], col[3], col[4], name)
                first = false
            end
        end
        if first then
            imgui.TextDisabled("none")
        end
    end

    imgui.Separator()

    -- Heal spell-line UI (diagnostics + simple enable/memorize flow)
    renderHealLayer(settings, setFunc)

    -- Group settings by layer
    local layers = groupSettingsByLayer(currentLoadout, settings)

    -- Render each layer section
    for _, layerName in ipairs(M._layerOrder) do
        local layerData = layers[layerName]
        if layerData then
            renderLayerSection(layerName, layerData, currentLoadout, settings, setFunc)
        end
    end

    -- Render the context menu (must be called once per frame, outside spell icon rendering)
    if M._contextMenuOpenRequested then
        imgui.OpenPopup("spell_context_menu")
        M._contextMenuOpenRequested = false
    end
    renderSpellContextMenu(currentLoadout)

    -- Render the swap modal (shown when enabling spell would exceed gem limit)
    M.renderSwapModal(currentLoadout)

    -- Render any open condition editors
    renderConditionEditors(currentLoadout, settings, setFunc)

    -- Render non-boolean settings (sliders, numbers, etc.)
    renderNonBooleanSettings(currentLoadout, settings, setFunc)

    imgui.Spacing()
    imgui.Separator()
    if imgui.CollapsingHeader("Debug: Spell Lineup") then
        M.renderSpellLineupDebug(currentLoadout)
    end

    -- INI Import section
    if imgui.CollapsingHeader("Import Configuration") then
        M.renderIniImport(settings, setFunc)
    end
end

--- Render spell lineup debug section
function M.renderSpellLineupDebug(currentLoadout)
    local SpellsetManager = getSpellsetManager()
    local ConfigLoader = getConfigLoader()

    local me = mq.TLO.Me
    if not me or not me() then
        imgui.TextColored(0.6, 0.6, 0.6, 1, "Character not loaded")
        return
    end

    local numGems = tonumber(me.NumGems()) or 0
    if numGems <= 0 then
        imgui.TextColored(0.6, 0.6, 0.6, 1, "Could not determine NumGems()")
        return
    end
    local expectedGems = {}
    if SpellsetManager and SpellsetManager.initialized and SpellsetManager.getLoadoutGems then
        expectedGems = SpellsetManager.getLoadoutGems(currentLoadout) or {}
    elseif ConfigLoader and ConfigLoader.current then
        local loadouts = ConfigLoader.current.SpellLoadouts
        local loadout = loadouts and loadouts[currentLoadout]
        if loadout and loadout.gems then
            for gem, setName in pairs(loadout.gems) do
                local spellName = ConfigLoader.resolveAbilitySet(setName)
                if spellName then
                    expectedGems[tonumber(gem)] = spellName
                end
            end
        end
    end

    imgui.Columns(3, "spell_debug_cols", true)
    imgui.SetColumnWidth(0, 50)
    imgui.SetColumnWidth(1, 200)
    imgui.SetColumnWidth(2, 200)

    imgui.TextColored(0.7, 0.7, 0.7, 1, "Gem")
    imgui.NextColumn()
    imgui.TextColored(0.7, 0.7, 0.7, 1, "Current Spell")
    imgui.NextColumn()
    imgui.TextColored(0.7, 0.7, 0.7, 1, "Expected Spell")
    imgui.NextColumn()
    imgui.Separator()

    for i = 1, numGems do
        local currentSpell = me.Gem(i)
        local currentName = currentSpell and currentSpell.Name and currentSpell.Name() or '(empty)'
        local expectedName = expectedGems[i] or ''
        local isMatch = (expectedName == '' and currentName ~= '(empty)') or (currentName == expectedName)

        imgui.Text(tostring(i))
        imgui.NextColumn()
        if isMatch or expectedName == '' then
            imgui.TextColored(0.3, 0.9, 0.3, 1, currentName)
        else
            imgui.TextColored(0.9, 0.3, 0.3, 1, currentName)
        end
        imgui.NextColumn()
        if expectedName ~= '' then
            imgui.Text(expectedName)
        else
            imgui.TextColored(0.5, 0.5, 0.5, 1, "(any)")
        end
        imgui.NextColumn()
    end

    imgui.Columns(1)
end

--- Get default values for all class settings
function M.getDefaults()
    local ConfigLoader = getConfigLoader()
    if not ConfigLoader or not ConfigLoader.current then return {} end

    local defaults = {}
    local defaultConfig = ConfigLoader.getDefaultConfig()

    for key, meta in pairs(defaultConfig) do
        defaults[key] = meta.Default
    end

    return defaults
end

--- Render loadout selector (uses SpellsetManager if available)
function M.renderLoadoutSelector(settings, setFunc)
    local SpellsetManager = getSpellsetManager()
    if SpellsetManager then
        return M.renderLoadoutManager(settings, setFunc)
    end

    local ConfigLoader = getConfigLoader()
    if not ConfigLoader or not ConfigLoader.current then return 'cc' end

    local loadouts = ConfigLoader.getLoadoutNames()
    if #loadouts == 0 then return 'cc' end

    imgui.Text("Spell Loadout:")
    imgui.SameLine()

    local currentLoadout = settings.SpellLoadout or 'cc'
    local comboItems = {}
    local currentIdx = 1

    for i, l in ipairs(loadouts) do
        table.insert(comboItems, l.name)
        if l.key == currentLoadout then
            currentIdx = i
        end
    end

    imgui.SetNextItemWidth(120)
    local newIdx = imgui.Combo("##loadout", currentIdx, comboItems, #comboItems)
    local loadoutChanged = false
    if newIdx ~= currentIdx and setFunc then
        local newKey = loadouts[newIdx] and loadouts[newIdx].key or 'cc'
        setFunc('SpellLoadout', newKey)
        currentLoadout = newKey
        loadoutChanged = true
    end

    local loadout = ConfigLoader.current.SpellLoadouts and ConfigLoader.current.SpellLoadouts[currentLoadout]
    if loadout and loadout.description then
        imgui.SameLine()
        imgui.TextColored(0.6, 0.6, 0.6, 1, "- " .. loadout.description)
    end

    imgui.SameLine()
    local isApplying = M.isApplying()
    if isApplying then
        imgui.PushStyleColor(ImGuiCol.Button, 0.5, 0.5, 0.2, 1.0)
        imgui.PushStyleColor(ImGuiCol.ButtonHovered, 0.6, 0.6, 0.3, 1.0)
        imgui.PushStyleColor(ImGuiCol.ButtonActive, 0.4, 0.4, 0.1, 1.0)
    end
    local applyLabel = isApplying and "Applying...##loadout" or "Apply##loadout"
    if imgui.Button(applyLabel) then
        if not isApplying then
            M.applyLoadout(currentLoadout)
        end
    end
    if isApplying then
        imgui.PopStyleColor(3)
    end
    if imgui.IsItemHovered() then
        if isApplying then
            local state = M._applyState
            local progress = state and string.format("Memorizing spell %d of %d", state.idx, #state.gems) or "Memorizing..."
            imgui.SetTooltip(progress)
        else
            imgui.SetTooltip("Memorize spells for this loadout")
        end
    end

    imgui.SameLine()
    local autoApply = settings.AutoApplyLoadout == true
    local newAutoApply, changed = imgui.Checkbox("Auto##applyloadout", autoApply)
    if changed and setFunc then
        setFunc('AutoApplyLoadout', newAutoApply)
        autoApply = newAutoApply
    end
    if imgui.IsItemHovered() then
        imgui.SetTooltip("Automatically apply loadout when changed")
    end

    if loadoutChanged and autoApply then
        M.applyLoadout(currentLoadout)
    end

    return currentLoadout
end

--- Initialize settings for a loadout from defaults if not set
function M.initLoadoutDefaults(settings, loadout, setFunc)
    local ConfigLoader = getConfigLoader()
    if not ConfigLoader or not ConfigLoader.current then return end

    local defaultConfig = ConfigLoader.getDefaultConfig()
    if not defaultConfig then return end

    for baseKey, meta in pairs(defaultConfig) do
        local key = loadoutKey(baseKey, loadout)
        if settings[key] == nil and setFunc then
            setFunc(key, meta.Default)
        end
    end
end

return M
