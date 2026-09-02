> **Point-in-time disclaimer:** This log records what was observed on 2026-09-02 against kro v0.9.2
> and chainsaw v0.2.15 in the `kropath-aws-test` kind cluster. kro behaviour, ACK CRD shapes, and
> chainsaw assertion semantics evolve; verify claims mechanically before acting on them.

# KRO-763: Five Chainsaw Assertion Traps in the CloudTrail Suites

**Date:** 2026-09-02
**Issue:** KRO-763 (PR #204)
**Symptom (as first seen in CI):** `chainsaw/cloudtrail/cloudtrailtrail` failed at step
`ac20-cwl-delivery-none` after 0.25 s with
`* status: Required value: field not found in the input object`, expected `status.resourceName: true`.

The sub-second failure was the tell: chainsaw's assert timeout is 5 m, so a genuine
"resource not reconciled yet" mismatch would have burned the full budget. An assert that dies
immediately is an **evaluation error**, not a retryable mismatch.

## Reproduction (local, before any fix)

```bash
cd tests
chainsaw test cloudtrail/cloudtrailtrail/ --config ../.chainsaw.yaml
#   ac20-cwl-delivery-none | ASSERT | ERROR
#   status.resourceName: Internal error: types are not comparable, bool - string
```

Local reproduction gave a far more precise message than CI. Always reproduce locally before fixing.

> Note: an *unrelated* local blocker surfaced first — the kro ServiceAccount could not `list`
> `trails.cloudtrail.services.k8s.aws`, so the instance never reconciled and status was absent
> entirely. That is stale local RBAC, not a code defect; `kubectl apply -f
> tests/fixtures/rbac/kro-controller.yaml` (which already grants `cloudtrail.services.k8s.aws`)
> clears it. Re-apply that fixture before concluding anything from a missing status.

## The five traps

### 1. An expression in assert *value* position is compared, not evaluated as a check

```yaml
# WRONG — chainsaw evaluates the expression to `true`, then compares bool against the
# actual string value: "Internal error: types are not comparable, bool - string"
status:
  resourceName: (contains(@, 'cloudtrailtrail'))

# CORRECT — assert the literal (naming is deterministic: {namespace}-{name})
status:
  resourceName: "cloudtrailtrail-ac20-trail"
  namingStatus: "valid"
```

The parenthesised-expression form only works in **key** position (`(expr): expected`), where the
key is the JMESPath and the value is what it must evaluate to.

### 2. `namingTemplate` set in BOTH config tiers is rejected by the CRD

`ac24-naming-mandatory-template` created a `CloudTrailConfig` with `spec.mandatory.namingTemplate`
*and* `spec.defaults.namingTemplate`. The CRD carries an `x-kubernetes-validations` mutual-exclusion
rule (`namingTemplate cannot be set in both mandatory and defaults`) and rejects the CR outright:

```
CloudTrailConfig.aws.kropath.run "ac24-cfg" is invalid: <nil>: Invalid value:
namingTemplate cannot be set in both mandatory and defaults
```

Declare the field in the **mandatory tier only**. Mandatory-wins precedence is still exercised —
the `status.effectiveConfig` patch carries both tiers, and that patch is what the RGD reads
(no controller runs in the test cluster).

### 3. `check:` blocks with `(contains(@, ...))` explode when the script writes no stdout

```yaml
# WRONG — if the script produced no stdout (e.g. the kubectl get failed), `@` is nil:
#   (contains(@, 'mandatory-tag-found')): Internal error: invalid type for: <nil>
check:
  (contains(@, 'mandatory-tag-found')): true

# CORRECT — signal failure with a non-zero exit; drop the check block entirely
echo "$TAGS" | jq -e '.[] | select(.key == "resource-type")' > /dev/null \
  || { echo "FAIL: mandatory tag resource-type not found"; exit 1; }
```

Same class as the earlier EDS `ac18`/`ac19` fixes in this PR.

### 4. A `script:` step does NOT retry — assert the child first

`script:` runs exactly once. Reading a kro-managed ACK child immediately after `apply:` races
reconciliation and returns `NotFound`. Asserting the **parent instance status** is not enough
either: kro writes instance status before the child becomes visible. Put a bare `assert:` on the
child resource itself directly before any script that reads it:

```yaml
- assert:
    resource:
      apiVersion: cloudtrail.services.k8s.aws/v1alpha1
      kind: Trail
      metadata:
        name: ac20-trail
        namespace: cloudtrailtrail
- script:
    content: |
      SPEC=$(kubectl get trail.cloudtrail.services.k8s.aws ac20-trail -n cloudtrailtrail -o jsonpath='{.spec}')
      ...
```

This one masqueraded as a flake: it passed on two runs and failed on the third.

### 5. `ownerReferences` asserted under `spec:` instead of `metadata:`

```yaml
# WRONG — evaluated against an empty spec; fails only after the full 5m assert timeout
spec:
  (ownerReferences[0].kind): CloudTrailTrail

# CORRECT
metadata:
  (ownerReferences[0].kind): CloudTrailTrail
```

Second occurrence in this PR (`ac23` had the same defect). A 5-minute assert timeout on a field
that should resolve instantly is the signature.

## Two tests that passed for the wrong reason

Fixing the above exposed two assertions that were passing vacuously in CI:

- **EDS `ac26-status-field-collision`** patched the ACK child's `status.status` to `ENABLED`
  (with `2>/dev/null || true`), then asserted `storeStatus: ""`. It only passed because the patch
  raced ahead of the child's creation and was silently swallowed — the step asserted the exact
  opposite of the propagation it was named for. Now: assert the child exists, patch without
  swallowing errors, assert `storeStatus: "ENABLED"`.
- **EDS `ac18-naming-exemption`** checked that `resourceName`/`namingStatus`/`predictedArn` are
  absent from status. With no preceding assert it could read an instance whose status had not been
  written at all, making every check trivially true. Now preceded by an assert on the ACK child.

A `|| true` or a `2>/dev/null` in a test script is nearly always a latent false pass.

## Verification

Three consecutive runs from wiped namespaces (`cloudtrailtrail`, `cloudtraileventdatastore`),
both suites in parallel — required, because a single green run can be reading state left behind
by an earlier partial run:

```
--- PASS: chainsaw/cloudtrail/cloudtraileventdatastore  (17.64s / 17.62s / 21.86s)
--- PASS: chainsaw/cloudtrail/cloudtrailtrail           (28.57s / 37.65s / 34.70s)
- Passed  tests 2 ; Failed tests 0     (x3)
```

## Addendum: inherited `main` regression (KRO-813) that kept the pipeline red

With both CloudTrail suites green, PR #204's CI still failed — in `cloudtrailconfig`, a suite the
PR does not touch:

```
KropathConfig.aws.kropath.run "cluster" is invalid: <nil>: Invalid value: "object":
no such key: allowedDocumentTypes evaluating rule:
spec.mandatory.ssm.allowedDocumentTypes and spec.defaults.ssm.allowedDocumentTypes
cannot both be set. Set the field in exactly one tier.
```

This is a `main` regression, not a PR defect. `main` had been red since
`a0d88b1 feat(KRO-813)` (run 33618110858 shows the identical error), and PR CI tests the branch
**merged with main**, so every open PR inherited it.

**Root cause.** KRO-813 correctly removed the scalar `default:` values from `KropathConfig`'s
`spec.mandatory.*` / `spec.defaults.*` fields, per `kropath-rgd-cel-traps` §2. But 27 of the CRD's
117 `x-kubernetes-validations` rules read those fields *without* a `has()` guard:

```cel
!(has(self.spec.mandatory) && has(self.spec.mandatory.ssm) &&
  size(self.spec.mandatory.ssm.allowedDocumentTypes) > 0 && ...)
```

While the defaults existed, Kubernetes materialised `[]` / `""` / `false` on every instance, so the
unguarded access always resolved and the omission was invisible. Once the defaults were removed the
key is genuinely absent, CEL raises `no such key`, and **every** `KropathConfig` apply is rejected —
including ones that set none of the fields in question.

**Fix.** Add the missing field-level guard before each access (54 insertions across 27 rules):

```cel
!(has(self.spec.mandatory) && has(self.spec.mandatory.ssm) &&
  has(self.spec.mandatory.ssm.allowedDocumentTypes) &&
  size(self.spec.mandatory.ssm.allowedDocumentTypes) > 0 && ...)
```

The change is strictly *loosening*: a guard can only make a rule evaluate `false` (no violation)
where it previously threw. It cannot introduce a new rejection. Verified against a live API server:

| Case | Expected | Result |
|---|---|---|
| Minimal config, no family fields (the failing one) | accepted | accepted |
| `ssm.allowedDocumentTypes` set in both tiers | rejected | rejected |
| `ec2.imdsv2Required: true` in both tiers | rejected | rejected |
| Fields set in the mandatory tier only | accepted | accepted |

Then re-ran the suites that consume `KropathConfig`: `cloudtrail` (3), `elasticache` + `memorydb`
(15), `kms` + `lambda` + `iam` (19) — 37 suites, 0 failures.

### Related latent occurrence — NOT fixed here

`crds/secretsmanagerconfig.yaml` has the same unguarded shape in 4 rules
(`kmsKeyID`, `replicaRegions`, `forceOverwriteReplicaSecret`, `namingTemplate`). It does not fail
today only because that CRD still carries the scalar `default:` values that cel-traps §2 prohibits.
Whoever removes those defaults must add the `has()` guards in the same change, or secretsmanager
will break exactly as KropathConfig did.

**Rule of thumb:** removing a `default:` from a field that any `x-kubernetes-validations` rule reads
is a breaking change unless every read of that field is `has()`-guarded. Audit the rules in the same
commit that removes the default.
