-- F:\lua\SideKick\automation\debuff.lua
-- Debuff coordination: Actor-based claim system to prevent duplicate debuffs
-- Tracks slow, cripple, malo/tash across shamans, enchanters, mages

local mq = require('mq')
local lazy = require('sidekick-next.utils.lazy_require')

local M = {}

-- Lazy-load Actors to avoid circular requires
local getActors = lazy('sidekick-next.utils.actors_coordinator')

-- Lazy-load runtime cache
local getCache = lazy('sidekick-next.utils.runtime_cache')

-- Debuff types we track
M.DEBUFF_TYPES = {
    'slow',      -- Shaman, Enchanter
    'cripple',   -- Shaman
    'malo',      -- Shaman (malo), Enchanter (tash), Mage (malo)
    'snare',     -- Various
}

-- Local debuff tracking (debuffs we applied)
M.localDebuffs = {}  -- { [mobId] = { [debuffType] = { appliedAt, expiresAt, spellName } } }

-- Remote debuff tracking (debuffs others applied)
M.remoteDebuffs = {}  -- { [mobId] = { [debuffType] = { appliedAt, expiresAt, applier, spellName } } }

-- Debuff claims (before casting, claim so others don't try)
M.localClaims = {}   -- { [mobId] = { [debuffType] = { claimedAt } } }
M.remoteClaims = {}  -- { [mobId] = { [debuffType] = { claimedAt, claimer } } }

-- Timing
local _lastBroadcast = 0
local _lastCleanup = 0
local BROADCAST_INTERVAL = 2.0   -- Broadcast every 2 seconds
local CLEANUP_INTERVAL = 1.0     -- Clean expired every 1 second
local CLAIM_TIMEOUT = 8.0        -- Claims expire after 8 seconds
local DEBUFF_DURATION_DEFAULT = 60  -- Default debuff duration

local _selfName = ''
local _isDebuffer = false

-- Debuff classes
local DEBUFFER_CLASSES = {
    SHM = { slow = true, cripple = true, malo = true },
    ENC = { slow = true, malo = true },  -- tash = malo equivalent
    MAG = { malo = true },
}

function M.init()
    M.localDebuffs = {}
    M.remoteDebuffs = {}
    M.localClaims = {}
    M.remoteClaims = {}

    _selfName = (mq.TLO.Me and mq.TLO.Me.CleanName and mq.TLO.Me.CleanName()) or ''

    -- Check if we're a debuffer class
    local cls = ''
    if mq.TLO.Me and mq.TLO.Me.Class and mq.TLO.Me.Class.ShortName then
        cls = tostring(mq.TLO.Me.Class.ShortName() or ''):upper()
    end
    _isDebuffer = DEBUFFER_CLASSES[cls] ~= nil
end

function M.tick()
    local now = os.clock()

    -- Cleanup expired
    if (now - _lastCleanup) >= CLEANUP_INTERVAL then
        _lastCleanup = now
        M.cleanupExpired()
    end

    -- Broadcast our debuffs periodically
    if _isDebuffer and (now - _lastBroadcast) >= BROADCAST_INTERVAL then
        _lastBroadcast = now
        M.broadcastDebuffs()
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
            if (now - data.claimedAt) >= CLAIM_TIMEOUT then
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
-- @param debuffType string 'slow', 'cripple', 'malo', 'snare'
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

--- Release a claim
-- @param mobId number Mob spawn ID
-- @param debuffType string|nil Debuff type (nil = all)
function M.releaseClaim(mobId, debuffType)
    if not mobId then return end
    local id = tonumber(mobId)
    if not id then return end

    if debuffType then
        debuffType = tostring(debuffType):lower()
        if M.localClaims[id] then
            M.localClaims[id][debuffType] = nil
            if not next(M.localClaims[id]) then
                M.localClaims[id] = nil
            end
        end
    else
        M.localClaims[id] = nil
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
        if (now - claim.claimedAt) < CLAIM_TIMEOUT then
            return true, claim.claimer
        end
    end

    return false, nil
end

--- Broadcast a claim
-- @param mobId number Mob spawn ID
-- @param debuffType string Debuff type
function M.broadcastClaim(mobId, debuffType)
    local Actors = getActors()
    if not Actors or not Actors.broadcast then return end

    Actors.broadcast('debuff:claim', {
        mobId = mobId,
        debuffType = debuffType,
        claimer = _selfName,
        claimedAt = os.clock(),
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

    M.remoteClaims[mobId] = M.remoteClaims[mobId] or {}
    M.remoteClaims[mobId][debuffType] = {
        claimedAt = os.clock(),
        claimer = claimer,
    }
end

--------------------------------------------------------------------------------
-- Debuff Tracking
--------------------------------------------------------------------------------

--- Track a debuff we just applied
-- @param mobId number Mob spawn ID
-- @param debuffType string 'slow', 'cripple', 'malo', 'snare'
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

    Actors.broadcast('debuff:landed', {
        mobId = mobId,
        debuffType = debuffType,
        spellName = spellName or '',
        duration = duration or DEBUFF_DURATION_DEFAULT,
        applier = _selfName,
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
function M.broadcastDebuffs()
    local Actors = getActors()
    if not Actors or not Actors.broadcast then return end

    if not next(M.localDebuffs) then return end

    local now = os.clock()
    local debuffList = {}

    for mobId, debuffs in pairs(M.localDebuffs) do
        for debuffType, data in pairs(debuffs) do
            local ttl = (data.expiresAt or 0) - now
            if ttl > 0 then
                debuffList[#debuffList + 1] = {
                    mobId = mobId,
                    debuffType = debuffType,
                    ttl = ttl,
                    spellName = data.spellName or '',
                }
            end
        end
    end

    if #debuffList > 0 then
        Actors.broadcast('debuff:list', {
            debuffs = debuffList,
            sender = _selfName,
        })
    end
end

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

    -- Fallback: Check TLO for slowed/snared on target
    if debuffType == 'slow' then
        local spawn = mq.TLO.Spawn(id)
        if spawn and spawn() and spawn.Slowed and spawn.Slowed() then
            return true
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

--- Check if mob has malo/tash
-- @param mobId number Mob spawn ID
-- @return boolean
function M.hasMalo(mobId)
    return M.hasDebuff(mobId, 'malo')
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
