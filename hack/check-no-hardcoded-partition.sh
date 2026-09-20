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
# check-no-hardcoded-partition.sh — fail if any RGD under rgds/ hard-codes the `arn:aws`
# partition literal outside the explicit allowlist.
#
# KRO-1147 (spec docs/specs/controller-account-region-placement.md §5.7) replaced every
# status.predictedArn construction's hard-coded "aws" partition segment with a read from
# effectiveConfig.aws.partition, so predictedArn is correct in aws-cn/aws-us-gov/ISO
# partitions instead of emitting a well-formed ARN that names no resource. This lint is
# the guard that keeps RGD number 216 correct: a sweep only proves today's files are right,
# this catches the next one that reintroduces the literal.
#
# Sites not yet converted (7 inline-IAM-policy-document sites + other ARN-shaped
# cross-references — OQ-5, a different failure mode with a different owner, see spec §5.7)
# are listed explicitly by file and line in hack/partition-lint-allowlist.txt. A comment
# line (`#...`) is never a lint failure — this checks code, not documentation examples.
set -euo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
ALLOWLIST="${REPO_ROOT}/hack/partition-lint-allowlist.txt"

python3 - "${REPO_ROOT}" "${ALLOWLIST}" <<'PYEOF'
import glob, os, re, sys

repo, allowlist_path = sys.argv[1], sys.argv[2]

allowed = set()
with open(allowlist_path, encoding="utf-8") as fh:
    for raw in fh:
        line = raw.split("#", 1)[0].strip()
        if not line:
            continue
        path, lineno = line.rsplit(":", 1)
        allowed.add((path, int(lineno)))

failures = []
for path in sorted(glob.glob(os.path.join(repo, "rgds", "*.yaml"))):
    rel = os.path.relpath(path, repo)
    with open(path, encoding="utf-8") as fh:
        for i, line in enumerate(fh, start=1):
            if "arn:aws" not in line:
                continue
            if line.strip().startswith("#"):
                continue  # documentation example, not code
            if (rel, i) in allowed:
                continue
            failures.append((rel, i, line.strip()))

if failures:
    print("check-no-hardcoded-partition: FAIL")
    print(f"({len(failures)}) hard-coded 'arn:aws' literal(s) found outside the allowlist:\n")
    for rel, i, text in failures:
        print(f"  {rel}:{i}: {text[:160]}")
    print(
        "\nEvery predictedArn construction must read the partition segment from "
        "effectiveConfig.aws.partition (no .orValue(\"aws\") fallback) rather than a literal "
        "'aws'. If this site is a genuine OQ-5 exception (inline IAM policy JSON or another "
        "ARN-shaped reference, not predictedArn), add it to "
        "hack/partition-lint-allowlist.txt with a # OQ-5 annotation instead of hard-coding it."
    )
    sys.exit(1)

print("check-no-hardcoded-partition: PASS (no hard-coded arn:aws literals outside the allowlist)")
PYEOF
