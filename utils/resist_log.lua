-- Adaptive resist tracking — persisted across sessions.
--
-- Records per (zone, mob, spell) cast/resist counts so the rotation engine
-- can skip abilities that consistently resist on a given mob. The log is
-- written to disk so the knowledge accumulates over time.
--
-- Decision rule (default):
--   Skip a (zone, mob, spell) tuple when:
--     - >= MIN_CASTS_TO_JUDGE casts AND
--     - resist rate >= SKIP_RATE_THRESHOLD
--   OR
--     - >= CONSECUTIVE_RESIST_LIMIT consecutive resists in the current fight
--
-- Wire-up:
--   - spell_events forwards results via M.recordResult(spellName, targetName, success)
--   - rotation_engine queries M.shouldSkip(spellName, targetName) before casting
--
-- Storage path:
--   <configDir>/SideKick/resist_log_<server>_<char>.lua

local mq = require('mq')
local lazy = require('sidekick-next.utils.lazy_require')
local getPaths = lazy('sidekick-next.utils.paths')
local SafeLoad = require('sidekick-next.utils.safe_load')

local M = {}

local _dirReady = false
local function ensureDirOnce()
    if _dirReady then return end
    local Paths = getPaths()
    local dir = (mq.configDir or 'config') .. '/SideKick'
    if Paths and Paths.ensureDir then
        Paths.ensureDir(dir)
    else
        os.execute('mkdir "' .. dir .. '" 2>nul')
    end
    _dirReady = true
end

local MIN_CASTS_TO_JUDGE = 5         -- need this many casts before we trust the rate
local SKIP_RATE_THRESHOLD = 0.5      -- 50%+ resist rate => skip
local CONSECUTIVE_RESIST_LIMIT = 3   -- 3 consecutive resists this fight => skip
local SAVE_INTERVAL = 60             -- seconds between throttled disk saves
local SESSION_TTL = 1800             -- drop session-level consecutive counters after 30 min idle

-- Persisted shape:
--   { zones = { [zone] = { [mob] = { [spell] = { casts, resists, lastResistAt } } } } }
M.data = { zones = {} }

-- In-memory only (not persisted):
--   _consecutive[zone][mob][spell] = { count, lastAt }
local _consecutive = {}
local _lastSaveAt = 0
local _dirty = false
local _disabled = false

-- ---------------------------------------------------------------------------
-- Storage
-- ---------------------------------------------------------------------------

local function getPath()
    local server = (mq.TLO.EverQuest and mq.TLO.EverQuest.Server and mq.TLO.EverQuest.Server()) or 'unknown'
    local char = (mq.TLO.Me and mq.TLO.Me.CleanName and mq.TLO.Me.CleanName()) or 'unknown'
    local dir = (mq.configDir or 'config') .. '/SideKick'
    ensureDirOnce()
    return string.format('%s/resist_log_%s_%s.lua', dir, server, char)
end

local function escapeString(s)
    return tostring(s):gsub('\\', '\\\\'):gsub('"', '\\"'):gsub('\n', '\\n'):gsub('\r', '\\r')
end

local function serialize(tbl, indent)
    indent = indent or ''
    local lines = { '{' }
    for k, v in pairs(tbl) do
        local key
        if type(k) == 'number' then key = '[' .. k .. ']'
        else key = '["' .. escapeString(k) .. '"]' end
        if type(v) == 'table' then
            table.insert(lines, indent .. '  ' .. key .. ' = ' .. serialize(v, indent .. '  ') .. ',')
        elseif type(v) == 'number' or type(v) == 'boolean' then
            table.insert(lines, indent .. '  ' .. key .. ' = ' .. tostring(v) .. ',')
        else
            table.insert(lines, indent .. '  ' .. key .. ' = "' .. escapeString(v) .. '",')
        end
    end
    table.insert(lines, indent .. '}')
    return table.concat(lines, '\n')
end

function M.load()
    local path = getPath()
    local f = io.open(path, 'r')
    if not f then return end
    local content = f:read('*all')
    f:close()
    if not content or content == '' then return end
    local data = SafeLoad.tableLiteral(content, path)
    if type(data) == 'table' and type(data.zones) == 'table' then
        M.data = data
    end
end

function M.save()
    if not _dirty then return end
    local safeWrite = require('sidekick-next.utils.safe_write')
    local content = serialize(M.data)
    local ok, err = safeWrite(getPath(), content)
    if ok then
        _dirty = false
        _lastSaveAt = os.time()
    else
        print(string.format('\ar[ResistLog]\ax save failed: %s', tostring(err)))
    end
end

function M.tick()
    if _disabled then return end
    if _dirty and (os.time() - _lastSaveAt) >= SAVE_INTERVAL then
        M.save()
    end
end

function M.setDisabled(v) _disabled = v and true or false end
function M.isDisabled() return _disabled end

-- ---------------------------------------------------------------------------
-- Helpers
-- ---------------------------------------------------------------------------

local function currentZone()
    return (mq.TLO.Zone and mq.TLO.Zone.ShortName and mq.TLO.Zone.ShortName()) or 'unknown'
end

