# DynamoDBTable: AC22-AC39 Stale-State Reuse, YAML Boolean Coercion, kro Rate-Limiter Backoff, and Chainsaw Missing-Resource Assert

**Date:** 2026-08-03
**Issue:** KRO-245 (continuation)
**File:** `tests/dynamodb/dynamodbtable/chainsaw-test.yaml`

## Symptom 1: AC22 `spec: {}` — composite-key-schema step

`ac22-composite-key-schema` asserted `spec.(length(keySchema)): 2` but the actual `Table` resource had `spec: {}` (completely empty), not merely the wrong length.

### Root Cause

Chainsaw's `cleanup:` blocks are deferred to the **end of the entire test file** (run in reverse step order), not immediately after each step — a previously-documented quirk (see §"Chainsaw Seed Steps Must Delete-Then-Create Config CRs" in `frequent-rgd-errors.md`, which fixed this for config CRs but not yet for the `Table`/`DynamoDBTable` resource CRs themselves). AC21 left a `test-table` `DynamoDBTable` CR in place with a single-attribute `keySchema`. AC22's `apply` used `kubectl apply` (a strategic/JSON merge patch under the hood for existing objects), which does not clear fields absent from the new manifest. The mismatched shape between AC21's stale object and AC22's new `keySchema` caused kro's CEL to bail out and the child `Table`'s `spec` block never populated at all.

### Fix

Add an explicit pre-cleanup `script:` step at the start of AC22's `try:` block, before `apply: file: 01-general-policy.yaml`, deleting the previous step's `Table`/`DynamoDBTable` CRs (finalizers stripped first, matching the established pattern from AC19/AC21):

```yaml
try:
  - script:
      content: |
        for name in $(kubectl get table -n dynamodbtable -o jsonpath='{.items[*].metadata.name}' 2>/dev/null); do
          kubectl patch table "$name" -n dynamodbtable --type=merge -p '{"metadata":{"finalizers":[]}}' 2>/dev/null || true
        done
        kubectl delete table --all -n dynamodbtable --ignore-not-found=true
        for name in $(kubectl get dynamodbtable -n dynamodbtable -o jsonpath='{.items[*].metadata.name}' 2>/dev/null); do
          kubectl patch dynamodbtable "$name" -n dynamodbtable --type=merge -p '{"metadata":{"finalizers":[]}}' 2>/dev/null || true
        done
        kubectl delete dynamodbtable --all -n dynamodbtable --ignore-not-found=true
  - apply:
      file: 01-general-policy.yaml
```

Once AC22 was fixed, AC23 immediately hit the identical bug (proving this is systemic, not one-off) — the same pre-cleanup block was inserted into **all 17 remaining steps** (AC23 through AC39) that reuse the `test-table` resource name.

## Symptom 2: AC24/AC25 — `must be of type string: "boolean"`

`ac24-lsi-create` and `ac25-lsi-passthrough` failed CRD validation on `attributeType: N`.

### Root Cause

YAML 1.1's "Norway problem": bare scalars `y`/`Y`/`yes`/`n`/`N`/`no`/`on`/`off`/`true`/`false` (and case variants) are parsed as booleans unless quoted. `attributeType: N` (DynamoDB's "Number" type code) was silently coerced to the boolean `false` by the YAML parser before it ever reached the Kubernetes API, which then rejected it against the CRD's `type: string` schema.

### Fix

Quote the value: `attributeType: "N"` (2 occurrences, AC24 and AC25).

**Rule:** Any DynamoDB `attributeType` (`S`/`N`/`B`), or any other single-letter/word field value that collides with a YAML 1.1 boolean literal, must always be quoted in test fixtures and RGD examples.

## Symptom 3: kro rate-limiter backoff compounding across the suite

User-reported: "not sure if this is a real problem for 'actual resource not found', besides, the delete takes a long time" — flagging that AC28 intermittently saw `actual resource not found` on `Table test-table`, and that cleanup deletes across the suite were visibly slow, worsening on repeated runs (154s vs. an expected ~30-40s).

