local mq = require('mq')
local imgui = require('ImGui')

local Core = require('utils.core')
local Themes = require('themes')
local Helpers = require('lib.helpers')
local Cooldowns = require('abilities.cooldowns')
local AbilityLoader = require('abilities.loader')
local Abilities = require('utils.abilities')
local SpecialAbilities = require('utils.special_abilities')
local CombatAssist = require('utils.combatassist')
local Chase = require('automation.chase')
local Assist = require('automation.assist')
local Burn = require('automation.burn')
local Tank = require('automation.tank')
local Meditation = require('automation.meditation')
local Healing = require('automation.healing')
local Cures = require('automation.cures')
local ActorsCoordinator = require('utils.actors_coordinator')
local SharedData = require('actors.shareddata')
local Grids = require('ui.grids')
local SettingsUI = require('ui.settings')
local Bar = require('ui.bar_animated')
local SpecialBar = require('ui.special_bar_animated')
local DiscBar = require('ui.disc_bar_animated')
local ItemBar = require('ui.item_bar_animated')
local ImAnim = require('lib.imanim')
local Anchor = require('ui.anchor')
local Items = require('utils.items')

-- New enhancement modules
local RemoteAbilities = require('ui.remote_abilities')
local AggroWarning = require('ui.aggro_warning')
local ActorsDebug = require('ui.actors_debug')

-- Runtime cache, action executor, rotation engine, CC, and spell engine
local RuntimeCache = require('utils.runtime_cache')
local ActionExecutor = require('utils.action_executor')
local RotationEngine = require('utils.rotation_engine')
local CC = require('automation.cc')
local Buff = require('automation.buff')
local SpellEngine = require('utils.spell_engine')
local SpellEvents = require('utils.spell_events')
local ImmuneDB = require('utils.immune_database')
local SpellLineup = require('utils.spell_lineup')
local ClassConfigLoader = require('utils.class_config_loader')
local SpellsetManager = require('utils.spellset_manager')
local SpellSetEditor = require('ui.spell_set_editor')

-- Throttled logging
local _ThrottledLog = nil
local function getThrottledLog()
    if not _ThrottledLog then
        local ok, tl = pcall(require, 'utils.throttled_log')
        if ok then _ThrottledLog = tl end
    end
    return _ThrottledLog
end

-- Debug logging flags for main automation loop
local debugAutomationLogging = true


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
    if mq.unbind then pcall(mq.unbind, withSlash) end
    pcall(mq.bind, withSlash, fn)
end

local function vec2xy(a, b)
    if b ~= nil then
        return tonumber(a) or 0, tonumber(b) or 0
    end
    if type(a) == 'table' then
        return tonumber(a.x or a[1]) or 0, tonumber(a.y or a[2]) or 0
    end
    return tonumber(a) or 0, 0
end

local function getStableGroupTargetBounds()
    local gt = _G.GroupTargetBounds
    if not gt or not gt.loaded then return nil end
    if gt.timestamp and (os.clock() - gt.timestamp) > 5.0 then return nil end
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

local function toggleButton(label, enabled, onClick)
    enabled = enabled == true
    if enabled then
        imgui.PushStyleColor(ImGuiCol.Button, 0.20, 0.70, 0.30, 0.90)
        imgui.PushStyleColor(ImGuiCol.ButtonHovered, 0.25, 0.80, 0.35, 1.00)
        imgui.PushStyleColor(ImGuiCol.ButtonActive, 0.15, 0.60, 0.25, 1.00)
    end
    local pressed = imgui.Button(label)
    if enabled then imgui.PopStyleColor(3) end
    if pressed and onClick then onClick() end
    return pressed
end

