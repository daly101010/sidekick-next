-- F:/lua/SideKick/ui/class_settings.lua
-- Class Settings UI - Auto-generates per-loadout settings from DefaultConfig
-- Extended with SpellsetManager integration for custom loadout management

local mq = require('mq')
local imgui = require('ImGui')

local M = {}

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

--- Build a per-loadout key
local function loadoutKey(baseKey, loadout)
    return baseKey .. '_' .. loadout
end

--- Build a condition key for a setting
local function conditionKey(baseKey, loadout)
    return baseKey .. '_' .. loadout .. '_Condition'
end

-- State for async spell memorization
M._applyState = nil

-- State for UI
M._saveAsName = ''
M._showSaveAsPopup = false
M._deleteConfirmName = nil

-- State for INI Import
M._showIniImportPopup = false
M._iniImportPath = ''
M._iniImportType = 'kissassist'  -- 'kissassist' or 'muleassist'
M._iniImportPreview = nil
M._iniImportError = nil
M._iniImportMerge = true  -- true = merge, false = replace

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

--- Memorize a single spell by AbilitySet name
function M.memorizeAbilitySet(abilitySetName, loadoutName)
    local ConfigLoader = getConfigLoader()
    if not ConfigLoader or not ConfigLoader.current then
        return false
    end

    local gemNum = findGemForAbilitySet(abilitySetName, loadoutName)
    if not gemNum then
        return false
    end

    local spellName = ConfigLoader.resolveAbilitySet(abilitySetName)
    if not spellName then
        mq.cmdf('/echo [SideKick] Could not resolve %s to a known spell', abilitySetName)
        return false
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

--- Render class-specific settings for current loadout
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

    currentLoadout = currentLoadout or settings.SpellLoadout or 'cc'
    local ConditionBuilder = getConditionBuilder()
    local Core = getCore()

    local categories, categoryOrder = groupByCategory(defaultConfig)

    local classShort = mq.TLO.Me.Class.ShortName() or 'Unknown'
    local className = mq.TLO.Me.Class.Name() or 'Unknown'
    imgui.Text(string.format("%s (%s) - %s Loadout", className, classShort, currentLoadout:upper()))
    imgui.Separator()

    for _, catName in ipairs(categoryOrder) do
        local catSettings = categories[catName]

        if imgui.CollapsingHeader(catName, ImGuiTreeNodeFlags.DefaultOpen) then
            for _, s in ipairs(catSettings) do
                local baseKey = s.key
                local meta = s.meta
                local displayName = meta.DisplayName or baseKey
                local settingKey = loadoutKey(baseKey, currentLoadout)
                local condKey = conditionKey(baseKey, currentLoadout)
                local currentValue = settings[settingKey]
                if currentValue == nil then
                    currentValue = meta.Default
                end

                imgui.PushID(settingKey)

                local changed = false
                local newValue = currentValue

                if meta.Min ~= nil and meta.Max ~= nil then
                    newValue, changed = imgui.SliderInt(displayName, currentValue or meta.Default, meta.Min, meta.Max)
                elseif type(meta.Default) == 'boolean' then
                    newValue, changed = imgui.Checkbox(displayName, currentValue or false)
                elseif type(meta.Default) == 'number' then
                    newValue, changed = imgui.InputInt(displayName, currentValue or 0)
                else
                    newValue, changed = imgui.InputText(displayName, currentValue or '', 256)
                end

                if meta.Tooltip and imgui.IsItemHovered() then
                    imgui.SetTooltip(meta.Tooltip)
                end

                if changed and setFunc then
                    setFunc(settingKey, newValue)
                    if type(meta.Default) == 'boolean' and newValue == true and meta.AbilitySet then
                        M.memorizeAbilitySet(meta.AbilitySet, currentLoadout)
                    end
                end

                if type(meta.Default) == 'boolean' and ConditionBuilder and Core then
                    imgui.SameLine()
                    local condData = settings[condKey]
                    if not condData and Core.Ini and Core.Ini['SideKick-Class'] then
                        local serialized = Core.Ini['SideKick-Class'][condKey]
                        if serialized and ConditionBuilder.deserialize then
                            condData = ConditionBuilder.deserialize(serialized)
                        end
                    end

                    local hasCondition = condData ~= nil
                    if hasCondition then
                        imgui.PushStyleColor(ImGuiCol.Button, 0.2, 0.5, 0.7, 0.8)
                    end

                    local condLabel = hasCondition and '[Cond]##' .. condKey or '[+Cond]##' .. condKey
                    if imgui.SmallButton(condLabel) then
                        M._showCondition = M._showCondition or {}
                        M._showCondition[condKey] = not M._showCondition[condKey]
                    end

                    if hasCondition then
                        imgui.PopStyleColor(1)
                    end

                    if imgui.IsItemHovered() then
                        imgui.SetTooltip(hasCondition and "Edit condition (click to show/hide)" or "Add condition for when to use this ability")
                    end

                    M._showCondition = M._showCondition or {}
                    if M._showCondition[condKey] then
                        imgui.Indent(20)
                        ConditionBuilder.drawInline(condKey, condData, function(newData)
                            settings[condKey] = newData
                            Core.Ini['SideKick-Class'] = Core.Ini['SideKick-Class'] or {}
                            if newData and ConditionBuilder.serialize then
                                Core.Ini['SideKick-Class'][condKey] = ConditionBuilder.serialize(newData)
                            else
                                Core.Ini['SideKick-Class'][condKey] = nil
                            end
                            if Core.save then Core.save() end
                        end)
                        imgui.Unindent(20)
                    end
                end

                imgui.PopID()
            end
        end
    end

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

    local numGems = tonumber(me.NumGems()) or 13
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
