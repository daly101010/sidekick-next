-- ============================================================
-- SideKick Texture Mappings
-- ============================================================
-- Maps UI component types to EQ texture animation names.
-- Used by texture_renderer.lua and themed components.
--
-- Usage:
--   local Mappings = require('sidekick-next.ui.texture_mappings')
--   local fillAnim = Mappings.GAUGE.health.fill

local M = {}

-- ============================================================
-- GAUGE TEXTURES
-- ============================================================

-- Classic EQ gauge components
-- Background: Dark recessed area
-- Fill: Colored fill bar (varies by gauge type)
-- Lines: Tick mark overlay
-- EndCaps: Left and right decorative ends

M.GAUGE = {
    health = {
        bg      = 'A_Classic_GaugeBackground',
        fill    = 'A_Classic_GaugeFill',
        lines   = 'A_Classic_GaugeLines',
        leftCap = 'A_Classic_GaugeEndCapLeft',
        rightCap= 'A_Classic_GaugeEndCapRight',
    },
    mana = {
        bg      = 'A_Classic_GaugeBackground',
        fill    = 'A_Classic_GaugeFill2',
        lines   = 'A_Classic_GaugeLines',
        leftCap = 'A_Classic_GaugeEndCapLeft',
        rightCap= 'A_Classic_GaugeEndCapRight',
    },
    endurance = {
        bg      = 'A_Classic_GaugeBackground',
        fill    = 'A_Classic_GaugeFill3',
        lines   = 'A_Classic_GaugeLines',
        leftCap = 'A_Classic_GaugeEndCapLeft',
        rightCap= 'A_Classic_GaugeEndCapRight',
    },
    cooldown = {
        bg      = 'A_Classic_GaugeBackground',
        fill    = 'A_Classic_GaugeFill4',
        lines   = 'A_Classic_GaugeLines',
        leftCap = 'A_Classic_GaugeEndCapLeft',
        rightCap= 'A_Classic_GaugeEndCapRight',
    },
    experience = {
        bg      = 'A_Classic_GaugeBackground',
        fill    = 'A_Classic_GaugeFill5',
        lines   = 'A_Classic_GaugeLines',
        leftCap = 'A_Classic_GaugeEndCapLeft',
        rightCap= 'A_Classic_GaugeEndCapRight',
    },
    aggro = {
        bg      = 'A_Classic_GaugeBackground',
        fill    = 'A_Classic_GaugeFill6',
        lines   = 'A_Classic_GaugeLines',
        leftCap = 'A_Classic_GaugeEndCapLeft',
        rightCap= 'A_Classic_GaugeEndCapRight',
    },
    pet = {
        bg      = 'A_Classic_GaugeBackground',
        fill    = 'A_Classic_PetGaugeFill',
        lines   = 'A_Classic_GaugeLines',
        leftCap = 'A_Classic_GaugeEndCapLeft',
        rightCap= 'A_Classic_GaugeEndCapRight',
    },
}

-- ============================================================
-- BUTTON TEXTURES
-- ============================================================

-- Button states: normal, hover (flyby), pressed, disabled
-- Sizes: std (96x19), big (120x24), small (48x19)

M.BUTTON = {
    normal = {
        std   = 'A_BtnNormal',
        big   = 'A_BigBtnNormal',
        small = 'A_SmallBtnNormal',
    },
    hover = {
        std   = 'A_BtnFlyby',
        big   = 'A_BigBtnFlyby',
        small = 'A_SmallBtnFlyby',
    },
    pressed = {
        std   = 'A_BtnPressed',
        big   = 'A_BigBtnPressed',
        small = 'A_SmallBtnPressed',
    },
    pressedHover = {
        std   = 'A_BtnPressedFlyby',
        big   = 'A_BigBtnPressedFlyby',
        small = 'A_SmallBtnPressedFlyby',
    },
    disabled = {
        std   = 'A_BtnDisabled',
        big   = 'A_BigBtnDisabled',
        small = 'A_SmallBtnDisabled',
    },
}

