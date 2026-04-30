-- ============================================================
-- SideKick Settings - Humanize Tab
-- ============================================================
-- Status, override controls, and per-subsystem toggles for the
-- behavioral humanization layer.

local imgui = require('ImGui')
local Components = require('sidekick-next.ui.components')

local M = {}

local function getH()
    local ok, H = pcall(require, 'sidekick-next.humanize')
    if ok then return H end
    return nil
end

local function badge(label, color)
    imgui.PushStyleColor(ImGuiCol.Text, color[1], color[2], color[3], color[4] or 1)
    imgui.Text(label)
    imgui.PopStyleColor()
end

local function colorForProfile(name)
    if name == 'off'       then return {0.55, 0.55, 0.55, 1} end
    if name == 'idle'      then return {0.55, 0.75, 0.95, 1} end
    if name == 'farming'   then return {0.55, 0.85, 0.55, 1} end
    if name == 'combat'    then return {0.95, 0.85, 0.45, 1} end
    if name == 'emergency' then return {1.00, 0.40, 0.30, 1} end
    if name == 'named'     then return {0.95, 0.55, 0.95, 1} end
    return {0.85, 0.85, 0.85, 1}
end

function M.draw(settings, themeNames, onChange)
    local H = getH()
    if not H then
        imgui.TextColored(1, 0.5, 0.5, 1, 'humanize module failed to load')
        return
    end

    -- Master flag
    local cfg = _G.SIDEKICK_NEXT_CONFIG or {}
    local enabled = cfg.HUMANIZE_BEHAVIOR == true

    local newEnabled, changed = imgui.Checkbox('Humanize layer enabled', enabled)
    if changed then
        cfg.HUMANIZE_BEHAVIOR = newEnabled and true or false
        _G.SIDEKICK_NEXT_CONFIG = cfg
    end

    if imgui.IsItemHovered() then
        imgui.SetTooltip(
            'Master switch for the humanization layer. When off, all gates and ' ..
            'choice perturbations are no-ops (byte-identical to baseline).'
        )
    end

    imgui.Separator()

    -- Status block
    local profile = H.activeProfile() or 'off'
    local override = H.getOverride() or 'auto'

    imgui.Text('Active profile: ')
    imgui.SameLine()
    badge(profile, colorForProfile(profile))

    imgui.Text('Override:       ')
    imgui.SameLine()
    if override == 'boss' then
        badge('BOSS (force named profile)', {0.95, 0.55, 0.95, 1})
    elseif override == 'off' then
        badge('FULL-BORE (layer bypassed)', {1.0, 0.4, 0.3, 1})
    else
        badge('auto', {0.7, 0.85, 1.0, 1})
    end

    imgui.Separator()

    -- Override buttons
    if imgui.Button('Auto') then H.setOverride(nil) end
    imgui.SameLine()
    if imgui.Button('Boss') then H.setOverride('boss') end
    imgui.SameLine()
    if imgui.Button('Full-bore (off)') then H.setOverride('off') end

    if imgui.IsItemHovered() then
        imgui.SetTooltip(
            'Auto: profile picked from world state (default).\n' ..
            'Boss: forces named profile (no decision noise, no skips).\n' ..
            'Full-bore: bypasses the layer entirely for max performance.'
        )
    end

    imgui.Separator()

    -- Per-subsystem toggles
    imgui.TextDisabled('Subsystems:')
    local subs = { 'combat', 'targeting', 'buffs', 'heals', 'engagement', 'fidget' }
    for _, name in ipairs(subs) do
        local cur = H.subsystemEnabled(name)
        local v, ch = imgui.Checkbox(name, cur)
        if ch then H.setSubsystem(name, v) end
    end

    imgui.Separator()

    -- Recent decisions (debug)
    if imgui.CollapsingHeader('Recent decisions (debug)') then
        local recent = H.dumpRecent() or {}
        if #recent == 0 then
            imgui.TextDisabled('No decisions logged. Use /sk_humanize debug on to enable.')
        else
            imgui.Text(string.format('Last %d:', #recent))
            for i = math.max(1, #recent - 19), #recent do
                local e = recent[i]
                if e then
                    local s = string.format('%s  kind=%s  prof=%s  delay=%s  urg=%s  action=%s',
                        tostring(e.at or 0), tostring(e.kind), tostring(e.profile),
                        tostring(e.delay), tostring(e.urgency), tostring(e.action))
                    imgui.TextUnformatted(s)
                end
            end
        end
        if imgui.Button('Toggle debug log') then
            -- Read state through dumpRecent presence, can't easily read flag; toggle blindly.
            local ok, State = pcall(require, 'sidekick-next.humanize.state')
            if ok and State and State.setDebug and State.debugEnabled then
                State.setDebug(not State.debugEnabled())
            end
        end
    end
end

return M
