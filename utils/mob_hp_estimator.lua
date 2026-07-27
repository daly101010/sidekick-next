-- utils/mob_hp_estimator.lua
-- Mob HP Estimator - Learns mobs' absolute HP pools from observed damage.
--
-- EQ never exposes NPC max HP (Spawn.MaxHPs() is percent-scale), but every
-- damage message is an absolute number and every spawn exposes PctHPs. Pairing
-- accumulated damage against the HP% it removed gives:
--     estMaxHP ~= damageDealt / (pctDropped / 100)
--
-- Estimates are aggregated per mob NAME (same-name mobs share HP pools) with
-- delta-weighted averaging (a 40% drop is far more reliable than a 2% blip,
-- since PctHPs is integer-granular), and persisted per zone so named/common
-- mobs have a usable estimate from the first cast of the next encounter.

local mq = require('mq')
local lazy = require('sidekick-next.utils.lazy_require')
local SafeLoad = require('sidekick-next.utils.safe_load')

local M = {}

-- Persistent database: zone -> mobName -> { maxHP, weight }
M.database = {}
M.zoneEstimates = {}
M.currentZone = ''
M.dirty = false

-- Live per-mob tracking this fight: mobName -> {
--   anchorPct, dmgSince,          - damage accumulated since the anchor HP%
--   estSum, weightSum,            - delta-weighted running estimate
--   spawnId, lastPct, lastSeen,   - cached spawn resolution
-- }
local _live = {}

-- Minimum HP% drop before computing an estimate (integer PctHPs makes smaller
-- deltas too noisy, especially on big mobs)
local MIN_DELTA_PCT = 2

-- Delta granting full confidence weight
local FULL_WEIGHT_DELTA = 10

-- Sanity bounds for a single estimate
local MIN_SANE_HP = 50
local MAX_SANE_HP = 2e9

-- Forget live entries not damaged for this long (ms); merge into database
local LIVE_TTL_MS = 60000

-- Spawn id re-resolution interval (ms)
local RESOLVE_INTERVAL_MS = 3000

local _lastSave = 0
local SAVE_INTERVAL_MS = 60000

local getPaths = lazy('sidekick-next.utils.paths')
local getDamageEvents = lazy('sidekick-next.utils.damage_events')
local getActors = lazy('sidekick-next.utils.actors_coordinator')

local _lastShare = 0
local SHARE_INTERVAL_MS = 2000

local function getDbPath()
    local Paths = getPaths()
    if Paths and Paths.getMobHpEstimatorPath then
        return Paths.getMobHpEstimatorPath()
    end
    return mq.configDir .. '/SideKick/data/mob_hp_estimates.lua'
end

-------------------------------------------------------------------------------
-- Persistence
-------------------------------------------------------------------------------

function M.loadDatabase()
    M.currentZone = ''
    M.zoneEstimates = {}

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
            return
        end
        print(string.format('\ar[MobHP]\ax load failed: %s', tostring(err or 'invalid data')))
    end
    M.database = {}
end

function M.saveDatabase()
    if not M.dirty then return end

    local Paths = getPaths()
    if Paths then
        Paths.ensureDir(Paths.getDataDir())
    end

    local function esc(s)
        return tostring(s):gsub('\\', '\\\\'):gsub('"', '\\"')
    end

    local lines = { '{' }
    for zone, mobs in pairs(M.database) do
        table.insert(lines, string.format('  ["%s"] = {', esc(zone)))
        for name, d in pairs(mobs) do
            table.insert(lines, string.format('    ["%s"] = { maxHP = %d, weight = %.2f },',
                esc(name), d.maxHP or 0, d.weight or 0))
        end
        table.insert(lines, '  },')
    end
    table.insert(lines, '}')

    local safeWrite = require('sidekick-next.utils.safe_write')
    local ok, err = safeWrite(getDbPath(), table.concat(lines, '\n'))
    if not ok then
        print(string.format('\ar[MobHP]\ax Failed to save: %s', tostring(err)))
        return
    end
    M.dirty = false
end

-- Merge a live estimate into the persistent per-zone database
local function mergeToDatabase(mobName, live)
    if not live or (live.weightSum or 0) <= 0 then return end

    local zone = M.currentZone
    if zone == '' then return end

    if not M.database[zone] then M.database[zone] = {} end
    local d = M.database[zone][mobName]
    local liveEst = live.estSum / live.weightSum
    if not d then
        M.database[zone][mobName] = { maxHP = liveEst, weight = live.weightSum }
    else
        local totalW = (d.weight or 0) + live.weightSum
        d.maxHP = ((d.maxHP or 0) * (d.weight or 0) + liveEst * live.weightSum) / totalW
        -- Cap stored weight so estimates can still drift with gear/level changes
        d.weight = math.min(totalW, 50)
    end
    M.zoneEstimates = M.database[zone]
    M.dirty = true
