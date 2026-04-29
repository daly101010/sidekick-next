-- F:/lua/SideKick/utils/runtime_cache.lua
-- Runtime Cache (Blackboard) - Centralized game state snapshot
-- Computes expensive TLO queries on a cadence, all modules read from here

local mq = require('mq')
local lazy = require('sidekick-next.utils.lazy_require')

local M = {}

-- Settings reference for checking IgnorePCPets
M._settings = nil

-- Lazy-load Targeting module to avoid circular dependency
local getTargeting = lazy('sidekick-next.utils.targeting')

-- Get setting value (with fallback)
local function getSetting(key)
    if M._settings and M._settings[key] ~= nil then
        return M._settings[key]
    end
    return nil
end

--- Set settings reference for runtime cache
-- @param settings table Settings table
function M.setSettings(settings)
    M._settings = settings
end

-- Cache data
M.me = {}
M.target = {}
M.group = {}
M.xtarget = {}

-- Buff tracking state (persists between group updates)
M.buffState = {}  -- { [memberId] = { [buffCategory] = { present, remaining, spellId, checkedAt } } }

-- Timing
local _lastHeavyUpdate = 0
local _lastLightUpdate = 0
local _lastBuffScan = 0
local _lastBuffCleanup = 0
local HEAVY_INTERVAL = 0.10  -- 100ms for group HP/position scans (healing needs fresh data)
local LIGHT_INTERVAL = 0.05  -- 50ms for lightweight self checks
local BUFF_SCAN_INTERVAL = 3.0  -- 3s between buff scans (expensive due to retargeting)
local BUFFSTATE_CLEANUP_INTERVAL = 30.0  -- 30s between prunes of stale buffState entries

function M.init()
    M.me = {}
    M.target = {}
    M.group = {}
    M.xtarget = {}
    M.buffState = {}
    _identityCached = false
end

function M.tick()
    local now = os.clock()

    -- Light update (every 50ms) — self + target snapshot
    if (now - _lastLightUpdate) >= LIGHT_INTERVAL then
        _lastLightUpdate = now
        M.updateLight()
        return  -- Stagger: only one update type per tick to spread TLO load
    end

    -- Heavy update (every 100ms) — group HP, xtarget, positions
    if (now - _lastHeavyUpdate) >= HEAVY_INTERVAL then
        _lastHeavyUpdate = now
        M.updateHeavy()
    end

    -- Periodic buffState prune (keeps the table from growing unbounded as mobs
    -- cycle through XTarget). Must run after heavy update so M.group/xtarget
    -- are populated for the valid-id set.
    if (now - _lastBuffCleanup) >= BUFFSTATE_CLEANUP_INTERVAL then
        _lastBuffCleanup = now
        M.cleanupBuffState()
    end
end

-- Cached identity fields (id/name/class/level rarely change during a session)
local _cachedId = 0
local _cachedName = ''
local _cachedClass = ''
local _cachedLevel = 0
local _identityCached = false

