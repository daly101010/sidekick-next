-- Buff request queue. A peer that wants a buff broadcasts `buff:need`; any
-- buffer that has the requested category in their config picks it up and
-- jumps it to the front of their next scan.
--
-- Data shape:
--   _requests[targetId] = { [category] = { from, requestedAt, expiresAt, urgency } }
--
-- Lifetime: requests expire after TTL (default 30s) or are explicitly cleared
-- when the requesting peer's buff is observed to land (cleared via the
-- existing buff:landed broadcast — see actors_coordinator hookup).
--
-- Wiring:
--   - `actors_coordinator.lua` dispatches `buff:need` and `buff:landed` to us.
--   - `sk_buffs.lua` queries M.peekHighestPriority() before its normal scan.
--   - User broadcasts via M.broadcastNeed(category) (slash command, UI button,
--     or auto on rez).

local mq = require('mq')

local M = {}

local DEFAULT_TTL = 30      -- seconds
local URGENT_TTL = 60       -- 'high' urgency lasts longer

local _requests = {}        -- [targetId][category] = { from, requestedAt, expiresAt, urgency, lineName }

local function now() return os.time() end

local function selfId()
    return (mq.TLO.Me and mq.TLO.Me.ID and mq.TLO.Me.ID()) or 0
end

local function selfName()
    return (mq.TLO.Me and mq.TLO.Me.CleanName and mq.TLO.Me.CleanName()) or ''
end

local function getActors()
    local ok, A = pcall(require, 'sidekick-next.utils.actors_coordinator')
    return ok and A or nil
end

-- ---------------------------------------------------------------------------
-- Pruning
-- ---------------------------------------------------------------------------

local _lastPruneAt = 0
local PRUNE_INTERVAL = 5

local function pruneExpired()
    local n = now()
    for tid, perCat in pairs(_requests) do
        for cat, req in pairs(perCat) do
            if (req.expiresAt or 0) <= n then
                perCat[cat] = nil
            end
        end
        if not next(perCat) then
            _requests[tid] = nil
        end
    end
end

function M.tick()
    local n = now()
    if (n - _lastPruneAt) >= PRUNE_INTERVAL then
        _lastPruneAt = n
        pruneExpired()
    end
end

-- ---------------------------------------------------------------------------
-- Receiving (actors → queue)
-- ---------------------------------------------------------------------------

--- Record an incoming buff:need request from a peer.
--- @param payload table { from, targetId?, category, lineName?, urgency?, ttl? }
function M.receiveNeed(payload)
    if type(payload) ~= 'table' then return end
    local from = tostring(payload.from or '')
    local category = tostring(payload.category or '')
    if from == '' or category == '' then return end

    -- targetId defaults to the requester themselves; resolved by spawn name
    -- since cross-client peer IDs aren't shared.
    local tid = tonumber(payload.targetId) or 0
    if tid <= 0 and from ~= '' then
        local sp = mq.TLO.Spawn and mq.TLO.Spawn('pc =' .. from)
        if sp and sp() then tid = sp.ID() or 0 end
    end
    if tid <= 0 then return end

    local urgency = tostring(payload.urgency or 'normal')
    local ttl = tonumber(payload.ttl) or (urgency == 'high' and URGENT_TTL or DEFAULT_TTL)

    _requests[tid] = _requests[tid] or {}
    _requests[tid][category] = {
        from = from,
        lineName = payload.lineName,
        urgency = urgency,
        requestedAt = now(),
        expiresAt = now() + ttl,
    }
end

--- Clear a request when the buff is observed to land (any source).
--- @param targetId number
--- @param category string
function M.clearRequest(targetId, category)
    local tid = tonumber(targetId) or 0
    if tid <= 0 then return end
    if _requests[tid] then
        _requests[tid][category] = nil
        if not next(_requests[tid]) then
            _requests[tid] = nil
        end
    end
end

-- ---------------------------------------------------------------------------
-- Broadcasting (this peer needs a buff)
-- ---------------------------------------------------------------------------

--- Broadcast a buff need request. Other peers with that category will pick it up.
--- @param category string Buff category from your spellset (e.g. 'Symbol', 'Aego')
--- @param opts table|nil { lineName?, urgency? = 'normal'|'high', targetId? }
function M.broadcastNeed(category, opts)
    opts = opts or {}
    local Actors = getActors()
    if not Actors or not Actors.broadcast then return end

    local payload = {
        category = tostring(category or ''),
        lineName = opts.lineName,
        urgency = opts.urgency or 'normal',
        targetId = opts.targetId or selfId(),
    }
    if payload.category == '' then return end

    Actors.broadcast('buff:need', payload)

    -- Also record locally so our own `findBuffNeed()` can prioritize it on
    -- the next tick, before any peer responds.
    payload.from = selfName()
    M.receiveNeed(payload)
end

-- ---------------------------------------------------------------------------
-- Query (used by sk_buffs.findBuffNeed)
-- ---------------------------------------------------------------------------

--- Return the highest-urgency, oldest pending request as { targetId, category,
--- from, urgency, lineName }, or nil if queue is empty.
function M.peekHighestPriority()
    pruneExpired()
    local best = nil
    for tid, perCat in pairs(_requests) do
        for cat, req in pairs(perCat) do
            local score = (req.urgency == 'high' and 1000 or 0) - (req.requestedAt or 0)
            if not best or score > best.score then
                best = {
                    score = score,
                    targetId = tid,
                    category = cat,
                    from = req.from,
                    urgency = req.urgency,
                    lineName = req.lineName,
                }
            end
        end
    end
    return best
end

--- Get the request for a specific (targetId, category) pair, or nil.
function M.getRequest(targetId, category)
    local perCat = _requests[tonumber(targetId) or 0]
    return perCat and perCat[category] or nil
end

function M.getAll() return _requests end

return M
