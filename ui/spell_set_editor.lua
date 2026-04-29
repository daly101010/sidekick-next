-- F:/lua/sidekick-next/ui/spell_set_editor.lua
-- Main Spell Set Editor Window with Two-Tab Layout (Combat Rotation / OOC Buffs)
-- Provides UI for creating, managing, and applying spell sets

local mq = require('mq')
local imgui = require('ImGui')
local lazy = require('sidekick-next.utils.lazy_require')

-- Lazy-load Toast to avoid circular dependencies
local getToast = lazy('sidekick-next.ui.components.toast')

local M = {}

--------------------------------------------------------------------------------
-- State
--------------------------------------------------------------------------------

M.isOpen = false

local state = {
    selectedSet = nil,
    newSetName = "",
    showNewSetPopup = false,
    showDeletePopup = false,
    showUpgradePopup = false,
    upgrades = {},
    loaded = false,
}

--------------------------------------------------------------------------------
-- Lazy-loaded dependencies
--------------------------------------------------------------------------------

local getPersistence = lazy('sidekick-next.utils.spellset_persistence')
local getMemorize = lazy('sidekick-next.utils.spellset_memorize')
local getScanner = lazy('sidekick-next.utils.spellbook_scanner')
local getCombatTab = lazy('sidekick-next.ui.spell_set_combat_tab')
local getOocTab = lazy('sidekick-next.ui.spell_set_ooc_tab')
local getSpellSetData = lazy('sidekick-next.utils.spellset_data')

--------------------------------------------------------------------------------
-- Helper Functions
--------------------------------------------------------------------------------

local function saveSpellSets(Persistence)
    if not Persistence or not Persistence.save then return false end
    local ok, saved = pcall(Persistence.save)
    if not ok then
        print(string.format('\ar[SpellSetEditor]\ax Save failed: %s', tostring(saved)))
        return false
    end
    return saved ~= false
end

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

--- Get the current spell set being edited
---@return table|nil The spell set or nil
local function getCurrentSpellSet()
    local Persistence = getPersistence()
    if not Persistence then return nil end

    if state.selectedSet then
        return Persistence.getSet(state.selectedSet)
    end

    return nil
end

--- Ensure persistence is loaded
local function ensureLoaded()
    if state.loaded then return end

    local Persistence = getPersistence()
    if not Persistence then return end

    -- Load spell sets from disk
    Persistence.load()

    -- Select active set if none selected
    if not state.selectedSet then
        state.selectedSet = Persistence.activeSetName
        if not state.selectedSet then
            local names = Persistence.getSetNames()
            state.selectedSet = names[1]
        end
    end

    state.loaded = true
end

--------------------------------------------------------------------------------
-- Render Functions
--------------------------------------------------------------------------------

