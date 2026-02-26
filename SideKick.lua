local mq = require('mq')
local imgui = require('ImGui')

-- Debug logging to file (using centralized Paths)
local _Paths = nil
local function getPaths()
    if not _Paths then
        local ok, p = pcall(require, 'sidekick-next.utils.paths')
        if ok then _Paths = p end
    end
    return _Paths
end

local function debugLog(fmt, ...)
    local msg = string.format(fmt, ...)
    local Paths = getPaths()
    local logPath = Paths and Paths.getLogPath('debug') or (mq.configDir .. '/SideKick_Debug.log')
    local f = io.open(logPath, 'a')
    if f then
        f:write(string.format('[%s] [Main] %s\n', os.date('%H:%M:%S'), msg))
        f:close()
    end
end

local Core = require('sidekick-next.utils.core')
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
local Meditation = require('sidekick-next.automation.meditation')
local LegacyHealing = require('sidekick-next.automation.healing')
local NewHealing = nil  -- Lazy-loaded for CLR

-- Function to get the appropriate healing module based on class
local function getHealingModule()
    local me = mq.TLO.Me
    if not me or not me() then return LegacyHealing end
    local classShort = me.Class and me.Class.ShortName and me.Class.ShortName() or ''
    classShort = classShort:upper()

    -- CLR uses new healing intelligence module
    if classShort == 'CLR' then
        if not NewHealing then
            local ok, mod = pcall(require, 'sidekick-next.healing')
            if ok then
                NewHealing = mod
                NewHealing.init()
            end
        end
        return NewHealing or LegacyHealing
    end

    -- All other classes use legacy module
    return LegacyHealing
end

local Healing = nil  -- Will be set dynamically by getHealingModule()

local Cures = require('sidekick-next.automation.cures')
local ActorsCoordinator = require('sidekick-next.utils.actors_coordinator')
local SharedData = require('sidekick-next.actors.shareddata')
local Grids = require('sidekick-next.ui.grids')
local SettingsUI = require('sidekick-next.ui.settings')
local Bar = require('sidekick-next.ui.bar_animated')
local SpecialBar = require('sidekick-next.ui.special_bar_animated')
local DiscBar = require('sidekick-next.ui.disc_bar_animated')
local ItemBar = require('sidekick-next.ui.item_bar_animated')
local iam = require('ImAnim')

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

-- New enhancement modules
local RemoteAbilities = require('sidekick-next.ui.remote_abilities')
local AggroWarning = require('sidekick-next.ui.aggro_warning')
local ActorsDebug = require('sidekick-next.ui.actors_debug')
local CoordinatorDebug = require('sidekick-next.ui.coordinator_debug')

-- Runtime cache, action executor, rotation engine, CC, and spell engine
local RuntimeCache = require('sidekick-next.utils.runtime_cache')
local ActionExecutor = require('sidekick-next.utils.action_executor')
local RotationEngine = require('sidekick-next.utils.rotation_engine')
local CC = require('sidekick-next.automation.cc')
local Buff = require('sidekick-next.automation.buff')
local SpellEngine = require('sidekick-next.utils.spell_engine')
local SpellEvents = require('sidekick-next.utils.spell_events')
local ImmuneDB = require('sidekick-next.utils.immune_database')
local SpellLineup = require('sidekick-next.utils.spell_lineup')
local ClassConfigLoader = require('sidekick-next.utils.class_config_loader')
local SpellsetManager = require('sidekick-next.utils.spellset_manager')
local SpellSetEditor = require('sidekick-next.ui.spell_set_editor')

-- Spell set memorization (lazy-loaded for processPending in main loop)
local _SpellSetMemorize = nil
local function getSpellSetMemorize()
    if not _SpellSetMemorize then
        local ok, mod = pcall(require, 'sidekick-next.utils.spellset_memorize')
        if ok then _SpellSetMemorize = mod end
    end
    return _SpellSetMemorize
end

-- OOC buff executor (lazy-loaded for process in main loop)
local _OocBuffExecutor = nil
local function getOocBuffExecutor()
    if not _OocBuffExecutor then
        local ok, mod = pcall(require, 'sidekick-next.utils.ooc_buff_executor')
        if ok then _OocBuffExecutor = mod end
    end
    return _OocBuffExecutor
