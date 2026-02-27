-- F:/lua/SideKick/ui/actors_debug.lua
-- Debug window showing actors data being shared by/to this character

local mq = require('mq')
local imgui = require('ImGui')
local lazy = require('sidekick-next.utils.lazy_require')

local M = {}

-- Window state
M.open = false
M._showWindow = false

-- Lazy-load actors coordinator
local getActorsCoord = lazy('sidekick-next.utils.actors_coordinator')

-- Helper to format a value for display
local function formatValue(v)
    if v == nil then return 'nil' end
    if type(v) == 'boolean' then return v and 'true' or 'false' end
    if type(v) == 'number' then return string.format('%.2f', v) end
    if type(v) == 'string' then return v end
    if type(v) == 'table' then
        local count = 0
        for _ in pairs(v) do count = count + 1 end
        return string.format('[table: %d items]', count)
    end
    return tostring(v)
end

-- Render a key-value table
local function renderKeyValueTable(data, tableId)
    if not data or type(data) ~= 'table' then
        imgui.TextColored(0.5, 0.5, 0.5, 1, 'No data')
        return
    end

    -- Collect and sort keys
    local keys = {}
    for k in pairs(data) do
        table.insert(keys, k)
    end
    table.sort(keys, function(a, b)
        return tostring(a) < tostring(b)
    end)

    if #keys == 0 then
        imgui.TextColored(0.5, 0.5, 0.5, 1, 'Empty')
        return
    end

    if imgui.BeginTable(tableId, 2, ImGuiTableFlags.Borders + ImGuiTableFlags.RowBg + ImGuiTableFlags.Resizable) then
        imgui.TableSetupColumn('Key', ImGuiTableColumnFlags.WidthFixed, 150)
        imgui.TableSetupColumn('Value', ImGuiTableColumnFlags.WidthStretch)
        imgui.TableHeadersRow()

        for _, k in ipairs(keys) do
            local v = data[k]
            imgui.TableNextRow()
            imgui.TableNextColumn()
            imgui.Text(tostring(k))
            imgui.TableNextColumn()

            -- If value is a table, show expandable tree
            if type(v) == 'table' then
                if imgui.TreeNode(tostring(k) .. '_expand', formatValue(v)) then
                    renderKeyValueTable(v, tableId .. '_' .. tostring(k))
                    imgui.TreePop()
                end
            else
                imgui.Text(formatValue(v))
            end
        end

        imgui.EndTable()
    end
end

