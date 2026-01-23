-- F:/lua/sidekick/sk_spells_clr.lua
-- Cleric spell lines for SideKick multi-script system
-- Spells ordered highest to lowest level within each line
-- Data sourced from Allakhazam EverQuest spell database

local M = {}

-- Healing spell lines
M.Heals = {
    -- Fast single-target heals (Remedy line)
    Remedy = {
        'Holy Remedy XIV',        -- 126
        'Avowed Remedy',          -- 121
        'Guileless Remedy',       -- 116
        'Sincere Remedy',         -- 111
        'Promised Remedy',        -- 108
        'Merciful Remedy',        -- 106
        'Spiritual Remedy',       -- 101
        'Graceful Remedy',        -- 96
        'Faithful Remedy',        -- 91
        'Earnest Remedy',         -- 86
        'Devout Remedy',          -- 81
        'Solemn Remedy',          -- 76
        'Sacred Remedy',          -- 71
        'Pious Remedy',           -- 66
        'Supernal Remedy',        -- 61
        'Ethereal Remedy',        -- 59
        'Remedy',                 -- 51
    },

    -- Big fast heals (Intervention line)
    Intervention = {
        'Eminent Intervention',   -- 128
        'Avowed Intervention',    -- 123
        'Atoned Intervention',    -- 118
        'Sincere Intervention',   -- 113
        'Merciful Intervention',  -- 108
        'Anticipated Intervention', -- 107
        'Mystical Intervention',  -- 103
        'Virtuous Intervention',  -- 98
        'Elysian Intervention',   -- 93
        'Celestial Intervention', -- 88
        'Holy Intervention',      -- 83
        'Divine Intervention',    -- 60
    },

    -- Large heal with recast (Renewal line)
    Renewal = {
        'Desperate Renewal XIII', -- 130
        'Promised Renewal XII',   -- 128
        'Heroic Renewal',         -- 125
        'Determined Renewal',     -- 120
        'Dire Renewal',           -- 115
        'Furial Renewal',         -- 110
        'Fervid Renewal',         -- 105
        'Fraught Renewal',        -- 100
        'Fervent Renewal',        -- 95
        'Frenzied Renewal',       -- 90
        'Frenetic Renewal',       -- 85
        'Frantic Renewal',        -- 80
        'Promised Renewal',       -- 73
        'Desperate Renewal',      -- 70
    },

    -- Promised heal (delayed/conditional)
    Promised = {
        'Promised Remediation',   -- 123
        'Promised Reclamation',   -- 118
        'Promised Redemption',    -- 113
        'Promised Remedy',        -- 108
        'Promised Rehabilitation', -- 103
        'Promised Reformation',   -- 98
        'Promised Restitution',   -- 93
        'Promised Resurgence',    -- 88
        'Promised Recuperation',  -- 83
        'Promised Restoration',   -- 78
        'Promised Renewal',       -- 73
    },

    -- Basic Healing line (classic direct heals)
    Basic = {
        'Superior Healing',       -- 30
        'Greater Healing',        -- 20
        'Healing',                -- 10
        'Light Healing',          -- 4
        'Minor Healing',          -- 1
    },

    -- Complete Heal
    CompleteHeal = {
        'Complete Heal',          -- 39
    },
}

-- Group heal spell lines
M.GroupHeals = {
    -- Word of... group heals
    Word = {
        'Word of Replenishment XIII', -- 129
        'Word of Wellbeing',      -- 126
        'Word of Greater Vivification', -- 124
        'Word of Acceptance',     -- 121
        'Word of Greater Rejuvenation', -- 120
        'Word of Redress',        -- 116
        'Word of Greater Replenishment', -- 115
        'Word of Soothing',       -- 111
        'Word of Greater Restoration', -- 110
        'Word of Mending',        -- 106
        'Word of Greater Reformation', -- 105
        'Word of Convalescence',  -- 101
        'Word of Reformation',    -- 100
        'Word of Renewal',        -- 96
        'Word of Rehabilitation', -- 95
        'Word of Resurgence',     -- 90
        'Word of Recovery',       -- 85
        'Word of Vivacity',       -- 80
        'Word of Vivification',   -- 69
        'Word of Replenishment',  -- 64
        'Word of Redemption',     -- 60
        'Word of Restoration',    -- 57
        'Word of Vigor',          -- 52
        'Word of Healing',        -- 45
        'Word of Health',         -- 30
    },
}

