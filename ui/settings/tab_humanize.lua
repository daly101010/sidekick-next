-- ============================================================
-- SideKick Settings - Humanize Tab
-- ============================================================
-- Status, override controls, per-subsystem toggles, and live tunables
-- for the behavioral humanization layer.

local imgui = require('ImGui')

local M = {}

local function getH()
    local ok, H = pcall(require, 'sidekick-next.humanize')
    if ok then return H end
    return nil
end

local function getFidget()
    local ok, F = pcall(require, 'sidekick-next.humanize.fidget')
    if ok then return F end
    return nil
end

local function getEngagement()
    local ok, E = pcall(require, 'sidekick-next.humanize.engagement')
    if ok then return E end
    return nil
end

local function getChase()
    local ok, C = pcall(require, 'sidekick-next.automation.chase')
    if ok then return C end
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

-- Ordered key lists so iteration is stable in the UI (pairs() order isn't).
local FIDGET_ACTIONS    = { 'turn', 'jump', 'strafe', 'window', 'pitch', 'face_spawn', 'med_cycle' }
local FIDGET_KEYBINDS   = { 'turn_left', 'turn_right', 'jump', 'strafe_left', 'strafe_right', 'look_up', 'look_down' }
local WINDOW_KEY_NAMES  = { 'inventory', 'character', 'map', 'group' }
local SUBSYSTEMS        = { 'combat', 'targeting', 'buffs', 'heals', 'engagement', 'fidget' }

function M.draw(settings, themeNames, onChange)
    local H = getH()
    if not H then
        imgui.TextColored(1, 0.5, 0.5, 1, 'humanize module failed to load')
        return
    end

    -- Master flag ---------------------------------------------------------
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

    -- Status block --------------------------------------------------------
    local profile = H.activeProfile() or 'off'
    local override = H.getOverride() or 'auto'

    imgui.Text('Active profile:')
    imgui.SameLine()
    badge(profile, colorForProfile(profile))

    imgui.Text('Override:      ')
    imgui.SameLine()
    if override == 'boss' then
        badge('BOSS (force named profile)', {0.95, 0.55, 0.95, 1})
    elseif override == 'off' then
        badge('FULL-BORE (layer bypassed)', {1.0, 0.4, 0.3, 1})
    else
        badge('auto', {0.7, 0.85, 1.0, 1})
    end

    if imgui.Button('Auto') then H.setOverride(nil) end
    imgui.SameLine()
    if imgui.Button('Boss') then H.setOverride('boss') end
    imgui.SameLine()
    if imgui.Button('Full-bore (off)') then H.setOverride('off') end

    imgui.Separator()

    -- Subsystem toggles ---------------------------------------------------
    imgui.TextDisabled('Subsystems:')
    for _, name in ipairs(SUBSYSTEMS) do
        local cur = H.subsystemEnabled(name)
        local v, ch = imgui.Checkbox(name .. '##sub_' .. name, cur)
        if ch then H.setSubsystem(name, v) end
        if name ~= SUBSYSTEMS[#SUBSYSTEMS] then imgui.SameLine() end
    end

    imgui.Separator()

    -- Fidget tuning -------------------------------------------------------
    if imgui.CollapsingHeader('Fidget tuning') then
        local F = getFidget()
        if not F then
            imgui.TextDisabled('fidget module not loaded')
        else
            local Cfg = F.getConfig()

            -- Min interval
            local mi = Cfg.minIntervalMs or 8000
            local newMi, miCh = imgui.SliderInt('Min interval (ms)##fidget_min', mi, 1000, 60000)
            if miCh then F.setMinIntervalMs(newMi) end
            if imgui.IsItemHovered() then
                imgui.SetTooltip('Minimum gap between fidgets. Default 8000.')
            end

            -- Per-second probability
            local fps = Cfg.fidgetPerSec or 1.0
            local newFps, fpsCh = imgui.SliderFloat('Avg per second##fidget_persec', fps, 0.05, 5.0, '%.2f')
            if fpsCh then F.setFidgetPerSec(newFps) end
            if imgui.IsItemHovered() then
                imgui.SetTooltip('Average fidget attempts per idle second. Default 1.0.')
            end

            imgui.Separator()
            imgui.TextDisabled('Action weights (sum > 0; remainder = no-op tick)')
            for _, action in ipairs(FIDGET_ACTIONS) do
                local cur = (Cfg.weights and Cfg.weights[action]) or 0
                local newW, ch = imgui.SliderFloat(action .. '##w_' .. action, cur, 0.0, 1.0, '%.2f')
                if ch then F.setWeight(action, newW) end
            end

            imgui.Separator()
            imgui.TextDisabled('Keybinds (raw key names for /keypress)')
            local kbs = F.getKeybinds()
            for _, name in ipairs(FIDGET_KEYBINDS) do
                local cur = kbs[name] or ''
                local newV, ch = imgui.InputText(name .. '##kb_' .. name, cur, 32)
                if ch then F.setKeybind(name, newV) end
            end

            imgui.Separator()
            imgui.TextDisabled('Window peek hotkeys (toggle keys)')
            local wks = F.getWindowKeys()
            for _, name in ipairs(WINDOW_KEY_NAMES) do
                local cur = wks[name] or ''
                local newV, ch = imgui.InputText(name .. '##wk_' .. name, cur, 16)
                if ch then F.setWindowKey(name, newV) end
            end
        end
    end

    -- Engagement tuning ---------------------------------------------------
    if imgui.CollapsingHeader('Engagement (stick + engage threshold)') then
        local E = getEngagement()
        if not E then
            imgui.TextDisabled('engagement module not loaded')
        else
            local T = E.getTunables()
            local minPct = T.engageMinPct or 88
            local newMin, ch = imgui.SliderInt('Engage HP% floor##eng_min', minPct, 50, 100)
            if ch then E.setEngageMinPct(newMin) end
            if imgui.IsItemHovered() then
                imgui.SetTooltip(
                    'Lowest mob HP% non-tank DPS will hold for before engaging. Default 88.\n' ..
                    'emergency/named profiles clamp to 95.'
                )
            end

            local restick = T.restickAfterMs or 60000
            local newRs, rsCh = imgui.SliderInt('Re-stick after (ms)##eng_restick', restick, 5000, 600000)
            if rsCh then E.setRestickAfterMs(newRs) end
            if imgui.IsItemHovered() then
                imgui.SetTooltip('How long an engagement runs before a re-stick is considered. Default 60000 (1 min).')
            end
        end
    end

    -- Chase tuning --------------------------------------------------------
    if imgui.CollapsingHeader('Chase distance jitter') then
        local C = getChase()
        if not C or not C.getChaseJitterPct then
            imgui.TextDisabled('chase module not loaded')
        else
            local cur = C.getChaseJitterPct() or 0.20
            local pct = math.floor(cur * 100 + 0.5)
            local newPct, ch = imgui.SliderInt('±jitter %##chase_jit', pct, 0, 50)
            if ch then C.setChaseJitterPct(newPct / 100.0) end
            if imgui.IsItemHovered() then
                imgui.SetTooltip(
                    'Per-episode jitter on the chase trigger distance.\n' ..
                    'At base=30 with 20%, you catch up between ~24 and ~36 across pulls.'
                )
            end
        end
    end

    -- Profile snapshot ----------------------------------------------------
    if imgui.CollapsingHeader('Active profile snapshot') then
        local ok, Profiles = pcall(require, 'sidekick-next.humanize.profiles')
        local p = ok and Profiles.get and Profiles.get(profile)
        if not p then
            imgui.TextDisabled('profile not found')
        else
            local function fmtDist(d)
                if not d then return '(none)' end
                return string.format('median=%d sigma=%.2f min=%d max=%d',
                    d.median_ms or 0, d.sigma or 0, d.min or 0, d.max or 0)
            end
            imgui.Text('reaction:    ' .. fmtDist(p.reaction))
            imgui.Text('precast:     ' .. fmtDist(p.precast))
            imgui.Text('target_lock: ' .. fmtDist(p.target_lock))
            imgui.Text(string.format('buff jitter: %.2f', p.buff_refresh_pct_jitter or 0))
            local n = p.noise or {}
            imgui.Text(string.format('noise: 2nd_best=%.0f%%  skip=%.0f%%  retarget=%.0f%%  double=%.1f%%',
                (n.second_best_p or 0)*100, (n.skip_global_p or 0)*100,
                (n.retarget_hesit or 0)*100, (n.double_press_p or 0)*100))
            imgui.TextDisabled('Edit humanize/profiles.lua to change distributions.')
        end
    end

    -- Recent decisions ----------------------------------------------------
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
            local ok, State = pcall(require, 'sidekick-next.humanize.state')
            if ok and State and State.setDebug and State.debugEnabled then
                State.setDebug(not State.debugEnabled())
            end
        end
    end
end

return M
