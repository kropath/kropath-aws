# KRO-1093: S3Bucket Silently Created With Illegal Name When aws Fields Absent

**Date:** 2026-09-17
**Issue:** KRO-1093
**Scope:** `rgds/s3bucket.aws.kropath.run.yaml` and 146 other RGDs sharing the same `replace()` pattern

> **Point-in-time disclaimer.** This log records what the author observed at the time of writing.
> CEL/kro behaviour may change across versions. Verify mechanically before acting on claims here.

## Problem

When `status.effectiveConfig.aws` in the referenced S3Config is absent or lacks `accountId` /
`region`, the S3Bucket RGD substituted an empty string `""` into the bucket name:

```
# Config absent — effectiveName becomes:
"s3bucket-kro1093-my-bucket-"   # missing account_id
"central-logging-"               # missing region in nameOverride
```

The `namingStatus` field reported `valid` because its validity check is:

```cel
naming.data.effectiveName.contains("{") ? "invalid-unresolved-tokens" : "valid"
```

After `.replace("{account_id}", "")` the token `{account_id}` is gone, so the check passes and
`namingStatus` reports `valid`. The RGD's `includeWhen` guards on ACK Bucket variants did not
block creation, so kro created an ACK `Bucket` with an illegal S3 name ending in `-`.

## Root cause

All `.replace()` calls used `.orValue("")` as the fallback when the optional field was absent:

```yaml
.replace("{account_id}", rsrcCfg.size() > 0
    ? rsrcCfg[0].status.effectiveConfig.aws.?accountId.orValue("")
    : "")
.replace("{region}", rsrcCfg.size() > 0
    ? rsrcCfg[0].status.effectiveConfig.aws.?region.orValue("")
    : "")
```

CEL's `.orValue("")` fires when the field is **absent** (the `?` optional access returned
`optional.none()`). The empty-string substitution removes the braces, making `namingStatus`
believe the name is valid.

The same pattern was present in 146 other RGD files generated from the same template.

## Fix

### 1. Preserve tokens verbatim when the field is absent

Change `.orValue("")` to `.orValue("{account_id}")` (and similarly for `{region}`):

```yaml
# Before
.replace("{account_id}", rsrcCfg.size() > 0
    ? rsrcCfg[0].status.effectiveConfig.aws.?accountId.orValue("")
    : "")

# After
.replace("{account_id}", rsrcCfg.size() > 0
    ? rsrcCfg[0].status.effectiveConfig.aws.?accountId.orValue("{account_id}")
    : "{account_id}")
```

When the field is absent, the token `{account_id}` remains in the name string. The existing
`namingStatus` check for `{` then correctly reports `invalid-unresolved-tokens`.

Applied globally to all 146 affected RGD files via Python script.

### 2. Guard all 12 ACK Bucket `includeWhen` blocks (S3Bucket-specific)

Added `&& !naming.data.effectiveName.contains("{")` to every `includeWhen` CEL expression on all
12 S3Bucket ACK Bucket variants (covering the HTTPS / logging / objectLock combinations):

```yaml
# Before (example variant — no-logging, no-objectlock, no-https):
includeWhen: "${... && naming.data.effectiveObjectLockMode == ""}"

# After:
includeWhen: "${... && naming.data.effectiveObjectLockMode == ""
              && !naming.data.effectiveName.contains("{")}"
```

This prevents any ACK Bucket from being created while there are still unresolved tokens, even if
some future code path were to set `namingStatus` to `valid` prematurely.

## Verification

1. **RGD compiles gate:** `kubectl delete rgd s3bucket.aws.kropath.run --ignore-not-found && kubectl apply -f rgds/s3bucket.aws.kropath.run.yaml` — reached `Active` on first iteration.

2. **Chainsaw negative path (AC-1 / AC-2):** S3Bucket with unresolved `{region}` or `{account_id}`
   in the effective name gets `namingStatus: invalid-unresolved-tokens` and no ACK Bucket is created.

3. **Chainsaw recovery path (AC-3):** Instance applied before config aws fields are populated →
   stays `invalid-unresolved-tokens`; once config reconciles, flips to `valid` and ACK Bucket appears.

4. **Chainsaw happy path (AC-4):** Fully resolved tokens → `namingStatus: valid`, ACK Bucket created.

## Key insight

`.orValue(fallback)` in CEL activates only when the optional returns `none()` (field absent).
If `effectiveConfig.aws` is present but `accountId` is an empty string `""`, `.orValue` does NOT
fire — the empty string is returned as-is. The fix preserves the token in the *absent* case only.
If aws fields are present but empty, the resulting name will contain a literal empty string where
the token was, which is still an invalid name — but that failure mode (present-but-empty field)
is out of scope for KRO-1093 and covered by a separate validation path.
