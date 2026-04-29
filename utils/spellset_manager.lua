-- F:/lua/sidekick/utils/spellset_manager.lua
-- Spell Set Manager - spell set storage, resolution, and OOC memorization
-- Note: Buff casting is handled by automation/buff.lua which uses getBuffSwapLines()

local mq = require('mq')
local lazy = require('sidekick-next.utils.lazy_require')

local M = {}

-- Spell set state
M.initialized = false
M.spellSets = {}           -- {[name] = SpellSet}
M.activeSetName = nil      -- Current active set name
M.pendingApply = nil       -- Queued set to apply when OOC
M.applying = false         -- True while apply is running
M.lastCapacityCheck = 0
M.rotationCapacity = 12    -- NumGems - 1 (updated periodically)
M.debugMem = false         -- Enable detailed memorization logging

local _lastMemLog = {}
local function logMem(key, intervalSec, fmt, ...)
    if not M.debugMem then return end
    local now = os.clock()
    local last = _lastMemLog[key] or 0
    if (now - last) < (intervalSec or 0) then return end
    _lastMemLog[key] = now
    -- In-game echo disabled
end

-- Lazy-load dependencies
local getCore = lazy('sidekick-next.utils.core')
local getSpellsClr = lazy('sidekick-next.sk_spells_clr')
local getConditionBuilder = lazy('sidekick-next.ui.condition_builder')
local getRuntimeCache = lazy('sidekick-next.utils.runtime_cache')
local getBuffLogger = lazy('sidekick-next.automation.buff_logger')

-- INI section for spell sets
local SPELLSET_SECTION = 'SideKick-SpellSets'

local function encodeKey(value)
    value = tostring(value or '')
    return (value:gsub('[^%w%-%._~]', function(c)
        return string.format('%%%02X', string.byte(c))
    end))
end

local function decodeKey(value)
    value = tostring(value or '')
    return (value:gsub('%%(%x%x)', function(h)
        return string.char(tonumber(h, 16))
    end))
end

local function getNumGems()
    local me = mq.TLO.Me
    if not me or not me() then return 0 end
    return tonumber(me.NumGems()) or 0
end

local function getRotationGems()
    local numGems = getNumGems()
    if numGems <= 1 then return 0 end
    return numGems - 1
end

--- Update rotation capacity from NumGems (call periodically)
function M.updateCapacity()
    local now = os.clock()
    if (now - M.lastCapacityCheck) < 30 then return end
    M.lastCapacityCheck = now

    local numGems = getNumGems()
    if numGems <= 0 then return end
    M.rotationCapacity = numGems - 1
end

--- Get current rotation capacity
function M.getRotationCapacity()
    M.updateCapacity()
    return M.rotationCapacity
end

--- Resolve the best spell from a line (highest level in spellbook)
-- @param lineName string The spell line name
-- @return string|nil The resolved spell name or nil
function M.resolveSpellFromLine(lineName)
    local SpellsClr = getSpellsClr()
    if not SpellsClr then return nil end

    local lineData = SpellsClr.getLine(lineName)
    if not lineData or not lineData.spells then return nil end

    local me = mq.TLO.Me
    if not me or not me() then return nil end

    for _, spellName in ipairs(lineData.spells) do
        local inBook = me.Book(spellName)
        if inBook and inBook() then
            return spellName
        end
    end

    return nil
end

local function isSafeToMem()
    local me = mq.TLO.Me
    if not me or not me() then return false end
    local inCombat = me.Combat()
    -- me.Casting() returns the spell name when casting OR the literal string
    -- "NULL" when idle. The previous `not casting` test treated "NULL" as
    -- truthy and silently disabled the entire manager memorize path —
    -- isSafeToMem returned false whenever the player wasn't in combat AND
    -- not actively casting, which is most of the time.
    local castingRaw = me.Casting and me.Casting() or ''
    local actuallyCasting = castingRaw ~= '' and castingRaw ~= 'NULL'
    local castingWindow = mq.TLO.Window("CastingWindow").Open()
    return (not inCombat) and (not actuallyCasting) and (not castingWindow)
end

--------------------------------------------------------------------------------
-- Spell Set CRUD Operations
--------------------------------------------------------------------------------

--- Create a new spell set
-- @param name string The spell set name
-- @return table|nil The new spell set or nil if invalid
function M.createSet(name)
    if not name or name == '' then return nil end
    if M.spellSets[name] then return M.spellSets[name] end

    local set = {
        name = name,
        lines = {},  -- {[lineName] = {enabled, slotType, condition, priority}}
    }

    M.spellSets[name] = set
    M.saveSpellSets()
    return set
end

--- Delete a spell set
-- @param name string The spell set name
-- @return boolean True if deleted
function M.deleteSet(name)
    if not name or not M.spellSets[name] then return false end

    M.spellSets[name] = nil

    if M.activeSetName == name then
        M.activeSetName = nil
    end

    M.saveSpellSets()
    return true
end

--- Get a spell set by name
function M.getSet(name)
    return M.spellSets[name]
end

--- Get the active spell set
function M.getActiveSet()
    if not M.activeSetName then return nil end
    return M.spellSets[M.activeSetName]
end

--- Check if a line is enabled in the active set
-- @param lineName string
-- @return boolean True if enabled (or no active set), false otherwise
function M.isLineEnabled(lineName)
    if not lineName or lineName == '' then return false end
    local set = M.getActiveSet()
    if not set then return true end
    local line = set.lines and set.lines[lineName]
    return line and line.enabled == true
