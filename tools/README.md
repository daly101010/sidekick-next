# Spell Data Extraction Tools

This directory contains tools for extracting and analyzing EverQuest spell data from online databases to keep the SideKick spell lists up to date.

## Quick Start

```bash
# 1. Save the spell page from raidloot.com as HTML
# 2. Run the parser
cd tools
python3 parse_spell_html.py ../data/Cleric\ Spell\ List

# 3. Review the output and /tmp/all_spell_families.txt
# 4. Add missing spell lines to ../data/class_configs/CLR.lua
```

## Tools

### `parse_spell_html.py`

Parses saved HTML files from raidloot.com to extract spell families and identify missing spell categories.

**Usage:**
```bash
python3 parse_spell_html.py <path_to_html_file>
```

**What it does:**
1. Extracts all spells from the HTML file
2. Groups them into spell families (removing rank suffixes like "Rk. III")
3. Displays spell families with 3+ spells
4. Saves complete list to `/tmp/all_spell_families.txt`

**Example Output:**
```
Found 1391 spells

====================================================================================================
SPELL FAMILIES WITH 3+ SPELLS
====================================================================================================

1. Yaulp (23 spells)
   Lv126: Yaulp XIX
   Lv126: Yaulp XIX Rk. III
   Lv121: Yaulp XVIII Rk. II
   ...

2. Promised Renewal (3 spells)
   Lv128: Promised Renewal XII
   Lv128: Promised Renewal XII Rk. III
   ...
```

## How to Extract Spell Pages

### Method 1: Save Complete HTML (Recommended)

1. **Navigate to raidloot.com spell list:**
   - Go to https://www.raidloot.com/spells/cleric
   - Or for other classes: https://www.raidloot.com/spells/<classname>

2. **Save the complete page:**
   - **Chrome/Edge:** Ctrl+S (Cmd+S on Mac) → Save as "Webpage, Complete"
   - **Firefox:** Ctrl+S (Cmd+S on Mac) → Save as "Web Page, complete"
   - **Safari:** File → Save As → Format: "Web Archive"

3. **Move the saved file:**
   ```bash
   mv ~/Downloads/Cleric\ Spell\ List.html data/Cleric\ Spell\ List
   ```

4. **Run the parser:**
   ```bash
   python3 tools/parse_spell_html.py data/Cleric\ Spell\ List
   ```

### Method 2: Using Browser Developer Tools

If you're comfortable with browser DevTools:

1. Open the spell list page
2. Press F12 to open DevTools
3. Go to the Elements/Inspector tab
4. Right-click on `<html>` → Copy → Copy outerHTML
5. Save to a file:
   ```bash
   # Paste clipboard content into a file
   pbpaste > data/Cleric\ Spell\ List  # macOS
   xclip -o > data/Cleric\ Spell\ List  # Linux
   ```

### Method 3: wget/curl (May be blocked)

⚠️ **Warning:** raidloot.com has anti-bot protection, so this may not work:

```bash
# This will likely fail due to bot protection
wget -O data/Cleric_Spell_List.html "https://www.raidloot.com/spells/cleric"
```

## Updating Spell Lists

After extracting spell families, follow these steps to update the spell lists:

### 1. Identify Missing Categories

Review the parser output and `/tmp/all_spell_families.txt` to find spell families that aren't in your current `data/class_configs/CLR.lua` file.

**Existing spell lines in CLR.lua:**
- Remedy (fast heals)
- Renewal (big heals)
- Intervention (heal + nuke)
- Contravention (nuke + heal)
- GroupHealCure (Word of...)
- GroupFastHeal (Syllable of...)
- PromisedHeal
- SingleHoT (Elixir)
- GroupHoT (Acquittal/Elixir)
- Yaulp
- Symbol (HP buff)
- Shining (damage shield)
- UndeadNuke
- MagicNuke
- CureDisease/Poison/Curse/Corruption/All
- CureDiseaseGroup

### 2. Add Missing Spell Lines

Edit `data/class_configs/CLR.lua` and add new spell lines in the `spellLines` section:

```lua
spellLines = {
    -- Existing spell lines...

    -- New category
    ["SplashHeal"] = {
        "Flourishing Splash", "Acceptance Splash", "Convalescent Splash",
        "Mending Splash", "Reforming Splash", "Refreshing Splash",
        "Rejuvenating Splash", "Restoring Splash", "Healing Splash",
    },

    -- Another new category
    ["VieWard"] = {
        "Rallied Bulwark of Vie", "Greater Bulwark of Vie",
        -- Add in newest-to-oldest order
    },
},
```

**Important Guidelines:**
- List spells in **newest to oldest** order (highest level first)
- Include the base spell name (without "Rk. II", "Rk. III", etc.)
- Keep categories that match the existing cleric spell role (healing, buffs, cures, etc.)
- Use descriptive category names that reflect the spell's purpose

### 3. Test and Commit

```bash
# Stage your changes
git add data/class_configs/CLR.lua

# Commit with a descriptive message
git commit -m "Add missing cleric spell lines: SplashHeal, VieWard, etc."

# Push to your branch
git push -u origin your-branch-name
```

## Other Classes

This same process works for other classes:

```bash
# Save the spell list page for a different class
# Example: https://www.raidloot.com/spells/druid

# Parse it
python3 tools/parse_spell_html.py data/Druid\ Spell\ List

# Update the corresponding file
# data/class_configs/DRU.lua
```

## Troubleshooting

### "File not found" error
Make sure you're using the correct path to the HTML file. If the filename has spaces, wrap it in quotes or escape them:
```bash
python3 parse_spell_html.py "../data/Cleric Spell List"
# or
python3 parse_spell_html.py ../data/Cleric\ Spell\ List
```

### "Found 0 spells"
The HTML file might not be in the expected format. Make sure you:
1. Saved the *complete* webpage (not just the HTML source)
2. The page loaded fully before saving (wait for all spells to appear)
3. You're using a file from raidloot.com (not allakhazam or other sites)

### Binary file matches (grep warning)
This is normal - the HTML file contains binary data (images). The script handles this with the `strings` command.

## Tips

- **Keep HTML files for reference:** Save the HTML files in `data/` for future reference and version tracking
- **Check multiple sources:** Cross-reference with allakhazam.com or EQ Resource if a spell seems incorrect
- **Version numbers:** EverQuest frequently adds new spell ranks, so check for updates regularly
- **Spell progression:** Most spell lines follow a progression (I, II, III... or names like Avowed, Guileless, Sincere)

## Future Improvements

Potential enhancements for these tools:
- [ ] Direct API integration with spell databases (if available)
- [ ] Automatic comparison with existing CLR.lua to highlight only new spells
- [ ] Support for parsing other spell databases (allakhazam, EQ Resource)
- [ ] Validation of spell level progressions
- [ ] Detection of deprecated spells that should be removed

## Questions?

If you encounter issues or have suggestions for improving these tools, please open an issue on GitHub.
