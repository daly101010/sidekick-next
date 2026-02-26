-- Auto-rebuild EQ UI overlay from XML-derived data.
-- Renders screens/pieces using ImGui for layout verification at target resolution.

local mq = require('mq')
local imgui = require('ImGui')
local ImAnim = require('sidekick-next.lib.imanim')
local Cooldowns = require('sidekick-next.abilities.cooldowns')
local PixelBuffer = require('ui.texture_workbench.pixel_buffer')

local data = require('sidekick-next.eq_ui_data')

local UI_PATH = "F:/lua/UI/upscaled_4x_combined/"
local CLASSIC_ICONS_PATH = "F:/lua/UI/upscaled_4x_combined/previous spell icons/"
local OFFSETS_PATH = "F:/lua/sidekick-next/eq_ui_offsets.lua"

local animSpellIcons = mq.FindTextureAnimation and mq.FindTextureAnimation('A_SpellIcons') or nil
local animSpellIconsGem = mq.FindTextureAnimation and mq.FindTextureAnimation('A_SpellIconsGem') or nil
local animItems = mq.FindTextureAnimation and mq.FindTextureAnimation('A_DragItem') or nil

-- Classic spell icons: 40x40 icons in 256x256 = 6x6 grid = 36 icons per sheet
-- spells01.tga through spells07.tga cover icons 0-251
local classicSpellIconsCache = {}  -- { [sheetNum] = texture }
local classicSpellIconsGemCache = {}  -- { [sheetNum] = texture } for oval gem icons
local CLASSIC_ICON_SIZE = 40
local CLASSIC_ICON_GRID = 6
local CLASSIC_ICONS_PER_SHEET = 36
local CLASSIC_ICON_SHEETS = 7  -- spells01.tga through spells07.tga
local CLASSIC_ICON_MAX = CLASSIC_ICON_SHEETS * CLASSIC_ICONS_PER_SHEET - 1  -- 251

-- Gemicons: 24x24 cells in 256x256 = 10x10 grid = 100 icons per sheet
-- gemicons01.tga through gemicons23.tga (from EQ uiresources)
local classicGemIconsCache = {}  -- { [sheetNum] = texture }
local GEMICON_SIZE = 24
local GEMICON_GRID = 10
local GEMICONS_PER_SHEET = 100
local GEMICON_SHEETS = 23  -- gemicons01.tga through gemicons23.tga
local GEMICON_MAX = GEMICON_SHEETS * GEMICONS_PER_SHEET - 1  -- 2299

-- Classic item icons: 40x40 icons in 256x256 = 6x6 grid = 36 icons per sheet
-- dragitem1.tga through dragitem34.tga in UI folder
-- Item icon IDs start at 500, so cell = iconId - 500
local classicItemIconsCache = {}  -- { [sheetNum] = texture }
local DEFAULT_ITEM_ICON_OFFSET = 500  -- item icons start at 500 (some UIs use different offsets)
local CLASSIC_ITEM_ICON_SHEETS = 376  -- dragitem1.tga through dragitem376.tga
local CLASSIC_ITEM_ICON_MAX = DEFAULT_ITEM_ICON_OFFSET + (CLASSIC_ITEM_ICON_SHEETS * CLASSIC_ICONS_PER_SHEET) - 1

local State = {
    open = true,
    draw = false,
    showSettings = false,
    showBounds = false,
    showScreenNames = false,
    centerX = false,
    scaleOverride = 0, -- 0 = auto by height
    filterText = "",
    showAll = false,
    assetScale = 1.0,
    showControls = false,
    showFallback = false,
    editMode = false,
    enableClicks = true,
    drawCursorMirror = false,
    dragScreens = false,
    showPieceBounds = false,
    showPieceList = false,
    priorityGlobal = false,
    unusedAssetFilter = "",
    unusedAssetsByTex = nil,
    unusedAssetsTexList = nil,
    unusedAssetsCount = 0,
    unusedAssetsDirty = true,
    unusedPiecesFilter = "",
    unusedPiecesList = nil,
    unusedPiecesCount = 0,
    unusedPiecesDirty = true,
    unusedTexturesFilter = "",
    unusedTexturesList = nil,
    unusedTexturesCount = 0,
    unusedTexturesDirty = true,
    itemIconGrid = 6,
    itemIconSize = 40,
    itemIconOneBased = false,
    itemIconColumnMajor = true,
    previewAnim = nil,
    previewLabel = nil,
    docking = {},
    buffTwoColumn = true,
    showBuffs = true,
    showBuffTimers = true,
    showBuffLabels = true,
    buffIconScale = 1.0,
    buffLabelScale = 1.0,
    spellGemIconScale = 0.90,
    spellGemTintStrength = 2.0,
    spellGemCountOverride = 0,
    spellGemBgOverridePath = "F:/lua/sidekick-next/assets/window_pieces02_live.tga",
    hotbuttonGroupByNumber = true,
    autoSaveEdits = false,
    autoSaveDelay = 0.75,
    autoSavePending = false,
    autoSaveLastChange = 0,
    fontScale = 1.0,
    itemIconOffset = 500,
    selectedKey = nil,
    selectedPieces = {},
    selectedPieceScreen = nil,
    selectedScreens = {},
    dockBatchMargin = 0,
    batchMoveStep = 1,
    batchScalePct = 100,
    batchScalePositions = true,
    batchScalePivot = "center",
    brushEnabled = false,
    brushRadius = 6,
    brushStrength = 0.35,
    brushFalloff = true,
    brushAlphaThreshold = 1,
    brushOnlyBorders = true,
    brushTextureName = nil,
    brushBuffer = nil,
    brushDirty = false,
    brushMouseDown = false,
    invOpen = false,
    lastInvOpen = nil,
    pendingAbBuff = false,
    dirtyScreens = {},
    dirtyControls = {},
    dirtyChildren = {},
    dragging = false,
    dragKey = nil,
    dragOffsetX = 0,
    dragOffsetY = 0,
    dragInfo = nil,
    dragGroupKeys = nil,
    dragGroupOffsets = nil,
    offsets = {},
    sizeOverrides = {},
    priorities = {},
    gaugeValues = {},
    gaugeText = {},
    spellIcons = {},
    spellGemIcons = {},
    spellNames = {},
    spellGemIcons = {},
    labelText = {},
    controlTextOverrides = {}, -- user-edited button text that should override dynamic labelText
    buffIcons = {},
    buffRemaining = {},
    clickRegions = {},
    cast = { active = false, name = "", pct = 0 },
    spellbookOpen = false,
    actionsPage = 1, -- 1=Main, 2=Abilities, 3=Combat, 4=Socials
    actionsState = { grouped = false, standing = true, pendingInvite = false },
    hoverBuff = nil,
    altHeld = false,
    altSpellLabelScale = 1.2,
    altSpellLabelMinScale = 0.8,
    lastGaugeUpdate = 0,
}

-- forward decls used by layout load/save
local FindChildByName
local MarkDirtyScreen
local MarkDirtyControl
local MarkDirtyChild
local ComputeRect

local InvSlotBackgrounds = {
    InvSlot0 = "A_InvCharm",
    InvSlot1 = "A_InvEar",
    InvSlot2 = "A_InvHead",
    InvSlot3 = "A_InvFace",
    InvSlot4 = "A_InvEar2",
    InvSlot5 = "A_InvNeck",
    InvSlot6 = "A_InvShoulders",
    InvSlot7 = "A_InvArms",
    InvSlot8 = "A_InvAboutBody",
    InvSlot9 = "A_InvWrist",
    InvSlot10 = "A_InvWrist2",
    InvSlot11 = "A_InvRange",
    InvSlot12 = "A_InvHands",
    InvSlot13 = "A_InvPrimary",
    InvSlot14 = "A_InvSecondary",
    InvSlot15 = "A_InvRing",
    InvSlot16 = "A_InvRing2",
    InvSlot17 = "A_InvChest",
    InvSlot18 = "A_InvLegs",
    InvSlot19 = "A_InvFeet",
    InvSlot20 = "A_InvWaist",
    InvSlot21 = "A_InvPowerSource", -- power source (not visible in classic)
    InvSlot22 = "A_InvAmmo",   -- ammo
    InvSlot23 = "A_InvMain1",  -- pack1
    InvSlot24 = "A_InvMain2",  -- pack2
    InvSlot25 = "A_InvMain3",  -- pack3
    InvSlot26 = "A_InvMain4",  -- pack4
    InvSlot27 = "A_InvMain5",  -- pack5
    InvSlot28 = "A_InvMain6",  -- pack6
    InvSlot29 = "A_InvMain7",  -- pack7
    InvSlot30 = "A_InvMain8",  -- pack8
}

-- MQ InvSlot names - use numbers for reliability, names as fallback display
local InvSlotNames = {
    InvSlot0 = 0,   -- charm
    InvSlot1 = 1,   -- leftear
    InvSlot2 = 2,   -- head
    InvSlot3 = 3,   -- face
    InvSlot4 = 4,   -- rightear
    InvSlot5 = 5,   -- neck
    InvSlot6 = 6,   -- shoulder
    InvSlot7 = 7,   -- arms
    InvSlot8 = 8,   -- back
    InvSlot9 = 9,   -- leftwrist
    InvSlot10 = 10, -- rightwrist
    InvSlot11 = 11, -- range
    InvSlot12 = 12, -- hands
    InvSlot13 = 13, -- mainhand
    InvSlot14 = 14, -- offhand
    InvSlot15 = 15, -- leftfinger
    InvSlot16 = 16, -- rightfinger
    InvSlot17 = 17, -- chest
    InvSlot18 = 18, -- legs
    InvSlot19 = 19, -- feet
    InvSlot20 = 20, -- waist
    InvSlot21 = 21, -- power source
    InvSlot22 = 22, -- ammo
    InvSlot23 = 23, -- pack1
    InvSlot24 = 24, -- pack2
    InvSlot25 = 25, -- pack3
    InvSlot26 = 26, -- pack4
    InvSlot27 = 27, -- pack5
    InvSlot28 = 28, -- pack6
    InvSlot29 = 29, -- pack7
    InvSlot30 = 30, -- pack8
}

local ClassicPreset = {
    "SelectorWindow",
    "ChatWindow",
    "PlayerWindow",
    "TargetWindow",
    "CastSpellWnd",
    "HotButtonWnd",
    "BuffWindow",
    "ShortDurationBuffWindow",
}

local Visible = {}
local function ApplyClassicPreset()
    for name in pairs(data.screens) do
        Visible[name] = false
    end
    for _, name in ipairs(ClassicPreset) do
        if data.screens[name] then
            Visible[name] = true
        end
    end
end

ApplyClassicPreset()

local function DetectAssetScale()
    local ref = data.textures["window_pieces01.tga"] or data.textures["classic_pieces01.tga"]
    if ref and ref.w and ref.w > 0 then
        return ref.w / 256
    end
    return 1.0
end

State.assetScale = DetectAssetScale()

local ScreenOrder = {}
for name in pairs(data.screens) do
    table.insert(ScreenOrder, name)
end
table.sort(ScreenOrder, function(a, b) return a:lower() < b:lower() end)

local Textures = {}
local function GetTexture(name, overridePath)
    if not name or name == '' then return nil end
    local key = overridePath or name
    if Textures[key] then return Textures[key] end
    local path = overridePath or (UI_PATH .. name)
    local ok, tex = pcall(function()
        return mq.CreateTexture(path)
    end)
    if ok and tex then
        Textures[key] = tex
        return tex
    end
    return nil
end

local _texDebugOnce = {}
local function GetClassicSpellIconsTex(sheetNum)
    if sheetNum < 1 or sheetNum > CLASSIC_ICON_SHEETS then return nil end
    if classicSpellIconsCache[sheetNum] then return classicSpellIconsCache[sheetNum] end
    local filename = string.format("spells%02d.tga", sheetNum)
    local fullPath = CLASSIC_ICONS_PATH .. filename
    local ok, tex = pcall(function()
        return mq.CreateTexture(fullPath)
    end)

    -- Debug: log texture loading once per sheet
    if not _texDebugOnce[sheetNum] then
        _texDebugOnce[sheetNum] = true
        if ok and tex then
            print(string.format("[EQ UI] Loaded texture: %s (type=%s)", filename, type(tex)))
        else
            print(string.format("[EQ UI] FAILED to load texture: %s (ok=%s, tex=%s)", fullPath, tostring(ok), tostring(tex)))
        end
    end

    if ok and tex then
        classicSpellIconsCache[sheetNum] = tex
        return tex
    end
    return nil
end

-- Gem (oval) spell icons: spells01_gem.tga through spells07_gem.tga
local _texGemDebugOnce = {}
local function GetClassicSpellIconsGemTex(sheetNum)
    if sheetNum < 1 or sheetNum > CLASSIC_ICON_SHEETS then return nil end
    if classicSpellIconsGemCache[sheetNum] then return classicSpellIconsGemCache[sheetNum] end
    local filename = string.format("spells%02d_gem.tga", sheetNum)
    local fullPath = CLASSIC_ICONS_PATH .. filename
    local ok, tex = pcall(function()
        return mq.CreateTexture(fullPath)
    end)

    -- Debug: log texture loading once per sheet
    if not _texGemDebugOnce[sheetNum] then
        _texGemDebugOnce[sheetNum] = true
        if ok and tex then
            print(string.format("[EQ UI] Loaded gem texture: %s (type=%s)", filename, type(tex)))
        else
            print(string.format("[EQ UI] FAILED to load gem texture: %s (ok=%s, tex=%s)", fullPath, tostring(ok), tostring(tex)))
        end
    end

    if ok and tex then
        classicSpellIconsGemCache[sheetNum] = tex
        return tex
    end
    return nil
end

-- Load gemicons textures (24x24 spell icons for gem display)
local _gemIconTexDebugOnce = {}
local function GetGemIconsTex(sheetNum)
    if sheetNum < 1 or sheetNum > GEMICON_SHEETS then return nil end
    if classicGemIconsCache[sheetNum] then return classicGemIconsCache[sheetNum] end
    local filename = string.format("gemicons%02d.tga", sheetNum)
    local fullPath = UI_PATH .. filename
    local ok, tex = pcall(function()
        return mq.CreateTexture(fullPath)
    end)
    if not _gemIconTexDebugOnce[sheetNum] then
        _gemIconTexDebugOnce[sheetNum] = true
        if ok and tex then
            print(string.format("[EQ UI] Loaded gemicon texture: %s", filename))
        else
            print(string.format("[EQ UI] FAILED to load gemicon texture: %s", fullPath))
        end
    end
    if ok and tex then
        classicGemIconsCache[sheetNum] = tex
        return tex
    end
    return nil
end

local _itemTexDebugOnce = {}
local function GetClassicItemIconsTex(sheetNum)
    if sheetNum < 1 or sheetNum > CLASSIC_ITEM_ICON_SHEETS then return nil end
    if classicItemIconsCache[sheetNum] then return classicItemIconsCache[sheetNum] end
    local filename = string.format("dragitem%d.tga", sheetNum)
    local fullPath = UI_PATH .. filename
    local ok, tex = pcall(function()
        return mq.CreateTexture(fullPath)
    end)

    -- Debug: log texture loading once per sheet
    if not _itemTexDebugOnce[sheetNum] then
        _itemTexDebugOnce[sheetNum] = true
        if ok and tex then
            print(string.format("[EQ UI] Loaded item texture: %s (type=%s)", filename, type(tex)))
        else
            print(string.format("[EQ UI] FAILED to load item texture: %s (ok=%s, tex=%s)", fullPath, tostring(ok), tostring(tex)))
        end
    end

    if ok and tex then
        classicItemIconsCache[sheetNum] = tex
        return tex
    end
    return nil
end

local function GetOffset(key)
    local o = State.offsets[key]
    if not o then
        o = { x = 0, y = 0 }
        State.offsets[key] = o
    end
    return o
end

local function GetPriority(key)
    local p = State.priorities[key]
    if p == nil then
        State.priorities[key] = 0
        return 0
    end
    return p
end

local function PriorityBounds()
    local minP, maxP = 0, 0
    for _, v in pairs(State.priorities or {}) do
        if v < minP then minP = v end
        if v > maxP then maxP = v end
    end
    return minP, maxP
end

local function GetDock(screenName)
    State.docking = State.docking or {}
    local d = State.docking[screenName]
    if not d then
        d = { side = "none", margin = 0 }
        State.docking[screenName] = d
    end
    if d.side == nil then d.side = "none" end
    if d.margin == nil then d.margin = 0 end
    return d
end

local function IsScreenSelected(name)
    return State.selectedScreens and State.selectedScreens[name] == true
end

local function SetScreenSelected(name, val)
    State.selectedScreens = State.selectedScreens or {}
    State.selectedScreens[name] = val == true
end

local function ClearScreenSelection()
    State.selectedScreens = {}
end

local function RequestAutoSave()
    if State.autoSaveEdits == false then return end
    State.autoSavePending = true
    State.autoSaveLastChange = os.clock()
end

local function ParsePieceKey(key)
    if not key then return nil end
    local screenName, pieceName, kind = key:match("^(.-)::(.-)::(.-)$")
    if screenName and pieceName and kind then
        return screenName, pieceName, kind
    end
    return nil
end

local function IsPieceSelected(key)
    return State.selectedPieces and State.selectedPieces[key] == true
end

local function ClearPieceSelection()
    State.selectedPieces = {}
    State.selectedPieceScreen = nil
end

local function ClearAllSelection()
    State.selectedKey = nil
    ClearScreenSelection()
    ClearPieceSelection()
end

local function SetPieceSelected(key, val)
    local screenName = ParsePieceKey(key)
    if not screenName then return end
    if val then
        if State.selectedPieceScreen and State.selectedPieceScreen ~= screenName then
            ClearPieceSelection()
        end
        State.selectedPieceScreen = screenName
        State.selectedPieces = State.selectedPieces or {}
        State.selectedPieces[key] = true
    else
        if State.selectedPieces then
            State.selectedPieces[key] = nil
        end
        if State.selectedPieceScreen == screenName then
            local any = false
            if State.selectedPieces then
                for k, selected in pairs(State.selectedPieces) do
                    if selected then
                        local s = ParsePieceKey(k)
                        if s == screenName then
                            any = true
                            break
                        end
                    end
                end
            end
            if not any then
                State.selectedPieceScreen = nil
            end
        end
    end
end

local function SelectedPieceKeys(screenName)
    local keys = {}
    if not screenName or not State.selectedPieces then return keys end
    for key, selected in pairs(State.selectedPieces) do
        if selected then
            local s = ParsePieceKey(key)
            if s == screenName then
                table.insert(keys, key)
            end
        end
    end
    return keys
end


local function ApplyDockToSelected(side, margin)
    State.selectedScreens = State.selectedScreens or {}
    for name, selected in pairs(State.selectedScreens) do
        if selected then
            local dock = GetDock(name)
            dock.side = side or "none"
            if margin ~= nil then
                dock.margin = margin
            end
        end
    end
end


local function DockBaseX(screenName, scale, offsetX, vpWidth, screenW)
    local d = GetDock(screenName)
    local margin = tonumber(d.margin) or 0
    if d.side == "left" then
        return (margin - offsetX) / scale
    elseif d.side == "right" then
        return ((vpWidth - margin) - (screenW * scale) - offsetX) / scale
    end
    return nil
end

local function AddClickRegion(id, x, y, w, h, onClick, onRightClick, tooltip, onRightHold, ctrlName, opts)
    if not State.clickRegions then State.clickRegions = {} end
    if w <= 0 or h <= 0 then return end
    local dragPayload = nil
    local deferLeftClick = false
    if type(opts) == "table" then
        dragPayload = opts.dragPayload
        deferLeftClick = opts.deferLeftClick == true
    end
    table.insert(State.clickRegions, {
        id = id,
        x = x, y = y, w = w, h = h,
        onClick = onClick,
        onRightClick = onRightClick,
        onRightHold = onRightHold,  -- triggered when right mouse held > threshold
        tooltip = tooltip,  -- string or function returning string
        ctrlName = ctrlName,
        dragPayload = dragPayload,
        deferLeftClick = deferLeftClick,
    })
end

-- Track right-click hold state per region
local rightHoldState = {
    regionId = nil,
    startTime = 0,
    triggered = false,
}
local RIGHT_HOLD_THRESHOLD = 0.4  -- seconds to trigger hold
local leftHoldState = {
    regionId = nil,
    startTime = 0,
    dragged = false,
    clickFn = nil,
    payload = nil,
}
local LEFT_HOLD_THRESHOLD = 0.2
local CURSOR_CHECK_DELAY = 2.0
local ACTW_HOLD_THRESHOLD = 1.1
local ACTW_CURSOR_DELAY = 1.1
local DRAG_DEBUG = true
local function trim_str(s)
    if s == nil then return "" end
    return tostring(s):gsub("^%s+", ""):gsub("%s+$", "")
end
local function fmt_cd_short(rem)
    rem = tonumber(rem) or 0
    if rem <= 0 then return "" end
    if rem >= 60 then
        local m = math.floor(rem / 60)
        local s = math.floor(rem % 60)
        return string.format("%d:%02d", m, s)
    end
    if rem >= 10 then
        return string.format("%d", math.floor(rem + 0.5))
    end
    return string.format("%.1f", rem)
end
local function cursor_attachment_type()
    local okAtt, att = pcall(function() return mq.TLO.CursorAttachment end)
    if okAtt and att and att() ~= nil then
        local okType, typ = pcall(function() return att.Type() end)
        if okType and typ ~= nil then
            return trim_str(typ)
        end
    end
    return ""
end
local function drag_debug_once(payload, key, msg)
    if not DRAG_DEBUG or not payload then return end
    payload._dbg = payload._dbg or {}
    if payload._dbg[key] then return end
    payload._dbg[key] = true
    print(msg)
end
local function drag_payload_label(payload)
    if not payload or type(payload) ~= "table" then return "" end
    drag_debug_once(payload, "payload", string.format("\ay[EQ UI]\ax Drag label payload=%s", tostring(payload.type)))
    if payload.type == "actw" then
        if payload.kind == "ability" then
            local names = State.actionsState and State.actionsState.abilityNames or {}
            local out = trim_str(names[payload.idx or 0] or "")
            drag_debug_once(payload, "actw_ability", string.format(
                "\ay[EQ UI]\ax Drag label actw ability idx=%s name='%s' names=%s",
                tostring(payload.idx), out, tostring(names[payload.idx or 0])))
            return out
        elseif payload.kind == "combat" then
            local names = State.actionsState and State.actionsState.combatAbilityNames or {}
            local out = trim_str(names[payload.idx or 0] or "")
            drag_debug_once(payload, "actw_combat", string.format(
                "\ay[EQ UI]\ax Drag label actw combat idx=%s name='%s' names=%s",
                tostring(payload.idx), out, tostring(names[payload.idx or 0])))
            return out
        elseif payload.kind == "social" then
            local socials = State.socials or {}
            local out = trim_str((socials[payload.idx or 0] and socials[payload.idx or 0].name) or "")
            drag_debug_once(payload, "actw_social", string.format(
                "\ay[EQ UI]\ax Drag label actw social idx=%s name='%s'", tostring(payload.idx), out))
            return out
        elseif payload.kind == "command" then
            local ctrlName = payload.ctrlName or ""
            local label = ""
            if State.labelText and State.labelText[ctrlName] then
                label = tostring(State.labelText[ctrlName])
            elseif data.controls and data.controls[ctrlName] and data.controls[ctrlName].text then
                label = tostring(data.controls[ctrlName].text)
            else
                local map = {
                    AMP_WhoButton = "Who",
                    AMP_InviteButton = "Invite",
                    AMP_FollowButton = "Follow",
                    AMP_DisbandButton = "Disband",
                    AMP_CampButton = "Camp",
                    AMP_StandButton = "Stand",
                    AMP_SitButton = "Sit",
                    AMP_RunButton = "Run",
                    AMP_WalkButton = "Walk",
                }
                label = map[ctrlName] or ""
            end
            local out = trim_str(label)
            drag_debug_once(payload, "actw_command", string.format(
                "\ay[EQ UI]\ax Drag label actw command ctrl=%s name='%s' labelRaw='%s'",
                tostring(ctrlName), out, tostring(label)))
            return out
        end
    elseif payload.type == "hotbutton" and payload.idx then
        local page = State.hotbuttonPage or 1
        local infos = (State.hotbuttonsPages and State.hotbuttonsPages[page]) or State.hotbuttons
        local info = infos and infos[payload.idx] or nil
        local out = trim_str(info and info.name or "")
        drag_debug_once(payload, "hotbutton", string.format(
            "\ay[EQ UI]\ax Drag label hotbutton idx=%s name='%s'", tostring(payload.idx), out))
        return out
    end
    return ""
end
local function cursor_name()
    local okCur, cur = pcall(function() return mq.TLO.Cursor end)
    if okCur and cur and cur() ~= nil then
        local okName, nm = pcall(function() return cur.Name() end)
        if okName and nm ~= nil then return trim_str(nm) end
    end
    local okAtt, att = pcall(function() return mq.TLO.CursorAttachment end)
    if okAtt and att and att() ~= nil then
        local atype = ""
        local okType, typ = pcall(function() return att.Type() end)
        if okType and typ ~= nil then atype = trim_str(typ) end

        local name = ""
        local okSpell, sp = pcall(function() return att.Spell() end)
        if okSpell and sp ~= nil then name = trim_str(sp) end
        if name == "" then
            local okBtn, bt = pcall(function() return att.ButtonText() end)
            if okBtn and bt ~= nil then name = trim_str(bt) end
        end
        if name == "" then
            local okItem, it = pcall(function() return att.Item() end)
            if okItem and it then
                if type(it) == "function" then
                    local okCall, iv = pcall(it)
                    if okCall and iv and iv() ~= nil then
                        local okIn, iname = pcall(function() return iv.Name() end)
                        if okIn and iname ~= nil then name = trim_str(iname) end
                    end
                else
                    local okIn, iname = pcall(function() return it.Name() end)
                    if okIn and iname ~= nil then name = trim_str(iname) end
                end
            end
        end
        if name ~= "" then return name end
        if atype ~= "" then return atype end
    end
    return ""
end

local function QueueCursorCheck(payload)
    if not State.pendingCursorChecks then State.pendingCursorChecks = {} end
    payload.due = (payload.due or os.clock()) + (payload.delay or CURSOR_CHECK_DELAY)
    payload.stage = payload.stage or 0
    table.insert(State.pendingCursorChecks, payload)
end

local function ProcessPendingCursorChecks()
    local pending = State.pendingCursorChecks
    if not pending or #pending == 0 then return end
    local now = os.clock()
    for i = #pending, 1, -1 do
        local p = pending[i]
        if now >= (p.due or 0) then
            if p.dragId and (not State.dragSpell or State.dragSpell.dragId ~= p.dragId) then
                table.remove(pending, i)
            else
                local cur = cursor_name()
                if cur ~= "" then
                    if DRAG_DEBUG and p.debugTag then
                        print(string.format("\ay[EQ UI]\ax %s cursor='%s'", p.debugTag, cur))
                    end
                    table.remove(pending, i)
                else
                    if p.kind == "spellgem_pickup" and p.gemIndex then
                        local idx = p.gemIndex - 1
                        if p.stage == 0 then
                            if DRAG_DEBUG then
                                print(string.format("\ay[EQ UI]\ax Drag pickup fallback notify=/notify CastSpellWnd CSPW_Spell%d leftmouseup", idx))
                            end
                            mq.cmdf('/notify CastSpellWnd CSPW_Spell%d leftmouseup', idx)
                            p.stage = 1
                            p.due = now + (p.delay or CURSOR_CHECK_DELAY)
                        else
                            local altName = string.format("SpellGem%d", p.gemIndex)
                            if DRAG_DEBUG then
                                print(string.format("\ay[EQ UI]\ax Drag pickup alt notify=/notify CastSpellWnd %s leftmouseheld", altName))
                            end
                            mq.cmdf('/notify CastSpellWnd %s leftmouseheld', altName)
                            if DRAG_DEBUG then
                                print(string.format("\ay[EQ UI]\ax Drag pickup alt notify=/notify CastSpellWnd %s leftmouseup", altName))
                            end
                            mq.cmdf('/notify CastSpellWnd %s leftmouseup', altName)
                            table.remove(pending, i)
                        end
                    elseif p.kind == "invitem_pickup" then
                        if DRAG_DEBUG then
                            print(string.format("\ay[EQ UI]\ax Drag pickup fallback notify=/notify %s %s leftmouseup",
                                tostring(p.winName), tostring(p.ctrlName)))
                        end
                        if p.winName and p.ctrlName then
                            mq.cmdf('/notify %s %s leftmouseup', p.winName, p.ctrlName)
                        elseif p.slotRef ~= nil then
                            mq.cmdf('/itemnotify %s leftmouseup', tostring(p.slotRef))
                        end
                        table.remove(pending, i)
                    elseif p.kind == "actw_pickup" then
                        local cur = cursor_name()
                        local ctype = cursor_attachment_type()
                        if DRAG_DEBUG then
                            local dt = -1
                            if State.dragSpell and State.dragSpell.dragStart then
                                dt = now - (State.dragSpell.dragStart or now)
                            end
                            print(string.format("\ay[EQ UI]\ax Drag pickup action check t=%.2f dt=%.2f cursorType='%s' cursorName='%s'",
                                now, dt, tostring(ctype), tostring(cur)))
                        end
                        if cur ~= "" or ctype ~= "" then
                            if State.dragSpell and (not p.dragId or State.dragSpell.dragId == p.dragId) then
                                State.dragSpell.useGameCursor = true
                                drag_debug_once(State.dragSpell, "draw_game_ready", string.format(
                                    "\ay[EQ UI]\ax Drag pickup action cursor ready type='%s' name='%s'",
                                    tostring(ctype), tostring(cur)))
                            end
                            table.remove(pending, i)
                        else
                            p.stage = (p.stage or 0) + 1
                            if p.stage <= 3 then
                                p.due = now + (p.delay or 0.2)
                            else
                                table.remove(pending, i)
                            end
                        end
                    else
                        table.remove(pending, i)
                    end
                end
            end
        end
    end
end

local function is_empty_gem(gemIndex)
    local icon = State.spellIcons and State.spellIcons[gemIndex] or 0
    if icon and icon > 0 then return false end
    local ok, gem = pcall(function() return mq.TLO.Me.Gem(gemIndex) end)
    if ok and gem and gem() ~= nil then return false end
    return true
end

local function RenderClickRegions()
    if State.editMode or not State.enableClicks then
        State.clickRegions = {}
        State.mouseOverClickRegion = false
        return
    end
    local regions = State.clickRegions or {}
    if #regions == 0 then
        State.mouseOverClickRegion = false
        return
    end

    State.mouseOverClickRegion = false
    State.pressedCtrls = {}
    State.dragHoverHotbutton = nil

    local flags = bit32.bor(
        ImGuiWindowFlags.NoTitleBar,
        ImGuiWindowFlags.NoResize,
        ImGuiWindowFlags.NoMove,
        ImGuiWindowFlags.NoScrollbar,
        ImGuiWindowFlags.NoScrollWithMouse,
        ImGuiWindowFlags.NoCollapse,
        ImGuiWindowFlags.NoBackground,
        ImGuiWindowFlags.NoBringToFrontOnFocus,
        ImGuiWindowFlags.NoFocusOnAppearing,
        ImGuiWindowFlags.NoNavFocus,
        ImGuiWindowFlags.NoNav,
        ImGuiWindowFlags.NoSavedSettings
    )

    local now = os.clock()
    local function find_hotbutton_index()
        local hb = State.dragHoverHotbutton
        local hidx = hb and tonumber(hb:match("^HB_Button(%d+)$")) or nil
        if not hidx and State.hotbuttonRects then
            -- Inline mouse pos since GetMousePosSafe isn't defined yet
            local mx, my = 0, 0
            local okMp, mp = pcall(imgui.GetMousePos)
            if okMp and type(mp) == 'table' then
                mx, my = mp.x or 0, mp.y or 0
            end
            for i, rct in pairs(State.hotbuttonRects) do
                if mx >= rct.x and mx <= rct.x + rct.w and my >= rct.y and my <= rct.y + rct.h then
                    hidx = i
                    break
                end
            end
        end
        return hidx
    end

    imgui.PushStyleVar(ImGuiStyleVar.WindowPadding, 0, 0)
    imgui.PushStyleVar(ImGuiStyleVar.WindowBorderSize, 0)
    for i = 1, #regions do
        local r = regions[i]
        imgui.SetNextWindowPos(r.x, r.y)
        imgui.SetNextWindowSize(r.w, r.h)
        imgui.Begin("##EQUIInput_" .. r.id, true, flags)
        imgui.InvisibleButton("##btn_" .. r.id, r.w, r.h)

        -- Right click with hold detection
        local isHovered = imgui.IsItemHovered()
        local rightDown = imgui.IsMouseDown(ImGuiMouseButton.Right)
        local leftDown = imgui.IsMouseDown(ImGuiMouseButton.Left)

        -- Left click handling (allow drag on hold)
        if r.deferLeftClick then
            if imgui.IsItemClicked(ImGuiMouseButton.Left) then
                leftHoldState.regionId = r.id
                leftHoldState.startTime = now
                leftHoldState.dragged = false
                leftHoldState.clickFn = r.onClick
                leftHoldState.payload = r.dragPayload
            end
        elseif r.onClick and imgui.IsItemClicked(ImGuiMouseButton.Left) then
            r.onClick()
        end

        -- Track if mouse is over any click region (for cursor rendering)
        if isHovered then
            State.mouseOverClickRegion = true
        end
        if isHovered and r.ctrlName and r.ctrlName:match("^HB_Button(%d+)$") then
            State.dragHoverHotbutton = r.ctrlName
        end

        if leftHoldState.regionId == r.id then
            if leftDown then
                -- Mouse still held - check for drag initiation
                local holdThreshold = LEFT_HOLD_THRESHOLD
                if leftHoldState.payload and leftHoldState.payload.type == "actw" then
                    holdThreshold = ACTW_HOLD_THRESHOLD
                end
                if (not leftHoldState.dragged) and (now - leftHoldState.startTime) >= holdThreshold then
                    leftHoldState.dragged = true
                    State.dragSpell = leftHoldState.payload
                    if State.dragSpell and State.dragSpell.type == "spellgem" and State.dragSpell.gemIndex then
                        local idx = State.dragSpell.gemIndex - 1
                        State.dragSeq = (State.dragSeq or 0) + 1
                        State.dragSpell.dragId = State.dragSeq
                        if DRAG_DEBUG then
                            print(string.format("\ay[EQ UI]\ax Drag start gem=%d notify=/notify CastSpellWnd CSPW_Spell%d leftmouseheld", State.dragSpell.gemIndex, idx))
                        end
                        mq.cmdf('/notify CastSpellWnd CSPW_Spell%d leftmouseheld', idx)
                        State.dragSpell.pickupAltTried = false
                        QueueCursorCheck({
                            kind = "spellgem_pickup",
                            gemIndex = State.dragSpell.gemIndex,
                            dragId = State.dragSpell.dragId,
                            debugTag = "Drag pickup gem",
                        })
                    elseif State.dragSpell and State.dragSpell.type == "invitem" then
                        local slotRef = State.dragSpell.slotRef
                        local ctrlName = State.dragSpell.ctrlName
                        local winName = State.dragSpell.windowName or "InventoryWindow"
                        local hasItem = false
                        if slotRef ~= nil then
                            local okSlot, slot = pcall(function() return mq.TLO.InvSlot(slotRef) end)
                            if okSlot and slot and slot() ~= nil then
                                local it = slot.Item
                                if it and it() ~= nil then
                                    hasItem = true
                                end
                            end
                        end
                        if hasItem then
                            State.dragSeq = (State.dragSeq or 0) + 1
                            State.dragSpell.dragId = State.dragSeq
                            if DRAG_DEBUG then
                                print(string.format("\ay[EQ UI]\ax Drag start item slot=%s notify=/notify %s %s leftmouseheldup",
                                    tostring(slotRef), tostring(winName), tostring(ctrlName)))
                            end
                            if winName and ctrlName then
                                mq.cmdf('/notify %s %s leftmouseheldup', winName, ctrlName)
                            elseif slotRef ~= nil then
                                mq.cmdf('/itemnotify %s leftmouseheldup', tostring(slotRef))
                            end
                            QueueCursorCheck({
                                kind = "invitem_pickup",
                                slotRef = slotRef,
                                ctrlName = ctrlName,
                                winName = winName,
                                dragId = State.dragSpell.dragId,
                                debugTag = "Drag pickup item",
                            })
                        else
                            State.dragSpell = nil
                        end
                    elseif State.dragSpell and State.dragSpell.type == "hotbutton" and State.dragSpell.idx then
                        local idx = State.dragSpell.idx
                        local page = State.hotbuttonPage or 1
                        local infos = (State.hotbuttonsPages and State.hotbuttonsPages[page]) or State.hotbuttons
                        local info = infos and infos[idx] or nil
                        local hasData = info and info.name and info.name ~= ""
                        if hasData then
                            local hbPath = string.format("HotButtonWnd/HB_Button%d", idx)
                            if DRAG_DEBUG then
                                print(string.format("\ay[EQ UI]\ax Hotbutton hold pickup idx=%d notify=/notify \"%s\" HB_SpellGem leftmouseheldup", idx, hbPath))
                            end
                            mq.cmdf('/notify "%s" HB_SpellGem leftmouseheldup', hbPath)
                            State.lastHotbuttonUpdate = 0
                        else
                            if DRAG_DEBUG then
                                print(string.format("\ay[EQ UI]\ax Hotbutton hold pickup idx=%d skipped (empty)", idx))
                            end
                            State.dragSpell = nil
                        end
                    elseif State.dragSpell and State.dragSpell.type == "actw" and State.dragSpell.ctrlName then
                        local kind = State.dragSpell.kind
                        local idx = State.dragSpell.idx
                        local hasData = true
                        if kind == "ability" then
                            local ids = State.actionsState and State.actionsState.abilityIds or {}
                            local id = ids[idx or 0] or -1
                            hasData = id ~= nil and id > 0
                        elseif kind == "combat" then
                            local names = State.actionsState and State.actionsState.combatAbilityNames or {}
                            local nm = names[idx or 0] or ""
                            hasData = nm ~= ""
                        elseif kind == "social" then
                            local socials = State.socials or {}
                            local nm = (socials[idx or 0] and socials[idx or 0].name) or ""
                            hasData = nm ~= ""
                        end
                        if hasData then
                            local winPath = string.format("ActionsWindow/%s", State.dragSpell.ctrlName)
                            if DRAG_DEBUG then
                                print(string.format("\ay[EQ UI]\ax Actions hold pickup ctrl=%s notify=/notify \"%s\" 0 leftmouseheldup",
                                    tostring(State.dragSpell.ctrlName), winPath))
                            end
                            mq.cmdf('/notify "%s" 0 leftmouseheldup', winPath)
                            State.dragSeq = (State.dragSeq or 0) + 1
                            State.dragSpell.dragId = State.dragSeq
                            State.dragSpell.dragStart = now
                            if DRAG_DEBUG then
                                print(string.format("\ay[EQ UI]\ax Actions drag start t=%.2f", now))
                            end
                            State.dragSpell.useGameCursor = false
                            QueueCursorCheck({
                                kind = "actw_pickup",
                                dragId = State.dragSpell.dragId,
                                delay = ACTW_CURSOR_DELAY,
                                debugTag = "Drag pickup action",
                            })
                        else
                            if DRAG_DEBUG then
                                print(string.format("\ay[EQ UI]\ax Actions hold pickup ctrl=%s skipped (empty)", tostring(State.dragSpell.ctrlName)))
                            end
                            State.dragSpell = nil
                        end
                    end
                end
            else
                -- Mouse released - handle click or drag drop
                if leftHoldState.dragged then
                    if State.dragSpell and State.dragSpell.type == "spellgem" and State.dragSpell.gemIndex then
                        local hidx = find_hotbutton_index()
                        if hidx then
                            local hbPath = string.format("HotButtonWnd/HB_Button%d", hidx)
                            if DRAG_DEBUG then
                                print(string.format("\ay[EQ UI]\ax Drag drop to HB_Button%d notify=/notify \"%s\" HB_SpellGem leftmouseup", hidx, hbPath))
                            end
                            mq.cmdf('/notify "%s" HB_SpellGem leftmouseup', hbPath)
                            State.lastHotbuttonUpdate = 0
                        elseif DRAG_DEBUG then
                            print("\ay[EQ UI]\ax Drag drop: no hotbutton under cursor")
                        end
                        local idx = State.dragSpell.gemIndex - 1
                        if DRAG_DEBUG then
                            print(string.format("\ay[EQ UI]\ax Drag release gem=%d notify=/notify CastSpellWnd CSPW_Spell%d leftmouseheldup", State.dragSpell.gemIndex, idx))
                        end
                        mq.cmdf('/notify CastSpellWnd CSPW_Spell%d leftmouseheldup', idx)
                        if DRAG_DEBUG then
                            print(string.format("\ay[EQ UI]\ax Cursor after drop='%s'", cursor_name()))
                        end
                    elseif State.dragSpell and State.dragSpell.type == "invitem" then
                        local hidx = find_hotbutton_index()
                        if hidx then
                            local hbPath = string.format("HotButtonWnd/HB_Button%d", hidx)
                            if DRAG_DEBUG then
                                print(string.format("\ay[EQ UI]\ax Drag drop item to HB_Button%d notify=/notify \"%s\" HB_SpellGem leftmouseup", hidx, hbPath))
                            end
                            mq.cmdf('/notify "%s" HB_SpellGem leftmouseup', hbPath)
                            State.lastHotbuttonUpdate = 0
                        elseif DRAG_DEBUG then
                            print("\ay[EQ UI]\ax Drag drop item: no hotbutton under cursor")
                        end
                    elseif State.dragSpell and State.dragSpell.type == "actw" then
                        local hidx = find_hotbutton_index()
                        if hidx then
                            local hbPath = string.format("HotButtonWnd/HB_Button%d", hidx)
                            if DRAG_DEBUG then
                                print(string.format("\ay[EQ UI]\ax Drag drop action to HB_Button%d notify=/notify \"%s\" HB_SpellGem leftmouseup", hidx, hbPath))
                            end
                            mq.cmdf('/notify "%s" HB_SpellGem leftmouseup', hbPath)
                            State.lastHotbuttonUpdate = 0
                        elseif DRAG_DEBUG then
                            print("\ay[EQ UI]\ax Drag drop action: no hotbutton under cursor")
                        end
                    end
                else
                    -- Not a drag, just a click - execute click handler
                    if leftHoldState.clickFn then leftHoldState.clickFn() end
                end
                -- Reset state
                leftHoldState.regionId = nil
                leftHoldState.startTime = 0
                leftHoldState.dragged = false
                leftHoldState.clickFn = nil
                leftHoldState.payload = nil
                State.dragSpell = nil
            end
        end

        if r.onRightHold then
            -- Track right mouse hold state
            if isHovered and imgui.IsItemClicked(ImGuiMouseButton.Right) then
                -- Start tracking hold
                rightHoldState.regionId = r.id
                rightHoldState.startTime = now
                rightHoldState.triggered = false
            end

            if rightHoldState.regionId == r.id then
                if rightDown and isHovered then
                    -- Check if hold threshold reached
                    if not rightHoldState.triggered and (now - rightHoldState.startTime) >= RIGHT_HOLD_THRESHOLD then
                        rightHoldState.triggered = true
                        r.onRightHold()
                    end
                elseif imgui.IsItemClicked(ImGuiMouseButton.Right) == false and not rightDown then
                    -- Mouse released - trigger quick click if not held long enough
                    if not rightHoldState.triggered and r.onRightClick then
                        r.onRightClick()
                    end
                    -- Reset hold state
                    rightHoldState.regionId = nil
                    rightHoldState.startTime = 0
                    rightHoldState.triggered = false
                end
            end
        else
            -- No hold handler - use simple right click
            if r.onRightClick and imgui.IsItemClicked(ImGuiMouseButton.Right) then
                r.onRightClick()
            end
        end

        -- Show tooltip on hover
        if r.tooltip and isHovered then
            local tooltipText = r.tooltip
            if type(r.tooltip) == 'function' then
                tooltipText = r.tooltip()
            end
            if tooltipText and tooltipText ~= '' then
                imgui.SetTooltip(tooltipText)
            end
        end
        if r.ctrlName and imgui.IsItemActive() then
            State.pressedCtrls[r.ctrlName] = true
        end
        imgui.End()
    end
    imgui.PopStyleVar(2)
    State.clickRegions = {}
