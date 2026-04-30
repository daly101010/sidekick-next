-- utils/spellset_memorize.lua
-- Spell Set Memorization Manager
-- Handles the actual gem memorization when applying spell sets

local mq = require('mq')
local lazy = require('sidekick-next.utils.lazy_require')
local actors = require('actors')
local lib = require('sidekick-next.sk_lib')

local M = {}

--------------------------------------------------------------------------------
-- State
--------------------------------------------------------------------------------

M.isMemorizing = false  -- Flag while memorization in progress
M.pendingSet = nil      -- Queued set to apply when out of combat
M.pendingSave = false   -- Whether to save before applying

--------------------------------------------------------------------------------
-- Lazy-loaded dependencies
--------------------------------------------------------------------------------

local getPersistence = lazy('sidekick-next.utils.spellset_persistence')
local getSpellSetData = lazy('sidekick-next.utils.spellset_data')

--------------------------------------------------------------------------------
-- Constants
--------------------------------------------------------------------------------

local CLEAR_DELAY_MS = 500          -- Delay after right-click to clear gem
local MEMORIZE_TIMEOUT_MS = 12000   -- Max time to wait for memorization
local WAIT_POLL_MS = 100            -- Poll interval for wait functions
local DIRTY_CHECK_INTERVAL = 30     -- Seconds between automatic dirty-gem checks
local STATUS_MODULE = 'spell_memorize'

--------------------------------------------------------------------------------
-- Internal Helpers
--------------------------------------------------------------------------------

--- Check if player is in combat
---@return boolean True if in combat
local function inCombat()
    local me = mq.TLO.Me
    if not me or not me() then return false end

    -- Check Me.Combat() boolean
    local combat = me.Combat()
    if combat then return true end

    -- Check Me.CombatState() string
    local combatState = me.CombatState()
    if combatState and tostring(combatState):upper() == 'COMBAT' then
        return true
    end

    return false
end

--- Clear a gem slot using right-click simulation
---@param slot number The gem slot to clear (1-13)
local function clearGem(slot)
    if not slot or slot < 1 then return end

    -- Right-click on the gem to clear it
    -- Note: CastSpellWnd uses 0-indexed buttons, so slot 1 = CSPW_Spell0
    mq.cmdf('/nomodkey /notify CastSpellWnd CSPW_Spell%d rightmouseup', slot - 1)
    mq.delay(CLEAR_DELAY_MS)
end

-- Gem state checks (no waiting). The state machine driver polls these once
-- per tick; `mq.delay`-style wait loops have been removed because they froze
-- the entire main loop for up to ~16s per gem (~186s across a full swap).
local function isGemEmpty(slot)
    if not slot or slot < 1 then return false end
    local gem = mq.TLO.Me.Gem(slot)
    return not (gem and gem() and gem.ID())
end

local function isGemMemorized(slot, spellId)
    if not slot or slot < 1 or not spellId then return false end
    local gem = mq.TLO.Me.Gem(slot)
    return gem and gem() and gem.ID() == spellId or false
end

--- Get the spell name for a spell ID
---@param spellId number The spell ID
---@return string|nil The spell name or nil
local function getSpellName(spellId)
    if not spellId then return nil end

    local spell = mq.TLO.Spell(spellId)
    if spell and spell() and spell.Name() then
        return spell.Name()
    end

    return nil
end

--- Get current spell ID in a gem slot
---@param slot number The gem slot
---@return number|nil The spell ID or nil if empty
local function getCurrentGemSpellId(slot)
    if not slot or slot < 1 then return nil end

    local gem = mq.TLO.Me.Gem(slot)
    if gem and gem() then
        return gem.ID()
    end

    return nil
end

--------------------------------------------------------------------------------
-- Public Functions
--------------------------------------------------------------------------------

--- Queue a spell set for application (safe to call from ImGui callback)
--- The actual memorization happens in processPending() from the main loop
---@param setName string The name of the spell set to apply
---@param saveFirst boolean|nil If true, save before applying
function M.queueApply(setName, saveFirst)
    M.pendingSet = setName
    M.pendingSave = saveFirst or false
    print(string.format('\ay[SpellSetMemorize]\ax Queued "%s" for memorization', setName or ''))
end