-- HoT (Heal over Time) spell lines
M.HoT = {
    -- Elixir line (group HoT)
    Elixir = {
        'Elixir of Absolution',   -- 130
        'Eminent Elixir',         -- 127
        'Elixir of Realization',  -- 125
        'Avowed Elixir',          -- 122
        'Elixir of Benevolence',  -- 120
        'Hallowed Elixir',        -- 117
        'Elixir of Transcendence', -- 115
        'Elixir of Wulthan',      -- 110
        'Merciful Elixir',        -- 107
        'Elixir of the Seas',     -- 105
        'Ardent Elixir',          -- 102
        'Elixir of the Acquittal', -- 100
        'Elixir of the Beneficent', -- 95
        'Elixir of the Ardent',   -- 90
        'Elixir of Atonement',    -- 80
        'Solemn Elixir',          -- 77
        'Elixir of Redemption',   -- 75
        'Elixir of Divinity',     -- 70
        'Pious Elixir',           -- 67
        'Holy Elixir',            -- 65
        'Ethereal Elixir',        -- 60
        'Celestial Elixir',       -- 59
    },

    -- Celestial line (older HoT)
    Celestial = {
        'Celestial Elixir',       -- 59
        'Celestial Healing',      -- 44
        'Celestial Health',       -- 29
        'Celestial Remedy',       -- 19
    },
}

-- Direct single-target heals
M.DirectHeals = {
    -- Light line (efficient direct heals)
    Light = {
        'Eminent Light',          -- 128
        'Avowed Light',           -- 123
        'Fervent Light',          -- 118
        'Sincere Light',          -- 113
        'Merciful Light',         -- 108
        'Ardent Light',           -- 103
        'Reverent Light',         -- 98
        'Zealous Light',          -- 93
        'Earnest Light',          -- 88
        'Devout Light',           -- 83
        'Solemn Light',           -- 78
        'Sacred Light',           -- 73
        'Ancient Hallowed Light', -- 70
        'Divine Light',           -- 53
    },

    -- Splash line (targeted AE heals)
    Splash = {
        'Flourishing Splash',     -- 130
        'Acceptance Splash',      -- 125
        'Refreshing Splash',      -- 120
        'Restoring Splash',       -- 115
        'Mending Splash',         -- 110
        'Convalescent Splash',    -- 105
        'Reforming Splash',       -- 100
        'Rejuvenating Splash',    -- 95
        'Healing Splash',         -- 90
    },
}

-- Reactive/Guardian heals
M.Reactive = {
    -- Divine line (reactive heals/wards)
    Divine = {
        'Divine Magnitude',       -- 129
        'Divine Interstition',    -- 127
        'Divine Rejoinder',       -- 124
        'Divine Interference',    -- 122
        'Divine Liturgy',         -- 122
        'Divine Contingency',     -- 118
        'Divine Mediation',       -- 117
        'Divine Bulwark',         -- 117
        'Divine Consequence',     -- 113
        'Divine Reaction',        -- 108
        'Divine Jurisdiction',    -- 107
        'Divine Response',        -- 102
        'Divine Indemnification', -- 102
        'Divine Indemnity',       -- 102
        'Divine Invocation',      -- 92
        'Divine Guard',           -- 92
        'Divine Intercession',    -- 87
        'Divine Fortitude',       -- 87
        'Divine Eminence',        -- 82
        'Divine Destiny',         -- 77
        'Divine Custody',         -- 72
    },
}

