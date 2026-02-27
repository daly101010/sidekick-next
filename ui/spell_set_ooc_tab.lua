-- F:/lua/sidekick-next/ui/spell_set_ooc_tab.lua
-- OOC Buffs Tab UI for Spell Set Editor
-- Provides checkbox-based UI for configuring out-of-combat buffs

local mq = require('mq')
local imgui = require('ImGui')
local lazy = require('sidekick-next.utils.lazy_require')

local M = {}

--------------------------------------------------------------------------------
-- State
--------------------------------------------------------------------------------

local state = {
    selectedBuff = nil,       -- spellId with condition editor open
    expandedCategories = {},  -- { [category] = bool }
    expandedSubcategories = {}, -- { [category..subcategory] = bool }
}

--------------------------------------------------------------------------------
-- Lazy-loaded dependencies
--------------------------------------------------------------------------------

local getScanner = lazy('sidekick-next.utils.spellbook_scanner')
local getSpellsetData = lazy('sidekick-next.utils.spellset_data')
local getConditionBuilder = lazy('sidekick-next.ui.condition_builder')
local getPersistence = lazy('sidekick-next.utils.spellset_persistence')

--------------------------------------------------------------------------------
-- Helper Functions
--------------------------------------------------------------------------------

--- Get spell name from ID using TLO
---@param spellId number The spell ID
---@return string name The spell name or "Unknown"
local function getSpellName(spellId)
    if not spellId or spellId <= 0 then return "---" end
    local spell = mq.TLO.Spell(spellId)
    if spell and spell() and spell.Name then
        return spell.Name() or "Unknown"
    end
    return "Unknown"
end

--- Check if a spell is single-target beneficial
---@param spellId number The spell ID
---@return boolean singleTarget True if single-target beneficial spell
local function isSingleTargetBeneficial(spellId)
    if not spellId or spellId <= 0 then return false end
    local spell = mq.TLO.Spell(spellId)
    if not spell or not spell() then return false end

    local beneficial = spell.Beneficial and spell.Beneficial() == true
    if not beneficial then return false end

    local targetType = spell.TargetType and spell.TargetType() or ""
    local targetLower = targetType:lower()

    -- Single-target beneficial types
    return targetLower == "single" or targetLower == "single in group"
        or targetLower == "single friendly" or targetLower == "single pc"
        or targetLower == "target_pc" or targetLower == "pet"
end

--- Find OOC buff config and index in the spell set
---@param spellSet table The spell set
---@param spellId number The spell ID to find
---@return table|nil config The OocBuffConfig or nil
---@return number|nil index The 1-based index or nil
function M.findOocBuff(spellSet, spellId)
    local SpellsetData = getSpellsetData()
    if not SpellsetData then return nil, nil end

    local idx = SpellsetData.findSpellInOocBuffs(spellSet, spellId)
    if not idx then return nil, nil end

    local config = SpellsetData.getOocBuffByIndex(spellSet, idx)
    return config, idx
end

--- Count enabled OOC buffs
---@param spellSet table The spell set
---@return number count Number of enabled OOC buffs
local function countEnabledBuffs(spellSet)
    local SpellsetData = getSpellsetData()
    if not SpellsetData then return 0 end

    local enabled = SpellsetData.getEnabledOocBuffs(spellSet)
    return #enabled
end

--------------------------------------------------------------------------------
-- Render Functions
--------------------------------------------------------------------------------