end

local function BuildKey(screenName, pieceName, kind)
    return string.format("%s::%s::%s", screenName or "", pieceName or "", kind or "piece")
end

local function BuildScreenKey(screenName)
    return string.format("screen::%s", screenName or "")
end

local function deep_copy(value, seen)
    if type(value) ~= "table" then return value end
    if not seen then seen = {} end
    if seen[value] then return seen[value] end
    local out = {}
    seen[value] = out
    for k, v in pairs(value) do
        out[deep_copy(k, seen)] = deep_copy(v, seen)
    end
    return out
end

local function MakeUniqueControlName(baseName)
    baseName = tostring(baseName or "")
    if baseName == "" then return nil end
    local stem, slot = baseName:match("^(.-)(%d+)$")
    local n = 1
    while n < 10000 do
        local candidate
        if slot then
            candidate = string.format("%s_copy%d_%s", stem, n, slot)
        else
            candidate = string.format("%s_copy%d", baseName, n)
        end
        if not data.controls[candidate] then
            return candidate
        end
        n = n + 1
    end
    return nil
end

local function DuplicatePiece(screenName, pieceName)
    if not screenName or not pieceName then return nil end
    local screen = data.screens[screenName]
    if not screen then return nil end
    local ctrl = data.controls[pieceName]
    if not ctrl then return nil end
    local newName = MakeUniqueControlName(pieceName)
    if not newName then return nil end
    local newCtrl = deep_copy(ctrl)
    newCtrl.name = newName
    data.controls[newName] = newCtrl
    screen.pieces = screen.pieces or {}
    table.insert(screen.pieces, newName)
    MarkDirtyControl(newName)
    MarkDirtyScreen(screenName)
    State.unusedPiecesDirty = true
    return newName
end

local function HotbuttonGroupKeys(screenName, targetNum)
    if not screenName or not targetNum then return {} end
    local screen = data.screens[screenName]
    if not screen then return {} end
    local keys = {}
    local function try_add(pieceName, kind)
        local ctrl = data.controls[pieceName]
        local name = (ctrl and ctrl.name) or pieceName or ""
        local num = name:match("(%d+)$")
        if num and tonumber(num) == targetNum then
            table.insert(keys, BuildKey(screenName, pieceName, kind))
        end
    end
    local pieces = screen.pieces or {}
    for i = 1, #pieces do
        try_add(pieces[i], "piece")
    end
    local children = screen.children or {}
    for i = 1, #children do
        local child = children[i]
        local childName = child and (child.name or ("child" .. i)) or ("child" .. i)
        try_add(childName, "child")
    end
    return keys
end

local function ApplySizeOverride(key, size)
    if not key or type(size) ~= "table" then return end
    local w = tonumber(size.w) or tonumber(size.W)
    local h = tonumber(size.h) or tonumber(size.H)
    if not w and not h then return end

    if key:sub(1, 8) == "screen::" then
        local screenName = key:sub(9)
        local screen = data.screens[screenName]
        if screen then
            if w then screen.w = w end
            if h then screen.h = h end
        end
        return
    end

    local screenName, pieceName, kind = key:match("^(.-)::(.-)::(.-)$")
    if not screenName or not pieceName or not kind then
        local ctrlName = key:match("^control::(.+)$")
        if ctrlName then
            local ctrl = data.controls[ctrlName]
            if ctrl then
                if w then ctrl.w = w end
                if h then ctrl.h = h end
            end
        end
        return
    end

    if kind == "child" then
        local screen = data.screens[screenName]
        if screen and screen.children then
            for i = 1, #screen.children do
                local child = screen.children[i]
                if child and child.name == pieceName then
                    if w then child.w = w end
                    if h then child.h = h end
                    return
                end
            end
        end
    else
        local ctrl = data.controls[pieceName]
        if ctrl then
            if w then ctrl.w = w end
            if h then ctrl.h = h end
        end
    end
end

local function ApplySizeOverrides(overrides)
    if type(overrides) ~= "table" then return end
    for key, size in pairs(overrides) do
        ApplySizeOverride(key, size)
    end
end

local function ScreenPriorityKeys(screenName)
    local keys = {}
    if not screenName then return keys end
    table.insert(keys, BuildScreenKey(screenName))
    local screen = data.screens[screenName]
    if screen then
        local pieces = screen.pieces or {}
        for i = 1, #pieces do
            table.insert(keys, BuildKey(screenName, pieces[i], "piece"))
        end
        local children = screen.children or {}
        for i = 1, #children do
            local child = children[i]
            local childName = child.name or ("child" .. i)
            table.insert(keys, BuildKey(screenName, childName, "child"))
        end
    end
    return keys
end

local function ScreenPieceKeys(screenName)
    local keys = {}
    if not screenName then return keys end
    local screen = data.screens[screenName]
    if not screen then return keys end
    local pieces = screen.pieces or {}
    for i = 1, #pieces do
        table.insert(keys, BuildKey(screenName, pieces[i], "piece"))
    end
    local children = screen.children or {}
    for i = 1, #children do
        local child = children[i]
        local childName = child.name or ("child" .. i)
        table.insert(keys, BuildKey(screenName, childName, "child"))
    end
    return keys
end

local function GetBatchScreens()
    local list = {}
    local seen = {}
    if State.selectedKey and State.selectedKey:sub(1, 8) == "screen::" then
        local name = State.selectedKey:sub(9)
        if name ~= "" then
            seen[name] = true
            table.insert(list, name)
        end
    end
    if State.selectedScreens then
        for name, selected in pairs(State.selectedScreens) do
            if selected and not seen[name] then
                seen[name] = true
                table.insert(list, name)
            end
        end
    end
    return list
end

local function ApplyBatchOffset(screenName, dx, dy)
    local keys = ScreenPieceKeys(screenName)
    for i = 1, #keys do
        local key = keys[i]
        local off = GetOffset(key)
        off.x = (tonumber(off.x) or 0) + dx
        off.y = (tonumber(off.y) or 0) + dy
        State.offsets[key] = off
    end
end

local function ApplyBatchScale(screenName, scaleFactor)
    if not scaleFactor or scaleFactor <= 0 then return end
    local keys = ScreenPieceKeys(screenName)
    local screen = data.screens[screenName]
    if not screen then return end
    local screenKey = BuildScreenKey(screenName)
    local screenOff = GetOffset(screenKey)
    local baseRect = {
        x = (screen.x or 0) + (screenOff.x or 0),
        y = (screen.y or 0) + (screenOff.y or 0),
        w = screen.w or 0,
        h = screen.h or 0,
    }
    local pivotX = baseRect.x
    local pivotY = baseRect.y
    if State.batchScalePivot == "center" then
        pivotX = baseRect.x + (baseRect.w * 0.5)
        pivotY = baseRect.y + (baseRect.h * 0.5)
    end

    for i = 1, #keys do
        local key = keys[i]
        local sName, pName, kind = key:match("^(.-)::(.-)::(.-)$")
        if sName and pName and kind then
            local ctrl = nil
            if kind == "child" then
                ctrl = FindChildByName(sName, pName)
            else
                ctrl = data.controls[pName]
            end
            if ctrl then
                local w = tonumber(ctrl.w) or 0
                local h = tonumber(ctrl.h) or 0
                local baseX, baseY = ComputeRect(baseRect, ctrl)
                if w > 0 or h > 0 then
                    local newW = w > 0 and math.max(1, math.floor((w * scaleFactor) + 0.5)) or nil
                    local newH = h > 0 and math.max(1, math.floor((h * scaleFactor) + 0.5)) or nil
                    State.sizeOverrides[key] = { w = newW, h = newH }
                    ApplySizeOverride(key, { w = newW, h = newH })
                    if kind == "child" then
                        MarkDirtyChild(sName .. "::" .. pName)
                    else
                        MarkDirtyControl(pName)
                    end
                end
                if State.batchScalePositions then
                    local off = GetOffset(key)
                    local posX = (baseX or 0) + (off.x or 0)
                    local posY = (baseY or 0) + (off.y or 0)
                    local newPosX = pivotX + ((posX - pivotX) * scaleFactor)
                    local newPosY = pivotY + ((posY - pivotY) * scaleFactor)
                    local newOffX = math.floor((newPosX - (baseX or 0)) + 0.5)
                    local newOffY = math.floor((newPosY - (baseY or 0)) + 0.5)
                    State.offsets[key] = { x = newOffX, y = newOffY }
                end
            end
        end
    end
end

local function CenterScreenOnViewport(screenName, viewport)
    if not screenName or not viewport then return end
    local screen = data.screens[screenName]
    if not screen then return end

    local vpSize = viewport.Size
    local scale = (State.scaleOverride and State.scaleOverride > 0 and State.scaleOverride)
        or (vpSize.y / data.base.h)
    local totalW = data.base.w * scale
    local offsetX = State.centerX and (vpSize.x - totalW) * 0.5 or 0

    local dockBaseX = DockBaseX(screenName, scale, offsetX, vpSize.x, screen.w) or screen.x
    local screenKey = BuildScreenKey(screenName)
    local off = GetOffset(screenKey)

    local targetCenterX = vpSize.x * 0.5
    local targetCenterY = vpSize.y * 0.5

    local newOffX = ((targetCenterX - offsetX) / scale) - dockBaseX - (screen.w * 0.5)
    local newOffY = (targetCenterY / scale) - screen.y - (screen.h * 0.5)

    off.x = math.floor(newOffX + 0.5)
    off.y = math.floor(newOffY + 0.5)
    State.offsets[screenKey] = off
end

local function IsBorderTexture(texName)
    if not texName then return false end
    local name = texName:lower()
    return name:find("border", 1, true)
        or name:find("wndborder", 1, true)
        or name:find("window_pieces", 1, true)
        or name:find("pieces", 1, true)
        or name:find("scrollbar", 1, true)
        or name:find("gutter", 1, true)
        or name:find("pane", 1, true)
        or name:find("shade", 1, true)
end

local function GetBrushBuffer(texName)
    if not texName or texName == "" then return nil end
    if State.brushTextureName == texName and State.brushBuffer then
        return State.brushBuffer
    end
    local path = UI_PATH .. texName
    local buf, err = PixelBuffer.fromFile(path)
    if not buf then
        print(string.format("\ay[EQ UI]\ax Brush load failed: %s", tostring(err)))
        return nil
    end
    State.brushTextureName = texName
    State.brushBuffer = buf
    State.brushDirty = false
    return buf
end

local function AverageNeighborhood(buffer, x, y, width, height, alphaThreshold)
    local sumR, sumG, sumB, count = 0, 0, 0, 0
    for ny = y - 1, y + 1 do
        if ny >= 0 and ny < height then
            for nx = x - 1, x + 1 do
                if nx >= 0 and nx < width then
                    local r, g, b, a = buffer:getPixel(nx, ny)
                    if a > alphaThreshold then
                        sumR = sumR + r
                        sumG = sumG + g
                        sumB = sumB + b
                        count = count + 1
                    end
                end
            end
        end
    end
    if count == 0 then return nil end
    return sumR / count, sumG / count, sumB / count
end

local function ApplyBlendBrush(buffer, cx, cy, radius, strength, alphaThreshold, falloff, bounds)
    if not buffer then return end
    local width, height = buffer:getWidth(), buffer:getHeight()
    radius = math.max(1, math.floor(radius or 1))
    strength = math.max(0, math.min(1, tonumber(strength) or 0))
    alphaThreshold = math.max(0, math.min(255, math.floor(alphaThreshold or 0)))

    local r2 = radius * radius
    local minX = math.max(0, math.floor(cx - radius))
    local maxX = math.min(width - 1, math.floor(cx + radius))
    local minY = math.max(0, math.floor(cy - radius))
    local maxY = math.min(height - 1, math.floor(cy + radius))

    local bx0, by0, bx1, by1 = nil, nil, nil, nil
    if bounds then
        bx0, by0, bx1, by1 = bounds.x0, bounds.y0, bounds.x1, bounds.y1
    end

    for y = minY, maxY do
        if by0 and (y < by0 or y > by1) then goto continue_row end
        for x = minX, maxX do
            if bx0 and (x < bx0 or x > bx1) then goto continue_col end
            local dx = x - cx
            local dy = y - cy
            local dist2 = dx * dx + dy * dy
            if dist2 <= r2 then
                local r, g, b, a = buffer:getPixel(x, y)
                if a > alphaThreshold then
                    local ar, ag, ab = AverageNeighborhood(buffer, x, y, width, height, alphaThreshold)
                    if ar then
                        local t = strength
                        if falloff and radius > 0 then
                            local dist = math.sqrt(dist2)
                            t = t * (1 - (dist / radius))
                        end
                        if t > 0 then
                            local nr = r + (ar - r) * t
                            local ng = g + (ag - g) * t
                            local nb = b + (ab - b) * t
                            buffer:setPixel(x, y, nr, ng, nb, a)
                        end
                    end
                end
            end
            ::continue_col::
        end
        ::continue_row::
    end
end

local function SetScreenPriority(screenName, value)
    for _, key in ipairs(ScreenPriorityKeys(screenName)) do
        State.priorities[key] = value
    end
end

local function LoadOffsets()
    local chunk = loadfile(OFFSETS_PATH)
    if not chunk then return false end
    local ok, tbl = pcall(chunk)
    if ok and type(tbl) == 'table' then
        -- Ensure dirty-tracking tables exist so loaded entries survive save cycles
        State.dirtyScreens = State.dirtyScreens or {}
        State.dirtyControls = State.dirtyControls or {}
        State.dirtyChildren = State.dirtyChildren or {}

        if type(tbl.screenEdits) == 'table' then
            for name, ed in pairs(tbl.screenEdits) do
                local screen = data.screens[name]
                if screen and type(ed) == 'table' then
                    for k, v in pairs(ed) do
                        screen[k] = v
                    end
                    State.dirtyScreens[name] = true
                end
            end
        end
        if type(tbl.screenPieces) == 'table' then
            for name, pieces in pairs(tbl.screenPieces) do
                local screen = data.screens[name]
                if screen and type(pieces) == 'table' then
                    local list = {}
                    for i = 1, #pieces do
                        list[i] = pieces[i]
                    end
                    screen.pieces = list
                    State.dirtyScreens[name] = true
                end
            end
        end
        if type(tbl.controlEdits) == 'table' then
            State.controlTextOverrides = {} -- reset text overrides
            for name, ed in pairs(tbl.controlEdits) do
                local ctrl = data.controls[name]
                if type(ed) == 'table' then
                    if not ctrl then
                        ctrl = {}
                        data.controls[name] = ctrl
                    end
                    for k, v in pairs(ed) do
                        ctrl[k] = v
                    end
                    if ctrl.name == nil then
                        ctrl.name = name
                    end
                    -- Track user-edited text so it overrides dynamic labelText
                    if ed.text ~= nil then
                        State.controlTextOverrides[name] = ed.text
                    end
                    State.dirtyControls[name] = true
                end
            end
        end
        if type(tbl.childEdits) == 'table' then
            for key, ed in pairs(tbl.childEdits) do
                local screenName, childName = tostring(key):match("^(.-)::(.-)$")
                local child = screenName and childName and FindChildByName(screenName, childName) or nil
                if child and type(ed) == 'table' then
                    for k, v in pairs(ed) do
                        child[k] = v
                    end
                    State.dirtyChildren[key] = true
                end
            end
        end
        if type(tbl.offsets) == 'table' then
            State.offsets = tbl.offsets
        else
            State.offsets = tbl
        end
        if type(tbl.visible) == 'table' then
            for name in pairs(data.screens) do
                Visible[name] = tbl.visible[name] == true
            end
        end
        if type(tbl.priorities) == 'table' then
            State.priorities = tbl.priorities
        end
        if type(tbl.docking) == 'table' then
            State.docking = tbl.docking
        end
        if type(tbl.sizes) == 'table' then
            State.sizeOverrides = tbl.sizes
            ApplySizeOverrides(State.sizeOverrides)
        else
            State.sizeOverrides = {}
        end
        if tbl.showAll ~= nil then
            State.showAll = tbl.showAll == true
        end
        if tbl.priorityGlobal ~= nil then
            State.priorityGlobal = tbl.priorityGlobal == true
        end
        if tbl.drawCursorMirror ~= nil then
            State.drawCursorMirror = tbl.drawCursorMirror == true
        end
        if tbl.scaleOverride ~= nil then
            State.scaleOverride = tonumber(tbl.scaleOverride) or State.scaleOverride
        end
        if tbl.fontScale ~= nil then
            State.fontScale = tonumber(tbl.fontScale) or State.fontScale
        end
        if tbl.invOpen ~= nil then
            State.invOpen = tbl.invOpen == true
        else
            State.invOpen = Visible["InventoryWindow"] == true
        end
        if tbl.buffIconScale ~= nil then
            State.buffIconScale = tonumber(tbl.buffIconScale) or 1.0
        end
        if tbl.buffLabelScale ~= nil then
            State.buffLabelScale = tonumber(tbl.buffLabelScale) or 1.0
        end
        if tbl.spellGemIconScale ~= nil then
            State.spellGemIconScale = tonumber(tbl.spellGemIconScale) or State.spellGemIconScale
        end
        if tbl.spellGemTintStrength ~= nil then
            State.spellGemTintStrength = tonumber(tbl.spellGemTintStrength) or State.spellGemTintStrength
        end
        if tbl.spellGemCountOverride ~= nil then
            State.spellGemCountOverride = tonumber(tbl.spellGemCountOverride) or State.spellGemCountOverride
        end
        if tbl.showBounds ~= nil then
            State.showBounds = tbl.showBounds == true
        end
        if tbl.showScreenNames ~= nil then
            State.showScreenNames = tbl.showScreenNames == true
        end
        if tbl.centerX ~= nil then
            State.centerX = tbl.centerX == true
        end
        if tbl.showControls ~= nil then
            State.showControls = tbl.showControls == true
        end
        if tbl.showFallback ~= nil then
            State.showFallback = tbl.showFallback == true
        end
        if tbl.editMode ~= nil then
            State.editMode = tbl.editMode == true
        end
        if tbl.enableClicks ~= nil then
            State.enableClicks = tbl.enableClicks == true
        end
        if tbl.dragScreens ~= nil then
            State.dragScreens = tbl.dragScreens == true
        end
        if tbl.showPieceBounds ~= nil then
            State.showPieceBounds = tbl.showPieceBounds == true
        end
        if tbl.showPieceList ~= nil then
            State.showPieceList = tbl.showPieceList == true
        end
        if tbl.filterText ~= nil then
            State.filterText = tostring(tbl.filterText or "")
        end
        if tbl.itemIconOffset ~= nil then
            State.itemIconOffset = tonumber(tbl.itemIconOffset) or State.itemIconOffset
        end
        if tbl.itemIconGrid ~= nil then
            State.itemIconGrid = tonumber(tbl.itemIconGrid) or State.itemIconGrid
        end
        if tbl.itemIconSize ~= nil then
            State.itemIconSize = tonumber(tbl.itemIconSize) or State.itemIconSize
        end
        if tbl.itemIconOneBased ~= nil then
            State.itemIconOneBased = tbl.itemIconOneBased == true
        end
        if tbl.itemIconColumnMajor ~= nil then
            State.itemIconColumnMajor = tbl.itemIconColumnMajor == true
        end
        if tbl.buffTwoColumn ~= nil then
            State.buffTwoColumn = tbl.buffTwoColumn == true
        end
        if tbl.hotbuttonGroupByNumber ~= nil then
            State.hotbuttonGroupByNumber = tbl.hotbuttonGroupByNumber == true
        end
        if tbl.showBuffs ~= nil then
            State.showBuffs = tbl.showBuffs == true
        end
        if tbl.showBuffTimers ~= nil then
            State.showBuffTimers = tbl.showBuffTimers == true
        end
        if tbl.showBuffLabels ~= nil then
            State.showBuffLabels = tbl.showBuffLabels == true
        end
        State.selectedKey = nil
        return true
    end
    return false
end

local function SaveOffsets()
    local function serialize_inline(v)
        local t = type(v)
        if t == "number" then return tostring(v) end
        if t == "boolean" then return v and "true" or "false" end
        if t == "string" then return string.format("%q", v) end
        if t ~= "table" then return "nil" end
        local parts = { "{ " }
        for k, vv in pairs(v) do
            local kk = (type(k) == "string") and string.format("[%q]", k) or "[" .. tostring(k) .. "]"
            table.insert(parts, kk .. " = " .. serialize_inline(vv) .. ", ")
        end
        table.insert(parts, "}" )
        return table.concat(parts, "")
    end

    local function serialize_list(list)
        if type(list) ~= "table" then return "{}" end
        local parts = { "{ " }
        for i = 1, #list do
            local v = list[i]
            local t = type(v)
            if t == "string" then
                table.insert(parts, string.format("%q, ", v))
            elseif t == "number" or t == "boolean" then
                table.insert(parts, tostring(v) .. ", ")
            else
                table.insert(parts, "nil, ")
            end
        end
        table.insert(parts, "}" )
        return table.concat(parts, "")
    end

    local function control_snapshot(ctrl)
        if not ctrl then return nil end
        return {
            name = ctrl.name,
            type = ctrl.type,
            x = ctrl.x, y = ctrl.y, w = ctrl.w, h = ctrl.h,
            rel = ctrl.rel,
            anim = ctrl.anim,
            text = ctrl.text,
            anchor = ctrl.anchor,
            gauge = ctrl.gauge,
            spellgem = ctrl.spellgem,
        }
    end

    local function screen_snapshot(screen)
        if not screen then return nil end
        return {
            x = screen.x, y = screen.y, w = screen.w, h = screen.h,
            rel = screen.rel,
            draw = screen.draw,
            text = screen.text,
            style = screen.style,
        }
    end

    local lines = { "return {" }
    table.insert(lines, "  offsets = {")
    for key, off in pairs(State.offsets or {}) do
        local x = math.floor(tonumber(off.x) or 0)
        local y = math.floor(tonumber(off.y) or 0)
        if x ~= 0 or y ~= 0 then
            table.insert(lines, string.format("    [%q] = { x = %d, y = %d },", key, x, y))
        end
    end
    table.insert(lines, "  },")
    table.insert(lines, "  visible = {")
    for _, name in ipairs(ScreenOrder) do
        local v = Visible[name] == true
        table.insert(lines, string.format("    [%q] = %s,", name, v and "true" or "false"))
    end
    table.insert(lines, "  },")
    table.insert(lines, "  priorities = {")
    for key, pr in pairs(State.priorities or {}) do
        local p = math.floor(tonumber(pr) or 0)
        if p ~= 0 then
            table.insert(lines, string.format("    [%q] = %d,", key, p))
        end
    end
    table.insert(lines, "  },")
    table.insert(lines, "  sizes = {")
    for key, sz in pairs(State.sizeOverrides or {}) do
        local w = tonumber(sz.w)
        local h = tonumber(sz.h)
        if w or h then
            table.insert(lines, string.format("    [%q] = { w = %s, h = %s },",
                key,
                w ~= nil and tostring(math.floor(w)) or "nil",
                h ~= nil and tostring(math.floor(h)) or "nil"))
        end
    end
    table.insert(lines, "  },")
    table.insert(lines, "  docking = {")
    for name, dock in pairs(State.docking or {}) do
        if dock and (dock.side ~= nil or dock.margin ~= nil) then
            local side = dock.side or "none"
            local margin = math.floor(tonumber(dock.margin) or 0)
            if side ~= "none" or margin ~= 0 then
                table.insert(lines, string.format("    [%q] = { side = %q, margin = %d },", name, side, margin))
            end
        end
    end
    table.insert(lines, "  },")
    table.insert(lines, "  -- Persist edited screen/control definitions (x/y/w/h/text/anim/etc)")
    table.insert(lines, "  screenEdits = {")
    for name in pairs(State.dirtyScreens or {}) do
        local screen = data.screens[name]
        local snap = screen_snapshot(screen)
        if snap then
            table.insert(lines, string.format("    [%q] = %s,", name, serialize_inline(snap)))
        end
    end
    table.insert(lines, "  },")
    table.insert(lines, "  screenPieces = {")
    for name in pairs(State.dirtyScreens or {}) do
        local screen = data.screens[name]
        if screen and type(screen.pieces) == "table" then
            table.insert(lines, string.format("    [%q] = %s,", name, serialize_list(screen.pieces)))
        end
    end
    table.insert(lines, "  },")
    table.insert(lines, "  controlEdits = {")
    for name in pairs(State.dirtyControls or {}) do
        local ctrl = data.controls[name]
        local snap = control_snapshot(ctrl)
        if snap then
            table.insert(lines, string.format("    [%q] = %s,", name, serialize_inline(snap)))
        end
    end
    table.insert(lines, "  },")
    table.insert(lines, "  childEdits = {")
    for key in pairs(State.dirtyChildren or {}) do
        local screenName, childName = tostring(key):match("^(.-)::(.-)$")
        local child = screenName and childName and FindChildByName(screenName, childName) or nil
        local snap = control_snapshot(child)
        if snap then
            table.insert(lines, string.format("    [%q] = %s,", key, serialize_inline(snap)))
        end
    end
    table.insert(lines, "  },")
    table.insert(lines, string.format("  showAll = %s,", State.showAll and "true" or "false"))
    table.insert(lines, string.format("  priorityGlobal = %s,", State.priorityGlobal and "true" or "false"))
    table.insert(lines, string.format("  drawCursorMirror = %s,", State.drawCursorMirror and "true" or "false"))
    table.insert(lines, string.format("  scaleOverride = %s,", tostring(State.scaleOverride or 0)))
    table.insert(lines, string.format("  fontScale = %s,", tostring(State.fontScale or 1.0)))
    table.insert(lines, string.format("  showBounds = %s,", State.showBounds and "true" or "false"))
    table.insert(lines, string.format("  showScreenNames = %s,", State.showScreenNames and "true" or "false"))
    table.insert(lines, string.format("  centerX = %s,", State.centerX and "true" or "false"))
    table.insert(lines, string.format("  showControls = %s,", State.showControls and "true" or "false"))
    table.insert(lines, string.format("  showFallback = %s,", State.showFallback and "true" or "false"))
    table.insert(lines, string.format("  editMode = %s,", State.editMode and "true" or "false"))
    table.insert(lines, string.format("  enableClicks = %s,", State.enableClicks and "true" or "false"))
    table.insert(lines, string.format("  dragScreens = %s,", State.dragScreens and "true" or "false"))
    table.insert(lines, string.format("  showPieceBounds = %s,", State.showPieceBounds and "true" or "false"))
    table.insert(lines, string.format("  showPieceList = %s,", State.showPieceList and "true" or "false"))
    table.insert(lines, string.format("  filterText = %q,", tostring(State.filterText or "")))
    table.insert(lines, string.format("  itemIconOffset = %s,", tostring(State.itemIconOffset or DEFAULT_ITEM_ICON_OFFSET)))
    table.insert(lines, string.format("  itemIconGrid = %s,", tostring(State.itemIconGrid or CLASSIC_ICON_GRID)))
    table.insert(lines, string.format("  itemIconSize = %s,", tostring(State.itemIconSize or CLASSIC_ICON_SIZE)))
    table.insert(lines, string.format("  itemIconOneBased = %s,", State.itemIconOneBased and "true" or "false"))
    table.insert(lines, string.format("  itemIconColumnMajor = %s,", State.itemIconColumnMajor and "true" or "false"))
    table.insert(lines, string.format("  buffTwoColumn = %s,", State.buffTwoColumn and "true" or "false"))
    table.insert(lines, string.format("  hotbuttonGroupByNumber = %s,", State.hotbuttonGroupByNumber and "true" or "false"))
    table.insert(lines, string.format("  buffIconScale = %s,", tostring(State.buffIconScale or 1.0)))
    table.insert(lines, string.format("  buffLabelScale = %s,", tostring(State.buffLabelScale or 1.0)))
    table.insert(lines, string.format("  spellGemIconScale = %s,", tostring(State.spellGemIconScale or 0.9)))
    table.insert(lines, string.format("  spellGemTintStrength = %s,", tostring(State.spellGemTintStrength or 2.0)))
    table.insert(lines, string.format("  spellGemCountOverride = %s,", tostring(State.spellGemCountOverride or 0)))
    table.insert(lines, string.format("  showBuffs = %s,", State.showBuffs and "true" or "false"))
    table.insert(lines, string.format("  showBuffTimers = %s,", State.showBuffTimers and "true" or "false"))
    table.insert(lines, string.format("  showBuffLabels = %s,", State.showBuffLabels and "true" or "false"))
    table.insert(lines, string.format("  invOpen = %s,", State.invOpen and "true" or "false"))
    table.insert(lines, "}")

    local f, err = io.open(OFFSETS_PATH, "w")
    if not f then
        print(string.format("\ay[EQ UI]\ax Failed to save offsets: %s", err or "unknown error"))
        return false
    end
    f:write(table.concat(lines, "\n"))
    f:close()
    print(string.format("\ay[EQ UI]\ax Offsets saved to %s", OFFSETS_PATH))
    return true
end

local function GetAnimUV(animName)
    if not animName or animName == '' then return nil end
    local anim = data.anims[animName]
    if not anim then return nil end
    local texName = anim.tex
    local texSize = data.textures[texName]
    if not texSize or texSize.w == 0 or texSize.h == 0 then return nil end

    return {
        tex = texName,
        u0 = anim.x / texSize.w,
        v0 = anim.y / texSize.h,
        u1 = (anim.x + anim.w) / texSize.w,
        v1 = (anim.y + anim.h) / texSize.h,
        srcW = anim.w,
        srcH = anim.h,
    }
end

local Trim
local GetMousePosSafe
local ItemCooldownSeconds
local LoadAbilitiesFromIni
local UpdateHotButtons
local UpdateSocialButtons
local SpellbookScanner
local function getSpellbookScanner()
    if SpellbookScanner == nil then
        local ok, mod = pcall(require, 'sidekick-next.utils.spellbook_scanner')
        if ok then SpellbookScanner = mod else SpellbookScanner = false end
    end
    return SpellbookScanner
end

local function Clamp01(v)
    if v < 0 then return 0 end
    if v > 1 then return 1 end
    return v
end

