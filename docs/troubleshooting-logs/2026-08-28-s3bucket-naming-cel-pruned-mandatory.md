# S3Bucket Naming CEL Throws on Pruned mandatory.namingTemplate

**Date:** 2026-08-28
**Ticket:** KRO-897
**Repo:** kropath-aws
**File:** `rgds/s3bucket.yaml`

> ⚠️ Point-in-time record. Reflects the state of the codebase on 2026-08-28. Verify claims
> against current sources before acting on them.

---

## Symptom

Two `S3Bucket` instances in the live integration cluster (`kind-kropath-aws-integration-test`)
stuck in `IN_PROGRESS, Ready=False`:

```
node "naming": failed to evaluate expression: ... no such key: namingTemplate (data pending)
```

All other resource types (SQSQueue, SNSTopic) reconciled correctly.

---

## Root Cause

`rgds/s3bucket.yaml` was the only RGD still using unsafe direct CEL map access for
`namingTemplate`. When the kropath-controller prunes empty values from
`status.effectiveConfig`, a tenant `S3Config` with `mandatory.namingTemplate: ""` results
in a `mandatory` map that contains only `tags` — the `namingTemplate` key is absent
entirely.

The broken expressions on lines 93 and 95 read:

```cel
rsrcCfg[0].status.effectiveConfig.mandatory.namingTemplate != ""
```

CEL throws `no such key: namingTemplate` when the key is absent. The `rsrcCfg.size() > 0`
guard only proves the list is non-empty; it says nothing about the key.

The same vulnerability existed in the `.transformList` block where `mandatory.tags`,
`mandatory.syncedLabels`, `mandatory.syncedAnnotations`, `defaults.tags`,
`defaults.syncedLabels`, and `defaults.syncedAnnotations` were accessed directly without
checking that the `mandatory`/`defaults` sub-map itself exists.

---

## Fix

Applied the same hardened guards already used in all 65 other RGDs
(e.g. `sqsqueue.aws.kropath.run.yaml`):

**namingTemplate access:**
```cel
# Before (throws when namingTemplate key is absent):
rsrcCfg.size() > 0 && rsrcCfg[0].status.effectiveConfig.mandatory.namingTemplate != ""

# After (safe optional access):
rsrcCfg.size() > 0 && has(rsrcCfg[0].status.effectiveConfig.mandatory) && rsrcCfg[0].status.effectiveConfig.mandatory.?namingTemplate.orValue("") != ""
```

**transformList tags/syncedLabels/syncedAnnotations access:**
```cel
# Before (throws when mandatory sub-map is absent):
rsrcCfg.size() > 0 && part.split("}")[0] in rsrcCfg[0].status.effectiveConfig.mandatory.tags

# After (checks has(mandatory) first):
rsrcCfg.size() > 0 && has(rsrcCfg[0].status.effectiveConfig.mandatory) && part.split("}")[0] in rsrcCfg[0].status.effectiveConfig.mandatory.tags
```

Same pattern applied for `defaults.tags`, `defaults.syncedLabels`,
`defaults.syncedAnnotations`.

---

## Why s3bucket.yaml Was Missed

The file uses the old naming convention (`s3bucket.yaml`) while all other hardened RGDs use
`<kind>.aws.kropath.run.yaml`. The bulk migration script that hardened the other 65 RGDs
keyed on the `.aws.kropath.run.yaml` suffix and silently skipped `s3bucket.yaml`.

---

## Regression Test

Added Chainsaw step `kro897-pruned-mandatory-naming-falls-to-defaults` to
`tests/s3/s3bucket/chainsaw-test.yaml`. The fixture patches `mandatory` with `tags` populated
but **without** `namingTemplate` (simulating the pruned state) and asserts that the bucket
correctly resolves via `defaults.namingTemplate`.

---

## Verification

- RGD reaches `Active` in one delete-apply-check round.
- `make test-s3` passes: `chainsaw/s3/s3bucket[s3bucket]` 78.91s PASS.
- New test step `kro897-pruned-mandatory-naming-falls-to-defaults` — PASS.
