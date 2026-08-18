# ElastiCache RGDs Inactive: `elasticache` Missing from `ACK_SERVICES` and kro-controller RBAC

**Date:** 2026-08-18
**Issue:** KRO-413
**PR:** #126

> **Point-in-time disclaimer:** This log records what the author understood at the time of
> writing. Verify claims mechanically before acting on them. See
> `docs/multica/agents/README.md` §"Knowledge source precedence".

## Symptom

CI `Setup test environment` step failed. All seven ElastiCache RGDs were `Inactive`:

```
GraphAccepted=False :: failed to build resource "ackCacheCluster": failed to get schema for
resource ackCacheCluster: cannot resolve group version
"elasticache.services.k8s.aws/v1alpha1": schema not found

GraphAccepted=False :: failed to build resource "ackParamGroup": failed to get schema for
resource ackParamGroup: cannot resolve group version
"elasticache.services.k8s.aws/v1alpha1": schema not found

GraphAccepted=False :: failed to build resource "ackReplicationGroup": ... schema not found
(repeated for all 7 ElastiCache RGDs)
```

## Root Cause

Two missing entries — both required for every new ACK service family:

1. **`hack/install-provider-crds.sh`** — `elasticache` was absent from `ACK_SERVICES`. The
   `elasticache-chart` Helm chart was never pulled, so
   `elasticacheclusters.elasticache.services.k8s.aws` (and sibling) CRDs were never installed.
   kro cannot resolve the group version and marks all RGDs `Inactive`.

2. **`tests/fixtures/rbac/kro-controller.yaml`** — `elasticache.services.k8s.aws` was absent
   from the aggregated ClusterRole. Without it, the kro controller receives `forbidden` errors
   when attempting to create/patch/delete ACK ElastiCache child resources during Chainsaw tests.

Both root causes follow the exact pattern documented for `cloudwatchlogs` in
`2026-08-18-cloudwatchlogs-missing-ack-service-in-install-script.md`.

## Fix

**1. `hack/install-provider-crds.sh`** — add `elasticache` to `ACK_SERVICES`:

```diff
-ACK_SERVICES="${ACK_SERVICES:-... lambda kafka}"
+ACK_SERVICES="${ACK_SERVICES:-... lambda kafka elasticache}"
```

**2. `tests/fixtures/rbac/kro-controller.yaml`** — add `elasticache.services.k8s.aws`:

```diff
       - kafka.services.k8s.aws
+      - elasticache.services.k8s.aws
```

**3. `tests/setup.sh`** — update the `# Installed services:` comment (documentation only):

```diff
-#                     eks ecr cloudwatch elbv2 eventbridge autoscaling lambda
+#                     eks ecr cloudwatch elbv2 eventbridge autoscaling lambda elasticache
```

## Pattern

Every new ACK group referenced by an RGD requires BOTH bootstrap steps:
- Add to `ACK_SERVICES` in `hack/install-provider-crds.sh`
- Add to `tests/fixtures/rbac/kro-controller.yaml` API groups list

This same pattern was needed for `cloudwatchlogs` (PR #121), `kafka` (earlier PR), and now
`elasticache` (PR #126). Check both files whenever introducing a new ACK service family.
The comment in `docs/frequent-rgd-errors.md` §"Provider bootstrap reminder" documents this.
