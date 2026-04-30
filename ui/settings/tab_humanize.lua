-- ============================================================
-- SideKick Settings - Humanize Tab
-- ============================================================
-- Status, override controls, per-subsystem toggles, and live tunables
-- for the behavioral humanization layer. All knob changes route through
-- humanize/persistence.lua so they survive script restart.

local imgui = require('ImGui')

local M = {}

local function getH()
    local ok, H = pcall(require, 'sidekick-next.humanize'); return ok and H or nil
end
local function getFidget()
    local ok, F = pcall(require, 'sidekick-next.humanize.fidget'); return ok and F or nil
end
local function getEngagement()
    local ok, E = pcall(require, 'sidekick-next.humanize.engagement'); return ok and E or nil
end
local function getChase()
    local ok, C = pcall(require, 'sidekick-next.automation.chase'); return ok and C or nil
end
local function getProfiles()
    local ok, P = pcall(require, 'sidekick-next.humanize.profiles'); return ok and P or nil
end
local function getPersistence()
    local ok, P = pcall(require, 'sidekick-next.humanize.persistence'); return ok and P or nil
end

local function persist(kind, args, value)
    local P = getPersistence()
    if P and P.persist then P.persist(kind, args, value) end
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

local FIDGET_ACTIONS    = { 'turn', 'jump', 'strafe', 'window', 'pitch', 'med_cycle' }
local FIDGET_KEYBINDS   = { 'turn_left', 'turn_right', 'jump', 'strafe_left', 'strafe_right', 'look_up', 'look_down' }
local WINDOW_KEY_NAMES  = { 'inventory', 'character', 'map', 'group' }
local SUBSYSTEMS        = { 'combat', 'targeting', 'buffs', 'heals', 'engagement', 'fidget' }
local PROFILE_NAMES     = { 'idle', 'farming', 'combat', 'emergency', 'named' }
local DIST_NAMES        = { 'reaction', 'precast', 'target_lock' }
local NOISE_KEYS        = { 'second_best_p', 'skip_global_p', 'retarget_hesit', 'double_press_p' }

-- Per-tab UI state (kept across draws via the closure of M).
local UIState = {
    selectedProfile = 'combat',
}

