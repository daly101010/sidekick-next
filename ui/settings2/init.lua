-- ============================================================
-- SideKick Settings Redesign - Shell (safe primitives only)
-- ============================================================
-- Pure-ImGui-widgets version. Every rectangle, separator, and pill
-- is a native widget - no BeginChild, no InvisibleButton, no
-- DrawList, no SetCursorScreenPos. This keeps us clear of the
-- ImGui state-corruption path that crashed the fancier shell.
--
-- Visual language is still: dark parchment, burnished gold nav,
-- vermilion/verdigris live-state pills, small-caps section titles.

local imgui = require('ImGui')
local mq = require('mq')
local P = require('sidekick-next.ui.settings2.palette')

-- Optional imports. Guarded because both are non-critical (imanim is used
-- for pill breathing, Registry for the search bar); shell must still work
-- without them.
local iam = (function()
    local ok, v = pcall(require, 'sidekick-next.utils.imanim')
    return ok and v or nil
end)()

local M = {}
local _remoteAbilities = false
local _aggroWarning = false
local _humanize = false
local _registry = false
local _settingsUi = false
local _preloaded = false

-- ------------------------------------------------------------
-- Chapter registry: chapter -> [tab module paths]
-- ------------------------------------------------------------

-- Inline custom sections that used to render outside the shell.
local function drawRemoteAbilitiesInline()
    local RA = _remoteAbilities or nil
    if not RA then
        imgui.TextColored(1, 0.4, 0.4, 1, 'RemoteAbilities module unavailable')
        return
    end
    imgui.PushStyleColor(ImGuiCol.Text, P.rgba(P.dim))
    imgui.TextWrapped('Trigger abilities on other characters running SideKick.')
    imgui.PopStyleColor()
    imgui.Dummy(0, 4)
    if RA.isOpen and RA.setOpen then
        local open = RA.isOpen()
        local newOpen, changed = imgui.Checkbox('Show Remote Ability Bar', open)
        if changed then RA.setOpen(newOpen) end
    end
    if RA.toggleSettings and imgui.Button('Configure Remote Abilities') then
        RA.toggleSettings()
    end
end

local function drawAggroWarningInline()
    local AW = _aggroWarning or nil
    if not AW then
        imgui.TextColored(1, 0.4, 0.4, 1, 'AggroWarning module unavailable')
        return
    end
    if AW.drawSettings then AW.drawSettings() end
end

