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
# ensure-acm-prereqs.sh — idempotent, NON-DESTRUCTIVE prerequisite check for the ACM suites.
#
# Usage (from tests/acm/<suite>/):  ../ensure-acm-prereqs.sh <rgd-basename>...
#   e.g.                            ../ensure-acm-prereqs.sh acmcertificate acmprivateca
#
# Why this exists (KRO-873 CI flake):
# The five ACM suites run concurrently (chainsaw --parallel 4) against one kro pod and one
# API server. Each used to open with an unconditional
#
#     kubectl apply -f ../../fixtures/crds/acm/ ...        # overwrite live CRDs
#     kubectl delete rgd <shared-rgd> --ignore-not-found   # tear down shared state
#     kubectl apply -f ../../../rgds/<shared-rgd>.yaml
#     kubectl wait rgd <shared-rgd> --for=condition=Ready --timeout=120s
#
# preamble, which mutates cluster-wide state that the *other* ACM suites are actively using:
#
#   1. The fixture CRDs are hand-written MINIMAL stubs (see their header comments), intended
#      only as a fallback for a cluster where the real ACK charts are unavailable. tests/setup.sh
#      installs the genuine ACK acm/acmpca CRDs from ECR, so applying the stubs on top narrows
#      the live schema out from under whichever sibling suite is mid-compile.
#   2. acmprivateca is deleted+recreated by both the acmprivateca and acmprivatecertificate
#      suites while the acmcertificate suite waits on it; acmeendpoint likewise by both the
#      acmeendpoint and acmedomainvalidation suites. Whoever is waiting sees the RGD vanish.
#   3. Every delete forces kro to tear down and re-derive the generated CRD. Five suites doing
#      that at once regularly pushed a single RGD past the 120s wait — the exact failure seen in
#      https://github.com/kropath/kropath-aws/actions/runs/33731687628 (acmcertificate, 127s).
#
# tests/setup.sh already installs the real ACK CRDs and applies + waits for every RGD, so the
# steady-state path here is pure verification and touches nothing. Repair actions run only when
# a prerequisite is genuinely absent, which keeps a bare-cluster `chainsaw test acm/` working.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "${SCRIPT_DIR}/../.." && pwd)"

ACK_CRDS=(
  acmedomainvalidations.acm.services.k8s.aws
  acmeendpoints.acm.services.k8s.aws
  certificates.acm.services.k8s.aws
  certificateauthorities.acmpca.services.k8s.aws
  certificateauthorityactivations.acmpca.services.k8s.aws
  certificates.acmpca.services.k8s.aws
)

missing=()
for crd in "${ACK_CRDS[@]}"; do
  kubectl get crd "${crd}" >/dev/null 2>&1 || missing+=("${crd}")
done

if [ ${#missing[@]} -gt 0 ]; then
  echo "==> ACK ACM CRDs absent (${missing[*]}) — applying minimal fixture stubs as a fallback."
  kubectl apply -f "${REPO_ROOT}/tests/fixtures/crds/acm/"
  kubectl apply -f "${REPO_ROOT}/tests/fixtures/crds/acmpca/"
  kubectl wait crd "${ACK_CRDS[@]}" --for=condition=Established --timeout=60s
else
  echo "==> ACK ACM CRDs present — leaving the live schemas untouched."
fi

# 300s (not 120s): the wait is instant when the RGD is already Active — the steady-state path in
# CI, where setup.sh has already applied and waited for every RGD — so the budget is only ever
# spent on the apply path, where kro must compile the graph and derive a CRD while up to four
# sibling suites hammer the same controller.
#
# If an RGD still will not go Ready, fail with kro's own message rather than deleting anything.
# A persistent "cannot update CRD ...: breaking changes detected" means the local cluster holds a
# CRD derived from an older revision of this RGD; kro only re-derives on a fresh create, so the
# fix is to recreate the kind cluster (`make teardown && make setup`). Deleting the RGD or its
# generated CRD here is NOT a safe shortcut: that cascades into the ACK child resources, whose
# finalizers are never removed on a cluster that runs kro but no ACK controllers, and the delete
# hangs (docs/frequent-rgd-errors.md §"CANONICAL: Unique-Name-Per-Step + skipDelete").
for rgd in "$@"; do
  full="${rgd}.aws.kropath.run"
  if kubectl wait "rgd/${full}" --for=condition=Ready --timeout=30s >/dev/null 2>&1; then
    echo "==> RGD ${full} already Active."
    continue
  fi
  echo "==> RGD ${full} not Ready — applying from rgds/ and waiting."
  kubectl apply --server-side --force-conflicts -f "${REPO_ROOT}/rgds/${full}.yaml"
  if ! kubectl wait "rgd/${full}" --for=condition=Ready --timeout=300s; then
    echo "ERROR: RGD ${full} did not become Ready. kro reports:" >&2
    kubectl get "rgd/${full}" \
      -o jsonpath='{range .status.conditions[?(@.status=="False")]}  {.type}: {.message}{"\n"}{end}' >&2 || true
    exit 1
  fi
done
