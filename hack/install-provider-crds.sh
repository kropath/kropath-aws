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

# install-provider-crds.sh — Installs provider CRDs (ACK, KCC, ASO) into the
# current kubectl context for local kropath-aws testing.
#
# Environment variables:
#   ACK_SERVICES   Space-separated list of ACK services (default: see below)
#   ACK_CHART_VERSION    ACK chart version prefix, e.g. "v1"
#   SKIP_ACK       Set to "true" to skip ACK CRD installation (default: false)
#   SKIP_KCC       Set to "true" to skip KCC CRD installation (default: true)
#   SKIP_ASO       Set to "true" to skip ASO CRD installation (default: true)

set -euo pipefail

ACK_SERVICES="${ACK_SERVICES:-s3 iam kms ec2 dynamodb rds sns sqs secretsmanager eks ecr cloudwatch elbv2 eventbridge autoscaling cloudfront}"
SKIP_ACK="${SKIP_ACK:-false}"
SKIP_KCC="${SKIP_KCC:-true}"
SKIP_ASO="${SKIP_ASO:-true}"

ACK_REGISTRY="public.ecr.aws/aws-controllers-k8s"
ACK_NAMESPACE="ack-system"

resolve_ack_chart_version() {
  local svc="$1"

  curl -fsSL "https://api.github.com/repos/aws-controllers-k8s/${svc}-controller/releases/latest" \
    | jq -r '.tag_name | ltrimstr("v")'
}

# ── ACK CRDs ──────────────────────────────────────────────────────────────────
if [ "${SKIP_ACK}" = "false" ]; then
  echo "Installing ACK CRDs (services: ${ACK_SERVICES})..."
  kubectl create namespace "${ACK_NAMESPACE}" --dry-run=client -o yaml | kubectl apply -f -

  mkdir -p "tmp"
  for service in ${ACK_SERVICES}; do
    version=$(resolve_ack_chart_version "${service}")
    echo "  -> ACK ${service}..."

    # Extract CRDs only from the Helm chart (no controller pod required locally).
    helm pull "oci://${ACK_REGISTRY}/${service}-chart" \
      --version "${version}" --untar --untardir tmp/
    kubectl apply --server-side -f "tmp/${service}-chart/crds" || echo "    WARNING: Could not install ACK CRDs for ${service} — chart may not exist at this version."
  done
  rm -rf tmp
  echo "ACK CRDs installed."
else
  echo "Skipping ACK CRDs (SKIP_ACK=true)."
fi

# ── KCC CRDs (GCP — skipped by default in kropath-aws) ───────────────────────
if [ "${SKIP_KCC}" = "false" ]; then
  echo "Installing KCC CRDs..."
  KCC_BUNDLE_URL="https://raw.githubusercontent.com/GoogleCloudPlatform/k8s-config-connector/master/install-bundles/install-bundle-namespaced/crds.yaml"
  curl -sSL "${KCC_BUNDLE_URL}" | kubectl apply --server-side -f -
  echo "KCC CRDs installed."
else
  echo "Skipping KCC CRDs (SKIP_KCC=true — GCP provider, not needed for kropath-aws)."
fi

# ── ASO CRDs (Azure — skipped by default in kropath-aws) ─────────────────────
if [ "${SKIP_ASO}" = "false" ]; then
  echo "Installing ASO CRDs..."
  ASO_VERSION="${ASO_VERSION:-v2.9.0}"
  helm show crds \
    "oci://mcr.microsoft.com/k8s/azureserviceoperator/helmchart/azure-service-operator" \
    --version "${ASO_VERSION}" \
    | kubectl apply --server-side -f -
  echo "ASO CRDs installed."
else
  echo "Skipping ASO CRDs (SKIP_ASO=true — Azure provider, not needed for kropath-aws)."
fi

echo "Provider CRD installation complete."
