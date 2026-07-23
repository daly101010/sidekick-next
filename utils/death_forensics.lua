-- utils/death_forensics.lua
-- Death Forensics - the combat "black box". Keeps a rolling window of what was
-- happening to the group, and when anyone dies, writes a report answering "why":
--   * incoming damage timeline by source (fed by healing/damage_parser)
--   * the deceased's HP trajectory
--   * every cast I completed (and its result) in the window
--   * group vitals at time of death
--   * what was engaged (with mob assessor difficulty + mob intel casts)
--
-- Reports land in SideKick/logs/deaths/, one file per death.

local mq = require('mq')
local lazy = require('sidekick-next.utils.lazy_require')

local M = {}

-- Rolling window length (ms) and entry cap
local WINDOW_MS = 30000
local MAX_EVENTS = 800

-- Event ring buffer: { t, kind = 'dmg'|'cast', ... }
local _events = {}

-- HP snapshots per member: name -> { {t, hp, mana}, ... }
local _vitals = {}

-- Members we consider alive (for death edge detection): name -> true
local _wasAlive = {}

-- Per-member report cooldown (avoid duplicate reports for one death)
local _lastReport = {}  -- name -> time
local REPORT_COOLDOWN_MS = 15000

local _lastSample = 0
local SAMPLE_INTERVAL_MS = 1000

local _initialized = false

local getPaths = lazy('sidekick-next.utils.paths')
local getCore = lazy('sidekick-next.utils.core')
local getDamageParser = lazy('sidekick-next.healing.damage_parser')
local getMobAssessor = lazy('sidekick-next.healing.mob_assessor')
local getMobIntel = lazy('sidekick-next.utils.mob_intel')
local getSpellEvents = lazy('sidekick-next.utils.spell_events')

local function enabled()
    local Core = getCore()
    local v = Core and Core.Settings and Core.Settings.DeathForensicsEnabled
    return v ~= false
end

local function pushEvent(ev)
    ev.t = mq.gettime()
    table.insert(_events, ev)
    if #_events > MAX_EVENTS then
        table.remove(_events, 1)
    end
end

local function pruneOld()
    local cutoff = mq.gettime() - WINDOW_MS
    while #_events > 0 and _events[1].t < cutoff do
        table.remove(_events, 1)
    end
    for name, samples in pairs(_vitals) do
        while #samples > 0 and samples[1].t < cutoff do
            table.remove(samples, 1)
        end
        if #samples == 0 then _vitals[name] = nil end
    end
end

-------------------------------------------------------------------------------
-- Feeds
-------------------------------------------------------------------------------

--- Incoming damage observation (from damage_parser listener)
function M.onIncomingDamage(targetId, targetName, amount, source, dmgType)
    if not enabled() then return end
    pushEvent({
        kind = 'dmg',
        target = targetName,
        amount = tonumber(amount) or 0,
        source = tostring(source or '?'),
        dmgType = tostring(dmgType or '?'),
    })
end

--- My cast completions (chained from SpellEngine.onCastComplete)
function M.onCastComplete(castData, result)
    if not enabled() then return end
    if not castData then return end
    local SpellEvents = getSpellEvents()
    local resultName = (SpellEvents and SpellEvents.getResultName and SpellEvents.getResultName(result))
        or tostring(result)
    local targetName = ''
    if castData.targetId and castData.targetId > 0 then
        local ok, name = pcall(function()
            local s = mq.TLO.Spawn(castData.targetId)
            return s and s() and s.CleanName() or ''
        end)
        targetName = ok and name or ''
    end
    pushEvent({
        kind = 'cast',
        spell = tostring(castData.spellName or '?'),
        category = tostring(castData.spellCategory or '?'),
        result = resultName,
        target = targetName,
    })
end

