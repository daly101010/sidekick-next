-- utils/session_stats.lua
-- Session Stats - XP/hour, kills/hour, per-member DPS, deaths, and casting
-- efficiency for the current play session, with a share-ready CSV export.
--
-- Feeds:
--  * damage_events (outgoing damage with attacker names) -> per-member damage
--  * kill messages ("You have slain X" / "X has been slain by Y")
--  * Me.PctExp/Level polling -> XP rate (level-ups handled)
--  * SpellEngine.onCastComplete -> casts, resists, mana spent
--  * death_forensics -> death counts (via recordDeath)

local mq = require('mq')
local lazy = require('sidekick-next.utils.lazy_require')

local M = {}

M.state = {
    startMs = 0,
    startLevel = 0,
    startXpPct = 0,
    xpPctGained = 0,   -- in percent-points (100 = one full level)
    lastLevel = 0,
    lastXpPct = 0,
    kills = 0,
    deaths = {},       -- name -> count
    deathTotal = 0,
    myManaSpent = 0,
    myCasts = 0,
    myResists = 0,
    myDamage = 0,
    members = {},      -- name -> { damage, activeSec, lastBucket }
}

local _lastXpPoll = 0
local XP_POLL_MS = 2000
local _initialized = false

local getPaths = lazy('sidekick-next.utils.paths')
local getSpellEvents = lazy('sidekick-next.utils.spell_events')
local getDamageEvents = lazy('sidekick-next.utils.damage_events')
local getSpellDamage = lazy('sidekick-next.utils.spell_damage_tracker')

local function myName()
    local ok, name = pcall(function() return mq.TLO.Me.CleanName() end)
    return (ok and name) or 'Me'
end

-------------------------------------------------------------------------------
-- Feeds
-------------------------------------------------------------------------------

local function recordMemberDamage(attacker, amount)
    if not attacker or attacker == '' then return end
    local m = M.state.members[attacker]
    if not m then
        m = { damage = 0, activeSec = 0, lastBucket = -1 }
        M.state.members[attacker] = m
    end
    m.damage = m.damage + amount

    -- Active time = number of distinct seconds in which this member dealt damage,
    -- so DPS reflects fighting time rather than total session time
    local bucket = math.floor(mq.gettime() / 1000)
    if bucket ~= m.lastBucket then
        m.lastBucket = bucket
        m.activeSec = m.activeSec + 1
    end
end

local function onDamageEvent(event)
    local attacker = event.mine and myName() or event.attacker
    if attacker == '' then return end
    recordMemberDamage(attacker, event.amount)
    if event.mine then
        M.state.myDamage = M.state.myDamage + event.amount
    end
end

function M.recordKill()
    M.state.kills = M.state.kills + 1
end

--- Record a death (called by death_forensics)
function M.recordDeath(name)
    name = tostring(name or '?')
    M.state.deaths[name] = (M.state.deaths[name] or 0) + 1
    M.state.deathTotal = M.state.deathTotal + 1
end

function M.onCastComplete(castData, result)
    if not castData then return end
    local SpellEvents = getSpellEvents()
    local RESULT = SpellEvents and SpellEvents.RESULT or {}

    if result == RESULT.SUCCESS then
        M.state.myCasts = M.state.myCasts + 1
        local ok, mana = pcall(function()
            local s = mq.TLO.Spell(castData.spellName)
            return s and s() and tonumber(s.Mana()) or 0
        end)
        M.state.myManaSpent = M.state.myManaSpent + ((ok and mana) or 0)
    elseif result == RESULT.RESISTED then
        M.state.myResists = M.state.myResists + 1
    end
end

local function pollXp()
    local now = mq.gettime()
    if (now - _lastXpPoll) < XP_POLL_MS then return end
    _lastXpPoll = now

    local ok, level, pct = pcall(function()
        return tonumber(mq.TLO.Me.Level()), tonumber(mq.TLO.Me.PctExp())
    end)
    if not ok or not level or not pct then return end

    local s = M.state
    if s.lastLevel == 0 then
        s.lastLevel, s.lastXpPct = level, pct
        return
    end

    if level > s.lastLevel then
        -- Leveled: remainder of the old level plus progress into the new one
        s.xpPctGained = s.xpPctGained + (100 - s.lastXpPct) + pct
            + (level - s.lastLevel - 1) * 100
    elseif level == s.lastLevel and pct > s.lastXpPct then
        s.xpPctGained = s.xpPctGained + (pct - s.lastXpPct)
    end
    -- De-level/rez XP loss: don't subtract, just re-anchor
    s.lastLevel, s.lastXpPct = level, pct
end

-------------------------------------------------------------------------------
-- Reporting
-------------------------------------------------------------------------------

function M.getSummary()
    local s = M.state
    local elapsedSec = math.max(1, (mq.gettime() - s.startMs) / 1000)
    local hours = elapsedSec / 3600

    local members = {}
    for name, m in pairs(s.members) do
        table.insert(members, {
            name = name,
            damage = m.damage,
            dps = m.damage / math.max(1, m.activeSec),
            activeSec = m.activeSec,
        })
    end
    table.sort(members, function(a, b) return a.damage > b.damage end)

    return {
        elapsedSec = elapsedSec,
        kills = s.kills,
        killsPerHour = s.kills / hours,
        xpPctGained = s.xpPctGained,
        xpPctPerHour = s.xpPctGained / hours,
        deathTotal = s.deathTotal,
        deaths = s.deaths,
        myCasts = s.myCasts,
        myResists = s.myResists,
        myManaSpent = s.myManaSpent,
        myDamage = s.myDamage,
        damagePerMana = s.myManaSpent > 0 and (s.myDamage / s.myManaSpent) or 0,
        members = members,
    }
end