-- Render outgoing data tab (what this character shares)
local function renderOutgoingTab()
    local ActorsCoord = getActorsCoord()
    if not ActorsCoord then
        imgui.TextColored(1, 0.5, 0.5, 1, 'Actors coordinator not loaded')
        return
    end

    -- Self info header
    local selfInfo = ActorsCoord.getSelfInfo()
    imgui.TextColored(0.5, 0.8, 1, 1, 'Self:')
    imgui.SameLine()
    imgui.Text(string.format('%s @ %s [%s]', selfInfo.name or '?', selfInfo.server or '?', selfInfo.zone or '?'))
    imgui.Separator()

    -- Outgoing status payload
    imgui.TextColored(0.8, 1, 0.8, 1, 'Outgoing Status Payload (broadcast every ~1s):')
    local outgoing = ActorsCoord.getOutgoingStatus()
    if outgoing then
        renderKeyValueTable(outgoing, 'outgoing_status')
    else
        imgui.TextColored(0.5, 0.5, 0.5, 1, 'Not yet broadcasting (tick not called)')
    end

    imgui.Spacing()
    imgui.Separator()

    -- Tank state (if we're broadcasting as tank)
    imgui.TextColored(0.8, 1, 0.8, 1, 'Tank State (if tanking):')
    local tankState = ActorsCoord.getTankState()
    if tankState and (tankState.primaryTargetId or tankState.tankId) then
        renderKeyValueTable(tankState, 'tank_state')
    else
        imgui.TextColored(0.5, 0.5, 0.5, 1, 'No tank state (not tanking)')
    end
end

-- Render incoming data tab (what this character receives)
local function renderIncomingTab()
    local ActorsCoord = getActorsCoord()
    if not ActorsCoord then
        imgui.TextColored(1, 0.5, 0.5, 1, 'Actors coordinator not loaded')
        return
    end

    -- Remote characters
    imgui.TextColored(1, 0.8, 0.5, 1, 'Remote Characters (status:update from other SideKick instances):')
    local remoteChars = ActorsCoord.getRemoteCharacters()
    local charCount = 0
    for _ in pairs(remoteChars) do charCount = charCount + 1 end

    if charCount == 0 then
        imgui.TextColored(0.5, 0.5, 0.5, 1, 'No remote characters detected')
    else
        imgui.Text(string.format('Receiving from %d character(s):', charCount))
        imgui.Spacing()

        if imgui.BeginTable('remote_chars', 7, ImGuiTableFlags.Borders + ImGuiTableFlags.RowBg + ImGuiTableFlags.Resizable + ImGuiTableFlags.ScrollY, 0, 200) then
            imgui.TableSetupColumn('Name', ImGuiTableColumnFlags.WidthFixed, 100)
            imgui.TableSetupColumn('Class', ImGuiTableColumnFlags.WidthFixed, 50)
            imgui.TableSetupColumn('Zone', ImGuiTableColumnFlags.WidthFixed, 80)
            imgui.TableSetupColumn('HP', ImGuiTableColumnFlags.WidthFixed, 50)
            imgui.TableSetupColumn('Mana', ImGuiTableColumnFlags.WidthFixed, 50)
            imgui.TableSetupColumn('Chase', ImGuiTableColumnFlags.WidthFixed, 50)
            imgui.TableSetupColumn('Age', ImGuiTableColumnFlags.WidthFixed, 50)
            imgui.TableHeadersRow()

            local now = os.clock()
            for name, data in pairs(remoteChars) do
                imgui.TableNextRow()
                imgui.TableNextColumn()
                imgui.Text(name)
                imgui.TableNextColumn()
                imgui.Text(data.class or '?')
                imgui.TableNextColumn()
                imgui.Text(data.zone or '?')
                imgui.TableNextColumn()
                imgui.Text(data.hp and string.format('%d%%', data.hp) or '?')
                imgui.TableNextColumn()
                imgui.Text(data.mana and string.format('%d%%', data.mana) or '?')
                imgui.TableNextColumn()
                imgui.Text(data.chase and 'On' or 'Off')
                imgui.TableNextColumn()
                local age = now - (data.lastSeen or now)
                imgui.Text(string.format('%.1fs', age))
            end

            imgui.EndTable()
        end

        -- Expandable details for each character
        imgui.Spacing()
        if imgui.CollapsingHeader('Character Details') then
            for name, data in pairs(remoteChars) do
                if imgui.TreeNode(name .. '_details', name) then
                    renderKeyValueTable(data, 'char_' .. name)
                    imgui.TreePop()
                end
            end
        end
    end

    imgui.Spacing()
    imgui.Separator()

    -- Heal claims
    imgui.TextColored(1, 0.8, 0.5, 1, 'Heal Claims (from other healers):')
    local healClaims = ActorsCoord.getHealClaimsRaw()
    local claimCount = 0
    for tid, perFrom in pairs(healClaims) do
        for _ in pairs(perFrom) do claimCount = claimCount + 1 end
    end

    if claimCount == 0 then
        imgui.TextColored(0.5, 0.5, 0.5, 1, 'No active heal claims')
    else
        imgui.Text(string.format('%d active claim(s):', claimCount))
        if imgui.BeginTable('heal_claims', 4, ImGuiTableFlags.Borders + ImGuiTableFlags.RowBg) then
            imgui.TableSetupColumn('Target ID', ImGuiTableColumnFlags.WidthFixed, 80)
            imgui.TableSetupColumn('From', ImGuiTableColumnFlags.WidthFixed, 100)
            imgui.TableSetupColumn('Spell', ImGuiTableColumnFlags.WidthStretch)
            imgui.TableSetupColumn('Expires', ImGuiTableColumnFlags.WidthFixed, 60)
            imgui.TableHeadersRow()

            local now = os.clock()
            for tid, perFrom in pairs(healClaims) do
                for from, claim in pairs(perFrom) do
                    imgui.TableNextRow()
                    imgui.TableNextColumn()
                    imgui.Text(tostring(tid))
                    imgui.TableNextColumn()
                    imgui.Text(from)
                    imgui.TableNextColumn()
                    imgui.Text(claim.spellName or '?')
                    imgui.TableNextColumn()
                    local ttl = (claim.expiresAt or now) - now
                    imgui.Text(string.format('%.1fs', ttl))
                end
            end

            imgui.EndTable()
        end
    end

    imgui.Spacing()
    imgui.Separator()

    -- HoT states
    imgui.TextColored(1, 0.8, 0.5, 1, 'HoT States (from other healers):')
    local hotStates = ActorsCoord.getHoTStatesRaw()
    local hotCount = 0
    for tid, perFrom in pairs(hotStates) do
        for _ in pairs(perFrom) do hotCount = hotCount + 1 end
    end

    if hotCount == 0 then
        imgui.TextColored(0.5, 0.5, 0.5, 1, 'No active HoT tracking')
    else
        imgui.Text(string.format('%d active HoT(s):', hotCount))
        if imgui.BeginTable('hot_states', 4, ImGuiTableFlags.Borders + ImGuiTableFlags.RowBg) then
            imgui.TableSetupColumn('Target ID', ImGuiTableColumnFlags.WidthFixed, 80)
            imgui.TableSetupColumn('From', ImGuiTableColumnFlags.WidthFixed, 100)
            imgui.TableSetupColumn('Spell', ImGuiTableColumnFlags.WidthStretch)
            imgui.TableSetupColumn('Expires', ImGuiTableColumnFlags.WidthFixed, 60)
            imgui.TableHeadersRow()

            local now = os.clock()
            for tid, perFrom in pairs(hotStates) do
                for from, hot in pairs(perFrom) do
                    imgui.TableNextRow()
                    imgui.TableNextColumn()
                    imgui.Text(tostring(tid))
                    imgui.TableNextColumn()
                    imgui.Text(from)
                    imgui.TableNextColumn()
                    imgui.Text(hot.spellName or '?')
                    imgui.TableNextColumn()
                    local ttl = (hot.expiresAt or now) - now
                    imgui.Text(string.format('%.1fs', ttl))
                end
            end

            imgui.EndTable()
        end
    end

    imgui.Spacing()
    imgui.Separator()

    -- Tank state received
    imgui.TextColored(1, 0.8, 0.5, 1, 'Tank State (received from tank):')
    local tankState = ActorsCoord.getTankState()
    if tankState and tankState.updatedAt and tankState.updatedAt > 0 then
        renderKeyValueTable(tankState, 'tank_state_recv')
    else
        imgui.TextColored(0.5, 0.5, 0.5, 1, 'No tank state received')
    end
end

-- Main render function
function M.render()
    if not M.open then return end

    M.open, M._showWindow = imgui.Begin('SideKick Actors Debug', M.open, ImGuiWindowFlags.None)
    if M._showWindow then
        if imgui.BeginTabBar('ActorsDebugTabs') then
            if imgui.BeginTabItem('Outgoing (Shared BY Me)') then
                renderOutgoingTab()
                imgui.EndTabItem()
            end

            if imgui.BeginTabItem('Incoming (Shared TO Me)') then
                renderIncomingTab()
                imgui.EndTabItem()
            end

            imgui.EndTabBar()
        end
    end
    imgui.End()
end

-- Toggle window visibility
function M.toggle()
    M.open = not M.open
end

-- Show window
function M.show()
    M.open = true
end

-- Hide window
function M.hide()
    M.open = false
end

return M
