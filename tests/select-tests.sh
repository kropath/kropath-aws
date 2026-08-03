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
# run every resource family's full chainsaw suite on every change. Falls
# back to the single "test" target (the full suite) whenever a shared or
# cross-cutting file changed, or whenever the diff can't be computed safely
# — an unmapped change must never result in silently skipping a suite.
set -euo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$REPO_ROOT"

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
# and DynamoDB RGDs), hack/ scripts, or the CI workflow itself.
SHARED_PATTERN='^(tests/setup\.sh|tests/teardown\.sh|tests/Makefile|tests/fixtures/|\.chainsaw\.yaml|hack/|crds/kropathconfig\.yaml|crds/policy/|\.github/workflows/)'
if echo "${CHANGED_FILES}" | grep -qE "${SHARED_PATTERN}"; then
  full_suite
fi

declare -A SERVICE_MAP=(
  [dynamodbtable]=dynamodb [dynamodbconfig]=dynamodb
  [iamgroup]=iam [iamidentityprovider]=iam [iampolicy]=iam [iamrole]=iam [iamuser]=iam [iamconfig]=iam
  [kmskey]=kms [kmsconfig]=kms
  [s3bucket]=s3 [s3config]=s3
  [secretsmanagersecret]=secretsmanager [secretsmanagerconfig]=secretsmanager
  [snstopic]=sns [snsconfig]=sns
  [sqsqueue]=sqs [sqsconfig]=sqs
  [eventbridgeconfig]=eventbridge
)

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
    tests/iam/*) add_service iam ;;
    tests/kms/*) add_service kms ;;
    tests/s3/*) add_service s3 ;;
    tests/sqs/*) add_service sqs ;;
    tests/secretsmanager/*) add_service secretsmanager ;;
    tests/sns/*) add_service sns ;;
    tests/dynamodb/*) add_service dynamodb ;;
    tests/eventbridge/*) add_service eventbridge ;;
    tests/policy/*) add_service policy ;;
    tests/chainsaw/*) ;; # smoke suite already runs unconditionally in the workflow
    rgds/*.yaml|crds/*.yaml)
      base=$(basename "${f}" .yaml)
      base=${base%.aws.kropath.run}
      svc="${SERVICE_MAP[${base}]:-}"
      if [ -n "${svc}" ]; then
        add_service "${svc}"
      else
        # Unmapped RGD/CRD file (e.g. a brand-new resource family) — don't guess.
        full_suite
      fi
      ;;
    *) ;;
  esac
done <<< "${CHANGED_FILES}"

if [ -z "${SERVICES}" ]; then
  exit 0
fi

for s in ${SERVICES}; do
  printf 'test-%s ' "${s}"
done
echo
