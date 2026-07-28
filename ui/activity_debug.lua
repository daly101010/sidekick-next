-- F:/lua/sidekick-next/ui/activity_debug.lua
-- Activity tab: live per-module action counters for verifying the automation
-- is actually doing things (heals cast, heals ducked, taunts landed, weapon
-- swaps, sits blocked by aggro, ...). Data arrives via each worker's
-- heartbeat -> coordinator moduleDiag -> UI state broadcast; this tab only
-- reads what already flows.

local imgui = require('ImGui')
local lazy = require('sidekick-next.utils.lazy_require')

local getCoordDebug = lazy('sidekick-next.ui.coordinator_debug')

local M = {}

-- Reset is local-display only: workers keep counting from session start; the
-- baseline snapshot subtracts what happened before the user clicked Reset.
local _baseline = {}      -- [module][counter] = count at reset time
local _resetAtLabel = nil

-- Friendlier labels for the well-known counters; unknown keys show verbatim.
local LABELS = {
    ['done:cast_spell'] = 'Spells cast',
    ['done:use_aa'] = 'AAs used',
    ['done:use_disc'] = 'Discs used',
    ['done:use_item'] = 'Items used',
    ['done:use_skill'] = 'Skills used',
    ['done:tank_engage'] = 'Engages',
    ['failed'] = 'Actions failed',
    ['heal_ducked'] = 'Heals ducked',
    ['taunt_landed'] = 'Taunts landed',
    ['taunt_missed'] = 'Taunts missed',
    ['taunt_unverified'] = 'Taunts (unverified)',
    ['aggro_stand'] = 'Aggro stands',
    ['sit'] = 'Sits',
    ['weapon_swap'] = 'Weapon swaps',
    ['mez_cast'] = 'Mezzes cast',
    ['mez_pretaunt'] = 'Mez pre-taunts',
    ['reposition_step'] = 'Drag steps',
    ['charm_acquire'] = 'Charms cast',
    ['charm_pretash'] = 'Pre-charm tashes',
    ['charm_break_tash'] = 'Break: tash',
    ['charm_break_stun'] = 'Break: AE stun',
    ['charm_break_charm'] = 'Break: recharm',
}

local function labelFor(key)
    local component, reason = tostring(key or ''):match('^failed:([^:]+):(.+)$')
    if component and reason then
        return string.format('%s failures (%s)', component,
            reason:gsub('_', ' '))
    end
    return LABELS[key] or key
end

local function sortedKeys(t)
    local keys = {}
    for k in pairs(t) do keys[#keys + 1] = k end
    table.sort(keys)
    return keys
end

function M.drawContent()
    local CoordDebug = getCoordDebug()
    local state = CoordDebug and CoordDebug.getLastState and CoordDebug.getLastState() or nil
    local moduleDiag = state and state.moduleDiag or nil

    imgui.TextWrapped('Action counters since worker start. Verifies the automation is doing what it claims: heals cast and ducked, taunts landed, weapon swaps, aggro stands...')
    imgui.Spacing()

    if imgui.Button('Reset Counters') then
        _baseline = {}
        if moduleDiag then
            for moduleName, diag in pairs(moduleDiag) do
                if type(diag.counters) == 'table' then
                    local base = {}
                    for k, v in pairs(diag.counters) do base[k] = tonumber(v) or 0 end
                    _baseline[moduleName] = base
                end
            end
        end
        _resetAtLabel = 'baseline set'
    end
    if _resetAtLabel then
        imgui.SameLine()
        imgui.TextColored(0.6, 0.6, 0.6, 1.0, '(' .. _resetAtLabel .. ')')
    end
    imgui.Separator()

    if not moduleDiag then
        imgui.TextColored(1.0, 0.6, 0.3, 1.0, 'No coordinator state received yet.')
        return
    end

    local anyCounters = false
    for _, moduleName in ipairs(sortedKeys(moduleDiag)) do
        local diag = moduleDiag[moduleName]
        local counters = type(diag) == 'table' and type(diag.counters) == 'table'
            and diag.counters or nil
        if counters then
            local base = _baseline[moduleName] or {}
            local rows = {}
            local hasFailureDetail = false
            for key in pairs(counters) do
                if tostring(key):match('^failed:[^:]+:.+$') then
                    hasFailureDetail = true
                    break
                end
            end
            for _, key in ipairs(sortedKeys(counters)) do
                local value = (tonumber(counters[key]) or 0) - (tonumber(base[key]) or 0)
                if value > 0 and not (key == 'failed' and hasFailureDetail) then
                    rows[#rows + 1] = string.format('%s: %d', labelFor(key), value)
                end
            end
            if #rows > 0 then
                anyCounters = true
                imgui.TextColored(0.4, 0.8, 1.0, 1.0, moduleName)
                imgui.SameLine(130)
                imgui.TextWrapped(table.concat(rows, '   '))
                imgui.Spacing()
            end
        end
    end

    if not anyCounters then
        imgui.TextColored(0.6, 0.6, 0.6, 1.0,
            'No actions counted yet (or all workers idle since reset).')
    end
end

return M
