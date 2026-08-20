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
# hack/install-provider-crds.sh installs ACK CRDs for all services referenced by
# kropath-aws RGDs. When adding a new provider service family, add its service
# name to ACK_SERVICES in that script so kro can compile the RGDs.
# Installed services: s3 iam kms ec2 dynamodb rds sns sqs secretsmanager
#                     eks ecr cloudwatch cloudwatchlogs elbv2 eventbridge autoscaling lambda elasticache efs
source "${SCRIPT_DIR}/../hack/install-provider-crds.sh"

echo "==> Installing kropath CRD definitions..."
kubectl apply -f "${SCRIPT_DIR}/../crds/*.yaml"
kubectl apply -f "${SCRIPT_DIR}/../crds/policy/policydocument.yaml"
# kro validates externalRef GVKs at compile time against the live API server.
# Newly-created CRDs are not immediately queryable — the API server must complete
# registration (Established condition) before kro can find the schema.
# Without this wait, RGDs applied within ~1s of a new CRD creation stay permanently
# Inactive because kro's initial compilation fails and it does not retry.
kubectl wait crd --all --for=condition=Established --timeout=60s

echo "==> Installing kropath.run RGD definitions (non-lambda)..."
# Build arg list excluding lambda RGDs, which must be applied in dependency-ordered waves below.
non_lambda_args=()
for rgd in "${SCRIPT_DIR}/../rgds/"*.yaml; do
  case "$(basename "$rgd")" in
    lambda*.yaml) ;; # applied below in waves
    *) non_lambda_args+=("-f" "$rgd") ;;
  esac
done
kubectl apply "${non_lambda_args[@]}"

# Wait for all non-lambda RGDs to become Ready before starting Lambda waves.
# Without this wait, Lambda wave 1's 120s clock starts while kro is still processing
# the non-lambda batch (90+ RGDs), and Lambda times out before kro drains the queue.
# This became a problem when the EKS family (7 RGDs) was added (KRO-532).
echo "==> Waiting for all non-lambda RGDs to become Ready (drains kro queue before Lambda waves)..."
if ! kubectl wait rgd --all --for=condition=Ready --timeout=300s; then
  echo ""
  echo "======================================================================"
  echo "Non-lambda RGD readiness FAILED. Broken RGDs:"
  echo "======================================================================"
  not_ready=$(kubectl get rgd -o jsonpath='{range .items[?(@.status.state!="Active")]}{.metadata.name}{"\n"}{end}')
  if [ -z "${not_ready}" ]; then
    echo "  (none are Inactive — slow-cluster timeout, not a broken graph.)"
  else
    for rgd in ${not_ready}; do
      echo ""
      echo "--- ${rgd} ---"
      kubectl get rgd "${rgd}" -o jsonpath='{range .status.conditions[*]}  {.type}={.status} :: {.message}{"\n"}{end}'
    done
  fi
  echo "======================================================================"
  exit 1
fi

# Lambda RGDs reference each other's kro-generated kinds via externalRef.
# kro validates every referenced GVK against the live API server at compile time.
# Applying all 7 simultaneously causes permanent Inactive state for those that
# reference a kind whose generator RGD has not yet become Active (CRD not yet created).
# Fix: apply in three waves, waiting for each wave to become Active so the generated
# CRDs are registered before the next wave's RGDs are compiled.
# See: docs/troubleshooting-logs/2026-08-11-lambda-rgd-yaml-selector-ci-failures.md
echo "==> Lambda RGD wave 1 (no cross-lambda deps: LambdaCodeSigningConfig, LambdaLayerVersion)..."
kubectl apply \
  -f "${SCRIPT_DIR}/../rgds/lambdacodesigningconfig.aws.kropath.run.yaml" \
  -f "${SCRIPT_DIR}/../rgds/lambdalayerversion.aws.kropath.run.yaml"
if ! kubectl wait rgd \
  lambdacodesigningconfig.aws.kropath.run \
  lambdalayerversion.aws.kropath.run \
  --for=condition=Ready --timeout=120s; then
  echo "==> RGD condition dump (for diagnosis):"
  kubectl get rgd lambdacodesigningconfig.aws.kropath.run lambdalayerversion.aws.kropath.run \
    -o jsonpath='{range .items[*]}{"--- "}{.metadata.name}{"\n"}{.status.conditions}{"\n"}{end}' || true
  exit 1
fi

echo "==> Lambda RGD wave 2 (LambdaFunction, needs LambdaCodeSigningConfig CRD from wave 1)..."
kubectl apply -f "${SCRIPT_DIR}/../rgds/lambdafunction.aws.kropath.run.yaml"
if ! kubectl wait rgd lambdafunction.aws.kropath.run --for=condition=Ready --timeout=120s; then
  echo "==> RGD condition dump (for diagnosis):"
  kubectl get rgd lambdafunction.aws.kropath.run \
    -o jsonpath='{"--- "}{.metadata.name}{"\n"}{.status.conditions}{"\n"}' || true
  exit 1
fi

echo "==> Lambda RGD wave 3 (need LambdaFunction CRD from wave 2)..."
kubectl apply \
  -f "${SCRIPT_DIR}/../rgds/lambdaalias.aws.kropath.run.yaml" \
  -f "${SCRIPT_DIR}/../rgds/lambdaeventsourcemapping.aws.kropath.run.yaml" \
  -f "${SCRIPT_DIR}/../rgds/lambdafunctionurlconfig.aws.kropath.run.yaml" \
  -f "${SCRIPT_DIR}/../rgds/lambdaversion.aws.kropath.run.yaml"

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
