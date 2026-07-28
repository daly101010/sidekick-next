local M = {}

-- Keys deliberately retired from both the active registry and compatibility
-- passthrough. Keeping the tombstones here prevents old combined/module INIs
-- from resurrecting no-op options as dynamic settings.
M.removed = {
    AssistEnabled = true,
    AssistEngageHpThreshold = true,
    AuraSelection = true,
    AutoStandFD = true,
    BuffAllowInCombat = true,
    BuffCoordinateActors = true,
    BuffFellowshipEnabled = true,
    BuffGroupEnabled = true,
    BuffRaidEnabled = true,
    BuffRebuffWindow = true,
    BuffSelfOnly = true,
    BurnNow = true,
    CooldownSweepEnabled = true,
    DoCombatRez = true,
    DoOutOfCombatRez = true,
    EmergencyHealPct = true,
    LowResourceThreshold = true,
    MAScanZRange = true,
    ResourceAllowCombat = true,
    ResourceHpAbovePctCombat = true,
    ResourceHpAbovePctOOC = true,
    ResourceManaBelowPct = true,
    SpecialEnabled = true,
    SpellRotationEnabled = true,

    TravelBrokerEnabled = true,
    Humanize_RestickAfterMs = true,
    Humanize_FW_face_spawn = true,
    DebuffAutoSlow = true,
    DebuffAutoCripple = true,
    DebuffAutoMalo = true,
    DebuffCoordinateActors = true,
    DebuffPrioritizeSelfHeal = true,
    DebuffSelfHealHpThreshold = true,
    DebuffGroupHealHpThreshold = true,
    CCEnabled = true,
    CCCoordinateActors = true,
    CCPrioritizeSelfHeal = true,
    CCSelfHealHpThreshold = true,
    CCMaxMezTargets = true,
    BuffPetsEnabled = true,
    CureCoordinateActors = true,
    DoCharm = true,
    CasterUseStick = true,
    CasterEscapeRange = true,
    CasterSafeZoneRadius = true,
}

