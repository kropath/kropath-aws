# AppScaling IAMRole Stub Apply Timeout Under Parallel-Test Load

**Date:** 2026-09-03
**Ticket:** KRO-773
**PR:** kropath-aws#212
**CI failure:** 3rd

> **Point-in-time disclaimer:** This log records observations made at the time of writing.
> Claims have not been independently verified by a second engineer. Treat as a working
> hypothesis to be validated by a passing CI run, not established fact.

---

## Symptom

`ac6-role-ref-resolution` step in `tests/appscaling/appscalingtarget/chainsaw-test.yaml`
failed with:

```
APPLY | ERROR | aws.kropath.run/v1alpha1/IAMRole @ appscalingtarget/appscaling-role-stub
client rate limiter Wait returned an error: rate: Wait(n=1) would exceed context deadline
```

Timestamp in CI log: `23:21:07.328`, exactly 60 seconds after the appscalingtarget test
CONT'd from a PAUSE (`23:20:05.2 CONT | 23:20:06-07 ac1-ac5 begin`).

## Root Cause

1. `appscalingtarget` was PAUSED for ~4 minutes 55 seconds while three other parallel
   Chainsaw suites consumed all available Kubernetes API rate-limiter tokens.
2. At `23:20:05` Chainsaw CONT'd the paused suite and began executing steps ac1-ac5
   immediately (all lightweight — only kro-instance CRs using existing ACK stubs).
3. Around `23:20:07`, `ac6-role-ref-resolution` started and issued
   `APPLY aws.kropath.run/v1alpha1/IAMRole` — a **new** CR creation that triggers kro
   graph reconciliation and multiple downstream API calls.
4. Under peak parallel load, these kro-originated API calls competed with all other
   running test suites, exhausting the client-go rate-limiter token bucket.
5. At `23:21:07` (exactly 60 s = the `applyTimeout` in `.chainsaw.yaml`), the apply
   context deadline expired. client-go's rate-limiter reported "would exceed context
   deadline" because it could not admit the next token before the deadline.

The IAMRole creation itself was not broken; it simply could not complete within the
60-second `applyTimeout` under peak cluster load when placed mid-suite.

## Fix

Moved `apply: 08-iam-role-stub.yaml` and the `kubectl patch iamrole ... --subresource status`
script from the `ac6-role-ref-resolution` step to the **`setup` step**, which runs before
any parallel suite contention begins.

`ac6-role-ref-resolution` now only applies `09-role-ref-resolution.yaml` (the AppScalingTarget
instance) and asserts — both are cheap operations on a resource that was already created and
patched during setup.

## Files Changed

- `tests/appscaling/appscalingtarget/chainsaw-test.yaml`:
  - `setup` step: added `apply: 08-iam-role-stub.yaml` and `kubectl patch iamrole` script
  - `ac6-role-ref-resolution` step: removed the two pre-create operations

## Pattern to Apply Elsewhere

When a Chainsaw suite test step needs to CREATE a cross-referenced CR (e.g. an IAMRole stub
for a `roleRef` lookup), and that creation triggers kro reconciliation of a new graph, prefer
creating it in the `setup` step rather than mid-suite. The `setup` step runs sequentially
before parallel suite scheduling begins, avoiding rate-limiter starvation from concurrent suites.
