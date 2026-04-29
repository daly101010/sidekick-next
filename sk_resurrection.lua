-- F:/lua/sidekick-next/sk_resurrection.lua
-- Resurrection module for SideKick multi-script system.
-- Priority 2: auto-rezzes dead group members (group only).
--
-- Behavior:
--   OOC + AutoRezOOC=true: cast highest-tier learned, currently-memorized
--   rez spell on the dead group member's corpse after a /corpse drag.
--
--   In-combat + AutoRezInCombat=true: fire class battle-rez AA. Despite
--   the "instant" reputation, modern Blessing of Resurrection has a real
--   cast time (~5s) and will pause the heal rotation for its duration —
--   the toggle is opt-in to acknowledge that trade-off. Spell-rez is
--   never used in combat.
--
--   AutoRezOOC=false / AutoRezInCombat=false: do nothing in that state.
--
-- v1 does NOT auto-memorize rez spells. If no class rez line is in a gem,
-- the module skips and logs once per corpse (10s suppress).
--
-- Cross-box coordination: first-cast-wins. EQ engine serializes — a
-- second rez to an already-rezzed corpse fails harmlessly.

local mq = require('mq')
local lib = require('sidekick-next.sk_lib')
local ModuleBase = require('sidekick-next.sk_module_base')
local lazy = require('sidekick-next.utils.lazy_require')

local RezData = require('sidekick-next.utils.rez_data')
local getCore = lazy('sidekick-next.utils.core')

-- Priority 2 maps to lib.Priority.RESURRECTION.
local module = ModuleBase.create('resurrection', lib.Priority.RESURRECTION)

-------------------------------------------------------------------------------
-- Tunables
-------------------------------------------------------------------------------

local LAST_ATTEMPT_SUPPRESS_MS = 10000  -- Skip same corpse for 10s after attempt.
local CORPSE_DRAG_DELAY_MS     = 300    -- Wait after /corpse for the drag.
local CAST_TIMEOUT_MARGIN_MS   = 2000   -- Add 2s safety to spell cast time.

-- Diagnostic echo so we can see what the module is deciding. Throttled per
-- (key) to avoid chat spam (module ticks every 50ms). Flip DEBUG to false
-- once stable.
local DEBUG = false
local _lastDbg = {}
local DBG_THROTTLE_MS = 2000
local function dbg(key, fmt, ...)
    if not DEBUG then return end
    local now = mq.gettime()
    if (now - (_lastDbg[key] or 0)) < DBG_THROTTLE_MS then return end
    _lastDbg[key] = now
    mq.cmdf('/echo \aw[sk_rez] %s', string.format(fmt, ...))
end

-------------------------------------------------------------------------------
-- State
-------------------------------------------------------------------------------

local _lastAttempt = {}                 -- [corpseSpawnId] = timeMs

-------------------------------------------------------------------------------
-- Settings access
-------------------------------------------------------------------------------

local function settingBool(key, default)
    local Core = getCore()
    if not (Core and Core.Settings) then return default end
    local v = Core.Settings[key]
    if v == nil then return default end
    return v == true
end

local function autoRezOOC()        return settingBool('AutoRezOOC',     true)  end
local function autoRezInCombat()   return settingBool('AutoRezInCombat', false) end

-------------------------------------------------------------------------------
-- Class detection
-------------------------------------------------------------------------------

local function myClassShort()
    return lib.safeTLO(function() return mq.TLO.Me.Class.ShortName() end, '') or ''
end

-------------------------------------------------------------------------------
-- Rez resource discovery
-------------------------------------------------------------------------------