local function draw()
    if not State.open then return end

    local themeName = Core.Settings.SideKickTheme or 'Classic'
    local style = Themes.getWindowStyle(themeName)

    local mainAnchor = tostring(Core.Settings.SideKickMainAnchor or 'none'):lower()
    local mainAnchorTarget = Anchor and Anchor.normalizeTargetKey and Anchor.normalizeTargetKey(Core.Settings.SideKickMainAnchorTarget or 'grouptarget')
        or tostring(Core.Settings.SideKickMainAnchorTarget or 'grouptarget'):lower()
    local anchorGap = tonumber(Core.Settings.SideKickMainAnchorGap) or 2
    local matchGTW = Core.Settings.SideKickMainMatchGTWidth == true
    local rounding = 6
    local gt = getStableGroupTargetBounds()
    if Core.Settings.SideKickSyncThemeWithGT == true and gt and tonumber(gt.windowRounding) then
        rounding = tonumber(gt.windowRounding)
    end

    local estW = tonumber(State._mainBarLast.w) or 200
    local estH = tonumber(State._mainBarLast.h) or 30

    if matchGTW and tostring(mainAnchorTarget or '') == 'grouptarget' then
        local gt = getStableGroupTargetBounds()
        local gtW = gt and tonumber(gt.width) or nil
        if gtW and gtW > 50 and imgui.SetNextWindowSizeConstraints then
            imgui.SetNextWindowSizeConstraints(gtW, 10, gtW, 10000)
            estW = gtW
        end
    end

    local anchorX, anchorY = Anchor.getAnchorPos(mainAnchorTarget, mainAnchor, estW, estH, anchorGap)
    local dockedToGT = (tostring(mainAnchorTarget or '') == 'grouptarget') and (anchorX ~= nil and anchorY ~= nil)
    _G.SideKickDockedToGT = dockedToGT

    -- Center horizontally above/below GT when not matching width
    if dockedToGT and not matchGTW and anchorX and gt then
        local gtW = tonumber(gt.width) or 0
        if gtW > 0 and (mainAnchor == 'above' or mainAnchor == 'below') then
            anchorX = anchorX + (gtW - estW) / 2
        end
    end

    if dockedToGT and imgui.SetNextWindowPos then
        local smoothX, smoothY = getSmoothWindowPos('SideKickMain', anchorX, anchorY, 0.25)
        imgui.SetNextWindowPos(smoothX, smoothY, (ImGuiCond and ImGuiCond.Always) or 0)
    elseif imgui.SetNextWindowPos then
        imgui.SetNextWindowPos(50, 160, (ImGuiCond and ImGuiCond.FirstUseEver) or 4)
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
            local function vecX(v)
                if type(v) == 'number' then return v end
                if type(v) == 'table' then return tonumber(v.x or v[1]) or 0 end
                return 0
            end
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
            table.insert(parts, { kind = 'btn', label = 'Assist##sk' })
            table.insert(parts, { kind = 'btn', label = 'Chase##sk' })
            table.insert(parts, { kind = 'btn', label = 'Burn##sk' })

            if dockedToGT then
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
            end

            table.insert(parts, { kind = 'txt', text = '|' })
            table.insert(parts, { kind = 'btn', label = tostring(cogIcon) .. '##SideKickSettings' })
            if dockedToGT then
                local lockIcon = (Icons and Icons.FA_LOCK or 'L')
                table.insert(parts, { kind = 'btn', label = tostring(lockIcon) .. '##GTLock' })
                table.insert(parts, { kind = 'btn', label = tostring(gtSettingsIcon) .. '##GTSettings' })
                table.insert(parts, { kind = 'btn', label = tostring(closeIcon) .. '##ExitBoth' })
            else
                table.insert(parts, { kind = 'btn', label = tostring(closeIcon) .. '##SideKickClose' })
            end

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

        toggleButton('Assist##sk', assistOn, function()
            enqueue(function() Core.set('AssistEnabled', not assistOn) end)
        end)
        if imgui.IsItemHovered() then imgui.SetTooltip('Toggle Assist') end

        imgui.SameLine()
        toggleButton('Chase##sk', chaseOn, function()
            enqueue(function() Core.set('ChaseEnabled', not chaseOn) end)
        end)
        if imgui.IsItemHovered() then imgui.SetTooltip('Toggle Chase') end

        imgui.SameLine()
        toggleButton('Burn##sk', burnOn, function()
            enqueue(function() Core.set('BurnActive', not burnOn) end)
        end)
        if imgui.IsItemHovered() then imgui.SetTooltip('Toggle Burn phase') end

        if dockedToGT then
            imgui.SameLine()
            imgui.Text('|')
            imgui.SameLine()

            if imgui.Button(inviteLabel) then
                mq.cmd('/keypress ctrl+i')
            end
            if imgui.IsItemHovered() then imgui.SetTooltip(isInvited and 'Accept group invite' or 'Invite target to group') end

            imgui.SameLine()
            if imgui.Button('Disband##grp') then
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
            end)
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
            end)
            if imgui.IsItemHovered() then imgui.SetTooltip('Toggle group chase (broadcast)') end

            imgui.SameLine()
            if imgui.Button('Come##grp') then
                local inRaid = (tonumber(mq.TLO.Raid and mq.TLO.Raid.Members and mq.TLO.Raid.Members() or 0) or 0) > 0
                local dgCmd = inRaid and '/dgre' or '/dgge'
                mq.cmdf('/squelch %s /nav id %d', dgCmd, mq.TLO.Me.ID() or 0)
            end
            if imgui.IsItemHovered() then imgui.SetTooltip('Tell group to nav to you (broadcast)') end

            imgui.SameLine()
            if imgui.Button('Travel##grp') then
                local inRaid = (tonumber(mq.TLO.Raid and mq.TLO.Raid.Members and mq.TLO.Raid.Members() or 0) or 0) > 0
                local dgCmd = inRaid and '/dgex' or '/dgge'
                mq.cmdf('/squelch %s /travelto %s', dgCmd, mq.TLO.Zone.ShortName() or '')
            end
            if imgui.IsItemHovered() then imgui.SetTooltip('Tell group to travel to your zone (broadcast)') end

            imgui.SameLine()
            local mimicActive = _G.GroupTargetMimicToggle or false
            toggleButton('Mimic##grp', mimicActive, function()
                _G.GroupTargetMimicToggle = not mimicActive
            end)
            if imgui.IsItemHovered() then imgui.SetTooltip('Toggle group mimic mode (local)') end

            imgui.SameLine()
            if imgui.Button('Doors##grp') then
                mq.cmd('/dga /doortarget')
                mq.cmd('/dga /click left door')
            end
            if imgui.IsItemHovered() then imgui.SetTooltip('Target nearest door and click it (broadcast)') end
        end

        imgui.SameLine()
        imgui.Text('|')
        imgui.SameLine()

        local wasOpen = State.settingsOpen == true
        if wasOpen then
            imgui.PushStyleColor(ImGuiCol.Button, 0.2, 0.6, 0.8, 1.0)
            imgui.PushStyleColor(ImGuiCol.ButtonHovered, 0.3, 0.7, 0.9, 1.0)
            imgui.PushStyleColor(ImGuiCol.ButtonActive, 0.1, 0.5, 0.7, 1.0)
        end
        if imgui.SmallButton(tostring(cogIcon) .. '##SideKickSettings') then
            State.settingsOpen = not State.settingsOpen
        end
        if wasOpen then imgui.PopStyleColor(3) end
        if imgui.IsItemHovered() then imgui.SetTooltip(State.settingsOpen and 'Close Options' or 'Open Options') end

        if dockedToGT then
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
            if imgui.SmallButton(tostring(lockIcon) .. '##GTLock') then
                ActorsCoordinator.sendToGroupTarget({ id = 'sidekick:toggle_lock' })
            end
            if gtLocked then imgui.PopStyleColor(3) end
            if imgui.IsItemHovered() then imgui.SetTooltip(gtLocked and 'Unlock GroupTarget Position' or 'Lock GroupTarget Position') end

            imgui.SameLine()
            if imgui.SmallButton(tostring(gtSettingsIcon) .. '##GTSettings') then
                ActorsCoordinator.sendToGroupTarget({ id = 'sidekick:toggle_settings' })
            end
            if imgui.IsItemHovered() then imgui.SetTooltip('GroupTarget Settings') end

            -- Exit Both button
            imgui.SameLine()
            imgui.PushStyleColor(ImGuiCol.Button, 0.6, 0.2, 0.2, 0.8)
            imgui.PushStyleColor(ImGuiCol.ButtonHovered, 0.8, 0.3, 0.3, 1.0)
            imgui.PushStyleColor(ImGuiCol.ButtonActive, 0.5, 0.1, 0.1, 1.0)
            if imgui.SmallButton(tostring(closeIcon) .. '##ExitBoth') then
                ActorsCoordinator.sendToGroupTarget({ id = 'sidekick:exit' })
                State.settingsOpen = false
                State.open = false
                State.isRunning = false  -- Terminate the script
            end
            imgui.PopStyleColor(3)
            if imgui.IsItemHovered() then imgui.SetTooltip('Exit Both (SideKick + GroupTarget on this character)') end
        else
            imgui.SameLine()
            imgui.PushStyleColor(ImGuiCol.Button, 0.6, 0.2, 0.2, 0.8)
            imgui.PushStyleColor(ImGuiCol.ButtonHovered, 0.8, 0.3, 0.3, 1.0)
            imgui.PushStyleColor(ImGuiCol.ButtonActive, 0.5, 0.1, 0.1, 1.0)
            if imgui.SmallButton(tostring(closeIcon) .. '##SideKickClose') then
                State.settingsOpen = false
                State.open = false
            end
            imgui.PopStyleColor(3)
            if imgui.IsItemHovered() then imgui.SetTooltip('Close SideKick UI') end
        end

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
            x = px,
            y = py,
            width = pw,
            height = ph,
        }
        if Anchor and Anchor.updateWindowBounds then
            Anchor.updateWindowBounds('sidekick_main', imgui)
        end
    end

    imgui.End()
    imgui.PopStyleVar(2)
    if pushedTheme > 0 then imgui.PopStyleColor(pushedTheme) end

    local openTarget = State.settingsOpen and 1.0 or 0.0
    local heightFactor = openTarget
    if ImAnim and ImAnim.spring then
        heightFactor = ImAnim.spring('sk_settings_height', openTarget, 200, 20)
    end

    if heightFactor > 0.01 then
        local mainX = tonumber(State._mainBarLast.x) or 50
        local mainY = tonumber(State._mainBarLast.y) or 160
        local mainW = math.max(350, tonumber(State._mainBarLast.w) or 350)
        local settingsH = math.max(90, math.floor(480 * heightFactor + 0.5))
        local settingsY = mainY - settingsH - 2

        if imgui.SetNextWindowPos then
            imgui.SetNextWindowPos(mainX, settingsY, (ImGuiCond and ImGuiCond.Always) or 0)
        end
        if imgui.SetNextWindowSize then
            imgui.SetNextWindowSize(mainW, settingsH, (ImGuiCond and ImGuiCond.Always) or 0)
        end

        local sFlags = 0
        if ImGuiWindowFlags and bit32 and bit32.bor then
            sFlags = bit32.bor(
                ImGuiWindowFlags.NoTitleBar or 0,
                ImGuiWindowFlags.NoResize or 0,
                ImGuiWindowFlags.NoMove or 0,
                ImGuiWindowFlags.NoCollapse or 0,
                ImGuiWindowFlags.NoScrollbar or 0
            )
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
                if imgui.BeginTabItem('Abilities') then
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
                    SettingsUI.draw({
                        settings = Core.Settings,
                        themeNames = Themes.getThemeNames(),
                        onChange = function(key, value)
                            if tostring(key) == 'SideKickTheme' then
                                State._themeLocalSetAt = os.clock()
                            end
                            Core.set(key, value)
                        end,
                    })

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
                            imgui.SetCursorScreenPos(mx - size / 2, my - size / 2)
                            pcall(imgui.DrawTextureAnimation, animItems, size, size)
                            imgui.SetCursorScreenPos(restoreX, restoreY)
                        end
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
    if playStyle ~= 'manual' and Healing and Healing.tick then
        priorityHealingActive = Healing.tick(Core.Settings) == true
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

    -- Buff casting - only when not in priority healing mode and ability automation allowed
    if allowAbilityAutomation and not priorityHealingActive then
        Buff.buffTick()
    else
        if debugAutomationLogging and TL then
            TL.log('buff_tick_skip', 15, 'Buff.buffTick SKIP: allowAbilityAutomation=%s, priorityHealingActive=%s',
                tostring(allowAbilityAutomation), tostring(priorityHealingActive))
        end
    end

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

    -- Meditation (sit/stand) should run last to avoid fighting with casting/movement actions.
    if playStyle ~= 'manual' and Meditation and Meditation.tick then
        Meditation.tick(Core.Settings)
    end
