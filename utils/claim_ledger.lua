-- Persistent ledger of actor-coordinated claim/landed events.
-- Tallies per-peer counts for cures, debuffs, mez, heals, buffs across the
-- current session, and persists prior sessions to disk for historical review.
--
-- Categories tracked:
--   cc_claim, debuff_claim, debuff_landed,
--   heal_claim, heal_landed, heal_cancelled,
--   buff_claim, buff_landed, cure_claim, cure_landed
--
-- Wiring: actors_coordinator.lua calls M.record(from, category) from both the
-- broadcast() send path (for self-fired claims) and the dispatcher (for
-- received remote claims).
--
-- UI: M.draw() renders a per-category stacked bar with per-peer slices and a
-- session-history selector. Embed inside a settings tab.

local mq = require('mq')
local lazy = require('sidekick-next.utils.lazy_require')
local getPaths = lazy('sidekick-next.utils.paths')
local SafeLoad = require('sidekick-next.utils.safe_load')

local M = {}

local _dirReady = false
local function ensureDirOnce()
    if _dirReady then return end
    local Paths = getPaths()
    local dir = (mq.configDir or 'config') .. '/SideKick'
    if Paths and Paths.ensureDir then
        Paths.ensureDir(dir)
    else
        os.execute('mkdir "' .. dir .. '" 2>nul')
    end
    _dirReady = true
end

local CATEGORIES = {
    'cc_claim',
    'debuff_claim', 'debuff_landed',
    'heal_claim', 'heal_landed', 'heal_cancelled',
    'buff_claim', 'buff_landed',
    'cure_claim', 'cure_landed',
}

local CATEGORY_LABELS = {
    cc_claim        = 'Mez Claims',
    debuff_claim    = 'Debuff Claims',
    debuff_landed   = 'Debuffs Landed',
    heal_claim      = 'Heal Claims',
    heal_landed     = 'Heals Landed',
    heal_cancelled  = 'Heals Cancelled',
    buff_claim      = 'Buff Claims',
    buff_landed     = 'Buffs Landed',
    cure_claim      = 'Cure Claims',
    cure_landed     = 'Cures Landed',
}

-- ---------------------------------------------------------------------------
-- Storage
-- ---------------------------------------------------------------------------

local SAVE_INTERVAL = 30           -- seconds between throttled disk saves
local MAX_HISTORY = 20             -- keep the last N sessions
local _lastSaveAt = 0
local _dirty = false

M.session = {
    startedAt = os.time(),
    counts = {},                   -- counts[from][category] = number
}
M.history = {}                     -- list of { startedAt, endedAt, counts }

local function getPath()
    local server = (mq.TLO.EverQuest and mq.TLO.EverQuest.Server and mq.TLO.EverQuest.Server()) or 'unknown'
    local char = (mq.TLO.Me and mq.TLO.Me.CleanName and mq.TLO.Me.CleanName()) or 'unknown'
    local dir = (mq.configDir or 'config') .. '/SideKick'
    ensureDirOnce()
    return string.format('%s/claim_ledger_%s_%s.lua', dir, server, char)
end

local function escapeString(s)
    return tostring(s):gsub('\\', '\\\\'):gsub('"', '\\"'):gsub('\n', '\\n'):gsub('\r', '\\r')
end

local function serialize(tbl, indent)
    indent = indent or ''
    local lines = { '{' }
    for k, v in pairs(tbl) do
        local key
        if type(k) == 'number' then
            key = '[' .. k .. ']'
        else
            key = '["' .. escapeString(k) .. '"]'
        end
        if type(v) == 'table' then
            table.insert(lines, indent .. '  ' .. key .. ' = ' .. serialize(v, indent .. '  ') .. ',')
        elseif type(v) == 'number' then
            table.insert(lines, indent .. '  ' .. key .. ' = ' .. tostring(v) .. ',')
        elseif type(v) == 'boolean' then
            table.insert(lines, indent .. '  ' .. key .. ' = ' .. tostring(v) .. ',')
        else
            table.insert(lines, indent .. '  ' .. key .. ' = "' .. escapeString(v) .. '",')
        end
    end
    table.insert(lines, indent .. '}')
    return table.concat(lines, '\n')
