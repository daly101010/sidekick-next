--- Performance Monitor for SideKick
--- Tracks per-module frame time consumption and displays a real-time dashboard.
---
--- Usage:
---   local PerfMonitor = require('sidekick-next.ui.perf_monitor')
---   PerfMonitor.begin('Healing')       -- Start timing a module
---   healingModule.tick()
---   PerfMonitor.finish('Healing')      -- Stop timing
---
---   -- In imgui render callback:
---   PerfMonitor.draw()                 -- Render the dashboard

local imgui = require('ImGui')

local M = {}

-- ============================================================
-- CONFIGURATION
-- ============================================================

local BUFFER_SIZE = 300     -- ~30s at 10ms/tick
local MAX_MODULES = 20      -- Max tracked modules
local UPDATE_INTERVAL = 0.1 -- Stats recalculation interval (seconds)

-- ============================================================
-- STATE
-- ============================================================

local _visible = false
local _enabled = false       -- Only collect data when visible (computed from _visible + _embeddedDrawn)
local _embeddedDrawn = false -- Set true each frame drawContent() is called from settings tab
local _modules = {}          -- { [name] = { times = circular_buf, startClock = nil, current = 0, avg = 0, max = 0, idx = 1 } }
local _moduleOrder = {}      -- Ordered list of module names
local _lastStatsUpdate = 0
local _totalFrameStart = nil
local _totalFrameTimes = nil
local _totalCurrent = 0
local _totalAvg = 0
local _totalMax = 0

-- ============================================================
-- CIRCULAR BUFFER
-- ============================================================

local function newBuffer()
    local buf = { idx = 1, count = 0, data = {} }
    for i = 1, BUFFER_SIZE do buf.data[i] = 0 end
    return buf
end

local function bufferPush(buf, value)
    buf.data[buf.idx] = value
    buf.idx = (buf.idx % BUFFER_SIZE) + 1
    if buf.count < BUFFER_SIZE then buf.count = buf.count + 1 end
end

-- ============================================================
-- TIMING API
-- ============================================================

--- Start timing a named module. Call before the module's tick function.
function M.begin(name)
    if not _enabled then return end

    local mod = _modules[name]
    if not mod then
        if #_moduleOrder >= MAX_MODULES then return end
        mod = { times = newBuffer(), startClock = nil, current = 0, avg = 0, max = 0 }
        _modules[name] = mod
        table.insert(_moduleOrder, name)
    end

    mod.startClock = os.clock()
end

--- Finish timing a named module. Call after the module's tick function.
function M.finish(name)
    if not _enabled then return end

    local mod = _modules[name]
    if not mod or not mod.startClock then return end

    local elapsed = (os.clock() - mod.startClock) * 1000  -- Convert to ms
    mod.startClock = nil
    mod.current = elapsed
    bufferPush(mod.times, elapsed)
end

--- Start timing the total frame (call at beginning of automation tick).
--- Also recomputes _enabled from standalone window visibility and embedded tab activity.
function M.beginFrame()
    -- Recompute enabled state: standalone window visible OR settings tab was drawn last frame
    _enabled = _visible or _embeddedDrawn
    _embeddedDrawn = false  -- Reset; drawContent() will re-set next frame if tab is active

    if not _enabled then return end
    _totalFrameStart = os.clock()
end

--- Finish timing the total frame
function M.finishFrame()
    if not _enabled then return end
    if not _totalFrameStart then return end

    local elapsed = (os.clock() - _totalFrameStart) * 1000
    _totalFrameStart = nil
    _totalCurrent = elapsed

    if not _totalFrameTimes then
        _totalFrameTimes = newBuffer()
    end
    bufferPush(_totalFrameTimes, elapsed)
end

-- ============================================================
-- STATS COMPUTATION
-- ============================================================

local function computeStats(buf)
    if not buf or buf.count == 0 then return 0, 0 end

    local sum = 0
    local maxVal = 0
    local count = buf.count

    for i = 1, count do
        local v = buf.data[i]
        sum = sum + v
        if v > maxVal then maxVal = v end
    end

    return sum / count, maxVal
end

local function updateStats()
    local now = os.clock()
    if now - _lastStatsUpdate < UPDATE_INTERVAL then return end
    _lastStatsUpdate = now

    for _, name in ipairs(_moduleOrder) do
        local mod = _modules[name]
        if mod then
            mod.avg, mod.max = computeStats(mod.times)
        end
    end

    if _totalFrameTimes then
        _totalAvg, _totalMax = computeStats(_totalFrameTimes)
    end