function M.printSummary()
    local sum = M.getSummary()
    local hrs = math.floor(sum.elapsedSec / 3600)
    local mins = math.floor((sum.elapsedSec % 3600) / 60)
    print(string.format('\ag[Session]\ax %dh%02dm | kills: %d (%.1f/hr) | xp: %.1f%% (%.1f%%/hr) | deaths: %d',
        hrs, mins, sum.kills, sum.killsPerHour, sum.xpPctGained, sum.xpPctPerHour, sum.deathTotal))
    print(string.format('\ag[Session]\ax my casts: %d (%d resisted) | mana spent: %d | dmg/mana: %.1f',
        sum.myCasts, sum.myResists, sum.myManaSpent, sum.damagePerMana))
    for i, m in ipairs(sum.members) do
        if i > 8 then break end
        print(string.format('\ag[Session]\ax   %-20s %10d dmg  %8.0f dps (%ds active)',
            m.name, m.damage, m.dps, m.activeSec))
    end
end

function M.exportCSV()
    local sum = M.getSummary()
    local lines = {
        'metric,value',
        string.format('session_seconds,%d', sum.elapsedSec),
        string.format('kills,%d', sum.kills),
        string.format('kills_per_hour,%.2f', sum.killsPerHour),
        string.format('xp_pct_gained,%.2f', sum.xpPctGained),
        string.format('xp_pct_per_hour,%.2f', sum.xpPctPerHour),
        string.format('deaths,%d', sum.deathTotal),
        string.format('my_casts,%d', sum.myCasts),
        string.format('my_resists,%d', sum.myResists),
        string.format('my_mana_spent,%d', sum.myManaSpent),
        string.format('my_damage,%d', sum.myDamage),
        string.format('damage_per_mana,%.2f', sum.damagePerMana),
        '',
        'member,damage,dps,active_seconds',
    }
    for _, m in ipairs(sum.members) do
        table.insert(lines, string.format('%s,%d,%.0f,%d', m.name, m.damage, m.dps, m.activeSec))
    end

    -- Per-spell damage stats (from the spell damage tracker)
    local SpellDamage = getSpellDamage()
    if SpellDamage and SpellDamage.load and not next(SpellDamage.data or {}) then
        pcall(SpellDamage.load)
    end
    if SpellDamage and SpellDamage.data and next(SpellDamage.data) then
        table.insert(lines, '')
        table.insert(lines, 'spell,typical_hit,max_hit,observations')
        local spells = {}
        for name in pairs(SpellDamage.data) do table.insert(spells, name) end
        table.sort(spells)
        for _, name in ipairs(spells) do
            local d = SpellDamage.data[name]
            table.insert(lines, string.format('"%s",%.0f,%d,%d',
                name:gsub('"', '""'), d.ema or 0, d.maxSeen or 0, d.count or 0))
        end
    end

    local Paths = getPaths()
    local dir = (Paths and Paths.getExportDir and Paths.getExportDir())
        or (mq.configDir .. '/SideKick/export')
    local path = string.format('%s/session_%s.csv', dir, os.date('%Y%m%d_%H%M%S'))

    local safeWrite = require('sidekick-next.utils.safe_write')
    local ok = safeWrite(path, table.concat(lines, '\n'))
    if ok then
        print(string.format('\ag[Session]\ax Exported %s', path))
        return path
    end
    print('\ar[Session]\ax Export failed')
    return nil
end

function M.reset()
    M.state = {
        startMs = mq.gettime(),
        startLevel = 0,
        startXpPct = 0,
        xpPctGained = 0,
        lastLevel = 0,
        lastXpPct = 0,
        kills = 0,
        deaths = {},
        deathTotal = 0,
        myManaSpent = 0,
        myCasts = 0,
        myResists = 0,
        myDamage = 0,
        members = {},
    }
    _lastXpPoll = 0
end

-------------------------------------------------------------------------------
-- Lifecycle
-------------------------------------------------------------------------------

function M.tick()
    pollXp()
end

function M.init()
    if _initialized then return end
    _initialized = true

    M.reset()

    -- Kill counting
    mq.event('sk_ss_slain1', "You have slain #1#!#*#", function()
        M.recordKill()
    end)
    mq.event('sk_ss_slain2', "#1# has been slain by #2#!#*#", function()
        M.recordKill()
    end)

    local coordinated = _G.SIDEKICK_NEXT_CONFIG
        and _G.SIDEKICK_NEXT_CONFIG.COORDINATED_MODE ~= false
    if coordinated then
        local ok, Actors = pcall(require, 'sidekick-next.utils.actors_coordinator')
        if ok and Actors and Actors.registerMessageCallback then
            Actors.registerMessageCallback('session:damage', function(content)
                for _, event in ipairs(type(content.events) == 'table' and content.events or {}) do
                    onDamageEvent(event)
                end
            end)
            -- Reuse the worker terminal-cast feed consumed by death forensics.
            Actors.registerMessageCallback('forensics:cast', function(content)
                M.onCastComplete(content.castData, content.result)
            end)
        end
    else
        -- Monolithic compatibility consumes local process feeds.
        local de = getDamageEvents()
        if de and de.addListener then
            de.addListener(onDamageEvent)
        end

        local ok, SpellEngine = pcall(require, 'sidekick-next.utils.spell_engine')
        if ok and SpellEngine then
            if SpellEngine.addCastCompleteListener then
                SpellEngine.addCastCompleteListener(M.onCastComplete)
            else
                local prev = SpellEngine.onCastComplete
                SpellEngine.onCastComplete = function(castData, result)
                    if prev then pcall(prev, castData, result) end
                    M.onCastComplete(castData, result)
                end
            end
        end
    end
end

function M.shutdown()
    mq.unevent('sk_ss_slain1')
    mq.unevent('sk_ss_slain2')
end

return M
