# KRO-992 — every `mwaa/mwaaenvironment` step fails "actual resource not found"

**Date:** 2026-09-08
**PR:** [#242](https://github.com/kropath/kropath-aws/pull/242)
**Symptom:** `chainsaw/mwaa/mwaaenvironment` fails at its very first step
(`ac1-naming-default-template`) after the full 300s assert timeout.

## Symptom

The parent assert passes — `status.resourceName`, `status.namingStatus` and
`status.predictedArn` are all correct — and then the child assert times out:

```
| mwaaenvironment | ac1-naming-default-template | ASSERT | ERROR |
    mwaa.services.k8s.aws/v1alpha1/Environment @ mwaaenvironment/env-ac1
=== ERROR
actual resource not found
```

The RGD is `Active`, the `MWAAEnvironment` CR reconciles far enough to populate
`status`, the `<name>-naming` ConfigMap is created with correct `data.effectiveName`
— and the ACK `Environment` child is simply never created.

## Misleading intermediate error

`kubectl get mwaaenvironment env-ac1 -o jsonpath='{.status.conditions[*]}'` reports:

```
ResourcesReady=False :: resource reconciliation failed: waiting for unresolved resource:
  gvr "/v1, Resource=configmaps": node "vpcGate": dependent node "naming" not ready:
  node "naming": no observed state: waiting for readiness (data pending)
```

**This message points at the wrong node.** It names `naming` (a plain ConfigMap that
exists, with `DATA 1`) and `vpcGate` (an `externalRef` whose selector reads
`${naming.data.effectiveName}`). Both are red herrings. Rewriting `vpcGate`'s selector
to inline the effectiveName CEL — the KRO-919 "don't reference a sibling template node"
fix — only moved the identical message onto the next node in the graph:

```
node "ackEnvNoKms": dependent node "naming" not ready: node "naming": no observed state
```

Referencing `${naming.data.effectiveName}` from an `externalRef.selector.matchLabels`
is **not** the problem; the original selector works fine once the real cause is fixed.
That change was reverted and is not in the final diff.

## Root cause

`kubectl logs -n kro-system deployment/kro` has the actual failure:

```
ERROR dynamic-controller.watch-manager Watch error
  {"gvr": "mwaa.services.k8s.aws/v1alpha1, Resource=environments",
   "error": "failed to list *v1.PartialObjectMetadata:
     environments.mwaa.services.k8s.aws is forbidden:
     User \"system:serviceaccount:kro-system:kro\" cannot list resource \"environments\"
     in API group \"mwaa.services.k8s.aws\" at the cluster scope"}
ERROR dynamic-controller.watch-coordinator Failed to ensure watch
  {"gvr": "...Resource=environments", "error": "cache sync timeout"}
```

`mwaa` was added to `ACK_SERVICES` in `hack/install-provider-crds.sh` (so the CRD
installs and the RGD validates to `Active`), but `mwaa.services.k8s.aws` was **not**
added to the kro controller ClusterRole in `tests/fixtures/rbac/kro-controller.yaml`.

kro cannot establish a watch for the GVR, the informer cache never syncs, and the
readiness evaluator reports "no observed state" against whichever node it is walking
at the time — which is why the message names an innocent sibling instead of the ACK
child that is actually inaccessible.

## Fix

One line in `tests/fixtures/rbac/kro-controller.yaml`:

```yaml
      - networkfirewall.services.k8s.aws
      - sagemaker.services.k8s.aws
      - mwaa.services.k8s.aws        # added
```

## Rule — adding an ACK service takes TWO files

Adding a new resource family requires editing **both**:

1. `hack/install-provider-crds.sh` → `ACK_SERVICES` (installs the CRDs)
2. `tests/fixtures/rbac/kro-controller.yaml` → `apiGroups` (lets kro watch them)

Miss #2 and the failure is silent and misattributed: the RGD reaches `Active`, the
instance populates `status`, and only the ACK child is missing — with an error message
that blames an unrelated node.

Drift check (should print nothing):

```bash
bash -c '
SVCS=$(grep "^ACK_SERVICES=" hack/install-provider-crds.sh | sed "s/^ACK_SERVICES=\"\${ACK_SERVICES:-//; s/}\"$//")
for s in $SVCS; do
  grep -q -- "- ${s}\.services\.k8s\.aws" tests/fixtures/rbac/kro-controller.yaml || echo "MISSING: ${s}"
done'
```

All 49 services matched after the fix.

## Verification

Local kind cluster, `mwaaenvironment` namespace wiped first (a dirty namespace makes
`ac1` fail against a later step's `namingTemplate`, since `skipDelete: true` keeps
earlier instances alive and kro re-reconciles them whenever the shared `general-policy`
config is re-patched):

```
tests=2  failures=0  errors=0  time=87.7s
  mwaa/mwaaconfig        1.98s  PASS
  mwaa/mwaaenvironment  87.59s  PASS
```

## Note on the rest of the PR's CI failures

The failing run also listed ~28 other suites (all of `sagemaker`, both
`networkfirewall` ones, `dynamodb`, `documentdb`, `dsql`, `ec2launchtemplate`,
`bedrockharnessendpoint`). None are caused by this PR — the branch was based on
`4af5b41`, whose own `main` run already failed ~37 suites. `main` has since landed
KRO-1064 (SageMaker) and KRO-1066 (NetworkFirewall); rebasing onto `558159a` picks
both up.