local function UpdateGaugeValues()
    local now = os.clock()
    if now - State.lastGaugeUpdate < 0.1 then return end
    State.lastGaugeUpdate = now

    local me = mq.TLO.Me
    local tgt = mq.TLO.Target
    local grp = mq.TLO.Group
    local inv = mq.TLO.InvSlot
    local win = mq.TLO.Window

    State.gaugeValues.player_hp = tonumber(me.PctHPs()) or 0
    State.gaugeValues.player_mana = tonumber(me.PctMana()) or 0
    State.gaugeValues.player_end = tonumber(me.PctEndurance()) or 0
    State.gaugeValues.player_xp = tonumber(me.PctExp()) or 0
    State.gaugeValues.player_aa = tonumber(me.PctAAExp()) or 0

    if tgt() ~= nil then
        State.gaugeValues.target_hp = tonumber(tgt.PctHPs()) or 0
    else
        State.gaugeValues.target_hp = 0
    end

    local pet = mq.TLO.Pet
    if pet() ~= nil then
        State.gaugeValues.pet_hp = tonumber(pet.PctHPs()) or 0
    else
        State.gaugeValues.pet_hp = 0
    end

    State.gaugeValues.group_hp = State.gaugeValues.group_hp or {}
    State.gaugeValues.group_pet = State.gaugeValues.group_pet or {}
    State.labelText = State.labelText or {}
    for i = 1, 5 do
        local mem = grp and grp.Member and grp.Member(i) or nil
        local name = ""
        local hpPct = 0
        local petPct = 0
        if mem and mem() ~= nil then
            local okName, n = pcall(function() return mem.Name() end)
            if okName then name = tostring(n or "") end
            local okHp, hp = pcall(function() return mem.PctHPs() end)
            if okHp then hpPct = tonumber(hp) or 0 end
            local okPet, petHp = pcall(function() return mem.Pet.PctHPs() end)
            if okPet then petPct = tonumber(petHp) or 0 end
        end
        State.gaugeValues.group_hp[i] = hpPct
        State.gaugeValues.group_pet[i] = petPct
        State.labelText["GW_HPLabel" .. i] = name
        State.labelText["GW_HPPercLabel" .. i] = string.format("%d%%", math.floor(hpPct + 0.5))
    end

    State.gaugeText.player_hp = string.format("%d / %d", tonumber(me.CurrentHPs()) or 0, tonumber(me.MaxHPs()) or 0)
    State.gaugeText.player_mana = string.format("%d / %d", tonumber(me.CurrentMana()) or 0, tonumber(me.MaxMana()) or 0)
    State.gaugeText.player_end = string.format("%d / %d", tonumber(me.CurrentEndurance()) or 0, tonumber(me.MaxEndurance()) or 0)
    State.gaugeText.player_xp = string.format("%d%%", math.floor(State.gaugeValues.player_xp + 0.5))
    State.gaugeText.player_aa = string.format("%d%%", math.floor(State.gaugeValues.player_aa + 0.5))
    State.gaugeText.target_hp = string.format("%d%%", math.floor(State.gaugeValues.target_hp + 0.5))

    local meName = tostring(me.Name() or "") or ""
    local meSurname = ""
    local okSurname, surname = pcall(function() return me.Surname() end)
    if okSurname then meSurname = tostring(surname or "") end
    if meSurname == "" then
        local okLast, last = pcall(function() return me.LastName() end)
        if okLast then meSurname = tostring(last or "") end
    end

    State.labelText.PW_Name = meName
    State.labelText.PW_Surname = meSurname
    State.labelText.PW_HPNumber = tostring(tonumber(me.CurrentHPs()) or 0)
    State.labelText.PW_HPPercent = string.format("%d%%", math.floor(State.gaugeValues.player_hp + 0.5))
    State.labelText.PW_ManaNumber = tostring(tonumber(me.CurrentMana()) or 0)
    State.labelText.PW_ManaPercent = string.format("%d%%", math.floor(State.gaugeValues.player_mana + 0.5))

    State.labelText.IW_Name = tostring(me.Name() or "") or ""
    State.labelText.IW_Level = tostring(tonumber(me.Level()) or 0)
    local okClass, className = pcall(function() return me.Class.ShortName() end)
    if not okClass or not className then
        okClass, className = pcall(function() return me.Class.Name() end)
    end
    State.labelText.IW_Class = okClass and tostring(className or "") or ""
    -- Store class ID for ClassAnime animation lookup
    local okClassId, classId = pcall(function() return me.Class.ID() end)
    State.classId = (okClassId and tonumber(classId)) or 1
    local okDeity, deityName = pcall(function() return me.Deity.Name() end)
    State.labelText.IW_Deity = okDeity and tostring(deityName or "") or ""
    State.labelText.IW_CurrentHP = tostring(tonumber(me.CurrentHPs()) or 0)
    State.labelText.IW_MaxHP = tostring(tonumber(me.MaxHPs()) or 0)
    State.labelText.IW_HPDivider = "/"

    local function win_child_text(windowName, childName)
        local ok, txt = pcall(function()
            local w = mq.TLO.Window(windowName)
            if not w or w() == nil then return "" end
            local c = w.Child and w.Child(childName) or nil
            if not c or c() == nil then return "" end
            if c.Text then return tostring(c.Text() or "") end
            return ""
        end)
        return ok and tostring(txt or "") or ""
    end

    local acMit = win_child_text("InventoryWindow", "IW_ACMitigation")
    local evasion = win_child_text("InventoryWindow", "IW_EVASION")
    if acMit ~= "" or evasion ~= "" then
        State.labelText.IW_ACNumber = string.format("%s/%s", acMit, evasion)
    else
        local okAC, ac = pcall(function() return me.AC() end)
        State.labelText.IW_ACNumber = tostring(tonumber(ac) or 0)
    end

    local offense = win_child_text("InventoryWindow", "IW_OFFENSE")
    local accuracy = win_child_text("InventoryWindow", "IW_ACCURACY")
    if offense ~= "" or accuracy ~= "" then
        State.labelText.IW_ATKNumber = string.format("%s / %s", offense, accuracy)
    else
        local okATK, atk = pcall(function() return me.ATK() end)
        State.labelText.IW_ATKNumber = tostring(tonumber(atk) or 0)
    end

    local function statVal(fn)
        local ok, v = pcall(fn)
        return tostring(tonumber(v) or 0)
    end
    State.heroicText = State.heroicText or {}
    State.labelText.IW_STRNumber = statVal(function() return me.STR() end)
    State.labelText.IW_STANumber = statVal(function() return me.STA() end)
    State.labelText.IW_AGINumber = statVal(function() return me.AGI() end)
    State.labelText.IW_DEXNumber = statVal(function() return me.DEX() end)
    State.labelText.IW_WISNumber = statVal(function() return me.WIS() end)
    State.labelText.IW_INTNumber = statVal(function() return me.INT() end)
    State.labelText.IW_CHANumber = statVal(function() return me.CHA() end)

    local function heroicVal(fn)
        local ok, v = pcall(fn)
        return ok and (tonumber(v) or 0) or 0
    end
    State.heroicText.IW_STRNumber = heroicVal(function() return me.HeroicSTRBonus() end)
    State.heroicText.IW_STANumber = heroicVal(function() return me.HeroicSTABonus() end)
    State.heroicText.IW_AGINumber = heroicVal(function() return me.HeroicAGIBonus() end)
    State.heroicText.IW_DEXNumber = heroicVal(function() return me.HeroicDEXBonus() end)
    State.heroicText.IW_WISNumber = heroicVal(function() return me.HeroicWISBonus() end)
    State.heroicText.IW_INTNumber = heroicVal(function() return me.HeroicINTBonus() end)
    State.heroicText.IW_CHANumber = heroicVal(function() return me.HeroicCHABonus() end)

    State.labelText.IW_PoisonNumber = statVal(function() return me.svPoison() end)
    State.labelText.IW_MagicNumber = statVal(function() return me.svMagic() end)
    State.labelText.IW_DiseaseNumber = statVal(function() return me.svDisease() end)
    State.labelText.IW_FireNumber = statVal(function() return me.svFire() end)
    State.labelText.IW_ColdNumber = statVal(function() return me.svCold() end)

    State.labelText.IW_CurrentWeight = statVal(function() return me.CurrentWeight() end)
    State.labelText.IW_WeightNumber = State.labelText.IW_CurrentWeight
    State.labelText.IW_MaxWeight = statVal(function() return me.MaxWeight() end)

    State.labelText.IW_ExpPct = string.format("%d%%", math.floor(State.gaugeValues.player_xp + 0.5))
    State.labelText.IW_AAExpPct = string.format("%d%%", math.floor(State.gaugeValues.player_aa + 0.5))
    State.labelText.IW_ExpNumber = State.labelText.IW_ExpPct
    State.labelText.IW_AAExpNumber = State.labelText.IW_AAExpPct
    State.labelText.IW_AltAdv = tostring(tonumber(me.AAPoints() or 0) or 0)
    State.labelText.IW_Money0 = statVal(function() return me.Platinum() end)
    State.labelText.IW_Money1 = statVal(function() return me.Gold() end)
    State.labelText.IW_Money2 = statVal(function() return me.Silver() end)
    State.labelText.IW_Money3 = statVal(function() return me.Copper() end)

    local tgtName = ""
    if tgt() ~= nil then
        local okTn, tn = pcall(function() return tgt.CleanName() end)
        if okTn then tgtName = tostring(tn or "") end
        if tgtName == "" then
            local okTn2, tn2 = pcall(function() return tgt.Name() end)
            if okTn2 then tgtName = tostring(tn2 or "") end
        end
    end
    State.labelText.TW_TargetName = tgtName

    -- Target's Target
    local tot = nil
    local okTot, totVal = pcall(function() return mq.TLO.TargetOfTarget end)
    if okTot and totVal and totVal() ~= nil then
        tot = totVal
    else
        local okAlt, alt = pcall(function()
            return mq.TLO.Target and mq.TLO.Target.TargetOfTarget
        end)
        if okAlt and alt and alt() ~= nil then
            tot = alt
        else
            local okAlt2, alt2 = pcall(function()
                return mq.TLO.Target and mq.TLO.Target.Target
            end)
            if okAlt2 and alt2 and alt2() ~= nil then
                tot = alt2
            end
        end
    end
    local totName = ""
    local totHp = 0
    if tot and tot() ~= nil then
        local okName, tn = pcall(function() return tot.CleanName() end)
        if okName then totName = tostring(tn or "") end
        if totName == "" then
            local okName2, tn2 = pcall(function() return tot.Name() end)
            if okName2 then totName = tostring(tn2 or "") end
        end
        local okHp, hp = pcall(function() return tot.PctHPs() end)
        if okHp then totHp = tonumber(hp) or 0 end
    end
    State.gaugeValues.target_target_hp = totHp or 0
    State.gaugeText.target_target_hp = (totHp and totHp > 0) and string.format("%d%%", math.floor(totHp + 0.5)) or "0%"
    State.labelText.TargetOfTarget_HPLabel = totName
    State.labelText.TargetOfTarget_HPPercLabel = (totHp and totHp > 0)
        and string.format("%d%%", math.floor(totHp + 0.5)) or ""

    local castingName = ""
    local castActive = false
    local okCastName, castVal = pcall(function() return me.Casting() end)
    if okCastName and castVal then
        castingName = tostring(castVal or "")
        if castingName ~= "" then
            castActive = true
        end
    end
    local castPct = 0
    local castLeftMs = 0
    if castActive then
        local totalMs = 0
        local okSpell, spell = pcall(function() return mq.TLO.Spell(castingName) end)
        if okSpell and spell and spell() and spell.MyCastTime then
            local okCT, ct = pcall(function() return spell.MyCastTime() end)
            if okCT then totalMs = tonumber(ct) or 0 end
        end
        local okLeft, left = pcall(function() return me.CastTimeLeft() end)
        local leftMs = okLeft and (tonumber(left) or 0) or 0
        castLeftMs = leftMs
        if totalMs > 0 then
            castPct = Clamp01(1.0 - (leftMs / totalMs)) * 100.0
        else
            castPct = 0
        end
    end
    State.cast.active = castActive
    State.cast.name = castingName
    State.cast.pct = castPct
    State.cast.leftMs = castLeftMs
    State.labelText.CSTW_Label = castingName ~= "" and castingName or "Casting..."

    local castWndOpen = false
    local okCastWnd, cw = pcall(function() return mq.TLO.Window('CastingWindow') end)
    if okCastWnd and cw and cw() ~= nil then
        local okOpen, v = pcall(function() return cw.Open() end)
        if okOpen then castWndOpen = v == true end
    end
    State.castWindowOpen = castWndOpen

    local sbOpen = false
    local okVal, v = pcall(function() return mq.TLO.Window('SpellBookWnd').Open() end)
    if okVal then sbOpen = v == true end
    State.spellbookOpen = sbOpen

    if not State.editMode then
        local openInv = false
        local okInv, w = pcall(function() return win("InventoryWindow") end)
        if okInv and w and w() ~= nil then
            local okOpen, o = pcall(function() return w.Open() end)
            if okOpen then openInv = o == true end
        end
        State.invOpen = openInv
        if State.lastInvOpen == nil then
            State.lastInvOpen = openInv
        elseif State.lastInvOpen ~= openInv then
            State.lastInvOpen = openInv
            State.pendingAbBuff = true
        end
        if openInv then
            Visible["InventoryWindow"] = true
        end
    end

    local grouped = false
    local standing = true
    local pendingInvite = false
    local abilityNames = {}
    local abilityIds = {}
    local combatAbilityNames = {}
    local combatAbilityCooldown = {}
    local abilityCooldown = {}
    local okGrouped, gv = pcall(function() return mq.TLO.Me.Grouped() end)
    if okGrouped then grouped = gv == true end
    local okStand, sv = pcall(function() return mq.TLO.Me.Standing() end)
    if okStand then standing = sv == true end
    local okGI, gi = pcall(function() return mq.TLO.Me.GroupInvited() end)
    if okGI and gi == true then pendingInvite = true end
    if not pendingInvite then
        local okInv, inv = pcall(function() return mq.TLO.Me.Invited() end)
        if okInv and inv == true then pendingInvite = true end
    end
    if not pendingInvite then
        local okGInv, ginv = pcall(function() return mq.TLO.Me.GroupInvite() end)
        if okGInv and ginv == true then pendingInvite = true end
    end
    State.actionsState = State.actionsState or {}
    State.actionsState.grouped = grouped
    State.actionsState.standing = standing
    State.actionsState.pendingInvite = pendingInvite

    abilityIds, abilityNames = LoadAbilitiesFromIni(now)
    State.actionsState.abilityIds = abilityIds
    State.actionsState.abilityNames = abilityNames
    State.actionsState.combatAbilityNames = combatAbilityNames
    State.actionsState.combatAbilityCooldown = combatAbilityCooldown
    State.actionsState.abilityCooldown = abilityCooldown

    local abilityButtonNames = {
        "AAP_FirstAbilityButton",
        "AAP_SecondAbilityButton",
        "AAP_ThirdAbilityButton",
        "AAP_FourthAbilityButton",
        "AAP_FifthAbilityButton",
        "AAP_SixthAbilityButton",
    }
    for i = 1, 6 do
        local nm = abilityNames[i] or ""
        if nm ~= "" then
            State.labelText[abilityButtonNames[i]] = nm
        else
            State.labelText[abilityButtonNames[i]] = nil
        end
        local cd = 0
        if nm ~= "" then
            local okCd, vcd = pcall(function() return mq.TLO.Me.CombatAbilityTimer(nm) end)
            if okCd and vcd ~= nil then cd = tonumber(vcd) or 0 end
        end
        abilityCooldown[i] = cd
    end

    local combatButtonNames = {
        "ACP_FirstAbilityButton",
        "ACP_SecondAbilityButton",
        "ACP_ThirdAbilityButton",
        "ACP_FourthAbilityButton",
    }
    for i = 1, 4 do
        local nm = ""
        local ok, ab = pcall(function() return mq.TLO.Me.CombatAbility(i) end)
        if ok and ab and ab() ~= nil then
            local okName, cn = pcall(function() return ab.Name() end)
            if okName and cn ~= nil then nm = Trim(cn) end
        end
        combatAbilityNames[i] = nm
        if nm ~= "" then
            State.labelText[combatButtonNames[i]] = nm
        else
            State.labelText[combatButtonNames[i]] = nil
        end
        local cd = 0
        if nm ~= "" then
            local okCd, vcd = pcall(function() return mq.TLO.Me.CombatAbilityTimer(nm) end)
            if okCd and vcd ~= nil then cd = tonumber(vcd) or 0 end
        end
        combatAbilityCooldown[i] = cd
    end

    UpdateHotButtons(now)
    UpdateSocialButtons(now)

    State.buffIcons = State.buffIcons or {}
    State.buffRemaining = State.buffRemaining or {}
    State.shortBuffIcons = State.shortBuffIcons or {}
    State.shortBuffRemaining = State.shortBuffRemaining or {}
    State.shortBuffNames = State.shortBuffNames or {}
    for i = 1, 15 do
        local buffName = ""
        local buffIcon = 0
        local remaining = 0
        if State.showBuffs or State.showBuffLabels or State.showBuffTimers then
            local okBuff, buff = pcall(function() return me.Buff(i) end)
            if okBuff and buff and buff() ~= nil then
                local okName, bn = pcall(function() return buff.Name() end)
                if okName then buffName = tostring(bn or "") end
                if State.showBuffs then
                    local okIcon, bi = pcall(function() return buff.SpellIcon() end)
                    if okIcon then buffIcon = tonumber(bi) or 0 end
                end
                if State.showBuffTimers then
                    local okDur, dur = pcall(function() return buff.Duration() end)
                    if okDur and dur ~= nil then
                        remaining = tonumber(dur) or 0
                    else
                        local okLeft, left = pcall(function() return buff.Duration.TotalSeconds() end)
                        if okLeft then remaining = tonumber(left) or 0 end
                    end
                end
            end
        end
        State.buffIcons[i] = buffIcon
        State.buffRemaining[i] = remaining
        State.labelText["BW_Label" .. tostring(i - 1)] = State.showBuffLabels and buffName or ""
    end

    for i = 1, 6 do
        local buffName = ""
        local buffIcon = 0
        local remaining = 0
        if State.showBuffs or State.showBuffLabels or State.showBuffTimers then
            local okBuff, buff = pcall(function()
                if me.Song then return me.Song(i) end
                return nil
            end)
            if okBuff and buff and buff() ~= nil then
                local okName, bn = pcall(function() return buff.Name() end)
                if okName then buffName = tostring(bn or "") end
                if State.showBuffs then
                    local okIcon, bi = pcall(function() return buff.SpellIcon() end)
                    if okIcon then buffIcon = tonumber(bi) or 0 end
                end
                if State.showBuffTimers then
                    local okDur, dur = pcall(function() return buff.Duration() end)
                    if okDur and dur ~= nil then
                        remaining = tonumber(dur) or 0
                    else
                        local okLeft, left = pcall(function() return buff.Duration.TotalSeconds() end)
                        if okLeft then remaining = tonumber(left) or 0 end
                    end
                end
            end
        end
        if State.showBuffs and buffIcon == 0 and buffName ~= "" then
            local sp = mq.TLO.Spell(buffName)
            if sp and sp() ~= nil then
                local okIcon, bi = pcall(function() return sp.SpellIcon() end)
                if okIcon then buffIcon = tonumber(bi) or 0 end
            end
        end
        State.shortBuffNames[i] = State.showBuffLabels and buffName or ""
        State.shortBuffIcons[i] = buffIcon
        State.shortBuffRemaining[i] = remaining
    end

    local gemCount = 12
    local okGems, numGems = pcall(function() return tonumber(me.NumGems()) end)
    if okGems and numGems and numGems > 0 then
        gemCount = math.max(gemCount, numGems)
    end
    local override = tonumber(State.spellGemCountOverride) or 0
    if override > 0 then
        gemCount = override
    end
    State.numGems = gemCount
    State.spellIcons = State.spellIcons or {}
    State.spellGemIcons = State.spellGemIcons or {}
    State.spellNames = State.spellNames or {}
    State.spellTargetType = State.spellTargetType or {}
    State.spellCooldown = State.spellCooldown or {}
    State.spellReady = State.spellReady or {}
    State.spellCooldownEnd = State.spellCooldownEnd or {}
    State.spellCooldownRemaining = State.spellCooldownRemaining or {}
    State.spellReadyPrev = State.spellReadyPrev or {}
    for i = 1, gemCount do
        local icon = 0
        local gemIcon = 0
        local sp = me.Gem(i)
        local spellName = ""
        local targetType = ""
        if sp and sp() then
            local okIcon, iconVal = pcall(function() return sp.SpellIcon end)
            if okIcon and iconVal ~= nil then
                if type(iconVal) == "function" then
                    local okCall, v = pcall(iconVal)
                    if okCall then iconVal = v end
                end
                icon = tonumber(iconVal) or tonumber(tostring(iconVal)) or 0
            else
                local okCall, v = pcall(function() return sp.SpellIcon() end)
                if okCall and v ~= nil then
                    icon = tonumber(v) or tonumber(tostring(v)) or 0
                end
            end
            if sp.GemIcon then
                local okGem, gemVal = pcall(function() return sp.GemIcon end)
                if okGem and gemVal ~= nil then
                    if type(gemVal) == "function" then
                        local okCall, v = pcall(gemVal)
                        if okCall then gemVal = v end
                    end
                    gemIcon = tonumber(gemVal) or tonumber(tostring(gemVal)) or 0
                else
                    local okCall, v = pcall(function() return sp.GemIcon() end)
                    if okCall and v ~= nil then
                        gemIcon = tonumber(v) or tonumber(tostring(v)) or 0
                    end
                end
            end
            local okName, nameVal = pcall(function() return sp.Name end)
            if okName and nameVal ~= nil then
                if type(nameVal) == "function" then
                    local okCall, v = pcall(nameVal)
                    if okCall then nameVal = v end
                end
                spellName = Trim(tostring(nameVal))
            else
                local okCall, v = pcall(function() return sp.Name() end)
                if okCall and v ~= nil then
                    spellName = Trim(tostring(v))
                end
            end

            local okCall, v = pcall(function() return sp.TargetType() end)
            if okCall and v ~= nil then
                targetType = tostring(v)
            else
                local okTT, ttVal = pcall(function() return sp.TargetType end)
                if okTT and ttVal ~= nil then
                    if type(ttVal) == "function" then
                        local okCall2, v2 = pcall(ttVal)
                        if okCall2 then ttVal = v2 end
                    end
                    targetType = tostring(ttVal or "")
                end
            end
        end
        State.spellIcons[i] = icon
        if gemIcon and gemIcon > 0 then
            State.spellGemIcons[i] = gemIcon
        else
            State.spellGemIcons[i] = icon
        end
        State.spellNames[i] = spellName
        State.spellTargetType[i] = targetType
        State._spellGemMissingDebugOnce = State._spellGemMissingDebugOnce or {}
        if spellName ~= "" and (State.spellGemIcons[i] or 0) <= 0 and not State._spellGemMissingDebugOnce[i] then
            State._spellGemMissingDebugOnce[i] = true
            print(string.format("[EQ UI] SpellGem %d missing icon. Spell=%s SpellIcon=%s GemIcon=%s",
                i,
                spellName,
                tostring(icon),
                tostring(gemIcon)))
        end
        local okReady, ready = pcall(function() return me.SpellReady(i) end)
        if okReady and ready ~= nil then
            State.spellReady[i] = ready == true
        else
            State.spellReady[i] = true
        end
        local okTimer, timer = pcall(function() return me.GemTimer(i) end)
        local t = okTimer and timer or nil
        local rem = 0
        if t ~= nil then
            local okTs, ts = pcall(function() return t.TotalSeconds() end)
            if okTs and ts ~= nil then
                rem = tonumber(ts) or 0
            else
                rem = tonumber(t) or 0
                if rem > 1000 then rem = rem / 1000 end
            end
        end
        State.spellCooldown[i] = rem

        local prevReady = State.spellReadyPrev[i]
        local now = os.clock()
        if prevReady == nil then prevReady = State.spellReady[i] end
        if prevReady == true and State.spellReady[i] == false then
            local recast = 0
            if spellName ~= "" then
                local okRec, rv = pcall(function() return mq.TLO.Me.Spell(spellName).RecastTime() end)
                if okRec and rv ~= nil then recast = tonumber(rv) or 0 end
            end
            if recast > 1000 then recast = recast / 1000 end
            State.spellCooldownEnd[i] = now + recast
        elseif State.spellReady[i] == true then
            State.spellCooldownEnd[i] = 0
        end
        State.spellReadyPrev[i] = State.spellReady[i]
        local endt = State.spellCooldownEnd[i] or 0
        if endt > 0 then
            State.spellCooldownRemaining[i] = math.max(0, endt - now)
        else
            State.spellCooldownRemaining[i] = 0
        end
    end

    -- Item cooldowns (inventory + hotbuttons share the same map)
    State.itemCooldown = State.itemCooldown or {}
    State.invItemCooldown = State.invItemCooldown or {}
    State.invItemName = State.invItemName or {}
    for k in pairs(State.itemCooldown) do State.itemCooldown[k] = nil end

    for slotIdx = 0, 30 do
        local slot = mq.TLO.InvSlot(slotIdx)
        local name = ""
        if slot and slot() ~= nil then
            local it = slot.Item
            if it and it() ~= nil then
                local okName, iname = pcall(function() return it.Name() end)
                if okName and iname ~= nil then name = Trim(iname) end
            end
        end
        local rem = 0
        if name ~= "" then
            rem = ItemCooldownSeconds(name)
            local key = name:lower()
            local existing = State.itemCooldown[key] or 0
            if rem > existing then State.itemCooldown[key] = rem end
        end
        State.invItemName[slotIdx] = name
        State.invItemCooldown[slotIdx] = rem
    end
end

local function EQTypeValue(eqtype)
    if eqtype == 1 then return State.gaugeValues.player_hp end
    if eqtype == 2 then return State.gaugeValues.player_mana end
    if eqtype == 3 then return State.gaugeValues.player_end end
    if eqtype == 4 then return State.gaugeValues.player_xp end
    if eqtype == 5 then return State.gaugeValues.player_aa end
    if eqtype == 6 then return State.gaugeValues.target_hp end
    if eqtype == 27 then return State.gaugeValues.target_target_hp or 0 end
    if eqtype == 16 then return State.gaugeValues.pet_hp end
    if eqtype >= 11 and eqtype <= 15 then
        local idx = eqtype - 10
        return (State.gaugeValues.group_hp and State.gaugeValues.group_hp[idx]) or 0
    end
    if eqtype >= 17 and eqtype <= 21 then
        local idx = eqtype - 16
        return (State.gaugeValues.group_pet and State.gaugeValues.group_pet[idx]) or 0
    end
    if eqtype == 7 then return State.cast and State.cast.pct or 0 end
    return 0
end

local function GaugeValueByName(name)
    if name == "IW_ExpGauge" then return State.gaugeValues.player_xp or 0 end
    if name == "IW_AltAdvGauge" then return State.gaugeValues.player_aa or 0 end
    return 0
end

local function EQTypeText(eqtype)
    if eqtype == 1 then return State.gaugeText.player_hp end
    if eqtype == 2 then return State.gaugeText.player_mana end
    if eqtype == 3 then return State.gaugeText.player_end end
    if eqtype == 4 then return State.gaugeText.player_xp end
    if eqtype == 5 then return State.gaugeText.player_aa end
    if eqtype == 6 then return State.gaugeText.target_hp end
    if eqtype == 27 then return State.gaugeText.target_target_hp end
    return nil
end

local function MatchFilter(name, filter)
    if not filter or filter == '' then return true end
    return name:lower():find(filter:lower(), 1, true) ~= nil
end

local function CollectAnimRefsFromTable(tbl, used)
    if type(tbl) ~= "table" then return end
    for _, v in pairs(tbl) do
        if type(v) == "string" then
            if data.anims and data.anims[v] then
                used[v] = true
            end
        elseif type(v) == "table" then
            CollectAnimRefsFromTable(v, used)
        end
    end
end

local function BuildUnusedAssetsByTexture()
    local used = {}
    CollectAnimRefsFromTable(data.controls, used)
    CollectAnimRefsFromTable(data.templates, used)
    CollectAnimRefsFromTable(data.screens, used)

    local byTex = {}
    local totalUnused = 0
    for animName, anim in pairs(data.anims or {}) do
        if not used[animName] then
            local tex = anim and anim.tex or "unknown"
            byTex[tex] = byTex[tex] or {}
            table.insert(byTex[tex], animName)
            totalUnused = totalUnused + 1
        end
    end

    local texList = {}
    for tex, list in pairs(byTex) do
        table.sort(list)
        table.insert(texList, tex)
    end
    table.sort(texList)

    return byTex, texList, totalUnused
end

local function BuildUnusedPiecesList()
    local used = {}
    for screenName, screen in pairs(data.screens or {}) do
        local pieces = screen.pieces or {}
        for i = 1, #pieces do
            used[pieces[i]] = true
        end
        local children = screen.children or {}
        for i = 1, #children do
            local child = children[i]
            if child and child.name then
                used[child.name] = true
            end
        end
    end

    local list = {}
    for name in pairs(data.controls or {}) do
        if not used[name] then
            table.insert(list, name)
        end
    end
    table.sort(list)
    return list, #list
end

local function BuildUnusedTexturesList()
    local used = {}
    for _, anim in pairs(data.anims or {}) do
        if anim and anim.tex then
            used[anim.tex] = true
        end
    end
    for _, tpl in pairs(data.templates or {}) do
        if tpl and tpl.background then
            used[tpl.background] = true
        end
    end
    -- Textures referenced directly in code (not through anims/templates)
    for i = 1, CLASSIC_ITEM_ICON_SHEETS do
        used[string.format("dragitem%d.tga", i)] = true
    end
    for i = 1, CLASSIC_ICON_SHEETS do
        used[string.format("spells%02d.tga", i)] = true
        used[string.format("spells%02d_gem.tga", i)] = true
    end

    local list = {}
    for texName in pairs(data.textures or {}) do
        if not used[texName] then
            table.insert(list, texName)
        end
    end
    table.sort(list)
    return list, #list
end

Trim = function(s)
    return (tostring(s or ""):gsub("^%s*(.-)%s*$", "%1"))
end

ItemCooldownSeconds = function(name)
    if not name or name == "" then return 0 end
    local item = mq.TLO.FindItem(name)
    if not item or item() == nil then return 0 end
    local remain = 0
    if item.Timer and item.Timer.TotalSeconds then
        local okT, ts = pcall(function() return item.Timer.TotalSeconds() end)
        if okT and ts ~= nil then remain = tonumber(ts) or 0 end
    end
    if remain <= 0 and item.TimerReady then
        local okR, raw = pcall(function() return item.TimerReady() end)
        local ticks = (okR and tonumber(raw)) or 0
        if ticks and ticks > 0 then
            remain = ticks * 6
        end
    end
    return tonumber(remain) or 0
end

LoadAbilitiesFromIni = function(now)
    State.actionsState = State.actionsState or {}
    local cache = State.actionsState
    cache.abilityIds = cache.abilityIds or { -1, -1, -1, -1, -1, -1 }
    cache.abilityNames = cache.abilityNames or { "", "", "", "", "", "" }

    if cache.lastAbilityLoad and (now - cache.lastAbilityLoad) < 1.0 then
        return cache.abilityIds, cache.abilityNames
    end
    cache.lastAbilityLoad = now

    local eqPath = mq.TLO.EverQuest.Path()
    local eqPathStr = ""
    if type(eqPath) == "function" then
        eqPathStr = eqPath() or ""
    else
        eqPathStr = tostring(eqPath or "")
    end
    if eqPathStr == "" then
        return cache.abilityIds, cache.abilityNames
    end

    local me = mq.TLO.Me
    local name = ""
    local okName, nm = pcall(function() return me.Name() end)
    if okName and nm ~= nil then name = Trim(nm) end
    local server = ""
    local okServer, sv = pcall(function() return me.Server() end)
    if okServer and sv ~= nil then
        server = Trim(sv)
    else
        local okEqServer, esv = pcall(function() return mq.TLO.EverQuest.Server() end)
        if okEqServer and esv ~= nil then server = Trim(esv) end
    end
    local classShort = ""
    local okClass, cs = pcall(function() return me.Class.ShortName() end)
    if okClass and cs ~= nil then classShort = Trim(cs) end

    if name == "" or classShort == "" then
        return cache.abilityIds, cache.abilityNames
    end

    local path = ""
    if server ~= "" then
        path = string.format("%s\\%s_%s_%s.ini", eqPathStr, name, server, classShort)
    else
        path = string.format("%s\\%s_%s.ini", eqPathStr, name, classShort)
    end
    local f = io.open(path, "r")
    if not f then
        return cache.abilityIds, cache.abilityNames
    end

    local ids = { -1, -1, -1, -1, -1, -1 }
    local inAbilities = false
    for line in f:lines() do
        local ln = Trim(line)
        if ln:match("^%[") then
            inAbilities = ln:lower() == "[abilities]"
        elseif inAbilities then
            local key, val = ln:match("^(Ability%d+)%s*=%s*(%-?%d+)")
            if key and val then
                local idx = tonumber(key:match("%d+"))
                if idx and idx >= 1 and idx <= 6 then
                    ids[idx] = tonumber(val) or -1
                end
            end
        end
    end
    f:close()

    cache.abilityIds = ids
    for i = 1, 6 do
        local nm = ""
        if ids[i] and ids[i] >= 0 then
            local skillId = ids[i] + 1
            local okName, sn = pcall(function() return mq.TLO.Skill(skillId).Name() end)
            if okName and sn ~= nil then
                nm = Trim(sn)
            end
        end
        cache.abilityNames[i] = nm
    end

    return cache.abilityIds, cache.abilityNames
end

