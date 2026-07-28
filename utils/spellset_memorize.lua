-- utils/spellset_memorize.lua
-- Spell Set Memorization Manager
-- Handles the actual gem memorization when applying spell sets

local mq = require('mq')
local lazy = require('sidekick-next.utils.lazy_require')
local lib = require('sidekick-next.sk_lib')

local M = {}

--------------------------------------------------------------------------------
-- State
--------------------------------------------------------------------------------

M.isMemorizing = false  -- Flag while memorization in progress
M.pendingSet = nil      -- Queued set to apply when out of combat
M.pendingSave = false   -- Whether to save before applying
M.suspendUntilMs = 0    -- External lease holder can pause spellset enforcement
M.suspendReason = nil
M._dirtyEffect = false  -- Owned gem/spellbook mutation not yet observed settled
M._cleanupCloseIssuedAt = 0

--------------------------------------------------------------------------------
-- Lazy-loaded dependencies
--------------------------------------------------------------------------------

local getPersistence = lazy('sidekick-next.utils.spellset_persistence')
local getSpellSetData = lazy('sidekick-next.utils.spellset_data')
local getConditionDefaults = lazy('sidekick-next.utils.condition_defaults')
local getActorsCoordinator = lazy('sidekick-next.utils.actors_coordinator')

--------------------------------------------------------------------------------
-- Constants
--------------------------------------------------------------------------------

local MEMORIZE_TIMEOUT_MS = 12000   -- Max time to wait for memorization
local WAIT_POLL_MS = 100            -- Poll interval for wait functions
local MANUAL_SCAN_INTERVAL_MS = 250 -- Polling is cheap and runs only while idle/OOC
local MANUAL_SETTLE_MS = 750        -- Require a stable post-memorization layout
local STATUS_TOPIC = 'spellset:status'
local TRANSPORT_TTL_MS = 5000
local COMMAND_RETRY_MS = 1000
local MAX_COMMAND_INBOX = 16

local _workerMode = false
local _workerTransportInitialized = false
local _clientTransportInitialized = false
local _commandInbox = {}
local _clientStatusInbox = {}
local _clientQueued = nil
local _clientRemote = {
    busy = false,
    pendingSet = nil,
    reason = 'idle',
    requestId = nil,
    receivedAtMs = 0,
}
local _transportSession = string.format('spellset:%d:%d',
    lib.getTimeMs(), math.random(100000, 999999))
local _transportSequence = 0
local _workerRequestId = nil
local _lastWorkerStatus = nil
local _lastWorkerStatusAtMs = 0

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

local function isSpellIdKnown(spellId)
    local spellName = getSpellName(spellId)
    if not spellName or spellName == '' then return false end
    local me = mq.TLO.Me
    if not (me and me() and me.Book) then return true end
    local ok, known = pcall(function()
        local bookSpell = me.Book(spellName)
        return bookSpell and bookSpell() and true or false
    end)
    if not ok then return true end
    return known == true
end

local function pruneUnavailableSpells(spellSet)
    if not spellSet then return false end
    local changed = false
    local SpellSetData = getSpellSetData()

    for slot, gemConfig in pairs(spellSet.gems or {}) do
        if gemConfig and gemConfig.spellId and not isSpellIdKnown(gemConfig.spellId) then
            print(string.format('\ay[SpellSetMemorize]\ax Removing unavailable spell ID %s from gem %s',
                tostring(gemConfig.spellId), tostring(slot)))
            if SpellSetData and SpellSetData.clearGem then
                SpellSetData.clearGem(spellSet, slot)
            else
                spellSet.gems[slot] = nil
            end
            changed = true
        end
    end

    if type(spellSet.oocBuffs) == 'table' then
        for i = #spellSet.oocBuffs, 1, -1 do
            local buffConfig = spellSet.oocBuffs[i]
            if buffConfig and buffConfig.spellId and not isSpellIdKnown(buffConfig.spellId) then
                print(string.format('\ay[SpellSetMemorize]\ax Removing unavailable OOC buff spell ID %s',
                    tostring(buffConfig.spellId)))
                table.remove(spellSet.oocBuffs, i)
                changed = true
            end
        end
    end

    return changed
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

