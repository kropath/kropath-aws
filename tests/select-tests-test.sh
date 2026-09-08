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
# Tests for tests/select-tests.sh.
#
# Each case builds a throwaway git repo with a real commit graph (a "main" branch and
# a PR branch), copies the script and a stub tests/Makefile in, and asserts the target
# list the script prints. Real git, real merge-bases — no mocking of the thing under
# test.
set -uo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
# Overridable so the suite can be pointed at another revision of the script.
SCRIPT="${SELECT_TESTS_SH:-${REPO_ROOT}/tests/select-tests.sh}"

PASS=0
FAIL=0

# Build a scratch repo: main has one commit, then a PR branch forks off it.
# Prints the repo path.
new_repo() {
  local d
  d=$(mktemp -d)
  git -C "$d" init --quiet --initial-branch=main
  git -C "$d" config user.email ci@example.com
  git -C "$d" config user.name CI
  mkdir -p "$d/tests" "$d/rgds" "$d/crds" "$d/tests/fixtures"
  cp "$SCRIPT" "$d/tests/select-tests.sh"
  # Stub Makefile — the script discovers services from its `test-<service>:` targets.
  printf 'test:\n\ntest-iam:\n\ntest-s3:\n\ntest-sagemaker:\n\ntest-dynamodb:\n' \
    >"$d/tests/Makefile"
  echo seed >"$d/README.md"
  git -C "$d" add -A
  git -C "$d" commit --quiet -m "seed"
  echo "$d"
}

commit_files() {
  local d="$1" msg="$2"
  shift 2
  local f
  for f in "$@"; do
    mkdir -p "$d/$(dirname "$f")"
    echo "change $(date +%s%N)" >>"$d/$f"
  done
  git -C "$d" add -A
  git -C "$d" commit --quiet -m "$msg"
}

# run_select <repo> <BASE_REF> <BASE_SHA> <HEAD_SHA>
run_select() {
  local d="$1"
  (cd "$d" && BASE_REF="$2" BASE_SHA="$3" HEAD_SHA="$4" ./tests/select-tests.sh 2>/dev/null)
}

# Compares as space-normalised strings so trailing-space differences don't matter.
check() {
  local name="$1" expected="$2" actual="$3"
  local e a
  e=$(echo $expected)
  a=$(echo $actual)
  if [ "$e" = "$a" ]; then
    PASS=$((PASS + 1))
    printf '  ok   %s\n' "$name"
  else
    FAIL=$((FAIL + 1))
    printf '  FAIL %s\n       expected: [%s]\n       actual:   [%s]\n' "$name" "$e" "$a"
  fi
}

echo "==> select-tests.sh"

# --- The regression this change is for -------------------------------------------
# main advances with an UNRELATED change after the PR forked. The PR itself only
# touches sagemaker, so only the sagemaker suite may be selected — main's post-fork
# commit must not be attributed to this PR.
d=$(new_repo)
git -C "$d" checkout --quiet -b pr
commit_files "$d" "pr: sagemaker" tests/sagemaker/x/chainsaw-test.yaml
head=$(git -C "$d" rev-parse HEAD)
git -C "$d" checkout --quiet main
commit_files "$d" "main: unrelated iam change" rgds/iamrole.yaml
check "PR diff excludes commits that landed on main after the fork" \
  "test-sagemaker" "$(run_select "$d" main "" "$head")"
rm -rf "$d"

# Same, but main's post-fork commit touches a SHARED file. Diffing against main's tip
# would trip the shared-file rule and escalate to the full suite; merge-base must not.
d=$(new_repo)
git -C "$d" checkout --quiet -b pr
commit_files "$d" "pr: sagemaker" tests/sagemaker/x/chainsaw-test.yaml
head=$(git -C "$d" rev-parse HEAD)
git -C "$d" checkout --quiet main
commit_files "$d" "main: shared fixture change" tests/fixtures/crds/foo.yaml
check "a shared-file change on main does not escalate the PR to the full suite" \
  "test-sagemaker" "$(run_select "$d" main "" "$head")"
rm -rf "$d"

# --- Whole-PR coverage, not just the latest push ---------------------------------
# Push 1 touches sagemaker, push 2 touches only iam. Both suites must run: selecting
# on the latest push alone would merge a PR whose sagemaker changes never ran.
d=$(new_repo)
git -C "$d" checkout --quiet -b pr
commit_files "$d" "pr push 1: sagemaker" tests/sagemaker/x/chainsaw-test.yaml
commit_files "$d" "pr push 2: iam" rgds/iamrole.yaml
head=$(git -C "$d" rev-parse HEAD)
check "selects the union of every push in the PR, not just the last" \
  "test-iam test-sagemaker" \
  "$(run_select "$d" main "" "$head" | tr ' ' '\n' | sort | tr '\n' ' ')"
rm -rf "$d"

# --- Force-push safety (push path) -----------------------------------------------
# BASE_SHA names a commit that is not an ancestor of HEAD (branch reset backwards).
# The diff against it would be a reverse diff of undone work, so fall back to full.
d=$(new_repo)
git -C "$d" checkout --quiet -b pr
commit_files "$d" "kept" tests/sagemaker/x/chainsaw-test.yaml
head=$(git -C "$d" rev-parse HEAD)
commit_files "$d" "later, discarded" rgds/iamrole.yaml
abandoned=$(git -C "$d" rev-parse HEAD)
git -C "$d" reset --hard --quiet "$head"
check "non-ancestor BASE_SHA (force-push) falls back to the full suite" \
  "test" "$(run_select "$d" "" "$abandoned" "$head")"
