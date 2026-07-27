-- humanize/fidget.lua
-- Idle-time movement emitter. Adds turn-key presses, jumps, strafes, window
-- peeks, and sit/stand med cycles when the active profile is 'idle'.
--
-- /face is intentionally avoided — it produces pixel-perfect heading snaps
-- that are an obvious bot tell. All rotation goes through /keypress instead,
-- which mimics real keyboard input.
--
-- Hard-gated off whenever in combat, following, navigating, looting, mezzed
-- mobs nearby, or any group member in combat. Min-interval between fidgets
-- prevents twitchy behavior.
--
-- Two-phase keypress pattern: emit a hold, then schedule a counter-press to
-- "release" after a randomized duration. State machine in M.tick() handles the
-- pending-release without blocking the caller.

local mq = require('mq')

local Profiles      = require('sidekick-next.humanize.profiles')
local Selector      = require('sidekick-next.humanize.selector')
local State         = require('sidekick-next.humanize.state')
local Distributions = require('sidekick-next.humanize.distributions')

local M = {}

-- Literal keyboard key names for /keypress. Edit to match your bindings.
-- /keypress takes raw key names (e.g. 'space', 'left', 'page_up'), NOT MQ
-- mappable command names ('forward', 'jump').
local Keybinds = {
    turn_left    = 'left',         -- arrow key
    turn_right   = 'right',        -- arrow key
    jump         = 'space',        -- common default
    strafe_left  = 'strafe_left',  -- mappable cmd name (default Q in EQ)
    strafe_right = 'strafe_right', -- mappable cmd name (default E in EQ)
    look_up      = nil,            -- set if you have a key bound to camera pitch up
    look_down    = nil,            -- set if you have a key bound to camera pitch down
}

-- Hotkeys that toggle windows. Real players poke at these idly. Same key
-- press opens and closes (EQ window keys are toggles). Edit to match your
-- bindings; entries set to nil are skipped at pick time.
local WindowKeys = {
    inventory = 'i',  -- inventory
    character = 'c',  -- character/stats
    map       = 'm',  -- map
    group     = 'v',  -- group window
}

