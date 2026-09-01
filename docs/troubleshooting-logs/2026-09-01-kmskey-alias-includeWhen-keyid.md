<!--
Point-in-time disclaimer: This log records the author's understanding at 2026-09-01.
Treat as a hypothesis unless confirmed by a higher-precedence source (agent instructions or
frequent-rgd-errors.md). If this log conflicts with either, those win.
-->

# 2026-09-01: kmskey Alias includeWhen requires keyID — chainsaw tests not updated

## Summary

KRO-925 added an `includeWhen` guard on the ACK Alias resource in `rgds/kmskey.yaml`. The guard
prevents Alias creation until the parent Key has a real `keyID` from AWS. The ac9 and ac10
Chainsaw scenarios were not updated to account for this, causing them to time out asserting on
an Alias that would never appear (no real ACK KMS controller in the test cluster).

## What Failed

Failing check: `kms/kmskey[kmskey]` — scenarios `ac9-alias-derived-from-naming` and
`ac10-alias-custom-name`.

Error: `ASSERT | FAILED | kms.services.k8s.aws/v1alpha1/Alias @ kmskey/alias-derived — actual
resource not found` after 5-minute timeout.

Reproducing command: `gh pr checks 196 -R kropath/kropath-aws` → RGD Tests → kmskey step.

## Root Cause

Commit `abb7408` (KRO-925) changed `rgds/kmskey.yaml` alias `includeWhen` from:
```
"${schema.spec.createAlias}"
```
to:
```
"${schema.spec.createAlias && key.?status.?keyID.orValue('') != ''}"
```

This was intentional: Alias creation requires the parent Key to exist in AWS first. In the test
cluster there is no real ACK KMS controller, so `key.status.keyID` is never populated, and kro
never creates the Alias.

The Chainsaw tests for ac9 and ac10 were not updated alongside the RGD change.

## Fix

Updated `tests/kms/kmskey/chainsaw-test.yaml` for both ac9 and ac10:

1. Assert on ACK Key creation (it always happens regardless of `createAlias`)
2. Patch the ACK Key's status with a fake `keyID` to satisfy the `includeWhen` guard:
   ```bash
   kubectl patch key <name> -n kmskey --subresource=status --type=merge \
     -p '{"status": {"keyID": "1234abcd-12ab-34cd-56ef-1234567890ab"}}'
   ```
3. Assert on ACK Alias creation (now possible because `keyID != ""`)
4. Assert on `KMSKey.status.aliasArn`

This is consistent with the existing pattern of using `kubectl patch --subresource=status` to
simulate ACK controller behaviour in the test cluster (used for KMSConfig `effectiveConfig`).

## Pattern to Reuse

When an RGD `includeWhen` condition depends on a child resource's ACK-populated status field
(e.g. `keyID`, `arn`, `roleID`), Chainsaw tests must pre-populate that status field via
`kubectl patch --subresource=status` before asserting on any resource whose `includeWhen`
depends on it.

This applies to any kropath-aws test scenario where a real AWS controller is absent.