### Root Cause

kro's dynamic-controller workqueue uses a per-object-key (`namespace/name`) exponential-backoff rate limiter, defaulting to `min-delay=200ms` / `max-delay=1000s` — tuned for production AWS reconciliation, where backing off for minutes avoids hammering a degraded cloud API. Measured retry gaps in the kro controller log (1s → 2s → 3s → 6s → 13s → 26s → 51s) matched `200ms × 2ⁿ` almost exactly, confirming the same object key (`dynamodbtable/test-table`) was accumulating backoff across the whole 39-step run, since every step reuses that name. `KRO_DYNAMIC_CONTROLLER_CONCURRENT_RECONCILES` also defaults to `1` (fully serialized), and the client-side QPS/burst limiter (`KRO_CLIENT_QPS`/`KRO_CLIENT_BURST`, 100/150) added its own throttling on top.

### Fix

Tune kro's dynamic-controller rate limiter for fast local/CI test churn, applied in `tests/setup.sh` immediately after the kro rollout wait (so every CI run and every `make setup` picks it up):

```bash
kubectl set env deployment/kro -n kro-system \
  KRO_DYNAMIC_CONTROLLER_RATE_LIMITER_MIN_DELAY=50ms \
  KRO_DYNAMIC_CONTROLLER_RATE_LIMITER_MAX_DELAY=5s \
  KRO_DYNAMIC_CONTROLLER_RATE_LIMITER_RATE_LIMIT=50 \
  KRO_DYNAMIC_CONTROLLER_RATE_LIMITER_BURST_LIMIT=200 \
  KRO_DYNAMIC_CONTROLLER_CONCURRENT_RECONCILES=5
kubectl rollout status deployment/kro -n kro-system --timeout=120s
```

Applied live to the running cluster first to verify (`kubectl set env deployment/kro -n kro-system ...` + rollout status), then baked into `tests/setup.sh` for permanence. This is a test/CI-environment-only tuning; it should never be applied to a production kro deployment reconciling real AWS resources, where the conservative production defaults are correct.

## Symptom 4: AC28 `actual resource not found` persisted after the rate-limiter fix

Even after tuning the rate limiter, AC28 (`ac28-resource-policy-ref`) still intermittently failed its final assert with "actual resource not found."

### Root Cause

Chainsaw's `assert` retries a **value mismatch** against the configured `assert: 5m` timeout in `.chainsaw.yaml`, but does **not** retry when the target object is completely missing — confirmed by comparing RUN/ERROR timestamps in the chainsaw log: a value-mismatch failure shows RUN and ERROR ~30s+ apart (many retries), while a missing-resource failure shows RUN and ERROR in the same second (zero retries). AC28's `resourcePolicyRef` field adds an *extra* externalRef hop (a `PolicyDocument` lookup) that must resolve before kro's `includeWhen` gate on the child `Table` even creates the object — making this step structurally more likely to be checked by chainsaw before the object exists at all, versus a simple value being wrong on an object that already exists.

### Fix

Replace the plain `assert:` on `spec.resourcePolicy` with a bounded poll script (30s timeout, 15 iterations × 2s sleep) that waits for the `Table` to exist and have a non-empty `resourcePolicy` before treating the step as passed:

```yaml
- script:
    timeout: 30s
    content: |
      for i in $(seq 1 15); do
        RESOURCE_POLICY=$(kubectl get table test-table -n dynamodbtable -o jsonpath='{.spec.resourcePolicy}' 2>/dev/null)
        if [ -n "$RESOURCE_POLICY" ]; then
          echo "PASS: resourcePolicy is set (length ${#RESOURCE_POLICY})"
          exit 0
        fi
        echo "Attempt $i: Table not found or resourcePolicy not yet set, waiting..."
        sleep 2
      done
      echo "FAIL: resourcePolicy still not set after 30 seconds"
      kubectl get table test-table -n dynamodbtable -o yaml
      exit 1
```

