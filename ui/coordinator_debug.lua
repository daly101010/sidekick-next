-- F:/lua/sidekick-next/ui/coordinator_debug.lua
-- Coordinator state popout for SideKick multi-script system

local mq = require('mq')
local imgui = require('ImGui')
local actors = require('actors')
local lib = require('sidekick-next.sk_lib')
local lazy = require('sidekick-next.utils.lazy_require')

local M = {}

M.open = false
M._showWindow = false
M._initialized = false
M._stateDropbox = nil

local State = {
    last = nil,
    receivedAtMs = 0,
}

-- Lazy-load healing module
local getHealing = lazy.once('sidekick-next.healing')

-- Get spell availability info
local function getSpellAvailability(spellName)
    if not spellName or spellName == '' then return nil end
    local me = mq.TLO.Me
    if not me or not me() then return nil end

    local spell = mq.TLO.Spell(spellName)
    if not spell or not spell() then return nil end

    local info = {
        name = spellName,
        memorized = false,
        ready = false,
        manaOk = false,
        manaCost = 0,
        castTimeMs = 0,
    }

    -- Check if memorized (in any gem slot)
    for i = 1, 13 do
        local gem = me.Gem(i)
        if gem and gem() and gem.Name and gem.Name() == spellName then
            info.memorized = true
            break
        end
    end

    -- Check mana
    info.manaCost = tonumber(spell.Mana()) or 0
    local currentMana = tonumber(me.CurrentMana()) or 0
    info.manaOk = currentMana >= info.manaCost

    -- Check if ready (memorized + not on cooldown)
    if info.memorized then
        local ready = me.SpellReady(spellName)
        info.ready = ready and ready() == true
    end

    -- Get cast time
    ---@diagnostic disable-next-line: undefined-field
    local mySpell = me.Spell and me.Spell(spellName)
    if mySpell and mySpell() then
        info.castTimeMs = tonumber(mySpell.MyCastTime()) or tonumber(spell.CastTime()) or 0
    else
        info.castTimeMs = tonumber(spell.CastTime()) or 0
    end

    return info
end

-- Get all heals with their availability
local function getHealAvailability()
    local healing = getHealing()
    if not healing or not healing.Config then return nil end

    local config = healing.Config
    if not config.spells then return nil end

    local categories = { 'fast', 'small', 'medium', 'large', 'group', 'hot', 'hotLight', 'groupHot', 'promised' }
    local result = {}

    for _, cat in ipairs(categories) do
        local spells = config.spells[cat]
        if spells and #spells > 0 then
            result[cat] = {}
            for _, spellName in ipairs(spells) do
                local avail = getSpellAvailability(spellName)
                if avail then
                    table.insert(result[cat], avail)
                end
            end
        end
    end

    return result
end

local priorityNames = {
    [lib.Priority.EMERGENCY] = 'Emergency',
    [lib.Priority.HEALING] = 'Healing',
    [lib.Priority.RESURRECTION] = 'Resurrection',
    [lib.Priority.DEBUFF] = 'Debuff',
    [lib.Priority.DPS] = 'DPS',
    [lib.Priority.IDLE] = 'Idle',
    [lib.Priority.BUFF] = 'Buff',
    [lib.Priority.MEDITATION] = 'Meditation',
}

local function formatBool(v)
    if v == true then return 'true' end
    if v == false then return 'false' end
    return 'nil'
end

local function formatValue(v)
    if v == nil then return 'nil' end
    if type(v) == 'boolean' then return formatBool(v) end
    if type(v) == 'number' then return string.format('%.2f', v) end
    if type(v) == 'string' then return v end
    return tostring(v)
end

local function renderRow(label, value)
    imgui.TableNextRow()
    imgui.TableNextColumn()
    imgui.Text(label)
    imgui.TableNextColumn()
    imgui.Text(value)
end

local function renderTable(tableId, rows)
    local flags = 0
    if ImGuiTableFlags and bit32 and bit32.bor then
        flags = bit32.bor(
            ImGuiTableFlags.Borders,
            ImGuiTableFlags.RowBg,
            ImGuiTableFlags.Resizable
        )
    end
    if imgui.BeginTable(tableId, 2, flags) then
        imgui.TableSetupColumn('Key', ImGuiTableColumnFlags.WidthFixed, 140)
        imgui.TableSetupColumn('Value', ImGuiTableColumnFlags.WidthStretch)
        imgui.TableHeadersRow()
        for _, row in ipairs(rows) do
            renderRow(row[1], row[2])
        end
        imgui.EndTable()
    end
