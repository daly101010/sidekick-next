-- F:/lua/SideKick/utils/action_executor.lua
-- Action Executor - Channel-based action execution with lockouts
-- Prevents spam, ensures proper sequencing, enables future spell integration

local mq = require('mq')
local lazy = require('sidekick-next.utils.lazy_require')
local Core = require('sidekick-next.utils.core')
local Helpers = require('sidekick-next.lib.helpers')

local M = {}

-- Optional buff logger for tracing executor-level spell casts
local getBuffLogger = lazy('sidekick-next.automation.buff_logger')
local getHumanize = lazy.once('sidekick-next.humanize')

-- Humanize gate for ability-channel actions. Returns:
--   true  -> caller should proceed (after any delay applied here)
--   false -> caller should bail (SKIP rolled or layer told us to drop)
local function humanizeAbilityGate(ctx)
    local H = getHumanize()
    if not H or not H.gate then return true end
    local d = H.gate('ability', ctx or {})
    if d == H.SKIP then return false end
    if d and d > 0 then mq.delay(d) end
    return true
end

local function isBuffSpell(opts)
    if not opts then return false end
    local cat = tostring(opts.spellCategory or opts.category or ''):lower()
    if cat == 'buff' or cat == 'selfbuff' or cat == 'groupbuff' or cat == 'aura' then
        return true
    end
    return tostring(opts.sourceLayer or ''):lower() == 'buff'
end

-- Channels with independent lockouts
local CHANNELS = {
    melee = { lastAction = 0, lockout = 0.1 },    -- 100ms between melee actions
    aa_disc = { lastAction = 0, lockout = 0.1 },  -- 100ms between AA/disc
    spell = { lastAction = 0, lockout = 0.5 },    -- 500ms between spell casts (GCD)
    item = { lastAction = 0, lockout = 0.2 },     -- 200ms between item clicks
}

