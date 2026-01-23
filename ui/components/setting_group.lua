-- ============================================================
-- SideKick Setting Group Component
-- ============================================================
-- Collapsible section with label and indent for settings organization.
--
-- Usage:
--   local SettingGroup = require('sidekick-next.ui.components.setting_group')
--   SettingGroup.draw('Combat Settings', function()
--       -- Settings widgets go here
--   end, { id = 'combat', defaultOpen = true })

local imgui = require('ImGui')

local M = {}

-- Track open/closed state for groups
local _groupStates = {}

-- ============================================================
-- COLLAPSIBLE SETTING GROUP
-- ============================================================

function M.draw(label, drawFn, opts)
    opts = opts or {}
    local id = opts.id or label
    local indent = opts.indent or 10
    local defaultOpen = opts.defaultOpen ~= false  -- Default to open

    -- Initialize state if needed
    if _groupStates[id] == nil then
        _groupStates[id] = defaultOpen
    end

    -- Draw collapsing header
    local flags = 0
    if _groupStates[id] then
        flags = ImGuiTreeNodeFlags and ImGuiTreeNodeFlags.DefaultOpen or 0
    end

    local isOpen = imgui.CollapsingHeader(label, flags)
    _groupStates[id] = isOpen

    if isOpen and drawFn then
        -- Indent content
        if indent > 0 then
            imgui.Indent(indent)
        end

        -- Draw content
        local ok, err = pcall(drawFn)

        -- Unindent
        if indent > 0 then
            imgui.Unindent(indent)
        end

        if not ok then
            imgui.TextColored(1, 0.3, 0.3, 1, 'Error: ' .. tostring(err))
        end

        -- Add spacing after group
        imgui.Spacing()
    end

    return isOpen
end

-- ============================================================
-- SIMPLE SECTION WITH SEPARATOR
-- ============================================================

function M.section(label, drawFnOrTheme, opts)
    -- Handle flexible argument patterns:
    -- section(label) - just header
    -- section(label, themeName) - header with theme (ignored, for consistency)
    -- section(label, drawFn) - header with callback
    -- section(label, drawFn, opts) - full form

    local drawFn = nil
    if type(drawFnOrTheme) == 'function' then
        drawFn = drawFnOrTheme
    elseif type(drawFnOrTheme) == 'table' then
        opts = drawFnOrTheme
    end
    -- If drawFnOrTheme is a string (theme name), we just ignore it

    opts = opts or {}
    local indent = opts.indent or 0

    -- Section header
    imgui.Separator()
    imgui.Text(label)
    imgui.Separator()

    -- Indent content
    if indent > 0 then
        imgui.Indent(indent)
    end

    -- Draw content (only if actually a function)
    if drawFn and type(drawFn) == 'function' then
        local ok, err = pcall(drawFn)
        if not ok then
            imgui.TextColored(1, 0.3, 0.3, 1, 'Error: ' .. tostring(err))
        end
    end

    -- Unindent
    if indent > 0 then
        imgui.Unindent(indent)
    end

    imgui.Spacing()
end

-- ============================================================
-- INLINE GROUP (no collapsing, just visual grouping)
-- ============================================================

function M.inline(label, drawFn, opts)
    opts = opts or {}
    local spacing = opts.spacing or 4

    if label and label ~= '' then
        imgui.TextDisabled(label)
    end

    if drawFn then
        local ok, err = pcall(drawFn)
        if not ok then
            imgui.TextColored(1, 0.3, 0.3, 1, 'Error: ' .. tostring(err))
        end
    end

    if spacing > 0 then
        imgui.Dummy(0, spacing)
    end
end

-- ============================================================
-- TREE NODE GROUP (for hierarchical settings)
-- ============================================================

function M.tree(label, drawFn, opts)
    opts = opts or {}
    local id = opts.id or label
    local flags = opts.flags or 0

    if imgui.TreeNode(label .. '##' .. id) then
        if drawFn then
            local ok, err = pcall(drawFn)
            if not ok then
                imgui.TextColored(1, 0.3, 0.3, 1, 'Error: ' .. tostring(err))
            end
        end
        imgui.TreePop()
        return true
    end
    return false
end

-- ============================================================
-- STATE MANAGEMENT
-- ============================================================

function M.isOpen(id)
    return _groupStates[id] == true
end

function M.setOpen(id, open)
    _groupStates[id] = open
end

function M.toggleOpen(id)
    _groupStates[id] = not _groupStates[id]
end

function M.resetAll()
    _groupStates = {}
end

return M