end

function M.loadZone()
    local zone = mq.TLO.Zone.ShortName() or ''
    if zone == M.currentZone then return end

    -- Flush live learning from the previous zone
    for name, live in pairs(_live) do
        mergeToDatabase(name, live)
    end
    _live = {}

    M.saveDatabase()
    M.currentZone = zone
    M.zoneEstimates = M.database[zone] or {}
end

-------------------------------------------------------------------------------
-- Spawn resolution (damage messages carry names, not IDs)
-------------------------------------------------------------------------------

local function resolvePct(mobName, live)
    local now = mq.gettime()

    -- Fast path: current target
    local ok, pct = pcall(function()
        local t = mq.TLO.Target
        if t and t() and t.CleanName() == mobName then
            local ty = t.Type and t.Type() or ''
            if ty == 'NPC' or ty == 'Pet' then
                live.spawnId = t.ID()
                return tonumber(t.PctHPs())
            end
        end
        return nil
    end)
    if ok and pct then
        live.lastSeen = now
        return pct
    end

    -- Cached spawn id
    if live.spawnId and live.spawnId > 0 then
        local ok2, pct2 = pcall(function()
            local s = mq.TLO.Spawn(live.spawnId)
            if s and s() and s.CleanName() == mobName and not s.Dead() then
                return tonumber(s.PctHPs())
            end
            return nil
        end)
        if ok2 and pct2 then
            live.lastSeen = now
            return pct2
        end
        live.spawnId = nil
    end

    -- Throttled search by name (only NPCs)
    if (now - (live.lastResolve or 0)) < RESOLVE_INTERVAL_MS then
        return nil
    end
    live.lastResolve = now

    local ok3, result = pcall(function()
        local s = mq.TLO.Spawn(string.format('npc "%s"', mobName))
        if s and s() and s.CleanName() == mobName then
            return { id = s.ID(), pct = tonumber(s.PctHPs()) }
        end
        return nil
    end)
    if ok3 and result then
        live.spawnId = result.id
        live.lastSeen = now
        return result.pct
    end
    return nil
end

-------------------------------------------------------------------------------
-- Observation
-------------------------------------------------------------------------------

--- Feed one outgoing damage observation (called from damage_events)
-- @param mobName string Mob name as printed in the damage message
-- @param amount number Damage dealt
function M.observe(mobName, amount)
    if not mobName or mobName == '' then return end
    amount = tonumber(amount) or 0
    if amount <= 0 then return end

    local live = _live[mobName]
    if not live then
        live = { dmgSince = 0, estSum = 0, weightSum = 0 }
        _live[mobName] = live
    end

    local pct = resolvePct(mobName, live)
    if not pct then
        -- Can't pair against HP% right now; still accumulate against the anchor
        if live.anchorPct then
            live.dmgSince = live.dmgSince + amount
        end
        return
    end

    if not live.anchorPct then
        -- First sighting: anchor at the current pct. This hit is already
        -- reflected in the pct we just read, so it must not count toward the
        -- next delta.
        live.anchorPct = pct
        live.dmgSince = 0
        live.lastPct = pct
        return
    end

    live.dmgSince = live.dmgSince + amount

    if pct > live.anchorPct + 1 then
        -- Mob got healed/regenerated past the anchor - restart pairing
        live.anchorPct = pct
        live.dmgSince = 0
    elseif (live.anchorPct - pct) >= MIN_DELTA_PCT then
        local delta = live.anchorPct - pct
        local est = live.dmgSince / (delta / 100)
        if est >= MIN_SANE_HP and est <= MAX_SANE_HP then
            local weight = math.min(delta / FULL_WEIGHT_DELTA, 1.0)
            live.estSum = live.estSum + est * weight
            live.weightSum = live.weightSum + weight
        end
        live.anchorPct = pct
        live.dmgSince = 0
    end

    live.lastPct = pct
end

-------------------------------------------------------------------------------
-- Queries
-------------------------------------------------------------------------------

