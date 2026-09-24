# KRO-1223: SNSSubscription `ackSub*` Variant Gates Read a Sibling Node's Observed State (KRO-919 Class)

**Date:** 2026-09-24
**Issue:** KRO-1223
**Scope:** `rgds/snssubscription.aws.kropath.run.yaml` — all 16 `ackSub*` variant `includeWhen` gates

> **Point-in-time disclaimer.** This log records what the author observed at the time of writing.
> CEL/kro behaviour may change across versions. Verify mechanically before acting on claims here.

## Problem (flagged in Implementation Reviewer's PR #298 review)

All 16 `ackSub*` variant `includeWhen` gates branched on the redrivePolicy-present/absent split
using:

```cel
# R present
(dlqCr.size() > 0 && schema.spec.redrivePolicy.deadLetterQueueRef != "")
# R absent
!(dlqCr.size() > 0 && schema.spec.redrivePolicy.deadLetterQueueRef != "")
```

`dlqCr` is a graph-read (`externalRef` lookup of the referenced `SQSQueue`'s *observed state*),
not `schema.spec` or a resolved config tier. Per `kropath-core/docs/checklists/pre-review.md`
("includeWhen graph-read safety check") and KRO-919: a gate that reads a sibling node cannot be
safely evaluated during teardown, when that sibling node may already be gone. If the DLQ
`SQSQueue` is deleted while the `SNSSubscription` still references it, `dlqCr` re-resolves to
`[]` on the next reconcile — which flips `dlqCr.size() > 0` from `true` to `false` and switches
this instance **mid-lifecycle** from an "R present" variant to an "R absent" variant. Since each
variant maps to a structurally different ACK child template, kro treats this as "materialize a
different child" rather than "update the existing child," which is exactly the failure mode
KRO-919 documents as causing the instance to hang in `DELETING` holding `kro.run/finalizer`.

The `filterPolicy`/`deliveryPolicy`/`subscriptionRoleArn` splits in this same RGD were already
schema-only (`schema.spec.filterPolicy != ""`, etc.) — only the `redrivePolicy` split incorrectly
pulled in the graph-read.

## Fix

1. Changed all 8 "R present" `includeWhen` gates from `dlqCr.size() > 0 && schema.spec.redrivePolicy.deadLetterQueueRef != ""` to schema-only `schema.spec.redrivePolicy.deadLetterQueueRef != ""`.
2. Changed all 8 "R absent" `includeWhen` gates from the negation to schema-only `schema.spec.redrivePolicy.deadLetterQueueRef == ""`.
3. Moved the `dlqCr.size() > 0` safety check into the `redrivePolicy:` template field itself (the
   8 "R present" variants), mirroring the existing `topicARN`/`topicCr` pattern:

   ```cel
   # Before (unguarded — errors/produces garbage if dlqCr hasn't resolved yet)
   redrivePolicy: >-
     ${"{\"deadLetterTargetArn\":\"" + dlqCr[0].status.predictedArn + "\"}"}

   # After (guarded, matches topicARN's ternary-on-graph-read-size pattern)
   redrivePolicy: >-
     ${dlqCr.size() > 0 ? "{\"deadLetterTargetArn\":\"" + dlqCr[0].status.predictedArn + "\"}" : ""}
   ```

   This is safe because template field evaluation (post variant-selection) doesn't change
   *which* child is materialized — only its field values — so reading sibling state here does
   not risk the mid-lifecycle variant-switch deadlock that `includeWhen` does.

## Why this is safe now

- `includeWhen` decides the RGD's static structural branch (which of the 16 mutually exclusive
  child templates gets instantiated) and must depend only on `schema.spec`/resolved config so
  that branch stays stable across the object's full lifecycle including teardown, when
  `dlqCr` may resolve to `[]` because the referenced `SQSQueue` was already deleted.
- The `redrivePolicy:` template field only computes a *value* within an already-selected variant;
  a graph-read there naturally degrades to `""` if the DLQ isn't resolved, rather than causing kro
  to reclassify which variant is active.

## Verification

1. **RGD compiles gate:** `kubectl delete rgd snssubscription.aws.kropath.run && kubectl apply -f rgds/snssubscription.aws.kropath.run.yaml` — reached `Active` on the first iteration (all conditions `True`: `GraphAccepted`, `GraphRevisionsResolved`, `KindReady`, `ControllerReady`, `Ready`).
2. **Chainsaw suite:** `chainsaw test sns/snssubscription/ --parallel 1` — all 30 AC scenarios pass (AC-16/AC-17, the redrivePolicy present/absent scenarios, still pass with the schema-only gate + guarded template value).

## Key insight

`includeWhen` gates that select between structurally different child templates must be
schema-only (or resolved-config-only) — never a graph-read of another node's `.status`. If a
child's *value* (not its structural shape) needs a sibling's resolved data, read that sibling
inside the template field itself with its own guard, not in the gate that decides which template
fires. This is the same principle documented for topicARN/topicCr in this RGD (already correct);
the redrivePolicy split simply missed it originally.