end

local function renderOwnerBlock(title, owner)
    imgui.Text(title)
    if not owner then
        imgui.SameLine()
        imgui.TextColored(0.6, 0.6, 0.6, 1, 'none')
        return
    end

    local rows = {
        { 'Module', tostring(owner.module or '?') },
        { 'Priority', tostring(priorityNames[owner.priority] or owner.priority or '?') },
        { 'Claim ID', tostring(owner.claimId or '?') },
        { 'TTL (ms)', tostring(owner.ttlMs or '?') },
    }
    renderTable('##' .. title .. '_owner', rows)

    local action = owner.action
    if action and type(action) == 'table' then
        if imgui.TreeNode(title .. '_action', 'Action') then
            local arows = {
                { 'Kind', tostring(action.kind or '?') },
                { 'Name', tostring(action.name or action.spellName or '?') },
                { 'Target ID', tostring(action.targetId or '?') },
                { 'Reason', tostring(action.reason or '') },
            }
            renderTable('##' .. title .. '_action_table', arows)
            imgui.TreePop()
        end
    end
end

local categoryLabels = {
    fast = 'Fast/Quick',
    small = 'Small',
    medium = 'Medium',
    large = 'Large',
    group = 'Group',
    hot = 'HoT',
    hotLight = 'Light HoT',
    groupHot = 'Group HoT',
    promised = 'Promised',
}

-------------------------------------------------------------------------------
-- Module Diagnostics
-------------------------------------------------------------------------------

