-- Debuff coordination: Actor-based claim system to prevent duplicate debuffs
-- Tracks slow, cripple, tash, malo, and snare independently across peers.

local mq = require('mq')
local lazy = require('sidekick-next.utils.lazy_require')
local CoordinationPolicy = require('sidekick-next.utils.coordination_policy')

local M = {}

-- Lazy-load Actors to avoid circular requires
local getActors = lazy('sidekick-next.utils.actors_coordinator')

-- Lazy-load runtime cache
local getCache = lazy('sidekick-next.utils.runtime_cache')

-- Debuff types we track
M.DEBUFF_TYPES = {
    'slow',      -- Shaman, Enchanter
    'cripple',   -- Shaman
    'tash',      -- Enchanter
    'malo',      -- Shaman, Mage
    'snare',     -- Various
}

-- Local debuff tracking (debuffs we applied)
M.localDebuffs = {}  -- { [mobId] = { [debuffType] = { appliedAt, expiresAt, spellName } } }

-- Remote debuff tracking (debuffs others applied)
M.remoteDebuffs = {}  -- { [mobId] = { [debuffType] = { appliedAt, expiresAt, applier, spellName } } }

-- Debuff claims (before casting, claim so others don't try)
M.localClaims = {}   -- { [mobId] = { [debuffType] = { claimedAt } } }
M.remoteClaims = {}  -- { [mobId] = { [debuffType] = { claimedAt, claimer } } }
M.lastPeerBlock = nil

-- Timing
local _lastCleanup = 0
local CLEANUP_INTERVAL = 1.0     -- Clean expired every 1 second
local CLAIM_TIMEOUT = CoordinationPolicy.CLAIM_TTL_SECONDS.DEBUFF
local DEBUFF_DURATION_DEFAULT = 60  -- Default debuff duration

local _selfName = ''
local _isDebuffer = false
local _lastClaimBroadcast = {}

-- Debuff classes
local DEBUFFER_CLASSES = {
    SHM = { slow = true, cripple = true, malo = true },
    ENC = { slow = true, tash = true },
    MAG = { malo = true },
}

function M.init()
    M.localDebuffs = {}
    M.remoteDebuffs = {}
    M.localClaims = {}
    M.remoteClaims = {}
    _lastClaimBroadcast = {}
    M.lastPeerBlock = nil

    _selfName = (mq.TLO.Me and mq.TLO.Me.CleanName and mq.TLO.Me.CleanName()) or ''
end

function M.tick()
    local now = os.clock()

    -- Cleanup expired
    if (now - _lastCleanup) >= CLEANUP_INTERVAL then
        _lastCleanup = now
        M.cleanupExpired()
    end
end

function M.cleanupExpired()
    local now = os.clock()

    -- Clean expired local debuffs
    for mobId, debuffs in pairs(M.localDebuffs) do
        for debuffType, data in pairs(debuffs) do
            if data.expiresAt and now >= data.expiresAt then
                debuffs[debuffType] = nil
            end
        end
        if not next(debuffs) then
            M.localDebuffs[mobId] = nil
        end
    end

    -- Clean expired remote debuffs
    for mobId, debuffs in pairs(M.remoteDebuffs) do
        for debuffType, data in pairs(debuffs) do
            if data.expiresAt and now >= data.expiresAt then
                debuffs[debuffType] = nil
            end
        end
        if not next(debuffs) then
            M.remoteDebuffs[mobId] = nil
        end
    end

    -- Clean expired local claims
    for mobId, claims in pairs(M.localClaims) do
        for debuffType, data in pairs(claims) do
            if (now - data.claimedAt) >= CLAIM_TIMEOUT then
                claims[debuffType] = nil
            end
        end
        if not next(claims) then
            M.localClaims[mobId] = nil
        end
    end

    -- Clean expired remote claims
    for mobId, claims in pairs(M.remoteClaims) do
        for debuffType, data in pairs(claims) do
            local active = CoordinationPolicy.evaluateLocalClaim(
                getActors(), data, CLAIM_TIMEOUT, now)
            if not active then
                claims[debuffType] = nil
            end
        end
        if not next(claims) then
            M.remoteClaims[mobId] = nil
        end
    end
end

--------------------------------------------------------------------------------
-- Claim System
--------------------------------------------------------------------------------

--- Claim a debuff target (broadcast to other debuffers)
-- Call BEFORE casting debuff to prevent duplicates
-- @param mobId number Mob spawn ID
-- @param debuffType string 'slow', 'cripple', 'tash', 'malo', 'snare'
-- @return boolean True if claim successful
function M.claimDebuff(mobId, debuffType)
    if not mobId or mobId == 0 then return false end
    local id = tonumber(mobId)
    if not id then return false end

    debuffType = tostring(debuffType or ''):lower()
    if debuffType == '' then return false end

    -- Already claimed by someone else?
    if M.isDebuffClaimed(id, debuffType) then
        return false
    end

    -- Already has this debuff?
    if M.hasDebuff(id, debuffType) then
        return false
    end

    -- Claim it
    M.localClaims[id] = M.localClaims[id] or {}
    M.localClaims[id][debuffType] = {
        claimedAt = os.clock(),
    }

    -- Broadcast claim immediately
    M.broadcastClaim(id, debuffType)
    return true
end

--- Return true only while this process still owns the peer reservation.
function M.ownsClaim(mobId, debuffType)
    local id = tonumber(mobId)
    debuffType = tostring(debuffType or ''):lower()
    if not id or id <= 0 or debuffType == '' then return false end
    local claim = M.localClaims[id] and M.localClaims[id][debuffType]
    return claim ~= nil and (os.clock() - (claim.claimedAt or 0)) < CLAIM_TIMEOUT
end

--- Refresh an owned reservation while waiting for or holding the local lease.
function M.renewClaim(mobId, debuffType)
    local id = tonumber(mobId)
    debuffType = tostring(debuffType or ''):lower()
    if not id or id <= 0 or debuffType == '' then return false end
    local claim = M.localClaims[id] and M.localClaims[id][debuffType]
    if not claim then return false end
    claim.claimedAt = os.clock()
    local key = tostring(id) .. ':' .. debuffType
    if (os.clock() - (_lastClaimBroadcast[key] or 0)) >= 2.0 then
        _lastClaimBroadcast[key] = os.clock()
        M.broadcastClaim(id, debuffType)
    end
    return true
end

--- Release a claim
-- @param mobId number Mob spawn ID
-- @param debuffType string|nil Debuff type (nil = all)
function M.releaseClaim(mobId, debuffType)
    if not mobId then return end
    local id = tonumber(mobId)
    if not id then return end

    if debuffType then
        debuffType = tostring(debuffType):lower()
        local owned = M.localClaims[id] and M.localClaims[id][debuffType] ~= nil
        if M.localClaims[id] then
            M.localClaims[id][debuffType] = nil
            if not next(M.localClaims[id]) then
                M.localClaims[id] = nil
            end
        end
        if owned then
            _lastClaimBroadcast[tostring(id) .. ':' .. debuffType] = nil
            M.broadcastRelease(id, debuffType)
        end
    else
        local released = M.localClaims[id]
        M.localClaims[id] = nil
        for ownedType in pairs(released or {}) do
            _lastClaimBroadcast[tostring(id) .. ':' .. tostring(ownedType)] = nil
            M.broadcastRelease(id, ownedType)
        end
    end
end

--- Check if debuff is claimed by another
-- @param mobId number Mob spawn ID
-- @param debuffType string Debuff type
-- @return boolean True if claimed by another
-- @return string|nil Claimer name
function M.isDebuffClaimed(mobId, debuffType)
    if not mobId then return false, nil end
    local id = tonumber(mobId)
    if not id then return false, nil end

    debuffType = tostring(debuffType or ''):lower()
    if debuffType == '' then return false, nil end

    local now = os.clock()
    local remoteClaims = M.remoteClaims[id]
    if remoteClaims and remoteClaims[debuffType] then
        local claim = remoteClaims[debuffType]
        local active, peer = CoordinationPolicy.evaluateLocalClaim(
            getActors(), claim, CLAIM_TIMEOUT, now)
        claim.peerAgeMs = peer.peerAgeMs
        claim.peerReason = peer.peerReason
        claim.leaseRemainingMs = peer.leaseRemainingMs
        if active then
            M.lastPeerBlock = {
                at = now,
                targetId = id,
                category = debuffType,
                blockedBy = claim.claimer,
                peerAgeMs = peer.peerAgeMs,
                leaseRemainingMs = peer.leaseRemainingMs,
            }
            return true, claim.claimer
        end
        remoteClaims[debuffType] = nil
        if not next(remoteClaims) then M.remoteClaims[id] = nil end
    end

    return false, nil
end

function M.getLastPeerBlockReason(maxAgeSeconds)
    local block = M.lastPeerBlock
    if not block or (os.clock() - (block.at or 0)) > (tonumber(maxAgeSeconds) or 1.0) then
        return nil
    end
    return CoordinationPolicy.formatPeerBlock('claimed_by', block.blockedBy, block)
end

--- Broadcast a claim
-- @param mobId number Mob spawn ID
-- @param debuffType string Debuff type
function M.broadcastClaim(mobId, debuffType)
    local Actors = getActors()
    if not Actors or not Actors.broadcast then return end

    -- Send zone explicitly so the receiver doesn't have to depend on the
    -- _remoteCharacters fallback (which can be stale during zone-in).
    local myZone = mq.TLO.Zone and mq.TLO.Zone.ShortName and mq.TLO.Zone.ShortName() or nil
    if myZone == '' or myZone == 'NULL' then myZone = nil end

    Actors.broadcast('debuff:claim', {
        mobId = mobId,
        debuffType = debuffType,
        claimer = _selfName,
        claimedAt = os.clock(),
        zone = myZone,
    })
end

function M.broadcastRelease(mobId, debuffType)
    local Actors = getActors()
    if not Actors or not Actors.broadcast then return end
    local myZone = mq.TLO.Zone and mq.TLO.Zone.ShortName
        and mq.TLO.Zone.ShortName() or nil
    if myZone == '' or myZone == 'NULL' then myZone = nil end
    Actors.broadcast('debuff:release', {
        mobId = mobId,
        debuffType = debuffType,
        claimer = _selfName,
        zone = myZone,
    })
end

--- Receive a claim from another debuffer
-- @param payload table Message payload
function M.receiveClaim(payload)
    local mobId = tonumber(payload.mobId)
    if not mobId or mobId == 0 then return end

    local debuffType = tostring(payload.debuffType or ''):lower()
    if debuffType == '' then return end

    local claimer = payload.claimer or payload.from or 'unknown'
    if claimer == _selfName then return end

    -- Simultaneous broadcasts are resolved deterministically. The lower
    -- normalized character name keeps the reservation; the loser must fail
    -- its worker preflight before it can cast.
    if M.ownsClaim(mobId, debuffType) then
        if tostring(_selfName):lower() <= tostring(claimer):lower() then
            return
        end
        if M.localClaims[mobId] then
            M.localClaims[mobId][debuffType] = nil
            if not next(M.localClaims[mobId]) then M.localClaims[mobId] = nil end
        end
    end

    M.remoteClaims[mobId] = M.remoteClaims[mobId] or {}
    M.remoteClaims[mobId][debuffType] = {
        claimedAt = os.clock(),
        claimer = claimer,
        zone = tostring(payload.zone or ''),
        server = tostring(payload.server or payload._skActorSenderServer or ''),
        senderScript = tostring(payload._skActorSenderScript or ''),
    }
end

function M.receiveRelease(payload)
    local mobId = tonumber(payload and payload.mobId)
    local debuffType = tostring(payload and payload.debuffType or ''):lower()
    local claimer = tostring(payload and (payload.claimer or payload.from) or '')
    if not mobId or mobId <= 0 or debuffType == '' or claimer == '' then return end
    local claim = M.remoteClaims[mobId] and M.remoteClaims[mobId][debuffType]
    if claim and tostring(claim.claimer or ''):lower() == claimer:lower() then
        M.remoteClaims[mobId][debuffType] = nil
        if not next(M.remoteClaims[mobId]) then M.remoteClaims[mobId] = nil end
    end
end

--------------------------------------------------------------------------------
-- Debuff Tracking
--------------------------------------------------------------------------------

--- Track a debuff we just applied
-- @param mobId number Mob spawn ID
-- @param debuffType string 'slow', 'cripple', 'tash', 'malo', 'snare'
-- @param spellName string|nil Spell name
-- @param duration number|nil Duration in seconds
function M.trackDebuff(mobId, debuffType, spellName, duration)
    if not mobId or mobId == 0 then return end
    local id = tonumber(mobId)
    if not id then return end

    debuffType = tostring(debuffType or ''):lower()
    if debuffType == '' then return end

    duration = duration or DEBUFF_DURATION_DEFAULT
    local now = os.clock()

    M.localDebuffs[id] = M.localDebuffs[id] or {}
    M.localDebuffs[id][debuffType] = {
        appliedAt = now,
        expiresAt = now + duration,
        spellName = spellName or '',
    }

    -- Release claim
    M.releaseClaim(id, debuffType)

    -- Broadcast immediately
    M.broadcastDebuffLanded(id, debuffType, spellName, duration)
end

--- Broadcast that debuff landed
-- @param mobId number Mob spawn ID
-- @param debuffType string Debuff type
-- @param spellName string|nil Spell name
-- @param duration number|nil Duration
function M.broadcastDebuffLanded(mobId, debuffType, spellName, duration)
    local Actors = getActors()
    if not Actors or not Actors.broadcast then return end

    local myZone = mq.TLO.Zone and mq.TLO.Zone.ShortName and mq.TLO.Zone.ShortName() or nil
    if myZone == '' or myZone == 'NULL' then myZone = nil end

    Actors.broadcast('debuff:landed', {
        mobId = mobId,
        debuffType = debuffType,
        spellName = spellName or '',
        duration = duration or DEBUFF_DURATION_DEFAULT,
        applier = _selfName,
        zone = myZone,
    })
end

--- Receive debuff landed notification
-- @param payload table Message payload
function M.receiveDebuffLanded(payload)
    local mobId = tonumber(payload.mobId)
    if not mobId or mobId == 0 then return end

    local debuffType = tostring(payload.debuffType or ''):lower()
    if debuffType == '' then return end

    local applier = payload.applier or payload.from or 'unknown'
    if applier == _selfName then return end

    local duration = tonumber(payload.duration) or DEBUFF_DURATION_DEFAULT
    local now = os.clock()

    M.remoteDebuffs[mobId] = M.remoteDebuffs[mobId] or {}
    M.remoteDebuffs[mobId][debuffType] = {
        appliedAt = now,
        expiresAt = now + duration,
        applier = applier,
        spellName = payload.spellName or '',
    }

    -- Clear any remote claims for this debuff (it landed)
    if M.remoteClaims[mobId] then
        M.remoteClaims[mobId][debuffType] = nil
        if not next(M.remoteClaims[mobId]) then
            M.remoteClaims[mobId] = nil
        end
    end
end

--- Broadcast all our active debuffs
--------------------------------------------------------------------------------
-- Query Functions
--------------------------------------------------------------------------------

--- Check if mob has a debuff (from anyone)
-- @param mobId number Mob spawn ID
-- @param debuffType string Debuff type
-- @return boolean True if debuffed
function M.hasDebuff(mobId, debuffType)
    if not mobId then return false end
    local id = tonumber(mobId)
    if not id then return false end

    debuffType = tostring(debuffType or ''):lower()
    if debuffType == '' then return false end

    local now = os.clock()

    -- Check local
    local local_d = M.localDebuffs[id] and M.localDebuffs[id][debuffType]
    if local_d and now < (local_d.expiresAt or 0) then
        return true
    end

    -- Check remote
    local remote_d = M.remoteDebuffs[id] and M.remoteDebuffs[id][debuffType]
    if remote_d and now < (remote_d.expiresAt or 0) then
        return true
    end

    -- Fallback: Check TLO for slowed/snared on target. spawn.Slowed is a
    -- Spell TLO that stringifies to "NULL" when not slowed (truthy in Lua),
    -- so we have to check the underlying spell ID instead.
    if debuffType == 'slow' then
        local spawn = mq.TLO.Spawn(id)
        if spawn and spawn() and spawn.Slowed and spawn.Slowed.ID then
            local slowedId = tonumber(spawn.Slowed.ID()) or 0
            if slowedId > 0 then
                return true
            end
        end
    end

    return false
end

--- Check if mob is slowed
-- @param mobId number Mob spawn ID
-- @return boolean
function M.isSlowed(mobId)
    return M.hasDebuff(mobId, 'slow')
end

--- Check if mob has malo
-- @param mobId number Mob spawn ID
-- @return boolean
function M.hasMalo(mobId)
    return M.hasDebuff(mobId, 'malo')
end

--- Check if mob has tash
-- @param mobId number
-- @return boolean
function M.hasTash(mobId)
    return M.hasDebuff(mobId, 'tash')
end

--- Check if mob is crippled
-- @param mobId number Mob spawn ID
-- @return boolean
function M.isCrippled(mobId)
    return M.hasDebuff(mobId, 'cripple')
end

--- Check if mob is snared
-- @param mobId number Mob spawn ID
-- @return boolean
function M.isSnared(mobId)
    return M.hasDebuff(mobId, 'snare')
end

--- Get best target for a debuff type (not debuffed, not claimed)
-- @param debuffType string Debuff type
-- @return number|nil Mob ID
-- @return string|nil Mob name
function M.getBestDebuffTarget(debuffType)
    local Cache = getCache()
    local haters = Cache and Cache.xtarget and Cache.xtarget.haters or nil
    if not haters then return nil, nil end

    debuffType = tostring(debuffType or ''):lower()
    if debuffType == '' then return nil, nil end

    local candidates = {}

    for _, hater in pairs(haters) do
        local id = tonumber(hater.id)
        if id and id > 0 then
            -- Skip if already has debuff
            if not M.hasDebuff(id, debuffType) then
                -- Skip if claimed by another
                local claimed, _ = M.isDebuffClaimed(id, debuffType)
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

    -- Sort by HP (prioritize higher HP mobs for slow/cripple)
    table.sort(candidates, function(a, b)
        return a.hp > b.hp
    end)

    if #candidates > 0 then
        return candidates[1].id, candidates[1].name
    end

    return nil, nil
end

--- Get all targets needing a specific debuff
-- @param debuffType string Debuff type
-- @return table Array of { id, name, hp, distance }
function M.getTargetsNeedingDebuff(debuffType)
    local Cache = getCache()
    local haters = Cache and Cache.xtarget and Cache.xtarget.haters or nil
    if not haters then return {} end

    debuffType = tostring(debuffType or ''):lower()
    if debuffType == '' then return {} end

    local candidates = {}

    for _, hater in pairs(haters) do
        local id = tonumber(hater.id)
        if id and id > 0 then
            if not M.hasDebuff(id, debuffType) then
                local claimed, _ = M.isDebuffClaimed(id, debuffType)
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

--- Check if we should debuff all task mobs (setting-based)
-- @param settings table Settings table
-- @return boolean
function M.shouldDebuffAllTask(settings)
    return settings and settings.DebuffAllTask == true
end

return M
