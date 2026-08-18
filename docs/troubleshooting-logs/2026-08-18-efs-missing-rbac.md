# EFS Chainsaw Tests Timing Out: Missing `efs.services.k8s.aws` in kro-controller RBAC

**Date:** 2026-08-18
**Issue:** KRO-423
**PR:** #127

> **Point-in-time disclaimer:** This log records what the author understood at the time of
> writing. Verify claims mechanically before acting on them. See
> `docs/multica/agents/README.md` §"Knowledge source precedence".

## Symptom

CI `Chainsaw E2E Tests` job failed. All three EFS test suites (`efsfilesystem`, `efsaccesspoint`,
`efsmounttarget`) timed out at 300s with no ACK FileSystem/AccessPoint/MountTarget CRs ever
being created:

```
| efsfilesystem | ac1-encrypted-default-false | ASSERT | FAIL |
--- timeout: context deadline exceeded (300s)
no match found for: efs.services.k8s.aws/v1alpha1/FileSystem
```

The CI setup step confirmed that:
- EFS CRDs installed successfully (`filesystems.efs.services.k8s.aws serverside-applied`)
- EFS RGDs reached Active (`efsfilesystem.aws.kropath.run condition met`)

Yet ACK FileSystem CRs were never created by the kro controller.

## Root Cause

`tests/fixtures/rbac/kro-controller.yaml` was missing `efs.services.k8s.aws` from the aggregated
ClusterRole. Without this entry, the kro controller receives `forbidden` errors when attempting
to create/get/patch/delete ACK EFS child resources:

```
filesystems.efs.services.k8s.aws "repro-fs" is forbidden: User
"system:serviceaccount:kro-system:kro" cannot get resource "filesystems"
in API group "efs.services.k8s.aws" in the namespace "efs-repro"
```

This is the exact same pattern documented for ElastiCache in
`2026-08-18-elasticache-missing-ack-service-and-rbac.md`.

Note: `hack/install-provider-crds.sh` already included `efs` in `ACK_SERVICES` (added in the
original implementation commit), so CRD installation was NOT the problem — only RBAC was missing.

## Local Reproduction

```bash
# Create test namespace
kubectl create namespace efs-repro

# Apply EFSConfig
kubectl apply -f - <<EOF
apiVersion: aws.kropath.run/v1alpha1
kind: EFSConfig
metadata:
  name: general-policy
  namespace: efs-repro
  labels:
    aws.kropath.run/resource-name: general-policy
spec: {}
EOF

# Patch effectiveConfig status
kubectl patch efsconfig general-policy -n efs-repro --subresource=status --type=merge \
  -p '{"status":{"effectiveConfig":{"mandatory":{},"defaults":{"encrypted":false},"aws":{"accountId":"123456789012","region":"ap-southeast-2"}}}}'

# Apply EFSFileSystem
kubectl apply -f - <<EOF
apiVersion: aws.kropath.run/v1alpha1
kind: EFSFileSystem
metadata:
  name: repro-fs
  namespace: efs-repro
spec: {}
EOF

# Check controller logs — showed "forbidden" error before fix
kubectl logs -n kro-system deployment/kro | grep -i "efs-repro"
```

Output before fix:
```
filesystems.efs.services.k8s.aws "repro-fs" is forbidden: User
"system:serviceaccount:kro-system:kro" cannot get resource "filesystems"
in API group "efs.services.k8s.aws" in the namespace "efs-repro"
```

Output after fix (FileSystem CR created successfully):
```
NAME       ID    ENCRYPTED   SIZE   MOUNTTARGETS   STATE   SYNCED   AGE
repro-fs         false                                              13s
```

## Fix

Added `- efs.services.k8s.aws` to `tests/fixtures/rbac/kro-controller.yaml`:

```diff
       - kafka.services.k8s.aws
       - elasticache.services.k8s.aws
+      - efs.services.k8s.aws
```

## Pattern

Every new ACK service family introduced into kropath-aws requires BOTH bootstrap steps:
1. Add to `ACK_SERVICES` in `hack/install-provider-crds.sh` — so CRDs are installed in CI
2. Add to `tests/fixtures/rbac/kro-controller.yaml` — so the kro controller can create/manage child CRs

Missing either step causes different symptoms:
- Missing from `ACK_SERVICES`: RGDs stay `Inactive` (kro can't resolve the group version)
- Missing from RBAC: RGDs are `Active`, CRs are created by users, but kro never reconciles the children (forbidden error, silent timeout)

The second failure mode is harder to diagnose because CI setup succeeds and RGDs are Active —
only the Chainsaw test assertions reveal the problem.
