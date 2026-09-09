> **Point-in-time note:** This log was written on 2026-09-09. Claims here reflect understanding at that date. If any claim conflicts with `docs/frequent-rgd-errors.md` or agent instructions, those higher-precedence sources win.

# WAF RGDs: `includeWhen` dependency on naming ConfigMap causes permanent block (KRO-919)

**Ticket:** KRO-883
**Date:** 2026-09-09
**Resources affected:** WAFIPSet, WAFRuleGroup, WAFWebACL
**Symptom:** All three WAF Chainsaw test suites timed out at 5 minutes (AssertTimeout). The ACK child resources (IPSet, RuleGroup, WebACL) were never created, but the naming ConfigMap WAS created with correct data.

## Root Cause

All three WAF RGDs gated their primary ACK resource on `naming.data.effectiveName`:

```yaml
- id: ipSet
  includeWhen:
    - '${!naming.data.effectiveName.contains("{")}'
```

This reads from the `naming` ConfigMap node in the same kro graph. Per KRO-919 (documented in `docs/frequent-rgd-errors.md`), kro v0.9.2 **never marks ConfigMap nodes as "ready"** for `includeWhen` dependency evaluation — ConfigMaps have no `.status.conditions`, so kro's readiness detector perpetually treats the node as unresolved.

**Exact error observed locally:**

```
resource reconciliation failed: waiting for unresolved resource: gvr "wafv2.services.k8s.aws/v1alpha1, Resource=ipsets": includeWhen dependency "naming" not ready: node "naming": no observed state: waiting for readiness (data pending)
```

The naming ConfigMap (`ipset-scope-default-wafipset-naming`) existed with correct data (`effectiveName: wafipset-ipset-scope-default`), but kro could not use it as a readiness gate.

## Prior fix in same CI run

Commit `45515327` removed `.sortBy(x, x.key)` from the tags CEL expression in all three RGDs. That fix was necessary but not sufficient — this naming gate issue was the second, independent blocker.

## Fix Applied

Removed the `'${!naming.data.effectiveName.contains("{")}'` line from `includeWhen` in all affected RGDs:

- `rgds/wafipset.aws.kropath.run.yaml`: removed entire `includeWhen` block (was the only condition)
- `rgds/wafrulegroup.aws.kropath.run.yaml`: removed entire `includeWhen` block (was the only condition)
- `rgds/wafwebacl.aws.kropath.run.yaml` webACLGovernance: removed naming condition, kept defaultAction condition
- `rgds/wafwebacl.aws.kropath.run.yaml` webACLInstance: removed naming condition, kept defaultAction condition

The naming ConfigMap remains as an **output** (for `status.resourceName` and `status.namingStatus`). It is no longer an **input** to inclusion decisions.

## Verification

All three RGDs reached `Active` after delete + re-apply. The `includeWhen` conditions on `rsrcCfg.*` (WAFConfig effectiveConfig fields) work correctly because `rsrcCfg` is an `externalRef` node — kro can assess its readiness via the referenced object's existence.

## Pattern

As documented in `docs/frequent-rgd-errors.md` §"KRO-919: `includeWhen` Must Not Read Another Node in the Same Graph":

> **What Works Instead:** Derive gate inputs from `schema.spec` and the resolved config tiers, which are available at every point in the lifecycle including deletion.
