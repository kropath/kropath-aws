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
# cover the files a change actually touches, so CI does not run every resource
# family's full chainsaw suite on every change.
#
# Inputs (set by .github/workflows/rgd-tests.yaml):
#   BASE_REF  pull_request only — the PR's target branch (e.g. "main"). The diff base
#             is the MERGE-BASE of that branch with $HEAD_SHA, so the changed-file set
#             is exactly what this PR contributes and nothing that landed on main
#             after the branch forked.
#   BASE_SHA  push only — the push's `before` commit. Ignored when BASE_REF is set.
#   HEAD_SHA  the commit under test (defaults to HEAD).
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

BASE_REF="${BASE_REF:-}"
BASE_SHA="${BASE_SHA:-}"
HEAD_SHA="${HEAD_SHA:-HEAD}"

# Resolve the commit to diff against.
#
# pull_request: BASE_REF is the target branch (e.g. "main"). The base must be the
# MERGE-BASE of that branch with the PR head, not the branch tip and not the previous
# push — i.e. `git diff base...HEAD` semantics. Two failure modes this avoids:
#
#   * Diffing against the branch TIP attributes commits that landed on main after this
#     branch forked to this PR. An unrelated (or main-breaking) merge would then pull
#     extra suites into this PR's run and report failures the PR did not cause.
#   * Diffing against github.event.before covers only the LAST push, so a PR whose
#     first push touched sagemaker and whose second push touched only iam goes green
#     having never run the sagemaker suite against the final tree.
#
# push (main): BASE_REF is empty and BASE_SHA is the push's `before` commit, which is
# already the correct delta for that event.
if [ -n "${BASE_REF}" ]; then
  base_tip=""
  for cand in "refs/remotes/origin/${BASE_REF}" "refs/heads/${BASE_REF}"; do
    if git rev-parse --verify --quiet "${cand}^{commit}" >/dev/null 2>&1; then
      base_tip="${cand}"
      break
    fi
  done
  # Checkout didn't bring the target branch down (shallow clone, or a fetch refspec
  # that only pulled the PR ref) — try once to fetch it before giving up.
  if [ -z "${base_tip}" ]; then
    if git fetch --quiet origin "+refs/heads/${BASE_REF}:refs/remotes/origin/${BASE_REF}" 2>/dev/null &&
      git rev-parse --verify --quiet "refs/remotes/origin/${BASE_REF}^{commit}" >/dev/null 2>&1; then
      base_tip="refs/remotes/origin/${BASE_REF}"
    fi
  fi
  if [ -z "${base_tip}" ]; then
    # Can't locate the target branch — never guess.
    full_suite
  fi
  BASE_SHA=$(git merge-base "${base_tip}" "${HEAD_SHA}" 2>/dev/null || true)
fi

# No usable base commit (first push to a branch, force-push, shallow history) — safest
# is to run everything rather than guess.
if [ -z "${BASE_SHA}" ] || [ "${BASE_SHA}" = "0000000000000000000000000000000000000000" ]; then
  full_suite
fi
if ! git cat-file -e "${BASE_SHA}^{commit}" 2>/dev/null; then
  full_suite
fi
# The base must be an ancestor of the head, or the diff is meaningless. After a
# force-push, github.event.before names a discarded commit, and diffing against it
# yields a REVERSE diff describing the work that was undone — nothing to do with what
# the branch actually changes. A merge-base is an ancestor by construction, so this
# only ever fires on the push path.
if ! git merge-base --is-ancestor "${BASE_SHA}" "${HEAD_SHA}" 2>/dev/null; then
  full_suite
fi

CHANGED_FILES=$(git diff --name-only "${BASE_SHA}" "${HEAD_SHA}" 2>/dev/null || true)
if [ -z "${CHANGED_FILES}" ]; then
  full_suite
fi

# Files that affect every resource family: bootstrap/teardown scripts, chainsaw
# config, genuinely shared fixtures, org-wide or cross-cutting CRDs (kropathconfig
# applies to every RGD's effCfg cascade; policy/ PolicyDocument is referenced by both
# IAM and DynamoDB RGDs), hack/ scripts, this script itself, or the CI workflow.
#
# Only the SHARED parts of tests/fixtures/ belong here: rbac/ (the kro ClusterRole —
# stripping an apiGroup there breaks every suite, see KRO-1064), configs/ (the seeded
# default KropathConfig feeds every RGD's effCfg cascade), and kind-config.yaml.
# tests/fixtures/crds/<service>/ is per-service and is mapped below instead; matching
# all of tests/fixtures/ used to escalate a single-service ACK CRD stub edit to the
# full suite (KRO-1066). Anything else under tests/fixtures/ still falls through to the
# tests/<dir>/ branch, where "fixtures" is not a known service — so the default for an
# unrecognised fixture path remains the full suite.
SHARED_PATTERN='^(tests/setup\.sh|tests/teardown\.sh|tests/Makefile|tests/select-tests\.sh|tests/fixtures/rbac/|tests/fixtures/configs/|tests/fixtures/kind-config|\.chainsaw\.yaml|hack/|crds/kropathconfig\.yaml|crds/policy/|\.github/workflows/)'
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
    tests/fixtures/crds/*/*)
      # Per-service ACK CRD stub. tests/fixtures/crds/<service>/*.yaml can only affect
      # that one service's suite, so map it instead of escalating. Must precede the
      # generic tests/*/* branch below, which would otherwise read the service as
      # "fixtures" and fall back to the full suite.
      svc="${f#tests/fixtures/crds/}"
      svc="${svc%%/*}"
      if is_known_service "${svc}"; then
        add_service "${svc}"
      else
        # A stub directory with no matching test-<service>: target — e.g. acmpca, whose
        # CRDs are consumed by another service's suite. Don't guess.
        full_suite
      fi
      ;;
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
