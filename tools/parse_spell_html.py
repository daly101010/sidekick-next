#!/usr/bin/env python3
"""
Spell HTML Parser for EverQuest Cleric Spells

This script parses saved HTML files from raidloot.com to extract spell families
and identify missing spell categories for the SideKick automation system.

Usage:
    python3 parse_spell_html.py <path_to_html_file>

Example:
    python3 parse_spell_html.py ../data/Cleric\ Spell\ List

The script will:
1. Extract all spells from the HTML file
2. Group them into spell families (removing rank suffixes)
3. Display spell families with 3+ spells
4. Save a complete list to /tmp/all_spell_families.txt
"""

import re
import subprocess
import sys
from collections import defaultdict


def extract_spells_from_html(html_file_path):
    """
    Extract spell names and levels from a saved HTML file.

    Args:
        html_file_path: Path to the HTML file (can contain spaces)

    Returns:
        List of dicts with 'name' and 'level' keys
    """
    # Use strings to extract text content from the HTML file
    result = subprocess.run(
        ['strings', html_file_path],
        capture_output=True,
        text=True,
        check=True
    )

    # Extract table cell contents that match the <td>content</td> pattern
    cell_result = subprocess.run(
        ['bash', '-c', f'strings "{html_file_path}" | grep -oP \'(?<=<td>)[^<]+(?=</td>)\''],
        capture_output=True,
        text=True
    )

    cells = [c.strip() for c in cell_result.stdout.split('\n') if c.strip()]

    # Parse spells from cells
    # Pattern is: Name, Level, ManaCost, CastTime, Recast, Duration, Resist, Target, Effects
    spells = []
    i = 0
    while i < len(cells):
        name = cells[i]
        if i + 1 < len(cells):
            level = cells[i + 1]
            # Check if level is numeric
            if level.isdigit():
                spells.append({'name': name, 'level': level})
                i += 9  # Skip to next spell (9 cells per row)
            else:
                i += 1
        else:
            break

    return spells


def get_base_spell_name(spell_name):
    """
    Extract base spell name without rank or version numbers.

    Examples:
        "Avowed Remedy Rk. III" -> "Avowed Remedy"
        "Yaulp XI" -> "Yaulp"
        "Desperate Renewal XIII" -> "Desperate Renewal"

    Args:
        spell_name: Full spell name

    Returns:
        Base spell name without rank/version
    """
    # Remove rank indicators (Rk. I, Rk. II, etc.)
    name = re.sub(r'\s+Rk\.\s+[IVX]+$', '', spell_name)
    # Remove roman numerals at end
    name = re.sub(r'\s+[IVX]+$', '', name)
    return name


def group_spells_by_family(spells):
    """
    Group spells into families based on base name.

    Args:
        spells: List of spell dicts with 'name' and 'level'

    Returns:
        Dict mapping base name to list of spell dicts
    """
    families = defaultdict(list)

    for spell in spells:
        base_name = get_base_spell_name(spell['name'])
        families[base_name].append(spell)

    return families


def display_spell_families(families, min_family_size=3):
    """
    Display spell families sorted by size.

    Args:
        families: Dict mapping base name to list of spells
        min_family_size: Minimum number of spells to display a family
    """
    sorted_families = sorted(families.items(), key=lambda x: len(x[1]), reverse=True)

    print("=" * 100)
    print(f"SPELL FAMILIES WITH {min_family_size}+ SPELLS")
    print("=" * 100)

    count = 0
    for base_name, spell_list in sorted_families:
        if len(spell_list) >= min_family_size:
            count += 1
            # Sort spells by level (newest first)
            sorted_spells = sorted(
                spell_list,
                key=lambda x: int(x['level']) if x['level'].isdigit() else 0,
                reverse=True
            )

            print(f"\n{count}. {base_name} ({len(spell_list)} spells)")
            # Show up to 5 highest level spells
            for spell in sorted_spells[:5]:
                print(f"   Lv{spell['level']:>3}: {spell['name']}")


def save_all_families(families, output_file='/tmp/all_spell_families.txt'):
    """
    Save all spell families to a text file.

    Args:
        families: Dict mapping base name to list of spells
        output_file: Path to output file
    """
    sorted_families = sorted(families.items(), key=lambda x: len(x[1]), reverse=True)

    with open(output_file, 'w') as f:
        for base_name, spell_list in sorted_families:
            if len(spell_list) >= 3:
                sorted_spells = sorted(
                    spell_list,
                    key=lambda x: int(x['level']) if x['level'].isdigit() else 0,
                    reverse=True
                )
                f.write(f"\n{base_name} ({len(spell_list)} spells):\n")
                for spell in sorted_spells:
                    f.write(f"  Lv{spell['level']:>3}: {spell['name']}\n")

    print(f"\n\nFull spell family list saved to: {output_file}")


def main():
    """Main entry point for the spell parser."""
    if len(sys.argv) != 2:
        print("Usage: python3 parse_spell_html.py <path_to_html_file>")
        print("\nExample:")
        print("  python3 parse_spell_html.py ../data/Cleric\\ Spell\\ List")
        sys.exit(1)

    html_file = sys.argv[1]

    print(f"Parsing spell data from: {html_file}")
    print("-" * 100)

    # Extract spells
    spells = extract_spells_from_html(html_file)
    print(f"Found {len(spells)} spells\n")

    # Group into families
    families = group_spells_by_family(spells)

    # Display families
    display_spell_families(families, min_family_size=3)

    # Save all families to file
    save_all_families(families)

    print("\n" + "=" * 100)
    print("TIP: Review /tmp/all_spell_families.txt to identify missing spell categories")
    print("     for your CLR.lua spellLines section.")
    print("=" * 100)


if __name__ == '__main__':
    main()