-- Sample group vitals and detect deaths
local function forEachMember(fn)
    -- Self first
    local me = mq.TLO.Me
    if me and me() then
        fn(me.CleanName() or 'Me', {
            hp = tonumber(me.PctHPs()) or 0,
            mana = tonumber(me.PctMana()) or 0,
            dead = (me.Hovering and me.Hovering()) == true,
            class = me.Class and me.Class.ShortName and me.Class.ShortName() or '',
        })
    end

    local count = tonumber(mq.TLO.Group.Members()) or 0
    for i = 1, count do
        local member = mq.TLO.Group.Member(i)
        if member and member() then
            local ok, data = pcall(function()
                local spawn = member
                if member.Spawn and member.Spawn() then spawn = member.Spawn() end
                local name = (spawn.CleanName and spawn.CleanName()) or member.Name() or ''
                local dead = false
                if member.Dead and member.Dead() then dead = true end
                local hp = tonumber(member.PctHPs and member.PctHPs() or nil) or 0
                if hp <= 0 then dead = dead or hp == 0 end
                return {
                    name = name,
                    hp = hp,
                    mana = tonumber(member.PctMana and member.PctMana() or nil) or 0,
                    dead = dead,
                    class = (member.Class and member.Class.ShortName and member.Class.ShortName()) or '',
                }
            end)
            if ok and data and data.name ~= '' then
                fn(data.name, data)
            end
        end
    end
end

-------------------------------------------------------------------------------
-- Report generation
-------------------------------------------------------------------------------

local function fmtAgo(now, t)
    return string.format('t-%.1fs', (now - t) / 1000)
end

