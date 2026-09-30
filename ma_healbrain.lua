-- ma_healbrain.lua — the raid heal gap ledger. Runs on the MA's box (launched by muleassist with
-- HealBrainOn=1 when MainAssist is this character). Receives every box's ma_healagent snapshot over
-- actors, runs the gap detectors (utils/heal_ledger.lua) four times a second, writes every gap row
-- to config/HealingLogs/heal-ledger-YYYY-MM-DD.jsonl and shows them in the "Raid Heal Ledger" window.
-- Passive: it decides nothing and casts nothing. /healbrain for commands.
-- Design: F:\macros\muleassist\docs\superpowers\specs\2026-09-30-heal-coordinator-design.md
local mq = require('mq')
local imgui = require('ImGui')
local actorsOk, actors = pcall(require, 'actors')
local Ledger = require('sidekick-next.utils.heal_ledger')
local Store = require('sidekick-next.utils.heal_ledger_store')

local LOOP_MS = 250
local HEARTBEAT_MS = 1000
local MACRO_GONE_EXIT_MS = 60000  -- a macro restart keeps the night's rows
local BRAIN_MAILBOX = 'heal_brain'
local AGENT_ADDR = { mailbox = 'heal_agent', script = 'sidekick-next/ma_healagent' }
local MAX_QUEUE = 2000

local function log(fmt, ...)
    print(string.format('\ag[HealBrain]\ax ' .. fmt, ...))
end

local function macroRunning()
    local d = mq.TLO.Defined('HealStats')
    return d and d() == true
end

local function macroInt(name)
    local ok, v = pcall(function() return mq.TLO.Macro.Variable(name)() end)
    if not ok or v == nil then return 0 end
    return tonumber(tostring(v)) or 0
end

local myName = tostring(mq.TLO.Me.CleanName() or 'brain')

-- ---------------------------------------------------------------- state
local ledger = Ledger.newLedger()
local store = Store.new((mq.configDir or 'config') .. '/HealingLogs')
local queue, qHead, qCount, qDropped = {}, 1, 0, 0
local otherBrains = {}      -- [name] = seenAt
local UI = {
    open = true, show = false, echo = false, paused = false,
    filterKinds = {}, filterText = '', selected = nil, tab = 'live',
    boxes = {}, boxesFresh = 0, boxesStale = 0, lastTickAt = 0,
}
for _, k in ipairs(Ledger.KINDS) do UI.filterKinds[k] = true end
local inCombat = false
local running = true

-- ---------------------------------------------------------------- actors
local dropbox = nil
if not (actorsOk and actors) then
    log('\aractors unavailable - exiting.')
    return
end
do
    local okReg, box = pcall(actors.register, BRAIN_MAILBOX, function(message)
        -- non-yieldable: queue the table, the loop ingests it
        local ok, c = pcall(function() return message() end)
        if not ok or type(c) ~= 'table' then return end
        if qCount >= MAX_QUEUE then qDropped = qDropped + 1 return end
        queue[qHead + qCount] = c
        qCount = qCount + 1
    end)
    if not okReg then
        log('\aractors.register failed: %s', tostring(box))
        return
    end
    dropbox = box
end

local function heartbeat()
    pcall(function()
        dropbox:send(AGENT_ADDR, { kind = 'brain', from = myName, ts = mq.gettime() })
        -- another brain hears this too and reports itself
        dropbox:send({ mailbox = BRAIN_MAILBOX, script = 'sidekick-next/ma_healbrain' }, { kind = 'brain', from = myName, ts = mq.gettime() })
    end)
end

-- ---------------------------------------------------------------- rows out
local function emit(row)
    Store.write(store, { type = 'gap', brain = myName, row = row })
    if UI.echo then
        print(string.format('\ay[HealLedger]\ax %s', Ledger.formatRow(row)))
    end
end

local function fightStart(now)
    Ledger.fightStart(ledger, now)
    Store.write(store, { type = 'fight_start', brain = myName, n = ledger.fight.n, at = now, clock = os.date('%H:%M:%S') })
end

