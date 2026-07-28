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
--
-- Partial resists: when my nuke's damage message arrives (via damage_events), the
-- observed amount is compared against the spell's learned baseline
-- (spell_damage_tracker). Hits landing far below baseline on a specific mob mean
-- the mob partially resists that element - tracked as an efficiency average per
-- mob/element and folded into shouldAvoid().

local mq = require('mq')
local lazy = require('sidekick-next.utils.lazy_require')
local SafeLoad = require('sidekick-next.utils.safe_load')
local MobName = require('sidekick-next.utils.mob_name')

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
local _initialized = false
local _recentOwnDamage = {} -- damage chat can dispatch just before cast completion
local RECENT_DAMAGE_TTL_MS = 2500

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
local getSpellDamage = lazy('sidekick-next.utils.spell_damage_tracker')
local getDamageEvents = lazy('sidekick-next.utils.damage_events')

local function getDbPath()
    local Paths = getPaths()
    if Paths and Paths.getResistTrackerPath then
        return Paths.getResistTrackerPath()
    end
    return mq.configDir .. '/SideKick/data/resist_tracker.lua'
end

local function mergeCorpseStats(database)
    local migrated = 0
    for _, mobs in pairs(type(database) == 'table' and database or {}) do
        if type(mobs) == 'table' then
            local moves = {}
            for name, elements in pairs(mobs) do
                local baseName = MobName.corpseBaseName(name)
                if baseName then
                    moves[#moves + 1] = {
                        corpseName = name,
                        baseName = baseName,
                        elements = elements,
                    }
                end
            end
            for _, move in ipairs(moves) do
                local destination = mobs[move.baseName]
                if type(destination) ~= 'table' then
                    destination = {}
                    mobs[move.baseName] = destination
                end
                for element, sourceStats in pairs(
                    type(move.elements) == 'table' and move.elements or {})
                do
                    local targetStats = destination[element]
                    if type(targetStats) ~= 'table' then
                        targetStats = {}
                        destination[element] = targetStats
                    end
                    for key, value in pairs(
                        type(sourceStats) == 'table' and sourceStats or {})
                    do
                        if type(value) == 'number' then
                            targetStats[key] = (tonumber(targetStats[key]) or 0) + value
                        elseif targetStats[key] == nil then
                            targetStats[key] = value
                        end
                    end
                end
                mobs[move.corpseName] = nil
                migrated = migrated + 1
            end
        end
    end
    return migrated
end

-------------------------------------------------------------------------------
-- Persistence (same shape as immune_database)
-------------------------------------------------------------------------------

function M.loadDatabase()
    M.currentZone = ''
    M.zoneStats = {}
    M.dirty = false

    local path = getDbPath()
    local file = io.open(path, 'r')
    if not file then
        M.database = {}
        return
    end

    local content = file:read('*all')
    file:close()

    if content and content ~= '' then
        local data, err = SafeLoad.tableLiteral(content, path)
        if type(data) == 'table' then
            M.database = data
            local migrated = mergeCorpseStats(M.database)
            if migrated > 0 then
                M.dirty = true
                print(string.format(
                    '\ay[ResistTracker]\ax Migrated %d corpse knowledge entr%s to live mob names',
                    migrated, migrated == 1 and 'y' or 'ies'))
            end
            return
        end
        print(string.format('\ar[ResistTracker]\ax load failed: %s', tostring(err or 'invalid data')))
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
    if not MobName.isKnowledgeName(mobName) then return nil end
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

--- Record how efficiently a landed hit came through (partial-resist signal)
-- @param mobName string Mob clean name
-- @param element string Resist type
-- @param efficiency number 0..1 (observed damage / spell baseline)
function M.recordEfficiency(mobName, element, efficiency)
    local stats = getStats(mobName, element, true)
    if not stats then return end
    efficiency = math.max(0, math.min(1, tonumber(efficiency) or 1))
    stats.effSum = (stats.effSum or 0) + efficiency
    stats.effCount = (stats.effCount or 0) + 1
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

--- Get the average landing efficiency for a mob/element (partial-resist signal)
-- @param mobName string Mob clean name
-- @param element string Resist type
-- @return number|nil avgEfficiency 0..1 (nil if no data)
-- @return number samples Efficiency observations
function M.getEfficiency(mobName, element)
    local stats = getStats(mobName, element, false)
    if not stats or (stats.effCount or 0) == 0 then return nil, 0 end
    return stats.effSum / stats.effCount, stats.effCount
end