end

local function syncModulesFromSettings()
    local now = os.clock()
    if (now - (State.lastStateSyncTick or 0)) < 0.2 then return end
    State.lastStateSyncTick = now

    -- Optional theme sync from GroupTarget bounds payload.
    if Core.Settings.SideKickSyncThemeWithGT == true then
        local gt = _G.GroupTargetBounds
        local gtTheme = gt and tostring(gt.activeTheme or '') or ''
        local localHoldUntil = (State._themeLocalSetAt or 0) + 1.0
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
                mq.cmd('/echo \\ag[SideKick]\\aw Autostart enabled!')
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
        elseif a1 == 'cache' then
            -- Debug command: show runtime cache state
            print(string.format('[Cache] Me: %s HP:%d Mana:%d Aggro:%d Combat:%s',
                RuntimeCache.me.name or 'nil', RuntimeCache.me.hp or 0, RuntimeCache.me.mana or 0,
                RuntimeCache.me.pctAggro or 0, tostring(RuntimeCache.me.combat)))
            print(string.format('[Cache] Target: %s HP:%d Named:%s Mezzed:%s',
                RuntimeCache.target.name or 'none', RuntimeCache.target.hp or 0,
                tostring(RuntimeCache.target.named), tostring(RuntimeCache.target.mezzed)))
            print(string.format('[Cache] Group: %d members, %d injured',
                RuntimeCache.group.count or 0, RuntimeCache.group.injuredCount or 0))
            print(string.format('[Cache] XTarget: %d haters, %d aggro deficit',
                RuntimeCache.xtarget.count or 0, RuntimeCache.xtarget.aggroDeficitCount or 0))
        elseif a1 == 'cc' then
            -- Debug command: show CC/mez state
            local localCount, remoteCount, totalCount = CC.getCounts()
            print(string.format('[CC] Local mezzes: %d, Remote mezzes: %d, Total: %d',
                localCount, remoteCount, totalCount))
            print(string.format('[CC] Has mezzed on XTarget: %s',
                tostring(CC.hasAnyMezzedOnXTarget())))

            for mobId, data in pairs(CC.allMezzes) do
                local remaining = data.expires - os.clock()
                print(string.format('  [%d] %s - %.1fs remaining (by %s)',
                    mobId, data.name or 'unknown', remaining, data.mezzer or 'self'))
            end
        elseif a1 == 'spell' then
            -- Debug command: show spell engine state
            local stateCode, stateName = SpellEngine.getState()
            local castInfo = SpellEngine.getCastInfo()
            print(string.format('[Spell] State: %s (%d)', stateName, stateCode))
            if castInfo then
                print(string.format('[Spell] Casting: %s (ID: %d)', castInfo.spellName, castInfo.spellId))
                print(string.format('[Spell] Target: %d, Retries left: %d', castInfo.targetId, castInfo.retriesLeft))
            end
        elseif a1 == 'testcast' then
            -- Debug command: test cast a spell
            local spellName = args[2]
            if spellName then
                print(string.format('[Spell] Testing cast: %s', spellName))
                local target = mq.TLO.Target
                local targetId = target and target() and target.ID() or 0
                local success, reason = SpellEngine.cast(spellName, targetId)
                print(string.format('[Spell] Result: %s (%s)', tostring(success), reason or 'ok'))
            else
                print('[Spell] Usage: /sidekick testcast <spellname>')
            end
        elseif a1 == 'assistme' then
            -- Broadcast assist me to all peers in same zone
            enqueue(function()
                ActorsCoordinator.broadcastAssistMe()
            end)
        elseif a1 == 'spellset' or a1 == 'ss' then
            SpellSetEditor.toggle()
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

    mq.imgui.init('SideKick', function()
        if Core.Settings.SideKickBarEnabled ~= false then
            Bar.draw({
                abilities = State.barAbilities,
                settings = Core.Settings,
                animSpellIcons = animSpellIcons,
                cooldownProbe = function(row) return Cooldowns.probe(row) end,
                helpers = Helpers,
                onActivate = function(def) enqueue(function() Abilities.activate(def) end) end,
            })
        end

        if Core.Settings.SideKickSpecialEnabled ~= false then
            SpecialBar.draw({
                settings = Core.Settings,
                animSpellIcons = animSpellIcons,
                cooldownProbe = function(row) return Cooldowns.probe(row) end,
                helpers = Helpers,
                onActivate = function(def) enqueue(function() Abilities.activate(def) end) end,
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
        SpellSetEditor.render()

        if State.shouldDraw then
            draw()
        end

        -- First-run autostart prompt (modal popup)
        drawAutostartPrompt()
    end)

    while State.isRunning do
        refreshClassAbilitiesIfNeeded()
        drainQueue()
        syncModulesFromSettings()
        tickAutomation()

        -- Check for zone change (immune database)
        ImmuneDB.loadZone()

        -- Update aggro warning state
        AggroWarning.update()

        -- Actors + GT dock/status updates (runs in main loop so yields are allowed elsewhere).
        if Core.Settings.ActorsEnabled ~= false then
            -- Docked when anchored to GroupTarget.
            local hasGT = (_G.GroupTargetBounds and _G.GroupTargetBounds.loaded)
            local function anchoredToGT(mode, target)
                mode = tostring(mode or 'none'):lower()
                if mode == 'none' then return false end
                target = Anchor and Anchor.normalizeTargetKey and Anchor.normalizeTargetKey(target or 'grouptarget') or tostring(target or 'grouptarget'):lower()
                return target == 'grouptarget'
            end
            local docked = hasGT and (
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
            })
            ActorsCoordinator.tick({ status = status })
        end

        mq.doevents()
        mq.delay(1)
    end

    -- Shutdown: save immune database
    ImmuneDB.shutdown()
end

return main
