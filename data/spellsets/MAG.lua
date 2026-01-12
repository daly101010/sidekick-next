-- F:/lua/SideKick/data/spellsets/MAG.lua
-- Magician Spellsets - Role-based spell loadouts with spell line definitions

return {
    roles = {
        dps = {
            name = "DPS Focused",
            gems = {
                [1] = { spellLine = "SpearNuke", priority = 1 },
                [2] = { spellLine = "ChaoticNuke", priority = 1 },
                [3] = { spellLine = "VolleyNuke", priority = 1 },
                [4] = { spellLine = "SwarmPet", priority = 2 },
                [5] = { spellLine = "MaloNuke", priority = 2 },
                [6] = { spellLine = "SummonedNuke", priority = 2 },
                [7] = { spellLine = "ShortDurDmgShield", priority = 3 },
                [8] = { spellLine = "LongDurDmgShield", priority = 3 },
            },
        },
        pettank = {
            name = "Pet Tank",
            gems = {
                [1] = { spellLine = "SpearNuke", priority = 1 },
                [2] = { spellLine = "ChaoticNuke", priority = 1 },
                [3] = { spellLine = "VolleyNuke", priority = 1 },
                [4] = { spellLine = "SwarmPet", priority = 2 },
                [5] = { spellLine = "SurgeDS1", priority = 2 },
                [6] = { spellLine = "LongDurDmgShield", priority = 2 },
                [7] = { spellLine = "ManaRegenBuff", priority = 3 },
                [8] = { spellLine = "SelfShield", priority = 3 },
            },
        },
        aoe = {
            name = "AoE DPS",
            gems = {
                [1] = { spellLine = "BeamNuke", priority = 1 },
                [2] = { spellLine = "RainNuke", priority = 1 },
                [3] = { spellLine = "MagicRainNuke", priority = 1 },
                [4] = { spellLine = "SwarmPet", priority = 2 },
                [5] = { spellLine = "SpearNuke", priority = 2 },
                [6] = { spellLine = "ChaoticNuke", priority = 2 },
                [7] = { spellLine = "ShortDurDmgShield", priority = 3 },
                [8] = { spellLine = "LongDurDmgShield", priority = 3 },
            },
        },
    },
    spellLines = {
        -- Nukes
        ["SpearNuke"] = {
            "Spear of Molten Dacite", "Spear of Molten Luclinite",
            "Spear of Molten Komatiite", "Spear of Molten Arcronite",
            "Spear of Molten Shieldstone", "Spear of Blistersteel",
            "Spear of Molten Steel", "Spear of Magma", "Spear of Ro",
        },
        ["ChaoticNuke"] = {
            "Chaotic Magma", "Chaotic Calamity", "Chaotic Pyroclasm",
            "Chaotic Inferno", "Chaotic Fire", "Fickle Magma",
            "Fickle Flames", "Fickle Flare", "Fickle Blaze",
            "Fickle Pyroclasm", "Fickle Inferno", "Fickle Fire",
        },
        ["VolleyNuke"] = {
            "Fusillade of Many", "Barrage of Many", "Shockwave of Many",
            "Volley of Many", "Storm of Many", "Salvo of Many",
            "Strike of Many", "Clash of Many", "Jolt of Many", "Shock of Many",
        },
        ["SummonedNuke"] = {
            "Dismantle the Unnatural", "Unmend the Unnatural",
            "Obliterate the Unnatural", "Repudiate the Unnatural",
            "Eradicate the Unnatural", "Exterminate the Unnatural",
            "Abolish the Divergent", "Annihilate the Divergent",
            "Annihilate the Anomalous", "Annihilate the Aberrant",
        },
        ["MaloNuke"] = {
            "Memorial Steel Malosinera", "Carbide Malosinetra",
            "Blistersteel Malosenia", "Darksteel Malosenete",
            "Arcronite Malosinata", "Burning Malosinara",
        },
        -- Swarm Pet
        ["SwarmPet"] = {
            "Ravening Servant", "Roiling Servant", "Riotous Servant",
            "Reckless Servant", "Remorseless Servant", "Relentless Servant",
            "Ruthless Servant", "Ruinous Servant", "Rumbling Servant",
            "Rancorous Servant", "Rampaging Servant", "Raging Servant",
            "Rage of Zomm",
        },
        -- AoE Nukes
        ["BeamNuke"] = {
            "Beam of Molten Dacite", "Beam of Molten Olivine",
            "Beam of Molten Komatiite", "Beam of Molten Rhyolite",
            "Beam of Molten Shieldstone", "Beam of Brimstone",
            "Beam of Molten Steel", "Beam of Rhyolite",
            "Beam of Molten Scoria", "Beam of Molten Dross",
        },
        ["RainNuke"] = {
            "Rain of Molten Dacite", "Rain of Molten Olivine",
            "Rain of Molten Komatiite", "Rain of Molten Rhyolite",
            "Coronal Rain", "Rain of Blistersteel", "Rain of Molten Steel",
            "Rain of Rhyolite", "Rain of Molten Scoria",
            "Rain of Jerikor", "Sun Storm", "Sirocco", "Rain of Lava",
        },
        ["MagicRainNuke"] = {
            "Rain of Kukris", "Rain of Falchions", "Rain of Blades",
            "Rain of Spikes", "Rain Of Swords", "ManaStorm",
            "Maelstrom of Electricity", "Maelstrom of Thunder",
        },
        -- Low level nukes
        ["FireDD"] = {
            "Burning Sand", "Scars of Sigil", "Lava Bolt", "Cinder Bolt",
            "Bolt of Flame", "Shock of Flame", "Flame Bolt", "Burn", "Burst of Flame",
        },
        ["MagicDD"] = {
            "Blade Strike", "Rock of Taelosia", "Black Steel", "Shock of Steel",
            "Shock of Swords", "Shock of Spikes", "Shock of Blades",
        },
        -- Damage Shields
        ["ShortDurDmgShield"] = {
            "Boiling Skin", "Scorching Skin", "Burning Skin", "Blistering Skin",
            "Coronal Skin", "Infernal Skin", "Molten Skin", "Blazing Skin",
            "Torrid Skin", "Brimstoneskin", "Searing Skin",
            "Ancient: Veil of Pyrilonus", "Pyrilen Skin",
        },
        ["LongDurDmgShield"] = {
            "Circle of Forgefire Coat", "Forgefire Coat",
            "Circle of Emberweave Coat", "Emberweave Coat",
            "Circle of Igneous Skin", "Igneous Coat",
            "Circle of the Inferno", "Inferno Coat",
            "Circle of Flameweaving", "Flameweave Coat",
            "Circle of Flameskin", "Flameskin",
            "Circle of Embers", "Embercoat",
        },
        ["SurgeDS1"] = {
            "Surge of Shadow", "Surge of Arcanum",
            "Surge of Shadowflares", "Surge of Thaumacretion",
        },
        -- Self Buffs
        ["SelfShield"] = {
            "Shield of Memories", "Shield of Shadow", "Shield of Restless Ice",
            "Shield of Scales", "Shield of the Pellarus", "Shield of the Dauntless",
            "Shield of Bronze", "Shield of Dreams", "Shield of the Void",
            "Prime Guard", "Prime Shielding", "Elemental Aura",
            "Shield of Maelin", "Shield of the Arcane", "Shield of the Magi",
        },
        ["ManaRegenBuff"] = {
            "Courageous Guardian", "Relentless Guardian", "Restless Guardian",
            "Burning Guardian", "Praetorian Guardian", "Phantasmal Guardian",
            "Splendrous Guardian", "Cognitive Guardian", "Empyrean Guardian",
            "Eidolic Guardian", "Phantasmal Warden", "Phantom Shield",
        },
        -- Alliance
        ["AllianceBuff"] = {
            "Firebound Covariance", "Firebound Conjunction",
            "Firebound Coalition", "Firebound Covenant", "Firebound Alliance",
        },
        -- Twincast
        ["TwinCast"] = {
            "Twincast",
        },
    },
}
