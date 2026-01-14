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

-- Placeholder stubs for functions to be implemented in Tasks 10 and 11
M.renderSpellLines = function() end
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
