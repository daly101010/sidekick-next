-- Shared policy for cross-character Actors leases and message processing.
--
-- Keep these values in one place: a sender that stops advancing must not leave
-- different modules applying unrelated definitions of "fresh".

local M = {}

M.HEARTBEAT_SECONDS = 2.0
M.PEER_STALE_SECONDS = 4.0
M.PEER_ACTIVITY_RETENTION_SECONDS = 60.0
M.REMOTE_STATUS_RETENTION_SECONDS = 10.0

M.CLAIM_TTL_SECONDS = {
    HEAL = 5.0,
    HOT = 18.0,
    CC = 5.0,
    BUFF = 8.0,
    DEBUFF = 8.0,
    CURE = 8.0,
    REZ = 3.0,
    CHARM = 30.0,
}

M.STATE_TTL_SECONDS = {
    ACTOR_TARGET = 5.0,
    PULL = 4.0,
}

M.MESSAGE_QUEUE = {
    MAX_PENDING = 500,
    MAX_PER_DRAIN = 64,
}

--- Convert a local monotonic claim timestamp into remaining milliseconds.
function M.localLeaseRemainingMs(claimedAt, ttlSeconds, now)
    now = tonumber(now) or os.clock()
    local elapsed = math.max(0, now - (tonumber(claimedAt) or 0))
    return math.max(0, math.floor(((tonumber(ttlSeconds) or 0) - elapsed) * 1000))
end

--- Convert a wall-clock expiry into remaining milliseconds.
function M.epochLeaseRemainingMs(expiresAt, nowEpoch)
    nowEpoch = tonumber(nowEpoch) or os.time()
    return math.max(0, math.floor(((tonumber(expiresAt) or 0) - nowEpoch) * 1000))
end

--- Evaluate a claim that uses a receiver-local os.clock() timestamp.
-- Unknown senders remain usable until their claim TTL expires; observed stale
-- senders are invalidated immediately.
function M.evaluateLocalClaim(actorsCoordinator, claim, ttlSeconds, now)
    claim = type(claim) == 'table' and claim or {}
    now = tonumber(now) or os.clock()
    local remainingMs = M.localLeaseRemainingMs(claim.claimedAt, ttlSeconds, now)
    local info = {
        leaseRemainingMs = remainingMs,
        peerAgeMs = nil,
        peerReason = 'not_checked',
        peerKnown = false,
    }
    local function annotate()
        claim.peerAgeMs = info.peerAgeMs
        claim.peerReason = info.peerReason
        claim.leaseRemainingMs = info.leaseRemainingMs
    end
    if remainingMs <= 0 then
        info.peerReason = 'lease_expired'
        annotate()
        return false, info
    end

    if actorsCoordinator and actorsCoordinator.isPeerLeaseFresh then
        local fresh, peer = actorsCoordinator.isPeerLeaseFresh(
            claim.claimer or claim.from or claim.ownerName,
            claim.zone,
            claim.server)
        peer = peer or {}
        info.peerAgeMs = peer.ageMs
        info.peerReason = peer.reason or 'unknown'
        info.peerKnown = peer.known == true
        if peer.known == true and fresh == false then
            annotate()
            return false, info
        end
    end
    annotate()
    return true, info
end

function M.formatPeerBlock(prefix, claimer, info)
    info = type(info) == 'table' and info or {}
    return string.format('%s:%s:peerAge=%sms:lease=%sms',
        tostring(prefix or 'claimed_by'),
        tostring(claimer or 'unknown'),
        tostring(info.peerAgeMs or '?'),
        tostring(info.leaseRemainingMs or '?'))
end

return M
