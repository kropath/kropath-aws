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
# Unit + negative tests for the tenant-namespace-onboarding chart (KRO-1140). No cluster
# needed — this only exercises `helm template` (offline rendering), matching the chart's own
# contract of never applying anything.
set -euo pipefail

cd "$(dirname "${BASH_SOURCE[0]}")/.."

fail_count=0

pass() { echo "PASS: $1"; }
fail() { echo "FAIL: $1"; fail_count=$((fail_count + 1)); }

render() {
  helm template test . -f tests/values-sample.yaml "$@"
}

render_global() {
  helm template test . -f tests/values-sample-global.yaml "$@"
}

# --- Happy path: sample values render the Namespace + 3 <Family>Config objects -------------

out=$(render)

if echo "$out" | yq -e 'select(.kind == "Namespace") | .metadata.name == "payments-dev"' >/dev/null 2>&1; then
  pass "Namespace payments-dev rendered"
else
  fail "Namespace payments-dev not rendered"
fi

ann_global=$(echo "$out" | yq 'select(.kind == "Namespace") | .metadata.annotations["aws.kropath.run/global-config-namespace"]')
[ "$ann_global" = "platform-governance" ] && pass "global-config-namespace annotation correct" || fail "global-config-namespace annotation wrong: $ann_global"

ann_acct=$(echo "$out" | yq 'select(.kind == "Namespace") | .metadata.annotations["services.k8s.aws/owner-account-id"]')
[ "$ann_acct" = "111122223333" ] && pass "owner-account-id annotation correct" || fail "owner-account-id annotation wrong: $ann_acct"

ann_region=$(echo "$out" | yq 'select(.kind == "Namespace") | .metadata.annotations["services.k8s.aws/default-region"]')
[ "$ann_region" = "ap-southeast-2" ] && pass "default-region annotation correct" || fail "default-region annotation wrong: $ann_region"

for pair in "s3:S3Config" "sqs:SQSConfig" "rds:RDSConfig"; do
  slug="${pair%%:*}"
  kind="${pair##*:}"
  match=$(echo "$out" | yq "select(.kind == \"$kind\") | .metadata.name")
  ns=$(echo "$out" | yq "select(.kind == \"$kind\") | .metadata.namespace")
  label=$(echo "$out" | yq "select(.kind == \"$kind\") | .metadata.labels[\"aws.kropath.run/resource-name\"]")
  if [ "$match" = "general-policy" ] && [ "$ns" = "payments-dev" ] && [ "$label" = "general-policy" ]; then
    pass "$kind rendered correctly for family $slug"
  else
    fail "$kind rendering wrong (name=$match ns=$ns label=$label)"
  fi
done

kpc_name=$(echo "$out" | yq 'select(.kind == "KropathConfig") | .metadata.name')
kpc_ns=$(echo "$out" | yq 'select(.kind == "KropathConfig") | .metadata.namespace')
kpc_spec=$(echo "$out" | yq -o=json 'select(.kind == "KropathConfig") | .spec')
if [ "$kpc_name" = "baseline" ] && [ "$kpc_ns" = "payments-dev" ] && [ "$kpc_spec" = "{}" ]; then
  pass "KropathConfig/baseline rendered correctly"
else
  fail "KropathConfig/baseline rendering wrong (name=$kpc_name ns=$kpc_ns spec=$kpc_spec)"
fi

# --- Happy path: "global" (governance-only) namespace renders NO placement annotations, -----
# --- but still renders KropathConfig/baseline and every declared <Family>Config (ADR-019 D-5,
# --- KRO-1175) ------------------------------------------------------------------------------

gout=$(render_global)

if echo "$gout" | yq -e 'select(.kind == "Namespace") | .metadata.name == "platform-governance"' >/dev/null 2>&1; then
  pass "global-role Namespace platform-governance rendered"
else
  fail "global-role Namespace platform-governance not rendered"
fi

gann=$(echo "$gout" | yq -o=json 'select(.kind == "Namespace") | .metadata.annotations // {}')
if [ "$gann" = "{}" ] || [ "$gann" = "null" ]; then
  pass "global-role Namespace renders no placement annotations"
else
  fail "global-role Namespace should render no annotations, got: $gann"
fi

for pair in "s3:S3Config" "sqs:SQSConfig" "rds:RDSConfig"; do
  slug="${pair%%:*}"
  kind="${pair##*:}"
  match=$(echo "$gout" | yq "select(.kind == \"$kind\") | .metadata.name")
  ns=$(echo "$gout" | yq "select(.kind == \"$kind\") | .metadata.namespace")
  if [ "$match" = "general-policy" ] && [ "$ns" = "platform-governance" ]; then
    pass "global-role $kind rendered correctly for family $slug"
  else
    fail "global-role $kind rendering wrong (name=$match ns=$ns)"
  fi
done

gkpc_name=$(echo "$gout" | yq 'select(.kind == "KropathConfig") | .metadata.name')
gkpc_ns=$(echo "$gout" | yq 'select(.kind == "KropathConfig") | .metadata.namespace')
if [ "$gkpc_name" = "baseline" ] && [ "$gkpc_ns" = "platform-governance" ]; then
  pass "global-role KropathConfig/baseline rendered correctly"
else
  fail "global-role KropathConfig/baseline rendering wrong (name=$gkpc_name ns=$gkpc_ns)"
fi

# --- Happy path: configRef override renders a differently-named profile --------------------

cout=$(render --set configRef=team-custom-policy)
cname=$(echo "$cout" | yq 'select(.kind == "S3Config") | .metadata.name')
[ "$cname" = "team-custom-policy" ] && pass "configRef override renders custom profile name" || fail "configRef override wrong: $cname"

# --- Negative: malformed accountId must fail schema validation -----------------------------

if render --set accountId=not-twelve-digits >/dev/null 2>&1; then
  fail "malformed accountId did not fail render"
else
  pass "malformed accountId correctly fails render"
fi

# --- Negative: unknown family slug must fail with a clear message --------------------------

if err=$(render --set 'families={s3,not-a-real-family}' 2>&1 >/dev/null); then
  fail "unknown family slug did not fail render"
else
  echo "$err" | grep -q "unknown family" && pass "unknown family slug correctly fails render" || fail "unknown family slug failed with unexpected error: $err"
fi

# --- Negative: missing required namespace must fail ----------------------------------------

if render --set namespace= >/dev/null 2>&1; then
  fail "empty namespace did not fail render"
else
  pass "empty namespace correctly fails render"
fi

# --- Negative: invalid namespaceRole must fail --------------------------------------------

if render --set namespaceRole=bogus >/dev/null 2>&1; then
  fail "invalid namespaceRole did not fail render"
else
  pass "invalid namespaceRole correctly fails render"
fi

# --- Negative: namespaceRole=local with accountId/region/globalConfigNamespace unset must ---
# --- fail schema validation (ADR-019 D-5, KRO-1175) -----------------------------------------

if render_global --set namespaceRole=local >/dev/null 2>&1; then
  fail "local role without accountId/region/globalConfigNamespace did not fail render"
else
  pass "local role without accountId/region/globalConfigNamespace correctly fails render"
fi

# --- Negative: namespaceRole=global must still render if accountId/region/globalConfigNamespace
# --- are absent entirely (they are optional, not merely ignored) ---------------------------

if render_global >/dev/null 2>&1; then
  pass "global role with no placement fields still renders"
else
  fail "global role with no placement fields unexpectedly failed to render"
fi

echo "---"
if [ "$fail_count" -eq 0 ]; then
  echo "All checks passed."
  exit 0
else
  echo "$fail_count check(s) failed."
  exit 1
fi