UpdateHotButtons = function(now)
    State.hotbuttonsPages = State.hotbuttonsPages or {}
    State.hotbuttonPage = State.hotbuttonPage or 1
    if State.debugHotbuttons == nil then State.debugHotbuttons = false end
    State.hotbuttonsDebugLast = State.hotbuttonsDebugLast or {}
    local textOnlyTypes = {
        CombatAbility = true,
        MeleeAbility = true,
        Skill = true,
        CombatSkill = true,
        Ability = true,
        Command = true,
        Social = true,
        LeadershipAbility = true,
    }

    if State.lastHotbuttonUpdate and (now - State.lastHotbuttonUpdate) < 0.25 then
        return
    end
    State.lastHotbuttonUpdate = now

    local win = mq.TLO.Window('HotButtonWnd')
    if win and win() ~= nil then
        local lbl = win.Child and win.Child("HB_CurrentPageLabel") or nil
        if lbl and lbl() ~= nil then
            local okText, txt = pcall(function() return lbl.Text() end)
            if okText and txt ~= nil then
                local raw = Trim(txt)
                local pageNum = tonumber(raw) or tonumber(raw:match("(%d+)"))
                if pageNum then
                    State.hotbuttonPage = pageNum
                end
            end
        end
    elseif State.debugHotbuttons then
        print("\ay[EQ UI]\ax HotButtonWnd not available")
    end
    -- Always show a page number even if the in-game label is blank/non-numeric.
    State.labelText["HB_CurrentPageLabel"] = tostring(State.hotbuttonPage or 1)

    local page = State.hotbuttonPage or 1
    State.hotbuttonsPages[page] = State.hotbuttonsPages[page] or {}
    local pageButtons = State.hotbuttonsPages[page]

    for i = 1, 12 do
        local info = pageButtons[i] or {}
        info.name = ""
        info.iconId = 0
        info.iconType = ""
        info.type = 0
        info.slot = -1

        local hbPath = string.format("HotButtonWnd/HB_Button%d", i)
        local hb = nil
        local okHB, hbv = pcall(function() return mq.TLO.Window(hbPath).HotButton end)
        if okHB then hb = hbv end

        if hb and hb() ~= nil then
            local okLabel, lbl = pcall(function() return hb.Label() end)
            if okLabel and lbl ~= nil then
                info.name = Trim(lbl)
                if State.debugHotbuttons then
                    print(string.format("\ay[EQ UI]\ax HB_Button%d label='%s'", i, info.name))
                end
            end
            local okType, tp = pcall(function() return hb.IconType() end)
            if okType and tp ~= nil then
                local tpn = tonumber(tp) or -1
                info.iconType = (tpn == 0 and "item") or (tpn == 1 and "spell") or (tpn == 2 and "menu") or ""
            end
            local okIcon, ic = pcall(function() return hb.IconSlot() end)
            if okIcon and ic ~= nil then
                info.iconId = tonumber(ic) or 0
            end
            local okHType, htp = pcall(function() return hb.Type() end)
            if okHType and htp ~= nil then info.type = tonumber(htp) or 0 end
            local okTypeName, tname = pcall(function() return hb.TypeName() end)
            if okTypeName and tname ~= nil then info.typeName = Trim(tname) end
            local okSlot, sl = pcall(function() return hb.Slot() end)
            if okSlot and sl ~= nil then info.slot = tonumber(sl) or -1 end

            local okSpell, sp = pcall(function() return hb.Spell() end)
            local okItemName, iname = pcall(function() return hb.ItemName() end)
            if info.iconType == "spell" and okSpell and sp ~= nil then
                info.name = Trim(sp)
            elseif info.iconType == "item" and okItemName and iname ~= nil then
                info.name = Trim(iname)
            elseif info.name == "" then
                if okSpell and sp ~= nil then info.name = Trim(sp) end
                if info.name == "" and okItemName and iname ~= nil then info.name = Trim(iname) end
            end
        elseif State.debugHotbuttons then
            print(string.format("\ay[EQ UI]\ax HB_Button%d HotButton not available", i))
        end

        if info.name == "" and win and win() ~= nil then
            local btn = win.Child and win.Child("HB_Button" .. tostring(i)) or nil
            if btn and btn() ~= nil then
                local okTip, tip = pcall(function() return btn.Tooltip() end)
                if okTip and tip ~= nil and Trim(tip) ~= "" then
                    info.name = Trim(tip)
                    if State.debugHotbuttons then
                        print(string.format("\ay[EQ UI]\ax HB_Button%d tooltip='%s'", i, info.name))
                    end
                else
                    local okText, txt = pcall(function() return btn.Text() end)
                    if okText and txt ~= nil then
                        info.name = Trim(txt)
                        if State.debugHotbuttons then
                            print(string.format("\ay[EQ UI]\ax HB_Button%d text='%s'", i, info.name))
                        end
                    end
                end
            elseif State.debugHotbuttons then
                print(string.format("\ay[EQ UI]\ax HB_Button%d window child missing", i))
            end
        end

        info.cooldown = false
        info.cooldownRem = 0
        info.cooldownTotal = 0
        local textOnly = info.typeName and textOnlyTypes[info.typeName] == true
        if info.name ~= "" and not textOnly then
            if info.iconType == "spell" then
                if info.iconId == 0 then
                    local sp = mq.TLO.Spell(info.name)
                    if sp and sp() ~= nil then
                        local okIc, sic = pcall(function() return sp.SpellIcon() end)
                        if okIc then info.iconId = tonumber(sic) or 0 end
                    end
                end
                local okReady, ready = pcall(function() return mq.TLO.Me.SpellReady(info.name) end)
                if okReady and ready ~= nil then info.cooldown = not (ready == true) end
            elseif info.iconType == "item" then
                if info.iconId == 0 then
                    local it = mq.TLO.FindItem(info.name)
                    if it and it() ~= nil then
                        local okIc, iic = pcall(function() return it.Icon() end)
                        if okIc then info.iconId = tonumber(iic) or 0 end
                    end
                end
                local key = info.name:lower()
                local rem = (State.itemCooldown and State.itemCooldown[key]) or 0
                info.cooldown = rem > 0
            else
                -- Fallback: try to resolve by name
                local sp = mq.TLO.Spell(info.name)
                if sp and sp() ~= nil then
                    local okIc, sic = pcall(function() return sp.SpellIcon() end)
                    if okIc then
                        info.iconId = tonumber(sic) or 0
                        info.iconType = "spell"
                    end
                end
                if info.iconId == 0 then
                    local it = mq.TLO.FindItem(info.name)
                    if it and it() ~= nil then
                        local okIc, iic = pcall(function() return it.Icon() end)
                        if okIc then
                            info.iconId = tonumber(iic) or 0
                            info.iconType = "item"
                        end
                    end
                end
                if info.iconType == "spell" then
                    local okReady, ready = pcall(function() return mq.TLO.Me.SpellReady(info.name) end)
                    if okReady and ready ~= nil then info.cooldown = not (ready == true) end
                elseif info.iconType == "item" then
                    local key = info.name:lower()
                    local rem = (State.itemCooldown and State.itemCooldown[key]) or 0
                    info.cooldown = rem > 0
                end
            end
        end
        if info.name ~= "" and Cooldowns and Cooldowns.probe then
            local rem, total = Cooldowns.probe({ label = info.name, key = info.name })
            info.cooldownRem = tonumber(rem) or 0
            info.cooldownTotal = tonumber(total) or 0
            if info.cooldownRem > 0 then
                info.cooldown = true
            end
        end

        if textOnly then
            info.iconType = ""
            info.iconId = 0
        else
            -- If the label isn't a real spell/item, suppress stale icons.
            if info.iconType == "spell" then
                local sp = mq.TLO.Spell(info.name)
                if not (sp and sp() ~= nil) then
                    info.iconType = ""
                    info.iconId = 0
                end
            elseif info.iconType == "item" then
                local it = mq.TLO.FindItem(info.name)
                if not (it and it() ~= nil) then
                    info.iconType = ""
                    info.iconId = 0
                end
            else
                info.iconId = 0
            end
        end

        pageButtons[i] = info
        if info.name ~= "" then
            State.labelText["HB_Button" .. tostring(i)] = info.name
        else
            State.labelText["HB_Button" .. tostring(i)] = nil
        end

        if State.debugHotbuttons then
            local key = tostring(i)
            local cur = string.format("name='%s' icon=%d type=%s", info.name or "", info.iconId or 0, info.iconType or "")
            if State.hotbuttonsDebugLast[key] ~= cur then
                State.hotbuttonsDebugLast[key] = cur
                print(string.format("\ay[EQ UI]\ax HB_Button%d -> %s", i, cur))
            end
        end
    end

    -- Convenience: point State.hotbuttons at current page snapshot for drawing.
    State.hotbuttons = pageButtons
end

UpdateSocialButtons = function(now)
    State.socials = State.socials or {}
    State.socialPage = State.socialPage or 1

    if State.lastSocialUpdate and (now - State.lastSocialUpdate) < 0.25 then
        return
    end
    State.lastSocialUpdate = now

    local win = mq.TLO.Window('ActionsWindow')
    if win and win() ~= nil then
        local lbl = win.Child and win.Child("ASP_CurrentSocialPageLabel") or nil
        if lbl and lbl() ~= nil then
            local okText, txt = pcall(function() return lbl.Text() end)
            if okText and txt ~= nil then
                State.labelText["ASP_CurrentSocialPageLabel"] = Trim(txt)
                State.socialPage = tonumber(Trim(txt)) or State.socialPage
            end
        end
    end

    for i = 1, 12 do
        local info = State.socials[i] or {}
        info.name = ""

        if win and win() ~= nil then
            local btn = win.Child and win.Child("ASP_SocialButton" .. tostring(i)) or nil
            if btn and btn() ~= nil then
                local okTip, tip = pcall(function() return btn.Tooltip() end)
                if okTip and tip ~= nil and Trim(tip) ~= "" then
                    info.name = Trim(tip)
                else
                    local okText, txt = pcall(function() return btn.Text() end)
                    if okText and txt ~= nil then info.name = Trim(txt) end
                end
            end
        end

        State.socials[i] = info
        if info.name ~= "" then
            State.labelText["ASP_SocialButton" .. tostring(i)] = info.name
        else
            State.labelText["ASP_SocialButton" .. tostring(i)] = nil
        end
    end
end

-- DrawList safety wrapper (ImVec2 vs raw coords)
local imvec2_ok = nil
local function draw_call(try_imvec, try_raw)
    if imvec2_ok == nil then
        local ok = pcall(try_imvec)
        if ok then
            imvec2_ok = true
            return
        end
        imvec2_ok = false
        pcall(try_raw)
        return
    end
    if imvec2_ok then
        pcall(try_imvec)
    else
        pcall(try_raw)
    end
end

local function dl_add_rect(dl, x1, y1, x2, y2, col)
    draw_call(
        function() dl:AddRect(ImVec2(x1, y1), ImVec2(x2, y2), col) end,
        function() dl:AddRect(x1, y1, x2, y2, col) end
    )
end

local function dl_add_rect_filled(dl, x1, y1, x2, y2, col)
    draw_call(
        function() dl:AddRectFilled(ImVec2(x1, y1), ImVec2(x2, y2), col) end,
        function() dl:AddRectFilled(x1, y1, x2, y2, col) end
    )
end

GetMousePosSafe = function()
    local ok, mp = pcall(imgui.GetMousePos)
    if ok and type(mp) == 'table' then
        return mp.x or 0, mp.y or 0
    end
    local okIO, io = pcall(imgui.GetIO)
    if okIO and io and io.MousePos and type(io.MousePos) == 'table' then
        return io.MousePos.x or 0, io.MousePos.y or 0
    end
    local okx, x = pcall(imgui.GetMousePosX)
    local oky, y = pcall(imgui.GetMousePosY)
    return (okx and x or 0), (oky and y or 0)
end

local function IsAltHeld()
    local okIO, io = pcall(imgui.GetIO)
    if okIO and io and io.KeyAlt ~= nil then
        return io.KeyAlt == true
    end
    if ImGuiMod and ImGuiMod.Alt and imgui.IsKeyDown then
        local okAlt, down = pcall(imgui.IsKeyDown, ImGuiMod.Alt)
        if okAlt and down == true then return true end
    end
    if ImGuiKey and imgui.IsKeyDown then
        local okL, l = pcall(imgui.IsKeyDown, ImGuiKey.LeftAlt)
        local okR, r = pcall(imgui.IsKeyDown, ImGuiKey.RightAlt)
        return (okL and l == true) or (okR and r == true)
    end
    return false
end

local function dl_add_text(dl, x, y, col, text)
    local ok = pcall(function()
        dl:AddText(ImVec2(x, y), col, text)
    end)
    if not ok then
        pcall(function()
            dl:AddText(x, y, col, text)
        end)
    end
end

local function calc_text_size(text)
    local ok, size = pcall(imgui.CalcTextSize, text)
    if ok then
        if type(size) == 'table' then
            return (size.x or 0), (size.y or 0)
        elseif type(size) == 'number' then
            return size, 12
        end
    end
    return 0, 0
end

local function dl_add_text_scaled(dl, x, y, col, text, scale)
    if not scale or scale == 1 then
        dl_add_text(dl, x, y, col, text)
        return
    end
    local ok = pcall(function()
        local font = imgui.GetFont and imgui.GetFont() or nil
        local fontSize = imgui.GetFontSize and imgui.GetFontSize() or nil
        if font and fontSize then
            local okText = pcall(function()
                dl:AddText(font, fontSize * scale, ImVec2(x, y), col, text)
            end)
            if not okText then
                pcall(function()
                    dl:AddText(font, fontSize * scale, x, y, col, text)
                end)
            end
        else
            dl_add_text(dl, x, y, col, text)
        end
    end)
    if not ok then
        dl_add_text(dl, x, y, col, text)
    end
end

local function dl_add_text_center(dl, x, y, w, h, col, text)
    local tw, th = calc_text_size(text)
    if tw > 0 then
        local tx = x + (w - tw) * 0.5
        local ty = y + (h - th) * 0.5
        dl_add_text(dl, tx, ty, col, text)
        return
    end
    dl_add_text(dl, x + 2, y + 2, col, text)
end

local function dl_add_text_top_center(dl, x, y, w, h, col, text, padding)
    local tw = calc_text_size(text)
    local pad = padding or 2
    if tw and tw > 0 then
        local tx = x + (w - tw) * 0.5
        local ty = y + pad
        dl_add_text(dl, tx, ty, col, text)
        return
    end
    dl_add_text(dl, x + 2, y + 2, col, text)
end

local function dl_add_text_top_center_scaled(dl, x, y, w, col, text, scale, padX, padY, minScale)
    local tw, th = calc_text_size(text)
    local useScale = scale or 1.0
    local px = padX or 4
    local py = padY or 2
    if tw and tw > 0 then
        local maxW = math.max(1, w - (px * 2))
        if (tw * useScale) > maxW then
            useScale = maxW / tw
            if minScale and useScale < minScale then
                useScale = minScale
            end
        end
        local sw = tw * useScale
        local sh = th * useScale
        local tx = x + (w - sw) * 0.5
        local ty = y + py
        return tx, ty, sw, sh, useScale
    end
    return x + 2, y + 2, 0, 0, useScale
end

local function dl_add_text_center_scaled(dl, x, y, w, h, col, text, scale)
    local tw, th = calc_text_size(text)
    if tw > 0 then
        local sw = tw * (scale or 1)
        local sh = th * (scale or 1)
        local tx = x + (w - sw) * 0.5
        local ty = y + (h - sh) * 0.5
        dl_add_text_scaled(dl, tx, ty, col, text, scale)
        return
    end
    dl_add_text_scaled(dl, x + 2, y + 2, col, text, scale)
end

local function WrapTextTwoLines(text, maxW)
    if not text or text == "" then return "", nil end
    local ok, size = pcall(imgui.CalcTextSize, text)
    if ok then
        if type(size) == 'table' and (size.x or 0) <= maxW then return text, nil end
        if type(size) == 'number' and size <= maxW then return text, nil end
    end
    local words = {}
    for w in text:gmatch("%S+") do table.insert(words, w) end
    if #words <= 1 then return text, nil end
    local line1 = ""
    local line2 = ""
    for i = 1, #words do
        local candidate = (line1 == "" and words[i]) or (line1 .. " " .. words[i])
        local okc, sz = pcall(imgui.CalcTextSize, candidate)
        local fits = false
        if okc then
            if type(sz) == 'table' then fits = (sz.x or 0) <= maxW end
            if type(sz) == 'number' then fits = sz <= maxW end
        end
        if fits then
            line1 = candidate
        else
            line2 = table.concat(words, " ", i)
            break
        end
    end
    if line1 == "" then
        line1 = words[1]
        line2 = table.concat(words, " ", 2)
    end
    if line2 == "" then return line1, nil end
    return line1, line2
end

local function TruncateTextToFit(text, maxW, scale)
    if not text or text == "" then return "" end
    maxW = tonumber(maxW) or 0
    if maxW <= 0 then return text end
    scale = tonumber(scale) or 1.0
    local function fits(s)
        local tw = calc_text_size(s)
        return (tw * scale) <= maxW
    end
    if fits(text) then return text end
    local base = text
    local suffix = "..."
    local limit = #base
    for i = limit, 1, -1 do
        local cand = base:sub(1, i) .. suffix
        if fits(cand) then
            return cand
        end
    end
    return suffix
end

local function dl_add_image(dl, texId, x1, y1, x2, y2, u0, v0, u1, v1, col)
    if col ~= nil then
        draw_call(
            function()
                dl:AddImage(texId, ImVec2(x1, y1), ImVec2(x2, y2), ImVec2(u0, v0), ImVec2(u1, v1), col)
            end,
            function()
                dl:AddImage(texId, x1, y1, x2, y2, u0, v0, u1, v1, col)
            end
        )
        return
    end
    draw_call(
        function()
            dl:AddImage(texId, ImVec2(x1, y1), ImVec2(x2, y2), ImVec2(u0, v0), ImVec2(u1, v1))
        end,
        function()
            dl:AddImage(texId, x1, y1, x2, y2, u0, v0, u1, v1)
        end
    )
end

local function dl_add_tex_anim(dl, anim, x, y, w, h)
    if not anim then return end
    pcall(function()
        dl:AddTextureAnimation(anim, ImVec2(x, y), ImVec2(w, h))
    end)
end

-- Draw a spell icon using classic textures (spells01-07.tga) or game texture for higher IDs
local _iconDebugOnce = {}
local function dl_add_spell_icon(dl, iconId, x, y, size)
    if iconId <= 0 or size <= 0 then return end

    if iconId <= CLASSIC_ICON_MAX then
        -- Calculate which sheet (1-7) and cell index within that sheet
        local sheetNum = math.floor(iconId / CLASSIC_ICONS_PER_SHEET) + 1
        local cellIndex = iconId % CLASSIC_ICONS_PER_SHEET

        -- Debug: log icon IDs once
        if not _iconDebugOnce[iconId] then
            _iconDebugOnce[iconId] = true
            print(string.format("[EQ UI] Spell icon ID: %d -> spells%02d.tga cell %d", iconId, sheetNum, cellIndex))
        end

        local tex = GetClassicSpellIconsTex(sheetNum)
        if tex then
            local texId = tex:GetTextureID()
            if texId then
                local col = cellIndex % CLASSIC_ICON_GRID
                local row = math.floor(cellIndex / CLASSIC_ICON_GRID)
                local u0 = col * CLASSIC_ICON_SIZE / 256
                local v0 = row * CLASSIC_ICON_SIZE / 256
                local u1 = (col + 1) * CLASSIC_ICON_SIZE / 256
                local v1 = (row + 1) * CLASSIC_ICON_SIZE / 256
                dl_add_image(dl, texId, x, y, x + size, y + size, u0, v0, u1, v1)
                return
            end
        end
    end

    -- Fall back to game texture animation for icons 252+ or if classic texture failed
    if animSpellIcons then
        animSpellIcons:SetTextureCell(iconId)
        dl_add_tex_anim(dl, animSpellIcons, x, y, size, size)
    end
end

-- Draw a spell icon using oval gem textures (spells01_gem-07_gem.tga) for CSPW_Spell gems only.
-- The _gem.tga cells are square (40x40). We draw the full cell scaled into
-- the target rect so the entire icon remains visible (no UV cropping).
local _iconGemDebugOnce = {}
local function dl_add_spell_icon_gem(dl, iconId, x, y, w, h)
    h = h or w
    if iconId <= 0 or w <= 0 or h <= 0 then return end

    if iconId <= CLASSIC_ICON_MAX then
        -- Calculate which sheet (1-7) and cell index within that sheet
        local sheetNum = math.floor(iconId / CLASSIC_ICONS_PER_SHEET) + 1
        local cellIndex = iconId % CLASSIC_ICONS_PER_SHEET

        -- Debug: log icon IDs once
        if not _iconGemDebugOnce[iconId] then
            _iconGemDebugOnce[iconId] = true
            print(string.format("[EQ UI] Spell gem icon ID: %d -> spells%02d_gem.tga cell %d", iconId, sheetNum, cellIndex))
        end

        local tex = GetClassicSpellIconsGemTex(sheetNum)
        if tex then
            local texId = tex:GetTextureID()
            if texId then
                local col = cellIndex % CLASSIC_ICON_GRID
                local row = math.floor(cellIndex / CLASSIC_ICON_GRID)
                local u0 = col * CLASSIC_ICON_SIZE / 256
                local v0 = row * CLASSIC_ICON_SIZE / 256
                local u1 = (col + 1) * CLASSIC_ICON_SIZE / 256
                local v1 = (row + 1) * CLASSIC_ICON_SIZE / 256

                dl_add_image(dl, texId, x, y, x + w, y + h, u0, v0, u1, v1)
                return
            end
        end
    end

    -- Fall back to game texture animation for icons 252+ or if gem texture failed
    if animSpellIconsGem then
        animSpellIconsGem:SetTextureCell(iconId)
        dl_add_tex_anim(dl, animSpellIconsGem, x, y, w, h)
    elseif animSpellIcons then
        -- Final fallback to square icons
        animSpellIcons:SetTextureCell(iconId)
        dl_add_tex_anim(dl, animSpellIcons, x, y, w, h)
    end
end

-- Draw a spell icon from gemicons textures (24x24 cells, the native EQ gem display icons).
-- These are smaller icons designed to be centered within the gem holder frame.
local _gemIconDebugOnce = {}
local function dl_add_gem_icon(dl, iconId, x, y, size, tintCol)
    if iconId <= 0 or size <= 0 then return false end

    if iconId <= GEMICON_MAX then
        local sheetNum = math.floor(iconId / GEMICONS_PER_SHEET) + 1
        local cellIndex = iconId % GEMICONS_PER_SHEET

        if not _gemIconDebugOnce[iconId] then
            _gemIconDebugOnce[iconId] = true
            print(string.format("[EQ UI] Gem icon ID: %d -> gemicons%02d.tga cell %d", iconId, sheetNum, cellIndex))
        end

        local tex = GetGemIconsTex(sheetNum)
        if tex then
            local texId = tex:GetTextureID()
            if texId then
                local colIdx = cellIndex % GEMICON_GRID
                local row = math.floor(cellIndex / GEMICON_GRID)
                local u0 = colIdx * GEMICON_SIZE / 256
                local v0 = row * GEMICON_SIZE / 256
                local u1 = (colIdx + 1) * GEMICON_SIZE / 256
                local v1 = (row + 1) * GEMICON_SIZE / 256
                dl_add_image(dl, texId, x, y, x + size, y + size, u0, v0, u1, v1, tintCol)
                return true
            end
        end
    end

    -- Fall back to regular square spell icon at the same size
    dl_add_spell_icon(dl, iconId, x, y, size)
    return true
end

-- Draw an item icon using classic textures (dragitem1-34.tga) or game texture for higher IDs
-- Set to false to use game textures instead of classic (for debugging)
local USE_CLASSIC_ITEM_ICONS = false

local _itemIconDebugOnce = {}
local function dl_add_item_icon(dl, iconId, x, y, size)
    if iconId <= 0 or size <= 0 then return end

    -- Debug: log icon IDs once
    local offset = State.itemIconOffset or DEFAULT_ITEM_ICON_OFFSET
    local grid = State.itemIconGrid or CLASSIC_ICON_GRID
    local iconsPerSheet = grid * grid
    local maxIcon = offset + (CLASSIC_ITEM_ICON_SHEETS * iconsPerSheet) - 1
    if not _itemIconDebugOnce[iconId] then
        _itemIconDebugOnce[iconId] = true
        local cellIndex = iconId - offset
        if State.itemIconOneBased then
            cellIndex = cellIndex - 1
        end
        if cellIndex < 0 then
            print(string.format(
                "[EQ UI] Item icon ID: %d below offset (offset=%d, oneBased=%s) -> using game icons",
                iconId, offset, tostring(State.itemIconOneBased == true)))
        else
            local sheetNum = math.floor(cellIndex / iconsPerSheet) + 1
            local cellInSheet = cellIndex % iconsPerSheet
            local col, row
            if State.itemIconColumnMajor then
                col = math.floor(cellInSheet / grid)
                row = cellInSheet % grid
            else
                col = cellInSheet % grid
                row = math.floor(cellInSheet / grid)
            end
            print(string.format("[EQ UI] Item icon ID: %d -> dragitem%d.tga cell %d (using %s)",
                iconId, sheetNum, cellInSheet, USE_CLASSIC_ITEM_ICONS and "classic" or "game"))
            print(string.format("[EQ UI] Item icon ID: %d -> row %d col %d (grid %dx%d, oneBased=%s, columnMajor=%s, offset=%d)",
                iconId, row, col, grid, grid, tostring(State.itemIconOneBased == true), tostring(State.itemIconColumnMajor == true), offset))
        end
    end

    -- Item icons start at 500
    if USE_CLASSIC_ITEM_ICONS and iconId >= offset and iconId <= maxIcon then
        local cellIndex = iconId - offset
        if State.itemIconOneBased then
            cellIndex = cellIndex - 1
        end
        if cellIndex < 0 then
            -- below offset; let game icons handle it
            return
        end
        local sheetNum = math.floor(cellIndex / iconsPerSheet) + 1
        local cellInSheet = cellIndex % iconsPerSheet

        local tex = GetClassicItemIconsTex(sheetNum)
        if tex then
            local texId = tex:GetTextureID()
            if texId then
                local gridSize = State.itemIconGrid or CLASSIC_ICON_GRID
                local iconSize = State.itemIconSize or CLASSIC_ICON_SIZE
                local col, row
                if State.itemIconColumnMajor then
                    col = math.floor(cellInSheet / gridSize)
                    row = cellInSheet % gridSize
                else
                    col = cellInSheet % gridSize
                    row = math.floor(cellInSheet / gridSize)
                end
                local u0 = col * iconSize / 256
                local v0 = row * iconSize / 256
                local u1 = (col + 1) * iconSize / 256
                local v1 = (row + 1) * iconSize / 256
                dl_add_image(dl, texId, x, y, x + size, y + size, u0, v0, u1, v1)
                return
            end
        end
    end

    -- Use game texture animation
    if animItems then
        -- Cell = max(0, iconId - 500)
        local cell = iconId - offset
        if State.itemIconOneBased then
            cell = cell - 1
        end
        if cell < 0 then cell = 0 end
        animItems:SetTextureCell(cell)
        dl_add_tex_anim(dl, animItems, x, y, size, size)
    end
end

ComputeRect = function(parent, ctrl)
    local a = ctrl.anchor or {}
    local x = ctrl.x or 0
    local y = ctrl.y or 0
    local w = ctrl.w or 0
    local h = ctrl.h or 0

    local left, right, top, bottom = nil, nil, nil, nil

    if a.LeftAnchorToLeft then left = parent.x + (a.LeftAnchorOffset or 0) end
    if a.LeftAnchorToRight then left = parent.x + parent.w + (a.LeftAnchorOffset or 0) end
    if a.RightAnchorToLeft then right = parent.x + (a.RightAnchorOffset or 0) end
    if a.RightAnchorToRight then right = parent.x + parent.w + (a.RightAnchorOffset or 0) end

    if a.TopAnchorToTop then top = parent.y + (a.TopAnchorOffset or 0) end
    if a.TopAnchorToBottom then top = parent.y + parent.h + (a.TopAnchorOffset or 0) end
    if a.BottomAnchorToTop then bottom = parent.y + (a.BottomAnchorOffset or 0) end
    if a.BottomAnchorToBottom then bottom = parent.y + parent.h + (a.BottomAnchorOffset or 0) end

    if left ~= nil and right ~= nil then
        x = left
        w = right - left
    elseif left ~= nil then
        x = left
    elseif right ~= nil then
        x = right - w
    else
        x = parent.x + x
    end

    if top ~= nil and bottom ~= nil then
        y = top
        h = bottom - top
    elseif top ~= nil then
        y = top
    elseif bottom ~= nil then
        y = bottom - h
    else
        y = parent.y + y
    end

    return x, y, w, h
end

local function DrawTiledTexture(dl, texName, x, y, w, h, scaleAdj)
    local tex = GetTexture(texName)
    local info = data.textures[texName]
    if not tex or not info or info.w == 0 or info.h == 0 then return end

    local tileW = info.w * scaleAdj
    local tileH = info.h * scaleAdj
    if tileW <= 0 or tileH <= 0 then return end

    local texId = tex:GetTextureID()
    if not texId then return end

    local yPos = y
    while yPos < y + h do
        local xPos = x
        while xPos < x + w do
            local drawW = math.min(tileW, (x + w) - xPos)
            local drawH = math.min(tileH, (y + h) - yPos)
            dl_add_image(dl, texId, xPos, yPos, xPos + drawW, yPos + drawH, 0, 0, drawW / tileW, drawH / tileH)
            xPos = xPos + tileW
        end
        yPos = yPos + tileH
    end
end

local function DrawAnim(dl, animName, x, y, w, h, texOverridePath, col)
    local uv = GetAnimUV(animName)
    if not uv then return false end
    local tex = GetTexture(uv.tex, texOverridePath)
    if not tex then return false end
    local texId = tex:GetTextureID()
    if not texId then return false end
    dl_add_image(dl, texId, x, y, x + w, y + h, uv.u0, uv.v0, uv.u1, uv.v1, col)
    return true
end

local function DrawAnimPreview(animName, maxW, maxH)
    if not animName or animName == "" then
        imgui.TextDisabled("No preview")
        return
    end
    local uv = GetAnimUV(animName)
    if not uv then
        imgui.TextDisabled("Unknown anim: " .. tostring(animName))
        return
    end
    local tex = GetTexture(uv.tex)
    if not tex then
        imgui.TextDisabled("Missing texture: " .. tostring(uv.tex))
        return
    end
    local texId = tex:GetTextureID()
    if not texId then
        imgui.TextDisabled("Texture not loaded")
        return
    end
    local srcW = uv.srcW or 0
    local srcH = uv.srcH or 0
    if srcW <= 0 or srcH <= 0 then
        imgui.TextDisabled("Invalid anim size")
        return
    end

    local scale = math.min(maxW / srcW, maxH / srcH, 1.0)
    local drawW = math.max(1, math.floor(srcW * scale + 0.5))
    local drawH = math.max(1, math.floor(srcH * scale + 0.5))

    local posX, posY = imgui.GetCursorScreenPos()
    local dl = imgui.GetWindowDrawList()
    dl_add_rect_filled(dl, posX, posY, posX + drawW, posY + drawH, 0xAA000000)
    dl_add_image(dl, texId, posX, posY, posX + drawW, posY + drawH, uv.u0, uv.v0, uv.u1, uv.v1)
    imgui.Dummy(drawW, drawH)
end

-- Class animation texture mapping (class ID -> {texture, frameCount, frameW, frameH})
-- Some classes have fewer valid frames or different frame sizes
local ClassAnimTextures = {
    [1] = { tex = "Warrior01.tga", frames = 8 },
    [2] = { tex = "cleric01.tga", frames = 8 },
    [3] = { tex = "paladin01.tga", frames = 8 },
    [4] = { tex = "ranger01.tga", frames = 8 },
    [5] = { tex = "shadowknight01.tga", frames = 8 },
    [6] = { tex = "druid01.tga", frames = 8 },
    [7] = { tex = "monk01.tga", frames = 8 },
    [8] = { tex = "bard01.tga", frames = 8 },
    [9] = { tex = "rogue01.tga", frames = 8 },
    [10] = { tex = "shaman01.tga", frames = 8 },
    [11] = { tex = "necromancer01.tga", frames = 8 },
    [12] = { tex = "wizard01.tga", frames = 8 },
    [13] = { tex = "magician01.tga", frames = 8 },
    [14] = { tex = "enchanter01.tga", frames = 8 },
    [15] = { tex = "beastlord01.tga", frames = 8 },
}

-- Draw animated class sprite with frame cycling
-- Animation plays once every 30 seconds, then holds on first frame
local function DrawClassAnim(dl, classId, x, y, w, h)
    local classInfo = ClassAnimTextures[classId]
    if not classInfo then classInfo = ClassAnimTextures[1] end -- fallback to Warrior

    local texName = classInfo.tex
    local texSize = data.textures[texName]
    if not texSize or texSize.w == 0 or texSize.h == 0 then return false end

    local tex = GetTexture(texName)
    if not tex then return false end
    local texId = tex:GetTextureID()
    if not texId then return false end

    -- Frame dimensions (default 64x128, but some classes like bard use 64x64)
    local frameW = classInfo.frameW or 64
    local frameH = classInfo.frameH or 128
    local cols = math.floor(texSize.w / frameW)  -- typically 4 columns
    local totalFrames = classInfo.frames or 8

    if totalFrames < 1 then totalFrames = 1 end
    if cols < 1 then cols = 1 end

    -- Animation timing: play animation once every 30 seconds
    -- Animation plays at ~150ms per frame, then holds on frame 0
    local frameTime = 0.15
    local animDuration = frameTime * totalFrames  -- ~1.2s for 8 frames
    local cycleDuration = 15.0  -- Full cycle is 15 seconds

    local t = os.clock() % cycleDuration
    local frameIdx = 0

    if t < animDuration then
        -- During animation phase: cycle through frames
        frameIdx = math.floor(t / frameTime) % totalFrames
    else
        -- Holding phase: stay on first frame
        frameIdx = 0
    end

    -- Calculate frame position in sprite sheet
    local col = frameIdx % cols
    local row = math.floor(frameIdx / cols)
    local srcX = col * frameW
    local srcY = row * frameH

    -- Calculate UV coordinates
    local u0 = srcX / texSize.w
    local v0 = srcY / texSize.h
    local u1 = (srcX + frameW) / texSize.w
    local v1 = (srcY + frameH) / texSize.h

    dl_add_image(dl, texId, x, y, x + w, y + h, u0, v0, u1, v1)
    return true
end

local function GetAnimSize(animName, scaleAdj)
    local uv = GetAnimUV(animName)
    if not uv then return 0, 0 end
    return (uv.srcW or 0) * (scaleAdj or 1.0), (uv.srcH or 0) * (scaleAdj or 1.0)
end

local function PopupBorderPadding(border, scaleAdj)
    if not border then return 0, 0 end
    local tlW, tlH = GetAnimSize(border.TopLeft, scaleAdj)
    local trW, trH = GetAnimSize(border.TopRight, scaleAdj)
    local blW, blH = GetAnimSize(border.BottomLeft, scaleAdj)
    local brW, brH = GetAnimSize(border.BottomRight, scaleAdj)
    local topW, topH = GetAnimSize(border.Top, scaleAdj)
    local bottomW, bottomH = GetAnimSize(border.Bottom, scaleAdj)
    local leftW, leftH = GetAnimSize(border.Left, scaleAdj)
    local rightW, rightH = GetAnimSize(border.Right, scaleAdj)

    local padX = math.ceil(math.max(tlW, trW, blW, brW, leftW, rightW, 0))
    local padY = math.ceil(math.max(tlH, trH, blH, brH, topH, bottomH, 0))
    return padX, padY
end

local function EQTexturedButton(label, animNormal, w, h, scale, scaleAdj, textCol)
    local dl = imgui.GetWindowDrawList()

    -- Use an invisible button for input; draw EQ textures ourselves.
    imgui.InvisibleButton("##eqbtn_" .. tostring(label), w, h)
    local hovered = imgui.IsItemHovered()
    local held = imgui.IsItemActive()
    local x, y = 0, 0
    local wDraw, hDraw = w, h
    do
        local okMin, minA, minB = pcall(imgui.GetItemRectMin)
        local okMax, maxA, maxB = pcall(imgui.GetItemRectMax)
        local minX, minY = 0, 0
        local maxX, maxY = 0, 0

        if okMin then
            if type(minA) == "table" then
                minX, minY = tonumber(minA.x) or 0, tonumber(minA.y) or 0
            else
                minX, minY = tonumber(minA) or 0, tonumber(minB) or 0
            end
        end
        if okMax then
            if type(maxA) == "table" then
                maxX, maxY = tonumber(maxA.x) or 0, tonumber(maxA.y) or 0
            else
                maxX, maxY = tonumber(maxA) or 0, tonumber(maxB) or 0
            end
        end

        x, y = minX, minY
        if okMin and okMax then
            wDraw = math.max(0, maxX - minX)
            hDraw = math.max(0, maxY - minY)
        end
    end

    local anim = animNormal
    if held then
        local candidate = animNormal
        if candidate:find("Pressed", 1, true) == nil then
            if candidate:find("Normal", 1, true) then
                candidate = candidate:gsub("Normal", "Pressed")
            else
                candidate = candidate .. "Pressed"
            end
        end
        if data.anims and data.anims[candidate] then anim = candidate end
    elseif hovered then
        local candidate = animNormal
        if candidate:find("Normal", 1, true) then
            candidate = candidate:gsub("Normal", "PressedFlyby")
        else
            candidate = candidate .. "PressedFlyby"
        end
        if data.anims and data.anims[candidate] then anim = candidate end
    end

    if dl and anim and anim ~= "" then
        DrawAnim(dl, anim, x, y, wDraw, hDraw)
        local textY = y - 1 * (scale or 1.0)
        dl_add_text_center_scaled(dl, x, textY, wDraw, hDraw, textCol or 0xEEFFFFFF, tostring(label), scale or 1.0)
    end

    return imgui.IsItemClicked(ImGuiMouseButton.Left)
end

local function DrawBorder(dl, rect, border, scaleAdj)
    if not border then return end

    local function anim_size(name)
        local uv = GetAnimUV(name)
        if not uv then return 0, 0 end
        return uv.srcW * scaleAdj, uv.srcH * scaleAdj
    end

    local tlW, tlH = anim_size(border.TopLeft)
    local trW, trH = anim_size(border.TopRight)
    local blW, blH = anim_size(border.BottomLeft)
    local brW, brH = anim_size(border.BottomRight)

    -- corners
    if tlW > 0 and tlH > 0 then DrawAnim(dl, border.TopLeft, rect.x, rect.y, tlW, tlH) end
    if trW > 0 and trH > 0 then DrawAnim(dl, border.TopRight, rect.x + rect.w - trW, rect.y, trW, trH) end
    if blW > 0 and blH > 0 then DrawAnim(dl, border.BottomLeft, rect.x, rect.y + rect.h - blH, blW, blH) end
    if brW > 0 and brH > 0 then DrawAnim(dl, border.BottomRight, rect.x + rect.w - brW, rect.y + rect.h - brH, brW, brH) end

    -- top/bottom edges
    local topW, topH = anim_size(border.Top)
    local bottomW, bottomH = anim_size(border.Bottom)

    if topW > 0 and topH > 0 then
        local xPos = rect.x + tlW
        local xEnd = rect.x + rect.w - trW
        while xPos < xEnd do
            local drawW = math.min(topW, xEnd - xPos)
            DrawAnim(dl, border.Top, xPos, rect.y, drawW, topH)
            xPos = xPos + topW
        end
    end

    if bottomW > 0 and bottomH > 0 then
        local xPos = rect.x + blW
        local xEnd = rect.x + rect.w - brW
        local yPos = rect.y + rect.h - bottomH
        while xPos < xEnd do
            local drawW = math.min(bottomW, xEnd - xPos)
            DrawAnim(dl, border.Bottom, xPos, yPos, drawW, bottomH)
            xPos = xPos + bottomW
        end
    end

    -- left/right edges
    local leftW, leftH = anim_size(border.Left)
    local rightW, rightH = anim_size(border.Right)

    if leftW > 0 and leftH > 0 then
        local yPos = rect.y + tlH
        local yEnd = rect.y + rect.h - blH
        while yPos < yEnd do
            local drawH = math.min(leftH, yEnd - yPos)
            DrawAnim(dl, border.Left, rect.x, yPos, leftW, drawH)
            yPos = yPos + leftH
        end
    end

    if rightW > 0 and rightH > 0 then
        local yPos = rect.y + trH
        local yEnd = rect.y + rect.h - brH
        local xPos = rect.x + rect.w - rightW
        while yPos < yEnd do
            local drawH = math.min(rightH, yEnd - yPos)
            DrawAnim(dl, border.Right, xPos, yPos, rightW, drawH)
            yPos = yPos + rightH
        end
    end
end

local function DrawTitlebar(dl, rect, titlebar, scaleAdj)
    if not titlebar then return end
    local function anim_size(name)
        local uv = GetAnimUV(name)
        if not uv then return 0, 0 end
        return uv.srcW * scaleAdj, uv.srcH * scaleAdj
    end

    local leftW, leftH = anim_size(titlebar.Left)
    local rightW, rightH = anim_size(titlebar.Right)
    local midW, midH = anim_size(titlebar.Middle)
    local barH = math.max(leftH, rightH, midH)

    if leftW > 0 then DrawAnim(dl, titlebar.Left, rect.x, rect.y, leftW, barH) end
    if rightW > 0 then DrawAnim(dl, titlebar.Right, rect.x + rect.w - rightW, rect.y, rightW, barH) end

    if midW > 0 then
        local xPos = rect.x + leftW
        local xEnd = rect.x + rect.w - rightW
        while xPos < xEnd do
            local drawW = math.min(midW, xEnd - xPos)
            DrawAnim(dl, titlebar.Middle, xPos, rect.y, drawW, barH)
            xPos = xPos + midW
        end
    end