-- Chapters ordered by frequency of use: primary combat first, then support
-- (healer / buffer duties), pulling (its own activity), interface polish,
-- system/config, presence (behavioral tuning), diagnostics (dev tools).
local CHAPTERS = {
    {
        id = 'combat', label = 'Combat', glyph = 'X',
        subtitle = 'How your character fights. Combat mode, CC, chase, standoff, meditation, burn.',
        tabs = {
            { path = 'sidekick-next.ui.settings.tab_automation', label = 'Combat & Chase' },
            -- Aggro warning lives here: it's a combat-safety readout, not
            -- a UI extra. Was appended by SideKick.lua before the redesign.
            { label = 'Aggro Warning', draw = drawAggroWarningInline },
        },
    },

    {
        id = 'support', label = 'Support', glyph = '+',
        subtitle = 'Group support. Healing, buffs, resurrection.',
        tabs = {
            { path = 'sidekick-next.ui.settings.tab_healing',      label = 'Healing' },
            { path = 'sidekick-next.ui.settings.tab_buffs',        label = 'Buffs' },
            { path = 'sidekick-next.ui.settings.tab_resurrection', label = 'Resurrection' },
        },
    },

    {
        id = 'pulling', label = 'Pulling', glyph = '>',
        subtitle = 'Camp control and pull queue. Only used when running as puller.',
        tabs = {
            { path = 'sidekick-next.ui.settings.tab_pull', label = 'Pull' },
        },
    },

    {
        id = 'interface', label = 'Interface', glyph = '#',
        subtitle = 'What you see. Themes, bars, animation, and the remote-ability bar.',
        tabs = {
            { path = 'sidekick-next.ui.settings.tab_ui',         label = 'Theme & Docking' },
            { path = 'sidekick-next.ui.settings.tab_bar',        label = 'Ability Bar' },
            { path = 'sidekick-next.ui.settings.tab_special',    label = 'Special Bar' },
            { path = 'sidekick-next.ui.settings.tab_items',      label = 'Item Bar' },
            -- Remote Abilities is another bar. Lives with the other bars.
            { label = 'Remote Ability Bar', draw = drawRemoteAbilitiesInline },
            { path = 'sidekick-next.ui.settings.tab_animations', label = 'Animations' },
        },
    },

    {
        id = 'system', label = 'System', glyph = '=',
        subtitle = 'External tools, actor peers, and log verbosity.',
        tabs = {
            { path = 'sidekick-next.ui.settings.tab_remote',      label = 'Remote Peers' },
            { path = 'sidekick-next.ui.settings.tab_integration', label = 'Integration' },
            { path = 'sidekick-next.ui.settings.tab_logging',     label = 'Logging' },
        },
    },

    {
        id = 'presence', label = 'Presence', glyph = '~',
        subtitle = 'Behavioral humanization. Fidget, per-profile timings, decision noise.',
        tabs = { { path = 'sidekick-next.ui.settings.tab_humanize', label = 'Humanize' } },
    },

    {
        id = 'diagnostics', label = 'Diagnostics', glyph = '?',
        subtitle = 'Live counters and internal state. Nothing here is saved.',
        tabs = {
            { path = 'sidekick-next.ui.perf_monitor',       label = 'Performance',    fn = 'drawContent' },
            { path = 'sidekick-next.ui.coordinator_debug',  label = 'Coordinator',    fn = 'drawContent' },
            { path = 'sidekick-next.ui.activity_debug',     label = 'Activity',       fn = 'drawContent' },
            -- DPS Intelligence: time-to-die reasoning + resist/CC/damage/zone
            -- telemetry driving the caster rotation gates.
            { path = 'sidekick-next.ui.intelligence_debug', label = 'DPS Intelligence', fn = 'drawContent' },
            -- Healing Monitor: live heal telemetry (only meaningful for healer
            -- classes; module renders its own "waiting for combat" state).
            { path = 'sidekick-next.healing.ui.monitor',    label = 'Healing Monitor',  fn = 'drawContent' },
        },
    },
}

-- ------------------------------------------------------------
-- Persistent state
-- ------------------------------------------------------------

local _selectedId = 'combat'
local _subNav = {}       -- [chapterId] = tab index (default 1)
local _searchFilter = ''
local _searchCache = nil
local _searchCacheKey = ''
local _mods = {}

local function subIndex(chapterId)
    return _subNav[chapterId] or 1
end
local function setSubIndex(chapterId, i)
    _subNav[chapterId] = i
end

local function loadMod(path)
    if _mods[path] ~= nil then return _mods[path] or nil end
    local ok, mod = pcall(require, path)
    _mods[path] = (ok and mod) or false
    if not ok then
        print(string.format('[SK2] require failed: %s: %s', path, tostring(mod)))
    end
    return _mods[path] or nil
end

-- ------------------------------------------------------------
-- Live status resolution (drives the rail pills)
-- Returns text, variant ('off'|'live'|'hot'|'cool'), isBreathing
-- ------------------------------------------------------------

local function getHumanizeProfile()
    local H = _humanize or nil
    if not H or not H.activeProfile then return nil end
    local okp, p = pcall(H.activeProfile)
    return okp and p or nil
end

