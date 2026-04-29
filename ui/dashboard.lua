-- SideKick Dashboard
--
-- Real-time tree view of every orchestrated module. Read-only — no actions
-- are triggered by drawing this window. Each top-level group is a tree node
-- containing one or more sub-panels that pull live state from a public API.
--
-- Adding a new panel:
--   table.insert(M.panels[<group>], { name = '...', draw = function() ... end })
-- Or call M.register(group, name, drawFn).
--
-- Toggle via slash command `/skdash` (and the legacy `/skhealpreview` alias).
-- Visibility persists in Core.Settings.DashboardVisible.

local mq = require('mq')
local imgui = require('ImGui')

local M = {}

-- ---------------------------------------------------------------------------
-- Lazy module refs (avoid circular requires at load time)
-- ---------------------------------------------------------------------------
local function lazy(path)
    local cached = nil
    return function()
        if cached == nil then
            local ok, mod = pcall(require, path)
            cached = ok and mod or false
        end
        return cached or nil
    end
end

local Mods = {
    Core            = lazy('sidekick-next.utils.core'),
    Healing         = lazy('sidekick-next.healing'),
    HealSelector    = lazy('sidekick-next.healing.heal_selector'),
    HealTracker     = lazy('sidekick-next.healing.heal_tracker'),
    TargetMonitor   = lazy('sidekick-next.healing.target_monitor'),
    IncomingHeals   = lazy('sidekick-next.healing.incoming_heals'),
    CombatAssessor  = lazy('sidekick-next.healing.combat_assessor'),
    Proactive       = lazy('sidekick-next.healing.proactive'),
    Actors          = lazy('sidekick-next.utils.actors_coordinator'),
    BuffMod         = lazy('sidekick-next.automation.buff'),
    BuffRequests    = lazy('sidekick-next.utils.buff_requests'),
    Cures           = lazy('sidekick-next.automation.cures'),
    Debuff          = lazy('sidekick-next.automation.debuff'),
    CC              = lazy('sidekick-next.automation.cc'),
    Chase           = lazy('sidekick-next.automation.chase'),
    Assist          = lazy('sidekick-next.automation.assist'),
    Positioning     = lazy('sidekick-next.utils.positioning'),
    CombatAssist    = lazy('sidekick-next.utils.combatassist'),
    RotationEngine  = lazy('sidekick-next.utils.rotation_engine'),
    SpellEngine     = lazy('sidekick-next.utils.spell_engine'),
    SpellEvents     = lazy('sidekick-next.utils.spell_events'),
    SpellRotation   = lazy('sidekick-next.utils.spell_rotation'),
    ResistLog       = lazy('sidekick-next.utils.resist_log'),
    ClaimLedger     = lazy('sidekick-next.utils.claim_ledger'),
    RuntimeCache    = lazy('sidekick-next.utils.runtime_cache'),
}

-- ---------------------------------------------------------------------------
-- Throttled cache for the heal-decision query (only expensive read)
-- ---------------------------------------------------------------------------
local QUERY_INTERVAL = 0.25
local _lastQueryAt = 0
local _cachedAction, _cachedActionReason, _cachedQueryError

local function refreshHealCache()
    local now = os.clock()
    if (now - _lastQueryAt) < QUERY_INTERVAL then return end
    _lastQueryAt = now

    local Healing = Mods.Healing()
    if not Healing or not Healing.buildHealAction then
        _cachedAction, _cachedActionReason = nil, 'healing module not loaded'
        return
    end
    local ok, action, reason = pcall(Healing.buildHealAction, {
        skipIfCasting = false, requireCanHeal = false,
    })
    if not ok then
        _cachedQueryError = tostring(action)
        _cachedAction = nil
        return
    end
    _cachedQueryError = nil
    _cachedAction, _cachedActionReason = action, reason
end

-- ---------------------------------------------------------------------------
-- Visibility
-- ---------------------------------------------------------------------------
function M.isVisible()
    local Core = Mods.Core()
    -- Honor either the new DashboardVisible setting or the legacy alias
    return Core and Core.Settings and
        (Core.Settings.DashboardVisible == true or Core.Settings.HealPreviewVisible == true)
end

function M.setVisible(v)
    local Core = Mods.Core()
    if not Core or not Core.Settings then return end
    local visible = v and true or false
    if Core.set then
        Core.set('DashboardVisible', visible)
        Core.set('HealPreviewVisible', visible)
    else
        Core.Settings.DashboardVisible = visible
        Core.Settings.HealPreviewVisible = visible
    end
end

function M.toggle() M.setVisible(not M.isVisible()) end

-- ---------------------------------------------------------------------------
-- Helpers
-- ---------------------------------------------------------------------------

local function tierColor(tier)
    if tier == 'emergency' then return 1.0, 0.35, 0.35
    elseif tier == 'priority' then return 1.0, 0.7, 0.3
    elseif tier == 'group' or tier == 'groupHot' then return 0.4, 0.85, 1.0
    elseif tier == 'hot' then return 0.6, 1.0, 0.6
    end
    return 0.85, 0.85, 0.85
end

local function spawnName(id)
    local n = tonumber(id)
    if not n or n == 0 then return tostring(id) end
    local sp = mq.TLO.Spawn(n)
    if sp and sp() and sp.CleanName then
        local cn = sp.CleanName()
        if cn and cn ~= '' then return cn end
    end
    return tostring(n)
end

local function safeText(label, value)
    imgui.TextDisabled(tostring(label))
    imgui.SameLine(180)
    imgui.Text(tostring(value))
