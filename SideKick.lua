local mq = require('mq')
local imgui = require('ImGui')
local lazy = require('sidekick-next.utils.lazy_require')

local Logger = require('sidekick-next.utils.logger')
local log = Logger.new('Main')

local Core = require('sidekick-next.utils.core')
local SettingsRegistry = require('sidekick-next.registry')
local Themes = require('sidekick-next.themes')
local Helpers = require('sidekick-next.lib.helpers')
local Draw = require('sidekick-next.ui.draw_helpers')
local Cooldowns = require('sidekick-next.abilities.cooldowns')
local AbilityLoader = require('sidekick-next.abilities.loader')
local Abilities = require('sidekick-next.utils.abilities')
local SpecialAbilities = require('sidekick-next.utils.special_abilities')
local CombatAssist = require('sidekick-next.utils.combatassist')
local Chase = require('sidekick-next.automation.chase')
local Assist = require('sidekick-next.automation.assist')
local Burn = require('sidekick-next.automation.burn')
local Tank = require('sidekick-next.automation.tank')
local HealerClasses = require('sidekick-next.utils.healer_classes')
local RezData = require('sidekick-next.utils.rez_data')
-- Lazy getters bundled into one table: the main function was at LuaJIT's
-- hard limit of 60 upvalues per function, and each bare `local getX` it
-- referenced cost one upvalue. One table = one upvalue for all of them.
local LZ = {}
LZ.getLegacyHealing = lazy.once('sidekick-next.automation.healing')
local NewHealing = nil  -- Lazy-loaded for supported healer classes

-- Phased healing module loader: spreads the healing module load
-- across multiple main loop ticks to avoid blocking MQ frames.
-- Phase 0: warmup (3s, legacy healing covers)
-- Phase 1: require module (fast since submodule requires are deferred)
-- Phases 2-6: initPhased(1..5), one per tick
-- Phase 7+: fully ready
local _healPhase = 0            -- Current loading phase
local _healMod = nil            -- Module reference during phased loading
local _healLoadComplete = false  -- True when all phases finished
local _healingWarmupStart = nil  -- Set when main loop begins
local HEALING_WARMUP_SEC = 3.0  -- Seconds before starting phased load

local function getHealingModule()
    local me = mq.TLO.Me
    if not me or not me() then return LZ.getLegacyHealing() end
    local classShort = me.Class and me.Class.ShortName and me.Class.ShortName() or ''
    local upper = classShort:upper()
    if not HealerClasses.isSupported(upper) then return LZ.getLegacyHealing() end

    -- Advance one phase per call until complete
    if not _healLoadComplete then
        -- Phase 0: warmup (use legacy healing while other systems stabilize)
        if _healPhase == 0 then
            if _healingWarmupStart and (os.clock() - _healingWarmupStart) >= HEALING_WARMUP_SEC then
                _healPhase = 1
            end

        -- Phase 1: require the module (fast since submodule requires are now deferred)
        elseif _healPhase == 1 then
            local ok, mod = pcall(require, 'sidekick-next.healing')
            if ok and mod then
                _healMod = mod
                _healPhase = 2
            else
                _healLoadComplete = true
            end

        -- Phases 2+: incremental init (one phase per tick)
        elseif _healMod then
            local initPhase = _healPhase - 1
            local totalPhases = _healMod.TOTAL_INIT_PHASES or 5
            if initPhase <= totalPhases then
                pcall(_healMod.initPhased, initPhase)
                _healPhase = _healPhase + 1

                if not NewHealing and _healMod.isInitialized and _healMod.isInitialized() then
                    NewHealing = _healMod
                end

                if initPhase >= totalPhases then
                    _healLoadComplete = true
                end
            else
                _healLoadComplete = true
            end
        end
    end

    return NewHealing or LZ.getLegacyHealing()
end

local Healing = nil  -- Will be set dynamically by getHealingModule()

LZ.getCures = lazy.init('sidekick-next.automation.cures')
LZ.getPull = lazy('sidekick-next.automation.pull')
local ActorsCoordinator = require('sidekick-next.utils.actors_coordinator')
local Supervisor = require('sidekick-next.utils.supervisor')
local SkLib = require('sidekick-next.sk_lib')
local SharedData = require('sidekick-next.actors.shareddata')
LZ.getGrids = lazy('sidekick-next.ui.grids')
local SettingsUI = require('sidekick-next.ui.settings.init')
LZ.getBar = lazy('sidekick-next.ui.bar_animated')
LZ.getSpecialBar = lazy('sidekick-next.ui.special_bar_animated')
LZ.getDiscBar = lazy('sidekick-next.ui.disc_bar_animated')
LZ.getItemBar = lazy('sidekick-next.ui.item_bar_animated')
LZ.getSkillBar = lazy('sidekick-next.ui.skill_bar_animated')
local iam = require('sidekick-next.utils.imanim')

-- Cached spring ease descriptors (iam.EaseSpring may be nil in some builds)
local _ezSpringHover = (function()
    local ez = IamEaseDesc()
    ez.type = IamEaseType.Spring
    ez.p0 = 1.0; ez.p1 = 300; ez.p2 = 22; ez.p3 = 0.0
    return ez
end)()
local _ezSpringSettings = (function()
    local ez = IamEaseDesc()
    ez.type = IamEaseType.Spring
    ez.p0 = 1.0; ez.p1 = 200; ez.p2 = 20; ez.p3 = 0.0
    return ez
end)()

local Anchor = require('sidekick-next.ui.anchor')
local Items = require('sidekick-next.utils.items')

-- Loading screen overlay (rendered during phased healing load)
local Loader = require('sidekick-next.ui.loader')

-- Performance monitor (tracks per-module frame times)
local PerfMonitor = require('sidekick-next.ui.perf_monitor')

-- New enhancement modules (lazy-loaded: only used in UI callbacks and commands)
LZ.getRemoteAbilities = lazy.init('sidekick-next.ui.remote_abilities')
LZ.getAggroWarning = lazy.init('sidekick-next.ui.aggro_warning')
LZ.getActorsDebug = lazy('sidekick-next.ui.actors_debug')
LZ.getCoordinatorDebug = lazy.init('sidekick-next.ui.coordinator_debug')

-- Runtime cache, action executor, rotation engine, CC, and spell engine (lazy-loaded)
LZ.getRuntimeCache = lazy.init('sidekick-next.utils.runtime_cache')
LZ.getActionExecutor = lazy.init('sidekick-next.utils.action_executor')
LZ.getRotationEngine = lazy('sidekick-next.utils.rotation_engine')
LZ.getCC = lazy.init('sidekick-next.automation.cc')
LZ.getBuff = lazy.init('sidekick-next.automation.buff')
LZ.getSpellEngine = lazy.init('sidekick-next.utils.spell_engine')
LZ.getImmuneDB = lazy.init('sidekick-next.utils.immune_database')
LZ.getRezAccept = lazy.init('sidekick-next.utils.rez_accept')
LZ.getResistTracker = lazy.init('sidekick-next.utils.resist_tracker')
LZ.getDamageEvents = lazy.init('sidekick-next.utils.damage_events')
LZ.getMobHpEstimator = lazy.init('sidekick-next.utils.mob_hp_estimator')
LZ.getSpellDamageTracker = lazy.init('sidekick-next.utils.spell_damage_tracker')
LZ.getMobIntel = lazy.init('sidekick-next.utils.mob_intel')
LZ.getDeathForensics = lazy.init('sidekick-next.utils.death_forensics')
LZ.getSessionStats = lazy.init('sidekick-next.utils.session_stats')
LZ.getReadiness = lazy('sidekick-next.utils.readiness')
LZ.getSpellLineup = lazy.init('sidekick-next.utils.spell_lineup')
LZ.getClassConfigLoader = lazy.init('sidekick-next.utils.class_config_loader')
LZ.getSpellsetManager = lazy.init('sidekick-next.utils.spellset_manager')
LZ.getSpellSetEditor = lazy.init('sidekick-next.ui.spell_set_editor')

LZ.getSpellSetMemorize = lazy('sidekick-next.utils.spellset_memorize')
LZ.getCombatSpellExecutor = lazy('sidekick-next.utils.combat_spell_executor')
LZ.getThrottledLog = lazy('sidekick-next.utils.throttled_log')
LZ.getHealingMonitor = lazy('sidekick-next.healing.ui.monitor')
LZ.getHealingSettingsTab = lazy('sidekick-next.ui.settings.tab_healing')
LZ.getItemsTab = lazy('sidekick-next.ui.settings.tab_items')
LZ.getBuffsTab = lazy('sidekick-next.ui.settings.tab_buffs')

-- Debug logging flags for main automation loop
local debugAutomationLogging = false


local animSpellIcons = mq.FindTextureAnimation and mq.FindTextureAnimation('A_SpellIcons') or nil
local animItems = mq.FindTextureAnimation and mq.FindTextureAnimation('A_DragItem') or nil
local _okIcons, Icons = pcall(require, 'mq.ICONS')
if not _okIcons then Icons = nil end

local function cooldownRemaining(row)
    local rem = Cooldowns.probe(row)
    return rem
end

local State = {
    open = true,
    shouldDraw = true,
    settingsOpen = false,
    isRunning = true,  -- Set to false to terminate the script
    _mainBarLast = { x = 50, y = 160, w = 200, h = 30 },
    actionQueue = {},
    classShort = nil,
    abilities = {},
    barAbilities = {},
    lastClassCheck = 0,
    burnActive = false,
    lastAutomationTick = 0,
    lastStateSyncTick = 0,
    lastThemeSyncAt = 0,
    -- First-run autostart prompt state
    showAutostartPrompt = false,
    autostartPromptChecked = false,
}

local function iniFlagIsTrue(section, key)
    if not Core or not Core.Ini or not Core.Ini[section] then return false end
    local v = Core.Ini[section][key]
    if v == true then return true end
    if v == false or v == nil then return false end
    local s = tostring(v):lower()
    return (s == '1' or s == 'true' or s == 'yes' or s == 'on')
end

local function filterTrainedAbilities(list)
    local me = mq.TLO.Me
    if not me or not me() then return list or {} end
    local excludedById = SpecialAbilities.excludedAltIDs()
    local excludedByName = SpecialAbilities.excludedNames()
    local out = {}
    for _, def in ipairs(list or {}) do
        if type(def) ~= 'table' then goto continue end

        local kind = tostring(def.kind or 'aa')
        if kind == 'aa' then
            if not (def.altID and def.altName and me.AltAbility) then goto continue end
            if excludedById[tonumber(def.altID)] or excludedByName[tostring(def.altName):lower()] then
                goto continue
            end
            local myAA = me.AltAbility(tonumber(def.altID))
            if myAA and myAA() then
                local passive = false
                if myAA.Passive then
                    local ok, v = pcall(function() return myAA.Passive() end)
                    passive = ok and v == true
                end
                if not passive then
                    table.insert(out, def)
                end
            end
        elseif kind == 'disc' then
            local discName = def.discName or def.altName
            if type(discName) ~= 'string' or discName == '' then goto continue end
            -- Only show disciplines that MQ recognizes for this character.
            -- User requirement: CombatAbilityTimer(<name>)() must not be nil.
            if me.CombatAbilityTimer then
                local resolved = nil
                for _, candidate in ipairs(Helpers.discNameCandidates(discName)) do
                    local ok, timerVal = pcall(function()
                        local t = me.CombatAbilityTimer(candidate)
                        return t and t()
                    end)
                    if ok and timerVal ~= nil then
                        resolved = candidate
                        break
                    end
                end
                if resolved then
                    def.discName = resolved
                    def.altName = resolved
                    table.insert(out, def)
                end
            end
        end
        ::continue::
    end
    return out
end

local function enqueue(fn)
    if type(fn) == 'function' then
        table.insert(State.actionQueue, fn)
    end
end

local _itemManualRequestCounter = 0
local function queueItemActivation(entry)
    local itemName = tostring(entry and entry.itemName or '')
    if itemName == '' then return end
    local slotKey = tostring(entry and entry.slotKey or '')
    _itemManualRequestCounter = _itemManualRequestCounter + 1
    local requestId = string.format('ui:%d:%d', mq.gettime(), _itemManualRequestCounter)

    enqueue(function()
        local coordinated = _G.SIDEKICK_NEXT_CONFIG
            and _G.SIDEKICK_NEXT_CONFIG.COORDINATED_MODE ~= false
        if coordinated then
            local sent = ActorsCoordinator.sendToLocalScript('sidekick-next/sk_items', 'item:manual', {
                requestId = requestId,
                requestedAtMs = mq.gettime(),
                itemName = itemName,
                slotKey = slotKey,
            })
            if not sent then
                print(string.format('\ar[SideKick Items]\ax Could not queue %s: item worker transport unavailable', itemName))
            end
        else
            Items.useItem(itemName, {
                throttleKey = slotKey ~= '' and slotKey or itemName,
                minInterval = 0.25,
            })
        end
    end)
end

local function drainQueue()
    if #State.actionQueue == 0 then return end
    local q = State.actionQueue
    State.actionQueue = {}
    for _, fn in ipairs(q) do
        pcall(fn)
    end
end

local function getClassShort()
    local me = mq.TLO.Me
    if not me then return nil end
    local cls = nil
    if me.Class and me.Class.ShortName then
        cls = me.Class.ShortName()
    end
    if (not cls or cls == '') and me.Class and me.Class.Name then
        cls = me.Class.Name()
    end
    if not cls or cls == '' then
        cls = me.Class and me.Class() or nil
    end
    if type(cls) ~= 'string' or cls == '' then return nil end
    return cls:upper()
end

local function applyBerDiscDefaultsOnce(abilities, isFirstDiscSeed)
    if tostring(State.classShort or '') ~= 'BER' then return end
    local me = mq.TLO.Me
    if not me or not me() then return end
    if Core.Settings.SideKickBERDiscDefaultsApplied == true then return end
    if isFirstDiscSeed ~= true then return end

    local bestByTimer = {}
    for _, def in ipairs(abilities or {}) do
        if type(def) == 'table' and tostring(def.kind or '') == 'disc' then
            local timer = tonumber(def.timer)
            if timer then
                local discName = def.discName or def.altName
                local ok, timerVal = pcall(function()
                    local t = me.CombatAbilityTimer and me.CombatAbilityTimer(discName)
                    return t and t()
                end)
                if not (ok and timerVal ~= nil) then goto continue end

                local cur = bestByTimer[timer]
                local lvl = tonumber(def.level) or 0
                if not cur or lvl > (tonumber(cur.level) or 0) then
                    bestByTimer[timer] = def
                end
            end
        end
        ::continue::
    end

    Core.Ini['SideKick'] = Core.Ini['SideKick'] or {}
    Core.Ini['SideKick-Abilities'] = Core.Ini['SideKick-Abilities'] or {}
    local abilitySection = Core.Ini['SideKick-Abilities']

    local changed = false
    for _, def in pairs(bestByTimer) do
        local key = def.settingKey
        if key and abilitySection[key] ~= '1' then
            abilitySection[key] = '1'
            Core.Settings[key] = true
            changed = true
        end
    end

    if changed then
        Core.set('SideKickBERDiscDefaultsApplied', true, { source = 'ber_disc_defaults' })
        Core.save()
    end
end

local function refreshClassAbilitiesIfNeeded()
    local now = os.clock()
    if (now - (State.lastClassCheck or 0)) < 1.0 then return end
    State.lastClassCheck = now

    local cls = getClassShort()
    if not cls or cls == State.classShort then return end

    State.classShort = cls
    State.abilities = filterTrainedAbilities(AbilityLoader.loadForClass(cls) or {})

    local hadAnyDiscToggle = false
    do
        local abilitySection = (Core.Ini and Core.Ini['SideKick-Abilities']) or {}
        for k, _ in pairs(abilitySection or {}) do
            if tostring(k):match('^doDisc') then
                hadAnyDiscToggle = true
                break
            end
        end
    end

    Core.ensureSeeded(State.abilities, Abilities.MODE)
    applyBerDiscDefaultsOnce(State.abilities, not hadAnyDiscToggle)

    -- Berserkers have a separate disciplines bar; keep AA bar free of discs for BER only.
    if cls == 'BER' then
        local filtered = {}
        for _, def in ipairs(State.abilities or {}) do
            if type(def) == 'table' and tostring(def.kind or '') ~= 'disc' then
                table.insert(filtered, def)
            end
        end
        State.barAbilities = filtered
    else
        State.barAbilities = State.abilities
    end