--- Render the header with set selector and buttons
local function renderHeader()
    local Persistence = getPersistence()
    local Memorize = getMemorize()
    if not Persistence then return end

    local isBusy = Memorize and Memorize.isBusy() or false

    -- Set selector dropdown
    local setNames = Persistence.getSetNames()
    local previewName = state.selectedSet or "(None)"

    imgui.Text("Spell Set:")
    imgui.SameLine()
    imgui.SetNextItemWidth(200)

    if imgui.BeginCombo("##SetSelector", previewName) then
        for _, name in ipairs(setNames) do
            local isSelected = (name == state.selectedSet)
            if imgui.Selectable(name, isSelected) then
                state.selectedSet = name
                Persistence.setActiveSet(name)
                saveSpellSets(Persistence)
            end
        end
        imgui.EndCombo()
    end

    -- New button
    imgui.SameLine()
    if imgui.Button("New") then
        state.newSetName = ""
        state.showNewSetPopup = true
        imgui.OpenPopup("New Spell Set##NewSetPopup")
    end

    -- Delete button
    imgui.SameLine()
    if imgui.Button("Delete") then
        if state.selectedSet and #setNames > 1 then
            state.showDeletePopup = true
            imgui.OpenPopup("Delete Spell Set?##DeletePopup")
        end
    end
    if imgui.IsItemHovered() and #setNames <= 1 then
        imgui.SetTooltip("Cannot delete the last spell set")
    end

    -- Save (and apply) button
    imgui.SameLine()
    if isBusy then
        imgui.BeginDisabled()
    end
    if imgui.Button("Save") then
        if state.selectedSet and Memorize then
            Memorize.queueApply(state.selectedSet, true)  -- true = save first
        else
            local saveOk = saveSpellSets(Persistence)
            local Toast = getToast()
            if Toast then
                if saveOk then
                    Toast.success('Spell sets saved')
                else
                    Toast.error('Failed to save spell sets')
                end
            end
        end
    end
    if isBusy then
        imgui.EndDisabled()
        if imgui.IsItemHovered(ImGuiHoveredFlags.AllowWhenDisabled) then
            imgui.SetTooltip("Memorization in progress...")
        end
    end

    -- Status indicator if memorizing
    if isBusy then
        imgui.SameLine()
        imgui.TextColored(1.0, 0.8, 0.2, 1.0, "Memorizing...")
    elseif Memorize and Memorize.getPendingSet() then
        imgui.SameLine()
            imgui.TextColored(0.7, 0.7, 0.7, 1.0,
                string.format("(Pending: %s)", Memorize.getPendingSet()))
    end

    imgui.Separator()
end

--- Render the new set popup modal
local function renderNewSetPopup()
    local Persistence = getPersistence()
    if not Persistence then return end

    local open = true
    if imgui.BeginPopupModal("New Spell Set##NewSetPopup", open, ImGuiWindowFlags.AlwaysAutoResize) then
        imgui.Text("Enter a name for the new spell set:")
        imgui.SetNextItemWidth(250)

        state.newSetName = imgui.InputText("##NewSetName", state.newSetName, 64)

        -- Check if name already exists
        local nameExists = state.newSetName ~= "" and Persistence.getSet(state.newSetName) ~= nil
        if nameExists then
            imgui.TextColored(1.0, 0.4, 0.4, 1.0, "A set with this name already exists")
        end

        imgui.Spacing()

        -- Create button (clones current set)
        local canCreate = state.newSetName ~= "" and not nameExists
        if not canCreate then
            imgui.BeginDisabled()
        end
        if imgui.Button("Create", 100, 0) then
            local SpellSetData = getSpellSetData()
            local currentSet = getCurrentSpellSet()

            if currentSet and SpellSetData and SpellSetData.clone then
                -- Clone the current set
                local newSet = SpellSetData.clone(currentSet)
                if newSet then
                    newSet.name = state.newSetName
                    -- Add directly to persistence spellSets
                    Persistence.spellSets[state.newSetName] = newSet
                    local Toast = getToast()
                    if Toast then
                        Toast.success(string.format('Created "%s"', state.newSetName))
                    end
                end
            else
                -- Fallback: create empty set if no current set
                Persistence.createSet(state.newSetName)
            end

            state.selectedSet = state.newSetName
            Persistence.setActiveSet(state.newSetName)
            saveSpellSets(Persistence)
            state.showNewSetPopup = false
            imgui.CloseCurrentPopup()
        end
        if not canCreate then
            imgui.EndDisabled()
        end

        imgui.SameLine()
        if imgui.Button("Cancel", 100, 0) then
            state.showNewSetPopup = false
            imgui.CloseCurrentPopup()
        end

        imgui.EndPopup()
    end
end