end

local function boolColor(v)
    if v then return 0.6, 1.0, 0.6
    else return 0.7, 0.7, 0.7 end
end

local function safeBool(label, v)
    imgui.TextDisabled(tostring(label))
    imgui.SameLine(180)
    local r, g, b = boolColor(v)
    imgui.TextColored(r, g, b, 1.0, tostring(v == true))
end

local function isEmpty(t)
    if type(t) ~= 'table' then return true end
    for _ in pairs(t) do return false end
    return true
end

local function ttlSec(absEpoch)
    local n = tonumber(absEpoch) or 0
    if n == 0 then return '?' end
    local diff = n - os.time()
    return string.format('%ds', diff)
end

-- ---------------------------------------------------------------------------
-- Panel registry
-- ---------------------------------------------------------------------------
M.GROUPS = {
    'Overview',
    'Healing',
    'Coordination',
    'Buffs',
    'Cures',
    'Debuffs',
    'CC',
    'Rotation',
    'Movement',
    'Diagnostics',
}
M.panels = {}
for _, g in ipairs(M.GROUPS) do M.panels[g] = {} end

function M.register(group, name, drawFn)
    if not M.panels[group] then
        table.insert(M.GROUPS, group)
        M.panels[group] = {}
    end
    table.insert(M.panels[group], { name = name, draw = drawFn })
end

-- ---------------------------------------------------------------------------
-- Panels: OVERVIEW (compact summary of everything)
-- ---------------------------------------------------------------------------

M.register('Overview', 'Self', function()
    local me = mq.TLO.Me
    if not me or not me() then imgui.TextDisabled('No character'); return end
    safeText('Name', me.CleanName())
    safeText('Class', (me.Class and me.Class.ShortName and me.Class.ShortName()) or '?')
    safeText('Level', tostring(me.Level() or 0))
    safeText('Zone', (mq.TLO.Zone and mq.TLO.Zone.ShortName and mq.TLO.Zone.ShortName()) or '?')
    safeText('HP/Mana/End', string.format('%d%% / %d%% / %d%%',
        tonumber(me.PctHPs()) or 0, tonumber(me.PctMana()) or 0, tonumber(me.PctEndurance()) or 0))
    local target = mq.TLO.Target
    safeText('Target', (target and target() and target.CleanName and target.CleanName()) or 'none')
end)

M.register('Overview', 'Module Status', function()
    local function modRow(label, mod, key)
        local on
        if type(key) == 'function' then
            local ok, v = pcall(key)
            on = ok and v == true
        elseif key and mod then
            on = mod[key] == true
        end
        imgui.TextDisabled(label)
        imgui.SameLine(180)
        if on then imgui.TextColored(0.6, 1.0, 0.6, 1.0, 'ON')
        else imgui.TextColored(0.6, 0.6, 0.6, 1.0, 'off') end
    end
    local Core = Mods.Core()
    local s = Core and Core.Settings or {}
    modRow('Healing',    nil, function() return s.DoHeals == true end)
    modRow('Buffing',    nil, function() return s.BuffingEnabled == true end)
    modRow('Cures',      nil, function() return s.DoCures == true end)
    modRow('Debuffs',    nil, function() return s.DoDebuffs == true end)
    modRow('CC (mez)',   nil, function() return s.MezzingEnabled == true end)
    modRow('Assist',     nil, function() return s.AssistEnabled == true end)
    modRow('Chase',      nil, function() return s.ChaseEnabled == true end)
    modRow('Positioning',nil, function() return s.PositioningEnabled == true end)
end)

-- ---------------------------------------------------------------------------
-- Panels: HEALING
-- ---------------------------------------------------------------------------

-- Parse a `details` string from heal_selector. Format is pipe-separated
-- segments, each segment is whitespace-separated key=value pairs:
--   "trigger=efficient category=single eff=12.34 net=200.0 | trigger=emergency"
-- Returns a list of segments, each a list of {key, value} pairs.
local function parseDetails(s)
    if type(s) ~= 'string' or s == '' then return {} end
    local segments = {}
    for seg in string.gmatch(s, '([^|]+)') do
        local trimmed = (seg:gsub('^%s+', ''):gsub('%s+$', ''))
        if trimmed ~= '' then
            local pairs_list = {}
            for token in string.gmatch(trimmed, '%S+') do
                local k, v = string.match(token, '^([^=]+)=(.*)$')
                if k then table.insert(pairs_list, { k, v })
                else table.insert(pairs_list, { token, '' }) end
            end
            table.insert(segments, pairs_list)
        end
    end
    return segments
end

