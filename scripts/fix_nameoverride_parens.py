#!/usr/bin/env python3
"""
fix_nameoverride_parens.py

Fixes the CEL operator precedence bug in RGD effectiveName expressions:

  BROKEN:  ${(A ? B : C).split("{tag.").transform...replace...}
  - `.split()` has higher precedence than `?:` in CEL, so it binds
    only to the false branch C, not to the whole ternary.

  FIXED:   ${((A ? B : C)).split("{tag.").transform...replace...}
  - The extra `(...)` wraps the entire ternary before `.split()`.

Two edits per occurrence (both in the multi-line effectiveName format):
  1. Line containing `${(schema.spec.nameOverride != ""`
     → change `${(schema.spec.nameOverride` to `${((schema.spec.nameOverride`
  2. The line immediately before `.split("{tag.")` that ends with `))`
     → change trailing `))` to `)))`

Single-line `includeWhen` variants (cognitouserpool, snstopic) already use
`!((A ? B : C).split(...))` which is correct — skip those (their prev line
does NOT end with `))` alone).
"""
import sys
import glob
import os

DRY_RUN = "--dry-run" in sys.argv

rgd_dir = os.path.join(os.path.dirname(__file__), "..", "rgds")
files = sorted(glob.glob(os.path.join(rgd_dir, "*.yaml")))

total_files_changed = 0
total_edits = 0

for path in files:
    with open(path, "r") as f:
        lines = f.readlines()

    new_lines = lines[:]
    edits = []

    for i, line in enumerate(lines):
        stripped = line.rstrip("\n")

        # Edit 1: open-paren fix on the nameOverride condition line
        # Only fix `${(schema.spec.nameOverride` (single `(`), not `${((` (already fixed)
        if "${(schema.spec.nameOverride != \"\"" in stripped and "${((schema.spec.nameOverride" not in stripped:
            fixed = stripped.replace(
                "${(schema.spec.nameOverride != \"\"",
                "${((schema.spec.nameOverride != \"\"",
                1,
            )
            new_lines[i] = fixed + "\n"
            edits.append((i + 1, "open-paren", stripped.rstrip(), fixed.rstrip()))

        # Edit 2: close-paren fix on the line immediately before the token-substitution chain.
        # The chain can start with:
        #   .split("{tag.")   — standard tag-token substitution path
        #   .replace("{       — direct replace path (athenapreparedstatement, ecs* RGDs)
        # The line before the chain must end with `))` (after stripping trailing whitespace)
        # and NOT already end with `)))` (already fixed).
        if i + 1 < len(lines):
            next_stripped = lines[i + 1].strip()
            stripped_rstrip = stripped.rstrip()
            is_chain_start = (
                next_stripped.startswith('.split("{tag.")')
                or next_stripped.startswith('.replace("{')
            )
            if (
                is_chain_start
                and stripped_rstrip.endswith("))")
                and not stripped_rstrip.endswith(")))")
            ):
                # Add one extra `)` at the end of this line's content
                indent = len(stripped) - len(stripped.lstrip())
                content = stripped_rstrip
                fixed = content + ")"
                new_lines[i] = fixed + "\n"
                edits.append((i + 1, "close-paren", content, fixed))

    if edits:
        total_files_changed += 1
        total_edits += len(edits)
        rel = os.path.relpath(path, os.path.join(os.path.dirname(__file__), ".."))
        print(f"\n{'[DRY-RUN] ' if DRY_RUN else ''}Patching {rel} ({len(edits)} edit(s)):")
        for lineno, kind, before, after in edits:
            print(f"  line {lineno} [{kind}]:")
            print(f"    - {before.strip()}")
            print(f"    + {after.strip()}")

        if not DRY_RUN:
            with open(path, "w") as f:
                f.writelines(new_lines)

print(f"\n{'[DRY-RUN] ' if DRY_RUN else ''}Done: {total_files_changed} file(s), {total_edits} edit(s) total.")
if DRY_RUN:
    print("Re-run without --dry-run to apply.")
