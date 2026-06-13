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

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

echo "==> Creating kind cluster..."
kind create cluster --name kropath-test --config "${SCRIPT_DIR}/fixtures/kind-config.yaml"

echo "==> Installing kro operator (v0.9.2)..."
kubectl create namespace kro-system
kubectl apply -f https://github.com/kubernetes-sigs/kro/releases/download/v0.9.2/kro-core-install-manifests.yaml
kubectl rollout status deployment/kro -n kro-system --timeout=120s

echo "==> Installing ACK IAM CRD definitions..."
kubectl apply -f "${SCRIPT_DIR}/fixtures/crds/iam/"

echo "==> Installing ACK EKS CRD definitions..."
kubectl apply -f "${SCRIPT_DIR}/fixtures/crds/eks/"

echo "==> Test environment ready."