M.register('Healing', 'Decision', function()
    if _cachedQueryError then
        imgui.TextColored(1.0, 0.4, 0.4, 1.0, 'Error: ' .. _cachedQueryError); return
    end
    local action = _cachedAction
    if not action then
        imgui.TextDisabled('Idle (no heal target)')
        if _cachedActionReason then imgui.TextDisabled('reason: ' .. tostring(_cachedActionReason)) end
        return
    end
    local r, g, b = tierColor(action.tier)
    imgui.TextColored(r, g, b, 1.0, tostring(action.tier or '?'):upper())
    imgui.SameLine()
    imgui.Text(string.format('-> %s on %s', tostring(action.spellName or '?'), tostring(action.targetName or '?')))
    if action.expected then
        imgui.TextDisabled(string.format('expected: %s%s', tostring(action.expected), action.isHoT and ' (HoT)' or ''))
    end
    if action.reason and action.reason ~= '' then
        imgui.TextDisabled('reason: ' .. tostring(action.reason))
    end

    -- Parsed details: each `|`-separated segment becomes its own row of
    -- key/value chips so a long debug string is actually readable.
    if action.details and action.details ~= '' then
        if imgui.TreeNode('details##healdetails') then
            local segments = parseDetails(action.details)
            for i, seg in ipairs(segments) do
                if #segments > 1 then
                    imgui.TextDisabled(string.format('[%d]', i))
                    imgui.SameLine()
                end
                local first = true
                for _, kv in ipairs(seg) do
                    if not first then imgui.SameLine() end
                    first = false
                    imgui.TextDisabled(kv[1] .. '=')
                    imgui.SameLine(0, 0)
                    imgui.Text(kv[2] ~= '' and kv[2] or '?')
                end
            end
            imgui.TreePop()
        end
    end
end)

M.register('Healing', 'Alternates Considered', function()
    local Sel = Mods.HealSelector()
    local snap = Sel and Sel.getLastScores and Sel.getLastScores() or nil
    if not snap or not snap.scores or #snap.scores == 0 then
        imgui.TextDisabled('No scoring snapshot yet. Trigger a heal pass to populate.')
        return
    end
    safeText('Pass kind', tostring(snap.kind or 'efficient'))
    safeText('Last pass for', string.format('%s (deficit %d)',
        tostring(snap.targetName or '?'), tonumber(snap.deficit) or 0))
    safeText('Winner', string.format('%s (score %.2f)',
        tostring(snap.winner or '-'), tonumber(snap.winnerScore) or 0))
    safeText('Aged', string.format('%ds', os.time() - (snap.at or 0)))

    if imgui.BeginTable('##sk_dash_alts', 6, 0) then
        imgui.TableSetupColumn('')           -- winner indicator
        imgui.TableSetupColumn('Spell')
        imgui.TableSetupColumn('Cat')
        imgui.TableSetupColumn('Score')
        imgui.TableSetupColumn('Expected')
        imgui.TableSetupColumn('Mana / Cast')
        imgui.TableHeadersRow()
        for _, sc in ipairs(snap.scores) do
            imgui.TableNextRow()
            imgui.TableNextColumn()
            if sc.spell == snap.winner then
                imgui.TextColored(0.6, 1.0, 0.6, 1.0, '*')
            else
                imgui.TextDisabled(' ')
            end
            imgui.TableNextColumn(); imgui.Text(tostring(sc.spell or '?'))
            imgui.TableNextColumn(); imgui.Text(tostring(sc.category or '-'))
            imgui.TableNextColumn(); imgui.Text(string.format('%.2f', tonumber(sc.score) or 0))
            imgui.TableNextColumn(); imgui.Text(tostring(tonumber(sc.expected) or 0))
            imgui.TableNextColumn(); imgui.Text(string.format('%d / %.2fs',
                tonumber(sc.mana) or 0, (tonumber(sc.castTime) or 0) / 1000))
        end
        imgui.EndTable()
    end
end)

M.register('Healing', 'Last Cast', function()
    local Sel = Mods.HealSelector()
    local last = Sel and Sel.getLastAction and Sel.getLastAction() or nil
    if last and last.spell and last.spell ~= '' then
        local age = os.time() - (last.time or 0)
        imgui.Text(string.format('%s on %s', tostring(last.spell), tostring(last.target or '?')))
        imgui.TextDisabled(string.format('%ds ago, expected %s', age, tostring(last.expected or '?')))
    else
        imgui.TextDisabled('none')
    end
end)

M.register('Healing', 'Injured Targets', function()
    local TM = Mods.TargetMonitor()
    if not TM or not TM.getInjuredTargets then imgui.TextDisabled('Target monitor unavailable'); return end
    local list = TM.getInjuredTargets(100) or {}
    if #list == 0 then imgui.TextDisabled('All targets healthy'); return end
    if imgui.BeginTable('##sk_dash_injured', 5, 0) then
        imgui.TableSetupColumn('Name'); imgui.TableSetupColumn('Role')
        imgui.TableSetupColumn('HP%'); imgui.TableSetupColumn('Deficit'); imgui.TableSetupColumn('Inc')
        imgui.TableHeadersRow()
        for _, t in ipairs(list) do
            imgui.TableNextRow()
            imgui.TableNextColumn(); imgui.Text(tostring(t.name or '?'))
            imgui.TableNextColumn(); imgui.Text(tostring(t.role or '-'))
            imgui.TableNextColumn(); imgui.Text(tostring(tonumber(t.pctHP) or 0))
            imgui.TableNextColumn(); imgui.Text(tostring(tonumber(t.deficit or 0) or 0))
            imgui.TableNextColumn(); imgui.Text(tostring(tonumber(t.incomingTotal or 0) or 0))
        end
        imgui.EndTable()
    end
end)