local function fightEnd(now)
    local f = Ledger.fightEnd(ledger, now)
    if f then
        Store.write(store, { type = 'fight_end', brain = myName, summary = f, clock = os.date('%H:%M:%S') })
        local kinds = {}
        for _, k in ipairs(Ledger.KINDS) do if (f.byKind[k] or 0) > 0 then kinds[#kinds + 1] = k .. ' ' .. f.byKind[k] end end
        log('fight %d over (%.0fs): %s', f.n, f.durationMs / 1000, #kinds > 0 and table.concat(kinds, ', ') or 'no gaps')
    end
end

local function report()
    for _, line in ipairs(Store.reportLines(ledger, Ledger)) do print('\ag[HealLedger]\ax ' .. line) end
    if store.path then print('\ag[HealLedger]\ax file: ' .. store.path) end
end

-- ---------------------------------------------------------------- window
local KIND_COLORS = {
    unhealed = { 1.0, 0.45, 0.45, 1 }, late = { 1.0, 0.75, 0.4, 1 }, duplicate = { 0.8, 0.6, 1.0, 1 },
    uncured = { 0.5, 1.0, 0.5, 1 }, missed_group = { 0.4, 0.8, 1.0, 1 }, interrupted_nothing = { 1.0, 0.9, 0.4, 1 },
    death = { 1.0, 0.2, 0.2, 1 }, withheld = { 0.8, 0.8, 0.8, 1 },
}

local function rowVisible(r)
    if not UI.filterKinds[r.kind] then return false end
    if UI.filterText ~= '' then
        local hay = (Ledger.formatRow(r)):lower()
        if not hay:find(UI.filterText:lower(), 1, true) then return false end
    end
    return true
end

local function drawCandidates(r)
    if r.candidates and #r.candidates > 0 then
        imgui.Text('Who could have acted:')
        for _, c in ipairs(r.candidates) do
            local bits = { c.box }
            if c.spell then bits[#bits + 1] = c.spell .. ' ready' end
            if c.dist then bits[#bits + 1] = c.dist .. 'u away' end
            if c.mana then bits[#bits + 1] = c.mana .. '% mana' end
            if c.casting then bits[#bits + 1] = 'casting ' .. c.casting end
            if c.whynot then bits[#bits + 1] = 'last /whynot: ' .. c.whynot end
            imgui.BulletText(table.concat(bits, '  |  '))
        end
    end
    if r.members then imgui.Text('Members under the line: ' .. table.concat(r.members, ', ')) end
    if r.history and #r.history > 0 then
        local hs = {}
        for _, s in ipairs(r.history) do hs[#hs + 1] = tostring(s[2]) .. '%' end
        imgui.Text('HP over the last seconds: ' .. table.concat(hs, ' '))
    end
    if r.reason then imgui.Text('Reason: ' .. tostring(r.reason)) end
end

local function drawLive()
    if imgui.Button('Reset') then Ledger.reset(ledger) UI.selected = nil end
    imgui.SameLine()
    if imgui.Button('Report to chat') then report() end
    imgui.SameLine()
    UI.echo = imgui.Checkbox('Echo rows to chat', UI.echo)
    imgui.SameLine()
    UI.paused = imgui.Checkbox('Pause', UI.paused)
    for i, k in ipairs(Ledger.KINDS) do
        if i > 1 then imgui.SameLine() end
        UI.filterKinds[k] = imgui.Checkbox(k, UI.filterKinds[k])
    end
    UI.filterText = imgui.InputText('filter', UI.filterText)
    imgui.Separator()
    if imgui.BeginTable('ledger_rows', 5, ImGuiTableFlags.RowBg + ImGuiTableFlags.Borders + ImGuiTableFlags.ScrollY, 0, 320) then
        imgui.TableSetupColumn('Time', ImGuiTableColumnFlags.WidthFixed, 90)
        imgui.TableSetupColumn('Gap', ImGuiTableColumnFlags.WidthFixed, 130)
        imgui.TableSetupColumn('For', ImGuiTableColumnFlags.WidthFixed, 60)
        imgui.TableSetupColumn('Target', ImGuiTableColumnFlags.WidthFixed, 110)
        imgui.TableSetupColumn('What happened', ImGuiTableColumnFlags.WidthStretch)
        imgui.TableHeadersRow()
        local shown = 0
        for i = #ledger.rows, 1, -1 do
            local r = ledger.rows[i]
            if rowVisible(r) then
                shown = shown + 1
                if shown > 300 then break end
                imgui.TableNextRow()
                imgui.TableNextColumn()
                local sel = UI.selected == r.id
                if imgui.Selectable(Ledger.clock(r.openedAt) .. '##' .. r.id, sel, ImGuiSelectableFlags.SpanAllColumns) then
                    UI.selected = sel and nil or r.id
                end
                imgui.TableNextColumn()
                local c = KIND_COLORS[r.kind] or { 1, 1, 1, 1 }
                imgui.TextColored(c[1], c[2], c[3], c[4], r.kind .. (r.closedAt and '' or ' (open)'))
                imgui.TableNextColumn()
                imgui.Text(r.durationMs and r.durationMs > 0 and string.format('%.1fs', r.durationMs / 1000) or '')
                imgui.TableNextColumn()
                imgui.Text(r.target and tostring(r.target.name) or (r.healer or ''))
                imgui.TableNextColumn()
                imgui.Text(r.detail or '')
            end
        end
        imgui.EndTable()
    end
    if UI.selected then
        local row = nil
        for _, r in ipairs(ledger.rows) do if r.id == UI.selected then row = r break end end
        if row then
            imgui.Separator()
            imgui.TextWrapped(Ledger.formatRow(row))
            drawCandidates(row)
            if imgui.Button('Print this row to chat') then print('\ay[HealLedger]\ax ' .. Ledger.formatRow(row)) end
        end
    end
end

local function drawSummary()
    local night = Ledger.nightSummary(ledger)
    imgui.Text(string.format('%d fights, %d gap rows%s', night.fights, night.rows, ledger.fight and (', fight ' .. ledger.fight.n .. ' in progress') or ''))
    if imgui.BeginTable('ledger_fights', 4, ImGuiTableFlags.RowBg + ImGuiTableFlags.Borders) then
        imgui.TableSetupColumn('Fight', ImGuiTableColumnFlags.WidthFixed, 50)
        imgui.TableSetupColumn('Length', ImGuiTableColumnFlags.WidthFixed, 60)
        imgui.TableSetupColumn('Gaps by kind', ImGuiTableColumnFlags.WidthStretch)
        imgui.TableSetupColumn('Healers (casting % / idle with a ready heal %)', ImGuiTableColumnFlags.WidthStretch)
        imgui.TableHeadersRow()
        for i = #ledger.fights, 1, -1 do
            local f = ledger.fights[i]
            imgui.TableNextRow()
            imgui.TableNextColumn() imgui.Text(tostring(f.n))
            imgui.TableNextColumn() imgui.Text(string.format('%.0fs', f.durationMs / 1000))
            imgui.TableNextColumn()
            local ks = {}
            for _, k in ipairs(Ledger.KINDS) do if (f.byKind[k] or 0) > 0 then ks[#ks + 1] = k .. ' ' .. f.byKind[k] end end
            imgui.Text(#ks > 0 and table.concat(ks, ', ') or 'clean')
            imgui.TableNextColumn()
            local hs = {}
            for name, h in pairs(f.healers) do hs[#hs + 1] = string.format('%s %d/%d', name, h.castingPct, h.idleReadyPct) end
            table.sort(hs)
            imgui.TextWrapped(table.concat(hs, '  '))
        end
        imgui.EndTable()
    end
    imgui.Separator()
    imgui.Text('Boxes reporting:')
    local names = {}
    for name in pairs(UI.boxes) do names[#names + 1] = name end
    table.sort(names)
    for _, name in ipairs(names) do
        local b = UI.boxes[name]
        local age = (mq.gettime() - b.at) / 1000
        if age > 1.0 then
            imgui.TextColored(1, 0.5, 0.5, 1, string.format('  %s  stale %.1fs', name, age))
        else
            imgui.Text(string.format('  %s  %s%s', name, b.role or '', b.casting and ('  casting ' .. b.casting) or ''))
        end
    end
end

local function drawWindow()
    if not UI.show then return end
    imgui.SetNextWindowSize(900, 520, ImGuiCond.FirstUseEver)
    local open, show = imgui.Begin('Raid Heal Ledger', UI.show)
    UI.show = open
    if show then
        local status = string.format('brain %s | %d boxes fresh, %d stale | %s | %s%s',
            myName, UI.boxesFresh, UI.boxesStale, inCombat and 'in combat' or 'out of combat',
            store.path and 'writing ' .. store.path or (store.failed and ('file: ' .. store.failed) or 'no file yet'),
            next(otherBrains) and '  \arANOTHER BRAIN IS RUNNING' or '')
        imgui.TextWrapped(status)
        if imgui.BeginTabBar('ledger_tabs') then
            if imgui.BeginTabItem('Live gaps') then drawLive() imgui.EndTabItem() end
            if imgui.BeginTabItem('Fights and boxes') then drawSummary() imgui.EndTabItem() end
            imgui.EndTabBar()
        end
    end
    imgui.End()
end

if mq.imgui and type(mq.imgui.init) == 'function' then
    mq.imgui.init('RaidHealLedger', drawWindow)
end

-- ---------------------------------------------------------------- commands
mq.bind('/healbrain', function(...)
    local args = { ... }
    local a = tostring(args[1] or ''):lower()
    local b = tostring(args[2] or ''):lower()
    if a == 'show' or a == 'on' then UI.show = true
    elseif a == 'hide' or a == 'off' then UI.show = false
    elseif a == 'report' then report()
    elseif a == 'reset' then Ledger.reset(ledger) UI.selected = nil log('ledger reset')
    elseif a == 'echo' then UI.echo = (b ~= 'off') log('echo %s', UI.echo and 'on' or 'off')
    elseif a == 'pause' then UI.paused = (b ~= 'off') log('%s', UI.paused and 'paused' or 'running')
    elseif a == 'set' then
        -- /healbrain set unhealedMs 2000 (any key of Ledger.DEFAULTS)
        local name, val = tostring(args[2] or ''), tonumber(args[3])
        if ledger.opts[name] ~= nil and val then
            ledger.opts[name] = val
            log('%s = %s', name, tostring(val))
        else
            local keys = {}
            for k in pairs(Ledger.DEFAULTS) do keys[#keys + 1] = k end
            table.sort(keys)
            log('unknown setting %s - one of: %s', name, table.concat(keys, ' '))
        end
    elseif a == 'stop' then running = false
    else
        log('/healbrain show|hide|report|reset|echo on|off|pause on|off|set <name> <ms>|stop  (window: %s, echo %s, %d rows, file %s)',
            UI.show and 'shown' or 'hidden', UI.echo and 'on' or 'off', #ledger.rows, tostring(store.path or 'none'))
    end
end)

-- ---------------------------------------------------------------- loop
log('Brain running as %s (%dms). /healbrain show for the window.', myName, LOOP_MS)
UI.show = true
local lastBeat, macroGoneSince = 0, nil

while running do
    mq.doevents()
    local now = mq.gettime()
    if not macroRunning() then
        macroGoneSince = macroGoneSince or now
        if (now - macroGoneSince) > MACRO_GONE_EXIT_MS then
            log('muleassist stopped - exiting.')
            break
        end
    else
        macroGoneSince = nil
    end
    -- ingest everything queued by the handler
    while qCount > 0 do
        local snap = queue[qHead]
        queue[qHead] = nil
        qHead = qHead + 1
        qCount = qCount - 1
        if snap.kind == 'brain' then
            if tostring(snap.from) ~= myName then otherBrains[tostring(snap.from)] = now end
        elseif not UI.paused then
            if Ledger.ingest(ledger, snap, now) then
                UI.boxes[snap.from] = { at = now, role = snap.macro and ((snap.macro.healsOn or 0) > 0 and 'healer' or ((snap.macro.curesOn or 0) > 0 and 'curer' or '')) or (UI.boxes[snap.from] and UI.boxes[snap.from].role),
                    casting = snap.me and snap.me.casting and snap.me.casting.spell or nil }
            end
        end
    end
    if qHead > 1000 then
        local nq = {}
        for i = 0, qCount - 1 do nq[i + 1] = queue[qHead + i] end
        queue, qHead = nq, 1
    end
    for name, at in pairs(otherBrains) do if (now - at) > 5000 then otherBrains[name] = nil end end
    -- fight boundaries: this box's macro when it runs, else its own combat state
    local combat
    if macroRunning() then combat = macroInt('CombatStart') > 0 or tostring(mq.TLO.Me.CombatState() or '') == 'COMBAT'
    else combat = tostring(mq.TLO.Me.CombatState() or '') == 'COMBAT' end
    if combat and not inCombat then fightStart(now) end
    if not combat and inCombat then fightEnd(now) end
    inCombat = combat
    if not UI.paused then
        local opened = Ledger.tick(ledger, now)
        for _, row in ipairs(opened) do emit(row) end
    end
    -- freshness for the header
    local fresh, stale = 0, 0
    for _, b in pairs(UI.boxes) do if (now - b.at) <= 1000 then fresh = fresh + 1 else stale = stale + 1 end end
    UI.boxesFresh, UI.boxesStale, UI.lastTickAt = fresh, stale, now
    if (now - lastBeat) >= HEARTBEAT_MS then
        heartbeat()
        lastBeat = now
    end
    mq.delay(LOOP_MS)
end
if inCombat then fightEnd(mq.gettime()) end
report()
Store.close(store)
pcall(function() dropbox:unregister() end)
mq.unbind('/healbrain')
log('Brain stopped.')