end

-- ============================================================
-- COLOR HELPERS
-- ============================================================

local function timeColor(ms)
    if ms < 1.0 then
        return 0.3, 0.9, 0.3, 1.0  -- green
    elseif ms < 5.0 then
        return 0.9, 0.9, 0.3, 1.0  -- yellow
    else
        return 0.9, 0.3, 0.3, 1.0  -- red
    end
end

-- ============================================================
-- DRAW
-- ============================================================

--- Render the performance monitor content (no window wrapper).
--- Can be embedded inside another window or settings tab.
function M.drawContent()
    _embeddedDrawn = true  -- Signal beginFrame() to enable data collection next tick
    _enabled = true        -- Also enable immediately for this frame's remaining timing calls
    updateStats()

    -- Total frame time header
    imgui.TextColored(0.6, 0.8, 1.0, 1.0, 'Total Frame')
    imgui.SameLine(200)
    local r, g, b, a = timeColor(_totalCurrent)
    imgui.TextColored(r, g, b, a, string.format('%.2f ms', _totalCurrent))
    imgui.SameLine(270)
    imgui.TextDisabled(string.format('avg: %.2f  max: %.1f', _totalAvg, _totalMax))
    imgui.Separator()

    -- Per-module table
    if imgui.BeginTable('##sk_perf_table', 4, ImGuiTableFlags.RowBg) then
        imgui.TableSetupColumn('Module', ImGuiTableColumnFlags.WidthFixed, 120)
        imgui.TableSetupColumn('Current', ImGuiTableColumnFlags.WidthFixed, 70)
        imgui.TableSetupColumn('Avg', ImGuiTableColumnFlags.WidthFixed, 70)
        imgui.TableSetupColumn('Max', ImGuiTableColumnFlags.WidthFixed, 70)
        imgui.TableHeadersRow()

        -- Sort by current time descending for the display
        local sorted = {}
        for _, name in ipairs(_moduleOrder) do
            sorted[#sorted + 1] = name
        end
        table.sort(sorted, function(a, b)
            return (_modules[a].current or 0) > (_modules[b].current or 0)
        end)

        for _, name in ipairs(sorted) do
            local mod = _modules[name]
            if mod then
                imgui.TableNextRow()

                imgui.TableSetColumnIndex(0)
                imgui.Text(name)

                imgui.TableSetColumnIndex(1)
                r, g, b, a = timeColor(mod.current)
                imgui.TextColored(r, g, b, a, string.format('%.2f ms', mod.current))

                imgui.TableSetColumnIndex(2)
                imgui.TextDisabled(string.format('%.2f ms', mod.avg))

                imgui.TableSetColumnIndex(3)
                imgui.TextDisabled(string.format('%.1f ms', mod.max))
            end
        end

        imgui.EndTable()
    end

    -- Visual bar chart
    imgui.Separator()
    imgui.TextDisabled('Frame breakdown:')
    local totalTime = math.max(_totalCurrent, 0.01)
    for _, name in ipairs(_moduleOrder) do
        local mod = _modules[name]
        if mod and mod.current > 0.01 then
            local pct = mod.current / totalTime
            r, g, b, a = timeColor(mod.current)
            imgui.PushStyleColor(ImGuiCol.PlotHistogram, r, g, b, a)
            imgui.ProgressBar(pct, -1, 14, string.format('%s: %.1fms', name, mod.current))
            imgui.PopStyleColor(1)
        end
    end
end

--- Draw the standalone performance monitor window.
function M.draw()
    if not _visible then return end

    imgui.SetNextWindowSize(360, 300, ImGuiCond.FirstUseEver)
    local draw
    _visible, draw = imgui.Begin('SideKick Performance##sk_perf', _visible)
    if not _visible then
        imgui.End()
        return
    end

    if draw then
        M.drawContent()
    end

    imgui.End()
end

--- Toggle standalone window visibility.
--- Data collection state is recomputed in beginFrame() from all sources.
function M.toggle()
    _visible = not _visible
end

--- Check if the monitor is active (collecting data)
function M.isActive()
    return _enabled
end

--- Reset all collected data
function M.reset()
    _modules = {}
    _moduleOrder = {}
    _totalFrameTimes = nil
    _totalCurrent = 0
    _totalAvg = 0
    _totalMax = 0
end

return M