end

--- Get list of all spell set names
function M.getSetNames()
    local names = {}
    for name, _ in pairs(M.spellSets) do
        table.insert(names, name)
    end
    table.sort(names)
    return names
end

--------------------------------------------------------------------------------
-- Spell Line Enable/Disable Operations
--------------------------------------------------------------------------------

--- Count enabled rotation lines in a set
function M.countEnabledRotation(setName)
    local set = M.getSet(setName)
    if not set then return 0 end

    local count = 0
    for _, lineData in pairs(set.lines) do
        if lineData.enabled and lineData.slotType == 'rotation' then
            count = count + 1
        end
    end
    return count
end

--- Enable a spell line in a set
function M.enableLine(setName, lineName, slotType)
    local set = M.getSet(setName)
    if not set then return false end

    local SpellsClr = getSpellsClr()
    local lineInfo = SpellsClr and SpellsClr.getLine(lineName) or nil
    local defaultSlotType = (lineInfo and lineInfo.defaultSlotType) or 'rotation'

    if not slotType then
        slotType = defaultSlotType
    end

    if slotType == 'rotation' then
        local count = M.countEnabledRotation(setName)
        if count >= M.getRotationCapacity() then
            return false
        end
    end

    set.lines[lineName] = set.lines[lineName] or {}
    local lineData = set.lines[lineName]
    lineData.enabled = true
    lineData.slotType = slotType
    lineData.priority = lineData.priority or 999
    lineData.resolved = M.resolveSpellFromLine(lineName)

    M.saveSpellSets()
    if setName == M.activeSetName then
        M.applySet(setName)
    end
    return true
end

--- Disable a spell line in a set
function M.disableLine(setName, lineName)
    local set = M.getSet(setName)
    if not set or not set.lines[lineName] then return end

    set.lines[lineName].enabled = false
    M.saveSpellSets()
    if setName == M.activeSetName then
        M.applySet(setName)
    end
end

--- Set slot type for a line
function M.setLineSlotType(setName, lineName, slotType)
    local set = M.getSet(setName)
    if not set then return false end

    set.lines[lineName] = set.lines[lineName] or {}
    local lineData = set.lines[lineName]

    if slotType == 'rotation' and lineData.enabled then
        local count = M.countEnabledRotation(setName)
        if lineData.slotType ~= 'rotation' and count >= M.getRotationCapacity() then
            return false
        end
    end

    lineData.slotType = slotType
    M.saveSpellSets()
    if setName == M.activeSetName then
        M.applySet(setName)
    end
    return true
end

--- Set condition for a line
function M.setLineCondition(setName, lineName, conditionData)
    local set = M.getSet(setName)
    if not set then return end

    set.lines[lineName] = set.lines[lineName] or {}
    set.lines[lineName].condition = conditionData
    M.saveSpellSets()
end

--- Set priority for a line
function M.setLinePriority(setName, lineName, priority)
    local set = M.getSet(setName)
    if not set then return end

    set.lines[lineName] = set.lines[lineName] or {}
    set.lines[lineName].priority = priority
    M.saveSpellSets()
end

--------------------------------------------------------------------------------
-- Spell Set Activation and Memorization
--------------------------------------------------------------------------------

--- Activate a spell set (does not memorize yet)
function M.activateSet(setName)
    if not M.spellSets[setName] then return false end

    M.activeSetName = setName
    M.saveSpellSets()
    return true
end

--- Queue spell set application (memorization)
-- Always queues and runs from the main loop when OOC.
-- @param setName string|nil The spell set name (nil = active set)
-- @return string 'queued' or 'error'
function M.applySet(setName)
    setName = setName or M.activeSetName
    if not setName or not M.spellSets[setName] then
        logMem('apply_error', 0.5, 'Apply failed (invalid set: %s)', tostring(setName))
        return 'error'
    end

    M.pendingApply = setName
    logMem('apply_queued', 0.5, 'Apply queued for set "%s"', tostring(setName))
    return 'queued'
end

-- State-machine-driven apply. Replaces the previous synchronous loop that
-- ran `mq.delay(12000, predicate)` per gem (~144s freeze worst-case across
-- a full swap). Setup happens immediately; advancement happens one step
-- per M.tick() call via _stepApplyJob().
local APPLY_MEM_TIMEOUT_MS = 12000

M._applyJob = nil  -- nil when idle; populated table when in progress

local function _applyNowMs()
    return (mq.gettime and mq.gettime()) or (os.clock() * 1000)
end

