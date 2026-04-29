local mq = require('mq')
local imgui = require('ImGui')
local iam = require('sidekick-next.utils.imanim')
local AnimHelpers = require('sidekick-next.ui.animation_helpers')
local Core = require('sidekick-next.utils.core')
local ActorsCoordinator = require('sidekick-next.utils.actors_coordinator')
local Themes = require('sidekick-next.themes')
local Draw = require('sidekick-next.ui.draw_helpers')
local Helpers = require('sidekick-next.lib.helpers')

-- Use centralized draw helpers for cross-build compatibility
local IM_COL32 = Draw.IM_COL32
local dlAddRectFilled = Draw.addRectFilled
local dlAddRect = Draw.addRect
local dlAddText = Draw.addText

local M = {}

-- Icon Rendering
local animSpellIcons = mq.FindTextureAnimation('A_SpellIcons')
local animItems = mq.FindTextureAnimation('A_DragItem')

local State = {
    open = false,
    selectedAbilities = {},  -- { [charName] = { [abilityName] = true } }
    abilityOrder = {},       -- { [charName] = { "ability1", "ability2", ... } } - ordered list
}

-- Module-level drag state for ImGui drag-drop
local _dragKey = nil  -- "charName:orderIndex"

-- Load saved selections from INI (order preserved from CSV)
local function loadSelections()
    local sec = Core.Ini['RemoteAbilities'] or {}
    for charName, csv in pairs(sec) do
        if type(csv) == 'string' then
            State.selectedAbilities[charName] = {}
            State.abilityOrder[charName] = {}
            for abilityName in string.gmatch(csv, '([^,]+)') do
                abilityName = abilityName:match('^%s*(.-)%s*$')
                if abilityName ~= '' then
                    State.selectedAbilities[charName][abilityName] = true
                    table.insert(State.abilityOrder[charName], abilityName)
                end
            end
        end
    end
end

-- Save selections to INI (preserves order)
local function saveSelections()
    Core.Ini['RemoteAbilities'] = Core.Ini['RemoteAbilities'] or {}
    for charName, _ in pairs(State.selectedAbilities) do
        local order = State.abilityOrder[charName] or {}
        -- Filter to only enabled abilities, maintaining order
        local list = {}
        for _, abilityName in ipairs(order) do
            if State.selectedAbilities[charName][abilityName] then
                table.insert(list, abilityName)
            end
        end
        Core.Ini['RemoteAbilities'][charName] = table.concat(list, ',')
    end
    if Core.save then Core.save() end
end

-- Get ordered list of abilities for a character
local function getOrderedAbilities(charName)
    local selected = State.selectedAbilities[charName] or {}
    local order = State.abilityOrder[charName] or {}

    -- Build ordered list of enabled abilities
    local ordered = {}
    local seen = {}
    for _, abilityName in ipairs(order) do
        if selected[abilityName] then
            table.insert(ordered, abilityName)
            seen[abilityName] = true
        end
    end

    -- Add any new abilities not in order yet
    for abilityName, enabled in pairs(selected) do
        if enabled and not seen[abilityName] then
            table.insert(ordered, abilityName)
        end
    end

    return ordered
end

-- Swap two abilities in the order
local function swapAbilities(charName, idx1, idx2)
    local order = State.abilityOrder[charName]
    if not order then return end
    if idx1 < 1 or idx1 > #order then return end
    if idx2 < 1 or idx2 > #order then return end
    order[idx1], order[idx2] = order[idx2], order[idx1]
    saveSelections()
end

-- Execute an ability on a remote character via /dex
local function executeRemoteAbility(charName, ability)
    local kind = ability.kind or 'aa'
    if kind == 'aa' and ability.altID then
        mq.cmdf('/dex %s /alt activate %d', charName, ability.altID)
    elseif kind == 'disc' and ability.discName then
        mq.cmdf('/dex %s /disc "%s"', charName, ability.discName)
    elseif kind == 'ability' and ability.altName then
        mq.cmdf('/dex %s /doability "%s"', charName, ability.altName)
    elseif kind == 'item' and ability.itemName then
        mq.cmdf('/dex %s /useitem "%s"', charName, ability.itemName)
    end