local function nextTransportId(prefix)
    _transportSequence = _transportSequence + 1
    return string.format('%s:%s:%d:%d', tostring(prefix),
        _transportSession, lib.getTimeMs(), _transportSequence)
end

local function hasValidActorEnvelope(content)
    local envelope = type(content) == 'table'
        and type(content.envelope) == 'table' and content.envelope or nil
    local ActorsCoordinator = getActorsCoordinator()
    local expectedVersion = ActorsCoordinator
        and tonumber(ActorsCoordinator.ENVELOPE_VERSION) or nil
    local sequence = envelope and tonumber(envelope.sequence) or 0
    local ttlMs = envelope and tonumber(envelope.ttlMs) or 0
    return envelope ~= nil
        and expectedVersion ~= nil
        and tonumber(envelope.version) == expectedVersion
        and tostring(envelope.session or '') ~= ''
        and sequence > 0
        and sequence == math.floor(sequence)
        and ttlMs > 0 and ttlMs <= 30000
        and tonumber(envelope.sentAtMs) ~= nil
end

local function isLocalUiSender(sender, fromMe)
    if fromMe ~= true or type(sender) ~= 'table' then return false end
    local scripts = type(lib.Scripts.UI) == 'table'
        and lib.Scripts.UI or { lib.Scripts.UI }
    for _, scriptName in ipairs(scripts) do
        if lib.actorSenderMatches(sender, scriptName, 'sidekick') then return true end
    end
    return false
end

local function copyApplyMessage(content, sender)
    if type(content) ~= 'table' then return nil end
    local setName = tostring(content.setName or '')
    local requestId = tostring(content.requestId or '')
    local ttlMs = tonumber(content.ttlMs) or TRANSPORT_TTL_MS
    if setName == '' or #setName > 256
        or requestId == '' or #requestId > 128
        or ttlMs <= 0 or ttlMs > TRANSPORT_TTL_MS then
        return nil
    end
    return {
        setName = setName,
        saveFirst = content.saveFirst == true,
        requestId = requestId,
        issuedAtMs = tonumber(content.issuedAtMs) or 0,
        ttlMs = ttlMs,
        ownerName = tostring(sender and sender.character or ''),
        ownerServer = tostring(sender and sender.server or ''),
    }
end

local function copyStatusMessage(content)
    if type(content) ~= 'table' then return nil end
    return {
        busy = content.busy == true,
        pendingSet = tostring(content.pendingSet or ''),
        reason = tostring(content.reason or ''),
        requestId = tostring(content.requestId or ''),
        sentAtMs = tonumber(content.sentAtMs) or 0,
    }
end

