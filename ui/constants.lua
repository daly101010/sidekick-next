-- ============================================================
-- SideKick UI Constants
-- ============================================================
-- Centralized constants for animation timing, layout defaults,
-- cooldown thresholds, and resource warnings.
--
-- Usage:
--   local C = require('sidekick-next.ui.constants')
--   local stiffness = C.ANIMATION.SPRING_STIFFNESS
--   local rounding = C.LAYOUT.DEFAULT_ROUNDING

local M = {}

-- ============================================================
-- ANIMATION TIMING
-- ============================================================

M.ANIMATION = {
    -- Spring physics parameters (tuned for snappier feel)
    SPRING_STIFFNESS = 450,       -- Tighter springs (was 400)
    SPRING_DAMPING = 28,          -- Slightly more damped (was 25)
    SPRING_STIFFNESS_FAST = 600,  -- Faster response (was 500)
    SPRING_DAMPING_FAST = 22,     -- (was 20)
    SPRING_STIFFNESS_SLOW = 300,
    SPRING_DAMPING_SLOW = 30,

    -- Tween durations (seconds)
    TWEEN_FAST = 0.12,            -- Snappier (was 0.15)
    TWEEN_NORMAL = 0.22,          -- Slightly faster (was 0.25)
    TWEEN_SLOW = 0.35,            -- (was 0.4)

    -- Button scaling (more noticeable feedback)
    HOVER_SCALE = 1.08,           -- More visible (was 1.05)
    PRESS_SCALE = 0.92,           -- More visible (was 0.95)
    TOGGLE_POP_SCALE = 1.18,      -- Punchier (was 1.15)

    -- Pulse/glow frequencies (Hz)
    READY_PULSE_FREQ = 2.5,       -- Faster pulse (was 2.0)
    LOW_RESOURCE_PULSE_FREQ_MIN = 1.5,
    LOW_RESOURCE_PULSE_FREQ_MAX = 4.0,  -- More urgent at low (was 3.5)

    -- Shake parameters
    SHAKE_MAGNITUDE = 4,          -- Slightly more visible (was 3)
    SHAKE_DECAY = 0.22,           -- Faster decay (was 0.25)

    -- Damage flash duration (seconds)
    DAMAGE_FLASH_DURATION = 0.25, -- Quicker flash (was 0.3)

    -- Stagger animation delay per item (seconds)
    STAGGER_DELAY = 0.04,         -- Slightly faster cascade (was 0.05)
    STAGGER_DURATION = 0.45,      -- (was 0.5)
}

-- ============================================================
-- UI LAYOUT DEFAULTS
-- ============================================================

M.LAYOUT = {
    -- Window styling
    DEFAULT_ROUNDING = 6,
    DEFAULT_GAP = 4,
    DEFAULT_PADDING = 6,
    DEFAULT_BG_ALPHA = 0.85,

    -- Anchor system
    MAX_ANCHOR_GAP = 48,  -- Increased from 24
    DEFAULT_ANCHOR_GAP = 2,

    -- Bar defaults
    DEFAULT_CELL_SIZE = 48,
    DEFAULT_ROWS = 2,
    MIN_CELL_SIZE = 32,
    MAX_CELL_SIZE = 120,
    MAX_ROWS = 6,

    -- Special bar
    SPECIAL_CELL_SIZE = 65,
    SPECIAL_ROWS = 1,

    -- Item bar
    ITEM_CELL_SIZE = 40,
    ITEM_ROWS = 1,

    -- Icon sizes
    ICON_SIZE_SMALL = 32,
    ICON_SIZE_NORMAL = 48,
    ICON_SIZE_LARGE = 64,
}

-- ============================================================
-- COOLDOWN THRESHOLDS
-- ============================================================

M.COOLDOWN = {
    -- Color transition thresholds (percentage of total cooldown remaining)
    RED_THRESHOLD = 0.66,      -- > 66% remaining = red
    ORANGE_THRESHOLD = 0.33,   -- > 33% remaining = orange
    YELLOW_THRESHOLD = 0.10,   -- > 10% remaining = yellow
    -- <= 10% = green (ready soon)

    -- Ready state glow parameters
    READY_GLOW_MIN = 0.4,
    READY_GLOW_MAX = 0.85,         -- Slightly brighter peak (was 0.8)
    READY_GLOW_FREQ = 2.5,         -- Synced with READY_PULSE_FREQ (was 2.0)
}

-- ============================================================
-- RESOURCE WARNING THRESHOLDS
-- ============================================================

M.RESOURCE = {
    -- Low resource warning threshold (percentage)
    LOW_THRESHOLD = 0.20,  -- 20%

    -- Emergency threshold (percentage)
    EMERGENCY_THRESHOLD = 0.10,  -- 10%

    -- Damage flash threshold (HP drop percentage)
    DAMAGE_FLASH_THRESHOLD = 5,  -- 5% HP drop
}

-- ============================================================
-- COLORS (raw values, use ui/colors.lua for theme-aware colors)
-- ============================================================

M.COLORS = {
    -- Cooldown overlay colors (0-1 floats)
    COOLDOWN_RED = { 1.0, 0.4, 0.4 },
    COOLDOWN_ORANGE = { 1.0, 0.7, 0.3 },
    COOLDOWN_YELLOW = { 1.0, 1.0, 0.4 },
    COOLDOWN_GREEN = { 0.4, 1.0, 0.4 },

    -- Ready glow
    READY_GLOW = { 80, 200, 255 },  -- RGB 0-255

    -- Warning colors
    LOW_RESOURCE_WARNING = { 1.0, 0.2, 0.2 },
    DAMAGE_FLASH = { 1.0, 0.0, 0.0 },

    -- Toggle states (0-1 floats)
    TOGGLE_ON = { 0.3, 0.8, 0.3, 1.0 },
    TOGGLE_OFF = { 0.5, 0.5, 0.5, 1.0 },

    -- Overlay alphas (0-255)
    COOLDOWN_OVERLAY_ALPHA = 110,
    COOLDOWN_FILL_ALPHA = 140,
    COOLDOWN_BORDER_ALPHA = 200,
    READY_GLOW_ALPHA_MAX = 80,
}

-- ============================================================
-- ANCHOR MODES
-- ============================================================

M.ANCHOR_MODES = {
    'none',
    'left',
    'right',
    'above',
    'below',
    'left_bottom',
    'right_bottom',
}

-- ============================================================
-- ANCHOR TARGETS
-- ============================================================

M.ANCHOR_TARGETS = {
    { key = 'grouptarget', label = 'GroupTarget' },
    { key = 'sidekick_main', label = 'SideKick Main' },
    { key = 'sidekick_bar', label = 'SideKick Ability Bar' },
    { key = 'sidekick_special', label = 'SideKick Special Bar' },
    { key = 'sidekick_disc', label = 'SideKick Disc Bar' },
    { key = 'sidekick_items', label = 'SideKick Item Bar' },
}

return M