end

-- Use shared fmtCooldown from Helpers
local fmtCooldown = Helpers.fmtCooldown

-- Draw outlined text (for button labels)
-- Uses Draw.addText wrapper for proper API detection across MQ builds
local function drawOutlinedText(drawList, x, y, text, col)
    local black = IM_COL32(0, 0, 0, 255)
    local offsets = { {-1,-1}, {0,-1}, {1,-1}, {-1,0}, {1,0}, {-1,1}, {0,1}, {1,1} }
    for _, off in ipairs(offsets) do
        Draw.addText(drawList, x + off[1], y + off[2], black, text)
    end
    Draw.addText(drawList, x, y, col, text)
end

-- Render a single ability button with icon, cooldown overlay, and timer
-- Returns: clicked, dropTarget (charName, abilityName of dropped item if any)
local function renderAbilityButton(charName, abilityName, ability, size, idx, orderIndex)
    local uniqueId = charName .. '_' .. abilityName .. '_' .. tostring(idx)
    local clicked = false
    local dropTarget = nil

    local cursorScreenPos = imgui.GetCursorScreenPosVec()
    local drawList = imgui.GetWindowDrawList()

    -- Extract coordinates for safe DrawList wrapper usage
    local cx, cy = Draw.vec2xy(cursorScreenPos)

    -- Get cooldown info
    local cooldown = tonumber(ability.cooldown) or 0
    local cooldownTotal = tonumber(ability.cooldownTotal) or 0
    local ready = ability.ready == true
    local iconId = tonumber(ability.icon) or 0

    -- Build drag key for this button
    local myDragKey = charName .. ':' .. tostring(orderIndex)

    -- Draw icon background
    if animSpellIcons and iconId > 0 then
        animSpellIcons:SetTextureCell(iconId)
        -- AddTextureAnimation requires ImVec2, use pcall for safety
        pcall(function() drawList:AddTextureAnimation(animSpellIcons, cursorScreenPos, ImVec2(size, size)) end)
    else
        -- Fallback: draw colored rectangle
        local bgCol = ready and IM_COL32(60, 120, 60, 200) or IM_COL32(80, 80, 80, 200)
        dlAddRectFilled(drawList, cx, cy, cx + size, cy + size, bgCol)
    end

    -- Dim if being dragged
    if _dragKey == myDragKey then
        dlAddRectFilled(drawList, cx, cy, cx + size, cy + size, IM_COL32(0, 0, 0, 120))
    end

    -- Invisible button for interaction
    imgui.InvisibleButton('##btn_' .. uniqueId, size, size)

    local isHovered = imgui.IsItemHovered()
    local isActive = imgui.IsItemActive()

    -- Track if we're dragging
    local isDragging = false
    if imgui.IsMouseDragging then
        local okDrag, dragging = pcall(imgui.IsMouseDragging, 0, 4)
        if okDrag and dragging and isActive then
            isDragging = true
        end
    end

    -- Drag source using ImGui native API
    if imgui.BeginDragDropSource and imgui.EndDragDropSource then
        local ok, started = pcall(imgui.BeginDragDropSource)
        if ok and started then
            _dragKey = myDragKey
            isDragging = true
            if imgui.SetDragDropPayload then
                pcall(imgui.SetDragDropPayload, 'RemoteAbilitySwap', myDragKey)
            end
            imgui.Text(string.format('Move: %s', abilityName))
            imgui.EndDragDropSource()
        end
    end

    -- Drop target using ImGui native API
    local swapped = false
    if imgui.BeginDragDropTarget and imgui.EndDragDropTarget then
        local ok, isTarget = pcall(imgui.BeginDragDropTarget)
        if ok and isTarget then
            local droppedKey = nil
            if imgui.AcceptDragDropPayload then
                local ok2, payload = pcall(imgui.AcceptDragDropPayload, 'RemoteAbilitySwap')
                if ok2 and payload ~= nil then
                    if type(payload) == 'string' then
                        droppedKey = payload
                    elseif type(payload) == 'table' then
                        droppedKey = payload.Data or payload.data or payload.Payload or payload.payload
                    end
                end
            end
            -- Fallback if payload didn't work
            if not droppedKey and _dragKey and imgui.IsMouseReleased and imgui.IsMouseReleased(0) then
                droppedKey = _dragKey
            end
            -- Process the drop if valid
            if droppedKey and droppedKey ~= '' and droppedKey ~= myDragKey then
                -- Parse the dropped key: "charName:orderIndex"
                local srcChar, srcIdx = droppedKey:match('^(.+):(%d+)$')
                srcIdx = tonumber(srcIdx)
                if srcChar == charName and srcIdx and srcIdx ~= orderIndex then
                    dropTarget = {
                        sourceIndex = srcIdx,
                        targetIndex = orderIndex,
                    }
                    swapped = true
                end
                _dragKey = nil
            end
            imgui.EndDragDropTarget()
        end
    end

    -- Handle click (only on release, not while dragging)
    local released = false
    if imgui.IsMouseReleased then
        local okRel, v = pcall(imgui.IsMouseReleased, 0)
        released = okRel and v == true
    end
    if released and isHovered and not isDragging and not swapped then
        clicked = true
    end

    -- Hover highlight (when not dragging)
    if isHovered and not _dragKey then
        dlAddRectFilled(drawList, cx, cy, cx + size, cy + size, IM_COL32(255, 255, 255, 50))
    end

    -- Cooldown overlay (red -> orange -> yellow gradient based on time remaining)
    if cooldown > 0 then
        local pct = 1.0
        if cooldownTotal > 0 then
            pct = cooldown / cooldownTotal
            pct = math.max(0, math.min(1, pct))
        end

        -- Interpolate from Red (high cooldown) to Yellow (almost ready)
        -- pct=1.0 (just fired) -> Red (255, 50, 50)
        -- pct=0.5 (halfway) -> Orange (255, 150, 50)
        -- pct=0.0 (ready) -> Yellow (255, 255, 50)
        local r = 255
        local g = math.floor(50 + (1.0 - pct) * 205)  -- 50 -> 255 as cooldown decreases
        local b = 50
        local overlayCol = IM_COL32(r, g, b, 140)

        -- Dark overlay first for better visibility
        dlAddRectFilled(drawList, cx, cy, cx + size, cy + size, IM_COL32(0, 0, 0, 120))

        -- Fill from bottom based on remaining cooldown
        local fillH = math.floor(size * pct)
        local fillY = cy + size - fillH
        dlAddRectFilled(drawList, cx, fillY, cx + size, cy + size, overlayCol)

        -- Colored border matching the overlay
        dlAddRect(drawList, cx, cy, cx + size, cy + size, IM_COL32(r, g, b, 200), 0, 0, 2)

        -- Draw cooldown timer text centered on button
        local timerText = fmtCooldown(cooldown)
        local textW, textH = imgui.CalcTextSize(timerText)
        local tx = cx + (size - textW) / 2
        local ty = cy + (size - textH) / 2
        -- Outline for readability
        drawOutlinedText(drawList, tx, ty, timerText, IM_COL32(255, 255, 255, 255))
    elseif ready then
        -- Ready glow effect
        local pulse = AnimHelpers.getReadyGlow and AnimHelpers.getReadyGlow() or 0.5
        local glowAlpha = math.floor(pulse * 80)
        dlAddRect(drawList, cx, cy, cx + size, cy + size, IM_COL32(80, 200, 255, glowAlpha), 0, 0, 2)
    end

    -- Draw short name label at top with word wrapping
    local label = ability.shortName or abilityName
    local maxWidth = size - 4  -- Leave small margin

    -- Split into words and wrap
    local words = {}
    for word in label:gmatch('%S+') do
        table.insert(words, word)
    end

    local lines = {}
    local currentLine = ''
    for _, word in ipairs(words) do
        local testLine = currentLine == '' and word or (currentLine .. ' ' .. word)
        local testW = imgui.CalcTextSize(testLine)
        if type(testW) == 'table' then testW = testW.x or testW[1] or 0 end

        if testW <= maxWidth then
            currentLine = testLine
        else
            if currentLine ~= '' then
                table.insert(lines, currentLine)
            end
            -- Check if single word fits, truncate if not
            local wordW = imgui.CalcTextSize(word)
            if type(wordW) == 'table' then wordW = wordW.x or wordW[1] or 0 end
            if wordW > maxWidth then
                -- Truncate long word
                local truncated = word
                while #truncated > 1 do
                    truncated = truncated:sub(1, -2)
                    local tw = imgui.CalcTextSize(truncated .. '..')
                    if type(tw) == 'table' then tw = tw.x or tw[1] or 0 end
                    if tw <= maxWidth then
                        truncated = truncated .. '..'
                        break
                    end
                end
                currentLine = truncated
            else
                currentLine = word
            end
        end
    end
    if currentLine ~= '' then
        table.insert(lines, currentLine)
    end

    -- Limit to 2 lines max
    if #lines > 2 then
        lines = { lines[1], lines[2] }
        if lines[2] then
            lines[2] = lines[2]:sub(1, -3) .. '..'
        end
    end

    -- Draw each line centered
    local lineH = imgui.GetTextLineHeight and imgui.GetTextLineHeight() or 13
    local ly = cursorScreenPos.y + 2
    for _, line in ipairs(lines) do
        local lineW = imgui.CalcTextSize(line)
        if type(lineW) == 'table' then lineW = lineW.x or lineW[1] or 0 end
        local lx = cursorScreenPos.x + (size - lineW) / 2
        drawOutlinedText(drawList, lx, ly, line, IM_COL32(255, 255, 255, 255))
        ly = ly + lineH
    end

    -- Tooltip on hover (but not while dragging)
    if isHovered and not _dragKey then
        imgui.BeginTooltip()
        imgui.Text(string.format('%s: %s', charName, abilityName))
        if cooldown > 0 then
            imgui.Text(string.format('Cooldown: %s', fmtCooldown(cooldown)))
        else
            imgui.TextColored(0.3, 1.0, 0.3, 1.0, 'Ready')
        end
        imgui.TextDisabled('Drag to reorder')
        imgui.EndTooltip()
    end

    return clicked, dropTarget