local function renderModuleDiagnostics(moduleDiag)
    if not moduleDiag or type(moduleDiag) ~= 'table' then
        imgui.TextColored(0.6, 0.6, 0.6, 1, 'No module data in state broadcast')
        return
    end

    -- Count modules
    local moduleCount = 0
    for _ in pairs(moduleDiag) do moduleCount = moduleCount + 1 end

    if moduleCount == 0 then
        imgui.TextColored(0.6, 0.6, 0.6, 1, 'No modules registered')
        return
    end

    -- Sort modules by priority for display
    local sorted = {}
    for name, diag in pairs(moduleDiag) do
        table.insert(sorted, { name = name, diag = diag })
    end
    table.sort(sorted, function(a, b)
        local pa = a.diag.needPriority or 999
        local pb = b.diag.needPriority or 999
        if pa ~= pb then return pa < pb end
        return a.name < b.name
    end)

    local flags = 0
    if ImGuiTableFlags and bit32 and bit32.bor then
        flags = bit32.bor(
            ImGuiTableFlags.Borders,
            ImGuiTableFlags.RowBg,
            ImGuiTableFlags.Resizable
        )
    end

    if imgui.BeginTable('##module_diag', 6, flags) then
        imgui.TableSetupColumn('Module', ImGuiTableColumnFlags.WidthFixed, 130)
        imgui.TableSetupColumn('HB', ImGuiTableColumnFlags.WidthFixed, 55)
        imgui.TableSetupColumn('Needs', ImGuiTableColumnFlags.WidthFixed, 50)
        imgui.TableSetupColumn('Priority', ImGuiTableColumnFlags.WidthFixed, 70)
        imgui.TableSetupColumn('Age', ImGuiTableColumnFlags.WidthFixed, 60)
        imgui.TableSetupColumn('Reason', ImGuiTableColumnFlags.WidthStretch)
        imgui.TableHeadersRow()

        for _, entry in ipairs(sorted) do
            local name = entry.name
            local diag = entry.diag
            imgui.PushID(name)

            imgui.TableNextRow()

            -- Module name
            imgui.TableNextColumn()
            if diag.needValid then
                imgui.TextColored(0.3, 1.0, 0.3, 1, name)  -- Green = active need
            elseif diag.ready then
                imgui.Text(name)  -- White = alive, no need
            else
                imgui.TextColored(0.6, 0.6, 0.6, 1, name)  -- Gray = not ready
            end

            -- Heartbeat age
            imgui.TableNextColumn()
            local hbAge = diag.heartbeatAge or 0
            if hbAge < 500 then
                imgui.TextColored(0.3, 1.0, 0.3, 1, string.format('%dms', hbAge))
            elseif hbAge < 2000 then
                imgui.TextColored(1.0, 1.0, 0.3, 1, string.format('%dms', hbAge))
            else
                imgui.TextColored(1.0, 0.3, 0.3, 1, string.format('%.1fs', hbAge / 1000))
            end

            -- Needs action
            imgui.TableNextColumn()
            if diag.needValid then
                imgui.TextColored(0.3, 1.0, 0.3, 1, 'YES')
            elseif diag.needsAction then
                imgui.TextColored(1.0, 0.5, 0.3, 1, 'exp')  -- Sent need but expired
            else
                imgui.TextColored(0.6, 0.6, 0.6, 1, 'no')
            end

            -- Need priority
            imgui.TableNextColumn()
            if diag.needPriority then
                local pName = priorityNames[diag.needPriority] or tostring(diag.needPriority)
                imgui.Text(pName)
            else
                imgui.TextColored(0.6, 0.6, 0.6, 1, '-')
            end

            -- Need age
            imgui.TableNextColumn()
            if diag.needsAction or diag.needValid then
                local age = diag.needAge or 0
                local ttl = diag.needTtl or 250
                local pct = ttl > 0 and (age / ttl) or 0
                if pct < 0.5 then
                    imgui.Text(string.format('%d/%d', age, ttl))
                elseif pct < 1.0 then
                    imgui.TextColored(1.0, 1.0, 0.3, 1, string.format('%d/%d', age, ttl))
                else
                    imgui.TextColored(1.0, 0.3, 0.3, 1, string.format('%d/%d', age, ttl))
                end
            else
                imgui.TextColored(0.6, 0.6, 0.6, 1, '-')
            end

            -- Reason (diagnostic - why module does/doesn't need action)
            imgui.TableNextColumn()
            local reason = diag.reason
            if reason and reason ~= '' then
                -- Color code common reasons
                if reason == 'no_action' or reason == 'no_emergency' or reason == 'no_emergency_action' then
                    imgui.TextColored(0.6, 0.6, 0.6, 1, reason)
                elseif reason == 'heals_disabled' or reason == 'spells_disabled' or reason == 'not_clr' then
                    imgui.TextColored(1.0, 0.3, 0.3, 1, reason)  -- Red = config/class problem
                elseif reason == 'init_failed' or reason == 'no_settings' then
                    imgui.TextColored(1.0, 0.5, 0.3, 1, reason)  -- Orange = init problem
                elseif reason == 'owns_cast' or reason == 'action found' then
                    imgui.TextColored(0.3, 1.0, 0.3, 1, reason)  -- Green = working
                else
                    imgui.Text(reason)
                end
            else
                imgui.TextColored(0.6, 0.6, 0.6, 1, '-')
            end

            imgui.PopID()
        end

        imgui.EndTable()
    end
end

-------------------------------------------------------------------------------
-- Healing Decision Diagnostics
-------------------------------------------------------------------------------

-- Cache for healing decision to avoid calling every frame
local _healDiagCache = {
    lastCheckAt = 0,
    result = nil,
    reason = nil,
    emergencyResult = nil,
    emergencyReason = nil,
}

local function getHealingDecision()
    local now = mq.gettime()
    -- Refresh every 250ms
    if (now - _healDiagCache.lastCheckAt) < 250 then
        return _healDiagCache
    end
    _healDiagCache.lastCheckAt = now

    local healing = getHealing()
    if not healing then
        _healDiagCache.result = nil
        _healDiagCache.reason = 'module not loaded'
        _healDiagCache.emergencyResult = nil
        _healDiagCache.emergencyReason = 'module not loaded'
        return _healDiagCache
    end

    if not healing.isInitialized or not healing.isInitialized() then
        _healDiagCache.result = nil
        _healDiagCache.reason = 'not initialized'
        _healDiagCache.emergencyResult = nil
        _healDiagCache.emergencyReason = 'not initialized'
        return _healDiagCache
    end

    -- Check non-emergency heal decision
    local ok1, action1, reason1 = pcall(function()
        return healing.buildHealAction({
            excludeEmergency = true,
            ignoreSpellEngine = true,
            skipIfCasting = true,
        })
    end)
    if ok1 then
        _healDiagCache.result = action1
        _healDiagCache.reason = reason1 or (action1 and 'action found' or 'no action needed')
    else
        _healDiagCache.result = nil
        _healDiagCache.reason = 'error: ' .. tostring(action1)
    end

    -- Check emergency heal decision
    local ok2, action2, reason2 = pcall(function()
        return healing.buildHealAction({
            onlyEmergency = true,
            ignoreSpellEngine = true,
            skipIfCasting = true,
        })
    end)
    if ok2 then
        _healDiagCache.emergencyResult = action2
        _healDiagCache.emergencyReason = reason2 or (action2 and 'action found' or 'no emergency')
    else
        _healDiagCache.emergencyResult = nil
        _healDiagCache.emergencyReason = 'error: ' .. tostring(action2)
    end

    return _healDiagCache
end

local function renderHealingDecision()
    local diag = getHealingDecision()
    if not diag then
        imgui.TextColored(0.6, 0.6, 0.6, 1, 'No healing data')
        return
    end

    -- Emergency section
    imgui.Text('Emergency:')
    imgui.SameLine()
    if diag.emergencyResult then
        local a = diag.emergencyResult
        imgui.TextColored(1.0, 0.3, 0.3, 1, string.format('%s on %s (id:%s)',
            tostring(a.spellName or a.name or '?'),
            tostring(a.targetName or '?'),
            tostring(a.targetId or '?')))
    else
        imgui.TextColored(0.6, 0.6, 0.6, 1, tostring(diag.emergencyReason or 'none'))
    end

    -- Normal heal section
    imgui.Text('Heal:')
    imgui.SameLine()
    if diag.result then
        local a = diag.result
        imgui.TextColored(0.3, 1.0, 0.3, 1, string.format('%s on %s (id:%s) [%s]',
            tostring(a.spellName or a.name or '?'),
            tostring(a.targetName or '?'),
            tostring(a.targetId or '?'),
            tostring(a.tier or '?')))
    else
        imgui.TextColored(0.6, 0.6, 0.6, 1, tostring(diag.reason or 'none'))
    end

    -- Show details if action exists
    local action = diag.result or diag.emergencyResult
    if action and type(action) == 'table' then
        local flags = 0
        if ImGuiTableFlags and bit32 and bit32.bor then
            flags = bit32.bor(
                ImGuiTableFlags.Borders,
                ImGuiTableFlags.RowBg,
                ImGuiTableFlags.Resizable
            )
        end
        if imgui.BeginTable('##heal_decision_detail', 2, flags) then
            imgui.TableSetupColumn('Key', ImGuiTableColumnFlags.WidthFixed, 100)
            imgui.TableSetupColumn('Value', ImGuiTableColumnFlags.WidthStretch)
            imgui.TableHeadersRow()

            local details = {
                { 'Spell', tostring(action.spellName or action.name or '?') },
                { 'Target', string.format('%s (id:%s)', tostring(action.targetName or '?'), tostring(action.targetId or '?')) },
                { 'Tier', tostring(action.tier or '?') },
                { 'Reason', tostring(action.reason or '?') },
            }
            if action.expected then
                table.insert(details, { 'Expected Heal', tostring(action.expected) })
            end
            if action.isHoT then
                table.insert(details, { 'Is HoT', 'true' })
            end
            if action.details and type(action.details) == 'string' then
                table.insert(details, { 'Details', action.details })
            end

            for _, row in ipairs(details) do
                renderRow(row[1], row[2])
            end
            imgui.EndTable()
        end
    end
end

local function renderHealAvailability()
    local avail = getHealAvailability()
    if not avail then
        imgui.TextColored(0.6, 0.6, 0.6, 1, 'Healing module not loaded')
        return
    end

    local hasAny = false
    for _, spells in pairs(avail) do
        if #spells > 0 then
            hasAny = true
            break
        end
    end

    if not hasAny then
        imgui.TextColored(0.6, 0.6, 0.6, 1, 'No heals configured')
        return
    end

    local flags = 0
    if ImGuiTableFlags and bit32 and bit32.bor then
        flags = bit32.bor(
            ImGuiTableFlags.Borders,
            ImGuiTableFlags.RowBg,
            ImGuiTableFlags.Resizable
        )
    end

    local categoryOrder = { 'fast', 'small', 'medium', 'large', 'group', 'hot', 'hotLight', 'groupHot', 'promised' }

    for _, cat in ipairs(categoryOrder) do
        local spells = avail[cat]
        if spells and #spells > 0 then
            local label = categoryLabels[cat] or cat
            if imgui.TreeNode('heal_cat_' .. cat, label .. ' (' .. #spells .. ')') then
                if imgui.BeginTable('##heals_' .. cat, 4, flags) then
                    imgui.TableSetupColumn('Spell', ImGuiTableColumnFlags.WidthStretch)
                    imgui.TableSetupColumn('Ready', ImGuiTableColumnFlags.WidthFixed, 50)
                    imgui.TableSetupColumn('Mana', ImGuiTableColumnFlags.WidthFixed, 50)
                    imgui.TableSetupColumn('Cast', ImGuiTableColumnFlags.WidthFixed, 50)
                    imgui.TableHeadersRow()

                    for _, spell in ipairs(spells) do
                        imgui.TableNextRow()
                        imgui.TableNextColumn()

                        -- Spell name with color based on availability
                        if spell.ready and spell.manaOk then
                            imgui.TextColored(0.3, 1.0, 0.3, 1, spell.name)  -- Green = ready
                        elseif spell.memorized then
                            imgui.TextColored(1.0, 1.0, 0.3, 1, spell.name)  -- Yellow = memorized but not ready
                        else
                            imgui.TextColored(0.6, 0.6, 0.6, 1, spell.name)  -- Gray = not memorized
                        end

                        imgui.TableNextColumn()
                        if spell.ready then
                            imgui.TextColored(0.3, 1.0, 0.3, 1, 'Yes')
                        elseif spell.memorized then
                            imgui.TextColored(1.0, 0.5, 0.3, 1, 'CD')  -- On cooldown
                        else
                            imgui.TextColored(0.6, 0.6, 0.6, 1, 'No')
                        end

                        imgui.TableNextColumn()
                        if spell.manaOk then
                            imgui.Text(tostring(spell.manaCost))
                        else
                            imgui.TextColored(1.0, 0.3, 0.3, 1, tostring(spell.manaCost))  -- Red = not enough mana
                        end

                        imgui.TableNextColumn()
                        imgui.Text(string.format('%.1fs', spell.castTimeMs / 1000))
                    end

                    imgui.EndTable()
                end
                imgui.TreePop()
            end
        end
    end
end

function M.init()
    if M._initialized then return end
    M._initialized = true

    M._stateDropbox = actors.register(lib.Mailbox.STATE, function(message)
        local content = message()
        if type(content) ~= 'table' then return end
        if content.tickId and content.epoch then
            State.last = content
            State.receivedAtMs = mq.gettime()
        end
    end)
end

function M.render()
    if not M.open then return end

    M.open, M._showWindow = imgui.Begin('SideKick Coordinator', M.open)
    if M._showWindow then
        if not State.last then
            imgui.TextColored(0.7, 0.7, 0.7, 1, 'Waiting for coordinator state...')
        else
            local nowMs = mq.gettime()
            local sentAt = State.last.sentAtMs or State.receivedAtMs
            local ageMs = nowMs - (sentAt or nowMs)
            local ttlMs = State.last.ttlMs or 0
            local stale = ttlMs > 0 and ageMs > ttlMs

            local rows = {
                { 'Active Priority', tostring(priorityNames[State.last.activePriority] or State.last.activePriority or '?') },
                { 'Cast Busy', formatBool(State.last.castBusy) },
                { 'Epoch', tostring(State.last.epoch or '?') },
                { 'Tick ID', tostring(State.last.tickId or '?') },
                { 'Age (s)', string.format('%.2f', ageMs / 1000) },
                { 'Stale', formatBool(stale) },
            }

            renderTable('##coord_summary', rows)

            imgui.Spacing()
            imgui.Separator()

            renderOwnerBlock('Cast Owner', State.last.castOwner)
            imgui.Spacing()
            renderOwnerBlock('Target Owner', State.last.targetOwner)

            imgui.Spacing()
            imgui.Separator()

            imgui.Text('World State')
            local ws = State.last.worldState or {}
            local wrows = {
                { 'In Combat', formatBool(ws.inCombat) },
                { 'My HP %', tostring(ws.myHpPct or '?') },
                { 'My Mana %', tostring(ws.myManaPct or '?') },
                { 'Group Needs Healing', formatBool(ws.groupNeedsHealing) },
                { 'Emergency Active', formatBool(ws.emergencyActive) },
                { 'Dead Count', tostring(ws.deadCount or '?') },
                { 'Main Assist ID', tostring(ws.mainAssistId or '?') },
            }
            renderTable('##coord_world', wrows)

            imgui.Spacing()
            imgui.Separator()

            -- Module Status (always visible - key diagnostic)
            if imgui.CollapsingHeader('Module Status##modules') then
                renderModuleDiagnostics(State.last.moduleDiag)
            end

            imgui.Spacing()
            imgui.Separator()

            -- Healing Decision (what HI thinks we should do right now)
            if imgui.CollapsingHeader('Healing Decision##healdecision') then
                renderHealingDecision()
            end

            imgui.Spacing()
            imgui.Separator()

            if imgui.CollapsingHeader('Heals Available##healavail') then
                renderHealAvailability()
            end
        end
    end
    imgui.End()
end

function M.toggle()
    M.open = not M.open
end

function M.show()
    M.open = true
end

function M.hide()
    M.open = false
end

return M
