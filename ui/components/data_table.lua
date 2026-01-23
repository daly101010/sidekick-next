-- ============================================================
-- SideKick Data Table Component
-- ============================================================
-- Styled data tables with sorting, selection, and theming.
--
-- Usage:
--   local DataTable = require('sidekick-next.ui.components.data_table')
--
--   local columns = {
--       { key = 'name', header = 'Name', width = 100 },
--       { key = 'level', header = 'Level', width = 50, sortable = true },
--       { key = 'class', header = 'Class', width = 60 },
--   }
--   local data = {
--       { name = 'Warrior', level = 65, class = 'WAR' },
--       { name = 'Cleric', level = 60, class = 'CLR' },
--   }
--
--   local selected = DataTable.draw('##players', columns, data, 'Classic', opts)

local imgui = require('ImGui')
local Draw = require('sidekick-next.ui.draw_helpers')
local Colors = require('sidekick-next.ui.colors')

local M = {}

-- ============================================================
-- TABLE STATE
-- ============================================================

local _tableStates = {}

local function getTableState(tableId)
    if not _tableStates[tableId] then
        _tableStates[tableId] = {
            sortColumn = nil,
            sortAscending = true,
            selectedRow = nil,
            scrollY = 0,
        }
    end
    return _tableStates[tableId]
end

-- ============================================================
-- SORTING
-- ============================================================

local function sortData(data, column, ascending)
    if not column or not data or #data == 0 then return data end

    local sorted = {}
    for i, row in ipairs(data) do
        sorted[i] = row
    end

    table.sort(sorted, function(a, b)
        local va = a[column.key]
        local vb = b[column.key]

        -- Handle nil values
        if va == nil and vb == nil then return false end
        if va == nil then return not ascending end
        if vb == nil then return ascending end

        -- Compare based on type
        local ta, tb = type(va), type(vb)
        if ta ~= tb then
            va, vb = tostring(va), tostring(vb)
        end

        if ta == 'number' then
            if ascending then
                return va < vb
            else
                return va > vb
            end
        else
            va, vb = tostring(va):lower(), tostring(vb):lower()
            if ascending then
                return va < vb
            else
                return va > vb
            end
        end
    end)

    return sorted
end

-- ============================================================
-- THEME COLORS
-- ============================================================

local function getTableColors(themeName)
    local colors = {
        Classic = {
            headerBg = { 0.18, 0.22, 0.28 },
            headerText = { 0.8, 0.85, 0.9 },
            rowBg = { 0.12, 0.14, 0.18 },
            rowAltBg = { 0.14, 0.16, 0.20 },
            rowHoverBg = { 0.20, 0.25, 0.32 },
            rowSelectedBg = { 0.22, 0.35, 0.50 },
            border = { 0.25, 0.28, 0.32 },
            text = { 0.75, 0.78, 0.82 },
            sortIndicator = { 0.5, 0.7, 1.0 },
        },
        Dark = {
            headerBg = { 0.10, 0.12, 0.16 },
            headerText = { 0.75, 0.80, 0.85 },
            rowBg = { 0.08, 0.10, 0.14 },
            rowAltBg = { 0.10, 0.12, 0.16 },
            rowHoverBg = { 0.16, 0.20, 0.28 },
            rowSelectedBg = { 0.18, 0.30, 0.45 },
            border = { 0.20, 0.22, 0.28 },
            text = { 0.70, 0.73, 0.78 },
            sortIndicator = { 0.45, 0.65, 0.95 },
        },
        Neon = {
            headerBg = { 0.05, 0.08, 0.12 },
            headerText = { 0.0, 0.9, 0.7 },
            rowBg = { 0.04, 0.06, 0.10 },
            rowAltBg = { 0.06, 0.08, 0.12 },
            rowHoverBg = { 0.08, 0.15, 0.18 },
            rowSelectedBg = { 0.0, 0.25, 0.30 },
            border = { 0.0, 0.4, 0.3 },
            text = { 0.0, 0.8, 0.6 },
            sortIndicator = { 0.0, 1.0, 0.8 },
        },
        Velious = {
            headerBg = { 0.12, 0.16, 0.24 },
            headerText = { 0.7, 0.85, 1.0 },
            rowBg = { 0.08, 0.12, 0.18 },
            rowAltBg = { 0.10, 0.14, 0.22 },
            rowHoverBg = { 0.15, 0.22, 0.35 },
            rowSelectedBg = { 0.18, 0.35, 0.55 },
            border = { 0.25, 0.38, 0.55 },
            text = { 0.65, 0.80, 0.95 },
            sortIndicator = { 0.5, 0.75, 1.0 },
        },
        Kunark = {
            headerBg = { 0.18, 0.12, 0.08 },
            headerText = { 1.0, 0.85, 0.65 },
            rowBg = { 0.12, 0.08, 0.05 },
            rowAltBg = { 0.15, 0.10, 0.07 },
            rowHoverBg = { 0.25, 0.18, 0.12 },
            rowSelectedBg = { 0.40, 0.28, 0.15 },
            border = { 0.45, 0.32, 0.20 },
            text = { 0.90, 0.78, 0.60 },
            sortIndicator = { 1.0, 0.7, 0.4 },
        },
    }
    return colors[themeName] or colors.Classic