-- Damage spell lines
M.Damage = {
    -- Contravention (nuke + heal hybrid)
    Contravention = {
        'Eminent Contravention',  -- 130
        'Avowed Contravention',   -- 125
        'Divine Contravention',   -- 120
        'Sincere Contravention',  -- 115
        'Merciful Contravention', -- 110
        'Ardent Contravention',   -- 105
        'Virtuous Contravention', -- 100
        'Elysian Contravention',  -- 95
        'Celestial Contravention', -- 90
        'Holy Contravention',     -- 85
    },

    -- Undead damage line
    Undead = {
        'Expunge the Undead',     -- 129
        'Banish the Undead',      -- 121
        'Extirpate the Undead',   -- 116
        'Obliterate the Undead',  -- 111
        'Repudiate the Undead',   -- 106
        'Eradicate the Undead',   -- 101
        'Abrogate the Undead',    -- 96
        'Abolish the Undead',     -- 91
        'Annihilate the Undead',  -- 86
        'Desolate Undead',        -- 68
        'Destroy Undead',         -- 64
        'Exile Undead',           -- 55
        'Banish Undead',          -- 43
        'Expel Undead',           -- 33
        'Dismiss Undead',         -- 23
        'Expulse Undead',         -- 13
        'Ward Undead',            -- 4
    },

    -- Sermon line (DD + stun hybrid)
    Sermon = {
        'Sermon of Eminence',     -- 127
        'Sermon of the Decree',   -- 121
        'Sermon of Repentance',   -- 118
        'Sermon of Injunction',   -- 113
        'Sermon of Sanction',     -- 108
        'Sermon of Justice',      -- 103
        'Sermon of Rebuke',       -- 98
        'Sermon of Condemnation', -- 93
        'Sermon of Censure',      -- 88
        'Sermon of Castigation',  -- 83
        'Sermon of Admonition',   -- 78
        'Sermon of Reproach',     -- 67
        'Sermon of Penitence',    -- 62
        'Sermon of the Righteous', -- 25
    },
}

-- Stun spell lines
M.Stuns = {
    -- Silent line (fast stun)
    Silent = {
        'Silent Injunction',      -- 129
        'Silent Doctrine',        -- 124
        'Silent Seal',            -- 119
        'Silent Writ',            -- 114
        'Silent Directive',       -- 109
        'Silent Behest',          -- 104
        'Silent Order',           -- 99
        'Silent Mandate',         -- 94
        'Silent Proclamation',    -- 89
        'Silent Edict',           -- 84
        'Silent Dictum',          -- 79
        'Silent Decree',          -- 74
        'Silent Command',         -- 65
    },

    -- Sound line (AE stun)
    Sound = {
        'Sound of Providence',    -- 118
        'Sound of Rebuke',        -- 113
        'Sound of Wrath',         -- 108
        'Sound of Thunder',       -- 103
        'Sound of Plangency',     -- 98
        'Sound of Fervor',        -- 93
        'Sound of Fury',          -- 88
        'Sound of Reverberance',  -- 83
        'Sound of Resonance',     -- 78
        'Sound of Zeal',          -- 73
        'Sound of Divinity',      -- 68
        'Sound of Might',         -- 63
        'Sound of Force',         -- 46
    },

    -- Awe line (DD + stun)
    Awe = {
        'Aweblast',               -- 116
        'Aweflash',               -- 111
        'Awestrike',              -- 106
        'Awecrush',               -- 101
        'Aweclash',               -- 96
        'Aweburst',               -- 91
        'Awecrash',               -- 86
        'Aweshake',               -- 81
        'Aweshock',               -- 76
        'Awestruck',              -- 71
        'Shock of Wonder',        -- 66
    },
}

-- Debuff spell lines
M.Debuffs = {
    -- Mark line (AC/atk debuff)
    Mark = {
        'Mark of the Righteous XIV', -- 129
        'Mark of Thormir',        -- 124
        'Mark of Ezra',           -- 119
        'Mark of Wenglawks',      -- 114
        'Mark of Shandral',       -- 109
        'Mark of the Vicarum',    -- 104
        'Mark of the Zealot',     -- 99
        'Mark of Tohan',          -- 97
        'Mark of the Adherent',   -- 94
        'Mark of Erion',          -- 92
        'Mark of the Devout',     -- 89
        'Mark of the Devoted',    -- 79
        'Mark of the Martyr',     -- 74
        'Mark of the Blameless',  -- 69
        'Mark of the Righteous',  -- 65
        'Mark of Kings',          -- 64
        'Mark of Karn',           -- 56
        'Mark of Retribution',    -- 54
    },
}

