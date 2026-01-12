-- F:\lua\SideKick\automation\buff.lua
-- Buff tracking and coordination
-- Tracks buffs applied by self and peers, coordinates to avoid duplicate casting

local mq = require('mq')

local M = {}

-- Lazy-load dependencies to avoid circular requires
local _Actors = nil
local function getActors()
    if not _Actors then
        local ok, a = pcall(require, 'utils.actors_coordinator')
        if ok then _Actors = a end
    end
    return _Actors
end

local _Cache = nil
local function getCache()
    if not _Cache then
        local ok, c = pcall(require, 'utils.runtime_cache')
        if ok then _Cache = c end
    end
    return _Cache
end

local _Core = nil
local function getCore()
    if not _Core then
        local ok, c = pcall(require, 'utils.core')
        if ok then _Core = c end
    end
    return _Core
end

local _SpellEngine = nil
local function getSpellEngine()
    if not _SpellEngine then
        local ok, se = pcall(require, 'utils.spell_engine')
        if ok then _SpellEngine = se end
    end
    return _SpellEngine
end

-- Local buff tracking (buffs we've applied)
M.localBuffs = {}  -- { [targetId] = { [buffCategory] = { expiresAt, spellId, spellName } } }

-- Remote buff tracking (buffs others have applied)
M.remoteBuffs = {}  -- { [targetId] = { [buffCategory] = { expiresAt, caster } } }

-- Claims (before casting, claim to prevent duplicates)
M.localClaims = {}   -- { [targetId] = { [buffCategory] = { claimedAt } } }
M.remoteClaims = {}  -- { [targetId] = { [buffCategory] = { claimedAt, claimer } } }

-- Buff blocks (what buffs targets don't want)
M.remoteBlocks = {}  -- { [charName] = { [buffCategory] = true } }

-- Buff definitions loaded from spellsets
M.buffDefinitions = {}  -- Loaded from class spellset

-- Full spellset for spell line resolution
local _spellset = nil

-- Timing
local _lastBuffListBroadcast = 0
local _lastBuffTick = 0
local _lastBlocksBroadcast = 0
local _lastCleanup = 0
local _selfName = ''

local BUFF_LIST_BROADCAST_INTERVAL = 2.0   -- Broadcast buff list every 2 seconds
local BLOCKS_BROADCAST_INTERVAL = 5.0      -- Broadcast blocks every 5 seconds
local CLEANUP_INTERVAL = 1.0               -- Clean expired every 1 second
local CLAIM_TIMEOUT = 8.0                  -- Claims expire after 8 seconds
local BUFF_CHECK_INTERVAL = 3.0            -- How often to recheck buff status on targets
local BUFF_TICK_INTERVAL = 0.5             -- Casting tick interval (500ms)
local DEFAULT_REBUFF_WINDOW = 60           -- Default seconds before expiry to rebuff
local GROUP_BUFF_THRESHOLD = 2             -- Min members needing buff to use group version

-- Initialization
function M.init()
    M.localBuffs = {}
    M.remoteBuffs = {}
    M.localClaims = {}
    M.remoteClaims = {}
    M.remoteBlocks = {}
    M.buffDefinitions = {}

    _selfName = (mq.TLO.Me and mq.TLO.Me.CleanName and mq.TLO.Me.CleanName()) or ''

    -- Load buff definitions from class spellset
    M.loadBuffDefinitions()
end

-- Load buff definitions from class spellset
function M.loadBuffDefinitions()
    local me = mq.TLO.Me
    if not me or not me.Class or not me.Class.ShortName then return end

    local className = tostring(me.Class.ShortName()):upper()
    local ok, spellset = pcall(require, 'data.spellsets.' .. className)
    if not ok or not spellset then return end

    -- Store full spellset for spell line resolution
    _spellset = spellset

    -- Look for buffLines in the spellset
    if spellset.buffLines then
        for category, def in pairs(spellset.buffLines) do
            M.buffDefinitions[category] = def
        end
    end
end

-- Check if a spell is memorized in any gem slot
-- @param spellName string Spell name
-- @return number|nil Gem slot number if memorized, nil otherwise
local function isSpellMemorized(spellName)
    if not spellName or spellName == '' then return nil end
    local me = mq.TLO.Me
    if not (me and me()) then return nil end
    local gem = me.Gem(spellName)
    if gem and gem() and gem() > 0 then
        return gem()
    end
    return nil
end

-- Resolve a spell line to the highest rank memorized spell
-- @param lineName string Spell line name (e.g., "Symbol")
-- @return string|nil Best memorized spell name, nil if none found
function M.resolveSpellFromLine(lineName)
    if not _spellset or not _spellset.spellLines or not lineName then return nil end

    local line = _spellset.spellLines[lineName]
    if type(line) ~= 'table' then return nil end

    -- Iterate through spells in order (highest rank first)
    for _, spellName in ipairs(line) do
        if isSpellMemorized(spellName) then
            return spellName
        end
    end

    return nil
end

-- Find any memorized spell from a buff definition
-- Checks spellLine first, then groupSpellLine if provided
-- @param buffDef table Buff definition from buffLines
-- @param preferGroup boolean If true, prefer group spell when available
-- @return string|nil Spell name, nil if none memorized
-- @return boolean True if this is a group spell
function M.findMemorizedBuffSpell(buffDef, preferGroup)
    if not buffDef then return nil, false end

    -- If preferring group and groupSpellLine is defined, try that first
    if preferGroup and buffDef.groupSpellLine then
        local groupSpell = M.resolveSpellFromLine(buffDef.groupSpellLine)
        if groupSpell then
            return groupSpell, true
        end
    end

    -- Try single target spell line
    if buffDef.spellLine then
        local singleSpell = M.resolveSpellFromLine(buffDef.spellLine)
        if singleSpell then
            return singleSpell, false
        end
    end

    -- Fallback: try group spell if not preferring single
    if not preferGroup and buffDef.groupSpellLine then
        local groupSpell = M.resolveSpellFromLine(buffDef.groupSpellLine)
        if groupSpell then
            return groupSpell, true
        end
    end

    return nil, false
end

-- Main tick function
function M.tick()
    local now = os.clock()

    -- Cleanup expired entries
    if (now - _lastCleanup) >= CLEANUP_INTERVAL then
        _lastCleanup = now
        M.cleanupExpired()
    end

    -- Broadcast our buff list
    if (now - _lastBuffListBroadcast) >= BUFF_LIST_BROADCAST_INTERVAL then
        _lastBuffListBroadcast = now
        M.broadcastBuffList()
    end

    -- Broadcast our blocked buffs
    if (now - _lastBlocksBroadcast) >= BLOCKS_BROADCAST_INTERVAL then
        _lastBlocksBroadcast = now
        M.broadcastBlocks()
    end
end

-- Cleanup expired buffs and claims
function M.cleanupExpired()
    local now = os.clock()

    -- Cleanup local buffs
    for targetId, categories in pairs(M.localBuffs) do
        for category, data in pairs(categories) do
            if now >= (data.expiresAt or 0) then
                categories[category] = nil
            end
        end
        if not next(categories) then
            M.localBuffs[targetId] = nil
        end
    end

    -- Cleanup remote buffs
    for targetId, categories in pairs(M.remoteBuffs) do
        for category, data in pairs(categories) do
            if now >= (data.expiresAt or 0) then
                categories[category] = nil
            end
        end
        if not next(categories) then
            M.remoteBuffs[targetId] = nil
        end
    end

    -- Cleanup local claims
    for targetId, categories in pairs(M.localClaims) do
        for category, data in pairs(categories) do
            if (now - (data.claimedAt or 0)) >= CLAIM_TIMEOUT then
                categories[category] = nil
            end
        end
        if not next(categories) then
            M.localClaims[targetId] = nil
        end
    end

    -- Cleanup remote claims
    for targetId, categories in pairs(M.remoteClaims) do
        for category, data in pairs(categories) do
            if (now - (data.claimedAt or 0)) >= CLAIM_TIMEOUT then
                categories[category] = nil
            end
        end
        if not next(categories) then
            M.remoteClaims[targetId] = nil
        end
    end
end

--- Broadcast our buff list to peers
function M.broadcastBuffList()
    if not next(M.localBuffs) then return end

    local Actors = getActors()
    if not Actors or not Actors.broadcast then return end

    local now = os.clock()
    local buffs = {}

    for targetId, categories in pairs(M.localBuffs) do
        buffs[targetId] = {}
        for category, data in pairs(categories) do
            local ttl = (data.expiresAt or 0) - now
            if ttl > 0 then
                buffs[targetId][category] = {
                    ttl = ttl,
                    spellId = data.spellId,
                    caster = _selfName,
                }
            end
        end
        if not next(buffs[targetId]) then
            buffs[targetId] = nil
        end
    end

    if not next(buffs) then return end

    Actors.broadcast('buff:list', {
        buffs = buffs,
        sender = _selfName,
        timestamp = now,
    })
end

--- Receive buff list from peer
function M.receiveBuffList(payload)
    local mobs = payload.buffs or {}
    local sender = payload.sender or payload.from or 'unknown'
    local recvNow = os.clock()

    for targetId, categories in pairs(mobs) do
        local id = tonumber(targetId)
        if id and id > 0 then
            M.remoteBuffs[id] = M.remoteBuffs[id] or {}
            for category, data in pairs(categories) do
                local ttl = tonumber(data.ttl) or 0
                if ttl > 0 then
                    M.remoteBuffs[id][category] = {
                        expiresAt = recvNow + ttl,
                        caster = data.caster or sender,
                        spellId = data.spellId,
                    }
                end
            end
        end
    end
end

--- Broadcast our blocked buffs
function M.broadcastBlocks()
    local Actors = getActors()
    if not Actors or not Actors.broadcast then return end

    local Core = getCore()
    if not Core or not Core.Settings then return end

    local blocked = {}
    for key, value in pairs(Core.Settings) do
        if key:match('^BuffBlock_') and value == true then
            local buffType = key:gsub('^BuffBlock_', '')
            table.insert(blocked, buffType)
        end
    end

    Actors.broadcast('buff:blocks', {
        charName = _selfName,
        blockedTypes = blocked,
    })
end

--- Receive blocked buffs from peer
function M.receiveBlocks(payload)
    local charName = payload.charName
    if not charName or charName == '' then return end

    M.remoteBlocks[charName] = {}
    for _, buffType in ipairs(payload.blockedTypes or {}) do
        M.remoteBlocks[charName][buffType] = true
    end
end

--- Claim a buff target before casting
-- @param targetId number Target spawn ID
-- @param buffCategory string Buff category
-- @return boolean True if claim successful
function M.claimBuff(targetId, buffCategory)
    if M.isBuffClaimed(targetId, buffCategory) then
        return false
    end

    local id = tonumber(targetId)
    if not id or id == 0 then return false end

    M.localClaims[id] = M.localClaims[id] or {}
    M.localClaims[id][buffCategory] = {
        claimedAt = os.clock(),
    }

    local Actors = getActors()
    if Actors and Actors.broadcast then
        Actors.broadcast('buff:claim', {
            targetId = id,
            buffType = buffCategory,
            claimer = _selfName,
        })
    end

    return true
end

--- Receive claim from peer
function M.receiveClaim(payload)
    local targetId = tonumber(payload.targetId)
    if not targetId or targetId == 0 then return end

    local buffType = payload.buffType
    if not buffType or buffType == '' then return end

    M.remoteClaims[targetId] = M.remoteClaims[targetId] or {}
    M.remoteClaims[targetId][buffType] = {
        claimedAt = os.clock(),
        claimer = payload.claimer or 'unknown',
    }
end

--- Release a claim (after buff lands or fails)
function M.releaseClaim(targetId, buffCategory)
    local id = tonumber(targetId)
    if not id then return end

    if M.localClaims[id] then
        M.localClaims[id][buffCategory] = nil
        if not next(M.localClaims[id]) then
            M.localClaims[id] = nil
        end
    end
end

--- Check if a buff is claimed by someone else
function M.isBuffClaimed(targetId, buffCategory)
    local id = tonumber(targetId)
    if not id then return false end

    local claim = M.remoteClaims[id] and M.remoteClaims[id][buffCategory]
    if claim and (os.clock() - (claim.claimedAt or 0)) < CLAIM_TIMEOUT then
        return true, claim.claimer
    end

    return false
end

--- Check if a target has blocked a buff type
function M.isBuffBlocked(targetName, buffCategory)
    if not targetName or not buffCategory then return false end

    -- Check self blocks
    if targetName == _selfName then
        local Core = getCore()
        if Core and Core.Settings then
            return Core.Settings['BuffBlock_' .. buffCategory] == true
        end
    end

    -- Check remote blocks
    local blocks = M.remoteBlocks[targetName]
    return blocks and blocks[buffCategory] == true
end

--- Track a buff we just applied
function M.trackLocalBuff(targetId, buffCategory, spellId, spellName, duration)
    local id = tonumber(targetId)
    if not id or id == 0 then return end

    duration = duration or 1200  -- Default 20 minutes if unknown

    M.localBuffs[id] = M.localBuffs[id] or {}
    M.localBuffs[id][buffCategory] = {
        expiresAt = os.clock() + duration,
        spellId = spellId,
        spellName = spellName,
    }

    -- Release claim now that buff landed
    M.releaseClaim(id, buffCategory)

    -- Broadcast immediately
    local Actors = getActors()
    if Actors and Actors.broadcast then
        Actors.broadcast('buff:landed', {
            targetId = id,
            buffType = buffCategory,
            caster = _selfName,
            duration = duration,
            spellId = spellId,
        })
    end
end

--- Receive buff landed notification from peer
function M.receiveBuffLanded(payload)
    local targetId = tonumber(payload.targetId)
    if not targetId or targetId == 0 then return end

    local buffType = payload.buffType
    if not buffType or buffType == '' then return end

    local duration = tonumber(payload.duration) or 1200

    M.remoteBuffs[targetId] = M.remoteBuffs[targetId] or {}
    M.remoteBuffs[targetId][buffType] = {
        expiresAt = os.clock() + duration,
        caster = payload.caster or 'unknown',
        spellId = payload.spellId,
    }

    -- Clear any claims for this target/buff
    if M.remoteClaims[targetId] then
        M.remoteClaims[targetId][buffType] = nil
    end
end

--- Check if target has a buff (from any source)
function M.hasBuffFromAnySource(targetId, buffCategory)
    local id = tonumber(targetId)
    if not id then return false, 0 end

    local now = os.clock()

    -- Check local buffs
    local localBuff = M.localBuffs[id] and M.localBuffs[id][buffCategory]
    if localBuff and now < (localBuff.expiresAt or 0) then
        return true, localBuff.expiresAt - now
    end

    -- Check remote buffs
    local remoteBuff = M.remoteBuffs[id] and M.remoteBuffs[id][buffCategory]
    if remoteBuff and now < (remoteBuff.expiresAt or 0) then
        return true, remoteBuff.expiresAt - now
    end

    return false, 0
end

--- Check buff status on a target using Target.FindBuff
-- This requires briefly targeting the member
-- @param memberId number Target spawn ID
-- @param spellId number Spell ID to check for
-- @return table { present, remaining }
function M.checkBuffOnTarget(memberId, spellId)
    if not memberId or not spellId then
        return { present = false, remaining = 0 }
    end

    -- Save current target
    local oldTargetId = mq.TLO.Target.ID()

    -- Target the member briefly
    mq.cmdf('/target id %d', memberId)
    mq.delay(50)  -- Brief delay for target to register

    -- Check buff status
    local result = { present = false, remaining = 0 }
    local buff = mq.TLO.Target.FindBuff('id ' .. spellId)
    if buff() then
        result.present = true
        result.remaining = buff.Duration.TotalSeconds() or 0
    end

    -- Restore original target
    if oldTargetId and oldTargetId > 0 then
        mq.cmdf('/target id %d', oldTargetId)
    else
        mq.cmd('/target clear')
    end

    return result
end

--- Should we buff now based on combat state?
function M.shouldBuffNow(buffDef)
    local Cache = getCache()
    if not Cache then return true end

    local inCombat = Cache.me and Cache.me.combat

    -- Combat-only buffs
    if buffDef.combatOnly and not inCombat then
        return false
    end

    -- Out-of-combat buffs
    if buffDef.outOfCombatOnly and inCombat then
        return false
    end

    return true
end

--- Get all buff definitions for current class
function M.getBuffDefinitions()
    return M.buffDefinitions
end

-- ============================================================================
-- BUFF CASTING EXECUTION
-- ============================================================================

--- Check if we can cast buffs now
-- @return boolean True if we can cast
-- @return string|nil Reason if we cannot
local function canBuffNow()
    local me = mq.TLO.Me
    if not (me and me()) then return false, 'no_character' end

    -- Check if moving
    if me.Moving() then return false, 'moving' end

    -- Check if already casting
    if me.Casting() then return false, 'casting' end

    -- Check if hovering (dead)
    if me.Hovering and me.Hovering() then return false, 'dead' end

    -- Check if stunned/mezzed
    if me.Stunned and me.Stunned() then return false, 'stunned' end
    if me.Mezzed and me.Mezzed() then return false, 'mezzed' end

    -- Check SpellEngine availability
    local SpellEngine = getSpellEngine()
    if SpellEngine and SpellEngine.isBusy and SpellEngine.isBusy() then
        return false, 'spell_engine_busy'
    end

    return true, nil
end

--- Get spell duration from spell data
-- @param spellName string Spell name
-- @return number Duration in seconds (default 1200 = 20 min)
local function getSpellDuration(spellName)
    if not spellName then return 1200 end
    local spell = mq.TLO.Spell(spellName)
    if spell and spell() and spell.Duration then
        local dur = spell.Duration.TotalSeconds
        if dur and dur() then
            return tonumber(dur()) or 1200
        end
    end
    return 1200
end

--- Get spell ID from spell name
-- @param spellName string Spell name
-- @return number|nil Spell ID
local function getSpellId(spellName)
    if not spellName then return nil end
    local spell = mq.TLO.Spell(spellName)
    if spell and spell() and spell.ID then
        return tonumber(spell.ID()) or nil
    end
    return nil
end

--- Cast a buff spell on a target
-- @param targetId number Target spawn ID
-- @param buffCategory string Buff category (e.g., "symbol")
-- @param spellName string Spell name to cast
-- @param buffDef table Buff definition
-- @return boolean True if cast was initiated
-- @return string|nil Failure reason if false
function M.castBuff(targetId, buffCategory, spellName, buffDef)
    if not targetId or not buffCategory or not spellName then
        return false, 'missing_params'
    end

    local SpellEngine = getSpellEngine()
    if not SpellEngine or not SpellEngine.cast then
        return false, 'no_spell_engine'
    end

    -- Get spell ID for tracking
    local spellId = getSpellId(spellName)
    local duration = (buffDef and buffDef.duration) or getSpellDuration(spellName)

    -- Cast the spell
    local success, reason = SpellEngine.cast(spellName, targetId, {
        spellCategory = 'buff',
        maxRetries = 2,
    })

    if success then
        -- Track the buff immediately (SpellEngine will handle cast completion)
        -- We track optimistically; if cast fails, cleanup will expire it
        M.trackLocalBuff(targetId, buffCategory, spellId, spellName, duration)
    end

    return success, reason
end

--- Count how many group members need a specific buff
-- @param buffCategory string Buff category
-- @param rebuffWindow number Seconds before expiry to consider needing rebuff
-- @return number Count of members needing the buff
function M.countMembersNeedingBuff(buffCategory, rebuffWindow)
    local Cache = getCache()
    if not Cache or not Cache.getMembersNeedingBuff then return 0 end

    local needing = Cache.getMembersNeedingBuff(buffCategory, rebuffWindow)
    return #needing
end

--- Main buff tick - check and cast buffs on targets
-- Called from main loop when buffing is enabled
function M.buffTick()
    local now = os.clock()

    -- Rate limit
    if (now - _lastBuffTick) < BUFF_TICK_INTERVAL then
        return
    end
    _lastBuffTick = now

    -- Check if buffing is enabled
    local Core = getCore()
    if not Core or not Core.Settings then return end
    if Core.Settings.BuffingEnabled == false then return end

    -- Check if we can cast
    local canCast, reason = canBuffNow()
    if not canCast then return end

    -- Get cache for target info
    local Cache = getCache()
    if not Cache then return end

    -- No buff definitions = nothing to do
    if not next(M.buffDefinitions) then return end

    -- Iterate through each buff definition
    for category, buffDef in pairs(M.buffDefinitions) do
        -- Check combat state for this buff
        if not M.shouldBuffNow(buffDef) then
            goto continue_buff
        end

        -- Get rebuff window from definition or use default
        local rebuffWindow = buffDef.rebuffWindow or DEFAULT_REBUFF_WINDOW

        -- Check what targets need this buff
        local targets = buffDef.targets or 'group'

        if targets == 'self' then
            -- Self-only buff
            local myId = Cache.me and Cache.me.id or 0
            if myId > 0 then
                local hasBuff, remaining = M.hasBuffFromAnySource(myId, category)
                if not hasBuff or remaining < rebuffWindow then
                    -- Check not claimed by someone else
                    if not M.isBuffClaimed(myId, category) then
                        -- Claim and cast
                        if M.claimBuff(myId, category) then
                            local spellName = M.resolveSpellFromLine(buffDef.spellLine)
                            if spellName then
                                local success, castReason = M.castBuff(myId, category, spellName, buffDef)
                                if success then
                                    return -- One cast per tick
                                else
                                    M.releaseClaim(myId, category)
                                end
                            else
                                M.releaseClaim(myId, category)
                            end
                        end
                    end
                end
            end
        else
            -- Group/other targets
            local needing = Cache.getMembersNeedingBuff(category, rebuffWindow)
            if #needing == 0 then
                goto continue_buff
            end

            -- Filter out blocked targets
            local validTargets = {}
            for _, entry in ipairs(needing) do
                local member = entry.member
                if member and member.id and member.id > 0 then
                    local targetName = member.name or ''
                    if not M.isBuffBlocked(targetName, category) then
                        -- Check not already claimed
                        if not M.isBuffClaimed(member.id, category) then
                            table.insert(validTargets, entry)
                        end
                    end
                end
            end

            if #validTargets == 0 then
                goto continue_buff
            end

            -- Decide: group spell or single target?
            local useGroup = #validTargets >= GROUP_BUFF_THRESHOLD and buffDef.groupSpellLine ~= nil
            local spellName, isGroup = M.findMemorizedBuffSpell(buffDef, useGroup)

            if not spellName then
                goto continue_buff
            end

            if isGroup then
                -- Group buff: target self (PB AE or group-targeted)
                local myId = Cache.me and Cache.me.id or 0
                if myId > 0 then
                    -- Claim all targets that will receive group buff
                    local claimedIds = {}
                    for _, entry in ipairs(validTargets) do
                        local memberId = entry.member.id
                        if M.claimBuff(memberId, category) then
                            table.insert(claimedIds, memberId)
                        end
                    end

                    if #claimedIds > 0 then
                        -- Cast group buff (target self for PB/group spells)
                        local success, castReason = M.castBuff(myId, category, spellName, buffDef)
                        if success then
                            -- Track for all group members
                            local duration = buffDef.duration or getSpellDuration(spellName)
                            local spellId = getSpellId(spellName)
                            for _, memberId in ipairs(claimedIds) do
                                M.trackLocalBuff(memberId, category, spellId, spellName, duration)
                            end
                            return -- One cast per tick
                        else
                            -- Release claims on failure
                            for _, memberId in ipairs(claimedIds) do
                                M.releaseClaim(memberId, category)
                            end
                        end
                    end
                end
            else
                -- Single target buff: pick highest priority target
                local target = validTargets[1]
                if target and target.member then
                    local memberId = target.member.id
                    if M.claimBuff(memberId, category) then
                        local success, castReason = M.castBuff(memberId, category, spellName, buffDef)
                        if success then
                            return -- One cast per tick
                        else
                            M.releaseClaim(memberId, category)
                        end
                    end
                end
            end
        end

        ::continue_buff::
    end

    -- Pet buffing (separate pass)
    M.buffPetsTick()
end

--- Tick for pet buffing
function M.buffPetsTick()
    local Core = getCore()
    if not Core or not Core.Settings then return end

    -- Check if pet buffing is enabled
    if Core.Settings.BuffPetsEnabled == false then return end

    local Cache = getCache()
    if not Cache or not Cache.getPetsNeedingBuff then return end

    -- Look for pet-specific buffs
    for category, buffDef in pairs(M.buffDefinitions) do
        -- Check if this buff targets pets
        local targets = buffDef.targets or 'group'
        if targets ~= 'pets' and not buffDef.includePets then
            goto continue_pet_buff
        end

        -- Check combat state
        if not M.shouldBuffNow(buffDef) then
            goto continue_pet_buff
        end

        local rebuffWindow = buffDef.rebuffWindow or DEFAULT_REBUFF_WINDOW
        local needing = Cache.getPetsNeedingBuff(category, rebuffWindow)

        for _, entry in ipairs(needing) do
            local pet = entry.pet
            if pet and pet.id and pet.id > 0 then
                -- Check not blocked (use owner name)
                local ownerName = entry.owner and entry.owner.name or ''
                if not M.isBuffBlocked(ownerName, category .. '_pet') then
                    -- Check not claimed
                    if not M.isBuffClaimed(pet.id, category) then
                        -- Get spell
                        local spellName = M.resolveSpellFromLine(buffDef.petSpellLine or buffDef.spellLine)
                        if spellName then
                            if M.claimBuff(pet.id, category) then
                                local success, reason = M.castBuff(pet.id, category, spellName, buffDef)
                                if success then
                                    return -- One cast per tick
                                else
                                    M.releaseClaim(pet.id, category)
                                end
                            end
                        end
                    end
                end
            end
        end

        ::continue_pet_buff::
    end
end

return M
