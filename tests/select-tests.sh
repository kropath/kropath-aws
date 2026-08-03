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
# Prints the space-separated `make` targets (see tests/Makefile) needed to
# cover the files changed between $BASE_SHA and $HEAD_SHA, so CI does not
# run every resource family's full chainsaw suite on every change.
#
# The service list is discovered from tests/Makefile's own `test-<service>:`
# targets, and a changed rgds/*.yaml or crds/*.yaml file is matched to a
# service by prefix (e.g. "dynamodbtable" -> service "dynamodb", because
# "dynamodbtable".startswith("dynamodb")) — the same convention every
# existing resource family already follows. This means adding a brand-new
# resource family (its own tests/<service>/ dir, rgds/crds file(s), and a
# `test-<service>:` Makefile target) is automatically covered with no edits
# to this script, as long as the new RGD/CRD filename is prefixed with the
# service name.
#
# Falls back to the single "test" target (the full suite) whenever a shared
# or cross-cutting file changed, the RGD/CRD naming convention above doesn't
# resolve to exactly one known service, or the diff can't be computed safely
# — an unmapped or ambiguous change must never result in silently skipping
# a suite.
set -euo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "${REPO_ROOT}"

full_suite() {
  echo "test"
  exit 0
}

BASE_SHA="${BASE_SHA:-}"
HEAD_SHA="${HEAD_SHA:-HEAD}"

# No usable base commit (first push to a branch, force-push, shallow history) — safest
# is to run everything rather than guess.
if [ -z "${BASE_SHA}" ] || [ "${BASE_SHA}" = "0000000000000000000000000000000000000000" ]; then
  full_suite
fi
if ! git cat-file -e "${BASE_SHA}^{commit}" 2>/dev/null; then
  full_suite
fi

CHANGED_FILES=$(git diff --name-only "${BASE_SHA}" "${HEAD_SHA}" 2>/dev/null || true)
if [ -z "${CHANGED_FILES}" ]; then
  full_suite
fi

# Files that affect every resource family: bootstrap/teardown scripts, chainsaw
# config, shared fixtures, org-wide or cross-cutting CRDs (kropathconfig applies
# to every RGD's effCfg cascade; policy/ PolicyDocument is referenced by both IAM
# and DynamoDB RGDs), hack/ scripts, this script itself, or the CI workflow.
SHARED_PATTERN='^(tests/setup\.sh|tests/teardown\.sh|tests/Makefile|tests/select-tests\.sh|tests/fixtures/|\.chainsaw\.yaml|hack/|crds/kropathconfig\.yaml|crds/policy/|\.github/workflows/)'
if echo "${CHANGED_FILES}" | grep -qE "${SHARED_PATTERN}"; then
  full_suite
fi

# Discover the known services from tests/Makefile's own `test-<service>:` targets
# rather than hardcoding a list, so this script does not need to change when a new
# resource family's Makefile target is added.
mapfile -t KNOWN_SERVICES < <(grep -oE '^test-[A-Za-z0-9_-]+:' tests/Makefile | sed -E 's/^test-//; s/:$//')
if [ "${#KNOWN_SERVICES[@]}" -eq 0 ]; then
  # Couldn't parse the Makefile — don't guess.
  full_suite
fi

is_known_service() {
  local svc="$1" k
  for k in "${KNOWN_SERVICES[@]}"; do
    [ "${k}" = "${svc}" ] && return 0
  done
  return 1
}

# Longest-prefix match: an RGD/CRD basename must start with the service name
# (e.g. "dynamodbtable" -> "dynamodb", "iamrole" -> "iam"). Picks the longest
# matching service name in case of any future ambiguity (e.g. "s3" vs a
# hypothetical "s3glacier").
find_service_for_basename() {
  local base="$1" svc best="" best_len=0
  for svc in "${KNOWN_SERVICES[@]}"; do
    case "${base}" in
      "${svc}"*)
        if [ "${#svc}" -gt "${best_len}" ]; then
          best="${svc}"
          best_len="${#svc}"
        fi
        ;;
    esac
  done
  echo "${best}"
}

SERVICES=""
add_service() {
  case " ${SERVICES} " in
    *" $1 "*) ;;
    *) SERVICES="${SERVICES} $1" ;;
  esac
}

while IFS= read -r f; do
  [ -z "${f}" ] && continue
  case "${f}" in
    tests/*/*)
      svc="${f#tests/}"
      svc="${svc%%/*}"
      if [ "${svc}" = "chainsaw" ]; then
        : # smoke suite (chainsaw-e2e) already runs unconditionally in the workflow
      elif is_known_service "${svc}"; then
        add_service "${svc}"
      else
        # A tests/<dir>/ with no matching test-<dir>: Makefile target yet — either a
        # stray path or a new service still being wired up. Don't guess.
        full_suite
      fi
      ;;
    rgds/*.yaml | crds/*.yaml)
      base=$(basename "${f}" .yaml)
      base=${base%.aws.kropath.run}
      svc=$(find_service_for_basename "${base}")
      if [ -n "${svc}" ]; then
        add_service "${svc}"
      else
        # Unmapped RGD/CRD file (e.g. a brand-new resource family whose Makefile
        # target/prefix hasn't landed in this diff) — don't guess.
        full_suite
      fi
      ;;
    *) ;;
  esac
done <<<"${CHANGED_FILES}"

if [ -z "${SERVICES}" ]; then
  exit 0
fi

for s in ${SERVICES}; do
  printf 'test-%s ' "${s}"
done
echo