end

function M.load()
    local path = getPath()
    local f = io.open(path, 'r')
    if not f then return end
    local content = f:read('*all')
    f:close()
    if not content or content == '' then return end

    local data = SafeLoad.tableLiteral(content, path)
    if type(data) ~= 'table' then return end

    M.history = data.history or {}
    -- Don't restore an in-progress session — it will be initialized fresh. The
    -- previous "session" if present gets archived into history on next save.
    if data.session and data.session.counts and next(data.session.counts) then
        local prev = data.session
        prev.endedAt = prev.endedAt or os.time()
        table.insert(M.history, 1, prev)
        if #M.history > MAX_HISTORY then
            for i = #M.history, MAX_HISTORY + 1, -1 do M.history[i] = nil end
        end
    end
end

function M.save()
    if not _dirty then return end
    local safeWrite = require('sidekick-next.utils.safe_write')
    local payload = { session = M.session, history = M.history }
    local content = serialize(payload)
    local ok, err = safeWrite(getPath(), content)
    if ok then
        _dirty = false
        _lastSaveAt = os.time()
    else
        print(string.format('\ar[ClaimLedger]\ax save failed: %s', tostring(err)))
    end
end

--- Tick from the main loop. Throttled save.
function M.tick()
    local now = os.time()
    if _dirty and (now - _lastSaveAt) >= SAVE_INTERVAL then
        M.save()
    end
end

--- Force-archive the current session and start a new one.
function M.startNewSession()
    if M.session.counts and next(M.session.counts) then
        M.session.endedAt = os.time()
        table.insert(M.history, 1, M.session)
        if #M.history > MAX_HISTORY then
            for i = #M.history, MAX_HISTORY + 1, -1 do M.history[i] = nil end
        end
    end
    M.session = { startedAt = os.time(), counts = {} }
    _dirty = true
    M.save()
end

-- ---------------------------------------------------------------------------
-- Recording
-- ---------------------------------------------------------------------------

--- Record a claim/landed event for a given peer.
--- @param from string Peer name
--- @param category string One of CATEGORIES
function M.record(from, category)
    if not from or from == '' then return end
    if not CATEGORY_LABELS[category] then return end
    local row = M.session.counts[from]
    if not row then
        row = {}
        M.session.counts[from] = row
    end
    row[category] = (row[category] or 0) + 1
    _dirty = true
end

-- ---------------------------------------------------------------------------
-- Query
-- ---------------------------------------------------------------------------

function M.getSession() return M.session end
function M.getHistory() return M.history end

local function totalsForBucket(bucket, category)
    local total = 0
    local perPeer = {}
    if not bucket or not bucket.counts then return total, perPeer end
    for peer, row in pairs(bucket.counts) do
        local n = row[category] or 0
        if n > 0 then
            perPeer[peer] = n
            total = total + n
        end
    end
    return total, perPeer
end

-- ---------------------------------------------------------------------------
-- UI
-- ---------------------------------------------------------------------------

-- Stable hash → hue, so the same peer name keeps the same color across draws.
local function peerColor(name)
    local h = 0
    for i = 1, #name do h = (h * 31 + name:byte(i)) % 360 end
    -- Convert HSV (S=0.55, V=0.85) to RGB
    local s, v = 0.55, 0.85
    local hp = h / 60.0
    local c = v * s
    local x = c * (1 - math.abs(hp % 2 - 1))
    local r, g, b = 0, 0, 0
    if hp < 1     then r, g, b = c, x, 0
    elseif hp < 2 then r, g, b = x, c, 0
    elseif hp < 3 then r, g, b = 0, c, x
    elseif hp < 4 then r, g, b = 0, x, c
    elseif hp < 5 then r, g, b = x, 0, c
    else               r, g, b = c, 0, x end
    local m = v - c
    return r + m, g + m, b + m
