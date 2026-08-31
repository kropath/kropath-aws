#!/usr/bin/env python3
"""
Add .sortBy(x, x.key) after .transformList(k, v, {"key": k, "value": v})}
in all RGDs that lack it.

Special case: kmskey uses {"tagKey": k, "tagValue": v} → .sortBy(x, x.tagKey).

Run from the kropath-aws repo root:
    python3 scripts/add_sortby.py [--dry-run]
"""

import sys
import os
import re
import glob

DRY_RUN = "--dry-run" in sys.argv

# Pattern 1: standard {"key": k, "value": v} → sortBy x.key
KEY_PATTERN = re.compile(r'^( +)(\.transformList\(k, v, \{"key": k, "value": v\}\))\}')
# Pattern 2: kmskey {"tagKey": k, "tagValue": v} → sortBy x.tagKey
TAGKEY_PATTERN = re.compile(r'^( +)(\.transformList\(k, v, \{"tagKey": k, "tagValue": v\}\))\}')

changed_files = []

for path in sorted(glob.glob("rgds/*.yaml")):
    with open(path, encoding="utf-8") as f:
        lines = f.readlines()

    new_lines = []
    modified = False
    for line in lines:
        m = KEY_PATTERN.match(line)
        if m:
            indent = m.group(1)
            tl = m.group(2)
            new_lines.append(f"{indent}{tl}\n")
            new_lines.append(f"{indent}.sortBy(x, x.key)}}\n")
            modified = True
            continue

        m = TAGKEY_PATTERN.match(line)
        if m:
            indent = m.group(1)
            tl = m.group(2)
            new_lines.append(f"{indent}{tl}\n")
            new_lines.append(f"{indent}.sortBy(x, x.tagKey)}}\n")
            modified = True
            continue

        new_lines.append(line)

    if modified:
        changed_files.append(path)
        if not DRY_RUN:
            with open(path, "w", encoding="utf-8") as f:
                f.writelines(new_lines)
            print(f"  UPDATED  {path}")
        else:
            print(f"  DRY-RUN  {path}")

print(f"\nTotal files {'to update' if DRY_RUN else 'updated'}: {len(changed_files)}")
