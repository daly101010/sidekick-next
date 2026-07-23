-- utils/spell_damage_tracker.lua
-- Spell Damage Tracker - Learns what each of my damage spells actually hits for
-- (analogous to heal_tracker learning expected heal amounts).
--
-- Used for:
--  * Overkill checks: don't throw a 30k nuke at a mob with 4k estimated HP left
--  * Partial-resist detection: a hit far below this spell's baseline on a
--    specific mob means the mob is partially resisting that element
--
-- Persisted per character (damage depends on level/gear/focus effects).

local mq = require('mq')
local lazy = require('sidekick-next.utils.lazy_require')

local M = {}

-- spellName -> { maxSeen, ema, count }
M.data = {}

M.dirty = false

-- EMA smoothing factor for typical-hit tracking
local EMA_ALPHA = 0.2

-- Minimum observations before expected/baseline values are trusted
local MIN_SAMPLES = 3

local getPaths = lazy('sidekick-next.utils.paths')

local function getDbPath()
    local Paths = getPaths()
    if Paths and Paths.getSpellDamagePath then
        return Paths.getSpellDamagePath()
    end
    return mq.configDir .. '/SideKick/data/spell_damage.lua'
end

function M.load()
    local file = io.open(getDbPath(), 'r')
    if not file then
        M.data = {}
        return
    end
    local content = file:read('*all')
    file:close()

    if content and content ~= '' then
        local fn = loadstring('return ' .. content)
        if fn then
            local ok, data = pcall(fn)
            if ok and type(data) == 'table' then
                M.data = data
                return
            end
        end
    end
    M.data = {}
end

function M.save()
    if not M.dirty then return end

    local Paths = getPaths()
    if Paths then
        Paths.ensureDir(Paths.getDataDir())
    end

    local lines = { '{' }
    for spell, d in pairs(M.data) do
        table.insert(lines, string.format('  ["%s"] = { maxSeen = %d, ema = %.1f, count = %d },',
            spell:gsub('\\', '\\\\'):gsub('"', '\\"'), d.maxSeen or 0, d.ema or 0, d.count or 0))
    end
    table.insert(lines, '}')

    local safeWrite = require('sidekick-next.utils.safe_write')
    local ok, err = safeWrite(getDbPath(), table.concat(lines, '\n'))
    if not ok then
        print(string.format('\ar[SpellDamage]\ax Failed to save: %s', tostring(err)))
        return
    end
    M.dirty = false
end

--- Record an observed hit for one of my damage spells
-- @param spellName string
-- @param amount number Damage dealt
function M.record(spellName, amount)
    if not spellName or spellName == '' then return end
    amount = tonumber(amount) or 0
    if amount <= 0 then return end

    local d = M.data[spellName]
    if not d then
        d = { maxSeen = 0, ema = 0, count = 0 }
        M.data[spellName] = d
    end

    d.count = d.count + 1
    if amount > (d.maxSeen or 0) then d.maxSeen = amount end
    if d.count == 1 then
        d.ema = amount
    else
        d.ema = d.ema + EMA_ALPHA * (amount - d.ema)
    end
    M.dirty = true
end

--- Get the expected (typical) damage for a spell
-- @param spellName string
-- @return number|nil expected Typical hit (nil if not enough data)
-- @return number count Observations
function M.getExpected(spellName)
    local d = spellName and M.data[spellName]
    if not d or (d.count or 0) < MIN_SAMPLES then
        return nil, d and d.count or 0
    end
    return d.ema, d.count
end

--- Get the full-landing baseline for partial-resist comparison.
-- maxSeen includes crits (roughly double), so the baseline is the larger of the
-- running typical hit and half the best hit ever seen.
-- @param spellName string
-- @return number|nil baseline (nil if not enough data)
function M.getBaseline(spellName)
    local d = spellName and M.data[spellName]
    if not d or (d.count or 0) < MIN_SAMPLES then
        return nil
    end
    return math.max(d.ema or 0, (d.maxSeen or 0) * 0.5)
end

local _lastSave = 0
local SAVE_INTERVAL_MS = 60000

--- Throttled periodic save
function M.tick()
    local now = mq.gettime()
    if M.dirty and (now - _lastSave) >= SAVE_INTERVAL_MS then
        _lastSave = now
        M.save()
    end
end

function M.init()
    M.load()
end

function M.shutdown()
    M.save()
end

return M
