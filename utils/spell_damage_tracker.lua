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
local SafeLoad = require('sidekick-next.utils.safe_load')
local MobName = require('sidekick-next.utils.mob_name')

local M = {}

-- spellName -> { maxSeen, ema, count }
M.data = {}

M.dirty = false

-- EMA smoothing factor for typical-hit tracking
local EMA_ALPHA = 0.2

-- Minimum observations before expected/baseline values are trusted
local MIN_SAMPLES = 3

local getPaths = lazy('sidekick-next.utils.paths')
local getDamageEvents = lazy('sidekick-next.utils.damage_events')
local getSpellEngine = lazy('sidekick-next.utils.spell_engine')
local getSpellEvents = lazy('sidekick-next.utils.spell_events')

-- Damage chat and SpellEngine completion can arrive in either order. Keep
-- short, bounded correlation queues so direct-damage learning does not depend
-- on the resist tracker (and therefore also works for unresistable nukes).
local _pendingCasts = {}
local _recentDamage = {}
local _initialized = false
local CORRELATION_TTL_MS = 2500
local MAX_CORRELATIONS = 20

M.diagnostics = {
    ownNukeEvents = 0,
    matched = 0,
    unmatched = 0,
    lastReason = 'not_initialized',
    lastSpell = '',
    lastTarget = '',
    lastAmount = 0,
}

local DAMAGE_CATEGORIES = {
    nuke = true,
    damage = true,
    direct_damage = true,
}

local function nowMs()
    return mq.gettime and mq.gettime() or math.floor(os.clock() * 1000)
end

local function normalizeName(value)
    local name = tostring(value or ''):match('^%s*(.-)%s*$')
    local liveName = MobName.corpseBaseName(name) or name
    return liveName:lower()
end

local function parseAmount(value)
    if type(value) == 'string' then value = value:gsub(',', '') end
    return tonumber(value) or 0
end

local function resolveTargetName(targetId)
    targetId = tonumber(targetId) or 0
    if targetId <= 0 then return '' end
    local spawn = mq.TLO and mq.TLO.Spawn and mq.TLO.Spawn(targetId) or nil
    if not (spawn and spawn()) then return '' end
    local ok, name = pcall(function() return spawn.CleanName() end)
    return ok and tostring(name or '') or ''
end

local function trimExpired(now)
    for index = #_recentDamage, 1, -1 do
        if now - (tonumber(_recentDamage[index].at) or 0) > CORRELATION_TTL_MS then
            table.remove(_recentDamage, index)
        end
    end
    for index = #_pendingCasts, 1, -1 do
        if now >= (tonumber(_pendingCasts[index].expires) or 0) then
            table.remove(_pendingCasts, index)
        end
    end
end