-- Buff spell lines
M.Buffs = {
    -- Symbol (HP buff)
    Symbol = {
        'Symbol of Sharosh',      -- 126
        'Symbol of Helmsbane',    -- 121
        'Symbol of Sanguineous',  -- 116
        'Symbol of Jorlleag',     -- 111
        'Symbol of Emra',         -- 106
        'Symbol of Nonia',        -- 101
        'Symbol of Gezat',        -- 96
        'Symbol of the Triumvirate', -- 91
        'Symbol of Ealdun',       -- 86
        'Symbol of Darianna',     -- 81
        'Symbol of Kaerra',       -- 76
        'Symbol of Elushar',      -- 71
        'Symbol of Balikor',      -- 66
        'Symbol of Kazad',        -- 61
        'Symbol of Marzin',       -- 54
        'Symbol of Naltron',      -- 41
        'Symbol of Pinzarn',      -- 31
        'Symbol of Ryltan',       -- 21
        'Symbol of Transal',      -- 11
    },

    -- Shining (HP aura buff)
    Shining = {
        'Shining Rampart IX',     -- 130
        'Shining Steel',          -- 124
        'Shining Fortitude',      -- 119
        'Shining Aegis',          -- 114
        'Shining Fortress',       -- 109
        'Shining Bulwark',        -- 104
        'Shining Bastion',        -- 99
        'Shining Armor',          -- 94
        'Shining Rampart',        -- 89
    },

    -- Hand (spell haste)
    Hand = {
        'Hand of Devotion',       -- 122
        'Hand of Devoutness',     -- 117
        'Hand of Reverence',      -- 112
        'Hand of Zeal',           -- 102
        'Hand of Fervor',         -- 97
        'Hand of Assurance',      -- 92
    },

    -- Benediction (group spell haste)
    Benediction = {
        'Benediction of Devotion', -- 121
        'Benediction of Resplendence', -- 116
        'Benediction of Reverence', -- 111
        'Benediction of Piety',   -- 101
        'Blessing of Assurance',  -- 91
    },

    -- Unity (combined group buff)
    Unity = {
        'Unity of Sharosh',       -- 126
        'Unity of Helmsbane',     -- 121
        'Unity of the Sanguine',  -- 116
        'Unity of Jorlleag',      -- 111
        'Unity of Emra',          -- 106
        'Unity of Nonia',         -- 101
        'Unity of Gezat',         -- 96
        'Unity of the Triumvirate', -- 91
    },

    -- Yaulp (self buff - HP/mana regen, haste)
    Yaulp = {
        'Yaulp XIX',              -- 126
        'Yaulp XVIII',            -- 121
        'Yaulp XVII',             -- 116
        'Yaulp XVI',              -- 111
        'Yaulp XV',               -- 106
        'Yaulp XIV',              -- 101
        'Yaulp XIII',             -- 96
        'Yaulp XII',              -- 91
        'Yaulp XI',               -- 86
        'Yaulp X',                -- 81
        'Yaulp IX',               -- 76
        'Yaulp VIII',             -- 71
        'Yaulp VII',              -- 69
        'Yaulp VI',               -- 65
        'Yaulp V',                -- 56
        'Yaulp IV',               -- 53
        'Yaulp III',              -- 41
        'Yaulp II',               -- 16
        'Yaulp',                  -- 1
    },
}