end

-- Main floating bar draw function
function M.draw()
    if not State.open then return end

    local remoteChars = {}
    if ActorsCoordinator.getRemoteCharacters then
        remoteChars = ActorsCoordinator.getRemoteCharacters() or {}
    end

    if not next(remoteChars) then return end

    -- Initialize animation helpers
    if AnimHelpers.init then
        AnimHelpers.init(ImAnim)
    end

    -- Settings
    local cell = 48
    local gap = 4
    local pad = 6

    -- Build window flags: no title bar, no scrollbar, auto-resize to fit content
    local flags = 0
    if ImGuiWindowFlags then
        flags = (ImGuiWindowFlags.NoTitleBar or 0)
        flags = flags + (ImGuiWindowFlags.NoScrollbar or 0)
        flags = flags + (ImGuiWindowFlags.AlwaysAutoResize or 0)
    end

    -- Apply theme
    local themeName = Core.Settings.SideKickTheme or 'Classic'
    local pushedTheme = Themes.pushWindowTheme(imgui, themeName, {
        windowAlpha = 0.92,
        childAlpha = 0.92 * 0.6,
        popupAlpha = 0.96,
        ImGuiCol = ImGuiCol,
    })

    imgui.PushStyleVar(ImGuiStyleVar.WindowPadding, pad, pad)
    imgui.PushStyleVar(ImGuiStyleVar.WindowRounding, 6)

    local open, show = imgui.Begin('Remote Abilities##SideKick', true, flags)
    if not open then
        State.open = false
        imgui.End()
        imgui.PopStyleVar(2)
        if pushedTheme > 0 then imgui.PopStyleColor(pushedTheme) end
        return
    end

    local idx = 0
    for charName, data in pairs(remoteChars) do
        -- Get ordered list of selected abilities
        local orderedNames = getOrderedAbilities(charName)
        local charAbilities = {}

        -- Collect abilities in order, with their data
        for orderIdx, abilityName in ipairs(orderedNames) do
            if data.abilities and data.abilities[abilityName] then
                table.insert(charAbilities, {
                    name = abilityName,
                    data = data.abilities[abilityName],
                    orderIndex = orderIdx,
                })
            end
        end

        if #charAbilities > 0 then
            -- Character header
            imgui.TextColored(0.7, 0.9, 1.0, 1.0, charName)
            if data.class and data.class ~= '' then
                imgui.SameLine()
                imgui.TextDisabled('(' .. data.class .. ')')
            end

            -- Draw ability buttons in a row
            local startX = imgui.GetCursorPosX()
            for i, item in ipairs(charAbilities) do
                idx = idx + 1
                if i > 1 then
                    imgui.SameLine(0, gap)
                end

                imgui.SetCursorPosX(startX + (i - 1) * (cell + gap))

                local clicked, dropTarget = renderAbilityButton(charName, item.name, item.data, cell, idx, item.orderIndex)

                if clicked and not _dragKey then
                    executeRemoteAbility(charName, item.data)
                end

                -- Handle drop - swap abilities
                if dropTarget then
                    swapAbilities(charName, dropTarget.sourceIndex, dropTarget.targetIndex)
                end
            end

            imgui.Spacing()
        end
    end

    -- Global cleanup: clear drag if mouse released anywhere
    if _dragKey and imgui.IsMouseDown and not imgui.IsMouseDown(0) then
        _dragKey = nil
    end

    imgui.End()
    imgui.PopStyleVar(2)
    if pushedTheme > 0 then imgui.PopStyleColor(pushedTheme) end