--- Build a set of currently-memmed gem names with EXACT match (defends
--- against MQ's substring lookup behavior on Me.Gem(name)).
local function currentGemNames()
    local names = {}
    for slot = 1, 13 do
        local n = lib.safeTLO(function() return mq.TLO.Me.Gem(slot).Name() end, '') or ''
        if n ~= '' then names[n] = true end
    end
    return names
end

--- Return the first rez spell that is currently memorized (exact-name).
--- We don't separately check Me.Book — being in a gem implies it's known.
local function pickMemorizedRezSpell()
    local memmed = currentGemNames()
    for _, name in ipairs(RezData.getSpells(myClassShort())) do
        if memmed[name] then return name end
    end
    return nil
end

--- Return the class battle-rez AA name iff it's currently ready, or nil.
local function pickReadyAA()
    local aaName = RezData.getAA(myClassShort())
    if not aaName then return nil end
    local ready = lib.safeTLO(function()
        return mq.TLO.Me.AltAbilityReady(aaName)()
    end, false)
    return ready and aaName or nil
end

-------------------------------------------------------------------------------
-- Corpse hunting
-------------------------------------------------------------------------------

--- Find the first dead group member with a corpse spawn in this zone that
--- isn't currently suppressed by _lastAttempt. Skips members who are
--- offline or in another zone — their Dead() may report stale state but
--- there is no corpse to rez here.
--- @return number|nil corpseId, string|nil memberName
local function findRezTarget()
    local now = lib.getTimeMs()
    local groupCount = lib.getGroupCount()
    for i = 1, groupCount do
        local member = mq.TLO.Group.Member(i)
        if member and member() then
            local offline   = lib.safeTLO(function() return member.Offline() end, false) == true
            local otherZone = lib.safeTLO(function() return member.OtherZone() end, false) == true
            local deadVal   = lib.safeTLO(function() return member.Dead() end, false)
            local dead      = deadVal == true
            if dead and not offline and not otherZone then
                local name = lib.safeTLO(function() return member.CleanName() end, nil)
                    or lib.safeTLO(function() return member.Name() end, nil)
                dbg('member_dead_' .. tostring(i),
                    'member %d "%s": Dead=%s Offline=%s OtherZone=%s',
                    i, tostring(name or '?'), tostring(deadVal),
                    tostring(offline), tostring(otherZone))
                if name and name ~= '' then
                    -- PC corpses are named "<charname>'s corpse" in EQ. Use
                    -- exact-name match against the full corpse name plus the
                    -- pccorpse filter — substring matching against just the
                    -- charname picks up unrelated NPC corpses whose names
                    -- happen to contain that substring.
                    local searchPattern = string.format([[pccorpse ="%s's corpse"]], name)
                    local corpseSpawn = mq.TLO.Spawn(searchPattern)
                    if corpseSpawn and corpseSpawn() then
                        local typ = lib.safeTLO(function() return corpseSpawn.Type() end, '')
                        local cName = lib.safeTLO(function() return corpseSpawn.CleanName() end, '')
                        if typ == 'Corpse' then
                            local id = lib.safeNum(function() return corpseSpawn.ID() end, 0)
                            if id > 0 then
                                local lastAt = _lastAttempt[id] or 0
                                if (now - lastAt) >= LAST_ATTEMPT_SUPPRESS_MS then
                                    dbg('target_' .. tostring(id),
                                        'TARGET: id=%d cleanName="%s" type=%s for member="%s"',
                                        id, tostring(cName), tostring(typ), tostring(name))
                                    return id, name
                                else
                                    dbg('suppressed_' .. tostring(id),
                                        'suppressed corpse id=%d (last attempt %.1fs ago)',
                                        id, (now - lastAt) / 1000)
                                end
                            end
                        else
                            dbg('non_corpse_' .. tostring(name),
                                'matched non-corpse spawn for "%s" (type=%s)',
                                tostring(name), tostring(typ))
                        end
                    end
                end
            end
        end
    end
    return nil, nil
end

local function corpseDistance(corpseId)
    local s = mq.TLO.Spawn(corpseId)
    if not (s and s()) then return nil end
    return lib.safeNum(function() return s.Distance() end, 99999)
end

-------------------------------------------------------------------------------
-- Module callbacks
-------------------------------------------------------------------------------

module.shouldAct = function(self)
    if not self:hasValidState() then return false end

    -- Gate on user toggles for the current combat state.
    local inCombat = lib.inCombat()
    if inCombat and not autoRezInCombat() then return false end
    if (not inCombat) and not autoRezOOC() then return false end

    -- Need a corpse target.
    local corpseId = findRezTarget()
    if not corpseId then return false end

    -- Need a rez resource appropriate for the situation.
    if inCombat then
        if not pickReadyAA() then return false end
    else
        if not pickMemorizedRezSpell() then return false end
    end

    return true
end

module.getAction = function(self)
    local inCombat = lib.inCombat()
    local corpseId, memberName = findRezTarget()
    if not corpseId then return nil end

    if inCombat then
        local aa = pickReadyAA()
        if not aa then return nil end
        return {
            kind = lib.ActionKind.USE_AA,
            name = aa,
            targetId = corpseId,
            idempotencyKey = string.format('rez:aa:%d', corpseId),
            reason = string.format('battle-rez %s', tostring(memberName or corpseId)),
        }
    else
        local spell = pickMemorizedRezSpell()
        if not spell then return nil end
        return {
            kind = lib.ActionKind.CAST_SPELL,
            name = spell,
            targetId = corpseId,
            idempotencyKey = string.format('rez:spell:%d', corpseId),
            reason = string.format('rez %s', tostring(memberName or corpseId)),
        }
    end
end

local function targetCorpse(corpseId)
    mq.cmdf('/target id %d', corpseId)
    mq.delay(150, function()
        local t = mq.TLO.Target
        return t and t() and lib.safeNum(function() return t.ID() end, 0) == corpseId
    end)
    local t = mq.TLO.Target
    return t and t() and lib.safeNum(function() return t.ID() end, 0) == corpseId
end

local function dragCorpse(corpseId)
    -- /corpse drags consented corpses (group members are auto-consented).
    -- Harmless if we're already at the corpse or out of drag range.
    mq.cmd('/corpse')
    mq.delay(CORPSE_DRAG_DELAY_MS)
end

local function awaitCastCompletion(spellName)
    local spell = mq.TLO.Spell(spellName)
    local castTimeMs = lib.safeNum(function() return spell.MyCastTime() end, 6000)
    local timeoutMs = castTimeMs + CAST_TIMEOUT_MARGIN_MS
    local startMs = lib.getTimeMs()
    -- Wait for the cast to start (engine takes a tick).
    mq.delay(150)
    while lib.isCasting() do
        mq.delay(50)
        if (lib.getTimeMs() - startMs) > timeoutMs then
            lib.log('warn', module.name, 'cast timeout: %s', spellName)
            break
        end
    end
end

module.executeAction = function(self)
    if not self:ownsAction() then return false, 'no_ownership' end

    local action = self.state.castOwner and self.state.castOwner.action
    if not action then return false, 'no_action' end

    local corpseId = action.targetId
    local now = lib.getTimeMs()
    _lastAttempt[corpseId] = now

    -- 1) Target the corpse.
    if not targetCorpse(corpseId) then
        lib.log('warn', module.name, 'failed to target corpse id %d', corpseId or -1)
        return true, 'target_failed'
    end

    -- 2) Drag the corpse to our feet (group consent is implicit).
    --    No-op if already at feet; harmless if too far to drag.
    dragCorpse(corpseId)

    -- 3) Re-verify range after drag. If still too far, abort.
    local dist = corpseDistance(corpseId) or 99999
    if action.kind == lib.ActionKind.CAST_SPELL then
        local spell = mq.TLO.Spell(action.name)
        local range = lib.safeNum(function() return spell.MyRange() end, 100)
        if dist > range then
            lib.log('info', module.name,
                'corpse out of cast range after /corpse: dist=%.1f range=%.0f',
                dist, range)
            return true, 'out_of_range'
        end
    elseif action.kind == lib.ActionKind.USE_AA then
        -- Use the AA's underlying spell range when available; otherwise
        -- fall through and let the engine refuse if out of range.
        local aaRange = lib.safeNum(function()
            return mq.TLO.Me.AltAbility(action.name).Spell.MyRange()
        end, 0)
        if aaRange > 0 and dist > aaRange then
            lib.log('info', module.name,
                'corpse out of AA range after /corpse: dist=%.1f range=%.0f',
                dist, aaRange)
            return true, 'out_of_range'
        end
    end

    -- 4) Fire the rez.
    if action.kind == lib.ActionKind.USE_AA then
        -- /alt activate takes the AA's numeric ID, not its name. Resolve
        -- the ID via Me.AltAbility(name).ID(); abort with a 10s suppress
        -- if the AA isn't on the character.
        local aaId = lib.safeNum(function()
            return mq.TLO.Me.AltAbility(action.name).ID()
        end, 0)
        if aaId <= 0 then
            dbg('aa_no_id_' .. tostring(action.name),
                'cannot resolve AA id for "%s" — skipping', tostring(action.name))
            return true, 'aa_id_unresolved'
        end
        dbg('battle_rez_fire',
            'battle-rez: /alt activate %d ("%s") target=%d',
            aaId, action.name, corpseId)
        mq.cmdf('/alt activate %d', aaId)
        mq.delay(200)
        if lib.isCasting() then
            awaitCastCompletion(action.name)
        end
    else
        lib.log('info', module.name, 'rez: /cast "%s" target=%d',
            action.name, corpseId)
        mq.cmdf('/cast "%s"', action.name)
        awaitCastCompletion(action.name)
    end

    return true, 'completed'
end

-------------------------------------------------------------------------------
-- Run (gated on class — non-rez classes exit immediately)
-------------------------------------------------------------------------------

if not RezData.isRezClass(myClassShort()) then
    -- Not a rez class. Module exits without running so we don't waste ticks.
    return module
end

module:run(50)

return module