--- Render the delete confirmation popup
local function renderDeletePopup()
    local Persistence = getPersistence()
    if not Persistence then return end

    local open = true
    if imgui.BeginPopupModal("Delete Spell Set?##DeletePopup", open, ImGuiWindowFlags.AlwaysAutoResize) then
        imgui.Text(string.format('Are you sure you want to delete "%s"?', state.selectedSet or ""))
        imgui.TextColored(1.0, 0.6, 0.2, 1.0, "This action cannot be undone.")
        imgui.Spacing()

        if imgui.Button("Delete", 100, 0) then
            Persistence.deleteSet(state.selectedSet)

            -- Select first available set
            local names = Persistence.getSetNames()
            state.selectedSet = names[1]
            if state.selectedSet then
                Persistence.setActiveSet(state.selectedSet)
            end

            saveSpellSets(Persistence)
            state.showDeletePopup = false
            imgui.CloseCurrentPopup()
        end

        imgui.SameLine()
        if imgui.Button("Cancel", 100, 0) then
            state.showDeletePopup = false
            imgui.CloseCurrentPopup()
        end

        imgui.EndPopup()
    end
end

--- Render the upgrade popup modal
local function renderUpgradePopup()
    local Persistence = getPersistence()
    local SpellSetData = getSpellSetData()
    if not Persistence or not SpellSetData then return end

    local open = true
    if imgui.BeginPopupModal("Spell Upgrades Available##UpgradePopup", open, ImGuiWindowFlags.AlwaysAutoResize) then
        imgui.Text("The following spells have upgrades available in your spellbook:")
        imgui.Separator()
        imgui.Spacing()

        local upgradeCount = 0
        local spellSet = getCurrentSpellSet()

        for slot, upgradeInfo in pairs(state.upgrades) do
            upgradeCount = upgradeCount + 1
            local currentName = upgradeInfo.current and upgradeInfo.current.name or "Unknown"
            local upgradeName = upgradeInfo.upgrade and upgradeInfo.upgrade.name or "Unknown"
            local upgradeLevel = upgradeInfo.upgrade and upgradeInfo.upgrade.level or 0

            imgui.Text(string.format("Gem %d: %s", slot, currentName))
            imgui.SameLine()
            imgui.TextColored(0.5, 0.5, 0.5, 1.0, "->")
            imgui.SameLine()
            imgui.TextColored(0.4, 0.8, 0.4, 1.0, string.format("%s (L%d)", upgradeName, upgradeLevel))

            imgui.SameLine()
            imgui.PushID("upgrade_" .. slot)
            if imgui.SmallButton("Upgrade") then
                -- Apply this single upgrade
                if spellSet and upgradeInfo.upgrade then
                    local gemConfig = SpellSetData.getGem(spellSet, slot)
                    if gemConfig then
                        SpellSetData.setGem(spellSet, slot, upgradeInfo.upgrade.id,
                            gemConfig.condition, gemConfig.priority, gemConfig.buffTarget)
                    else
                        SpellSetData.setGem(spellSet, slot, upgradeInfo.upgrade.id, nil, nil, nil)
                    end
                    -- Remove from upgrades list
                    state.upgrades[slot] = nil
                end
            end
            imgui.PopID()
        end

        if upgradeCount == 0 then
            imgui.TextColored(0.5, 0.5, 0.5, 1.0, "All upgrades have been applied")
        end

        imgui.Spacing()
        imgui.Separator()

        -- Upgrade All button
        if upgradeCount > 0 then
            if imgui.Button("Upgrade All", 120, 0) then
                if spellSet then
                    for slot, upgradeInfo in pairs(state.upgrades) do
                        if upgradeInfo.upgrade then
                            local gemConfig = SpellSetData.getGem(spellSet, slot)
                            if gemConfig then
                                SpellSetData.setGem(spellSet, slot, upgradeInfo.upgrade.id,
                                    gemConfig.condition, gemConfig.priority, gemConfig.buffTarget)
                            else
                                SpellSetData.setGem(spellSet, slot, upgradeInfo.upgrade.id, nil, nil, nil)
                            end
                        end
                    end
                    state.upgrades = {}
                end
            end
            imgui.SameLine()
        end

        if imgui.Button("Close", 100, 0) then
            state.showUpgradePopup = false
            state.upgrades = {}
            imgui.CloseCurrentPopup()
        end

        imgui.EndPopup()
    end
