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
# Installed services: s3 iam kms ec2 dynamodb rds sns sqs ssm secretsmanager
#                     eks ecr cloudwatch cloudwatchlogs elbv2 eventbridge autoscaling lambda elasticache efs sfn
#                     acm acmpca glue athena
source "${SCRIPT_DIR}/../hack/install-provider-crds.sh"

echo "==> Installing kropath CRD definitions..."
kubectl apply -f "${SCRIPT_DIR}/../crds/*.yaml"
kubectl apply -f "${SCRIPT_DIR}/../crds/policy/policydocument.yaml"
# kro validates externalRef GVKs at compile time against the live API server.
# Newly-created CRDs are not immediately queryable — the API server must complete
# registration (Established condition) before kro can find the schema.
# Without this wait, RGDs applied within ~1s of a new CRD creation stay permanently
# Inactive because kro's initial compilation fails and it does not retry.
#
# Wait only for the kropath-native CRDs (*.aws.kropath.run) that this setup
# actually applies — not --all 290+ CRDs. The --all form shares ONE deadline
# across every CRD in the cluster: the heavy kropathconfigs.aws.kropath.run
# (145KB, 92 CEL rules) consumes most of the budget while the API server
# compiles its rules, and every alphabetically-later CRD is then reported as
# "timed out" even though it was never given time (reproduced locally:
# vpcs.ec2.services.k8s.aws appeared as timed-out but was Established=True
# immediately after the wait exited). ACK CRD establishment is validated
# indirectly: kro fails to compile any RGD that references a missing ACK CRD
# GVK, and the RGD readiness check below classifies those as GraphAccepted=False.
mapfile -t _kropath_crds < <(
  grep -rh '^  name:.*\.aws\.kropath\.run' "${SCRIPT_DIR}/../crds/" --include='*.yaml' | awk '{print "crd/" $2}'
)
if [[ ${#_kropath_crds[@]} -gt 0 ]]; then
  kubectl wait "${_kropath_crds[@]}" --for=condition=Established --timeout=120s
fi
unset _kropath_crds

echo "==> Installing kropath.run RGD definitions (non-lambda)..."
# Build arg list excluding:
#   - lambda RGDs (applied in dependency-ordered waves below)
#   - athenapreparedstatement (needs AthenaWorkGroup CRD generated by athenaworkgroup RGD;
#     applied in the Athena wave after the non-lambda wait so the CRD is guaranteed present)
non_lambda_args=()
for rgd in "${SCRIPT_DIR}/../rgds/"*.yaml; do
  case "$(basename "$rgd")" in
    lambda*.yaml) ;; # applied below in waves
    athenapreparedstatement*.yaml) ;; # applied below in Athena wave (needs AthenaWorkGroup CRD)
    *) non_lambda_args+=("-f" "$rgd") ;;
  esac
done
kubectl apply "${non_lambda_args[@]}"

# Wait for all non-lambda RGDs to become Ready before starting Lambda waves.
# Without this wait, Lambda wave 1's 120s clock starts while kro is still processing
# the non-lambda batch (90+ RGDs), and Lambda times out before kro drains the queue.
# This became a problem when the EKS family (7 RGDs) was added (KRO-532).
#
# Caveat: some ACK chart versions are published to GitHub Releases before the ECR OCI
# registry is updated. When hack/install-provider-crds.sh cannot pull a chart from ECR,
# the affected RGDs permanently fail with GraphAccepted=False (schema not found). Those
# RGDs are NOT in kro's processing queue (they were rejected at compile time) and will
# never reach Ready, so `kubectl wait --all` would block for the full 300s. We
# distinguish permanent compile-time failures from genuine graph errors: if ALL not-ready
# RGDs have GraphAccepted=False, the queue IS drained and setup continues. If any
# not-ready RGD does NOT have GraphAccepted=False, it is a real error that blocks setup.
echo "==> Waiting for all non-lambda RGDs to become Ready (drains kro queue before Lambda waves)..."
if ! kubectl wait rgd --all --for=condition=Ready --timeout=300s; then
  echo ""
  echo "======================================================================"
  not_ready=$(kubectl get rgd -o jsonpath='{range .items[?(@.status.state!="Active")]}{.metadata.name}{"\n"}{end}')

  if [ -z "${not_ready}" ]; then
    echo "Non-lambda RGD readiness TIMED OUT (slow cluster; all RGDs are now Active)."
    echo "kro queue did not drain within the 300s budget; Lambda wave timing may be affected."
    echo "======================================================================"
    exit 1
  fi

  # Classify failures: permanent GraphAccepted=False (ACK CRDs missing from ECR) vs genuine
  # graph compilation errors. Permanent failures do NOT consume kro queue capacity.
  perm_failed_rgds=()
  has_non_perm_failure=false
  while IFS= read -r rgd; do
    [ -z "${rgd}" ] && continue
    ga_status=$(kubectl get rgd "${rgd}" \
      -o jsonpath='{.status.conditions[?(@.type=="GraphAccepted")].status}' 2>/dev/null || true)
    if [ "${ga_status}" = "False" ]; then
      perm_failed_rgds+=("${rgd}")
    else
      has_non_perm_failure=true
    fi
  done <<< "${not_ready}"

  if [ "${#perm_failed_rgds[@]}" -gt 0 ]; then
    echo "  WARNING: The following RGDs have permanent GraphAccepted=False (ACK CRDs not in ECR)."
    echo "  kro queue IS drained for all valid RGDs; these are compile-time rejections."
    echo "  Their individual test suites will surface the exact missing-CRD errors. Setup continues."
    for rgd in "${perm_failed_rgds[@]}"; do
      msg=$(kubectl get rgd "${rgd}" \
        -o jsonpath='{.status.conditions[?(@.type=="GraphAccepted")].message}' 2>/dev/null || true)
      echo "    - ${rgd}: ${msg}"
    done
    echo ""
  fi

  if ${has_non_perm_failure}; then
    echo "Non-lambda RGD readiness FAILED (genuine graph errors — fix these before proceeding):"
    while IFS= read -r rgd; do
      [ -z "${rgd}" ] && continue
      ga_status=$(kubectl get rgd "${rgd}" \
        -o jsonpath='{.status.conditions[?(@.type=="GraphAccepted")].status}' 2>/dev/null || true)
      [ "${ga_status}" = "False" ] && continue
      echo ""
      echo "--- ${rgd} ---"
      kubectl get rgd "${rgd}" \
        -o jsonpath='{range .status.conditions[*]}  {.type}={.status} :: {.message}{"\n"}{end}'
    done <<< "${not_ready}"
    echo "======================================================================"
    exit 1
  fi

  echo "======================================================================"
  # All not-ready RGDs have permanent GraphAccepted=False — queue is drained, proceeding.
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

