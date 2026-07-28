-- Per-character worker status HUD.
-- Answers the question "why isn't this worker acting?" without dropping to a
-- slash command. One row per registered worker on THIS character; no
-- cross-character rollup — each character owns its own overlay.
--
-- Data source: sk_coordinator's local state snapshot (moduleDiag), which is
-- refreshed by every sk:hb heartbeat this character's workers send. Zero new
-- actor sends: idleReason, idleSinceAt, and lastActionAt piggyback on the
-- existing HEARTBEAT cadence.

local mq = require('mq')
local imgui = require('ImGui')
local lazy = require('sidekick-next.utils.lazy_require')

local M = {}

M.open = false
M._showWindow = false
M._registered = false

local _lastRenderErrorAt = 0

local getLib = lazy('sidekick-next.sk_lib')
local getCoordinatorDebug = lazy('sidekick-next.ui.coordinator_debug')
local getCore = lazy('sidekick-next.utils.core')

-- Age thresholds (ms) for the traffic-light color.
local IDLE_WARN_MS = 2000    -- yellow: idle-with-reason > this
local HEARTBEAT_STALE_MS = 5000  -- red: heartbeat older than this

local function nowMs()
    return math.floor((mq.gettime and mq.gettime()) or (os.clock() * 1000))
end

local function fmtAge(ms)
    ms = tonumber(ms) or 0
    if ms <= 0 then return '-' end
    if ms < 1000 then return string.format('%dms', ms) end
    if ms < 60000 then return string.format('%.1fs', ms / 1000) end
    return string.format('%dm%02ds', math.floor(ms / 60000), math.floor((ms % 60000) / 1000))
end

-- Returns r, g, b, a for a worker row based on its heartbeat and idle age.
-- Green: currently owns the lease or completed an action recently.
-- Yellow: idle > IDLE_WARN_MS with a reason (worker is running, just gated).
-- Red: heartbeat missing / stale > HEARTBEAT_STALE_MS (worker is silent).
-- Neutral: healthy heartbeat without current or recent activity.
local function statusColor(diag, heartbeatSeen, hbAgeMs, idleAgeMs,
        actionAgeMs, ownsLease)
    if not diag or not heartbeatSeen or not diag.ready then
        return 0.85, 0.35, 0.35, 1.0  -- red
    end
    if hbAgeMs > HEARTBEAT_STALE_MS then
        return 0.85, 0.35, 0.35, 1.0  -- red
    end
    if ownsLease then
        return 0.50, 0.85, 0.50, 1.0  -- green: currently acting
    end
    if actionAgeMs < IDLE_WARN_MS and actionAgeMs > 0 then
        return 0.50, 0.85, 0.50, 1.0  -- green: fresh action
    end
    if idleAgeMs > IDLE_WARN_MS and (diag.idleReason or '') ~= '' then
        return 0.90, 0.80, 0.35, 1.0  -- yellow: idle with reason
    end
    return 0.75, 0.75, 0.75, 1.0  -- neutral: fresh heartbeat, no signal either way
end