local function chapterStatus(id, settings)
    settings = settings or {}
    if id == 'combat' then
        local mode = tostring(settings.CombatMode or 'off')
        if mode == 'off' then return 'off', 'off', false end
        if settings.BurnActive == true then return 'burn', 'hot', true end
        return mode, 'live', true
    elseif id == 'support' then
        local heals = settings.HealingEnabled == true
        local buffs = settings.BuffsEnabled ~= false
        local rez = settings.AutoAcceptRez == true or (tostring(settings.AutoRezMode or 'off') ~= 'off')
        local n = (heals and 1 or 0) + (buffs and 1 or 0) + (rez and 1 or 0)
        if n == 0 then return nil, nil, false end
        return string.format('%d on', n), 'live', false
    elseif id == 'presence' then
        local cfg = _G.SIDEKICK_NEXT_CONFIG or {}
        if cfg.HUMANIZE_BEHAVIOR ~= true then return 'off', 'off', false end
        local prof = getHumanizeProfile() or 'auto'
        if prof == 'combat' or prof == 'emergency' or prof == 'named' then
            return prof, 'hot', true
        elseif prof == 'idle' or prof == 'farming' then
            return prof, 'cool', false
        end
        return prof, 'live', false
    elseif id == 'pulling' then
        local pull = settings.PullEnabled == true
        if pull then return 'active', 'live', true end
        return 'off', 'off', false
    end
    return nil, nil, false
end

-- Chase runs from Combat, so it drives the Combat pill secondary state.
-- We fold that in above (BurnActive check dominates); a chase-only readout
-- would be nice but the pill fits one word max at the current rail width.

-- ------------------------------------------------------------
-- Breathing alpha for live pills.
-- Prefers iam.Oscillate (proper ImAnim native oscillator) with a
-- math.sin fallback if imanim didn't load. Cached dt per frame so
-- multiple pills don't accumulate error across calls.
-- ------------------------------------------------------------

local _cachedFrame, _cachedDt, _lastClock = nil, 0.016, os.clock()

local function get_dt()
    local frame = (imgui.GetFrameCount and imgui.GetFrameCount()) or nil
    if frame ~= nil and frame == _cachedFrame then return _cachedDt end
    _cachedFrame = frame
    local dt
    local io = (imgui.GetIO and imgui.GetIO()) or nil
    if io and io.DeltaTime ~= nil then dt = tonumber(io.DeltaTime) end
    if not dt or dt <= 0 then
        local now = os.clock()
        dt = now - _lastClock
        _lastClock = now
    else
        _lastClock = os.clock()
    end
    _cachedDt = math.min(math.max(dt, 0), 0.1)
    return _cachedDt
end

local function breathe(id)
    if iam and iam.Oscillate and IamWaveType and IamWaveType.Sine then
        local ok, wave = pcall(iam.Oscillate, 'sk2.pill.' .. tostring(id),
            0.15, 0.9, IamWaveType.Sine, 0.0, get_dt())
        if ok and type(wave) == 'number' then
            return 0.85 + wave
        end
    end
    -- Fallback: same output curve using stdlib.
    return 0.85 + 0.15 * math.sin(os.clock() * 2 * math.pi * 0.9)
end

-- ------------------------------------------------------------
-- Atoms (text-only, no DrawList)
-- ------------------------------------------------------------

--- Small-caps letterspaced title using default font.
local function smallCaps(text)
    return (text:upper():gsub('.', '%0 '):gsub(' $', ''))
end

local function titleText(text, color, alpha)
    color = color or P.ink
    imgui.PushStyleColor(ImGuiCol.Text, P.rgba(color, alpha or 1.0))
    imgui.Text(smallCaps(text))
    imgui.PopStyleColor()
end

-- Palette-tinted separator by pushing SeparatorColor around it.
local function bronzeSeparator(alpha)
    imgui.PushStyleColor(ImGuiCol.Separator, P.rgba(P.rule, alpha or 0.7))
    imgui.Separator()
    imgui.PopStyleColor()
end

-- Colored pill using TextColored + brackets. No DrawList background,
-- but distinctive enough with the palette color to read as a pill.
local function pillText(text, variant, alpha)
    if not text or text == '' then return end
    alpha = alpha or 1.0
    local color = P.dim
    if variant == 'hot' then color = P.hot
    elseif variant == 'cool' then color = P.cool
    elseif variant == 'live' then color = P.accent
    end
    imgui.PushStyleColor(ImGuiCol.Text, P.rgba(color, alpha))
    imgui.Text('  ' .. smallCaps(text))
    imgui.PopStyleColor()