--- Should spell selection avoid this element on this mob?
-- True once we have enough samples and either the full-resist rate is at/above
-- threshold, or landed hits average far below the spell baseline (partial resist).
-- @param mobName string Mob clean name
-- @param element string Resist type
-- @param settings table|nil Settings (ResistMinSamples, ResistAvoidPct, ResistMinEfficiencyPct)
-- @return boolean
function M.shouldAvoid(mobName, element, settings)
    settings = settings or {}
    local minSamples = tonumber(settings.ResistMinSamples) or 4

    local rate, samples = M.getResistRate(mobName, element)
    if rate and samples >= minSamples then
        local avoidPct = tonumber(settings.ResistAvoidPct) or 50
        if (rate * 100) >= avoidPct then
            return true
        end
    end

    local eff, effSamples = M.getEfficiency(mobName, element)
    if eff and effSamples >= minSamples then
        local minEffPct = tonumber(settings.ResistMinEfficiencyPct) or 35
        if (eff * 100) <= minEffPct then
            return true
        end
    end

    return false
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

    local mobName = tostring(castData.targetName or '')
    if mobName == '' then mobName = resolveMobName(castData.targetId) end
    if not MobName.isKnowledgeName(mobName) then return end

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
        -- ModuleBase drains MQ events before advancing SpellEngine. If the
        -- damage line landed in that drain, consume the bounded cached hit now
        -- that its cast attempt exists.
        local now = mq.gettime()
        for i = #_recentOwnDamage, 1, -1 do
            local hit = _recentOwnDamage[i]
            if (now - hit.at) > RECENT_DAMAGE_TTL_MS then
                table.remove(_recentOwnDamage, i)
            elseif hit.mob == mobName then
                table.remove(_recentOwnDamage, i)
                M.onOwnSpellDamage(hit.mob, hit.amount)
                break
            end
        end
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

--- Called when one of my nuke damage messages lands (via damage_events).
-- Claims the matching pending attempt as landed and records partial-resist
-- efficiency against the spell's learned baseline.
-- @param mobName string Mob name from the damage message
-- @param amount number Damage dealt
function M.onOwnSpellDamage(mobName, amount)
    if not mobName or mobName == '' then return end
    amount = tonumber(amount) or 0
    if amount <= 0 then return end

    for i, p in ipairs(_pending) do
        if p.mob == mobName then
            table.remove(_pending, i)
            M.recordLanded(p.mob, p.element)

            local SpellDamage = getSpellDamage()
            if SpellDamage then
                local baseline = SpellDamage.getBaseline and SpellDamage.getBaseline(p.spell)
                if baseline and baseline > 0 then
                    M.recordEfficiency(p.mob, p.element, amount / baseline)
                end
            end
            return
        end
    end
    -- Cache only damage from the SpellEngine cast that is still awaiting its
    -- terminal tick. Unrelated proc damage must not be attributed to the next
    -- nuke cast on the same mob.
    local ok, SpellEngine = pcall(require, 'sidekick-next.utils.spell_engine')
    local castInfo = ok and SpellEngine and SpellEngine.getCastInfo
        and SpellEngine.getCastInfo() or nil
    local castTargetName = castInfo and tostring(castInfo.targetName or '') or ''
    if castTargetName == '' and castInfo then
        castTargetName = resolveMobName(castInfo.targetId)
    end
    if not castInfo or not DAMAGE_CATEGORIES[tostring(castInfo.category or ''):lower()]
        or castTargetName ~= mobName then
        return
    end
    table.insert(_recentOwnDamage, {
        mob = mobName,
        amount = amount,
        at = mq.gettime(),
    })
    if #_recentOwnDamage > 20 then table.remove(_recentOwnDamage, 1) end
end

--- Resolve expired pending attempts as landed; throttled periodic save
function M.tick()
    local now = mq.gettime()

    for i = #_recentOwnDamage, 1, -1 do
        if (now - (_recentOwnDamage[i].at or 0)) > RECENT_DAMAGE_TTL_MS then
            table.remove(_recentOwnDamage, i)
        end
    end

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
    if _initialized then return end
    M.loadDatabase()
    M.loadZone()

    -- Resist events (own registrations; spell_events' handlers are independent)
    mq.event('sk_rt_resist1', "Your target resisted the #1# spell#*#", function(_, spell)
        onResistEvent(spell)
    end)
    mq.event('sk_rt_resist2', "#2# resisted your #1#!", function(_, spell, _)
        onResistEvent(spell)
    end)

    -- Hook cast completions without replacing other process-local observers.
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

    -- Listen for my own nuke damage (landed confirmation + partial-resist signal)
    local DamageEvents = getDamageEvents()
    if DamageEvents and DamageEvents.addListener then
        DamageEvents.addListener(function(event)
            if event.mine and event.kind == 'nuke' then
                M.onOwnSpellDamage(event.target, event.amount)
            end
        end)
    end
    _initialized = true
end

function M.shutdown()
    mq.unevent('sk_rt_resist1')
    mq.unevent('sk_rt_resist2')
    M.saveDatabase()
end

return M
