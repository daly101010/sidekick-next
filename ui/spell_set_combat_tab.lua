-- F:/lua/sidekick-next/ui/spell_set_combat_tab.lua
-- Combat Rotation Tab UI for Spell Set Editor
-- Provides drag-to-slots UI for configuring combat spell rotation

local mq = require('mq')
local imgui = require('ImGui')
local lazy = require('sidekick-next.utils.lazy_require')

local M = {}

-- Spell icon texture animation (loaded once)
local _animSpellIcons = nil
local function getSpellIcons()
    if not _animSpellIcons and mq.FindTextureAnimation then
        _animSpellIcons = mq.FindTextureAnimation('A_SpellIcons')
    end
    return _animSpellIcons
end

--------------------------------------------------------------------------------
-- State
--------------------------------------------------------------------------------

local state = {
    dragSpell = nil,          -- SpellEntry being dragged
    selectedGem = nil,        -- Gem slot with condition editor open
    expandedCategories = {},  -- { [category] = bool }
    expandedSubcategories = {}, -- { [category..subcategory] = bool }
}

--------------------------------------------------------------------------------
-- Lazy-loaded dependencies
--------------------------------------------------------------------------------

local getScanner = lazy('sidekick-next.utils.spellbook_scanner')
local getSpellsetData = lazy('sidekick-next.utils.spellset_data')
local getConditionDefaults = lazy('sidekick-next.utils.condition_defaults')
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

--- Check if a spell is beneficial (for buff target selector)
---@param spellId number The spell ID
---@return boolean beneficial True if spell is beneficial
local function isSpellBeneficial(spellId)
    if not spellId or spellId <= 0 then return false end
    local spell = mq.TLO.Spell(spellId)
    if spell and spell() and spell.Beneficial then
        return spell.Beneficial() == true
    end
    return false
end

--- Check if a spell is single-target
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

--- Get the rotation gem count (total minus reserved for OOC)
---@param spellSet table The spell set
---@return number rotationGemCount Number of gems available for rotation
local function getRotationGemCount(spellSet)
    local SpellsetData = getSpellsetData()
    if not SpellsetData then return 0 end

    local hasOoc = SpellsetData.hasOocBuffs(spellSet)
    return SpellsetData.getRotationGemCount(hasOoc)
end

--------------------------------------------------------------------------------
-- Render Functions
--------------------------------------------------------------------------------

--- Render a single gem slot
---@param slot number The gem slot number (1-13)
---@param spellSet table The spell set being edited
---@param scanner table The spellbook scanner module
function M.renderGemSlot(slot, spellSet, scanner)
    local SpellsetData = getSpellsetData()
    if not SpellsetData then return end

    imgui.PushID("gem_slot_" .. slot)

    local gemConfig = SpellsetData.getGem(spellSet, slot)
    local spellId = gemConfig and gemConfig.spellId or 0
    local spellName = getSpellName(spellId)

    -- Indicators
    local hasCondition = gemConfig and gemConfig.condition
        and gemConfig.condition.conditions
        and #gemConfig.condition.conditions > 0
    local hasBuffTarget = gemConfig and gemConfig.buffTarget

    -- Get spell icon
    local spellIcon = 0
    if spellId > 0 then
        local spell = mq.TLO.Spell(spellId)
        if spell and spell() and spell.SpellIcon then
            spellIcon = spell.SpellIcon() or 0
        end
    end

    -- Draw spell icon if available
    local animSpellIcons = getSpellIcons()
    local iconSize = 20
    local hasIcon = spellId > 0 and animSpellIcons and imgui.DrawTextureAnimation

    if hasIcon then
        animSpellIcons:SetTextureCell(spellIcon)
        imgui.DrawTextureAnimation(animSpellIcons, iconSize, iconSize)
        imgui.SameLine()
    end

    -- Build button label
    local label = string.format("[%d] %s", slot, spellName)
    if hasCondition then
        label = label .. " [C]"
    end
    if hasBuffTarget then
        label = label .. " [T]"
    end

    -- Button styling based on whether slot has a spell
    if spellId > 0 then
        imgui.PushStyleColor(ImGuiCol.Button, 0.2, 0.4, 0.6, 1.0)
        imgui.PushStyleColor(ImGuiCol.ButtonHovered, 0.3, 0.5, 0.7, 1.0)
    else
        imgui.PushStyleColor(ImGuiCol.Button, 0.3, 0.3, 0.3, 1.0)
        imgui.PushStyleColor(ImGuiCol.ButtonHovered, 0.4, 0.4, 0.4, 1.0)
    end

    -- Render button (adjust width if icon was drawn)
    local buttonWidth = imgui.GetContentRegionAvail() - 10
    if imgui.Button(label, buttonWidth, iconSize + 4) then
        -- Toggle condition editor on click
        if state.selectedGem == slot then
            state.selectedGem = nil
        else
            state.selectedGem = slot
        end
    end

    imgui.PopStyleColor(2)

    -- Right-click context menu to clear slot or inspect
    if imgui.BeginPopupContextItem("gem_ctx_" .. slot) then
        if spellId > 0 then
            if imgui.MenuItem("Inspect Spell") then
                local spellObj = mq.TLO.Spell(spellId)
                if spellObj and spellObj() and spellObj.Inspect then
                    spellObj.Inspect()
                end
            end
            imgui.Separator()
            if imgui.MenuItem("Clear Slot") then
                SpellsetData.clearGem(spellSet, slot)
                if state.selectedGem == slot then
                    state.selectedGem = nil
                end
            end
        else
            imgui.TextDisabled("(empty slot)")
        end
        imgui.EndPopup()
    end

    -- Drag-drop target
    if imgui.BeginDragDropTarget() then
        local payload = imgui.AcceptDragDropPayload("SPELL_ENTRY")
        if payload then
            -- payload is the spell entry table
            local droppedSpell = state.dragSpell
            if droppedSpell and droppedSpell.id then
                -- Generate default condition for combat spells
                local ConditionDefaults = getConditionDefaults()
                local condition = nil
                if ConditionDefaults and ConditionDefaults.shouldGenerateDefaults(droppedSpell) then
                    condition = ConditionDefaults.generateCombatCondition(droppedSpell)
                end

                -- Set the gem
                SpellsetData.setGem(spellSet, slot, droppedSpell.id, condition, nil, nil)
            end
        end
        imgui.EndDragDropTarget()
    end

    imgui.PopID()