-- Ward/absorption spell lines
M.Wards = {
    -- Vie line (damage absorption)
    Vie = {
        'Rallied Bulwark of Vie', -- 130
        'Rallied Ward of Vie XVI', -- 128
        'Rallied Citadel of Vie', -- 125
        'Greater Aegis of Vie',   -- 123
        'Rallied Sanctuary of Vie', -- 120
        'Rallied Greater Blessing of Vie', -- 120
        'Greater Bulwark of Vie', -- 118
        'Rallied Greater Protection of Vie', -- 115
        'Greater Protection of Vie', -- 113
        'Rallied Greater Guard of Vie', -- 110
        'Greater Guard of Vie',   -- 108
        'Rallied Greater Ward of Vie', -- 105
        'Greater Ward of Vie',    -- 103
        'Rallied Bastion of Vie', -- 100
        'Bastion of Vie',         -- 98
        'Rallied Armor of Vie',   -- 95
        'Armor of Vie',           -- 93
        'Rallied Rampart of Vie', -- 90
        'Rampart of Vie',         -- 88
        'Rallied Palladium of Vie', -- 85
        'Palladium of Vie',       -- 83
        'Rallied Shield of Vie',  -- 80
        'Shield of Vie',          -- 78
        'Rallied Aegis of Vie',   -- 75
        'Aegis of Vie',           -- 73
        'Panoply of Vie',         -- 67
        'Bulwark of Vie',         -- 62
        'Protection of Vie',      -- 54
        'Guard of Vie',           -- 40
        'Ward of Vie',            -- 20
    },
}

-- Aura spell lines
M.Auras = {
    -- HP auras
    HPAura = {
        'Divine Magnitude',       -- 129
        'Bastion of Divinity',    -- 120
        'Aura of the Persistent', -- 119
        'Aura of the Reverent',   -- 100
        'Aura of Divinity',       -- 100
        'Aura of Loyalty',        -- 82
        'Aura of Resolve',        -- 77
        'Aura of Purpose',        -- 72
        'Aura of the Pious',      -- 70
        'Aura of Devotion',       -- 69
        'Aura of the Zealot',     -- 55
    },
}

-- Resurrection spell lines
M.Resurrection = {
    Rez = {
        'Resurrection',           -- 47
        'Revive',                 -- 27
        'Reanimation',            -- 12
    },
}

-- Cure spell lines
M.Cures = {
    -- Purify line
    Purify = {
        'Purified Ground',        -- 113
        'Purified Blood',         -- 84
        'Pure Blood',             -- 51
    },

    -- Blood cure line (poison/disease removal)
    Blood = {
        'Mastery Sanctified Blood', -- 129
        'Sanctified Blood',       -- 119
        'Expurgated Blood',       -- 109
        'Unblemished Blood',      -- 104
        'Cleansed Blood',         -- 99
        'Blood of the Adherent',  -- 95
        'Perfected Blood',        -- 94
        'Blood of the Devout',    -- 90
        'Purged Blood',           -- 89
        'Pristine Blood',         -- 87
        'Blood of the Unsullied', -- 85
        'Purified Blood',         -- 84
        'Blood of the Devoted',   -- 80
        'Blood of the Martyr',    -- 75
    },

    -- Basic cures
    Disease = { 'Cure Disease' }, -- 4
    Poison = { 'Cure Poison' },   -- 1
    Blindness = { 'Cure Blindness' }, -- 3
}

