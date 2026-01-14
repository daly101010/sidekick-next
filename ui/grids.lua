local imgui = require('ImGui')
local ConditionBuilder = require('ui.condition_builder')
local Core = require('utils.core')
local Ability = require('utils.abilities')

local M = {}

-- Mode constants (from Ability module)
local MODE_ON_DEMAND = Ability.MODE.ON_DEMAND
local MODE_ON_CONDITION = Ability.MODE.ON_CONDITION
local MODE_ON_COOLDOWN = Ability.MODE.ON_COOLDOWN

-- Context constants for ON_COOLDOWN mode
local CONTEXT_COMBAT = Ability.CONTEXT.COMBAT
local CONTEXT_OUT_OF_COMBAT = Ability.CONTEXT.OUT_OF_COMBAT
local CONTEXT_ANYTIME = Ability.CONTEXT.ANYTIME

local CONTEXT_KEYS = { CONTEXT_COMBAT, CONTEXT_OUT_OF_COMBAT, CONTEXT_ANYTIME }
local CONTEXT_LABELS = Ability.CONTEXT_LABELS

local LAYER_KEYS = { 'auto', 'emergency', 'aggro', 'defenses', 'burn', 'combat', 'utility' }
local LAYER_LABELS = {
    auto = 'Auto',
    emergency = 'Emergency',
    aggro = 'Aggro',
    defenses = 'Defenses',
    burn = 'Burn',
    combat = 'Combat',
    utility = 'Utility',
}

local function vecX(v)
    if type(v) == 'number' then return tonumber(v) or 0 end
    if type(v) == 'table' then return tonumber(v.x or v[1]) or 0 end
    local ok, x = pcall(function() return v.x end)
    if ok and x ~= nil then return tonumber(x) or 0 end
    return 0
end

local function textWidth(txt)
    local w = imgui.CalcTextSize(tostring(txt or ''))
    return vecX(w)
end

local function getAvailX()
    local a, b = imgui.GetContentRegionAvail()
    if b ~= nil then return tonumber(a) or 0 end
    if type(a) == 'table' and a.x then return tonumber(a.x) or 0 end
    return tonumber(a) or 0
end

local function cooldownTotalFor(def, cooldownProbe)
    if not cooldownProbe then return nil end
    local name = def and (def.discName or def.altName)
    if type(name) ~= 'string' or name == '' then return nil end
    local ok, _, total = pcall(function() return cooldownProbe({ label = name, key = name }) end)
    if not ok then return nil end
    total = tonumber(total) or 0
    if total <= 0 then return nil end
    return total
end

local function drawDescription(desc)
    desc = tostring(desc or '')
    if desc == '' then return end
    desc = desc:gsub('\\n', '\n')
    desc = desc:gsub('\r', '')
    for line in desc:gmatch('([^\n]+)') do
        imgui.TextWrapped(line)
    end
end

function M.collectEnabledAbilities(abilities, settings)
    local out = {}
    for _, def in ipairs(abilities or {}) do
        if type(def) == 'table' and def.settingKey and (def.visible ~= false) then
            if settings and settings[def.settingKey] == true then
                table.insert(out, def)
            end
        end
    end
    return out
end

local function comboMode(label, current, labelsByMode)
    -- Build sorted list of mode keys
    local modes = {}
    for mode, _ in pairs(labelsByMode) do
        table.insert(modes, mode)
    end
    table.sort(modes, function(a, b) return tonumber(a) < tonumber(b) end)

    -- Build null-separated labels string and find current index
    local labels = {}
    local currentIdx = 1  -- MQ ImGui Combo uses 1-based indexing
    for i, mode in ipairs(modes) do
        table.insert(labels, labelsByMode[mode])
        if mode == current then
            currentIdx = i  -- 1-based index for MQ
        end
    end
    local labelStr = table.concat(labels, '\0') .. '\0\0'

    -- Use simple Combo which returns new index directly (1-based in MQ)
    local newIdx = imgui.Combo(label, currentIdx, labelStr)
    if newIdx ~= currentIdx and modes[newIdx] then
        return modes[newIdx]
    end
    return current
end