function M.updateLight()
    local me = mq.TLO.Me
    if not me or not me() then
        M.me = {}
        return
    end

    -- Cache identity fields once (these don't change during gameplay)
    if not _identityCached then
        _cachedId = tonumber(me.ID()) or 0
        _cachedName = me.CleanName() or ''
        _cachedClass = (me.Class and me.Class.ShortName()) or ''
        _cachedLevel = tonumber(me.Level()) or 0
        _identityCached = (_cachedId > 0)
    end

    -- Casting state: check once, derive all fields
    local castSpell = me.Casting() or ''
    local isCasting = castSpell ~= '' and castSpell ~= 'NULL'
    local castingId = 0
    local castingTargetId = 0
    if isCasting then
        local castingObj = me.Casting
        if castingObj and castingObj.ID then
            castingId = tonumber(castingObj.ID()) or 0
        end
        local castTarget = me.CastingTarget
        if castTarget and castTarget() then
            castingTargetId = tonumber(castTarget.ID()) or 0
        end
    end

    M.me = {
        id = _cachedId,
        name = _cachedName,
        class = _cachedClass,
        level = _cachedLevel,

        -- Resources (checked frequently for heals/burns)
        hp = tonumber(me.PctHPs()) or 0,
        mana = tonumber(me.PctMana()) or 0,
        endur = tonumber(me.PctEndurance()) or 0,

        -- Combat state
        combat = me.Combat() == true,
        casting = isCasting,
        castingSpell = castSpell,
        castingId = castingId,
        castingTargetId = castingTargetId,
        moving = me.Moving() == true,
        sitting = me.Sitting() == true,
        standing = me.Standing() == true,
        stunned = me.Stunned() == true,

        -- Aggro (0-100; 100 = full aggro, <100 = deficit)
        pctAggro = tonumber(me.PctAggro()) or 0,
        secondaryPctAggro = tonumber(me.SecondaryPctAggro()) or 0,
    }

    -- Self pet tracking
    local myPet = me.Pet
    if myPet and myPet() then
        local petId = tonumber(myPet.ID()) or 0
        if petId > 0 then
            if not M.buffState[petId] then M.buffState[petId] = {} end
            M.me.pet = {
                id = petId,
                name = myPet.CleanName() or '',
                hp = tonumber(myPet.PctHPs()) or 100,
                distance = tonumber(myPet.Distance()) or 0,
                buffs = M.buffState[petId],
            }
        else
            M.me.pet = nil
        end
    else
        M.me.pet = nil
    end

    -- Target snapshot
    local target = mq.TLO.Target
    local targetId = target and target() and tonumber(target.ID()) or 0
    if targetId > 0 then
        -- Resolve debuff spell names once; MQ Spell-typed TLOs stringify to
        -- "NULL" when empty, so a raw `~= nil and ~= ''` check would report
        -- every non-mezzed mob as mezzed.
        local function _debuffActive(accessor)
            if not accessor then return false end
            local v = accessor()
            return v ~= nil and v ~= '' and v ~= 'NULL'
        end
        M.target = {
            id = targetId,
            name = target.CleanName() or '',
            type = target.Type() or '',
            level = tonumber(target.Level()) or 0,
            hp = tonumber(target.PctHPs()) or 100,
            distance = tonumber(target.Distance()) or 999,
            los = target.LineOfSight() == true,
            named = target.Named() == true,

            -- Debuff state (for CC/tank decisions)
            mezzed = _debuffActive(target.Mezzed),
            slowed = _debuffActive(target.Slowed),
            rooted = _debuffActive(target.Rooted),

            -- Target of target (for aggro decisions)
            totId = (target.TargetOfTarget and target.TargetOfTarget.ID and tonumber(target.TargetOfTarget.ID())) or 0,
        }
    else
        M.target = {}
    end
end

function M.updateHeavy()
    -- Group snapshot
    local memberCount = tonumber(mq.TLO.Group.Members()) or 0
    local members = {}
    local injuredCount = 0
    local injuredThreshold = 80  -- Consider injured below 80%
    local centroidX, centroidY, centroidCount = 0, 0, 0
    local myId = M.me.id or 0

    for i = 1, memberCount do
        local member = mq.TLO.Group.Member(i)
        if not member or not member() then goto nextMember end

        local memberId = tonumber(member.ID()) or 0
        if memberId <= 0 then goto nextMember end

        local hp = tonumber(member.PctHPs()) or 100

        -- Ensure buff state exists for this member
        if not M.buffState[memberId] then M.buffState[memberId] = {} end

        -- Check for pet
        local pet = nil
        local memberPet = member.Pet
        if memberPet and memberPet() then
            local petId = tonumber(memberPet.ID()) or 0
            if petId > 0 then
                if not M.buffState[petId] then M.buffState[petId] = {} end
                pet = {
                    id = petId,
                    name = memberPet.CleanName() or '',
                    hp = tonumber(memberPet.PctHPs()) or 100,
                    distance = tonumber(memberPet.Distance()) or 999,
                    buffs = M.buffState[petId],
                }
            end
        end

        members[i] = {
            id = memberId,
            name = member.CleanName() or '',
            class = (member.Class and member.Class.ShortName()) or '',
            hp = hp,
            distance = tonumber(member.Distance()) or 999,
            buffs = M.buffState[memberId],
            pet = pet,
        }

        if hp < injuredThreshold then
            injuredCount = injuredCount + 1
        end

        -- Centroid calculation (exclude self)
        if memberId ~= myId then
            centroidX = centroidX + (tonumber(member.X()) or 0)
            centroidY = centroidY + (tonumber(member.Y()) or 0)
            centroidCount = centroidCount + 1
        end
        ::nextMember::
    end

    M.group = {
        count = memberCount,
        members = members,
        injuredCount = injuredCount,
        centroidX = centroidCount > 0 and (centroidX / centroidCount) or nil,
        centroidY = centroidCount > 0 and (centroidY / centroidCount) or nil,
    }

    -- XTarget snapshot
    local xtCount = tonumber(mq.TLO.Me.XTarget()) or 0
    local haters = {}
    local aggroDeficitCount = 0

    -- Cache setting + targeting module outside loop (avoid per-iteration lookup)
    local ignorePCPets = getSetting('IgnorePCPets') ~= false  -- Default true
    local Targeting = ignorePCPets and getTargeting() or nil
    local isPCPet = Targeting and Targeting.isPCPet or nil

    for i = 1, xtCount do
        local xt = mq.TLO.Me.XTarget(i)
        if not xt then goto continue end
        local xtId = tonumber(xt.ID()) or 0
        if xtId <= 0 then goto continue end

        -- Only count actual combat haters. XTarget slots can be configured to PCs/NPCs/etc.
        local rawTT = xt.TargetType and xt.TargetType()
        local targetType = rawTT and tostring(rawTT):lower() or ''

        local aggressive = xt.Aggressive and xt.Aggressive() == true
        if not aggressive and targetType ~= 'auto hater' then
            goto continue
        end

        local dead = xt.Dead and xt.Dead() == true
        if dead then goto continue end
        local hpPct = tonumber(xt.PctHPs and xt.PctHPs()) or 100
        if hpPct <= 0 then goto continue end

        -- Check if this is a PC pet and should be ignored
        if isPCPet and isPCPet(xtId) then
            goto continue
        end

        local aggro = tonumber(xt.PctAggro()) or 100
        local totId = (xt.TargetOfTarget and xt.TargetOfTarget.ID and tonumber(xt.TargetOfTarget.ID())) or 0

        local mezVal = xt.Mezzed and xt.Mezzed() or nil
        local isMezzed = mezVal ~= nil and mezVal ~= '' and mezVal ~= 'NULL'
        haters[#haters + 1] = {
            id = xtId,
            name = xt.CleanName() or '',
            hp = hpPct,
            distance = tonumber(xt.Distance()) or 999,
            aggro = aggro,
            targetingMe = totId == myId,
            mezzed = isMezzed,
            targetType = targetType,
        }

        if aggro < 100 then
            aggroDeficitCount = aggroDeficitCount + 1
        end
        ::continue::
    end

    M.xtarget = {
        count = #haters,
        haters = haters,
        aggroDeficitCount = aggroDeficitCount,
    }
end

-- Staleness accessors

--- Get age of light-update data (self, target) in seconds
---@return number Age in seconds since last light update
function M.lightAge()
    return os.clock() - _lastLightUpdate
end

--- Get age of heavy-update data (group, xtarget) in seconds
---@return number Age in seconds since last heavy update
function M.heavyAge()
    return os.clock() - _lastHeavyUpdate
end

--- Check if heavy data is stale (older than threshold)
---@param maxAge number|nil Max age in seconds (default 0.5)
---@return boolean True if data is stale
function M.isHeavyStale(maxAge)
    return M.heavyAge() > (maxAge or 0.5)
end

-- Convenience accessors

--- Check if player is in combat
function M.inCombat()
    return M.me.combat == true or (M.xtarget.count or 0) > 0
end

--- Check if target is named
function M.isTargetNamed()
    return M.target.named == true
end

--- Check if tank aggro lead is low (needs hate gen)
function M.aggroLeadLow()
    return (M.me.pctAggro or 100) < 100 or (M.me.secondaryPctAggro or 0) > 80
end

--- Get count of unmezzed mobs on XTarget
function M.unmezzedHaterCount()
    local count = 0
    for _, h in pairs(M.xtarget.haters or {}) do
        if not h.mezzed then
            count = count + 1
        end
    end
    return count
end

--- Check if Me has enough resources for ability
function M.hasResources(hpMin, manaMin, endurMin)
    hpMin = hpMin or 0
    manaMin = manaMin or 0
    endurMin = endurMin or 0
    return (M.me.hp or 0) >= hpMin
       and (M.me.mana or 0) >= manaMin
       and (M.me.endur or 0) >= endurMin
end

--- Get injured group member count below threshold
function M.injuredGroupCount(threshold)
    threshold = threshold or 80
    local count = 0
    for _, m in pairs(M.group.members or {}) do
        if (m.hp or 100) < threshold then
            count = count + 1
        end
    end
    return count
end

-- CC Integration

--- Check if any XTarget mob is mezzed
-- Uses CC module if available, falls back to TLO check
function M.hasAnyMezzedOnXTarget()
    local ok, CC = pcall(require, 'sidekick-next.automation.cc')
    if ok and CC and CC.hasAnyMezzedOnXTarget then
        return CC.hasAnyMezzedOnXTarget()
    end

    -- Fallback: check TLO directly (less reliable)
    for _, h in pairs(M.xtarget.haters or {}) do
        if h.mezzed then
            return true
        end
    end

    return false
end

--- Check if a specific mob is mezzed
-- @param mobId number Mob spawn ID
-- @return boolean True if mezzed
function M.isMobMezzed(mobId)
    local ok, CC = pcall(require, 'sidekick-next.automation.cc')
    if ok and CC and CC.isMobMezzed then
        return CC.isMobMezzed(mobId)
    end

    -- Fallback: check xtarget cache
    for _, h in pairs(M.xtarget.haters or {}) do
        if h.id == mobId and h.mezzed then
            return true
        end
    end

    return false
end

-- Buff Integration

--- Initialize self in buffState (called on heavy update for self)
local function ensureSelfInBuffState()
    local myId = M.me.id or 0
    if myId > 0 then
        M.buffState[myId] = M.buffState[myId] or {}
    end
end

--- Check buff on a target using Target.FindBuff (requires brief retargeting)
-- This is expensive - use sparingly, called by Buff module
-- @param targetId number Target spawn ID
-- @param spellId number Spell ID to check for
-- @param buffCategory string Category to store result under
-- @return table { present, remaining, spellId, checkedAt }
function M.checkBuff(targetId, spellId, buffCategory)
    if not targetId or targetId == 0 or not spellId then
        return { present = false, remaining = 0, checkedAt = os.clock() }
    end

    -- Save current target
    local oldTargetId = mq.TLO.Target.ID() or 0

    -- Check if already targeting this spawn (skip retarget)
    local needRetarget = (oldTargetId ~= targetId)
    if needRetarget then
        mq.cmdf('/target id %d', targetId)
        mq.delay(50)  -- Brief delay for target to register
    end

    -- Check buff status using Target.FindBuff
    local result = { present = false, remaining = 0, spellId = nil, checkedAt = os.clock() }
    local buff = mq.TLO.Target.FindBuff('id ' .. spellId)
    if buff and buff() then
        result.present = true
        local dur = buff.Duration
        result.remaining = dur and dur.TotalSeconds and (tonumber(dur.TotalSeconds()) or 0) or 0
        result.spellId = spellId
    end

    -- Restore original target
    if needRetarget then
        if oldTargetId > 0 then
            mq.cmdf('/target id %d', oldTargetId)
        else
            mq.cmd('/target clear')
        end
    end

    -- Store in buffState
    M.buffState[targetId] = M.buffState[targetId] or {}
    M.buffState[targetId][buffCategory] = result

    return result
end

--- Check buff on self (no retargeting needed)
-- Uses Me.Buff directly
-- @param spellId number Spell ID to check for
-- @param buffCategory string Category to store result under
-- @return table { present, remaining, spellId, checkedAt }
function M.checkSelfBuff(spellId, buffCategory)
    local myId = M.me.id or 0
    if myId == 0 or not spellId then
        return { present = false, remaining = 0, checkedAt = os.clock() }
    end

    local result = { present = false, remaining = 0, spellId = nil, checkedAt = os.clock() }
    local buff = mq.TLO.Me.Buff('id ' .. spellId)
    if buff and buff() then
        result.present = true
        result.remaining = tonumber(buff.Duration.TotalSeconds()) or 0
        result.spellId = spellId
    end

    -- Store in buffState
    M.buffState[myId] = M.buffState[myId] or {}
    M.buffState[myId][buffCategory] = result

    return result
end

--- Get buff state for a member
-- @param memberId number Member spawn ID
-- @param buffCategory string Buff category
-- @return table|nil { present, remaining, spellId, checkedAt } or nil if never checked
function M.getBuffState(memberId, buffCategory)
    local state = M.buffState[memberId]
    if not state then return nil end
    return state[buffCategory]
end

--- Check if buff state is stale (needs recheck)
-- @param memberId number Member spawn ID
-- @param buffCategory string Buff category
-- @param maxAge number Maximum age in seconds before considered stale (default 5)
-- @return boolean True if stale or never checked
function M.isBuffStateStale(memberId, buffCategory, maxAge)
    maxAge = maxAge or 5
    local state = M.getBuffState(memberId, buffCategory)
    if not state or not state.checkedAt then return true end
    return (os.clock() - state.checkedAt) >= maxAge
end

--- Get members needing buff (convenience for Buff module)
-- @param buffCategory string Buff category to check
-- @param rebuffWindow number Seconds before expiry to consider needing rebuff
-- @return table Array of { member, remaining } sorted by priority (lowest remaining first)
function M.getMembersNeedingBuff(buffCategory, rebuffWindow)
    rebuffWindow = rebuffWindow or 60
    local needing = {}

    -- Check self first
    local myId = M.me.id or 0
    if myId > 0 then
        ensureSelfInBuffState()
        local selfState = M.buffState[myId] and M.buffState[myId][buffCategory]
        if selfState and selfState.pending then
            -- Skip pending buffs (recently cast, awaiting confirmation)
        elseif not selfState or not selfState.present or (selfState.remaining or 0) < rebuffWindow then
            table.insert(needing, {
                member = {
                    id = myId,
                    name = M.me.name or '',
                    class = M.me.class or '',
                    hp = M.me.hp or 100,
                    distance = 0,
                    buffs = M.buffState[myId],
                },
                remaining = selfState and selfState.remaining or 0,
                isSelf = true,
            })
        end
    end

    -- Check group members
    for _, member in pairs(M.group.members or {}) do
        -- Check buffState directly (member.buffs may be stale nil reference)
        local memberId = member.id
        local state = M.buffState[memberId] and M.buffState[memberId][buffCategory]
        if state and state.pending then
            -- Skip pending buffs (recently cast, awaiting confirmation)
        elseif not state or not state.present or (state.remaining or 0) < rebuffWindow then
            table.insert(needing, {
                member = member,
                remaining = state and state.remaining or 0,
                isSelf = false,
            })
        end
    end

    -- Sort by remaining time (lowest first = most urgent)
    table.sort(needing, function(a, b)
        -- Missing buffs (remaining=0) come first
        if a.remaining == 0 and b.remaining > 0 then return true end
        if b.remaining == 0 and a.remaining > 0 then return false end
        return a.remaining < b.remaining
    end)

    return needing
end

--- Get pets needing buff (convenience for Buff module)
-- @param buffCategory string Buff category to check
-- @param rebuffWindow number Seconds before expiry to consider needing rebuff
-- @return table Array of { pet, owner, remaining } sorted by priority (lowest remaining first)
function M.getPetsNeedingBuff(buffCategory, rebuffWindow)
    rebuffWindow = rebuffWindow or 60
    local needing = {}

    -- Check self pet first
    if M.me.pet and M.me.pet.id and M.me.pet.id > 0 then
        local petId = M.me.pet.id
        -- Check buffState directly (pet.buffs may be stale nil reference)
        local petState = M.buffState[petId] and M.buffState[petId][buffCategory]
        if petState and petState.pending then
            -- Skip pending buffs (recently cast, awaiting confirmation)
        elseif not petState or not petState.present or (petState.remaining or 0) < rebuffWindow then
            table.insert(needing, {
                pet = M.me.pet,
                owner = {
                    id = M.me.id,
                    name = M.me.name,
                    class = M.me.class,
                },
                remaining = petState and petState.remaining or 0,
                isSelfPet = true,
            })
        end
    end

    -- Check group member pets
    for _, member in pairs(M.group.members or {}) do
        if member.pet and member.pet.id and member.pet.id > 0 then
            local petId = member.pet.id
            -- Check buffState directly (pet.buffs may be stale nil reference)
            local petState = M.buffState[petId] and M.buffState[petId][buffCategory]
            if petState and petState.pending then
                -- Skip pending buffs (recently cast, awaiting confirmation)
            elseif not petState or not petState.present or (petState.remaining or 0) < rebuffWindow then
                table.insert(needing, {
                    pet = member.pet,
                    owner = member,
                    remaining = petState and petState.remaining or 0,
                    isSelfPet = false,
                })
            end
        end
    end

    -- Sort by remaining time (lowest first = most urgent)
    table.sort(needing, function(a, b)
        -- Missing buffs (remaining=0) come first
        if a.remaining == 0 and b.remaining > 0 then return true end
        if b.remaining == 0 and a.remaining > 0 then return false end
        return a.remaining < b.remaining
    end)

    return needing
end

-- OOG (Out of Group) Buffing Support

--- Get raid members for buffing (excludes self)
-- @return table Array of { id, name, class, distance, buffs }
function M.getRaidMembers()
    local members = {}
    local myId = M.me.id or 0

    local raidCount = tonumber(mq.TLO.Raid.Members()) or 0
    for i = 1, raidCount do
        local member = mq.TLO.Raid.Member(i)
        if member and member() then
            local spawn = member.Spawn
            if spawn and spawn() and spawn.ID and spawn.ID() and spawn.ID() > 0 then
                local memberId = tonumber(spawn.ID()) or 0
                if memberId > 0 and memberId ~= myId then
                    -- Ensure buff state exists
                    M.buffState[memberId] = M.buffState[memberId] or {}

                    table.insert(members, {
                        id = memberId,
                        name = member.Name() or '',
                        class = (member.Class and member.Class.ShortName()) or '',
                        distance = tonumber(spawn.Distance()) or 999,
                        buffs = M.buffState[memberId],
                    })
                end
            end
        end
    end

    return members
end

--- Get fellowship members for buffing (excludes self)
-- @return table Array of { id, name, class, distance, buffs }
function M.getFellowshipMembers()
    local members = {}
    local myId = M.me.id or 0

    local fellowshipCount = tonumber(mq.TLO.Fellowship.Members()) or 0
    for i = 1, fellowshipCount do
        local member = mq.TLO.Fellowship.Member(i)
        if member and member() then
            local spawn = member.Spawn
            if spawn and spawn() and spawn.ID and spawn.ID() and spawn.ID() > 0 then
                local memberId = tonumber(spawn.ID()) or 0
                if memberId > 0 and memberId ~= myId then
                    -- Ensure buff state exists
                    M.buffState[memberId] = M.buffState[memberId] or {}

                    table.insert(members, {
                        id = memberId,
                        name = member.Name() or '',
                        class = (member.Class and member.Class.ShortName()) or '',
                        distance = tonumber(spawn.Distance()) or 999,
                        buffs = M.buffState[memberId],
                    })
                end
            end
        end
    end

    return members
end

--- Get OOG targets needing buff
-- @param source string 'raid' or 'fellowship'
-- @param buffCategory string Buff category to check
-- @param rebuffWindow number Seconds before expiry to consider needing rebuff
-- @return table Array of { member, remaining } sorted by priority
function M.getOOGNeedingBuff(source, buffCategory, rebuffWindow)
    rebuffWindow = rebuffWindow or 60
    local needing = {}

    local members = {}
    if source == 'raid' then
        members = M.getRaidMembers()
    elseif source == 'fellowship' then
        members = M.getFellowshipMembers()
    end

    for _, member in ipairs(members) do
        local state = member.buffs and member.buffs[buffCategory]
        if not state or not state.present or (state.remaining or 0) < rebuffWindow then
            table.insert(needing, {
                member = member,
                remaining = state and state.remaining or 0,
            })
        end
    end

    -- Sort by remaining time (lowest first = most urgent)
    table.sort(needing, function(a, b)
        if a.remaining == 0 and b.remaining > 0 then return true end
        if b.remaining == 0 and a.remaining > 0 then return false end
        return a.remaining < b.remaining
    end)

    return needing
end

--- Clean up stale buff state for members no longer in group
--- Includes current XTarget ids (mobs we might be debuffing) as valid; also
--- TTL-drops any entry whose newest checkedAt is older than BUFFSTATE_TTL.
function M.cleanupBuffState()
    local validIds = {}

    -- Self is always valid
    local myId = M.me.id or 0
    if myId > 0 then validIds[myId] = true end

    -- Self pet is valid
    if M.me.pet and M.me.pet.id and M.me.pet.id > 0 then
        validIds[M.me.pet.id] = true
    end

    -- Group members and their pets are valid
    for _, member in pairs(M.group.members or {}) do
        if member.id and member.id > 0 then
            validIds[member.id] = true
        end
        if member.pet and member.pet.id and member.pet.id > 0 then
            validIds[member.pet.id] = true
        end
    end

    -- Current XTarget haters are valid — they may hold active debuff state.
    if M.xtarget and M.xtarget.haters then
        for _, hater in ipairs(M.xtarget.haters) do
            if hater.id and hater.id > 0 then validIds[hater.id] = true end
        end
    end

    -- TTL: drop buff state entries whose most recent check is older than this.
    local BUFFSTATE_TTL = 60.0  -- seconds
    local now = os.clock()

    -- Remove entries for IDs no longer valid, OR whose latest check is too old
    -- (prevents unbounded growth across mob kills / zone-ins where the valid-id
    -- set would otherwise forget mobs we stopped tracking).
    for memberId, categories in pairs(M.buffState) do
        if not validIds[memberId] then
            M.buffState[memberId] = nil
        elseif type(categories) == 'table' then
            local newestCheck = 0
            for _, entry in pairs(categories) do
                local ts = type(entry) == 'table' and tonumber(entry.checkedAt) or nil
                if ts and ts > newestCheck then newestCheck = ts end
            end
            if newestCheck > 0 and (now - newestCheck) > BUFFSTATE_TTL then
                M.buffState[memberId] = nil
            end
        end
    end
end

return M