M.defaults = {
    SideKickTheme = { type = 'text', Default = 'Classic', Category = 'UI', DisplayName = 'Theme' },
    SideKickSyncThemeWithGT = { type = 'bool', Default = true, Category = 'UI', DisplayName = 'Sync Theme With GroupTarget' },
    SideKickDebugSettings = { type = 'bool', Default = false, Category = 'UI', DisplayName = 'Debug Settings Logging' },
    SideKickLogLevel = { type = 'number', Default = 3, Min = 1, Max = 5, Category = 'Diagnostics', DisplayName = 'Log Level' },
    SideKickLogFile = { type = 'bool', Default = false, Category = 'Diagnostics', DisplayName = 'Write General Log File' },
    SideKickLogFilter = { type = 'text', Default = '', Category = 'Diagnostics', DisplayName = 'Log Filter' },
    SideKickModuleLogLevels = { type = 'text', Default = '', Category = 'Diagnostics', DisplayName = 'Per-Module Log Levels' },
    DashboardVisible = { type = 'bool', Default = false, Category = 'UI', DisplayName = 'Dashboard Visible' },
    HealPreviewVisible = { type = 'bool', Default = false, Category = 'UI', DisplayName = 'Heal Preview Visible' },
    SideKickMainEnabled = { type = 'bool', Default = false, Category = 'UI', DisplayName = 'Show Main Bar' },
    SideKickOptionsManual = { type = 'bool', Default = true, Category = 'UI', DisplayName = 'Options Window Manual Move/Resize' },
    SideKickOptionsPosX = { type = 'number', Default = -1, Category = 'UI', DisplayName = 'Options Window X' },
    SideKickOptionsPosY = { type = 'number', Default = -1, Category = 'UI', DisplayName = 'Options Window Y' },
    SideKickOptionsWidth = { type = 'number', Default = 0, Category = 'UI', DisplayName = 'Options Window Width' },
    SideKickOptionsHeight = { type = 'number', Default = 0, Category = 'UI', DisplayName = 'Options Window Height' },
    SideKickMainAnchor = { type = 'text', Default = 'none', Category = 'UI', DisplayName = 'Main Anchor (GroupTarget)' },
    SideKickMainAnchorTarget = { type = 'text', Default = 'grouptarget', Category = 'UI', DisplayName = 'Main Anchor Target' },
    SideKickMainAnchorGap = { type = 'number', Default = 2, Category = 'UI', DisplayName = 'Main Anchor Gap' },
    SideKickMainButtonScale = { type = 'number', Default = 1.0, Category = 'UI', DisplayName = 'Main Button Scale' },
    SideKickMainRounding = { type = 'number', Default = 6, Category = 'UI', DisplayName = 'Main Window Rounding' },
    SideKickMainWidth = { type = 'number', Default = 0, Category = 'UI', DisplayName = 'Main Width Override' },
    SideKickMainShowBorder = { type = 'bool', Default = true, Category = 'UI', DisplayName = 'Main Gold Border' },
    SideKickFontScale = { type = 'number', Default = 1.0, Category = 'UI', DisplayName = 'Font Scale' },
    SideKickMainTextureTint = { type = 'text', Default = '1.0,1.0,1.0', Category = 'UI', DisplayName = 'Main Bar Texture Tint' },
    SideKickMainBgStyle = { type = 'text', Default = 'lightrock', Category = 'UI', DisplayName = 'Main Bar Background Style' },
    SideKickMainBgTexture = { type = 'text', Default = 'A_Listbox_Background1', Category = 'UI', DisplayName = 'Main Bar Background Texture' },
    SideKickMainBgTile = { type = 'bool', Default = true, Category = 'UI', DisplayName = 'Main Bar Background Tile' },
    SideKickLaunchGroup = { type = 'bool', Default = true, Category = 'Integration', DisplayName = 'Launch GroupTarget' },
    AutostartPromptShown = { type = 'bool', Default = false, Category = 'Integration', DisplayName = 'Autostart Prompt Shown' },
    SideKickButtonsSubtab = { type = 'text', Default = 'aas', Category = 'UI', DisplayName = 'Buttons Subtab' },

    SideKickBarEnabled = { type = 'bool', Default = true, Category = 'Bar', DisplayName = 'Show Ability Bar' },
    SideKickBarCell = { type = 'number', Default = 48, Category = 'Bar', DisplayName = 'Cell Size' },
    SideKickBarRows = { type = 'number', Default = 2, Category = 'Bar', DisplayName = 'Rows' },
    SideKickBarGap = { type = 'number', Default = 4, Category = 'Bar', DisplayName = 'Gap' },
    SideKickBarPad = { type = 'number', Default = 6, Category = 'Bar', DisplayName = 'Padding' },
    SideKickBarBgAlpha = { type = 'number', Default = 0.85, Category = 'Bar', DisplayName = 'Background Alpha' },
    SideKickBarWidth = { type = 'number', Default = 0, Category = 'Bar', DisplayName = 'Width Override' },
    SideKickBarShowBorder = { type = 'bool', Default = true, Category = 'Bar', DisplayName = 'Show Gold Border' },
    SideKickBarAnchorTarget = { type = 'text', Default = 'grouptarget', Category = 'Bar', DisplayName = 'Anchor Target' },
    SideKickBarAnchor = { type = 'text', Default = 'none', Category = 'Bar', DisplayName = 'Anchor Mode' },
    SideKickBarAnchorGap = { type = 'number', Default = 2, Category = 'Bar', DisplayName = 'Anchor Gap' },
    SideKickBarTextureTint = { type = 'text', Default = '1.0,1.0,1.0', Category = 'Bar', DisplayName = 'Bar Texture Tint' },

    SideKickSpecialEnabled = { type = 'bool', Default = true, Category = 'Special', DisplayName = 'Show Special Abilities' },
    SideKickSpecialForceSingleRow = { type = 'bool', Default = false, Category = 'Special', DisplayName = 'Specials: Force Single Row' },
    SideKickSpecialForceSingleColumn = { type = 'bool', Default = false, Category = 'Special', DisplayName = 'Specials: Force Single Column' },
    SideKickSpecialPerButtonMove = { type = 'bool', Default = false, Category = 'Special', DisplayName = 'Specials: Per-Button Move' },
    SideKickSpecialCell = { type = 'number', Default = 65, Category = 'Special', DisplayName = 'Cell Size' },
    SideKickSpecialRows = { type = 'number', Default = 1, Category = 'Special', DisplayName = 'Rows' },
    SideKickSpecialGap = { type = 'number', Default = 4, Category = 'Special', DisplayName = 'Gap' },
    SideKickSpecialPad = { type = 'number', Default = 6, Category = 'Special', DisplayName = 'Padding' },
    SideKickSpecialBgAlpha = { type = 'number', Default = 0.85, Category = 'Special', DisplayName = 'Background Alpha' },
    SideKickSpecialWidth = { type = 'number', Default = 0, Category = 'Special', DisplayName = 'Width Override' },
    SideKickSpecialShowBorder = { type = 'bool', Default = true, Category = 'Special', DisplayName = 'Show Gold Border' },
    SideKickSpecialAnchorTarget = { type = 'text', Default = 'grouptarget', Category = 'Special', DisplayName = 'Anchor Target' },
    SideKickSpecialAnchor = { type = 'text', Default = 'none', Category = 'Special', DisplayName = 'Anchor Mode' },
    SideKickSpecialAnchorGap = { type = 'number', Default = 2, Category = 'Special', DisplayName = 'Anchor Gap' },
    SideKickSpecialTextureTint = { type = 'text', Default = '1.0,1.0,1.0', Category = 'Special', DisplayName = 'Special Bar Texture Tint' },

    SideKickDiscBarEnabled = { type = 'bool', Default = true, Category = 'Disciplines', DisplayName = 'Show Disciplines Bar' },
    SideKickDiscBarCell = { type = 'number', Default = 48, Category = 'Disciplines', DisplayName = 'Bar Cell Size' },
    SideKickDiscBarRows = { type = 'number', Default = 2, Category = 'Disciplines', DisplayName = 'Bar Rows' },
    SideKickDiscBarGap = { type = 'number', Default = 4, Category = 'Disciplines', DisplayName = 'Bar Gap' },
    SideKickDiscBarPad = { type = 'number', Default = 6, Category = 'Disciplines', DisplayName = 'Bar Padding' },
    SideKickDiscBarBgAlpha = { type = 'number', Default = 0.85, Category = 'Disciplines', DisplayName = 'Bar Background Alpha' },
    SideKickDiscBarWidth = { type = 'number', Default = 0, Category = 'Disciplines', DisplayName = 'Bar Width Override' },
    SideKickDiscBarShowBorder = { type = 'bool', Default = true, Category = 'Disciplines', DisplayName = 'Show Gold Border' },
    SideKickDiscBarAnchorTarget = { type = 'text', Default = 'grouptarget', Category = 'Disciplines', DisplayName = 'Bar Anchor Target' },
    SideKickDiscBarAnchor = { type = 'text', Default = 'none', Category = 'Disciplines', DisplayName = 'Bar Anchor Mode' },
    SideKickDiscBarAnchorGap = { type = 'number', Default = 2, Category = 'Disciplines', DisplayName = 'Bar Anchor Gap' },
    SideKickDiscBarTextureTint = { type = 'text', Default = '1.0,1.0,1.0', Category = 'Disciplines', DisplayName = 'Disc Bar Texture Tint' },

    BandolierEnabled = { type = 'bool', Default = false, Category = 'Items', DisplayName = 'Bandolier Swapping' },
    SideKickItemBarEnabled = { type = 'bool', Default = true, Category = 'Items', DisplayName = 'Show Item Bar' },
    SideKickItemBarCell = { type = 'number', Default = 40, Category = 'Items', DisplayName = 'Cell Size' },
    SideKickItemBarRows = { type = 'number', Default = 1, Category = 'Items', DisplayName = 'Rows' },
    SideKickItemBarGap = { type = 'number', Default = 4, Category = 'Items', DisplayName = 'Gap' },
    SideKickItemBarPad = { type = 'number', Default = 6, Category = 'Items', DisplayName = 'Padding' },
    SideKickItemBarBgAlpha = { type = 'number', Default = 0.85, Category = 'Items', DisplayName = 'Background Alpha' },
    SideKickItemBarWidth = { type = 'number', Default = 0, Category = 'Items', DisplayName = 'Width Override' },
    SideKickItemBarAnchorTarget = { type = 'text', Default = 'grouptarget', Category = 'Items', DisplayName = 'Anchor Target' },
    SideKickItemBarAnchor = { type = 'text', Default = 'none', Category = 'Items', DisplayName = 'Anchor Mode' },
    SideKickItemBarAnchorGap = { type = 'number', Default = 2, Category = 'Items', DisplayName = 'Anchor Gap' },
    SideKickItemBarTextureTint = { type = 'text', Default = '1.0,1.0,1.0', Category = 'Items', DisplayName = 'Item Bar Texture Tint' },

    SideKickSkillBarEnabled = { type = 'bool', Default = true, Category = 'Bar', DisplayName = 'Show Skills Bar' },
    SideKickSkillBarCell = { type = 'number', Default = 48, Category = 'Bar', DisplayName = 'Skills Bar Cell Size' },
    SideKickSkillBarRows = { type = 'number', Default = 2, Category = 'Bar', DisplayName = 'Skills Bar Rows' },
    SideKickSkillBarGap = { type = 'number', Default = 4, Category = 'Bar', DisplayName = 'Skills Bar Gap' },
    SideKickSkillBarPad = { type = 'number', Default = 6, Category = 'Bar', DisplayName = 'Skills Bar Padding' },
    SideKickSkillBarBgAlpha = { type = 'number', Default = 0.85, Category = 'Bar', DisplayName = 'Skills Bar Background Alpha' },
    SideKickSkillBarWidth = { type = 'number', Default = 0, Category = 'Bar', DisplayName = 'Skills Bar Width Override' },
    SideKickSkillBarAnchorTarget = { type = 'text', Default = 'none', Category = 'Bar', DisplayName = 'Skills Bar Anchor Target' },
    SideKickSkillBarAnchor = { type = 'text', Default = 'none', Category = 'Bar', DisplayName = 'Skills Bar Anchor Mode' },
    SideKickSkillBarAnchorGap = { type = 'number', Default = 2, Category = 'Bar', DisplayName = 'Skills Bar Anchor Gap' },
    SideKickSkillBarShowBorder = { type = 'bool', Default = true, Category = 'Bar', DisplayName = 'Skills Bar Gold Border' },
    SideKickSkillBarTextureTint = { type = 'text', Default = '1.0,1.0,1.0', Category = 'Bar', DisplayName = 'Skills Bar Texture Tint' },
    SideKickBERDiscDefaultsApplied = { type = 'bool', Default = false, Category = 'Disciplines', DisplayName = 'Berserker Defaults Applied', Internal = true },

    ChaseEnabled = { type = 'bool', Default = false, Category = 'Automation', DisplayName = 'Chase Enabled' },
    ChaseRole = { type = 'text', Default = 'ma', Category = 'Automation', DisplayName = 'Chase Role (none/ma/mt/leader/raid1/raid2/raid3/byname)', Options = { 'none', 'ma', 'mt', 'leader', 'raid1', 'raid2', 'raid3', 'byname' } },
    ChaseTarget = { type = 'text', Default = '', Category = 'Automation', DisplayName = 'Chase Target (name)' },
    ChaseDistance = { type = 'number', Default = 30, Category = 'Automation', DisplayName = 'Chase Distance' },

    AutomationLevel = { type = 'text', Default = 'auto', Category = 'Automation', DisplayName = 'Play Style (manual/hybrid/auto)', Options = { 'manual', 'hybrid', 'auto' } },
    AutomationPaused = { type = 'bool', Default = false, Category = 'Automation', DisplayName = 'Global Pause' },
    LeasePreemptionEnabled = { type = 'bool', Default = true, Category = 'Automation', DisplayName = 'Allow Urgent Lease Preemption' },
    AutoAbilitiesEnabled = { type = 'bool', Default = true, Category = 'Automation', DisplayName = 'Auto Abilities (AAs/Discs)' },
    AutoItemsEnabled = { type = 'bool', Default = true, Category = 'Automation', DisplayName = 'Auto Items (Clickies)' },
    DpsEnabled = { type = 'bool', Default = true, Category = 'Automation', DisplayName = 'DPS Enabled' },

    MeditationMode = { type = 'text', Default = 'off', Category = 'Automation', DisplayName = 'Meditation (off/ooc/in combat)', Options = { 'off', 'ooc', 'always', 'in combat' }, Aliases = { on = 'ooc', incombat = 'in combat', inout = 'always' } },
    MeditationAfterCombatDelay = { type = 'number', Default = 2, Category = 'Automation', DisplayName = 'Meditation After Combat Delay (sec)' },
    MeditationAggroCheck = { type = 'bool', Default = true, Category = 'Automation', DisplayName = 'Meditation Aggro Safety Check' },
    MeditationAggroPct = { type = 'number', Default = 95, Category = 'Automation', DisplayName = 'Meditation Aggro % (stand if >=)' },
    MeditationStandWhenDone = { type = 'bool', Default = true, Category = 'Automation', DisplayName = 'Stand When Meditation Done' },
    MeditationMinStateSeconds = { type = 'number', Default = 1, Category = 'Automation', DisplayName = 'Meditation Min Sit/Stand Hold (sec)' },

    MeditationHPStartPct = { type = 'number', Default = 70, Category = 'Automation', DisplayName = 'Meditation Start HP %' },
    MeditationHPStopPct = { type = 'number', Default = 95, Category = 'Automation', DisplayName = 'Meditation Stop HP %' },
    MeditationManaStartPct = { type = 'number', Default = 50, Category = 'Automation', DisplayName = 'Meditation Start Mana %' },
    MeditationManaStopPct = { type = 'number', Default = 95, Category = 'Automation', DisplayName = 'Meditation Stop Mana %' },
    MeditationEndStartPct = { type = 'number', Default = 60, Category = 'Automation', DisplayName = 'Meditation Start Endurance %' },
    MeditationEndStopPct = { type = 'number', Default = 95, Category = 'Automation', DisplayName = 'Meditation Stop Endurance %' },

    ResourceConversionEnabled = { type = 'bool', Default = true, Category = 'Automation', DisplayName = 'Resource Conversion Enabled' },
    ResourceMinSecondsBetweenCasts = { type = 'number', Default = 3, Category = 'Automation', DisplayName = 'Resource Conversion Cast Gap (sec)' },

    AssistMode = { type = 'text', Default = 'group', Category = 'Automation', DisplayName = 'Assist Mode (group/raid1/raid2/raid3/byname)', Options = { 'group', 'raid1', 'raid2', 'raid3', 'byname' } },
    AssistName = { type = 'text', Default = '', Category = 'Automation', DisplayName = 'Assist Name (if byname)' },
    RaidAssistOverrideActive = { type = 'bool', Default = false, Category = 'Automation', DisplayName = 'Raid Command-Bar Assist Override' },
    AssistAt = { type = 'number', Default = 97, Category = 'Automation', DisplayName = 'Assist At %' },
    AssistRange = { type = 'number', Default = 100, Category = 'Automation', DisplayName = 'Assist Range' },

    BurnActive = { type = 'bool', Default = false, Category = 'Automation', DisplayName = 'Burn Active' },
    BurnDuration = { type = 'number', Default = 30, Category = 'Automation', DisplayName = 'Burn Duration (sec)' },

    -- Combat Mode (Tank/Assist role selection)
    CombatMode = { type = 'text', Default = 'off', Category = 'Combat', DisplayName = 'Combat Mode (off/tank/assist)', Options = { 'off', 'tank', 'assist' } },

    -- Tank Settings
    TankTargetMode = { type = 'text', Default = 'auto', Category = 'Combat', DisplayName = 'Tank Target Mode (auto/manual)', Options = { 'auto', 'manual' } },
    TankAoEThreshold = { type = 'number', Default = 3, Category = 'Combat', DisplayName = 'AoE Mob Threshold' },
    TankRequireAggroDeficit = { type = 'bool', Default = true, Category = 'Combat', DisplayName = 'Require Aggro Deficit for AoE' },
    TankSafeAECheck = { type = 'bool', Default = true, Category = 'Combat', DisplayName = 'Extended Safe AE Check' },
    TankRepositionEnabled = { type = 'bool', Default = false, Category = 'Combat', DisplayName = 'Drag Mobs To Camp' },
    TankRepositionCooldown = { type = 'number', Default = 5, Category = 'Combat', DisplayName = 'Drag Step Interval (sec)' },
    TankTauntChaseRange = { type = 'number', Default = 60, Category = 'Combat', DisplayName = 'Taunt Chase Range' },
    TankEngageRange = { type = 'number', Default = 125, Category = 'Combat', DisplayName = 'Engage Range' },
    TankBreakMez = { type = 'bool', Default = true, Category = 'Combat', DisplayName = 'Break Mez When Camp Clear' },
    TankAnnounce = { type = 'bool', Default = true, Category = 'Combat', DisplayName = 'Announce Target Choices (console)' },
    TankHoldRadius = { type = 'number', Default = 50, Category = 'Combat', DisplayName = 'Hold Radius' },

    -- Assist Settings (when in assist combat mode)
    AssistTargetMode = { type = 'text', Default = 'sticky', Category = 'Combat', DisplayName = 'Assist Target Mode (sticky/follow)', Options = { 'sticky', 'follow' } },
    AssistEngageCondition = { type = 'text', Default = 'hp', Category = 'Combat', DisplayName = 'Engage Condition (hp/tank_aggro)', Options = { 'hp', 'tank_aggro' } },

    -- Stick Settings
    StickCommand = { type = 'text', Default = '/stick snaproll behind 10 moveback uw', Category = 'Combat', DisplayName = 'Stick Command' },
    SoftPauseStick = { type = 'text', Default = '/stick !front', Category = 'Combat', DisplayName = 'Soft Pause Stick' },

    -- Dragon Positioning
    DragonPositioning = { type = 'bool', Default = false, Category = 'Combat', DisplayName = 'Dragon Positioning' },
    DragonPositionAngle = { type = 'number', Default = 135, Category = 'Combat', DisplayName = 'Dragon Position Angle' },

    -- PC Pet Handling
    IgnorePCPets = { type = 'bool', Default = true, Category = 'Combat', DisplayName = 'Ignore PC Pets on XTarget' },

    -- Rotation Layer Thresholds
    EmergencyHpThreshold = { type = 'number', Default = 35, Category = 'Combat', DisplayName = 'Emergency HP %' },
    DefenseHpThreshold = { type = 'number', Default = 70, Category = 'Combat', DisplayName = 'Defense HP % (Non-Tank)' },
    TankDefenseHpThreshold = { type = 'number', Default = 40, Category = 'Combat', DisplayName = 'Tank Defense HP %' },

    -- Master Ability Type Toggles
    UseSpells = { type = 'bool', Default = true, Category = 'Combat', DisplayName = 'Use Spells' },
    UseAAs = { type = 'bool', Default = true, Category = 'Combat', DisplayName = 'Use AAs' },
    UseDiscs = { type = 'bool', Default = true, Category = 'Combat', DisplayName = 'Use Disciplines' },

    -- Debuffer Settings (Shaman, Enchanter, Mage)
    DebuffAllTask = { type = 'bool', Default = false, Category = 'Debuff', DisplayName = 'Debuff All Task Mobs' },

    -- Caster Assist Settings
    CasterStandoffEnabled = { type = 'bool', Default = false, Category = 'Combat', DisplayName = 'Caster Standoff (Ranged Casting)' },
    CasterStandoffMin = { type = 'number', Default = 35, Category = 'Combat', DisplayName = 'Standoff Min Distance' },
    CasterStandoffMax = { type = 'number', Default = 60, Category = 'Combat', DisplayName = 'Standoff Retreat Distance' },
    PreferredResistType = { type = 'text', Default = 'Any', Category = 'Combat', DisplayName = 'Preferred Resist Type' },

    -- Spell execution and rotation retry settings
    RotationResetWindow = { type = 'number', Default = 2, Category = 'Combat', DisplayName = 'Rotation Reset Window (sec)' },
    RetryOnFizzle = { type = 'bool', Default = true, Category = 'Combat', DisplayName = 'Retry on Fizzle' },
    RetryOnResist = { type = 'bool', Default = true, Category = 'Combat', DisplayName = 'Retry on Resist' },
    RetryOnInterrupt = { type = 'bool', Default = true, Category = 'Combat', DisplayName = 'Retry on Interrupt' },
    UseImmuneDatabase = { type = 'bool', Default = true, Category = 'Combat', DisplayName = 'Use Immune Database' },
    AdaptiveResistSkip = { type = 'bool', Default = true, Category = 'Combat', DisplayName = 'Adaptive Resist Skip' },

    -- DPS Intelligence (time-to-die gating for damage spells)
    UseDpsIntelligence = { type = 'bool', Default = true, Category = 'Combat', DisplayName = 'Smart DPS (Time-to-Die)' },
    -- Skip every DPS cast while own mana is below this % — tash line exempt
    -- (it enables charm/mez landing). 0 disables. Meant for charm enchanters.
    DpsMinManaPct = { type = 'number', Default = 0, Category = 'Combat', DisplayName = 'DPS Mana Floor % (Tash Exempt)' },
    DpsNukeLandMargin = { type = 'number', Default = 1.0, Category = 'Combat', DisplayName = 'Nuke Land Margin (sec)' },
    DpsDotBreakevenPct = { type = 'number', Default = 50, Category = 'Combat', DisplayName = 'DoT Breakeven (% of duration)' },
    DpsDefaultNukeCastTime = { type = 'number', Default = 3.0, Category = 'Combat', DisplayName = 'Default Nuke Cast Time (sec)' },
    DpsDefaultDotDuration = { type = 'number', Default = 24, Category = 'Combat', DisplayName = 'Default DoT Duration (sec)' },
    DpsOverkillFactor = { type = 'number', Default = 1.5, Category = 'Combat', DisplayName = 'Nuke Overkill Factor (x remaining HP)' },
    DpsRainPayoffSec = { type = 'number', Default = 4, Category = 'Combat', DisplayName = 'Rain Wave Payoff Window (sec)' },
    DpsRainSafetyMode = { type = 'text', Default = 'mezzed', Category = 'Combat', DisplayName = 'Rain Mez Safety (mezzed/solo/off)' },
    DpsRainSafetyRadius = { type = 'number', Default = 35, Category = 'Combat', DisplayName = 'Rain Safety Radius' },

    -- Death Forensics
    DeathForensicsEnabled = { type = 'bool', Default = true, Category = 'Combat', DisplayName = 'Death Reports (Black Box)' },

    -- Damage observer scope (chat event pattern matching)
    DamageObserver = { type = 'text', Default = 'auto', Category = 'Combat', DisplayName = 'Damage Observer (auto/always/never)' },

    -- Tank: auto-peel and flee-handoff
    TankAutoPeel = { type = 'bool', Default = true, Category = 'Combat', DisplayName = 'Auto-Peel (Protect Squishies First)' },
    TankPeelMinPriority = { type = 'number', Default = 1, Category = 'Combat', DisplayName = 'Peel Min Victim Priority (1=any, 4=casters+, 5=healers)' },
    TankFleeHandoff = { type = 'bool', Default = true, Category = 'Combat', DisplayName = 'Hand Off Fleeing Mobs to DPS' },
    TankFleeHpThreshold = { type = 'number', Default = 20, Category = 'Combat', DisplayName = 'Flee Handoff HP %' },
    TankFleeMinRecedeRate = { type = 'number', Default = 2.25, Category = 'Combat', DisplayName = 'Flee Handoff Min Recede Speed' },
    TankFleeHandoffWindowSec = { type = 'number', Default = 15, Category = 'Combat', DisplayName = 'Flee Handoff Window (sec)' },
    TankFleeMinAdds = { type = 'number', Default = 2, Category = 'Combat', DisplayName = 'Flee Handoff Min Haters (incl. runner)' },

    -- Healer: pull-landing pre-heal
    PrePullHotEnabled = { type = 'bool', Default = true, Category = 'Combat', DisplayName = 'Pre-Pull HoT on Tank' },
    PrePullHotEtaSec = { type = 'number', Default = 8, Category = 'Combat', DisplayName = 'Pre-Pull HoT ETA Window (sec)' },
    PrePullHotBigMult = { type = 'number', Default = 2.0, Category = 'Combat', DisplayName = 'Big HoT At Mob Multiplier >=' },

    -- Group readiness coordinator (opt-in; needs actors)
    ReadinessEnabled = { type = 'bool', Default = false, Category = 'Combat', DisplayName = 'Group Readiness Coordinator' },
    ReadinessAnnounce = { type = 'bool', Default = true, Category = 'Combat', DisplayName = 'Announce READY in Group Chat' },
    ReadyHpPct = { type = 'number', Default = 90, Category = 'Combat', DisplayName = 'Ready HP %' },
    ReadyManaPct = { type = 'number', Default = 80, Category = 'Combat', DisplayName = 'Ready Mana %' },
    ReadyEndPct = { type = 'number', Default = 50, Category = 'Combat', DisplayName = 'Ready Endurance %' },

    -- Vitals hub (tank publishes consolidated group vitals for UI scripts)
    VitalsHubEnabled = { type = 'bool', Default = true, Category = 'Combat', DisplayName = 'Publish Group Vitals (Tank Hub)' },

    -- Resist Tracker (per-mob element resist learning)
    UseResistTracker = { type = 'bool', Default = true, Category = 'Combat', DisplayName = 'Learn Mob Resists' },
    ResistAvoidPct = { type = 'number', Default = 50, Category = 'Combat', DisplayName = 'Avoid Element At Resist %' },
    ResistMinSamples = { type = 'number', Default = 4, Category = 'Combat', DisplayName = 'Resist Min Samples' },
    ResistMinEfficiencyPct = { type = 'number', Default = 35, Category = 'Combat', DisplayName = 'Avoid Element Below Efficiency %' },

    -- Spell Lineup Settings
    SpellRescanOnZone = { type = 'bool', Default = true, Category = 'Spells', DisplayName = 'Rescan Gems on Zone' },
    HealThreshold = { type = 'number', Default = 80, Category = 'Spells', DisplayName = 'Heal HP Threshold' },
    HealPetsEnabled = { type = 'bool', Default = false, Category = 'Spells', DisplayName = 'Heal Pets' },

    -- Healing (legacy tiers plus Healing Intelligence for healer classes)
    DoHeals = { type = 'bool', Default = true, Category = 'Heal/Rez', DisplayName = 'Enable Heals' },
    PriorityHealing = { type = 'bool', Default = true, Category = 'Heal/Rez', DisplayName = 'Priority Healing' },
    HealBreakInvisOOC = { type = 'bool', Default = false, Category = 'Heal/Rez', DisplayName = 'Break Invis OOC To Heal' },

    MainHealPoint = { type = 'number', Default = 80, Category = 'Heal/Rez', DisplayName = 'Main Heal Point (HP %)' },
    BigHealPoint = { type = 'number', Default = 50, Category = 'Heal/Rez', DisplayName = 'Big Heal Point (HP %)' },
    GroupHealPoint = { type = 'number', Default = 75, Category = 'Heal/Rez', DisplayName = 'Group Heal Point (HP %)' },
    GroupInjureCnt = { type = 'number', Default = 2, Category = 'Heal/Rez', DisplayName = 'Group Injured Count' },

    DoPetHeals = { type = 'bool', Default = false, Category = 'Heal/Rez', DisplayName = 'Enable Pet Heals' },
    PetHealPoint = { type = 'number', Default = 50, Category = 'Heal/Rez', DisplayName = 'Pet Heal Point (HP %)' },

    HealWatchMA = { type = 'bool', Default = false, Category = 'Heal/Rez', DisplayName = 'Watch Main Assist (OOG OK)' },
    HealXTargetEnabled = { type = 'bool', Default = false, Category = 'Heal/Rez', DisplayName = 'Heal XTarget Slots' },
    HealXTargetSlots = { type = 'text', Default = '', Category = 'Heal/Rez', DisplayName = 'XTarget Slots (e.g. 1|2|3)' },

    HealUseHoTs = { type = 'bool', Default = true, Category = 'Heal/Rez', DisplayName = 'Use HoTs (when available)' },
    HealHoTMinSeconds = { type = 'number', Default = 6, Category = 'Heal/Rez', DisplayName = 'HoT Refresh Window (sec)' },

    HealCoordinateActors = { type = 'bool', Default = true, Category = 'Heal/Rez', DisplayName = 'Coordinate Heals via Actors' },
    HealTrackHoTsViaActors = { type = 'bool', Default = true, Category = 'Heal/Rez', DisplayName = 'Track HoTs via Actors' },

    -- CC Settings (Enchanter, Bard, Necro)

    -- Mez/charm immune persistence — records mobs that fail mez/charm
    -- attempts to a per-zone persistent DB; future attempts skip them.
    MezImmunePersistEnabled = { type = 'bool', Default = true, Category = 'CC', DisplayName = 'Persist Mez/Charm Immune Mobs' },

    -- Discipline / burn ability framework — evaluates per-class config
    -- predicates and fires the matching disc/AA on combat ticks.
    DisciplinesEnabled = { type = 'bool', Default = true, Category = 'Combat', DisplayName = 'Auto-Use Class Disciplines/AAs' },
    -- Mez Casting Settings (ENC, BRD, NEC)
    MezzingEnabled = { type = 'bool', Default = false, Category = 'CC', DisplayName = 'Mezzing Enabled' },
    MezMinLevel = { type = 'number', Default = 0, Category = 'CC', DisplayName = 'Mez Min Level (skip grey cons)' },
    MezMaxTargets = { type = 'number', Default = 3, Category = 'CC', DisplayName = 'Max Mobs to Mez' },
    UseAEMez = { type = 'bool', Default = false, Category = 'CC', DisplayName = 'Use AE Mez' },
    AEMezMinTargets = { type = 'number', Default = 3, Category = 'CC', DisplayName = 'AE Mez Min Targets' },
    UseFastMez = { type = 'bool', Default = true, Category = 'CC', DisplayName = 'Use Fast Mez' },
    MezRefreshWindow = { type = 'number', Default = 6, Category = 'CC', DisplayName = 'Mez Refresh Window (sec)' },

    -- Charm (DPS charm pet, ENC). Target cap comes from the charm spell's own
    -- MaxLevel; the blacklist keeps healer-class NPCs (useless pets) off the
    -- menu. Break response: tash if needed -> AE stun -> recharm.
    CharmEnabled = { type = 'bool', Default = false, Category = 'CC', DisplayName = 'Charm Pet Enabled' },
    CharmClassBlacklist = { type = 'text', Default = 'CLR SHM', Category = 'CC', DisplayName = 'Charm Class Blacklist' },
    CharmBreakTash = { type = 'bool', Default = true, Category = 'CC', DisplayName = 'Tash Before Recharm' },
    CharmPreTash = { type = 'bool', Default = true, Category = 'CC', DisplayName = 'Tash Before First Charm' },
    CharmBreakStun = { type = 'bool', Default = true, Category = 'CC', DisplayName = 'AE Stun On Charm Break' },
    -- Mez trumps a broken charm ONLY when more than this many unmezzed
    -- haters (excluding the loose ex-pet) are in camp.
    CharmHoldUnmezzed = { type = 'number', Default = 2, Category = 'CC', DisplayName = 'Hold Recharm If Unmezzed Mobs Exceed' },

    -- Spell Engine Settings
    SpellRole = { type = 'text', Default = 'default', Category = 'Spells', DisplayName = 'Spell Role' },
    SpellAutoMemorize = { type = 'bool', Default = true, Category = 'Spells', DisplayName = 'Auto-Memorize Spells' },
    SpellMaxRetries = { type = 'number', Default = 3, Category = 'Spells', DisplayName = 'Max Cast Retries' },
    SpellMemTimeout = { type = 'number', Default = 25000, Category = 'Spells', DisplayName = 'Memorize Timeout (ms)' },
    SpellReadyTimeout = { type = 'number', Default = 5000, Category = 'Spells', DisplayName = 'Spell Ready Timeout (ms)' },

    -- Auto-Interrupt Settings
    InterruptOnTargetDeath = { type = 'bool', Default = true, Category = 'Spells', DisplayName = 'Interrupt on Target Death' },
    InterruptOnOutOfRange = { type = 'bool', Default = true, Category = 'Spells', DisplayName = 'Interrupt on Out of Range' },
    InterruptHpThreshold = { type = 'number', Default = 20, Category = 'Spells', DisplayName = 'Interrupt Self HP %' },
    InterruptOnSelfEmergency = { type = 'bool', Default = true, Category = 'Spells', DisplayName = 'Interrupt on Self Emergency' },

    -- Raid-specific Interrupt Conditions
    RaidHealStopEnabled = { type = 'bool', Default = false, Category = 'Spells', DisplayName = 'Stop Heals at HP% (Raid)' },
    RaidHealStopHpThreshold = { type = 'number', Default = 90, Category = 'Spells', DisplayName = 'Heal Stop HP %' },
    RaidDamageStopEnabled = { type = 'bool', Default = false, Category = 'Spells', DisplayName = 'Stop Damage at HP% (Raid)' },
    RaidDamageStopHpThreshold = { type = 'number', Default = 2, Category = 'Spells', DisplayName = 'Damage Stop HP %' },

    -- Gem Lock Settings
    GemLockEnabled = { type = 'bool', Default = true, Category = 'Spells', DisplayName = 'Enable Gem Locking' },

    -- Buff Settings
    BuffingEnabled = { type = 'bool', Default = true, Category = 'Buffs', DisplayName = 'Enable Buffing' },

    ActorsEnabled = { type = 'bool', Default = true, Category = 'Integration', DisplayName = 'Enable Actors' },
    ActorsTeamEnabled = { type = 'bool', Default = true, Category = 'Integration', DisplayName = 'Enable Actor Team' },
    ActorsTeamMode = { type = 'text', Default = 'auto', Category = 'Integration', DisplayName = 'Actor Team Mode', Options = { 'auto', 'group', 'raid', 'manual' } },
    ActorsTeamName = { type = 'text', Default = '', Category = 'Integration', DisplayName = 'Manual Actor Team Name' },

    -- Safe Targeting (KS Prevention)
    SafeTargetingEnabled = { type = 'bool', Default = true, Category = 'Combat', DisplayName = 'Safe Targeting (KS Prevention)' },
    SafeTargetingCheckRaid = { type = 'bool', Default = true, Category = 'Combat', DisplayName = 'Safe Targeting: Check Raid Members' },
    SafeTargetingCheckPeers = { type = 'bool', Default = true, Category = 'Combat', DisplayName = 'Safe Targeting: Check Actor Peers' },

    -- Target Overrides
    TargetingForcedTargetName = { type = 'text', Default = '', Category = 'Combat', DisplayName = 'Targeting: Forced Target (name)' },
    TargetingIgnoredTargetNames = { type = 'text', Default = '', Category = 'Combat', DisplayName = 'Targeting: Ignored Targets (comma-separated names)' },

    -- Named Detection
    NamedDetectionUseSpawnMaster = { type = 'bool', Default = true, Category = 'Combat', DisplayName = 'Named Detection: Use MQ2SpawnMaster' },
    NamedDetectionUseAlertMaster = { type = 'bool', Default = true, Category = 'Combat', DisplayName = 'Named Detection: Use AlertMaster' },
    NamedDetectionMinLevel = { type = 'number', Default = 0, Category = 'Combat', DisplayName = 'Named Detection: Minimum Level' },
    NamedDetectionCustomNames = { type = 'text', Default = '', Category = 'Combat', DisplayName = 'Named Detection: Custom Names' },
    NamedDetectionForceNamed = { type = 'bool', Default = false, Category = 'Combat', DisplayName = 'Named Detection: Force Current Mobs Named' },

    -- AssistOutside: Enable assisting group, raid, and actor peers
    AssistOutsideGroup = { type = 'bool', Default = true, Category = 'Combat', DisplayName = 'Assist Outside: Group Members' },
    AssistOutsideRaid = { type = 'bool', Default = true, Category = 'Combat', DisplayName = 'Assist Outside: Raid Members' },
    AssistOutsidePeers = { type = 'bool', Default = true, Category = 'Combat', DisplayName = 'Assist Outside: Actor Peers (Same Zone)' },

    -- Cure Settings
    DoCures = { type = 'bool', Default = true, Category = 'Heal/Rez', DisplayName = 'Enable Cures' },
    CurePrioritySelf = { type = 'bool', Default = false, Category = 'Heal/Rez', DisplayName = 'Cure Self First' },
    CureInCombat = { type = 'bool', Default = true, Category = 'Heal/Rez', DisplayName = 'Cure During Combat' },

    -- Resurrection Settings
    AutoRezOOC = { type = 'bool', Default = true, Category = 'Heal/Rez', DisplayName = 'Auto-Rez Out of Combat' },
    AutoRezInCombat = { type = 'bool', Default = false, Category = 'Heal/Rez', DisplayName = 'Auto-Rez In Combat' },
    AutoAcceptRez = { type = 'bool', Default = true, Category = 'Heal/Rez', DisplayName = 'Auto-Accept Rez Offers' },
    RezOOCMethod = { type = 'text', Default = 'Auto', Category = 'Heal/Rez', DisplayName = 'OOC Rez Method', Options = { 'Auto', 'Item', 'Spell' } },
    RezCombatMethod = { type = 'text', Default = 'Auto', Category = 'Heal/Rez', DisplayName = 'Combat Rez Method', Options = { 'Auto', 'Item', 'AA', 'Spell' } },
    RezCombatTargetClasses = { type = 'text', Default = 'ALL', Category = 'Heal/Rez', DisplayName = 'Combat Rez Target Classes' },
    RezItemName = { type = 'text', Default = '', Category = 'Heal/Rez', DisplayName = 'Rez Item Name' },
    RezAutoMemorize = { type = 'bool', Default = true, Category = 'Heal/Rez', DisplayName = 'Auto-Memorize Rez Spells' },
    RezGem = { type = 'number', Default = 0, Category = 'Heal/Rez', DisplayName = 'Temporary Rez Gem (0 = Last)' },
    RezRestoreGem = { type = 'bool', Default = true, Category = 'Heal/Rez', DisplayName = 'Restore Temporary Rez Gem' },
    RezCoordinateActors = { type = 'bool', Default = true, Category = 'Heal/Rez', DisplayName = 'Coordinate Rez via Actors' },
    RezPriority = { type = 'number', Default = 50, Category = 'Heal/Rez', DisplayName = 'Rezzer Priority' },
    RezNavigate = { type = 'bool', Default = false, Category = 'Heal/Rez', DisplayName = 'Navigate to Corpses' },
    RezNavMaxDistance = { type = 'number', Default = 250, Category = 'Heal/Rez', DisplayName = 'Maximum Corpse Navigation Distance' },
    RezDebug = { type = 'bool', Default = false, Category = 'Heal/Rez', DisplayName = 'Rez Debug Logging' },

    -- Animation Settings
    AnimationsEnabled = { type = 'bool', Default = true, Category = 'Animations', DisplayName = 'Enable Animations' },
    HoverScaleEnabled = { type = 'bool', Default = true, Category = 'Animations', DisplayName = 'Hover Scale' },
    ClickBounceEnabled = { type = 'bool', Default = true, Category = 'Animations', DisplayName = 'Click Bounce' },
    TogglePopEnabled = { type = 'bool', Default = true, Category = 'Animations', DisplayName = 'Toggle Pop' },
    ReadyPulseEnabled = { type = 'bool', Default = true, Category = 'Animations', DisplayName = 'Ready Pulse' },
    CooldownColorTweenEnabled = { type = 'bool', Default = true, Category = 'Animations', DisplayName = 'Cooldown Color Transition' },
    ToggleColorTweenEnabled = { type = 'bool', Default = true, Category = 'Animations', DisplayName = 'Toggle Color Transition' },
    StaggerAnimationEnabled = { type = 'bool', Default = true, Category = 'Animations', DisplayName = 'Stagger Animation' },
    LowResourceWarningEnabled = { type = 'bool', Default = true, Category = 'Animations', DisplayName = 'Low Resource Warning' },
    DamageFlashEnabled = { type = 'bool', Default = true, Category = 'Animations', DisplayName = 'Damage Flash' },
}