end

local function DrawTemplate(dl, screen, rect, scaleAdj)
    local tpl = data.templates[screen.draw or ""]
    if not tpl then return end

    if tpl.background and tpl.background ~= '' then
        DrawTiledTexture(dl, tpl.background, rect.x, rect.y, rect.w, rect.h, scaleAdj)
    end

    if screen.style and screen.style.Border ~= false then
        DrawBorder(dl, rect, tpl.border, scaleAdj)
    end

    if screen.style and screen.style.Titlebar ~= false then
        DrawTitlebar(dl, rect, tpl.titlebar, scaleAdj)
    end
end

local function GetBuffLayout(screenName, parentRect)
    if screenName ~= "BuffWindow" or not State.buffTwoColumn then return nil end
    local rows = 8 -- 15 buffs -> 8 rows in 2 columns
    local padL, padR, padT, padB = 4, 4, 6, 6
    local gapX, gapY = 3, 2
    local innerW = math.max(0, (parentRect.w or 0) - padL - padR)
    local innerH = math.max(0, (parentRect.h or 0) - padT - padB)
    local colW = math.floor((innerW - gapX) / 2)
    local buttonH = math.floor((innerH - (rows - 1) * gapY) / rows)
    if colW <= 0 or buttonH <= 0 then return nil end
    return {
        x = (parentRect.x or 0) + padL,
        y = (parentRect.y or 0) + padT,
        colW = colW,
        gapX = gapX,
        gapY = gapY,
        buttonH = buttonH,
        ignoreOffsets = true,
    }
end

local function DrawGauge(dl, ctrl, x, y, w, h, scaleAdj)
    if not ctrl.gauge then return false end
    local tpl = ctrl.gauge.Template
    if not tpl then return false end

    local raw = EQTypeValue(ctrl.gauge.EQType or 0)
    if raw == 0 and ctrl.name then
        raw = GaugeValueByName(ctrl.name)
    end
    local pct = Clamp01((raw or 0) / 100.0)

    -- background
    if tpl.Background and tpl.Background ~= '' then
        DrawAnim(dl, tpl.Background, x, y, w, h)
    end

    -- fill (clip by pct)
    if tpl.Fill and tpl.Fill ~= '' then
        local fillW = math.floor(w * pct + 0.5)
        if fillW > 0 then
            DrawAnim(dl, tpl.Fill, x, y, fillW, h)
        end
    end

    -- lines overlay
    if tpl.Lines and tpl.Lines ~= '' then
        DrawAnim(dl, tpl.Lines, x, y, w, h)
    end

    -- endcaps
    if tpl.EndCapLeft and tpl.EndCapLeft ~= '' then
        local uv = GetAnimUV(tpl.EndCapLeft)
        if uv then
            DrawAnim(dl, tpl.EndCapLeft, x, y, uv.srcW * scaleAdj, uv.srcH * scaleAdj)
        end
    end
    if tpl.EndCapRight and tpl.EndCapRight ~= '' then
        local uv = GetAnimUV(tpl.EndCapRight)
        if uv then
            local capW = uv.srcW * scaleAdj
            DrawAnim(dl, tpl.EndCapRight, x + w - capW, y, capW, uv.srcH * scaleAdj)
        end
    end

    return true
end

local SPELLGEM_TINTS = {
    Single = { r = 0.871, g = 0.129, b = 0.129, a = 1.0 }, -- #DE2121FF
    TargetedAE = { r = 0.259, g = 0.871, b = 0.388, a = 1.0 }, -- #42DE63FF
    Group = { r = 0.612, g = 0.192, b = 0.871, a = 1.0 }, -- #9C31DEFF
    PBAE = { r = 0.322, g = 0.259, b = 0.871, a = 1.0 }, -- #5242DEFF
    Self = { r = 0.808, g = 0.871, b = 0.161, a = 1.0 }, -- #CEDE29FF
}
local CAST_TINT = { r = 0.086, g = 0.012, b = 0.012, a = 1.0 } -- #160303FF

local function GetSpellGemTint(targetType)
    if not targetType or targetType == "" then return nil end
    local t = tostring(targetType)
    local lower = t:lower()
    if lower:find("uber giants", 1, true) or lower:find("uber dragons", 1, true) or lower:find("single", 1, true) then
        return SPELLGEM_TINTS.Single
    end
    if lower:find("targeted", 1, true) and lower:find("ae", 1, true) then
        return SPELLGEM_TINTS.TargetedAE
    end
    if lower:find("ae pc v2", 1, true) or lower:find("group v1", 1, true) or lower:find("group v2", 1, true) or lower:find("group", 1, true) then
        return SPELLGEM_TINTS.Group
    end
    if lower:find("pb", 1, true) and lower:find("ae", 1, true) then
        return SPELLGEM_TINTS.PBAE
    end
    if lower:find("self", 1, true) then
        return SPELLGEM_TINTS.Self
    end
    return nil
end

local function DrawSpellGem(dl, ctrl, x, y, w, h, scale, skipOverlay)
    if not ctrl.spellgem or not ctrl.spellgem.Template then return false end

    local tpl = ctrl.spellgem.Template
    local gemIndex = ctrl.spellgem.GemIndex

    -- Layer 1: Background (dark gem fill)
    -- Draw even if template says empty — needed now that we use small centered icons
    local bgTint = nil
    local tintR, tintG, tintB, tintA = 1.0, 1.0, 1.0, 1.0
    local targetType = gemIndex and State.spellTargetType and State.spellTargetType[gemIndex] or ""
    local useCastTint = (State.cast and (tonumber(State.cast.leftMs) or 0) > 0) or false
    local tintDef = useCastTint and CAST_TINT or GetSpellGemTint(targetType)
    if tintDef and imgui.GetColorU32 then
        tintR = tintDef.r or 1.0
        tintG = tintDef.g or 1.0
        tintB = tintDef.b or 1.0
        tintA = tintDef.a or 1.0
        local ok, col = pcall(imgui.GetColorU32, tintR, tintG, tintB, tintA)
        if ok then bgTint = col end
    end
    if bgTint then
        -- Strength controls how many blended passes we apply.
        local strength = tonumber(State.spellGemTintStrength) or 1.0
        if strength > 0 then
            local fullPasses = math.floor(strength)
            local frac = strength - fullPasses
            for _ = 1, fullPasses do
                DrawAnim(dl, "A_SpellGemBackground", x, y, w, h, State.spellGemBgOverridePath, bgTint)
            end
            if frac > 0 then
                local ok, col = pcall(imgui.GetColorU32, tintR, tintG, tintB, tintA * frac)
                if ok then
                    DrawAnim(dl, "A_SpellGemBackground", x, y, w, h, State.spellGemBgOverridePath, col)
                end
            end
        else
            DrawAnim(dl, "A_SpellGemBackground", x, y, w, h, State.spellGemBgOverridePath)
        end
    else
        DrawAnim(dl, "A_SpellGemBackground", x, y, w, h, State.spellGemBgOverridePath)
    end

    -- Layer 2: Spell gem fill centered within the control.
    -- Use gemicons##.tga (matches live EQ) and honor IconOffsetX/Y plus the
    -- configurable Spell Gem Icon Scale.
    local iconId = 0
    if gemIndex then
        iconId = (State.spellGemIcons and State.spellGemIcons[gemIndex]) or (State.spellIcons and State.spellIcons[gemIndex]) or 0
    end
    if iconId > 0 and w > 0 and h > 0 then
        local iconScale = tonumber(State.spellGemIconScale) or 1.0
        local ox = (ctrl.spellgem.IconOffsetX or 0) * (scale or 1.0)
        local oy = (ctrl.spellgem.IconOffsetY or 0) * (scale or 1.0)
        local innerW = math.max(0, w - (ox * 2))
        local innerH = math.max(0, h - (oy * 2))
        local iconSize = math.min(innerW, innerH) * iconScale
        if iconSize > 0 then
            local ix = x + ox + (innerW - iconSize) * 0.5
            local iy = y + oy + (innerH - iconSize) * 0.5
            dl_add_gem_icon(dl, iconId, ix, iy, iconSize)
            if useCastTint and bgTint then
                local ok, col = pcall(imgui.GetColorU32, tintR, tintG, tintB, math.min(1.0, tintA * 0.35))
                if ok then
                    dl_add_rect_filled(dl, ix, iy, ix + iconSize, iy + iconSize, col)
                end
            end
        end
    end

    -- Layer 3: Holder frame (gem-shaped border with transparent center)
    if not skipOverlay then
        if tpl.Holder and tpl.Holder ~= '' then
            if useCastTint and bgTint then
                DrawAnim(dl, tpl.Holder, x, y, w, h, nil, bgTint)
            else
                DrawAnim(dl, tpl.Holder, x, y, w, h)
            end
        end
        -- Layer 4: Highlight (hover/selection glow)
        if tpl.Highlight and tpl.Highlight ~= '' then
            DrawAnim(dl, tpl.Highlight, x, y, w, h)
        end
    end

    return true
end

local function FormatBuffTime(secs)
    local hours = math.floor(secs / 3600)
    local mins = math.floor((secs % 3600) / 60)
    local s = math.floor(secs % 60)
    if hours > 0 then
        return string.format("%dH %dM", hours, mins)
    elseif mins > 0 then
        return string.format("%dM %dS", mins, s)
    else
        return string.format("%dS", s)
    end
end

local function BuildBuffTooltip(name, remaining)
    name = tostring(name or "")
    if name == "" then return nil end
    remaining = tonumber(remaining) or 0
    if State.showBuffTimers and remaining > 0 then
        local secs = remaining
        if remaining > 1000 then
            secs = math.floor(remaining / 1000)
        end
        return string.format("%s\n%s", name, FormatBuffTime(secs))
    end
    return name
end

local function DrawBuffIcon(dl, slotIndex, x, y, w, h)
    if not State.showBuffs then return end
    local iconId = State.buffIcons and State.buffIcons[slotIndex] or 0
    if iconId <= 0 then return end
    local iconScale = State.buffIconScale or 1.0
    local pad = 2
    local baseSize = math.max(0, math.min(w, h) - (pad * 2))
    local size = baseSize * iconScale
    if size <= 0 then return end
    local ix = x + (w - size) * 0.5
    local iy = y + (h - size) * 0.5
    dl_add_spell_icon(dl, iconId, ix, iy, size)
    local remaining = State.buffRemaining and State.buffRemaining[slotIndex] or 0
    if State.showBuffTimers and remaining and remaining > 0 then
        local secs = remaining
        if remaining > 1000 then
            secs = math.floor(remaining / 1000)
        end
        local text = FormatBuffTime(secs)
        local tw, th = calc_text_size(text)
        local timerScale = State.buffTimerScale or 0.8
        local tpad = 1
        local bgPad = math.max(1, math.floor(2 * timerScale))
        local sw = tw * timerScale
        local sh = th * timerScale
        local offX = State.buffTimerOffsetX or 2
        local offY = State.buffTimerOffsetY or 0
        -- Position timer relative to actual icon position, not cell bounds
        local tx = (ix + size) - (sw + tpad) + offX
        local ty = (iy + size) - (sh + tpad) + offY
        -- Draw background for readability
        dl_add_rect_filled(dl, tx - bgPad, ty - bgPad, tx + sw + bgPad, ty + sh + bgPad, 0xCC000000)
        dl_add_text_scaled(dl, tx, ty, 0xFF0000FF, text, timerScale)  -- Red in ABGR format
    end
end

local function DrawShortBuffIcon(dl, slotIndex, x, y, w, h)
    if not State.showBuffs then return end
    local iconId = State.shortBuffIcons and State.shortBuffIcons[slotIndex] or 0
    if iconId <= 0 then return end
    local iconScale = State.buffIconScale or 1.0
    local pad = 2
    local baseSize = math.max(0, math.min(w, h) - (pad * 2))
    local size = baseSize * iconScale
    if size <= 0 then return end
    local ix = x + (w - size) * 0.5
    local iy = y + (h - size) * 0.5
    dl_add_spell_icon(dl, iconId, ix, iy, size)
    local remaining = State.shortBuffRemaining and State.shortBuffRemaining[slotIndex] or 0
    if State.showBuffTimers and remaining and remaining > 0 then
        local secs = remaining
        if remaining > 1000 then
            secs = math.floor(remaining / 1000)
        end
        local text = FormatBuffTime(secs)
        local tw, th = calc_text_size(text)
        local timerScale = State.buffTimerScale or 0.8
        local tpad = 1
        local bgPad = math.max(1, math.floor(2 * timerScale))
        local sw = tw * timerScale
        local sh = th * timerScale
        local offX = State.buffTimerOffsetX or 2
        local offY = State.buffTimerOffsetY or 0
        -- Position timer relative to actual icon position, not cell bounds
        local tx = (ix + size) - (sw + tpad) + offX
        local ty = (iy + size) - (sh + tpad) + offY
        -- Draw background for readability
        dl_add_rect_filled(dl, tx - bgPad, ty - bgPad, tx + sw + bgPad, ty + sh + bgPad, 0xCC000000)
        dl_add_text_scaled(dl, tx, ty, 0xFF0000FF, text, timerScale)  -- Red in ABGR format
    end
end

local function IconCellFromIconId(iconId)
    local iconIdx = tonumber(iconId) or 0
    local offset = State.itemIconOffset or DEFAULT_ITEM_ICON_OFFSET
    local cell0 = (iconIdx > 0) and (iconIdx - offset) or 0
    if State.itemIconOneBased then
        cell0 = cell0 - 1
    end
    if cell0 < 0 then cell0 = 0 end
    return cell0
end

local function ActionsPageForName(name)
    if not name then return 0 end
    if name == "ACTW_bg" then return 0 end
    if name == "ACTW_ActionsSubwindows" then return 0 end
    if name:match("^AMP_") then return 1 end
    if name:match("^AAP_") then return 2 end
    if name:match("^ACP_") then return 3 end
    if name:match("^ASP_") then return 4 end
    return 0
end

local function ActionsShouldShow(name)
    if not name then return true end
    if name == "AMP_InviteButton" then
        return not (State.actionsState and State.actionsState.pendingInvite)
    end
    if name == "AMP_FollowButton" then
        return State.actionsState and State.actionsState.pendingInvite
    end
    if name == "AMP_SitButton" then
        return State.actionsState and State.actionsState.standing
    end
    if name == "AMP_StandButton" then
        return State.actionsState and not State.actionsState.standing
    end
    return true
end

local function DrawActionsTabs(dl, baseRect, scale, originX, originY, scaleAdj)
    local iconSize = 18
    local gap = 4
    local startX = baseRect.x + 11
    local startY = baseRect.y + 4
    local tabs = {
        { page = 1, normal = "A_MainTabIcon", active = "A_MainTabActiveIcon" },
        { page = 2, normal = "A_AbilitiesTabIcon", active = "A_AbilitiesTabActiveIcon" },
        { page = 3, normal = "A_CombatTabIcon", active = "A_CombatTabActiveIcon" },
        { page = 4, normal = "A_SocialsTabIcon", active = "A_SocialsTabActiveIcon" },
    }
    for i = 1, #tabs do
        local t = tabs[i]
        local x = startX + (i - 1) * (iconSize + gap)
        local y = startY
        local xS = originX + (x * scale)
        local yS = originY + (y * scale)
        local sS = iconSize * scale
        local anim = (State.actionsPage == t.page) and t.active or t.normal
        DrawAnim(dl, anim, xS, yS, sS, sS)
        if not State.editMode and State.enableClicks then
            AddClickRegion("ACTW_Tab_" .. tostring(t.page), xS, yS, sS, sS, function()
                State.actionsPage = t.page
            end)
        end
    end
end

local function DrawControl(dl, ctrl, parentRect, scale, originX, originY, key, hover, drawOutline, scaleAdj, layout)
    local baseX, baseY, w, h = ComputeRect(parentRect, ctrl)
    local off = GetOffset(key)
    local adjX = baseX
    local adjY = baseY
    local ignoreOffset = false



    if layout and ctrl.name then
        if ActionsPageForName(ctrl.name) ~= 0 then
            if layout.actionsPageOffsetY then
                adjY = adjY + layout.actionsPageOffsetY
            end
            if layout.actionsPageOffsetX then
                adjX = adjX + layout.actionsPageOffsetX
            end
        end
        local idx = tonumber(ctrl.name:match("^BW_Buff(%d+)_Button$"))
        if idx ~= nil then
            local col = idx % 2
            local row = math.floor(idx / 2)
            adjX = layout.x + col * (layout.colW + layout.gapX)
            adjY = layout.y + row * (layout.buttonH + layout.gapY)
            w = layout.colW
            h = layout.buttonH
            ignoreOffset = layout.ignoreOffsets == true
        else
            local lidx = tonumber(ctrl.name:match("^BW_Label(%d+)$"))
            if lidx ~= nil then
                local col = lidx % 2
                local row = math.floor(lidx / 2)
                adjX = layout.x + col * (layout.colW + layout.gapX)
                adjY = layout.y + row * (layout.buttonH + layout.gapY)
                w = layout.colW
                h = layout.buttonH
                ignoreOffset = layout.ignoreOffsets == true
            end
        end
    end

    if not ignoreOffset then
        adjX = adjX + off.x
        adjY = adjY + off.y
    end

    local x = originX + (adjX * scale)
    local y = originY + (adjY * scale)
    local wS = w * scale
    local hS = h * scale

    if not State.editMode then
        local hide = false
        if ctrl.gauge and ctrl.gauge.EQType then
            local eqtype = ctrl.gauge.EQType
            if (eqtype >= 11 and eqtype <= 15) or (eqtype >= 17 and eqtype <= 21) then
                local idx = (eqtype >= 17) and (eqtype - 16) or (eqtype - 10)
                local memName = (State.labelText and State.labelText["GW_HPLabel" .. tostring(idx)]) or ""
                if memName == "" then hide = true end
            end
        end
        if ctrl.name then
            local pidx = tonumber(ctrl.name:match("^GW_HPPercLabel(%d)$") or "")
            if pidx then
                local memName = (State.labelText and State.labelText["GW_HPLabel" .. tostring(pidx)]) or ""
                if memName == "" then hide = true end
            end
        end
        if hide then
            return { key = key, x = x, y = y, w = 0, h = 0, baseX = baseX, baseY = baseY, originX = originX, originY = originY, scale = scale }
        end
    end

    if ctrl.name and (ctrl.name:match("^HB_InvSlot") or ctrl.name:match("^HB_SpellGem")) then
        return {
            key = key,
            x = x, y = y, w = wS, h = hS,
            baseX = baseX, baseY = baseY,
            originX = originX, originY = originY,
            scale = scale,
        }
    end

    local drew = false
    local pressed = ctrl.type == "Button" and State.pressedCtrls and ctrl.name and State.pressedCtrls[ctrl.name] == true
    local invBtnOverride = false
    if ctrl.type == "Button" and ctrl.name and key and key:match("^InventoryWindow::") then
        local invBtns = {
            IW_DoneButton = true,
            IW_FacePick = true,
            IW_Tinting = true, -- dye/tint
            IW_Dye = true,
            IW_Destroy = true,
            IW_Skills = true,
            IW_AltAdvBtn = true,
        }
        invBtnOverride = invBtns[ctrl.name] == true
    end
    local function pressed_anim_name(animName)
        if not animName or animName == "" then return nil end
        if animName:find("Pressed", 1, true) then return animName end
        local candidate = animName
        if animName:find("Normal", 1, true) then
            candidate = animName:gsub("Normal", "Pressed")
        else
            candidate = animName .. "Pressed"
        end
        if data.anims and data.anims[candidate] then return candidate end
        return nil
    end
    if ctrl.type == "Gauge" then
        drew = DrawGauge(dl, ctrl, x, y, wS, hS, scaleAdj)
        local txt = EQTypeText(ctrl.gauge and ctrl.gauge.EQType or 0)
        if txt and txt ~= '' then
            dl_add_text_top_center(dl, x, y, wS, hS, 0xCCFFFFFF, txt, 2)
        end
    elseif ctrl.type == "SpellGem" then
        -- Skip rendering gems beyond the character's available gem count
        local gemIdx = ctrl.spellgem and ctrl.spellgem.GemIndex
        if gemIdx and State.numGems and gemIdx > State.numGems then
            -- Don't draw this gem - beyond available slots
            drew = false
        else
            drew = DrawSpellGem(dl, ctrl, x, y, wS, hS, scale)
            if drew and State.altHeld and gemIdx then
                local name = ""
                local okGem, gemSpell = pcall(function() return mq.TLO.Me.Gem(gemIdx) end)
                if okGem and gemSpell and gemSpell() then
                    local okName, n = pcall(function() return gemSpell.Name() end)
                    if okName and n and n ~= "" then name = tostring(n) end
                end
                if name ~= "" then
                    local maxScale = State.altSpellLabelScale or 1.2
                    local minScale = State.altSpellLabelMinScale or 0.8
                    local maxW = wS - 4
                    local labelScale = maxScale

                    local line1, line2 = name, nil
                    local tw1, th = calc_text_size(line1)
                    if tw1 > 0 and (tw1 * maxScale) > maxW then
                        line1, line2 = WrapTextTwoLines(name, maxW / maxScale)
                    end
                    if line1 and line1 ~= "" then
                        tw1, th = calc_text_size(line1)
                    end
                    local tw2 = 0
                    if line2 and line2 ~= "" then
                        tw2 = calc_text_size(line2)
                    end
                    local widest = math.max(tw1 or 0, tw2 or 0)
                    if widest > 0 and (widest * labelScale) > maxW then
                        labelScale = maxW / widest
                        if labelScale < minScale then labelScale = minScale end
                    end

                    if widest > 0 and (widest * labelScale) > maxW then
                        line1 = TruncateTextToFit(line1, maxW, labelScale)
                        if line2 and line2 ~= "" then
                            line2 = TruncateTextToFit(line2, maxW, labelScale)
                        end
                        tw1, th = calc_text_size(line1)
                        tw2 = (line2 and line2 ~= "") and calc_text_size(line2) or 0
                        widest = math.max(tw1 or 0, tw2 or 0)
                    end

                    if widest > 0 then
                        local sw = widest * labelScale
                        local sh = th * labelScale
                        local lineGap = math.max(1, math.floor(1 * labelScale))
                        local totalH = sh
                        if line2 and line2 ~= "" then
                            totalH = sh * 2 + lineGap
                        end
                        local tx = x + (wS - sw) * 0.5
                        local ty = y - totalH - 4
                        if ty < 0 then ty = y end
                        local bgPad = 2
                        dl_add_rect_filled(dl, tx - bgPad, ty - bgPad, tx + sw + bgPad, ty + totalH + bgPad, 0xAA000000)
                        dl_add_text_scaled(dl, tx, ty, 0xFFFFFFFF, line1 or "", labelScale)
                        if line2 and line2 ~= "" then
                            dl_add_text_scaled(dl, tx, ty + sh + lineGap, 0xFFFFFFFF, line2, labelScale)
                        end
                    else
                        dl_add_text_center_scaled(dl, x, y - (hS * 0.5), wS, hS, 0xFFFFFFFF, name, labelScale)
                    end
                end
            end
        end
    elseif ctrl.type == "InvSlot" then
        local bgAnim = ctrl.name and InvSlotBackgrounds[ctrl.name]
        if bgAnim then
            DrawAnim(dl, bgAnim, x, y, wS, hS)
            drew = true
        end
        local slotName = ctrl.name and InvSlotNames[ctrl.name] or nil
        local idx = ctrl.name and tonumber(ctrl.name:match("^InvSlot(%d+)$")) or nil
        if idx ~= nil then
            local iconId = 0
            local function getIcon(slotRef)
                local s = mq.TLO.InvSlot(slotRef)
                if s and s() ~= nil then
                    local it = s.Item
                    if it and it() ~= nil and it.Icon then
                        return it.Icon() or 0
                    end
                end
                return 0
            end
            if slotName then
                iconId = getIcon(slotName)
            end
            if iconId == 0 and idx ~= nil then
                iconId = getIcon(idx)
            end
            if iconId and iconId > 0 then
                local iconSize = math.min(wS, hS)
                local ix = x + (wS - iconSize) * 0.5
                local iy = y + (hS - iconSize) * 0.5
                dl_add_item_icon(dl, iconId, ix, iy, iconSize)
                drew = true
                local rem = (State.invItemCooldown and State.invItemCooldown[idx]) or 0
                if rem and rem > 0 then
                    dl_add_rect_filled(dl, ix, iy, ix + iconSize, iy + iconSize, 0x550000FF)
                end
            end
        end
    elseif ctrl.anim and ctrl.anim ~= '' then
        local skipAnim = false
        -- Skip CastSpellWnd background pieces that are beyond the character's available gem count
        if ctrl.name and State.numGems then
            if ctrl.name == "CSPW_bg1b" and State.numGems < 5 then
                skipAnim = true
            elseif ctrl.name == "CSPW_bg1b2" and State.numGems < 8 then
                skipAnim = true
            elseif ctrl.name == "CSPW_bg1c" and State.numGems < 11 then
                skipAnim = true
            end
        end
        local bwBuffIdx = nil
        if ctrl.type == "Button" and ctrl.name then
            local idx = tonumber(ctrl.name:match("^BW_Buff(%d+)_Button$"))
            if idx ~= nil then
                -- The BW_Buff buttons use Blue/RedIconBackground anims (striped backgrounds) which look wrong
                -- when we remap the layout to large icon slots. Skip their anim and just draw the icon/timer.
                bwBuffIdx = idx + 1
                skipAnim = true
            end
            local sidx = tonumber(ctrl.name:match("^SDBW_Buff(%d+)_Button$"))
            if sidx ~= nil then
                -- draw base anim, then overlay icon + timer
                if State.showBuffs then
                    skipAnim = false
                else
                    skipAnim = true
                end
            end
            -- Skip button background anim for hotbuttons that have a spell/item icon
            -- so the icon renders cleanly on the recessed A_InvSlotFrame
            local hbIdx = tonumber(ctrl.name:match("^HB_Button(%d+)$") or "")
            if hbIdx then
                local page = State.hotbuttonPage or 1
                local infos = (State.hotbuttonsPages and State.hotbuttonsPages[page]) or State.hotbuttons
                local info = infos and infos[hbIdx] or nil
                if info and info.iconId and info.iconId > 0 then
                    skipAnim = true
                end
            end
        end
        if not skipAnim then
            local animName = ctrl.anim
            if invBtnOverride then
                animName = "A_BtnNormal"
            end
            if pressed then
                local pAnim = pressed_anim_name(animName)
                if pAnim then animName = pAnim end
            end
            -- ClassAnime: draw animated sprite based on player class
            if ctrl.name == "ClassAnime" or ctrl.name == "ClassAnim" then
                local cid = State.classId or 1
                if cid >= 1 and cid <= 15 then
                    if DrawClassAnim(dl, cid, x, y, wS, hS) then
                        drew = true
                    else
                        -- Fallback to static animation if animated draw fails
                        DrawAnim(dl, animName, x, y, wS, hS)
                        drew = true
                    end
                else
                    -- Berserker or unknown class: use static frame
                    DrawAnim(dl, animName, x, y, wS, hS)
                    drew = true
                end
            else
                DrawAnim(dl, animName, x, y, wS, hS)
                drew = true
            end

            -- Inventory money panel coin icons (these belong on IW_Money*, not the bg piece)
            if ctrl.name then
                local midx = tonumber(ctrl.name:match("^IW_Money(%d)$") or "")
                if midx ~= nil then
                    local coinAnim = ({ "A_PlatinumCoin", "A_GoldCoin", "A_SilverCoin", "A_CopperCoin" })[midx + 1]
                    if coinAnim and data.anims and data.anims[coinAnim] then
                        local cw, ch = GetAnimSize(coinAnim, scaleAdj)
                        if cw > 0 and ch > 0 then
                            local pad = 3 * scale
                            local cx = x + pad
                            local cy = y + math.max(0, hS - ch - pad)
                            DrawAnim(dl, coinAnim, cx, cy, cw, ch)
                        end
                    end
                end
            end
        end
        if ctrl.type == "Button" and ctrl.name then
            if bwBuffIdx ~= nil then
                DrawBuffIcon(dl, bwBuffIdx, x, y, wS, hS)
                drew = true
            end
            local sidx = tonumber(ctrl.name:match("^SDBW_Buff(%d+)_Button$"))
            if sidx ~= nil then
                DrawShortBuffIcon(dl, sidx + 1, x, y, wS, hS)
                drew = true
            end
        end
    elseif State.showFallback and wS > 0 and hS > 0 then
        dl_add_rect(dl, x, y, x + wS, y + hS, 0x44FF00FF)
        drew = true
    end

    if not drew then
        local label = nil
        if ctrl.type == "Label" then
            label = (State.labelText and State.labelText[ctrl.name]) or ctrl.text
        elseif ctrl.text and ctrl.text ~= '' then
            label = ctrl.text
        end
        if State.showBuffLabels and label and label ~= '' and ctrl.name and ctrl.name:match("^BW_Label%d+$") then
            -- When click regions are enabled, tooltip already shows the buff name + timer.
            -- Only suppress label when Alt is not held.
            if State.enableClicks and not State.altHeld then
                label = nil
            end
            local idx = tonumber(ctrl.name:match("^BW_Label(%d+)$")) or -1
            if (State.hoverBuff == nil or idx ~= State.hoverBuff) and not State.altHeld then
                label = nil
            end
        end
        if label and label ~= '' then
            if ctrl.name and ctrl.name:match("^BW_Label%d+$") then
                local labelScale = State.buffLabelScale or 1.0
                -- Calculate text dimensions for background
                local tw, th = calc_text_size(label)
                if tw > 0 then
                    local sw = tw * labelScale
                    local sh = th * labelScale
                    local tx = x + (wS - sw) * 0.5
                    local ty = y + (hS - sh) * 0.5
                    local bgPad = 2
                    -- Draw black background for readability
                    dl_add_rect_filled(dl, tx - bgPad, ty - bgPad, tx + sw + bgPad, ty + sh + bgPad, 0xCC000000)
                    dl_add_text_scaled(dl, tx, ty, 0xFFFFFFFF, label, labelScale)
                else
                    dl_add_text_center_scaled(dl, x, y, wS, hS, 0xFFFFFFFF, label, labelScale)
                end
            else
                if ctrl.name == "CSTW_Label" then
                    local line1, line2 = WrapTextTwoLines(label, wS - 4)
                    local _, lh = calc_text_size(line1)
                    dl_add_text(dl, x + 2, y + 2, 0xCCFFFFFF, line1)
                    if line2 and line2 ~= "" then
                        dl_add_text(dl, x + 2, y + 2 + (lh > 0 and lh or 12), 0xCCFFFFFF, line2)
                    end
                elseif State.heroicText and State.heroicText[ctrl.name] and State.heroicText[ctrl.name] > 0 then
                    local baseW, _ = calc_text_size(label)
                    dl_add_text(dl, x + 2, y + 2, 0xCCFFFFFF, label)
                    local hero = State.heroicText[ctrl.name]
                    dl_add_text(dl, x + 2 + (baseW > 0 and baseW + 2 or 0), y + 2, 0xCC33FF33, string.format("+%d", hero))
                elseif ctrl.name == "TW_TargetName" then
                    local tx = x + 2
                    local ty = y + 2
                    local shadow = 0xCC000000
                    dl_add_text(dl, tx - 1, ty, shadow, label)
                    dl_add_text(dl, tx + 1, ty, shadow, label)
                    dl_add_text(dl, tx, ty - 1, shadow, label)
                    dl_add_text(dl, tx, ty + 1, shadow, label)
                    dl_add_text(dl, tx, ty, 0xFFFFFFFF, label)
                else
                    dl_add_text(dl, x + 2, y + 2, 0xCCFFFFFF, label)
                end
            end
        end
    end

    if drawOutline and wS > 0 and hS > 0 then
        local col = hover and 0xAA00FFFF or 0x6600FFFF
        dl_add_rect(dl, x, y, x + wS, y + hS, col)
    end

    if ctrl.type == "Button" then
        local text = ""
        local isHotbutton = ctrl.name and ctrl.name:match("^HB_Button%d+$") ~= nil
        if isHotbutton then
            -- Hotbuttons: prefer live labelText; fall back to edited/static text only if empty.
            local dyn = State.labelText and State.labelText[ctrl.name]
            if dyn and dyn ~= "" then
                text = tostring(dyn)
            elseif State.controlTextOverrides and State.controlTextOverrides[ctrl.name] then
                text = tostring(State.controlTextOverrides[ctrl.name])
            elseif ctrl.text and ctrl.text ~= "" then
                text = tostring(ctrl.text or "")
            end
        else
            -- Non-hotbuttons: keep override priority.
            if State.controlTextOverrides and State.controlTextOverrides[ctrl.name] then
                text = tostring(State.controlTextOverrides[ctrl.name])
            elseif State.labelText and State.labelText[ctrl.name] then
                text = tostring(State.labelText[ctrl.name] or "")
            elseif ctrl.text and ctrl.text ~= "" then
                text = tostring(ctrl.text or "")
            end
        end
        local hbIconDrawn = false
        if ctrl.name then
            local idx = tonumber(ctrl.name:match("^HB_Button(%d+)$") or "")
            if idx then
                local page = State.hotbuttonPage or 1
                local infos = (State.hotbuttonsPages and State.hotbuttonsPages[page]) or State.hotbuttons
                local info = infos and infos[idx] or nil
                local iconId = info and info.iconId or 0
                if iconId and iconId > 0 then
                    local pad = 3 * scale
                    local iconSize = math.max(0, math.min(wS, hS) - (pad * 2))
                    if iconSize > 0 then
                        local ix = x + (wS - iconSize) * 0.5
                        local iy = y + (hS - iconSize) * 0.5
                        if info.iconType == "spell" then
                            dl_add_spell_icon(dl, iconId, ix, iy, iconSize)
                        elseif info.iconType == "item" then
                            dl_add_item_icon(dl, iconId, ix, iy, iconSize)
                        end
                        hbIconDrawn = true
                    end
                end
            end
        end
        if hbIconDrawn then
            text = ""
        end
        if text ~= "" then
            -- Inventory money buttons: left coin icon + right-justified amount.
            local moneyIdx = ctrl.name and tonumber(ctrl.name:match("^IW_Money(%d)$") or "")
            if moneyIdx ~= nil then
                local coinAnim = ({ "A_PlatinumCoin", "A_GoldCoin", "A_SilverCoin", "A_CopperCoin" })[moneyIdx + 1]
                local cw, ch = (coinAnim and GetAnimSize(coinAnim, scaleAdj)) or 0, 0
                local padL = 3 * scale
                local padR = 4 * scale
                local gap = 4 * scale
                local maxW = math.max(0, wS - (padL + cw + gap) - padR)
                local maxH = math.max(0, hS - (2 * scale))

                local tw, th = calc_text_size(text)
                local sW = (tw > 0) and (maxW / tw) or 1
                local sH = (th > 0) and (maxH / th) or 1
                local s = math.min(1, sW, sH)

                local tx = x + wS - padR - (tw * s)
                local ty = y + (hS - (th * s)) * 0.5
                dl_add_text_scaled(dl, tx, ty, 0xEEFFFFFF, text, s)
                goto skip_button_text
            end

            local isActions = key and key:match("^ActionsWindow::") ~= nil
            local isActionsWhite = ctrl.name and (ctrl.name:match("^AAP_") or ctrl.name:match("^ACP_")) ~= nil
            local color = (isActions and not isActionsWhite) and 0xCC000000 or 0xCCFFFFFF
            if invBtnOverride then
                color = 0xFF000000
            elseif key and key:match("^HotButtonWnd::") then
                color = 0xFF000000
            end
            local bold = ctrl.name and ctrl.name:match("^AMP_") ~= nil

            local line1, line2 = WrapTextTwoLines(text, wS - 4)
            local lines = (line2 and line2 ~= "") and 2 or 1
            local maxW = wS - 4
            local maxH = hS - 4

            local line1W, line1H = calc_text_size(line1)
            local lineMaxW = line1W
            if lines == 2 then
                local line2W, line2H = calc_text_size(line2)
                lineMaxW = math.max(lineMaxW, line2W)
                line1H = math.max(line1H, line2H)
            end
            local targetH = line1H * lines
            local scaleW = (lineMaxW > 0) and (maxW / lineMaxW) or 1
            local scaleH = (targetH > 0) and (maxH / targetH) or 1
            local scale = math.min(1, scaleW, scaleH)

            if lines == 2 then
                local halfH = hS * 0.5
                if bold then
                    dl_add_text_center_scaled(dl, x + 1, y - 2, wS, halfH, color, line1, scale)
                    dl_add_text_center_scaled(dl, x + 1, y + halfH - 2, wS, halfH, color, line2, scale)
                end
                dl_add_text_center_scaled(dl, x, y - 2, wS, halfH, color, line1, scale)
                dl_add_text_center_scaled(dl, x, y + halfH - 2, wS, halfH, color, line2, scale)
                goto skip_button_text
            end

            if bold then
                dl_add_text_center_scaled(dl, x + 1, y, wS, hS, color, text, scale)
            end
            dl_add_text_center_scaled(dl, x, y, wS, hS, color, text, scale)
        end
    end
    ::skip_button_text::

    if ctrl.type == "Button" and State.pressedCtrls and ctrl.name and State.pressedCtrls[ctrl.name] then
        local hasPressedAnim = false
        local baseAnim = ctrl.anim
        if invBtnOverride then
            baseAnim = "A_BtnNormal"
        end
        if baseAnim and baseAnim ~= "" then
            local pAnim = baseAnim:find("Pressed", 1, true) and baseAnim or baseAnim:gsub("Normal", "Pressed")
            if data.anims and data.anims[pAnim] then hasPressedAnim = true end
        end
        if not hasPressedAnim then
            dl_add_rect_filled(dl, x, y, x + wS, y + hS, 0x33000000)
        end
    end

    if ctrl.type == "SpellGem" and State.pressedCtrls and ctrl.name and State.pressedCtrls[ctrl.name] then
        dl_add_rect_filled(dl, x, y, x + wS, y + hS, 0x33000000)
    end

    if ctrl.type == "SpellGem" and ctrl.spellgem and ctrl.spellgem.GemIndex then
        local g = ctrl.spellgem.GemIndex
        local iconId = (State.spellGemIcons and State.spellGemIcons[g]) or (State.spellIcons and State.spellIcons[g]) or 0
        if iconId and iconId > 0 then
            local remaining = (State.spellCooldown and State.spellCooldown[g]) or 0
            if remaining <= 0 then
                remaining = (State.spellCooldownRemaining and State.spellCooldownRemaining[g]) or 0
            end
            if remaining and remaining > 0 then
                local ox = (ctrl.spellgem.IconOffsetX or 0) * scale
                local oy = (ctrl.spellgem.IconOffsetY or 0) * scale
                local iconW = math.max(0, wS - (ox * 2))
                local iconH = math.max(0, hS - (oy * 2))
                local iconSize = math.max(0, math.min(iconW, iconH))
                local ix = x + ox + (iconW - iconSize) * 0.5
                local iy = y + oy + (iconH - iconSize) * 0.5
                dl_add_rect_filled(dl, ix, iy, ix + iconSize, iy + iconSize, 0x550000FF)
            end
        end
    end

    if ctrl.type == "Button" and ctrl.name then
        local hb = ctrl.name:match("^HB_Button(%d+)$")
        if hb then
            local idx = tonumber(hb) or 0
            local page = State.hotbuttonPage or 1
            local infos = (State.hotbuttonsPages and State.hotbuttonsPages[page]) or State.hotbuttons
            local info = infos and infos[idx] or nil
            if info and info.cooldown then
                local rem = tonumber(info.cooldownRem) or 0
                local total = tonumber(info.cooldownTotal) or 0
                local pct = 1
                if total and total > 0 then
                    pct = math.max(0, math.min(1, rem / total))
                end
                if info.iconId and info.iconId > 0 then
                    local pad = 3 * scale
                    local iconSize = math.max(0, math.min(wS, hS) - (pad * 2))
                    if iconSize > 0 then
                        local ix = x + (wS - iconSize) * 0.5
                        local iy = y + (hS - iconSize) * 0.5
                        local fillH = iconSize * pct
                        dl_add_rect_filled(dl, ix, iy + (iconSize - fillH), ix + iconSize, iy + iconSize, 0x550000FF)
                    end
                else
                    local fillH = hS * pct
                    dl_add_rect_filled(dl, x, y + (hS - fillH), x + wS, y + hS, 0x550000FF)
                end
                if rem and rem > 0 then
                    local cdText = fmt_cd_short(rem)
                    if cdText ~= "" then
                        local tw, th = calc_text_size(cdText)
                        local pad = math.max(2, math.floor(2 * scale))
                        local bx = x + (wS - tw) * 0.5
                        local by = y + (hS - th) * 0.5
                        local tcol = 0xFF000000
                        if total and total > 0 then
                            local frac = math.max(0, math.min(1, rem / total))
                            if frac <= 0.33 then
                                tcol = 0xFF00FF00
                            elseif frac <= 0.66 then
                                tcol = 0xFFFFFF00
                            else
                                tcol = 0xFF000000
                            end
                        else
                            tcol = 0xFFFFFF00
                        end
                        dl_add_text(dl, bx, by, tcol, cdText)
                    end
                end
            end
        end
        local ai = ctrl.name:match("^AAP_")
        if ai then
            local i = tonumber(ctrl.name:match("(%d+)")) or 0
            if i > 0 then
                local cd = State.actionsState and State.actionsState.abilityCooldown and State.actionsState.abilityCooldown[i] or 0
                if cd and cd > 0 then
                    dl_add_rect_filled(dl, x, y, x + wS, y + hS, 0x550000FF)
                end
            end
        end
        local ci = ctrl.name:match("^ACP_")
        if ci then
            local i = tonumber(ctrl.name:match("(%d+)")) or 0
            if i > 0 then
                local cd = State.actionsState and State.actionsState.combatAbilityCooldown and State.actionsState.combatAbilityCooldown[i] or 0
                if cd and cd > 0 then
                    dl_add_rect_filled(dl, x, y, x + wS, y + hS, 0x550000FF)
                end
            end
        end
    end

    if ctrl.name then
        local hb = tonumber(ctrl.name:match("^HB_Button(%d+)$") or "")
        if hb then
            State.hotbuttonRects = State.hotbuttonRects or {}
            State.hotbuttonRects[hb] = { x = x, y = y, w = wS, h = hS }
        end
    end

    return {
        key = key,
        x = x, y = y, w = wS, h = hS,
        baseX = baseX, baseY = baseY,
        originX = originX, originY = originY,
        scale = scale,
    }