**Rule:** Any chainsaw assert against a resource created via a multi-hop `externalRef`/`includeWhen` dependency chain (i.e., the child object's very existence, not just a field value, depends on another resource resolving first) should use a poll-based `script:` step instead of a plain declarative `assert:`, since chainsaw will not retry a "resource not found" the way it retries a value mismatch.

## Follow-up: First CI Run After This Fix (same day)

Pushing the above fixes to CI surfaced two failures that hadn't reproduced locally:

1. **`dynamodbtable` — `ac34-tags-merge-cascade` script exited 4 (`Table "test-table" not found`), then its cleanup phase later timed out.** This step's jq tag-merge check ran immediately after `apply`, with zero retry — the identical race already fixed for AC28 (Symptom 4 above), just not yet applied here since AC34 predates that fix. **Fix:** wrapped the jq check in the same 30s/15-iteration poll pattern used for AC28. Separately, `ac39-deletion-policy-retain` (the file's actual last step) had no `finally:` block — unlike `snstopic`, which already got one in the 2026-08-02 investigation — so its own cleanup phase was exposed to the documented "Chainsaw Cleanup Timeout — kro Cascade Deletion Queue Backup" issue. **Fix:** added the same `finally:` pre-cleanup block used in `snstopic`'s last step, and completed AC39's `cleanup:` script to also strip `--wait=false` and delete the `dynamodbconfig`, matching every other step's cleanup pattern.
2. **`snstopic` — `ac34-deletion-policy-retain`'s cleanup phase hit `context deadline exceeded`, even though this step already has the established `finally:` fix from 2026-08-02.** This suite passed on the immediately-prior commit (before the kro rate-limiter tuning) and only started failing after `KRO_DYNAMIC_CONTROLLER_CONCURRENT_RECONCILES` was raised from 1 to 5. `tests/Makefile` already runs 4 chainsaw suites concurrently against the same kro pod (`--parallel 4`), and GitHub Actions runners have far fewer CPU cores than the local dev machine this was tuned on — raising kro's own reconcile concurrency on top of that added contention rather than relieving it, apparently pushing this suite's cleanup phase past the 2-minute timeout that it was otherwise passing within. **Fix:** dialed `KRO_DYNAMIC_CONTROLLER_CONCURRENT_RECONCILES` back down to `2` (still an improvement over the default of `1`, without the CI-runner contention cost of `5`), and padded `.chainsaw.yaml`'s `cleanup`/`delete` timeouts from `2m` to `3m` as a margin against any remaining borderline cases.

**Lesson:** a rate-limiter/concurrency tuning change validated only on a local machine is not validated for CI — CI runners have a different (usually much smaller) resource budget, and chainsaw's own `--parallel` setting means the tuned component is never the only consumer of that budget. Re-check any such tuning against an actual CI run before treating it as settled.

## Residual — Unresolved

Across 9 full-suite reruns while validating the above fixes, 3 hit `signal: killed` on a plain `kubectl delete` shell step (an external process kill, not a chainsaw/kro/CEL error) — once in AC19, twice in AC28's pre-cleanup script. This did not reproduce under isolated manual testing, and only appeared after 9 consecutive full 39-step suite runs on a machine simultaneously running 5 concurrent kind clusters plus several other project containers. Consistent with local resource exhaustion rather than a code defect, but not conclusively proven — recommend confirming via CI or a quieter local run before considering it fully closed.

## Files Changed

- `tests/dynamodb/dynamodbtable/chainsaw-test.yaml` — pre-cleanup script added to AC22-AC39 (18 steps total); `attributeType: "N"` quoting in AC24/AC25; AC28's assert replaced with poll script.
- `tests/setup.sh` — kro dynamic-controller rate limiter tuning added after the kro rollout wait.