end

local function _bindCmd(cmd, fn)
    if not mq or not mq.bind then return end
    local raw = tostring(cmd or ''):gsub('^%s+', ''):gsub('%s+$', '')
    if raw == '' then return end
    local withSlash = raw:match('^/') and raw or ('/' .. raw)
    if mq.unbind then
        -- MQ binds can be case-insensitive depending on build; attempt common variants.
        pcall(mq.unbind, withSlash)
        pcall(mq.unbind, withSlash:lower())
        pcall(mq.unbind, withSlash:upper())
    end
    pcall(mq.bind, withSlash, fn)
end

-- Use shared vec2xy from Helpers
local vec2xy = Helpers.vec2xy

local function getStableGroupTargetBounds()
    if Anchor and Anchor.getTargetBounds then
        local gt = Anchor.getTargetBounds('grouptarget')
        if gt then return gt end
    end
    local gt = _G.GroupTargetBounds
    if not gt then return nil end
    -- Accept bounds even if 'loaded' is missing/false as long as required fields exist.
    local hasCore = (gt.x ~= nil and gt.y ~= nil and gt.width ~= nil and gt.height ~= nil)
    if not gt.loaded and not hasCore then return nil end
    -- Avoid hard-expiring bounds; GroupTarget may only broadcast on changes.
    -- If stale, keep last known bounds rather than breaking docking entirely.
    return gt
end

local _smoothPos = _smoothPos or {}
local function getSmoothWindowPos(key, targetX, targetY, smoothTime)
    smoothTime = tonumber(smoothTime) or 0.25
    local now = os.clock()
    local s = _smoothPos[key] or { x = targetX, y = targetY, at = now }
    local dt = math.max(0, now - (s.at or now))
    s.at = now

    if smoothTime <= 0 or dt <= 0 then
        s.x, s.y = targetX, targetY
    else
        local alpha = math.min(1, dt / smoothTime)
        s.x = (s.x or targetX) + (targetX - (s.x or targetX)) * alpha
        s.y = (s.y or targetY) + (targetY - (s.y or targetY)) * alpha
    end

    _smoothPos[key] = s
    return s.x, s.y
end

-- Track button hover states for spring animation
local _buttonHoverState = {}

-- Animated button with spring hover effect
local function animatedButton(label, btnScale)
    btnScale = btnScale or 1.0
    local animEnabled = Core.Settings.AnimationsEnabled ~= false and Core.Settings.HoverScaleEnabled ~= false
    local hoverScale = 1.0

    if animEnabled and iam and iam.TweenFloat then
        local springId = 'btn_hover_' .. label
        local isHovered = _buttonHoverState[label] or false
        local targetScale = isHovered and 1.08 or 1.0
        hoverScale = iam.TweenFloat(springId, imgui.GetID('hscale'), targetScale, 0.5, _ezSpringHover, IamPolicy.Crossfade, imgui.GetIO().DeltaTime)
    end

    -- Apply scale via padding adjustment
    local padX, padY = math.floor(4 * btnScale), math.floor(2 * btnScale)
    local pushedStyle = false
    if hoverScale > 1.001 or btnScale ~= 1.0 then
        local extraPad = (hoverScale - 1.0) * 8
        padX = padX + extraPad
        padY = padY + extraPad * 0.5
        imgui.PushStyleVar(ImGuiStyleVar.FramePadding, padX, padY)
        pushedStyle = true
    end

    -- Check if we should use textured rendering
    local themeName = Core.Settings.SideKickTheme or 'Classic'
    local useTextures = false
    pcall(function()
        if not Themes.isTexturedTheme or not Themes.isTexturedTheme(themeName) then return end
        local TextureRenderer = Draw.getTextureRenderer and Draw.getTextureRenderer()
        if not TextureRenderer then return end
        if TextureRenderer.isAvailable and not TextureRenderer.isAvailable() then return end

        local dl = imgui.GetWindowDrawList()
        if not dl then return end

        local screenX, screenY = imgui.GetCursorScreenPos()
        if type(screenX) == 'table' then
            screenY = screenX.y or screenX[2]
            screenX = screenX.x or screenX[1]
        end

        -- Calculate button size to match ImGui button exactly
        local textW = imgui.CalcTextSize(label:gsub('##.*', ''))
        local tw = type(textW) == 'number' and textW or (textW.x or textW[1] or 50)
        -- Get the actual FramePadding ImGui will use
        local framePadX = padX
        pcall(function()
            local style = imgui.GetStyle()
            if style and style.FramePadding then
                local fp = style.FramePadding
                framePadX = type(fp) == 'number' and fp or (fp.x or fp[1] or padX)
            end
        end)
        local btnW = tw + framePadX * 2
        local btnH = imgui.GetTextLineHeight() + padY * 2

        local state = (_buttonHoverState[label] or false) and 'hover' or 'normal'
        local btnSize = TextureRenderer.getBestButtonSize and TextureRenderer.getBestButtonSize(btnW, btnH) or 'std'
        TextureRenderer.drawClassicButton(dl, screenX, screenY, btnW, btnH, state, btnSize)

        -- Make ImGui button transparent with black text
        imgui.PushStyleColor(ImGuiCol.Button, 0, 0, 0, 0)
        imgui.PushStyleColor(ImGuiCol.ButtonHovered, 1, 1, 1, 0.15)
        imgui.PushStyleColor(ImGuiCol.ButtonActive, 0, 0, 0, 0.2)
        imgui.PushStyleColor(ImGuiCol.Text, 0, 0, 0, 1)
        useTextures = true
    end)

    local pressed = imgui.Button(label)
    _buttonHoverState[label] = imgui.IsItemHovered()

    if useTextures then imgui.PopStyleColor(4) end
    if pushedStyle then imgui.PopStyleVar() end
    return pressed, useTextures
end

-- Animated small button with spring hover effect (for icon buttons)
local function animatedSmallButton(label, btnScale)
    btnScale = btnScale or 1.0
    local animEnabled = Core.Settings.AnimationsEnabled ~= false and Core.Settings.HoverScaleEnabled ~= false
    local hoverScale = 1.0

    if animEnabled and iam and iam.TweenFloat then
        local springId = 'sbtn_hover_' .. label
        local isHovered = _buttonHoverState[label] or false
        local targetScale = isHovered and 1.12 or 1.0
        hoverScale = iam.TweenFloat(springId, imgui.GetID('hscale'), targetScale, 0.5, _ezSpringHover, IamPolicy.Crossfade, imgui.GetIO().DeltaTime)
    end

    -- Apply scale via padding adjustment (smaller base padding for SmallButton)
    local padX, padY = math.floor(2 * btnScale), math.floor(1 * btnScale)
    local pushedStyle = false
    if hoverScale > 1.001 or btnScale ~= 1.0 then
        local extraPad = (hoverScale - 1.0) * 6
        padX = padX + extraPad
        padY = padY + extraPad * 0.5
        imgui.PushStyleVar(ImGuiStyleVar.FramePadding, padX, padY)
        pushedStyle = true
    end

    -- Check if we should use textured rendering
    local themeName = Core.Settings.SideKickTheme or 'Classic'
    local useTextures = false
    pcall(function()
        if not Themes.isTexturedTheme or not Themes.isTexturedTheme(themeName) then return end
        local TextureRenderer = Draw.getTextureRenderer and Draw.getTextureRenderer()
        if not TextureRenderer then return end
        if TextureRenderer.isAvailable and not TextureRenderer.isAvailable() then return end

        local dl = imgui.GetWindowDrawList()
        if not dl then return end

        local screenX, screenY = imgui.GetCursorScreenPos()
        if type(screenX) == 'table' then
            screenY = screenX.y or screenX[2]
            screenX = screenX.x or screenX[1]
        end

        -- Calculate button size to match ImGui button exactly
        local textW = imgui.CalcTextSize(label:gsub('##.*', ''))
        local tw = type(textW) == 'number' and textW or (textW.x or textW[1] or 20)
        -- Get the actual FramePadding ImGui will use
        local framePadX = padX
        pcall(function()
            local style = imgui.GetStyle()
            if style and style.FramePadding then
                local fp = style.FramePadding
                framePadX = type(fp) == 'number' and fp or (fp.x or fp[1] or padX)
            end
        end)
        local btnW = tw + framePadX * 2
        local btnH = imgui.GetTextLineHeight() + padY * 2

        local state = (_buttonHoverState[label] or false) and 'hover' or 'normal'
        -- Use small button size for icon buttons
        TextureRenderer.drawClassicButton(dl, screenX, screenY, btnW, btnH, state, 'small')

        -- Make ImGui button transparent with black text
        imgui.PushStyleColor(ImGuiCol.Button, 0, 0, 0, 0)
        imgui.PushStyleColor(ImGuiCol.ButtonHovered, 1, 1, 1, 0.15)
        imgui.PushStyleColor(ImGuiCol.ButtonActive, 0, 0, 0, 0.2)
        imgui.PushStyleColor(ImGuiCol.Text, 0, 0, 0, 1)
        useTextures = true
    end)

    local pressed = imgui.SmallButton(label)
    _buttonHoverState[label] = imgui.IsItemHovered()

    if useTextures then imgui.PopStyleColor(4) end
    if pushedStyle then imgui.PopStyleVar() end
    return pressed, useTextures
end

