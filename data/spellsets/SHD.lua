-- F:/lua/SideKick/data/spellsets/SHD.lua
-- Shadow Knight Spellsets - Role-based spell loadouts with spell line definitions

return {
    roles = {
        tank = {
            name = "Tank Focused",
            gems = {
                [1] = { spellLine = "Terror", priority = 1 },
                [2] = { spellLine = "AETaunt", priority = 1 },
                [3] = { spellLine = "ForPower", priority = 1 },
                [4] = { spellLine = "LifeTap", priority = 1 },
                [5] = { spellLine = "DireTap", priority = 2 },
                [6] = { spellLine = "SpearNuke", priority = 2 },
                [7] = { spellLine = "DichoSpell", priority = 2 },
                [8] = { spellLine = "TempHP", priority = 3 },
                [9] = { spellLine = "BondTap", priority = 3 },
            },
        },
        dps = {
            name = "DPS Focused",
            gems = {
                [1] = { spellLine = "LifeTap", priority = 1 },
                [2] = { spellLine = "DireTap", priority = 1 },
                [3] = { spellLine = "DichoSpell", priority = 1 },
                [4] = { spellLine = "SpearNuke", priority = 1 },
                [5] = { spellLine = "BondTap", priority = 2 },
                [6] = { spellLine = "BiteTap", priority = 2 },
                [7] = { spellLine = "PoisonDot", priority = 2 },
                [8] = { spellLine = "CorruptionDot", priority = 3 },
                [9] = { spellLine = "DireDot", priority = 3 },
            },
        },
        dot = {
            name = "DOT Heavy",
            gems = {
                [1] = { spellLine = "PoisonDot", priority = 1 },
                [2] = { spellLine = "CorruptionDot", priority = 1 },
                [3] = { spellLine = "DireDot", priority = 1 },
                [4] = { spellLine = "BondTap", priority = 1 },
                [5] = { spellLine = "DichoSpell", priority = 2 },
                [6] = { spellLine = "LifeTap", priority = 2 },
                [7] = { spellLine = "DireTap", priority = 2 },
                [8] = { spellLine = "SpearNuke", priority = 3 },
                [9] = { spellLine = "Terror", priority = 3 },
            },
        },
    },
    spellLines = {
        -- Lifetaps
        ["LifeTap"] = {
            "Touch of Drendar", "Touch of Lutzen", "Touch of Urash",
            "Touch of Dyalgem", "Touch of T`Vem", "Touch of Vizat",
            "Touch of Holmein", "Touch of Fallon", "Touch of the Wailing Three",
            "Touch of Innoruuk", "Drain Soul",
        },
        ["DireTap"] = {
            "Dire Rebuke", "Dire Censure", "Dire Testimony",
            "Dire Indictment", "Dire Conviction", "Dire Declaration",
            "Dire Accusation", "Dire Implication",
        },
        ["BondTap"] = {
            "Bond of Inruku", "Bond of Tatalros", "Bond of Vulak",
            "Bond of Xalgoz", "Bond of Bonemaw", "Bond of Rallos",
            "Bond of Mortality", "Bond of Death", "Vampiric Curse",
        },
        ["BiteTap"] = {
            "Distasteful Bargain", "Repugnant Bargain", "Abhorrent Bargain",
            "Odious Bargain", "Loathsome Bargain", "Despicable Bargain",
            "Grisly Bargain", "Ghastly Bargain", "Vile Bargain",
        },
        ["MaxHPTap"] = {
            "Tylix's Swift Sundering", "Cadcane's Swift Sundering",
            "Brightfeld's Swift Sundering", "Mortimus' Swift Sundering",
        },
        -- Nukes
        ["SpearNuke"] = {
            "Spike of Disease", "Spear of Disease", "Spear of Pain",
            "Spear of Plague", "Spear of Decay", "Spear of Muram",
            "Spear of Vizat", "Spear of Tylix", "Spear of Cadcane",
            "Spear of Bloodwretch", "Spear of Grelleth",
        },
        -- DOTs
        ["PoisonDot"] = {
            "Blood of Shoru", "Blood of Tearc", "Blood of Ikatiar",
            "Blood of Drakus", "Blood of Bonemaw", "Blood of Ralstok",
            "Blood of Korum", "Blood of Malthiasiss", "Blood of Laarthik",
            "Blood of the Blackwater", "Blood of the Blacktalon",
            "Blood of Inruku", "Blood of Discord", "Blood of Hate",
        },
        ["CorruptionDot"] = {
            "Perfidious Blight", "Surreptitious Blight", "Deceitful Blight",
            "Duplicitous Blight", "Nefarious Blight", "Unscrupulous Blight",
            "Vitriolic Blight", "Insidious Blight",
        },
        ["DireDot"] = {
            "Dire Stenching",
        },
        -- Aggro spells
        ["Terror"] = {
            "Terror of Rerekalen", "Terror of Desalin", "Terror of Kra`Du",
            "Terror of Jelvalak", "Terror of Darkness", "Terror of Discord",
            "Terror of Thule", "Terror of Death", "Terror of Shadows",
        },
        ["AETaunt"] = {
            "Animus", "Antipathy", "Contempt", "Revulsion", "Disgust",
            "Abhorrence", "Loathing", "Burst of Spite", "Revile", "Vilify",
            "Dread Gaze",
        },
        ["ForPower"] = {
            "For Power", "Impose for Power", "Assert for Power",
            "Protest for Power", "Demand for Power", "Petition for Power",
        },
        -- Dicho
        ["DichoSpell"] = {
            "Reciprocal Theft", "Ecliptic Theft", "Composite Theft",
            "Dissident Theft", "Dichotomic Theft",
        },
        -- Temp HP
        ["TempHP"] = {
            "Pestilent Darkness", "Virulent Darkness", "Malignant Darkness",
            "Foul Darkness", "Miasmic Darkness", "Nefarious Darkness",
            "Corrosive Darkness", "Maleficent Darkness",
        },
        -- Pet
        ["PetSpell"] = {
            "Minion of Fandrel", "Minion of Itzal", "Minion of Drendar",
            "Minion of T`Vem", "Minion of Vizat", "Minion of Grelleth",
            "Minion of Sholoth", "Minion of Fear", "Minion of Sebilis",
            "Maladroit Minion", "Son of Decay", "Invoke Death",
        },
        ["PetHaste"] = {
            "Gift of Fandrel", "Gift of Itzal", "Gift of Drendar",
            "Gift of T`Vem", "Gift of Lutzen", "Gift of Urash",
            "Gift of Dyalgem", "Expatiate Death", "Amplify Death",
            "Rune of Decay", "Augmentation of Death",
        },
        -- Buffs
        ["Shroud"] = {
            "Shroud of Rimeclaw", "Shroud of Zelinstein", "Shroud of the Restless",
            "Shroud of the Krellnakor", "Shroud of the Doomscale",
            "Shroud of the Darksworn", "Shroud of the Shadeborne",
            "Shroud of the Plagueborne", "Shroud of the Blightborn",
            "Shroud of the Gloomborn", "Shroud of the Nightborn",
        },
        ["Horror"] = {
            "Mortimus' Horror", "Brightfeld's Horror", "Cadcane's Horror",
            "Tylix's Horror", "Vizat's Horror", "Grelleth's Horror",
            "Sholothian Horror", "Amygdalan Horror", "Mindshear Horror",
            "Soulthirst Horror", "Marrowthirst Horror", "Shroud of Discord",
        },
        ["Mental"] = {
            "Mental Retchedness", "Mental Anguish", "Mental Torment",
            "Mental Fright", "Mental Dread", "Mental Terror",
            "Mental Horror", "Mental Corruption",
        },
        ["Skin"] = {
            "Krizad's Skin", "Xenacious' Skin", "Cadcane's Skin",
            "Tylix's Skin", "Vizat's Skin", "Grelleth's Skin",
            "Sholothian Skin", "Gorgon Skin", "Malarian Skin",
            "Umbral Skin", "Decrepit Skin",
        },
        ["SelfDS"] = {
            "Goblin Skin", "Tekuel Skin", "Specter Skin", "Helot Skin",
            "Zombie Skin", "Ghoul Skin", "Banshee Skin", "Banshee Aura",
        },
        ["CloakHP"] = {
            "Drape of the Ankexfen", "Drape of the Akheva",
            "Drape of the Iceforged", "Drape of the Magmaforged",
            "Drape of the Wrathforged", "Drape of the Fallen",
            "Drape of the Sepulcher", "Drape of Fear", "Drape of Korafax",
        },
        ["Covenant"] = {
            "Kar's Covenant", "Aten Ha Ra's Covenant", "Syl`Tor Covenant",
            "Helot Covenant", "Livio's Covenant", "Falhotep's Covenant",
            "Worag's Covenant", "Gixblat's Covenant", "Venril's Covenant",
        },
        ["CallAtk"] = {
            "Call of Blight", "Penumbral Call", "Call of Twilight",
            "Call of Nightfall", "Call of Gloomhaze", "Call of Shadow",
            "Call of Dusk", "Call of Darkness",
        },
        ["Demeanor"] = {
            "Impenitent Demeanor", "Remorseless Demeanor",
        },
        ["HealBurn"] = {
            "Paradoxical Disruption", "Penumbral Disruption",
            "Confluent Disruption", "Concordant Disruption",
            "Harmonious Disruption",
        },
        -- Snare
        ["SnareDot"] = {
            "Encroaching Darkness", "Cascading Darkness", "Clinging Darkness",
            "Engulfing Darkness", "Dooming Darkness", "Festering Darkness",
        },
        -- Mantle/Carapace
        ["Mantle"] = {
            "Geomimus Mantle", "Fyrthek Mantle", "Restless Mantle",
            "Krellnakor Mantle", "Doomscale Mantle", "Bonebrood Mantle",
            "Recondite Mantle", "Gorgon Mantle", "Malarian Mantle",
            "Umbral Carapace", "Soul Carapace", "Soul Shield", "Soul Guard",
        },
        ["Carapace"] = {
            "Kanghammer's Carapace", "Xetheg's Carapace", "Cadcane's Carapace",
            "Tylix's Carapace", "Vizat's Carapace", "Grelleth's Carapace",
            "Sholothian Carapace", "Gorgon Carapace",
        },
        -- Alliance
        ["AllianceNuke"] = {
            "Bloodletting Coalition", "Bloodletting Covenant",
            "Bloodletting Alliance",
        },
        -- Acrimony (aggrolock)
        ["Acrimony"] = {
            "Acrimony", "Antipathy",
        },
        -- Spite Strike
        ["SpiteStrike"] = {
            "Spite of Ronak", "Spite of Kra`Du", "Spite of Mirenilla",
        },
    },
}
