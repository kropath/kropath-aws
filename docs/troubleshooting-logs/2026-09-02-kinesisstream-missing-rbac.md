# 2026-09-02: KinesisStream CI Failure — Missing kinesis.services.k8s.aws RBAC

> **Point-in-time disclaimer:** This log records what was observed and concluded at the time of
> writing. It may be superseded by later discoveries. Verify claims mechanically before acting on
> them; do not elevate this log above `docs/frequent-rgd-errors.md` or agent instructions.

## Ticket

KRO-747 — [kropath-aws] RGD + Tests: Kinesis resources (PR #198)

## Symptom

CI failed on commit `aefa3f5f` with "Chainsaw E2E Tests" timing out at the very first
`kinesisstream` test step (`ac1-streammode-default-ondemand`):

```
actual resource not found
```

The assert was waiting for `kinesis.services.k8s.aws/v1alpha1/Stream @ kinesisstream/sm-default-od`
for the full 5-minute AssertTimeout and then failing. The `kinesisconfig` suite ran and passed
in parallel (completed in ~1 second). Local tests always passed.

## Root Cause

`kinesis.services.k8s.aws` was absent from `tests/fixtures/rbac/kro-controller.yaml`.

Without this API group in the kro controller's ClusterRole, kro cannot create, get, list,
patch, update, or watch `kinesis.services.k8s.aws/Stream` resources. When the KinesisStream
RGD attempted to reconcile an instance, kro had no permission to create the ACK Stream child
CR — the create call was silently denied by the API server's RBAC enforcement. The
KinesisStream instance appeared to reconcile (no error on the parent CR) but the ACK Stream
child never materialised.

**Why local tests passed:** The local test cluster had `kinesis.services.k8s.aws` in the
ClusterRole from a prior manual `kubectl apply` or from an earlier session that had already
added the entry. CI always starts from a fresh cluster, applies `kro-controller.yaml` exactly
as it is in the repository, and thus started without the permission.

**Why the failure was at AC-1, not at setup:** The `kinesisstream` RGD compiles to Active
(kro's schema validation passes without RBAC), and the KinesisStream instance is admitted by
the API server (the KinesisStream CRD is installed). Only when kro tries to create the ACK
Stream child does the permission error occur — and kro swallows that error silently, leaving
the ACK Stream absent. The Chainsaw assert then waits until its 5-minute AssertTimeout expires.

## Fix

Added `kinesis.services.k8s.aws` to the `apiGroups` list in `tests/fixtures/rbac/kro-controller.yaml`
(after `cognitoidentityprovider.services.k8s.aws`).

Also added `streams` (the ACK Kinesis plural) to the `ACK_BARE_NAMES` list in
`tests/lint-test-scripts.sh` per the repo rule: add every new ACK-backed resource plural so
the linter catches any future unqualified `kubectl get stream` references.

## Pattern Learned

**Adding a new ACK resource family requires three concurrent changes:**
1. `hack/install-provider-crds.sh` — add the service name to `ACK_SERVICES` (so the CRD is installed).
2. `tests/fixtures/rbac/kro-controller.yaml` — add `<service>.services.k8s.aws` to the kro
   controller's ClusterRole (so kro can create child CRs).
3. `tests/lint-test-scripts.sh` — add the plural resource name(s) to `ACK_BARE_NAMES` (so the
   linter catches unqualified `kubectl get` references).

Missing step 2 causes a silent RBAC failure in CI: the RGD reaches Active (schema validation
passes), the parent CR is admitted (the kropath CRD is installed), but no child CR is ever
created. The Chainsaw assert times out with "actual resource not found" — a misleading error
that looks like a kro reconciliation bug rather than a permissions problem.

**Previous instances of this exact pattern:**
- `2026-08-18-efs-missing-rbac.md` — `efs.services.k8s.aws` missing
- `2026-08-19-memorydb-rbac-and-kubectl-user-ambiguity.md` — `memorydb.services.k8s.aws` missing
- `2026-08-18-cloudwatchlogs-missing-ack-service-in-install-script.md` — cloudwatchlogs missing from install script

## Related

- `docs/frequent-rgd-errors.md` — should include this pattern in a dedicated section
- KRO-747, PR kropath/kropath-aws#198