end

local function formatTimestamp(ts)
    if not ts then return '?' end
    return os.date('%Y-%m-%d %H:%M', ts)
end

local _selectedHistoryIdx = 0   -- 0 = current session

local function countTotalEvents(bucket)
    if not bucket or not bucket.counts then return 0 end
    local n = 0
    for _, row in pairs(bucket.counts) do
        for _, v in pairs(row) do n = n + v end
    end
    return n
end

--- Draw the ledger UI.
--- @param imgui table The imgui module reference
function M.draw(imgui)
    if not imgui then return end

    -- Session selector
    imgui.Text('Session:')
    imgui.SameLine()
    local items = { 'Current' }
    for i, h in ipairs(M.history) do
        items[i + 1] = string.format('%s (%d events)', formatTimestamp(h.startedAt), countTotalEvents(h))
    end

    if imgui.BeginCombo('##claim_session', items[_selectedHistoryIdx + 1] or 'Current') then
        for i, label in ipairs(items) do
            local isSel = (_selectedHistoryIdx == (i - 1))
            if imgui.Selectable(label, isSel) then
                _selectedHistoryIdx = i - 1
            end
        end
        imgui.EndCombo()
    end

    imgui.SameLine()
    if imgui.SmallButton('New Session##claims') then
        M.startNewSession()
        _selectedHistoryIdx = 0
    end

    imgui.Separator()

    local bucket = (_selectedHistoryIdx == 0) and M.session or M.history[_selectedHistoryIdx]
    if not bucket then
        imgui.TextDisabled('No session data.')
        return
    end

    if not bucket.counts or not next(bucket.counts) then
        imgui.TextDisabled('No claim activity recorded yet.')
        return
    end

    local barW = imgui.GetContentRegionAvail()
    if type(barW) == 'table' then barW = barW.x or 400 end
    barW = math.max(200, (tonumber(barW) or 400) - 8)
    local barH = 14

    for _, category in ipairs(CATEGORIES) do
        local total, perPeer = totalsForBucket(bucket, category)
        if total > 0 then
            imgui.Text(string.format('%s  (%d)', CATEGORY_LABELS[category], total))

            -- Sort peers descending by count for stable display
            local sorted = {}
            for peer, n in pairs(perPeer) do sorted[#sorted + 1] = { peer, n } end
            table.sort(sorted, function(a, b) return a[2] > b[2] end)

            local cp = imgui.GetCursorScreenPos()
            local cx, cy
            if type(cp) == 'table' then cx, cy = cp.x or cp[1], cp.y or cp[2]
            else cx, cy = cp, select(2, imgui.GetCursorScreenPos()) end
            local dl = imgui.GetWindowDrawList()
            local x = cx
            for _, e in ipairs(sorted) do
                local peer, n = e[1], e[2]
                local w = barW * (n / total)
                local r, g, b = peerColor(peer)
                local col = IM_COL32(math.floor(r * 255), math.floor(g * 255), math.floor(b * 255), 255)
                dl:AddRectFilled(ImVec2(x, cy), ImVec2(x + w, cy + barH), col)
                x = x + w
            end
            -- Reserve the bar area in layout
            imgui.Dummy(ImVec2(barW, barH))

            -- Legend row
            for _, e in ipairs(sorted) do
                local peer, n = e[1], e[2]
                local r, g, b = peerColor(peer)
                imgui.TextColored(r, g, b, 1.0, string.format('%s: %d (%.0f%%)', peer, n, 100 * n / total))
                imgui.SameLine()
            end
            imgui.NewLine()
            imgui.Spacing()
        end
    end
end

return M
