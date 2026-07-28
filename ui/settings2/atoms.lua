-- ============================================================
-- SideKick Settings Redesign - Atoms
-- ============================================================
-- Small drawing primitives that speak the new visual language.
-- Nothing here is stateful; state lives in rail.lua and motion.lua.
--
-- DrawList calls go through sidekick-next.ui.draw_helpers, which
-- probes ImVec2 vs raw-coord binding at startup - critical: on some
-- MQ builds raw ImVec2 constructors CRASH ImGui at End() time
-- (see group/DRAWLIST_NOTES.md), not just throw a Lua error.

local imgui = require('ImGui')
local P = require('sidekick-next.ui.settings2.palette')
local Draw = require('sidekick-next.ui.draw_helpers')

local M = {}

-- ------------------------------------------------------------
-- Text primitives
-- ------------------------------------------------------------

--- Section title: small-caps, letterspaced (spaces between chars).
function M.title(text)
    if not text or text == '' then return end
    imgui.PushStyleColor(ImGuiCol.Text, P.rgba(P.ink))
    local upper = text:upper()
    local spaced = upper:gsub('.', '%0 '):gsub(' $', '')
    imgui.Text(spaced)
    imgui.PopStyleColor()
end

--- Chapter title with a bronze underscore rule.
function M.chapterHeader(text)
    M.title(text)
    local dl = imgui.GetWindowDrawList()
    local x, y = imgui.GetCursorScreenPos()
    local w = imgui.GetContentRegionAvail()
    Draw.addLine(dl, x, y + 1, x + w, y + 1, P.col32(P.rule, 1.0), 1.0)
    imgui.Dummy(0, 6)
end

--- Sub-section label inside a chapter: small-caps, dim color, hairline under.
function M.sectionLabel(text)
    imgui.Dummy(0, 4)
    imgui.PushStyleColor(ImGuiCol.Text, P.rgba(P.dim))
    local upper = text:upper()
    local spaced = upper:gsub('.', '%0 '):gsub(' $', '')
    imgui.Text(spaced)
    imgui.PopStyleColor()
    local dl = imgui.GetWindowDrawList()
    local x, y = imgui.GetCursorScreenPos()
    local w = imgui.GetContentRegionAvail()
    Draw.addRectFilled(dl, x, y, x + w, y + 1, P.col32(P.rule, 0.6))
    imgui.Dummy(0, 4)
end

--- Dimmed hint text.
function M.hint(text)
    if not text or text == '' then return end
    imgui.PushStyleColor(ImGuiCol.Text, P.rgba(P.dim))
    imgui.TextWrapped(text)
    imgui.PopStyleColor()
end

--- 1px bronze hairline spanning content width.
function M.hairline(alpha)
    local dl = imgui.GetWindowDrawList()
    local x, y = imgui.GetCursorScreenPos()
    local w = imgui.GetContentRegionAvail()
    Draw.addRectFilled(dl, x, y, x + w, y + 1, P.col32(P.rule, alpha or 0.5))
    imgui.Dummy(0, 2)
end

-- ------------------------------------------------------------
-- Pills / badges
-- ------------------------------------------------------------

--- Render a status pill in-line.
--   'off'  - outlined only, dim text
--   'live' - accent fill, bg text
--   'hot'  - vermilion fill, ink text
--   'cool' - verdigris fill, ink text
function M.pill(text, variant, alpha)
    text = tostring(text or '')
    if text == '' then return end
    local fillColor, textColor
    if variant == 'hot' then
        fillColor, textColor = P.hot, P.ink
    elseif variant == 'cool' then
        fillColor, textColor = P.cool, P.ink
    elseif variant == 'live' then
        fillColor, textColor = P.accent, P.bg
    else
        fillColor, textColor = nil, P.dim
    end

    local dl = imgui.GetWindowDrawList()
    local x, y = imgui.GetCursorScreenPos()
    local pad_x, pad_y = 6, 2
    local sz_x, sz_y = imgui.CalcTextSize(text:upper())
    local w = sz_x + pad_x * 2
    local h = sz_y + pad_y * 2

    if fillColor then
        Draw.addRectFilled(dl, x, y, x + w, y + h, P.col32(fillColor, alpha or 1.0), 3.0)
    else
        Draw.addRect(dl, x, y, x + w, y + h, P.col32(P.rule, alpha or 0.6), 3.0)
    end

    imgui.SetCursorScreenPos(x + pad_x, y + pad_y)
    imgui.PushStyleColor(ImGuiCol.Text, P.rgba(textColor, alpha or 1.0))
    imgui.Text(text:upper())
    imgui.PopStyleColor()

    imgui.SetCursorScreenPos(x + w + 4, y + h)
end

--- Glyph icon (single character).
function M.glyph(ch, tint, alpha)
    tint = tint or P.dim
    imgui.PushStyleColor(ImGuiCol.Text, P.rgba(tint, alpha or 1.0))
    imgui.Text(ch)
    imgui.PopStyleColor()
end

-- ------------------------------------------------------------
-- Panel backgrounds (style push helpers)
-- ------------------------------------------------------------

function M.pushPanelBg()
    imgui.PushStyleColor(ImGuiCol.ChildBg, P.rgba(P.panel, 1.0))
    imgui.PushStyleColor(ImGuiCol.Border, P.rgba(P.rule, 1.0))
end

function M.popPanelBg()
    imgui.PopStyleColor(2)
end

function M.pushInkText()
    imgui.PushStyleColor(ImGuiCol.Text, P.rgba(P.ink))
end

function M.popInkText()
    imgui.PopStyleColor()
end

return M
