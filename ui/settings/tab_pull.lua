-- ============================================================
-- SideKick Settings - Pull Tab
-- ============================================================
-- UI for the ported rgmercs pull module (Normal + Chain modes).
-- Knob changes are persisted via the pull module's persistKnob() helper,
-- which writes through Core.set under the 'Pull_' prefix.

local imgui = require('ImGui')
local mq = require('mq')

local M = {}

local function getPull()
    local ok, P = pcall(require, 'sidekick-next.automation.pull')
    if ok then return P end
    return nil
end

local function getAbilities()
    local ok, A = pcall(require, 'sidekick-next.automation.pull.abilities')
    if ok then return A end
    return nil
end

local MODES = { 'Normal', 'Chain' }

local function colorState(s)
    if s == 'IDLE'          then return 0.55, 0.85, 0.55, 1 end
    if s == 'SCAN'          then return 0.55, 0.85, 0.95, 1 end
    if s == 'NAV_TO_TARGET' then return 0.95, 0.85, 0.45, 1 end
    if s == 'PULLING'       then return 1.00, 0.45, 0.30, 1 end
    if s == 'RETURN_CAMP'   then return 0.95, 0.85, 0.45, 1 end
    if s == 'WAITING_MOB'   then return 0.85, 0.85, 0.45, 1 end
    if s == 'WAITING_GATE'  then return 0.95, 0.55, 0.55, 1 end
    return 0.85, 0.85, 0.85, 1
end