M.register('Healing', 'Incoming Heals', function()
    local IH = Mods.IncomingHeals()
    if not IH or not IH.getAll then imgui.TextDisabled('Tracker unavailable'); return end
    local all = IH.getAll() or {}
    if isEmpty(all) then imgui.TextDisabled('No heals in flight'); return end
    local nowMs = mq.gettime()
    if imgui.BeginTable('##sk_dash_inc', 5, 0) then
        imgui.TableSetupColumn('Target'); imgui.TableSetupColumn('Healer')
        imgui.TableSetupColumn('Spell'); imgui.TableSetupColumn('Expected'); imgui.TableSetupColumn('Lands')
        imgui.TableHeadersRow()
        for tid, perH in pairs(all) do
            for hid, data in pairs(perH) do
                imgui.TableNextRow()
                imgui.TableNextColumn(); imgui.Text(spawnName(tid))
                imgui.TableNextColumn(); imgui.Text(spawnName(hid))
                imgui.TableNextColumn(); imgui.Text(tostring(data.spellName or '?'))
                imgui.TableNextColumn(); imgui.Text(tostring(tonumber(data.expectedAmount) or 0))
                local landsIn = ((tonumber(data.landsAt) or 0) - nowMs) / 1000
                imgui.TableNextColumn()
                if landsIn > 0 then imgui.Text(string.format('+%.1fs', landsIn))
                else imgui.TextColored(0.7,0.7,0.7,1.0, string.format('%.1fs late', -landsIn)) end
            end
        end
        imgui.EndTable()
    end
end)

M.register('Healing', 'Active HoTs', function()
    local A = Mods.Actors()
    if not A or not A.getHoTStates then imgui.TextDisabled('Coordinator unavailable'); return end
    local hots = A.getHoTStates() or {}
    if isEmpty(hots) then imgui.TextDisabled('No active HoTs'); return end
    if imgui.BeginTable('##sk_dash_hots', 4, 0) then
        imgui.TableSetupColumn('Target'); imgui.TableSetupColumn('Healer')
        imgui.TableSetupColumn('Spell'); imgui.TableSetupColumn('TTL')
        imgui.TableHeadersRow()
        for tid, perFrom in pairs(hots) do
            for healer, perSpell in pairs(perFrom) do
                if type(perSpell) == 'table' then
                    for sname, info in pairs(perSpell) do
                        imgui.TableNextRow()
                        imgui.TableNextColumn(); imgui.Text(spawnName(tid))
                        imgui.TableNextColumn(); imgui.Text(tostring(healer))
                        imgui.TableNextColumn(); imgui.Text(tostring(sname))
                        imgui.TableNextColumn(); imgui.Text(ttlSec(info and info.expiresAt))
                    end
                end
            end
        end
        imgui.EndTable()
    end
end)

M.register('Healing', 'Combat Assessor', function()
    local CA = Mods.CombatAssessor()
    if not CA or not CA.getState then imgui.TextDisabled('Combat assessor unavailable'); return end
    local s = CA.getState() or {}
    safeBool('In combat', s.inCombat)
    safeText('Phase', tostring(s.fightPhase or 'none'))
    safeBool('Survival mode', s.survivalMode)
    safeBool('High pressure', s.highPressure)
    safeText('Active mobs', string.format('%d (mezzed %d)', s.activeMobCount or 0, s.mezzedMobCount or 0))
    safeText('Avg mob HP', string.format('%d%%', tonumber(s.avgMobHP) or 0))
    safeText('Estimated TTK', string.format('%ds', tonumber(s.estimatedTTK) or 0))
    safeText('Incoming DPS', tostring(tonumber(s.totalIncomingDps) or 0))
    safeText('Tank DPS%', string.format('%.0f%%', tonumber(s.tankDpsPct) or 0))
    safeBool('Named mob', s.hasNamedMob)
    safeBool('Raid mob', s.hasRaidMob)
    safeText('Difficulty', tostring(s.mobDifficultyTier or 'normal'))
    safeText('Mob DPS x', string.format('%.2f', tonumber(s.mobDpsMultiplier) or 1.0))
    safeText('Overheal % / Throttle',
        string.format('%.0f%%  /  %.2f', tonumber(s.fightOverhealPct) or 0, tonumber(s.throttleLevel) or 0))
end)

-- ---------------------------------------------------------------------------
-- Panels: COORDINATION
-- ---------------------------------------------------------------------------

M.register('Coordination', 'Peer Roster', function()
    local A = Mods.Actors()
    if not A or not A.getRemoteCharacters then imgui.TextDisabled('No coordinator'); return end
    local peers = A.getRemoteCharacters() or {}
    if isEmpty(peers) then imgui.TextDisabled('No peers seen'); return end
    if imgui.BeginTable('##sk_dash_peers', 6, 0) then
        imgui.TableSetupColumn('Name'); imgui.TableSetupColumn('Class'); imgui.TableSetupColumn('Zone')
        imgui.TableSetupColumn('HP%'); imgui.TableSetupColumn('Mana%'); imgui.TableSetupColumn('Seen')
        imgui.TableHeadersRow()
        for name, p in pairs(peers) do
            imgui.TableNextRow()
            imgui.TableNextColumn(); imgui.Text(tostring(name))
            imgui.TableNextColumn(); imgui.Text(tostring(p.class or '?'))
            imgui.TableNextColumn(); imgui.Text(tostring(p.zone or '?'))
            imgui.TableNextColumn(); imgui.Text(tostring(tonumber(p.hp) or 0))
            imgui.TableNextColumn(); imgui.Text(tostring(tonumber(p.mana) or 0))
            local age = os.clock() - (tonumber(p.lastSeen) or 0)
            imgui.TableNextColumn(); imgui.Text(string.format('%.0fs', age))
        end
        imgui.EndTable()
    end
end)