end

-- ------------------------------------------------------------
-- Rail: vertical list of chapter buttons + live pills
-- Uses BeginGroup (safe - no BeginChild).
-- ------------------------------------------------------------

local RAIL_BTN_WIDTH = 170

local function drawRail(settings)
    imgui.BeginGroup()

    -- Header
    imgui.PushStyleColor(ImGuiCol.Text, P.rgba(P.accent))
    imgui.Text(smallCaps('SideKick'))
    imgui.PopStyleColor()
    imgui.PushStyleColor(ImGuiCol.Text, P.rgba(P.dim))
    imgui.Text('control panel')
    imgui.PopStyleColor()
    imgui.Dummy(0, 6)
    bronzeSeparator(0.6)
    imgui.Dummy(0, 4)

    for _, ch in ipairs(CHAPTERS) do
        local isSelected = ch.id == _selectedId

        -- Style the button so selected = burnished-gold bg + dark ink text,
        -- unselected = flat panel bg + ink text, hover = subtle plate.
        if isSelected then
            imgui.PushStyleColor(ImGuiCol.Button,        P.rgba(P.accent, 0.9))
            imgui.PushStyleColor(ImGuiCol.ButtonHovered, P.rgba(P.accent, 1.0))
            imgui.PushStyleColor(ImGuiCol.ButtonActive,  P.rgba(P.accent, 1.0))
            imgui.PushStyleColor(ImGuiCol.Text,          P.rgba(P.bg))
        else
            imgui.PushStyleColor(ImGuiCol.Button,        P.rgba(P.plate, 0.4))
            imgui.PushStyleColor(ImGuiCol.ButtonHovered, P.rgba(P.plate, 0.8))
            imgui.PushStyleColor(ImGuiCol.ButtonActive,  P.rgba(P.plate, 1.0))
            imgui.PushStyleColor(ImGuiCol.Text,          P.rgba(P.ink))
        end

        local label = string.format('  %s  %s', ch.glyph, ch.label)
        if imgui.Button(label .. '##sk2_rail_' .. ch.id, RAIL_BTN_WIDTH, 26) then
            _selectedId = ch.id
        end

        imgui.PopStyleColor(4)

        -- Live status pill under the button, indented to align with the label.
        local pillT, variant, isBreathing = chapterStatus(ch.id, settings)
        if pillT then
            local a = isBreathing and breathe(ch.id) or 1.0
            imgui.Indent(28)
            pillText(pillT, variant, a)
            imgui.Unindent(28)
        end

        imgui.Dummy(0, 6)
    end

    imgui.EndGroup()
end

-- ------------------------------------------------------------
-- Content pane
-- ------------------------------------------------------------

