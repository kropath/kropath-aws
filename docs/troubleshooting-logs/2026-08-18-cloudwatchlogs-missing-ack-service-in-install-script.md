# CloudWatch Logs LogGroup — RGD Inactive: `cloudwatchlogs` Missing from `ACK_SERVICES`

**Date:** 2026-08-18
**Issue:** KRO-336
**PR:** #121

> **Point-in-time disclaimer:** This log records what the author understood at the time of
> writing. Verify claims mechanically before acting on them. See
> `docs/multica/agents/README.md` §"Knowledge source precedence".

## Symptom

CI `Setup test environment` step failed. `cloudwatchlogsloggroup.aws.kropath.run` RGD was
`Inactive`:

```
GraphAccepted=False :: failed to build resource "ackLogGroup": failed to get schema for resource
ackLogGroup: cannot resolve group version "cloudwatchlogs.services.k8s.aws/v1alpha1": schema not found
```

## Root Cause

`cloudwatchlogs` was absent from the `ACK_SERVICES` list in `hack/install-provider-crds.sh`.

CI runs `make setup` → `setup.sh` → `install-provider-crds.sh`. Without `cloudwatchlogs` in
the list, the `cloudwatchlogs-chart` Helm chart is never pulled, and the
`loggroups.cloudwatchlogs.services.k8s.aws` CRD is never installed in the test cluster.
kro then cannot resolve the group version and leaves the RGD `Inactive`.

The RGD was verified `Active` locally in the prior session because the CRD was already present
in the local kind cluster (installed during an earlier `make setup` run that had a different
in-flight state). The CI cluster starts fresh every run.

## Fix

Two changes, both required per `docs/frequent-rgd-errors.md` §"Provider bootstrap reminder":

**1. `hack/install-provider-crds.sh`** — add `cloudwatchlogs` to `ACK_SERVICES`:

```diff
-ACK_SERVICES="${ACK_SERVICES:-s3 iam kms ec2 dynamodb rds sns sqs secretsmanager eks ecr cloudwatch elbv2 eventbridge autoscaling cloudfront ecs apigateway apigatewayv2 lambda}"
+ACK_SERVICES="${ACK_SERVICES:-s3 iam kms ec2 dynamodb rds sns sqs secretsmanager eks ecr cloudwatch cloudwatchlogs elbv2 eventbridge autoscaling cloudfront ecs apigateway apigatewayv2 lambda}"
```

**2. `tests/fixtures/rbac/kro-controller.yaml`** — add `cloudwatchlogs.services.k8s.aws` to
the aggregated ClusterRole (missing this causes `forbidden` when kro tries to create LogGroup
children):

```diff
     - cloudwatch.services.k8s.aws
+    - cloudwatchlogs.services.k8s.aws
     - elbv2.services.k8s.aws
```

## Local Reproduction Steps

```bash
# Remove the CRD to simulate a fresh CI cluster
kubectl delete crd loggroups.cloudwatchlogs.services.k8s.aws

# Delete and re-apply the RGD (kro re-validates only on CREATE)
kubectl delete rgd cloudwatchlogsloggroup.aws.kropath.run
kubectl apply -f rgds/cloudwatchlogsloggroup.aws.kropath.run.yaml

# Observe Inactive state with the same error as CI
kubectl get rgd cloudwatchlogsloggroup.aws.kropath.run \
  -o jsonpath='{.status.conditions[?(@.type=="GraphAccepted")].message}'
# → "failed to build resource "ackLogGroup": failed to get schema for resource ackLogGroup:
#    cannot resolve group version "cloudwatchlogs.services.k8s.aws/v1alpha1": schema not found"

# Install the CRD (cloudwatchlogs-chart v1.4.1 at time of writing)
helm pull oci://public.ecr.aws/aws-controllers-k8s/cloudwatchlogs-chart --version 1.4.1 \
  --untar --untardir tmp/
kubectl apply --server-side -f tmp/cloudwatchlogs-chart/crds

# Re-create the RGD — reaches Active immediately
kubectl delete rgd cloudwatchlogsloggroup.aws.kropath.run
kubectl apply -f rgds/cloudwatchlogsloggroup.aws.kropath.run.yaml
# → Active
```

## Pattern

Every new ACK group referenced by an RGD requires both bootstrap steps. The same pattern
caused the `elbv2` failure (documented in `frequent-rgd-errors.md` §"Provider bootstrap
reminder"). Check the list in `hack/install-provider-crds.sh` and
`tests/fixtures/rbac/kro-controller.yaml` whenever a new ACK group is introduced.