# AthenaPreparedStatement references AthenaWorkGroup (a kro-generated kind).
# kro validates every referenced GVK at compile time, so AthenaPreparedStatement can only
# be applied after athenaworkgroup.aws.kropath.run is Active and has generated the
# AthenaWorkGroup CRD. By this point, the non-lambda wait above has confirmed that
# athenaworkgroup is Ready (or permanently GraphAccepted=False, which would mean the
# Athena ACK CRDs are missing — fix: add athena to ACK_SERVICES in hack/install-provider-crds.sh).
echo "==> Athena wave (AthenaPreparedStatement, needs AthenaWorkGroup CRD from non-lambda batch)..."
kubectl apply -f "${SCRIPT_DIR}/../rgds/athenapreparedstatement.aws.kropath.run.yaml"

echo "==> Waiting for all RGDs to become Ready (kro must generate CRDs before tests run)..."
# NOTE: `kubectl wait --all` walks resources in NAME ORDER against ONE shared deadline, so the
# first broken RGD burns the whole budget and every RGD alphabetically after it is reported as
# "timed out" without ever being given time. That list is therefore
# "first broken RGD + everything after it", NOT the set of broken RGDs — reading it literally
# has twice sent someone chasing healthy RGDs (KRO-443). Always print the real diagnosis on
# failure so CI logs name the actual offender and its validation error.
# As with the non-lambda wait above: permanent GraphAccepted=False RGDs (missing ACK CRDs) are
# skipped — they are not blocking tests for other services and will not become Active.
if ! kubectl wait rgd --all --for=condition=Ready --timeout=300s; then
  echo ""
  echo "======================================================================"
  not_ready=$(kubectl get rgd -o jsonpath='{range .items[?(@.status.state!="Active")]}{.metadata.name}{"\n"}{end}')

  if [ -z "${not_ready}" ]; then
    echo "RGD readiness TIMED OUT (slow cluster; all RGDs reached Active after the deadline)."
    echo "This is a slow-cluster timeout, not a broken graph."
    echo "======================================================================"
    exit 1
  fi

  perm_failed_rgds=()
  has_non_perm_failure=false
  while IFS= read -r rgd; do
    [ -z "${rgd}" ] && continue
    ga_status=$(kubectl get rgd "${rgd}" \
      -o jsonpath='{.status.conditions[?(@.type=="GraphAccepted")].status}' 2>/dev/null || true)
    if [ "${ga_status}" = "False" ]; then
      perm_failed_rgds+=("${rgd}")
    else
      has_non_perm_failure=true
    fi
  done <<< "${not_ready}"

  if [ "${#perm_failed_rgds[@]}" -gt 0 ]; then
    echo "  WARNING: The following RGDs have permanent GraphAccepted=False (ACK CRDs not in ECR)."
    echo "  Their test suites will surface the exact missing-CRD errors."
    for rgd in "${perm_failed_rgds[@]}"; do
      msg=$(kubectl get rgd "${rgd}" \
        -o jsonpath='{.status.conditions[?(@.type=="GraphAccepted")].message}' 2>/dev/null || true)
      echo "    - ${rgd}: ${msg}"
    done
    echo ""
  fi

  if ${has_non_perm_failure}; then
    echo "RGD readiness FAILED. Ignore the 'timed out' list above — it is mostly"
    echo "collateral from kubectl wait's shared timeout budget."
    echo "The RGDs below are the ones actually broken:"
    while IFS= read -r rgd; do
      [ -z "${rgd}" ] && continue
      ga_status=$(kubectl get rgd "${rgd}" \
        -o jsonpath='{.status.conditions[?(@.type=="GraphAccepted")].status}' 2>/dev/null || true)
      [ "${ga_status}" = "False" ] && continue
      echo ""
      echo "--- ${rgd} ---"
      kubectl get rgd "${rgd}" \
        -o jsonpath='{range .status.conditions[*]}  {.type}={.status} :: {.message}{"\n"}{end}'
    done <<< "${not_ready}"
    echo ""
    echo "To reproduce and iterate locally (kro re-validates only on re-CREATE, never on re-apply):"
    echo "  kubectl delete rgd <name> && kubectl apply -f rgds/<name>.yaml"
    echo "  kubectl get rgd <name> -o jsonpath='{.status.conditions[?(@.type==\"GraphAccepted\")].message}'"
    echo "Errors surface ONE LAYER AT A TIME — repeat until the RGD reports Active."
    echo "See docs/frequent-rgd-errors.md §7 and §8."
    echo "======================================================================"
    exit 1
  fi

  echo "======================================================================"
  # All not-ready RGDs have permanent GraphAccepted=False — tests proceed.
fi

echo "==> Test environment ready."
