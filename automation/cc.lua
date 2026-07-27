-- F:\lua\SideKick\automation\cc.lua
-- Crowd Control tracking and broadcasting
-- Broadcasts mezzed mob list to group, receives from other mezzers

local mq = require('mq')
local lazy = require('sidekick-next.utils.lazy_require')

local M = {}

-- Optional decision-trace hook. sk_cc points this at its console tracer
-- while /sk_cc debug is on; nil (the default) makes every dlog a no-op.
M.trace = nil
local function dlog(fmt, ...)
    if M.trace then M.trace(fmt, ...) end
end

-- Lazy-load Actors to avoid circular requires
local getActors = lazy('sidekick-next.utils.actors_coordinator')

-- Lazy-load runtime cache for fallback checks
local getCache = lazy('sidekick-next.utils.runtime_cache')

-- Lazy-load the per-zone mob immunity DB (existing infra; covers
-- 'mez' and 'charm' categories among others) and the Core settings
-- table for the user toggle.
local getImmuneDB = lazy('sidekick-next.utils.immune_database')
local getCore = lazy('sidekick-next.utils.core')

local function immunePersistEnabled()
    local Core = getCore()
    if not (Core and Core.Settings) then return true end
    local v = Core.Settings.MezImmunePersistEnabled
    return v ~= false  -- nil or true => enabled
end

local function recordImmune(category)
    if not immunePersistEnabled() then return end
    local DB = getImmuneDB()
    if not (DB and DB.addImmune) then return end
    local target = mq.TLO.Target
    if not (target and target()) then return end
    local name = nil
    pcall(function() name = target.CleanName() or target.Name() end)
    if not name or name == '' then return end
    -- The DB scopes by current zone internally; ensure we're indexed
    -- against the live zone before recording.
    if DB.loadZone then pcall(DB.loadZone) end
    DB.addImmune(name, category)
end

--- Public check used by the target-selection paths. Defaults to
--- "not immune" if the toggle is off or the DB isn't ready.
function M.isMobImmuneToCC(mobName, category)
    if not mobName or mobName == '' then return false end
    if not immunePersistEnabled() then return false end
    local DB = getImmuneDB()
    if not (DB and DB.isImmune) then return false end
    return DB.isImmune(mobName, category) == true
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
-- Cached integer derived from _selfName, used to shard target selection
-- across multiple mezzers running in the same group. With two ENC/BRD boxes
-- both seeing the same XTarget hater list, the previous selection always
-- picked candidates[1] for everyone — causing both to claim and double-cast
-- the same mob in the async window before claims propagate. Hash-based
-- sharding lets each mezzer pick a different index of the sorted list, so
-- the common case naturally avoids contention even before the claim system
-- has a chance to broadcast.
local _shardOffset = 0
local function _refreshShardOffset()
    local sum = 0
    for i = 1, #_selfName do
        sum = sum + string.byte(_selfName, i)
    end
    _shardOffset = sum