-- ============================================================
-- VALIDATORS
-- ============================================================

local VALIDATORS = {
    -- Anchor gap: 0-48
    SideKickMainAnchorGap = { min = 0, max = 48 },
    SideKickBarAnchorGap = { min = 0, max = 48 },
    SideKickSpecialAnchorGap = { min = 0, max = 48 },
    SideKickDiscBarAnchorGap = { min = 0, max = 48 },
    SideKickItemBarAnchorGap = { min = 0, max = 48 },
    SideKickSkillBarAnchorGap = { min = 0, max = 48 },

    -- Width overrides: 0 means automatic.
    SideKickMainWidth = { min = 0, max = 1200 },
    SideKickBarWidth = { min = 0, max = 1200 },
    SideKickSpecialWidth = { min = 0, max = 1200 },
    SideKickDiscBarWidth = { min = 0, max = 1200 },
    SideKickItemBarWidth = { min = 0, max = 1200 },
    SideKickMainRounding = { min = 0, max = 20 },

    -- Button scale: 0.5-3.0
    SideKickMainButtonScale = { min = 0.5, max = 3.0 },

    -- Font scale: 0.5-3.0
    SideKickFontScale = { min = 0.5, max = 3.0 },

    -- Cell sizes: 32-120
    SideKickBarCell = { min = 32, max = 120 },
    SideKickSpecialCell = { min = 32, max = 120 },
    SideKickDiscBarCell = { min = 32, max = 120 },
    SideKickItemBarCell = { min = 32, max = 120 },
    SideKickSkillBarCell = { min = 24, max = 96 },

    -- Rows: 1-6
    SideKickBarRows = { min = 1, max = 6 },
    SideKickSpecialRows = { min = 1, max = 6 },
    SideKickDiscBarRows = { min = 1, max = 6 },
    SideKickItemBarRows = { min = 1, max = 6 },
    SideKickSkillBarRows = { min = 1, max = 8 },

    -- Alpha: 0-1
    SideKickBarBgAlpha = { min = 0.0, max = 1.0 },
    SideKickSpecialBgAlpha = { min = 0.0, max = 1.0 },
    SideKickDiscBarBgAlpha = { min = 0.0, max = 1.0 },
    SideKickItemBarBgAlpha = { min = 0.0, max = 1.0 },
    SideKickSkillBarBgAlpha = { min = 0.0, max = 1.0 },

    -- Percentages: 0-100
    AssistAt = { min = 0, max = 100 },
    MeditationAggroPct = { min = 0, max = 100 },
    MeditationHPStartPct = { min = 0, max = 100 },
    MeditationHPStopPct = { min = 0, max = 100 },
    MeditationManaStartPct = { min = 0, max = 100 },
    MeditationManaStopPct = { min = 0, max = 100 },
    MeditationEndStartPct = { min = 0, max = 100 },
    MeditationEndStopPct = { min = 0, max = 100 },
    MainHealPoint = { min = 0, max = 100 },
    BigHealPoint = { min = 0, max = 100 },
    GroupHealPoint = { min = 0, max = 100 },
    EmergencyHpThreshold = { min = 0, max = 100 },
}

