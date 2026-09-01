#!/usr/bin/env bash
# lint-test-scripts.sh — Guard against ambiguous ACK resource names in Chainsaw test scripts.
#
# Each `kubectl get <word>` found inside a `- script:` step must use the fully qualified
# <plural>.<service>.services.k8s.aws form for any ACK-managed resource.  A bare name like
# `kubectl get cluster` resolves to whichever API group sorts first in the discovery cache and
# will silently target the wrong group the moment a second ACK service installs a CRD with the
# same plural.  This guard fires on the exact symptom seen in KRO-674 / the iam/iamuser suite.
#
# Usage: ./lint-test-scripts.sh (exits 0 on success, non-zero with details on failure)
# Also callable as `make lint-test-scripts` from tests/.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# Bare plural names that are registered ACK resource types in at least one of the ACK services
# installed by hack/install-provider-crds.sh.  Any `kubectl get <name>` that uses one of these
# without a dotted group qualifier is an error.
#
# Rules for maintaining this list:
#   - Add a name here when you write a new ACK-backed resource type (lookup the ACK plural in
#     the controller CRD cache at kropath-core/docs/crd-cache/).
#   - Do NOT add kropath.run wrapper CRD names (iamconfig, kmskey, …); those are unique and
#     need no qualification.
#   - Keep the list sorted alphabetically for easy diff review.
ACK_BARE_NAMES=(
  accesspoint
  acl
  api
  authorizer
  cachecluster
  cacheparametergroup
  cachesubnetgroup
  capacityprovider
  cluster
  codesigningconfig
  configuration
  dashboard
  dbcluster
  dbinstance
  dbsubnetgroup
  distribution
  domainname
  eventsourcemapping
  filesystem
  function
  functionurlconfig
  group
  instanceprofile
  layerversion
  metricalarm
  metricstream
  mounttarget
  openidconnectprovider
  parametergroup
  pullthroughcacherule
  replicationgroup
  repository
  repositorycreationtemplate
  resource
  restapi
  role
  route
  serverlesscache
  snapshot
  streams
  subnetgroup
  table
  taskdefinition
  user
  usergroup
  version
)

# Build a grep alternation pattern: word\|word\|...
# We match "kubectl get <bare> " (bare followed by a space, resource-name, or flag).
PATTERN=$(IFS='|'; echo "${ACK_BARE_NAMES[*]}")

# Find every chainsaw-test.yaml under the tests directory.
TESTS_DIR="${SCRIPT_DIR}"
mapfile -t TEST_FILES < <(find "${TESTS_DIR}" -name "chainsaw-test.yaml" -type f | sort)

FAILURES=0

for f in "${TEST_FILES[@]}"; do
  # Extract lines that look like `kubectl get <bare> ` — match bare name followed by space.
  # We exclude lines that already have the qualified form (contain ".services.k8s.aws").
  while IFS= read -r line; do
    # Skip if the resource name is already dotted-qualified
    if echo "$line" | grep -qE "kubectl get [a-z][a-z0-9.-]+\.[a-z]"; then
      continue
    fi
    echo "ERROR: unqualified ACK resource name in ${f#${TESTS_DIR}/}:"
    echo "  ${line}"
    FAILURES=$((FAILURES + 1))
  done < <(grep -E "kubectl get (${PATTERN}) " "$f" 2>/dev/null || true)
done

if [ "${FAILURES}" -gt 0 ]; then
  echo ""
  echo "FAIL: ${FAILURES} unqualified ACK resource reference(s) found."
  echo "Replace each bare name with the fully qualified <plural>.<service>.services.k8s.aws form."
  echo "See docs/frequent-rgd-errors.md §\"Ambiguous kubectl Resource Name\" for details."
  exit 1
fi