function M.draw(settings, themeNames, onChange)
    local H = getH()
    if not H then
        imgui.TextColored(1, 0.5, 0.5, 1, 'humanize module failed to load')
        return
    end

    -- Lazy-apply persisted settings on first draw.
    if H.applySettings then pcall(H.applySettings) end

    -- Master flag ---------------------------------------------------------
    local cfg = _G.SIDEKICK_NEXT_CONFIG or {}
    local enabled = cfg.HUMANIZE_BEHAVIOR == true
    local newEnabled, changed = imgui.Checkbox('Humanize layer enabled', enabled)
    if changed then persist('master', nil, newEnabled) end
    if imgui.IsItemHovered() then
        imgui.SetTooltip('Master switch. When off, gates and perturbations are no-ops (byte-identical to baseline).')
    end

    imgui.Separator()

    -- Status block --------------------------------------------------------
    local profile = H.activeProfile() or 'off'
    local override = H.getOverride() or 'auto'

    imgui.Text('Active profile:'); imgui.SameLine()
    badge(profile, colorForProfile(profile))
    imgui.Text('Override:      '); imgui.SameLine()
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
        if ch then persist('subsystem', { name = name }, v) end
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

            local mi = Cfg.minIntervalMs or 8000
            local newMi, miCh = imgui.SliderInt('Min interval (ms)##fidget_min', mi, 1000, 60000)
            if miCh then persist('fidget_minInterval', nil, newMi) end

            local fps = Cfg.fidgetPerSec or 1.0
            local newFps, fpsCh = imgui.SliderFloat('Avg per second##fidget_persec', fps, 0.05, 5.0, '%.2f')
            if fpsCh then persist('fidget_perSec', nil, newFps) end

            imgui.Separator()
            imgui.TextDisabled('Action weights')
            for _, action in ipairs(FIDGET_ACTIONS) do
                local cur = (Cfg.weights and Cfg.weights[action]) or 0
                local newW, ch = imgui.SliderFloat(action .. '##w_' .. action, cur, 0.0, 1.0, '%.2f')
                if ch then persist('fidget_weight', { action = action }, newW) end
            end

            imgui.Separator()
            imgui.TextDisabled('Keybinds (raw key names for /keypress)')
            local kbs = F.getKeybinds()
            for _, name in ipairs(FIDGET_KEYBINDS) do
                local cur = kbs[name] or ''
                local newV, ch = imgui.InputText(name .. '##kb_' .. name, cur, 32)
                if ch then persist('fidget_keybind', { name = name }, newV) end
            end

            imgui.Separator()
            imgui.TextDisabled('Window peek hotkeys')
            local wks = F.getWindowKeys()
            for _, name in ipairs(WINDOW_KEY_NAMES) do
                local cur = wks[name] or ''
                local newV, ch = imgui.InputText(name .. '##wk_' .. name, cur, 16)
                if ch then persist('window_key', { name = name }, newV) end
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
            if ch then persist('engage_min', nil, newMin) end

            local restick = T.restickAfterMs or 60000
            local newRs, rsCh = imgui.SliderInt('Re-stick after (ms)##eng_restick', restick, 5000, 600000)
            if rsCh then persist('restick_ms', nil, newRs) end
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
            if ch then persist('chase_jitter', nil, newPct / 100.0) end
        end
    end

    -- Profile editor ------------------------------------------------------
    if imgui.CollapsingHeader('Profile timings (per profile)') then
        local Profiles = getProfiles()
        if not Profiles then
            imgui.TextDisabled('profiles module not loaded')
        else
            -- Profile picker
            imgui.Text('Edit profile:')
            for _, pname in ipairs(PROFILE_NAMES) do
                imgui.SameLine()
                local pressed = false
                if pname == UIState.selectedProfile then
                    imgui.PushStyleColor(ImGuiCol.Button, 0.30, 0.55, 0.85, 1.0)
                    pressed = imgui.Button(pname .. '##pick_' .. pname)
                    imgui.PopStyleColor()
                else
                    pressed = imgui.Button(pname .. '##pick_' .. pname)
                end
                if pressed then UIState.selectedProfile = pname end
            end

            local sel = UIState.selectedProfile
            local p = Profiles.get(sel)
            if not p then
                imgui.TextDisabled('profile not found')
            else
                imgui.Separator()
                imgui.TextDisabled(string.format('Editing profile: %s', sel))

                for _, dname in ipairs(DIST_NAMES) do
                    local d = p[dname]
                    if d then
                        imgui.Text(dname .. ':')
                        local med = d.median_ms or 200
                        local newMed, c1 = imgui.SliderInt('median ms##' .. sel .. dname, med, 30, 2000)
                        if c1 then persist('profile_dist', { profile = sel, dist = dname, field = 'median_ms' }, newMed) end

                        local sig = d.sigma or 0.4
                        local newSig, c2 = imgui.SliderFloat('sigma##' .. sel .. dname, sig, 0.05, 1.0, '%.2f')
                        if c2 then persist('profile_dist', { profile = sel, dist = dname, field = 'sigma' }, newSig) end

                        local mn = d.min or 50
                        local newMn, c3 = imgui.SliderInt('min ms##' .. sel .. dname, mn, 0, 1000)
                        if c3 then persist('profile_dist', { profile = sel, dist = dname, field = 'min' }, newMn) end

                        local mx = d.max or 1500
                        local newMx, c4 = imgui.SliderInt('max ms##' .. sel .. dname, mx, 100, 5000)
                        if c4 then persist('profile_dist', { profile = sel, dist = dname, field = 'max' }, newMx) end
                        imgui.Separator()
                    end
                end

                local bj = p.buff_refresh_pct_jitter or 0
                local newBj, bjCh = imgui.SliderFloat('buff_refresh_pct_jitter##' .. sel, bj, 0.0, 0.5, '%.2f')
                if bjCh then persist('profile_buff', { profile = sel }, newBj) end

                imgui.Separator()
                imgui.TextDisabled('Decision noise')
                local noise = p.noise or {}
                for _, nk in ipairs(NOISE_KEYS) do
                    local cur = noise[nk] or 0
                    local newN, c = imgui.SliderFloat(nk .. '##' .. sel .. nk, cur, 0.0, 0.5, '%.3f')
                    if c then persist('profile_noise', { profile = sel, key = nk }, newN) end
                end
            end
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
