# 2026-09-01: KinesisStream Chainsaw Test — ac19 Re-run Stale streamMode

> **Point-in-time disclaimer:** This log records what was observed and concluded at the time of
> writing. It may be superseded by later discoveries. Verify claims mechanically before acting on
> them; do not elevate this log above `docs/frequent-rgd-errors.md` or agent instructions.

## Ticket

KRO-747 — [kropath-aws] RGD + Tests: Kinesis resources (PR #198)

## Symptom

On the third local `make test-kinesis` run, step `ac19-mode-switch-ondemand-to-provisioned`
failed with a 306-second timeout. The first assert (expecting ACK Stream
`streamModeDetails.streamMode: ON_DEMAND`) never matched.

## Root Cause

The Chainsaw suite runs with `skipDelete: true`, so all Kubernetes resources created during
a test run persist across subsequent runs. The `ac19` test exercises a mode switch:

1. Step 1 — apply KinesisStream `mode-switch-od` (no `streamMode` / `shardCount` → cascade
   defaults → `on_demand`)
2. Step 2 — apply the same KinesisStream with `streamMode: provisioned, shardCount: 4`

After a successful first run, `mode-switch-od` is left in PROVISIONED state (from step 2).
On re-run, step 1's apply manifest did not include `streamMode` or `shardCount`. Kubernetes
client-side strategic merge patch treats absent fields as "leave as-is", so `streamMode:
provisioned` and `shardCount: 4` were NOT cleared. kro therefore saw no change in the
KinesisStream spec, did not reconcile, and the ACK Stream stayed PROVISIONED. The ON_DEMAND
assert timed out after 5 minutes.

## Approaches Tried

### Approach 1 (successful): Explicit zero-value reset in step 1 apply

Add `streamMode: ""` and `shardCount: 0` to step 1's KinesisStream apply manifest.
Setting these to their schema defaults explicitly forces strategic merge patch to update the
fields (from `"provisioned"` / `4` to `""` / `0`). kro detects the spec change, re-evaluates
the cascade, finds `schema.spec.streamMode == ""` → falls through to defaults → `on_demand`,
and updates the ACK Stream to `ON_DEMAND`.

**Result:** Test is deterministic across multiple re-runs.
`chainsaw/kinesis/kinesisstream[kinesisstream] 8.33s PASS`

## Pattern Learned

**When a Chainsaw test exercises a state machine with `skipDelete: true`**: every step that
expects a specific state MUST explicitly set all fields that the previous step may have left
in a different state. Do NOT rely on "absent fields default to zero" — client-side apply
preserves existing values for absent fields.

For KinesisStream specifically:
- `streamMode: ""` — empty string is the schema default; setting it explicitly resets any
  previously applied mode value and allows the cascade to fall through to defaults.
- `shardCount: 0` — zero is the schema default; setting it explicitly resets any previously
  applied shard count.

This pattern applies to any re-runnable Chainsaw scenario that tests mode switches, capacity
changes, or other mutable spec fields on resources that persist across runs.

## Related

- `docs/frequent-rgd-errors.md` — §"Re-runnable Chainsaw Tests / skipDelete": add if not present
- KRO-747, PR kropath/kropath-aws#198
