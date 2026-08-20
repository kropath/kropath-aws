# Setup: Non-Lambda Wait Blocks Indefinitely on Permanent GraphAccepted=False RGDs

**Date:** 2026-08-20
**Ticket:** KRO-532
**Symptom:** CI fails during `make setup` — specifically the non-lambda RGD readiness wait
(`kubectl wait rgd --all --for=condition=Ready --timeout=300s`) exits non-zero after the full
300-second budget. EKS Chainsaw tests never run.

> ⚠️ **Point-in-time disclaimer:** This log records the author's understanding at the time of
> writing. Claims about kro internals are inferred from CI log evidence and should be verified
> before acting on them in a different context. Cross-reference `docs/frequent-rgd-errors.md`
> for any entry that conflicts with this log.

---

## Symptom

CI run 32369654551 — `Chainsaw E2E Tests` job, step "Setup test environment":

```
Error from server (NotFound): resourcegraphdefinitions "apigatewayapikey.aws.kropath.run" not found
```

Followed by the diagnostic block added by the prior fix (KRO-532 third CI failure), which printed:

```
GraphAccepted=False :: failed to build resource "apiKey": failed to get schema for resource
apiKey: cannot resolve group version "apigateway.services.k8s.aws/v1alpha1": schema not found
```

The run used a **fresh** Kind cluster (not a pre-existing one), so `hack/install-provider-crds.sh`
had to pull every ACK chart from ECR.

---

## Root Cause

`hack/install-provider-crds.sh` resolves each ACK controller's chart version by calling the
GitHub Releases API and using the latest release tag:

```bash
resolve_ack_chart_version() {
  local svc="$1"
  curl -fsSL "https://api.github.com/repos/aws-controllers-k8s/${svc}-controller/releases/latest" \
    | jq -r '.tag_name | ltrimstr("v")'
}
```

For `apigateway`, the latest GitHub release tag resolved to `v1.8.1`. However, the OCI chart for
that version had not yet been published to ECR (`public.ecr.aws/aws-controllers-k8s/apigateway-chart:1.8.1`).
The Helm pull failed silently with a warning:

```
WARNING: Could not pull ACK chart for apigateway:1.8.1 — chart not found in ECR, skipping.
```

As a result, the ACK apigateway v1 CRDs (`apigateway.services.k8s.aws/v1alpha1` group) were never
installed. kro then permanently failed all 11 apigateway v1 RGDs during graph compilation:

```
GraphAccepted=False :: failed to build resource "apiKey": failed to get schema for resource
  apiKey: cannot resolve group version "apigateway.services.k8s.aws/v1alpha1": schema not found
```

These 11 RGDs have `status.state != "Active"` (they are `Inactive`). The non-lambda wait added
in the prior fix (see `2026-08-20-eks-ci-setup-lambda-wave-timeout.md`) used `kubectl wait rgd --all
--for=condition=Ready --timeout=300s`. Because RGDs with `GraphAccepted=False` can **never** reach
`Ready`, the wait ran for the full 300s and exited non-zero, triggering `exit 1` in setup.

**Key distinction:** `GraphAccepted=False` RGDs are permanently rejected at kro's compile step.
They are **not** placed in kro's processing queue and do **not** prevent queue-draining for other
RGDs. The other ~81 non-lambda RGDs all reached `Active` within the 300s budget. The wait's purpose
(draining kro's queue before Lambda waves start) was already satisfied — but the blanket `--all`
caused setup to exit anyway.

---

## What Was Tried

Only one approach was needed — the root cause was clear from the CI log.

---

## Fix

Modified both `kubectl wait rgd --all --for=condition=Ready` blocks in `tests/setup.sh`:

1. **Non-lambda wait (pre-Lambda-wave barrier)**
2. **Final wait (post-Lambda-wave gate)**

In both, after the wait times out, the code now classifies each Inactive RGD:

- **`GraphAccepted=False`** → permanent compile-time rejection (missing CRDs) — listed as a
  WARNING, setup continues.
- **`GraphAccepted` not `False` (True, Unknown, or unset)** → genuine graph error or slow timeout
  — printed with full condition details, setup exits 1.

The classification logic:

```bash
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

if ${has_non_perm_failure}; then
  # ... print genuine errors and exit 1 ...
fi
# else: all not-ready RGDs have permanent GraphAccepted=False — queue is drained, continue
```

---

## Prevention

When an ACK service's latest GitHub Release has not yet been mirrored to ECR, its CRDs cannot be
installed, and its RGDs will have permanent `GraphAccepted=False`. This is a temporary out-of-sync
state that resolves once the ECR chart is published.

The setup.sh fix makes this situation non-fatal: affected services' test suites surface the
missing-CRD error directly (kro condition message), while unaffected services (EKS, IAM, S3, …)
run normally.

**If setup still times out after this fix:**

1. Check `kubectl get rgd -o wide` for any `Inactive` RGDs with `GraphAccepted=True` — those are
   correctness failures, not ECR sync issues.
2. If all Inactive RGDs have `GraphAccepted=False`, the issue is an ECR chart lag for one or more
   ACK services. Wait for the ECR chart to be published or pin the chart version in
   `hack/install-provider-crds.sh` to a version that IS in ECR.

**See also:** `2026-08-20-eks-ci-setup-lambda-wave-timeout.md` — the prior fix that introduced the
non-lambda wait (which this log addresses).
