-- utils/rez_accept.lua
-- Auto-accept resurrection offers when AutoAcceptRez is enabled.
-- Registers an mq.event on the rez-offer chat line and exposes a tick()
-- that runs a 1Hz fallback poll on the ConfirmationDialogBox window.
-- Lives in SideKick.lua's main loop and runs on EVERY character (not just
-- rez classes) — anyone can die and need a rez accepted.

local mq = require('mq')
local lazy = require('sidekick-next.utils.lazy_require')

local getCore = lazy('sidekick-next.utils.core')

local M = {}

local _initialized = false
local _lastPollMs = 0
local _pendingClickAtMs = 0
local POLL_INTERVAL_MS = 1000

local function autoAcceptEnabled()
    local Core = getCore()
    if not (Core and Core.Settings) then return true end -- default true
    local v = Core.Settings.AutoAcceptRez
    return v ~= false -- nil or true => enabled
end

local function clickYes()
    -- The standard EQ resurrection prompt window. /notify Yes_Button
    -- triggers the same path as the user clicking Yes.
    mq.cmd('/notify ConfirmationDialogBox Yes_Button leftmouseup')
end

local function queueClickYes()
    _pendingClickAtMs = mq.gettime() + 300
end

local function isRezDialogOpen()
    local ok, w = pcall(function() return mq.TLO.Window('ConfirmationDialogBox') end)
    if not ok or not w then return false end
    if not w.Open() then return false end
    -- The dialog text contains "resurrect"/"resurrection" for rez offers
    -- but the same window class is reused for many other prompts. Filter
    -- by inspecting the visible text.
    local text = ''
    pcall(function()
        local child = w.Child('CD_TextOutput')
        if child and child() then text = tostring(child.Text() or '') end
    end)
    if text == '' then
        pcall(function() text = tostring(w.Child('Text').Text() or '') end)
    end
    text = text:lower()
    return text:find('resurrect', 1, true) ~= nil
end

--- Register the chat event. Idempotent.
function M.init()
    if _initialized then return end
    _initialized = true

    -- Standard EQ rez-offer chat line. Captures the caster name in #1#.
    mq.event(
        'SideKick_RezOffer',
        '#1# is attempting to resurrect you. Do you wish to be revived?',
        function()
            if autoAcceptEnabled() then queueClickYes() end
        end
    )
end

--- Per-tick hook — runs the 1Hz fallback poll on the dialog window.
--- Caller must drive mq.doevents() elsewhere (SideKick's main loop already
--- does this once per tick). The fallback poll covers rare cases where the
--- rez chat line is suppressed (chat filters, custom rez sources).
function M.tick()
    if not _initialized then return end

    local now = mq.gettime()
    if _pendingClickAtMs > 0 and now >= _pendingClickAtMs then
        _pendingClickAtMs = 0
        if autoAcceptEnabled() then clickYes() end
    end

    -- Fallback poll, throttled to 1Hz wall-clock.
    if (now - _lastPollMs) < POLL_INTERVAL_MS then return end
    _lastPollMs = now

    if not autoAcceptEnabled() then return end
    if isRezDialogOpen() then clickYes() end
end

return M