local function comboKeyed(label, current, keys, labelsByKey)
    keys = keys or {}
    labelsByKey = labelsByKey or {}

    local currentIdx = 1 -- MQ ImGui Combo uses 1-based indexing
    local labels = {}
    for i, k in ipairs(keys) do
        local kk = tostring(k)
        labels[i] = labelsByKey[kk] or kk
        if kk == tostring(current) then
            currentIdx = i
        end
    end

    local labelStr = table.concat(labels, '\0') .. '\0\0'
    local newIdx = imgui.Combo(label, currentIdx, labelStr)
    if newIdx ~= currentIdx and keys[newIdx] then
        return tostring(keys[newIdx])
    end
    return tostring(current)
end

local function romanToInt(s)
    s = tostring(s or ''):upper()
    if s == '' then return nil end
    local map = { I = 1, V = 5, X = 10, L = 50, C = 100, D = 500, M = 1000 }
    local total = 0
    local prev = 0
    for i = #s, 1, -1 do
        local ch = s:sub(i, i)
        local v = map[ch]
        if not v then return nil end
        if v < prev then total = total - v else total = total + v; prev = v end
    end
    return total
end

local function splitRankSuffix(name)
    name = tostring(name or '')
    local base, num = name:match('^(.-)%s+(%d+)$')
    if base and num then
        return base, tonumber(num)
    end
    local base2, roman = name:match('^(.-)%s+([IVXLCDM]+)$')
    if base2 and roman then
        local r = romanToInt(roman)
        if r then return base2, r end
    end
    return name, nil
end

