-- F:/lua/sidekick-next/ui/coordinator_debug.lua
-- Coordinator state popout for SideKick multi-script system

local mq = require('mq')
local imgui = require('ImGui')
local actors = require('actors')
local lib = require('sidekick-next.sk_lib')

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
local _Healing = nil
local function getHealing()
    if _Healing == nil then
        local ok, h = pcall(require, 'sidekick-next.healing')
        _Healing = ok and h or false
    end
    return _Healing or nil
end

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

            if imgui.CollapsingHeader('Heals Available') then
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
