#!/usr/bin/env bash
# Copyright 2024 kropath Authors
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

# setup-local.sh — Creates and bootstraps the 'kro-aws' Kind cluster for
# local kropath-aws development and Chainsaw E2E testing.
#
# Prerequisites: kind, kubectl, helm (>= 3.13)
# Usage: ./hack/setup-local.sh [--skip-kro] [--skip-crds]

set -euo pipefail

CLUSTER_NAME="kro-aws"
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
KRO_VERSION="${KRO_VERSION:-v0.3.0}"
SKIP_KRO=false
SKIP_CRDS=false

# ── Argument parsing ──────────────────────────────────────────────────────────
for arg in "$@"; do
  case "$arg" in
    --skip-kro)  SKIP_KRO=true  ;;
    --skip-crds) SKIP_CRDS=true ;;
    *)
      echo "Unknown argument: $arg"
      echo "Usage: $0 [--skip-kro] [--skip-crds]"
      exit 1
      ;;
  esac
done

# ── Prerequisite check ────────────────────────────────────────────────────────
echo "Checking prerequisites..."
for cmd in kind kubectl helm; do
  if ! command -v "$cmd" &>/dev/null; then
    echo "Error: '$cmd' is not installed. See docs/testing-local.md for installation instructions."
    exit 1
  fi
done

# ── Cluster creation ──────────────────────────────────────────────────────────
if kind get clusters 2>/dev/null | grep -q "^${CLUSTER_NAME}$"; then
  echo "Kind cluster '${CLUSTER_NAME}' already exists — skipping creation."
else
  echo "Creating Kind cluster: ${CLUSTER_NAME}..."
  kind create cluster --name "${CLUSTER_NAME}" --config "${SCRIPT_DIR}/kind-config.yaml"
fi

kubectl config use-context "kind-${CLUSTER_NAME}"

echo "Waiting for all nodes to be Ready..."
kubectl wait --for=condition=Ready nodes --all --timeout=120s

# ── kro installation ──────────────────────────────────────────────────────────
if [ "${SKIP_KRO}" = false ]; then
  echo "Installing kro ${KRO_VERSION}..."
  helm upgrade --install kro \
    "oci://ghcr.io/awslabs/kro/charts/kro" \
    --version "${KRO_VERSION}" \
    --namespace kro \
    --create-namespace \
    --wait \
    --timeout 5m
  echo "kro installed."
else
  echo "Skipping kro installation (--skip-kro)."
fi

# ── kropath CRDs ───────────────────────────────────────────────────────────────
if [ -d "${SCRIPT_DIR}/../crds" ]; then
  echo "Installing kropath CRDs..."
  kubectl apply -f "${SCRIPT_DIR}/../crds/"
else
  echo "No kropath CRDs directory found — skipping."
fi

# ── Provider CRDs ─────────────────────────────────────────────────────────────
if [ "${SKIP_CRDS}" = false ]; then
  echo "Installing provider CRDs..."
  "${SCRIPT_DIR}/install-provider-crds.sh"
else
  echo "Skipping provider CRD installation (--skip-crds)."
fi

# ── Done ──────────────────────────────────────────────────────────────────────
echo ""
echo "Cluster '${CLUSTER_NAME}' is ready."
echo "  Context : kind-${CLUSTER_NAME}"
echo "  Run E2E : chainsaw test ./tests/chainsaw/"
echo ""
echo "To tear down: kind delete cluster --name ${CLUSTER_NAME}"