local Config = {
    -- Average per-second probability of emitting a fidget when idle.
    fidgetPerSec = 1.0,

    -- Minimum gap between fidgets.
    minIntervalMs = 8000,

    -- Action weights (must sum to <=1; remainder is "no-op this tick").
    weights = {
        turn       = 0.40,
        jump       = 0.12,
        strafe     = 0.15,
        window     = 0.13,
        pitch      = 0.00,   -- disabled by default: pitch keys are usually unbound
        med_cycle  = 0.20,
    },

    -- Turn/pitch hold duration distribution (ms before the counter-press).
    holdMs = { dist = 'lognormal', median_ms = 140, sigma = 0.40, min = 80, max = 280 },

    -- Strafe hold per leg (left, then right). Two legs = ~2-4s total.
    -- Net position change is ~zero since you go out and back.
    strafeHoldMs = { dist = 'lognormal', median_ms = 1300, sigma = 0.30, min = 800, max = 2200 },

    -- How long a peeked window stays open before the close keypress fires.
    windowPeekMs = { dist = 'lognormal', median_ms = 2200, sigma = 0.40, min = 900, max = 5500 },

    -- Med cycle hold duration (ms).
    medHoldMs = { dist = 'lognormal', median_ms = 35000, sigma = 0.45, min = 20000, max = 60000 },

    -- Mana threshold below which med_cycle is allowed (humans don't med at full mana).
    medMaxManaPct = 90,

    -- Awareness range for "mezzed mob nearby" check (units).
    mezAwarenessRange = 80,
}

-- State machine: when 'pending_release', M.tick() emits the counter-press once
-- the timer expires. Prevents callers from having to mq.delay.
local Fidget = {
    lastFidgetAt = 0,
    lastTickAt   = 0,
    pending      = nil,   -- { kind='turn'|'pitch'|'med', releaseAt=ms, releaseKey=keybind }
    planned      = nil,
    planCounter  = 0,
}

local function flagOn()
    local cfg = _G.SIDEKICK_NEXT_CONFIG
    return cfg and cfg.HUMANIZE_BEHAVIOR == true
end

local function isMeValid()
    local me = mq.TLO.Me
    return me and me() ~= nil
end

local function blockedByGameState()
    if not isMeValid() then return true, 'no_me' end
    local me = mq.TLO.Me

    -- Never synthesize keypresses while the player is typing. Use only members
    -- present in mq-definitions; pcall is for transient window absence, not for
    -- guessing TLO names.
    local function truthyProbe(fn)
        local ok, value = pcall(fn)
        if not ok then return false end
        if type(value) == 'string' then return value ~= '' and value:lower() ~= 'false' end
        return value == true or (tonumber(value) or 0) > 0
    end
    local chatInput = mq.TLO.Window('ChatWindow').Child('CW_ChatInput')
    if truthyProbe(function() return chatInput.Highlighted() end)
        or truthyProbe(function() return chatInput.Text() end) then
        return true, 'chat_input'
    end

    -- In combat (self).
    local cs = me.CombatState and me.CombatState() or ''
    if cs == 'COMBAT' then return true, 'combat' end

    -- Casting.
    local casting = me.Casting and me.Casting() or ''
    if casting ~= '' then return true, 'casting' end

    -- Following someone.
    local af = me.AutoFollowing and me.AutoFollowing() or false
    if af == true then return true, 'autofollow' end

    -- On a nav path.
    local navActive = mq.TLO.Nav and mq.TLO.Nav.Active and mq.TLO.Nav.Active()
    if navActive == true then return true, 'navigating' end

    -- Looting (LootWindow open).
    local lootOpen = mq.TLO.Window('LootWnd').Open and mq.TLO.Window('LootWnd').Open()
    if lootOpen == true then return true, 'looting' end

    -- Group member in combat.
    local groupSize = mq.TLO.Group.Members() or 0
    for i = 1, groupSize do
        local member = mq.TLO.Group.Member(i)
        if member and member() then
            local memberCs = member.CombatState and member.CombatState() or ''
            if memberCs == 'COMBAT' then return true, 'group_combat' end
        end
    end

    -- Mezzed mobs in awareness range (movement could break mez).
    local xtCount = (me.XTarget and me.XTarget()) or 0
    for i = 1, xtCount do
        local xt = me.XTarget(i)
        if xt and xt() then
            local id = xt.ID and xt.ID() or 0
            if id > 0 then
                local sp = mq.TLO.Spawn(id)
                if sp and sp() then
                    local dist = sp.Distance3D and sp.Distance3D() or 999
                    if dist < Config.mezAwarenessRange then
                        local mezzed = sp.Mezzed and sp.Mezzed() ~= nil
                        if mezzed then return true, 'mez_nearby' end
                    end
                end
            end
        end
    end

    return false, nil
end

local function rollAction()
    local r = math.random()
    local acc = 0
    for kind, w in pairs(Config.weights) do
        acc = acc + w
        if r <= acc then return kind end
    end
    return nil
end

local function manaPct()
    local me = mq.TLO.Me
    return (me and me.PctMana and me.PctMana()) or 100
end

local function isSitting()
    local me = mq.TLO.Me
    return me and me.Sitting and me.Sitting() == true
end

local function pickWindowKey()
    -- Collect configured (non-nil) window keys; pick uniformly.
    local keys = {}
    for _, k in pairs(WindowKeys) do
        if type(k) == 'string' and k ~= '' then table.insert(keys, k) end
    end
    if #keys == 0 then return nil end
    return keys[math.random(1, #keys)]
end

local function emit(kind)
    local now = State.now()
    -- Movement actions (turn/jump/strafe) will stand you up if you're medding.
    -- Capture pre-fidget sit state so we can restore it after the action chain
    -- finishes. Stored on the pending entry; final-release in tick() handles it.
    local wasSitting = isSitting()

    if kind == 'turn' then
        local left = math.random() < 0.5
        local pressKey = left and Keybinds.turn_left or Keybinds.turn_right
        local releaseKey = left and Keybinds.turn_right or Keybinds.turn_left
        local hold = math.floor(Distributions.sample(Config.holdMs))
        mq.cmdf('/keypress %s hold', pressKey)
        Fidget.pending = {
            kind = 'turn',
            releaseAt = now + hold,
            releaseKey = releaseKey,
            resitAfter = wasSitting,
        }
        return true
    elseif kind == 'pitch' then
        -- Skip if no keybinds configured (EQ has no defaults).
        if not Keybinds.look_up or not Keybinds.look_down then return false end
        local up = math.random() < 0.5
        local pressKey = up and Keybinds.look_up or Keybinds.look_down
        local releaseKey = up and Keybinds.look_down or Keybinds.look_up
        local hold = math.floor(Distributions.sample(Config.holdMs))
        mq.cmdf('/keypress %s hold', pressKey)
        Fidget.pending = {
            kind = 'pitch',
            releaseAt = now + hold,
            releaseKey = releaseKey,
            resitAfter = wasSitting,
        }
        return true
    elseif kind == 'jump' then
        if not Keybinds.jump then return false end
        -- Single tap; jump is instantaneous. If we were sitting, sit back down
        -- after a brief beat so the jump animation can play.
        mq.cmdf('/keypress %s', Keybinds.jump)
        if wasSitting then
            Fidget.pending = {
                kind = 'jump_resit',
                releaseAt = now + 600,  -- give the jump animation room
                releaseKey = nil,
                resitAfter = true,
            }
        end
        return true
    elseif kind == 'strafe' then
        if not Keybinds.strafe_left or not Keybinds.strafe_right then return false end
        -- Always start with left, then chain right via the pending-release path.
        -- Net displacement ~zero.
        local hold = math.floor(Distributions.sample(Config.strafeHoldMs))
        mq.cmdf('/keypress %s hold', Keybinds.strafe_left)
        Fidget.pending = {
            kind        = 'strafe',
            releaseAt   = now + hold,
            releaseKey  = Keybinds.strafe_left,
            chainPress  = Keybinds.strafe_right,  -- press this after releasing left
            chainHoldMs = math.floor(Distributions.sample(Config.strafeHoldMs)),
            resitAfter  = wasSitting,             -- carried through to final release
        }
        return true
    elseif kind == 'window' then
        local key = pickWindowKey()
        if not key then return false end
        local hold = math.floor(Distributions.sample(Config.windowPeekMs))
        mq.cmdf('/keypress %s', key)
        Fidget.pending = {
            kind = 'window',
            releaseAt = now + hold,
            releaseKey = key,   -- same key toggles the window closed
            -- no resitAfter: opening a window doesn't stand the character
        }
        return true
    elseif kind == 'med_cycle' then
        if manaPct() >= Config.medMaxManaPct then return false end
        local me = mq.TLO.Me
        local sitting = me and me.Sitting and me.Sitting() == true
        if not sitting then
            mq.cmd('/sit')
            local hold = math.floor(Distributions.sample(Config.medHoldMs))
            Fidget.pending = {
                kind = 'med',
                releaseAt = now + hold,
                releaseKey = nil, -- handled in tick: cmd is /stand
            }
            return true
        end
        return false
    end
    return false
end

local function pendingHoldsMovement()
    local p = Fidget.pending
    return p and p.releaseKey
        and (p.kind == 'turn' or p.kind == 'pitch' or p.kind == 'strafe')
end

function M.releaseHeldKeys()
    if not pendingHoldsMovement() then return false end
    local releaseKey = Fidget.pending.releaseKey
    Fidget.pending = nil
    mq.cmdf('/keypress %s', releaseKey)
    return true
end

function M.hasPending()
    return Fidget.pending ~= nil
end

function M.planAction()
    if not flagOn() then
        Fidget.planned = nil
        return nil, 'humanize_off'
    end
    if not Profiles.subsystemEnabled('fidget') then
        Fidget.planned = nil
        return nil, 'fidget_off'
    end
    if Fidget.pending then return nil, 'episode_active' end

    local now = State.now()
    if Fidget.planned and (now - (Fidget.planned.plannedAt or 0)) <= 5000 then
        local blocked, reason = blockedByGameState()
        if not blocked and Selector.resolve() == 'idle' then
            return Fidget.planned, 'planned'
        end
        Fidget.planned = nil
        return nil, reason or 'profile_changed'
    end
    if (now - Fidget.lastTickAt) < 250 then return nil, 'sensor_throttled' end
    Fidget.lastTickAt = now
    if Selector.resolve() ~= 'idle' then return nil, 'not_idle_profile' end
    if (now - Fidget.lastFidgetAt) < Config.minIntervalMs then
        return nil, 'minimum_interval'
    end
    local blocked, reason = blockedByGameState()
    if blocked then return nil, reason or 'blocked' end

    local pPerTick = math.min(0.5, (Config.fidgetPerSec * 250) / 1000.0)
    if not Distributions.chance(pPerTick) then return nil, 'roll_skipped' end
    local kind = rollAction()
    if not kind then return nil, 'no_action_rolled' end

    Fidget.planCounter = Fidget.planCounter + 1
    Fidget.planned = {
        kind = 'fidget',
        fidgetKind = kind,
        planId = string.format('%d:%d', now, Fidget.planCounter),
        plannedAt = now,
        breaksInvis = false,
        skipBoundaryTarget = true,
        timeoutMs = 10000,
        idempotencyKey = string.format('fidget:%d:%d', now, Fidget.planCounter),
        reason = 'idle_fidget:' .. kind,
    }
    return Fidget.planned, 'ready'
end

function M.startAction(action)
    action = type(action) == 'table' and action or {}
    local planned = Fidget.planned
    if not planned
        or tostring(action.planId or '') ~= tostring(planned.planId or '')
        or tostring(action.fidgetKind or '') ~= tostring(planned.fidgetKind or '') then
        return false, 'plan_changed'
    end
    local blocked, reason = blockedByGameState()
    if blocked or Selector.resolve() ~= 'idle' then
        Fidget.planned = nil
        return false, reason or 'not_idle_profile'
    end
    Fidget.planned = nil
    return M.tick({
        allowMutations = true,
        plannedKind = action.fidgetKind,
    })
end

function M.advanceAction()
    M.tick({ allowMutations = true, advanceOnly = true })
    return Fidget.pending == nil,
        Fidget.pending and ('waiting:' .. tostring(Fidget.pending.kind))
            or 'episode_complete'
end

function M.cancelAction()
    Fidget.planned = nil
    local pending = Fidget.pending
    if not pending then return true end
    if pendingHoldsMovement() then
        M.releaseHeldKeys()
        return true
    end
    Fidget.pending = nil
    if pending.kind == 'window' and pending.releaseKey then
        mq.cmdf('/keypress %s', pending.releaseKey)
    elseif pending.kind == 'med' then
        mq.cmd('/stand')
    end
    return true
end

function M.recoverHeldKeys()
    Fidget.pending = nil
    Fidget.planned = nil
    local seen = {}
    for _, name in ipairs({
        'turn_left', 'turn_right', 'strafe_left', 'strafe_right',
        'look_up', 'look_down',
    }) do
        local key = Keybinds[name]
        if type(key) == 'string' and key ~= '' and not seen[key] then
            seen[key] = true
            mq.cmdf('/keypress %s', key)
        end
    end
    return true
end

-- Drive the fidget state machine. Call once per main-loop tick. No-op when
-- humanize is disabled or fidget subsystem is off.
function M.tick(opts)
    opts = type(opts) == 'table' and opts or {}
    if opts.allowMutations ~= true then
        return false, 'lease_required'
    end
    if not flagOn() then M.releaseHeldKeys(); return end
    if not Profiles.subsystemEnabled('fidget') then M.releaseHeldKeys(); return end

    local now = State.now()

    -- A held movement key must always be released, even if chat gained focus
    -- after the hold began. Starting a chained leg, toggling a window, or
    -- changing sit state remains blocked while chat owns the keyboard.
    local blocked, blockedReason = blockedByGameState()

    -- Process any pending release first.
    if Fidget.pending and now >= Fidget.pending.releaseAt then
        local p = Fidget.pending
        local heldMovement = p.kind == 'turn' or p.kind == 'pitch' or p.kind == 'strafe'
        if blockedReason == 'chat_input' and not heldMovement then return end
        Fidget.pending = nil
        if p.kind == 'med' then
            -- Only stand back up if we're still safe to do so.
            local blocked = select(1, blockedByGameState())
            if not blocked then
                mq.cmd('/stand')
            end
        elseif p.kind == 'jump_resit' then
            -- Post-jump resit: the jump itself already fired; this step is a
            -- timer to let the animation play, then sit back down.
            local blocked = select(1, blockedByGameState())
            if not blocked and p.resitAfter and not isSitting() then
                mq.cmd('/sit')
            end
        elseif p.releaseKey then
            mq.cmdf('/keypress %s', p.releaseKey)
            -- If this step has a chained second leg (e.g. strafe left -> right),
            -- press the chain key and re-arm pending so tick releases it next.
            -- Carry resitAfter through so the final release re-sits if needed.
            if p.chainPress and blockedReason ~= 'chat_input' then
                mq.cmdf('/keypress %s hold', p.chainPress)
                Fidget.pending = {
                    kind       = p.kind,
                    releaseAt  = now + (p.chainHoldMs or 1200),
                    releaseKey = p.chainPress,
                    resitAfter = p.resitAfter,
                }
            elseif p.resitAfter then
                -- Final leg: re-sit if we were medding before fidgeting.
                local blocked = select(1, blockedByGameState())
                if not blocked and not isSitting() then
                    mq.cmd('/sit')
                end
            end
        end
        return
    end

    if blocked and blockedReason == 'chat_input' then return end

    -- Don't roll a new fidget while one is in progress.
    if Fidget.pending then return end
    if opts.advanceOnly == true then return true, 'episode_complete' end

    if opts.plannedKind then
        if blocked then return false, blockedReason or 'blocked' end
        Fidget.lastFidgetAt = now
        local emitted = emit(tostring(opts.plannedKind))
        return emitted, emitted and 'episode_started' or 'emit_refused'
    end

    -- Throttle.
    if (now - Fidget.lastTickAt) < 250 then return end
    Fidget.lastTickAt = now

    -- Profile must be 'idle'.
    local profileName = Selector.resolve()
    if profileName ~= 'idle' then return end

    -- Min-interval gate.
    if (now - Fidget.lastFidgetAt) < Config.minIntervalMs then return end

    -- Hard gates from game state.
    if blockedByGameState() then return end

    -- Roll: ~Config.fidgetPerSec attempts/sec, modulated by tick rate.
    local pPerTick = (Config.fidgetPerSec * (now - (Fidget.lastTickAt - 250))) / 1000.0
    if pPerTick > 0.5 then pPerTick = 0.5 end
    if not Distributions.chance(pPerTick) then return end

    local kind = rollAction()
    if not kind then return end

    Fidget.lastFidgetAt = now
    emit(kind)
end

-- Expose tunables for the UI tab to read/edit.
function M.getKeybinds() return Keybinds end
function M.setKeybind(name, value)
    if Keybinds[name] == nil and not (name == 'look_up' or name == 'look_down') then return end
    if value == '' then value = nil end
    Keybinds[name] = value
end

function M.getWindowKeys() return WindowKeys end
function M.setWindowKey(name, value)
    if WindowKeys[name] == nil then return end
    if value == '' then value = nil end
    WindowKeys[name] = value
end

function M.getConfig() return Config end
function M.setWeight(action, value)
    if not Config.weights or Config.weights[action] == nil then return end
    value = tonumber(value) or 0
    if value < 0 then value = 0 end
    if value > 1 then value = 1 end
    Config.weights[action] = value
end
function M.setMinIntervalMs(ms)
    ms = tonumber(ms) or 8000
    if ms < 1000 then ms = 1000 end
    if ms > 60000 then ms = 60000 end
    Config.minIntervalMs = ms
end
function M.setFidgetPerSec(v)
    v = tonumber(v) or 1.0
    if v < 0.05 then v = 0.05 end
    if v > 5.0 then v = 5.0 end
    Config.fidgetPerSec = v
end

return M
