--- Loading screen overlay for phased module loading.
--- Shows a small progress bar with status text during CLR healing module init.
---
--- Usage:
---   local Loader = require('sidekick-next.ui.loader')
---   -- In imgui render callback:
---   Loader.draw(phase, totalPhases, isComplete)

local imgui = require('ImGui')
local iam = require('ImAnim')

local M = {}

-- Phase labels for the healing module loader
local PHASE_LABELS = {
    [0] = 'Warming up...',
    [1] = 'Loading module...',
    [2] = 'Initializing config...',
    [3] = 'Loading trackers...',
    [4] = 'Loading analytics...',
    [5] = 'Loading proactive engine...',
    [6] = 'Starting UI...',
}

-- State
local _fadeAlpha = 0
local _completedAt = nil
local _dismissed = false
local LINGER_SEC = 1.0
local FADE_SPEED = 4.0  -- alpha per second

--- Draw the loading overlay.
--- @param phase number Current loading phase (0-7)
--- @param totalPhases number Total phases including warmup (typically 7)
--- @param isComplete boolean Whether loading is fully complete
function M.draw(phase, totalPhases, isComplete)
    if _dismissed then return end

    totalPhases = totalPhases or 7

    -- Track completion for linger + fade-out
    if isComplete and not _completedAt then
        _completedAt = os.clock()
    end

    -- Fade out after linger period
    if _completedAt then
        local elapsed = os.clock() - _completedAt
        if elapsed > LINGER_SEC then
            _fadeAlpha = _fadeAlpha - FADE_SPEED * (1.0 / 60.0)  -- approx per-frame
            if _fadeAlpha <= 0 then
                _fadeAlpha = 0
                _dismissed = true
                return
            end
        end
    else
        -- Fade in
        if _fadeAlpha < 1.0 then
            _fadeAlpha = math.min(1.0, _fadeAlpha + FADE_SPEED * (1.0 / 60.0))
        end
    end

    -- Calculate progress and label BEFORE any ImGui state changes
    local progress = math.min(1.0, (phase or 0) / totalPhases)
    local label = isComplete and 'Ready!' or (PHASE_LABELS[phase] or string.format('Phase %d...', phase))

    -- Get viewport size for positioning (before PushStyleVar to avoid stack corruption on error)
    local io = imgui.GetIO()
    local vpW = io and io.DisplaySize and io.DisplaySize.x or 1920
    local vpH = io and io.DisplaySize and io.DisplaySize.y or 1080

    -- All ImGui calls wrapped in pcall to prevent style stack corruption
    local ok, err = pcall(function()
        -- Window setup
        imgui.PushStyleVar(ImGuiStyleVar.WindowRounding, 10)
        imgui.PushStyleVar(ImGuiStyleVar.FrameRounding, 6)
        imgui.PushStyleVar(ImGuiStyleVar.Alpha, _fadeAlpha)

        imgui.SetNextWindowSize(320, 56, ImGuiCond.Always)

        -- Position: upper-right area (offset from top-right corner)
        imgui.SetNextWindowPos(vpW - 340, 20, ImGuiCond.Always)

        local flags = bit32.bor(
            ImGuiWindowFlags.NoTitleBar,
            ImGuiWindowFlags.NoResize,
            ImGuiWindowFlags.NoMove,
            ImGuiWindowFlags.NoScrollbar,
            ImGuiWindowFlags.NoFocusOnAppearing,
            ImGuiWindowFlags.NoBringToFrontOnFocus,
            ImGuiWindowFlags.NoCollapse,
            ImGuiWindowFlags.NoNav
        )

        imgui.Begin('##SKLoader', nil, flags)

        -- Title line
        imgui.TextColored(0.6, 0.8, 1.0, 1.0, 'SideKick')
        imgui.SameLine()
        imgui.TextDisabled(label)

        -- Progress bar
        local barColor = isComplete
            and { 0.2, 0.8, 0.3, 1.0 }   -- green when done
            or  { 0.3, 0.6, 1.0, 1.0 }    -- blue while loading

        imgui.PushStyleColor(ImGuiCol.PlotHistogram, barColor[1], barColor[2], barColor[3], barColor[4])
        imgui.ProgressBar(progress, -1, 18, string.format('%.0f%%', progress * 100))
        imgui.PopStyleColor(1)

        imgui.End()
        imgui.PopStyleVar(3)
    end)

    if not ok then
        -- Emergency cleanup: pop any remaining style vars to prevent stack corruption
        pcall(imgui.PopStyleVar, 3)
        pcall(imgui.End)
    end
end

--- Reset the loader state (for re-use across sessions if needed).
function M.reset()
    _fadeAlpha = 0
    _completedAt = nil
    _dismissed = false
end

return M
