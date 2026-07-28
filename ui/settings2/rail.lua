-- ============================================================
-- SideKick Settings Redesign - Chapter Rail
-- ============================================================
-- Left column that replaces the tab bar. Each row = one chapter,
-- with a glyph, name, and a live-state pill that turns the rail
-- into a mini dashboard.
--
-- Rendering uses the ImGui Selectable path (unstyled) plus a
-- manual DrawList background so hover/selected states can use the
-- palette instead of ImGui defaults.

local imgui = require('ImGui')
local P = require('sidekick-next.ui.settings2.palette')
local Atoms = require('sidekick-next.ui.settings2.atoms')
local Motion = require('sidekick-next.ui.settings2.motion')
local Draw = require('sidekick-next.ui.draw_helpers')

local M = {}

M.WIDTH = 190

-- ------------------------------------------------------------
-- Chapter definitions
-- ------------------------------------------------------------
-- Ordered top-to-bottom. `pinnedBottom = true` gets separated by a
-- hairline and pushed to the bottom of the rail.
M.CHAPTERS = {
    { id = 'combat',      name = 'Combat',    glyph = 'X' },
    { id = 'support',     name = 'Support',   glyph = '+' },
    { id = 'presence',    name = 'Presence',  glyph = '~' },
    { id = 'interface',   name = 'Interface', glyph = '#' },
    { id = 'extras',      name = 'Extras',    glyph = '>' },
    { id = 'diagnostics', name = 'Diagnostics', glyph = '?', pinnedBottom = true },
}

-- ------------------------------------------------------------
-- Live status resolution
-- ------------------------------------------------------------
-- Returns text, variant ('off'|'live'|'hot'|'cool'), isBreathing.

local function getHumanizeProfile()
    local ok, H = pcall(require, 'sidekick-next.humanize')
    if not ok or not H then return nil end
    local okp, p = pcall(H.activeProfile)
    if not okp then return nil end
    return p
end

local function chapterStatus(chapterId, settings)
    settings = settings or {}

    if chapterId == 'combat' then
        local mode = tostring(settings.CombatMode or 'off')
        if mode == 'off' then
            return 'off', 'off', false
        end
        local burnOn = settings.BurnActive == true
        if burnOn then
            return 'BURN', 'hot', true
        end
        -- 'assist' or 'tank' -> live pill in accent, breathing
        return mode, 'live', true

    elseif chapterId == 'support' then
        -- Show what's on. Buffs + heals + rez pieces are class-conditional
        -- so the pill is meta ("armed") rather than granular.
        local heals = settings.HealingEnabled == true
        local buffs = settings.BuffsEnabled ~= false
        local rez = settings.AutoAcceptRez == true or (tostring(settings.AutoRezMode or 'off') ~= 'off')
        local n = (heals and 1 or 0) + (buffs and 1 or 0) + (rez and 1 or 0)
        if n == 0 then return 'off', 'off', false end
        return tostring(n) .. ' on', 'live', false

    elseif chapterId == 'presence' then
        local cfg = _G.SIDEKICK_NEXT_CONFIG or {}
        if cfg.HUMANIZE_BEHAVIOR ~= true then
            return 'off', 'off', false
        end
        local prof = getHumanizeProfile() or 'auto'
        local variant = 'live'
        local breathe = false
        if prof == 'combat' or prof == 'emergency' or prof == 'named' then
            variant = 'hot'; breathe = true
        elseif prof == 'idle' or prof == 'farming' then
            variant = 'cool'
        end
        return prof, variant, breathe

    elseif chapterId == 'interface' then
        return nil, nil, false  -- no state pill

    elseif chapterId == 'extras' then
        local chaseOn = settings.ChaseEnabled == true
        local pullOn = settings.PullEnabled == true
        if chaseOn and pullOn then return 'CHASE·PULL', 'live', true end
        if chaseOn then return 'chase', 'live', true end
        if pullOn then return 'pull', 'live', true end
        return 'off', 'off', false

    elseif chapterId == 'diagnostics' then
        return nil, nil, false
    end
    return nil, nil, false
end

-- ------------------------------------------------------------
-- Draw one rail row.
-- ------------------------------------------------------------