-- Button dimensions for each size
M.BUTTON_SIZES = {
    std   = { w = 96,  h = 19 },
    big   = { w = 120, h = 24 },
    small = { w = 48,  h = 19 },
}

-- ============================================================
-- WINDOW BORDER TEXTURES
-- ============================================================

-- Classic EQ window frame pieces

M.WINDOW_BORDER = {
    topLeft     = 'A_ClassicTopLeft',
    top         = 'A_ClassicTop',
    topRight    = 'A_ClassicTopRight',
    left        = 'A_ClassicLeft',
    right       = 'A_ClassicRight',
    bottomLeft  = 'A_ClassicBottomLeft',
    bottom      = 'A_ClassicBottom',
    bottomRight = 'A_ClassicBottomRight',
}

-- ============================================================
-- ICON/SLOT TEXTURES
-- ============================================================

-- Inventory slot backgrounds

M.SLOT = {
    normal = 'A_InvSlotNormal',
    hover  = 'A_InvSlotHover',
    active = 'A_InvSlotActive',
}

-- ============================================================
-- CHECKBOX TEXTURES
-- ============================================================

M.CHECKBOX = {
    unchecked = 'A_CheckBoxNormal',
    checked   = 'A_CheckBoxPressed',
    hover     = 'A_CheckBoxFlyby',
}

-- ============================================================
-- SCROLLBAR TEXTURES
-- ============================================================

M.SCROLLBAR = {
    track    = 'A_ScrollbarTrack',
    thumb    = 'A_ScrollbarThumb',
    upBtn    = 'A_ScrollbarUpNormal',
    upHover  = 'A_ScrollbarUpFlyby',
    upPressed= 'A_ScrollbarUpPressed',
    downBtn  = 'A_ScrollbarDownNormal',
    downHover= 'A_ScrollbarDownFlyby',
    downPressed = 'A_ScrollbarDownPressed',
}

-- ============================================================
-- TITLEBAR TEXTURES
-- ============================================================

M.TITLEBAR = {
    closeNormal   = 'A_CloseBoxNormal',
    closeHover    = 'A_CloseBoxFlyby',
    closePressed  = 'A_CloseBoxPressed',
    minNormal     = 'A_MinimizeBoxNormal',
    minHover      = 'A_MinimizeBoxFlyby',
    minPressed    = 'A_MinimizeBoxPressed',
    lockNormal    = 'A_LockBoxNormal',
    lockHover     = 'A_LockBoxFlyby',
    lockPressed   = 'A_LockBoxPressed',
}

-- ============================================================
-- HELPER FUNCTIONS
-- ============================================================

-- Get animation name for a gauge type and part
function M.getGaugeAnim(gaugeType, part)
    local gauge = M.GAUGE[gaugeType] or M.GAUGE.health
    return gauge[part]
end

-- Get animation name for a button state and size
function M.getButtonAnim(state, size)
    local stateMap = M.BUTTON[state] or M.BUTTON.normal
    return stateMap[size] or stateMap.std
end

-- Get best button size based on dimensions
function M.getBestButtonSize(width, height)
    if width >= 100 then return 'big' end
    if width <= 60 then return 'small' end
    return 'std'
end

-- Get gauge type from resource type name
function M.gaugeTypeFromResource(resourceType)
    local mapping = {
        hp = 'health',
        health = 'health',
        mana = 'mana',
        mp = 'mana',
        endurance = 'endurance',
        end_ = 'endurance',
        exp = 'experience',
        xp = 'experience',
        experience = 'experience',
        aggro = 'aggro',
        threat = 'aggro',
        cooldown = 'cooldown',
        reuse = 'cooldown',
        pet = 'pet',
    }
    return mapping[string.lower(resourceType or '')] or 'health'
end

return M