function M.draw(settings, themeNames, onChange)
    local Pull = getPull()
    if not Pull then
        imgui.TextColored(1, 0.5, 0.5, 1, 'pull module failed to load')
        return
    end

    local cfg = Pull.getConfig()
    local st  = Pull.getState()

    -- Status block --------------------------------------------------------
    local r, g, b, a = colorState(st.state)
    imgui.Text('State: ')
    imgui.SameLine()
    imgui.TextColored(r, g, b, a, st.state .. (st.reason ~= '' and (' (' .. st.reason .. ')') or ''))

    if st.pullId and st.pullId > 0 then
        local sp = mq.TLO.Spawn(st.pullId)
        local nm = (sp and sp() and sp.CleanName and sp.CleanName()) or '?'
        imgui.Text(string.format('Target: %s (id=%d)', nm, st.pullId))
    end

    if st.campSet then
        imgui.TextDisabled('Camp set')
    else
        imgui.TextDisabled('Camp not set (will set on start)')
    end

    imgui.Separator()

    -- Master controls -----------------------------------------------------
    if cfg.enabled then
        if imgui.Button('Stop##pull_stop') then Pull.stop() end
    else
        if imgui.Button('Start##pull_start') then Pull.start() end
    end
    imgui.SameLine()
    if imgui.Button('Set Camp Here##pull_camp') then mq.cmd('/sk_pull camp') end
    imgui.SameLine()
    if imgui.Button('Pull Current Target##pull_one') then Pull.pullCurrentTarget() end
    imgui.SameLine()
    if imgui.Button('Clear Ignore##pull_ignore') then Pull.clearIgnore() end

    imgui.Separator()

    -- Mode + ability ------------------------------------------------------
    if imgui.BeginCombo('Mode##pull_mode', cfg.mode) then
        for _, m in ipairs(MODES) do
            local sel = (m == cfg.mode)
            if imgui.Selectable(m, sel) then Pull.persistKnob('mode', m) end
        end
        imgui.EndCombo()
    end

    local A = getAbilities()
    if A then
        local options = {}
        for _, def in ipairs(A.Definitions) do table.insert(options, def.id) end
        if imgui.BeginCombo('Pull ability##pull_ability', cfg.ability) then
            for _, id in ipairs(options) do
                local sel = (id == cfg.ability)
                if imgui.Selectable(id, sel) then Pull.persistKnob('ability', id) end
            end
            imgui.EndCombo()
        end

        if cfg.ability == 'Item' then
            local newName, ch = imgui.InputText('Item name##pull_item', cfg.pullItemName or '', 64)
            if ch then Pull.persistKnob('pullItemName', newName) end
        end
    end

    imgui.Separator()

    -- Numeric tunables ----------------------------------------------------
    if imgui.CollapsingHeader('Movement') then
        local r1, c1 = imgui.SliderInt('Pull radius##pr', cfg.pullRadius or 200, 30, 600)
        if c1 then Pull.persistKnob('pullRadius', r1) end
        local r2, c2 = imgui.SliderInt('Pull Z radius##pzr', cfg.pullZRadius or 100, 10, 400)
        if c2 then Pull.persistKnob('pullZRadius', r2) end
        local r3, c3 = imgui.SliderInt('Pull delay (s)##pd', cfg.pullDelaySec or 5, 1, 300)
        if c3 then Pull.persistKnob('pullDelaySec', r3) end
        local r4, c4 = imgui.SliderInt('Max nav time (s)##mt', cfg.maxMoveTimeSec or 30, 5, 180)
        if c4 then Pull.persistKnob('maxMoveTimeSec', r4) end
        local r5, c5 = imgui.SliderInt('Max path range (0=any)##mpr', cfg.maxPathRange or 0, 0, 1000)
        if c5 then Pull.persistKnob('maxPathRange', r5) end
        local r6, c6 = imgui.SliderInt('Auto camp radius##acr', cfg.autoCampRadius or 25, 5, 100)
        if c6 then Pull.persistKnob('autoCampRadius', r6) end
        local v, ch = imgui.Checkbox('Pull facing backwards##pb', cfg.pullBackwards == true)
        if ch then Pull.persistKnob('pullBackwards', v) end
    end

    if imgui.CollapsingHeader('Chain') then
        local r1, c1 = imgui.SliderInt('Chain count##cc', cfg.chainCount or 2, 1, 10)
        if c1 then Pull.persistKnob('chainCount', r1) end
        imgui.TextDisabled('In Chain mode, pull while combat has fewer than this many haters.')
    end

    if imgui.CollapsingHeader('Safety gates') then
        local r1, c1 = imgui.SliderInt('Min HP %##hp', cfg.pullHpPct or 75, 0, 100)
        if c1 then Pull.persistKnob('pullHpPct', r1) end
        local r2, c2 = imgui.SliderInt('Min mana %##mana', cfg.pullManaPct or 30, 0, 100)
        if c2 then Pull.persistKnob('pullManaPct', r2) end
        local r3, c3 = imgui.SliderInt('Min endurance %##end', cfg.pullEndPct or 25, 0, 100)
        if c3 then Pull.persistKnob('pullEndPct', r3) end
        local r4, c4 = imgui.SliderInt('Required buff count##bc', cfg.pullBuffCount or 0, 0, 60)
        if c4 then Pull.persistKnob('pullBuffCount', r4) end
        local v1, ch1 = imgui.Checkbox('Pull while debuffed##pd_dbg', cfg.pullDebuffed == true)
        if ch1 then Pull.persistKnob('pullDebuffed', v1) end
        local v2, ch2 = imgui.Checkbox('Pull mobs in water##pmw', cfg.pullMobsInWater == true)
        if ch2 then Pull.persistKnob('pullMobsInWater', v2) end
        local v3, ch3 = imgui.Checkbox('Respect med state##rms', cfg.pullRespectMedState == true)
        if ch3 then Pull.persistKnob('pullRespectMedState', v3) end
    end

    if imgui.CollapsingHeader('Target filter') then
        local v, ch = imgui.Checkbox('Use level range (vs con)##ul', cfg.useLevels == true)
        if ch then Pull.persistKnob('useLevels', v) end
        if cfg.useLevels then
            local r1, c1 = imgui.SliderInt('Min level##minl', cfg.minLevel or 1, 1, 125)
            if c1 then Pull.persistKnob('minLevel', r1) end
            local r2, c2 = imgui.SliderInt('Max level##maxl', cfg.maxLevel or 999, 1, 999)
            if c2 then Pull.persistKnob('maxLevel', r2) end
        else
            local r1, c1 = imgui.SliderInt('Min con (1=grey..7=red)##minc', cfg.minCon or 2, 1, 7)
            if c1 then Pull.persistKnob('minCon', r1) end
            local r2, c2 = imgui.SliderInt('Max con (1=grey..7=red)##maxc', cfg.maxCon or 7, 1, 7)
            if c2 then Pull.persistKnob('maxCon', r2) end
            local r3, c3 = imgui.SliderInt('Max level diff over me##mld', cfg.maxLevelDiff or 3, 0, 10)
            if c3 then Pull.persistKnob('maxLevelDiff', r3) end
        end
    end

    -- Allow / Deny lists --------------------------------------------------
    if imgui.CollapsingHeader('Allow / Deny lists') then
        local function drawList(title, key, list)
            imgui.TextDisabled(title .. ' (' .. (#list or 0) .. ')')
            local newL = {}
            for i, name in ipairs(list or {}) do
                imgui.Text(name)
                imgui.SameLine()
                if imgui.SmallButton('x##' .. key .. i) then
                    -- omit this one
                else
                    table.insert(newL, name)
                end
            end
            -- Apply removals if anything was dropped
            if #newL ~= #(list or {}) then Pull.persistKnob(key, newL) end

            local btn = 'Add target##add_' .. key
            if imgui.Button(btn) then
                local tn = mq.TLO.Target.CleanName and mq.TLO.Target.CleanName() or ''
                if tn and tn ~= '' then
                    if key == 'denyList' then Pull.deny(tn) else Pull.allow(tn) end
                end
            end
            imgui.Separator()
        end
        drawList('Allow list', 'allowList', cfg.allowList or {})
        drawList('Deny list',  'denyList',  cfg.denyList  or {})
    end
end

return M