end

-- ============================================================
-- MAIN TABLE DRAWING
-- ============================================================

function M.draw(tableId, columns, data, themeName, opts)
    opts = opts or {}

    local height = opts.height or 0  -- 0 = auto
    local selectable = opts.selectable ~= false
    local striped = opts.striped ~= false
    local borders = opts.borders ~= false
    local resizable = opts.resizable == true
    local showHeader = opts.showHeader ~= false
    local rowHeight = opts.rowHeight or 24

    if not columns or #columns == 0 then return nil end

    local state = getTableState(tableId)
    local colors = getTableColors(themeName or 'Classic')

    -- Sort data if needed
    local displayData = data or {}
    if state.sortColumn then
        displayData = sortData(displayData, state.sortColumn, state.sortAscending)
    end

    -- Build table flags
    local flags = 0
    if ImGuiTableFlags then
        if borders then
            flags = bit32 and bit32.bor(flags, ImGuiTableFlags.BordersOuter or 0) or flags
            flags = bit32 and bit32.bor(flags, ImGuiTableFlags.BordersInnerV or 0) or flags
        end
        if resizable then
            flags = bit32 and bit32.bor(flags, ImGuiTableFlags.Resizable or 0) or flags
        end
        flags = bit32 and bit32.bor(flags, ImGuiTableFlags.ScrollY or 0) or flags
        flags = bit32 and bit32.bor(flags, ImGuiTableFlags.RowBg or 0) or flags
    end

    -- Push table colors
    local colorsPushed = 0
    if imgui.PushStyleColor and ImGuiCol then
        pcall(function()
            imgui.PushStyleColor(ImGuiCol.TableHeaderBg, colors.headerBg[1], colors.headerBg[2], colors.headerBg[3], 1)
            colorsPushed = colorsPushed + 1
        end)
        pcall(function()
            imgui.PushStyleColor(ImGuiCol.TableRowBg, colors.rowBg[1], colors.rowBg[2], colors.rowBg[3], 1)
            colorsPushed = colorsPushed + 1
        end)
        pcall(function()
            imgui.PushStyleColor(ImGuiCol.TableRowBgAlt, colors.rowAltBg[1], colors.rowAltBg[2], colors.rowAltBg[3], 1)
            colorsPushed = colorsPushed + 1
        end)
        pcall(function()
            imgui.PushStyleColor(ImGuiCol.TableBorderStrong, colors.border[1], colors.border[2], colors.border[3], 1)
            colorsPushed = colorsPushed + 1
        end)
        pcall(function()
            imgui.PushStyleColor(ImGuiCol.TableBorderLight, colors.border[1], colors.border[2], colors.border[3], 0.5)
            colorsPushed = colorsPushed + 1
        end)
    end

    local selectedRow = nil

    if imgui.BeginTable(tableId, #columns, flags, 0, height) then
        -- Setup columns
        for _, col in ipairs(columns) do
            local colFlags = 0
            if ImGuiTableColumnFlags then
                if col.width then
                    colFlags = bit32 and bit32.bor(colFlags, ImGuiTableColumnFlags.WidthFixed or 0) or colFlags
                end
                if not col.sortable then
                    colFlags = bit32 and bit32.bor(colFlags, ImGuiTableColumnFlags.NoSort or 0) or colFlags
                end
            end
            imgui.TableSetupColumn(col.header or col.key, colFlags, col.width or 0)
        end

        -- Header row
        if showHeader then
            imgui.TableHeadersRow()

            -- Handle sorting clicks on headers
            for i, col in ipairs(columns) do
                if col.sortable then
                    imgui.TableSetColumnIndex(i - 1)
                    if imgui.IsItemClicked and imgui.IsItemClicked() then
                        if state.sortColumn and state.sortColumn.key == col.key then
                            state.sortAscending = not state.sortAscending
                        else
                            state.sortColumn = col
                            state.sortAscending = true
                        end
                    end
                end
            end
        end

        -- Data rows
        for rowIdx, row in ipairs(displayData) do
            imgui.TableNextRow(0, rowHeight)

            local isSelected = (state.selectedRow == rowIdx)
            local rowHovered = false

            for colIdx, col in ipairs(columns) do
                imgui.TableSetColumnIndex(colIdx - 1)

                local value = row[col.key]
                local displayValue = value

                -- Format value
                if col.format then
                    displayValue = col.format(value, row)
                elseif value == nil then
                    displayValue = ''
                else
                    displayValue = tostring(value)
                end

                -- Custom renderer
                if col.render then
                    col.render(value, row, themeName)
                else
                    -- Selectable for row selection
                    if selectable and colIdx == 1 then
                        local selectFlags = 0
                        if ImGuiSelectableFlags then
                            selectFlags = ImGuiSelectableFlags.SpanAllColumns or 0
                        end

                        if imgui.Selectable('##row' .. rowIdx, isSelected, selectFlags, 0, rowHeight) then
                            state.selectedRow = rowIdx
                            selectedRow = row
                        end
                        imgui.SameLine()
                    end

                    -- Text with color
                    local textCol = col.color and col.color(value, row) or colors.text
                    imgui.TextColored(textCol[1], textCol[2], textCol[3], 1, displayValue)
                end

                -- Check hover
                if imgui.IsItemHovered and imgui.IsItemHovered() then
                    rowHovered = true
                end
            end

            -- Row tooltip
            if rowHovered and opts.rowTooltip then
                imgui.BeginTooltip()
                opts.rowTooltip(row, themeName)
                imgui.EndTooltip()
            end
        end

        imgui.EndTable()
    end

    -- Pop colors
    if colorsPushed > 0 then
        pcall(imgui.PopStyleColor, colorsPushed)
    end

    -- Return selected row data
    if selectedRow then
        return selectedRow, state.selectedRow
    elseif state.selectedRow and displayData[state.selectedRow] then
        return displayData[state.selectedRow], state.selectedRow
    end

    return nil, nil
end

-- ============================================================
-- SIMPLE TABLE (auto-generate columns from data)
-- ============================================================

function M.simple(tableId, data, themeName, opts)
    opts = opts or {}

    if not data or #data == 0 then
        imgui.Text('No data')
        return nil
    end

    -- Auto-generate columns from first row
    local columns = {}
    local firstRow = data[1]
    for key, _ in pairs(firstRow) do
        table.insert(columns, {
            key = key,
            header = key:gsub('^%l', string.upper),  -- Capitalize first letter
            sortable = true,
        })
    end

    -- Sort columns alphabetically by key
    table.sort(columns, function(a, b) return a.key < b.key end)

    return M.draw(tableId, columns, data, themeName, opts)
end

-- ============================================================
-- COMPACT TABLE (minimal styling)
-- ============================================================

function M.compact(tableId, columns, data, themeName, opts)
    opts = opts or {}
    opts.rowHeight = opts.rowHeight or 20
    opts.borders = opts.borders == nil and false or opts.borders
    opts.striped = opts.striped == nil and true or opts.striped

    return M.draw(tableId, columns, data, themeName, opts)
end

-- ============================================================
-- STATE MANAGEMENT
-- ============================================================

function M.clearSelection(tableId)
    local state = getTableState(tableId)
    state.selectedRow = nil
end

function M.setSelection(tableId, rowIndex)
    local state = getTableState(tableId)
    state.selectedRow = rowIndex
end

function M.getSelection(tableId)
    local state = getTableState(tableId)
    return state.selectedRow
end

function M.clearSort(tableId)
    local state = getTableState(tableId)
    state.sortColumn = nil
    state.sortAscending = true
end

function M.setSort(tableId, columnKey, ascending)
    local state = getTableState(tableId)
    state.sortColumn = { key = columnKey }
    state.sortAscending = ascending ~= false
end

function M.reset(tableId)
    _tableStates[tableId] = nil
end

function M.resetAll()
    _tableStates = {}
end

return M
