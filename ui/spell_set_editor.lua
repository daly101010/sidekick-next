-- ui/spell_set_editor.lua
-- Spell Set Editor UI for creating and managing spell sets

local mq = require('mq')
local imgui = require('ImGui')

local M = {}

-- State
M.isOpen = false
M.selectedSet = nil
M.newSetName = ''
M.showNewSetPopup = false
M.showDeleteConfirm = false
M.showConditionPopup = false
M.conditionEditLine = nil
M.categoryFilter = 'All'

-- Lazy-load dependencies
local _SpellsetManager = nil
local function getSpellsetManager()
    if not _SpellsetManager then
        local ok, sm = pcall(require, 'utils.spellset_manager')
        if ok then _SpellsetManager = sm end
    end
    return _SpellsetManager
end

local _SpellsClr = nil
local function getSpellsClr()
    if not _SpellsClr then
        local ok, s = pcall(require, 'sk_spells_clr')
        if ok then _SpellsClr = s end
    end
    return _SpellsClr
end

local _ConditionBuilder = nil
local function getConditionBuilder()
    if not _ConditionBuilder then
        local ok, cb = pcall(require, 'ui.condition_builder')
        if ok then _ConditionBuilder = cb end
    end
    return _ConditionBuilder
end

--- Toggle the editor window
function M.toggle()
    M.isOpen = not M.isOpen
end

--- Open the editor window
function M.open()
    M.isOpen = true

    -- Select active set if none selected
    local SpellsetManager = getSpellsetManager()
    if SpellsetManager and not M.selectedSet then
        M.selectedSet = SpellsetManager.activeSetName
    end
end

--- Close the editor window
function M.close()
    M.isOpen = false
end

--- Initialize the editor
function M.init()
    local SpellsetManager = getSpellsetManager()
    if SpellsetManager then
        M.selectedSet = SpellsetManager.activeSetName
    end
end

--- Render the header (set selector, buttons)
function M.renderHeader(SpellsetManager)
    -- Set selector dropdown
    local setNames = SpellsetManager.getSetNames()
    local currentIdx = 0
    for i, name in ipairs(setNames) do
        if name == M.selectedSet then
            currentIdx = i
            break
        end
    end

    imgui.Text('Spell Set:')
    imgui.SameLine()
    imgui.SetNextItemWidth(200)

    local previewName = M.selectedSet or '(None)'
    if imgui.BeginCombo('##SetSelector', previewName) then
        for i, name in ipairs(setNames) do
            local isSelected = (name == M.selectedSet)
            if imgui.Selectable(name, isSelected) then
                M.selectedSet = name
                SpellsetManager.activateSet(name)
            end
        end
        imgui.EndCombo()
    end

    -- Buttons
    imgui.SameLine()
    if imgui.Button('New') then
        M.newSetName = ''
        M.showNewSetPopup = true
        imgui.OpenPopup('New Spell Set##NewSetPopup')
    end

    imgui.SameLine()
    if imgui.Button('Delete') then
        if M.selectedSet then
            M.showDeleteConfirm = true
            imgui.OpenPopup('Delete Spell Set?##DeleteConfirm')
        end
    end

    imgui.SameLine()
    if imgui.Button('Apply') then
        if M.selectedSet then
            local result = SpellsetManager.applySet(M.selectedSet)
            if result == 'queued' then
                mq.cmd('/echo [SpellSet] Memorization queued for out of combat')
            elseif result == 'applied' then
                mq.cmd('/echo [SpellSet] Memorization started')
            end
        end
    end

    -- Slot counter
    if M.selectedSet then
        local rotationCount = SpellsetManager.countEnabledRotation(M.selectedSet)
        local capacity = SpellsetManager.getRotationCapacity()
        imgui.Text(string.format('Rotation Slots: %d/%d', rotationCount, capacity))
    end
end

--- Render the spell lines sections
function M.renderSpellLines(SpellsetManager, SpellsClr)
    if not M.selectedSet then
        imgui.TextDisabled('Select or create a spell set to begin.')
        return
    end

    local set = SpellsetManager.getSet(M.selectedSet)
    if not set then return end

    local allLines = SpellsClr.enumerateLines()
    local capacity = SpellsetManager.getRotationCapacity()
    local rotationCount = SpellsetManager.countEnabledRotation(M.selectedSet)
    local atCapacity = rotationCount >= capacity

    -- Category filter
    imgui.Text('Filter:')
    imgui.SameLine()
    imgui.SetNextItemWidth(150)
    if imgui.BeginCombo('##CategoryFilter', M.categoryFilter) then
        if imgui.Selectable('All', M.categoryFilter == 'All') then
            M.categoryFilter = 'All'
        end

        local categories = {}
        for _, line in ipairs(allLines) do
            if not categories[line.category] then
                categories[line.category] = true
                if imgui.Selectable(line.category, M.categoryFilter == line.category) then
                    M.categoryFilter = line.category
                end
            end
        end
        imgui.EndCombo()
    end

    imgui.Separator()

    -- Rotation section
    if imgui.CollapsingHeader('Rotation Spells (combat)', ImGuiTreeNodeFlags.DefaultOpen) then
        M.renderLineSection(SpellsetManager, allLines, set, 'rotation', atCapacity)
    end

    -- Buff swap section
    if imgui.CollapsingHeader('Buff Swap Spells (OOC only)', ImGuiTreeNodeFlags.DefaultOpen) then
        M.renderLineSection(SpellsetManager, allLines, set, 'buff_swap', false)
    end
