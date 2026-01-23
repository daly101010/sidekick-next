-- F:\lua\SideKick\automation\cc.lua
-- Crowd Control tracking and broadcasting
-- Broadcasts mezzed mob list to group, receives from other mezzers

local mq = require('mq')

local M = {}

-- Lazy-load Actors to avoid circular requires
local _Actors = nil
local function getActors()
    if not _Actors then
        local ok, a = pcall(require, 'sidekick-next.utils.actors_coordinator')
        if ok then _Actors = a end
    end
    return _Actors
end

-- Lazy-load runtime cache for fallback checks
local _Cache = nil
local function getCache()
    if not _Cache then
        local ok, c = pcall(require, 'sidekick-next.utils.runtime_cache')
        if ok then _Cache = c end
    end
    return _Cache
end

-- Local mez tracking (mobs we mezzed)
M.localMezzes = {}  -- { [mobId] = { expires = os.clock(), name = 'mob name' } }

-- Remote mez tracking (mobs others mezzed)
M.remoteMezzes = {}  -- { [mobId] = { expires = os.clock(), name = 'mob name', mezzer = 'name' } }

-- Combined view (for checking)
M.allMezzes = {}  -- merged view, updated each tick

-- Mez target claims (before casting, claim target so others don't try)
M.localClaims = {}   -- { [mobId] = { claimedAt = os.clock(), name = 'mob name' } }
M.remoteClaims = {}  -- { [mobId] = { claimedAt = os.clock(), name = 'mob name', claimer = 'name' } }

-- Timing
local _lastBroadcast = 0
local _lastCleanup = 0
local _lastClaimBroadcast = 0
local BROADCAST_INTERVAL = 1.0  -- Broadcast every 1 second
local CLEANUP_INTERVAL = 0.5    -- Clean expired every 500ms
local CLAIM_TIMEOUT = 5.0       -- Claims expire after 5 seconds if mez not landed
local MEZ_DURATION_DEFAULT = 18 -- Default mez duration if unknown
local _eventsRegistered = false
local _selfName = ''

local function trim(s)
    s = tostring(s or '')
    s = s:gsub('^%s+', ''):gsub('%s+$', '')
    return s
end

local function findMobIdByName(mobName)
    mobName = trim(mobName)
    if mobName == '' then return nil end
    local mobLower = mobName:lower()

    local Cache = getCache()
    for _, hater in pairs((Cache and Cache.xtarget and Cache.xtarget.haters) or {}) do
        if tostring(hater.name or ''):lower() == mobLower then
            local id = tonumber(hater.id)
            if id and id > 0 then return id end
        end
    end

    local t = mq.TLO.Target
    if t and t() and t.CleanName and tostring(t.CleanName() or ''):lower() == mobLower then
        local id = tonumber(t.ID and t.ID() or 0) or 0
        if id > 0 then return id end
    end

    return nil
end

function M.init()
    M.localMezzes = {}
    M.remoteMezzes = {}
    M.allMezzes = {}
    M.localClaims = {}
    M.remoteClaims = {}

    _selfName = (mq.TLO.Me and mq.TLO.Me.CleanName and mq.TLO.Me.CleanName()) or ''

    -- Best-effort local mez tracking via combat text events (ENC/BRD/NEC).
    if not _eventsRegistered and mq and mq.event and mq.TLO and mq.TLO.Me and mq.TLO.Me.Class and mq.TLO.Me.Class.ShortName then
        local cls = tostring(mq.TLO.Me.Class.ShortName() or ''):upper()
        local isMezzer = (cls == 'ENC' or cls == 'BRD' or cls == 'NEC')
        if isMezzer then
            -- Conservative TTL: prefer overestimating to avoid mez breaks.
            MEZ_DURATION_DEFAULT = 60

            mq.event('sidekick_cc_mezzed', '#1# has been mesmerized#*#', function(_, mobName)
                local id = findMobIdByName(mobName)
                if id then
                    M.trackLocalMez(id, mobName, MEZ_DURATION_DEFAULT)
                    -- Release claim once mez lands
                    M.releaseClaim(id)
                end
            end)

            mq.event('sidekick_cc_mezwoke', '#1# has been awakened by#*#', function(_, mobName)
                local id = findMobIdByName(mobName)
                if id then
                    M.removeMez(id)
                end
            end)

            _eventsRegistered = true
        end
    end
end

function M.tick()
    local now = os.clock()

    -- Cleanup expired mezzes
    if (now - _lastCleanup) >= CLEANUP_INTERVAL then
        _lastCleanup = now
        M.cleanupExpired()
    end

    -- Broadcast local mezzes if we have any
    if (now - _lastBroadcast) >= BROADCAST_INTERVAL then
        _lastBroadcast = now
        M.broadcastMezList()
    end

    -- Merge local + remote into allMezzes
    M.mergeAllMezzes()
end

function M.cleanupExpired()
    local now = os.clock()

    for mobId, data in pairs(M.localMezzes) do
        if now >= data.expires then
            M.localMezzes[mobId] = nil
        end
    end

    for mobId, data in pairs(M.remoteMezzes) do
        if now >= data.expires then
            M.remoteMezzes[mobId] = nil
        end
    end

    -- Cleanup expired claims
    for mobId, data in pairs(M.localClaims) do
        if (now - data.claimedAt) >= CLAIM_TIMEOUT then
            M.localClaims[mobId] = nil
        end
    end

    for mobId, data in pairs(M.remoteClaims) do
        if (now - data.claimedAt) >= CLAIM_TIMEOUT then
            M.remoteClaims[mobId] = nil
        end
    end
end

function M.mergeAllMezzes()
    M.allMezzes = {}

    for mobId, data in pairs(M.localMezzes) do
        M.allMezzes[mobId] = data
    end

    for mobId, data in pairs(M.remoteMezzes) do
        if not M.allMezzes[mobId] or data.expires > M.allMezzes[mobId].expires then
            M.allMezzes[mobId] = data
        end
    end
end

function M.broadcastMezList()
    -- Only broadcast if we have local mezzes
    if not next(M.localMezzes) then return end

    local Actors = getActors()
    if not Actors or not Actors.broadcast then return end

    local now = os.clock()
    local mezList = {}
    for mobId, data in pairs(M.localMezzes) do
        local expires = tonumber(data.expires) or 0
        local ttl = expires - now
        if ttl > 0 then
        mezList[mobId] = {
            -- Prefer ttl-based sync across clients; absolute expires is process-local (os.clock).
            ttl = ttl,
            expires = expires,
            name = data.name,
        }
        end
    end

    Actors.broadcast('cc:mezlist', {
        mobs = mezList,
        sender = mq.TLO.Me.CleanName(),
        timestamp = now, -- sender-local os.clock (paired with expires for backward compatibility)
    })
end

--- Track a mez we just cast
-- @param mobId number Mob spawn ID
-- @param mobName string Mob name
-- @param duration number Mez duration in seconds (optional)
function M.trackLocalMez(mobId, mobName, duration)
    if not mobId or mobId == 0 then return end

    duration = duration or MEZ_DURATION_DEFAULT

    M.localMezzes[tonumber(mobId)] = {
        expires = os.clock() + duration,
        name = mobName or '',
    }
end

--- Remove a mez (mob died or mez broken)
-- @param mobId number Mob spawn ID
function M.removeMez(mobId)
    local id = tonumber(mobId)
    if not id then return end
    M.localMezzes[id] = nil
    M.remoteMezzes[id] = nil
    M.allMezzes[id] = nil
end

--- Receive mez list from another player (called by Actors handler)
-- @param payload table Message payload with mobs, sender, timestamp
function M.receiveMezList(payload)
    local mobs = payload.mobs or {}
    local sender = payload.sender or payload.from or 'unknown'
    local recvNow = os.clock()
    local sentAt = tonumber(payload.timestamp) -- sender-local os.clock (only valid as a delta with expires)

    for mobId, data in pairs(mobs) do
        local id = tonumber(mobId)
        if id and id > 0 then
            local ttl = tonumber(data.ttl)
            if (ttl == nil or ttl <= 0) and data.expires and sentAt then
                ttl = (tonumber(data.expires) or 0) - sentAt
            end
            -- Last-resort compatibility: if expires looks like a small TTL, accept it.
            if (ttl == nil or ttl <= 0) and data.expires then
                local maybe = tonumber(data.expires) or 0
                if maybe > 0 and maybe <= 120 then
                    ttl = maybe
                end
            end

            if not ttl or ttl <= 0 then
                goto continue
            end

            M.remoteMezzes[id] = {
                expires = recvNow + ttl,
                name = data.name or '',
                mezzer = sender,
            }
        end
        ::continue::
    end
end

--- Check if a mob is mezzed (by anyone)
-- @param mobId number Mob spawn ID
-- @return boolean True if mezzed
function M.isMobMezzed(mobId)
    if not mobId then return false end
    local id = tonumber(mobId)
    if not id then return false end

    local data = M.allMezzes[id]
    if data and os.clock() < (tonumber(data.expires) or 0) then
        return true
    end

    -- Fallback: consult runtime cache's XTarget mezzed flag (less reliable, but better than "always false").
    local Cache = getCache()
    for _, hater in pairs((Cache and Cache.xtarget and Cache.xtarget.haters) or {}) do
        if hater.id == id and hater.mezzed == true then
            return true
        end
    end

    return false
end

--- Check if any XTarget mob is mezzed
-- @return boolean True if any XTarget mob is mezzed
function M.hasAnyMezzedOnXTarget()
    local Cache = getCache()
    local haters = Cache and Cache.xtarget and Cache.xtarget.haters or nil
    if not haters then return false end

    local now = os.clock()
    for _, hater in pairs(haters) do
        local id = tonumber(hater.id)
        if id and id > 0 then
            if hater.mezzed == true then
                return true
            end
            local data = M.allMezzes[id]
            if data and now < (tonumber(data.expires) or 0) then
                return true
            end
        end
    end

    return false
end

--- Get list of mezzed mob IDs on XTarget
-- @return table Array of mezzed mob IDs
function M.getMezzedOnXTarget()
    local result = {}
    local Cache = getCache()
    local haters = Cache and Cache.xtarget and Cache.xtarget.haters or nil
    if not haters then return result end

    local now = os.clock()
    for _, hater in pairs(haters) do
        local id = tonumber(hater.id)
        if id and id > 0 then
            if hater.mezzed == true then
                table.insert(result, id)
            else
                local data = M.allMezzes[id]
                if data and now < (tonumber(data.expires) or 0) then
                    table.insert(result, id)
                end
            end
        end
    end

    return result
end

--- Get count of mezzed mobs
-- @return number local count, number remote count, number total count
function M.getCounts()
    local localCount = 0
    local remoteCount = 0

    for _ in pairs(M.localMezzes) do localCount = localCount + 1 end
    for _ in pairs(M.remoteMezzes) do remoteCount = remoteCount + 1 end

    local totalCount = 0
    for _ in pairs(M.allMezzes) do totalCount = totalCount + 1 end

    return localCount, remoteCount, totalCount
end

--------------------------------------------------------------------------------
-- Claim System: Coordinate who is mezzing what target
--------------------------------------------------------------------------------

--- Claim a target for mez (broadcast to other mezzers)
-- Call this BEFORE casting mez to prevent duplicate mezzes
-- @param mobId number Mob spawn ID
-- @param mobName string|nil Mob name (optional)
-- @return boolean True if claim successful, false if already claimed by another
function M.claimTarget(mobId, mobName)
    if not mobId or mobId == 0 then return false end
    local id = tonumber(mobId)
    if not id then return false end

    -- Already claimed by someone else?
    if M.isTargetClaimed(id) then
        return false
    end

    -- Already mezzed?
    if M.isMobMezzed(id) then
        return false
    end

    -- Claim it
    M.localClaims[id] = {
        claimedAt = os.clock(),
        name = mobName or '',
    }

    -- Broadcast claim immediately
    M.broadcastClaim(id, mobName)
    return true
end

--- Release a claim (after mez lands or target dies)
-- @param mobId number Mob spawn ID
function M.releaseClaim(mobId)
    if not mobId then return end
    local id = tonumber(mobId)
    if not id then return end

    M.localClaims[id] = nil
    -- Don't remove remote claims, let them expire
end

--- Check if a target is claimed by someone else (not us)
-- @param mobId number Mob spawn ID
-- @return boolean True if claimed by another mezzer
-- @return string|nil Claimer name if claimed
function M.isTargetClaimed(mobId)
    if not mobId then return false, nil end
    local id = tonumber(mobId)
    if not id then return false, nil end

    local now = os.clock()

    -- Check remote claims (other mezzers)
    local remoteClaim = M.remoteClaims[id]
    if remoteClaim and (now - remoteClaim.claimedAt) < CLAIM_TIMEOUT then
        return true, remoteClaim.claimer
    end

    return false, nil
end

--- Check if we have claimed a target
-- @param mobId number Mob spawn ID
-- @return boolean True if we claimed it
function M.didWeClaim(mobId)
    if not mobId then return false end
    local id = tonumber(mobId)
    if not id then return false end

    local localClaim = M.localClaims[id]
    if localClaim and (os.clock() - localClaim.claimedAt) < CLAIM_TIMEOUT then
        return true
    end
    return false
end

--- Broadcast a claim to other mezzers
-- @param mobId number Mob spawn ID
-- @param mobName string|nil Mob name
function M.broadcastClaim(mobId, mobName)
    local Actors = getActors()
    if not Actors or not Actors.broadcast then return end

    Actors.broadcast('cc:claim', {
        mobId = mobId,
        mobName = mobName or '',
        claimer = _selfName,
        claimedAt = os.clock(),
    })
end

--- Receive a claim from another mezzer (called by Actors handler)
-- @param payload table Message payload
function M.receiveClaim(payload)
    local mobId = tonumber(payload.mobId)
    if not mobId or mobId == 0 then return end

    local claimer = payload.claimer or payload.from or 'unknown'

    -- Don't process our own claims
    if claimer == _selfName then return end

    M.remoteClaims[mobId] = {
        claimedAt = os.clock(),
        name = payload.mobName or '',
        claimer = claimer,
    }
end

--- Get best mez target from XTarget (unmezzed, unclaimed, lowest HP first)
-- @param maxTargets number|nil Max targets to check (default all)
-- @return number|nil Mob ID to mez, or nil if none available
-- @return string|nil Mob name
function M.getBestMezTarget(maxTargets)
    local Cache = getCache()
    local haters = Cache and Cache.xtarget and Cache.xtarget.haters or nil
    if not haters then return nil, nil end

    -- Build list of valid targets
    local candidates = {}
    local primaryTarget = nil

    -- Get primary target to exclude it
    if Cache and Cache.target then
        primaryTarget = Cache.target.id
    end

    for _, hater in pairs(haters) do
        local id = tonumber(hater.id)
        if id and id > 0 and id ~= primaryTarget then
            -- Skip if already mezzed
            if not M.isMobMezzed(id) then
                -- Skip if claimed by another
                local claimed, _ = M.isTargetClaimed(id)
                if not claimed then
                    table.insert(candidates, {
                        id = id,
                        name = hater.name or '',
                        hp = hater.hp or 100,
                        distance = hater.distance or 999,
                    })
                end
            end
        end
    end

    -- Sort by HP (lowest first - most dangerous), then by distance
    table.sort(candidates, function(a, b)
        if a.hp ~= b.hp then
            return a.hp < b.hp
        end
        return a.distance < b.distance
    end)

    if #candidates > 0 then
        return candidates[1].id, candidates[1].name
    end

    return nil, nil
end

--- Get all available mez targets (unmezzed, unclaimed)
-- @return table Array of { id = mobId, name = mobName, hp = hp }
function M.getAvailableMezTargets()
    local Cache = getCache()
    local haters = Cache and Cache.xtarget and Cache.xtarget.haters or nil
    if not haters then return {} end

    local candidates = {}
    local primaryTarget = nil

    if Cache and Cache.target then
        primaryTarget = Cache.target.id
    end

    for _, hater in pairs(haters) do
        local id = tonumber(hater.id)
        if id and id > 0 and id ~= primaryTarget then
            if not M.isMobMezzed(id) then
                local claimed, _ = M.isTargetClaimed(id)
                if not claimed then
                    table.insert(candidates, {
                        id = id,
                        name = hater.name or '',
                        hp = hater.hp or 100,
                        distance = hater.distance or 999,
                    })
                end
            end
        end
    end

    return candidates
end

--------------------------------------------------------------------------------
-- Mez Casting Functions
--------------------------------------------------------------------------------

-- Lazy-load Core for settings
local _Core = nil
local function getCore()
    if not _Core then
        local ok, c = pcall(require, 'sidekick-next.utils.core')
        if ok then _Core = c end
    end
    return _Core
end

-- Lazy-load SpellEngine for casting
local _SpellEngine = nil
local function getSpellEngine()
    if not _SpellEngine then
        local ok, se = pcall(require, 'sidekick-next.utils.spell_engine')
        if ok then _SpellEngine = se end
    end
    return _SpellEngine
end

-- Mez casting state
local _mezCastState = {
    lastMezAttemptAt = 0,
    lastMezDecisionAt = 0,
    currentMezTarget = nil,
}

-- Mez class profiles (spell lines to use)
local _mezProfiles = {
    ENC = {
        main = { 'MezSpell' },
        fast = { 'MezSpellFast' },
        ae = { 'MezAESpell' },
        aeFast = { 'MezAESpellFast' },
    },
    BRD = {
        main = { 'MezSong' },
        ae = { 'MezAESong' },
    },
    -- NEC has fear/charm but not true mez; exclude from active mezzing
}

-- Helper: check if spell is memorized
local function spellMemorized(spellName)
    if not spellName or spellName == '' then return false end
    local me = mq.TLO.Me
    if not (me and me()) then return false end
    local gems = tonumber(me.NumGems()) or 13
    for i = 1, gems do
        local gem = me.Gem(i)
        if gem and gem() and (gem.Name() or '') == spellName then
            return true
        end
    end
    return false
end

-- Helper: load class config for class
local function loadClassConfig(classShort)
    local ok, config = pcall(require, string.format('data.class_configs.%s', classShort))
    if ok then return config end
    return nil
end

-- Helper: resolve best memorized spell from a line
local function resolveSpellLine(classConfig, lineName)
    if not classConfig or not classConfig.spellLines or not lineName then return nil end
    local line = classConfig.spellLines[lineName]
    if type(line) ~= 'table' then return nil end
    for _, name in ipairs(line) do
        if spellMemorized(name) then
            return name
        end
    end
    return nil
end

-- Helper: choose spell from profile
local function chooseSpellForLines(classConfig, lines)
    for _, lineName in ipairs(lines or {}) do
        local spellName = resolveSpellLine(classConfig, lineName)
        if spellName and spellName ~= '' then
            return spellName
        end
    end
    return nil
end

-- Helper: get mez duration from spell
local function getMezDuration(spellName)
    if not spellName or spellName == '' then return MEZ_DURATION_DEFAULT end
    local spell = mq.TLO.Spell(spellName)
    if not (spell and spell()) then return MEZ_DURATION_DEFAULT end
    if spell.Duration and spell.Duration.TotalSeconds then
        local ok, v = pcall(function() return spell.Duration.TotalSeconds() end)
        if ok and v and tonumber(v) > 0 then
            return tonumber(v)
        end
    end
    return MEZ_DURATION_DEFAULT
end

-- Helper: check if target is valid for mezzing
local function isValidMezTarget(mobId, settings)
    if not mobId or mobId == 0 then return false end

    local spawn = mq.TLO.Spawn(mobId)
    if not spawn or not spawn() then return false end
    if spawn.Dead() then return false end

    -- Check level (skip grey cons)
    local minLevel = tonumber(settings.MezMinLevel) or 0
    if minLevel > 0 then
        local mobLevel = tonumber(spawn.Level()) or 0
        if mobLevel < minLevel then
            return false
        end
    end

    -- Check distance (within spell range)
    local distance = tonumber(spawn.Distance()) or 999
    if distance > 200 then return false end

    -- Check line of sight
    if not spawn.LineOfSight() then return false end

    return true
end

-- Helper: get number of targets in AE range
local function getAETargetCount(centerMobId)
    local Cache = getCache()
    local haters = Cache and Cache.xtarget and Cache.xtarget.haters or nil
    if not haters then return 0 end

    local centerSpawn = mq.TLO.Spawn(centerMobId)
    if not centerSpawn or not centerSpawn() then return 0 end

    local centerX = tonumber(centerSpawn.X()) or 0
    local centerY = tonumber(centerSpawn.Y()) or 0
    local aeRange = 30 -- Typical AE mez range

    local count = 0
    for _, hater in pairs(haters) do
        local id = tonumber(hater.id)
        if id and id > 0 and not M.isMobMezzed(id) then
            local spawn = mq.TLO.Spawn(id)
            if spawn and spawn() then
                local x = tonumber(spawn.X()) or 0
                local y = tonumber(spawn.Y()) or 0
                local dist = math.sqrt((x - centerX)^2 + (y - centerY)^2)
                if dist <= aeRange then
                    count = count + 1
                end
            end
        end
    end

    return count
end

--- Check if current character is a mez-capable class
-- @return boolean True if ENC or BRD (NEC excluded from active mezzing)
function M.isMezClass()
    local me = mq.TLO.Me
    if not (me and me()) then return false end
    local cls = tostring(me.Class.ShortName() or ''):upper()
    return cls == 'ENC' or cls == 'BRD'
end

--- Get mez remaining time for a target (for remez decisions)
-- @param mobId number Mob spawn ID
-- @return number Seconds remaining on mez, 0 if not mezzed
function M.getMezTimeRemaining(mobId)
    if not mobId then return 0 end
    local id = tonumber(mobId)
    if not id then return 0 end

    local data = M.allMezzes[id]
    if data then
        local remaining = (tonumber(data.expires) or 0) - os.clock()
        if remaining > 0 then
            return remaining
        end
    end
    return 0
end

--- Check if we need to remez a target
-- @param mobId number Mob spawn ID
-- @param refreshWindow number Seconds before expiry to remez
-- @return boolean True if target needs remez
function M.needsRemez(mobId, refreshWindow)
    refreshWindow = refreshWindow or 6
    local remaining = M.getMezTimeRemaining(mobId)
    if remaining > 0 and remaining <= refreshWindow then
        return true
    end
    return false
end

--- Cast mez on a target
-- Uses SpellEngine for casting management
-- @param mobId number Target mob ID
-- @param mobName string Target mob name
-- @param spellName string Mez spell to cast
-- @param opts table|nil Options
-- @return boolean True if cast initiated
-- @return string|nil Error reason if false
function M.castMez(mobId, mobName, spellName, opts)
    opts = opts or {}

    if not mobId or mobId == 0 then
        return false, 'invalid_target'
    end

    if not spellName or spellName == '' then
        return false, 'no_spell'
    end

    local SpellEngine = getSpellEngine()
    if not SpellEngine then
        return false, 'no_spell_engine'
    end

    -- Check if SpellEngine is busy
    if SpellEngine.isBusy and SpellEngine.isBusy() then
        return false, 'spell_engine_busy'
    end

    -- Check if we're already casting (Casting() returns spell name string, empty if not)
    local me = mq.TLO.Me
    local casting = me and me.Casting() or ''
    if casting ~= '' then
        return false, 'already_casting'
    end

    -- Claim the target before casting
    if not M.claimTarget(mobId, mobName) then
        return false, 'target_claimed'
    end

    -- Initiate cast
    local success, reason = SpellEngine.cast(spellName, mobId, {
        spellCategory = 'mez',
        allowDead = false,
    })

    if success then
        _mezCastState.lastMezAttemptAt = os.clock()
        _mezCastState.currentMezTarget = mobId
    else
        -- Release claim on failure
        M.releaseClaim(mobId)
    end

    return success, reason
end

--- Main mez tick function - call this from main loop
-- Checks conditions, selects targets, and initiates mez casts
-- @param settings table Settings table with mez options
-- @return boolean True if mez action was taken or pending
function M.mezTick(settings)
    settings = settings or {}
    local Core = getCore()
    if Core and Core.Settings then
        -- Merge Core.Settings as fallback
        for k, v in pairs(Core.Settings) do
            if settings[k] == nil then
                settings[k] = v
            end
        end
    end

    -- Check if mezzing is enabled
    if settings.MezzingEnabled ~= true then
        return false
    end

    -- Only mez classes should mez
    if not M.isMezClass() then
        return false
    end

    local me = mq.TLO.Me
    if not (me and me()) then return false end

    -- Check if we can cast (not stunned, mezzed, etc.)
    if me.Stunned() or (me.Mezzed and me.Mezzed()) or (me.Silenced and me.Silenced()) then
        return false
    end

    -- Don't mez while moving (except for bards)
    local cls = tostring(me.Class.ShortName() or ''):upper()
    if cls ~= 'BRD' and me.Moving() then
        return false
    end

    -- Check if SpellEngine is busy
    local SpellEngine = getSpellEngine()
    if SpellEngine and SpellEngine.isBusy and SpellEngine.isBusy() then
        return true -- Spell in progress
    end

    -- Throttle decision making
    local now = os.clock()
    if (now - (_mezCastState.lastMezDecisionAt or 0)) < 0.2 then
        return false
    end
    _mezCastState.lastMezDecisionAt = now

    -- Get class profile and class config
    local profile = _mezProfiles[cls]
    if not profile then
        return false
    end

    local classConfig = loadClassConfig(cls)
    if not classConfig then
        return false
    end

    -- Count current mezzed targets
    local localCount, _, totalCount = M.getCounts()
    local maxTargets = tonumber(settings.MezMaxTargets) or 3

    -- Check if we're at max mez targets
    if totalCount >= maxTargets then
        -- Check for remez on existing targets
        local refreshWindow = tonumber(settings.MezRefreshWindow) or 6
        for mobId, data in pairs(M.localMezzes) do
            if M.needsRemez(mobId, refreshWindow) then
                -- Remez this target
                local spellName = chooseSpellForLines(classConfig, settings.UseFastMez and profile.fast or profile.main)
                if not spellName then
                    spellName = chooseSpellForLines(classConfig, profile.main)
                end
                if spellName and isValidMezTarget(mobId, settings) then
                    return M.castMez(mobId, data.name, spellName)
                end
            end
        end
        return false
    end

    -- Get best mez target
    local targetId, targetName = M.getBestMezTarget(maxTargets)
    if not targetId then
        return false
    end

    -- Validate target
    if not isValidMezTarget(targetId, settings) then
        return false
    end

    -- Check for AE mez opportunity
    local useAEMez = settings.UseAEMez == true
    local aeMinTargets = tonumber(settings.AEMezMinTargets) or 3
    local spellName = nil

    if useAEMez and profile.ae then
        local aeCount = getAETargetCount(targetId)
        if aeCount >= aeMinTargets then
            -- Use AE mez
            spellName = chooseSpellForLines(classConfig, profile.aeFast or profile.ae)
            if not spellName then
                spellName = chooseSpellForLines(classConfig, profile.ae)
            end
        end
    end

    -- Fall back to single target mez
    if not spellName then
        if settings.UseFastMez and profile.fast then
            spellName = chooseSpellForLines(classConfig, profile.fast)
        end
        if not spellName then
            spellName = chooseSpellForLines(classConfig, profile.main)
        end
    end

    if not spellName then
        return false
    end

    -- Cast the mez
    local success, reason = M.castMez(targetId, targetName, spellName)
    return success
end

return M