end

--- Render all gem slots
---@param spellSet table The spell set being edited
function M.renderGemSlots(spellSet)
    local SpellsetData = getSpellsetData()
    local scanner = getScanner()
    if not SpellsetData or not scanner then return end

    local rotationGemCount = getRotationGemCount(spellSet)
    local totalGems = SpellsetData.getTotalGemCount()
    local usedCount = SpellsetData.countGems(spellSet)

    -- Header
    imgui.Text(string.format("Gem Slots (%d/%d)", usedCount, rotationGemCount))
    imgui.Separator()

    -- Render each rotation gem slot
    for slot = 1, rotationGemCount do
        M.renderGemSlot(slot, spellSet, scanner)
        imgui.Spacing()
    end

    -- Show reserved gem info if OOC buffs exist
    if SpellsetData.hasOocBuffs(spellSet) then
        imgui.Spacing()
        imgui.Separator()
        imgui.TextColored(0.7, 0.7, 0.7, 1.0,
            string.format("Gem %d reserved for buff swapping", totalGems))
    end
end

--- Render the spell browser with categories and subcategories
---@param spellSet table The spell set being edited
function M.renderSpellBrowser(spellSet)
    local scanner = getScanner()
    local SpellsetData = getSpellsetData()
    if not scanner or not SpellsetData then
        imgui.TextDisabled("Scanner not available")
        return
    end

    -- Scan spellbook if needed
    scanner.scan()

    -- Get categories
    local categories = scanner.getCategories('combat')
    if #categories == 0 then
        imgui.TextDisabled("No spells found in spellbook")
        return
    end

    imgui.Text("Spell Browser")
    imgui.Separator()

    -- Render each category as a tree
    for _, category in ipairs(categories) do
        imgui.PushID("cat_" .. category)

        -- Category tree node
        local catKey = category
        local catExpanded = state.expandedCategories[catKey]
        imgui.SetNextItemOpen(catExpanded == true)

        if imgui.TreeNode(category .. "##cat") then
            state.expandedCategories[catKey] = true

            -- Get subcategories
            local subcategories = scanner.getSubcategories('combat', category)

            for _, subcategory in ipairs(subcategories) do
                imgui.PushID("subcat_" .. subcategory)

                -- Subcategory tree node
                local subcatKey = category .. "/" .. subcategory
                local subcatExpanded = state.expandedSubcategories[subcatKey]
                imgui.SetNextItemOpen(subcatExpanded == true)

                if imgui.TreeNode(subcategory .. "##subcat") then
                    state.expandedSubcategories[subcatKey] = true

                    -- Get spells in subcategory
                    local spells = scanner.getSpells('combat', category, subcategory)

                    for _, spell in ipairs(spells) do
                        imgui.PushID("spell_" .. spell.id)

                        -- Check if spell is already in a gem slot
                        local inGem = SpellsetData.findSpellInGems(spellSet, spell.id)

                        -- Build spell label with indicator
                        local indicator = inGem and "*" or "o"
                        local spellLabel = string.format("%s %s (L%d)",
                            indicator, spell.name, spell.level or 0)

                        -- Color based on whether in gem
                        if inGem then
                            imgui.TextColored(0.4, 0.8, 0.4, 1.0, spellLabel)
                        else
                            imgui.Text(spellLabel)
                        end

                        -- Drag source
                        if imgui.BeginDragDropSource(ImGuiDragDropFlags.SourceAllowNullID) then
                            state.dragSpell = spell
                            imgui.SetDragDropPayload("SPELL_ENTRY", "spell")
                            imgui.Text("Dragging: " .. spell.name)
                            imgui.EndDragDropSource()
                        end

                        -- Right-click context menu for inspect
                        if imgui.BeginPopupContextItem("spell_ctx_" .. spell.id) then
                            if imgui.MenuItem("Inspect Spell") then
                                local spellObj = mq.TLO.Spell(spell.id)
                                if spellObj and spellObj() and spellObj.Inspect then
                                    spellObj.Inspect()
                                end
                            end
                            imgui.EndPopup()
                        end

                        -- Tooltip with spell info
                        if imgui.IsItemHovered() then
                            imgui.BeginTooltip()
                            imgui.Text(spell.name)
                            imgui.TextColored(0.7, 0.7, 0.7, 1.0,
                                string.format("Level %d | %s", spell.level or 0, spell.targetType or ""))
                            if spell.beneficial then
                                imgui.TextColored(0.4, 0.8, 0.4, 1.0, "Beneficial")
                            else
                                imgui.TextColored(0.8, 0.4, 0.4, 1.0, "Detrimental")
                            end
                            if inGem then
                                imgui.TextColored(0.8, 0.8, 0.4, 1.0,
                                    string.format("In Gem Slot %d", inGem))
                            end
                            imgui.TextColored(0.5, 0.5, 0.5, 1.0, "Right-click to inspect")
                            imgui.EndTooltip()
                        end

                        imgui.PopID()
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