-- Draw the mounted-tab body (either the module's draw() or an inline draw).
local function drawTabBody(tabEntry, settings, themeNames, onChange)
    if tabEntry.draw then
        local ok, err = pcall(tabEntry.draw, settings, themeNames, onChange)
        if not ok then
            imgui.TextColored(1, 0.3, 0.3, 1, 'Section error:')
            imgui.TextWrapped(tostring(err))
        end
        return
    end
    if tabEntry.path then
        local mod = loadMod(tabEntry.path)
        if not mod then
            imgui.TextColored(1, 0.4, 0.4, 1, 'Failed to load: ' .. tabEntry.path)
            return
        end
        if mod.isAvailable then
            local availOk, avail = pcall(mod.isAvailable)
            if availOk and avail == false then
                imgui.PushStyleColor(ImGuiCol.Text, P.rgba(P.dim))
                imgui.Text('(not available for your class)')
                imgui.PopStyleColor()
                return
            end
        end
        local drawFn = mod[tabEntry.fn or 'draw']
        if not drawFn then
            imgui.TextColored(1, 0.4, 0.4, 1, 'Missing ' .. (tabEntry.fn or 'draw') .. '()')
            return
        end
        local ok, err = pcall(drawFn, settings, themeNames, onChange)
        if not ok then
            imgui.TextColored(1, 0.3, 0.3, 1, 'Section error:')
            imgui.TextWrapped(tostring(err))
        end
    end
end

-- Horizontal chip strip for chapters with multiple sections.
-- Each chip is a SmallButton palette-styled. Only shown when >1 tab.
local function drawSubNav(chapter)
    if #chapter.tabs <= 1 then return end
    local active = subIndex(chapter.id)
    for i, tabEntry in ipairs(chapter.tabs) do
        if i > 1 then imgui.SameLine(0, 6) end
        local isActive = i == active
        if isActive then
            imgui.PushStyleColor(ImGuiCol.Button,        P.rgba(P.accent, 0.9))
            imgui.PushStyleColor(ImGuiCol.ButtonHovered, P.rgba(P.accent, 1.0))
            imgui.PushStyleColor(ImGuiCol.ButtonActive,  P.rgba(P.accent, 1.0))
            imgui.PushStyleColor(ImGuiCol.Text,          P.rgba(P.bg))
        else
            imgui.PushStyleColor(ImGuiCol.Button,        P.rgba(P.plate, 0.5))
            imgui.PushStyleColor(ImGuiCol.ButtonHovered, P.rgba(P.plate, 0.9))
            imgui.PushStyleColor(ImGuiCol.ButtonActive,  P.rgba(P.plate, 1.0))
            imgui.PushStyleColor(ImGuiCol.Text,          P.rgba(P.dim))
        end
        if imgui.SmallButton(' ' .. tabEntry.label .. ' ##sk2_sub_' .. chapter.id .. '_' .. i) then
            setSubIndex(chapter.id, i)
        end
        imgui.PopStyleColor(4)
    end
    imgui.Dummy(0, 4)
    bronzeSeparator(0.4)
    imgui.Dummy(0, 4)
end

-- ------------------------------------------------------------
-- Search (registry-driven, jumps to owning chapter/section)
-- ------------------------------------------------------------

-- Static map: Registry Category -> which chapter+section id to jump to.
-- Categories come from Registry meta; kept explicit here so search results
-- can navigate the user home. Anything not mapped just renders inline.
local CATEGORY_TO_JUMP = {
    Combat      = { chapter = 'combat',    sectionLabel = 'Combat & Chase' },
    Tank        = { chapter = 'combat',    sectionLabel = 'Combat & Chase' },
    Assist      = { chapter = 'combat',    sectionLabel = 'Combat & Chase' },
    Chase       = { chapter = 'combat',    sectionLabel = 'Combat & Chase' },
    Meditation  = { chapter = 'combat',    sectionLabel = 'Combat & Chase' },
    Burn        = { chapter = 'combat',    sectionLabel = 'Combat & Chase' },
    ['Crowd Control'] = { chapter = 'combat', sectionLabel = 'Combat & Chase' },
    Healing     = { chapter = 'support',   sectionLabel = 'Healing' },
    Buffs       = { chapter = 'support',   sectionLabel = 'Buffs' },
    Resurrection = { chapter = 'support',  sectionLabel = 'Resurrection' },
    Pull        = { chapter = 'pulling',   sectionLabel = 'Pull' },
    UI          = { chapter = 'interface', sectionLabel = 'Theme & Docking' },
    Theme       = { chapter = 'interface', sectionLabel = 'Theme & Docking' },
    Bars        = { chapter = 'interface', sectionLabel = 'Ability Bar' },
    Animation   = { chapter = 'interface', sectionLabel = 'Animations' },
    Integration = { chapter = 'system',    sectionLabel = 'Integration' },
    Logging     = { chapter = 'system',    sectionLabel = 'Logging' },
    Remote      = { chapter = 'system',    sectionLabel = 'Remote Peers' },
    Humanize    = { chapter = 'presence',  sectionLabel = 'Humanize' },
}

local function jumpToCategory(cat)
    local jump = CATEGORY_TO_JUMP[cat]
    if not jump then return end
    _selectedId = jump.chapter
    -- Resolve section label to tab index within the chapter.
    for _, ch in ipairs(CHAPTERS) do
        if ch.id == jump.chapter then
            for i, t in ipairs(ch.tabs) do
                if t.label == jump.sectionLabel then
                    setSubIndex(jump.chapter, i)
                    break
                end
            end
            break
        end
    end
    _searchFilter = ''
    _searchCache = nil
    _searchCacheKey = ''
end

local function buildSearchResults(filter)
    local Registry = _registry or nil
    if not Registry or not Registry.iter_all then return {} end
    local lower = filter:lower()
    local out = {}
    for _, key in Registry.iter_all() do
        local meta = Registry.defaults[key]
        if meta and meta.Internal ~= true then
            local display = meta.DisplayName or key
            local cat = meta.Category or 'Other'
            local hay = (display .. ' ' .. cat .. ' ' .. key):lower()
            if hay:find(lower, 1, true) then
                out[#out + 1] = { key = key, meta = meta, category = cat, display = display }
            end
        end
    end
    table.sort(out, function(a, b)
        if a.category ~= b.category then return a.category < b.category end
        return a.display < b.display
    end)
    return out
end

local function drawSearchBar()
    _searchFilter = tostring(_searchFilter or '')
    imgui.PushStyleColor(ImGuiCol.FrameBg, P.rgba(P.bg, 1.0))
    imgui.PushStyleColor(ImGuiCol.Text,    P.rgba(P.ink))
    imgui.PushItemWidth(-80)
    _searchFilter = imgui.InputText('##sk2_search', _searchFilter, 256) or ''
    imgui.PopItemWidth()
    imgui.PopStyleColor(2)
    imgui.SameLine()
    if imgui.SmallButton('clear##sk2_clr') then
        _searchFilter = ''
        _searchCache = nil
        _searchCacheKey = ''
    end
    if _searchFilter == '' then
        imgui.SameLine()
        imgui.PushStyleColor(ImGuiCol.Text, P.rgba(P.dim))
        imgui.Text('search settings')
        imgui.PopStyleColor()
    end
end

local function drawSearchResults(settings, onChange)
    if _searchCacheKey ~= _searchFilter then
        _searchCache = buildSearchResults(_searchFilter)
        _searchCacheKey = _searchFilter
    end
    local results = _searchCache or {}
    if #results == 0 then
        imgui.Dummy(0, 8)
        imgui.PushStyleColor(ImGuiCol.Text, P.rgba(P.dim))
        imgui.Text('No matches for "' .. _searchFilter .. '"')
        imgui.PopStyleColor()
        return
    end
    imgui.Dummy(0, 6)
    imgui.PushStyleColor(ImGuiCol.Text, P.rgba(P.dim))
    imgui.Text(string.format('%d matches', #results))
    imgui.PopStyleColor()
    bronzeSeparator(0.4)

    local Settings = _settingsUi or nil
    if not Settings then
        imgui.TextColored(1, 0.4, 0.4, 1,
            'Settings helpers were not initialized before drawing.')
        return
    end
    local lastCat = nil
    for _, entry in ipairs(results) do
        if entry.category ~= lastCat then
            lastCat = entry.category
            imgui.Dummy(0, 6)
            imgui.PushStyleColor(ImGuiCol.Text, P.rgba(P.accent))
            imgui.Text(smallCaps(entry.category))
            imgui.PopStyleColor()
            local jump = CATEGORY_TO_JUMP[entry.category]
            if jump then
                imgui.SameLine()
                imgui.PushStyleColor(ImGuiCol.Button,        P.rgba(P.plate, 0.4))
                imgui.PushStyleColor(ImGuiCol.ButtonHovered, P.rgba(P.plate, 0.9))
                imgui.PushStyleColor(ImGuiCol.ButtonActive,  P.rgba(P.accent, 0.6))
                imgui.PushStyleColor(ImGuiCol.Text,          P.rgba(P.dim))
                if imgui.SmallButton('open in ' .. jump.chapter .. '##jmp_' .. entry.category) then
                    jumpToCategory(entry.category)
                end
                imgui.PopStyleColor(4)
            end
            bronzeSeparator(0.3)
        end
        -- Render editable widget via legacy helpers.
        local k, meta = entry.key, entry.meta
        local t = meta.type or 'text'
        local v = settings[k]
        if t == 'bool' then
            local nv, ch = Settings.labeledCheckbox(entry.display .. '##sk2sr_' .. k, v == true)
            if ch and onChange then onChange(k, nv) end
        elseif t == 'number' then
            local nv = tonumber(v) or meta.Default or 0
            local ch = false
            if meta.Min and meta.Max then
                local d = tonumber(meta.Default) or nv
                local isInt = d % 1 == 0 and meta.Min % 1 == 0 and meta.Max % 1 == 0
                if isInt then
                    nv, ch = Settings.labeledSliderInt(entry.display .. '##sk2sr_' .. k,
                        math.floor(nv), meta.Min, meta.Max)
                else
                    nv, ch = Settings.labeledSliderFloat(entry.display .. '##sk2sr_' .. k,
                        nv, meta.Min, meta.Max)
                end
            else
                nv, ch = Settings.labeledSliderFloat(entry.display .. '##sk2sr_' .. k, nv, 0, 100)
            end
            if ch and onChange then onChange(k, nv) end
        elseif t == 'text' then
            local sv = tostring(v or meta.Default or '')
            local nv
            if type(meta.Options) == 'table' and #meta.Options > 0 then
                nv = Settings.labeledCombo(entry.display .. '##sk2sr_' .. k, sv, meta.Options, meta.Tooltip)
            else
                nv = Settings.labeledInputText(entry.display .. '##sk2sr_' .. k, sv, meta.Tooltip)
            end
            if nv ~= sv and onChange then onChange(k, nv) end
        end
    end
end

local function drawContent(settings, themeNames, onChange)
    imgui.BeginGroup()

    -- Search bar sits at the very top of the content pane.
    drawSearchBar()
    bronzeSeparator(0.5)
    imgui.Dummy(0, 4)

    if _searchFilter ~= '' then
        drawSearchResults(settings, onChange)
        imgui.EndGroup()
        return
    end

    local chapter = nil
    for _, ch in ipairs(CHAPTERS) do
        if ch.id == _selectedId then chapter = ch; break end
    end
    if not chapter then
        imgui.TextDisabled('No chapter selected')
        imgui.EndGroup()
        return
    end

    -- Chapter title + subtitle.
    titleText(chapter.label, P.ink)
    bronzeSeparator(1.0)
    if chapter.subtitle then
        imgui.PushStyleColor(ImGuiCol.Text, P.rgba(P.dim))
        imgui.TextWrapped(chapter.subtitle)
        imgui.PopStyleColor()
        imgui.Dummy(0, 4)
    end

    -- Sub-nav (only for multi-section chapters).
    drawSubNav(chapter)

    -- Render just the active section.
    local idx = subIndex(chapter.id)
    if idx < 1 or idx > #chapter.tabs then idx = 1 end
    local tabEntry = chapter.tabs[idx]
    if tabEntry then
        imgui.PushID('sk2_body_' .. chapter.id .. '_' .. idx)
        drawTabBody(tabEntry, settings, themeNames, onChange)
        imgui.PopID()
    end

    imgui.EndGroup()
end

-- ------------------------------------------------------------
-- Top-level draw
-- ------------------------------------------------------------

-- ------------------------------------------------------------
-- Palette-wide theme sweep
-- ------------------------------------------------------------
-- Overrides every ImGuiCol the inner tab modules touch so their
-- checkboxes, sliders, and CollapsingHeader bars stop reading
-- as bright-blue stock ImGui. Kept as a table of {enum, r,g,b,a}
-- rows so a missing enum on an older MQ build is skipped, not
-- crashing.
local function pushThemeColors()
    local pushes = 0
    local function push(enum, color, alpha)
        if enum == nil then return end
        local ok = pcall(function()
            imgui.PushStyleColor(enum, P.rgba(color, alpha or 1.0))
        end)
        if ok then pushes = pushes + 1 end
    end

    -- Frames (inputs, sliders, checkboxes)
    push(ImGuiCol.FrameBg,          P.panel, 1.0)
    push(ImGuiCol.FrameBgHovered,   P.plate, 1.0)
    push(ImGuiCol.FrameBgActive,    P.plate, 1.0)
    -- Slider grip
    push(ImGuiCol.SliderGrab,       P.accent, 1.0)
    push(ImGuiCol.SliderGrabActive, P.accent, 1.0)
    -- Checkbox tick
    push(ImGuiCol.CheckMark,        P.accent, 1.0)
    -- CollapsingHeader / Selectable selected
    push(ImGuiCol.Header,           P.plate, 1.0)
    push(ImGuiCol.HeaderHovered,    P.rule, 0.6)
    push(ImGuiCol.HeaderActive,     P.accent, 0.7)
    -- Tab bar (in case anything renders one inside)
    push(ImGuiCol.Tab,              P.panel, 1.0)
    push(ImGuiCol.TabHovered,       P.plate, 1.0)
    push(ImGuiCol.TabActive,        P.accent, 0.5)
    -- Borders + separators
    push(ImGuiCol.Border,           P.rule, 1.0)
    push(ImGuiCol.Separator,        P.rule, 0.7)
    push(ImGuiCol.SeparatorHovered, P.accent, 0.5)
    push(ImGuiCol.SeparatorActive,  P.accent, 0.8)
    -- Scrollbars
    push(ImGuiCol.ScrollbarBg,      P.bg, 1.0)
    push(ImGuiCol.ScrollbarGrab,    P.rule, 1.0)
    push(ImGuiCol.ScrollbarGrabHovered, P.dim, 1.0)
    push(ImGuiCol.ScrollbarGrabActive,  P.accent, 1.0)
    -- Text
    push(ImGuiCol.Text,             P.ink, 1.0)
    push(ImGuiCol.TextDisabled,     P.dim, 1.0)
    -- Buttons (rail overrides mid-draw; this is the default for tab content)
    push(ImGuiCol.Button,           P.plate, 0.7)
    push(ImGuiCol.ButtonHovered,    P.plate, 1.0)
    push(ImGuiCol.ButtonActive,     P.accent, 0.6)
    -- Popups (combo dropdowns)
    push(ImGuiCol.PopupBg,          P.panel, 1.0)

    return pushes
end

--- Load every mounted module from the normal Lua coroutine. MacroQuest ImGui
--- callbacks are non-yieldable, so draw() must only consume these caches.
function M.preload(settingsUi)
    if _preloaded then return true end
    _settingsUi = settingsUi or package.loaded['sidekick-next.ui.settings.init'] or false

    local function optional(path)
        local ok, value = pcall(require, path)
        return ok and value or false
    end

    _remoteAbilities = optional('sidekick-next.ui.remote_abilities')
    _aggroWarning = optional('sidekick-next.ui.aggro_warning')
    _humanize = optional('sidekick-next.humanize')
    _registry = optional('sidekick-next.registry')
    for _, chapter in ipairs(CHAPTERS) do
        for _, tab in ipairs(chapter.tabs or {}) do
            if tab.path then loadMod(tab.path) end
        end
    end
    _preloaded = true
    return true
end

function M.draw(settings, themeNames, onChange, opts)
    if not _preloaded then
        imgui.TextColored(1, 0.4, 0.4, 1,
            'Settings redesign is waiting for main-loop initialization.')
        return
    end
    local themePushes = pushThemeColors()

    -- Rail on the left, content on the right - split by SameLine (no BeginChild).
    drawRail(settings)
    imgui.SameLine(0, 12)
    drawContent(settings, themeNames, onChange)

    if themePushes > 0 then
        pcall(imgui.PopStyleColor, themePushes)
    end
end

return M