end

-- Note: drawSettings() has been moved to ui/settings.lua (Remote tab)
-- The separate settings window is no longer used.

-- Deprecated: toggleSettings() - settings are now in the main Settings window (Remote tab)
-- Kept for backwards compatibility but does nothing
function M.toggleSettings()
    -- Settings are now in the main Settings window (Remote tab)
    -- This function is deprecated and does nothing
end

function M.setOpen(open)
    State.open = open
end

function M.isOpen()
    return State.open
end

function M.toggle()
    State.open = not State.open
end

-- Get the selected abilities table (for settings UI to read/modify)
function M.getSelectedAbilities()
    return State.selectedAbilities
end

-- Set an ability selection and save immediately
function M.setAbilitySelected(charName, abilityName, enabled)
    State.selectedAbilities[charName] = State.selectedAbilities[charName] or {}
    State.abilityOrder[charName] = State.abilityOrder[charName] or {}

    if enabled then
        State.selectedAbilities[charName][abilityName] = true
        -- Add to order if not already present
        local found = false
        for _, name in ipairs(State.abilityOrder[charName]) do
            if name == abilityName then
                found = true
                break
            end
        end
        if not found then
            table.insert(State.abilityOrder[charName], abilityName)
        end
    else
        State.selectedAbilities[charName][abilityName] = nil
        -- Remove from order
        for i, name in ipairs(State.abilityOrder[charName]) do
            if name == abilityName then
                table.remove(State.abilityOrder[charName], i)
                break
            end
        end
    end

    saveSelections()
end

-- Check if any abilities are selected across all characters
function M.hasAnySelected()
    for charName, abilities in pairs(State.selectedAbilities) do
        for abilityName, enabled in pairs(abilities) do
            if enabled then
                return true
            end
        end
    end
    return false
end

-- Auto-open the bar if any abilities are selected
function M.autoOpen()
    if M.hasAnySelected() then
        State.open = true
    end
end

function M.init()
    loadSelections()
    -- Auto-open if any abilities were previously selected
    M.autoOpen()
end

return M
