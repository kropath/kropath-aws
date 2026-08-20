# EKS CI: Lambda Wave 1 Timeout After Adding EKS Family (7 RGDs)

**Date:** 2026-08-20
**Ticket:** KRO-532
**Symptom:** Second CI failure on PR #134 after the first CI failure (wrong `effectiveConfig` field
paths) was already fixed. The `Chainsaw E2E Tests` job failed during `make setup` — specifically
during the Lambda wave 1 `kubectl wait` step.

> ⚠️ **Point-in-time disclaimer:** This log records the author's understanding at the time of
> writing. Claims about kro internals (queue behavior, CONCURRENT_RECONCILES semantics) are
> inferred from CI timing evidence and should be verified before acting on them in a different
> context. Cross-reference `docs/frequent-rgd-errors.md` for any entry that conflicts with this
> log.

---

## Symptom

CI run 32358376518 — step "Setup test environment":

```
timed out waiting for the condition on
  resourcegraphdefinitions/lambdacodesigningconfig.aws.kropath.run
timed out waiting for the condition on
  resourcegraphdefinitions/lambdalayerversion.aws.kropath.run
make: *** [Makefile:30: setup] Error 1
```

Condition dump for both failing RGDs at timeout:

```
{"lastTransitionTime":"2026-08-20T10:21:20Z","reason":"GraphReady","status":"True","type":"GraphAccepted"}
{"lastTransitionTime":"2026-08-20T10:21:20Z","reason":"WaitingForGraphRevisionCompilation","status":"Unknown","type":"GraphRevisionsResolved"}
```

`GraphAccepted=True` (graph validated, no CEL/type errors) but `GraphRevisionsResolved=Unknown`
after 120 seconds.

---

## Root Cause

`tests/setup.sh` applies non-lambda RGDs in a batch, then immediately starts the Lambda wave 1
`kubectl wait` with a 120-second timeout. Before the EKS family was added (KRO-532), the
non-lambda batch was ~85 RGDs. After KRO-532, it became 92.

kro's graph-revision compiler processes RGDs sequentially through an internal work queue
(evidence: timestamp of `GraphRevisionsResolved` condition never updated after initial set,
suggesting kro had not yet started processing `lambdacodesigningconfig` and `lambdalayerversion`).
With 92 non-lambda RGDs ahead of them in the queue and `CONCURRENT_RECONCILES=2`, kro could
not process the Lambda wave 1 RGDs within the 120-second window.

The key diagnostic indicator: `GraphAccepted=True` means the graph YAML is valid (no CEL or
type errors). `GraphRevisionsResolved=Unknown` with a `WaitingForGraphRevisionCompilation`
reason and an **unchanged `lastTransitionTime`** means kro set this condition once on
initial apply and has not yet revisited the RGD to compile its graph revision.

This is distinct from an RGD-correctness failure (where `GraphAccepted` would show `False` with
an error message). It is a pure throughput/timing issue.

---

## What Was Tried

Only one approach was needed — the root cause was clear from the condition timestamps.

---

## Fix

Added a `kubectl wait rgd --all --for=condition=Ready --timeout=300s` barrier between the
non-lambda batch and Lambda wave 1 in `tests/setup.sh`:

```bash
# Wait for all non-lambda RGDs to become Ready before starting Lambda waves.
# Without this wait, Lambda wave 1's 120s clock starts while kro is still processing
# the non-lambda batch (90+ RGDs), and Lambda times out before kro drains the queue.
# This became a problem when the EKS family (7 RGDs) was added (KRO-532).
echo "==> Waiting for all non-lambda RGDs to become Ready (drains kro queue before Lambda waves)..."
if ! kubectl wait rgd --all --for=condition=Ready --timeout=300s; then
  # ... diagnosis block ...
  exit 1
fi
```

This ensures kro's processing queue is fully drained before the Lambda wave 1 clock starts.
Lambda wave 1 RGDs (having `GraphAccepted=True` from when they were first applied) then
complete `GraphRevisionsResolved` quickly once the queue has room.

---

## Prevention

When the total number of non-lambda RGDs grows (e.g. adding another resource family), the same
timeout issue can recur if the new non-lambda wait's 300-second budget is insufficient.

If setup starts timing out during the non-lambda wait:
1. Check `kubectl get rgd -o wide` for any `Inactive` RGDs — those are correctness failures.
2. If all RGDs are Active but the wait exceeded 300s, this is a cluster throughput issue — the
   non-lambda wait timeout may need to be increased, or CONCURRENT_RECONCILES may need tuning.

Do NOT interpret the Lambda wave timeout in isolation. Always check the non-lambda pre-lambda
wait first — the Lambda timeout is downstream of the queue drain.

**See also:** `2026-08-11-lambda-rgd-yaml-selector-ci-failures.md` for the original Lambda wave
ordering design (cross-graph CRD dependency races, separate from this queue-drain issue).
