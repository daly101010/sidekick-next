-- utils/resist_tracker.lua
-- Resist Tracker - Persistent per-zone learning of mob resist rates by element
--
-- The immune database only remembers hard immunities (binary). This tracker counts
-- landed vs resisted casts per mob name per resist type (fire/cold/poison/magic/
-- disease/...), so spell selection can steer away from elements a mob soft-resists
-- most of the time without being outright immune.
--
-- Feeding: spell_engine invokes onCastComplete when a damage cast finishes. A cast
-- that completes successfully becomes a pending attempt; if a resist message for
-- that spell arrives within the grace window the attempt counts as resisted,
-- otherwise it counts as landed. Casts that fail with RESISTED directly (detected
-- mid-cast) are counted immediately and create no pending attempt.

local mq = require('mq')
local lazy = require('sidekick-next.utils.lazy_require')

local M = {}

-- Full database (all zones): zone -> mobName -> element -> {landed, resisted}
M.database = {}

-- Current zone's stats (loaded into memory)
M.zoneStats = {}

-- Current zone name
M.currentZone = ''

-- Dirty flag for persistence
M.dirty = false

-- Pending attempts awaiting land/resist resolution
local _pending = {}  -- array of {spell, mob, element, expires (ms)}

-- How long after cast completion a resist message can still claim the attempt
local PENDING_GRACE_MS = 2000

-- Periodic save throttle
local _lastSave = 0
local SAVE_INTERVAL_MS = 30000

-- Spell categories this tracker cares about
local DAMAGE_CATEGORIES = {
    nuke = true, dot = true, damage = true, direct_damage = true,
}

local getPaths = lazy('sidekick-next.utils.paths')
local getSpellEvents = lazy('sidekick-next.utils.spell_events')

local function getDbPath()
    local Paths = getPaths()
    if Paths and Paths.getResistTrackerPath then
        return Paths.getResistTrackerPath()
    end
    return mq.configDir .. '/SideKick/data/resist_tracker.lua'
end

-------------------------------------------------------------------------------
-- Persistence (same shape as immune_database)
-------------------------------------------------------------------------------

function M.loadDatabase()
    M.currentZone = ''
    M.zoneStats = {}

    local file = io.open(getDbPath(), 'r')
    if not file then
        M.database = {}
        return
    end

    local content = file:read('*all')
    file:close()

    if content and content ~= '' then
        local fn = loadstring('return ' .. content)
        if fn then
            local ok, data = pcall(fn)
            if ok and type(data) == 'table' then
                M.database = data
                return
            end
        end
    end

    M.database = {}
end

function M.saveDatabase()
    if not M.dirty then return end

    local Paths = getPaths()
    if Paths then
        Paths.ensureDir(Paths.getDataDir())
    end

    local function escapeString(s)
        return s:gsub('\\', '\\\\'):gsub('"', '\\"'):gsub('\n', '\\n'):gsub('\r', '\\r')
    end

    local function serialize(tbl, indent)
        indent = indent or ''
        local lines = {}
        table.insert(lines, '{')
        for k, v in pairs(tbl) do
            local key = type(k) == 'string' and ('["' .. escapeString(k) .. '"]') or ('[' .. k .. ']')
            if type(v) == 'table' then
                table.insert(lines, indent .. '  ' .. key .. ' = ' .. serialize(v, indent .. '  ') .. ',')
            elseif type(v) == 'number' or type(v) == 'boolean' then
                table.insert(lines, indent .. '  ' .. key .. ' = ' .. tostring(v) .. ',')
            else
                table.insert(lines, indent .. '  ' .. key .. ' = "' .. escapeString(tostring(v)) .. '",')
            end
        end
        table.insert(lines, indent .. '}')
        return table.concat(lines, '\n')
    end

    local safeWrite = require('sidekick-next.utils.safe_write')
    local ok, err = safeWrite(getDbPath(), serialize(M.database))
    if not ok then
        print(string.format('\ar[ResistTracker]\ax Failed to save: %s', tostring(err)))
        return
    end
    M.dirty = false
end

--- Load current zone's stats into memory (call on zone change)
function M.loadZone()
    local zone = mq.TLO.Zone.ShortName() or ''
    if zone == M.currentZone then return end

    -- Save learning from the previous zone before switching
    M.saveDatabase()
    M.currentZone = zone
    M.zoneStats = M.database[zone] or {}
    _pending = {}
end

-------------------------------------------------------------------------------
-- Recording
-------------------------------------------------------------------------------

local function getStats(mobName, element, create)
    if not mobName or mobName == '' then return nil end
    if not element or element == '' then return nil end
    element = element:lower()

    local zone = M.currentZone
    if zone == '' then return nil end

    if create then
        if not M.database[zone] then M.database[zone] = {} end
        if not M.database[zone][mobName] then M.database[zone][mobName] = {} end
        if not M.database[zone][mobName][element] then
            M.database[zone][mobName][element] = { landed = 0, resisted = 0 }
        end
        M.zoneStats = M.database[zone]
        return M.database[zone][mobName][element]
    end

    local mobData = M.zoneStats[mobName]
    return mobData and mobData[element] or nil
end

function M.recordLanded(mobName, element)
    local stats = getStats(mobName, element, true)
    if not stats then return end
    stats.landed = (stats.landed or 0) + 1
    M.dirty = true
