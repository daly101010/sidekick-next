-- ============================================================
-- SideKick Checkbox Row Component
-- ============================================================
-- Label + Checkbox + tooltip pattern for settings.
--
-- Usage:
--   local CheckboxRow = require('sidekick-next.ui.components.checkbox_row')
--   local changed, newValue = CheckboxRow.draw('Enable Animations', 'AnimationsEnabled', current)

local imgui = require('ImGui')

local M = {}

-- ============================================================
-- STANDARD CHECKBOX ROW
-- ============================================================

function M.draw(label, settingKey, current, onChange, opts)
    opts = opts or {}
    local tooltip = opts.tooltip

    -- Checkbox with label
    local changed, newValue = imgui.Checkbox(label .. '##' .. settingKey, current)

    -- Tooltip
    if tooltip and imgui.IsItemHovered() then
        imgui.SetTooltip(tooltip)
    end

    -- Callback
    if changed and onChange then
        onChange(newValue)
    end

    return changed, newValue
end

-- ============================================================
-- CHECKBOX WITH DESCRIPTION (label on right)
-- ============================================================

function M.withDesc(label, description, settingKey, current, onChange, opts)
    opts = opts or {}

    -- Checkbox
    local changed, newValue = imgui.Checkbox('##' .. settingKey, current)

    imgui.SameLine()

    -- Label
    imgui.Text(label)
    if opts.tooltip and imgui.IsItemHovered() then
        imgui.SetTooltip(opts.tooltip)
    end

    -- Description on next line
    if description then
        imgui.SameLine()
        imgui.TextDisabled('- ' .. description)
    end

    -- Callback
    if changed and onChange then
        onChange(newValue)
    end

    return changed, newValue
end

-- ============================================================
-- INDENTED CHECKBOX (for sub-settings)
-- ============================================================

function M.indented(label, settingKey, current, onChange, opts)
    opts = opts or {}
    local indent = opts.indent or 20

    imgui.Indent(indent)
    local changed, newValue = M.draw(label, settingKey, current, onChange, opts)
    imgui.Unindent(indent)

    return changed, newValue
end

-- ============================================================
-- CHECKBOX GROUP (multiple related checkboxes)
-- ============================================================

function M.group(items, opts)
    opts = opts or {}
    local columns = opts.columns or 1
    local spacing = opts.spacing or 4

    local results = {}
    local anyChanged = false

    if columns > 1 then
        imgui.Columns(columns, nil, false)
    end

    for i, item in ipairs(items) do
        local changed, newValue = M.draw(
            item.label,
            item.key,
            item.value,
            item.onChange,
            { tooltip = item.tooltip }
        )
        results[item.key] = newValue
        if changed then
            anyChanged = true
        end

        if columns > 1 then
            imgui.NextColumn()
        end
    end

    if columns > 1 then
        imgui.Columns(1)
    end

    if spacing > 0 then
        imgui.Dummy(0, spacing)
    end

    return anyChanged, results
end

-- ============================================================
-- TOGGLE-STYLE CHECKBOX (styled as a toggle switch)
-- ============================================================

function M.toggle(label, settingKey, current, onChange, opts)
    opts = opts or {}
    local tooltip = opts.tooltip

    -- Style as toggle
    local onColor = { 0.3, 0.8, 0.3, 1.0 }
    local offColor = { 0.5, 0.5, 0.5, 1.0 }
    local color = current and onColor or offColor

    imgui.PushStyleColor(ImGuiCol.FrameBg, offColor[1], offColor[2], offColor[3], offColor[4])
    imgui.PushStyleColor(ImGuiCol.FrameBgHovered, offColor[1] * 1.1, offColor[2] * 1.1, offColor[3] * 1.1, offColor[4])
    imgui.PushStyleColor(ImGuiCol.CheckMark, onColor[1], onColor[2], onColor[3], onColor[4])

    local changed, newValue = imgui.Checkbox(label .. '##' .. settingKey, current)

    imgui.PopStyleColor(3)

    -- Tooltip
    if tooltip and imgui.IsItemHovered() then
        imgui.SetTooltip(tooltip)
    end

    -- Callback
    if changed and onChange then
        onChange(newValue)
    end

    return changed, newValue
end

-- ============================================================
-- DEPENDENT CHECKBOX (enabled based on parent)
-- ============================================================

function M.dependent(label, settingKey, current, parentEnabled, onChange, opts)
    opts = opts or {}

    -- Disable if parent is off
    if not parentEnabled then
        imgui.BeginDisabled()
    end

    local changed, newValue = M.draw(label, settingKey, current, onChange, opts)

    if not parentEnabled then
        imgui.EndDisabled()
    end

    return changed, newValue
end

return M