-- Global casting lock (can't do most actions while casting)
local _casting = false
local _castEndTime = 0

-- Use centralized game state check from Core
local function can_query_items()
    return Core.CanQueryItems()
end

function M.init()
    for _, ch in pairs(CHANNELS) do
        ch.lastAction = 0
    end
    _casting = false
    _castEndTime = 0
end

--- Check if a channel is ready for action
-- @param channel string Channel name ('melee', 'aa_disc', 'spell', 'item')
-- @return boolean True if channel can execute
function M.isChannelReady(channel)
    local ch = CHANNELS[channel]
    if not ch then return false end

    local now = os.clock()

    -- Global casting lock (except melee)
    if channel ~= 'melee' and _casting and now < _castEndTime then
        return false
    end

    return (now - ch.lastAction) >= ch.lockout
end

--- Mark a channel as used (start lockout)
-- @param channel string Channel name
function M.markChannelUsed(channel)
    local ch = CHANNELS[channel]
    if ch then
        ch.lastAction = os.clock()
    end
end

--- Set casting state (blocks other channels during cast)
-- @param casting boolean Is currently casting
-- @param duration number Cast duration in seconds (optional)
function M.setCasting(casting, duration)
    _casting = casting
    if casting and duration then
        _castEndTime = os.clock() + duration
    elseif not casting then
        _castEndTime = 0
    end
end

--- Check if currently casting
function M.isCasting()
    if _casting and os.clock() >= _castEndTime then
        _casting = false
    end
    return _casting
end

-- AA/Disc Execution

--- Execute an AA ability
-- @param altId number Alt ability ID
-- @return boolean True if executed
function M.executeAA(altId)
    if not altId then return false end
    if not M.isChannelReady('aa_disc') then return false end

    local me = mq.TLO.Me
    if not me or not me() then return false end
    if not me.AltAbilityReady(altId)() then return false end

    if not humanizeAbilityGate({ kind = 'aa', altId = altId }) then return false end

    mq.cmdf('/alt activate %d', altId)
    M.markChannelUsed('aa_disc')
    return true
end

--- Execute a discipline
-- @param discName string Discipline name
-- @return boolean True if executed
function M.executeDisc(discName)
    if not discName or discName == '' then return false end
    if not M.isChannelReady('aa_disc') then return false end

    local me = mq.TLO.Me
    if not me or not me() then return false end

    local readyName = nil
    for _, candidate in ipairs(Helpers.discNameCandidates(discName)) do
        local ok, ready = pcall(function()
            return me.CombatAbilityReady(candidate)() == true
        end)
        if ok and ready then
            readyName = candidate
            break
        end
    end
    if not readyName then return false end

    if not humanizeAbilityGate({ kind = 'disc', name = readyName }) then return false end

    mq.cmd('/disc ' .. readyName)
    M.markChannelUsed('aa_disc')
    return true
end

--- Execute an ability from definition table
-- @param def table Ability definition with kind, altID/discName/spellName
-- @return boolean True if executed
function M.executeAbility(def)
    if not def then return false end

    local kind = tostring(def.kind or 'aa')

    if kind == 'aa' then
        return M.executeAA(tonumber(def.altID))
    elseif kind == 'disc' then
        return M.executeDisc(def.discName or def.altName)
    elseif kind == 'spell' then
        return M.executeSpell(def.spellName, def.targetId, def)
    end

    return false
end

-- Spell Execution

--- Execute a spell through the spell engine
-- @param spellName string Spell name
-- @param targetId number|nil Target spawn ID
-- @param opts table|nil Options (allowMem, preferredGem, maxRetries, spellCategory)
-- @return boolean True if cast initiated
function M.executeSpell(spellName, targetId, opts)
    if not spellName or spellName == '' then return false end
    if not M.isChannelReady('spell') then return false, 'channel_not_ready' end

    -- Delegate to spell engine for full state machine handling
    local ok, SpellEngine = pcall(require, 'sidekick-next.utils.spell_engine')
    if not ok or not SpellEngine then return false, 'no_spell_engine' end

    -- Check if spell engine is already casting
    if SpellEngine.isBusy() then return false, 'busy' end

    local buffLog = isBuffSpell(opts) and getBuffLogger() or nil
    if buffLog then
        buffLog.info('executor', 'Execute spell: spell=%s targetId=%d sourceLayer=%s',
            tostring(spellName), tonumber(targetId) or 0, tostring(opts and opts.sourceLayer or ''))
    end
    local success, reason = SpellEngine.cast(spellName, targetId, opts)
    if buffLog then
        if success then
            buffLog.info('executor', 'Execute spell accepted: spell=%s targetId=%d',
                tostring(spellName), tonumber(targetId) or 0)
        else
            buffLog.warn('executor', 'Execute spell rejected: spell=%s targetId=%d reason=%s',
                tostring(spellName), tonumber(targetId) or 0, tostring(reason))
        end
    end
    return success == true, reason
end

--- Check if spell engine is busy
-- @return boolean True if currently casting a spell
function M.isSpellBusy()
    local ok, SpellEngine = pcall(require, 'sidekick-next.utils.spell_engine')
    if ok and SpellEngine then
        return SpellEngine.isBusy()
    end
    return false
end

-- Item Execution

--- Execute an item click
-- @param itemName string Item name
-- @return boolean True if executed
function M.executeItem(itemName)
    if not itemName or itemName == '' then return false end
    if not M.isChannelReady('item') then return false end

    if not can_query_items() then return false end
    local item = mq.TLO.FindItem(itemName)
    if not item or not item() then return false end
    if item.TimerReady() ~= 0 then return false end  -- 0 means ready

    if not humanizeAbilityGate({ kind = 'item', name = itemName }) then return false end

    mq.cmdf('/useitem "%s"', itemName)
    M.markChannelUsed('item')
    return true
end

--- Execute an item click by slot
-- @param slotName string Slot name (e.g., 'charm', 'pack1')
-- @return boolean True if executed
function M.executeItemSlot(slotName)
    if not slotName or slotName == '' then return false end
    if not M.isChannelReady('item') then return false end

    if not can_query_items() then return false end
    local item = mq.TLO.InvSlot(slotName).Item
    if not item or not item() then return false end
    if item.TimerReady() ~= 0 then return false end

    if not humanizeAbilityGate({ kind = 'itemslot', slot = slotName }) then return false end

    mq.cmdf('/itemnotify %s rightmouseup', slotName)
    M.markChannelUsed('item')
    return true
end

-- Melee Ability Execution

--- Execute a melee ability (Taunt, Kick, Bash, etc.)
-- @param abilityName string Ability name
-- @return boolean True if executed
function M.executeMeleeAbility(abilityName)
    if not abilityName or abilityName == '' then return false end
    if not M.isChannelReady('melee') then return false end

    local me = mq.TLO.Me
    if not me or not me() then return false end
    if not me.AbilityReady(abilityName)() then return false end

    if not humanizeAbilityGate({ kind = 'melee', name = abilityName }) then return false end

    mq.cmdf('/doability "%s"', abilityName)
    M.markChannelUsed('melee')
    return true
end

--- Execute Taunt specifically (commonly used)
-- @return boolean True if executed
function M.executeTaunt()
    return M.executeMeleeAbility('Taunt')
end

--- Execute Kick
-- @return boolean True if executed
function M.executeKick()
    return M.executeMeleeAbility('Kick')
end

return M