end

-- Combat spell executor (lazy-loaded for process in main loop)
local _CombatSpellExecutor = nil
local function getCombatSpellExecutor()
    if not _CombatSpellExecutor then
        local ok, mod = pcall(require, 'sidekick-next.utils.combat_spell_executor')
        if ok then _CombatSpellExecutor = mod end
    end
    return _CombatSpellExecutor
end

-- Throttled logging
local _ThrottledLog = nil
local function getThrottledLog()
    if not _ThrottledLog then
        local ok, tl = pcall(require, 'sidekick-next.utils.throttled_log')
        if ok then _ThrottledLog = tl end
    end
    return _ThrottledLog
end

-- Healing monitor UI (lazy-loaded for Healing tab)
local _HealingMonitor = nil
local function getHealingMonitor()
    if not _HealingMonitor then
        local ok, mod = pcall(require, 'sidekick-next.healing.ui.monitor')
        if ok then _HealingMonitor = mod end
    end
    return _HealingMonitor
end

-- Healing settings tab (lazy-loaded for Healing tab)
local _HealingSettingsTab = nil
local function getHealingSettingsTab()
    if not _HealingSettingsTab then
        local ok, mod = pcall(require, 'sidekick-next.ui.settings.tab_healing')
        if ok then _HealingSettingsTab = mod end
    end
    return _HealingSettingsTab
end

-- Items tab (lazy-loaded)
local _ItemsTab = nil
local function getItemsTab()
    if not _ItemsTab then
        local ok, mod = pcall(require, 'sidekick-next.ui.settings.tab_items')
        if ok then _ItemsTab = mod end
    end
    return _ItemsTab
end

-- Buffs tab (lazy-loaded)
local _BuffsTab = nil
local function getBuffsTab()
    if not _BuffsTab then
        local ok, mod = pcall(require, 'sidekick-next.ui.settings.tab_buffs')
        if ok then _BuffsTab = mod end
    end
    return _BuffsTab