--- Render a single buff entry with checkbox
---@param spell table SpellEntry from scanner
---@param spellSet table The spell set being edited
function M.renderBuffEntry(spell, spellSet)
    local SpellsetData = getSpellsetData()
    local ConditionBuilder = getConditionBuilder()
    if not SpellsetData then return end

    imgui.PushID("ooc_spell_" .. spell.id)

    local buffConfig, buffIdx = M.findOocBuff(spellSet, spell.id)
    local isEnabled = buffConfig and buffConfig.enabled or false
    local isInList = buffConfig ~= nil

    -- Check if this spell is also in a combat gem slot (will be dimmed)
    local inCombatGem = SpellsetData.findSpellInGems(spellSet, spell.id)

    -- Checkbox to enable/disable
    local newEnabled, changed = imgui.Checkbox("##enabled", isEnabled)
    if changed and newEnabled ~= isEnabled then
        if isInList then
            -- Toggle existing buff
            SpellsetData.toggleOocBuff(spellSet, spell.id)
        else
            -- Add new buff (enabled by default)
            SpellsetData.addOocBuff(spellSet, spell.id, true, nil, nil)
        end
        -- Auto-save
        local Persistence = getPersistence()
        if Persistence then Persistence.save() end
    end

    -- Spell name (dimmed if also in combat rotation)
    imgui.SameLine()
    if inCombatGem then
        imgui.TextColored(0.5, 0.5, 0.5, 1.0, spell.name)
        if imgui.IsItemHovered() then
            imgui.SetTooltip("Also in combat gem slot %d\nRight-click to inspect", inCombatGem)
        end
    else
        imgui.Text(spell.name)
        if imgui.IsItemHovered() then
            imgui.SetTooltip("Right-click to inspect")
        end
    end

    -- Right-click context menu for inspect
    if imgui.BeginPopupContextItem("ooc_spell_ctx_" .. spell.id) then
        if imgui.MenuItem("Inspect Spell") then
            local spellObj = mq.TLO.Spell(spell.id)
            if spellObj and spellObj() and spellObj.Inspect then
                spellObj.Inspect()
            end
        end
        imgui.EndPopup()
    end

    -- Level info
    imgui.SameLine()
    imgui.TextColored(0.6, 0.6, 0.6, 1.0, string.format("(L%d)", spell.level or 0))

    -- [C] button for condition editor
    imgui.SameLine()
    local hasCondition = buffConfig and buffConfig.condition
        and buffConfig.condition.conditions
        and #buffConfig.condition.conditions > 0
    local isSelected = state.selectedBuff == spell.id

    if hasCondition then
        imgui.PushStyleColor(ImGuiCol.Button, 0.2, 0.5, 0.2, 1.0)
        imgui.PushStyleColor(ImGuiCol.ButtonHovered, 0.3, 0.6, 0.3, 1.0)
    end

    if imgui.SmallButton("[C]##cond") then
        if isSelected then
            state.selectedBuff = nil
        else
            -- Ensure buff is in the list before editing conditions
            if not isInList then
                SpellsetData.addOocBuff(spellSet, spell.id, false, nil, nil)
            end
            state.selectedBuff = spell.id
        end
    end

    if hasCondition then
        imgui.PopStyleColor(2)
    end

    if imgui.IsItemHovered() then
        if hasCondition then
            imgui.SetTooltip("Edit conditions (has conditions)")
        else
            imgui.SetTooltip("Add conditions")
        end
    end

    -- Right-click context menu
    if imgui.BeginPopupContextItem("ooc_ctx_" .. spell.id) then
        if isInList then
            if imgui.MenuItem("Remove from OOC Buffs") then
                SpellsetData.removeOocBuff(spellSet, spell.id)
                if state.selectedBuff == spell.id then
                    state.selectedBuff = nil
                end
            end
            imgui.Separator()
            if buffIdx and buffIdx > 1 then
                if imgui.MenuItem("Move Up") then
                    SpellsetData.moveOocBuffUp(spellSet, spell.id)
                end
            end
            if buffIdx and spellSet.oocBuffs and buffIdx < #spellSet.oocBuffs then
                if imgui.MenuItem("Move Down") then
                    SpellsetData.moveOocBuffDown(spellSet, spell.id)
                end
            end
        else
            if imgui.MenuItem("Add to OOC Buffs") then
                SpellsetData.addOocBuff(spellSet, spell.id, true, nil, nil)
            end
        end
        imgui.EndPopup()
    end

    -- Inline condition editor (shown below the spell when selected)
    if isSelected and buffConfig and ConditionBuilder then
        imgui.Indent(20)
        imgui.Separator()

        -- Condition builder
        imgui.Text("Conditions:")
        local uniqueId = "ooc_buff_" .. spell.id
        local newCondition = ConditionBuilder.drawInline(uniqueId, buffConfig.condition, function(data)
            buffConfig.condition = data
            -- Auto-save when condition changes
            local Persistence = getPersistence()
            if Persistence then
                Persistence.save()
            end
        end)
        if newCondition then
            buffConfig.condition = newCondition
        end

        -- Target override section (only for single-target buffs)
        if isSingleTargetBeneficial(spell.id) then
            imgui.Spacing()
            imgui.Separator()
            imgui.Text("Target Override:")

            local targetTypes = { "group", "role", "class", "name" }
            local targetLabels = { "Group (iterate)", "By Role", "By Class", "By Name" }

            local currentType = buffConfig.buffTarget and buffConfig.buffTarget.type or "group"
            local currentIdx = 1
            for i, t in ipairs(targetTypes) do
                if t == currentType then
                    currentIdx = i
                    break
                end
            end

            imgui.PushItemWidth(130)
            if imgui.BeginCombo("##buffTarget", targetLabels[currentIdx]) then
                for i, label in ipairs(targetLabels) do
                    if imgui.Selectable(label, currentIdx == i) then
                        buffConfig.buffTarget = buffConfig.buffTarget or {}
                        buffConfig.buffTarget.type = targetTypes[i]
                        if targetTypes[i] == "group" then
                            buffConfig.buffTarget.value = nil
                        end
                        -- Auto-save
                        local Persistence = getPersistence()
                        if Persistence then Persistence.save() end
                    end
                end
                imgui.EndCombo()
            end
            imgui.PopItemWidth()

            -- Value input for role/class/name
            if currentType == "role" then
                local roles = { "MainTank", "MainAssist", "Puller" }
                local currentRole = buffConfig.buffTarget and buffConfig.buffTarget.value or "MainTank"
                local roleIdx = 1
                for i, r in ipairs(roles) do
                    if r == currentRole then
                        roleIdx = i
                        break
                    end
                end

                imgui.SameLine()
                imgui.PushItemWidth(100)
                if imgui.BeginCombo("##buffRole", roles[roleIdx]) then
                    for i, role in ipairs(roles) do
                        if imgui.Selectable(role, roleIdx == i) then
                            buffConfig.buffTarget = buffConfig.buffTarget or {}
                            buffConfig.buffTarget.value = role
                            -- Auto-save
                            local Persistence = getPersistence()
                            if Persistence then Persistence.save() end
                        end
                    end
                    imgui.EndCombo()
                end
                imgui.PopItemWidth()

            elseif currentType == "class" then
                imgui.SameLine()
                imgui.PushItemWidth(80)
                local classValue = buffConfig.buffTarget and buffConfig.buffTarget.value or ""
                local newClass = imgui.InputText("##buffClass", classValue, 32)
                if newClass ~= classValue then
                    buffConfig.buffTarget = buffConfig.buffTarget or {}
                    buffConfig.buffTarget.value = newClass
                    -- Auto-save
                    local Persistence = getPersistence()
                    if Persistence then Persistence.save() end
                end
                imgui.PopItemWidth()

            elseif currentType == "name" then
                imgui.SameLine()
                imgui.PushItemWidth(120)
                local nameValue = buffConfig.buffTarget and buffConfig.buffTarget.value or ""
                local newName = imgui.InputText("##buffName", nameValue, 64)
                if newName ~= nameValue then
                    buffConfig.buffTarget = buffConfig.buffTarget or {}
                    buffConfig.buffTarget.value = newName
                    -- Auto-save
                    local Persistence = getPersistence()
                    if Persistence then Persistence.save() end
                end
                imgui.PopItemWidth()
            end
        end

        -- Close button
        imgui.Spacing()
        if imgui.Button("Close##condEdit") then
            state.selectedBuff = nil
        end

        imgui.Separator()
        imgui.Unindent(20)
    end

    imgui.PopID()