local function renderRows()
    local lib = getLib()
    if not lib or not lib.WorkerRegistry then
        imgui.TextColored(0.7, 0.7, 0.7, 1, 'sk_lib not available')
        return
    end
    local dbg = getCoordinatorDebug()
    local state = dbg and dbg.getLastState and dbg.getLastState() or nil
    local diagMap = state and state.moduleDiag or nil
    if not diagMap then
        imgui.TextColored(0.7, 0.7, 0.7, 1, 'No coordinator state yet')
        return
    end
    local now = nowMs()

    if not imgui.BeginTable('worker_status_hud', 4,
        (ImGuiTableFlags.Borders or 0) + (ImGuiTableFlags.RowBg or 0)
        + (ImGuiTableFlags.SizingStretchProp or 0)) then
        return
    end
    local tableOk, tableError = xpcall(function()
    imgui.TableSetupColumn('Worker', ImGuiTableColumnFlags.WidthFixed or 0, 90)
    imgui.TableSetupColumn('State', ImGuiTableColumnFlags.WidthFixed or 0, 50)
    imgui.TableSetupColumn('Last Action', ImGuiTableColumnFlags.WidthFixed or 0, 70)
    imgui.TableSetupColumn('Idle Reason', ImGuiTableColumnFlags.WidthStretch or 0)
    imgui.TableHeadersRow()

    for _, spec in ipairs(lib.WorkerRegistry) do
        local diag = diagMap[spec.module]
        local heartbeatSeen = diag
            and tostring(diag.workerSessionId or '') ~= ''
        local hbAge = diag and tonumber(diag.heartbeatAge) or math.huge
        local actionAt = diag and tonumber(diag.lastActionAt) or 0
        local actionAge = actionAt > 0 and math.max(0, now - actionAt) or math.huge
        local idleReason = diag and tostring(diag.idleReason or '') or ''
        local idleSinceAt = diag and tonumber(diag.idleSinceAt) or 0
        local idleAge = idleSinceAt > 0
            and math.max(0, now - idleSinceAt) or 0
        local lease = state and state.lease or nil
        local ownsLease = heartbeatSeen and lease
            and tostring(lease.holderModule or '') == tostring(spec.module)
        local intentActive = heartbeatSeen and diag.intentActive == true
        local isQueued = heartbeatSeen
            and (diag.requestId ~= nil or intentActive)
            and not ownsLease
        local r, g, b, a = statusColor(diag, heartbeatSeen, hbAge,
            idleAge, actionAge, ownsLease)

        imgui.TableNextRow()
        imgui.TableNextColumn()
        imgui.TextColored(r, g, b, a, spec.module)

        imgui.TableNextColumn()
        local label = 'gone'
        if heartbeatSeen then
            if hbAge > HEARTBEAT_STALE_MS then
                label = 'stale'
            elseif not diag.ready then
                label = 'not ready'
            elseif ownsLease then
                label = 'active'
            elseif isQueued then
                label = 'queued'
            elseif actionAge < IDLE_WARN_MS and actionAge > 0 then
                label = 'recent'
            elseif idleReason ~= '' then
                label = 'idle'
            else
                label = 'ok'
            end
        end
        imgui.TextColored(r, g, b, a, label)

        imgui.TableNextColumn()
        imgui.Text(actionAt > 0 and fmtAge(actionAge) or '-')

        imgui.TableNextColumn()
        imgui.Text(idleReason == '' and '-' or idleReason)
    end
    end, debug.traceback)
    imgui.EndTable()
    if not tableOk then error(tableError, 0) end
end

function M.render()
    local Core = getCore()
    if not Core or Core.Settings.WorkerStatusHUDVisible ~= true then return end
    if not M.open then M.open = true end

    imgui.SetNextWindowSize(420, 260, ImGuiCond.FirstUseEver or 0)
    M.open, M._showWindow = imgui.Begin('SideKick Worker Status', M.open,
        ImGuiWindowFlags.None or 0)
    local renderOk, renderError = true, nil
    if M._showWindow then
        renderOk, renderError = xpcall(renderRows, debug.traceback)
    end
    imgui.End()

    if not renderOk then
        local now = nowMs()
        if (now - _lastRenderErrorAt) >= 5000 then
            _lastRenderErrorAt = now
            print(string.format(
                '\ar[SideKick Worker HUD]\ax Render failed: %s',
                tostring(renderError)))
        end
    end

    -- Closing the window from the [X] should also flip the setting off, so
    -- the HUD doesn't silently re-open on next frame.
    if not M.open and Core.set then
        Core.set('WorkerStatusHUDVisible', false, { source = 'hud_close' })
    end
end

function M.init()
    if M._registered then return true end
    if not mq.imgui or type(mq.imgui.init) ~= 'function' then
        return false
    end
    mq.imgui.init('SideKickWorkerStatus', M.render)
    M._registered = true
    return true
end

function M.toggle()
    local Core = getCore()
    if Core and Core.set then
        Core.set('WorkerStatusHUDVisible',
            not (Core.Settings.WorkerStatusHUDVisible == true),
            { source = 'hud_toggle' })
    end
end

return M