--- Render the condition editor for the selected gem
---@param spellSet table The spell set being edited
function M.renderConditionEditor(spellSet)
    if not state.selectedGem then return end

    local SpellsetData = getSpellsetData()
    local ConditionBuilder = getConditionBuilder()
    if not SpellsetData or not ConditionBuilder then return end

    local gemConfig = SpellsetData.getGem(spellSet, state.selectedGem)
    if not gemConfig then
        state.selectedGem = nil
        return
    end

    local spellName = getSpellName(gemConfig.spellId)

    imgui.Spacing()
    imgui.Separator()
    imgui.Text(string.format("Editing: [%d] %s", state.selectedGem, spellName))
    imgui.Separator()

    -- Condition builder
    imgui.Text("Conditions:")
    local uniqueId = "combat_gem_" .. state.selectedGem
    local newCondition = ConditionBuilder.drawInline(uniqueId, gemConfig.condition, function(data)
        gemConfig.condition = data
        -- Auto-save when condition changes
        local Persistence = getPersistence()
        if Persistence then
            Persistence.save()
        end
    end)
    if newCondition then
        gemConfig.condition = newCondition
    end

    imgui.Spacing()

    -- Buff target selector (only for single-target beneficial spells)
    if isSingleTargetBeneficial(gemConfig.spellId) then
        imgui.Separator()
        imgui.Text("Buff Target:")

        local targetTypes = { "self", "group", "role", "class", "name", "npc" }
        local targetLabels = { "Self Only", "Group Members", "By Role", "By Class", "By Name", "Current NPC Target" }

        local currentType = gemConfig.buffTarget and gemConfig.buffTarget.type or "self"
        local currentIdx = 1
        for i, t in ipairs(targetTypes) do
            if t == currentType then
                currentIdx = i
                break
            end
        end

        imgui.PushItemWidth(150)
        if imgui.BeginCombo("##buffTarget", targetLabels[currentIdx]) then
            for i, label in ipairs(targetLabels) do
                if imgui.Selectable(label, currentIdx == i) then
                    gemConfig.buffTarget = gemConfig.buffTarget or {}
                    gemConfig.buffTarget.type = targetTypes[i]
                    if targetTypes[i] == "self" or targetTypes[i] == "group" or targetTypes[i] == "npc" then
                        gemConfig.buffTarget.value = nil
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
            local currentRole = gemConfig.buffTarget and gemConfig.buffTarget.value or "MainTank"
            local roleIdx = 1
            for i, r in ipairs(roles) do
                if r == currentRole then
                    roleIdx = i
                    break
                end
            end

            imgui.SameLine()
            imgui.PushItemWidth(120)
            if imgui.BeginCombo("##buffRole", roles[roleIdx]) then
                for i, role in ipairs(roles) do
                    if imgui.Selectable(role, roleIdx == i) then
                        gemConfig.buffTarget = gemConfig.buffTarget or {}
                        gemConfig.buffTarget.value = role
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
            imgui.PushItemWidth(120)
            local classValue = gemConfig.buffTarget and gemConfig.buffTarget.value or ""
            local newClass = imgui.InputText("##buffClass", classValue, 32)
            if newClass ~= classValue then
                gemConfig.buffTarget = gemConfig.buffTarget or {}
                gemConfig.buffTarget.value = newClass
                -- Auto-save
                local Persistence = getPersistence()
                if Persistence then Persistence.save() end
            end
            imgui.PopItemWidth()
            if imgui.IsItemHovered() then
                imgui.SetTooltip("Enter class short name (e.g., WAR, CLR, PAL)")
            end

        elseif currentType == "name" then
            imgui.SameLine()
            imgui.PushItemWidth(150)
            local nameValue = gemConfig.buffTarget and gemConfig.buffTarget.value or ""
            local newName = imgui.InputText("##buffName", nameValue, 64)
            if newName ~= nameValue then
                gemConfig.buffTarget = gemConfig.buffTarget or {}
                gemConfig.buffTarget.value = newName
                -- Auto-save
                local Persistence = getPersistence()
                if Persistence then Persistence.save() end
            end
            imgui.PopItemWidth()
            if imgui.IsItemHovered() then
                imgui.SetTooltip("Enter character name")
            end

        elseif currentType == "npc" then
            imgui.SameLine()
            imgui.TextColored(0.7, 0.7, 0.7, 1.0, "(reverse DS, etc.)")
            if imgui.IsItemHovered() then
                imgui.SetTooltip("For beneficial spells cast on enemies like reverse damage shields.\nWill check if effect already exists on target before casting.")
            end
        end
    end

    -- Priority override slider
    imgui.Separator()
    imgui.Text("Priority Override:")
    imgui.PushItemWidth(150)
    local priority = gemConfig.priority or 50
    local newPriority = imgui.SliderInt("##priority", priority, 1, 200)
    if newPriority ~= priority then
        gemConfig.priority = newPriority
        -- Auto-save
        local Persistence = getPersistence()
        if Persistence then Persistence.save() end
    end
    imgui.PopItemWidth()
    if imgui.IsItemHovered() then
        imgui.SetTooltip("Lower = higher priority. Leave at 50 for default.")
    end

    -- Close button
    imgui.Spacing()
    if imgui.Button("Close##condEdit") then
        state.selectedGem = nil
    end
end

--- Main render function for the Combat Rotation tab
---@param spellSet table The spell set being edited
function M.render(spellSet)
    if not spellSet then
        imgui.TextDisabled("No spell set loaded")
        return
    end

    -- Two-column layout using columns instead of child windows
    local availWidth, availHeight = imgui.GetContentRegionAvail()
    local leftWidth = math.max(availWidth * 0.55, 200)
    local rightWidth = math.max(availWidth * 0.42, 150)

    -- Left panel: Gem slots + condition editor
    imgui.BeginChild("CombatLeftPanel", leftWidth, availHeight - 5, true)
    M.renderGemSlots(spellSet)
    M.renderConditionEditor(spellSet)
    imgui.EndChild()

    imgui.SameLine()

    -- Right panel: Spell browser
    imgui.BeginChild("CombatRightPanel", rightWidth, availHeight - 5, true)
    M.renderSpellBrowser(spellSet)
    imgui.EndChild()
end

--- Reset the tab state
function M.reset()
    state.dragSpell = nil
    state.selectedGem = nil
    state.expandedCategories = {}
    state.expandedSubcategories = {}
end

return M