-- Self buff spell lines
M.SelfBuffs = {
    -- Armor line (HP/AC self buff)
    Armor = {
        'Armor of the Eminent',   -- 130
        'Armor of the Avowed',    -- 125
        'Armor of Penance',       -- 120
        'Armor of Sincerity',     -- 115
        'Armor of the Merciful',  -- 110
        'Armor of the Ardent',    -- 105
        'Armor of the Reverent',  -- 100
        'Armor of the Zealous',   -- 95
        'Armor of the Earnest',   -- 90
        'Armor of the Devout',    -- 85
        'Armor of the Solemn',    -- 80
        'Armor of the Sacred',    -- 75
        'Armor of the Pious',     -- 70
        'Armor of the Zealot',    -- 65
        'Blessed Armor of the Risen', -- 58
        'Armor of the Faithful',  -- 49
        'Armor of Protection',    -- 34
    },

    -- Glow line (reaction radius self buff)
    Glow = {
        'Tranquil Glow',          -- 126
        'Congenial Glow',         -- 121
        'Contenting Glow',        -- 116
        'Placating Glow',         -- 111
        'Mollifying Glow',        -- 106
        'Pacifying Glow',         -- 101
        'Soothing Glow',          -- 96
    },

    -- Vow line (self buff)
    Vow = {
        'Vow of Vitriol XI',      -- 128
        'Vow of Valor XI',        -- 126
        'Vow of Retribution',     -- 123
        'Vow of Virtuosity',      -- 121
        'Vow of Perniciousness',  -- 118
        'Vow of Tenacity',        -- 116
        'Vow of Vituperation',    -- 113
        'Vow of Veracity',        -- 111
        'Vow of Vengeance',       -- 108
        'Vow of Vigilance',       -- 106
        'Vow of Virulence',       -- 103
        'Vow of Vigor',           -- 101
        'Vow of Vehemence',       -- 98
        'Vow of Vitality',        -- 96
        'Vow of Veneration',      -- 91
        'Vow of Vanquishing',     -- 86
        'Vow of Valiance',        -- 81
        'Vow of Victory',         -- 76
        'Vow of Valor',           -- 71
    },

    -- Aegolism / Hand line (HP buff, consolidated)
    Aegolism = {
        'Unified Hand of Infallibility', -- 125
        'Unified Hand of Persistence', -- 120
        'Unified Hand of Righteousness', -- 115
        'Unified Hand of Assurance', -- 110
        'Unified Hand of Surety', -- 105
        'Unified Hand of Certitude', -- 100
        'Unified Hand of Credence', -- 95
        'Hand of Reliance',       -- 90
        'Hand of Gallantry',      -- 85
        'Hand Of Temerity',       -- 80
        'Hand of Tenacity',       -- 75
        'Hand of Conviction',     -- 70
        'Hand of Virtue',         -- 65
        'Blessing of Aegolism',   -- 60
        'Blessing of Temperance', -- 60
        'Aegolism',               -- 60
        'Temperance',             -- 60
        'Valor',                  -- 55
        'Bravery',                -- 50
        'Daring',                 -- 45
        'Center',                 -- 40
        'Courage',                -- 30
    },
}

-- Proc buff spell lines
M.Procs = {
    -- Retort line (heal proc on target)
    Retort = {
        'Hazuri\'s Retort',       -- 125
        'Axoeviq\'s Retort',      -- 120
        'Jorlleag\'s Retort',     -- 115
        'Curate\'s Retort',       -- 110
        'Vicarum\'s Retort',      -- 105
        'Olsif\'s Retort',        -- 100
        'Galvos\' Retort',        -- 95
        'Fintar\'s Retort',       -- 90
    },
}

-- Persistent/Ground heal spell lines
M.Persistent = {
    -- Ground line (persistent AE heal)
    Ground = {
        'Resplendent Ground',     -- 125
        'Venerated Ground',       -- 118
        'Purified Ground',        -- 113
        'Blessed Ground',         -- 108
        'Glorified Ground',       -- 98
        'Anointed Ground',        -- 93
        'Sanctified Ground',      -- 88
        'Holy Ground',            -- 83
        'Hallowed Ground',        -- 78
        'Consecrate Ground',      -- 73
    },

    -- Issuance line (healing pet)
    Issuance = {
        'Issuance of Eminence',   -- 130
        'Issuance of Heroism',    -- 123
        'Issuance of Conviction', -- 118
        'Issuance of Sincerity',  -- 113
        'Issuance of Mercy',      -- 108
        'Issuance of Spirit',     -- 103
        'Issuance of Grace',      -- 98
        'Issuance of Faith',      -- 93
    },
}

