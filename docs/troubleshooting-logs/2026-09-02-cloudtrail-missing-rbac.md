> **Point-in-time disclaimer:** This log records what was observed on 2026-09-02 against kro v0.9.2
> in the `kropath-aws-test` kind cluster. kro behaviour, ACK CRD shapes, and RGD patterns evolve;
> verify claims mechanically before acting on them.

# KRO-763: CloudTrail Trail and EventDataStore suites fail — missing RBAC

**Date:** 2026-09-02
**Issue:** KRO-763 (PR #204)
**Symptom:** `chainsaw/cloudtrail/cloudtrailtrail[cloudtrailtrail]` and
`chainsaw/cloudtrail/cloudtraileventdatastore[cloudtraileventdatastore]` both failed after a full
5-minute assert timeout with `actual resource not found` for
`cloudtrail.services.k8s.aws/v1alpha1/Trail` and
`cloudtrail.services.k8s.aws/v1alpha1/EventDataStore` respectively.

## Reproduction

The CloudTrailTrail and CloudTrailEventDataStore kropath CRs were created (CREATE OK). The RGDs
were Active (setup.sh completed successfully). kro reconciled the instances but never created the
ACK child resources.

## Root Cause

`cloudtrail.services.k8s.aws` was absent from `tests/fixtures/rbac/kro-controller.yaml`. Without
this entry, kro's service account lacks permission to create, get, list, update, patch, delete, and
watch Trail and EventDataStore resources in the test cluster. kro silently fails the child resource
creation (forbidden by the API server) and the Chainsaw assert times out after 300s.

Identical pattern to KRO-643 (EFS, August 2026) and KRO-647 (ElastiCache, August 2026) — every new
ACK service added to kropath-aws requires a matching entry in the RBAC file.

## What Was Tried

| # | Approach | Result |
|---|---|---|
| 1 | Diagnosed by grepping `kro-controller.yaml` for `cloudtrail` — zero matches confirmed the missing entry | Confirmed root cause |
| 2 | Added `cloudtrail.services.k8s.aws` to the `apiGroups` list in `kro-controller.yaml` | Adopted |

## What Worked

```yaml
# tests/fixtures/rbac/kro-controller.yaml
# Added to the apiGroups list:
- cloudtrail.services.k8s.aws
```

One line addition to the ClusterRole's `apiGroups` list. Covers both `Trail` and `EventDataStore`
since they share the `cloudtrail.services.k8s.aws` API group.

## Rule for Future Additions

Whenever a new ACK service is added to kropath-aws:
1. Add the service to `hack/install-provider-crds.sh` `ACK_SERVICES` list.
2. Add `<service>.services.k8s.aws` to `tests/fixtures/rbac/kro-controller.yaml`.

Missing step 2 causes exactly this failure: RGD Active, instances created, child resources never
appear, 5-minute assert timeout.