M.register('Coordination', 'Heal Claims', function()
    local A = Mods.Actors()
    if not A or not A.getHealClaims then imgui.TextDisabled('Coordinator unavailable'); return end
    local claims = A.getHealClaims() or {}
    if isEmpty(claims) then imgui.TextDisabled('No active heal claims'); return end
    if imgui.BeginTable('##sk_dash_hclaims', 5, 0) then
        imgui.TableSetupColumn('Target'); imgui.TableSetupColumn('Healer')
        imgui.TableSetupColumn('Spell'); imgui.TableSetupColumn('Tier'); imgui.TableSetupColumn('TTL')
        imgui.TableHeadersRow()
        for tid, perFrom in pairs(claims) do
            for healer, claim in pairs(perFrom) do
                imgui.TableNextRow()
                imgui.TableNextColumn(); imgui.Text(spawnName(tid))
                imgui.TableNextColumn(); imgui.Text(tostring(healer))
                imgui.TableNextColumn(); imgui.Text(tostring(claim.spellName or '?'))
                imgui.TableNextColumn(); imgui.Text(tostring(claim.tier or '?'))
                imgui.TableNextColumn(); imgui.Text(ttlSec(claim.expiresAt))
            end
        end
        imgui.EndTable()
    end
end)

M.register('Coordination', 'Buff Requests', function()
    local R = Mods.BuffRequests()
    if not R or not R.getAll then imgui.TextDisabled('Module unavailable'); return end
    local all = R.getAll() or {}
    if isEmpty(all) then imgui.TextDisabled('No pending requests'); return end
    if imgui.BeginTable('##sk_dash_breq', 5, 0) then
        imgui.TableSetupColumn('Target'); imgui.TableSetupColumn('Category')
        imgui.TableSetupColumn('From'); imgui.TableSetupColumn('Urgency'); imgui.TableSetupColumn('TTL')
        imgui.TableHeadersRow()
        for tid, perCat in pairs(all) do
            for cat, req in pairs(perCat) do
                imgui.TableNextRow()
                imgui.TableNextColumn(); imgui.Text(spawnName(tid))
                imgui.TableNextColumn(); imgui.Text(tostring(cat))
                imgui.TableNextColumn(); imgui.Text(tostring(req.from or '?'))
                imgui.TableNextColumn()
                if req.urgency == 'high' then imgui.TextColored(1,0.7,0.3,1,'high')
                else imgui.Text(tostring(req.urgency or 'normal')) end
                imgui.TableNextColumn(); imgui.Text(ttlSec(req.expiresAt))
            end
        end
        imgui.EndTable()
    end
end)

M.register('Coordination', 'Claim Ledger (this session)', function()
    local L = Mods.ClaimLedger()
    if not L or not L.getSession then imgui.TextDisabled('Module unavailable'); return end
    local s = L.getSession()
    if not s or isEmpty(s.counts) then imgui.TextDisabled('No claims recorded yet'); return end
    if imgui.BeginTable('##sk_dash_ledger', 4, 0) then
        imgui.TableSetupColumn('Peer'); imgui.TableSetupColumn('Heal'); imgui.TableSetupColumn('Cure'); imgui.TableSetupColumn('Other')
        imgui.TableHeadersRow()
        for peer, row in pairs(s.counts) do
            local heal = (row.heal_claim or 0) + (row.heal_landed or 0)
            local cure = (row.cure_claim or 0) + (row.cure_landed or 0)
            local other = (row.cc_claim or 0) + (row.debuff_claim or 0) + (row.debuff_landed or 0)
                + (row.buff_claim or 0) + (row.buff_landed or 0) + (row.heal_cancelled or 0)
            imgui.TableNextRow()
            imgui.TableNextColumn(); imgui.Text(tostring(peer))
            imgui.TableNextColumn(); imgui.Text(tostring(heal))
            imgui.TableNextColumn(); imgui.Text(tostring(cure))
            imgui.TableNextColumn(); imgui.Text(tostring(other))
        end
        imgui.EndTable()
    end
end)

-- ---------------------------------------------------------------------------
-- Panels: BUFFS
-- ---------------------------------------------------------------------------

M.register('Buffs', 'Definitions', function()
    local B = Mods.BuffMod()
    if not B or not B.buffDefinitions then imgui.TextDisabled('No buff module'); return end
    if isEmpty(B.buffDefinitions) then imgui.TextDisabled('No definitions loaded'); return end
    if imgui.BeginTable('##sk_dash_bdefs', 3, 0) then
        imgui.TableSetupColumn('Category'); imgui.TableSetupColumn('Spell'); imgui.TableSetupColumn('Priority')
        imgui.TableHeadersRow()
        for cat, def in pairs(B.buffDefinitions) do
            imgui.TableNextRow()
            imgui.TableNextColumn(); imgui.Text(tostring(cat))
            imgui.TableNextColumn(); imgui.Text(tostring(def.spellName or '?'))
            imgui.TableNextColumn(); imgui.Text(tostring(def.priority or 999))
        end
        imgui.EndTable()
    end
end)

M.register('Buffs', 'Local Casts', function()
    local B = Mods.BuffMod()
    if not B or not B.localBuffs then imgui.TextDisabled('No buff module'); return end
    if isEmpty(B.localBuffs) then imgui.TextDisabled('No local buff records'); return end
    local now = os.clock()
    if imgui.BeginTable('##sk_dash_lbuffs', 4, 0) then
        imgui.TableSetupColumn('Target'); imgui.TableSetupColumn('Category')
        imgui.TableSetupColumn('Spell'); imgui.TableSetupColumn('TTL')
        imgui.TableHeadersRow()
        for tid, cats in pairs(B.localBuffs) do
            for cat, data in pairs(cats) do
                imgui.TableNextRow()
                imgui.TableNextColumn(); imgui.Text(spawnName(tid))
                imgui.TableNextColumn(); imgui.Text(tostring(cat))
                imgui.TableNextColumn(); imgui.Text(tostring(data.spellName or '?'))
                imgui.TableNextColumn(); imgui.Text(string.format('%.0fs', (data.expiresAt or 0) - now))
            end
        end
        imgui.EndTable()
    end
end)