-- Additional damage spell lines
M.AEDamage = {
    -- Tectonic line (PB AE damage)
    Tectonic = {
        'Tectonic Quake XVI',     -- 130
        'Tectonic Bedlam',        -- 125
        'Tectonic Shadowvent',    -- 119
        'Tectonic Frostheave',    -- 114
        'Tectonic Eruption',      -- 109
        'Tectonic Destruction',   -- 104
        'Tectonic Temblor',       -- 99
        'Tectonic Tremor',        -- 94
        'Tectonic Shock',         -- 89
        'Tectonic Tumult',        -- 84
        'Tectonic Upheaval',      -- 79
        'Tectonic Quake',         -- 74
    },

    -- Hammer line (DD)
    Hammer = {
        'Hammer of Eminence',     -- 127
        'Hammer of the Remembered', -- 122
        'Hammer of Penance',      -- 117
        'Hammer of Obliteration', -- 112
        'Hammer of Repudiation',  -- 107
        'Ardent Hammer of Zeal',  -- 104
        'Hammer of Reverence',    -- 97
        'Hammer of Reproach',     -- 68
        'Hammer of Damnation',    -- 63
        'Hammer of Souls',        -- 60
        'Hammer of Divinity',     -- 58
        'Hammer of Judgment',     -- 56
        'Hammer of Requital',     -- 40
        'Hammer of Striking',     -- 20
        'Hammer of Wrath',        -- 7
    },
}

-- Acquittal heal line
M.Heals.Acquittal = {
    'Eminent Acquittal',      -- 129
    'Avowed Acquittal',       -- 124
    'Devout Acquittal',       -- 119
    'Sincere Acquittal',      -- 114
    'Merciful Acquittal',     -- 109
    'Ardent Acquittal',       -- 104
    'Cleansing Acquittal',    -- 99
}

-- Ward line (defensive buff, NOT Vie absorption)
M.Wards.Ward = {
    'Ward of Retribution',    -- 127
    'Ward of Eminence',       -- 126
    'Ward of Repudiation',    -- 122
    'Ward of Commitment',     -- 122
    'Ward of the Avowed',     -- 121
    'Ward of Persistence',    -- 117
    'Ward of Prohibition',    -- 117
    'Ward of the Guileless',  -- 116
    'Ward of Injunction',     -- 112
    'Ward of Righteousness',  -- 112
    'Ward of Sincerity',      -- 111
    'Ward of Assurance',      -- 107
    'Ward of Condemnation',   -- 107
    'Ward of Censure',        -- 102
    'Ward of Surety',         -- 102
    'Ward of Indictment',     -- 97
    'Ward of Certitude',      -- 97
    'Ward of the Reverent',   -- 96
    'Ward of Recrimination',  -- 92
    'Ward of the Zealous',    -- 91
    'Ward of Retaliation',    -- 87
    'Ward of the Earnest',    -- 86
    'Ward of Admonishment',   -- 82
    'Ward of the Devout',     -- 81
    'Ward of Requital',       -- 77
    'Ward of the Resolute',   -- 76
    'Ward of Reprisal',       -- 72
    'Ward of the Dauntless',  -- 71
}

-- Chromatic damage line
M.Damage.Chromatic = {
    'Chromaclast',            -- 129
    'Chromaruption',          -- 124
    'Chromablast',            -- 119
    'Chromaflare',            -- 114
    'Chromaburst',            -- 109
    'Chromabash',             -- 104
    'Chromacrush',            -- 99
    'Chromacleave',           -- 94
    'Chromarend',             -- 89
    'Chromassail',            -- 84
    'Chromassault',           -- 79
    'Chromastrike',           -- 69
}

-- Corruption cure line
M.Cures.Corruption = {
    'Mastery Purge Corruption', -- 129
    'Defy Corruption',        -- 128
    'Purge Corruption',       -- 119
    'Deny Corruption',        -- 118
    'Extricate Corruption',   -- 109
    'Endure Corruption',      -- 108
    'Nullify Corruption',     -- 104
    'Abrogate Corruption',    -- 99
    'Thwart Corruption',      -- 98
    'Eradicate Corruption',   -- 94
    'Dissolve Corruption',    -- 89
    'Reject Corruption',      -- 88
    'Abolish Corruption',     -- 84
    'Repel Corruption',       -- 83
    'Vitiate Corruption',     -- 79
    'Forbear Corruption',     -- 78
    'Expunge Corruption',     -- 64
    'Resist Corruption',      -- 63
}

