-- utils/spellset_memorize.lua
-- Spell Set Memorization Manager
-- Handles the actual gem memorization when applying spell sets

local mq = require('mq')
local lazy = require('sidekick-next.utils.lazy_require')

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

--- Wait until a gem slot is empty or timeout
---@param slot number The gem slot to check
---@param timeout number Timeout in milliseconds
---@return boolean True if gem is now empty, false if timed out
local function waitGemClear(slot, timeout)
    if not slot or slot < 1 then return false end
    timeout = timeout or 5000

    local elapsed = 0
    while elapsed < timeout do
        local gem = mq.TLO.Me.Gem(slot)
        if not gem or not gem() or not gem.ID() then
            return true
        end

        mq.delay(WAIT_POLL_MS)
        elapsed = elapsed + WAIT_POLL_MS

        -- Check for combat interrupt
        if inCombat() then
            return false
        end
    end

    return false
end

--- Wait until a spell is memorized in a gem slot or timeout
---@param slot number The gem slot to check
---@param spellId number The expected spell ID
---@param timeout number Timeout in milliseconds
---@return boolean True if spell is memorized, false if timed out
local function waitGemMemorize(slot, spellId, timeout)
    if not slot or slot < 1 or not spellId then return false end
    timeout = timeout or MEMORIZE_TIMEOUT_MS

    local elapsed = 0
    while elapsed < timeout do
        local gem = mq.TLO.Me.Gem(slot)
        if gem and gem() and gem.ID() == spellId then
            return true
        end

        mq.delay(WAIT_POLL_MS)
        elapsed = elapsed + WAIT_POLL_MS

        -- Check for combat interrupt
        if inCombat() then
            return false
        end
    end

    return false
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

--- Apply a spell set (memorize spells)
--- WARNING: This uses mq.delay and cannot be called from ImGui callbacks!
--- Use queueApply() instead from UI code.
---@param setName string The name of the spell set to apply
---@return boolean True if memorization completed, false if failed/queued
function M.apply(setName)
    -- Check if already memorizing
    if M.isMemorizing then
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

    -- Get the spell set
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

    -- Get spell set data module for gem count calculation
    local SpellSetData = getSpellSetData()
    if not SpellSetData then
        print('\ar[SpellSetMemorize]\ax Failed to load spellset_data module')
        return false
    end

    -- Start memorization
    M.isMemorizing = true
    M.pendingSet = nil

    print(string.format('\ag[SpellSetMemorize]\ax Applying spell set "%s"', setName))

    -- Calculate rotation gems (reserve last gem if OOC buffs exist)
    local hasOocBuffs = SpellSetData.hasOocBuffs(spellSet)
    local rotationGems = SpellSetData.getRotationGemCount(hasOocBuffs)
    local totalGems = SpellSetData.getTotalGemCount()

    -- Process each rotation gem slot
    for slot = 1, rotationGems do
        -- Check for combat interrupt
        if inCombat() then
            print('\ay[SpellSetMemorize]\ax Interrupted by combat')
            M.isMemorizing = false
            M.pendingSet = setName  -- Queue for retry
            return false
        end

        local gemConfig = spellSet.gems[slot]
        local currentSpellId = getCurrentGemSpellId(slot)

        if gemConfig and gemConfig.spellId then
            -- Config exists for this slot
            if currentSpellId ~= gemConfig.spellId then
                -- Need to change the spell in this slot
                local spellName = getSpellName(gemConfig.spellId)
                if spellName then
                    -- Clear the gem first if it has a spell
                    if currentSpellId then
                        clearGem(slot)
                        if not waitGemClear(slot, 3000) then
                            print(string.format('\ay[SpellSetMemorize]\ax Failed to clear gem %d', slot))
                            -- Continue anyway, memspell might work
                        end
                    end

                    -- Memorize the new spell
                    mq.cmdf('/memspell %d "%s"', slot, spellName)

                    -- Wait for memorization
                    if not waitGemMemorize(slot, gemConfig.spellId, MEMORIZE_TIMEOUT_MS) then
                        if inCombat() then
                            print('\ay[SpellSetMemorize]\ax Interrupted by combat during memorization')
                            M.isMemorizing = false
                            M.pendingSet = setName
                            return false
                        else
                            print(string.format('\ay[SpellSetMemorize]\ax Timeout memorizing "%s" in gem %d', spellName, slot))
                        end
                    end
                else
                    print(string.format('\ay[SpellSetMemorize]\ax Spell ID %d not found in spellbook', gemConfig.spellId))
                end
            end
            -- else: spell already memorized, no action needed
        elseif currentSpellId then
            -- No config for this slot, but has a spell - clear it
            clearGem(slot)
            waitGemClear(slot, 3000)
        end
        -- else: no config and no spell, leave empty
    end

    -- Clear the reserved gem if OOC buffs exist
    if hasOocBuffs and totalGems > 0 then
        local reservedSlot = totalGems
        local currentSpellId = getCurrentGemSpellId(reservedSlot)
        if currentSpellId then
            -- Check for combat interrupt
            if inCombat() then
                print('\ay[SpellSetMemorize]\ax Interrupted by combat')
                M.isMemorizing = false
                M.pendingSet = setName
                return false
            end

            clearGem(reservedSlot)
            waitGemClear(reservedSlot, 3000)
        end
    end

    -- Set the active set in persistence
    Persistence.setActiveSet(setName)

    M.isMemorizing = false
    print(string.format('\ag[SpellSetMemorize]\ax Spell set "%s" applied successfully', setName))
    return true
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

--- Process pending spell set if out of combat
--- Called from main loop
function M.processPending()
    -- If nothing pending, run the periodic dirty-gem check
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
            Persistence.save()
            print('\ag[SpellSetMemorize]\ax Spell sets saved')
        end
    end

    M.apply(setName)
end

--- Cancel the pending spell set
function M.cancelPending()
    if M.pendingSet then
        print(string.format('\ay[SpellSetMemorize]\ax Cancelled pending set "%s"', M.pendingSet))
        M.pendingSet = nil
    end
end

--- Check if memorization is in progress
---@return boolean True if busy memorizing
function M.isBusy()
    return M.isMemorizing
end

--- Get the pending set name (if any)
---@return string|nil The pending set name or nil
function M.getPendingSet()
    return M.pendingSet
end

return M
