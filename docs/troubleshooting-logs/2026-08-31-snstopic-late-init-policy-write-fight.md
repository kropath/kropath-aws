# Troubleshooting Log: SNSTopic ACK Late-Init Policy Write Fight (KRO-920)

**Date:** 2026-08-31
**Author:** Implementer
**Ticket:** KRO-920
**Repo:** kropath-aws
**Files:** `rgds/snstopic.aws.kropath.run.yaml`, `docs/frequent-rgd-errors.md`

> **Point-in-time disclaimer:** This log records the author's understanding at the time of writing.
> Claims here may later be superseded by updated findings in `docs/frequent-rgd-errors.md` or
> subsequent troubleshooting logs. Verify mechanically before acting on any claim.

---

## Symptom

`metadata.generation` on ACK `Topic` objects advanced roughly five times per second for ~10–15
minutes after creation, costing ~2,600 writes per resource creation. Both SNS topics in the test
namespaces (`payments-test/payment-events`, `data-test/ingest-events`) exhibited this. ACK reported
`ACK.ResourceSynced=True` with no terminal condition; kro reported `Ready=True :: AllResourcesReady`.
Nothing appeared broken.

An earlier observation (sampled mid-handover) incorrectly concluded that this was an unbounded loop
and that delete-and-recreate did not help. It is bounded: both topics settled (~generation 2703 and
2595) and stayed settled. Recreation does resolve it — it simply re-pays the ~2,600-write handover.

---

## Root Cause

KRO-905 changed the six "NoPolicy" SNS Topic variants (standard + FIFO, 3 feedback combinations
each) to omit `spec.policy` entirely when no `topicPolicyRef` is set. SNS returns a default access
policy for every topic, so ACK reads it back and writes it to `spec.policy` via late-initialisation.
kro then re-applies the object (without `spec.policy` in its managed field set), ACK late-inits again,
and the cycle continues until both managers settle into shared ownership of the field.

```
kro.run/applyset   Apply    -> metadata + the spec kro renders   (no policy)
controller         Update   -> {"f:spec": {"f:policy": {}}}       <- ACK claims policy
```

This is the "Supplies when absent → do not omit" case documented in `docs/frequent-rgd-errors.md`
§"Omission Is Wrong for Fields the Provider Late-Initialises". The tell: `ACK.LateInitialized=True`
condition, or a field appearing in `spec` with a value nobody configured.

---

## Fix

Added the AWS default access policy JSON to all six "NoPolicy" ACK Topic variants. The policy is
constructed at render time using `naming.data.resourceName`, `rsrcCfg[0].status.effectiveConfig.aws.region`,
and `rsrcCfg[0].status.effectiveConfig.aws.accountId` — the same values used to build `predictedArn`.

When these values are not yet resolved (resourceName still contains `{`), the expression returns `""`
and kro omits the field (matching prior behaviour). In practice this path is never taken: the
`includeWhen` guard ensures a topic variant is only active after naming is resolved.

The fix resolves the write fight because kro's desired state now matches what ACK would late-initialise:
the two managers converge immediately rather than requiring a ~2,600-write handover period.

---

## Verification

RGD reached Active in one iteration after applying the fix:

```
kubectl delete rgd snstopic.aws.kropath.run --ignore-not-found=true
kubectl apply --server-side -f rgds/snstopic.aws.kropath.run.yaml
# -> state=Active (iteration 1)
```

Note: `kubectl apply` (without `--server-side`) fails for this RGD because the file is ~265KB and
the `last-applied-configuration` annotation hits the 262,144-byte Kubernetes limit. Always use
`kubectl apply --server-side` for the SNS Topic RGD.

---

## Remaining Work

The same "supplies when absent" trap may affect S3 (`createBucketConfiguration.locationConstraint`,
`versioning.status`) and SQS, which were also touched by the omit-don't-empty work in KRO-905/915.
These should be audited in a follow-up.