M.register('Buffs', 'Remote Casts (peers)', function()
    local B = Mods.BuffMod()
    if not B or not B.remoteBuffs then imgui.TextDisabled('No buff module'); return end
    if isEmpty(B.remoteBuffs) then imgui.TextDisabled('No remote buff records'); return end
    local now = os.clock()
    if imgui.BeginTable('##sk_dash_rbuffs', 4, 0) then
        imgui.TableSetupColumn('Target'); imgui.TableSetupColumn('Category')
        imgui.TableSetupColumn('Caster'); imgui.TableSetupColumn('TTL')
        imgui.TableHeadersRow()
        for tid, cats in pairs(B.remoteBuffs) do
            for cat, data in pairs(cats) do
                imgui.TableNextRow()
                imgui.TableNextColumn(); imgui.Text(spawnName(tid))
                imgui.TableNextColumn(); imgui.Text(tostring(cat))
                imgui.TableNextColumn(); imgui.Text(tostring(data.caster or '?'))
                imgui.TableNextColumn(); imgui.Text(string.format('%.0fs', (data.expiresAt or 0) - now))
            end
        end
        imgui.EndTable()
    end
end)

M.register('Buffs', 'Blocked by Peers', function()
    local B = Mods.BuffMod()
    if not B or not B.remoteBlocks or isEmpty(B.remoteBlocks) then
        imgui.TextDisabled('No remote blocks reported'); return
    end
    for char, blocks in pairs(B.remoteBlocks) do
        local items = {}
        for cat in pairs(blocks) do items[#items+1] = cat end
        table.sort(items)
        imgui.Text(string.format('%s: %s', tostring(char), table.concat(items, ', ')))
    end
end)

-- ---------------------------------------------------------------------------
-- Panels: CURES
-- ---------------------------------------------------------------------------

M.register('Cures', 'Capabilities (self)', function()
    local C = Mods.Cures()
    if not C or not C.getCureCapabilities then imgui.TextDisabled('No cures module'); return end
    local caps = C.getCureCapabilities() or {}
    for _, t in ipairs({'Disease','Poison','Curse','Corruption'}) do
        safeBool(t, caps[t] == true)
    end
end)

M.register('Cures', 'Tracked Debuffs', function()
    local C = Mods.Cures()
    if not C or not C.getTrackedDebuffs then imgui.TextDisabled('No cures module'); return end
    local all = C.getTrackedDebuffs() or {}
    if isEmpty(all) then imgui.TextDisabled('Nothing detected'); return end
    if imgui.BeginTable('##sk_dash_curescan', 3, 0) then
        imgui.TableSetupColumn('Target'); imgui.TableSetupColumn('Type'); imgui.TableSetupColumn('Count')
        imgui.TableHeadersRow()
        for tid, perType in pairs(all) do
            for tname, list in pairs(perType) do
                imgui.TableNextRow()
                imgui.TableNextColumn(); imgui.Text(spawnName(tid))
                imgui.TableNextColumn(); imgui.Text(tostring(tname))
                imgui.TableNextColumn(); imgui.Text(tostring(#list))
            end
        end
        imgui.EndTable()
    end
end)

M.register('Cures', 'Shard Owners', function()
    local C = Mods.Cures()
    if not C or not C._computeShardOwner then imgui.TextDisabled('Sharding helper unavailable'); return end
    local tracked = C.getTrackedDebuffs and C.getTrackedDebuffs() or {}
    if isEmpty(tracked) then imgui.TextDisabled('No active debuffs to shard'); return end
    if imgui.BeginTable('##sk_dash_shard', 4, 0) then
        imgui.TableSetupColumn('Target'); imgui.TableSetupColumn('Type')
        imgui.TableSetupColumn('Owner'); imgui.TableSetupColumn('Capable')
        imgui.TableHeadersRow()
        for tid, perType in pairs(tracked) do
            for tname in pairs(perType) do
                local owner, list = C._computeShardOwner(tid, tname)
                imgui.TableNextRow()
                imgui.TableNextColumn(); imgui.Text(spawnName(tid))
                imgui.TableNextColumn(); imgui.Text(tostring(tname))
                imgui.TableNextColumn(); imgui.Text(tostring(owner or '-'))
                imgui.TableNextColumn(); imgui.Text(tostring(list and #list or 0))
            end
        end
        imgui.EndTable()
    end
end)

-- ---------------------------------------------------------------------------
-- Panels: DEBUFFS
-- ---------------------------------------------------------------------------

M.register('Debuffs', 'Status', function()
    local D = Mods.Debuff()
    if not D then imgui.TextDisabled('No debuff module'); return end
    -- These tables exist as module-level state; print whatever is there.
    local function tableCount(t) local n = 0 for _ in pairs(t or {}) do n = n + 1 end return n end
    if D.localClaims then safeText('Local claims', tableCount(D.localClaims)) end
    if D.remoteClaims then safeText('Remote claims', tableCount(D.remoteClaims)) end
    if D.trackedDebuffs then safeText('Tracked', tableCount(D.trackedDebuffs)) end
end)

-- ---------------------------------------------------------------------------
-- Panels: CC (mez)
-- ---------------------------------------------------------------------------

M.register('CC', 'Status', function()
    local CC = Mods.CC()
    if not CC then imgui.TextDisabled('No cc module'); return end
    if CC.getCounts then
        local ok, counts = pcall(CC.getCounts)
        if ok and type(counts) == 'table' then
            for k, v in pairs(counts) do safeText(tostring(k), tostring(v)) end
        end
    end
    if CC.isMezClass then
        local ok, v = pcall(CC.isMezClass)
        if ok then safeBool('Mez class', v) end
    end
end)

M.register('CC', 'Mezzed Mobs (XTarget)', function()
    local CC = Mods.CC()
    if not CC or not CC.getMezzedOnXTarget then imgui.TextDisabled('Helper unavailable'); return end
    local ok, mobs = pcall(CC.getMezzedOnXTarget)
    if not ok or not mobs or #mobs == 0 then imgui.TextDisabled('None'); return end
    for _, m in ipairs(mobs) do
        imgui.Text(string.format('  - %s (%s)', tostring(m.name or '?'), tostring(m.id or '?')))
    end
end)

-- ---------------------------------------------------------------------------
-- Panels: ROTATION
-- ---------------------------------------------------------------------------

M.register('Rotation', 'Last Tick (per layer)', function()
    local RE = Mods.RotationEngine()
    if not RE or not RE.getLastTickStats then imgui.TextDisabled('No rotation engine'); return end
    local s = RE.getLastTickStats()
    safeText('Tick at', string.format('%.1fs ago', os.clock() - (s.tickAt or 0)))
    safeBool('Spell rotation ran', s.spellRotationRan)
    safeBool('  ↳ deferred (high pri)', s.spellRotationDeferred)
    if s.skipReason then safeText('Skip reason', tostring(s.skipReason)) end
    if not isEmpty(s.layers) then
        if imgui.BeginTable('##sk_dash_layers', 4, 0) then
            imgui.TableSetupColumn('Layer'); imgui.TableSetupColumn('Abilities')
            imgui.TableSetupColumn('Executed'); imgui.TableSetupColumn('Spell attempts')
            imgui.TableHeadersRow()
            for name, st in pairs(s.layers) do
                imgui.TableNextRow()
                imgui.TableNextColumn(); imgui.Text(tostring(name))
                imgui.TableNextColumn(); imgui.Text(tostring(st.abilities or 0))
                imgui.TableNextColumn(); imgui.Text(tostring(st.executed or 0))
                imgui.TableNextColumn(); imgui.Text(tostring(st.spellAttempts or 0))
            end
            imgui.EndTable()
        end
    end
end)

M.register('Rotation', 'Resist Log (current target)', function()
    local R = Mods.ResistLog()
    if not R then imgui.TextDisabled('No resist log'); return end
    if R.isDisabled and R.isDisabled() then
        imgui.TextDisabled('Resist log: DISABLED'); return
    end
    local target = mq.TLO.Target
    local tname = target and target() and target.CleanName and target.CleanName() or ''
    if tname == '' then imgui.TextDisabled('No target'); return end
    safeText('Target', tname)

    if R.iterZone then
        local rows = {}
        for mob, spell, rec in R.iterZone() do
            if mob == tname then rows[#rows+1] = { spell, rec } end
        end
        if #rows == 0 then imgui.TextDisabled('No history for this mob'); return end
        if imgui.BeginTable('##sk_dash_resist', 4, 0) then
            imgui.TableSetupColumn('Spell'); imgui.TableSetupColumn('Casts')
            imgui.TableSetupColumn('Resists'); imgui.TableSetupColumn('Skip?')
            imgui.TableHeadersRow()
            for _, e in ipairs(rows) do
                local spell, rec = e[1], e[2]
                local skip, reason = false, nil
                if R.shouldSkip then skip, reason = R.shouldSkip(spell, tname) end
                imgui.TableNextRow()
                imgui.TableNextColumn(); imgui.Text(tostring(spell))
                imgui.TableNextColumn(); imgui.Text(tostring(rec.casts or 0))
                imgui.TableNextColumn(); imgui.Text(tostring(rec.resists or 0))
                imgui.TableNextColumn()
                if skip then imgui.TextColored(1,0.5,0.4,1, reason or 'skip')
                else imgui.TextDisabled('-') end
            end
            imgui.EndTable()
        end
    end
end)

M.register('Rotation', 'Spell Rotation State', function()
    local SR = Mods.SpellRotation()
    if not SR or not SR.state then imgui.TextDisabled('No spell rotation'); return end
    local cur = SR.state.currentSpell
    if cur then
        safeText('Current spell', tostring(cur.spellName or cur.name or '?'))
        safeText('Retry count', tostring(SR.state.retryCount or 0))
    else
        imgui.TextDisabled('Idle')
    end
end)

M.register('Rotation', 'Spell Engine', function()
    local SE = Mods.SpellEngine()
    if not SE then imgui.TextDisabled('No spell engine'); return end
    if SE.isBusy then
        local ok, busy = pcall(SE.isBusy)
        if ok then safeBool('Busy', busy) end
    end
    local Ev = Mods.SpellEvents()
    if Ev and Ev.getLastResult then
        local res, t = Ev.getLastResult()
        local name = (Ev.getResultName and Ev.getResultName(res)) or tostring(res)
        safeText('Last result', string.format('%s (%.1fs ago)', tostring(name), os.clock() - (t or 0)))
    end
    if Ev and Ev.getLastResistInfo then
        local sp, tg = Ev.getLastResistInfo()
        if sp then safeText('Last resist', string.format('%s on %s', tostring(sp), tostring(tg or '?'))) end
    end
end)

-- ---------------------------------------------------------------------------
-- Panels: MOVEMENT
-- ---------------------------------------------------------------------------

M.register('Movement', 'Chase', function()
    local Ch = Mods.Chase()
    if not Ch then imgui.TextDisabled('No chase module'); return end
    safeBool('Enabled', Ch.enabled)
    local s = Ch.state or {}
    safeText('Role', tostring(s.role or 'none'))
    safeText('Target', tostring(s.target or ''))
    safeText('Distance', tostring(s.distance or 30))
    safeBool('User paused', s.userPaused)
end)

M.register('Movement', 'Assist', function()
    local A = Mods.Assist()
    if not A then imgui.TextDisabled('No assist module'); return end
    safeBool('Enabled', A.enabled)
end)

M.register('Movement', 'Positioning', function()
    local P = Mods.Positioning()
    if not P then imgui.TextDisabled('No positioning module'); return end
    if P.enabled ~= nil then safeBool('Enabled', P.enabled) end
    if P.state then
        for k, v in pairs(P.state) do
            if type(v) ~= 'table' then safeText(tostring(k), tostring(v)) end
        end
    end
end)

-- ---------------------------------------------------------------------------
-- Panels: DIAGNOSTICS
-- ---------------------------------------------------------------------------

M.register('Diagnostics', 'Coordinator', function()
    local A = Mods.Actors()
    if not A or not A.getDebugState then imgui.TextDisabled('No coordinator'); return end
    local s = A.getDebugState() or {}
    safeBool('Actors loaded', s.actors_loaded)
    safeBool('Dropbox ready', s.dropbox_ready)
    safeBool('Docked', s.docked)
    if s.init_error then safeText('Init error', tostring(s.init_error)) end
    if s.last_send_err then safeText('Last send err', tostring(s.last_send_err)) end
    if s.last_send_result then safeText('Last send result', tostring(s.last_send_result)) end
    if s.self then
        safeText('Self', string.format('%s @ %s (%s)',
            tostring(s.self.name), tostring(s.self.server), tostring(s.self.zone)))
    end
    safeText('Last GT msg', string.format('%s (%.1fs ago)',
        tostring(s.last_gt_msg_id or '?'), os.clock() - (s.last_gt_msg_at or 0)))
end)

M.register('Diagnostics', 'Runtime Cache', function()
    local C = Mods.RuntimeCache()
    if not C then imgui.TextDisabled('No runtime cache'); return end
    if C.inCombat then
        local ok, v = pcall(C.inCombat); if ok then safeBool('In combat', v) end
    end
    if C.me then
        if C.me.moving ~= nil then safeBool('Moving', C.me.moving == true) end
    end
end)

-- ---------------------------------------------------------------------------
-- Tree renderer
-- ---------------------------------------------------------------------------
local _filter = ''

local function matchesFilter(s)
    if _filter == nil or _filter == '' then return true end
    return string.find(string.lower(tostring(s)), _filter, 1, true) ~= nil
end

local function drawGroup(group)
    local panels = M.panels[group]
    if not panels or #panels == 0 then return false end

    -- Pre-filter: skip the entire group node if no panel name matches
    local anyMatch = false
    for _, p in ipairs(panels) do
        if matchesFilter(group) or matchesFilter(p.name) then anyMatch = true; break end
    end
    if not anyMatch then return false end

    local opened = imgui.TreeNode(group)
    if opened then
        for _, p in ipairs(panels) do
            if matchesFilter(group) or matchesFilter(p.name) then
                if imgui.TreeNode(p.name .. '##' .. group) then
                    local ok, err = pcall(p.draw)
                    if not ok then
                        imgui.TextColored(1.0, 0.4, 0.4, 1.0, 'panel error: ' .. tostring(err))
                    end
                    imgui.TreePop()
                end
            end
        end
        imgui.TreePop()
    end
    return true
end

function M.draw()
    if not M.isVisible() then return end
    refreshHealCache()

    imgui.SetNextWindowSize(ImVec2(560, 720), 4)  -- ImGuiCond_FirstUseEver = 4
    local open, visible = imgui.Begin('SideKick Dashboard###sk_dashboard', true, 0)
    if not open then M.setVisible(false) end
    if visible then
        local changed
        _filter, changed = imgui.InputText('Filter', _filter, 64)
        if _filter then _filter = string.lower(_filter) end
        imgui.SameLine()
        if imgui.SmallButton('Clear##dashfilter') then _filter = '' end
        imgui.Separator()

        for _, g in ipairs(M.GROUPS) do
            drawGroup(g)
        end
    end
    imgui.End()
end

-- ---------------------------------------------------------------------------
-- One-time registration
-- ---------------------------------------------------------------------------
local _registered = false
function M.register_window()
    if _registered then return end
    _registered = true
    if mq and mq.imgui and mq.imgui.init then
        pcall(mq.imgui.init, 'SideKickDashboard', function()
            local ok, err = pcall(M.draw)
            if not ok then
                pcall(imgui.Begin, 'SideKick Dashboard Error###sk_dashboard_err', true, 0)
                imgui.TextColored(1, 0.3, 0.3, 1, tostring(err))
                pcall(imgui.End)
            end
        end)
    end
end

return M
