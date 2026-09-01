> **Point-in-time disclaimer:** This log records what was observed on 2026-09-02 against kro v0.9.2
> in the `kropath-aws-test` kind cluster. kro behaviour, ACK CRD shapes, and RGD patterns evolve;
> verify claims mechanically before acting on them.

# KRO-925: includeWhen Variant Split Silently Emptied Status Across 8 RGDs

**Date:** 2026-09-02
**Issue:** KRO-925 (PR #195)
**Symptom (as first seen):** `chainsaw/apigateway/apigatewayauthorizer` step `ac6-restapi-ref` failed
after a full 5-minute assert timeout with
`* spec.restAPIID: Invalid value: "": Expected value: "abc123def"`.

## Reproduction (local, before any fix)

```bash
kubectl create ns repro925
# APIGatewayConfig with minimumTlsVersion "" in BOTH tiers, then an APIGatewayRestAPI + Authorizer
kubectl patch restapi r6-api -n repro925 --subresource=status --type=merge \
  -p '{"status":{"id":"abc123def"}}'
kubectl get apigatewayrestapi r6-api -n repro925 -o jsonpath='{.status}'
#   -> "noPolicyRestApiId":"abc123def"   and NO "restApiId" key at all
kubectl get authorizer r6-auth -n repro925 -o jsonpath='{.spec.restAPIID}'
#   -> "" (empty)
```

## Root Cause

KRO-925 replaced single always-included ACK children with mutually exclusive `includeWhen` variants
so that optional fields are *omitted* rather than sent as `""`. Two follow-on defects came with that:

1. **Combined status expressions never evaluate.** A `status:` expression that coalesces across the
   variants (`withKms.?status... != "" ? withKms... : noKms...`) always mentions at least one
   *excluded* resource, and kro skips the whole field — silently, with the instance still `ACTIVE`.
   This is the Unbound Variable Freeze applied to the `status:` block.
   Confirmed with `dsql/dsqlcluster` `ac19-status-fields-propagation`, which asserted
   `status.arn/clusterStatus/endpoint/identifier` and got `status: {}`.

2. **Per-variant status fields leak into consumers.** The earlier fix attempt (commit `a6fed85`)
   split `APIGatewayRestAPI.status.restApiId` into `restApiId` + `noPolicyRestApiId` and taught
   `APIGatewayDeployment` to coalesce both — but **not** `APIGatewayAuthorizer`, which kept reading
   `restApiId` alone and silently got `""`. The same class of miss was latent in
   `EFSAccessPoint`/`EFSMountTarget`, which read `EFSFileSystem.status.fileSystemId`.

An audit for `status:` expressions naming more than one gated resource id found **8** affected RGDs;
only 3 of them had a failing Chainsaw suite. A green suite is not evidence of correctness here — the
field only fails when a test exercises a non-first variant *and* asserts that status field.

## What Was Tried

| # | Approach | Result |
|---|---|---|
| 1 | Coalesce on the consumer side (`restApiId` else `noPolicyRestApiId`) in `apigatewayauthorizer` | Works, verified live (`spec.restAPIID: abc123def`), but does not scale: every current and future consumer must remember to coalesce, and dsqlcluster would have needed 28 status fields (7 values × 4 variants). Kept only long enough to confirm the diagnosis, then replaced by #2. |
| 2 | **Always-bound self-lookup `externalRef`** to the RGD's own ACK child, keyed on the `app.kubernetes.io/instance` label every variant already sets | Adopted. RGD reaches `Active`; `dsql/dsqlcluster` and all 11 CI-selected suites pass. |

## What Worked

Add an `externalRef` for the RGD's own child. An `externalRef` is never excluded by `includeWhen` —
it resolves to `[]` until the child exists — so the status field is evaluated on every reconcile:

```yaml
resources:
  - id: ackClusterRef
    externalRef:
      apiVersion: dsql.services.k8s.aws/v1alpha1
      kind: Cluster
      metadata:
        namespace: ${schema.metadata.namespace}
        selector:
          matchLabels:
            app.kubernetes.io/instance: ${schema.metadata.name}
status:
  arn: >-
    ${ackClusterRef.size() > 0 ? ackClusterRef[0].?status.?ackResourceMetadata.?arn.orValue("") : ""}
```

Safe because every variant renders the same `metadata.name` and the same
`app.kubernetes.io/instance` label, and the lookup is scoped by `apiVersion` + `kind` + namespace,
so it can only match this instance's own child. No dependency cycle: `externalRef` is a cluster
lookup, not a graph edge, so kro does not order it after the variants.

Applied to: `dsqlcluster`, `efsfilesystem`, `ecrrepository`, `ekscluster`, `lambdafunction`,
`secretsmanagersecret`, `cloudfrontoriginaccesscontrol`, `acmedomainvalidation`, and
`apigatewayrestapi`. For `apigatewayrestapi` it also removed the leaky `noPolicyRestApiId` /
`noPolicyRootResourceId` status fields, reverted the coalesce in `apigatewaydeployment` and
`apigatewayauthorizer` to a single `restApiId` read, and collapsed the duplicated
`apiResourcesWithPolicy` / `apiResourcesNoPolicy` `forEach` blocks back into one `apiResources`.

## Two Unrelated Test Defects Found in the Same Sweep

* `tests/secretsmanager/secretsmanagersecret` `ac1-basic-creation` still asserted
  `spec.kmsKeyID: ""`. KRO-925 deliberately omits that field now — changed to `(spec.kmsKeyID): null`.
* `tests/eks/ekscluster` `ac15-unresolved-naming-token` patched `"tags":{}` with a merge patch, which
  **cannot remove map keys**, so `env: prod` set by the later `ac17-tags-merge` step survived into the
  next run of the suite and made `{tag.env}` resolve. Passes on a fresh CI cluster, fails on every
  local re-run. Fixed with the documented two-command reset (`effectiveConfig: null`, then re-patch).

## Local-Cluster Artifacts (not code bugs — do not "fix" these in the RGDs)

* `cannot update CRD <plural>: breaking changes detected: Property X was removed` — a long-lived kind
  cluster holds a CRD derived from an older RGD/ACK schema. `kubectl delete crd <plural>.aws.kropath.run`
  (strip instance finalizers first; the test cluster has no ACK controllers) and re-apply the RGD.
  `acmcertificate` hit this with `type_`/`httpRedirect` from an older ACK Certificate CRD.
* Stale resources from previous runs persist because the canonical suite pattern uses
  `spec.skipDelete: true`. A ConfigMap or CR from a run 12 days earlier can make an assert pass or
  fail for reasons unrelated to the current code — check `metadata.creationTimestamp` before
  concluding anything from a single suite result.

## Known Remaining Instance (pre-existing, NOT fixed here)

The audit script still reports one hit on `main`, outside this PR's scope:

```
rgds/snstopic.aws.kropath.run.yaml  topicArn -> [ackTopicNoPolicyNoFeedback,
  ackTopicNoPolicyWithFeedback, ackTopicNoPolicyWithFeedbackNoARN,
  ackTopicWithPolicyNoFeedback, ackTopicWithPolicyWithFeedback,
  ackTopicWithPolicyWithFeedbackNoARN]
```

`SNSTopic.status.topicArn` coalesces across six variants, so it is never written. It shipped with
KRO-928 (PR #189) and is not touched by KRO-925; deliberately left for a follow-up ticket rather than
widened into this PR. The `sns` suite is not in this PR's CI-selected target set, so it is not
exercised here. The fix is the same always-bound self-lookup shown above.

## Verification

RGD compiles gate (`delete rgd` → `apply` → wait for `Active`) run on all 10 changed RGDs, then the
full CI-selected target set locally:

```
test-acm ALL PASS          test-ecs ALL PASS        test-eks ALL PASS
test-apigateway ALL PASS   test-efs ALL PASS        test-elb ALL PASS
test-cloudfront ALL PASS   test-ecr ALL PASS        test-lambda ALL PASS
test-dsql ALL PASS         test-secretsmanager ALL PASS
```

See `docs/frequent-rgd-errors.md` §"Variant-Split Resources Freeze Combined Status Expressions —
Use an Always-Bound Self-Lookup" for the audit script and the rule.