local function buildReport(deadName, deadInfo)
    local now = mq.gettime()
    local lines = {}
    local function add(fmt, ...)
        table.insert(lines, select('#', ...) > 0 and string.format(fmt, ...) or fmt)
    end

    local zone = tostring(mq.TLO.Zone.ShortName() or '?')
    add('=== Death Report: %s (%s) - %s [%s] ===', deadName,
        deadInfo and deadInfo.class or '?', os.date('%Y-%m-%d %H:%M:%S'), zone)
    add('')

    -- HP trajectory of the deceased
    local samples = _vitals[deadName] or {}
    if #samples > 0 then
        local traj = {}
        for _, s in ipairs(samples) do
            table.insert(traj, string.format('%d', s.hp))
        end
        add('HP trajectory (last %ds, 1/sec): %s -> DEAD', WINDOW_MS / 1000, table.concat(traj, ' '))
        add('')
    end

    -- Damage to the deceased: timeline + totals by source
    local totals = {}
    local hits = 0
    local biggest = { amount = 0 }
    add('Incoming damage to %s:', deadName)
    for _, ev in ipairs(_events) do
        if ev.kind == 'dmg' and ev.target == deadName then
            hits = hits + 1
            add('  %s  %s -> %d (%s)', fmtAgo(now, ev.t), ev.source, ev.amount, ev.dmgType)
            local tsrc = totals[ev.source] or { amount = 0, hits = 0 }
            tsrc.amount = tsrc.amount + ev.amount
            tsrc.hits = tsrc.hits + 1
            totals[ev.source] = tsrc
            if ev.amount > biggest.amount then
                biggest = { amount = ev.amount, source = ev.source }
            end
        end
    end
    if hits == 0 then
        add('  (none recorded - death may have been out of parser range or from an untracked source)')
    end
    add('')

    local totalDamage = 0
    if hits > 0 then
        add('Totals by source:')
        for source, t in pairs(totals) do
            totalDamage = totalDamage + t.amount
            add('  %-30s %8d over %d hits', source, t.amount, t.hits)
        end
        add('  TOTAL: %d', totalDamage)
        add('')
    end

    -- My casts during the window
    add('My casts (last %ds):', WINDOW_MS / 1000)
    local castCount = 0
    for _, ev in ipairs(_events) do
        if ev.kind == 'cast' then
            castCount = castCount + 1
            local tgt = ev.target ~= '' and (' -> ' .. ev.target) or ''
            add('  %s  %s [%s]%s = %s', fmtAgo(now, ev.t), ev.spell, ev.category, tgt, ev.result)
        end
    end
    if castCount == 0 then add('  (none)') end
    add('')

    -- Group vitals at death
    add('Group at time of death:')
    for name, samplesN in pairs(_vitals) do
        local last = samplesN[#samplesN]
        if last then
            add('  %-20s HP %3d%%  Mana %3d%%', name, last.hp, last.mana)
        end
    end
    add('')

    -- Engaged mobs with intel
    add('Engaged mobs:')
    local ma = getMobAssessor()
    local mi = getMobIntel()
    local xtCount = tonumber(mq.TLO.Me.XTarget()) or 0
    local mobLines = 0
    for i = 1, xtCount do
        local xt = mq.TLO.Me.XTarget(i)
        if xt and xt() and xt.ID() and xt.ID() > 0 then
            local name = (xt.CleanName and xt.CleanName()) or '?'
            local pct = tonumber(xt.PctHPs and xt.PctHPs() or nil) or 0
            local extra = {}
            if ma and ma.getMobMultiplier then
                local okM, mult, tier = pcall(ma.getMobMultiplier, xt.ID())
                if okM and mult and mult > 1.0 then
                    table.insert(extra, string.format('%s x%.1f', tostring(tier), mult))
                end
            end
            if mi and mi.getNpcCasts then
                local okC, casts = pcall(mi.getNpcCasts, name)
                if okC and casts then
                    local spells = {}
                    for spellName in pairs(casts) do table.insert(spells, spellName) end
                    if #spells > 0 then
                        table.sort(spells)
                        table.insert(extra, 'casts: ' .. table.concat(spells, ', '))
                    end
                end
            end
            add('  %s (%d%% hp)%s', name, pct, #extra > 0 and (' [' .. table.concat(extra, '; ') .. ']') or '')
            mobLines = mobLines + 1
        end
    end
    if mobLines == 0 then add('  (nothing on xtarget)') end

    return table.concat(lines, '\n'), totalDamage, biggest
end

local function reportDeath(name, info)
    local now = mq.gettime()
    if _lastReport[name] and (now - _lastReport[name]) < REPORT_COOLDOWN_MS then return end
    _lastReport[name] = now

    -- Feed the session death counter
    local okS, SessionStats = pcall(require, 'sidekick-next.utils.session_stats')
    if okS and SessionStats and SessionStats.recordDeath then
        pcall(SessionStats.recordDeath, name)
    end

    local report, totalDamage, biggest = buildReport(name, info)

    local Paths = getPaths()
    local dir = (Paths and Paths.getLogDir and Paths.getLogDir('deaths'))
        or (mq.configDir .. '/SideKick/logs/deaths')
    if Paths and Paths.ensureDir then Paths.ensureDir(dir) end
    local path = string.format('%s/death_%s_%s.txt', dir, name, os.date('%Y%m%d_%H%M%S'))

    local safeWrite = require('sidekick-next.utils.safe_write')
    local ok = safeWrite(path, report)

    if biggest.amount > 0 then
        print(string.format('\ar[Deaths]\ax %s died - %d damage in the last %ds (biggest hit %d from %s). %s',
            name, totalDamage, WINDOW_MS / 1000, biggest.amount, tostring(biggest.source),
            ok and ('Report: ' .. path) or 'Report write failed'))
    else
        print(string.format('\ar[Deaths]\ax %s died. %s',
            name, ok and ('Report: ' .. path) or 'Report write failed'))
    end
end

-------------------------------------------------------------------------------
-- Tick / lifecycle
-------------------------------------------------------------------------------

function M.tick()
    if not enabled() then return end

    local now = mq.gettime()
    if (now - _lastSample) < SAMPLE_INTERVAL_MS then return end
    _lastSample = now

    forEachMember(function(name, data)
        -- Record vitals
        local samples = _vitals[name]
        if not samples then
            samples = {}
            _vitals[name] = samples
        end
        table.insert(samples, { t = now, hp = data.hp, mana = data.mana })

        -- Death edge detection
        if data.dead then
            if _wasAlive[name] then
                _wasAlive[name] = nil
                reportDeath(name, data)
            end
        elseif data.hp > 0 then
            _wasAlive[name] = true
        end
    end)

    pruneOld()
end

function M.init()
    if _initialized then return end
    _initialized = true

    -- Incoming damage feed (available once the healing module loads the parser)
    local dp = getDamageParser()
    if dp and dp.addListener then
        dp.addListener(function(targetId, targetName, amount, source, dmgType)
            M.onIncomingDamage(targetId, targetName, amount, source, dmgType)
        end)
    end

    -- My cast completions
    local ok, SpellEngine = pcall(require, 'sidekick-next.utils.spell_engine')
    if ok and SpellEngine then
        local prev = SpellEngine.onCastComplete
        SpellEngine.onCastComplete = function(castData, result)
            if prev then pcall(prev, castData, result) end
            M.onCastComplete(castData, result)
        end
    end
end

return M
