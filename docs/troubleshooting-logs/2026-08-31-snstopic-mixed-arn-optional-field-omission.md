# SNS Topic — Mixed ARN Detection and optional.none() Write-Position Probe

> **Point-in-time disclaimer:** This log records what was observed on 2026-08-31 using kro v0.9.2.
> Claims here are hypotheses verified against that specific version. Future kro versions may
> change behaviour; always verify against the running cluster before acting on this log.

**Ticket:** KRO-928  
**Date:** 2026-08-31  
**RGD:** `snstopic.aws.kropath.run`

---

## Problem

The SNS Topic RGD has 10 ARN fields (5 protocols × `successFeedbackRoleArn` and
`failureFeedbackRoleArn`). The `hasAnyFeedbackARN` flag routes to the WithARN template when ANY
ARN is configured. But when only some ARNs are configured (mixed case), the WithARN template
renders the unconfigured fields as `""`. ACK forwards empty-string attributes to AWS SNS, which
rejects them (KRO-911 / `omit-don't-empty` rule).

**Question:** Can kro v0.9.2 omit a scalar string field when its CEL expression evaluates to
"no value", so that a single template can handle both the configured and unconfigured cases?

---

## Approaches Tried

### Approach 1: `optional.none()` in write position (probe 4)

```yaml
# kro928probe4.aws.kropath.run
resources:
  - id: testConfigMap
    template:
      apiVersion: v1
      kind: ConfigMap
      metadata:
        name: ${schema.metadata.name}-cm
      data:
        nested:
          sqsSuccessFeedbackRoleArn: >-
            ${schema.spec.testConfig.nested.sqsSuccessFeedbackRoleArn != ""
              ? schema.spec.testConfig.nested.sqsSuccessFeedbackRoleArn
              : optional.none()}
```

**Result:** RGD → Inactive.

```
GraphAccepted: False
found no matching overload for '_?_:_' applied to '(bool, string, optional_type(dyn))'
```

kro's CEL type checker requires both ternary branches to return identical types. `optional.none()`
returns `optional_type(dyn)`, which is incompatible with `string`.

**Conclusion:** `optional.none()` in write position is not supported in kro v0.9.2.

### Approach 2: Map-merge construction

Map merge (`{}.merge(conditionalMap)`) cannot conditionally include or exclude a YAML key that
is declared in the template structure. The template YAML structure is fixed at authoring time;
only the VALUES of declared keys can be changed by CEL.

**Conclusion:** Map-merge cannot achieve field-level omission either.

---

## What Worked

**In-graph detection + error ConfigMap pattern:**

1. Added `hasMixedFeedbackARN` flag to the naming ConfigMap `data` block. CEL expression:
   `(anyArn) && !(all 10 ARN positions each have at least one non-empty source)`.

2. Added `mixedFeedbackARNError` advisory ConfigMap resource:
   ```yaml
   - id: mixedFeedbackARNError
     includeWhen:
       - '${naming.data.hasMixedFeedbackARN == "true"}'
   ```

3. Gated all 4 WithARN templates to exclude when mixed:
   ```yaml
   includeWhen:
     - '${...existing conditions... && naming.data.hasMixedFeedbackARN != "true"}'
   ```

**Key verification:** After fixing a double-`}}` bug in the initial gate (the GATE_SUFFIX
mistakenly included a closing `}` that was already present in the original), the RGD reached
`Active` immediately on apply.

---

## CEL Patterns Confirmed Working

- `naming.data.<key>` IS accessible from `includeWhen` conditions for peer resources.
  `topicPolicyCr.size() > 0` already used this pattern; `naming.data.hasMixedFeedbackARN`
  follows the same in-graph dependency resolution.

- The folded block scalar (`>-`) with embedded newlines for multi-line CEL expressions works
  correctly — YAML folds newlines to spaces, producing a single CEL string. kro evaluates it.

---

## Files Changed

- `rgds/snstopic.aws.kropath.run.yaml` — `hasMixedFeedbackARN` flag, `mixedFeedbackARNError`
  resource, 4 WithARN `includeWhen` gates
- `docs/frequent-rgd-errors.md` — new section on `optional.none()` write-position rejection
- `docs/deferred-capabilities.md` — new entry for SNS mixed-ARN deferred capability
- `tests/sns/snstopic/chainsaw-test.yaml` — mixed-ARN error case scenario added