-- Build the rotation/buff-swap list and seed _applyJob. Returns false on
-- validation failure (caller resets M.applying).
local function _setupApplyJob(setName, set)
    local me = mq.TLO.Me
    if not me or not me() then return false end

    local rotationSpells = {}
    local buffSwapSpells = {}
    for lineName, lineData in pairs(set.lines) do
        if lineData.enabled and lineData.slotType == 'rotation' then
            lineData.resolved = lineData.resolved or M.resolveSpellFromLine(lineName)
            if lineData.resolved then
                table.insert(rotationSpells, {
                    lineName = lineName,
                    spellName = lineData.resolved,
                    priority = lineData.priority or 999,
                })
            end
        elseif lineData.enabled and lineData.slotType == 'buff_swap' then
            lineData.resolved = lineData.resolved or M.resolveSpellFromLine(lineName)
            if lineData.resolved then
                table.insert(buffSwapSpells, {
                    lineName = lineName,
                    spellName = lineData.resolved,
                    priority = lineData.priority or 999,
                })
            end
        end
    end

    table.sort(rotationSpells, function(a, b) return a.priority < b.priority end)
    table.sort(buffSwapSpells, function(a, b) return a.priority < b.priority end)

    local enabledLines = {}
    for lineName, lineData in pairs(set.lines) do
        if lineData.enabled then
            table.insert(enabledLines, string.format('%s[slot=%s prio=%s resolved=%s]',
                tostring(lineName),
                tostring(lineData.slotType),
                tostring(lineData.priority or 999),
                tostring(lineData.resolved or 'nil')))
        end
    end
    table.sort(enabledLines)

    logMem('apply_start', 0.5, 'Applying set "%s": %d rotation lines, %d buff-swap lines',
        tostring(setName), #rotationSpells, #buffSwapSpells)
    logMem('apply_enabled', 0, 'Apply enabled lines: %s',
        (#enabledLines > 0) and table.concat(enabledLines, ', ') or '<none>')

    M._applyJob = {
        setName = setName,
        rotationSpells = rotationSpells,
        buffSwapSpells = buffSwapSpells,
        numGems = M.getRotationCapacity(),
        index = 0,
        phase = 'next_slot',
        targetName = nil,
        deadlineMs = 0,
    }
    return true
end

local function _stepApplyJob()
    local job = M._applyJob
    if not job then return end

    local me = mq.TLO.Me
    if not me or not me() then
        logMem('apply_no_me', 1, 'Apply aborted (no character)')
        M._applyJob = nil
        M.pendingApply = nil
        M.applying = false
        return
    end

    local now = _applyNowMs()

    if job.phase == 'next_slot' then
        job.index = job.index + 1
        if job.index > #job.rotationSpells or job.index > (job.numGems or 0) then
            -- Buff-swap is currently a no-op stub (delegated to sk_buffs).
            if #job.buffSwapSpells > 0 then
                M.runBuffSwap(job.buffSwapSpells, job.rotationSpells, nil)
            end
            job.phase = 'done'
            return
        end

        local spell = job.rotationSpells[job.index]
        local currentGem = me.Gem(job.index)
        local currentName = currentGem and currentGem() and currentGem.Name() or ''

        if currentName == spell.spellName then
            logMem('mem_skip_' .. tostring(job.index), 0, 'Gem %d already "%s"', job.index, tostring(currentName))
            return  -- stay in next_slot; index advances next call
        end

        logMem('mem_start_' .. tostring(job.index), 0, 'Memorizing gem %d: "%s" (was "%s")',
            job.index, tostring(spell.spellName), tostring(currentName))
        mq.cmdf('/memspell %d "%s"', job.index, spell.spellName)
        job.targetName = spell.spellName
        job.deadlineMs = now + APPLY_MEM_TIMEOUT_MS
        job.phase = 'wait_mem'
        return
    end

    if job.phase == 'wait_mem' then
        local gem = me.Gem(job.index)
        local name = gem and gem() and gem.Name() or ''
        local casting = me.Casting and me.Casting() or ''
        local notCasting = casting == '' or casting == 'NULL'
        if name == job.targetName and notCasting then
            logMem('mem_ok_' .. tostring(job.index), 0, 'Gem %d now "%s"', job.index, tostring(name))
            job.phase = 'next_slot'
            return
        end
        if now >= job.deadlineMs then
            logMem('mem_timeout_' .. tostring(job.index), 0,
                'Timeout waiting for gem %d (current="%s", expected="%s")',
                job.index, tostring(name), tostring(job.targetName))
            job.phase = 'next_slot'
        end
        return
    end

    if job.phase == 'done' then
        M.activeSetName = job.setName
        M.pendingApply = nil
        M.saveSpellSets()
        logMem('apply_done', 0.5, 'Apply complete for set "%s"', tostring(job.setName))
        M._applyJob = nil
        M.applying = false
        return
    end
end

--- Actually apply a spell set (memorize spells).
--- Sets up the state machine; the actual memorize advances one step per
--- M.tick() call. Returns immediately — never blocks the main loop.
function M.doApplySet(setName)
    local set = M.spellSets[setName]
    if not set then return end
    if M.applying then return end
    M.applying = true

    if not _setupApplyJob(setName, set) then
        M.applying = false
        return
    end
    -- _applyJob is now populated; M.tick() will drive it.
end

--- Run buff-swap pass using the reserved gem (OOC only)
--- DISABLED: Now handled by sk_buffs.lua coordinator module
function M.runBuffSwap(buffSwapSpells, rotationSpells, waitForMemorizeFn)
    -- Always skip - buffing is now handled by the coordinator (sk_buffs.lua)
    -- This ensures no out-of-coordinator buff casting occurs
    return
end

--[[ DISABLED: Original runBuffSwap code - now handled by sk_buffs.lua
function M._runBuffSwap_DISABLED(buffSwapSpells, rotationSpells, waitForMemorizeFn)
    local me = mq.TLO.Me
    if not me or not me() then return end

    local buffLog = getBuffLogger()
    local Core = getCore()
    local coordinatorEnabled = Core and Core.Settings and Core.Settings.BuffingEnabled ~= false
    if coordinatorEnabled then
        logMem('buffswap_skip_coord', 1.0, 'Buff-swap skipped (coordinator enabled)')
        if buffLog then
            buffLog.info('buffswap', 'Buff-swap skipped: coordinator enabled (coordinator handles mem/cast)')
        end
        return
    end

    if not isSafeToMem() then
        logMem('buffswap_blocked', 1.0, 'Buff-swap blocked (not safe to mem)')
        if buffLog then
            buffLog.warn('buffswap', 'Buff-swap blocked (not safe to mem)')
        end
        return
    end

    local reservedGem = getNumGems()
    if reservedGem <= 0 then
        logMem('buffswap_skip', 1.0, 'Buff-swap skipped (no gems available)')
        if buffLog then
            buffLog.warn('buffswap', 'Buff-swap skipped (no gems available)')
        end
        return
    end

    local allowedRestore = {}
    for _, s in ipairs(rotationSpells or {}) do
        allowedRestore[s.spellName] = true
    end
    for _, s in ipairs(buffSwapSpells or {}) do
        allowedRestore[s.spellName] = true
    end

    local originalSpell = ''
    local currentGem = me.Gem(reservedGem)
    if currentGem and currentGem() then
        originalSpell = currentGem.Name() or ''
    end

    local prevTargetId = mq.TLO.Target.ID() or 0
    logMem('buffswap_start', 0.5, 'Buff-swap: %d lines (reserved gem %d)', #buffSwapSpells, reservedGem)
    if buffLog then
        buffLog.info('buffswap', 'Buff-swap start: lines=%d reservedGem=%d', #buffSwapSpells, reservedGem)
    end
    do
        local allowedList = {}
        for name in pairs(allowedRestore) do
            table.insert(allowedList, tostring(name))
        end
        table.sort(allowedList)
        logMem('buffswap_restore_list', 0,
            'Buff-swap restore allowed: %s (original="%s")',
            (#allowedList > 0) and table.concat(allowedList, ', ') or '<none>',
            tostring(originalSpell))
    end

    local function getSpellId(spellName)
        if not spellName or spellName == '' then return nil end
        local spell = mq.TLO.Spell(spellName)
        if spell and spell() and spell.ID then
            return tonumber(spell.ID()) or nil
        end
        return nil
    end

    local function buildNameQuery(spellName)
        if not spellName or spellName == '' then return nil end
        return string.format('name "%s"', spellName)
    end

    local function hasSelfBuff(spellName, spellId)
        if not spellName or spellName == '' then return false end
        if spellId and me.FindBuff and me.FindBuff('id ' .. spellId)() then
            return true
        end
        local query = buildNameQuery(spellName)
        if query and me.FindBuff and me.FindBuff(query)() then
            return true
        end
        if query and me.FindSong and me.FindSong(query)() then
            return true
        end
        if me.Song and me.Song(spellName)() then
            return true
        end
        return false
    end

    local function hasTargetBuff(spellName, spellId)
        if not spellName or spellName == '' then return false end
        if spellId and mq.TLO.Target.FindBuff and mq.TLO.Target.FindBuff('id ' .. spellId)() then
            return true
        end
        local query = buildNameQuery(spellName)
        if query and mq.TLO.Target.FindBuff and mq.TLO.Target.FindBuff(query)() then
            return true
        end
        return false
    end

    local function ensureTarget(tid)
        if not tid or tid <= 0 then return false end
        if (mq.TLO.Target.ID() or 0) ~= tid then
            mq.cmdf('/target id %d', tid)
        end
        mq.delay(200, function()
            return (mq.TLO.Target.ID() or 0) == tid
        end)
        if mq.TLO.Target.BuffsPopulated then
            mq.delay(300, function() return mq.TLO.Target.BuffsPopulated() == true end)
        end
        return (mq.TLO.Target.ID() or 0) == tid
    end

    local function waitForCastDone()
        mq.delay(12000, function()
            return not me.Casting() and not mq.TLO.Window("CastingWindow").Open()
        end)
    end

    local function waitForSpellReady(spellName)
        local timeoutMs = 6000
        logMem('buffswap_ready_wait_' .. tostring(spellName), 0,
            'Buff-swap ready wait: "%s"', tostring(spellName))
        mq.delay(timeoutMs, function()
            return me.SpellReady and me.SpellReady(spellName)()
        end)
        local ready = me.SpellReady and me.SpellReady(spellName)()
        logMem('buffswap_ready_' .. tostring(spellName), 0,
            'Buff-swap ready: "%s" ready=%s', tostring(spellName), tostring(ready))
        return ready
    end

    local function buildTargets()
        local targets = {}
        local meId = me.ID()
        if meId and meId > 0 then
            table.insert(targets, meId)
        end
        local group = mq.TLO.Group
        local members = group and group.Members() or 0
        for i = 1, members do
            local member = group.Member(i)
            if member and member() then
                local id = member.ID() or 0
                if id > 0 and id ~= meId then
                    table.insert(targets, id)
                end
            end
        end
        return targets
    end

    local targets = buildTargets()
    local gemWasChanged = false  -- Track if we actually memorized anything

    local ConditionBuilder = getConditionBuilder()

    -- Helper to check if a condition uses BuffTarget subject
    local function hasBuffTargetCondition(condition)
        if not condition or not condition.conditions then return false end
        for _, cond in ipairs(condition.conditions) do
            if cond.subject == 'BuffTarget' then return true end
        end
        return false
    end

    -- Helper to get spell range
    local function getSpellRange(spellName)
        local spell = mq.TLO.Spell(spellName)
        if spell and spell() then
            local range = spell.Range() or 0
            local aeRange = spell.AERange() or 0
            return math.max(range, aeRange, 200) -- Default to 200 if no range specified
        end
        return 200
    end

    local function getSpellTargetType(spellName)
        local spell = mq.TLO.Spell(spellName)
        if spell and spell() and spell.TargetType then
            return tostring(spell.TargetType() or '')
        end
        return ''
    end

    local function isSelfOnlyTargetType(targetType)
        local tt = tostring(targetType or ''):lower()
        return tt == 'self' or tt == 'self only' or tt == 'pb ae'
    end

    -- Helper to build context for a target spawn
    local function buildTargetContext(spawn, tid)
        local ctx = { buffTarget = spawn }
        if spawn and spawn() then
            ctx.buffTargetHp = spawn.PctHPs() or 100
            ctx.buffTargetMana = spawn.PctMana() or 100
            ctx.buffTargetIsMe = (tid == (me.ID() or 0))
            local cls = spawn.Class and spawn.Class.ShortName and spawn.Class.ShortName() or ''
            ctx.buffTargetClass = cls
            ctx.buffTargetIsTank = (cls == 'WAR' or cls == 'PAL' or cls == 'SHD')
            ctx.buffTargetIsHealer = (cls == 'CLR' or cls == 'DRU' or cls == 'SHM')
            ctx.buffTargetIsMelee = (cls == 'WAR' or cls == 'PAL' or cls == 'SHD' or cls == 'MNK' or cls == 'ROG' or cls == 'BER' or cls == 'RNG' or cls == 'BST')
            ctx.buffTargetIsCaster = (cls == 'WIZ' or cls == 'MAG' or cls == 'ENC' or cls == 'NEC' or cls == 'CLR' or cls == 'DRU' or cls == 'SHM')
            -- Check group role
            local group = mq.TLO.Group
            if group then
                if group.MainTank and group.MainTank.ID and group.MainTank.ID() == tid then
                    ctx.buffTargetRole = 'MainTank'
                elseif group.MainAssist and group.MainAssist.ID and group.MainAssist.ID() == tid then
                    ctx.buffTargetRole = 'MainAssist'
                elseif group.Puller and group.Puller.ID and group.Puller.ID() == tid then
                    ctx.buffTargetRole = 'Puller'
                end
            end
        end
        return ctx
    end

    for _, spell in ipairs(buffSwapSpells) do
        logMem('buffswap_check_' .. spell.spellName, 0, 'Buff-swap check: "%s"', tostring(spell.spellName))
        if buffLog then
            buffLog.info('buffswap', 'Buff-swap check: spell=%s line=%s', tostring(spell.spellName), tostring(spell.lineName))
        end

        local spellId = getSpellId(spell.spellName)
        local spellRange = getSpellRange(spell.spellName)
        local spellTargetType = getSpellTargetType(spell.spellName)
        local selfOnly = isSelfOnlyTargetType(spellTargetType)
        local usesBuffTargetCondition = hasBuffTargetCondition(spell.condition)

        -- Check mana cost before doing anything else
        local spellData = mq.TLO.Spell(spell.spellName)
        local manaCost = spellData and spellData.Mana and spellData.Mana() or 0
        local currentMana = me.CurrentMana() or 0
        if manaCost > 0 and currentMana < manaCost then
            logMem('buffswap_mana_' .. tostring(spell.spellName), 0,
                'Buff-swap skip: "%s" not enough mana (%d < %d)',
                tostring(spell.spellName), currentMana, manaCost)
            goto continue_spell
        end

        -- If condition doesn't use BuffTarget, check it once upfront (caster conditions)
        if spell.condition and ConditionBuilder and not usesBuffTargetCondition then
            local conditionPasses = ConditionBuilder.evaluate(spell.condition)
            if not conditionPasses then
                logMem('buffswap_cond_fail_' .. tostring(spell.spellName), 0,
                    'Buff-swap skip: "%s" caster condition not met', tostring(spell.spellName))
                goto continue_spell
            end
            logMem('buffswap_cond_pass_' .. tostring(spell.spellName), 0,
                'Buff-swap caster cond pass: "%s"', tostring(spell.spellName))
        end

        -- Build list of targets that need the buff and pass conditions
        local validTargets = {}
        for _, tid in ipairs(targets) do
            local spawn = mq.TLO.Spawn(tid)
            if not spawn or not spawn() then
                goto next_target
            end

            if selfOnly and tid ~= (me.ID() or 0) then
                logMem('buffswap_selfonly_skip_' .. tostring(tid), 0,
                    'Buff-swap skip: "%s" target %d self-only targetType=%s',
                    tostring(spell.spellName), tid, tostring(spellTargetType))
                goto next_target
            end

            -- Check range (skip self for range check)
            local isSelf = (tid == (me.ID() or 0))
            if not isSelf then
                local distance = spawn.Distance() or 0
                if distance > spellRange then
                    logMem('buffswap_range_' .. tostring(tid), 0,
                        'Buff-swap skip: "%s" target %d out of range (%.0f > %.0f)',
                        tostring(spell.spellName), tid, distance, spellRange)
                    goto next_target
                end
            end

            -- Check if already has buff (use cache first, then fresh check if stale)
            local Cache = getRuntimeCache()
            local buffCategory = spell.lineName
            local hasBuff = false

            if isSelf then
                -- Check self buff - use cache if available and fresh
                if Cache and Cache.buffState and Cache.buffState[tid] and Cache.buffState[tid][buffCategory] then
                    local cached = Cache.buffState[tid][buffCategory]
                    local age = os.clock() - (cached.checkedAt or 0)
                    if age < 5 and cached.present then
                        hasBuff = true
                    elseif age >= 5 then
                        -- Cache stale, do fresh check
                        hasBuff = hasSelfBuff(spell.spellName, spellId)
                        -- Update cache
                        Cache.buffState[tid] = Cache.buffState[tid] or {}
                        Cache.buffState[tid][buffCategory] = {
                            present = hasBuff,
                            remaining = 0,
                            spellId = spellId,
                            checkedAt = os.clock(),
                        }
                    end
                else
                    -- No cache, do fresh check
                    hasBuff = hasSelfBuff(spell.spellName, spellId)
                    if Cache and Cache.buffState then
                        Cache.buffState[tid] = Cache.buffState[tid] or {}
                        Cache.buffState[tid][buffCategory] = {
                            present = hasBuff,
                            remaining = 0,
                            spellId = spellId,
                            checkedAt = os.clock(),
                        }
                    end
                end
            else
                -- Check group member buff - use cache if available and fresh
                if Cache and Cache.buffState and Cache.buffState[tid] and Cache.buffState[tid][buffCategory] then
                    local cached = Cache.buffState[tid][buffCategory]
                    local age = os.clock() - (cached.checkedAt or 0)
                    if age < 5 and cached.present then
                        hasBuff = true
                    elseif age >= 5 then
                        -- Cache stale, need to target and check
                        if ensureTarget(tid) then
                            hasBuff = hasTargetBuff(spell.spellName, spellId)
                            Cache.buffState[tid] = Cache.buffState[tid] or {}
                            Cache.buffState[tid][buffCategory] = {
                                present = hasBuff,
                                remaining = 0,
                                spellId = spellId,
                                checkedAt = os.clock(),
                            }
                        end
                    end
                else
                    -- No cache, need to target and check
                    if ensureTarget(tid) then
                        hasBuff = hasTargetBuff(spell.spellName, spellId)
                        if Cache and Cache.buffState then
                            Cache.buffState[tid] = Cache.buffState[tid] or {}
                            Cache.buffState[tid][buffCategory] = {
                                present = hasBuff,
                                remaining = 0,
                                spellId = spellId,
                                checkedAt = os.clock(),
                            }
                        end
                    end
                end
            end

            if hasBuff then
                goto next_target
            end

            -- Check per-target condition (BuffTarget conditions)
            if spell.condition and ConditionBuilder and usesBuffTargetCondition then
                local ctx = buildTargetContext(spawn, tid)
                local conditionPasses = ConditionBuilder.evaluateWithContext(spell.condition, ctx)
                if not conditionPasses then
                    logMem('buffswap_targetcond_' .. tostring(tid), 0,
                        'Buff-swap skip: "%s" target %d condition not met',
                        tostring(spell.spellName), tid)
                    goto next_target
                end
            end

            table.insert(validTargets, tid)
            ::next_target::
        end

        if #validTargets == 0 then
            logMem('buffswap_skip_all_' .. tostring(spell.spellName), 0,
                'Buff-swap skip: "%s" no valid targets', tostring(spell.spellName))
            goto continue_spell
        end

        logMem('buffswap_mem_' .. spell.spellName, 0, 'Buff-swap mem: "%s" for %d targets', tostring(spell.spellName), #validTargets)
        gemWasChanged = true
        mq.cmdf('/memspell %d "%s"', reservedGem, spell.spellName)
        waitForMemorizeFn(reservedGem, spell.spellName)

        local Cache = getRuntimeCache()
        local buffCategory = spell.lineName

        for _, tid in ipairs(validTargets) do
            local isSelf = (tid == (me.ID() or 0))
            if isSelf then
                -- Re-check self buff (might have changed)
                if not hasSelfBuff(spell.spellName, spellId) then
                    logMem('buffswap_cast_' .. tostring(tid), 0, 'Buff-swap cast: "%s" on self', tostring(spell.spellName))
                    if buffLog then
                        buffLog.info('buffswap', 'Buff-swap cast: spell=%s targetId=%d (self)', tostring(spell.spellName), tonumber(tid) or 0)
                    end
                    waitForSpellReady(spell.spellName)
                    mq.cmdf('/cast %d', reservedGem)
                    waitForCastDone()
                    -- Update cache after cast (assume success)
                    if Cache and Cache.buffState then
                        Cache.buffState[tid] = Cache.buffState[tid] or {}
                        Cache.buffState[tid][buffCategory] = {
                            present = true,
                            remaining = 0,
                            spellId = spellId,
                            checkedAt = os.clock(),
                        }
                    end
                end
            else
                if selfOnly then
                    logMem('buffswap_selfonly_skip_' .. tostring(tid), 0,
                        'Buff-swap skip: "%s" target %d self-only targetType=%s',
                        tostring(spell.spellName), tid, tostring(spellTargetType))
                else
                if ensureTarget(tid) then
                    -- Re-check target buff and range
                    local spawn = mq.TLO.Target
                    local distance = spawn and spawn.Distance and spawn.Distance() or 0
                    if distance <= spellRange and not hasTargetBuff(spell.spellName, spellId) then
                        logMem('buffswap_cast_' .. tostring(tid), 0, 'Buff-swap cast: "%s" on %d', tostring(spell.spellName), tid)
                        if buffLog then
                            buffLog.info('buffswap', 'Buff-swap cast: spell=%s targetId=%d', tostring(spell.spellName), tonumber(tid) or 0)
                        end
                        waitForSpellReady(spell.spellName)
                        mq.cmdf('/cast %d', reservedGem)
                        waitForCastDone()
                        -- Update cache after cast (assume success)
                        if Cache and Cache.buffState then
                            Cache.buffState[tid] = Cache.buffState[tid] or {}
                            Cache.buffState[tid][buffCategory] = {
                                present = true,
                                remaining = 0,
                                spellId = spellId,
                                checkedAt = os.clock(),
                            }
                        end
                    else
                        logMem('buffswap_skip_' .. tostring(tid), 0, 'Buff-swap skip: "%s" on %d (has buff or out of range)', tostring(spell.spellName), tid)
                        if buffLog then
                            buffLog.info('buffswap', 'Buff-swap skip: spell=%s targetId=%d hasBuffOrRange', tostring(spell.spellName), tonumber(tid) or 0)
                        end
                    end
                end
                end
            end
        end
        ::continue_spell::
    end

    -- Restore original spell to reserved gem (only if we actually changed it)
    if gemWasChanged and originalSpell ~= '' then
        local canRestore = allowedRestore[originalSpell] == true
        logMem('buffswap_restore_check', 0,
            'Buff-swap restore check: original="%s" allowed=%s',
            tostring(originalSpell), tostring(canRestore))
        if canRestore then
            logMem('buffswap_restore', 0, 'Buff-swap restore: "%s" -> gem %d', tostring(originalSpell), reservedGem)
            mq.cmdf('/memspell %d "%s"', reservedGem, originalSpell)
            waitForMemorizeFn(reservedGem, originalSpell)
        else
            logMem('buffswap_restore_skip', 0,
                'Buff-swap restore skipped (original "%s" not enabled in set)', tostring(originalSpell))
        end
    elseif not gemWasChanged then
        logMem('buffswap_no_restore', 0, 'Buff-swap no restore needed (gem unchanged)')
    end

    if prevTargetId and prevTargetId > 0 then
        mq.cmdf('/target id %d', prevTargetId)
    else
        mq.cmd('/target clear')
    end
end
--]] -- End of disabled _runBuffSwap_DISABLED

--- Check for pending apply and execute when safe
function M.checkPendingApply()
    if not M.pendingApply or M.applying then return end

    if isSafeToMem() then
        logMem('pending_ok', 0.5, 'Pending apply allowed (set "%s")', tostring(M.pendingApply))
        M.doApplySet(M.pendingApply)
    else
        local me = mq.TLO.Me
        local inCombat = me and me.Combat() or false
        local castingSpell = me and me.Casting and me.Casting() or ''
        local casting = castingSpell ~= '' and castingSpell ~= 'NULL'
        local castingWindow = mq.TLO.Window("CastingWindow").Open()
        logMem('pending_blocked', 1.0,
            'Pending blocked (set="%s" inCombat=%s casting=%s castingWindow=%s)',
            tostring(M.pendingApply), tostring(inCombat), tostring(casting), tostring(castingWindow))
    end
end

--------------------------------------------------------------------------------
-- Spell Set INI Persistence
--------------------------------------------------------------------------------

--- Save all spell sets to INI
function M.saveSpellSets()
    local Core = getCore()
    if not Core or not Core.Ini then
        -- Echo disabled
        return
    end

    local ConditionBuilder = getConditionBuilder()

    Core.Ini[SPELLSET_SECTION] = Core.Ini[SPELLSET_SECTION] or {}
    local section = Core.Ini[SPELLSET_SECTION]

    for key in pairs(section) do
        section[key] = nil
    end

    local setNames = M.getSetNames()
    section['_sets'] = table.concat(setNames, ',')
    section['_active'] = M.activeSetName or ''

    local lineCount = 0
    for setName, set in pairs(M.spellSets) do
        local setKey = encodeKey(setName)
        for lineName, lineData in pairs(set.lines) do
            local lineKey = encodeKey(lineName)
            local keyBase = string.format('set|%s|%s|', setKey, lineKey)
            section[keyBase .. 'enabled'] = lineData.enabled and '1' or '0'
            section[keyBase .. 'slotType'] = lineData.slotType or 'rotation'
            section[keyBase .. 'priority'] = tostring(lineData.priority or 999)

            if lineData.condition and ConditionBuilder then
                section[keyBase .. 'condition'] = ConditionBuilder.serialize(lineData.condition)
            else
                section[keyBase .. 'condition'] = ''
            end
            lineCount = lineCount + 1
        end
    end

    -- Echo disabled

    if Core.save then Core.save() end
end

--- Load spell sets from INI
function M.loadSpellSets()
    local Core = getCore()
    if not Core or not Core.Ini then
        -- Echo disabled
        return
    end

    local ConditionBuilder = getConditionBuilder()
    local section = Core.Ini[SPELLSET_SECTION]
    if not section then
        -- Echo disabled
        return
    end

    -- Echo disabled
    M.spellSets = {}

    local setNamesStr = section['_sets'] or ''
    M.activeSetName = section['_active']
    if M.activeSetName == '' then M.activeSetName = nil end

    local setNames = {}
    for name in setNamesStr:gmatch('[^,]+') do
        name = name:match('^%s*(.-)%s*$')
        if name ~= '' then
            table.insert(setNames, name)
            M.spellSets[name] = { name = name, lines = {} }
        end
    end

    for key, value in pairs(section) do
        local setKeyEnc, lineKeyEnc, prop = key:match('^set|([^|]+)|([^|]+)|(.+)$')
        if setKeyEnc and lineKeyEnc and prop then
            local setName = decodeKey(setKeyEnc)
            local lineName = decodeKey(lineKeyEnc)
            if lineName == 'UnifiedHand' then
                lineName = 'Aegolism'
            end
            if M.spellSets[setName] then
                local set = M.spellSets[setName]
                set.lines[lineName] = set.lines[lineName] or {}
                local lineData = set.lines[lineName]

                if prop == 'enabled' then
                    lineData.enabled = (value == '1' or value == 1 or value == true)
                elseif prop == 'slotType' then
                    lineData.slotType = value
                elseif prop == 'priority' then
                    lineData.priority = tonumber(value) or 999
                elseif prop == 'condition' then
                    if value ~= '' and ConditionBuilder then
                        lineData.condition = ConditionBuilder.deserialize(value)
                    end
                end
            end
        else
            -- Legacy format fallback
            local setKey, lineName, propLegacy = key:match('^set_([^_]+)_([^_]+)_(.+)$')
            if setKey and lineName and propLegacy then
                if lineName == 'UnifiedHand' then
                    lineName = 'Aegolism'
                end
                local setName = nil
                for name, _ in pairs(M.spellSets) do
                    if name:gsub('[^%w]', '_') == setKey then
                        setName = name
                        break
                    end
                end

                if setName and M.spellSets[setName] then
                    local set = M.spellSets[setName]
                    set.lines[lineName] = set.lines[lineName] or {}
                    local lineData = set.lines[lineName]

                    if propLegacy == 'enabled' then
                        lineData.enabled = (value == '1' or value == 1 or value == true)
                    elseif propLegacy == 'slotType' then
                        lineData.slotType = value
                    elseif propLegacy == 'priority' then
                        lineData.priority = tonumber(value) or 999
                    elseif propLegacy == 'condition' then
                        if value ~= '' and ConditionBuilder then
                            lineData.condition = ConditionBuilder.deserialize(value)
                        end
                    end
                end
            end
        end
    end

    local lineCount = 0
    local enabledCount = 0
    for _, set in pairs(M.spellSets) do
        for lineName, lineData in pairs(set.lines) do
            if lineData.enabled then
                lineData.resolved = M.resolveSpellFromLine(lineName)
                enabledCount = enabledCount + 1
            end
            lineCount = lineCount + 1
        end
    end

    local setCount = 0
    for _ in pairs(M.spellSets) do setCount = setCount + 1 end
    -- Echo disabled
end

--------------------------------------------------------------------------------
-- Module Query Functions
--------------------------------------------------------------------------------

--- Get enabled lines of a specific slot type, sorted by priority
function M.getEnabledLines(slotType)
    local set = M.getActiveSet()
    if not set then return {} end

    local lines = {}
    for lineName, lineData in pairs(set.lines) do
        if lineData.enabled and lineData.slotType == slotType and lineData.resolved then
            table.insert(lines, {
                lineName = lineName,
                spellName = lineData.resolved,
                condition = lineData.condition,
                priority = lineData.priority or 999,
            })
        end
    end

    table.sort(lines, function(a, b)
        return a.priority < b.priority
    end)

    return lines
end

function M.getRotationLines()
    return M.getEnabledLines('rotation')
end

function M.getBuffSwapLines()
    return M.getEnabledLines('buff_swap')
end

--- Find the best matching spell for a category with conditions
function M.findBestSpell(category, ctx)
    local set = M.getActiveSet()
    if not set then return nil end

    local SpellsClr = getSpellsClr()
    local ConditionBuilder = getConditionBuilder()
    if not SpellsClr then return nil end

    local candidates = {}
    for lineName, lineData in pairs(set.lines) do
        if lineData.enabled and lineData.slotType == 'rotation' and lineData.resolved then
            local lineInfo = SpellsClr.getLine(lineName)
            if lineInfo and lineInfo.category == category then
                table.insert(candidates, {
                    lineName = lineName,
                    spellName = lineData.resolved,
                    condition = lineData.condition,
                    priority = lineData.priority or 999,
                })
            end
        end
    end

    table.sort(candidates, function(a, b)
        return a.priority < b.priority
    end)

    for _, cand in ipairs(candidates) do
        local passes = true
        if cand.condition and ConditionBuilder then
            passes = ConditionBuilder.evaluateWithContext(cand.condition, ctx)
        end

        if passes then
            local me = mq.TLO.Me
            if me and me() and me.SpellReady(cand.spellName)() then
                return cand.spellName
            end
        end
    end

    return nil
end

--------------------------------------------------------------------------------
-- Init / Tick
--------------------------------------------------------------------------------

function M.init()
    if M.initialized then return end

    M.loadSpellSets()
    M.updateCapacity()

    -- Ensure we always have at least one set to edit
    local needsSave = false
    if not next(M.spellSets) then
        local defaultName = 'Default'
        M.spellSets[defaultName] = { name = defaultName, lines = {} }
        M.activeSetName = defaultName
        needsSave = true
    elseif not M.activeSetName then
        local names = M.getSetNames()
        if names[1] then
            M.activeSetName = names[1]
            needsSave = true
        end
    end
    if needsSave then M.saveSpellSets() end

    M.initialized = true
    if M.activeSetName then
        M.applySet(M.activeSetName)
    end
end

function M.tick()
    if not M.initialized then return end
    -- Drive the apply state machine first if a job is in flight; otherwise
    -- let checkPendingApply potentially start a new one.
    if M._applyJob then
        _stepApplyJob()
    else
        M.checkPendingApply()
    end
    -- Note: OOC buff maintenance has been moved to automation/buff.lua
    -- which uses getBuffSwapLines() and handles buffing via the last gem hot-swap
end

return M