end

local function IsVisible(name)
    if State.showAll then return true end
    if name == "CastingWindow" then
        if State.editMode then
            return Visible[name]
        end
        return Visible[name]
            and State.cast and State.cast.active
            and State.castWindowOpen == true
    end
    if name == "InventoryWindow" then
        if State.editMode then
            return Visible[name]
        end
        return Visible[name] and State.invOpen == true
    end
    return Visible[name]
end

FindChildByName = function(screenName, childName)
    local screen = data.screens[screenName]
    if not screen or not screen.children then return nil end
    for i = 1, #screen.children do
        local child = screen.children[i]
        if child and child.name == childName then
            return child
        end
    end
    return nil
end

local function GetSelectedElement()
    local key = State.selectedKey
    if not key then return nil end
    if key:sub(1, 8) == "screen::" then
        local screenName = key:sub(9)
        local screen = data.screens[screenName]
        if screen then
            return { kind = "screen", name = screenName, screen = screen }
        end
        return nil
    end
    local screenName, pieceName, kind = key:match("^(.-)::(.-)::(.-)$")
    if not screenName or not pieceName then return nil end
    local ctrl = data.controls[pieceName]
    if not ctrl and kind == "child" then
        ctrl = FindChildByName(screenName, pieceName)
    end
    if ctrl then
        return { kind = "control", name = pieceName, screen = screenName, ctrl = ctrl }
    end
    return nil
end

MarkDirtyScreen = function(name)
    State.dirtyScreens = State.dirtyScreens or {}
    State.dirtyScreens[name] = true
end

MarkDirtyControl = function(name)
    State.dirtyControls = State.dirtyControls or {}
    State.dirtyControls[name] = true
end

MarkDirtyChild = function(key)
    State.dirtyChildren = State.dirtyChildren or {}
    State.dirtyChildren[key] = true
end

local function copy_anchor(a)
    if not a then return nil end
    return {
        LeftAnchorToLeft = a.LeftAnchorToLeft,
        LeftAnchorToRight = a.LeftAnchorToRight,
        RightAnchorToLeft = a.RightAnchorToLeft,
        RightAnchorToRight = a.RightAnchorToRight,
        TopAnchorToTop = a.TopAnchorToTop,
        TopAnchorToBottom = a.TopAnchorToBottom,
        BottomAnchorToTop = a.BottomAnchorToTop,
        BottomAnchorToBottom = a.BottomAnchorToBottom,
        TopAnchorOffset = a.TopAnchorOffset,
        BottomAnchorOffset = a.BottomAnchorOffset,
        LeftAnchorOffset = a.LeftAnchorOffset,
        RightAnchorOffset = a.RightAnchorOffset,
        AutoStretch = a.AutoStretch,
    }
end

local function copy_gauge(g)
    if not g then return nil end
    local t = g.Template
    return {
        EQType = g.EQType,
        Template = t and {
            Background = t.Background,
            Fill = t.Fill,
            Lines = t.Lines,
            LinesFill = t.LinesFill,
            EndCapLeft = t.EndCapLeft,
            EndCapRight = t.EndCapRight,
        } or nil,
    }
end

local function copy_spellgem(sg)
    if not sg then return nil end
    local t = sg.Template
    return {
        GemIndex = sg.GemIndex,
        IconOffsetX = sg.IconOffsetX,
        IconOffsetY = sg.IconOffsetY,
        Template = t and {
            Holder = t.Holder,
            Background = t.Background,
            Highlight = t.Highlight,
        } or nil,
    }
end

local function copy_control(ctrl)
    if not ctrl then return nil end
    return {
        name = ctrl.name,
        type = ctrl.type,
        x = ctrl.x, y = ctrl.y, w = ctrl.w, h = ctrl.h,
        rel = ctrl.rel,
        anim = ctrl.anim,
        text = ctrl.text,
        anchor = copy_anchor(ctrl.anchor),
        gauge = copy_gauge(ctrl.gauge),
        spellgem = copy_spellgem(ctrl.spellgem),
    }
end

local function copy_screen(screen)
    if not screen then return nil end
    return {
        x = screen.x, y = screen.y, w = screen.w, h = screen.h,
        rel = screen.rel,
        draw = screen.draw,
        text = screen.text,
        style = screen.style and {
            Titlebar = screen.style.Titlebar,
            Border = screen.style.Border,
            Transparent = screen.style.Transparent,
        } or nil,
    }
end

local function serialize(value, indent)
    indent = indent or ""
    local t = type(value)
    if t == "number" then return tostring(value) end
    if t == "boolean" then return value and "true" or "false" end
    if t == "string" then return string.format("%q", value) end
    if t ~= "table" then return "nil" end
    local parts = { "{\n" }
    local nextIndent = indent .. "  "
    for k, v in pairs(value) do
        local key
        if type(k) == "string" then
            key = string.format("[%q]", k)
        else
            key = "[" .. tostring(k) .. "]"
        end
        table.insert(parts, nextIndent .. key .. " = " .. serialize(v, nextIndent) .. ",\n")
    end
    table.insert(parts, indent .. "}")
    return table.concat(parts, "")
end

local function write_export(path, export)
    local f, err = io.open(path, "w")
    if not f then
        print(string.format("\ay[EQ UI]\ax Export failed: %s", err or "unknown error"))
        return false
    end
    f:write("return " .. serialize(export) .. "\n")
    f:close()
    print(string.format("\ay[EQ UI]\ax Exported edits to %s", path))
    return true
end

local function ExportEdits(path, onlySelected)
    local export = { screens = {}, controls = {}, children = {}, meta = { timestamp = os.date("%Y-%m-%d %H:%M:%S") } }
    if onlySelected then
        local el = GetSelectedElement()
        if not el then return false end
        if el.kind == "screen" then
            export.screens[el.name] = copy_screen(el.screen)
        else
            if data.controls[el.name] then
                export.controls[el.name] = copy_control(el.ctrl)
            else
                export.children[BuildKey(el.screen, el.name, "child")] = copy_control(el.ctrl)
            end
        end
        return write_export(path, export)
    end

    for name in pairs(State.dirtyScreens or {}) do
        local screen = data.screens[name]
        if screen then export.screens[name] = copy_screen(screen) end
    end
    for name in pairs(State.dirtyControls or {}) do
        local ctrl = data.controls[name]
        if ctrl then export.controls[name] = copy_control(ctrl) end
    end
    for key in pairs(State.dirtyChildren or {}) do
        local screenName, childName = key:match("^(.-)::(.-)$")
        local child = FindChildByName(screenName, childName)
        if child then export.children[BuildKey(screenName, childName, "child")] = copy_control(child) end
    end
    return write_export(path, export)
end

local function input_int(label, value)
    local v, changed = imgui.InputInt(label, value)
    if changed == nil then
        changed = v ~= value
    end
    return v, changed
end

local function input_text(label, value)
    local v, changed = imgui.InputText(label, value or "")
    if changed == nil then
        changed = v ~= value
    end
    return v, changed
end

local function input_bool(label, value)
    local v = imgui.Checkbox(label, value == true)
    if v ~= value then return v, true end
    return value, false
end

local function edit_anchor(anchor)
    if not anchor then return end
    anchor.LeftAnchorToLeft = imgui.Checkbox("Left->Left", anchor.LeftAnchorToLeft == true)
    anchor.LeftAnchorToRight = imgui.Checkbox("Left->Right", anchor.LeftAnchorToRight == true)
    anchor.RightAnchorToLeft = imgui.Checkbox("Right->Left", anchor.RightAnchorToLeft == true)
    anchor.RightAnchorToRight = imgui.Checkbox("Right->Right", anchor.RightAnchorToRight == true)
    anchor.TopAnchorToTop = imgui.Checkbox("Top->Top", anchor.TopAnchorToTop == true)
    anchor.TopAnchorToBottom = imgui.Checkbox("Top->Bottom", anchor.TopAnchorToBottom == true)
    anchor.BottomAnchorToTop = imgui.Checkbox("Bottom->Top", anchor.BottomAnchorToTop == true)
    anchor.BottomAnchorToBottom = imgui.Checkbox("Bottom->Bottom", anchor.BottomAnchorToBottom == true)
    local v, c = input_int("LeftOffset", anchor.LeftAnchorOffset or 0); if c then anchor.LeftAnchorOffset = v end
    v, c = input_int("RightOffset", anchor.RightAnchorOffset or 0); if c then anchor.RightAnchorOffset = v end
    v, c = input_int("TopOffset", anchor.TopAnchorOffset or 0); if c then anchor.TopAnchorOffset = v end
    v, c = input_int("BottomOffset", anchor.BottomAnchorOffset or 0); if c then anchor.BottomAnchorOffset = v end
    anchor.AutoStretch = imgui.Checkbox("AutoStretch", anchor.AutoStretch == true)
end

local function edit_control(ctrl, key)
    local changed = false
    local autosave = false
    local v, c = input_int("x", ctrl.x or 0); if c then ctrl.x = v; changed = true end
    v, c = input_int("y", ctrl.y or 0); if c then ctrl.y = v; changed = true end
    v, c = input_int("w", ctrl.w or 0); if c then ctrl.w = v; changed = true end
    if c and key then
        State.sizeOverrides[key] = { w = ctrl.w, h = ctrl.h }
    end
    v, c = input_int("h", ctrl.h or 0); if c then ctrl.h = v; changed = true end
    if c and key then
        State.sizeOverrides[key] = { w = ctrl.w, h = ctrl.h }
    end
    local s, cs = input_text("text", ctrl.text or "")
    if cs then
        ctrl.text = s
        changed = true
        autosave = true
        -- Track user-edited text so it overrides dynamic labelText
        if ctrl.name then
            State.controlTextOverrides = State.controlTextOverrides or {}
            State.controlTextOverrides[ctrl.name] = s
        end
    end
    s, cs = input_text("anim", ctrl.anim or "")
    if cs then
        ctrl.anim = s
        changed = true
        autosave = true
    end
    local rel = imgui.Checkbox("rel", ctrl.rel == true)
    if rel ~= (ctrl.rel == true) then ctrl.rel = rel; changed = true end
    if ctrl.anchor then
        if imgui.TreeNode("anchor") then
            edit_anchor(ctrl.anchor)
            changed = true
            imgui.TreePop()
        end
    end
    if ctrl.gauge then
        if imgui.TreeNode("gauge") then
            local gv, gc = input_int("EQType", ctrl.gauge.EQType or 0); if gc then ctrl.gauge.EQType = gv; changed = true end
            if ctrl.gauge.Template then
                local t = ctrl.gauge.Template
                local b, bc = input_text("Background", t.Background or ""); if bc then t.Background = b; changed = true end
                local f, fc = input_text("Fill", t.Fill or ""); if fc then t.Fill = f; changed = true end
                local l, lc = input_text("Lines", t.Lines or ""); if lc then t.Lines = l; changed = true end
                local lf, lfc = input_text("LinesFill", t.LinesFill or ""); if lfc then t.LinesFill = lf; changed = true end
                local el, elc = input_text("EndCapLeft", t.EndCapLeft or ""); if elc then t.EndCapLeft = el; changed = true end
                local er, erc = input_text("EndCapRight", t.EndCapRight or ""); if erc then t.EndCapRight = er; changed = true end
            end
            imgui.TreePop()
        end
    end
    if ctrl.spellgem then
        if imgui.TreeNode("spellgem") then
            local sv, sc = input_int("GemIndex", ctrl.spellgem.GemIndex or 0); if sc then ctrl.spellgem.GemIndex = sv; changed = true end
            sv, sc = input_int("IconOffsetX", ctrl.spellgem.IconOffsetX or 0); if sc then ctrl.spellgem.IconOffsetX = sv; changed = true end
            sv, sc = input_int("IconOffsetY", ctrl.spellgem.IconOffsetY or 0); if sc then ctrl.spellgem.IconOffsetY = sv; changed = true end
            if ctrl.spellgem.Template then
                local t = ctrl.spellgem.Template
                local b, bc = input_text("Holder", t.Holder or ""); if bc then t.Holder = b; changed = true end
                local f, fc = input_text("Background", t.Background or ""); if fc then t.Background = f; changed = true end
                local h, hc = input_text("Highlight", t.Highlight or ""); if hc then t.Highlight = h; changed = true end
            end
            imgui.TreePop()
        end
    end
    return changed, autosave
end

local function edit_screen(screen)
    local changed = false
    local v, c = input_int("x", screen.x or 0); if c then screen.x = v; changed = true end
    v, c = input_int("y", screen.y or 0); if c then screen.y = v; changed = true end
    v, c = input_int("w", screen.w or 0); if c then screen.w = v; changed = true end
    v, c = input_int("h", screen.h or 0); if c then screen.h = v; changed = true end
    local s, cs = input_text("draw", screen.draw or ""); if cs then screen.draw = s; changed = true end
    s, cs = input_text("text", screen.text or ""); if cs then screen.text = s; changed = true end
    local rel = imgui.Checkbox("rel", screen.rel == true)
    if rel ~= (screen.rel == true) then screen.rel = rel; changed = true end
    if screen.style then
        if imgui.TreeNode("style") then
            local t = imgui.Checkbox("Titlebar", screen.style.Titlebar ~= false)
            local b = imgui.Checkbox("Border", screen.style.Border ~= false)
            local tr = imgui.Checkbox("Transparent", screen.style.Transparent == true)
            if t ~= (screen.style.Titlebar ~= false) then screen.style.Titlebar = t; changed = true end
            if b ~= (screen.style.Border ~= false) then screen.style.Border = b; changed = true end
            if tr ~= (screen.style.Transparent == true) then screen.style.Transparent = tr; changed = true end
            imgui.TreePop()
        end
    end
    return changed
end

