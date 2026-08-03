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
# Cap the backoff and raise concurrency/throughput for local/CI test runs.
echo "==> Tuning kro dynamic-controller rate limiter for fast test-suite churn..."
kubectl set env deployment/kro -n kro-system \
  KRO_DYNAMIC_CONTROLLER_RATE_LIMITER_MIN_DELAY=50ms \
  KRO_DYNAMIC_CONTROLLER_RATE_LIMITER_MAX_DELAY=5s \
  KRO_DYNAMIC_CONTROLLER_RATE_LIMITER_RATE_LIMIT=50 \
  KRO_DYNAMIC_CONTROLLER_RATE_LIMITER_BURST_LIMIT=200 \
  KRO_DYNAMIC_CONTROLLER_CONCURRENT_RECONCILES=5
kubectl rollout status deployment/kro -n kro-system --timeout=120s

echo "==> Installing ACK CRD definitions..."
source "${SCRIPT_DIR}/../hack/install-provider-crds.sh"

echo "==> Installing kropath CRD definitions..."
kubectl apply -f "${SCRIPT_DIR}/../crds/*.yaml"
kubectl apply -f "${SCRIPT_DIR}/../crds/policy/policydocument.yaml"

echo "==> Installing kropath.run RGDS definitions..."
kubectl apply -f "${SCRIPT_DIR}/../rgds/*.yaml"

echo "==> Waiting for all RGDs to become Ready (kro must generate CRDs before tests run)..."
kubectl wait rgd --all --for=condition=Ready --timeout=120s

echo "==> Test environment ready."