local function drawRow(chapter, isSelected, settings)
    local w = M.WIDTH - 8
    local h = 32
    local x, y = imgui.GetCursorScreenPos()
    local dl = imgui.GetWindowDrawList()

    -- Hover detection: use an invisible button for hit-testing.
    imgui.PushID('rail_' .. chapter.id)
    local clicked = imgui.InvisibleButton('##hit', w, h)
    local hovered = imgui.IsItemHovered()
    imgui.PopID()

    -- Background
    if isSelected then
        Draw.addRectFilled(dl, x, y, x + w, y + h, P.col32(P.plate, 1.0), 4.0)
        -- Accent bar on the left edge
        Draw.addRectFilled(dl, x, y + 4, x + 3, y + h - 4, P.col32(P.accent, 1.0), 1.5)
    elseif hovered then
        Draw.addRectFilled(dl, x, y, x + w, y + h, P.col32(P.plate, 0.5), 4.0)
    end

    -- Glyph + name
    local textColor = isSelected and P.ink or (hovered and P.ink or P.dim)
    local glyphColor = isSelected and P.accent or P.dim

    imgui.SetCursorScreenPos(x + 10, y + 8)
    imgui.PushStyleColor(ImGuiCol.Text, P.rgba(glyphColor))
    imgui.Text(chapter.glyph)
    imgui.PopStyleColor()

    imgui.SetCursorScreenPos(x + 28, y + 8)
    imgui.PushStyleColor(ImGuiCol.Text, P.rgba(textColor))
    imgui.Text(chapter.name)
    imgui.PopStyleColor()

    -- Live status pill (right-aligned)
    local pillText, variant, breathing = chapterStatus(chapter.id, settings)
    if pillText and pillText ~= '' then
        local alpha = 1.0
        if breathing then
            alpha = Motion.pillBreathe(chapter.id)
        end
        -- togglePop observe for high-impact toggles
        if chapter.id == 'combat' then
            Motion.observeToggle('combat', tostring(settings.CombatMode or 'off') ~= 'off' or settings.BurnActive == true)
        elseif chapter.id == 'extras' then
            Motion.observeToggle('extras', settings.ChaseEnabled == true or settings.PullEnabled == true)
        end
        -- Estimate pill width (best-effort: text width + padding + margin)
        local tw = imgui.CalcTextSize(pillText:upper())
        local pillW = tw + 12
        local scale = 1.0
        if chapter.id == 'combat' then scale = Motion.popScale('combat')
        elseif chapter.id == 'extras' then scale = Motion.popScale('extras') end
        imgui.SetCursorScreenPos(x + w - pillW - 6, y + (h - 16) * 0.5)
        -- Emulate pop by inflating alpha and drawing a subtle outer glow when scale > 1
        Atoms.pill(pillText, variant, alpha)
        if scale > 1.001 then
            -- Outer glow on pop (single-frame, cheap)
            local gx, gy = x + w - pillW - 6, y + (h - 16) * 0.5
            local pad = (scale - 1.0) * 12
            local glowAlpha = math.min(0.35, (scale - 1.0) * 2.5)
            local glowColor = variant == 'hot' and P.hot or P.accent
            Draw.addRect(dl, gx - pad, gy - pad, gx + pillW + pad, gy + 16 + pad,
                P.col32(glowColor, glowAlpha), 5.0, 0, 1.5)
        end
    end

    -- Advance cursor past the row for next iteration
    imgui.SetCursorScreenPos(x, y + h + 2)

    return clicked
end

-- ------------------------------------------------------------
-- Draw the rail. Returns the (possibly updated) selectedId.
-- ------------------------------------------------------------

function M.draw(selectedId, settings)
    Atoms.pushPanelBg()
    imgui.BeginChild('##sk2_rail', M.WIDTH, 0, true)
    Atoms.popPanelBg()

    -- Body wrapped in pcall - if we throw, EndChild still runs so the parent
    -- window's End() doesn't detect a missing EndChild and crash the overlay.
    local ok, err = pcall(function()
        imgui.Dummy(0, 4)
        imgui.PushStyleColor(ImGuiCol.Text, P.rgba(P.accent))
        imgui.SetCursorPosX(12)
        imgui.Text('SIDEKICK')
        imgui.PopStyleColor()
        imgui.PushStyleColor(ImGuiCol.Text, P.rgba(P.dim))
        imgui.SetCursorPosX(12)
        imgui.Text('control panel')
        imgui.PopStyleColor()
        imgui.Dummy(0, 8)
        Atoms.hairline(0.6)

        for _, chapter in ipairs(M.CHAPTERS) do
            if not chapter.pinnedBottom then
                if drawRow(chapter, chapter.id == selectedId, settings) then
                    if selectedId ~= chapter.id then
                        selectedId = chapter.id
                        Motion.markChapterSwitched()
                    end
                end
            end
        end

        local _, remainingY = imgui.GetContentRegionAvail()
        local pinnedCount = 0
        for _, c in ipairs(M.CHAPTERS) do if c.pinnedBottom then pinnedCount = pinnedCount + 1 end end
        local pushDown = math.max(0, (tonumber(remainingY) or 0) - (pinnedCount * 34) - 12)
        if pushDown > 0 then imgui.Dummy(0, pushDown) end
        Atoms.hairline(0.4)

        for _, chapter in ipairs(M.CHAPTERS) do
            if chapter.pinnedBottom then
                if drawRow(chapter, chapter.id == selectedId, settings) then
                    if selectedId ~= chapter.id then
                        selectedId = chapter.id
                        Motion.markChapterSwitched()
                    end
                end
            end
        end
    end)
    if not ok then
        imgui.TextColored(1, 0.3, 0.3, 1, 'Rail error:')
        imgui.TextWrapped(tostring(err))
    end

    imgui.EndChild()

    return selectedId
end

return M
