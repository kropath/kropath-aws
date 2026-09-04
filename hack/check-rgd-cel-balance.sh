#!/usr/bin/env bash
# Copyright 2026 kropath Authors
#
# Licensed under the Apache License, Version 2.0 (the "License");
# you may not use this file except in compliance with the License.
# You may obtain a copy of the License at
#
#     http://www.apache.org/licenses/LICENSE-2.0
#
# Unless required by applicable law or agreed to in writing, software
# distributed under the License is distributed on an "AS IS" BASIS,
# WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
# See the License for the specific language governing permissions and
# limitations under the License.
#
# check-rgd-cel-balance.sh — fail fast on a CEL expression whose parentheses do not balance.
#
# kro rejects an unparseable expression at graph-build time, so the RGD never leaves Inactive and
# every Chainsaw suite for that kind fails in CI ~20 minutes later with a stack of unrelated-looking
# "timed out waiting for the condition on resourcegraphdefinitions/<name>" lines. Catching it
# statically turns that into a sub-second PR check.
#
# This exists because a scripted mass-edit across all 77 RGDs (KRO-977, "apply {token} substitution
# to nameOverride") rewrote the closing parens of every naming expression but matched the opening
# parens with a narrower pattern. In the two RGDs whose expression already opened with `((`, only
# the closing rewrite fired, leaving one unmatched `)`:
#
#   .replace("{configRef}", schema.spec.configRef))).contains("{")
#                                                 ^ one too many
#
# Scope: parenthesis balance only. It is deliberately not a CEL parser — it catches the mechanical
# failure mode that mass-edits produce, and kro remains the authority on everything else.
set -euo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

python3 - "${REPO_ROOT}" <<'PYEOF'
import glob, os, sys

repo = sys.argv[1]

def unbalanced(path):
    """Yield (line, opens, closes) for each ${...} whose parens do not balance.

    Walks the raw file rather than the parsed YAML so the reported line number points at the
    expression a human has to edit. Tracks quoting because CEL string literals legitimately
    contain '(' , ')' and '}' (e.g. .contains("{"), .split("{tag.")).
    """
    src = open(path, encoding="utf-8").read()
    n, i = len(src), 0
    while True:
        start = src.find("${", i)
        if start < 0:
            return
        depth, quote, esc, opens, closes = 1, None, False, 0, 0
        k = start + 2
        while k < n:
            c = src[k]
            if quote:
                if esc:
                    esc = False
                elif c == "\\":
                    esc = True
                elif c == quote:
                    quote = None
            elif c in "\"'":
                quote = c
            elif c == "{":
                depth += 1
            elif c == "}":
                depth -= 1
                if depth == 0:
                    break
            elif c == "(":
                opens += 1
            elif c == ")":
                closes += 1
            k += 1
        if depth != 0:
            # Unterminated ${...}; YAML parsing/kro will report this far more precisely.
            i = start + 2
            continue
        if opens != closes:
            yield src.count("\n", 0, start) + 1, opens, closes
        i = k + 1

failures = 0
for path in sorted(glob.glob(os.path.join(repo, "rgds", "*.yaml"))):
    rel = os.path.relpath(path, repo)
    for line, opens, closes in unbalanced(path):
        failures += 1
        extra = "closing" if closes > opens else "opening"
        print(f"{rel}:{line}: unbalanced CEL expression — {opens} '(' vs {closes} ')' "
              f"({abs(opens - closes)} extra {extra} paren)")

if failures:
    print(f"\ncheck-rgd-cel-balance: FAIL ({failures} unbalanced expression(s))")
    print("kro would reject these at graph-build time and the RGD would never reach Active.")
    sys.exit(1)

print("check-rgd-cel-balance: PASS (all rgds/*.yaml CEL expressions balance)")
PYEOF