rm -rf "$d"

# --- Push-event path still works --------------------------------------------------
d=$(new_repo)
before=$(git -C "$d" rev-parse HEAD)
commit_files "$d" "push: s3" rgds/s3bucket.yaml
head=$(git -C "$d" rev-parse HEAD)
check "push event uses BASE_SHA (the push delta)" \
  "test-s3" "$(run_select "$d" "" "$before" "$head")"
rm -rf "$d"

# --- Per-service fixture CRD stubs (KRO-1066) --------------------------------------
# tests/fixtures/crds/<service>/ only affects that service. It used to match the blanket
# `tests/fixtures/` shared pattern and escalate the whole suite.
d=$(new_repo)
git -C "$d" checkout --quiet -b pr
commit_files "$d" "pr: s3 crd stub" tests/fixtures/crds/s3/s3.services.k8s.aws_buckets.yaml
head=$(git -C "$d" rev-parse HEAD)
check "a per-service fixture CRD stub selects only that service" \
  "test-s3" "$(run_select "$d" main "" "$head")"
rm -rf "$d"

d=$(new_repo)
git -C "$d" checkout --quiet -b pr
commit_files "$d" "pr: stub + rgd" \
  tests/fixtures/crds/s3/s3.services.k8s.aws_buckets.yaml rgds/s3bucket.yaml
head=$(git -C "$d" rev-parse HEAD)
check "a fixture stub alongside its own RGD stays a single-service selection" \
  "test-s3" "$(run_select "$d" main "" "$head")"
rm -rf "$d"

d=$(new_repo)
git -C "$d" checkout --quiet -b pr
commit_files "$d" "pr: unmapped stub dir" tests/fixtures/crds/acmpca/x.yaml
head=$(git -C "$d" rev-parse HEAD)
check "a fixture stub dir with no Makefile target escalates to the full suite" \
  "test" "$(run_select "$d" main "" "$head")"
rm -rf "$d"

# The genuinely shared parts of tests/fixtures/ must still escalate.
d=$(new_repo)
git -C "$d" checkout --quiet -b pr
commit_files "$d" "pr: kro rbac" tests/fixtures/rbac/kro-controller.yaml
head=$(git -C "$d" rev-parse HEAD)
check "the shared kro RBAC fixture still escalates to the full suite" \
  "test" "$(run_select "$d" main "" "$head")"
rm -rf "$d"

d=$(new_repo)
git -C "$d" checkout --quiet -b pr
commit_files "$d" "pr: default config" tests/fixtures/configs/default-kropathconfig.yaml
head=$(git -C "$d" rev-parse HEAD)
check "the seeded default config fixture still escalates to the full suite" \
  "test" "$(run_select "$d" main "" "$head")"
rm -rf "$d"

d=$(new_repo)
git -C "$d" checkout --quiet -b pr
commit_files "$d" "pr: kind config" tests/fixtures/kind-config.yaml
head=$(git -C "$d" rev-parse HEAD)
check "the kind cluster config fixture still escalates to the full suite" \
  "test" "$(run_select "$d" main "" "$head")"
rm -rf "$d"

# An unrecognised path under tests/fixtures/ must fail safe, not silently select nothing.
d=$(new_repo)
git -C "$d" checkout --quiet -b pr
commit_files "$d" "pr: novel fixture" tests/fixtures/webhooks/some-new-thing.yaml
head=$(git -C "$d" rev-parse HEAD)
check "an unrecognised tests/fixtures/ path falls back to the full suite" \
  "test" "$(run_select "$d" main "" "$head")"
rm -rf "$d"

# --- Fallbacks preserved ----------------------------------------------------------
d=$(new_repo)
git -C "$d" checkout --quiet -b pr
commit_files "$d" "pr: shared fixture" tests/fixtures/crds/foo.yaml
head=$(git -C "$d" rev-parse HEAD)
check "a shared file changed BY THE PR still escalates to the full suite" \
  "test" "$(run_select "$d" main "" "$head")"
rm -rf "$d"

d=$(new_repo)
git -C "$d" checkout --quiet -b pr
commit_files "$d" "pr: unmapped rgd" rgds/quantumledger.yaml
head=$(git -C "$d" rev-parse HEAD)
check "an RGD with no matching Makefile target escalates to the full suite" \
  "test" "$(run_select "$d" main "" "$head")"
rm -rf "$d"

d=$(new_repo)
git -C "$d" checkout --quiet -b pr
commit_files "$d" "pr: docs only" docs/notes.md
head=$(git -C "$d" rev-parse HEAD)
check "a non-resource change selects no per-service suite" \
  "" "$(run_select "$d" main "" "$head")"
rm -rf "$d"

d=$(new_repo)
head=$(git -C "$d" rev-parse HEAD)
check "an unknown BASE_REF falls back to the full suite" \
  "test" "$(run_select "$d" nonexistent-branch "" "$head")"
rm -rf "$d"

d=$(new_repo)
head=$(git -C "$d" rev-parse HEAD)
check "an empty base falls back to the full suite" \
  "test" "$(run_select "$d" "" "" "$head")"
rm -rf "$d"

echo "==> select-tests.sh: ${PASS} passed, ${FAIL} failed"
[ "$FAIL" -eq 0 ]