local function ensureBucket(zone, mob, spell)
    M.data.zones[zone] = M.data.zones[zone] or {}
    M.data.zones[zone][mob] = M.data.zones[zone][mob] or {}
    M.data.zones[zone][mob][spell] = M.data.zones[zone][mob][spell] or {
        casts = 0,
        resists = 0,
        lastResistAt = 0,
    }
    return M.data.zones[zone][mob][spell]
end

local function getConsecutive(zone, mob, spell)
    if not _consecutive[zone] then return 0, 0 end
    if not _consecutive[zone][mob] then return 0, 0 end
    local rec = _consecutive[zone][mob][spell]
    if not rec then return 0, 0 end
    -- Expire stale session counters so a long-ago resist series doesn't
    -- permanently skip the spell.
    if (os.time() - (rec.lastAt or 0)) > SESSION_TTL then
        _consecutive[zone][mob][spell] = nil
        return 0, 0
    end
    return rec.count or 0, rec.lastAt or 0
end

local function bumpConsecutive(zone, mob, spell, isResist)
    _consecutive[zone] = _consecutive[zone] or {}
    _consecutive[zone][mob] = _consecutive[zone][mob] or {}
    local rec = _consecutive[zone][mob][spell] or { count = 0, lastAt = 0 }
    if isResist then
        rec.count = (rec.count or 0) + 1
        rec.lastAt = os.time()
    else
        rec.count = 0
        rec.lastAt = os.time()
    end
    _consecutive[zone][mob][spell] = rec
end

-- ---------------------------------------------------------------------------
-- Recording
-- ---------------------------------------------------------------------------

--- Record that a cast was *attempted* (initiated). Increments cast count and
--- resets the consecutive-resist counter — the consecutive counter only goes
--- up when a resist actually fires.
--- @param spellName string
--- @param targetName string
function M.recordCast(spellName, targetName)
    if _disabled then return end
    spellName = tostring(spellName or '')
    targetName = tostring(targetName or '')
    if spellName == '' or targetName == '' then return end

    local zone = currentZone()
    local bucket = ensureBucket(zone, targetName, spellName)
    bucket.casts = (bucket.casts or 0) + 1
    bumpConsecutive(zone, targetName, spellName, false)
    _dirty = true
end

--- Record that a cast was resisted by the named target. Bumps both the
--- per-(zone, mob, spell) resist count and the in-fight consecutive counter.
--- @param spellName string
--- @param targetName string
function M.recordResist(spellName, targetName)
    if _disabled then return end
    spellName = tostring(spellName or '')
    targetName = tostring(targetName or '')
    if spellName == '' or targetName == '' then return end

    local zone = currentZone()
    local bucket = ensureBucket(zone, targetName, spellName)
    bucket.resists = (bucket.resists or 0) + 1
    bucket.lastResistAt = os.time()
    bumpConsecutive(zone, targetName, spellName, true)
    _dirty = true
end

-- ---------------------------------------------------------------------------
-- Query
-- ---------------------------------------------------------------------------

--- Should the rotation engine skip casting `spellName` at `targetName` right now?
--- @param spellName string
--- @param targetName string
--- @return boolean skip
--- @return string|nil reason
function M.shouldSkip(spellName, targetName)
    if _disabled then return false end
    spellName = tostring(spellName or '')
    targetName = tostring(targetName or '')
    if spellName == '' or targetName == '' then return false end

    local zone = currentZone()

    local consecutive = (select(1, getConsecutive(zone, targetName, spellName)))
    if consecutive >= CONSECUTIVE_RESIST_LIMIT then
        return true, string.format('%d consecutive resists', consecutive)
    end

    local zoneRec = M.data.zones[zone]
    if not zoneRec then return false end
    local mobRec = zoneRec[targetName]
    if not mobRec then return false end
    local spellRec = mobRec[spellName]
    if not spellRec then return false end

    local casts = spellRec.casts or 0
    local resists = spellRec.resists or 0
    if casts < MIN_CASTS_TO_JUDGE then return false end
    local rate = resists / casts
    if rate >= SKIP_RATE_THRESHOLD then
        return true, string.format('%d%% resist rate (%d/%d)', math.floor(rate * 100), resists, casts)
    end
    return false
end

--- Inspect the persisted record for (zone, mob, spell). For UI/debug.
function M.getRecord(zone, mob, spell)
    zone = zone or currentZone()
    local zr = M.data.zones[zone]
    if not zr then return nil end
    local mr = zr[mob]
    if not mr then return nil end
    return mr[spell]
end

--- Walk all records for the given zone (defaults to current). For UI listing.
--- @return function iterator yielding (mob, spell, record)
function M.iterZone(zone)
    zone = zone or currentZone()
    local zr = M.data.zones[zone] or {}
    local mob, perSpell = next(zr)
    local spell, rec
    return function()
        while mob do
            spell, rec = next(perSpell, spell)
            if spell then return mob, spell, rec end
            mob, perSpell = next(zr, mob)
            spell = nil
        end
    end
end

--- Reset all consecutive counters (called on combat-end for a clean fight).
function M.resetSessionCounters() _consecutive = {} end

--- Wipe a single spell's history (for UI "forget this" button).
function M.forget(zone, mob, spell)
    local zr = M.data.zones[zone or currentZone()]
    if not zr then return end
    if mob and spell and zr[mob] then zr[mob][spell] = nil
    elseif mob then zr[mob] = nil
    end
    _dirty = true
end

return M