function M.drawAbilities(ctx)
    ctx = ctx or {}
    local abilities = ctx.abilities or {}
    local settings = ctx.settings or {}
    local modeLabels = ctx.modeLabels or {}

    if #abilities == 0 then
        imgui.Text('No class abilities loaded yet.')
        imgui.Text('Run `tools/aa_discovery.lua` in-game to generate `data/classes/<CLASS>.lua`.')
        return
    end

    local aas, discs = {}, {}
    for _, def in ipairs(abilities) do
        if type(def) == 'table' then
            local kind = tostring(def.kind or 'aa')
            if kind == 'disc' then
                table.insert(discs, def)
            else
                table.insert(aas, def)
            end
        end
    end

    -- Consolidate Mythic Glyph variants to the highest rank available.
    -- Also migrate any enabled lower-rank glyphs to the highest rank once per session.
    do
        local glyphGroups = {}
        for _, def in ipairs(aas) do
            local name = tostring(def.altName or def.label or '')
            if name:lower():match('^mythic%s+glyph%s+of%s+') then
                local base, rank = splitRankSuffix(name)
                base = tostring(base or name)
                glyphGroups[base] = glyphGroups[base] or { defs = {} }
                table.insert(glyphGroups[base].defs, { def = def, rank = tonumber(rank) or 0 })
            end
        end

        local migrated = M._glyphMigrated or {}
        M._glyphMigrated = migrated

        for base, g in pairs(glyphGroups) do
            table.sort(g.defs, function(a, b)
                if a.rank ~= b.rank then return a.rank > b.rank end
                return tostring(a.def.settingKey or '') < tostring(b.def.settingKey or '')
            end)
            local highest = g.defs[1] and g.defs[1].def or nil
            if highest then
                local anyEnabled = nil
                local enabledMode = nil
                for _, entry in ipairs(g.defs) do
                    local d = entry.def
                    if settings[d.settingKey] == true then
                        anyEnabled = d
                        enabledMode = tonumber(settings[d.modeKey])
                        break
                    end
                end

                if anyEnabled and anyEnabled.settingKey ~= highest.settingKey and migrated[base] ~= true then
                    migrated[base] = true
                    if ctx.onToggle then
                        -- Disable all glyph variants and enable the highest.
                        for _, entry in ipairs(g.defs) do
                            local d = entry.def
                            if settings[d.settingKey] == true then
                                ctx.onToggle(d.settingKey, false)
                            end
                        end
                        ctx.onToggle(highest.settingKey, true)
                    end
                    if enabledMode ~= nil and ctx.onMode and highest.modeKey then
                        ctx.onMode(highest.modeKey, enabledMode)
                    end
                end
            end
        end

        -- Filter AAs list to show only the highest glyph per base.
        if next(glyphGroups) ~= nil then
            local keep = {}
            for base, g in pairs(glyphGroups) do
                table.sort(g.defs, function(a, b)
                    if a.rank ~= b.rank then return a.rank > b.rank end
                    return tostring(a.def.settingKey or '') < tostring(b.def.settingKey or '')
                end)
                local highest = g.defs[1] and g.defs[1].def or nil
                if highest then keep[highest.settingKey] = true end
            end
            local filtered = {}
            for _, def in ipairs(aas) do
                local name = tostring(def.altName or def.label or '')
                if name:lower():match('^mythic%s+glyph%s+of%s+') then
                    if keep[def.settingKey] then
                        table.insert(filtered, def)
                    end
                else
                    table.insert(filtered, def)
                end
            end
            aas = filtered
        end
    end

    if #aas > 0 then
        table.sort(aas, function(a, b)
            local at = cooldownTotalFor(a, ctx.cooldownProbe)
            local bt = cooldownTotalFor(b, ctx.cooldownProbe)
            if at == nil and bt ~= nil then return false end
            if at ~= nil and bt == nil then return true end
            if at ~= nil and bt ~= nil and at ~= bt then return at < bt end
            return tostring(a.altName or '') < tostring(b.altName or '')
        end)
    end

    if #discs > 0 then
        table.sort(discs, function(a, b)
            local at = tonumber(a.timer)
            local bt = tonumber(b.timer)
            if at == nil and bt ~= nil then return false end
            if at ~= nil and bt == nil then return true end
            if at ~= nil and bt ~= nil and at ~= bt then return at < bt end

            local al = tonumber(a.level) or 0
            local bl = tonumber(b.level) or 0
            if al ~= bl then return al > bl end

            local an = tostring(a.discName or a.altName or '')
            local bn = tostring(b.discName or b.altName or '')
            return an < bn
        end)
    end

    local function drawList(list)
        -- New column layout: Enable | Ability | Mode | Context/Layer | CD
        imgui.Columns(5, '##sk_cols', false)
        local avail = math.max(360, getAvailX())
        local enW = math.max(50, textWidth('Enable') + 8)
        local modeW = 105
        local contextW = 105  -- Context or Layer column
        local cdW = 54
        local abilityW = math.max(160, avail - (enW + modeW + contextW + cdW))
        if imgui.SetColumnWidth then
            imgui.SetColumnWidth(0, enW)
            imgui.SetColumnWidth(1, abilityW)
            imgui.SetColumnWidth(2, modeW)
            imgui.SetColumnWidth(3, contextW)
            imgui.SetColumnWidth(4, cdW)
        end
        imgui.Text('Enable'); imgui.NextColumn()
        imgui.Text('Ability'); imgui.NextColumn()
        imgui.Text('Mode'); imgui.NextColumn()
        imgui.Text(''); imgui.NextColumn()  -- Context/Layer header (dynamic)
        imgui.Text('CD'); imgui.NextColumn()
        imgui.Separator()

        local function setSetting(key, value)
            if ctx.onSetting then
                ctx.onSetting(key, value)
            elseif ctx.onMode then
                ctx.onMode(key, value)
            elseif ctx.onToggle then
                ctx.onToggle(key, value)
            end
        end

        for _, def in ipairs(list) do
            if type(def) == 'table' and def.settingKey and def.modeKey then
                imgui.PushID(def.settingKey)

                local enabled = settings[def.settingKey] == true
                local changed
                enabled, changed = imgui.Checkbox('##en', enabled)
                if changed and ctx.onToggle then ctx.onToggle(def.settingKey, enabled) end
                imgui.NextColumn()

                local kind = tostring(def.kind or 'aa')
                local name = tostring(def.altName or def.discName or def.label or def.settingKey)
                if kind == 'disc' then
                    local t = (def.timer ~= nil) and ('T' .. tostring(def.timer)) or 'T-'
                    local lvl = (def.level ~= nil) and tostring(def.level) or '-'
                    imgui.Text(string.format('[%s L%s] %s', t, lvl, name))
                else
                    imgui.Text(name)
                end

                if imgui.IsItemHovered() then
                    imgui.BeginTooltip()
                    imgui.Text(name)
                    if kind == 'disc' then
                        if def.timer ~= nil then imgui.Text(string.format('Timer: T%s', tostring(def.timer))) end
                        if def.level ~= nil then imgui.Text(string.format('Level: %s', tostring(def.level))) end
                    end
                    if def.description and tostring(def.description) ~= '' then
                        imgui.Separator()
                        drawDescription(def.description)
                    end
                    imgui.EndTooltip()
                end
                imgui.NextColumn()

                -- Mode dropdown
                local mode = tonumber(settings[def.modeKey]) or MODE_ON_DEMAND
                imgui.SetNextItemWidth(modeW - 6)
                local newMode = comboMode('##mode_' .. def.settingKey, mode, modeLabels)
                if newMode ~= mode and ctx.onMode then
                    ctx.onMode(def.modeKey, newMode)
                    mode = newMode  -- Update for conditional rendering below
                end
                imgui.NextColumn()

                -- Context/Layer column (depends on mode)
                if mode == MODE_ON_COOLDOWN then
                    -- Show Context dropdown for mash abilities
                    local contextKey = tostring(def.settingKey) .. 'Context'
                    local curContext = tonumber(settings[contextKey]) or CONTEXT_COMBAT
                    imgui.SetNextItemWidth(contextW - 6)
                    local newContext = comboMode('##ctx_' .. def.settingKey, curContext, CONTEXT_LABELS)
                    if newContext ~= curContext then
                        setSetting(contextKey, newContext)
                    end
                elseif mode == MODE_ON_CONDITION then
                    -- Show Layer dropdown for conditional abilities
                    local layerKey = tostring(def.settingKey) .. 'Layer'
                    local curLayer = tostring(settings[layerKey] or 'auto'):lower()
                    if curLayer == '' or curLayer == 'nil' or LAYER_LABELS[curLayer] == nil then
                        curLayer = 'auto'
                    end
                    imgui.SetNextItemWidth(contextW - 6)
                    local newLayer = comboKeyed('##layer_' .. def.settingKey, curLayer, LAYER_KEYS, LAYER_LABELS)
                    if newLayer ~= curLayer then
                        setSetting(layerKey, newLayer)
                    end
                else
                    -- On Demand: no additional controls
                    imgui.Text('')
                end
                imgui.NextColumn()

                -- CD column
                local cdText = ''
                if ctx.cooldownProbe then
                    local nm = def.altName or def.discName
                    local rem, total = ctx.cooldownProbe({ label = nm, key = nm })
                    if rem and rem > 0 and total and total > 0 and ctx.helpers and ctx.helpers.fmtCooldown then
                        cdText = ctx.helpers.fmtCooldown(rem)
                    end
                end
                imgui.Text(cdText)
                imgui.NextColumn()

                -- Show condition builder when mode is ON_CONDITION
                if mode == MODE_ON_CONDITION then
                    local condKey = def.modeKey:gsub('Mode$', 'Condition')
                    local condData = settings[condKey]
                    if not condData and Core.Ini and Core.Ini['SideKick-Abilities'] then
                        local serialized = Core.Ini['SideKick-Abilities'][condKey]
                        if serialized and ConditionBuilder.deserialize then
                            condData = ConditionBuilder.deserialize(serialized)
                        end
                    end

                    -- Span all columns for the condition builder
                    imgui.Columns(1)
                    imgui.Indent(20)
                    ConditionBuilder.drawInline(condKey, condData, function(newData)
                        Core.Settings[condKey] = newData
                        if Core.Ini and ConditionBuilder.serialize then
                            Core.Ini['SideKick-Abilities'] = Core.Ini['SideKick-Abilities'] or {}
                            Core.Ini['SideKick-Abilities'][condKey] = ConditionBuilder.serialize(newData)
                        end
                        if Core.save then Core.save() end
                    end)
                    imgui.Unindent(20)
                    -- Restore columns
                    imgui.Columns(5, '##sk_cols', false)
                    if imgui.SetColumnWidth then
                        imgui.SetColumnWidth(0, enW)
                        imgui.SetColumnWidth(1, abilityW)
                        imgui.SetColumnWidth(2, modeW)
                        imgui.SetColumnWidth(3, contextW)
                        imgui.SetColumnWidth(4, cdW)
                    end
                end

                imgui.PopID()
            end
        end

        imgui.Columns(1)
    end

    local function drawDiscList(list)
        -- Group by timer; allow multiple enabled per timer.
        local groups = {}
        for _, def in ipairs(list or {}) do
            if type(def) == 'table' and def.settingKey and def.modeKey then
                local t = tonumber(def.timer)
                if not t then
                    -- Keep "timerless" discs grouped separately.
                    t = -1
                end
                groups[t] = groups[t] or {}
                table.insert(groups[t], def)
            end
        end

        local timers = {}
        for t, _ in pairs(groups) do table.insert(timers, t) end
        table.sort(timers, function(a, b) return (tonumber(a) or 0) < (tonumber(b) or 0) end)

        local function sortByLevelDesc(a, b)
            local al = tonumber(a.level) or 0
            local bl = tonumber(b.level) or 0
            if al ~= bl then return al > bl end
            return tostring(a.discName or a.altName or '') < tostring(b.discName or b.altName or '')
        end

        local function enabledCount(defs)
            local c = 0
            for _, d in ipairs(defs or {}) do
                if settings[d.settingKey] == true then c = c + 1 end
            end
            return c
        end

        local function applyGroupEnabled(defs, enabled)
            if not ctx.onToggle then return end
            if enabled ~= true then
                for _, d in ipairs(defs or {}) do
                    if settings[d.settingKey] == true then
                        ctx.onToggle(d.settingKey, false)
                    end
                end
                return
            end
            -- Turn on: default to enabling the highest-level disc only (user can enable more by expanding).
            local best = defs and defs[1] or nil
            for _, d in ipairs(defs or {}) do
                if best == nil then best = d end
                if settings[d.settingKey] == true then best = nil break end -- already has selection(s)
            end
            if best and best.settingKey then
                ctx.onToggle(best.settingKey, true)
            end
        end

        -- New column layout: Enable | Timer | Discipline | Mode | Context/Layer | CD
        imgui.Columns(6, '##sk_disc_groups', false)
        local avail = math.max(420, getAvailX())
        local enW = math.max(50, textWidth('Enable') + 8)
        local tW = math.max(48, textWidth('Timer') + 8)
        local modeW = 105
        local contextW = 105  -- Context or Layer column
        local cdW = 54
        local discW = math.max(160, avail - (enW + tW + modeW + contextW + cdW))
        if imgui.SetColumnWidth then
            imgui.SetColumnWidth(0, enW)
            imgui.SetColumnWidth(1, tW)
            imgui.SetColumnWidth(2, discW)
            imgui.SetColumnWidth(3, modeW)
            imgui.SetColumnWidth(4, contextW)
            imgui.SetColumnWidth(5, cdW)
        end
        imgui.Text('Enable'); imgui.NextColumn()
        imgui.Text('Timer'); imgui.NextColumn()
        imgui.Text('Discipline'); imgui.NextColumn()
        imgui.Text('Mode'); imgui.NextColumn()
        imgui.Text(''); imgui.NextColumn()  -- Context/Layer header (dynamic)
        imgui.Text('CD'); imgui.NextColumn()
        imgui.Separator()

        local function setSetting(key, value)
            if ctx.onSetting then
                ctx.onSetting(key, value)
            elseif ctx.onMode then
                ctx.onMode(key, value)
            elseif ctx.onToggle then
                ctx.onToggle(key, value)
            end
        end

        for _, timer in ipairs(timers) do
            local defs = groups[timer] or {}
            table.sort(defs, sortByLevelDesc)
            local cacheKey = tostring(timer)
            local enCount = enabledCount(defs)
            local anyEnabled = enCount > 0

            imgui.PushID('discgrp_' .. cacheKey)

            local enNow, changed = imgui.Checkbox('##en', anyEnabled)
            if changed then
                applyGroupEnabled(defs, enNow)
            end
            if imgui.IsItemHovered() then
                imgui.SetTooltip('Toggle this timer group (defaults to highest level). Expand to enable multiple.')
            end
            imgui.NextColumn()

            imgui.Text(timer >= 0 and tostring(timer) or '-')
            imgui.NextColumn()

            local label = string.format('(%d/%d enabled)', enCount, #defs)
            local childrenSummary = ''
            do
                local top = defs[1]
                local topName = top and (top.discName or top.altName or top.label) or nil
                topName = tostring(topName or 'Timer Group')
                if topName == '' then topName = 'Timer Group' end
                local visibleName = topName
                if #visibleName > 28 then
                    visibleName = visibleName:sub(1, 25) .. '...'
                end
                childrenSummary = visibleName
                if #defs > 1 then
                    childrenSummary = string.format('%s (+%d)', visibleName, #defs - 1)
                end
            end
            local open = false
            local nodeLabel = (timer >= 0) and 'Timer' or 'No Timer'
            if imgui.TreeNode then
                open = imgui.TreeNode(nodeLabel .. '##timergrp_' .. cacheKey)
                if imgui.IsItemHovered() then
                    imgui.BeginTooltip()
                    imgui.Text(string.format('Timer %s', timer >= 0 and tostring(timer) or '-'))
                    imgui.Separator()
                    for _, d in ipairs(defs) do
                        local nm = tostring(d.discName or d.altName or d.label or d.settingKey)
                        local lvl = d.level ~= nil and tostring(d.level) or '?'
                        local mark = (settings[d.settingKey] == true) and '*' or ' '
                        imgui.Text(string.format('%s Lv%s %s', mark, lvl, nm))
                    end
                    imgui.EndTooltip()
                end
                imgui.SameLine()
                imgui.TextDisabled(string.format('%s %s', label, childrenSummary))
            else
                imgui.Text(string.format('%s %s %s', nodeLabel, label, childrenSummary))
            end
            imgui.NextColumn()

            imgui.Text(''); imgui.NextColumn() -- Mode (group header)
            imgui.Text(''); imgui.NextColumn() -- Context/Layer (group header)
            imgui.Text(''); imgui.NextColumn() -- CD (group header)

            if open then
                for _, def in ipairs(defs) do
                    imgui.PushID(def.settingKey)

                    local enabled = settings[def.settingKey] == true
                    local changed2
                    enabled, changed2 = imgui.Checkbox('##en', enabled)
                    if changed2 and ctx.onToggle then ctx.onToggle(def.settingKey, enabled) end
                    imgui.NextColumn()

                    imgui.Text('') -- Timer shown on group header
                    imgui.NextColumn()

                    local nm = tostring(def.discName or def.altName or def.label or def.settingKey)
                    local lvl = def.level ~= nil and tostring(def.level) or '?'
                    imgui.Text(string.format('Lv%s %s', lvl, nm))
                    if imgui.IsItemHovered() then
                        imgui.BeginTooltip()
                        imgui.Text(nm)
                        if def.timer ~= nil then imgui.Text(string.format('Timer: T%s', tostring(def.timer))) end
                        if def.level ~= nil then imgui.Text(string.format('Level: %s', tostring(def.level))) end
                        if def.description and tostring(def.description) ~= '' then
                            imgui.Separator()
                            drawDescription(def.description)
                        end
                        imgui.EndTooltip()
                    end
                    imgui.NextColumn()

                    -- Mode dropdown
                    local mode = tonumber(settings[def.modeKey]) or MODE_ON_DEMAND
                    imgui.SetNextItemWidth(modeW - 6)
                    local newMode = comboMode('##mode_' .. def.settingKey, mode, modeLabels)
                    if newMode ~= mode and ctx.onMode then
                        ctx.onMode(def.modeKey, newMode)
                        mode = newMode  -- Update for conditional rendering below
                    end
                    imgui.NextColumn()

                    -- Context/Layer column (depends on mode)
                    if mode == MODE_ON_COOLDOWN then
                        -- Show Context dropdown for mash abilities
                        local contextKey = tostring(def.settingKey) .. 'Context'
                        local curContext = tonumber(settings[contextKey]) or CONTEXT_COMBAT
                        imgui.SetNextItemWidth(contextW - 6)
                        local newContext = comboMode('##ctx_' .. def.settingKey, curContext, CONTEXT_LABELS)
                        if newContext ~= curContext then
                            setSetting(contextKey, newContext)
                        end
                    elseif mode == MODE_ON_CONDITION then
                        -- Show Layer dropdown for conditional abilities
                        local layerKey = tostring(def.settingKey) .. 'Layer'
                        local curLayer = tostring(settings[layerKey] or 'auto'):lower()
                        if curLayer == '' or curLayer == 'nil' or LAYER_LABELS[curLayer] == nil then
                            curLayer = 'auto'
                        end
                        imgui.SetNextItemWidth(contextW - 6)
                        local newLayer = comboKeyed('##layer_' .. def.settingKey, curLayer, LAYER_KEYS, LAYER_LABELS)
                        if newLayer ~= curLayer then
                            setSetting(layerKey, newLayer)
                        end
                    else
                        -- On Demand: no additional controls
                        imgui.Text('')
                    end
                    imgui.NextColumn()

                    -- CD column
                    local cdText = ''
                    if ctx.cooldownProbe then
                        local keyName = def.discName or def.altName
                        local rem, total = ctx.cooldownProbe({ label = keyName, key = keyName })
                        if rem and rem > 0 and ctx.helpers and ctx.helpers.fmtCooldown then
                            cdText = ctx.helpers.fmtCooldown(rem)
                        end
                    end
                    imgui.Text(cdText)
                    imgui.NextColumn()

                    -- Show condition builder when mode is ON_CONDITION
                    if mode == MODE_ON_CONDITION then
                        local condKey = def.modeKey:gsub('Mode$', 'Condition')
                        local condData = settings[condKey]
                        if not condData and Core.Ini and Core.Ini['SideKick-Abilities'] then
                            local serialized = Core.Ini['SideKick-Abilities'][condKey]
                            if serialized and ConditionBuilder.deserialize then
                                condData = ConditionBuilder.deserialize(serialized)
                            end
                        end

                        -- Span all columns for the condition builder
                        imgui.Columns(1)
                        imgui.Indent(20)
                        ConditionBuilder.drawInline(condKey, condData, function(newData)
                            Core.Settings[condKey] = newData
                            if Core.Ini and ConditionBuilder.serialize then
                                Core.Ini['SideKick-Abilities'] = Core.Ini['SideKick-Abilities'] or {}
                                Core.Ini['SideKick-Abilities'][condKey] = ConditionBuilder.serialize(newData)
                            end
                            if Core.save then Core.save() end
                        end)
                        imgui.Unindent(20)
                        -- Restore columns
                        imgui.Columns(6, '##sk_disc_groups', false)
                        if imgui.SetColumnWidth then
                            imgui.SetColumnWidth(0, enW)
                            imgui.SetColumnWidth(1, tW)
                            imgui.SetColumnWidth(2, discW)
                            imgui.SetColumnWidth(3, modeW)
                            imgui.SetColumnWidth(4, contextW)
                            imgui.SetColumnWidth(5, cdW)
                        end
                    end

                    imgui.PopID()
                end

                if imgui.TreePop then imgui.TreePop() end
            end

            imgui.PopID()
        end

        imgui.Columns(1)
    end

    local function drawInScrollChild(childId, fn)
        if not (imgui and imgui.BeginChild and imgui.EndChild) then
            fn()
            return
        end
        local started = imgui.BeginChild(childId)
        if started then
            fn()
        end
        imgui.EndChild()
    end

    -- Keep the "AAs / Disciplines" tab bar pinned by putting the list in a child scroller.
    if #discs > 0 and imgui.BeginTabBar('##sk_ability_tabs') then
        if imgui.BeginTabItem('AAs') then
            drawInScrollChild('##sk_aa_scroll', function() drawList(aas) end)
            imgui.EndTabItem()
        end
        if imgui.BeginTabItem('Disciplines') then
            drawInScrollChild('##sk_disc_scroll', function() drawDiscList(discs) end)
            imgui.EndTabItem()
        end
        imgui.EndTabBar()
    else
        drawInScrollChild('##sk_aa_scroll', function() drawList(aas) end)
    end
end

function M.drawEnabledBar(ctx)
    ctx = ctx or {}
    local abilities = ctx.abilities or {}
    local settings = ctx.settings or {}
    local helpers = ctx.helpers

    local enabled = M.collectEnabledAbilities(abilities, settings)
    if #enabled == 0 then
        imgui.Text('No enabled abilities.')
        return
    end

    local cell = tonumber(ctx.cell) or 110
    local gap = tonumber(ctx.gap) or 6
    local availX = getAvailX()
    local cols = math.max(1, math.floor((availX + gap) / (cell + gap)))

    for idx, def in ipairs(enabled) do
        imgui.PushID(def.settingKey)

        local label = tostring(def.altName or def.label or def.settingKey)
        local rem = 0
        if ctx.cooldownProbe then
            rem = select(1, ctx.cooldownProbe({ label = label, key = label })) or 0
        end

        local btnLabel = label .. '##fire'
        if imgui.Button(btnLabel, cell, 0) then
            if ctx.onActivate then ctx.onActivate(def) end
        end

        if rem and rem > 0 and helpers and helpers.fmtCooldown then
            imgui.SameLine()
            imgui.TextDisabled(helpers.fmtCooldown(rem))
        end

        if (idx % cols) ~= 0 then
            imgui.SameLine()
        end

        imgui.PopID()
    end
end

return M
