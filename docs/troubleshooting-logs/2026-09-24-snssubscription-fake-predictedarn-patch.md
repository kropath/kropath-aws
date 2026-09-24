# KRO-1223: Chainsaw Fixture Faked `predictedArn` via Direct Status Patch — Silently Overwritten/Never Set

**Date:** 2026-09-24
**Issue:** KRO-1223
**Scope:** `tests/sns/snssubscription/chainsaw-test.yaml` (AC-1 `topic-ref-local`, AC-16 `redrive-policy-dlq-ref`)

> **Point-in-time disclaimer.** This log records what the author observed at the time of writing.
> CEL/kro behaviour may change across versions. Verify mechanically before acting on claims here.

## Problem

CI failed on PR #298 with:

```
* spec.topicARN: Invalid value: "": Expected value: "arn:aws:sns:ap-southeast-2:123456789012:events-prod-order-events"
```

The ACK `Subscription` child's `spec.topicARN` resolved to `""` instead of the referenced
`SNSTopic`'s ARN, even though the test fixture explicitly patched the topic's
`status.predictedArn` to the expected value.

## Root cause

`SNSTopic.status.predictedArn` (and `SQSQueue.status.predictedArn`) are **kro-computed CEL
fields**, not ACK-populated passthrough fields like `status.ackResourceMetadata.arn`:

```yaml
predictedArn: >-
  ${rsrcCfg.size() > 0 && has(rsrcCfg[0].status.effectiveConfig) && has(rsrcCfg[0].status.effectiveConfig.aws) && ...
    ? "arn:" + ... + naming.data.resourceName
    : ""}
```

A `kubectl patch --subresource=status` directly setting `predictedArn` is **not durable** —
kro recomputes this field from `rsrcCfg` (the topic's own governance config lookup) and
`naming.data.resourceName` on every reconcile. Two compounding bugs made the recompute always
land on `""`:

1. The `SNSTopic`/`SQSQueue` test fixtures used `spec: {}` — **never setting `configRef`** —
   so the config lookup fell back to a nonexistent `general-policy` config, `rsrcCfg.size() == 0`,
   and the `predictedArn` guard's leading `rsrcCfg.size() > 0 &&` short-circuited to `""`.
2. For AC-16 specifically, the SQSQueue's referenced config was created as an **`SNSConfig`**
   (reusing the variable name from the subscription's own config) instead of the required
   **`SQSConfig`** kind — `SQSQueue`'s `rsrcCfg` externalRef selector only matches `SQSConfig`.

Because kro only reconciles `SNSTopic`/`SQSQueue` on watch events for resources it actually
manages, and status is fully computed (never partially preserved across the patch), the manual
`predictedArn` patch was silently discarded on the next reconcile (typically immediate, since
kro's `KRO_INSTANCE_REQUEUE_INTERVAL` is 3s in this test cluster).

## Fix

For both AC-1 and AC-16:

1. Set `spec.configRef` on the `SNSTopic` / `SQSQueue` fixture to a config that's actually
   populated (matching the SNS/SQS naming-template pattern used elsewhere, e.g. `aws-sns-01`
   ac22/ac23 in `tests/sns/snstopic/chainsaw-test.yaml`).
2. Patch the config's `status.effectiveConfig` with the **full** field set including the `aws`
   tier (`accountId`/`region`/`partition`) and `defaults.namingTemplate` — not just
   `tags`/`syncedLabels`/`syncedAnnotations`.
3. For AC-16, create a dedicated `SQSConfig` (not `SNSConfig`) for the DLQ `SQSQueue`.
4. Removed the direct `kubectl patch ... predictedArn` scripts entirely; added an intermediate
   `assert` on the topic's/queue's own `status.predictedArn` (computed via the default
   `{namespace}-{name}` naming template) so a future regression fails at the source resource,
   not only at the downstream `Subscription` assert.
5. Updated the downstream `Subscription`/`redrivePolicy` assert literals to the correctly
   computed ARNs (`arn:aws:sns:...:snssubscription-ac1-topic`,
   `arn:aws:sqs:...:snssubscription-ac16-dlq`) instead of the illustrative ARNs quoted verbatim
   from the spec's AC table (those were example values, not a literal naming-template
   requirement — AC-1/AC-16 test the *relationship* between `Subscription.spec.topicARN`/
   `redrivePolicy` and the referenced resource's `predictedArn`, not a specific string).

## Verification

1. Reproduced the exact CI failure locally: `chainsaw test sns/snssubscription/` against the
   `kropath-aws-test` kind cluster reproduced the identical
   `spec.topicARN: Invalid value: "": Expected value: "..."` failure before the fix.
2. Applied the fix, re-ran `chainsaw test sns/snssubscription/ --parallel 1` — all 30 AC
   scenarios passed (352.54s).
3. Note: mid-investigation the `kro` operator pod was found `CrashLoopBackOff`/`OOMKilled`
   (unrelated pre-existing cluster-age issue, 45h+ uptime with heavy RGD churn) — this
   fully masked reconciliation and produced a red herring `status: field not found` assertion
   error on an unrelated retry. `kubectl -n kro-system rollout restart deployment/kro` cleared
   it. Not a code issue; noted here in case a future session hits the same symptom on this
   shared long-lived cluster.

## Key insight

Never assume an RGD's computed `status.*` field can be faked via a direct
`kubectl patch --subresource=status` in a Chainsaw fixture. Only fields that are genuine
ACK/external passthroughs (e.g. `status.ackResourceMetadata.arn`) are safe to patch this way —
anything derived from `rsrcCfg`/`naming.data` inside the RGD's own `status:` block is
recomputed by kro on every reconcile and a manual patch will not stick. Drive those fields
through a properly configured (and correctly-kinded) governance config instead, exactly as the
"real" naming-template tests already do.