function M.initializeWorker()
    if _workerTransportInitialized then return true end
    _workerMode = true
    local Actors = getActorsCoordinator()
    if not Actors or not Actors.registerWorkerCommand then return false end
    Actors.registerWorkerCommand('scribing',
        function(command, content, envelope, sender, fromMe)
        -- Actor callbacks retain no message handle and perform no TLO, file,
        -- gameplay, send, or yielding work.
        if tostring(command or ''):lower() ~= 'apply_spellset'
            or not hasValidActorEnvelope(envelope)
            or not isLocalUiSender(sender, fromMe)
            or #_commandInbox >= MAX_COMMAND_INBOX then
            return true
        end
        local copied = copyApplyMessage(content, sender)
        if copied then _commandInbox[#_commandInbox + 1] = copied end
        return true
        end)
    _workerTransportInitialized = true
    return true
end

function M.initializeClient()
    if _clientTransportInitialized then return true end
    local Actors = getActorsCoordinator()
    if not Actors or not Actors.registerTelemetryCallback then return false end
    Actors.registerTelemetryCallback(STATUS_TOPIC, function(content)
        if #_clientStatusInbox >= MAX_COMMAND_INBOX then return end
        local copied = copyStatusMessage(content)
        if copied then _clientStatusInbox[#_clientStatusInbox + 1] = copied end
    end)
    _clientTransportInitialized = true
    return true
end

function M.drainWorkerCommands()
    if not _workerMode or #_commandInbox == 0 then return 0 end
    local inbox = _commandInbox
    _commandInbox = {}
    local now = lib.getTimeMs()
    local myName = tostring(lib.getMyName() or ''):lower()
    local myServer = tostring(lib.getMyServer() or ''):lower()
    local accepted = 0
    for _, command in ipairs(inbox) do
        local ageMs = now - command.issuedAtMs
        local fresh = command.issuedAtMs > 0
            and ageMs >= 0
            and ageMs <= math.max(1, command.ttlMs)
        local localOwner = tostring(command.ownerName or ''):lower() == myName
            and tostring(command.ownerServer or ''):lower() == myServer
        if fresh and localOwner and command.setName ~= ''
            and command.requestId ~= '' and command.requestId ~= _workerRequestId then
            -- Last accepted request wins; a currently executing job remains
            -- bounded and the replacement waits in pendingSet.
            M.pendingSet = command.setName
            M.pendingSave = command.saveFirst == true
            _workerRequestId = command.requestId
            accepted = accepted + 1
        end
    end
    return accepted
end

function M.drainClientStatus()
    if #_clientStatusInbox == 0 then return end
    local inbox = _clientStatusInbox
    _clientStatusInbox = {}
    for _, status in ipairs(inbox) do
        if status.sentAtMs >= (_clientRemote.receivedAtMs or 0) then
            _clientRemote.busy = status.busy
            _clientRemote.pendingSet = status.pendingSet ~= '' and status.pendingSet or nil
            _clientRemote.reason = status.reason
            _clientRemote.requestId = status.requestId ~= '' and status.requestId or nil
            _clientRemote.receivedAtMs = status.sentAtMs
            if _clientQueued and _clientRemote.requestId == _clientQueued.requestId then
                _clientQueued.acknowledged = true
            end
        end
    end
end

function M.publishWorkerStatus(reason, force)
    if not _workerMode then return false end
    local now = lib.getTimeMs()
    local busy = M.isMemorizing == true or M._memJob ~= nil
    local pendingSet = M.pendingSet
    local signature = table.concat({
        tostring(busy), tostring(pendingSet or ''), tostring(reason or ''),
        tostring(_workerRequestId or ''),
    }, '|')
    if force ~= true and signature == _lastWorkerStatus
        and (now - _lastWorkerStatusAtMs) < 1000 then
        return true
    end
    _lastWorkerStatus = signature
    _lastWorkerStatusAtMs = now
    local Actors = getActorsCoordinator()
    if not Actors or not Actors.sendTelemetryToScript then return false end
    local payload = {
        busy = busy,
        pendingSet = pendingSet or '',
        reason = tostring(reason or (busy and 'active' or 'idle')),
        requestId = tostring(_workerRequestId or ''),
        sentAtMs = now,
    }
    local sent = false
    local scripts = type(lib.Scripts.UI) == 'table' and lib.Scripts.UI
        or { lib.Scripts.UI }
    for _, scriptName in ipairs(scripts) do
        local ok = Actors.sendTelemetryToScript(
            scriptName, 'scribing', STATUS_TOPIC, payload)
        sent = ok or sent
    end
    return sent
end

--- Queue a spell set for application (safe to call from ImGui callback)
--- The UI path stores intent only. processPending() sends it from the main
--- loop; the scribing worker performs mutations only after acquiring a lease.
---@param setName string The name of the spell set to apply
---@param saveFirst boolean|nil If true, save before applying
function M.queueApply(setName, saveFirst)
    setName = tostring(setName or '')
    if setName == '' then return false end
    if _workerMode then
        M.pendingSet = setName
        M.pendingSave = saveFirst == true
        _workerRequestId = _workerRequestId or nextTransportId('local')
    else
        M.initializeClient()
        _clientQueued = {
            setName = setName,
            saveFirst = saveFirst == true,
            requestId = nextTransportId('apply'),
            issuedAtMs = lib.getTimeMs(),
            lastSentAtMs = 0,
            acknowledged = false,
        }
    end
    print(string.format('\ay[SpellSetMemorize]\ax Queued "%s" for memorization', setName or ''))
    return true
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

local function getExternalLeasePath()
    return string.format('%s/SideKick_buff_gem_lease.txt', tostring(mq.configDir or 'config'))
end

local function readExternalLease()
    local path = getExternalLeasePath()
    local fh = io.open(path, 'r')
    if not fh then return 0, nil end
    local line = fh:read('*l') or ''
    fh:close()
    local expiry, reason = line:match('^(%d+)%s*(.*)$')
    expiry = tonumber(expiry) or 0
    if expiry > 0 and os.time() > expiry then
        pcall(os.remove, path)
    end
    return expiry, reason
end

local function isSuspended()
    if _nowMs() < (M.suspendUntilMs or 0) then
        return true
    end

    local expiry, reason = readExternalLease()
    if os.time() <= expiry then
        M.suspendReason = reason ~= '' and reason or 'external_buff_hotswap'
        return true
    end
    M.suspendReason = nil
    return false
end

local function ensurePersistenceLoaded(Persistence)
    if not Persistence then return false end
    if not Persistence.loaded and Persistence.load then
        local ok, loaded = pcall(Persistence.load)
        return ok and loaded == true
    end
    return true
end

--- Temporarily pause spellset memorization/enforcement.
--- Used by buff hotswap so the reserved OOC buff gem is not cleared while
--- sk_buffs is memorizing/casting from it.
---@param ttlMs number Milliseconds to suspend
---@param reason string|nil Human-readable reason
function M.suspend(ttlMs, reason)
    ttlMs = tonumber(ttlMs) or 0
    if ttlMs <= 0 then return end
    local untilMs = _nowMs() + ttlMs
    if untilMs > (M.suspendUntilMs or 0) then
        M.suspendUntilMs = untilMs
    end
    M.suspendReason = reason or M.suspendReason or 'suspended'
end

function M.clearSuspend(reason)
    if not reason or reason == M.suspendReason then
        M.suspendUntilMs = 0
        M.suspendReason = nil
    end
end

local function publishStatus(needsAction, reason)
    M.publishWorkerStatus(tostring(reason
        or (needsAction and 'memorizing' or 'idle')), false)
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
    if isSuspended() then
        M.pendingSet = setName
        print(string.format('\ay[SpellSetMemorize]\ax Suspended (%s), queuing "%s"',
            tostring(M.suspendReason or 'external'), tostring(setName or '')))
        return false
    end

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
    if not ensurePersistenceLoaded(Persistence) then
        print('\ar[SpellSetMemorize]\ax Failed to load spell set persistence')
        return false
    end

    local spellSet = Persistence.getSet(setName)
    if not spellSet then
        print(string.format('\ar[SpellSetMemorize]\ax Spell set "%s" not found', setName or ''))
        return false
    end
    if pruneUnavailableSpells(spellSet) then
        pcall(Persistence.save)
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
local isSpellBookOpen

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
                M._dirtyEffect = true
                job.deadlineMs = now + 3000
                job.phase = 'wait_clear'
            else
                mq.cmdf('/memspell %d "%s"', job.slot, spellName)
                M._dirtyEffect = true
                job.deadlineMs = now + MEMORIZE_TIMEOUT_MS
                job.phase = 'wait_mem'
            end
            return
        end

        if currentSpellId then
            -- No config but slot has a spell — clear it, no follow-up memspell.
            clearGem(job.slot)
            M._dirtyEffect = true
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
            M._dirtyEffect = false
            if job.targetSpellId and job.targetSpellId > 0 then
                mq.cmdf('/memspell %d "%s"', job.slot, job.targetSpellName)
                M._dirtyEffect = true
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
                M._dirtyEffect = true
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
            M._dirtyEffect = false
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
        M._dirtyEffect = true
        job.deadlineMs = now + 3000
        job.slot = reservedSlot
        job.phase = 'reserved_wait'
        return
    end

    if job.phase == 'reserved_wait' then
        if isGemEmpty(job.slot) then
            M._dirtyEffect = false
            job.phase = 'done'
        elseif now >= job.deadlineMs then
            job.phase = 'done'
        end
        return
    end

    if job.phase == 'done' then
        if M._dirtyEffect and isSpellBookOpen and isSpellBookOpen() then
            lib.safeTLO(function()
                local window = mq.TLO.Window('SpellBookWnd')
                if window and window.Open and window.Open() and window.DoClose then
                    window.DoClose()
                end
                return true
            end, false)
            M._cleanupCloseIssuedAt = now
            job.deadlineMs = now + 1500
            job.phase = 'cleanup_wait'
            return
        end
        M._dirtyEffect = false
        _finishMemJob()
        return
    end

    if job.phase == 'cleanup_wait' then
        if not isSpellBookOpen() then
            M._dirtyEffect = false
            _finishMemJob()
        elseif now >= job.deadlineMs then
            _abortMemJob('spellbook_cleanup_timeout', true)
        end
        return
    end
end

--------------------------------------------------------------------------------
-- Manual Gem Adoption
--------------------------------------------------------------------------------

local _lastManualScanAtMs = -MANUAL_SCAN_INTERVAL_MS
local _manualGemObservations = {}

isSpellBookOpen = function()
    local ok, open = pcall(function()
        local window = mq.TLO.Window('SpellBookWnd')
        return window and window.Open and window.Open() or false
    end)
    return ok and open == true
end

--- Adopt stable live gem changes into the active spell set.
--- The spellbook guard prevents capturing the transient empty gem created in
--- the middle of /memspell. SideKick jobs and buff swaps are excluded by the
--- caller and the cross-script suspension lease.
local function adoptManualGemChanges()
    local nowMs = _nowMs()
    if (nowMs - _lastManualScanAtMs) < MANUAL_SCAN_INTERVAL_MS then return end
    _lastManualScanAtMs = nowMs

    if inCombat() then
        _manualGemObservations = {}
        return
    end
    if isSpellBookOpen() then
        _manualGemObservations = {}
        return
    end

    local Persistence = getPersistence()
    if not Persistence then return end
    if not ensurePersistenceLoaded(Persistence) then return end

    local activeSetName = Persistence.activeSetName
    if not activeSetName then return end

    local spellSet = Persistence.getSet(activeSetName)
    if not spellSet or not spellSet.gems then return end
    if pruneUnavailableSpells(spellSet) then
        pcall(Persistence.save)
    end

    local SpellSetData = getSpellSetData()
    if not SpellSetData then return end

    local hasOocBuffs = SpellSetData.hasOocBuffs(spellSet)
    local rotationGems = SpellSetData.getRotationGemCount(hasOocBuffs)
    local changed = 0

    for slot = 1, rotationGems do
        local gemConfig = spellSet.gems[slot]
        local configuredId = gemConfig and tonumber(gemConfig.spellId) or nil
        local currentId = tonumber(getCurrentGemSpellId(slot))
        if currentId == 0 then currentId = nil end

        if currentId == configuredId then
            _manualGemObservations[slot] = nil
        else
            local observation = _manualGemObservations[slot]
            if not observation or observation.spellId ~= currentId or observation.configuredId ~= configuredId then
                _manualGemObservations[slot] = {
                    spellId = currentId,
                    configuredId = configuredId,
                    sinceMs = nowMs,
                }
            elseif (nowMs - observation.sinceMs) >= MANUAL_SETTLE_MS then
                local oldName = configuredId and (getSpellName(configuredId) or tostring(configuredId)) or '(empty)'
                local newName = currentId and (getSpellName(currentId) or tostring(currentId)) or '(empty)'
                local restoredProfile = currentId and SpellSetData.getSpellProfile
                    and SpellSetData.getSpellProfile(spellSet, currentId) or nil
                local detectedType = nil

                if currentId then
                    local condition = restoredProfile and restoredProfile.condition or nil
                    local ConditionDefaults = getConditionDefaults()
                    if ConditionDefaults and ConditionDefaults.getSpellTypeCategory then
                        local ok, result = pcall(ConditionDefaults.getSpellTypeCategory, currentId)
                        if ok then
                            detectedType = result
                        else
                            print(string.format(
                                '\ay[SpellSetMemorize] Unable to classify manually memorized spell %s: %s\ax',
                                newName, tostring(result)))
                        end
                    end
                    if not restoredProfile then
                        local shouldGenerate = false
                        if ConditionDefaults and ConditionDefaults.shouldGenerateDefaults then
                            local ok, result = pcall(ConditionDefaults.shouldGenerateDefaults, currentId)
                            if ok then
                                shouldGenerate = result == true
                            else
                                print(string.format(
                                    '\ay[SpellSetMemorize] Unable to inspect default condition for %s: %s\ax',
                                    newName, tostring(result)))
                            end
                        end
                        if shouldGenerate and ConditionDefaults.generateCombatCondition then
                            local ok, result = pcall(ConditionDefaults.generateCombatCondition, currentId)
                            if ok then
                                condition = result
                            else
                                print(string.format(
                                    '\ay[SpellSetMemorize] Unable to generate default condition for %s: %s\ax',
                                    newName, tostring(result)))
                            end
                        end
                    end
                    SpellSetData.setGem(spellSet, slot, currentId, condition,
                        restoredProfile and restoredProfile.priority or nil,
                        restoredProfile and restoredProfile.buffTarget or nil,
                        restoredProfile and restoredProfile.utility or nil)
                else
                    SpellSetData.clearGem(spellSet, slot)
                end

                changed = changed + 1
                _manualGemObservations[slot] = nil
                print(string.format(
                    '\ag[SpellSetMemorize]\ax Adopted manual gem %d: %s -> %s type=%s%s',
                    slot, oldName, newName,
                    tostring(detectedType or 'empty'),
                    restoredProfile and ' (restored saved condition/settings)' or ''))
            end
        end
    end

    if changed > 0 then
        local ok, saved = pcall(Persistence.save)
        if not ok or saved ~= true then
            print(string.format(
                '\ar[SpellSetMemorize]\ax Adopted %d manual gem change(s) in memory but failed to save: %s',
                changed, tostring(ok and saved or saved)))
        else
            print(string.format(
                '\ag[SpellSetMemorize]\ax Saved %d manual gem change(s) to active set "%s"',
                changed, activeSetName))
        end
    end
end

--- Process pending spell set / advance active job. Called from main loop.
--- One state-machine step per tick — never blocks.
local function advancePendingLeased()
    if isSuspended() then
        -- Another worker owns the temporary buff gem. Keep the request queued
        -- and do not advance any gem mutation.
        publishStatus(false, 'suspended:' .. tostring(M.suspendReason or 'external'))
        return
    end

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

    -- No active job. Adopt stable manual gem changes if not memorizing.
    if not M.pendingSet then
        if not M.isMemorizing then
            adoptManualGemChanges()
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
        if Persistence and ensurePersistenceLoaded(Persistence) then
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

--- Read-only/local planning for the dedicated scribing worker.
function M.inspectWork()
    M.drainWorkerCommands()

    if M._dirtyEffect then
        return {
            mode = 'cleanup',
            setName = M._memJob and M._memJob.setName or M.pendingSet,
            phase = M._memJob and M._memJob.phase or 'orphan_cleanup',
        }, 'owned_effect_cleanup'
    end

    if M._memJob and inCombat() then
        _abortMemJob('combat detected', true)
    end
    if M._memJob and isSuspended() then
        _abortMemJob('suspended:' .. tostring(M.suspendReason or 'external'), true)
    end
    if isSuspended() then return nil, 'suspended:' .. tostring(M.suspendReason or 'external') end

    if M._memJob then
        return {
            mode = 'apply',
            setName = M._memJob.setName,
            phase = M._memJob.phase,
        }, 'active'
    end
    if M.pendingSet and not inCombat() then
        return {
            mode = 'apply',
            setName = M.pendingSet,
            phase = 'pending',
        }, 'pending'
    end

    if not M.isMemorizing then adoptManualGemChanges() end
    return nil, inCombat() and 'combat_wait' or 'idle'
end

--- Advance exactly one state-machine step under an exact local lease.
---@return boolean terminal True when this lease episode is complete
---@return string reason Diagnostic phase/result
function M.advanceLeased()
    if not _workerMode then return true, 'not_worker' end
    M.drainWorkerCommands()
    if isSuspended() then
        if M._memJob then
            _abortMemJob('suspended:' .. tostring(M.suspendReason or 'external'), true)
        end
        return true, 'suspended'
    end
    advancePendingLeased()
    if M._memJob then
        return false, 'phase:' .. tostring(M._memJob.phase or 'active')
    end
    if M.pendingSet then
        return true, inCombat() and 'combat_requeued' or 'pending_requeued'
    end
    return true, 'completed'
end

function M.abortActive(reason, requeue)
    if M._memJob then _abortMemJob(reason or 'aborted', requeue ~= false) end
end

function M.hasDirtyEffects()
    return M._dirtyEffect == true
end

--- Drain only effects this process marked when it issued a gem mutation.
--- Must be called from a worker finalizer holding the exact/recovery lease.
function M.drainOwnedEffects(reason)
    if M._dirtyEffect then
        if isSpellBookOpen() then
            local now = _nowMs()
            if (now - (M._cleanupCloseIssuedAt or 0)) >= 250 then
                M._cleanupCloseIssuedAt = now
                lib.safeTLO(function()
                    local window = mq.TLO.Window('SpellBookWnd')
                    if window and window.Open and window.Open() and window.DoClose then
                        window.DoClose()
                    end
                    return true
                end, false)
            end
            if isSpellBookOpen() then return false, 'closing_owned_spellbook' end
        end
        M._dirtyEffect = false
    end
    M.abortActive(reason or 'lease_finalized', true)
    return true, reason or 'effects_drained'
end

--- UI-host transport tick. It sends intent only; no TLO/gameplay mutation is
--- performed here. The worker acknowledges asynchronously through STATUS_TOPIC.
function M.processPending()
    if _workerMode then return end
    M.initializeClient()
    M.drainClientStatus()
    local queued = _clientQueued
    if not queued then return end
    if queued.acknowledged then
        _clientQueued = nil
        return
    end
    local now = lib.getTimeMs()
    if (now - (queued.lastSentAtMs or 0)) < COMMAND_RETRY_MS then return end
    queued.lastSentAtMs = now
    queued.issuedAtMs = now
    local Actors = getActorsCoordinator()
    if not Actors or not Actors.sendWorkerCommand then return end
    Actors.sendWorkerCommand('scribing', 'apply_spellset', {
        setName = queued.setName,
        saveFirst = queued.saveFirst == true,
        requestId = queued.requestId,
        issuedAtMs = queued.issuedAtMs,
        ttlMs = TRANSPORT_TTL_MS,
        ownerName = lib.getMyName(),
        ownerServer = lib.getMyServer(),
    }, { component = 'scribing', requestId = queued.requestId })
end

--- Cancel the pending spell set
function M.cancelPending()
    if _workerMode and M.pendingSet then
        print(string.format('\ay[SpellSetMemorize]\ax Cancelled pending set "%s"', M.pendingSet))
        M.pendingSet = nil
    elseif not _workerMode and _clientQueued then
        print(string.format('\ay[SpellSetMemorize]\ax Cancelled pending set "%s"',
            tostring(_clientQueued.setName or '')))
        _clientQueued = nil
    end
end

--- Check if memorization is in progress (active job or legacy flag).
---@return boolean True if busy memorizing
function M.isBusy()
    if _workerMode then return M.isMemorizing or M._memJob ~= nil end
    M.drainClientStatus()
    return _clientRemote.busy == true
end

--- Get the pending set name (if any)
---@return string|nil The pending set name or nil
function M.getPendingSet()
    if _workerMode then return M.pendingSet end
    M.drainClientStatus()
    if _clientQueued then return _clientQueued.setName end
    return _clientRemote.pendingSet
end

return M