-- Unyielding damage line (high damage DD)
M.Damage.Unyielding = {
    'Unyielding Denunciation', -- 129
    'Unyielding Admonition',  -- 124
    'Unyielding Rebuke',      -- 119
    'Unyielding Censure',     -- 114
    'Unyielding Judgment',    -- 109
}

-- Glorious damage line (triple DD)
M.Damage.Glorious = {
    'Glorious Judgment',      -- 104
    'Glorious Rebuke',        -- 99
    'Glorious Admonition',    -- 94
    'Glorious Censure',       -- 89
    'Glorious Denunciation',  -- 84
}

-- Unified group buff lines
M.GroupBuffs = {
    -- Unified self buff (combined self buff)
    Unified = {
        'Unified Aegolism XV',    -- 127
        'Unified Commitment',     -- 122
        'Unified Righteousness',  -- 112
        'Unified Assurance',      -- 107
        'Unified Surety',         -- 102
        'Unified Certitude',      -- 97
        'Unified Credence',       -- 92
    },
}

-- Category to default slot type mapping
M.DEFAULT_SLOT_TYPES = {
    -- Combat essential (rotation)
    Heals = 'rotation',
    GroupHeals = 'rotation',
    HoT = 'rotation',
    DirectHeals = 'rotation',
    Reactive = 'rotation',
    Damage = 'rotation',
    Stuns = 'rotation',
    Debuffs = 'rotation',
    Cures = 'rotation',
    AEDamage = 'rotation',

    -- OOC acceptable (buff_swap)
    Buffs = 'buff_swap',
    Auras = 'buff_swap',
    SelfBuffs = 'buff_swap',
    Wards = 'buff_swap',
    GroupBuffs = 'buff_swap',
    Procs = 'buff_swap',
    Persistent = 'buff_swap',
    Resurrection = 'buff_swap',
}

--- Enumerate all spell lines with their category
-- @return table Array of {category, lineName, spells, defaultSlotType}
function M.enumerateLines()
    local lines = {}

    -- Helper to process a category table
    local function processCategory(categoryName, categoryTable)
        if type(categoryTable) ~= 'table' then return end

        for lineName, spells in pairs(categoryTable) do
            if type(spells) == 'table' and #spells > 0 then
                table.insert(lines, {
                    category = categoryName,
                    lineName = lineName,
                    spells = spells,
                    defaultSlotType = M.DEFAULT_SLOT_TYPES[categoryName] or 'rotation',
                })
            end
        end
    end

    -- Process all categories
    processCategory('Heals', M.Heals)
    processCategory('GroupHeals', M.GroupHeals)
    processCategory('HoT', M.HoT)
    processCategory('DirectHeals', M.DirectHeals)
    processCategory('Reactive', M.Reactive)
    processCategory('Damage', M.Damage)
    processCategory('Stuns', M.Stuns)
    processCategory('Debuffs', M.Debuffs)
    processCategory('Cures', M.Cures)
    processCategory('AEDamage', M.AEDamage)
    processCategory('Buffs', M.Buffs)
    processCategory('Auras', M.Auras)
    processCategory('SelfBuffs', M.SelfBuffs)
    processCategory('Wards', M.Wards)
    processCategory('GroupBuffs', M.GroupBuffs)
    processCategory('Procs', M.Procs)
    processCategory('Persistent', M.Persistent)
    processCategory('Resurrection', M.Resurrection)

    -- Sort by category then line name
    table.sort(lines, function(a, b)
        if a.category ~= b.category then
            return a.category < b.category
        end
        return a.lineName < b.lineName
    end)

    return lines
end

--- Get a specific spell line by name
-- @param lineName string The line name (e.g., "Remedy")
-- @return table|nil The spell list or nil if not found
function M.getLine(lineName)
    for _, lineData in ipairs(M.enumerateLines()) do
        if lineData.lineName == lineName then
            return lineData
        end
    end
    return nil
end

return M
