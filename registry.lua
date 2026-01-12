local M = {}

M.defaults = {
    SideKickTheme = { type = 'text', Default = 'Classic', Category = 'UI', DisplayName = 'Theme' },
    SideKickSyncThemeWithGT = { type = 'bool', Default = true, Category = 'UI', DisplayName = 'Sync Theme With GroupTarget' },
    SideKickMainAnchor = { type = 'text', Default = 'none', Category = 'UI', DisplayName = 'Main Anchor (GroupTarget)' },
    SideKickMainAnchorTarget = { type = 'text', Default = 'grouptarget', Category = 'UI', DisplayName = 'Main Anchor Target' },
    SideKickMainAnchorGap = { type = 'number', Default = 2, Category = 'UI', DisplayName = 'Main Anchor Gap' },
    SideKickMainMatchGTWidth = { type = 'bool', Default = false, Category = 'UI', DisplayName = 'Main Match GroupTarget Width' },

    SideKickBarEnabled = { type = 'bool', Default = true, Category = 'Bar', DisplayName = 'Show Ability Bar' },
    SideKickBarCell = { type = 'number', Default = 48, Category = 'Bar', DisplayName = 'Cell Size' },
    SideKickBarRows = { type = 'number', Default = 2, Category = 'Bar', DisplayName = 'Rows' },
    SideKickBarGap = { type = 'number', Default = 4, Category = 'Bar', DisplayName = 'Gap' },
    SideKickBarPad = { type = 'number', Default = 6, Category = 'Bar', DisplayName = 'Padding' },
    SideKickBarBgAlpha = { type = 'number', Default = 0.85, Category = 'Bar', DisplayName = 'Background Alpha' },
    SideKickBarAnchorTarget = { type = 'text', Default = 'grouptarget', Category = 'Bar', DisplayName = 'Anchor Target' },
    SideKickBarAnchor = { type = 'text', Default = 'none', Category = 'Bar', DisplayName = 'Anchor Mode' },
    SideKickBarAnchorGap = { type = 'number', Default = 2, Category = 'Bar', DisplayName = 'Anchor Gap' },

    SideKickSpecialEnabled = { type = 'bool', Default = true, Category = 'Special', DisplayName = 'Show Special Abilities' },
    SideKickSpecialCell = { type = 'number', Default = 65, Category = 'Special', DisplayName = 'Cell Size' },
    SideKickSpecialRows = { type = 'number', Default = 1, Category = 'Special', DisplayName = 'Rows' },
    SideKickSpecialGap = { type = 'number', Default = 4, Category = 'Special', DisplayName = 'Gap' },
    SideKickSpecialPad = { type = 'number', Default = 6, Category = 'Special', DisplayName = 'Padding' },
    SideKickSpecialBgAlpha = { type = 'number', Default = 0.85, Category = 'Special', DisplayName = 'Background Alpha' },
    SideKickSpecialAnchorTarget = { type = 'text', Default = 'grouptarget', Category = 'Special', DisplayName = 'Anchor Target' },
    SideKickSpecialAnchor = { type = 'text', Default = 'none', Category = 'Special', DisplayName = 'Anchor Mode' },
    SideKickSpecialAnchorGap = { type = 'number', Default = 2, Category = 'Special', DisplayName = 'Anchor Gap' },

    SideKickDiscBarEnabled = { type = 'bool', Default = true, Category = 'Disciplines', DisplayName = 'Show Disciplines Bar' },
    SideKickDiscBarCell = { type = 'number', Default = 48, Category = 'Disciplines', DisplayName = 'Bar Cell Size' },
    SideKickDiscBarRows = { type = 'number', Default = 2, Category = 'Disciplines', DisplayName = 'Bar Rows' },
    SideKickDiscBarGap = { type = 'number', Default = 4, Category = 'Disciplines', DisplayName = 'Bar Gap' },
    SideKickDiscBarPad = { type = 'number', Default = 6, Category = 'Disciplines', DisplayName = 'Bar Padding' },
    SideKickDiscBarBgAlpha = { type = 'number', Default = 0.85, Category = 'Disciplines', DisplayName = 'Bar Background Alpha' },
    SideKickDiscBarAnchorTarget = { type = 'text', Default = 'grouptarget', Category = 'Disciplines', DisplayName = 'Bar Anchor Target' },
    SideKickDiscBarAnchor = { type = 'text', Default = 'none', Category = 'Disciplines', DisplayName = 'Bar Anchor Mode' },
    SideKickDiscBarAnchorGap = { type = 'number', Default = 2, Category = 'Disciplines', DisplayName = 'Bar Anchor Gap' },

    SideKickItemBarEnabled = { type = 'bool', Default = true, Category = 'Items', DisplayName = 'Show Item Bar' },
    SideKickItemBarCell = { type = 'number', Default = 40, Category = 'Items', DisplayName = 'Cell Size' },
    SideKickItemBarRows = { type = 'number', Default = 1, Category = 'Items', DisplayName = 'Rows' },
    SideKickItemBarGap = { type = 'number', Default = 4, Category = 'Items', DisplayName = 'Gap' },
    SideKickItemBarPad = { type = 'number', Default = 6, Category = 'Items', DisplayName = 'Padding' },
    SideKickItemBarBgAlpha = { type = 'number', Default = 0.85, Category = 'Items', DisplayName = 'Background Alpha' },
    SideKickItemBarAnchorTarget = { type = 'text', Default = 'grouptarget', Category = 'Items', DisplayName = 'Anchor Target' },
    SideKickItemBarAnchor = { type = 'text', Default = 'none', Category = 'Items', DisplayName = 'Anchor Mode' },
    SideKickItemBarAnchorGap = { type = 'number', Default = 2, Category = 'Items', DisplayName = 'Anchor Gap' },

    ChaseEnabled = { type = 'bool', Default = false, Category = 'Automation', DisplayName = 'Chase Enabled' },
    ChaseRole = { type = 'text', Default = 'ma', Category = 'Automation', DisplayName = 'Chase Role (none/ma/mt/leader/raid1/raid2/raid3)' },
    ChaseTarget = { type = 'text', Default = '', Category = 'Automation', DisplayName = 'Chase Target (name)' },
    ChaseDistance = { type = 'number', Default = 30, Category = 'Automation', DisplayName = 'Chase Distance' },

    AutomationLevel = { type = 'text', Default = 'auto', Category = 'Automation', DisplayName = 'Play Style (manual/hybrid/auto)' },
    AutoAbilitiesEnabled = { type = 'bool', Default = true, Category = 'Automation', DisplayName = 'Auto Abilities (AAs/Discs)' },
    AutoItemsEnabled = { type = 'bool', Default = true, Category = 'Automation', DisplayName = 'Auto Items (Clickies)' },

    MeditationMode = { type = 'text', Default = 'off', Category = 'Automation', DisplayName = 'Meditation (off/ooc/in combat)' },
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

    AssistEnabled = { type = 'bool', Default = false, Category = 'Automation', DisplayName = 'Assist Enabled' },
    AssistMode = { type = 'text', Default = 'group', Category = 'Automation', DisplayName = 'Assist Mode (group/raid1/raid2/raid3/byname)' },
    AssistName = { type = 'text', Default = '', Category = 'Automation', DisplayName = 'Assist Name (if byname)' },
    AssistAt = { type = 'number', Default = 97, Category = 'Automation', DisplayName = 'Assist At %' },
    AssistRange = { type = 'number', Default = 100, Category = 'Automation', DisplayName = 'Assist Range' },

    BurnActive = { type = 'bool', Default = false, Category = 'Automation', DisplayName = 'Burn Active' },
    BurnDuration = { type = 'number', Default = 30, Category = 'Automation', DisplayName = 'Burn Duration (sec)' },

    -- Combat Mode (Tank/Assist role selection)
    CombatMode = { type = 'text', Default = 'off', Category = 'Combat', DisplayName = 'Combat Mode (off/tank/assist)' },

    -- Tank Settings
    TankTargetMode = { type = 'text', Default = 'auto', Category = 'Combat', DisplayName = 'Tank Target Mode (auto/manual)' },
    TankAoEThreshold = { type = 'number', Default = 3, Category = 'Combat', DisplayName = 'AoE Mob Threshold' },
    TankRequireAggroDeficit = { type = 'bool', Default = true, Category = 'Combat', DisplayName = 'Require Aggro Deficit for AoE' },
    TankSafeAECheck = { type = 'bool', Default = false, Category = 'Combat', DisplayName = 'Safe AE Check (no mezzed)' },
    TankRepositionEnabled = { type = 'bool', Default = false, Category = 'Combat', DisplayName = 'Tank Repositioning' },
    TankRepositionCooldown = { type = 'number', Default = 5, Category = 'Combat', DisplayName = 'Reposition Cooldown (sec)' },

    -- Assist Settings (when in assist combat mode)
    AssistTargetMode = { type = 'text', Default = 'sticky', Category = 'Combat', DisplayName = 'Assist Target Mode (sticky/follow)' },
    AssistEngageCondition = { type = 'text', Default = 'hp', Category = 'Combat', DisplayName = 'Engage Condition (hp/tank_aggro)' },
    AssistEngageHpThreshold = { type = 'number', Default = 97, Category = 'Combat', DisplayName = 'Engage HP Threshold' },

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
    DebuffAutoSlow = { type = 'bool', Default = true, Category = 'Debuff', DisplayName = 'Auto-Slow' },
    DebuffAutoCripple = { type = 'bool', Default = false, Category = 'Debuff', DisplayName = 'Auto-Cripple' },
    DebuffAutoMalo = { type = 'bool', Default = true, Category = 'Debuff', DisplayName = 'Auto-Malo/Tash' },
    DebuffCoordinateActors = { type = 'bool', Default = true, Category = 'Debuff', DisplayName = 'Coordinate via Actors' },
    DebuffPrioritizeSelfHeal = { type = 'bool', Default = true, Category = 'Debuff', DisplayName = 'Prioritize Self/Group Heals' },
    DebuffSelfHealHpThreshold = { type = 'number', Default = 60, Category = 'Debuff', DisplayName = 'Self Heal HP Threshold' },
    DebuffGroupHealHpThreshold = { type = 'number', Default = 50, Category = 'Debuff', DisplayName = 'Group Heal HP Threshold' },

    -- Caster Assist Settings
    CasterUseStick = { type = 'bool', Default = false, Category = 'Combat', DisplayName = 'Caster Use Stick' },
    CasterEscapeRange = { type = 'number', Default = 30, Category = 'Combat', DisplayName = 'Caster Escape Range' },
    CasterSafeZoneRadius = { type = 'number', Default = 30, Category = 'Combat', DisplayName = 'Safe Zone Radius' },
    PreferredResistType = { type = 'text', Default = 'Any', Category = 'Combat', DisplayName = 'Preferred Resist Type' },

    -- Spell Rotation Settings
    SpellRotationEnabled = { type = 'bool', Default = false, Category = 'Combat', DisplayName = 'Spell Rotation Enabled' },
    RotationResetWindow = { type = 'number', Default = 2, Category = 'Combat', DisplayName = 'Rotation Reset Window (sec)' },
    RetryOnFizzle = { type = 'bool', Default = true, Category = 'Combat', DisplayName = 'Retry on Fizzle' },
    RetryOnResist = { type = 'bool', Default = true, Category = 'Combat', DisplayName = 'Retry on Resist' },
    RetryOnInterrupt = { type = 'bool', Default = true, Category = 'Combat', DisplayName = 'Retry on Interrupt' },
    UseImmuneDatabase = { type = 'bool', Default = true, Category = 'Combat', DisplayName = 'Use Immune Database' },

    -- Spell Lineup Settings
    SpellRescanOnZone = { type = 'bool', Default = true, Category = 'Spells', DisplayName = 'Rescan Gems on Zone' },
    HealThreshold = { type = 'number', Default = 80, Category = 'Spells', DisplayName = 'Heal HP Threshold' },
    HealPetsEnabled = { type = 'bool', Default = false, Category = 'Spells', DisplayName = 'Heal Pets' },

    -- Healing (rgmercs-style tiers; excludes PAL in implementation)
    DoHeals = { type = 'bool', Default = false, Category = 'Heal/Rez', DisplayName = 'Enable Heals' },
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
    CCEnabled = { type = 'bool', Default = true, Category = 'CC', DisplayName = 'CC Enabled' },
    CCCoordinateActors = { type = 'bool', Default = true, Category = 'CC', DisplayName = 'Coordinate via Actors' },
    CCPrioritizeSelfHeal = { type = 'bool', Default = true, Category = 'CC', DisplayName = 'Prioritize Self Heals/Runes' },
    CCSelfHealHpThreshold = { type = 'number', Default = 60, Category = 'CC', DisplayName = 'Self Heal HP Threshold' },
    CCMaxMezTargets = { type = 'number', Default = 3, Category = 'CC', DisplayName = 'Max Mez Targets' },

    -- Mez Casting Settings (ENC, BRD, NEC)
    MezzingEnabled = { type = 'bool', Default = false, Category = 'CC', DisplayName = 'Mezzing Enabled' },
    MezMinLevel = { type = 'number', Default = 0, Category = 'CC', DisplayName = 'Mez Min Level (skip grey cons)' },
    MezMaxTargets = { type = 'number', Default = 3, Category = 'CC', DisplayName = 'Max Mobs to Mez' },
    UseAEMez = { type = 'bool', Default = false, Category = 'CC', DisplayName = 'Use AE Mez' },
    AEMezMinTargets = { type = 'number', Default = 3, Category = 'CC', DisplayName = 'AE Mez Min Targets' },
    UseFastMez = { type = 'bool', Default = true, Category = 'CC', DisplayName = 'Use Fast Mez' },
    MezRefreshWindow = { type = 'number', Default = 6, Category = 'CC', DisplayName = 'Mez Refresh Window (sec)' },

    -- Spell Engine Settings
    SpellRole = { type = 'text', Default = 'default', Category = 'Spells', DisplayName = 'Spell Role' },
    SpellUseGem = { type = 'number', Default = 13, Category = 'Spells', DisplayName = 'Rotation Gem Slot' },
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

    -- Spell Loadout Settings
    SpellLoadout = { type = 'text', Default = '' , Category = 'Spells', DisplayName = 'Spell Loadout' },
    AutoDetectSpellChanges = { type = 'bool', Default = true, Category = 'Spells', DisplayName = 'Auto-Detect Spell Changes' },

    -- Buff Settings
    BuffingEnabled = { type = 'bool', Default = true, Category = 'Buffs', DisplayName = 'Enable Buffing' },
    BuffRebuffWindow = { type = 'number', Default = 60, Category = 'Buffs', DisplayName = 'Rebuff Window (seconds)' },
    BuffSelfOnly = { type = 'bool', Default = false, Category = 'Buffs', DisplayName = 'Self Buffs Only' },
    BuffAllowInCombat = { type = 'bool', Default = false, Category = 'Buffs', DisplayName = 'Allow Buffing In Combat' },
    BuffGroupEnabled = { type = 'bool', Default = true, Category = 'Buffs', DisplayName = 'Buff Group Members' },
    BuffPetsEnabled = { type = 'bool', Default = true, Category = 'Buffs', DisplayName = 'Buff Pets' },
    BuffRaidEnabled = { type = 'bool', Default = false, Category = 'Buffs', DisplayName = 'Buff Raid Members' },
    BuffFellowshipEnabled = { type = 'bool', Default = false, Category = 'Buffs', DisplayName = 'Buff Fellowship' },
    BuffCoordinateActors = { type = 'bool', Default = true, Category = 'Buffs', DisplayName = 'Coordinate via Actors' },

    ActorsEnabled = { type = 'bool', Default = true, Category = 'Integration', DisplayName = 'Enable Actors' },

    -- Safe Targeting (KS Prevention)
    SafeTargetingEnabled = { type = 'bool', Default = true, Category = 'Combat', DisplayName = 'Safe Targeting (KS Prevention)' },
    SafeTargetingCheckRaid = { type = 'bool', Default = true, Category = 'Combat', DisplayName = 'Safe Targeting: Check Raid Members' },
    SafeTargetingCheckPeers = { type = 'bool', Default = true, Category = 'Combat', DisplayName = 'Safe Targeting: Check Actor Peers' },

    -- Combat/Targeting: Auto Stand from Feign Death
    AutoStandFD = { type = 'bool', Default = false, Category = 'Combat', DisplayName = 'Auto Stand from FD' },

    -- Combat/Targeting: MA Scan Z-Axis Range
    MAScanZRange = { type = 'number', Default = 100, Category = 'Combat', DisplayName = 'MA Scan Z Range' },

    -- AssistOutside: Enable assisting group, raid, and actor peers
    AssistOutsideGroup = { type = 'bool', Default = true, Category = 'Combat', DisplayName = 'Assist Outside: Group Members' },
    AssistOutsideRaid = { type = 'bool', Default = true, Category = 'Combat', DisplayName = 'Assist Outside: Raid Members' },
    AssistOutsidePeers = { type = 'bool', Default = true, Category = 'Combat', DisplayName = 'Assist Outside: Actor Peers (Same Zone)' },

    -- Healing: Rez Settings
    DoCombatRez = { type = 'bool', Default = false, Category = 'Heal/Rez', DisplayName = 'Combat Rez Enabled' },
    DoOutOfCombatRez = { type = 'bool', Default = true, Category = 'Heal/Rez', DisplayName = 'Out of Combat Rez Enabled' },

    -- Healing: Emergency Settings
    EmergencyHealPct = { type = 'number', Default = 20, Category = 'Heal/Rez', DisplayName = 'Emergency Heal Pct' },

    -- Buffing: Aura Selection
    AuraSelection = { type = 'text', Default = '', Category = 'Buffs', DisplayName = 'Aura Selection' },

    -- Cure Settings
    DoCures = { type = 'bool', Default = true, Category = 'Heal/Rez', DisplayName = 'Enable Cures' },
    CurePrioritySelf = { type = 'bool', Default = false, Category = 'Heal/Rez', DisplayName = 'Cure Self First' },
    CureInCombat = { type = 'bool', Default = true, Category = 'Heal/Rez', DisplayName = 'Cure During Combat' },
    CureCoordinateActors = { type = 'bool', Default = true, Category = 'Heal/Rez', DisplayName = 'Coordinate Cures via Actors' },
}

function M.meta(key)
    return M.defaults[key]
end

function M.iter_all()
    local keys = {}
    for k, _ in pairs(M.defaults) do
        table.insert(keys, k)
    end
    table.sort(keys)
    local i = 0
    return function()
        i = i + 1
        local k = keys[i]
        if not k then return nil end
        return i, k
    end
end

return M