--- Get the estimated max HP for a mob
-- @param mobNameOrId string|number Mob name or spawn ID
-- @return number|nil maxHP Estimated max HP
-- @return number weight Confidence weight (higher = more observed HP% covered)
function M.getMaxHP(mobNameOrId)
    local name = mobNameOrId
    if type(mobNameOrId) == 'number' then
        local ok, resolved = pcall(function()
            local s = mq.TLO.Spawn(mobNameOrId)
            return s and s() and s.CleanName() or nil
        end)
        name = ok and resolved or nil
    end
    if not name or name == '' then return nil, 0 end

    local liveEst, liveW = nil, 0
    local live = _live[name]
    if live and (live.weightSum or 0) > 0 then
        liveEst = live.estSum / live.weightSum
        liveW = live.weightSum
    end

    local stored = M.zoneEstimates[name]
    local storedEst = stored and stored.maxHP or nil
    local storedW = stored and stored.weight or 0

    if liveEst and storedEst then
        local totalW = liveW + storedW
        return (liveEst * liveW + storedEst * storedW) / totalW, totalW
    end
    if liveEst or storedEst then
        return liveEst or storedEst, liveEst and liveW or storedW
    end

    -- No local data: fall back to the group's damage observer (the tank sees
    -- everyone's damage; lean-scope characters only see their own)
    local Actors = getActors()
    if Actors and Actors.getRemoteMobHp then
        local ok, remoteEst, remoteW = pcall(Actors.getRemoteMobHp, name)
        if ok and remoteEst then
            return remoteEst, remoteW or 0
        end
    end
    return nil, 0
end

--- Get the estimated REMAINING HP for a mob
-- @param mobId number Spawn ID
-- @return number|nil remainingHP
-- @return number weight Confidence weight
function M.getRemainingHP(mobId)
    if not mobId or mobId <= 0 then return nil, 0 end

    local ok, info = pcall(function()
        local s = mq.TLO.Spawn(mobId)
        if s and s() then
            return { name = s.CleanName(), pct = tonumber(s.PctHPs()) }
        end
        return nil
    end)
    if not ok or not info or not info.name or not info.pct then return nil, 0 end

    local maxHP, weight = M.getMaxHP(info.name)
    if not maxHP then return nil, 0 end
    return maxHP * (info.pct / 100), weight
end

-------------------------------------------------------------------------------
-- Maintenance
-------------------------------------------------------------------------------

--- Share current estimates for engaged mobs (observer-side; throttled)
local function shareEstimates(now)
    local de = getDamageEvents()
    if not de or de.getScope() ~= 'full' then return end
    if (now - _lastShare) < SHARE_INTERVAL_MS then return end
    _lastShare = now

    local Actors = getActors()
    if not Actors or not Actors.broadcastMobHp then return end

    local estimates = {}
    local found = false
    local ok = pcall(function()
        local xtCount = tonumber(mq.TLO.Me.XTarget()) or 0
        for i = 1, xtCount do
            local xt = mq.TLO.Me.XTarget(i)
            if xt and xt() and xt.ID() and xt.ID() > 0 then
                local name = (xt.CleanName and xt.CleanName()) or ''
                if name ~= '' and not estimates[name] then
                    local maxHP, weight = M.getMaxHP(name)
                    if maxHP then
                        estimates[name] = { maxHP = maxHP, weight = weight }
                        found = true
                    end
                end
            end
        end
    end)
    if ok and found then
        pcall(Actors.broadcastMobHp, estimates)
    end
end

--- Expire stale live entries (merging their learning) and periodic save
function M.tick()
    local now = mq.gettime()

    shareEstimates(now)

    for name, live in pairs(_live) do
        if (now - (live.lastSeen or now)) > LIVE_TTL_MS then
            mergeToDatabase(name, live)
            _live[name] = nil
        end
    end

    if M.dirty and (now - _lastSave) >= SAVE_INTERVAL_MS then
        _lastSave = now
        -- Fold current live learning in before writing so restarts lose nothing
        for name, live in pairs(_live) do
            if (live.weightSum or 0) > 0 then
                mergeToDatabase(name, live)
                live.estSum = 0
                live.weightSum = 0
            end
        end
        M.saveDatabase()
    end
end

--- Merge live learning into the database and save immediately (used by exports)
function M.flush()
    for name, live in pairs(_live) do
        if (live.weightSum or 0) > 0 then
            mergeToDatabase(name, live)
            live.estSum = 0
            live.weightSum = 0
        end
    end
    M.saveDatabase()
end

function M.init()
    M.loadDatabase()
    M.loadZone()

    local DamageEvents = getDamageEvents()
    if DamageEvents then
        DamageEvents.addListener(function(event)
            M.observe(event.target, event.amount)
        end)
    end
end

function M.shutdown()
    M.flush()
    _live = {}
end

return M