for key, bounds in pairs(VALIDATORS) do
    local meta = M.defaults[key]
    if meta then
        if meta.Min == nil then meta.Min = bounds.min end
        if meta.Max == nil then meta.Max = bounds.max end
    end
end

-- ============================================================
-- MODULE OWNERSHIP
-- ============================================================
--
-- Ownership is deliberately enumerated by key. UI categories and naming
-- conventions are presentation concerns; they must never decide which file
-- wins a persistence conflict. Dynamically generated settings are handled by
-- the declared namespaces below.

local MODULE_KEYS = {
    ui = [[
        SideKickTheme SideKickSyncThemeWithGT SideKickDebugSettings SideKickLogLevel SideKickLogFile
        SideKickLogFilter SideKickModuleLogLevels DashboardVisible HealPreviewVisible
        SideKickMainEnabled SideKickOptionsManual SideKickOptionsPosX SideKickOptionsPosY
        SideKickOptionsWidth SideKickOptionsHeight SideKickMainAnchor SideKickMainAnchorTarget
        SideKickMainAnchorGap SideKickMainButtonScale SideKickMainRounding SideKickMainWidth
        SideKickMainShowBorder SideKickFontScale SideKickMainTextureTint SideKickMainBgStyle
        SideKickMainBgTexture SideKickMainBgTile SideKickButtonsSubtab
        SideKickBarEnabled SideKickBarCell SideKickBarRows SideKickBarGap SideKickBarPad
        SideKickBarBgAlpha SideKickBarWidth SideKickBarShowBorder SideKickBarAnchorTarget SideKickBarAnchor SideKickBarAnchorGap
        SideKickBarTextureTint SideKickSpecialEnabled SideKickSpecialForceSingleRow
        SideKickSpecialForceSingleColumn SideKickSpecialPerButtonMove SideKickSpecialCell
        SideKickSpecialRows SideKickSpecialGap SideKickSpecialPad SideKickSpecialBgAlpha
        SideKickSpecialWidth SideKickSpecialShowBorder
        SideKickSpecialAnchorTarget SideKickSpecialAnchor SideKickSpecialAnchorGap
        SideKickSpecialTextureTint SideKickDiscBarEnabled SideKickDiscBarCell SideKickDiscBarRows
        SideKickDiscBarGap SideKickDiscBarPad SideKickDiscBarBgAlpha SideKickDiscBarWidth
        SideKickDiscBarShowBorder SideKickDiscBarAnchorTarget
        SideKickDiscBarAnchor SideKickDiscBarAnchorGap SideKickDiscBarTextureTint
        SideKickItemBarEnabled SideKickItemBarCell SideKickItemBarRows SideKickItemBarGap
        SideKickItemBarPad SideKickItemBarBgAlpha SideKickItemBarWidth SideKickItemBarAnchorTarget SideKickItemBarAnchor
        SideKickItemBarAnchorGap SideKickItemBarTextureTint SideKickSkillBarEnabled
        SideKickSkillBarCell SideKickSkillBarRows SideKickSkillBarGap SideKickSkillBarPad
        SideKickSkillBarBgAlpha SideKickSkillBarWidth SideKickSkillBarAnchorTarget
        SideKickSkillBarAnchor SideKickSkillBarAnchorGap SideKickSkillBarShowBorder
        SideKickSkillBarTextureTint AnimationsEnabled HoverScaleEnabled ClickBounceEnabled
        TogglePopEnabled ReadyPulseEnabled CooldownColorTweenEnabled ToggleColorTweenEnabled
        StaggerAnimationEnabled LowResourceWarningEnabled DamageFlashEnabled
    ]],
    main = [[
        AutomationLevel AutomationPaused LeasePreemptionEnabled AutoAbilitiesEnabled AutoItemsEnabled AutostartPromptShown
    ]],
    chase = [[
        ChaseEnabled ChaseRole ChaseTarget ChaseDistance
    ]],
    meditation = [[
        MeditationMode MeditationAfterCombatDelay MeditationAggroCheck MeditationAggroPct
        MeditationStandWhenDone MeditationMinStateSeconds MeditationHPStartPct MeditationHPStopPct
        MeditationManaStartPct MeditationManaStopPct MeditationEndStartPct MeditationEndStopPct
    ]],
    resources = [[
        ResourceConversionEnabled ResourceMinSecondsBetweenCasts
    ]],
    assist = [[
        AssistMode AssistName RaidAssistOverrideActive AssistAt AssistRange AssistTargetMode AssistEngageCondition
        AssistOutsideGroup AssistOutsideRaid AssistOutsidePeers
    ]],
    dps = [[
        DpsEnabled BurnActive BurnDuration RotationResetWindow
        UseDpsIntelligence DpsMinManaPct DpsNukeLandMargin DpsDotBreakevenPct DpsDefaultNukeCastTime
        DpsDefaultDotDuration DpsOverkillFactor DpsRainPayoffSec DpsRainSafetyMode
        DpsRainSafetyRadius UseResistTracker ResistAvoidPct ResistMinSamples
        ResistMinEfficiencyPct
    ]],
    combat = [[
        CombatMode TankTargetMode TankAoEThreshold TankRequireAggroDeficit TankSafeAECheck
        TankRepositionEnabled TankRepositionCooldown TankTauntChaseRange TankEngageRange
        TankBreakMez TankAnnounce TankHoldRadius BandolierEnabled StickCommand SoftPauseStick DragonPositioning
        DragonPositionAngle IgnorePCPets EmergencyHpThreshold DefenseHpThreshold
        TankDefenseHpThreshold UseSpells UseAAs UseDiscs
        PreferredResistType SafeTargetingEnabled SafeTargetingCheckRaid
        SafeTargetingCheckPeers TargetingForcedTargetName TargetingIgnoredTargetNames
        NamedDetectionUseSpawnMaster NamedDetectionUseAlertMaster NamedDetectionMinLevel
        NamedDetectionCustomNames NamedDetectionForceNamed
        CasterStandoffEnabled CasterStandoffMin CasterStandoffMax
        TankAutoPeel TankPeelMinPriority TankFleeHandoff TankFleeHpThreshold
        TankFleeMinRecedeRate TankFleeHandoffWindowSec TankFleeMinAdds
        DamageObserver DeathForensicsEnabled
        ReadinessEnabled ReadinessAnnounce ReadyHpPct ReadyManaPct ReadyEndPct
    ]],
    debuff = [[ DebuffAllTask ]],
    spells = [[
        RetryOnFizzle RetryOnResist RetryOnInterrupt UseImmuneDatabase AdaptiveResistSkip
        SpellRescanOnZone SpellRole SpellAutoMemorize SpellMaxRetries SpellMemTimeout
        SpellReadyTimeout InterruptOnTargetDeath InterruptOnOutOfRange InterruptHpThreshold
        InterruptOnSelfEmergency RaidHealStopEnabled RaidHealStopHpThreshold RaidDamageStopEnabled
        RaidDamageStopHpThreshold GemLockEnabled
    ]],
    healing = [[
        HealThreshold HealPetsEnabled DoHeals PriorityHealing HealBreakInvisOOC MainHealPoint
        BigHealPoint GroupHealPoint GroupInjureCnt DoPetHeals PetHealPoint HealWatchMA
        HealXTargetEnabled HealXTargetSlots HealUseHoTs HealHoTMinSeconds HealCoordinateActors
        HealTrackHoTsViaActors PrePullHotEnabled PrePullHotEtaSec PrePullHotBigMult
    ]],
    cc = [[
        MezImmunePersistEnabled MezzingEnabled MezMinLevel MezMaxTargets UseAEMez
        AEMezMinTargets UseFastMez MezRefreshWindow
        CharmEnabled CharmClassBlacklist CharmBreakTash CharmPreTash CharmBreakStun CharmHoldUnmezzed
    ]],
    disciplines = [[ DisciplinesEnabled SideKickBERDiscDefaultsApplied ]],
    buffs = [[ BuffingEnabled ]],
    integration = [[ ActorsEnabled ActorsTeamEnabled ActorsTeamMode ActorsTeamName SideKickLaunchGroup VitalsHubEnabled ]],
    cures = [[ DoCures CurePrioritySelf CureInCombat ]],
    resurrection = [[
        AutoRezOOC AutoRezInCombat AutoAcceptRez RezOOCMethod RezCombatMethod
        RezCombatTargetClasses RezItemName RezAutoMemorize RezGem RezRestoreGem
        RezCoordinateActors RezPriority RezNavigate RezNavMaxDistance RezDebug
    ]],
}

