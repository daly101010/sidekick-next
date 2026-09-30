-- ma_healagent.lua — per-box publisher for the raid heal gap ledger (ma_healbrain on the MA's box).
-- Runs beside muleassist.mac on every box (launched by it with HealBrainOn=1). Every 250ms it ships
-- what this box knows - its own HP, mana, cast in flight and counters, its group's HP and positions,
-- the raid roster when it is the MA, its heal/cure lines and their readiness (1Hz) and the macro's
-- own decisions (/whynot, withheld group heals, unready cures, interrupts) - to the brain over actors.
-- Passive: it never casts and never writes a macro variable.
-- Design: F:\macros\muleassist\docs\superpowers\specs\2026-09-30-heal-coordinator-design.md
local mq = require('mq')
local actorsOk, actors = pcall(require, 'actors')
local imguiOk, imgui = pcall(require, 'ImGui')

local LOOP_MS = 250
local LINES_MS = 1000
local RAID_MS = 1000
local MACRO_GONE_EXIT_MS = 10000
local BRAIN_ADDR = { mailbox = 'heal_brain', script = 'sidekick-next/ma_healbrain' }
local AGENT_MAILBOX = 'heal_agent'

local function log(fmt, ...)
    print(string.format('\ag[HealAgent]\ax ' .. fmt, ...))
end

-- ---------------------------------------------------------------- macro access
local function macroRunning()
    local d = mq.TLO.Defined('HealStats')
    return d and d() == true
end

local function macroVar(name)
    local ok, v = pcall(function() return mq.TLO.Macro.Variable(name)() end)
    if not ok or v == nil then return nil end
    v = tostring(v)
    if v == 'NULL' then return nil end
    return v
end

local function macroInt(name)
    return tonumber(macroVar(name)) or 0
end

local function macroArray(name, max)
    local out = {}
    for i = 1, max do
        local v = macroVar(string.format('%s[%d]', name, i))
        if v == nil or v == '' then break end
        out[#out + 1] = v
    end
    return out
end

-- ---------------------------------------------------------------- TLO helpers
local function num(fn, default)
    local ok, v = pcall(fn)
    if ok then v = tonumber(v) end
    return v or default or 0
end

local function str(fn, default)
    local ok, v = pcall(fn)
    if ok and v ~= nil then return tostring(v) end
    return default or ''
end

local function bool(fn)
    local ok, v = pcall(fn)
    return ok and (v == true or v == 1 or v == 'TRUE')
end

local function split(s, sep)
    local out = {}
    for piece in string.gmatch(s or '', '([^' .. sep .. ']+)') do out[#out + 1] = piece end
    return out
end

local function trim(s) return (tostring(s or ''):gsub('^%s+', ''):gsub('%s+$', '')) end

-- ---------------------------------------------------------------- identity
local myName = str(function() return mq.TLO.Me.CleanName() end)
local myId = num(function() return mq.TLO.Me.ID() end)

local function groupKey()
    local rg = num(function() return mq.TLO.Raid.Member(myName).Group() end, 0)
    if rg > 0 then return 'raid:' .. rg end
    local leader = str(function() return mq.TLO.Group.Leader.CleanName() end)
    if leader ~= '' then return 'grp:' .. leader end
    return 'grp:' .. myName
end

local function amMainAssist()
    local ma = macroVar('MainAssist') or ''
    return ma:lower() == myName:lower()
end

-- ---------------------------------------------------------------- spell facts
local factsCache = {}   -- static per spell name: range, cast time, mana cost, kind
local function spellFacts(name)
    if factsCache[name] then return factsCache[name] end
    local f = { range = 0, castMs = 0, mana = 0, kind = 'other', aerange = 0 }
    local sp = mq.TLO.Spell(name)
    local aa = mq.TLO.Me.AltAbility(name)
    local it = mq.TLO.FindItem('=' .. name)
    local src = nil
    if sp and sp() then src = sp
    elseif aa and aa() and aa.Spell and aa.Spell() then src = aa.Spell
    elseif it and it() and it.Spell and it.Spell() then src = it.Spell end
    if not src then return f end   -- unknown name: not cached, so a later scribe/memorize is picked up
    f.range = num(function() return src.MyRange() end, 0)
    f.aerange = num(function() return src.AERange() end, 0)
    f.castMs = num(function() return src.MyCastTime() end, 0)
    f.mana = num(function() return src.Mana() end, 0)
    local tt = str(function() return src.TargetType() end):lower()
    local sub = str(function() return src.Subcategory() end):lower()
    local st = str(function() return src.SpellType() end):lower()
    if tt:find('group') then f.kind = 'group'
    elseif st == 'detrimental' then f.kind = 'other'
    elseif sub:find('duration') then f.kind = 'hot'
    else f.kind = 'direct' end
    factsCache[name] = f
    return f
end

local function isReady(name)
    if bool(function() return mq.TLO.Me.SpellReady(name)() end) then return true end
    if bool(function() return mq.TLO.Me.AltAbilityReady(name)() end) then return true end
    if bool(function() return mq.TLO.Me.ItemReady(name)() end) then return true end
    return false
end

local CURE_TYPES = { 'poison', 'disease', 'curse', 'corruption' }

-- the macro's heal and cure lines with readiness; refreshed at 1Hz
local lineKinds = {}   -- [spellName] = 'direct'|'hot'|'group'|'cure'
local function buildLines()
    local mana = num(function() return mq.TLO.Me.CurrentMana() end)
    local out = { direct = {}, group = {}, cures = {} }
    lineKinds = {}
    for _, entry in ipairs(macroArray('SingleHeal', 40)) do
        local parts = split(entry, '|')
        local name, pct, tag = trim(parts[1]), tonumber(parts[2]) or 0, (parts[3] or ''):lower()
        if name ~= '' and pct > 0 and not tag:find('tap') and not tag:find('mob') then
            local f = spellFacts(name)
            if f.kind == 'direct' or f.kind == 'hot' then
                lineKinds[name] = f.kind
                out.direct[#out.direct + 1] = { name = name, pct = pct, range = f.range > 0 and f.range or 100,
                    castMs = f.castMs, ready = isReady(name), mana = f.mana <= mana, tag = tag, hot = f.kind == 'hot' }
            end
        end
    end
    for _, entry in ipairs(macroArray('GroupHeal', 10)) do
        local parts = split(entry, '|')
        local name, pct = trim(parts[1]), tonumber(parts[2]) or 0
        if name ~= '' and pct > 0 then
            local f = spellFacts(name)
            lineKinds[name] = 'group'
            out.group[#out.group + 1] = { name = name, pct = pct, range = f.aerange > 0 and f.aerange or 100,
                ready = isReady(name), mana = f.mana <= mana }
        end
    end
    for _, entry in ipairs(macroArray('Cures', 10)) do
        local parts = split(entry, '|')
        local name = trim(parts[1])
        if name ~= '' then
            local types = {}
            for i = 2, #parts do
                for _, ty in ipairs(split(parts[i]:lower(), ',')) do
                    ty = trim(ty)
                    for _, known in ipairs(CURE_TYPES) do if ty == known then types[known] = true end end
                end
            end
            local f = spellFacts(name)
            lineKinds[name] = 'cure'
            out.cures[#out.cures + 1] = { name = name, types = types, range = f.range > 0 and f.range or 100, ready = isReady(name) }
        end
    end
    return out
end

-- ---------------------------------------------------------------- /healreport counters (1Hz)
local STAT_INTS = {
    single = 'HSSingle', tank = 'HSTank', groupT = 'HSGroupT', self = 'HSSelf', pet = 'HSPet', oog = 'HSOOG',
    tap = 'HSTap', mob = 'HSMob', intHeal = 'HSIntHeal', intTap = 'HSIntTap', intMob = 'HSIntMob', intNPC = 'HSIntNPC',
    dpsCut = 'HSDPSCut', fail = 'HSFail', group = 'HSGroup', groupRange = 'HSGroupRange', smart = 'HSSmart',
    smartFail = 'HSSmartFail', cure = 'HSCure', cureGroup = 'HSCureGroup', cureHeld = 'HSCureHeld',
    cureUnready = 'HSCureUnready', skip = 'HSSkip', lowPct = 'HSLowPct', tankLow = 'HSTankLow', fights = 'HSFights',
}
local function buildStats()
    local st = {}
    for key, var in pairs(STAT_INTS) do st[key] = macroInt(var) end
    st.failLast = macroVar('HSFailLast')
    st.lowName = macroVar('HSLowName')
    st.line = macroVar('HealStats')
    local runTime = num(function() return mq.TLO.Macro.RunTime() end, 0)
    st.sinceSec = math.max(0, runTime - macroInt('HSSince'))
    return st
end

-- ---------------------------------------------------------------- counters
local function myCounters()
    local c = {
        p = num(function() return mq.TLO.Me.CountersPoison() end, -1),
        d = num(function() return mq.TLO.Me.CountersDisease() end, -1),
        c = num(function() return mq.TLO.Me.CountersCurse() end, -1),
        co = num(function() return mq.TLO.Me.CountersCorruption() end, -1),
    }
    if c.p >= 0 and c.d >= 0 and c.c >= 0 and c.co >= 0 then return c end
    -- fall back to the macro's own line: N|poisonID|diseaseID|curseID|corruptionID (0 = clean)
    local md = split(macroVar('MyDebuffs') or '0', '|')
    return { p = (tonumber(md[2]) or 0) > 0 and 1 or 0, d = (tonumber(md[3]) or 0) > 0 and 1 or 0,
             c = (tonumber(md[4]) or 0) > 0 and 1 or 0, co = (tonumber(md[5]) or 0) > 0 and 1 or 0 }
end

-- ---------------------------------------------------------------- cast in flight
local castSeen = { spell = nil, startedAt = 0, targetId = 0, targetName = nil }
local function casting(nowMs)
    local spell = str(function() return mq.TLO.Me.Casting() end)
    if spell == '' then castSeen.spell = nil return nil end
    if castSeen.spell ~= spell then
        castSeen.spell = spell
        castSeen.startedAt = nowMs
        castSeen.targetId = num(function() return mq.TLO.Target.ID() end)
        castSeen.targetName = str(function() return mq.TLO.Target.CleanName() end)
    end
    local left = num(function() return mq.TLO.Me.CastTimeLeft() end)
    local kind = lineKinds[spell]
    if not kind then
        local f = spellFacts(spell)
        kind = f.kind
    end
    local tid = castSeen.targetId
    if kind == 'group' then tid = myId end
    return { spell = spell, targetId = tid, targetName = castSeen.targetName, landsAt = nowMs + left, startedAt = castSeen.startedAt, kind = kind }
end

-- ---------------------------------------------------------------- targets
local function spawnRecord(sp, name, group, isPet)
    if not sp or not sp() then return nil end
    local id = num(function() return sp.ID() end)
    if id <= 0 then return nil end
    local hp = num(function() return sp.PctHPs() end)
    -- a dead member's spawn stays type PC at 0 HP (the corpse is another spawn): Dead() or 0 HP
    return id, {
        name = name or str(function() return sp.CleanName() end),
        hp = hp,
        x = num(function() return sp.X() end), y = num(function() return sp.Y() end), z = num(function() return sp.Z() end),
        dead = bool(function() return sp.Dead() end) or hp <= 0,
        class = str(function() return sp.Class.ShortName() end),
        group = group, pet = isPet == true,
    }
end

local function buildTargets(gkey, withRaid)
    local out = {}
    local n = num(function() return mq.TLO.Group.Members() end)
    for i = 1, n do
        local m = mq.TLO.Group.Member(i)
        -- keyed by tostring(id): a sparse integer-keyed table is not a safe actors payload
        local id, rec = spawnRecord(m, nil, gkey, false)
        if id and id ~= myId then out[tostring(id)] = rec end
        local pid, prec = spawnRecord(m and m.Pet, nil, gkey, true)
        if pid then out[tostring(pid)] = prec end
    end
    if withRaid then
        local rn = num(function() return mq.TLO.Raid.Members() end)
        for i = 1, rn do
            local rm = mq.TLO.Raid.Member(i)
            -- only raiders with a spawn in this zone: no position means the brain cannot judge range
            local rid = num(function() return rm.Spawn.ID() end)
            if rid > 0 and rid ~= myId and not out[tostring(rid)] then
                local rg = num(function() return rm.Group() end)
                local id, rec = spawnRecord(rm.Spawn, str(function() return rm.Name() end), 'raid:' .. rg, false)
                if id then out[tostring(id)] = rec end
            end
        end
    end
    return out
end

-- ---------------------------------------------------------------- macro decisions -> events
local hs = { intHeal = 0, intTap = 0, intMob = 0, intNPC = 0, groupRange = 0, cureUnready = 0, whynotText = nil, seeded = false }
local lastCast = { spell = nil, targetId = 0, targetName = nil }
local INT_REASONS = {
    intHeal = 'target past the heal line', intTap = 'tap at full HP',
    intMob = 'nuke-heal with the tank recovered', intNPC = 'heal on an NPC',
}
local INT_VARS = { intHeal = 'HSIntHeal', intTap = 'HSIntTap', intMob = 'HSIntMob', intNPC = 'HSIntNPC' }

local function whynotTarget(text)
    -- "[HH:MM:SS] Where: What -> Who: Why (xN)"
    local who = text and text:match('%->%s*([^:]+):') or nil
    if not who then return nil, nil end
    who = trim(who)
    local id = num(function() return mq.TLO.Spawn('=' .. who).ID() end)
    return id, who
end

local function collectEvents(nowMs, cast)
    local events = {}
    if cast then lastCast = { spell = cast.spell, targetId = cast.targetId, targetName = cast.targetName } end
    -- the macro's own interrupt counters (/healreport): each increment is one interrupt of the last cast
    for key, var in pairs(INT_VARS) do
        local n = macroInt(var)
        if hs.seeded and n > hs[key] then
            events[#events + 1] = { kind = 'interrupt', spell = lastCast.spell, targetId = lastCast.targetId,
                targetName = lastCast.targetName, reason = INT_REASONS[key], ts = nowMs }
        end
        hs[key] = n
    end
    local gr = macroInt('HSGroupRange')
    if hs.seeded and gr > hs.groupRange then
        events[#events + 1] = { kind = 'withheld', spell = 'group heal', targetId = 0, reason = 'withheld: 2+ hurt in the zone but nobody in the heal\'s range', ts = nowMs }
    end
    hs.groupRange = gr
    local cu = macroInt('HSCureUnready')
    if cu > hs.cureUnready and hs.seeded then
        events[#events + 1] = { kind = 'withheld', spell = macroVar('HSCureUnreadyLast') or 'cure', targetId = 0, reason = 'cure not ready (not memmed in combat, or on reuse)', ts = nowMs }
    end
    hs.cureUnready = cu
    local idx = macroInt('WhyNotIdx')
    local text = idx > 0 and macroVar(string.format('WhyNot[%d]', idx)) or nil
    if text and text ~= hs.whynotText and hs.seeded then
        -- "[HH:MM:SS] Where: What -> Who: Why (xN)": strip the stamp, the spell sits between the first ':' and '->'
        local tid, who = whynotTarget(text)
        local body = text:gsub('^%[[^%]]*%]%s*', '')
        local spell = body:match('^[^:]+:%s*(.-)%s*%->')
        events[#events + 1] = { kind = 'withheld', spell = (spell and spell ~= '') and spell or nil,
            targetId = tid or 0, targetName = who, reason = body, ts = nowMs }
    end
    hs.whynotText = text
    hs.seeded = true
    return events, text
end

-- ---------------------------------------------------------------- actors
local dropbox = nil
local brain = { name = nil, seenAt = 0 }
local sent, sendFails = 0, 0
local stats = nil          -- last buildStats(), drawn by the window
local UI = { show = false }

-- ---------------------------------------------------------------- own window: this box's HealStats
local function statRow(label, value)
    imgui.TableNextRow()
    imgui.TableNextColumn() imgui.Text(label)
    imgui.TableNextColumn() imgui.Text(tostring(value))
end

local function drawWindow()
    if not UI.show then return end
    imgui.SetNextWindowSize(420, 360, ImGuiCond.FirstUseEver)
    local open, show = imgui.Begin('Heal Stats - ' .. myName, UI.show)
    UI.show = open
    if show then
        local age = brain.seenAt > 0 and (mq.gettime() - brain.seenAt) or -1
        if age >= 0 and age < 3000 then
            imgui.TextColored(0.5, 1, 0.5, 1, string.format('brain %s (%.1fs)', tostring(brain.name), age / 1000))
        else
            imgui.TextColored(1, 0.6, 0.4, 1, 'no brain heard - rows are not being recorded')
        end
        local st = stats
        if not st then
            imgui.Text('waiting for the macro...')
        else
            imgui.Text(string.format('%d fights, %dm%02ds since reset', st.fights, math.floor(st.sinceSec / 60), st.sinceSec % 60))
            if imgui.BeginTable('healstats', 2, ImGuiTableFlags.RowBg + ImGuiTableFlags.Borders) then
                imgui.TableSetupColumn('', ImGuiTableColumnFlags.WidthFixed, 150)
                imgui.TableSetupColumn('', ImGuiTableColumnFlags.WidthStretch)
                statRow('Single heals', string.format('%d  (tank %d, group %d, self %d, pet %d, xtar %d)', st.single, st.tank, st.groupT, st.self, st.pet, st.oog))
                statRow('Taps / nuke-heals', string.format('%d / %d', st.tap, st.mob))
                statRow('Interrupted', string.format('%d  (past line %d, tap %d, nuke-heal %d, NPC %d)', st.intHeal + st.intTap + st.intMob + st.intNPC, st.intHeal, st.intTap, st.intMob, st.intNPC))
                statRow('Nukes cut for a heal', st.dpsCut)
                statRow('Failed casts', string.format('%d%s', st.fail, st.failLast and (' (last: ' .. st.failLast .. ')') or ''))
                statRow('Group heals', string.format('%d cast, %d withheld for range', st.group, st.groupRange))
                statRow('Smart heals', string.format('%d cast, %d failed', st.smart, st.smartFail))
                statRow('Cures', string.format('%d (%d group), held %d, not ready %d', st.cure, st.cureGroup, st.cureHeld, st.cureUnready))
                statRow('Skipped (/whynot)', st.skip)
                statRow('Lowest seen', string.format('tank %s, anyone %s', st.tankLow < 100 and (st.tankLow .. '%') or '-', st.lowPct < 100 and (tostring(st.lowName) .. ' ' .. st.lowPct .. '%') or '-'))
                imgui.EndTable()
            end
            if st.line and st.line ~= '' then imgui.TextWrapped(st.line) end
        end
        if imgui.Button('/healreport reset') then mq.cmd('/healreport reset') end
        imgui.SameLine()
        if imgui.Button('/healreport') then mq.cmd('/healreport') end
    end
    imgui.End()
end

if actorsOk and actors then
    local okReg, box = pcall(actors.register, AGENT_MAILBOX, function(message)
        -- non-yieldable: copy scalars only
        local ok, c = pcall(function() return message() end)
        if ok and type(c) == 'table' and c.kind == 'brain' then
            brain.name = tostring(c.from or '?')
            brain.seenAt = mq.gettime()
        end
    end)
    if okReg then dropbox = box else log('\aractors.register failed: %s', tostring(box)) end
else
    log('\aractors unavailable - exiting.')
    return
end

-- ---------------------------------------------------------------- startup
local waitUntil = mq.gettime() + 15000
while not macroRunning() and mq.gettime() < waitUntil do mq.delay(250) end
if not macroRunning() then
    log('\armuleassist.mac (with /healreport) is not running - exiting.')
    return
end
log('Agent running as %s (%dms).', myName, LOOP_MS)

local running = true
if imguiOk and imgui and mq.imgui and type(mq.imgui.init) == 'function' then
    mq.imgui.init('HealAgentStats', drawWindow)
    -- shown by default on a box that heals or cures; /healagent hide
    UI.show = (macroInt('HealsOn') > 0 or macroInt('CuresOn') > 0)
end
mq.bind('/healagent', function(cmd)
    cmd = tostring(cmd or ''):lower()
    if cmd == 'stop' then running = false return end
    if cmd == 'show' then UI.show = true return end
    if cmd == 'hide' then UI.show = false return end
    local age = brain.seenAt > 0 and (mq.gettime() - brain.seenAt) or -1
    log('sent %d (fails %d); brain %s %s', sent, sendFails, tostring(brain.name or 'none'),
        age >= 0 and string.format('seen %.1fs ago', age / 1000) or 'never seen')
end)

local seq = 0
local lastLinesAt, lastRaidAt = 0, 0
local lines, raidTargets = nil, nil
local macroGoneSince = nil

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
        myId = num(function() return mq.TLO.Me.ID() end, myId)
        local gkey = groupKey()
        local sendLines = (now - lastLinesAt) >= LINES_MS
        if sendLines then
            lines = buildLines()
            stats = buildStats()
            lastLinesAt = now
        end
        local isMA = amMainAssist()
        local cast = casting(now)
        local events, whynot = collectEvents(now, cast)
        local targets = buildTargets(gkey, isMA and (now - lastRaidAt) >= RAID_MS)
        if isMA and (now - lastRaidAt) >= RAID_MS then lastRaidAt = now end
        seq = seq + 1
        local snap = {
            v = 1, from = myName, id = myId, ts = now, seq = seq,
            zone = str(function() return mq.TLO.Zone.ShortName() end),
            me = {
                hp = num(function() return mq.TLO.Me.PctHPs() end), mana = num(function() return mq.TLO.Me.PctMana() end),
                dead = bool(function() return mq.TLO.Me.Dead() end) or num(function() return mq.TLO.Me.PctHPs() end) <= 0,
                stunned = bool(function() return mq.TLO.Me.Stunned() end), feigned = bool(function() return mq.TLO.Me.Feigning() end),
                x = num(function() return mq.TLO.Me.X() end), y = num(function() return mq.TLO.Me.Y() end), z = num(function() return mq.TLO.Me.Z() end),
                class = str(function() return mq.TLO.Me.Class.ShortName() end), group = gkey,
                inCombat = str(function() return mq.TLO.Me.CombatState() end) == 'COMBAT',
                casting = cast, counters = myCounters(),
            },
            lines = sendLines and lines or nil,
            stats = sendLines and stats or nil,
            targets = targets,
            macro = sendLines and {
                healLine = macroInt('SingleHealPoint'), tankLine = macroInt('SingleHealPointMA'),
                healTank = macroVar('HealTank'), healTankId = macroInt('HealTankID'),
                healsOn = macroInt('HealsOn'), curesOn = macroInt('CuresOn'), whynotLast = whynot,
                healPets = macroInt('HealGroupPetsOn') > 0,
                isMA = isMA, combat = macroInt('CombatStart') > 0,
            } or nil,
            events = events,
        }
        local ok, res = pcall(function() return dropbox:send(BRAIN_ADDR, snap) end)
        if ok and not (type(res) == 'number' and res < 0) then sent = sent + 1 else sendFails = sendFails + 1 end
    end
    mq.delay(LOOP_MS)
end
pcall(function() dropbox:unregister() end)
mq.unbind('/healagent')
log('Agent stopped.')