local function RenderSettings(viewport)
    if not State.showSettings then return end
    imgui.SetNextWindowSize(520, 480, ImGuiCond.FirstUseEver)
    State.showSettings = imgui.Begin("EQ UI Rebuild Settings", State.showSettings)
    local settingsChanged = false
    local function set_bool(label, value)
        local v = imgui.Checkbox(label, value == true)
        if v ~= (value == true) then
            settingsChanged = true
        end
        return v
    end

    imgui.Text(string.format("Viewport: %.0fx%.0f", viewport.Size.x, viewport.Size.y))
    imgui.Text(string.format("Base: %dx%d", data.base.w, data.base.h))
    imgui.Text(string.format("Asset scale: %.2f", State.assetScale))
    imgui.Separator()

    State.showBounds = set_bool("Show screen bounds", State.showBounds)
    State.showScreenNames = set_bool("Show screen names", State.showScreenNames)
    State.centerX = set_bool("Center UI horizontally", State.centerX)
    State.showAll = set_bool("Show all screens", State.showAll)
    State.showControls = set_bool("Draw child controls", State.showControls)
    State.showFallback = set_bool("Draw fallback boxes", State.showFallback)
    local wasEditMode = State.editMode
    State.editMode = set_bool("Edit mode (drag pieces/controls)", State.editMode)
    if wasEditMode and not State.editMode then
        ClearAllSelection()
    end
    State.enableClicks = set_bool("Enable UI clicks (group/spells)", State.enableClicks)
    State.drawCursorMirror = set_bool("Draw cursor icon in ImGui windows", State.drawCursorMirror)
    State.dragScreens = set_bool("Drag whole screens", State.dragScreens)
    State.showPieceBounds = set_bool("Show piece bounds", State.showPieceBounds)
    State.showPieceList = set_bool("Show piece list (by screen)", State.showPieceList)
    State.priorityGlobal = set_bool("Global priorities (cross-screen)", State.priorityGlobal)
    State.hotbuttonGroupByNumber = set_bool("Hotbuttons: group by number on drag", State.hotbuttonGroupByNumber)
    State.showBuffs = set_bool("Buffs: show icons", State.showBuffs)
    State.showBuffTimers = set_bool("Buffs: show timers", State.showBuffTimers)
    State.showBuffLabels = set_bool("Buffs: show labels", State.showBuffLabels)
    State.buffTwoColumn = set_bool("Buffs: two-column layout", State.buffTwoColumn)

    imgui.Text("Buff Icon Scale")
    local oldBuffIconScale = State.buffIconScale
    State.buffIconScale = imgui.SliderFloat("##buffIconScale", State.buffIconScale, 0.5, 2.0, "%.2f")
    if State.buffIconScale ~= oldBuffIconScale then settingsChanged = true end
    imgui.Text("Buff Label Scale")
    local oldBuffLabelScale = State.buffLabelScale
    State.buffLabelScale = imgui.SliderFloat("##buffLabelScale", State.buffLabelScale, 0.5, 2.0, "%.2f")
    if State.buffLabelScale ~= oldBuffLabelScale then settingsChanged = true end
    imgui.Text("Spell Gem Icon Scale")
    local oldSpellGemIconScale = State.spellGemIconScale
    State.spellGemIconScale = imgui.SliderFloat("##spellGemIconScale", State.spellGemIconScale or 0.9, 0.7, 1.1, "%.2f")
    if State.spellGemIconScale ~= oldSpellGemIconScale then settingsChanged = true end
    imgui.Text("Spell Gem Count (0 = auto)")
    local oldSpellGemCountOverride = State.spellGemCountOverride
    State.spellGemCountOverride = imgui.SliderInt("##spellGemCountOverride", State.spellGemCountOverride or 0, 0, 13)
    if State.spellGemCountOverride ~= oldSpellGemCountOverride then settingsChanged = true end
    imgui.Text("Spell Gem Tint Strength")
    local oldSpellGemTintStrength = State.spellGemTintStrength
    State.spellGemTintStrength = imgui.SliderFloat("##spellGemTintStrength", State.spellGemTintStrength or 2.0, 0.0, 4.0, "%.2f")
    if State.spellGemTintStrength ~= oldSpellGemTintStrength then settingsChanged = true end

    local newIconOffset, iconOffsetChanged = imgui.InputInt("Item icon offset", State.itemIconOffset or DEFAULT_ITEM_ICON_OFFSET)
    if iconOffsetChanged then
        State.itemIconOffset = newIconOffset
        settingsChanged = true
    end
    local newGrid, gridChanged = imgui.InputInt("Item icon grid", State.itemIconGrid or CLASSIC_ICON_GRID)
    if gridChanged then
        State.itemIconGrid = math.max(1, newGrid)
        settingsChanged = true
    end
    local newSize, sizeChanged = imgui.InputInt("Item icon size", State.itemIconSize or CLASSIC_ICON_SIZE)
    if sizeChanged then
        State.itemIconSize = math.max(1, newSize)
        settingsChanged = true
    end
    local oldOneBased = State.itemIconOneBased == true
    State.itemIconOneBased = imgui.Checkbox("Item icon one-based indexing", oldOneBased)
    if State.itemIconOneBased ~= oldOneBased then settingsChanged = true end
    local oldColumnMajor = State.itemIconColumnMajor == true
    State.itemIconColumnMajor = imgui.Checkbox("Item icon column-major", oldColumnMajor)
    if State.itemIconColumnMajor ~= oldColumnMajor then settingsChanged = true end

    imgui.Text("Scale (0 = auto by height)")
    local oldScaleOverride = State.scaleOverride
    State.scaleOverride = imgui.SliderFloat("##scale", State.scaleOverride, 0.0, 3.0, "%.2f")
    if State.scaleOverride ~= oldScaleOverride then settingsChanged = true end

    imgui.Text("Font Scale")
    local oldFontScale = State.fontScale
    State.fontScale = imgui.SliderFloat("##fontScale", State.fontScale, 0.5, 3.0, "%.2f")
    if State.fontScale ~= oldFontScale then settingsChanged = true end

    imgui.Separator()
    imgui.Text("Filter screens")
    local oldFilter = State.filterText or ""
    State.filterText = imgui.InputTextWithHint("##filter", "e.g. Chat, Player, Inventory", State.filterText)
    if State.filterText ~= oldFilter then settingsChanged = true end

    if imgui.Button("Classic preset") then
        ApplyClassicPreset()
        State.showAll = false
        settingsChanged = true
    end
    imgui.SameLine()
    if imgui.Button("Show none") then
        for name in pairs(Visible) do
            Visible[name] = false
        end
        State.showAll = false
        settingsChanged = true
    end
    imgui.SameLine()
    if imgui.Button("Show all") then
        State.showAll = true
        settingsChanged = true
    end

    imgui.Separator()
    imgui.Text("Visible screens")

    if imgui.BeginChild("##screens", 0, 160, true) then
        for _, name in ipairs(ScreenOrder) do
            if MatchFilter(name, State.filterText) then
                imgui.PushID(name)
                local checked = Visible[name] or false
                local newChecked = imgui.Checkbox(name, checked)
                if newChecked ~= checked then
                    Visible[name] = newChecked
                    if newChecked and State.showAll then
                        State.showAll = false
                    end
                    settingsChanged = true
                end
                imgui.PopID()
            end
        end
    end
    imgui.EndChild()

    if State.showPieceList then
        imgui.Separator()
        imgui.Text("Pieces by screen")
        imgui.TextDisabled("Multi-select pieces with checkboxes (one screen at a time).")
        if imgui.BeginChild("##pieces", 0, 260, true) then
            for _, screenName in ipairs(ScreenOrder) do
                if MatchFilter(screenName, State.filterText) then
                    local screen = data.screens[screenName]
                    if screen then
                        imgui.PushID(screenName)
                        local selected = IsScreenSelected(screenName)
                        local selectChanged = imgui.Checkbox("##sel", selected)
                        if selectChanged ~= selected then
                            SetScreenSelected(screenName, selectChanged)
                            State.selectedKey = BuildScreenKey(screenName)
                        end
                        imgui.SameLine()
                        local open = imgui.TreeNode(screenName)
                        if open then
                            local dock = GetDock(screenName)
                            local dockItems = { "None", "Left", "Right" }
                            local dockIdx = 1
                            if dock.side == "left" then dockIdx = 2 end
                            if dock.side == "right" then dockIdx = 3 end
                            local newIdx, dockChanged = imgui.Combo("Dock", dockIdx, dockItems, #dockItems)
                            if dockChanged then
                                if newIdx == 2 then dock.side = "left"
                                elseif newIdx == 3 then dock.side = "right"
                                else dock.side = "none" end
                                settingsChanged = true
                            end
                            local newMargin, marginChanged = imgui.InputInt("Margin", dock.margin or 0)
                            if marginChanged then
                                dock.margin = newMargin
                                settingsChanged = true
                            end
                            local pieces = screen.pieces or {}
                            for i = 1, #pieces do
                                local pieceName = pieces[i]
                                local key = BuildKey(screenName, pieceName, "piece")
                                local pr = GetPriority(key)
                                local label = pieceName .. (pr ~= 0 and string.format(" (p=%d)", pr) or "")
                                imgui.PushID(key)
                                local multiSelected = IsPieceSelected(key)
                                local newMulti = imgui.Checkbox("##multi", multiSelected)
                                if newMulti ~= multiSelected then
                                    SetPieceSelected(key, newMulti)
                                    if newMulti then
                                        State.selectedKey = key
                                    end
                                end
                                imgui.SameLine()
                                if imgui.SmallButton("Dup") then
                                    local newName = DuplicatePiece(screenName, pieceName)
                                    if newName then
                                        local newKey = BuildKey(screenName, newName, "piece")
                                        State.selectedKey = newKey
                                        RequestAutoSave()
                                    end
                                end
                                imgui.SameLine()
                                local selected = State.selectedKey == key
                                if imgui.Selectable(label, selected) then
                                    State.selectedKey = key
                                end
                                imgui.PopID()
                            end
                            local children = screen.children or {}
                            for i = 1, #children do
                                local child = children[i]
                                local childName = child.name or ("child" .. i)
                                local key = BuildKey(screenName, childName, "child")
                                local pr = GetPriority(key)
                                local label = "[child] " .. childName .. (pr ~= 0 and string.format(" (p=%d)", pr) or "")
                                imgui.PushID(key)
                                local multiSelected = IsPieceSelected(key)
                                local newMulti = imgui.Checkbox("##multi", multiSelected)
                                if newMulti ~= multiSelected then
                                    SetPieceSelected(key, newMulti)
                                    if newMulti then
                                        State.selectedKey = key
                                    end
                                end
                                imgui.SameLine()
                                local selected = State.selectedKey == key
                                if imgui.Selectable(label, selected) then
                                    State.selectedKey = key
                                end
                                imgui.PopID()
                            end
                            imgui.TreePop()
                        end
                        imgui.PopID()
                    end
                end
            end
        end
        imgui.EndChild()

        local pieceCount = 0
        if State.selectedPieces then
            for _, selected in pairs(State.selectedPieces) do
                if selected then pieceCount = pieceCount + 1 end
            end
        end
        if pieceCount > 0 then
            imgui.Text(string.format("Selected pieces: %d", pieceCount))
            if State.selectedPieceScreen then
                imgui.SameLine()
                imgui.TextDisabled("(" .. State.selectedPieceScreen .. ")")
            end
            if imgui.Button("Clear piece selection") then
                ClearPieceSelection()
            end
        end

        imgui.Text("Dock selected screens")
        local newBatch, batchChanged = imgui.InputInt("##dockmargin", State.dockBatchMargin or 0)
        if batchChanged then
            State.dockBatchMargin = newBatch
        end
        if imgui.Button("Dock Left") then
            ApplyDockToSelected("left", State.dockBatchMargin)
            settingsChanged = true
        end
        imgui.SameLine()
        if imgui.Button("Dock Right") then
            ApplyDockToSelected("right", State.dockBatchMargin)
            settingsChanged = true
        end
        imgui.SameLine()
        if imgui.Button("Clear Dock") then
            ApplyDockToSelected("none", 0)
            settingsChanged = true
        end
        imgui.SameLine()
        if imgui.Button("Clear Selection") then
            ClearScreenSelection()
        end
    end

    imgui.Separator()
    if imgui.TreeNode("Unused pieces") then
        if imgui.Button("Refresh list") then
            State.unusedPiecesDirty = true
        end
        if State.unusedPiecesDirty or not State.unusedPiecesList then
            State.unusedPiecesList, State.unusedPiecesCount = BuildUnusedPiecesList()
            State.unusedPiecesDirty = false
        end
        imgui.SameLine()
        imgui.Text(string.format("Unused pieces: %d", State.unusedPiecesCount or 0))

        State.unusedPiecesFilter = imgui.InputTextWithHint(
            "##unusedPiecesFilter",
            "filter by piece name",
            State.unusedPiecesFilter or ""
        )

        local selectedScreenName = nil
        if State.selectedKey and State.selectedKey:sub(1, 8) == "screen::" then
            selectedScreenName = State.selectedKey:sub(9)
        end
        if selectedScreenName then
            imgui.Text(string.format("Target screen: %s", selectedScreenName))
        else
            imgui.TextDisabled("Target screen: <select a screen>")
        end

        local listW = 260
        if imgui.BeginChild("##unusedPiecesList", listW, 220, true) then
            local filter = State.unusedPiecesFilter or ""
            for i = 1, #(State.unusedPiecesList or {}) do
                local pieceName = State.unusedPiecesList[i]
                if filter == "" or MatchFilter(pieceName, filter) then
                    imgui.PushID("unused_" .. pieceName)
                    if imgui.Button("Add") then
                        if selectedScreenName and data.screens[selectedScreenName] then
                            local pieces = data.screens[selectedScreenName].pieces or {}
                            local exists = false
                            for j = 1, #pieces do
                                if pieces[j] == pieceName then
                                    exists = true
                                    break
                                end
                            end
                            if not exists then
                                table.insert(pieces, pieceName)
                                data.screens[selectedScreenName].pieces = pieces
                                MarkDirtyScreen(selectedScreenName)
                                State.unusedPiecesDirty = true
                            end
                        end
                    end
                    imgui.SameLine()
                    if imgui.Selectable(pieceName, State.previewLabel == pieceName) then
                        State.previewLabel = pieceName
                        local ctrl = data.controls and data.controls[pieceName] or nil
                        State.previewAnim = ctrl and ctrl.anim or nil
                    end
                    imgui.PopID()
                end
            end
        end
        imgui.EndChild()
        imgui.SameLine()
        if imgui.BeginChild("##unusedPiecesPreview", 0, 220, true) then
            imgui.Text("Preview")
            imgui.Separator()
            if State.previewLabel then
                imgui.Text(State.previewLabel)
            end
            DrawAnimPreview(State.previewAnim, 180, 180)
        end
        imgui.EndChild()
        imgui.TreePop()
    end

    imgui.Separator()
    if imgui.TreeNode("Unused assets (by TGA)") then
        if imgui.Button("Refresh list") then
            State.unusedAssetsDirty = true
        end

        if State.unusedAssetsDirty or not State.unusedAssetsByTex then
            State.unusedAssetsByTex, State.unusedAssetsTexList, State.unusedAssetsCount = BuildUnusedAssetsByTexture()
            State.unusedAssetsDirty = false
        end

        imgui.SameLine()
        imgui.Text(string.format("Unused anims: %d", State.unusedAssetsCount or 0))

        State.unusedAssetFilter = imgui.InputTextWithHint(
            "##unusedAssetFilter",
            "filter by texture or anim name",
            State.unusedAssetFilter or ""
        )

        local listW = 260
        if imgui.BeginChild("##unusedAssets", listW, 220, true) then
            local filter = State.unusedAssetFilter or ""
            for _, tex in ipairs(State.unusedAssetsTexList or {}) do
                local list = State.unusedAssetsByTex and State.unusedAssetsByTex[tex] or nil
                if list then
                    local showTex = MatchFilter(tex, filter)
                    if not showTex and filter ~= "" then
                        for i = 1, #list do
                            if MatchFilter(list[i], filter) then
                                showTex = true
                                break
                            end
                        end
                    end
                    if showTex then
                        local label = string.format("%s (%d)", tex, #list)
                        if imgui.TreeNode(label) then
                            for i = 1, #list do
                                local animName = list[i]
                                if filter == "" or MatchFilter(animName, filter) or MatchFilter(tex, filter) then
                                    if imgui.Selectable(animName, State.previewLabel == animName) then
                                        State.previewLabel = animName
                                        State.previewAnim = animName
                                    end
                                end
                            end
                            imgui.TreePop()
                        end
                    end
                end
            end
        end
        imgui.EndChild()
        imgui.SameLine()
        if imgui.BeginChild("##unusedAssetsPreview", 0, 220, true) then
            imgui.Text("Preview")
            imgui.Separator()
            if State.previewLabel then
                imgui.Text(State.previewLabel)
            end
            DrawAnimPreview(State.previewAnim, 180, 180)
        end
        imgui.EndChild()
        imgui.TreePop()
    end

    imgui.Separator()
    if imgui.TreeNode("Unused textures") then
        if imgui.Button("Refresh list") then
            State.unusedTexturesDirty = true
        end
        if State.unusedTexturesDirty or not State.unusedTexturesList then
            State.unusedTexturesList, State.unusedTexturesCount = BuildUnusedTexturesList()
            State.unusedTexturesDirty = false
        end
        imgui.SameLine()
        imgui.Text(string.format("Unused textures: %d", State.unusedTexturesCount or 0))

        State.unusedTexturesFilter = imgui.InputTextWithHint(
            "##unusedTexturesFilter",
            "filter by texture name",
            State.unusedTexturesFilter or ""
        )

        local listW = 260
        if imgui.BeginChild("##unusedTexturesList", listW, 220, true) then
            local filter = State.unusedTexturesFilter or ""
            for i = 1, #(State.unusedTexturesList or {}) do
                local texName = State.unusedTexturesList[i]
                if filter == "" or MatchFilter(texName, filter) then
                    if imgui.Selectable(texName, State.previewLabel == texName) then
                        State.previewLabel = texName
                        State.previewAnim = nil
                    end
                end
            end
        end
        imgui.EndChild()
        imgui.SameLine()
        if imgui.BeginChild("##unusedTexturesPreview", 0, 220, true) then
            imgui.Text("Preview")
            imgui.Separator()
            if State.previewLabel then
                imgui.Text(State.previewLabel)
            end
            if State.previewLabel then
                local tex = GetTexture(State.previewLabel)
                if tex then
                    local texId = tex:GetTextureID()
                    local texSize = data.textures[State.previewLabel]
                    if texId and texSize then
                        local srcW = texSize.w or 0
                        local srcH = texSize.h or 0
                        if srcW > 0 and srcH > 0 then
                            local scale = math.min(180 / srcW, 180 / srcH, 1.0)
                            local drawW = math.max(1, math.floor(srcW * scale + 0.5))
                            local drawH = math.max(1, math.floor(srcH * scale + 0.5))
                            local posX, posY = imgui.GetCursorScreenPos()
                            local dl = imgui.GetWindowDrawList()
                            dl_add_rect_filled(dl, posX, posY, posX + drawW, posY + drawH, 0xAA000000)
                            dl_add_image(dl, texId, posX, posY, posX + drawW, posY + drawH, 0, 0, 1, 1)
                            imgui.Dummy(drawW, drawH)
                        else
                            imgui.TextDisabled("Unknown texture size")
                        end
                    else
                        imgui.TextDisabled("Texture not loaded")
                    end
                else
                    imgui.TextDisabled("Texture not found")
                end
            end
        end
        imgui.EndChild()
        imgui.TreePop()
    end

    imgui.Separator()
    imgui.Text("Batch move/resize screen pieces")
    local batchScreens = GetBatchScreens()
    if #batchScreens == 0 then
        imgui.TextDisabled("Select a screen in 'Pieces by screen' or select a screen key.")
    else
        imgui.Text("Target screens: " .. table.concat(batchScreens, ", "))
        local step, stepChanged = input_int("Move step", State.batchMoveStep or 1)
        if stepChanged then State.batchMoveStep = step end
        local dx = State.batchMoveStep or 0
        local dy = State.batchMoveStep or 0
        if imgui.Button("Move Left") then
            for i = 1, #batchScreens do
                ApplyBatchOffset(batchScreens[i], -dx, 0)
            end
        end
        imgui.SameLine()
        if imgui.Button("Move Right") then
            for i = 1, #batchScreens do
                ApplyBatchOffset(batchScreens[i], dx, 0)
            end
        end
        imgui.SameLine()
        if imgui.Button("Move Up") then
            for i = 1, #batchScreens do
                ApplyBatchOffset(batchScreens[i], 0, -dy)
            end
        end
        imgui.SameLine()
        if imgui.Button("Move Down") then
            for i = 1, #batchScreens do
                ApplyBatchOffset(batchScreens[i], 0, dy)
            end
        end

        local pct, pctChanged = input_int("Scale (%)", State.batchScalePct or 100)
        if pctChanged then State.batchScalePct = pct end
        State.batchScalePositions = imgui.Checkbox("Scale positions", State.batchScalePositions == true)
        local pivotItems = { "Top-Left", "Center" }
        local pivotIdx = (State.batchScalePivot == "center") and 2 or 1
        local newPivotIdx, pivotChanged = imgui.Combo("Pivot", pivotIdx, pivotItems, #pivotItems)
        if pivotChanged then
            State.batchScalePivot = (newPivotIdx == 2) and "center" or "topleft"
        end
        if imgui.Button("Scale Pieces") then
            local scaleFactor = (tonumber(State.batchScalePct) or 100) / 100
            if scaleFactor > 0 then
                for i = 1, #batchScreens do
                    ApplyBatchScale(batchScreens[i], scaleFactor)
                end
            end
        end
    end

    imgui.Separator()
    imgui.Text("Brush (border blend)")
    State.brushEnabled = imgui.Checkbox("Enable brush", State.brushEnabled)
    State.brushOnlyBorders = imgui.Checkbox("Only border textures", State.brushOnlyBorders)
    State.brushFalloff = imgui.Checkbox("Falloff", State.brushFalloff)
    local r, rChanged = input_int("Brush radius", State.brushRadius or 6)
    if rChanged then State.brushRadius = math.max(1, r) end
    State.brushStrength = imgui.SliderFloat("Strength", State.brushStrength or 0.35, 0.05, 1.0, "%.2f")
    local at, atChanged = input_int("Alpha min", State.brushAlphaThreshold or 1)
    if atChanged then
        State.brushAlphaThreshold = math.max(0, math.min(255, at))
    end
    if State.brushHover and State.brushHover.texName then
        imgui.Text("Target: " .. tostring(State.brushHover.texName))
    else
        imgui.Text("Target: <none>")
    end

    imgui.Separator()
    imgui.Text("Selected piece")
    imgui.Text(State.selectedKey or "<none>")
    if State.selectedKey then
        local off = GetOffset(State.selectedKey)
        imgui.Text(string.format("Offset: x=%d y=%d", off.x, off.y))
        if imgui.Button("Reset selected offset") then
            State.offsets[State.selectedKey] = { x = 0, y = 0 }
        end
        if State.selectedKey:sub(1, 8) == "screen::" then
            if imgui.Button("Center selected screen") then
                CenterScreenOnViewport(State.selectedKey:sub(9), viewport)
            end
        end
        local pr = GetPriority(State.selectedKey)
        imgui.Text(string.format("Priority: %d", pr))
        local isScreen = State.selectedKey:sub(1, 8) == "screen::"
        if imgui.Button("Bring to front") then
            local _, maxP = PriorityBounds()
            local newP = maxP + 1
            if isScreen then
                SetScreenPriority(State.selectedKey:sub(9), newP)
            else
                State.priorities[State.selectedKey] = newP
            end
        end
        imgui.SameLine()
        if imgui.Button("Send to back") then
            local minP, _ = PriorityBounds()
            local newP = minP - 1
            if isScreen then
                SetScreenPriority(State.selectedKey:sub(9), newP)
            else
                State.priorities[State.selectedKey] = newP
            end
        end
        if imgui.Button("Reset selected priority") then
            if isScreen then
                SetScreenPriority(State.selectedKey:sub(9), 0)
            else
                State.priorities[State.selectedKey] = 0
            end
        end
        local sName, pName, kind = State.selectedKey:match("^(.-)::(.-)::(.-)$")
        if sName and pName and kind == "piece" then
            if imgui.Button("Duplicate selected piece") then
                local newName = DuplicatePiece(sName, pName)
                if newName then
                    State.selectedKey = BuildKey(sName, newName, "piece")
                    RequestAutoSave()
                end
            end
        end
    end
    if imgui.Button("Reset all offsets") then
        State.offsets = {}
        State.selectedKey = nil
    end
    imgui.SameLine()
    if imgui.Button("Reset all priorities") then
        State.priorities = {}
    end
    imgui.Separator()
    imgui.Text("Element editor")
    local el = GetSelectedElement()
    if el then
        if el.kind == "screen" then
            imgui.Text("Screen: " .. tostring(el.name))
            local changed = edit_screen(el.screen)
            if changed then
                MarkDirtyScreen(el.name)
            end
        elseif el.kind == "control" then
            imgui.Text("Control: " .. tostring(el.name))
            if imgui.Button("Remove from screen") then
                local screen = data.screens[el.screen]
                if screen and screen.pieces then
                    for i = #screen.pieces, 1, -1 do
                        if screen.pieces[i] == el.name then
                            table.remove(screen.pieces, i)
                        end
                    end
                    MarkDirtyScreen(el.screen)
                    State.unusedPiecesDirty = true
                    State.selectedKey = nil
                end
            end
            local changed, autosave = edit_control(el.ctrl, State.selectedKey)
            if changed then
                if data.controls[el.name] then
                    MarkDirtyControl(el.name)
                else
                    MarkDirtyChild(el.screen .. "::" .. el.name)
                end
            end
            if autosave then
                RequestAutoSave()
            end
        end
    else
        imgui.Text("<select a screen or piece>")
    end
    local exportBase = "F:/lua/sidekick-next/eq_ui_export"
    if imgui.Button("Export selected") then
        ExportEdits(exportBase .. ".lua", true)
    end
    imgui.SameLine()
    if imgui.Button("Export dirty") then
        local ts = os.date("%Y%m%d_%H%M%S")
        ExportEdits(exportBase .. "_" .. ts .. ".lua", false)
    end
    imgui.Separator()
    imgui.Text("Layout")
    if imgui.Button("Save layout") then
        SaveOffsets()
    end
    imgui.SameLine()
    if imgui.Button("Reload layout") then
        LoadOffsets()
    end

    if settingsChanged then
        RequestAutoSave()
    end

    imgui.End()
end

local function RenderUI()
    if not State.open then return end

    -- Apply font scale for high-resolution monitors
    local fontScale = tonumber(State.fontScale) or 1.0
    if fontScale ~= 1.0 then
        imgui.PushFont(imgui.GetFont(), imgui.GetFontSize() * fontScale)
    end

    local viewport = imgui.GetMainViewport()
    local vpPos = viewport.Pos
    local vpSize = viewport.Size

    imgui.SetNextWindowPos(vpPos.x, vpPos.y)
    imgui.SetNextWindowSize(vpSize.x, vpSize.y)

    local flags = bit32.bor(
        ImGuiWindowFlags.NoTitleBar,
        ImGuiWindowFlags.NoResize,
        ImGuiWindowFlags.NoMove,
        ImGuiWindowFlags.NoScrollbar,
        ImGuiWindowFlags.NoScrollWithMouse,
        ImGuiWindowFlags.NoCollapse,
        ImGuiWindowFlags.NoBackground,
        ImGuiWindowFlags.NoBringToFrontOnFocus,
        ImGuiWindowFlags.NoFocusOnAppearing,
        ImGuiWindowFlags.NoNavFocus,
        ImGuiWindowFlags.NoNav
    )
    if not State.editMode then
        flags = bit32.bor(flags, ImGuiWindowFlags.NoInputs)
    end

    imgui.PushStyleVar(ImGuiStyleVar.WindowPadding, 0, 0)
    imgui.PushStyleVar(ImGuiStyleVar.WindowBorderSize, 0)

    State.open, State.draw = imgui.Begin("##EQUIRebuildOverlay", State.open, flags)

    if State.draw then
        local dl = imgui.GetWindowDrawList()
        local mx, my = imgui.GetMousePos()
        State.altHeld = IsAltHeld()
        UpdateGaugeValues()

        local scale = (State.scaleOverride and State.scaleOverride > 0 and State.scaleOverride)
            or (vpSize.y / data.base.h)

        local totalW = data.base.w * scale
        local offsetX = State.centerX and (vpSize.x - totalW) * 0.5 or 0
        local offsetY = 0
        local scaleAdj = scale / (State.assetScale > 0 and State.assetScale or 1.0)

        local hovered = nil
        State.hoverBuff = nil

        local topScreens = { PlayerWindow = true }
        local screenRects = {}
        local drawItems = {}
        local selectedRect = nil
        local selectedLabel = nil
        local drawOrder = 0
        State.hotbuttonRects = {}
        State.castSpellWndRect = nil
        State.castSpellGemHits = nil

        local function computeBaseRect(name)
            local screen = data.screens[name]
            if not screen then return nil end
            local screenKey = BuildScreenKey(name)
            local screenOff = GetOffset(screenKey)
            local dockBaseX = DockBaseX(name, scale, offsetX, vpSize.x, screen.w) or screen.x
            return {
                screen = screen,
                screenKey = screenKey,
                screenOff = screenOff,
                dockBaseX = dockBaseX,
                baseX = dockBaseX + screenOff.x,
                baseY = screen.y + screenOff.y,
                w = screen.w,
                h = screen.h,
            }
        end

        local anchorBaseX = nil
        for _, anchorName in ipairs({ "SelectorWindow", "HotButtonWnd" }) do
            if IsVisible(anchorName) then
                local br = computeBaseRect(anchorName)
                if br then
                    local rightEdge = br.baseX + br.w
                    if not anchorBaseX or rightEdge > anchorBaseX then
                        anchorBaseX = rightEdge
                    end
                end
            end
        end

        local function addItem(item)
            table.insert(drawItems, item)
        end

        for pass = 1, 2 do
            for _, screenName in ipairs(ScreenOrder) do
                local isTop = topScreens[screenName] == true
                if (pass == 1 and isTop) or (pass == 2 and not isTop) then
                    goto continue_screen
                end
                if not (IsVisible(screenName) and MatchFilter(screenName, State.filterText)) then
                    goto continue_screen
                end
                drawOrder = drawOrder + 1

                local screen = data.screens[screenName]
                local screenKey = BuildScreenKey(screenName)
                local screenOff = GetOffset(screenKey)
                local dockBaseX = DockBaseX(screenName, scale, offsetX, vpSize.x, screen.w) or screen.x
                local baseX = dockBaseX + screenOff.x
                local baseY = screen.y + screenOff.y
                if screenName == "InventoryWindow" then
                    local margin = 0
                    local openX = ((vpSize.x - (screen.w * scale) - margin) - offsetX) / scale
                    local closedX = ((vpSize.x + 6 + margin) - offsetX) / scale
                    local target = State.invOpen and 1.0 or 0.0
                    local t = ImAnim and ImAnim.spring and ImAnim.spring('inv_slide_x', target, 200, 20) or target
                    baseX = (closedX + (openX - closedX) * t) + screenOff.x
                end
                local baseRect = {
                    x = baseX,
                    y = baseY,
                    w = screen.w,
                    h = screen.h,
                }
                local rect = {
                    x = offsetX + (baseRect.x * scale),
                    y = offsetY + (baseRect.y * scale),
                    w = screen.w * scale,
                    h = screen.h * scale,
                }

        local buffLayout = (State.showBuffs or State.showBuffLabels or State.showBuffTimers) and GetBuffLayout(screenName, baseRect) or nil

                screenRects[screenName] = {
                    screen = screen,
                    rect = rect,
                    baseRect = baseRect,
                    screenKey = screenKey,
                    dockBaseX = dockBaseX,
                }
                table.insert(screenRects, screenName)
                if State.selectedKey == screenKey then
                    selectedRect = { x = rect.x, y = rect.y, w = rect.w, h = rect.h }
                    selectedLabel = "Screen: " .. screenName
                end
                if screenName == "CastSpellWnd" then
                    State.castSpellWndRect = rect
                end

                if State.showBounds then
                    dl_add_rect(dl, rect.x, rect.y, rect.x + rect.w, rect.y + rect.h, 0x66FFFFFF)
                end

                if State.showScreenNames then
                    dl_add_text(dl, rect.x + 2, rect.y + 2, 0xAAFFFFFF, screenName)
                end

                addItem({
                    kind = "template",
                    screenName = screenName,
                    screen = screen,
                    rect = rect,
                    key = BuildScreenKey(screenName),
                    screenOrder = drawOrder,
                    itemOrder = 0,
                })

                if screenName == "ActionsWindow" then
                    addItem({
                        kind = "actions_tabs",
                        screenName = screenName,
                        baseRect = baseRect,
                        screenOrder = drawOrder,
                        -- Draw tabs on top of all ActionsWindow pieces so they don't get covered.
                        itemOrder = 100000,
                    })
                end

                local pieces = screen.pieces or {}
                for i = 1, #pieces do
                    local pieceName = pieces[i]
                    local ctrl = data.controls[pieceName]
                    if ctrl then
                        if screenName == "ActionsWindow" then
                            local page = ActionsPageForName(ctrl.name)
                            if page ~= 0 and page ~= State.actionsPage then
                                goto continue_piece
                            end
                            if ctrl.name == "ACTW_ActionsSubwindows" then
                                goto continue_piece
                            end
                            if not ActionsShouldShow(ctrl.name) then
                                goto continue_piece
                            end
                        end
                        local key = BuildKey(screenName, pieceName, "piece")
                        addItem({
                            kind = "ctrl",
                            screenName = screenName,
                            ctrl = ctrl,
                            key = key,
                            baseRect = baseRect,
                            layout = (screenName == "ActionsWindow") and { actionsPageOffsetY = 20, actionsPageOffsetX = 5 } or buffLayout,
                            screenOrder = drawOrder,
                            itemOrder = i,
                        })
                    end
                    ::continue_piece::
                end

                if State.showControls then
                    local children = screen.children or {}
                    for i = 1, #children do
                        local child = children[i]
                        local key = BuildKey(screenName, child.name or ("child" .. i), "child")
                        addItem({
                            kind = "ctrl",
                            screenName = screenName,
                            ctrl = child,
                            key = key,
                            baseRect = baseRect,
                            layout = buffLayout,
                            screenOrder = drawOrder,
                            itemOrder = 10000 + i,
                        })
                    end
                end
                ::continue_screen::
            end
        end

        table.sort(drawItems, function(a, b)
            local pa = a.key and GetPriority(a.key) or 0
            local pb = b.key and GetPriority(b.key) or 0
            -- Clamp: no piece renders behind its own parent screen
            if a.screenName and a.kind ~= "screen" then
                local sp = GetPriority(BuildScreenKey(a.screenName))
                if pa < sp then pa = sp end
            end
            if b.screenName and b.kind ~= "screen" then
                local sp = GetPriority(BuildScreenKey(b.screenName))
                if pb < sp then pb = sp end
            end
            if State.priorityGlobal then
                if pa ~= pb then return pa < pb end
                if a.screenOrder ~= b.screenOrder then return a.screenOrder < b.screenOrder end
                if a.screenName and b.screenName and a.screenName == b.screenName and a.kind ~= b.kind then
                    if a.kind == "template" then return true end
                    if b.kind == "template" then return false end
                end
                return a.itemOrder < b.itemOrder
            end
            if a.screenOrder ~= b.screenOrder then return a.screenOrder < b.screenOrder end
            if pa ~= pb then return pa < pb end
            if a.screenName and b.screenName and a.screenName == b.screenName and a.kind ~= b.kind then
                if a.kind == "template" then return true end
                if b.kind == "template" then return false end
            end
            return a.itemOrder < b.itemOrder
        end)

        for i = 1, #drawItems do
            local item = drawItems[i]
            if item.kind == "template" then
                DrawTemplate(dl, item.screen, item.rect, scaleAdj)
            elseif item.kind == "actions_tabs" then
                DrawActionsTabs(dl, item.baseRect, scale, offsetX, offsetY, scaleAdj)
            else
                local hit = DrawControl(
                    dl,
                    item.ctrl,
                    item.baseRect,
                    scale,
                    offsetX,
                    offsetY,
                    item.key,
                    false,
                    State.showPieceBounds or State.editMode,
                    scaleAdj,
                    item.layout
                )
                if item.key == State.selectedKey and hit and hit.w > 0 and hit.h > 0 then
                    selectedRect = { x = hit.x, y = hit.y, w = hit.w, h = hit.h }
                    local labelName = (item.ctrl and item.ctrl.name) or item.key
                    selectedLabel = "Piece: " .. tostring(labelName)
                end
                if item.screenName == "CastSpellWnd" and item.ctrl and item.ctrl.type == "SpellGem" and item.ctrl.spellgem and item.ctrl.spellgem.GemIndex then
                    State.castSpellGemHits = State.castSpellGemHits or {}
                    State.castSpellGemHits[item.ctrl.spellgem.GemIndex] = hit
                end
                if State.editMode and not State.dragging and hit.w > 0 and hit.h > 0 then
                    if mx >= hit.x and mx <= hit.x + hit.w and my >= hit.y and my <= hit.y + hit.h then
                        hovered = hit
                        hovered.key = item.key
                        hovered.ctrl = item.ctrl
                        hovered.screenName = item.screenName
                    end
                end
                if not State.editMode and State.enableClicks and item.screenName == "GroupWindow" and item.ctrl and item.ctrl.name then
                    local name = item.ctrl.name
                    local idx = tonumber(name:match("^GW_Gauge(%d)$"))
                        or tonumber(name:match("^GW_PetGauge(%d)$"))
                        or tonumber(name:match("^GW_HPLabel(%d)$"))
                        or tonumber(name:match("^GW_HPPercLabel(%d)$"))
                    if idx then
                        local memName = (State.labelText and State.labelText["GW_HPLabel" .. idx]) or ""
                        if memName and memName ~= "" then
                            AddClickRegion("grp_" .. name .. "_" .. idx, hit.x, hit.y, hit.w, hit.h, function()
                                mq.cmdf("/target %s", memName)
                            end)
                        end
                    elseif name == "GW_InviteButton" then
                        AddClickRegion("grp_invite", hit.x, hit.y, hit.w, hit.h, function()
                            mq.cmd("/invite")
                        end)
                    elseif name == "GW_DisbandButton" then
                        AddClickRegion("grp_disband", hit.x, hit.y, hit.w, hit.h, function()
                            mq.cmd("/disband")
                        end)
                    elseif name == "GW_FollowButton" then
                        AddClickRegion("grp_follow", hit.x, hit.y, hit.w, hit.h, function()
                            mq.cmd("/follow")
                        end)
                    elseif name == "GW_DeclineButton" then
                        AddClickRegion("grp_decline", hit.x, hit.y, hit.w, hit.h, function()
                            mq.cmd("/decline")
                        end)
                    elseif name == "GW_LFGButton" then
                        AddClickRegion("grp_lfg", hit.x, hit.y, hit.w, hit.h, function()
                            pcall(function()
                                local w = mq.TLO.Window('LFGuildWnd')
                                local okOpen, isOpen = pcall(function() return w and w() ~= nil and w.Open and w.Open() end)
                                if okOpen and isOpen then
                                    if w and w() ~= nil and w.DoClose then
                                        w.DoClose()
                                    else
                                        mq.cmd("/lfguild")
                                    end
                                else
                                    if w and w() ~= nil and w.DoOpen then
                                        w.DoOpen()
                                    else
                                        mq.cmd("/lfguild")
                                    end
                                end
                            end)
                        end, nil, nil, nil, name)
                    end
                end
                if not State.editMode and State.enableClicks and item.ctrl and item.ctrl.name == "CSPW_SpellBook" then
                    AddClickRegion("CSPW_SpellBook", hit.x, hit.y, hit.w, hit.h, function()
                        local sb = mq.TLO.Window('SpellBookWnd')
                        local okVal, v = pcall(function() return mq.TLO.Window('SpellBookWnd').Open() end)
                        local open = okVal and v == true
                        State.spellbookOpen = open
                        print(string.format("\ay[EQ UI]\ax CSPW_SpellBook click: okVal=%s open=%s", tostring(okVal), tostring(open)))
                        if open then
                            local okClose, errClose = pcall(function() return sb.DoClose() end)
                            print(string.format("\ay[EQ UI]\ax CSPW_SpellBook DoClose ok=%s err=%s", tostring(okClose), tostring(errClose)))
                        else
                            local okOpen, errOpen = pcall(function() return sb.DoOpen() end)
                            print(string.format("\ay[EQ UI]\ax CSPW_SpellBook DoOpen ok=%s err=%s", tostring(okOpen), tostring(errOpen)))
                        end
                    end)
                end
                if not State.editMode and State.enableClicks and item.screenName == "PlayerWindow" and item.ctrl and item.ctrl.name and item.ctrl.name:match("^PW_") then
                    AddClickRegion("pw_self_" .. item.ctrl.name, hit.x, hit.y, hit.w, hit.h, function()
                        local okName, nm = pcall(function() return mq.TLO.Me.Name() end)
                        if okName and nm ~= nil then
                            mq.cmdf("/target %s", tostring(nm))
                        end
                    end)
                end
                if not State.editMode and State.enableClicks and item.screenName == "ActionsWindow" and item.ctrl and item.ctrl.name then
                    local name = item.ctrl.name
                    local function add_amp(regionId, onClick)
                        AddClickRegion(regionId, hit.x, hit.y, hit.w, hit.h, onClick, nil, nil, nil, name, {
                            deferLeftClick = true,
                            dragPayload = { type = "actw", kind = "command", ctrlName = name },
                        })
                    end
                    if name == "AMP_WhoButton" then
                        add_amp("act_who", function() mq.cmd("/who") end)
                    elseif name == "AMP_InviteButton" then
                        add_amp("act_invite", function()
                            mq.cmd("/invite")
                            mq.cmd("/keypress ctrl+I")
                        end)
                    elseif name == "AMP_FollowButton" then
                        add_amp("act_follow", function() mq.cmd("/keypress ctrl+I") end)
                    elseif name == "AMP_DisbandButton" then
                        add_amp("act_disband", function() mq.cmd("/keypress ctrl+D") end)
                    elseif name == "AMP_CampButton" then
                        add_amp("act_camp", function() mq.cmd("/camp") end)
                    elseif name == "AMP_StandButton" then
                        add_amp("act_stand", function() mq.cmd("/stand") end)
                    elseif name == "AMP_SitButton" then
                        add_amp("act_sit", function() mq.cmd("/sit") end)
                    elseif name == "AMP_RunButton" or name == "AMP_WalkButton" then
                        add_amp("act_runwalk_" .. name, function() mq.cmd("/keypress ctrl+R") end)
                    end
                end
                if not State.editMode and State.enableClicks and item.screenName == "ActionsWindow" and item.ctrl and item.ctrl.name then
                    local name = item.ctrl.name
                    if name == "ASP_SocialPageLeftButton" or name == "ASP_SocialPageRightButton" then
                        AddClickRegion("asp_page_" .. name, hit.x, hit.y, hit.w, hit.h, function()
                            local win = mq.TLO.Window('ActionsWindow')
                            if win and win() ~= nil then
                                local btn = win.Child and win.Child(name) or nil
                                if btn and btn() ~= nil then
                                    pcall(function() btn.LeftMouseUp() end)
                                end
                            end
                        end, nil, nil, nil, name)
                    else
                        local idx = tonumber(name:match("^ASP_SocialButton(%d+)$") or "")
                        if idx then
                            AddClickRegion("asp_btn_" .. tostring(idx), hit.x, hit.y, hit.w, hit.h, function()
                                local win = mq.TLO.Window('ActionsWindow')
                                if win and win() ~= nil then
                                    local btn = win.Child and win.Child("ASP_SocialButton" .. tostring(idx)) or nil
                                    if btn and btn() ~= nil then
                                        pcall(function() btn.LeftMouseUp() end)
                                    end
                                end
                            end, nil, nil, nil, name, {
                                deferLeftClick = true,
                                dragPayload = { type = "actw", kind = "social", idx = idx, ctrlName = name },
                            })
                        end
                    end
                end
                if not State.editMode and State.enableClicks and item.screenName == "ActionsWindow" and item.ctrl and item.ctrl.name then
                    local name = item.ctrl.name
                    local aidx = tonumber(name:match("^AAP_(%w+)AbilityButton$") or "")
                    if aidx == nil then
                        if name == "AAP_FirstAbilityButton" then aidx = 1
                        elseif name == "AAP_SecondAbilityButton" then aidx = 2
                        elseif name == "AAP_ThirdAbilityButton" then aidx = 3
                        elseif name == "AAP_FourthAbilityButton" then aidx = 4
                        elseif name == "AAP_FifthAbilityButton" then aidx = 5
                        elseif name == "AAP_SixthAbilityButton" then aidx = 6
                        end
                    end
                    if aidx then
                        AddClickRegion("act_ability_" .. tostring(aidx), hit.x, hit.y, hit.w, hit.h, function()
                            local ids = State.actionsState and State.actionsState.abilityIds or {}
                            local id = ids[aidx] or -1
                            if id == nil or id <= 0 then
                                pcall(function() mq.TLO.Window('SkillsSelectWindow').DoOpen() end)
                            else
                                mq.cmdf("/doability %d", aidx)
                            end
                        end, nil, nil, nil, name, {
                            deferLeftClick = true,
                            dragPayload = { type = "actw", kind = "ability", idx = aidx, ctrlName = name },
                        })
                    end
                end
                if not State.editMode and State.enableClicks and item.screenName == "ActionsWindow" and item.ctrl and item.ctrl.name == "ACP_MeleeAttackButton" then
                    AddClickRegion("act_autoattack", hit.x, hit.y, hit.w, hit.h, function()
                        local on = false
                        local ok, v = pcall(function() return mq.TLO.Me.Combat() end)
                        if ok then on = v == true end
                        mq.cmd(on and "/attack off" or "/attack on")
                    end, nil, nil, nil, item.ctrl.name)
                end
                if not State.editMode and State.enableClicks and item.screenName == "ActionsWindow" and item.ctrl and item.ctrl.name then
                    local name = item.ctrl.name
                    local cidx = tonumber(name:match("^ACP_(%w+)AbilityButton$") or "")
                    if cidx == nil then
                        if name == "ACP_FirstAbilityButton" then cidx = 1
                        elseif name == "ACP_SecondAbilityButton" then cidx = 2
                        elseif name == "ACP_ThirdAbilityButton" then cidx = 3
                        elseif name == "ACP_FourthAbilityButton" then cidx = 4
                        end
                    end
                    if cidx then
                        AddClickRegion("act_combat_ability_" .. tostring(cidx), hit.x, hit.y, hit.w, hit.h, function()
                            local names = State.actionsState and State.actionsState.combatAbilityNames or {}
                            local nm = names[cidx] or ""
                            if nm == "" then
                                pcall(function() mq.TLO.Window('SkillsSelectWindow').DoOpen() end)
                            else
                                mq.cmdf("/doability %d", cidx)
                            end
                        end, nil, nil, nil, name, {
                            deferLeftClick = true,
                            dragPayload = { type = "actw", kind = "combat", idx = cidx, ctrlName = name },
                        })
                    end
                end
                if not State.editMode and State.enableClicks and item.screenName == "HotButtonWnd" and item.ctrl and item.ctrl.name then
                    local name = item.ctrl.name
                    if name == "HB_PageLeftButton" or name == "HB_PageRightButton" then
                        AddClickRegion("hb_page_" .. name, hit.x, hit.y, hit.w, hit.h, function()
                            local win = mq.TLO.Window('HotButtonWnd')
                            if win and win() ~= nil then
                                local btn = win.Child and win.Child(name) or nil
                                if btn and btn() ~= nil then
                                    pcall(function() btn.LeftMouseUp() end)
                                end
                            end
                            local delta = (name == "HB_PageRightButton") and 1 or -1
                            State.hotbuttonPage = math.max(1, (State.hotbuttonPage or 1) + delta)
                            State.labelText["HB_CurrentPageLabel"] = tostring(State.hotbuttonPage)
                            -- Force a refresh so HB_CurrentPageLabel + icons update immediately after paging.
                            State.lastHotbuttonUpdate = 0
                            pcall(function()
                                local lbl = win and win.Child and win.Child("HB_CurrentPageLabel") or nil
                                if lbl and lbl() ~= nil then
                                    local txt = lbl.Text and lbl.Text() or ""
                                    local raw = Trim(txt)
                                    local p = tonumber(raw) or tonumber(raw:match("(%d+)"))
                                    if p then State.hotbuttonPage = p end
                                end
                            end)
                            State.labelText["HB_CurrentPageLabel"] = tostring(State.hotbuttonPage or 1)
                        end, nil, nil, nil, name)
                    else
                        local idx = tonumber(name:match("^HB_Button(%d+)$") or "")
                        if idx then
                            local tooltipFn = function()
                                if cursor_name() ~= "" then return "" end
                                local page = State.hotbuttonPage or 1
                                local infos = (State.hotbuttonsPages and State.hotbuttonsPages[page]) or State.hotbuttons
                                local info = infos and infos[idx] or nil
                                if not info then return "" end
                                local base = info.name or ""
                                local cd = tonumber(info.cooldownRem) or 0
                                if cd > 0 then
                                    local cdTxt = fmt_cd_short(cd)
                                    if cdTxt ~= "" then
                                        return string.format("%s\nCooldown: %s", base, cdTxt)
                                    end
                                end
                                return base
                            end
                            AddClickRegion("hb_btn_" .. tostring(idx), hit.x, hit.y, hit.w, hit.h, function()
                                if DRAG_DEBUG then
                                    local curName = cursor_name()
                                    local page = State.hotbuttonPage or 1
                                    local infos = (State.hotbuttonsPages and State.hotbuttonsPages[page]) or State.hotbuttons
                                    local info = infos and infos[idx] or nil
                                    local name = info and info.name or ""
                                    print(string.format("\ay[EQ UI]\ax Hotbutton click idx=%d cursor='%s' name='%s'", idx, curName, name))
                                end
                                local page = State.hotbuttonPage or 1
                                local infos = (State.hotbuttonsPages and State.hotbuttonsPages[page]) or State.hotbuttons
                                local info = infos and infos[idx] or nil
                                local isEmpty = (not info) or (info.name == nil) or (info.name == "")
                                local curName = cursor_name()
                                if curName ~= "" or isEmpty then
                                    local hbPath = string.format("HotButtonWnd/HB_Button%d", idx)
                                    if DRAG_DEBUG then
                                        local why = (curName ~= "" and "cursor") or "empty"
                                        print(string.format("\ay[EQ UI]\ax Hotbutton click drop(%s) to HB_Button%d notify=/notify \"%s\" HB_SpellGem leftmouseup", why, idx, hbPath))
                                    end
                                    mq.cmdf('/notify "%s" HB_SpellGem leftmouseup', hbPath)
                                    if curName ~= "" then
                                        local curType = cursor_attachment_type()
                                        local isTextOnly = curType ~= "" and curType ~= "ITEM" and curType ~= "INVSLOT"
                                            and curType ~= "SPELL_GEM" and curType ~= "MEMORIZE_SPELL"
                                            and curType ~= "ITEM_LINK" and curType ~= "KRONO_SLOT"
                                        if infos and infos[idx] then
                                            infos[idx].name = curName
                                            if isTextOnly then
                                                infos[idx].iconId = 0
                                                infos[idx].iconType = ""
                                            end
                                        end
                                        State.labelText["HB_Button" .. tostring(idx)] = curName
                                    end
                                    State.lastHotbuttonUpdate = 0
                                    return
                                end
                                local hbPath = string.format("HotButtonWnd/HB_Button%d", idx)
                                local okAct = pcall(function()
                                    local hb = mq.TLO.Window(hbPath).HotButton
                                    if hb and hb() ~= nil then
                                        hb.Activate()
                                        return true
                                    end
                                    return false
                                end)
                                if not okAct then
                                    local win = mq.TLO.Window('HotButtonWnd')
                                    if win and win() ~= nil then
                                        local btn = win.Child and win.Child("HB_Button" .. tostring(idx)) or nil
                                        if btn and btn() ~= nil then
                                            pcall(function() btn.LeftMouseUp() end)
                                            return
                                        end
                                    end
                                    mq.cmdf("/hotbutton %d", idx)
                                end
                            end, nil, tooltipFn, nil, name, { deferLeftClick = true, dragPayload = { type = "hotbutton", idx = idx } })
                        end
                    end
                end
                if not State.editMode and item.ctrl and item.ctrl.name then
                    local bidx = tonumber(item.ctrl.name:match("^BW_Buff(%d+)_Button$"))
                    if bidx ~= nil then
                        if mx >= hit.x and mx <= hit.x + hit.w and my >= hit.y and my <= hit.y + hit.h then
                            State.hoverBuff = bidx
                        end
                        if State.enableClicks then
                            local slot = bidx + 1
                            local buffName = (State.labelText and State.labelText["BW_Label" .. tostring(bidx)]) or ""
                            if buffName ~= "" then
                                local tooltipFn = function()
                                    local rem = (State.buffRemaining and State.buffRemaining[slot]) or 0
                                    return BuildBuffTooltip(buffName, rem)
                                end
                                AddClickRegion(
                                    "buff_" .. tostring(slot),
                                    hit.x, hit.y, hit.w, hit.h,
                                    function() mq.cmdf('/removebuff \"%s\"', buffName) end,
                                    function()
                                        local okInspect = pcall(function()
                                            local sp = mq.TLO.Spell(buffName)
                                            if sp and sp() and sp.Inspect then sp.Inspect() end
                                        end)
                                        if not okInspect then
                                            mq.cmdf('/inspect \"%s\"', buffName)
                                        end
                                    end,
                                    tooltipFn
                                )
                            end
                        end
                    end
                end
                if not State.editMode and State.enableClicks and item.ctrl and item.ctrl.name then
                    local sidx = tonumber(item.ctrl.name:match("^SDBW_Buff(%d+)_Button$"))
                    if sidx ~= nil then
                        local slot = sidx + 1
                        local buffName = (State.shortBuffNames and State.shortBuffNames[slot]) or ""
                        local tooltipFn = function()
                            local rem = (State.shortBuffRemaining and State.shortBuffRemaining[slot]) or 0
                            return BuildBuffTooltip(buffName, rem)
                        end
                        AddClickRegion(
                            "sdbw_buff_" .. tostring(slot),
                            hit.x, hit.y, hit.w, hit.h,
                            function()
                                if buffName ~= "" then
                                    mq.cmdf('/removebuff \"%s\"', buffName)
                                end
                            end,
                            function()
                                if buffName ~= "" then
                                    local okInspect = pcall(function()
                                        local sp = mq.TLO.Spell(buffName)
                                        if sp and sp() and sp.Inspect then sp.Inspect() end
                                    end)
                                    if not okInspect then
                                        mq.cmdf('/inspect \"%s\"', buffName)
                                    end
                                end
                            end,
                            tooltipFn,
                            nil,
                            item.ctrl.name
                        )
                    end
                end
                if not State.editMode and State.enableClicks and item.ctrl and item.ctrl.type == "SpellGem" then
                    local gemIndex = item.ctrl.spellgem and item.ctrl.spellgem.GemIndex
                    -- Skip click regions for gems beyond the character's available count
                    if gemIndex and item.screenName == "CastSpellWnd" and (not State.numGems or gemIndex <= State.numGems) then
                        local iconId = State.spellIcons and State.spellIcons[gemIndex] or 0
                        local hx, hy, hw, hh = hit.x, hit.y, hit.w, hit.h
                        -- Tooltip function to show spell name on hover
                        local tooltipFn = function()
                            local okGem, gemSpell = pcall(function() return mq.TLO.Me.Gem(gemIndex) end)
                            if okGem and gemSpell and gemSpell() then
                                local okName, name = pcall(function() return gemSpell.Name() end)
                                if okName and name and name ~= "" then
                                    return name
                                end
                            end
                            return nil
                        end
                        AddClickRegion("cast_gem_" .. tostring(gemIndex), hit.x, hit.y, hit.w, hit.h,
                            function()
                                mq.cmdf("/cast %d", gemIndex)
                            end,
                            function()
                                if is_empty_gem(gemIndex) then
                                    -- Empty gem - open memorize menu
                                    State.spellMenu = { gemIndex = gemIndex, input = "", isEmpty = true }
                                    State.spellMenuAnchor = { x = hx, y = hy, w = hw, h = hh }
                                    State.spellMenuPos = true
                                else
                                    -- Non-empty gem - open context menu with Cast/Unmemorize options
                                    State.spellMenu = { gemIndex = gemIndex, input = "", isEmpty = false }
                                    State.spellMenuAnchor = { x = hx, y = hy, w = hw, h = hh }
                                    State.spellMenuPos = true
                                end
                            end,
                            tooltipFn,
                            nil,
                            item.ctrl.name,
                            { deferLeftClick = true, dragPayload = { type = "spellgem", gemIndex = gemIndex, iconId = iconId } }
                        )
                    end
                end
                -- Inventory slot click handling
                if not State.editMode and State.enableClicks and item.ctrl and item.ctrl.type == "InvSlot" then
                    local slotName = item.ctrl.name and InvSlotNames[item.ctrl.name]
                    local slotIdx = item.ctrl.name and tonumber(item.ctrl.name:match("^InvSlot(%d+)$"))
                    if slotName or slotIdx then
                        local slotRef = slotName or slotIdx
                        -- Get item info for this slot
                        local function getSlotItem()
                            local ok, result = pcall(function()
                                local s = mq.TLO.InvSlot(slotRef)
                                if s and s() then
                                    return s.Item
                                end
                                return nil
                            end)
                            return ok and result or nil
                        end
                        -- Tooltip: show item name on hover
                        local tooltipFn = function()
                            local item = getSlotItem()
                            if item and item() then
                                return item.Name() or ""
                            end
                            return ""
                        end
                        -- Check if this is a bag slot (23-30=pack1-pack8; 22=ammo; 21=power source)
                        local isBagSlot = slotIdx and (slotIdx >= 23 and slotIdx <= 30)

                        -- Left click: pick up item (leftmouseup)
                        local onClickFn = function()
                            local function safe_num(fn)
                                local ok, v = pcall(fn)
                                if ok then return tonumber(v) or 0 end
                                return 0
                            end
                            local function want_quantity_selector()
                                local item = getSlotItem()
                                if not item or not item() then return false end
                                local stack = safe_num(function() return item.Stack() end)
                                local stackCount = safe_num(function() return item.StackCount() end)
                                local charges = safe_num(function() return item.Charges() end)
                                return (stack > 1) or (stackCount > 1) or (charges > 1)
                            end
                            local okCur, cur = pcall(function() return mq.TLO.Cursor end)
                            if okCur and cur and cur() ~= nil then
                                mq.cmdf('/itemnotify %s leftmouseup', tostring(slotRef))
                                return
                            end
                            if want_quantity_selector() then
                                mq.cmd('/shiftkey down')
                                mq.cmdf('/itemnotify %s leftmouseup', tostring(slotRef))
                                mq.cmd('/shiftkey up')
                                return
                            end
                            mq.cmdf('/itemnotify %s leftmouseup', tostring(slotRef))
                        end

                        -- Right click behavior:
                        -- Containers: open bag
                        -- Non-containers: activate item (use/rightmouseup)
                        local onRightClickFn = function()
                            -- rightmouseup works for both opening bags and activating items
                            mq.cmdf('/itemnotify %s rightmouseup', tostring(slotRef))
                        end

                        -- Hold right click: inspect item (for all slot types)
                        local onRightHoldFn = function()
                            local slotItem = getSlotItem()
                            if slotItem and slotItem() then
                                local itemName = slotItem.Name()
                                if itemName and itemName ~= '' then
                                    pcall(function()
                                        mq.TLO.FindItem(itemName).Inspect()
                                    end)
                                end
                            end
                        end

                        local dragOpts = nil
                        if item.screenName == "InventoryWindow" then
                            dragOpts = {
                                deferLeftClick = true,
                                dragPayload = {
                                    type = "invitem",
                                    slotRef = slotRef,
                                    ctrlName = item.ctrl.name,
                                    windowName = item.screenName or "InventoryWindow",
                                },
                            }
                        end
                        AddClickRegion(
                            "inv_" .. (item.ctrl.name or tostring(slotIdx)),
                            hit.x, hit.y, hit.w, hit.h,
                            onClickFn,
                            onRightClickFn,
                            tooltipFn,
                            onRightHoldFn,
                            item.ctrl.name,
                            dragOpts
                        )
                    end
                end
                if not State.editMode and State.enableClicks and item.screenName == "InventoryWindow" and item.ctrl and item.ctrl.name then
                    local name = item.ctrl.name
                    local invButtons = {
                        IW_DoneButton = true,
                        IW_FacePick = true,
                        IW_Tinting = true,
                        IW_Destroy = true,
                        IW_Skills = true,
                        IW_AltAdvBtn = true,
                    }
                    if invButtons[name] then
                        AddClickRegion("inv_btn_" .. name, hit.x, hit.y, hit.w, hit.h, function()
                            local win = mq.TLO.Window('InventoryWindow')
                            if win and win() ~= nil then
                                local btn = win.Child and win.Child(name) or nil
                                if btn and btn() ~= nil then
                                    pcall(function() btn.LeftMouseUp() end)
                                end
                            end
                        end, nil, nil, nil, name)
                    elseif name:match("^IW_Money[0-3]$") then
                        AddClickRegion("inv_money_" .. name, hit.x, hit.y, hit.w, hit.h, function()
                            local win = mq.TLO.Window('InventoryWindow')
                            if win and win() ~= nil then
                                local btn = win.Child and win.Child(name) or nil
                                if btn and btn() ~= nil then
                                    pcall(function() btn.LeftMouseUp() end)
                                end
                            end
                        end, nil, nil, nil, name)
                    elseif name == "IW_bg_autoequip" then
                        AddClickRegion("inv_autoinv", hit.x, hit.y, hit.w, hit.h, function()
                            local okCur, cur = pcall(function() return mq.TLO.Cursor end)
                            if okCur and cur and cur() ~= nil then
                                mq.cmd("/autoinventory")
                            end
                        end, nil, nil, nil, name)
                    end
                end
                if not State.editMode and item.ctrl and item.ctrl.name == "SELW_InventoryToggleButton" then
                    AddClickRegion("inv_toggle", hit.x, hit.y, hit.w, hit.h, function()
                        State.invOpen = not State.invOpen
                        if State.invOpen then
                            Visible["InventoryWindow"] = true
                        end
                    end)
                end
                if not State.editMode and item.ctrl and item.ctrl.name == "SELW_GuildToggleButton" then
                    AddClickRegion("guild_toggle", hit.x, hit.y, hit.w, hit.h, function()
                        pcall(function()
                            local gw = mq.TLO.Window('GuildManagementWnd')
                            local okOpen, isOpen = pcall(function() return gw and gw() ~= nil and gw.Open and gw.Open() end)
                            if okOpen and isOpen then
                                if gw and gw() ~= nil and gw.DoClose then
                                    gw.DoClose()
                                else
                                    mq.cmd("/guildmanage")
                                end
                            else
                                if gw and gw() ~= nil and gw.DoOpen then
                                    gw.DoOpen()
                                else
                                    mq.cmd("/guildmanage")
                                end
                            end
                        end)
                    end, nil, nil, nil, item.ctrl.name)
                end
                if not State.editMode and item.ctrl and item.ctrl.name == "SELW_MapToggleButton" then
                    AddClickRegion("map_toggle", hit.x, hit.y, hit.w, hit.h, function()
                        pcall(function()
                            local mw = mq.TLO.Window('MapViewWnd')
                            local okOpen, isOpen = pcall(function() return mw and mw() ~= nil and mw.Open and mw.Open() end)
                            if okOpen and isOpen then
                                if mw and mw() ~= nil and mw.DoClose then
                                    mw.DoClose()
                                elseif mw and mw() ~= nil and mw.Close then
                                    mw.Close()
                                else
                                    mq.cmd("/maphide")
                                end
                            else
                                if mw and mw() ~= nil and mw.DoOpen then
                                    mw.DoOpen()
                                elseif mw and mw() ~= nil and mw.Open then
                                    mw.Open()
                                else
                                    mq.cmd("/mapshow")
                                end
                            end
                        end)
                    end, nil, nil, nil, item.ctrl.name)
                end
                if not State.editMode and item.ctrl and item.ctrl.name == "SELW_JournalToggleButton" then
                    AddClickRegion("task_toggle", hit.x, hit.y, hit.w, hit.h, function()
                        pcall(function()
                            local tw = mq.TLO.Window('TaskWnd')
                            local okOpen, isOpen = pcall(function() return tw and tw() ~= nil and tw.Open and tw.Open() end)
                            if okOpen and isOpen then
                                if tw and tw() ~= nil and tw.DoClose then
                                    tw.DoClose()
                                else
                                    mq.cmd("/task") -- best-effort toggle fallback
                                end
                            else
                                if tw and tw() ~= nil and tw.DoOpen then
                                    tw.DoOpen()
                                else
                                    mq.cmd("/task")
                                end
                            end
                        end)
                    end, nil, nil, nil, item.ctrl.name)
                end
                if not State.editMode and item.ctrl and item.ctrl.name == "SELW_StoryToggleButton" then
                    AddClickRegion("equibuild_settings_toggle", hit.x, hit.y, hit.w, hit.h, function()
                        State.showSettings = not State.showSettings
                    end, nil, nil, nil, item.ctrl.name)
                end
            end
        end

    if State.dragSpell then
        if State.dragSpell.type == "actw" then
            local now = os.clock()
            local startT = State.dragSpell.dragStart or now
            local curType = cursor_attachment_type()
            local curName = cursor_name()
            if DRAG_DEBUG then
                local lastDbg = State.dragSpell._dbg_actw_last or 0
                if (now - lastDbg) >= 0.25 then
                    State.dragSpell._dbg_actw_last = now
                    print(string.format("\ay[EQ UI]\ax Actw drag wait dt=%.2f cursorType='%s' cursorName='%s'",
                        (now - startT), tostring(curType), tostring(curName)))
                end
            end
            -- For ActionsWindow drags, only show the game's cursor; do not draw overlay preview.
            goto skip_drag_draw
        end
        local useGameCursor = State.dragSpell.useGameCursor == true
        if useGameCursor then
            drag_debug_once(State.dragSpell, "draw_skip_game", "\ay[EQ UI]\ax Drag draw skipped (game cursor)")
        else
            local dragDl = imgui.GetForegroundDrawList() or dl
            if State.dragSpell.iconId and State.dragSpell.iconId > 0 then
                local mx, my = GetMousePosSafe()
                local size = 28 * scale
                local ix = mx - (size * 0.5)
                local iy = my - (size * 0.5)
                -- Use oval gem icon when dragging a spell gem
                if State.dragSpell.type == "spellgem" then
                    local gemScale = tonumber(State.spellGemIconScale) or 1.0
                    if gemScale > 0 then
                        size = size * gemScale
                        ix = mx - (size * 0.5)
                        iy = my - (size * 0.5)
                    end
                    dl_add_spell_icon_gem(dragDl, State.dragSpell.iconId, ix, iy, size)
                else
                    dl_add_spell_icon(dragDl, State.dragSpell.iconId, ix, iy, size)
                end
            else
                drag_debug_once(State.dragSpell, "draw_state", string.format(
                    "\ay[EQ UI]\ax Drag draw state type=%s kind=%s idx=%s iconId=%s ctrl=%s",
                    tostring(State.dragSpell.type),
                    tostring(State.dragSpell.kind),
                    tostring(State.dragSpell.idx),
                    tostring(State.dragSpell.iconId),
                    tostring(State.dragSpell.ctrlName)))
                local label = drag_payload_label(State.dragSpell)
                if label == "" then
                    label = cursor_name()
                end
                if label == "" then
                    drag_debug_once(State.dragSpell, "draw_empty_label", string.format(
                        "\ay[EQ UI]\ax Drag draw label empty cursor='%s' attach='%s'",
                        tostring(cursor_name()),
                        tostring(cursor_attachment_type())))
                else
                    drag_debug_once(State.dragSpell, "draw_label", string.format(
                        "\ay[EQ UI]\ax Drag draw label='%s'", tostring(label)))
                end
                if label ~= "" then
                    local mx, my = GetMousePosSafe()
                    local w = 64 * scale
                    local h = 28 * scale
                    local bx = mx - (w * 0.5)
                    local by = my - (h * 0.5)
                    dl_add_rect_filled(dragDl, bx, by, bx + w, by + h, 0xAA000000)
                    local line1, line2 = WrapTextTwoLines(label, w - 4)
                    if line2 and line2 ~= "" then
                        local half = h * 0.5
                        dl_add_text_center_scaled(dragDl, bx, by, w, half, 0xFFFFFFFF, line1, 1.0)
                        dl_add_text_center_scaled(dragDl, bx, by + half, w, half, 0xFFFFFFFF, line2, 1.0)
                    else
                        dl_add_text_center_scaled(dragDl, bx, by, w, h, 0xFFFFFFFF, line1, 1.0)
                    end
                end
            end
        end
        ::skip_drag_draw::
    end

        -- Allow spell context menu while in edit mode (click regions are disabled in edit mode).
        if State.editMode and imgui.IsMouseClicked(ImGuiMouseButton.Right) and State.castSpellGemHits then
            for gemIndex, hit in pairs(State.castSpellGemHits) do
                -- Skip gems beyond the character's available count
                if State.numGems and gemIndex > State.numGems then
                    -- Skip this gem
                elseif hit and hit.w and hit.w > 0 and hit.h and hit.h > 0 then
                    if mx >= hit.x and mx <= hit.x + hit.w and my >= hit.y and my <= hit.y + hit.h then
                        local isEmpty = is_empty_gem(gemIndex)
                        State.spellMenu = { gemIndex = gemIndex, input = "", isEmpty = isEmpty }
                        State.spellMenuAnchor = { x = hit.x, y = hit.y, w = hit.w, h = hit.h }
                        State.spellMenuPos = true
                        break
                    end
                end
            end
        end

        -- Spell gem context menu (right click empty gem)
        -- IMPORTANT: Only open/reposition the popup once per right-click. If we call
        -- SetNextWindowPos(..., Always) + OpenPopup() every frame, the popup will
        -- follow the cursor.
        if State.spellMenu and State.spellMenu.gemIndex and State.spellMenuPos then
            local pad = 8 * scale
            local base = State.castSpellWndRect or State.spellMenuAnchor
            local x = (base and (base.x + base.w + pad)) or (mx or 0)
            local y = (State.spellMenuAnchor and State.spellMenuAnchor.y) or (my or 0)

            -- Keep within viewport. If there's no room on the right, prefer left of the spellbar.
            local estW = 280 * scale
            local estH = 460 * scale
            if base and (x + estW) > (vpPos.x + vpSize.x) then
                x = base.x - estW - pad
            end
            x = math.max(vpPos.x, math.min(x, (vpPos.x + vpSize.x) - estW))
            y = math.max(vpPos.y, math.min(y, (vpPos.y + vpSize.y) - estH))

            imgui.SetNextWindowPos(x, y, ImGuiCond.Always)
            imgui.OpenPopup("##SpellGemContext")
            State.spellMenuPos = nil
        end
        do
            local tpl = data.templates and (data.templates["WDT_Def2"] or data.templates["WDT_Def"]) or nil
            local padX, padY = tpl and PopupBorderPadding(tpl.border, scaleAdj) or 6, 6

            -- Make the ImGui popup background transparent so we can draw EQ textures behind it.
            pcall(imgui.PushStyleColor, ImGuiCol.PopupBg, 0, 0, 0, 0)
            imgui.PushStyleVar(ImGuiStyleVar.WindowBorderSize, 0)
            imgui.PushStyleVar(ImGuiStyleVar.WindowPadding, padX, padY)

            if imgui.BeginPopup("##SpellGemContext") then
                local ok, err = pcall(function()
                    local okWinPos, posA, posB = pcall(imgui.GetWindowPos)
                    local okWinSize, sizeA, sizeB = pcall(imgui.GetWindowSize)
                    local wx, wy, ww, wh = 0, 0, 0, 0

                    if okWinPos then
                        if type(posA) == "table" then
                            wx, wy = tonumber(posA.x) or 0, tonumber(posA.y) or 0
                        else
                            wx, wy = tonumber(posA) or 0, tonumber(posB) or 0
                        end
                    end

                    if okWinSize then
                        if type(sizeA) == "table" then
                            ww, wh = tonumber(sizeA.x) or 0, tonumber(sizeA.y) or 0
                        else
                            ww, wh = tonumber(sizeA) or 0, tonumber(sizeB) or 0
                        end
                    end

                    if tpl and okWinPos and okWinSize then
                        local rect = { x = wx, y = wy, w = ww, h = wh }
                        local dl = imgui.GetWindowDrawList()
                        if tpl.background and tpl.background ~= "" then
                            DrawTiledTexture(dl, tpl.background, rect.x, rect.y, rect.w, rect.h, scaleAdj)
                        else
                            dl_add_rect_filled(dl, rect.x, rect.y, rect.x + rect.w, rect.y + rect.h, 0xEE1A1A1A)
                        end
                        if tpl.border then
                            DrawBorder(dl, rect, tpl.border, scaleAdj)
                        end
                    end

                    local gemIndex = State.spellMenu and State.spellMenu.gemIndex
                    local isEmpty = State.spellMenu and State.spellMenu.isEmpty

                    if isEmpty then
                        -- Empty gem - show memorize spell menu
                        imgui.Text("Memorize Spell")
                        imgui.Separator()

                        local scanner = getSpellbookScanner()
                        if scanner then
                            scanner.scan()
                            local btnW, btnH = GetAnimSize("A_BigBtnNormal", scaleAdj)
                            if btnW <= 0 or btnH <= 0 then btnW, btnH = 120 * scale, 24 * scale end
                            if EQTexturedButton("Rescan Spellbook", "A_BigBtnNormal", btnW, btnH, scale, scaleAdj) then
                                scanner.invalidate()
                                scanner.scan()
                            end
                            imgui.Separator()

                            local tab = "combat" -- combat includes all spells
                            local categories = scanner.getCategories(tab)
                            for _, cat in ipairs(categories) do
                                if imgui.BeginMenu(cat) then
                                    local subcats = scanner.getSubcategories(tab, cat)
                                    for _, sub in ipairs(subcats) do
                                        if imgui.BeginMenu(sub) then
                                            local spells = scanner.getSpells(tab, cat, sub)
                                            table.sort(spells, function(a, b)
                                                return (a.name or "") < (b.name or "")
                                            end)
                                            for _, spell in ipairs(spells) do
                                                if imgui.MenuItem(spell.name) then
                                                    local gem = State.spellMenu and State.spellMenu.gemIndex
                                                    if gem then
                                                        mq.cmdf("/memspell %d \"%s\"", gem, spell.name)
                                                    end
                                                    State.spellMenu = nil
                                                    State.spellMenuAnchor = nil
                                                    imgui.CloseCurrentPopup()
                                                end
                                            end
                                            imgui.EndMenu()
                                        end
                                    end
                                    imgui.EndMenu()
                                end
                            end
                        else
                            imgui.TextDisabled("Spellbook scanner unavailable")
                        end

                        imgui.Separator()
                        local btnW, btnH = GetAnimSize("A_BtnNormal", scaleAdj)
                        if btnW <= 0 or btnH <= 0 then btnW, btnH = 96 * scale, 19 * scale end
                        local openClicked = EQTexturedButton("Open Spellbook", "A_BtnNormal", btnW, btnH, scale, scaleAdj, 0xFF000000)
                        imgui.SameLine()
                        local cancelClicked = EQTexturedButton("Cancel", "A_BtnNormal", btnW, btnH, scale, scaleAdj, 0xFF000000)
                        if openClicked then
                            pcall(function() mq.TLO.Window('SpellBookWnd').DoOpen() end)
                            State.spellMenu = nil
                            State.spellMenuAnchor = nil
                            imgui.CloseCurrentPopup()
                        elseif cancelClicked then
                            State.spellMenu = nil
                            State.spellMenuAnchor = nil
                            imgui.CloseCurrentPopup()
                        end
                    else
                        -- Non-empty gem - show spell options
                        local spellName = ""
                        local spellMana = 0
                        local spellCastTime = 0
                        local spellRecastTime = 0
                        local okGem, gemSpell = pcall(function() return mq.TLO.Me.Gem(gemIndex) end)
                        if okGem and gemSpell and gemSpell() then
                            local okName, name = pcall(function() return gemSpell.Name() end)
                            if okName and name then spellName = name end
                            local okMana, mana = pcall(function() return gemSpell.Mana() end)
                            if okMana and mana then spellMana = mana end
                            local okCast, cast = pcall(function() return gemSpell.MyCastTime() end)
                            if okCast and cast then spellCastTime = cast end
                            local okRecast, recast = pcall(function() return gemSpell.RecastTime() end)
                            if okRecast and recast then spellRecastTime = recast end
                        end

                        imgui.Text(string.format("Gem %d: %s", gemIndex, spellName ~= "" and spellName or "Unknown"))
                        if spellMana > 0 or spellCastTime > 0 then
                            imgui.TextDisabled(string.format("Mana: %d  Cast: %.1fs", spellMana, spellCastTime / 1000))
                        end
                        imgui.Separator()

                        local btnW, btnH = GetAnimSize("A_BtnNormal", scaleAdj)
                        if btnW <= 0 or btnH <= 0 then btnW, btnH = 96 * scale, 19 * scale end

                        -- Inspect spell button - uses Spell TLO Inspect method
                        if EQTexturedButton("Inspect", "A_BtnNormal", btnW, btnH, scale, scaleAdj, 0xFF000000) then
                            if spellName ~= "" then
                                pcall(function() mq.TLO.Spell(spellName).Inspect() end)
                            end
                            State.spellMenu = nil
                            State.spellMenuAnchor = nil
                            imgui.CloseCurrentPopup()
                        end

                        -- Clear/Unmemorize button - opens game's native context menu for this gem
                        imgui.SameLine()
                        if EQTexturedButton("Clear", "A_BtnNormal", btnW, btnH, scale, scaleAdj, 0xFF000000) then
                            local idx = gemIndex - 1  -- Game uses 0-indexed spell gems (CSPW_Spell0 = gem 1)
                            local win = mq.TLO.Window('CastSpellWnd')
                            if win and win() ~= nil then
                                local btn = win.Child and win.Child("CSPW_Spell" .. tostring(idx)) or nil
                                if btn and btn() ~= nil then
                                    -- Send right click to open game's context menu which has "Clear" option
                                    pcall(function() btn.RightMouseUp() end)
                                end
                            end
                            State.spellMenu = nil
                            State.spellMenuAnchor = nil
                            imgui.CloseCurrentPopup()
                        end

                        imgui.Separator()

                        -- Memorize different spell submenu
                        imgui.SameLine()
                        if imgui.BeginMenu("Replace...") then
                            local scanner = getSpellbookScanner()
                            if scanner then
                                scanner.scan()
                                local tab = "combat"
                                local categories = scanner.getCategories(tab)
                                for _, cat in ipairs(categories) do
                                    if imgui.BeginMenu(cat) then
                                        local subcats = scanner.getSubcategories(tab, cat)
                                        for _, sub in ipairs(subcats) do
                                            if imgui.BeginMenu(sub) then
                                                local spells = scanner.getSpells(tab, cat, sub)
                                                table.sort(spells, function(a, b)
                                                    return (a.name or "") < (b.name or "")
                                                end)
                                                for _, spell in ipairs(spells) do
                                                    if imgui.MenuItem(spell.name) then
                                                        mq.cmdf("/memspell %d \"%s\"", gemIndex, spell.name)
                                                        State.spellMenu = nil
                                                        State.spellMenuAnchor = nil
                                                        imgui.CloseCurrentPopup()
                                                    end
                                                end
                                                imgui.EndMenu()
                                            end
                                        end
                                        imgui.EndMenu()
                                    end
                                end
                            else
                                imgui.TextDisabled("Spellbook scanner unavailable")
                            end
                            imgui.EndMenu()
                        end

                        imgui.Separator()
                        local cancelClicked = EQTexturedButton("Cancel", "A_BtnNormal", btnW, btnH, scale, scaleAdj, 0xFF000000)
                        if cancelClicked then
                            State.spellMenu = nil
                            State.spellMenuAnchor = nil
                            imgui.CloseCurrentPopup()
                        end
                    end
                end)

                if not ok then
                    print(string.format("\ay[EQ UI]\ax SpellGemContext error: %s", tostring(err)))
                    State.spellMenu = nil
                    State.spellMenuAnchor = nil
                    pcall(imgui.CloseCurrentPopup)
                end
                imgui.EndPopup()
            end

            imgui.PopStyleVar(2)
            pcall(imgui.PopStyleColor, 1)
        end

        if State.editMode and selectedRect and selectedRect.w > 0 and selectedRect.h > 0 then
            dl_add_rect(
                dl,
                selectedRect.x,
                selectedRect.y,
                selectedRect.x + selectedRect.w,
                selectedRect.y + selectedRect.h,
                0xFF0000FF
            )
            if mx >= selectedRect.x and mx <= selectedRect.x + selectedRect.w
                and my >= selectedRect.y and my <= selectedRect.y + selectedRect.h then
                imgui.SetTooltip(selectedLabel or "Selected")
            end
        end

        -- Check if mouse is over any of our rendered overlay screens
        State.mouseOverOverlay = false
        for i = 1, #screenRects do
            local screenName = screenRects[i]
            local info = screenRects[screenName]
            if info and info.rect then
                local rect = info.rect
                if mx >= rect.x and mx <= rect.x + rect.w and my >= rect.y and my <= rect.y + rect.h then
                    State.mouseOverOverlay = true
                    break
                end
            end
        end

        -- Brush (edit mode only)
        State.brushHover = nil
        if State.editMode and State.brushEnabled and hovered and hovered.ctrl and hovered.ctrl.anim then
            local anim = data.anims and data.anims[hovered.ctrl.anim] or nil
            if anim and anim.tex then
                if not State.brushOnlyBorders or IsBorderTexture(anim.tex) then
                    State.brushHover = {
                        anim = anim,
                        texName = anim.tex,
                        rect = hovered,
                    }
                end
            end
        end
        if State.editMode and State.brushEnabled and State.brushHover and imgui.IsMouseDown(ImGuiMouseButton.Left) then
            local rect = State.brushHover.rect
            if rect and rect.w > 0 and rect.h > 0 then
                local u = (mx - rect.x) / rect.w
                local v = (my - rect.y) / rect.h
                if u >= 0 and u <= 1 and v >= 0 and v <= 1 then
                    local anim = State.brushHover.anim
                    local texName = State.brushHover.texName
                    local texX = math.floor(anim.x + (u * anim.w))
                    local texY = math.floor(anim.y + (v * anim.h))
                    local buf = GetBrushBuffer(texName)
                    if buf then
                        local bounds = {
                            x0 = anim.x,
                            y0 = anim.y,
                            x1 = anim.x + anim.w - 1,
                            y1 = anim.y + anim.h - 1,
                        }
                        ApplyBlendBrush(
                            buf,
                            texX,
                            texY,
                            State.brushRadius,
                            State.brushStrength,
                            State.brushAlphaThreshold,
                            State.brushFalloff,
                            bounds
                        )
                        State.brushDirty = true
                    end
                end
            end
            State.brushMouseDown = true
        elseif State.brushMouseDown then
            -- Mouse released or brush disabled: commit changes if any
            if State.brushDirty and State.brushBuffer and State.brushTextureName then
                local savePath = UI_PATH .. State.brushTextureName
                local ok, err = State.brushBuffer:toTGA(savePath)
                if ok then
                    State.brushBuffer:markClean()
                    State.brushDirty = false
                    Textures[State.brushTextureName] = nil
                    print(string.format("\ay[EQ UI]\ax Brush saved: %s", savePath))
                else
                    print(string.format("\ay[EQ UI]\ax Brush save failed: %s", tostring(err)))
                end
            end
            State.brushMouseDown = false
        end

        if State.editMode and not State.brushEnabled and State.dragScreens and not State.dragging and not hovered then
            for i = #screenRects, 1, -1 do
                local screenName = screenRects[i]
                local info = screenRects[screenName]
                if info and info.rect then
                    local rect = info.rect
                    if mx >= rect.x and mx <= rect.x + rect.w and my >= rect.y and my <= rect.y + rect.h then
                        hovered = {
                            key = info.screenKey,
                            x = rect.x, y = rect.y, w = rect.w, h = rect.h,
                            baseX = info.dockBaseX or info.screen.x, baseY = info.screen.y,
                            originX = offsetX, originY = offsetY,
                            scale = scale,
                        }
                        break
                    end
                end
            end
        end

        if State.editMode and not State.brushEnabled then
            if hovered and State.showPieceBounds then
                dl_add_rect(dl, hovered.x, hovered.y, hovered.x + hovered.w, hovered.y + hovered.h, 0xAA00FFFF)
            end

            if imgui.IsMouseClicked(ImGuiMouseButton.Left) and hovered then
                State.selectedKey = hovered.key
                State.dragging = true
                State.dragKey = hovered.key
                State.dragOffsetX = mx - hovered.x
                State.dragOffsetY = my - hovered.y
                State.dragInfo = hovered
                State.dragGroupKeys = nil
                State.dragGroupOffsets = nil
                if IsPieceSelected(hovered.key) then
                    local screenName = ParsePieceKey(hovered.key)
                    if screenName then
                        local groupKeys = SelectedPieceKeys(screenName)
                        if #groupKeys > 1 then
                            State.dragGroupKeys = groupKeys
                            local offsets = {}
                            for i = 1, #groupKeys do
                                local key = groupKeys[i]
                                local off = GetOffset(key)
                                offsets[key] = { x = off.x or 0, y = off.y or 0 }
                            end
                            State.dragGroupOffsets = offsets
                        end
                    end
                end
                if not State.dragGroupKeys and hovered.screenName == "HotButtonWnd" and State.hotbuttonGroupByNumber then
                    local name = (hovered.ctrl and hovered.ctrl.name) or ""
                    local num = tonumber(name:match("(%d+)$"))
                    if not num then
                        local _, pieceName = ParsePieceKey(hovered.key)
                        if pieceName then
                            num = tonumber(pieceName:match("(%d+)$"))
                        end
                    end
                    if num then
                        local groupKeys = HotbuttonGroupKeys("HotButtonWnd", num)
                        if #groupKeys > 1 then
                            State.dragGroupKeys = groupKeys
                            local offsets = {}
                            for i = 1, #groupKeys do
                                local key = groupKeys[i]
                                local off = GetOffset(key)
                                offsets[key] = { x = off.x or 0, y = off.y or 0 }
                            end
                            State.dragGroupOffsets = offsets
                        end
                    end
                end
            end

            if State.dragging and State.dragKey and imgui.IsMouseDown(ImGuiMouseButton.Left) and State.dragInfo then
                local info = State.dragInfo
                local off = GetOffset(info.key)
                local newOffX = ((mx - info.originX - State.dragOffsetX) / info.scale) - info.baseX
                local newOffY = ((my - info.originY - State.dragOffsetY) / info.scale) - info.baseY
                local newX = math.floor(newOffX + 0.5)
                local newY = math.floor(newOffY + 0.5)
                if State.dragGroupKeys and State.dragGroupOffsets then
                    local start = State.dragGroupOffsets[info.key] or { x = off.x or 0, y = off.y or 0 }
                    local dx = newX - (tonumber(start.x) or 0)
                    local dy = newY - (tonumber(start.y) or 0)
                    for i = 1, #State.dragGroupKeys do
                        local key = State.dragGroupKeys[i]
                        local base = State.dragGroupOffsets[key]
                        if base then
                            State.offsets[key] = {
                                x = (tonumber(base.x) or 0) + dx,
                                y = (tonumber(base.y) or 0) + dy,
                            }
                        end
                    end
                else
                    off.x = newX
                    off.y = newY
                end
            elseif State.dragging and not imgui.IsMouseDown(ImGuiMouseButton.Left) then
                State.dragging = false
                State.dragKey = nil
                State.dragInfo = nil
                State.dragGroupKeys = nil
                State.dragGroupOffsets = nil
            end
        end

    end

    imgui.End()
    imgui.PopStyleVar(2)

    RenderSettings(viewport)
    RenderClickRegions()

    -- Render cursor item only when mouse is over our interactive click regions
    -- (when outside our UI, the game renders the cursor item itself)
    -- Use foreground draw list to ensure it renders on top of everything
    if State.open and State.drawCursorMirror and not State.editMode and State.mouseOverClickRegion then
        local dl = imgui.GetForegroundDrawList()
        if dl then
            local mx, my = imgui.GetMousePos()
            local vpSize = viewport.Size
            local scale = (State.scaleOverride and State.scaleOverride > 0 and State.scaleOverride)
                or (vpSize.y / data.base.h)

            local cursorItem = mq.TLO.Cursor
            local cursorIcon = 0
            if cursorItem and cursorItem() then
                cursorIcon = cursorItem.Icon and cursorItem.Icon() or 0
            end
            if cursorIcon and cursorIcon > 0 then
                local cursorSize = 40 * scale
                local cx = mx - cursorSize * 0.5
                local cy = my - cursorSize * 0.5
                dl_add_item_icon(dl, cursorIcon, cx, cy, cursorSize)
            else
                local label = cursor_name()
                if label ~= "" then
                    local w = 64 * scale
                    local h = 28 * scale
                    local bx = mx - (w * 0.5)
                    local by = my - (h * 0.5)
                    dl_add_rect_filled(dl, bx, by, bx + w, by + h, 0xAA000000)
                    local line1, line2 = WrapTextTwoLines(label, w - 4)
                    if line2 and line2 ~= "" then
                        local half = h * 0.5
                        dl_add_text_center_scaled(dl, bx, by, w, half, 0xFFFFFFFF, line1, 1.0)
                        dl_add_text_center_scaled(dl, bx, by + half, w, half, 0xFFFFFFFF, line2, 1.0)
                    else
                        dl_add_text_center_scaled(dl, bx, by, w, h, 0xFFFFFFFF, line1, 1.0)
                    end
                end
            end
        end
    end

    -- Restore original font scale
    if fontScale ~= 1.0 then
        imgui.PopFont()
    end
end

LoadOffsets()
State.editMode = false
ClearAllSelection()

mq.imgui.init('EQUIRebuildOverlay', RenderUI)

mq.bind('/equibuild', function()
    State.open = not State.open
    print(string.format("\ay[EQ UI]\ax Rebuild overlay %s", State.open and "shown" or "hidden"))
end)

mq.bind('/equibuildsettings', function()
    State.showSettings = not State.showSettings
end)

mq.bind('/equigem', function(line)
    local idx = tonumber(line)
    if not idx or idx <= 0 then
        print("\ay[EQ UI]\ax Usage: /equigem <index> (1-based)")
        return
    end
    local sp = mq.TLO.Me.Gem(idx)
    if not sp or not sp() then
        print(string.format("\ay[EQ UI]\ax Gem %d: <empty>", idx))
        return
    end
    local name = ""
    local icon = 0
    local gemIcon = 0
    local okName, n = pcall(function() return sp.Name end)
    if okName and n ~= nil then
        if type(n) == "function" then
            local okCall, v = pcall(n)
            if okCall then n = v end
        end
        name = tostring(n)
    else
        local okCall, v = pcall(function() return sp.Name() end)
        if okCall and v ~= nil then name = tostring(v) end
    end
    local okIcon, i = pcall(function() return sp.SpellIcon end)
    if okIcon and i ~= nil then
        if type(i) == "function" then
            local okCall, v = pcall(i)
            if okCall then i = v end
        end
        icon = tonumber(i) or tonumber(tostring(i)) or 0
    else
        local okCall, v = pcall(function() return sp.SpellIcon() end)
        if okCall and v ~= nil then icon = tonumber(v) or tonumber(tostring(v)) or 0 end
    end
    if sp.GemIcon then
        local okGem, gi = pcall(function() return sp.GemIcon end)
        if okGem and gi ~= nil then
            if type(gi) == "function" then
                local okCall, v = pcall(gi)
                if okCall then gi = v end
            end
            gemIcon = tonumber(gi) or tonumber(tostring(gi)) or 0
        else
            local okCall, v = pcall(function() return sp.GemIcon() end)
            if okCall and v ~= nil then gemIcon = tonumber(v) or tonumber(tostring(v)) or 0 end
        end
    end
    print(string.format("\ay[EQ UI]\ax Gem %d: %s SpellIcon=%s GemIcon=%s", idx, name ~= "" and name or "<unnamed>", tostring(icon), tostring(gemIcon)))
end)

print("\ay[EQ UI]\ax Rebuild overlay loaded. Commands: /equibuild, /equibuildsettings")

while State.open or mq.TLO.MacroQuest.GameState() == "INGAME" do
    ProcessPendingCursorChecks()
    if State.pendingAbBuff then
        State.pendingAbBuff = false
        mq.cmd('/ab buff')
    end
    if State.autoSavePending then
        local now = os.clock()
        local delay = tonumber(State.autoSaveDelay) or 0
        if delay <= 0 or (now - (State.autoSaveLastChange or 0)) >= delay then
            State.autoSavePending = false
            SaveOffsets()
        end
    end
    mq.delay(100)
end
