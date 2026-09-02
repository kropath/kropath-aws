> **Point-in-time disclaimer:** This log records what was observed on 2026-09-03 against kro v0.9.2
> in the `kropath-aws-test` kind cluster. kro behaviour, ACK CRD shapes, and RGD patterns evolve;
> verify claims mechanically before acting on them.

# KRO-773: AppScaling CI Failure — Missing applicationautoscaling.services.k8s.aws RBAC

**Date:** 2026-09-03
**Issue:** KRO-773 (PR #212)
**Symptom:** Chainsaw `appscalingtarget` and `appscalingpolicy` suites timed out at the full
5-minute AssertTimeout on the very first test step. `appscalingconfig` passed in ~2s.

## Reproduction (code inspection)

```bash
grep "applicationautoscaling" tests/fixtures/rbac/kro-controller.yaml
# → (no output — entry was absent)
```

The `applicationautoscaling.services.k8s.aws` API group was not listed in the kro controller's
ClusterRole `apiGroups`, so kro had no permission to create `ScalableTarget` or `ScalingPolicy`
child CRs. kro swallows the RBAC denial silently; the ACK child CRs never materialised;
Chainsaw's assert waited the full 5 minutes and then failed with "actual resource not found".

## Root Cause

Exact same pattern as `2026-09-02-kinesisstream-missing-rbac.md`. Adding a new ACK resource
family requires three concurrent changes (see that log and `frequent-rgd-errors.md`):

1. `hack/install-provider-crds.sh` → `ACK_SERVICES` — `applicationautoscaling` was already present.
2. `tests/fixtures/rbac/kro-controller.yaml` → add `applicationautoscaling.services.k8s.aws` — **this was missing**.
3. `tests/lint-test-scripts.sh` → `ACK_BARE_NAMES` — `scalabletargets` and `scalingpolicies` were missing.

## Fix

Added `applicationautoscaling.services.k8s.aws` to the `apiGroups` list in
`tests/fixtures/rbac/kro-controller.yaml` (after `autoscaling.services.k8s.aws`).

Added `scalabletargets` and `scalingpolicies` to `ACK_BARE_NAMES` in
`tests/lint-test-scripts.sh` (alphabetically between `route` and `serverlesscache`).

## Why appscalingconfig Passed

`AppScalingConfig` is a pure governance CRD (`aws.kropath.run`). kro always has permission to
read `aws.kropath.run/*` resources (the first rule in the ClusterRole). No ACK child CRs are
created by the `appscalingconfig` suite — it just asserts on the `AppScalingConfig` CR itself.
`AppScalingTarget` and `AppScalingPolicy` drive kro to create ACK `ScalableTarget`/`ScalingPolicy`
child CRs, which require the missing `applicationautoscaling.services.k8s.aws` permission.
