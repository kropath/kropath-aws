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
set -euo pipefail

CLUSTER_NAME="${CLUSTER_NAME:-kropath-aws-test}"

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

if kind get clusters | grep -q "^${CLUSTER_NAME}$"; then
  echo "Kind cluster '${CLUSTER_NAME}' already exists — skipping creation."
else
  echo "Creating Kind cluster: ${CLUSTER_NAME}..."
  kind create cluster --name "${CLUSTER_NAME}" --config "${SCRIPT_DIR}/fixtures/kind-config.yaml"
fi

kubectl config use-context "kind-${CLUSTER_NAME}"

if kubectl get ns kro-system &>/dev/null; then
  echo "Namespace 'kro-system' already exists — skipping kro operator installation."
else
  echo "Creating namespace 'kro-system'..."
  kubectl create namespace kro-system
fi

echo "==> Installing kro operator (v0.9.2)..."
kubectl apply -f https://github.com/kubernetes-sigs/kro/releases/download/v0.9.2/kro-core-install-manifests.yaml

kubectl apply -f "${SCRIPT_DIR}/fixtures/rbac/kro-controller.yaml"
kubectl rollout status deployment/kro -n kro-system --timeout=120s

# kro's default dynamic-controller rate limiter (min-delay=200ms, max-delay=1000s) is tuned
# for production AWS reconciliation, where backing off for minutes avoids hammering a
# degraded API. Chainsaw tests create/delete/patch the same-named resources dozens of times
# per run; any transient "dependency not ready yet" condition trips the per-item exponential
# backoff, and consecutive trips compound (200ms, 400ms, 800ms... up to the 1000s cap),
# causing asserts to see "resource not found" and cleanup deletes to stall for minutes.
# Cap the backoff for local/CI test runs. CONCURRENT_RECONCILES is raised only modestly
# (1 -> 2): CI already runs 4 chainsaw suites in parallel against this same kro pod
# (tests/Makefile --parallel 4), and a CI runner has far fewer CPU cores than a local dev
# machine, so pushing concurrency too high (tried 5) adds contention that costs more in
# reconcile latency than it saves, and tipped an unrelated suite (snstopic) over its
# cleanup-phase timeout in CI even though it helped locally.
echo "==> Tuning kro dynamic-controller rate limiter for fast test-suite churn..."
kubectl set env deployment/kro -n kro-system \
  KRO_DYNAMIC_CONTROLLER_RATE_LIMITER_MIN_DELAY=50ms \
  KRO_DYNAMIC_CONTROLLER_RATE_LIMITER_MAX_DELAY=5s \
  KRO_DYNAMIC_CONTROLLER_RATE_LIMITER_RATE_LIMIT=50 \
  KRO_DYNAMIC_CONTROLLER_RATE_LIMITER_BURST_LIMIT=200 \
  KRO_DYNAMIC_CONTROLLER_CONCURRENT_RECONCILES=2
kubectl rollout status deployment/kro -n kro-system --timeout=120s

echo "==> Installing ACK CRD definitions..."
source "${SCRIPT_DIR}/../hack/install-provider-crds.sh"

echo "==> Installing kropath CRD definitions..."
kubectl apply -f "${SCRIPT_DIR}/../crds/*.yaml"
kubectl apply -f "${SCRIPT_DIR}/../crds/policy/policydocument.yaml"

echo "==> Installing kropath.run RGDS definitions..."
kubectl apply -f "${SCRIPT_DIR}/../rgds/*.yaml"

echo "==> Waiting for all RGDs to become Ready (kro must generate CRDs before tests run)..."
# NOTE: `kubectl wait --all` walks resources in NAME ORDER against ONE shared deadline, so the
# first broken RGD burns the whole budget and every RGD alphabetically after it is reported as
# "timed out" without ever being given time. That list is therefore
# "first broken RGD + everything after it", NOT the set of broken RGDs — reading it literally
# has twice sent someone chasing healthy RGDs (KRO-443). Always print the real diagnosis on
# failure so CI logs name the actual offender and its validation error.
if ! kubectl wait rgd --all --for=condition=Ready --timeout=300s; then
  echo ""
  echo "======================================================================"
  echo "RGD readiness FAILED. Ignore the 'timed out' list above — it is mostly"
  echo "collateral from kubectl wait's shared timeout budget."
  echo "The RGDs below are the ones actually broken:"
  echo "======================================================================"
  not_ready=$(kubectl get rgd -o jsonpath='{range .items[?(@.status.state!="Active")]}{.metadata.name}{"\n"}{end}')
  if [ -z "${not_ready}" ]; then
    echo "  (none are Inactive — all RGDs reached Active after the deadline;"
    echo "   this is a slow-cluster timeout, not a broken graph.)"
  else
    for rgd in ${not_ready}; do
      echo ""
      echo "--- ${rgd} ---"
      kubectl get rgd "${rgd}" -o jsonpath='{range .status.conditions[*]}  {.type}={.status} :: {.message}{"\n"}{end}'
    done
    echo ""
    echo "To reproduce and iterate locally (kro re-validates only on re-CREATE, never on re-apply):"
    echo "  kubectl delete rgd <name> && kubectl apply -f rgds/<name>.yaml"
    echo "  kubectl get rgd <name> -o jsonpath='{.status.conditions[?(@.type==\"GraphAccepted\")].message}'"
    echo "Errors surface ONE LAYER AT A TIME — repeat until the RGD reports Active."
    echo "See docs/frequent-rgd-errors.md §7 and §8."
  fi
  echo "======================================================================"
  exit 1
fi

echo "==> Test environment ready."
