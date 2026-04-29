-- F:/lua/sidekick-next/ui/rotation_debug.lua
-- Visibility into the current state of rotation_engine: per-layer activity
-- counts and the SpellRotation deferral signal. Reads M.lastTickStats which
-- is repopulated on every rotation_engine.tick().

local mq = require('mq')
local imgui = require('ImGui')
local lazy = require('sidekick-next.utils.lazy_require')

local M = {}

local getRotationEngine = lazy('sidekick-next.utils.rotation_engine')
local getSpellEngine    = lazy('sidekick-next.utils.spell_engine')

-- ImGui table flags fallback (matches pattern in coordinator_debug.lua)
local function tableFlags()
    if ImGuiTableFlags and bit32 and bit32.bor then
        return bit32.bor(ImGuiTableFlags.Borders, ImGuiTableFlags.RowBg, ImGuiTableFlags.Resizable)
    end
    return 0
end

-- Layer order matches rotation_engine.LAYERS priority (1..9).
local LAYER_ORDER = {
    'emergency', 'heal', 'aggro', 'defenses', 'support',
    'burn', 'combat', 'utility', 'buff',
}

local function colorForLayerStat(stat)
    if not stat or not stat.ran then
        return 0.55, 0.55, 0.55, 1.0
    end
    if (stat.executed or 0) > 0 then
        return 0.30, 1.00, 0.30, 1.0  -- green when something fired
    end
    if (stat.spellAttempts or 0) > 0 then
        return 1.00, 0.85, 0.30, 1.0  -- yellow when spell attempts hit but engine was busy
    end
    return 0.80, 0.80, 0.80, 1.0      -- white-grey when ran but nothing fired
end

--- Embeddable content for a settings tab or standalone window.
function M.drawContent()
    local Engine = getRotationEngine()
    if not Engine or not Engine.getLastTickStats then
        imgui.TextColored(0.8, 0.4, 0.4, 1.0, 'rotation_engine not loaded')
        return
    end

    local stats = Engine.getLastTickStats() or {}
    local now = os.clock()
    local age = (stats.tickAt and stats.tickAt > 0) and (now - stats.tickAt) or nil

    -- Header: tick freshness + SpellRotation deferral status
    if age then
        imgui.Text(string.format('Last tick: %.2fs ago', age))
    else
        imgui.TextColored(0.7, 0.7, 0.7, 1.0, 'No tick recorded yet')
    end

    if stats.skipReason then
        imgui.SameLine()
        imgui.TextColored(0.9, 0.6, 0.3, 1.0, '  (skipped: ' .. tostring(stats.skipReason) .. ')')
    end

    -- SpellEngine state
    local SpellEngine = getSpellEngine()
    local engineBusy = SpellEngine and SpellEngine.isBusy and SpellEngine.isBusy() or false
    imgui.Text('SpellEngine:')
    imgui.SameLine()
    if engineBusy then
        imgui.TextColored(1.0, 0.85, 0.30, 1.0, 'BUSY')
    else
        imgui.TextColored(0.30, 1.00, 0.30, 1.0, 'idle')
    end

    -- SpellRotation status
    imgui.Text('SpellRotation:')
    imgui.SameLine()
    if stats.spellRotationDeferred then
        imgui.TextColored(1.0, 0.6, 0.3, 1.0, 'DEFERRED (high-priority layer pending)')
    elseif stats.spellRotationRan then
        imgui.TextColored(0.30, 1.00, 0.30, 1.0, 'ran')
    else
        imgui.TextColored(0.7, 0.7, 0.7, 1.0, 'not run')
    end

    if stats.highPriPendingSpell then
        imgui.TextColored(1.0, 0.85, 0.30, 1.0,
            'A high-priority layer had pending spell work this tick.')
    end

    imgui.Spacing()
    imgui.Separator()
    imgui.Spacing()

    -- Per-layer breakdown
    imgui.TextColored(0.7, 0.85, 1.0, 1.0, 'Layers (priority order):')

    if imgui.BeginTable('##rotation_layers', 5, tableFlags()) then
        imgui.TableSetupColumn('Layer',     ImGuiTableColumnFlags.WidthStretch)
        imgui.TableSetupColumn('Abilities', ImGuiTableColumnFlags.WidthFixed, 80)
        imgui.TableSetupColumn('Executed',  ImGuiTableColumnFlags.WidthFixed, 80)
        imgui.TableSetupColumn('Spell tries', ImGuiTableColumnFlags.WidthFixed, 90)
        imgui.TableSetupColumn('Status',    ImGuiTableColumnFlags.WidthFixed, 110)
        imgui.TableHeadersRow()

        for _, name in ipairs(LAYER_ORDER) do
            local stat = stats.layers and stats.layers[name] or nil
            imgui.TableNextRow()
            imgui.TableNextColumn()
            local r, g, b, a = colorForLayerStat(stat)
            imgui.TextColored(r, g, b, a, name)

            imgui.TableNextColumn()
            imgui.Text(tostring((stat and stat.abilities) or 0))

            imgui.TableNextColumn()
            imgui.Text(tostring((stat and stat.executed) or 0))

            imgui.TableNextColumn()
            imgui.Text(tostring((stat and stat.spellAttempts) or 0))

            imgui.TableNextColumn()
            if not stat then
                imgui.TextColored(0.6, 0.6, 0.6, 1.0, '—')
            elseif stat.ran then
                imgui.TextColored(0.30, 1.00, 0.30, 1.0, 'ran')
            elseif stat.skipReason then
                imgui.TextColored(0.9, 0.6, 0.3, 1.0, stat.skipReason)
            else
                imgui.Text('—')
            end
        end

        imgui.EndTable()
    end

    imgui.Spacing()
    imgui.Separator()
    imgui.Spacing()
    imgui.TextColored(0.7, 0.7, 0.7, 1.0,
        'Green=executed; Yellow=spell tries blocked by busy engine; Grey=ran but nothing fired.')
end

--- Standalone window wrapper (matches actors_debug pattern).
M.open = false
function M.draw()
    if not M.open then return end
    local open, visible = imgui.Begin('SideKick: Rotation Debug', M.open, ImGuiWindowFlags.AlwaysAutoResize)
    M.open = open
    if visible then
        M.drawContent()
    end
    imgui.End()
end

return M