end

--- Render a section of spell lines
function M.renderLineSection(SpellsetManager, allLines, set, slotType, atCapacity)
    for _, lineInfo in ipairs(allLines) do
        -- Apply category filter
        if M.categoryFilter ~= 'All' and lineInfo.category ~= M.categoryFilter then
            goto continue
        end

        local lineName = lineInfo.lineName
        local lineData = set.lines[lineName] or {}
        local isEnabled = lineData.enabled == true
        local currentSlotType = lineData.slotType or lineInfo.defaultSlotType

        -- Only show lines matching this section's slot type
        if currentSlotType ~= slotType then
            goto continue
        end

        imgui.PushID('line_' .. lineName)

        -- Checkbox (disabled if at capacity and not enabled)
        local canEnable = isEnabled or not atCapacity or slotType ~= 'rotation'

        if not canEnable then
            imgui.BeginDisabled()
        end

        local newEnabled
        newEnabled, _ = imgui.Checkbox('##enabled', isEnabled)

        if not canEnable then
            imgui.EndDisabled()
            if imgui.IsItemHovered(ImGuiHoveredFlags.AllowWhenDisabled) then
                imgui.SetTooltip('Disable another rotation line to enable this one')
            end
        end

        if newEnabled ~= isEnabled then
            if newEnabled then
                SpellsetManager.enableLine(M.selectedSet, lineName, slotType)
            else
                SpellsetManager.disableLine(M.selectedSet, lineName)
            end
        end

        -- Line name
        imgui.SameLine()
        imgui.Text(lineName)

        -- Resolved spell
        local resolved = lineData.resolved or SpellsetManager.resolveSpellFromLine(lineName)
        imgui.SameLine()
        imgui.TextColored(0.6, 0.6, 0.6, 1, '→')
        imgui.SameLine()
        if resolved then
            imgui.TextColored(0.7, 0.9, 0.7, 1, resolved)
        else
            imgui.TextColored(0.9, 0.5, 0.5, 1, '(not in book)')
        end

        -- Condition button
        imgui.SameLine()
        local hasCondition = lineData.condition and lineData.condition.conditions and #lineData.condition.conditions > 0
        if hasCondition then
            imgui.PushStyleColor(ImGuiCol.Button, 0.2, 0.5, 0.2, 1)
        end
        if imgui.SmallButton('Cond##' .. lineName) then
            M.conditionEditLine = lineName
            M.showConditionPopup = true
        end
        if hasCondition then
            imgui.PopStyleColor()
        end

        -- Right-click context menu
        if imgui.BeginPopupContextItem('ctx_' .. lineName) then
            local otherSlot = slotType == 'rotation' and 'buff_swap' or 'rotation'
            local label = slotType == 'rotation' and 'Move to Buff Swap' or 'Move to Rotation'

            if imgui.MenuItem(label) then
                if otherSlot == 'rotation' and atCapacity then
                    mq.cmd('/echo [SpellSet] Cannot move to rotation - at capacity')
                else
                    SpellsetManager.setLineSlotType(M.selectedSet, lineName, otherSlot)
                end
            end
            imgui.EndPopup()
        end

        imgui.PopID()
        ::continue::
    end
end

-- Placeholder stubs for functions to be implemented in Task 11
M.renderNewSetPopup = function() end
M.renderDeleteConfirmPopup = function() end
M.renderConditionPopup = function() end

--- Render the spell set editor window
function M.render()
    if not M.isOpen then return end

    local SpellsetManager = getSpellsetManager()
    local SpellsClr = getSpellsClr()
    if not SpellsetManager or not SpellsClr then return end

    imgui.SetNextWindowSize(500, 600, ImGuiCond.FirstUseEver)

    local open
    open, M.isOpen = imgui.Begin('Spell Set Editor##SpellSetEditor', M.isOpen)

    if open then
        M.renderHeader(SpellsetManager)
        imgui.Separator()
        M.renderSpellLines(SpellsetManager, SpellsClr)
    end

    imgui.End()

    -- Render popups
    M.renderNewSetPopup(SpellsetManager)
    M.renderDeleteConfirmPopup(SpellsetManager)
    M.renderConditionPopup()
end

return M