end

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
    _refreshShardOffset()

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
                    -- trackMezLanded prefers the REAL duration of the spell
                    -- we just cast: the 60s conservative default keeps a
                    -- broken-early mez flagged as mezzed for up to a minute,
                    -- and the tank + mezzer both ignore the loose add that
                    -- whole time.
                    if M.trackMezLanded then
                        M.trackMezLanded(id, mobName)
                    else
                        M.trackLocalMez(id, mobName, MEZ_DURATION_DEFAULT)
                    end
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

            -- Mez/charm immunity events. The chat lines are emitted by EQ
            -- when a mez/charm cast fails because the target is immune.
            -- We capture the active target's CleanName via mq.TLO.Target —
            -- the cast just resolved so the target is still locked in.
            mq.event('sidekick_cc_mez_immune', 'Your target cannot be mesmerized#*#', function()
                recordImmune('mez')
            end)
            mq.event('sidekick_cc_charm_immune', 'Your target cannot be charmed#*#', function()
                recordImmune('charm')
            end)
            mq.event('sidekick_cc_charm_immune_npc', 'This NPC cannot be charmed#*#', function()
                recordImmune('charm')
            end)
            -- Charm spell tier too low — functionally immune for current
            -- spell, so record charm immunity. User can clear via the DB
            -- if they upgrade and want to retry.
            mq.event('sidekick_cc_charm_lvl_high', 'Your target is too high of a level for your charm spell.#*#', function()
                recordImmune('charm')
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

    local myZone = mq.TLO.Zone and mq.TLO.Zone.ShortName and mq.TLO.Zone.ShortName() or nil
    if myZone == '' or myZone == 'NULL' then myZone = nil end

    (Actors.broadcastFleet or Actors.broadcast)('cc:mezlist', {
        mobs = mezList,
        sender = mq.TLO.Me.CleanName(),
        timestamp = now, -- sender-local os.clock (paired with expires for backward compatibility)
        zone = myZone,
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

    -- Check local/remote directly, not just the merged view: allMezzes is
    -- only rebuilt by mergeAllMezzes() inside M.tick(), which runs ONLY in
    -- the sk_cc worker. Every other process (tank, dps) receives cc:mezlist
    -- broadcasts into remoteMezzes but never merges — reading allMezzes
    -- alone made every mezzed mob look unmezzed to the tank.
    local now = os.clock()
    for _, tbl in ipairs({ M.allMezzes, M.localMezzes, M.remoteMezzes }) do
        local data = tbl[id]
        if data and now < (tonumber(data.expires) or 0) then
            return true
        end
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

    -- Check remote claims (other mezzers). Our OWN name never blocks us:
    -- with the fleet fan-out, our claim broadcast loops back and can land
    -- AFTER the local claim was already released (mez landed fast) — the
    -- late copy gets stored as "remote" and would lock us out of our own
    -- target (e.g. recharming the mob we just mezzed) for CLAIM_TIMEOUT.
    local remoteClaim = M.remoteClaims[id]
    if remoteClaim and (now - remoteClaim.claimedAt) < CLAIM_TIMEOUT
        and remoteClaim.claimer ~= _selfName then
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

    -- Include zone explicitly so the coordinator's senderInSameZone helper
    -- doesn't have to fall back to _remoteCharacters[name].zone (which can be
    -- stale during zone-in transitions). Send only if we have a real zone
    -- name — "NULL" or empty would defeat the receive-side filter.
    local myZone = mq.TLO.Zone and mq.TLO.Zone.ShortName and mq.TLO.Zone.ShortName() or nil
    if myZone == '' or myZone == 'NULL' then myZone = nil end

    (Actors.broadcastFleet or Actors.broadcast)('cc:claim', {
        mobId = mobId,
        mobName = mobName or '',
        claimer = _selfName,
        claimedAt = os.clock(),
        zone = myZone,
    })
end

--- Receive a claim from another mezzer (called by Actors handler)
-- @param payload table Message payload
function M.receiveClaim(payload)
    local mobId = tonumber(payload.mobId)
    if not mobId or mobId == 0 then return end

    local claimer = payload.claimer or payload.from or 'unknown'

    -- Don't mirror our own claim into the process that HOLDS it (it would
    -- make isTargetClaimed() true for our own target). Sibling scripts on
    -- this character (sk_tank/sk_dps) have no localClaims and must store it.
    if claimer == _selfName and M.localClaims[mobId] then return end

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
-- The tank's broadcast kill target must never be mezzed: mezzing the mob the
-- tank is actively fighting stalls the kill and the tank's next swing breaks
-- it anyway. Local Cache.target only covers this mezzer's own target, so
-- consult the tank-state broadcast too.
local function tankPrimaryId()
    local Actors = getActors()
    if not (Actors and Actors.getTankState) then return 0 end
    local state = Actors.getTankState()
    -- The tank rebroadcasts every second; a silent entry is a dead tank
    -- worker or a finished fight — don't let it block mezzing forever.
    if (os.clock() - (tonumber(state.updatedAt) or 0)) > 10 then return 0 end
    return tonumber(state.primaryTargetId) or 0
end

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
    local tankPrimary = tankPrimaryId()
    -- Exclude our charm pet from mez only while the charm is actually
    -- holding (belt-and-suspenders: a held pet isn't a hater anyway). A
    -- BROKEN pet is deliberately mezzable — mez is the control tool while
    -- the recharm ladder waits on an out-of-control camp.
    local ourCharmPet = tonumber(M.charm and M.charm.petId) or 0
    if ourCharmPet > 0 then
        local pid = 0
        pcall(function() pid = tonumber(mq.TLO.Me.Pet.ID()) or 0 end)
        if pid ~= ourCharmPet then ourCharmPet = 0 end
    end

    for _, hater in pairs(haters) do
        local id = tonumber(hater.id)
        if id and id > 0 and id ~= primaryTarget
            and id ~= tankPrimary and id ~= ourCharmPet then
            -- Skip if already mezzed
            if not M.isMobMezzed(id) then
                -- Skip if claimed by another
                local claimed, _ = M.isTargetClaimed(id)
                if not claimed then
                    -- Skip if the per-zone immune DB has flagged this mob
                    -- as mez-immune previously.
                    if not M.isMobImmuneToCC(hater.name or '', 'mez') then
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
    end

    -- Sort by HP (lowest first), distance, then mobId. The mobId tiebreaker
    -- guarantees every mezzer in the group sees the same ordering — without
    -- it, two mezzers iterating an unordered xtarget pairs table can end up
    -- with different first-element candidates and the sharding below would
    -- become inconsistent.
    table.sort(candidates, function(a, b)
        if a.hp ~= b.hp then return a.hp < b.hp end
        if a.distance ~= b.distance then return a.distance < b.distance end
        return a.id < b.id
    end)

    if #candidates > 0 then
        -- Shard by character-name hash so co-located mezzers naturally pick
        -- different mobs. Falls back to candidates[1] when only one is
        -- available (both mezzers will land on it; the claim system + cast
        -- path is the safety net for that case).
        local idx = ((_shardOffset - 1) % #candidates) + 1
        return candidates[idx].id, candidates[idx].name
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
    local tankPrimary = tankPrimaryId()
    -- Exclude our charm pet from mez only while the charm is actually
    -- holding (belt-and-suspenders: a held pet isn't a hater anyway). A
    -- BROKEN pet is deliberately mezzable — mez is the control tool while
    -- the recharm ladder waits on an out-of-control camp.
    local ourCharmPet = tonumber(M.charm and M.charm.petId) or 0
    if ourCharmPet > 0 then
        local pid = 0
        pcall(function() pid = tonumber(mq.TLO.Me.Pet.ID()) or 0 end)
        if pid ~= ourCharmPet then ourCharmPet = 0 end
    end

    for _, hater in pairs(haters) do
        local id = tonumber(hater.id)
        if id and id > 0 and id ~= primaryTarget
            and id ~= tankPrimary and id ~= ourCharmPet then
            if not M.isMobMezzed(id) then
                local claimed, _ = M.isTargetClaimed(id)
                if not claimed then
                    if not M.isMobImmuneToCC(hater.name or '', 'mez') then
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
    end

    -- Same deterministic ordering as getBestMezTarget so callers can sort/
    -- shard consistently across mezzers.
    table.sort(candidates, function(a, b)
        if a.hp ~= b.hp then return a.hp < b.hp end
        if a.distance ~= b.distance then return a.distance < b.distance end
        return a.id < b.id
    end)

    return candidates
end

--------------------------------------------------------------------------------
-- Mez Casting Functions
--------------------------------------------------------------------------------

-- Lazy-load Core for settings
local getCore = lazy('sidekick-next.utils.core')

-- Lazy-load SpellEngine for casting
local getSpellEngine = lazy('sidekick-next.utils.spell_engine')

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

-- Helper: strip " Rk. II" / " Rk. III" / etc. so we can compare base names.
-- Also normalizes apostrophes: EQ spell data uses backticks in lore names
-- ("Boltran`s Agacerie") while config lists are written with apostrophes —
-- a literal compare misses every such spell.
local function stripRank(name)
    if not name then return '' end
    return tostring(name):gsub(' Rk%. %u+$', ''):gsub('`', "'")
end

-- Helper: check if any rank of `spellName` is memorized in any gem. Compares
-- base names so an unranked config entry matches a ranked memorized spell.
local function spellMemorized(spellName)
    if not spellName or spellName == '' then return false end
    local me = mq.TLO.Me
    if not (me and me()) then return false end
    local base = stripRank(spellName)
    local gems = tonumber(me.NumGems()) or 13
    for i = 1, gems do
        local gem = me.Gem(i)
        if gem and gem() then
            local gemName = gem.Name() or ''
            if stripRank(gemName) == base then
                return true
            end
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

-- Helper: resolve best memorized spell from a line. Class configs carry two
-- parallel progressions — spellLines (condition-engine names like 'SingleMez')
-- and AbilitySets (rgmercs-style names like 'MezSpell') — and callers here
-- reference both vocabularies, so check spellLines first then AbilitySets.
local function resolveSpellLine(classConfig, lineName)
    if not classConfig or not lineName then return nil end
    -- Check BOTH vocabularies: spellLines (condition-engine names) and
    -- AbilitySets (rgmercs-style names). A lineName may exist in both with
    -- different coverage, so a miss in one still tries the other.
    for _, tbl in ipairs({ classConfig.spellLines, classConfig.AbilitySets }) do
        local line = tbl and tbl[lineName]
        if type(line) == 'table' then
            for _, name in ipairs(line) do
                if spellMemorized(name) then
                    return name
                end
            end
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

--- Record a landed mez using the real duration of the spell we just cast on
--- that mob (falls back to the conservative default when the landing wasn't
--- ours or the spell is unknown). Called from the 'has been mesmerized' event.
function M.trackMezLanded(mobId, mobName)
    local duration = nil
    if tonumber(_mezCastState.currentMezTarget) == tonumber(mobId)
        and _mezCastState.currentMezSpell then
        duration = getMezDuration(_mezCastState.currentMezSpell)
    end
    M.trackLocalMez(mobId, mobName, duration or MEZ_DURATION_DEFAULT)
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

    -- Check if we're already casting. Casting() returns the spell name when
    -- active, empty string OR the literal "NULL" when idle — must reject both.
    local me = mq.TLO.Me
    local casting = me and me.Casting() or ''
    if casting ~= '' and casting ~= 'NULL' then
        return false, 'already_casting'
    end

    -- Claim the target before casting
    if not M.claimTarget(mobId, mobName) then
        return false, 'target_claimed'
    end

    -- Brief confirmation window: another mezzer that claimed simultaneously
    -- has time to broadcast to us. After the yield, re-check remoteClaims;
    -- if a peer also claimed this mob, tie-break by lexicographic name —
    -- the mezzer whose name sorts FIRST wins, the other defers. Without
    -- the tie-break BOTH mezzers would see each other's claim and BOTH
    -- abort, leaving the mob un-mezzed.
    mq.delay(50)
    local conflicted, otherClaimer = M.isTargetClaimed(mobId)
    if conflicted and otherClaimer then
        if _selfName == '' or otherClaimer < _selfName then
            -- They win the tie. Drop our local claim and abort.
            M.releaseClaim(mobId)
            return false, string.format('target_claimed_late_by_%s', tostring(otherClaimer))
        end
        -- We win the tie. Clear the stale remote claim so we don't keep
        -- seeing it as "claimed by someone else" on subsequent checks.
        M.remoteClaims[mobId] = nil
    end

    -- Initiate cast
    local success, reason = SpellEngine.cast(spellName, mobId, {
        spellCategory = 'mez',
        allowDead = false,
    })

    if success then
        _mezCastState.lastMezAttemptAt = os.clock()
        _mezCastState.currentMezTarget = mobId
        _mezCastState.currentMezSpell = spellName
    else
        -- Release claim on failure
        M.releaseClaim(mobId)
    end

    return success, reason
end

--- Select the next mez action without casting it.
-- Coordinator workers use this to advertise need and obtain exclusive cast
-- ownership before any target or spell command is issued.
-- @param settings table Settings table with mez options
-- @return table|nil action { targetId, targetName, spellName }
-- @return string reason
function M.selectMezAction(settings)
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
        return nil, 'disabled'
    end

    -- Only mez classes should mez
    if not M.isMezClass() then
        return nil, 'not_mez_class'
    end

    local me = mq.TLO.Me
    if not (me and me()) then return nil, 'no_me' end

    -- Check if we can cast (not stunned, mezzed, etc.)
    -- me.Stunned/Silenced are bool TLOs (true/false); me.Mezzed is a Spell
    -- TLO that stringifies to "NULL" when not mezzed — checking it directly
    -- would always be truthy and permanently block mezzing.
    local mezzedNow = false
    if me.Mezzed and me.Mezzed.ID then
        mezzedNow = (tonumber(me.Mezzed.ID()) or 0) > 0
    end
    if me.Stunned() or mezzedNow or (me.Silenced and me.Silenced()) then
        return nil, 'incapacitated'
    end

    -- Don't mez while moving (except for bards)
    local cls = tostring(me.Class.ShortName() or ''):upper()
    if cls ~= 'BRD' and me.Moving() then
        return nil, 'moving'
    end

    -- Check if SpellEngine is busy
    local SpellEngine = getSpellEngine()
    if SpellEngine and SpellEngine.isBusy and SpellEngine.isBusy() then
        return nil, 'spell_engine_busy'
    end

    -- Throttle decision making
    local now = os.clock()
    if (now - (_mezCastState.lastMezDecisionAt or 0)) < 0.2 then
        return nil, 'throttled'
    end
    _mezCastState.lastMezDecisionAt = now

    -- Get class profile and class config
    local profile = _mezProfiles[cls]
    if not profile then
        return nil, 'no_profile'
    end

    local classConfig = loadClassConfig(cls)
    if not classConfig then
        return nil, 'no_class_config'
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
                    return {
                        targetId = mobId,
                        targetName = data.name,
                        spellName = spellName,
                        reason = 'remez',
                    }, 'remez'
                end
            end
        end
        return nil, 'mez_cap_reached'
    end

    -- Get best mez target
    local targetId, targetName = M.getBestMezTarget(maxTargets)
    if not targetId then
        return nil, 'no_target'
    end

    -- Validate target
    if not isValidMezTarget(targetId, settings) then
        return nil, 'invalid_target'
    end

    -- Check for AE mez opportunity
    local useAEMez = settings.UseAEMez == true
    local aeMinTargets = tonumber(settings.AEMezMinTargets) or 3
    local spellName = nil

    -- Deferred charm break (camp_control_hold) forces AE preference: >2
    -- unmezzed plus the loose ex-pet are in camp, and one AE mez both locks
    -- the camp and makes the ex-pet safely recharmable. Overrides the
    -- UseAEMez setting for this window; keeps a floor of 2 clustered
    -- targets so a lone straggler still gets the cheaper single mez.
    local campHold = (now - (M.charm.campHoldAt or 0)) < 3.0
    if profile.ae and (useAEMez or campHold) then
        local aeCount = getAETargetCount(targetId)
        if aeCount >= (campHold and 2 or aeMinTargets) then
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
        return nil, 'no_spell'
    end

    return {
        targetId = targetId,
        targetName = targetName,
        spellName = spellName,
        reason = 'mez',
    }, 'mez'
end

--------------------------------------------------------------------------------
-- Charm (DPS charm pet)
--------------------------------------------------------------------------------
-- Doctrine: the enchanter keeps a charmed NPC as a DPS pet. On charm break
-- the response ladder is tash (if not already applied) -> PBAE stun (locks
-- the loose pet while the recharm windup runs) -> recharm. Target selection
-- caps at the charm spell's own max level and blacklists NPC healer classes
-- (a CLR/SHM pet spends its time healing the camp instead of killing it).
-- The pet's spawn ID is broadcast group-wide so nobody kills it mid-break;
-- the tank protects the enchanter with damageless aggro only.

local CHARM_BROADCAST_INTERVAL = 5.0   -- rebroadcast cadence while pet/recovery live
local CHARM_PET_CMD_INTERVAL = 1.5     -- /pet attack|back throttle
local CHARM_BREAK_GIVEUP_SEC = 30      -- abandon recharm after this long
local CHARM_MAX_ATTEMPTS = 3           -- failed recharm casts before giving up on the ex-pet
local CHARM_ACQUIRE_MAX_ATTEMPTS = 2   -- resists before moving on to another candidate
local CHARM_HOLD_UNMEZZED_DEFAULT = 2  -- defer recharm while more than this many unmezzed haters (ex-pet excluded)
local CHARM_BLOCK_TTL_SEC = 120        -- how long a gave-up mob stays off the menu
local TASH_TTL_SEC = 300               -- assume our tash outlives any recharm cycle

M.charm = {
    petId = 0,
    petName = '',
    breakSteps = nil,       -- remaining ladder steps, e.g. {'tash','stun','charm'}
    breakStartedAt = 0,
    pendingCharmTargetId = 0,
    pendingCharmAt = 0,
    tashedIds = {},         -- [mobId] = os.clock() when our tash landed
    attempts = {},          -- [mobId] = failed charm cast count
    blocked = {},           -- [mobId] = os.clock() expiry of the give-up block
    lastBroadcastAt = 0,
    lastPetCmdAt = 0,
    lastDecisionAt = 0,
    campHoldAt = 0,         -- os.clock() of the last camp_control_hold (forces AE mez preference)
}

local _charmProfiles = {
    ENC = {
        charm = { 'Charm', 'CharmSpell' },
        tash = { 'Tash', 'TashSpell' },
        stun = { 'ColorStun' },
    },
}

function M.isCharmClass()
    local me = mq.TLO.Me
    if not (me and me()) then return false end
    return _charmProfiles[tostring(me.Class.ShortName() or ''):upper()] ~= nil
end

-- SPA-based charm resolution: scan memorized gems for a detrimental spell
-- with SPA 22 (charm). Server-proof — custom emu spell names that aren't in
-- any config list still resolve. Used as the fallback when the name lists
-- miss; result cached until the gem lineup changes.
local _charmGemScan = { sig = '', name = nil }
local function findMemorizedCharmBySPA()
    local me = mq.TLO.Me
    if not (me and me()) then return nil end
    local gems = tonumber(me.NumGems()) or 13
    local sig = {}
    for i = 1, gems do
        sig[#sig + 1] = tostring(me.Gem(i) and me.Gem(i).Name() or '')
    end
    local sigStr = table.concat(sig, '|')
    if sigStr == _charmGemScan.sig then return _charmGemScan.name end
    _charmGemScan.sig = sigStr
    _charmGemScan.name = nil
    for i = 1, gems do
        local gem = me.Gem(i)
        if gem and gem() then
            local isCharm = false
            pcall(function()
                isCharm = gem.HasSPA(22)() == true
                    and gem.Beneficial() ~= true
            end)
            if isCharm then
                _charmGemScan.name = gem.Name()
                break
            end
        end
    end
    return _charmGemScan.name
end

-- Resolve the charm spell: config name lists first, SPA gem-scan fallback.
local function resolveCharmSpell(classConfig, profile)
    return chooseSpellForLines(classConfig, profile.charm)
        or findMemorizedCharmBySPA()
end

--- The mob ID currently protected as our charm pet (live or mid-recovery).
function M.getCharmPetId()
    return tonumber(M.charm.petId) or 0
end

local function charmProfile()
    local me = mq.TLO.Me
    if not (me and me()) then return nil end
    return _charmProfiles[tostring(me.Class.ShortName() or ''):upper()]
end

local function myPetId()
    local ok, id = pcall(function() return tonumber(mq.TLO.Me.Pet.ID()) or 0 end)
    return ok and id or 0
end

-- Broadcast the protected pet ID (0 = explicit release). Receivers store it
-- in actors_coordinator's owner-keyed charm states; the handler accepts our own loopback so
-- sibling workers on this character see it too.
function M.broadcastCharmState(force)
    local now = os.clock()
    if not force and (now - (M.charm.lastBroadcastAt or 0)) < CHARM_BROADCAST_INTERVAL then
        return
    end
    local Actors = getActors()
    if not (Actors and Actors.broadcast) then return end
    M.charm.lastBroadcastAt = now
    local myZone = mq.TLO.Zone and mq.TLO.Zone.ShortName and mq.TLO.Zone.ShortName() or nil
    if myZone == '' or myZone == 'NULL' then myZone = nil end
    (Actors.broadcastFleet or Actors.broadcast)('cc:charmpet', {
        petId = tonumber(M.charm.petId) or 0,
        petName = tostring(M.charm.petName or ''),
        owner = _selfName,
        zone = myZone,
    })
end

local function clearCharm(reason)
    local hadPet = (tonumber(M.charm.petId) or 0) > 0
    if hadPet then
        dlog('charm-cleared: pet=%d %s (%s)', tonumber(M.charm.petId) or 0,
            tostring(M.charm.petName or ''), tostring(reason or '?'))
    end
    M.charm.petId = 0
    M.charm.petName = ''
    M.charm.breakSteps = nil
    M.charm.breakStartedAt = 0
    M.charm.pendingCharmTargetId = 0
    M.charm.pendingCharmAt = 0
    if hadPet then
        -- Explicit release so the group is free to kill the ex-pet.
        M.broadcastCharmState(true)
    end
end

local function parseClassBlacklist(settings)
    local raw = tostring(settings.CharmClassBlacklist or 'CLR SHM')
    local set = {}
    for tok in raw:gmatch('%a+') do
        set[tok:upper()] = true
    end
    return set
end

local function charmSpellMaxLevel(spellName)
    local cap = nil
    pcall(function()
        cap = tonumber(mq.TLO.Spell(spellName).MaxLevel())
    end)
    if cap and cap > 0 then return cap end
    return nil -- unknown: don't filter; the "too high level" event blacklists
end

local function mobTashed(mobId)
    local at = M.charm.tashedIds[tonumber(mobId) or 0]
    if at and (os.clock() - at) < TASH_TTL_SEC then return true end
    -- Tashed is only readable off the current target's buff data.
    local t = mq.TLO.Target
    if t and t() and (tonumber(t.ID() or 0) or 0) == (tonumber(mobId) or 0) then
        local ok, tashed = pcall(function() return t.Tashed() ~= nil and t.Tashed.ID() ~= nil end)
        if ok and tashed then return true end
    end
    return false
end

-- Prune the break ladder to steps that can actually fire right now.
-- Returns the first actionable step + spell, or nil when the ladder is empty.
local function nextBreakStep(profile, classConfig, settings, targetId)
    while M.charm.breakSteps and #M.charm.breakSteps > 0 do
        local step = M.charm.breakSteps[1]
        if step == 'tash' then
            local spellName = settings.CharmBreakTash ~= false
                and not mobTashed(targetId)
                and chooseSpellForLines(classConfig, profile.tash) or nil
            if spellName then return step, spellName end
        elseif step == 'stun' then
            -- Skip only if the pet is already mezzed (it's locked; save the
            -- mana). Stuns deal no damage, so the PBAE hitting mezzed mobs
            -- is harmless — no camp-mez guard needed.
            local spellName = settings.CharmBreakStun ~= false
                and not M.isMobMezzed(targetId)
                and chooseSpellForLines(classConfig, profile.stun) or nil
            if spellName then
                -- PBAE: the loose pet must be inside the stun's radius.
                local aeRange = 40
                pcall(function()
                    aeRange = tonumber(mq.TLO.Spell(spellName).AERange()) or 40
                end)
                local spawn = mq.TLO.Spawn(targetId)
                local dist = spawn and spawn() and (tonumber(spawn.Distance()) or 999) or 999
                if dist <= aeRange then return step, spellName end
            end
        elseif step == 'charm' then
            local spellName = resolveCharmSpell(classConfig, profile)
            if spellName then return step, spellName end
            -- No charm spell memorized: the ladder can't finish.
            return nil, nil
        end
        table.remove(M.charm.breakSteps, 1)
    end
    return nil, nil
end

--- Select the next charm action without casting it (side-effect free apart
--- from internal break-ladder bookkeeping). Mirrors selectMezAction's shape.
-- @return table|nil action { targetId, targetName, spellName, charmStep, reason, urgent }
-- @return string reason
function M.selectCharmAction(settings)
    settings = settings or {}
    local Core = getCore()
    if Core and Core.Settings then
        for k, v in pairs(Core.Settings) do
            if settings[k] == nil then settings[k] = v end
        end
    end

    if settings.CharmEnabled ~= true then return nil, 'disabled' end
    if not M.isCharmClass() then return nil, 'not_charm_class' end

    local me = mq.TLO.Me
    if not (me and me()) then return nil, 'no_me' end

    local mezzedNow = false
    if me.Mezzed and me.Mezzed.ID then
        mezzedNow = (tonumber(me.Mezzed.ID()) or 0) > 0
    end
    if me.Stunned() or mezzedNow or (me.Silenced and me.Silenced()) then
        return nil, 'incapacitated'
    end
    if me.Moving() then return nil, 'moving' end

    local SpellEngine = getSpellEngine()
    if SpellEngine and SpellEngine.isBusy and SpellEngine.isBusy() then
        return nil, 'spell_engine_busy'
    end

    local now = os.clock()
    if (now - (M.charm.lastDecisionAt or 0)) < 0.25 then
        return nil, 'throttled'
    end
    M.charm.lastDecisionAt = now

    local profile = charmProfile()
    local classConfig = loadClassConfig(tostring(me.Class.ShortName() or ''):upper())
    if not (profile and classConfig) then return nil, 'no_profile' end

    local petIdNow = myPetId()
    local petId = tonumber(M.charm.petId) or 0

    -- Charm break handling ------------------------------------------------
    if petId > 0 then
        local petSpawn = mq.TLO.Spawn(petId)
        local petAlive = petSpawn and petSpawn() and not petSpawn.Dead()
        if not petAlive then
            clearCharm('pet_dead')
            petId = 0
        elseif petIdNow == petId then
            M.charm.breakSteps = nil
            M.charm.breakStartedAt = 0
            return nil, 'pet_active'
        else
            -- Pet slot empty but the mob lives: charm broke.
            if not M.charm.breakSteps then
                M.charm.breakSteps = { 'tash', 'stun', 'charm' }
                M.charm.breakStartedAt = now
                M.broadcastCharmState(true)
            end

            -- Escape hatch: with the camp out of control (several unmezzed
            -- haters beyond the ex-pet), recharming ties up our cast bar
            -- while mez is the thing keeping everyone alive. Defer the
            -- ladder — mez runs instead (the ex-pet itself is mezzable
            -- while broken), the tank taunt-protects, DPS still won't
            -- touch the pet — and resume once the count drops.
            local holdAt = tonumber(settings.CharmHoldUnmezzed) or CHARM_HOLD_UNMEZZED_DEFAULT
            local Cache = getCache()
            local unmezzed = 0
            for _, hater in pairs((Cache and Cache.xtarget and Cache.xtarget.haters) or {}) do
                local hid = tonumber(hater.id) or 0
                if hid > 0 and hid ~= petId and not M.isMobMezzed(hid) then
                    unmezzed = unmezzed + 1
                end
            end
            if unmezzed > holdAt then
                -- Pause the give-up clock while deferred: it should only
                -- measure active recharm effort. Flag the hold so mez
                -- selection prefers an AE mez — one cast locks the camp
                -- (ex-pet included) and reopens the recharm window.
                M.charm.breakStartedAt = now
                M.charm.campHoldAt = now
                return nil, 'camp_control_hold'
            end

            local attempts = M.charm.attempts[petId] or 0
            if attempts >= CHARM_MAX_ATTEMPTS
                or (now - M.charm.breakStartedAt) > CHARM_BREAK_GIVEUP_SEC then
                -- Give up: block the mob and release protection so the group
                -- can kill it.
                M.charm.blocked[petId] = now + CHARM_BLOCK_TTL_SEC
                M.charm.attempts[petId] = nil
                clearCharm('recharm_giveup')
                return nil, 'recharm_giveup'
            end

            local step, spellName = nextBreakStep(profile, classConfig, settings, petId)
            if not step then
                M.charm.blocked[petId] = now + CHARM_BLOCK_TTL_SEC
                clearCharm('no_break_spell')
                return nil, 'no_break_spell'
            end
            return {
                targetId = petId,
                targetName = M.charm.petName,
                spellName = spellName,
                charmStep = step,
                reason = 'charm_break_' .. step,
                urgent = true,
            }, 'charm_break_' .. step
        end
    end

    -- Acquisition ----------------------------------------------------------
    local charmSpell = resolveCharmSpell(classConfig, profile)
    if not charmSpell then return nil, 'no_charm_spell' end

    local Cache = getCache()
    local haters = Cache and Cache.xtarget and Cache.xtarget.haters or nil
    if not haters then return nil, 'no_haters' end

    local blacklist = parseClassBlacklist(settings)
    local maxLevel = charmSpellMaxLevel(charmSpell)
    local tankPrimary = tankPrimaryId()

    -- NOTE deliberate asymmetry: acquisition NEVER defers to mez — charm
    -- trumps mez in every situation except one: a BROKEN charm with the
    -- camp out of control (see the CharmHoldUnmezzed gate in the break
    -- ladder above). Charming a mob both removes an enemy and adds DPS,
    -- so it is always the better first cast.

    -- Solo hater: a lone valid mob is a free pet, not a kill — waive the
    -- tank-primary exclusion so the enchanter charms it out from under the
    -- fight. The charm-pet broadcast makes tank/DPS stand down on land.
    local haterCount = 0
    for _ in pairs(haters) do haterCount = haterCount + 1 end
    local soloHater = haterCount == 1

    local best, bestScore = nil, -math.huge
    for _, hater in pairs(haters) do
        local id = tonumber(hater.id) or 0
        local level = tonumber(hater.level) or 0
        local cls = tostring(hater.classShort or ''):upper()
        if id > 0
            and (id ~= tankPrimary or soloHater)
            and (os.clock() >= (M.charm.blocked[id] or 0))
            -- Resist cap: after CHARM_ACQUIRE_MAX_ATTEMPTS failed casts on a
            -- mob, move on to another candidate instead of nuking our mana
            -- bar retrying the same resistant one.
            and (M.charm.attempts[id] or 0) < CHARM_ACQUIRE_MAX_ATTEMPTS
            and not blacklist[cls]
            and (not maxLevel or level == 0 or level <= maxLevel)
            and not M.isMobImmuneToCC(hater.name or '', 'charm') then
            local claimed = M.isTargetClaimed(id)
            if not claimed then
                local spawn = mq.TLO.Spawn(id)
                local named = false
                if spawn and spawn() then
                    pcall(function() named = spawn.Named() == true end)
                end
                if spawn and spawn() and not spawn.Dead()
                    and not named
                    and (tonumber(spawn.Distance()) or 999) <= 150
                    and spawn.LineOfSight() then
                    -- Prefer mezzed mobs (safe cast window), then higher level
                    -- (stronger pet), then closer.
                    local score = (M.isMobMezzed(id) and 1000 or 0)
                        + level * 10
                        - (tonumber(hater.distance) or 0)
                    if score > bestScore then
                        best, bestScore = {
                            id = id,
                            name = tostring(hater.name or ''),
                        }, score
                    end
                end
            end
        end
    end

    if not best then return nil, 'no_charm_target' end

    -- An existing pet blocks charm (the cast fails with a pet up). An
    -- enchanter with charm enabled treats an animation as a placeholder:
    -- dismiss it once a real charm candidate is standing by. Deliberately
    -- AFTER candidate selection so we never dismiss without a replacement.
    if petIdNow > 0 then
        if (now - (M.charm.lastPetDismissAt or 0)) >= 5.0 then
            return {
                kind = 'pet_command',
                petCommand = 'dismiss',
                targetId = petIdNow,
                targetName = tostring(mq.TLO.Pet.CleanName() or ''),
                reason = 'charm_dismiss_pet',
                urgent = false,
            }, 'charm_dismiss_pet'
        end
        return nil, 'dismissing_pet'
    end

    -- Pre-tash: charm is an MR check, and tash deals no damage (mez-safe on
    -- a mezzed candidate). Land it first so the charm sticks.
    if settings.CharmPreTash ~= false and not mobTashed(best.id) then
        local tashSpell = chooseSpellForLines(classConfig, profile.tash)
        if tashSpell then
            return {
                targetId = best.id,
                targetName = best.name,
                spellName = tashSpell,
                charmStep = 'tash',
                reason = 'charm_pretash',
                urgent = false,
            }, 'charm_pretash'
        end
    end

    return {
        targetId = best.id,
        targetName = best.name,
        spellName = charmSpell,
        charmStep = 'charm',
        reason = 'charm_acquire',
        urgent = false,
    }, 'charm_acquire'
end

--- Cast one charm-ladder step (tash / stun / charm). Claims the target so
--- co-located mezzers don't fight us over it mid-recovery.
-- @param action table Action from selectCharmAction
-- @return boolean True if cast initiated
-- @return string|nil Error reason if false
function M.castCharmAction(action)
    if not action then return false, 'no_action' end
    local mobId = tonumber(action.targetId) or 0
    local spellName = tostring(action.spellName or '')
    if mobId == 0 then return false, 'invalid_target' end
    if spellName == '' then return false, 'no_spell' end

    local SpellEngine = getSpellEngine()
    if not SpellEngine then return false, 'no_spell_engine' end
    if SpellEngine.isBusy and SpellEngine.isBusy() then
        return false, 'spell_engine_busy'
    end
    local me = mq.TLO.Me
    local casting = me and me.Casting() or ''
    if casting ~= '' and casting ~= 'NULL' then
        return false, 'already_casting'
    end

    if not M.claimTarget(mobId, action.targetName) then
        return false, 'target_claimed'
    end

    local step = tostring(action.charmStep or 'charm')
    local category = step == 'charm' and 'charm'
        or step == 'stun' and 'stun'
        or 'debuff'

    local success, reason = SpellEngine.cast(spellName, mobId, {
        spellCategory = category,
        allowDead = false,
    })

    if not success then
        M.releaseClaim(mobId)
        return false, reason
    end

    local now = os.clock()
    if step == 'charm' then
        M.charm.pendingCharmTargetId = mobId
        M.charm.pendingCharmAt = now
        -- Never cleared on failure: lets charmTick adopt a pet whose Pet.ID
        -- registered a beat after the pending window was closed out.
        M.charm.lastCharmTargetId = mobId
    elseif step == 'tash' then
        -- Best effort: assume it lands; resists just mean an early recharm try.
        M.charm.tashedIds[mobId] = now
    end
    -- Ladder bookkeeping: tash/stun are one-shot per break; charm stays until
    -- it succeeds or the give-up counter trips.
    if M.charm.breakSteps and M.charm.breakSteps[1] == step and step ~= 'charm' then
        table.remove(M.charm.breakSteps, 1)
    end
    return true, nil
end

--- Per-tick charm upkeep: adopt cast results, detect breaks, drive the pet,
--- rebroadcast protection state. Called from sk_cc's onTick.
function M.charmTick(settings)
    settings = settings or {}
    local now = os.clock()
    local petIdNow = myPetId()

    -- Late adoption: a charm we cast succeeded but Pet.ID registered after
    -- the pending window was closed out as a failure.
    if (tonumber(M.charm.petId) or 0) == 0 and petIdNow > 0
        and petIdNow == (tonumber(M.charm.lastCharmTargetId) or 0) then
        M.charm.pendingCharmTargetId = petIdNow
        M.charm.pendingCharmAt = now
    end

    -- Resolve a pending charm cast: success = the target became our pet.
    local pendingId = tonumber(M.charm.pendingCharmTargetId) or 0
    if pendingId > 0 then
        if petIdNow == pendingId then
            dlog('charm-confirmed: pet=%d', pendingId)
            M.charm.petId = pendingId
            local ok, name = pcall(function()
                return tostring(mq.TLO.Spawn(pendingId).CleanName() or '')
            end)
            M.charm.petName = (ok and name ~= '') and name or M.charm.petName
            M.charm.breakSteps = nil
            M.charm.breakStartedAt = 0
            M.charm.attempts[pendingId] = nil
            M.charm.pendingCharmTargetId = 0
            M.charm.pendingCharmAt = 0
            M.releaseClaim(pendingId)
            M.broadcastCharmState(true)
        elseif (now - (M.charm.pendingCharmAt or 0)) > 12 then
            -- Cast window long gone with no pet: count the failure.
            dlog('charm-fail: no pet 12s after cast target=%d attempts=%d',
                pendingId, (M.charm.attempts[pendingId] or 0) + 1)
            M.charm.attempts[pendingId] = (M.charm.attempts[pendingId] or 0) + 1
            M.charm.pendingCharmTargetId = 0
            M.charm.pendingCharmAt = 0
            M.releaseClaim(pendingId)
        elseif (now - (M.charm.pendingCharmAt or 0)) > 1.0 then
            -- Grace period: don't inspect the engine in the same instant the
            -- cast was initiated or a not-yet-busy engine reads as a failure.
            local SpellEngine = getSpellEngine()
            local busy = SpellEngine and SpellEngine.isBusy and SpellEngine.isBusy()
            local casting = mq.TLO.Me.Casting() or ''
            if not busy and (casting == '' or casting == 'NULL') then
                -- Cast fully resolved without producing a pet: failed.
                dlog('charm-fail: cast resolved, no pet (resist/interrupt) target=%d attempts=%d',
                    pendingId, (M.charm.attempts[pendingId] or 0) + 1)
                M.charm.attempts[pendingId] = (M.charm.attempts[pendingId] or 0) + 1
                M.charm.pendingCharmTargetId = 0
                M.charm.pendingCharmAt = 0
                M.releaseClaim(pendingId)
            end
        end
    end

    local petId = tonumber(M.charm.petId) or 0
    if petId <= 0 then return end

    -- Death cleanup outside the selection path too, so protection is released
    -- even while claims route elsewhere.
    local petSpawn = mq.TLO.Spawn(petId)
    if not (petSpawn and petSpawn() and not petSpawn.Dead()) then
        clearCharm('pet_dead')
        return
    end

    -- Keep the protection broadcast warm (receivers fail open after 30s).
    M.broadcastCharmState(false)

    -- Pet command upkeep only while the charm is actually holding.
    if petIdNow ~= petId then return end
    if (now - (M.charm.lastPetCmdAt or 0)) < CHARM_PET_CMD_INTERVAL then return end

    local primaryId = tankPrimaryId()
    local primarySpawn = primaryId > 0 and mq.TLO.Spawn(primaryId) or nil
    local primaryAlive = primarySpawn and primarySpawn() and not primarySpawn.Dead()

    if primaryAlive and not M.isMobMezzed(primaryId) then
        local petTargetId = 0
        pcall(function() petTargetId = tonumber(mq.TLO.Pet.Target.ID()) or 0 end)
        if petTargetId ~= primaryId then
            return {
                kind = 'pet_command',
                petCommand = 'attack',
                targetId = primaryId,
                reason = 'charm_pet_attack',
            }
        end
    else
        local petFighting = false
        pcall(function() petFighting = mq.TLO.Pet.Combat() == true end)
        if petFighting then
            return {
                kind = 'pet_command',
                petCommand = 'backoff',
                targetId = petId,
                reason = 'charm_pet_backoff',
            }
        end
    end
end

function M.executePetCommand(action)
    if type(action) ~= 'table' then return false, 'no_action' end
    local command = tostring(action.petCommand or '')
    if command == 'dismiss' then
        mq.cmd('/pet get lost')
        M.charm.lastPetDismissAt = os.clock()
    elseif command == 'attack' then
        local targetId = tonumber(action.targetId) or 0
        if targetId <= 0 then return false, 'invalid_target' end
        mq.cmdf('/pet attack %d', targetId)
        M.charm.lastPetCmdAt = os.clock()
    elseif command == 'backoff' then
        mq.cmd('/pet back off')
        M.charm.lastPetCmdAt = os.clock()
    else
        return false, 'unknown_pet_command'
    end
    return true, 'issued'
end

return M