local function remember(queue, value)
    queue[#queue + 1] = value
    if #queue > MAX_CORRELATIONS then table.remove(queue, 1) end
end

local function claimPending(targetKey, amount)
    for index, pending in ipairs(_pendingCasts) do
        if pending.targetKey == targetKey then
            table.remove(_pendingCasts, index)
            M.record(pending.spellName, amount)
            M.diagnostics.matched = M.diagnostics.matched + 1
            M.diagnostics.lastReason = 'matched_pending_cast'
            M.diagnostics.lastSpell = pending.spellName
            M.diagnostics.lastTarget = pending.targetName
            M.diagnostics.lastAmount = amount
            return true
        end
    end
    return false
end

local function getDbPath()
    local Paths = getPaths()
    if Paths and Paths.getSpellDamagePath then
        return Paths.getSpellDamagePath()
    end
    return mq.configDir .. '/SideKick/data/spell_damage.lua'
end

function M.load()
    local path = getDbPath()
    local file = io.open(path, 'r')
    if not file then
        M.data = {}
        return
    end
    local content = file:read('*all')
    file:close()

    if content and content ~= '' then
        local data, err = SafeLoad.tableLiteral(content, path)
        if type(data) == 'table' then
            M.data = data
            return
        end
        print(string.format('\ar[SpellDamage]\ax load failed: %s', tostring(err or 'invalid data')))
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
    amount = parseAmount(amount)
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

--- Observe one outgoing damage event and correlate own nukes with SpellEngine.
-- Public for diagnostics/tests; normal callers receive this through
-- damage_events.addListener().
function M.observeDamage(event)
    if type(event) ~= 'table' or event.mine ~= true or event.kind ~= 'nuke' then
        return false
    end
    local amount = parseAmount(event.amount)
    local targetName = tostring(event.target or '')
    local targetKey = normalizeName(targetName)
    if amount <= 0 or targetKey == '' then return false end

    M.diagnostics.ownNukeEvents = M.diagnostics.ownNukeEvents + 1
    trimExpired(nowMs())
    if claimPending(targetKey, amount) then return true end

    -- ModuleBase drains MQ events before the executor advances SpellEngine, so
    -- the damage line commonly arrives while the cast still owns _castData.
    local SpellEngine = getSpellEngine()
    local cast = SpellEngine and SpellEngine.getCastInfo and SpellEngine.getCastInfo() or nil
    local category = tostring(cast and cast.category or ''):lower()
    local castName = tostring(cast and cast.targetName or '')
    if castName == '' and cast then castName = resolveTargetName(cast.targetId) end
    if cast and DAMAGE_CATEGORIES[category]
        and normalizeName(castName) == targetKey then
        remember(_recentDamage, {
            targetKey = targetKey,
            targetName = targetName,
            amount = amount,
            at = nowMs(),
        })
        M.diagnostics.lastReason = 'damage_waiting_for_cast_completion'
        M.diagnostics.lastTarget = targetName
        M.diagnostics.lastAmount = amount
        return true
    end

    M.diagnostics.unmatched = M.diagnostics.unmatched + 1
    M.diagnostics.lastReason = 'no_matching_damage_cast'
    M.diagnostics.lastTarget = targetName
    M.diagnostics.lastAmount = amount
    return false
end

--- Receive one terminal SpellEngine cast result.
function M.onCastComplete(castData, result)
    if type(castData) ~= 'table'
        or not DAMAGE_CATEGORIES[tostring(castData.spellCategory or ''):lower()] then
        return false
    end
    local SpellEvents = getSpellEvents()
    local RESULT = SpellEvents and SpellEvents.RESULT or {}
    if result ~= RESULT.SUCCESS then return false end

    local targetName = tostring(castData.targetName or '')
    if targetName == '' then targetName = resolveTargetName(castData.targetId) end
    local targetKey = normalizeName(targetName)
    local spellName = tostring(castData.spellName or '')
    if targetKey == '' or spellName == '' then return false end

    local now = nowMs()
    trimExpired(now)
    for index = #_recentDamage, 1, -1 do
        local hit = _recentDamage[index]
        if hit.targetKey == targetKey then
            table.remove(_recentDamage, index)
            M.record(spellName, hit.amount)
            M.diagnostics.matched = M.diagnostics.matched + 1
            M.diagnostics.lastReason = 'matched_recent_damage'
            M.diagnostics.lastSpell = spellName
            M.diagnostics.lastTarget = targetName
            M.diagnostics.lastAmount = hit.amount
            return true
        end
    end

    remember(_pendingCasts, {
        spellName = spellName,
        targetName = targetName,
        targetKey = targetKey,
        expires = now + CORRELATION_TTL_MS,
    })
    M.diagnostics.lastReason = 'cast_waiting_for_damage'
    M.diagnostics.lastSpell = spellName
    M.diagnostics.lastTarget = targetName
    return true
end

function M.getDiagnostics()
    return {
        ownNukeEvents = M.diagnostics.ownNukeEvents,
        matched = M.diagnostics.matched,
        unmatched = M.diagnostics.unmatched,
        pendingCasts = #_pendingCasts,
        recentDamage = #_recentDamage,
        lastReason = M.diagnostics.lastReason,
        lastSpell = M.diagnostics.lastSpell,
        lastTarget = M.diagnostics.lastTarget,
        lastAmount = M.diagnostics.lastAmount,
    }
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
    trimExpired(now)
    if M.dirty and (now - _lastSave) >= SAVE_INTERVAL_MS then
        _lastSave = now
        M.save()
    end
end

function M.init()
    if _initialized then return end
    M.load()
    local DamageEvents = getDamageEvents()
    if DamageEvents and DamageEvents.addListener then
        DamageEvents.addListener(M.observeDamage)
    end
    local SpellEngine = getSpellEngine()
    if SpellEngine and SpellEngine.addCastCompleteListener then
        SpellEngine.addCastCompleteListener(M.onCastComplete)
    end
    _initialized = true
    M.diagnostics.lastReason = 'ready'
end

function M.shutdown()
    M.save()
end

function M._resetLearningForTest()
    M.data = {}
    M.dirty = false
    _pendingCasts = {}
    _recentDamage = {}
    M.diagnostics = {
        ownNukeEvents = 0,
        matched = 0,
        unmatched = 0,
        lastReason = 'test_reset',
        lastSpell = '',
        lastTarget = '',
        lastAmount = 0,
    }
end

return M
