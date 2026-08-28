---
date: 2026-08-28
ticket: KRO-799
pr: kropath-aws#154
author: Implementer (e9bf59b4)
disclaimer: Point-in-time hypothesis; verify before acting on claims.
---

# DSQLCluster AC-11: policy mutual-exclusion status.validationError always empty

## Symptom

Chainsaw test `ac11-policy-mutual-exclusion` timed out (304 s = AssertTimeout) on CI
commit `9c330d9`. The assert expected:

```
status:
  validationError: "spec.policy and spec.clusterPolicyRef are mutually exclusive — set exactly one"
```

Actual result:

```
status: {}
```

AC-7 (kmsKey mutual exclusion) passed. AC-11 (policy mutual exclusion) failed.

## Root Cause

The `status.validationError` expression used a nested ternary referencing TWO `includeWhen`-gated
ConfigMap variables:

```yaml
validationError: >-
  ${has(kmsKeyMutualExclusionError.data) && has(kmsKeyMutualExclusionError.data.error)
    ? kmsKeyMutualExclusionError.data.error
    : (has(policyMutualExclusionError.data) && has(policyMutualExclusionError.data.error)
        ? policyMutualExclusionError.data.error
        : "")}
```

In AC-11: `kmsKeyMutualExclusionError` is NOT included (KMS conflict absent), `policyMutualExclusionError`
IS included (policy conflict present). `has()` on an excluded `includeWhen` template variable
silently causes the entire status field expression to return `""` — the Unbound Variable Freeze
documented in `docs/frequent-rgd-errors.md §"The Unbound Variable Freeze"`. CEL short-circuit does
NOT help because kro's evaluation of the first `has()` call already fails/returns empty before the
else branch runs.

AC-7 passed because `kmsKeyMutualExclusionError` IS included in that scenario; the `has()` check
succeeds and CEL short-circuits before ever evaluating `policyMutualExclusionError`.

Reproduced locally: applied ac11-cluster with both `spec.policy` and `spec.clusterPolicyRef` set,
observed `status.validationError` missing after 10 s of reconciliation while the
`ac11-cluster-policy-validation-error` ConfigMap WAS correctly created.

## What Failed

**First fix attempt (rejected):** Replace the CM variable references with direct `schema.spec.*` checks:

```yaml
validationError: >-
  ${(schema.spec.kmsKeyArn != "" && schema.spec.kmsKeyRef != "")
    ? "..."
    : ((schema.spec.policy != "" && schema.spec.clusterPolicyRef != "")
        ? "..."
        : "")}
```

kro rejected this with `references unknown identifiers: [schema]`. The `status:` block in kro v0.9.2
does NOT have access to `schema.*`; that identifier is only available in resource `template:` blocks.

## What Worked

Added an always-included `validationMsg` ConfigMap (no `includeWhen`) that computes the combined
error message using `schema.spec.*` in the template block — the same pattern as the `naming` CM in
`eventbridgearchive.aws.kropath.run.yaml`:

```yaml
- id: validationMsg
  template:
    apiVersion: v1
    kind: ConfigMap
    metadata:
      name: ${schema.metadata.name}-validation-msg
    data:
      error: >-
        ${(schema.spec.kmsKeyArn != "" && schema.spec.kmsKeyRef != "")
          ? "spec.kmsKeyArn and spec.kmsKeyRef are mutually exclusive — set exactly one"
          : ((schema.spec.policy != "" && schema.spec.clusterPolicyRef != "")
              ? "spec.policy and spec.clusterPolicyRef are mutually exclusive — set exactly one"
              : "")}
```

Status block then reads:

```yaml
validationError: >-
  ${validationMsg.data.error}
```

This keeps `validationMsg` always bound (no Unbound Variable Freeze possible) and uses `schema.spec.*`
in the template block where it IS valid.

The existing `kmsKeyMutualExclusionError` and `policyMutualExclusionError` CMs are retained so
Chainsaw tests can still assert on their existence (`ac?-cluster-kms-validation-error`,
`ac?-cluster-policy-validation-error`).

Verified locally:
- AC-11 (policy conflict): `status.validationError = "spec.policy and clusterPolicyRef..."` ✓
- AC-7 (kms conflict): `status.validationError = "spec.kmsKeyArn and kmsKeyRef..."` ✓
- No-conflict case: `status.validationError = ""` (field present but empty, no test asserts absence) ✓

## Pattern Generalisation

When a single `status:` field must combine errors from TWO or more `includeWhen`-gated CMs, do NOT
nest ternaries that reference both CM variables. Instead, materialise the combined error in an
always-included CM using `schema.spec.*` in the template block. Reference only the always-bound
variable in the `status:` block.

The ACM Certificate RGD (`acmcertificate.aws.kropath.run.yaml`) avoids this trap by using one
status field per error CM (never referencing a second CM in the else branch).