end

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
    if iniFlagIsTrue('SideKick', 'SideKickBERDiscDefaultsApplied') then return end
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
        Core.Ini['SideKick']['SideKickBERDiscDefaultsApplied'] = '1'
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

        local assistOn = Core.Settings.AssistEnabled == true
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
            enqueue(function() Core.set('AutomationPaused', not pausedOn) end)
        end, btnScale)
        if imgui.IsItemHovered() then imgui.SetTooltip('Pause all automation') end

        imgui.SameLine()
        toggleButton('Assist##sk', assistOn, function()
            enqueue(function() Core.set('AssistEnabled', not assistOn) end)
        end, btnScale)
        if imgui.IsItemHovered() then imgui.SetTooltip('Toggle Assist') end

        imgui.SameLine()
        toggleButton('Chase##sk', chaseOn, function()
            enqueue(function() Core.set('ChaseEnabled', not chaseOn) end)
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

        local open = imgui.Begin('SideKick Options##SettingsPopup', true, sFlags)
        if open then
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
                if imgui.BeginTabItem("AA's") then
                    Grids.drawAbilities({
                        abilities = State.abilities,
                        settings = Core.Settings,
                        modeLabels = Abilities.MODE_LABELS,
                        onToggle = function(key, value) Core.set(key, value) end,
                        onMode = function(key, value) Core.set(key, value) end,
                        onActivate = function(def) enqueue(function() Abilities.activate(def) end) end,
                        cooldownProbe = function(row) return Cooldowns.probe(row) end,
                        helpers = Helpers,
                    })
                    imgui.EndTabItem()
                end

                if imgui.BeginTabItem('Options') then
                    local debugSettings = Core.Settings.SideKickDebugSettings == true
                    local themeNames = Themes.getThemeNames()

                    -- DEBUG: Log theme info once per second
                    State._lastThemeDebugLog = State._lastThemeDebugLog or 0
                    if os.clock() - State._lastThemeDebugLog > 1.0 then
                        State._lastThemeDebugLog = os.clock()
                        print(string.format('\aw[SideKick] Options tab: %d themes, current=%s\ax', #themeNames, tostring(Core.Settings.SideKickTheme or 'nil')))
                    end

                    if debugSettings then
                        local TL = getThrottledLog()
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

                    SettingsUI.draw(
                        Core.Settings,
                        themeNames,
                        function(key, value)
                            print(string.format('\ay[SideKick] onChange called: key=%s value=%s\ax', tostring(key), tostring(value)))
                            if tostring(key) == 'SideKickTheme' then
                                State._themeLocalSetAt = os.clock()
                                print(string.format('\ag[SideKick] Theme change detected, holdUntil set to %.2f\ax', State._themeLocalSetAt + 5.0))
                            end
                            Core.set(key, value)
                            print(string.format('\ag[SideKick] Core.set completed, new value=%s\ax', tostring(Core.Settings[tostring(key)])))
                        end
                    )

                    -- Remote Abilities settings section
                    imgui.Separator()
                    if imgui.CollapsingHeader('Remote Abilities') then
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

                    -- Aggro Warning settings section
                    if imgui.CollapsingHeader('Warnings') then
                        AggroWarning.drawSettings()
                    end

                    imgui.EndTabItem()
                end

                -- Spell Set tab
                if imgui.BeginTabItem('Spell Set') then
                    local ok, err = pcall(function()
                        SpellSetEditor.drawContent()
                    end)
                    if not ok then
                        imgui.TextColored(1, 0.3, 0.3, 1, 'Error: ' .. tostring(err))
                    end
                    imgui.EndTabItem()
                end

                -- Healing tab (healer classes only)
                local isHealerClass = State.classShort == 'CLR' or State.classShort == 'DRU' or
                                      State.classShort == 'SHM' or State.classShort == 'PAL'
                if isHealerClass then
                    if imgui.BeginTabItem('Healing') then
                        -- Sub-tabs within Healing
                        if imgui.BeginTabBar('HealingSubTabs') then
                            -- Settings sub-tab
                            local HealSettingsTab = getHealingSettingsTab()
                            if HealSettingsTab then
                                if imgui.BeginTabItem('Settings') then
                                    local ok, err = pcall(function()
                                        HealSettingsTab.draw(Core.Settings, Themes.getThemeNames(), function(key, val)
                                            Core.Settings[key] = val
                                            Core.save()
                                        end)
                                    end)
                                    if not ok then
                                        imgui.TextColored(1, 0.3, 0.3, 1, 'Error: ' .. tostring(err))
                                    end
                                    imgui.EndTabItem()
                                end
                            end

                            -- Monitor sub-tab (CLR only with healing intelligence)
                            local HealMonitor = getHealingMonitor()
                            if HealMonitor and HealMonitor.isInitialized and HealMonitor.isInitialized() then
                                if imgui.BeginTabItem('Monitor') then
                                    HealMonitor.drawContent()
                                    imgui.EndTabItem()
                                end
                            elseif State.classShort == 'CLR' then
                                if imgui.BeginTabItem('Monitor') then
                                    imgui.TextDisabled('Healing monitor initializing...')
                                    imgui.TextDisabled('Enter combat to activate')
                                    imgui.EndTabItem()
                                end
                            end

                            imgui.EndTabBar()
                        end
                        imgui.EndTabItem()
                    end
                end

                -- Items tab
                if imgui.BeginTabItem('Items') then
                    local ItemsTab = getItemsTab()
                    if ItemsTab then
                        local ok, err = pcall(function()
                            ItemsTab.draw(Core.Settings, Themes.getThemeNames(), function(key, val)
                                Core.Settings[key] = val
                                Core.save()
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
                    local BuffsTab = getBuffsTab()
                    if BuffsTab then
                        local ok, err = pcall(function()
                            BuffsTab.draw(Core.Settings, Themes.getThemeNames(), function(key, val)
                                Core.Settings[key] = val
                                Core.save()
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

            -- MQ's ImGui integration can hide EQ's cursor-drawn item icon when hovering an ImGui window.
            -- Mirror the cursor item icon inside this window so drag/drop feels consistent.
            do
                if animItems and mq and mq.TLO and mq.TLO.Cursor and mq.TLO.Cursor() and imgui.DrawTextureAnimation then
                    local mp = imgui.GetMousePos and imgui.GetMousePos() or nil
                    local mx, my = vec2xy(mp)
                    local wp = imgui.GetWindowPos and imgui.GetWindowPos() or nil
                    local ws = imgui.GetWindowSize and imgui.GetWindowSize() or nil
                    local wx, wy = vec2xy(wp)
                    local ww, wh = vec2xy(ws)

                    local inside = (mx >= wx and my >= wy and mx <= (wx + ww) and my <= (wy + wh))
                    if inside then
                        local iconId = 0
                        if mq.TLO.Cursor.Icon then
                            local okIcon, vIcon = pcall(function() return mq.TLO.Cursor.Icon() end)
                            if okIcon then iconId = tonumber(vIcon) or 0 end
                        end
                        if iconId > 0 then
                            local cell0 = iconId - 500
                            if cell0 < 0 then cell0 = 0 end
                            pcall(function() animItems:SetTextureCell(cell0) end)

                            local size = 34
                            local restoreX, restoreY = vec2xy(imgui.GetCursorScreenPos())
                            -- Draw slightly offset from the actual mouse position so this overlay does not
                            -- block interaction with underlying ImGui widgets (checkboxes/sliders/etc).
                            imgui.SetCursorScreenPos(mx + 16, my + 16)
                            pcall(imgui.DrawTextureAnimation, animItems, size, size)
                            imgui.SetCursorScreenPos(restoreX, restoreY)
                        end
                    end
                end
            end

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
        end
        imgui.End()
        imgui.PopStyleVar(2)
        if pushedTheme2 > 0 then imgui.PopStyleColor(pushedTheme2) end
    end
end

local function tickAutomation()
    local now = os.clock()
    if (now - (State.lastAutomationTick or 0)) < 0.05 then return end
    State.lastAutomationTick = now

    -- Global pause check - stop all automation when paused
    if Core.Settings.AutomationPaused == true then return end

    local playStyle = tostring(Core.Settings.AutomationLevel or 'auto'):lower()
    local allowAbilityAutomation = (playStyle ~= 'manual')
    local allowMovementAutomation = (playStyle == 'auto')

    -- Update runtime cache (before other automation)
    RuntimeCache.tick()

    -- Update CC tracking (mez broadcasts/receives)
    CC.tick()

    -- Mez casting tick (ENC/BRD only, checks isMezClass internally)
    if allowAbilityAutomation then
        CC.mezTick(Core.Settings)
    end

    -- Update buff tracking (buff broadcasts/receives)
    Buff.tick()

    -- Update spell engine state machine (non-blocking cast monitoring)
    SpellEngine.tick()
    SpellsetManager.tick()

    -- Process events for cast result detection
    mq.doevents()

    local priorityHealingActive = false
    if playStyle ~= 'manual' then
        Healing = getHealingModule()  -- Get appropriate module for current class
        if Healing and Healing.tick then
            debugLog('[HealingTick] calling Healing.tick')
            priorityHealingActive = Healing.tick(Core.Settings) == true
            debugLog('[HealingTick] result=%s', tostring(priorityHealingActive))
        else
            debugLog('[HealingTick] no Healing.tick available')
        end
    end

    -- Cure tick (after healing, before rotation engine)
    if allowAbilityAutomation and not priorityHealingActive and Cures and Cures.tick then
        Cures.tick(Core.Settings)
    end

    -- Run layered rotation engine (replaces flat Abilities.tryAllAbilities)
    local TL = getThrottledLog()
    if allowAbilityAutomation and Core.Settings.AutoAbilitiesEnabled ~= false then
        if debugAutomationLogging and TL then
            TL.log('rotation_start', 15, 'RotationEngine.tick: abilities=%d, burnActive=%s, priorityHealing=%s',
                #(State.abilities or {}), tostring(Burn.active), tostring(priorityHealingActive))
        end
        RotationEngine.tick({
            abilities = State.abilities,
            settings = Core.Settings,
            burnActive = Burn.active,
            priorityHealingActive = priorityHealingActive,
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

    -- Buff casting - DISABLED: Now handled by sk_buffs.lua coordinator module
    -- if allowAbilityAutomation and not priorityHealingActive then
    --     Buff.buffTick()
    -- else
    --     if debugAutomationLogging and TL then
    --         TL.log('buff_tick_skip', 15, 'Buff.buffTick SKIP: allowAbilityAutomation=%s, priorityHealingActive=%s',
    --             tostring(allowAbilityAutomation), tostring(priorityHealingActive))
    --     end
    -- end
    -- NOTE: Buff.tick() is still called above (line ~1223) for broadcast/cleanup tasks (non-casting logic)

    Burn.tick()

    if allowMovementAutomation then
        Chase.tick()
    elseif Chase and Chase.stopNav then
        Chase.stopNav()
    end

    -- Combat mode: tank handles targeting/aggro, assist handles engagement
    local CombatMode = Core.Settings.CombatMode or 'off'
    if allowMovementAutomation and CombatMode == 'tank' then
        Tank.tick(State.abilities, Core.Settings)
    end
    if allowMovementAutomation then
        if not priorityHealingActive then
            Assist.tick()
        end
    end

    if allowAbilityAutomation and Items and Items.tick and Core.Settings.AutoItemsEnabled ~= false then
        Items.tick()
    end

    -- Meditation (sit/stand) - DISABLED: Now handled by sk_meditation.lua coordinator module
    -- if playStyle ~= 'manual' and Meditation and Meditation.tick then
    --     debugLog('[MedTick] calling meditation.tick playStyle=%s mode=%s', tostring(playStyle), tostring(Core.Settings.MeditationMode or 'unknown'))
    --     Meditation.tick(Core.Settings)
    -- end
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

    CombatAssist.apply_config({
        enabled = Core.Settings.AssistEnabled == true,
        assist_at = Core.Settings.AssistAt,
        assist_rng = Core.Settings.AssistRange,
        assist_mode = Core.Settings.AssistMode,
        assist_name = Core.Settings.AssistName,
        stick_cmd = Core.Settings.StickCommand,
    })
    if (Core.Settings.AssistEnabled == true) ~= (Assist.enabled == true) then
        Assist.setEnabled(Core.Settings.AssistEnabled == true)
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
            newLines[#newLines + 1] = '/lua run sidekick'

            local outFile = io.open(autostartPath, 'w')
            if outFile then
                for _, line in ipairs(newLines) do
                    outFile:write(line .. '\n')
                end
                outFile:close()
            end

            -- Mark prompt as shown
            Core.Ini['SideKick'] = Core.Ini['SideKick'] or {}
            Core.Ini['SideKick']['AutostartPromptShown'] = '1'
            Core.save()
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
            Core.Ini['SideKick'] = Core.Ini['SideKick'] or {}
            Core.Ini['SideKick']['AutostartPromptShown'] = '1'
            Core.save()
            State.showAutostartPrompt = false
            imgui.CloseCurrentPopup()
        end
        imgui.PopStyleColor(3)

        imgui.EndPopup()
    end
end

local function main()
    Core.load()
    if _G.SIDEKICK_NEXT_CONFIG then
        _G.SIDEKICK_NEXT_CONFIG.DEBUG_SETTINGS = Core.Settings.SideKickDebugSettings == true
    end

    -- First-run autostart prompt check
    if not State.autostartPromptChecked then
        State.autostartPromptChecked = true
        local promptShown = Core.Ini['SideKick'] and Core.Ini['SideKick']['AutostartPromptShown']
        if not promptShown or promptShown == '0' or promptShown == '' then
            State.showAutostartPrompt = true
        end
    end

    ActorsCoordinator.init()

    Chase.init({ Core = Core })
    Burn.init({ Core = Core })
    CombatAssist.apply_config({
        enabled = Core.Settings.AssistEnabled == true,
        assist_at = Core.Settings.AssistAt,
        assist_rng = Core.Settings.AssistRange,
        assist_mode = Core.Settings.AssistMode,
        assist_name = Core.Settings.AssistName,
        stick_cmd = Core.Settings.StickCommand,
    })
    Assist.init({ Core = Core, CombatAssist = CombatAssist, Chase = Chase })
    Tank.init(Core.Settings)

    -- Initialize new enhancement modules
    RemoteAbilities.init()
    AggroWarning.init()
    CoordinatorDebug.init()

    -- Initialize runtime cache, action executor, CC, cures, and spell engine
    RuntimeCache.init()
    ActionExecutor.init()
    CC.init()
    Buff.init()
    Cures.init()
    SpellEngine.init()
    ImmuneDB.init()
    SpellLineup.init()
    ClassConfigLoader.init()
    SpellsetManager.init()
    SpellSetEditor.init()

    -- Launch Group script on startup if enabled (default true)
    if Core.Settings.SideKickLaunchGroup ~= false then
        mq.cmd('/lua run group')
    end

    _bindCmd('/SideKick', function(...)
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
            end)
        elseif a1 == 'assist' then
            enqueue(function()
                Core.set('AssistEnabled', not (Core.Settings.AssistEnabled == true))
            end)
        elseif a1 == 'remote' then
            -- New command: toggle remote ability bar
            RemoteAbilities.toggle()
        elseif a1 == 'remoteconfig' then
            -- New command: open remote abilities settings
            RemoteAbilities.toggleSettings()
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
            ActorsDebug.toggle()
        elseif a1 == 'coord' or a1 == 'coordinator' then
            CoordinatorDebug.toggle()
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
                SpellEngine.cast(spellName, targetId)
            end
        elseif a1 == 'healmonitor' then
            local mod = getHealingModule()
            if mod and mod.toggleMonitor then
                mod.toggleMonitor()
            end
        elseif a1 == 'assistme' then
            -- Broadcast assist me to all peers in same zone
            enqueue(function()
                ActorsCoordinator.broadcastAssistMe()
            end)
        elseif a1 == 'spellset' or a1 == 'ss' then
            SpellSetEditor.toggle()
        elseif a1 == 'debugcombat' then
            -- Debug combat spell executor
            local ok, CombatExec = pcall(require, 'sidekick-next.utils.combat_spell_executor')
            if not ok then
                print('\ar[SideKick]\ax Failed to load combat_spell_executor: ' .. tostring(CombatExec))
            elseif CombatExec then
                local a2 = tostring(args[2] or ''):lower()
                if a2 == 'gems' then
                    if CombatExec.debugPrintAllGems then
                        CombatExec.debugPrintAllGems()
                    else
                        print('\ar[SideKick]\ax debugPrintAllGems not found')
                    end
                elseif a2 == 'state' then
                    if CombatExec.debugPrintState then
                        CombatExec.debugPrintState()
                    else
                        print('\ar[SideKick]\ax debugPrintState not found')
                    end
                elseif a2 == 'list' then
                    if CombatExec.debugPrintCastList then
                        CombatExec.debugPrintCastList()
                    else
                        print('\ar[SideKick]\ax debugPrintCastList not found')
                    end
                else
                    print('\ay[SideKick]\ax Combat Debug Commands:')
                    print('  /sidekick debugcombat gems  - Show all gems and their types')
                    print('  /sidekick debugcombat state - Show combat state and target')
                    print('  /sidekick debugcombat list  - Show castable spells (excludes heals)')
                end
            else
                print('\ar[SideKick]\ax CombatExec is nil')
            end
        elseif a1 == 'debugooc' then
            -- Debug OOC buff executor
            local OocExec = getOocBuffExecutor()
            if OocExec and OocExec.debugPrint then
                OocExec.debugPrint()
            end
        elseif a1 == 'settings' or a1 == 'options' or a1 == 'config' then
            -- Toggle settings panel (also ensures main window is open)
            State.open = true
            State.settingsOpen = not State.settingsOpen
        else
            State.open = not State.open
        end
    end)

    -- Group-control friendly binds (for /dgge, /dgre broadcasts)
    _bindCmd('/skchaseon', function()
        enqueue(function()
            Core.set('ChaseEnabled', true)
            Chase.setEnabled(true, { user = true })
        end)
    end)
    _bindCmd('/skchaseoff', function()
        enqueue(function()
            Core.set('ChaseEnabled', false)
            Chase.setEnabled(false, { user = true })
        end)
    end)
    _bindCmd('/skassistme', function()
        enqueue(function()
            ActorsCoordinator.broadcastAssistMe()
        end)
    end)
    _bindCmd('/skactors', function()
        ActorsDebug.toggle()
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

    mq.imgui.init('SideKick', function()
        -- Apply font scale for high-resolution monitors
        local fontScale = tonumber(Core.Settings.SideKickFontScale) or 1.0
        if fontScale ~= 1.0 then
            imgui.PushFont(imgui.GetFont(), imgui.GetFontSize() * fontScale)
        end

        if Core.Settings.SideKickBarEnabled ~= false then
            Bar.draw({
                abilities = State.barAbilities,
                settings = Core.Settings,
                animSpellIcons = animSpellIcons,
                cooldownProbe = function(row) return Cooldowns.probe(row) end,
                helpers = Helpers,
                onActivate = function(def) enqueue(function() Abilities.activate(def) end) end,
                modeLabels = Abilities.MODE_LABELS,
                onMode = function(key, value) Core.set(key, value) end,
                onOpenSettings = function() State.settingsOpen = true end,
            })
        end

        if Core.Settings.SideKickSpecialEnabled ~= false then
            SpecialBar.draw({
                settings = Core.Settings,
                animSpellIcons = animSpellIcons,
                cooldownProbe = function(row) return Cooldowns.probe(row) end,
                helpers = Helpers,
                onActivate = function(def) enqueue(function() Abilities.activate(def) end) end,
                onSettingChange = function(key, value) Core.set(key, value) end,
            })
        end

        if Core.Settings.SideKickDiscBarEnabled ~= false and tostring(State.classShort or '') == 'BER' then
            DiscBar.draw({
                abilities = State.abilities,
                settings = Core.Settings,
                animSpellIcons = animSpellIcons,
                cooldownProbe = function(row) return Cooldowns.probe(row) end,
                helpers = Helpers,
                onActivate = function(def) enqueue(function() Abilities.activate(def) end) end,
            })
        end

        if Core.Settings.SideKickItemBarEnabled ~= false then
            ItemBar.draw({
                settings = Core.Settings,
                animItems = animItems,
                cooldownProbe = function(row) return Cooldowns.probe(row) end,
                helpers = Helpers,
            })
        end

        -- Draw new enhancement UIs
        RemoteAbilities.draw()
        AggroWarning.draw()
        ActorsDebug.render()
        CoordinatorDebug.render()
        SpellSetEditor.render()

        -- Healing monitor (new healing intelligence module)
        if NewHealing and NewHealing.drawMonitor then
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

    while State.isRunning and mq.TLO.MacroQuest.GameState() == 'INGAME' do
        refreshClassAbilitiesIfNeeded()
        drainQueue()
        syncModulesFromSettings()
        tickAutomation()

        -- Process pending spell set memorization (must be in main loop, not ImGui)
        local Memorize = getSpellSetMemorize()
        if Memorize and Memorize.processPending then
            Memorize.processPending()
        end

        -- Process combat spells (must be in main loop for mq.delay)
        local CombatSpellExecutor = getCombatSpellExecutor()
        if CombatSpellExecutor and CombatSpellExecutor.process then
            CombatSpellExecutor.process()
        end

        -- Process OOC buffs - DISABLED: Now handled by sk_buffs.lua coordinator module
        -- local OocBuffExecutor = getOocBuffExecutor()
        -- if OocBuffExecutor and OocBuffExecutor.process then
        --     OocBuffExecutor.process()
        -- end

        -- Check for zone change (immune database)
        ImmuneDB.loadZone()

        -- Update aggro warning state
        AggroWarning.update()

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
                assistEnabled = Core.Settings.AssistEnabled == true,
                burnActive = Core.Settings.BurnActive == true,
                settingsOpen = State.settingsOpen == true,
            })
            ActorsCoordinator.tick({ status = status })

            -- Healing module actors tick (for multi-healer coordination)
            if Healing and Healing.tickActors then
                Healing.tickActors()
            end
        end

        mq.doevents()
        mq.delay(1)
    end

    -- Shutdown: healing module (new healing intelligence)
    if NewHealing and NewHealing.shutdown then
        NewHealing.shutdown()
    end

    -- Shutdown: save immune database
    ImmuneDB.shutdown()
end

return main