--------------------------------------------------------------------------------
-- State Machine for Memorization (Non-Blocking)
--
-- Replaces the previous synchronous `M.apply` that ran inline mq.delay loops
-- on every gem (up to ~16s per gem × ~12 gems = ~186s of frozen main loop).
-- The state machine advances one step per processPending() tick — same per-
-- gem timeouts as before, but other automation (healing, mez, defensives)
-- continues running between steps.
--
-- Phases (held in M._memJob.phase):
--   start       — initial setup, immediately transitions to next_slot
--   next_slot   — pick the next slot, decide what to do (clear / memspell / skip)
--   wait_clear  — waiting for a /notify rightmouseup to empty the gem
--   wait_mem    — waiting for /memspell to land the requested spell
--   reserved_clear — clear the reserved (last) gem if OOC buffs exist
--   reserved_wait  — waiting for the reserved-gem clear to complete
--   done        — finalize (set active, broadcast, clear state)
--------------------------------------------------------------------------------

M._memJob = nil  -- nil when idle; otherwise see schema below

local function _nowMs()
    return (mq.gettime and mq.gettime()) or (os.clock() * 1000)
end

local _statusActor = nil
local _lastStatusNeed = nil
local _lastStatusReason = nil
local _lastStatusSentAt = 0
local _lastHeartbeatAt = 0

local function getStatusActor()
    if _statusActor ~= nil then return _statusActor end
    local ok, actor = pcall(function()
        return actors.register(STATUS_MODULE, function() end)
    end)
    _statusActor = ok and actor or false
    return _statusActor
end

local function publishStatus(needsAction, reason)
    local actor = getStatusActor()
    if not actor then return end

    local now = lib.getTimeMs()
    if (now - (_lastHeartbeatAt or 0)) >= lib.Timing.MODULE_HEARTBEAT_MS then
        _lastHeartbeatAt = now
        pcall(function()
            actor:send({ mailbox = lib.Mailbox.HEARTBEAT, script = lib.Scripts.COORDINATOR }, {
                msgType = 'heartbeat',
                module = STATUS_MODULE,
                ownerName = lib.getMyName(),
                ownerServer = lib.getMyServer(),
                sentAtMs = now,
                ready = true,
            })
        end)
    end

    local need = needsAction == true
    reason = tostring(reason or (need and 'memorizing' or 'idle'))
    if need == _lastStatusNeed and reason == _lastStatusReason and (now - (_lastStatusSentAt or 0)) < 100 then
        return
    end

    _lastStatusNeed = need
    _lastStatusReason = reason
    _lastStatusSentAt = now
    pcall(function()
        actor:send({ mailbox = lib.Mailbox.NEED, script = lib.Scripts.COORDINATOR }, {
            msgType = 'need',
            module = STATUS_MODULE,
            ownerName = lib.getMyName(),
            ownerServer = lib.getMyServer(),
            priority = lib.Priority.BUFF,
            needsAction = need,
            ttlMs = need and 1000 or 250,
            reason = reason,
        })
    end)
end

local function _abortMemJob(reason, requeue)
    if M._memJob and requeue then
        M.pendingSet = M._memJob.setName
    end
    if M._memJob then
        print(string.format('\ay[SpellSetMemorize]\ax %s "%s" — %s',
            requeue and 'Interrupted, requeuing' or 'Aborted',
            tostring(M._memJob.setName or ''),
            tostring(reason or '')))
    end
    M._memJob = nil
    M.isMemorizing = false
    publishStatus(false, reason or 'aborted')
end

local function _finishMemJob()
    local job = M._memJob
    if not job then return end

    local Persistence = getPersistence()
    if Persistence and Persistence.setActiveSet then
        Persistence.setActiveSet(job.setName)
    end

    print(string.format('\ag[SpellSetMemorize]\ax Spell set "%s" applied successfully', job.setName))
    M._memJob = nil
    M.isMemorizing = false
    publishStatus(false, 'done')
end