end

--- Build a short condition summary string
---@param conditionData table The condition data
---@return string summary Short summary or "(default)" if no conditions
local function buildConditionSummary(conditionData)
    if not conditionData or not conditionData.conditions or #conditionData.conditions == 0 then
        return nil
    end

    local ConditionBuilder = getConditionBuilder()
    if ConditionBuilder and ConditionBuilder.buildPreviewString then
        return ConditionBuilder.buildPreviewString(conditionData)
    end

    return string.format("(%d conditions)", #conditionData.conditions)
end

--- Render enabled buffs summary for right panel
---@param spellSet table The spell set being edited
function M.renderEnabledBuffsSummary(spellSet)
    local SpellsetData = getSpellsetData()
    if not SpellsetData then return end

    imgui.Text("Enabled OOC Buffs")
    imgui.Separator()

    local enabledBuffs = SpellsetData.getEnabledOocBuffs(spellSet)

    if #enabledBuffs == 0 then
        imgui.TextDisabled("No buffs enabled")
        imgui.Spacing()
        imgui.TextWrapped("Enable buffs using checkboxes in the browser on the left.")
        return
    end

    for i, buffConfig in ipairs(enabledBuffs) do
        imgui.PushID("summary_" .. i)

        local spellName = getSpellName(buffConfig.spellId)
        local condSummary = buildConditionSummary(buffConfig.condition)

        -- Buff name
        imgui.Text(string.format("%d. %s", i, spellName))

        -- Condition summary (if not default)
        if condSummary then
            imgui.Indent(15)
            imgui.TextColored(0.6, 0.8, 0.6, 1.0, condSummary)
            imgui.Unindent(15)
        end

        -- Target override info
        if buffConfig.buffTarget and buffConfig.buffTarget.type and buffConfig.buffTarget.type ~= "group" then
            imgui.Indent(15)
            local targetInfo = buffConfig.buffTarget.type
            if buffConfig.buffTarget.value then
                targetInfo = targetInfo .. ": " .. buffConfig.buffTarget.value
            end
            imgui.TextColored(0.8, 0.7, 0.5, 1.0, "Target: " .. targetInfo)
            imgui.Unindent(15)
        end

        imgui.Spacing()
        imgui.PopID()
    end
end

--- Render the buff browser with categories and subcategories
---@param spellSet table The spell set being edited
function M.renderBuffBrowser(spellSet)
    local scanner = getScanner()
    local SpellsetData = getSpellsetData()
    if not scanner or not SpellsetData then
        imgui.TextDisabled("Scanner not available")
        return
    end

    -- Scan spellbook if needed
    scanner.scan()

    -- Get categories for OOC spells (beneficial only)
    local categories = scanner.getCategories('ooc')
    if #categories == 0 then
        imgui.TextDisabled("No beneficial spells found in spellbook")
        return
    end

    -- Render each category as a tree
    for _, category in ipairs(categories) do
        imgui.PushID("ooc_cat_" .. category)

        -- Category tree node
        local catKey = category
        local catExpanded = state.expandedCategories[catKey]
        imgui.SetNextItemOpen(catExpanded == true)

        if imgui.TreeNode(category .. "##cat") then
            state.expandedCategories[catKey] = true

            -- Get subcategories
            local subcategories = scanner.getSubcategories('ooc', category)

            for _, subcategory in ipairs(subcategories) do
                imgui.PushID("ooc_subcat_" .. subcategory)

                -- Subcategory tree node
                local subcatKey = category .. "/" .. subcategory
                local subcatExpanded = state.expandedSubcategories[subcatKey]
                imgui.SetNextItemOpen(subcatExpanded == true)

                if imgui.TreeNode(subcategory .. "##subcat") then
                    state.expandedSubcategories[subcatKey] = true

                    -- Get spells in subcategory
                    local spells = scanner.getSpells('ooc', category, subcategory)

                    for _, spell in ipairs(spells) do
                        M.renderBuffEntry(spell, spellSet)
                    end

                    imgui.TreePop()
                else
                    state.expandedSubcategories[subcatKey] = false
                end

                imgui.PopID()
            end

            imgui.TreePop()
        else
            state.expandedCategories[catKey] = false
        end

        imgui.PopID()
    end
end

--- Main render function for the OOC Buffs tab
---@param spellSet table The spell set being edited
function M.render(spellSet)
    if not spellSet then
        imgui.TextDisabled("No spell set loaded")
        return
    end

    local SpellsetData = getSpellsetData()
    if not SpellsetData then
        imgui.TextDisabled("Spell set data module not available")
        return
    end

    -- Header with enabled count
    local enabledCount = countEnabledBuffs(spellSet)
    imgui.Text(string.format("OOC Buffs Enabled: %d", enabledCount))

    -- Info about gem reservation
    if SpellsetData.hasOocBuffs(spellSet) then
        local totalGems = SpellsetData.getTotalGemCount()
        imgui.SameLine()
        imgui.TextColored(0.7, 0.7, 0.7, 1.0,
            string.format("(Gem %d reserved for buff swapping)", totalGems))
    end

    imgui.Separator()

    -- Two-column layout
    local availWidth, availHeight = imgui.GetContentRegionAvail()
    local leftWidth = math.max(availWidth * 0.55, 200)
    local rightWidth = math.max(availWidth * 0.4, 150)

    -- Left panel: Buff browser with checkboxes
    imgui.BeginChild("OocLeftPanel", leftWidth, availHeight - 5, true)
    M.renderBuffBrowser(spellSet)
    imgui.EndChild()

    imgui.SameLine()

    -- Right panel: Summary of enabled buffs
    imgui.BeginChild("OocRightPanel", rightWidth, availHeight - 5, true)
    M.renderEnabledBuffsSummary(spellSet)
    imgui.EndChild()
end

--- Reset the tab state
function M.reset()
    state.selectedBuff = nil
    state.expandedCategories = {}
    state.expandedSubcategories = {}
end

return M