local _owners = {}
local _moduleKeys = {}
local _lowerToKey = {}
local _registrationErrors = {}
local _dynamicNamespaces = {}
local _changeListeners = {}
local _sortedKeys = nil

local function recordRegistrationError(message)
    _registrationErrors[#_registrationErrors + 1] = tostring(message)
end

local function assignOwner(moduleName, key)
    moduleName = tostring(moduleName or ''):lower()
    key = tostring(key or '')
    if moduleName == '' or key == '' then
        recordRegistrationError('module and key are required')
        return false
    end
    if not M.defaults[key] then
        recordRegistrationError(string.format('module %s owns unknown key %s', moduleName, key))
        return false
    end
    local lowerKey = key:lower()
    if _lowerToKey[lowerKey] and _lowerToKey[lowerKey] ~= key then
        recordRegistrationError(string.format('case-insensitive setting collision: %s and %s',
            _lowerToKey[lowerKey], key))
        return false
    end
    local previous = _owners[key]
    if previous and previous ~= moduleName then
        recordRegistrationError(string.format('duplicate setting owner for %s: %s and %s', key, previous, moduleName))
        return false
    end
    _owners[key] = moduleName
    _lowerToKey[lowerKey] = key
    M.defaults[key].Module = moduleName
    _moduleKeys[moduleName] = _moduleKeys[moduleName] or {}
    _moduleKeys[moduleName][key] = true
    return true
end

for moduleName, keys in pairs(MODULE_KEYS) do
    for key in tostring(keys):gmatch('[%w_]+') do
        assignOwner(moduleName, key)
    end
end

--- Register additional settings owned by a module.
--- Existing metadata may be completed by the owning module, but a second
--- module can never claim the same key.
function M.registerModule(moduleName, definitions)
    if type(definitions) ~= 'table' then return false, 'definitions must be a table' end
    local added = {}
    for key, definition in pairs(definitions) do
        if type(definition) ~= 'table' then
            recordRegistrationError(string.format('invalid schema for %s.%s', tostring(moduleName), tostring(key)))
        else
            local current = M.defaults[key]
            if current and _owners[key] and _owners[key] ~= tostring(moduleName):lower() then
                recordRegistrationError(string.format('duplicate setting owner for %s: %s and %s',
                    tostring(key), tostring(_owners[key]), tostring(moduleName)))
            else
                if current then
                    for field, value in pairs(definition) do current[field] = value end
                else
                    M.defaults[key] = definition
                end
                if assignOwner(moduleName, key) then added[#added + 1] = key end
            end
        end
    end
    _sortedKeys = nil
    if #added == 0 then return false, 'no settings registered' end
    return true, added
end

--- Declare ownership for a generated key family. These namespaces do not
--- invent schema metadata; they only provide a stable persistence owner.
function M.registerNamespace(moduleName, luaPattern)
    moduleName = tostring(moduleName or ''):lower()
    luaPattern = tostring(luaPattern or '')
    if moduleName == '' or luaPattern == '' then return false, 'module and pattern are required' end
    for _, entry in ipairs(_dynamicNamespaces) do
        if entry.pattern == luaPattern then
            if entry.module ~= moduleName then
                recordRegistrationError(string.format('dynamic namespace %s owned by %s and %s',
                    luaPattern, entry.module, moduleName))
                return false, 'duplicate namespace owner'
            end
            return true
        end
    end
    _dynamicNamespaces[#_dynamicNamespaces + 1] = { module = moduleName, pattern = luaPattern }
    return true
end

M.registerNamespace('abilities', '^do')
M.registerNamespace('pull', '^Pull_')
M.registerNamespace('humanize', '^Humanize_')
M.registerNamespace('humanize', '^HUMANIZE_')
M.registerNamespace('ui', '^SideKickSkill_')

function M.owner(key)
    key = tostring(key or '')
    key = _lowerToKey[key:lower()] or key
    if _owners[key] then return _owners[key], 'schema' end
    for _, entry in ipairs(_dynamicNamespaces) do
        if key:match(entry.pattern) then return entry.module, 'namespace' end
    end
    return nil, 'unregistered'
end

function M.resolveKey(key)
    key = tostring(key or '')
    return _lowerToKey[key:lower()] or key
end

function M.keysForModule(moduleName)
    local result = {}
    for key in pairs(_moduleKeys[tostring(moduleName or ''):lower()] or {}) do
        result[#result + 1] = key
    end
    table.sort(result)
    return result
end

function M.audit()
    local errors = {}
    for _, message in ipairs(_registrationErrors) do errors[#errors + 1] = message end
    local missingOwners = {}
    local allowedTypes = { bool = true, number = true, text = true }
    for key, meta in pairs(M.defaults) do
        if not _owners[key] then missingOwners[#missingOwners + 1] = key end
        if type(meta) ~= 'table' then
            errors[#errors + 1] = string.format('setting %s has no schema table', key)
        else
            local valType = tostring(meta.type or ''):lower()
            if not allowedTypes[valType] then
                errors[#errors + 1] = string.format('setting %s has unsupported type %s', key, tostring(meta.type))
            end
            if meta.Default == nil then
                errors[#errors + 1] = string.format('setting %s has no default', key)
            else
                local valid, _, reason = M.normalize(key, meta.Default)
                if not valid then
                    errors[#errors + 1] = string.format('setting %s has invalid default: %s', key, tostring(reason))
                end
            end
        end
    end
    table.sort(missingOwners)
    for _, key in ipairs(missingOwners) do
        errors[#errors + 1] = string.format('registered setting has no owner: %s', key)
    end
    return {
        ok = #errors == 0,
        errors = errors,
        registered = (function()
            local count = 0
            for _ in pairs(M.defaults) do count = count + 1 end
            return count
        end)(),
        owned = (function()
            local count = 0
            for _ in pairs(_owners) do count = count + 1 end
            return count
        end)(),
        namespaces = #_dynamicNamespaces,
    }
end

function M.addChangeListener(listener)
    if type(listener) ~= 'function' then return false end
    _changeListeners[#_changeListeners + 1] = listener
    return true
end

function M.notifyChanged(key, newValue, oldValue, source)
    local meta = M.defaults[key]
    if meta and type(meta.OnChange) == 'function' then
        pcall(meta.OnChange, oldValue, newValue, source)
    end
    for _, listener in ipairs(_changeListeners) do
        pcall(listener, key, oldValue, newValue, source)
    end
end

function M.meta(key)
    return M.defaults[M.resolveKey(key)]
end

function M.is_removed(key)
    return M.removed[tostring(key or '')] == true
end

local function strictBool(value)
    if type(value) == 'boolean' then return true, value end
    if type(value) == 'number' and (value == 0 or value == 1) then return true, value == 1 end
    if type(value) == 'string' then
        local normalized = value:lower():match('^%s*(.-)%s*$')
        if normalized == '1' or normalized == 'true' or normalized == 'yes' or normalized == 'on' then
            return true, true
        end
        if normalized == '0' or normalized == 'false' or normalized == 'no' or normalized == 'off' then
            return true, false
        end
    end
    return false, nil
end

--- Validate and normalize a setting without mutating persistence.
--- @return boolean ok, any normalizedValue, string|nil error
function M.normalize(key, value)
    key = M.resolveKey(key)
    if key == '' then return false, nil, 'setting key is required' end
    if M.is_removed(key) then return false, nil, string.format('setting %s was removed', key) end

    local meta = M.defaults[key]
    if not meta then
        -- Compatibility and generated namespaces remain writable, but callers
        -- can identify them by the third return value.
        return true, value, 'unregistered'
    end

    local valType = tostring(meta.type or 'text'):lower()
    local normalized = value
    if valType == 'bool' then
        local ok
        ok, normalized = strictBool(value)
        if not ok then return false, nil, string.format('%s expects a boolean', key) end
    elseif valType == 'number' then
        normalized = tonumber(value)
        if not normalized then return false, nil, string.format('%s expects a number', key) end
        local validator = VALIDATORS[key] or {}
        local minValue = meta.Min ~= nil and tonumber(meta.Min) or tonumber(validator.min)
        local maxValue = meta.Max ~= nil and tonumber(meta.Max) or tonumber(validator.max)
        if minValue and normalized < minValue then
            return false, nil, string.format('%s must be >= %s', key, tostring(minValue))
        end
        if maxValue and normalized > maxValue then
            return false, nil, string.format('%s must be <= %s', key, tostring(maxValue))
        end
    elseif valType == 'text' then
        if value == nil then return false, nil, string.format('%s expects text', key) end
        normalized = tostring(value)
    end

    if type(meta.Aliases) == 'table' then
        local alias = meta.Aliases[tostring(normalized):lower()]
        if alias ~= nil then normalized = alias end
    end

    if type(meta.Options) == 'table' and #meta.Options > 0 then
        local wanted = tostring(normalized):lower()
        local matched = nil
        for _, option in ipairs(meta.Options) do
            if tostring(option):lower() == wanted then matched = option break end
        end
        if matched == nil then
            return false, nil, string.format('%s must be one of: %s', key, table.concat(meta.Options, ', '))
        end
        normalized = matched
    end

    return true, normalized, nil
end

function M.validate(key, value)
    local meta = M.defaults[key]
    local ok, normalized = M.normalize(key, value)
    if ok then return normalized end
    return meta and meta.Default or value
end

function M.getValidator(key)
    return VALIDATORS[key]
end

function M.iter_all()
    if not _sortedKeys then
        _sortedKeys = {}
        for k, _ in pairs(M.defaults) do
            _sortedKeys[#_sortedKeys + 1] = k
        end
        table.sort(_sortedKeys)
    end
    local keys = _sortedKeys
    local i = 0
    return function()
        i = i + 1
        local k = keys[i]
        if not k then return nil end
        return i, k
    end
end

return M