--- Apply a spell set (memorize spells) via a non-blocking state machine.
--- Safe to call from any context — does not yield. The actual memorize
--- progresses one step per processPending() tick. The function returns
--- true if a job was successfully queued/started, false if validation failed.
---@param setName string The name of the spell set to apply
---@return boolean True if a memorize job is in progress, false if rejected
function M.apply(setName)
    -- Check if already memorizing
    if M.isMemorizing or M._memJob then
        print(string.format('\ay[SpellSetMemorize]\ax Already memorizing, queuing "%s"', setName or ''))
        M.pendingSet = setName
        return false
    end

    -- Check if in combat
    if inCombat() then
        print(string.format('\ay[SpellSetMemorize]\ax In combat, queuing "%s" for later', setName or ''))
        M.pendingSet = setName
        return false
    end

    local Persistence = getPersistence()
    if not Persistence then
        print('\ar[SpellSetMemorize]\ax Failed to load persistence module')
        return false
    end

    local spellSet = Persistence.getSet(setName)
    if not spellSet then
        print(string.format('\ar[SpellSetMemorize]\ax Spell set "%s" not found', setName or ''))
        return false
    end

    local SpellSetData = getSpellSetData()
    if not SpellSetData then
        print('\ar[SpellSetMemorize]\ax Failed to load spellset_data module')
        return false
    end

    local hasOocBuffs = SpellSetData.hasOocBuffs(spellSet)
    local rotationGems = SpellSetData.getRotationGemCount(hasOocBuffs)
    local totalGems = SpellSetData.getTotalGemCount()

    M.isMemorizing = true
    M.pendingSet = nil
    M._memJob = {
        setName = setName,
        spellSet = spellSet,
        rotationGems = rotationGems,
        totalGems = totalGems,
        hasOocBuffs = hasOocBuffs,
        phase = 'start',
        slot = 0,                -- incremented by next_slot
        targetSpellId = 0,
        deadlineMs = 0,
        clearAttempted = false,
    }

    print(string.format('\ag[SpellSetMemorize]\ax Applying spell set "%s"', setName))
    publishStatus(true, 'starting:' .. tostring(setName or ''))
    return true
end

-- Advance the state machine by one step. Called from processPending each
-- main-loop tick. Each step does at most one TLO read pass + one issued
-- command — the heavy lifting is yielding back to the main loop between
-- ticks rather than blocking inside mq.delay loops.
local function _stepMemJob()
    local job = M._memJob
    if not job then return end

    -- Combat interrupt check at every step.
    if inCombat() then
        _abortMemJob('combat detected', true)
        return
    end

    local now = _nowMs()

    if job.phase == 'start' then
        job.phase = 'next_slot'
        return
    end

    if job.phase == 'next_slot' then
        job.slot = job.slot + 1
        job.clearAttempted = false

        if job.slot > job.rotationGems then
            -- Done with rotation gems. Handle reserved gem if needed.
            if job.hasOocBuffs and job.totalGems and job.totalGems > 0 then
                job.phase = 'reserved_clear'
            else
                job.phase = 'done'
            end
            return
        end

        local gemConfig = job.spellSet.gems[job.slot]
        local currentSpellId = getCurrentGemSpellId(job.slot)

        if gemConfig and gemConfig.spellId then
            if currentSpellId == gemConfig.spellId then
                -- Already correct, advance.
                return
            end
            -- Need to change. Clear (if needed) then memspell.
            local spellName = getSpellName(gemConfig.spellId)
            if not spellName then
                print(string.format('\ay[SpellSetMemorize]\ax Spell ID %d not found in spellbook', gemConfig.spellId))
                return  -- next_slot stays the phase, slot advances next call
            end
            job.targetSpellId = gemConfig.spellId
            job.targetSpellName = spellName
            if currentSpellId then
                clearGem(job.slot)
                job.deadlineMs = now + 3000
                job.phase = 'wait_clear'
            else
                mq.cmdf('/memspell %d "%s"', job.slot, spellName)
                job.deadlineMs = now + MEMORIZE_TIMEOUT_MS
                job.phase = 'wait_mem'
            end
            return
        end

        if currentSpellId then
            -- No config but slot has a spell — clear it, no follow-up memspell.
            clearGem(job.slot)
            job.deadlineMs = now + 3000
            job.targetSpellId = 0  -- signal: no memspell after clear
            job.phase = 'wait_clear'
            return
        end

        -- No config, no spell — leave empty, advance.
        return
    end

    if job.phase == 'wait_clear' then
        if isGemEmpty(job.slot) then
            if job.targetSpellId and job.targetSpellId > 0 then
                mq.cmdf('/memspell %d "%s"', job.slot, job.targetSpellName)
                job.deadlineMs = now + MEMORIZE_TIMEOUT_MS
                job.phase = 'wait_mem'
            else
                job.phase = 'next_slot'
            end
            return
        end
        if now >= job.deadlineMs then
            print(string.format('\ay[SpellSetMemorize]\ax Failed to clear gem %d (continuing)', job.slot))
            -- Try memspell anyway if we have a target — otherwise advance.
            if job.targetSpellId and job.targetSpellId > 0 then
                mq.cmdf('/memspell %d "%s"', job.slot, job.targetSpellName)
                job.deadlineMs = now + MEMORIZE_TIMEOUT_MS
                job.phase = 'wait_mem'
            else
                job.phase = 'next_slot'
            end
        end
        return
    end

    if job.phase == 'wait_mem' then
        if isGemMemorized(job.slot, job.targetSpellId) then
            job.phase = 'next_slot'
            return
        end
        if now >= job.deadlineMs then
            print(string.format('\ay[SpellSetMemorize]\ax Timeout memorizing "%s" in gem %d',
                tostring(job.targetSpellName or '?'), job.slot))
            job.phase = 'next_slot'
        end
        return
    end

    if job.phase == 'reserved_clear' then
        local reservedSlot = job.totalGems
        local currentSpellId = getCurrentGemSpellId(reservedSlot)
        if not currentSpellId then
            job.phase = 'done'
            return
        end
        clearGem(reservedSlot)
        job.deadlineMs = now + 3000
        job.slot = reservedSlot
        job.phase = 'reserved_wait'
        return
    end

    if job.phase == 'reserved_wait' then
        if isGemEmpty(job.slot) or now >= job.deadlineMs then
            job.phase = 'done'
        end
        return
    end

    if job.phase == 'done' then
        _finishMemJob()
        return
    end
