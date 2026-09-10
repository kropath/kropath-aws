> **Point-in-time note:** This log was written on 2026-09-11. Claims here reflect understanding at that date. If any claim conflicts with `docs/frequent-rgd-errors.md` or agent instructions, those higher-precedence sources win.

# OpenSearchCollection: `includeWhen` dependency on naming ConfigMap causes ACK Collection not to be created (KRO-885, KRO-919)

**Ticket:** KRO-885
**Date:** 2026-09-11
**Resource affected:** OpenSearchCollection (`opensearchcollection.aws.kropath.run`)
**Symptom:** All 15 Chainsaw AC scenarios timed out at the first assert. The ACK Collection CR was never created, but the naming ConfigMap WAS materialised with correct data.

## CI Failure

CI check "RGD Tests" failed on `chainsaw/opensearch/opensearchcollection`. First failure point:

```
step ac1-type-search
assert: resource not found: collections.opensearchserverless.services.k8s.aws
```

All 15 steps failed at the same point — the ACK Collection never existed.

## Root Cause

The RGD gated the ACK Collection resource on `naming.data.effectiveName`:

```yaml
- id: ackCollection
  includeWhen:
    - '${!naming.data.effectiveName.contains("{")}'
  template:
    apiVersion: opensearchserverless.services.k8s.aws/v1alpha1
    kind: Collection
```

This reads from the `naming` ConfigMap node in the same kro graph. Per KRO-919 (documented in `docs/frequent-rgd-errors.md` §"KRO-919: `includeWhen` Must Not Read Another Node in the Same Graph"), kro v0.9.2 **never marks ConfigMap nodes as "ready"** for `includeWhen` dependency evaluation — ConfigMaps have no `.status.conditions`, so kro's readiness detector perpetually treats the node as unresolved.

Expected error (identical to WAF case in `docs/troubleshooting-logs/2026-09-09-waf-includeWhen-naming-configmap.md`):

```
resource reconciliation failed: waiting for unresolved resource: gvr "opensearchserverless.services.k8s.aws/v1alpha1, Resource=collections": includeWhen dependency "naming" not ready: node "naming": no observed state: waiting for readiness (data pending)
```

The naming ConfigMap existed with correct data, but kro could not use it as a readiness gate.

## Fix Applied

Removed the `includeWhen` block entirely from the `ackCollection` resource in `rgds/opensearchcollection.aws.kropath.run.yaml`. The naming ConfigMap remains as an **output** (for `status.resourceName` and `status.namingStatus`). It is no longer an **input** to inclusion decisions.

Before:
```yaml
- id: ackCollection
  includeWhen:
    - '${!naming.data.effectiveName.contains("{")}'
  template:
    apiVersion: opensearchserverless.services.k8s.aws/v1alpha1
    kind: Collection
```

After:
```yaml
- id: ackCollection
  template:
    apiVersion: opensearchserverless.services.k8s.aws/v1alpha1
    kind: Collection
```

## AC-10 Impact

AC-10 (`ac10-naming-unresolved`) tests the naming-invalid negative path. Its assert checks only `status.namingStatus: invalid-unresolved-tokens` — it does NOT assert that the ACK Collection is absent. Removing `includeWhen` does not break this scenario; the status field is computed from the naming ConfigMap output regardless.

## Verification

RGD compiles gate passed — `opensearchcollection.aws.kropath.run` reached `Active` after delete + re-apply in 1 round:

```bash
kubectl delete rgd opensearchcollection.aws.kropath.run --ignore-not-found=true --timeout=60s
kubectl apply -f rgds/opensearchcollection.aws.kropath.run.yaml
# Result: Active after iteration 1
```

## Cross-Reference

This is the same root cause as KRO-883 (WAF resources). See `docs/troubleshooting-logs/2026-09-09-waf-includeWhen-naming-configmap.md` for the full prior art, including the exact error message from local reproduction.

## Pattern

As documented in `docs/frequent-rgd-errors.md` §"KRO-919: `includeWhen` Must Not Read Another Node in the Same Graph":

> **What Works Instead:** Derive gate inputs from `schema.spec` and the resolved config tiers, which are available at every point in the lifecycle including deletion.