end

--- Draw the editor content (for embedding in main UI tab)
--- @return boolean True if content was drawn
function M.drawContent()
    -- Ensure persistence is loaded
    ensureLoaded()

    local Persistence = getPersistence()
    local CombatTab = getCombatTab()
    local OocTab = getOocTab()

    if not Persistence then
        imgui.TextDisabled("Spell set persistence not available")
        return false
    end

    -- Render header with set selector and buttons
    renderHeader()

    imgui.Separator()

    -- Get current spell set
    local spellSet = getCurrentSpellSet()

    if not spellSet then
        imgui.TextDisabled("Select or create a spell set to begin editing.")
    else
        -- Tab bar for Combat Rotation and OOC Buffs
        if imgui.BeginTabBar("SpellSetTabs##Embedded") then
            -- Combat Rotation tab
            if imgui.BeginTabItem("Combat Rotation") then
                if CombatTab then
                    local ok, err = pcall(CombatTab.render, spellSet)
                    if not ok then
                        imgui.TextColored(1, 0.3, 0.3, 1, 'Error: ' .. tostring(err))
                    end
                else
                    imgui.TextDisabled("Combat tab module not available")
                end
                imgui.EndTabItem()
            end

            -- OOC Buffs tab
            if imgui.BeginTabItem("OOC Buffs") then
                if OocTab then
                    local ok, err = pcall(OocTab.render, spellSet)
                    if not ok then
                        imgui.TextColored(1, 0.3, 0.3, 1, 'Error: ' .. tostring(err))
                    end
                else
                    imgui.TextDisabled("OOC buffs tab module not available")
                end
                imgui.EndTabItem()
            end

            imgui.EndTabBar()
        end
    end

    -- Render popups (must be inside window context where OpenPopup was called)
    renderNewSetPopup()
    renderDeletePopup()
    renderUpgradePopup()

    return true
end

--- Main render function for the spell set editor window (standalone)
function M.render()
    if not M.isOpen then return end

    -- Ensure persistence is loaded
    ensureLoaded()

    local Persistence = getPersistence()

    if not Persistence then
        M.isOpen = false
        return
    end

    -- NOTE: processPending() must be called from the main loop, not here
    -- See SideKick.lua main loop for the call to Memorize.processPending()

    -- Window setup
    imgui.SetNextWindowSize(600, 700, ImGuiCond.FirstUseEver)

    local open, shouldDraw = imgui.Begin("Spell Set Editor##SpellSetEditor", M.isOpen, ImGuiWindowFlags.NoCollapse)
    if not open then
        M.isOpen = false
    end

    if shouldDraw then
        M.drawContent()
    end

    imgui.End()
end

--- Toggle the editor window visibility
function M.toggle()
    M.isOpen = not M.isOpen

    -- Scan spellbook when opening
    if M.isOpen then
        local Scanner = getScanner()
        if Scanner then
            Scanner.scan()
        end
    end
end

--- Open the editor window
function M.open()
    M.isOpen = true

    -- Scan spellbook when opening
    local Scanner = getScanner()
    if Scanner then
        Scanner.scan()
    end
end

--- Close the editor window
function M.close()
    M.isOpen = false
end

--- Reset the editor state (for reload)
function M.reset()
    state.selectedSet = nil
    state.newSetName = ""
    state.showNewSetPopup = false
    state.showDeletePopup = false
    state.showUpgradePopup = false
    state.upgrades = {}
    state.loaded = false

    -- Reset child tabs
    local CombatTab = getCombatTab()
    local OocTab = getOocTab()

    if CombatTab and CombatTab.reset then
        CombatTab.reset()
    end
    if OocTab and OocTab.reset then
        OocTab.reset()
    end
end

--- Initialize the spell set editor (loads persistence)
--- Called from SideKick.lua during startup
function M.init()
    -- Load persistence early so executors have access to active spell set
    ensureLoaded()
end

return M