end

--------------------------------------------------------------------------------
-- Dirty-Gem Watchdog
--------------------------------------------------------------------------------

local _lastDirtyCheck = 0

--- Compare live gems against the active spell set.
--- If any slot mismatches, queue the active set for re-memorization.
local function checkDirtyGems()
    local now = os.clock()
    if (now - _lastDirtyCheck) < DIRTY_CHECK_INTERVAL then return end
    _lastDirtyCheck = now

    if inCombat() then return end

    local Persistence = getPersistence()
    if not Persistence then return end

    local activeSetName = Persistence.activeSetName
    if not activeSetName then return end

    local spellSet = Persistence.getSet(activeSetName)
    if not spellSet or not spellSet.gems then return end

    local SpellSetData = getSpellSetData()
    if not SpellSetData then return end

    local hasOocBuffs = SpellSetData.hasOocBuffs(spellSet)
    local rotationGems = SpellSetData.getRotationGemCount(hasOocBuffs)

    for slot = 1, rotationGems do
        local gemConfig = spellSet.gems[slot]
        if gemConfig and gemConfig.spellId then
            local currentId = getCurrentGemSpellId(slot)
            if currentId ~= gemConfig.spellId then
                print(string.format(
                    '\ay[SpellSetMemorize]\ax Gem %d is dirty — queuing "%s" for re-memorization',
                    slot, activeSetName))
                M.pendingSet = activeSetName
                return
            end
        end
    end
end

--- Process pending spell set / advance active job. Called from main loop.
--- One state-machine step per tick — never blocks.
function M.processPending()
    -- If a job is already running, advance it one step and return.
    if M._memJob then
        publishStatus(true, 'phase:' .. tostring(M._memJob.phase or 'active'))
        _stepMemJob()
        if not M._memJob then
            publishStatus(false, 'idle')
        end
        return
    end

    publishStatus(false, 'idle')

    -- No active job. Run the periodic dirty-gem check if not memorizing.
    if not M.pendingSet then
        if not M.isMemorizing then
            checkDirtyGems()
        end
        if not M.pendingSet then return end
    end

    if M.isMemorizing then return end
    if inCombat() then return end

    local setName = M.pendingSet
    local shouldSave = M.pendingSave
    M.pendingSet = nil
    M.pendingSave = false

    -- Save first if requested
    if shouldSave then
        local Persistence = getPersistence()
        if Persistence then
            local ok = Persistence.save()
            if ok ~= false then
                print('\ag[SpellSetMemorize]\ax Spell sets saved')
            else
                print('\ar[SpellSetMemorize]\ax Spell sets save failed')
                M.pendingSet = setName
                return
            end
        end
    end

    M.apply(setName)
    -- M.apply just sets up _memJob; the next tick will start advancing it.
end

--- Cancel the pending spell set
function M.cancelPending()
    if M.pendingSet then
        print(string.format('\ay[SpellSetMemorize]\ax Cancelled pending set "%s"', M.pendingSet))
        M.pendingSet = nil
    end
end

--- Check if memorization is in progress (active job or legacy flag).
---@return boolean True if busy memorizing
function M.isBusy()
    return M.isMemorizing or M._memJob ~= nil
end

--- Get the pending set name (if any)
---@return string|nil The pending set name or nil
function M.getPendingSet()
    return M.pendingSet
end

return M
