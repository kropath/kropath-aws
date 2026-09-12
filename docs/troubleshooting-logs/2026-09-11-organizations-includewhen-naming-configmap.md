> **Point-in-time disclaimer:** This log records findings from 2026-09-11. Conclusions were valid
> at time of writing. Verify mechanically before acting on any claim here.

# Organizations: `includeWhen` on ACK Child Gated on Naming ConfigMap (KRO-919)

**Date:** 2026-09-11
**Ticket:** KRO-1000
**Affected RGDs:** `organizationsaccount.aws.kropath.run`, `organizationsou.aws.kropath.run`
**Root cause:** KRO-919 — kro v0.9.2 `includeWhen` bug when the condition reads from a ConfigMap node in the same graph

## Symptom

CI "RGD Tests" check timed out at 300 s (the `AssertTimeout`) on both `organizationsaccount`
and `organizationsou` Chainsaw suites. The failing assert in each suite was the ACK child CR
(`organizations.services.k8s.aws/Account` and `organizations.services.k8s.aws/OrganizationalUnit`
respectively) — those CRs were never created, so every scenario that asserted their existence
timed out.

The `organizationsconfig` suite passed, confirming the cluster setup and CRD stubs were correct.

## Root Cause

Both RGDs gated their ACK child resource on:

```yaml
includeWhen:
  - >-
    ${!naming.data.effectiveName.contains("{")}
```

This reads `naming.data.effectiveName` — where `naming` is a `ConfigMap` node **in the same kro
graph**. Per KRO-919, kro v0.9.2's readiness detector never marks a ConfigMap node as "ready"
(ConfigMaps have no `.status.conditions`), so the readiness check for the `naming` dependency
perpetually returns "unresolved". kro therefore never evaluates the `includeWhen` condition and
never instantiates the ACK child CR.

This is the same bug as KRO-883 (WAF) and KRO-885 (OpenSearchCollection).

## Fix

Remove the `includeWhen` block from the ACK child resource in both RGDs. The naming ConfigMap
remains in the graph as an **output-only** node, populating `status.resourceName` and
`status.namingStatus`. It is no longer an **input** to inclusion decisions.

**Before (organizationsaccount.aws.kropath.run.yaml):**
```yaml
- id: account
  includeWhen:
    - >-
      ${!naming.data.effectiveName.contains("{")}
  template:
    apiVersion: organizations.services.k8s.aws/v1alpha1
    kind: Account
```

**After:**
```yaml
- id: account
  template:
    apiVersion: organizations.services.k8s.aws/v1alpha1
    kind: Account
```

Same change applied to the `ou` resource in `organizationsou.aws.kropath.run.yaml`.

The `parentIDError` ConfigMap in the OU RGD has its own `includeWhen` that reads only from
`schema.spec.*` (not from any graph node) — that `includeWhen` was left unchanged; it is safe.

## Verification

Both RGDs reached `Active` immediately after the fix:

```
kubectl delete rgd organizationsaccount.aws.kropath.run --ignore-not-found=true
kubectl apply -f rgds/organizationsaccount.aws.kropath.run.yaml
# → state=Active (poll 1)

kubectl delete rgd organizationsou.aws.kropath.run --ignore-not-found=true
kubectl apply -f rgds/organizationsou.aws.kropath.run.yaml
# → state=Active (poll 1)
```

## Test Impact

The negative-path naming tests (`ac12-naming-invalid-token` for Account, `ou-ac18-naming-invalid-token`
for OU) assert `status.namingStatus: invalid-unresolved-tokens` only — they do NOT assert that
the ACK CR is absent. Removing `includeWhen` does not break these tests.

## Pattern (add to frequent-rgd-errors.md if not already there)

**Never gate an ACK child resource on a `naming` ConfigMap node in the same graph.** The naming
ConfigMap is output-only. If a naming-invalid guard is needed, implement it via a separate
error-advisory ConfigMap (gated on `schema.spec.*`) and surface it in `status.validationError`.