end

function M.recordResisted(mobName, element)
    local stats = getStats(mobName, element, true)
    if not stats then return end
    stats.resisted = (stats.resisted or 0) + 1
    M.dirty = true
end

-------------------------------------------------------------------------------
-- Queries
-------------------------------------------------------------------------------

--- Get the observed resist rate for a mob/element
-- @param mobName string Mob clean name
-- @param element string Resist type (fire, cold, poison, disease, magic, ...)
-- @return number|nil rate 0..1 (nil if no data)
-- @return number samples Total observed casts
function M.getResistRate(mobName, element)
    local stats = getStats(mobName, element, false)
    if not stats then return nil, 0 end
    local landed = stats.landed or 0
    local resisted = stats.resisted or 0
    local samples = landed + resisted
    if samples == 0 then return nil, 0 end
    return resisted / samples, samples
end

--- Should spell selection avoid this element on this mob?
-- True once we have enough samples and the resist rate is at/above threshold.
-- @param mobName string Mob clean name
-- @param element string Resist type
-- @param settings table|nil Settings (ResistMinSamples, ResistAvoidPct)
-- @return boolean
function M.shouldAvoid(mobName, element, settings)
    settings = settings or {}
    local rate, samples = M.getResistRate(mobName, element)
    if not rate then return false end

    local minSamples = tonumber(settings.ResistMinSamples) or 4
    local avoidPct = tonumber(settings.ResistAvoidPct) or 50

    return samples >= minSamples and (rate * 100) >= avoidPct
end

-------------------------------------------------------------------------------
-- Feeding (spell_engine completion hook + resist events)
-------------------------------------------------------------------------------

local function resolveMobName(targetId)
    if not targetId or targetId <= 0 then return '' end
    local spawn = mq.TLO.Spawn(targetId)
    if not spawn or not spawn() then return '' end
    local ok, name = pcall(function() return spawn.CleanName() end)
    return (ok and name) or ''
end

local function resolveElement(spellName)
    if not spellName or spellName == '' then return '' end
    local spell = mq.TLO.Spell(spellName)
    if not spell or not spell() then return '' end
    local ok, rt = pcall(function() return spell.ResistType() end)
    rt = (ok and rt) or ''
    -- Unresistable spells carry no useful element signal
    if rt == '' or rt:lower() == 'unresistable' then return '' end
    return rt:lower()
end

--- Called by spell_engine when a cast completes (success or terminal failure)
-- @param castData table {spellName, targetId, spellCategory, ...}
-- @param result number SpellEvents.RESULT code
function M.onCastComplete(castData, result)
    if not castData then return end
    if not DAMAGE_CATEGORIES[tostring(castData.spellCategory or ''):lower()] then return end

    local element = resolveElement(castData.spellName)
    if element == '' then return end

    local mobName = resolveMobName(castData.targetId)
    if mobName == '' then return end

    local SpellEvents = getSpellEvents()
    local RESULT = SpellEvents and SpellEvents.RESULT or {}

    if result == RESULT.RESISTED then
        -- Resist detected before/at completion - count immediately, no pending
        M.recordResisted(mobName, element)
    elseif result == RESULT.SUCCESS then
        -- Cast finished; the resist message (if any) arrives shortly after landing
        table.insert(_pending, {
            spell = castData.spellName,
            mob = mobName,
            element = element,
            expires = mq.gettime() + PENDING_GRACE_MS,
        })
    end
    -- IMMUNE and other failures are not resist-rate signal (immune DB owns immunities)
end

--- Called from our own resist events; claims the matching pending attempt
local function onResistEvent(spellName)
    for i, p in ipairs(_pending) do
        if not spellName or spellName == '' or p.spell == spellName then
            table.remove(_pending, i)
            M.recordResisted(p.mob, p.element)
            return
        end
    end
end

--- Resolve expired pending attempts as landed; throttled periodic save
function M.tick()
    local now = mq.gettime()

    local i = 1
    while i <= #_pending do
        local p = _pending[i]
        if now >= p.expires then
            table.remove(_pending, i)
            M.recordLanded(p.mob, p.element)
        else
            i = i + 1
        end
    end

    if M.dirty and (now - _lastSave) >= SAVE_INTERVAL_MS then
        _lastSave = now
        M.saveDatabase()
    end
end

-------------------------------------------------------------------------------
-- Lifecycle
-------------------------------------------------------------------------------

function M.init()
    M.loadDatabase()
    M.loadZone()

    -- Resist events (own registrations; spell_events' handlers are independent)
    mq.event('sk_rt_resist1', "Your target resisted the #1# spell#*#", function(_, spell)
        onResistEvent(spell)
    end)
    mq.event('sk_rt_resist2', "#2# resisted your #1#!", function(_, spell, _)
        onResistEvent(spell)
    end)

    -- Hook cast completions (chain any existing callback)
    local ok, SpellEngine = pcall(require, 'sidekick-next.utils.spell_engine')
    if ok and SpellEngine then
        local prev = SpellEngine.onCastComplete
        SpellEngine.onCastComplete = function(castData, result)
            if prev then pcall(prev, castData, result) end
            M.onCastComplete(castData, result)
        end
    end
end

function M.shutdown()
    mq.unevent('sk_rt_resist1')
    mq.unevent('sk_rt_resist2')
    M.saveDatabase()
end

return M