local function toggleButton(label, enabled, onClick, btnScale)
    btnScale = btnScale or 1.0
    enabled = enabled == true

    -- Spring hover animation
    local animEnabled = Core.Settings.AnimationsEnabled ~= false and Core.Settings.HoverScaleEnabled ~= false
    local hoverScale = 1.0

    if animEnabled and iam and iam.TweenFloat then
        -- Use invisible button to detect hover before rendering
        local btnId = label:gsub('##.*', '') -- Strip ImGui ID suffix for display
        local springId = 'btn_hover_' .. label

        -- Check if this button will be hovered (use last frame's state)
        local isHovered = _buttonHoverState[label] or false
        local targetScale = isHovered and 1.08 or 1.0
        hoverScale = iam.TweenFloat(springId, imgui.GetID('hscale'), targetScale, 0.5, _ezSpringHover, IamPolicy.Crossfade, imgui.GetIO().DeltaTime)
    end

    -- Apply scale via padding adjustment
    local padX, padY = math.floor(4 * btnScale), math.floor(2 * btnScale)
    local pushedScale = false
    if hoverScale > 1.001 or btnScale ~= 1.0 then
        local extraPad = (hoverScale - 1.0) * 8
        padX = padX + extraPad
        padY = padY + extraPad * 0.5
        imgui.PushStyleVar(ImGuiStyleVar.FramePadding, padX, padY)
        pushedScale = true
    end

    -- Check if we should use textured rendering
    local themeName = Core.Settings.SideKickTheme or 'Classic'
    local useTextures = false
    pcall(function()
        if not Themes.isTexturedTheme or not Themes.isTexturedTheme(themeName) then return end
        local TextureRenderer = Draw.getTextureRenderer and Draw.getTextureRenderer()
        if not TextureRenderer then return end
        if TextureRenderer.isAvailable and not TextureRenderer.isAvailable() then return end

        local dl = imgui.GetWindowDrawList()
        if not dl then return end

        local screenX, screenY = imgui.GetCursorScreenPos()
        if type(screenX) == 'table' then
            screenY = screenX.y or screenX[2]
            screenX = screenX.x or screenX[1]
        end

        -- Calculate button size to match ImGui button exactly
        local textW = imgui.CalcTextSize(label:gsub('##.*', ''))
        local tw = type(textW) == 'number' and textW or (textW.x or textW[1] or 50)
        -- Get the actual FramePadding ImGui will use
        local framePadX = padX
        pcall(function()
            local style = imgui.GetStyle()
            if style and style.FramePadding then
                local fp = style.FramePadding
                framePadX = type(fp) == 'number' and fp or (fp.x or fp[1] or padX)
            end
        end)
        local btnW = tw + framePadX * 2
        local btnH = imgui.GetTextLineHeight() + padY * 2

        -- Use 'pressed' state for enabled toggle buttons
        local state = enabled and 'pressed' or ((_buttonHoverState[label] or false) and 'hover' or 'normal')
        local btnSize = TextureRenderer.getBestButtonSize and TextureRenderer.getBestButtonSize(btnW, btnH) or 'std'
        TextureRenderer.drawClassicButton(dl, screenX, screenY, btnW, btnH, state, btnSize)

        -- Make ImGui button mostly transparent but with slight tint for enabled state
        -- Use black text for readability on textured buttons
        if enabled then
            imgui.PushStyleColor(ImGuiCol.Button, 0.1, 0.3, 0.1, 0.3)
            imgui.PushStyleColor(ImGuiCol.ButtonHovered, 0.15, 0.4, 0.15, 0.4)
            imgui.PushStyleColor(ImGuiCol.ButtonActive, 0.1, 0.25, 0.1, 0.4)
        else
            imgui.PushStyleColor(ImGuiCol.Button, 0, 0, 0, 0)
            imgui.PushStyleColor(ImGuiCol.ButtonHovered, 1, 1, 1, 0.15)
            imgui.PushStyleColor(ImGuiCol.ButtonActive, 0, 0, 0, 0.2)
        end
        imgui.PushStyleColor(ImGuiCol.Text, 0, 0, 0, 1)
        useTextures = true
    end)

    -- Only apply default enabled colors if not using textures
    if not useTextures and enabled then
        imgui.PushStyleColor(ImGuiCol.Button, 0.20, 0.70, 0.30, 0.90)
        imgui.PushStyleColor(ImGuiCol.ButtonHovered, 0.25, 0.80, 0.35, 1.00)
        imgui.PushStyleColor(ImGuiCol.ButtonActive, 0.15, 0.60, 0.25, 1.00)
    end

    local pressed = imgui.Button(label)

    -- Update hover state for next frame
    _buttonHoverState[label] = imgui.IsItemHovered()

    if useTextures then
        imgui.PopStyleColor(4)  -- 3 button colors + 1 text color
    elseif enabled then
        imgui.PopStyleColor(3)
    end
    if pushedScale then imgui.PopStyleVar() end

    if pressed and onClick then onClick() end
    return pressed, useTextures
end

local function draw()
    local settings = Core.Settings or {}
    local mainEnabled = settings.SideKickMainEnabled ~= false
    if not mainEnabled or not State.open then
        _G.SideKickDockedToGT = false
    end
    if (not State.open or not mainEnabled) and not State.settingsOpen then return end

    local themeName = settings.SideKickTheme or 'Classic'
    local style = Themes.getWindowStyle(themeName)

    if mainEnabled and State.open then
        local mainAnchor = tostring(Core.Settings.SideKickMainAnchor or 'none'):lower()
    local mainAnchorTarget = Anchor and Anchor.normalizeTargetKey and Anchor.normalizeTargetKey(Core.Settings.SideKickMainAnchorTarget or 'grouptarget')
        or tostring(Core.Settings.SideKickMainAnchorTarget or 'grouptarget'):lower()
        local anchorGap = tonumber(Core.Settings.SideKickMainAnchorGap) or 2
        local rounding = tonumber(Core.Settings.SideKickMainRounding) or 6
        local gt = getStableGroupTargetBounds()
        if Core.Settings.SideKickSyncThemeWithGT == true and gt and tonumber(gt.windowRounding) then
            rounding = tonumber(gt.windowRounding)
        end

        local estW = tonumber(State._mainBarLast.w) or 200
        local estH = tonumber(State._mainBarLast.h) or 30

        local anchorX, anchorY = Anchor.getAnchorPos(mainAnchorTarget, mainAnchor, estW, estH, anchorGap)
        -- Consider docked if anchored to any GroupTarget window (group, target, or xtarget)
    local isGTWindow = (mainAnchorTarget == 'grouptarget' or mainAnchorTarget == 'target' or mainAnchorTarget == 'xtarget' or mainAnchorTarget == 'gt_commandbar')
        local dockedToGT = isGTWindow and (anchorX ~= nil and anchorY ~= nil)
        _G.SideKickDockedToGT = dockedToGT

        if anchorX and anchorY and imgui.SetNextWindowPos then
            local smoothX, smoothY = getSmoothWindowPos('SideKickMain', anchorX, anchorY, 0.25)
            imgui.SetNextWindowPos(smoothX, smoothY, (ImGuiCond and ImGuiCond.Always) or 0)
        elseif imgui.SetNextWindowPos then
            imgui.SetNextWindowPos(50, 160, (ImGuiCond and ImGuiCond.FirstUseEver) or 4)
        end

        -- Width override (0 = auto)
        local widthOverride = tonumber(Core.Settings.SideKickMainWidth) or 0
        if widthOverride > 0 and imgui.SetNextWindowSizeConstraints then
            imgui.SetNextWindowSizeConstraints(widthOverride, 0, widthOverride, 2000)
        end

        local flags = (ImGuiWindowFlags and ImGuiWindowFlags.AlwaysAutoResize) or 0
        if ImGuiWindowFlags and bit32 and bit32.bor then
            flags = bit32.bor(
                flags,
                ImGuiWindowFlags.NoTitleBar or 0,
                ImGuiWindowFlags.NoScrollbar or 0,
                ImGuiWindowFlags.NoCollapse or 0
            )
        end

        -- Check if using textured theme for transparent background
        local isTexturedTheme = Themes.isTexturedTheme and Themes.isTexturedTheme(themeName)
        local pushedTexturedBg = false
        if isTexturedTheme then
            imgui.PushStyleColor(ImGuiCol.WindowBg, 0, 0, 0, 0)
            pushedTexturedBg = true
        end

        -- Animated theme crossfade (smooth OKLAB blend on theme change)
        Themes.tweenToTheme(themeName, imgui.GetIO().DeltaTime)

        local pushedTheme = Themes.pushWindowTheme(imgui, themeName, {
            windowAlpha = 0.92,
            childAlpha = 0.92 * 0.6,
            popupAlpha = 0.96,
            ImGuiCol = ImGuiCol,
        })
        imgui.PushStyleVar(ImGuiStyleVar.WindowRounding, rounding)
        imgui.PushStyleVar(ImGuiStyleVar.WindowPadding, 8, 6)

        local shown
        State.open, shown = imgui.Begin('SideKick##MainBar', State.open, flags)
        if shown then
        -- Draw textured background for ClassicEQ Textured theme
        -- ShowBorder: true = gold frame for 'classic' style, false = background only (no gold border)
        local showBorder = settings.SideKickMainShowBorder ~= false
        if isTexturedTheme then
            pcall(function()
                local TextureRenderer = Draw.getTextureRenderer and Draw.getTextureRenderer()
                if not TextureRenderer then return end

                local dl = imgui.GetWindowDrawList()
                if not dl then return end

                local winPosX, winPosY = imgui.GetWindowPos()
                if type(winPosX) == 'table' then
                    winPosY = winPosX.y or winPosX[2]
                    winPosX = winPosX.x or winPosX[1]
                end
                local winSizeX, winSizeY = imgui.GetWindowSize()
                if type(winSizeX) == 'table' then
                    winSizeY = winSizeX.y or winSizeX[2]
                    winSizeX = winSizeX.x or winSizeX[1]
                end

                local tintCol = TextureRenderer.parseTintSetting and TextureRenderer.parseTintSetting(settings.SideKickMainTextureTint) or nil
                local bgStyle = tostring(settings.SideKickMainBgStyle or 'lightrock')
                local customAnim = tostring(settings.SideKickMainBgTexture or '')
                local tileCustom = (bgStyle == 'custom') and (settings.SideKickMainBgTile ~= false) or true

                if bgStyle == 'none' then
                    return
                elseif bgStyle == 'lightrock' and TextureRenderer.drawLightRockBg then
                    TextureRenderer.drawLightRockBg(dl, winPosX, winPosY, winSizeX, winSizeY, { rounding = rounding, tintCol = tintCol })
                    return
                elseif bgStyle == 'classic' then
                    -- 'classic' style has gold frame - use it only when showBorder is true
                    if showBorder and TextureRenderer.drawHotbuttonBg then
                        TextureRenderer.drawHotbuttonBg(dl, winPosX, winPosY, winSizeX, winSizeY, { rounding = rounding, tintCol = tintCol })
                    elseif TextureRenderer.drawActionWindowBg then
                        -- Draw background only (no gold border)
                        TextureRenderer.drawActionWindowBg(dl, winPosX, winPosY, winSizeX, winSizeY, {
                            tile = true,
                            shadows = false,
                            tintCol = tintCol,
                        })
                    end
                    return
                end

                -- Fallback to generic tiled background for other styles/custom.
                local anim = customAnim
                if bgStyle == 'darkrock' then
                    anim = 'A_Listbox_Background1'
                elseif bgStyle == 'action' then
                    anim = 'ACTW_bg_TX'
                elseif anim == '' or anim == 'nil' then
                    anim = 'A_Listbox_Background1'
                end

                if TextureRenderer.drawTiledAnimBg then
                    TextureRenderer.drawTiledAnimBg(dl, winPosX, winPosY, winSizeX, winSizeY, anim, {
                        rounding = rounding,
                        tintCol = tintCol,
                        tile = tileCustom,
                    })
                elseif TextureRenderer.drawActionWindowBg and anim == 'A_Listbox_Background1' then
                    TextureRenderer.drawActionWindowBg(dl, winPosX, winPosY, winSizeX, winSizeY, {
                        tile = tileCustom,
                        tintCol = tintCol,
                        shadows = false,
                    })
                end
            end)
        end

        -- Add extra button spacing for textured themes
        local pushedItemSpacing = false
        local isTextured = Themes.isTexturedTheme and Themes.isTexturedTheme(themeName)
        if isTextured then
            imgui.PushStyleVar(ImGuiStyleVar.ItemSpacing, 8, 4)
            pushedItemSpacing = 1
        end

        -- Read button scale setting
        local btnScale = tonumber(Core.Settings.SideKickMainButtonScale) or 1.0
        -- Push scaled FramePadding so buttonW() reads correct padding for centering
        local pushedBtnScale = false
        if btnScale ~= 1.0 then
            imgui.PushStyleVar(ImGuiStyleVar.FramePadding, math.floor(4 * btnScale), math.floor(2 * btnScale))
            pushedBtnScale = true
        end

        local assistOn = (Core.Settings.CombatMode or 'off') == 'assist'
        local chaseOn = Core.Settings.ChaseEnabled == true
        local burnOn = Core.Settings.BurnActive == true

        local isInvited = mq.TLO.Me and mq.TLO.Me.Invited and mq.TLO.Me.Invited() or false
        local inviteLabel = isInvited and 'Join##grp' or 'Invite##grp'

        local cogIcon = (Icons and (Icons.MD_SETTINGS or Icons.FA_COG)) or 'Options'
        local closeIcon = (Icons and (Icons.FA_TIMES or Icons.MD_CLOSE)) or 'X'
        local gtSettingsIcon = (Icons and (Icons.FA_USERS or Icons.MD_GROUP)) or 'GT'

        -- Center the row contents in the bar (works with or without match-GT-width).
        do
            -- Use shared vecX from Helpers
            local vecX = Helpers.vecX
            local function visibleLabel(lbl)
                lbl = tostring(lbl or '')
                return (lbl:gsub('##.*$', ''))
            end
            local function textW(txt)
                if Helpers and Helpers.textWidth then return Helpers.textWidth(txt) end
                local w = imgui.CalcTextSize(tostring(txt or ''))
                return vecX(w)
            end
            local function getStyleVec2(field, defaultX)
                local style = (imgui.GetStyle and imgui.GetStyle()) or nil
                if not style then return defaultX end
                local ok, v = pcall(function() return style[field] end)
                if not ok or v == nil then
                    ok, v = pcall(function() return style[tostring(field)] end)
                end
                if not ok or v == nil then return defaultX end
                if type(v) == 'number' then return tonumber(v) or defaultX end
                if type(v) == 'table' then return tonumber(v.x or v[1]) or defaultX end
                -- userdata: attempt x field access
                local ok2, x = pcall(function() return v.x end)
                if ok2 and x ~= nil then return tonumber(x) or defaultX end
                local ok3, x2 = pcall(function() return v[1] end)
                if ok3 and x2 ~= nil then return tonumber(x2) or defaultX end
                return defaultX
            end
            local function buttonW(lbl)
                local padX = getStyleVec2('FramePadding', 4)
                local spacingX = getStyleVec2('ItemSpacing', 8)
                local w = textW(visibleLabel(lbl)) + padX * 2
                return w, spacingX
            end

            local parts = {}
            table.insert(parts, { kind = 'btn', label = 'Pause##sk' })
            table.insert(parts, { kind = 'btn', label = 'Assist##sk' })
            table.insert(parts, { kind = 'btn', label = 'Chase##sk' })
            table.insert(parts, { kind = 'btn', label = 'Burn##sk' })

            -- Always show group control buttons (no longer requires docking)
            table.insert(parts, { kind = 'txt', text = '|' })
            table.insert(parts, { kind = 'btn', label = inviteLabel })
            table.insert(parts, { kind = 'btn', label = 'Disband##grp' })
            table.insert(parts, { kind = 'txt', text = '|' }) -- divider between Disband and AFollow
            table.insert(parts, { kind = 'btn', label = 'AFollow##grp' })
            table.insert(parts, { kind = 'btn', label = 'GChase##grp' })
            table.insert(parts, { kind = 'btn', label = 'Come##grp' })
            table.insert(parts, { kind = 'btn', label = 'Travel##grp' })
            table.insert(parts, { kind = 'btn', label = 'Mimic##grp' })
            table.insert(parts, { kind = 'btn', label = 'Doors##grp' })

            table.insert(parts, { kind = 'txt', text = '|' })
            table.insert(parts, { kind = 'btn', label = tostring(cogIcon) .. '##SideKickSettings' })
            -- Always show GT control buttons (no longer requires docking)
            local lockIcon = (Icons and Icons.FA_LOCK or 'L')
            table.insert(parts, { kind = 'btn', label = tostring(lockIcon) .. '##GTLock' })
            table.insert(parts, { kind = 'btn', label = tostring(gtSettingsIcon) .. '##GTSettings' })
            table.insert(parts, { kind = 'btn', label = tostring(closeIcon) .. '##ExitBoth' })

            local totalW = 0
            local spacingX = 0
            local count = 0
            for _, p in ipairs(parts) do
                count = count + 1
                if p.kind == 'txt' then
                    totalW = totalW + textW(p.text)
                else
                    local bw, sx = buttonW(p.label)
                    totalW = totalW + bw
                    if sx > 0 then spacingX = sx end
                end
            end
            if count > 1 and spacingX > 0 then
                totalW = totalW + spacingX * (count - 1)
            end

            local avail = imgui.GetContentRegionAvail()
            local availW = vecX(avail)
            local curX = imgui.GetCursorPosX()
            local offset = math.max(0, (availW - totalW) / 2)
            imgui.SetCursorPosX(curX + offset)
        end

        -- Pop the centering FramePadding; each button function pushes its own
        if pushedBtnScale then imgui.PopStyleVar() end

        local pausedOn = Core.Settings.AutomationPaused == true
        toggleButton('Pause##sk', pausedOn, function()
            enqueue(function()
                Core.set('AutomationPaused', not pausedOn)
                Core.forceSave()
            end)
        end, btnScale)
        -- Right-click: apply the same explicit state to the whole group over
        -- DanNet (explicit pause/resume rather than toggle, so characters
        -- whose states drifted apart all land in the same state).
        if imgui.IsItemClicked(1) then
            local newPaused = not pausedOn
            enqueue(function()
                Core.set('AutomationPaused', newPaused)
                Core.forceSave()
                mq.cmdf('/squelch /dgae %s', newPaused and '/skpause' or '/skunpause')
            end)
        end
        if imgui.IsItemHovered() then
            imgui.SetTooltip('Pause all automation\nRight-click: pause/resume the entire group (DanNet)')
        end

        imgui.SameLine()
        toggleButton('Assist##sk', assistOn, function()
            enqueue(function()
                Core.set('CombatMode', assistOn and 'off' or 'assist')
                Core.forceSave()
            end)
        end, btnScale)
        if imgui.IsItemHovered() then imgui.SetTooltip('Toggle Assist') end

        imgui.SameLine()
        toggleButton('Chase##sk', chaseOn, function()
            enqueue(function()
                Core.set('ChaseEnabled', not chaseOn)
                Core.forceSave()
            end)
        end, btnScale)
        if imgui.IsItemHovered() then imgui.SetTooltip('Toggle Chase') end

        imgui.SameLine()
        toggleButton('Burn##sk', burnOn, function()
            enqueue(function() Core.set('BurnActive', not burnOn) end)
        end, btnScale)
        if imgui.IsItemHovered() then imgui.SetTooltip('Toggle Burn phase') end

        -- Always show group control buttons (no longer requires docking)
        imgui.SameLine()
        imgui.Text('|')
        imgui.SameLine()

        if animatedButton(inviteLabel, btnScale) then
            mq.cmd('/keypress ctrl+i')
        end
        if imgui.IsItemHovered() then imgui.SetTooltip(isInvited and 'Accept group invite' or 'Invite target to group') end

            imgui.SameLine()
            if animatedButton('Disband##grp', btnScale) then
                mq.cmdf('/disband')
            end
            if imgui.IsItemHovered() then imgui.SetTooltip('Disband group') end

            imgui.SameLine()
            imgui.Text('|')
            imgui.SameLine()

            local isFollowing = _G.GroupTargetFollowing or false
            toggleButton('AFollow##grp', isFollowing, function()
                local inRaid = (tonumber(mq.TLO.Raid and mq.TLO.Raid.Members and mq.TLO.Raid.Members() or 0) or 0) > 0
                local dgCmd = inRaid and '/dgre' or '/dgge'
                if isFollowing then
                    mq.cmdf('/squelch %s /afollow off', dgCmd)
                    _G.GroupTargetFollowing = false
                else
                    mq.cmdf('/squelch %s /afollow spawn ${Me.ID}', dgCmd)
                    _G.GroupTargetFollowing = true
                end
            end, btnScale)
            if imgui.IsItemHovered() then imgui.SetTooltip('Toggle /afollow for group (broadcast)') end

            imgui.SameLine()
            local groupChaseActive = _G.GroupTargetChaseToggle or false
            toggleButton('GChase##grp', groupChaseActive, function()
                _G.GroupTargetChaseToggle = not groupChaseActive
                local inRaid = (tonumber(mq.TLO.Raid and mq.TLO.Raid.Members and mq.TLO.Raid.Members() or 0) or 0) > 0
                local dgCmd = inRaid and '/dgre' or '/dgge'
                if _G.GroupTargetChaseToggle then
                    mq.cmdf('/squelch %s /skchaseon', dgCmd)
                else
                    mq.cmdf('/squelch %s /skchaseoff', dgCmd)
                end
            end, btnScale)
            if imgui.IsItemHovered() then imgui.SetTooltip('Toggle group chase (broadcast)') end

            imgui.SameLine()
            if animatedButton('Come##grp', btnScale) then
                local inRaid = (tonumber(mq.TLO.Raid and mq.TLO.Raid.Members and mq.TLO.Raid.Members() or 0) or 0) > 0
                local dgCmd = inRaid and '/dgre' or '/dgge'
                mq.cmdf('/squelch %s /nav id %d', dgCmd, mq.TLO.Me.ID() or 0)
            end
            if imgui.IsItemHovered() then imgui.SetTooltip('Tell group to nav to you (broadcast)') end

            imgui.SameLine()
            if animatedButton('Travel##grp', btnScale) then
                local inRaid = (tonumber(mq.TLO.Raid and mq.TLO.Raid.Members and mq.TLO.Raid.Members() or 0) or 0) > 0
                local dgCmd = inRaid and '/dgex' or '/dgge'
                mq.cmdf('/squelch %s /travelto %s', dgCmd, mq.TLO.Zone.ShortName() or '')
            end
            if imgui.IsItemHovered() then imgui.SetTooltip('Tell group to travel to your zone (broadcast)') end

            imgui.SameLine()
            local mimicActive = _G.GroupTargetMimicToggle or false
            toggleButton('Mimic##grp', mimicActive, function()
                _G.GroupTargetMimicToggle = not mimicActive
            end, btnScale)
            if imgui.IsItemHovered() then imgui.SetTooltip('Toggle group mimic mode (local)') end

            imgui.SameLine()
            if animatedButton('Doors##grp', btnScale) then
                mq.cmd('/dga /doortarget')
                mq.cmd('/dga /click left door')
            end
            if imgui.IsItemHovered() then imgui.SetTooltip('Target nearest door and click it (broadcast)') end

        imgui.SameLine()
        imgui.Text('|')
        imgui.SameLine()

        local wasOpen = State.settingsOpen == true
        if wasOpen then
            imgui.PushStyleColor(ImGuiCol.Button, 0.2, 0.6, 0.8, 1.0)
            imgui.PushStyleColor(ImGuiCol.ButtonHovered, 0.3, 0.7, 0.9, 1.0)
            imgui.PushStyleColor(ImGuiCol.ButtonActive, 0.1, 0.5, 0.7, 1.0)
        end
        if animatedSmallButton(tostring(cogIcon) .. '##SideKickSettings', btnScale) then
            State.settingsOpen = not State.settingsOpen
        end
        if wasOpen then imgui.PopStyleColor(3) end
        if imgui.IsItemHovered() then imgui.SetTooltip(State.settingsOpen and 'Close Options' or 'Open Options') end

        -- Always show GT control buttons (no longer requires docking)
        imgui.SameLine()
        -- Lock button for GroupTarget
        local gt = getStableGroupTargetBounds()
        local gtLocked = gt and gt.locked == true
        local lockIcon = gtLocked and (Icons and Icons.FA_LOCK or 'L') or (Icons and Icons.FA_UNLOCK or 'U')
        if gtLocked then
            imgui.PushStyleColor(ImGuiCol.Button, 0.6, 0.5, 0.1, 0.9)
            imgui.PushStyleColor(ImGuiCol.ButtonHovered, 0.7, 0.6, 0.2, 1.0)
            imgui.PushStyleColor(ImGuiCol.ButtonActive, 0.5, 0.4, 0.1, 1.0)
        end
        if animatedSmallButton(tostring(lockIcon) .. '##GTLock', btnScale) then
            ActorsCoordinator.sendToGroupTarget({ id = 'sidekick:toggle_lock' })
        end
        if gtLocked then imgui.PopStyleColor(3) end
        if imgui.IsItemHovered() then imgui.SetTooltip(gtLocked and 'Unlock GroupTarget Position' or 'Lock GroupTarget Position') end

        imgui.SameLine()
        if animatedSmallButton(tostring(gtSettingsIcon) .. '##GTSettings', btnScale) then
            ActorsCoordinator.sendToGroupTarget({ id = 'sidekick:toggle_settings' })
        end
        if imgui.IsItemHovered() then imgui.SetTooltip('GroupTarget Settings') end

        -- Exit Both button
        imgui.SameLine()
        imgui.PushStyleColor(ImGuiCol.Button, 0.6, 0.2, 0.2, 0.8)
        imgui.PushStyleColor(ImGuiCol.ButtonHovered, 0.8, 0.3, 0.3, 1.0)
        imgui.PushStyleColor(ImGuiCol.ButtonActive, 0.5, 0.1, 0.1, 1.0)
        if animatedSmallButton(tostring(closeIcon) .. '##ExitBoth', btnScale) then
            ActorsCoordinator.sendToGroupTarget({ id = 'sidekick:exit' })
            State.settingsOpen = false
            State.open = false
            State.isRunning = false  -- Terminate the script
        end
        imgui.PopStyleColor(3)
        if imgui.IsItemHovered() then imgui.SetTooltip('Exit Both (SideKick + GroupTarget on this character)') end

        local px, py = vec2xy(imgui.GetWindowPos())
        local pw, ph = vec2xy(imgui.GetWindowSize())
        State._mainBarLast = { x = px, y = py, w = pw, h = ph }

        _G.SideKickState = {
            running = true,
            timestamp = os.clock(),
            docked = dockedToGT,
            anchor = mainAnchor,
            anchorTarget = mainAnchorTarget,
            syncThemeWithGT = Core.Settings.SideKickSyncThemeWithGT == true,
            activeTheme = tostring(Core.Settings.SideKickTheme or 'Classic'),
            settingsOpen = State.settingsOpen == true,
            x = px,
            y = py,
            width = pw,
            height = ph,
        }
        -- Export settings for external scripts (GroupTarget command bar)
        _G.SideKickSettings = Core.Settings
        if Anchor and Anchor.updateWindowBounds then
            Anchor.updateWindowBounds('sidekick_main', imgui)
        end

        -- Pop item spacing if we pushed it for textured theme
        if pushedItemSpacing then imgui.PopStyleVar(pushedItemSpacing) end
    end

        imgui.End()
        imgui.PopStyleVar(2)
        if pushedTheme > 0 then imgui.PopStyleColor(pushedTheme) end
        if pushedTexturedBg then imgui.PopStyleColor() end
    end

    local openTarget = State.settingsOpen and 1.0 or 0.0
    local manualOptions = Core.Settings.SideKickOptionsManual ~= false
    local heightFactor = openTarget
    if not manualOptions and iam and iam.TweenFloat then
        heightFactor = iam.TweenFloat('sk_settings_height', imgui.GetID('hfactor'), openTarget, 0.5, _ezSpringSettings, IamPolicy.Crossfade, imgui.GetIO().DeltaTime)
    end

    if (manualOptions and State.settingsOpen) or (not manualOptions and heightFactor > 0.01) then
        local mainX = tonumber(State._mainBarLast.x) or 50
        local mainY = tonumber(State._mainBarLast.y) or 160
        local mainW = math.max(350, tonumber(State._mainBarLast.w) or 350)
        local settingsH = math.max(90, math.floor(480 * heightFactor + 0.5))
        local settingsY = mainY - settingsH - 2

        local optW = tonumber(Core.Settings.SideKickOptionsWidth) or 0
        if optW <= 0 then optW = mainW end
        local optH = tonumber(Core.Settings.SideKickOptionsHeight) or 0
        if optH <= 0 then optH = 480 end
        local optX = tonumber(Core.Settings.SideKickOptionsPosX)
        local optY = tonumber(Core.Settings.SideKickOptionsPosY)

        if imgui.SetNextWindowPos then
            if manualOptions then
                local px = optX
                local py = optY
                if px == nil or py == nil or px < 0 or py < 0 then
                    px = mainX
                    py = mainY - optH - 2
                end
                imgui.SetNextWindowPos(px, py, (ImGuiCond and ImGuiCond.FirstUseEver) or 4)
            else
                imgui.SetNextWindowPos(mainX, settingsY, (ImGuiCond and ImGuiCond.Always) or 0)
            end
        end
        if imgui.SetNextWindowSize then
            if manualOptions then
                imgui.SetNextWindowSize(optW, optH, (ImGuiCond and ImGuiCond.FirstUseEver) or 4)
            else
                imgui.SetNextWindowSize(mainW, settingsH, (ImGuiCond and ImGuiCond.Always) or 0)
            end
        end

        local sFlags = 0
        if ImGuiWindowFlags and bit32 and bit32.bor then
            sFlags = bit32.bor(
                ImGuiWindowFlags.NoTitleBar or 0,
                ImGuiWindowFlags.NoCollapse or 0,
                ImGuiWindowFlags.NoScrollbar or 0
            )
            if not manualOptions then
                sFlags = bit32.bor(
                    sFlags,
                    ImGuiWindowFlags.NoResize or 0,
                    ImGuiWindowFlags.NoMove or 0
                )
            end
        end

        local pushedTheme2 = Themes.pushWindowTheme(imgui, themeName, {
            windowAlpha = 0.96,
            childAlpha = 0.96 * 0.6,
            popupAlpha = 0.98,
            ImGuiCol = ImGuiCol,
        })
        imgui.PushStyleVar(ImGuiStyleVar.WindowRounding, 6)
        imgui.PushStyleVar(ImGuiStyleVar.WindowPadding, 8, 8)

        local optionsOpen, shown = imgui.Begin('SideKick Options##SettingsPopup', true, sFlags)
        if shown == nil then shown, optionsOpen = optionsOpen, true end
        if optionsOpen == false then State.settingsOpen = false end
        local _popupOk, _popupErr = true, nil
        if shown then _popupOk, _popupErr = pcall(function()
            local closeIcon2 = (Icons and (Icons.FA_TIMES or Icons.MD_CLOSE)) or 'X'
            local availWidth = imgui.GetContentRegionAvail()
            if type(availWidth) ~= 'number' then availWidth = availWidth.x or availWidth[1] or mainW end
            imgui.SetCursorPosX(imgui.GetCursorPosX() + availWidth - 25)
            imgui.PushStyleColor(ImGuiCol.Button, 0.6, 0.2, 0.2, 0.8)
            imgui.PushStyleColor(ImGuiCol.ButtonHovered, 0.8, 0.3, 0.3, 1.0)
            imgui.PushStyleColor(ImGuiCol.ButtonActive, 0.5, 0.1, 0.1, 1.0)
            if imgui.SmallButton(tostring(closeIcon2) .. '##CloseOptions') then
                State.settingsOpen = false
            end
            imgui.PopStyleColor(3)

            if imgui.BeginTabBar('##sidekick_popup_tabs') then
                if imgui.BeginTabItem('Buttons') then
                    -- Sub-section selector via radio buttons (avoids nested
                    -- ImGui TabBars which conflict with the inner TabBar that
                    -- Grids.drawAbilities creates for AAs/Discs).
                    local sub = tostring(Core.Settings.SideKickButtonsSubtab or 'aas')
                    if sub ~= 'aas' and sub ~= 'discs' and sub ~= 'skills' then sub = 'aas' end
                    do
                        local function radio(label, value)
                            if imgui.RadioButton(label .. '##sub_' .. value, sub == value) then
                                Core.set('SideKickButtonsSubtab', value)
                                sub = value
                            end
                        end
                        radio("AA's", 'aas')
                        imgui.SameLine()
                        radio('Discs', 'discs')
                        imgui.SameLine()
                        radio('Skills', 'skills')
                        imgui.Separator()
                    end

                    if sub == 'aas' then
                        local ok, err = pcall(function()
                            local Grids = LZ.getGrids()
                            local aas = {}
                            for _, def in ipairs(State.abilities or {}) do
                                if tostring(def.kind or 'aa') ~= 'disc' then table.insert(aas, def) end
                            end
                            if Grids then Grids.drawAbilities({
                                abilities = aas,
                                settings = Core.Settings,
                                modeLabels = Abilities.MODE_LABELS,
                                onToggle = function(key, value) Core.set(key, value) end,
                                onMode = function(key, value) Core.set(key, value) end,
                                onActivate = function(def) enqueue(function() Abilities.activate(def) end) end,
                                cooldownProbe = function(row) return Cooldowns.probe(row) end,
                                helpers = Helpers,
                            }) end
                        end)
                        if not ok then imgui.TextColored(1, 0.3, 0.3, 1, 'AA section error: ' .. tostring(err)) end
                    elseif sub == 'discs' then
                        local ok, err = pcall(function()
                            local Grids = LZ.getGrids()
                            local discs = {}
                            for _, def in ipairs(State.abilities or {}) do
                                if tostring(def.kind or '') == 'disc' then table.insert(discs, def) end
                            end
                            if Grids then Grids.drawAbilities({
                                abilities = discs,
                                settings = Core.Settings,
                                modeLabels = Abilities.MODE_LABELS,
                                onToggle = function(key, value) Core.set(key, value) end,
                                onMode = function(key, value) Core.set(key, value) end,
                                onActivate = function(def) enqueue(function() Abilities.activate(def) end) end,
                                cooldownProbe = function(row) return Cooldowns.probe(row) end,
                                helpers = Helpers,
                            }) end
                        end)
                        if not ok then imgui.TextColored(1, 0.3, 0.3, 1, 'Disc section error: ' .. tostring(err)) end
                    elseif sub == 'skills' then
                        do
                            local skTabOk, skTabErr = pcall(function()
                            local Skills = require('sidekick-next.utils.skills')
                            local function _truthy(v)
                                if v == true then return true end
                                if v == false or v == nil then return false end
                                if type(v) == 'number' then return v ~= 0 end
                                if type(v) == 'string' then
                                    local s = v:lower()
                                    return s == '1' or s == 'true' or s == 'yes' or s == 'on'
                                end
                                return false
                            end
                            local barEnabled = _truthy(Core.Settings.SideKickSkillBarEnabled)
                            local newBarEnabled, barChanged = imgui.Checkbox('Show Skill Bar', barEnabled)
                            if barChanged then Core.set('SideKickSkillBarEnabled', newBarEnabled) end

                            imgui.Separator()
                            imgui.Text('Bar layout')

                            local cell = tonumber(Core.Settings.SideKickSkillBarCell) or 48
                            local newCell, cellChanged = imgui.SliderInt('Cell size##sk_cell', cell, 24, 96)
                            if cellChanged then Core.set('SideKickSkillBarCell', newCell) end

                            local rows = tonumber(Core.Settings.SideKickSkillBarRows) or 2
                            local newRows, rowsChanged = imgui.SliderInt('Rows##sk_rows', rows, 1, 8)
                            if rowsChanged then Core.set('SideKickSkillBarRows', newRows) end

                            local gap = tonumber(Core.Settings.SideKickSkillBarGap) or 4
                            local newGap, gapChanged = imgui.SliderInt('Gap##sk_gap', gap, 0, 16)
                            if gapChanged then Core.set('SideKickSkillBarGap', newGap) end

                            local pad = tonumber(Core.Settings.SideKickSkillBarPad) or 6
                            local newPad, padChanged = imgui.SliderInt('Padding##sk_pad', pad, 0, 16)
                            if padChanged then Core.set('SideKickSkillBarPad', newPad) end

                            local bg = tonumber(Core.Settings.SideKickSkillBarBgAlpha) or 0.85
                            local newBg, bgChanged = imgui.SliderFloat('Background alpha##sk_bg', bg, 0.0, 1.0)
                            if bgChanged then Core.set('SideKickSkillBarBgAlpha', newBg) end

                            imgui.Separator()
                            imgui.Text('Visible skills')
                            imgui.SameLine()
                            if imgui.Button('Refresh##SideKickSkillsRefresh') then
                                Skills.refresh()
                            end
                            local list = Skills.discover()
                            if #list == 0 then
                                imgui.TextDisabled('No activated skills detected for this character.')
                            else
                                for _, sk in ipairs(list) do
                                    local key = 'SideKickSkill_' .. tostring(sk.index)
                                    local cur = _truthy(Core.Settings[key])
                                    local newVal, changed = imgui.Checkbox(string.format('%s##%s', sk.name, key), cur)
                                    if changed then Core.set(key, newVal) end
                                end
                            end
                            end)
                            if not skTabOk then imgui.TextColored(1, 0.3, 0.3, 1, 'Skills section error: ' .. tostring(skTabErr)) end
                        end
                    end
                    imgui.EndTabItem()
                end

                if imgui.BeginTabItem('Options') then
                    local debugSettings = Core.Settings.SideKickDebugSettings == true
                    local themeNames = Themes.getThemeNames()

                    -- DEBUG: Log theme info once per second
                    State._lastThemeDebugLog = State._lastThemeDebugLog or 0
                    if os.clock() - State._lastThemeDebugLog > 1.0 then
                        State._lastThemeDebugLog = os.clock()
                        log.verbose('Options tab: %d themes, current=%s', #themeNames, tostring(Core.Settings.SideKickTheme or 'nil'))
                    end

                    if debugSettings then
                        local TL = LZ.getThrottledLog()
                        if TL and TL.log then
                            TL.log('debug_settings_themes', 2, 'Themes.getThemeNames()=%d current=%s',
                                #themeNames,
                                tostring(Core.Settings.SideKickTheme or ''))
                        end
                    end

                    -- Debug toggle here (outside SettingsUI) so we can still enable logging
                    -- even when SettingsUI widgets aren't persisting.
                    do
                        local dbg = Core.Settings.SideKickDebugSettings == true
                        if imgui.SmallButton((dbg and 'Debug: ON' or 'Debug: OFF') .. '##sk_debug_settings') then
                            dbg = not dbg
                            Core.set('SideKickDebugSettings', dbg)
                            if _G.SIDEKICK_NEXT_CONFIG then
                                _G.SIDEKICK_NEXT_CONFIG.DEBUG_SETTINGS = dbg
                            end
                            debugSettings = dbg
                        end
                        imgui.SameLine()
                        imgui.TextDisabled('Settings logging')
                        imgui.Separator()
                    end

                    local settingsOk, settingsErr = pcall(function()
                        SettingsUI.draw(
                            Core.Settings,
                            themeNames,
                            function(key, value)
                                log.debug('onChange: key=%s value=%s', tostring(key), tostring(value))
                                if tostring(key) == 'SideKickTheme' then
                                    State._themeLocalSetAt = os.clock()
                                    log.debug('Theme change, holdUntil=%.2f', State._themeLocalSetAt + 5.0)
                                end
                                Core.set(key, value)
                                local settingKey = tostring(key)
                                if settingKey:match('^Meditation') or settingKey:match('^Chase')
                                    or settingKey:match('^Rez') or settingKey:match('^AutoRez')
                                    or settingKey == 'AutoAcceptRez' or settingKey == 'CombatMode' then
                                    enqueue(function() Core.forceSave() end)
                                end
                                log.debug('Core.set done, new=%s', tostring(Core.Settings[tostring(key)]))
                            end
                        )
                    end)
                    if not settingsOk then
                        imgui.TextColored(1, 0.3, 0.3, 1, 'Options error: ' .. tostring(settingsErr))
                    end

                    local extrasOk, extrasErr = pcall(function()
                        -- Remote Abilities settings section
                        imgui.Separator()
                        if imgui.CollapsingHeader('Remote Abilities') then
                            local RemoteAbilities = LZ.getRemoteAbilities()
                            if RemoteAbilities then
                                local raOpen = RemoteAbilities.isOpen()
                                local changed
                                raOpen, changed = imgui.Checkbox('Show Remote Ability Bar', raOpen)
                                if changed then
                                    RemoteAbilities.setOpen(raOpen)
                                end
                                if imgui.Button('Configure Remote Abilities') then
                                    RemoteAbilities.toggleSettings()
                                end
                            end
                        end

                        -- Aggro Warning settings section
                        if imgui.CollapsingHeader('Warnings') then
                            local AggroWarning = LZ.getAggroWarning()
                            if AggroWarning then AggroWarning.drawSettings() end
                        end
                    end)
                    if not extrasOk then
                        imgui.TextColored(1, 0.3, 0.3, 1,
                            'Options extras error: ' .. tostring(extrasErr))
                    end

                    imgui.EndTabItem()
                end

                -- Spell Set tab
                if imgui.BeginTabItem('Spell Set') then
                    local SSE = LZ.getSpellSetEditor()
                    if SSE then
                        local ok, err = pcall(function() SSE.drawContent() end)
                        if not ok then
                            imgui.TextColored(1, 0.3, 0.3, 1, 'Error: ' .. tostring(err))
                        end
                    end
                    imgui.EndTabItem()
                end

                -- Healing/rez settings. Rez-capable utility classes such as
                -- NEC get the rez surface without loading Healing Intelligence.
                local isHealerClass = HealerClasses.isSupported(State.classShort)
                local isRezClass = RezData.isRezClass(State.classShort)
                if isHealerClass or isRezClass then
                    if imgui.BeginTabItem(isHealerClass and 'Healing' or 'Resurrection') then
                        -- Sub-tabs within Healing
                        if imgui.BeginTabBar('HealingSubTabs') then
                            -- Settings sub-tab
                            local HealSettingsTab = LZ.getHealingSettingsTab()
                            if HealSettingsTab then
                                if imgui.BeginTabItem('Settings') then
                                    local ok, err = pcall(function()
                                        HealSettingsTab.draw(Core.Settings, Themes.getThemeNames(), function(key, val)
                                            Core.set(key, val)
                                            local settingKey = tostring(key)
                                            if settingKey:match('^Rez') or settingKey:match('^AutoRez')
                                                or settingKey == 'AutoAcceptRez' then
                                                enqueue(function() Core.forceSave() end)
                                            end
                                        end)
                                    end)
                                    if not ok then
                                        imgui.TextColored(1, 0.3, 0.3, 1, 'Error: ' .. tostring(err))
                                    end
                                    imgui.EndTabItem()
                                end
                            end

                            -- Monitor sub-tab for supported Healing Intelligence classes
                            if isHealerClass then
                                local HealMonitor = LZ.getHealingMonitor()
                                if HealMonitor and HealMonitor.isInitialized and HealMonitor.isInitialized() then
                                    if imgui.BeginTabItem('Monitor') then
                                        HealMonitor.drawContent()
                                        imgui.EndTabItem()
                                    end
                                else
                                    if imgui.BeginTabItem('Monitor') then
                                        imgui.TextDisabled('Healing monitor initializing...')
                                        imgui.TextDisabled('Enter combat to activate')
                                        imgui.EndTabItem()
                                    end
                                end
                            end

                            imgui.EndTabBar()
                        end
                        imgui.EndTabItem()
                    end
                end

                -- Items tab
                if imgui.BeginTabItem('Items') then
                    local ItemsTab = LZ.getItemsTab()
                    if ItemsTab then
                        local ok, err = pcall(function()
                            ItemsTab.draw(Core.Settings, Themes.getThemeNames(), function(key, val)
                                Core.set(key, val)
                            end)
                        end)
                        if not ok then
                            imgui.TextColored(1, 0.3, 0.3, 1, 'Error: ' .. tostring(err))
                        end
                    else
                        imgui.TextDisabled('Items module not available')
                    end
                    imgui.EndTabItem()
                end

                -- Buffs tab
                if imgui.BeginTabItem('Buffs') then
                    local BuffsTab = LZ.getBuffsTab()
                    if BuffsTab then
                        local ok, err = pcall(function()
                            BuffsTab.draw(Core.Settings, Themes.getThemeNames(), function(key, val)
                                Core.set(key, val)
                            end)
                        end)
                        if not ok then
                            imgui.TextColored(1, 0.3, 0.3, 1, 'Error: ' .. tostring(err))
                        end
                    else
                        imgui.TextDisabled('Buffs module not available')
                    end
                    imgui.EndTabItem()
                end

                imgui.EndTabBar()
            end

            -- Cursor item icon mirror — drawing imgui content while an EQ item
            -- is on the cursor was previously triggering "Missing End()" crashes
            -- via DrawTextureAnimation. Disabled until we can audit the binding.
            -- (When enabled, gate the entire block in a single pcall so any
            -- failure can't leak imgui state.)

            if manualOptions then
                local winX, winY = vec2xy(imgui.GetWindowPos())
                local winW, winH = vec2xy(imgui.GetWindowSize())
                if imgui.IsMouseReleased then
                    local okRel, released = pcall(imgui.IsMouseReleased, 0)
                    if okRel and released then
                        local rx = math.floor((winX or 0) + 0.5)
                        local ry = math.floor((winY or 0) + 0.5)
                        local rw = math.floor((winW or 0) + 0.5)
                        local rh = math.floor((winH or 0) + 0.5)
                        if Core.Settings.SideKickOptionsPosX ~= rx then Core.set('SideKickOptionsPosX', rx) end
                        if Core.Settings.SideKickOptionsPosY ~= ry then Core.set('SideKickOptionsPosY', ry) end
                        if Core.Settings.SideKickOptionsWidth ~= rw then Core.set('SideKickOptionsWidth', rw) end
                        if Core.Settings.SideKickOptionsHeight ~= rh then Core.set('SideKickOptionsHeight', rh) end
                    end
                end
            end
        end) end
        if not _popupOk then
            -- Surface the error in chat so it doesn't silently fail.
            pcall(function()
                if mq and mq.cmd then
                    mq.cmdf('/echo \\ar[SideKick popup]\\ax %s', tostring(_popupErr))
                end
            end)
        end
        imgui.End()
        imgui.PopStyleVar(2)
        if pushedTheme2 > 0 then imgui.PopStyleColor(pushedTheme2) end
    end
end

local _automationInitDone = false
local function tickAutomation()
    local now = os.clock()
    if (now - (State.lastAutomationTick or 0)) < 0.05 then return end
    State.lastAutomationTick = now

    -- Deferred init: trigger lazy.init() modules on first tick (spreads load after startup)
    if not _automationInitDone then
        local ae = LZ.getActionExecutor()
        local sl = LZ.getSpellLineup()
        local ccl = LZ.getClassConfigLoader()
        _automationInitDone = (ae ~= nil) and (sl ~= nil) and (ccl ~= nil)
    end

    -- Global pause check - stop all automation when paused
    if Core.Settings.AutomationPaused == true then return end

    local playStyle = tostring(Core.Settings.AutomationLevel or 'auto'):lower()
    local allowAbilityAutomation = (playStyle ~= 'manual')
    local allowMovementAutomation = (playStyle == 'auto')

    PerfMonitor.beginFrame()

    -- Update runtime cache (before other automation)
    PerfMonitor.begin('RuntimeCache')
    do local M = LZ.getRuntimeCache() if M then M.tick() end end
    PerfMonitor.finish('RuntimeCache')

    local monolithicMode = _G.SIDEKICK_NEXT_CONFIG
        and _G.SIDEKICK_NEXT_CONFIG.COORDINATED_MODE == false
    if monolithicMode then
        -- These modules own event handlers and cast state. In coordinated mode
        -- their dedicated workers are the only instances allowed to initialize.
        PerfMonitor.begin('CC')
        local CC = LZ.getCC()
        if CC then
            CC.tick()
            if allowAbilityAutomation then CC.mezTick(Core.Settings) end
        end
        PerfMonitor.finish('CC')

        PerfMonitor.begin('Buff')
        do local M = LZ.getBuff() if M then M.tick() end end
        PerfMonitor.finish('Buff')

        PerfMonitor.begin('SpellEngine')
        do local M = LZ.getSpellEngine() if M then M.tick() end end
        PerfMonitor.finish('SpellEngine')

        PerfMonitor.begin('SpellsetMgr')
        do local M = LZ.getSpellsetManager() if M then M.tick() end end
        PerfMonitor.finish('SpellsetMgr')
    else
        -- Manual UI/test casts may explicitly load a UI-local SpellEngine.
        -- Advance it if present, but do not instantiate it during normal
        -- coordinated automation.
        local loadedSpellEngine = package.loaded['sidekick-next.utils.spell_engine']
        if loadedSpellEngine and loadedSpellEngine.tick then loadedSpellEngine.tick() end
    end

    -- Process events for cast result detection
    mq.doevents()

    -- Chase is local movement controlled by the UI host. It must run in both
    -- coordinated and monolithic modes; worker scripts handle casts/claims but
    -- do not own follower movement.
    PerfMonitor.begin('Chase')
    if allowMovementAutomation then
        Chase.tick()
    elseif Chase and Chase.stopNav then
        Chase.stopNav()
    end
    PerfMonitor.finish('Chase')

    -- In canonical coordinated mode this script is the UI/state host only.
    -- Automatic combat/cast actions are executed exclusively by claimed worker
    -- modules. Local follower movement remains above this return.
    if not monolithicMode then
        PerfMonitor.finishFrame()
        return
    end

    local priorityHealingActive = false
    if playStyle ~= 'manual' then
        PerfMonitor.begin('Healing')
        Healing = getHealingModule()  -- Get appropriate module for current class
        if Healing and Healing.tick then
            log.debug('[HealingTick] calling Healing.tick')
            priorityHealingActive = Healing.tick(Core.Settings) == true
            log.debug('[HealingTick] result=%s', tostring(priorityHealingActive))
        else
            log.debug('[HealingTick] no Healing.tick available')
        end
        PerfMonitor.finish('Healing')
    end

    -- Cure tick (after healing, before rotation engine)
    PerfMonitor.begin('Cures')
    local Cures = LZ.getCures()
    if allowAbilityAutomation and not priorityHealingActive and Cures and Cures.tick then
        Cures.tick(Core.Settings)
    end
    PerfMonitor.finish('Cures')

    -- Run layered rotation engine (replaces flat Abilities.tryAllAbilities)
    PerfMonitor.begin('Rotation')
    local TL = LZ.getThrottledLog()
    local RotationEngine = LZ.getRotationEngine()
    if allowAbilityAutomation and Core.Settings.AutoAbilitiesEnabled ~= false and RotationEngine then
        if debugAutomationLogging and TL then
            TL.log('rotation_start', 15, 'RotationEngine.tick: abilities=%d, burnActive=%s, priorityHealing=%s',
                #(State.abilities or {}), tostring(Burn.active), tostring(priorityHealingActive))
        end
        -- When tank mode is active, tank module owns the aggro layer
        local skipLayers = nil
        if (Core.Settings.CombatMode or 'off') == 'tank' then
            skipLayers = { aggro = true }
        end
        RotationEngine.tick({
            abilities = State.abilities,
            settings = Core.Settings,
            burnActive = Burn.active,
            priorityHealingActive = priorityHealingActive,
            skipLayers = skipLayers,
        })

        -- Process mash queue (ON_COOLDOWN abilities) after rotation
        -- These are instant/off-GCD abilities that fire whenever ready
        RotationEngine.processMashQueue({
            abilities = State.abilities,
            settings = Core.Settings,
        })
    else
        if debugAutomationLogging and TL then
            TL.log('rotation_skip', 15, 'RotationEngine SKIP: allowAbilityAutomation=%s, AutoAbilitiesEnabled=%s',
                tostring(allowAbilityAutomation), tostring(Core.Settings.AutoAbilitiesEnabled))
        end
    end
    PerfMonitor.finish('Rotation')

    PerfMonitor.begin('Burn')
    Burn.tick()
    PerfMonitor.finish('Burn')

    PerfMonitor.begin('Tank')
    local CombatMode = Core.Settings.CombatMode or 'off'
    if allowMovementAutomation and CombatMode == 'tank' then
        Tank.tick(State.abilities, Core.Settings)
    end
    PerfMonitor.finish('Tank')

    PerfMonitor.begin('Assist')
    if allowMovementAutomation then
        if not priorityHealingActive then
            Assist.tick()
        end
    end
    PerfMonitor.finish('Assist')

    PerfMonitor.begin('Items')
    if allowAbilityAutomation and Items and Items.tick and Core.Settings.AutoItemsEnabled ~= false then
        Items.tick()
    end
    PerfMonitor.finish('Items')

    PerfMonitor.finishFrame()
end

local function syncModulesFromSettings()
    local now = os.clock()
    if (now - (State.lastStateSyncTick or 0)) < 0.2 then return end
    State.lastStateSyncTick = now

    -- Optional theme sync from GroupTarget bounds payload.
    if Core.Settings.SideKickSyncThemeWithGT == true then
        local gt = _G.GroupTargetBounds
        local gtTheme = gt and tostring(gt.activeTheme or '') or ''
        local localHoldUntil = (State._themeLocalSetAt or 0) + 5.0  -- Hold for 5 seconds after manual change
        if now >= localHoldUntil and gtTheme ~= '' and gtTheme ~= tostring(Core.Settings.SideKickTheme or '') then
            if (now - (State.lastThemeSyncAt or 0)) >= 1.0 then
                State.lastThemeSyncAt = now
                State._themeFromGTAt = now
                Core.set('SideKickTheme', gtTheme)
            end
        end
    end

    -- Theme sync TO GroupTarget (bidirectional). Avoid ping-pong by suppressing
    -- broadcasts briefly after applying a theme that came from GroupTarget.
    if Core.Settings.SideKickSyncThemeWithGT == true and ActorsCoordinator and ActorsCoordinator.sendToGroupTarget then
        State._lastThemeSentAt = State._lastThemeSentAt or 0
        State._lastThemeSent = State._lastThemeSent or ''
        local suppressUntil = (State._themeFromGTAt or 0) + 1.0
        local curTheme = tostring(Core.Settings.SideKickTheme or '')
        if curTheme ~= '' and curTheme ~= State._lastThemeSent and now >= suppressUntil and (now - State._lastThemeSentAt) >= 0.5 then
            State._lastThemeSentAt = now
            State._lastThemeSent = curTheme
            ActorsCoordinator.sendToGroupTarget({ id = 'sidekick:set_theme', theme = curTheme })
        end
    end

    Chase.state.role = tostring(Core.Settings.ChaseRole or 'ma')
    Chase.state.target = tostring(Core.Settings.ChaseTarget or '')
    Chase.state.distance = tonumber(Core.Settings.ChaseDistance) or 30

    if (Core.Settings.ChaseEnabled == true) ~= (Chase.enabled == true) then
        Chase.setEnabled(Core.Settings.ChaseEnabled == true, { auto = true })
    end

    local assistEnabled = (Core.Settings.CombatMode or 'off') == 'assist'
    CombatAssist.apply_config({
        enabled = assistEnabled,
        assist_at = Core.Settings.AssistAt,
        assist_rng = Core.Settings.AssistRange,
        assist_mode = Core.Settings.AssistMode,
        assist_name = Core.Settings.AssistName,
        stick_cmd = Core.Settings.StickCommand,
    })
    if assistEnabled ~= (Assist.enabled == true) then
        Assist.setEnabled(assistEnabled)
    end

    if (Core.Settings.BurnActive == true) ~= (Burn.active == true) then
        Burn.setActive(Core.Settings.BurnActive == true, { duration = Core.Settings.BurnDuration })
    end
end

local function drawAutostartPrompt()
    if not State.showAutostartPrompt then return end

    local popupId = 'SideKick Autostart##FirstRunPrompt'
    if not imgui.IsPopupOpen(popupId) then
        imgui.OpenPopup(popupId)
    end

    local centerX, centerY = 0, 0
    if imgui.GetMainViewportCenter then
        centerX, centerY = imgui.GetMainViewportCenter()
    end
    if centerX == 0 then
        local vpSize = imgui.GetMainViewport and imgui.GetMainViewport().Size or nil
        if vpSize then
            centerX = (vpSize.x or vpSize[1] or 800) / 2
            centerY = (vpSize.y or vpSize[2] or 600) / 2
        else
            centerX, centerY = 400, 300
        end
    end
    imgui.SetNextWindowPos(centerX, centerY, ImGuiCond.Appearing, 0.5, 0.5)

    local flags = 0
    if ImGuiWindowFlags and bit32 and bit32.bor then
        flags = bit32.bor(
            ImGuiWindowFlags.AlwaysAutoResize or 0,
            ImGuiWindowFlags.NoCollapse or 0,
            ImGuiWindowFlags.NoMove or 0
        )
    end

    local open = imgui.BeginPopupModal(popupId, nil, flags)
    if open then
        imgui.Text('Would you like SideKick to start automatically')
        imgui.Text('when you log in with this character?')
        imgui.Spacing()
        imgui.Separator()
        imgui.Spacing()

        local server = mq.TLO.EverQuest.Server():gsub(" ", "_") or 'Unknown'
        local charName = mq.TLO.Me.CleanName() or 'Unknown'
        imgui.TextDisabled(string.format('Config: %s_%s.cfg', server, charName))
        imgui.Spacing()

        local buttonWidth = 80
        local spacing = 20
        local totalWidth = buttonWidth * 2 + spacing
        local avail = imgui.GetContentRegionAvail()
        local availWidth = (type(avail) == 'number') and avail or (avail.x or avail[1] or 200)
        local startX = (availWidth - totalWidth) / 2
        if startX > 0 then
            imgui.SetCursorPosX(imgui.GetCursorPosX() + startX)
        end

        -- Yes button
        imgui.PushStyleColor(ImGuiCol.Button, 0.2, 0.6, 0.2, 1.0)
        imgui.PushStyleColor(ImGuiCol.ButtonHovered, 0.3, 0.7, 0.3, 1.0)
        imgui.PushStyleColor(ImGuiCol.ButtonActive, 0.15, 0.5, 0.15, 1.0)
        if imgui.Button('Yes', buttonWidth, 0) then
            -- Enable autostart
            local autostartPath = string.format('%s/%s_%s.cfg', mq.configDir, server, charName)
            local currentContents = {}
            local fileHandle = io.open(autostartPath, 'r')
            if fileHandle then
                for line in fileHandle:lines() do
                    currentContents[#currentContents + 1] = line
                end
                fileHandle:close()
            end

            -- Remove existing sidekick entries
            local newLines = {}
            for _, line in ipairs(currentContents) do
                if not line:lower():find('/lua run sidekick', 1, true) then
                    newLines[#newLines + 1] = line
                end
            end
            newLines[#newLines + 1] = '/lua run sidekick-next'

            local outFile = io.open(autostartPath, 'w')
            if outFile then
                for _, line in ipairs(newLines) do
                    outFile:write(line .. '\n')
                end
                outFile:close()
            end

            -- Mark prompt as shown
            Core.set('AutostartPromptShown', true, { source = 'autostart_prompt' })
            State.showAutostartPrompt = false
            imgui.CloseCurrentPopup()
        end
        imgui.PopStyleColor(3)

        imgui.SameLine(0, spacing)

        -- No button
        imgui.PushStyleColor(ImGuiCol.Button, 0.5, 0.2, 0.2, 1.0)
        imgui.PushStyleColor(ImGuiCol.ButtonHovered, 0.6, 0.3, 0.3, 1.0)
        imgui.PushStyleColor(ImGuiCol.ButtonActive, 0.4, 0.15, 0.15, 1.0)
        if imgui.Button('No', buttonWidth, 0) then
            -- Mark prompt as shown without enabling autostart
            Core.set('AutostartPromptShown', true, { source = 'autostart_prompt' })
            State.showAutostartPrompt = false
            imgui.CloseCurrentPopup()
        end
        imgui.PopStyleColor(3)

        imgui.EndPopup()
    end
end

local function main()
    Core.load()
    Logger.configure(Core.Settings)

    if _G.SIDEKICK_NEXT_CONFIG then
        _G.SIDEKICK_NEXT_CONFIG.DEBUG_SETTINGS = Core.Settings.SideKickDebugSettings == true
    end

    -- First-run autostart prompt check
    if not State.autostartPromptChecked then
        State.autostartPromptChecked = true
        local promptShown = Core.Settings.AutostartPromptShown
        if promptShown ~= true then
            State.showAutostartPrompt = true
        end
    end

    -- Humanize binds (/sk_humanize, /skboss, /skfullbore) register when the
    -- module loads in the UI process. Require it here so coordinated mode gets
    -- the binds deterministically instead of depending on which settings tab
    -- first pulls the module in.
    pcall(require, 'sidekick-next.humanize')

    ActorsCoordinator.init()
    LZ.getRezAccept()
    do
        local monitor = LZ.getHealingMonitor()
        if monitor and ActorsCoordinator.registerMessageCallback then
            ActorsCoordinator.registerMessageCallback('heal:telemetry', function(content)
                monitor.setTelemetry(content)
                return true
            end)
        end
    end
    if ActorsCoordinator.registerMessageCallback then
        ActorsCoordinator.registerMessageCallback('rez:telemetry', function(content)
            local debugUi = LZ.getCoordinatorDebug()
            if debugUi and debugUi.setRezTelemetry then
                debugUi.setRezTelemetry(content)
            end
            return true
        end)
        ActorsCoordinator.registerMessageCallback('pull:telemetry', function(content)
            _G.SK_PULL_TELEMETRY = {
                state = tostring(content.state or ''),
                reason = tostring(content.reason or ''),
                pullId = tonumber(content.pullId) or 0,
                campSet = content.campSet == true,
                ownsTarget = content.ownsTarget == true,
                receivedAt = mq.gettime(),
            }
            return true
        end)
    end

    Chase.init({ Core = Core })
    Burn.init({ Core = Core })
    CombatAssist.apply_config({
        enabled = (Core.Settings.CombatMode or 'off') == 'assist',
        assist_at = Core.Settings.AssistAt,
        assist_rng = Core.Settings.AssistRange,
        assist_mode = Core.Settings.AssistMode,
        assist_name = Core.Settings.AssistName,
        stick_cmd = Core.Settings.StickCommand,
    })
    Assist.init({ Core = Core, CombatAssist = CombatAssist })
    Tank.init(Core.Settings)
    -- Cures are owned and initialized by sk_cures in coordinated mode. The
    -- feature-flagged monolithic path initializes them lazily inside its tick.
    -- All other modules init on first access via lazy.init().

    local function queueMuleAssistImport(importArgs)
        local options = { preview = false, importSpellSet = true, activateSpellSet = true }
        local pathParts = {}
        for _, value in ipairs(importArgs or {}) do
            local token = tostring(value or '')
            local lower = token:lower()
            if lower == 'preview' or lower == '--preview' then
                options.preview = true
            elseif lower == 'activate' or lower == '--activate' then
                options.activateSpellSet = true
            elseif lower == 'staged' or lower == '--staged' or lower == 'noactivate' or lower == '--noactivate' then
                options.activateSpellSet = false
            elseif lower == 'settings-only' or lower == '--settings-only' then
                options.importSpellSet = false
            elseif token ~= '' then
                pathParts[#pathParts + 1] = token
            end
        end
        local path = #pathParts > 0 and table.concat(pathParts, ' ') or nil

        enqueue(function()
            local ok, Importer = pcall(require, 'sidekick-next.utils.ini_importer')
            if not ok or not Importer then
                log.error('Unable to load MuleAssist importer: %s', tostring(Importer))
                return
            end
            local result = Importer.run(path, Core, options)
            local lines = Importer.summaryLines(result)
            for i, line in ipairs(lines) do
                if result.ok then log.info('%s', line) else log.error('%s', line) end
            end
            if result.ok and result.plan then
                for _, warning in ipairs(result.plan.warnings or {}) do
                    log.warn('MuleAssist import: %s', warning)
                end
            end
            if result.ok and options.preview and result.plan then
                for _, setting in ipairs(result.plan.settings or {}) do
                    log.info('  %s=%s  <= %s', setting.key, tostring(setting.value), setting.source)
                end
                for _, reason in ipairs(result.plan.ignored or {}) do
                    log.info('  Not imported: %s', reason)
                end
            end
            if result.ok and not options.preview then
                if result.spellSet and result.spellSet.activated then
                    log.info('Imported spell set "%s" is now active. Use /SideKick spellset to review it.',
                        tostring(result.spellSet.name))
                    local Memorize = LZ.getSpellSetMemorize()
                    if Memorize and Memorize.queueApply then
                        Memorize.queueApply(result.spellSet.name, false)
                    end
                elseif result.spellSet then
                    log.info('Use /SideKick spellset to review the staged import before activating it.')
                end
            end
        end)
    end

    -- Launch Group script on startup if enabled (default true)
    if Core.Settings.SideKickLaunchGroup ~= false then
        mq.cmd('/lua run group')
    end

    local function setAutomationPaused(paused, source)
        paused = paused == true
        Core.set('AutomationPaused', paused)
        Core.forceSave()
        pcall(function()
            mq.cmdf('/echo \\ag[SideKick]\\ax automation %s%s',
                paused and 'paused' or 'resumed',
                source and source ~= '' and (' (' .. tostring(source) .. ')') or '')
        end)
    end

    local function toggleAutomationPaused(source)
        setAutomationPaused(not (Core.Settings.AutomationPaused == true), source or 'toggle')
    end

    local function handleSideKickCommand(...)
        local args = { ... }
        local a1 = tostring(args[1] or ''):lower()
        if a1 == 'burn' then
            enqueue(function()
                Core.set('BurnActive', true)
                Burn.setActive(true, { duration = Core.Settings.BurnDuration })
            end)
        elseif a1 == 'burnoff' then
            enqueue(function()
                Core.set('BurnActive', false)
                Burn.setActive(false)
            end)
        elseif a1 == 'bar' then
            enqueue(function()
                local cur = Core.Settings.SideKickBarEnabled
                if cur == nil then cur = true end
                Core.set('SideKickBarEnabled', not cur)
            end)
        elseif a1 == 'chase' then
            enqueue(function()
                Core.set('ChaseEnabled', not (Core.Settings.ChaseEnabled == true))
                Core.forceSave()
            end)
        elseif a1 == 'assist' then
            enqueue(function()
                local assistOn = (Core.Settings.CombatMode or 'off') == 'assist'
                Core.set('CombatMode', assistOn and 'off' or 'assist')
                Core.forceSave()
            end)
        elseif a1 == 'pause' or a1 == 'paused' then
            enqueue(function() setAutomationPaused(true, 'command') end)
        elseif a1 == 'resume' or a1 == 'unpause' then
            enqueue(function() setAutomationPaused(false, 'command') end)
        elseif a1 == 'togglepause' or a1 == 'pausetoggle' then
            enqueue(function() toggleAutomationPaused('command') end)
        elseif a1 == 'status' then
            pcall(function()
                mq.cmdf('/echo \\ag[SideKick]\\ax paused=%s assist=%s chase=%s buffs=%s heals=%s dps=%s',
                    tostring(Core.Settings.AutomationPaused == true),
                    tostring((Core.Settings.CombatMode or 'off') == 'assist'),
                    tostring(Core.Settings.ChaseEnabled == true),
                    tostring(Core.Settings.BuffingEnabled ~= false),
                    tostring(Core.Settings.DoHeals == true),
                    tostring(Core.Settings.SpellRotationEnabled == true))
            end)
        elseif a1 == 'import' or a1 == 'importini' then
            local importArgs = {}
            for i = 2, #args do importArgs[#importArgs + 1] = args[i] end
            queueMuleAssistImport(importArgs)
        elseif a1 == 'remote' then
            -- New command: toggle remote ability bar
            local M = LZ.getRemoteAbilities() if M then M.toggle() end
        elseif a1 == 'remoteconfig' then
            -- New command: open remote abilities settings
            local M = LZ.getRemoteAbilities() if M then M.toggleSettings() end
        elseif a1 == 'debugsettings' then
            -- Toggle settings persistence debugging (/SideKick debugsettings on|off|toggle)
            local a2 = tostring(args[2] or ''):lower()
            local enable = nil
            if a2 == '' or a2 == 'toggle' then
                enable = not (Core.Settings.SideKickDebugSettings == true)
            elseif a2 == 'on' or a2 == '1' or a2 == 'true' or a2 == 'yes' then
                enable = true
            elseif a2 == 'off' or a2 == '0' or a2 == 'false' or a2 == 'no' then
                enable = false
            end
            if enable ~= nil then
                Core.set('SideKickDebugSettings', enable)
                if _G.SIDEKICK_NEXT_CONFIG then
                    _G.SIDEKICK_NEXT_CONFIG.DEBUG_SETTINGS = enable
                end
            end
        elseif a1 == 'actorsdebug' then
            -- Opens actors debug window instead of echoing
            do local M = LZ.getActorsDebug() if M then M.toggle() end end
        elseif a1 == 'coord' or a1 == 'coordinator' then
            do local M = LZ.getCoordinatorDebug() if M then M.toggle() end end
        elseif a1 == 'cache' then
            -- Debug command disabled (no in-game output)
        elseif a1 == 'cc' then
            -- Debug command disabled (no in-game output)
        elseif a1 == 'spell' then
            -- Debug command disabled (no in-game output)
        elseif a1 == 'testcast' then
            -- Debug command: test cast a spell (silent)
            local spellName = args[2]
            if spellName then
                local target = mq.TLO.Target
                local targetId = target and target() and target.ID() or 0
                local SE = LZ.getSpellEngine()
                if SE then SE.cast(spellName, targetId) end
            end
        elseif a1 == 'healmonitor' then
            if _G.SIDEKICK_NEXT_CONFIG and _G.SIDEKICK_NEXT_CONFIG.COORDINATED_MODE ~= false then
                do local M = LZ.getHealingMonitor() if M then M.toggle() end end
            else
                local mod = getHealingModule()
                if mod and mod.toggleMonitor then
                    mod.toggleMonitor()
                end
            end
        elseif a1 == 'assistme' then
            -- Broadcast assist me to all peers in same zone
            enqueue(function()
                ActorsCoordinator.broadcastAssistMe()
            end)
        elseif a1 == 'spellset' or a1 == 'ss' then
            do local M = LZ.getSpellSetEditor() if M then M.toggle() end end
        elseif a1 == 'debugcombat' then
            -- Debug combat spell executor
            local ok, CombatExec = pcall(require, 'sidekick-next.utils.combat_spell_executor')
            if not ok then
                log.error('Failed to load combat_spell_executor: %s', tostring(CombatExec))
            elseif CombatExec then
                local a2 = tostring(args[2] or ''):lower()
                if a2 == 'gems' then
                    if CombatExec.debugPrintAllGems then
                        CombatExec.debugPrintAllGems()
                    else
                        log.error('debugPrintAllGems not found')
                    end
                elseif a2 == 'state' then
                    if CombatExec.debugPrintState then
                        CombatExec.debugPrintState()
                    else
                        log.error('debugPrintState not found')
                    end
                elseif a2 == 'list' then
                    if CombatExec.debugPrintCastList then
                        CombatExec.debugPrintCastList()
                    else
                        log.error('debugPrintCastList not found')
                    end
                else
                    log.info('Combat Debug: /sidekick debugcombat gems|state|list')
                end
            else
                log.error('CombatExec is nil')
            end
        elseif a1 == 'debugooc' then
            mq.cmd('/echo \\ay[SideKick]\\ax debugooc is retired; use /sk coordinator to inspect the buffs worker.')
        elseif a1 == 'settings' or a1 == 'options' or a1 == 'config' then
            local a2 = tostring(args[2] or ''):lower()
            if a2 == 'audit' or a2 == 'validate' or a2 == 'status' then
                local diag = Core.getRegistryDiagnostics and Core.getRegistryDiagnostics() or {}
                local audit = diag.registry or {}
                mq.cmdf('/echo \\ag[SK Settings]\\ax registry=%s registered=%d owned=%d namespaces=%d unregistered=%d invalid=%d',
                    audit.ok == true and 'ok' or 'ERROR', tonumber(audit.registered) or 0,
                    tonumber(audit.owned) or 0, tonumber(audit.namespaces) or 0,
                    #(diag.unregistered or {}), #(diag.invalid or {}))
                for i = 1, math.min(5, #(audit.errors or {})) do
                    mq.cmdf('/echo \\ar[SK Settings]\\ax %s', tostring(audit.errors[i]))
                end
                for i = 1, math.min(5, #(diag.invalid or {})) do
                    local entry = diag.invalid[i]
                    mq.cmdf('/echo \\ar[SK Settings]\\ax invalid %s: %s',
                        tostring(entry.key), tostring(entry.reason))
                end
                for i = 1, math.min(5, #(diag.unregistered or {})) do
                    local entry = diag.unregistered[i]
                    mq.cmdf('/echo \\ay[SK Settings]\\ax unregistered %s (section=%s)',
                        tostring(entry.key), tostring(entry.section))
                end
            elseif a2 == 'get' then
                local key = SettingsRegistry.resolveKey(tostring(args[3] or ''))
                local owner, kind = SettingsRegistry.owner(key)
                if key == '' then
                    mq.cmd('/echo \\ay[SK Settings]\\ax Usage: /sk config get <key>')
                else
                    local configPath = owner and Core.getModuleConfigPath(owner) or 'compatibility routing'
                    configPath = tostring(configPath):gsub('\\', '/')
                    mq.cmdf('/echo \\ag[SK Settings]\\ax %s=%s owner=%s registration=%s file=%s',
                        key, tostring(Core.Settings[key]), tostring(owner or 'unregistered'), tostring(kind),
                        configPath)
                end
            elseif a2 == 'set' then
                local key = SettingsRegistry.resolveKey(tostring(args[3] or ''))
                local valueParts = {}
                for i = 4, #args do valueParts[#valueParts + 1] = tostring(args[i]) end
                local rawValue = table.concat(valueParts, ' ')
                if key == '' or #valueParts == 0 then
                    mq.cmd('/echo \\ay[SK Settings]\\ax Usage: /sk config set <key> <value>')
                else
                    enqueue(function()
                        local ok, err = Core.set(key, rawValue, { save = true, source = 'command' })
                        if ok then
                            local owner = select(1, SettingsRegistry.owner(key))
                            mq.cmdf('/echo \\ag[SK Settings]\\ax saved %s=%s owner=%s',
                                key, tostring(Core.Settings[key]), tostring(owner or 'unregistered'))
                        else
                            mq.cmdf('/echo \\ar[SK Settings]\\ax rejected %s: %s', key, tostring(err))
                        end
                    end)
                end
            else
                -- No registry subcommand: preserve the existing options toggle.
                State.open = true
                State.settingsOpen = not State.settingsOpen
            end
        else
            State.open = not State.open
        end
    end

    _bindCmd('/SideKick', handleSideKickCommand)
    _bindCmd('/sk', handleSideKickCommand)

    -- Pull settings are written only by this primary UI process. Manual
    -- movement requests are sent to the coordinated worker, which must acquire
    -- target ownership before advancing from READY.
    _bindCmd('/sk_pull', function(sub, arg, arg2)
        local Pull = LZ.getPull()
        if not Pull then return end
        local command = tostring(sub or 'status'):lower()
        if command == 'pulltarget' or command == 'clearignore' or command == 'camp' or command == 'status' then
            local targetId = command == 'pulltarget' and (tonumber(mq.TLO.Target.ID()) or 0) or 0
            local sent = ActorsCoordinator.sendToLocalScript('sidekick-next/sk_pull', 'pull:manual', {
                command = command,
                targetId = targetId,
            })
            if not sent then
                mq.cmd('/echo \\ar[SK Pull]\\ax worker transport unavailable')
            end
            return
        end
        Pull.handleCommand(command, arg, arg2)
        Core.forceSave()
    end)

    -- Internal single-writer endpoint used by the standalone meditation
    -- worker. All main INI writes must execute in this UI Lua state.
    _bindCmd('/sk_next_set_meditation', function(rawMode)
        local mode = tostring(rawMode or ''):lower():match('^%s*(.-)%s*$')
        if mode == 'on' then mode = 'ooc' end
        if mode == 'incombat' then mode = 'in combat' end
        if mode ~= 'off' and mode ~= 'ooc' and mode ~= 'always' and mode ~= 'in combat' then
            mq.cmd('/echo \\ar[SK-Next]\\ax Invalid meditation mode. Use off, ooc, or always.')
            return
        end
        Core.set('MeditationMode', mode)
        local saved, err = Core.forceSave()
        if saved == false then
            mq.cmdf('/echo \\ar[SK-Next]\\ax MeditationMode save failed: %s', tostring(err))
        else
            mq.cmdf('/echo \\ag[SK-Next]\\ax MeditationMode saved as %s by the primary settings writer.', mode)
        end
    end)

    -- Internal single-writer endpoint used by sk_disciplines. Worker Lua
    -- states may request a burn change but never write settings themselves.
    _bindCmd('/sk_next_set_burn', function(rawValue)
        local value = tostring(rawValue or ''):lower()
        local enabled = value == 'on' or value == '1' or value == 'true'
        Core.set('BurnNow', enabled)
        Core.forceSave()
    end)

    -- Group-control friendly binds (for /dgge, /dgre broadcasts)
    _bindCmd('/skchaseon', function()
        enqueue(function()
            Core.set('ChaseEnabled', true)
            Core.forceSave()
            Chase.setEnabled(true, { user = true })
        end)
    end)
    _bindCmd('/skchaseoff', function()
        enqueue(function()
            Core.set('ChaseEnabled', false)
            Core.forceSave()
            Chase.setEnabled(false, { user = true })
        end)
    end)
    _bindCmd('/skchase', function(...)
        local args = { ... }
        local a1 = tostring(args[1] or ''):lower()
        enqueue(function()
            if a1 == 'on' then
                Core.set('ChaseEnabled', true)
                Core.forceSave()
                Chase.setEnabled(true, { user = true })
            elseif a1 == 'off' then
                Core.set('ChaseEnabled', false)
                Core.forceSave()
                Chase.setEnabled(false, { user = true })
            end

            local s = Chase.status and Chase.status() or {}
            local playStyle = tostring(Core.Settings.AutomationLevel or 'auto')
            pcall(function()
                mq.cmdf('/echo \\ag[SK Chase]\\ax enabled=%s paused=%s automation=%s role=%s target=%s dist=%s resolved=%s(%s) resolvedDist=%s nav=%s ownNav=%s reason=%s',
                    tostring(s.enabled),
                    tostring(s.userPaused),
                    playStyle,
                    tostring(s.role),
                    tostring(s.target),
                    tostring(s.distance),
                    tostring(s.resolvedName),
                    tostring(s.resolvedId),
                    s.resolvedDistance and string.format('%.1f', s.resolvedDistance) or 'nil',
                    tostring(s.navActive),
                    tostring(s.initiatedNav),
                    tostring(s.reason))
            end)
        end)
    end)
    _bindCmd('/skassistme', function()
        enqueue(function()
            ActorsCoordinator.broadcastAssistMe()
        end)
    end)
    _bindCmd('/skpause', function()
        enqueue(function() setAutomationPaused(true, 'skpause') end)
    end)
    _bindCmd('/skresume', function()
        enqueue(function() setAutomationPaused(false, 'skresume') end)
    end)
    _bindCmd('/skunpause', function()
        enqueue(function() setAutomationPaused(false, 'skunpause') end)
    end)
    _bindCmd('/sktogglepause', function()
        enqueue(function() toggleAutomationPaused('sktogglepause') end)
    end)
    _bindCmd('/skstatus', function()
        pcall(function()
            mq.cmdf('/echo \\ag[SideKick]\\ax paused=%s assist=%s chase=%s buffs=%s heals=%s dps=%s',
                tostring(Core.Settings.AutomationPaused == true),
                tostring((Core.Settings.CombatMode or 'off') == 'assist'),
                tostring(Core.Settings.ChaseEnabled == true),
                tostring(Core.Settings.BuffingEnabled ~= false),
                tostring(Core.Settings.DoHeals == true),
                tostring(Core.Settings.SpellRotationEnabled == true))
        end)
    end)
    _bindCmd('/skactors', function()
        local M = LZ.getActorsDebug() if M then M.toggle() end
    end)
    _bindCmd('/skimport', function(...)
        queueMuleAssistImport({ ... })
    end)
    _bindCmd('/skspells', function(cmd)
        enqueue(function()
            local ok, scanner = pcall(require, 'sidekick-next.utils.spellbook_scanner')
            if ok and scanner then
                scanner.handleCommand(cmd)
            end
        end)
    end)
    _bindCmd('/skcd', function(...)
        local args = { ... }
        local sub = tostring(args[1] or ''):lower()
        if sub == 'on' or sub == 'debug' then
            local filter = args[2]
            -- Join remaining args for multi-word names like "Fists of Wu"
            if filter then
                local parts = {}
                for i = 2, #args do parts[#parts+1] = tostring(args[i]) end
                filter = table.concat(parts, ' ')
            end
            Cooldowns._debug = true
            Cooldowns._debugFilter = filter
            mq.cmd('/echo \\ag[SideKick]\\ax CD debug ON' ..
                (filter and (' filter="' .. filter .. '"') or ' (all abilities)'))
        elseif sub == 'off' then
            Cooldowns._debug = false
            Cooldowns._debugFilter = nil
            mq.cmd('/echo \\ag[SideKick]\\ax CD debug OFF')
        elseif sub == 'clear' then
            Cooldowns._observedTotal = {}
            Cooldowns._smooth = {}
            mq.cmd('/echo \\ag[SideKick]\\ax CD caches cleared')
        else
            mq.cmd('/echo \\ay[SideKick]\\ax /skcd on [name] | /skcd off | /skcd clear')
        end
    end)

    _bindCmd('/skperf', function()
        PerfMonitor.toggle()
    end)

    _bindCmd('/skloglevel', function(level)
        level = tonumber(level)
        if level and level >= 1 and level <= 5 then
            local saved, saveErr = Core.set('SideKickLogLevel', level, { save = true, source = 'command' })
            if not saved then
                print(string.format('\ar[SideKick Logging]\ax failed to save level: %s', tostring(saveErr)))
                return
            end
            Logger.configure(Core.Settings)
            local names = { 'error', 'warn', 'info', 'debug', 'verbose' }
            print(string.format('\ag[SideKick Logging]\ax level=%d (%s), propagated to workers', level, names[level] or '?'))
        else
            print(string.format('\ay[SideKick Logging]\ax Usage: /skloglevel <1-5> (1=error 2=warn 3=info 4=debug 5=verbose) Current: %d', Logger.getLevel()))
        end
    end)

    _bindCmd('/sklogfilter', function(...)
        local pattern = table.concat({ ... }, ' ')
        if pattern == '' or pattern == 'clear' then
            local saved, saveErr = Core.set('SideKickLogFilter', '', { save = true, source = 'command' })
            if not saved then
                print(string.format('\ar[SideKick Logging]\ax failed to clear filter: %s', tostring(saveErr)))
                return
            end
            Logger.configure(Core.Settings)
            print('\ag[SideKick Logging]\ax filter cleared and propagated to workers')
        else
            local saved, saveErr = Core.set('SideKickLogFilter', pattern, { save = true, source = 'command' })
            if not saved then
                print(string.format('\ar[SideKick Logging]\ax failed to save filter: %s', tostring(saveErr)))
                return
            end
            Logger.configure(Core.Settings)
            print(string.format('\ag[SideKick Logging]\ax filter="%s", propagated to workers', pattern))
        end
    end)

    _bindCmd('/sklogfile', function(toggle)
        if toggle == 'on' then
            local saved, saveErr = Core.set('SideKickLogFile', true, { save = true, source = 'command' })
            if not saved then
                print(string.format('\ar[SideKick Logging]\ax failed to enable file logging: %s', tostring(saveErr)))
                return
            end
            Logger.configure(Core.Settings)
            print('\ag[SideKick Logging]\ax general file logging enabled for all workers')
        elseif toggle == 'off' then
            local saved, saveErr = Core.set('SideKickLogFile', false, { save = true, source = 'command' })
            if not saved then
                print(string.format('\ar[SideKick Logging]\ax failed to disable file logging: %s', tostring(saveErr)))
                return
            end
            Logger.configure(Core.Settings)
            print('\ag[SideKick Logging]\ax general file logging disabled for all workers')
        else
            local cfg = Logger.getConfiguration()
            print(string.format('\ay[SideKick Logging]\ax Usage: /sklogfile on|off (current=%s)', tostring(cfg.fileLogging)))
        end
    end)

    _bindCmd('/skset', function(key, ...)
        key = tostring(key or '')
        if key == '' then
            log.info('Usage: /skset <SettingKey> [value] - bools toggle when value omitted')
            log.info('Examples: /skset TankFleeHandoff off | /skset PrePullHotEtaSec 6 | /skset ReadinessEnabled')
            return
        end

        local okReg, Registry = pcall(require, 'sidekick-next.registry')
        local def = okReg and Registry and Registry.defaults and Registry.defaults[key]
        if not def then
            log.info('Unknown setting: %s', key)
            return
        end

        local raw = table.concat({ ... }, ' ')
        local value
        if def.type == 'bool' then
            local lower = raw:lower()
            if raw == '' or lower == 'toggle' then
                value = not (Core.Settings[key] == true or (Core.Settings[key] == nil and def.Default == true))
            elseif lower == 'on' or lower == 'true' or lower == '1' or lower == 'yes' then
                value = true
            elseif lower == 'off' or lower == 'false' or lower == '0' or lower == 'no' then
                value = false
            else
                log.info('%s is a bool - use on/off/toggle', key)
                return
            end
        elseif def.type == 'number' then
            value = tonumber(raw)
            if not value then
                log.info('%s needs a number (current: %s, default: %s)', key,
                    tostring(Core.Settings[key]), tostring(def.Default))
                return
            end
        else
            if raw == '' then
                log.info('%s = %s (default: %s)', key, tostring(Core.Settings[key]), tostring(def.Default))
                return
            end
            value = raw
        end

        enqueue(function()
            Core.set(key, value)
            log.info('%s = %s', key, tostring(value))
        end)
    end)

    _bindCmd('/skready', function()
        local Readiness = LZ.getReadiness()
        if Readiness and Readiness.printStatus then
            Readiness.printStatus()
        end
    end)

    -- One-shot fleet health rollup: is everything running and wired?
    -- All requires are pcall'd inline (no new upvalues, resilient to
    -- partially-loaded sessions).
    _bindCmd('/skhealth', function()
        print('\ag[SideKick]\ax === fleet health ===')

        local okLib, sklib = pcall(require, 'sidekick-next.sk_lib')
        if okLib and sklib then
            local running, stopped = 0, {}
            local scripts = { sklib.Scripts.COORDINATOR }
            for _, s in ipairs(sklib.Scripts.WORKERS or {}) do scripts[#scripts + 1] = s end
            for _, s in ipairs(scripts) do
                if sklib.isLuaScriptRunning(s) then
                    running = running + 1
                else
                    stopped[#stopped + 1] = s:match('sk_%w+$') or s
                end
            end
            print(string.format('  processes: %s%d/%d running\ax%s',
                #stopped == 0 and '\ag' or '\ay', running, #scripts,
                #stopped > 0 and ('  stopped: ' .. table.concat(stopped, ', ')
                    .. ' (some exit by design for this class)') or ''))
        end

        do
            local okAct, Actors = pcall(require, 'sidekick-next.utils.actors_coordinator')
            if okAct and Actors and Actors.getRemoteCharacters then
                local n = 0
                for _ in pairs(Actors.getRemoteCharacters() or {}) do n = n + 1 end
                print(string.format('  actors: %d live peer(s)', n))
            end
        end

        do
            local isTank = tostring(Core.Settings.CombatMode or 'off'):lower() == 'tank'
            if not isTank then
                print('  vitals hub: consumer (not tank mode)')
            else
                local okVH, VH = pcall(require, 'sidekick-next.utils.vitals_hub')
                local st = okVH and VH and VH.getStats and VH.getStats() or nil
                if st and (st.seq or 0) > 0 then
                    print(string.format('  vitals hub: \agpublishing\ax seq=%d last=%.1fs ago',
                        st.seq, os.clock() - (st.lastSendAt or 0)))
                else
                    print('  vitals hub: \aytank mode but nothing published yet\ax'
                        .. ' (grouped? VitalsHubEnabled? ActorsEnabled?)')
                end
            end
        end

        do
            local okDE, DE = pcall(require, 'sidekick-next.utils.damage_events')
            if okDE and DE and DE.getScope then
                local scope = tostring(DE.getScope() or 'unregistered')
                print(string.format('  damage observer: %s%s', scope,
                    scope == 'full' and ' (this char parses group damage)' or ''))
            end
        end

        do
            local okReg, Registry = pcall(require, 'sidekick-next.registry')
            local audit = okReg and Registry and Registry.audit and Registry.audit() or nil
            if audit then
                print(string.format('  registry: %s',
                    audit.ok and '\agok\ax'
                    or string.format('\ar%d error(s)\ax — /sk config audit', #audit.errors)))
            end
        end

        print('  detail: /sk_coord status | /skready | /sksession | /skmobintel')
    end)

    _bindCmd('/sksession', function(sub)
        local Stats = LZ.getSessionStats()
        if not Stats then
            log.info('Session stats module not available')
            return
        end
        sub = tostring(sub or ''):lower()
        if sub == 'export' then
            Stats.exportCSV()
        elseif sub == 'reset' then
            Stats.reset()
            log.info('Session stats reset')
        else
            Stats.printSummary()
        end
    end)

    _bindCmd('/skmobintel', function(sub, arg)
        local MobIntel = LZ.getMobIntel()
        if not MobIntel then
            log.info('Mob intel module not available')
            return
        end
        sub = tostring(sub or ''):lower()
        if sub == 'export' then
            -- Fold in-flight HP learning into the database so the export sees it
            do local M = LZ.getMobHpEstimator() if M and M.flush then M.flush() end end
            MobIntel.exportAll()
        elseif sub == 'mob' then
            local name = arg or mq.TLO.Target.CleanName() or ''
            if name == '' then
                log.info('Usage: /skmobintel mob [name] (defaults to current target)')
                return
            end
            for _, cc in ipairs({ 'slow', 'snare', 'mez', 'charm', 'root' }) do
                local status, stats = MobIntel.getCCStatus(name, cc)
                if stats then
                    log.info('%s: %s = %s (%d landed / %d resisted)', name, cc, status,
                        stats.landed or 0, stats.resisted or 0)
                end
            end
            local casts = MobIntel.getNpcCasts(name)
            for spell, count in pairs(casts) do
                log.info('%s casts: %s (seen %d)', name, spell, count)
            end
        else
            log.info('Usage: /skmobintel export | mob [name]')
        end
    end)

    mq.imgui.init('SideKick', function()
        -- Apply font scale for high-resolution monitors
        local fontScale = tonumber(Core.Settings.SideKickFontScale) or 1.0
        if fontScale ~= 1.0 then
            imgui.PushFont(imgui.GetFont(), imgui.GetFontSize() * fontScale)
        end

        -- Loading screen overlay during phased healing module init
        if not _healLoadComplete and _healPhase > 0 then
            local totalPhases = (_healMod and _healMod.TOTAL_INIT_PHASES or 5) + 2  -- +2 for warmup + require phases
            Loader.draw(_healPhase, totalPhases, false)
        elseif _healLoadComplete and _healPhase > 0 then
            Loader.draw(_healPhase, _healPhase, true)
        end

        if Core.Settings.SideKickBarEnabled ~= false then
            local Bar = LZ.getBar()
            if Bar then Bar.draw({
                abilities = State.barAbilities,
                settings = Core.Settings,
                animSpellIcons = animSpellIcons,
                cooldownProbe = function(row) return Cooldowns.probe(row) end,
                helpers = Helpers,
                onActivate = function(def) enqueue(function() Abilities.activate(def) end) end,
                modeLabels = Abilities.MODE_LABELS,
                onMode = function(key, value) Core.set(key, value) end,
                onOpenSettings = function() State.settingsOpen = true end,
            }) end
        end

        if Core.Settings.SideKickSpecialEnabled ~= false then
            local SpecialBar = LZ.getSpecialBar()
            if SpecialBar then SpecialBar.draw({
                settings = Core.Settings,
                animSpellIcons = animSpellIcons,
                cooldownProbe = function(row) return Cooldowns.probe(row) end,
                helpers = Helpers,
                onActivate = function(def) enqueue(function() Abilities.activate(def) end) end,
                onSettingChange = function(key, value) Core.set(key, value) end,
            }) end
        end

        if Core.Settings.SideKickDiscBarEnabled ~= false and tostring(State.classShort or '') == 'BER' then
            local DiscBar = LZ.getDiscBar()
            if DiscBar then DiscBar.draw({
                abilities = State.abilities,
                settings = Core.Settings,
                animSpellIcons = animSpellIcons,
                cooldownProbe = function(row) return Cooldowns.probe(row) end,
                helpers = Helpers,
                onActivate = function(def) enqueue(function() Abilities.activate(def) end) end,
            }) end
        end

        if Core.Settings.SideKickItemBarEnabled ~= false then
            local ItemBar = LZ.getItemBar()
            if ItemBar then ItemBar.draw({
                settings = Core.Settings,
                animItems = animItems,
                cooldownProbe = function(row) return Cooldowns.probe(row) end,
                helpers = Helpers,
                onActivate = queueItemActivation,
            }) end
        end

        do
            local v = Core.Settings.SideKickSkillBarEnabled
            local skillBarEnabled = (v == true) or (v == 1) or (v == '1') or (v == 'true')
            if skillBarEnabled then
                local SkillBar = LZ.getSkillBar()
                if SkillBar then SkillBar.draw({
                    settings = Core.Settings,
                    onActivate = function(sk)
                        enqueue(function()
                            Abilities.activate({ kind = 'skill', skillName = sk.name })
                        end)
                    end,
                }) end
            end
        end

        -- Draw new enhancement UIs (lazy-loaded)
        do local M = LZ.getRemoteAbilities() if M then M.draw() end end
        do local M = LZ.getAggroWarning() if M then M.draw() end end
        do local M = LZ.getActorsDebug() if M then M.render() end end
        do local M = LZ.getCoordinatorDebug() if M then M.render() end end
        do local M = LZ.getSpellSetEditor() if M then M.render() end end
        PerfMonitor.draw()

        -- Healing monitor: coordinated mode renders worker telemetry only;
        -- monolithic mode renders the locally-owned Healing Intelligence UI.
        if _G.SIDEKICK_NEXT_CONFIG and _G.SIDEKICK_NEXT_CONFIG.COORDINATED_MODE ~= false then
            do local M = LZ.getHealingMonitor() if M and M.draw then M.draw() end end
        elseif NewHealing and NewHealing.drawMonitor then
            NewHealing.drawMonitor()
        end

        if State.shouldDraw then
            draw()
        end

        -- First-run autostart prompt (modal popup)
        drawAutostartPrompt()

        -- Restore original font scale
        if fontScale ~= 1.0 then
            imgui.PopFont()
        end
    end)

    _healingWarmupStart = os.clock()  -- Start warmup timer (defers heavy CLR healing load)

    -- Camp detection: any running Lua worker issuing commands (sit, stand,
    -- casts, sticks) aborts the camp countdown. Shut the whole SideKick fleet
    -- down instead — State.isRunning=false ends this loop, and init.lua's
    -- Supervisor.stop() then /lua-stops every worker without moving the
    -- character, letting the camp complete.
    mq.event('sk_camp_shutdown', 'It will take#*#prepare your camp#*#', function()
        if not State.isRunning then return end
        print('\ay[SideKick]\ax Camp detected — pausing automation and shutting down so the camp completes.')
        pcall(function() Core.set('AutomationPaused', true) end)
        pcall(function() Core.forceSave() end)
        State.isRunning = false
    end)

    while State.isRunning do
        Supervisor.tick({
            automationPaused = Core.Settings.AutomationPaused == true,
            settingsRevision = Core.getRevision and Core.getRevision() or 0,
        })

        local gameState = SkLib.getGameState()
        if gameState ~= 'INGAME' then
            -- Zoning/loading: keep the supervisor heartbeat alive while all
            -- UI-host automation remains suspended. Do not tear workers down.
            -- MacroQuest can briefly report character-select-like states while
            -- changing zones, so GameState is never used to terminate SideKick.
            mq.doevents()
            mq.delay(100)
        else
        refreshClassAbilitiesIfNeeded()
        drainQueue()
        syncModulesFromSettings()
        do local M = LZ.getRezAccept() if M and M.tick then M.tick() end end
        tickAutomation()

        -- Humanize: drive selector + fidget state machine.
        if _G.SIDEKICK_NEXT_CONFIG and _G.SIDEKICK_NEXT_CONFIG.COORDINATED_MODE == false then
            local ok, H = pcall(require, 'sidekick-next.humanize')
            if ok and H and H.tick then H.tick() end
            local okF, F = pcall(require, 'sidekick-next.humanize.fidget')
            if okF and F and F.tick then F.tick() end
        end

        -- Process pending spell set memorization (must be in main loop, not ImGui).
        -- This must run in both monolithic and coordinated modes; worker scripts
        -- read the active spell set but the UI script owns safe /memspell driving.
        local Memorize = LZ.getSpellSetMemorize()
        if Memorize and Memorize.processPending then
            Memorize.processPending()
        end

        if _G.SIDEKICK_NEXT_CONFIG and _G.SIDEKICK_NEXT_CONFIG.COORDINATED_MODE == false then
            -- Process combat spells (must be in main loop for mq.delay)
            local CombatSpellExecutor = LZ.getCombatSpellExecutor()
            if CombatSpellExecutor and CombatSpellExecutor.process then
                CombatSpellExecutor.process()
            end
        end

        -- Check for zone change (immune database)
        do local M = LZ.getImmuneDB() if M then M.loadZone() end end

        -- Resist tracker: zone change check + resolve pending cast attempts
        do local M = LZ.getResistTracker() if M then M.loadZone() M.tick() end end

        -- Outgoing damage observation (mob HP estimation, spell damage learning).
        -- ensureScope re-registers lean/full pattern sets if DamageObserver or
        -- CombatMode changed (the tank runs the full observer set).
        do local M = LZ.getDamageEvents() if M and M.ensureScope then M.ensureScope() end end
        do local M = LZ.getMobHpEstimator() if M then M.loadZone() M.tick() end end
        do local M = LZ.getSpellDamageTracker() if M and M.tick then M.tick() end end

        -- Mob intel: CC results, NPC cast observation, consolidated knowledge base
        do local M = LZ.getMobIntel() if M then M.loadZone() M.tick() end end

        -- Death forensics: rolling combat black box + death reports
        do local M = LZ.getDeathForensics() if M then M.tick() end end

        -- Session stats: XP/kills/DPS tracking
        do local M = LZ.getSessionStats() if M then M.tick() end end

        -- Group readiness coordinator (actors-based, opt-in)
        do local M = LZ.getReadiness() if M then M.tick() end end

        -- Update aggro warning state
        do local M = LZ.getAggroWarning() if M and M.update then M.update() end end

        -- Actors + GT dock/status updates (runs in main loop so yields are allowed elsewhere).
        if Core.Settings.ActorsEnabled ~= false then
            -- Docked when configured to anchor to GroupTarget (even if GT bounds aren't available yet).
            -- This avoids a deadlock where GT only broadcasts bounds after seeing sidekick:docked=true.
            local hasGT = (_G.GroupTargetBounds and _G.GroupTargetBounds.loaded)
            local function anchoredToGT(mode, target)
                mode = tostring(mode or 'none'):lower()
                if mode == 'none' then return false end
                target = Anchor and Anchor.normalizeTargetKey and Anchor.normalizeTargetKey(target or 'grouptarget') or tostring(target or 'grouptarget'):lower()
                return target == 'grouptarget' or target == 'gt_commandbar'
            end
            local docked = (
                anchoredToGT(Core.Settings.SideKickBarAnchor, Core.Settings.SideKickBarAnchorTarget)
                or anchoredToGT(Core.Settings.SideKickSpecialAnchor, Core.Settings.SideKickSpecialAnchorTarget)
                or anchoredToGT(Core.Settings.SideKickDiscBarAnchor, Core.Settings.SideKickDiscBarAnchorTarget)
                or anchoredToGT(Core.Settings.SideKickItemBarAnchor, Core.Settings.SideKickItemBarAnchorTarget)
                or anchoredToGT(Core.Settings.SideKickMainAnchor, Core.Settings.SideKickMainAnchorTarget)
            )
            ActorsCoordinator.setDocked(docked)

            local status = SharedData.buildStatusPayload({
                abilities = State.abilities,
                cooldownProbe = cooldownRemaining,
                chase = Core.Settings.ChaseEnabled == true,
                assistEnabled = (Core.Settings.CombatMode or 'off') == 'assist',
                automationPaused = Core.Settings.AutomationPaused == true,
                burnActive = Core.Settings.BurnActive == true,
                settingsOpen = State.settingsOpen == true,
            })
            ActorsCoordinator.tick({ status = status })

            -- Tank-side consolidated group vitals for UI consumers (no-op
            -- unless CombatMode == 'tank'; rate-limited internally).
            -- Plain require, not a `lazy` file-scope local: the main function
            -- sits at LuaJIT's 60-upvalue limit and one more local broke the
            -- load ("more than 60 upvalues"). Globals don't count.
            do
                local okVH, VH = pcall(require, 'sidekick-next.utils.vitals_hub')
                if okVH and VH then VH.tick() end
            end

            -- Healing module actors tick (for multi-healer coordination)
            if Healing and Healing.tickActors then
                Healing.tickActors()
            end
        end

        -- Flush pending settings writes (debounced, max once/sec)
        Core.flush()

        mq.doevents()
        mq.delay(1)
        end
    end

    -- Shutdown: healing module (new healing intelligence)
    if NewHealing and NewHealing.shutdown then
        NewHealing.shutdown()
    end

    -- Shutdown: save immune database
    do local M = LZ.getImmuneDB() if M and M.shutdown then M.shutdown() end end

    -- Shutdown: save resist tracker
    do local M = LZ.getResistTracker() if M and M.shutdown then M.shutdown() end end

    -- Shutdown: save mob HP estimates and learned spell damage
    do local M = LZ.getMobHpEstimator() if M and M.shutdown then M.shutdown() end end
    do local M = LZ.getSpellDamageTracker() if M and M.shutdown then M.shutdown() end end
    do local M = LZ.getDamageEvents() if M and M.shutdown then M.shutdown() end end

    -- Shutdown: save mob intel (CC results, NPC casts)
    do local M = LZ.getMobIntel() if M and M.shutdown then M.shutdown() end end

    -- Shutdown: session stats events
    do local M = LZ.getSessionStats() if M and M.shutdown then M.shutdown() end end

    -- Shutdown: flush any pending Core settings
    Core.forceSave()
end

return main
