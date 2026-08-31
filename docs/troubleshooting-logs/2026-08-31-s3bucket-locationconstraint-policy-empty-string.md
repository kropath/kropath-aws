> **Point-in-time disclaimer**: This log records observations and conclusions made on 2026-08-31.
> Claims about runtime or AWS API behaviour are based on integration cluster evidence at that date.
> Verify mechanically before acting on them in a new context.

# 2026-08-31 — S3Bucket RGD: locationConstraint and policy empty-string fallbacks (KRO-924)

## Symptom

Two integration cluster buckets (`events` in `data-test`, `receipts` in `payments-test`) showed
extreme generation counts (14157 and 11775 respectively) with `ACK.LateInitialized: True` and
`locationConstraint: ""` in the ACK Bucket spec — despite the bucket names encoding
`ap-southeast-2`, proving the buckets lived in that region.

## Root cause

### locationConstraint — KRO-920 drift

`rgds/s3bucket.aws.kropath.run.yaml` resolved `locationConstraint` via:

```yaml
locationConstraint: >-
  ${schema.spec.region != "" && schema.spec.region != "us-east-1"
    ? schema.spec.region
    : ""}
```

When `schema.spec.region == ""` (user did not specify a region — the common case when relying on
`S3Config.effectiveConfig.aws.region` to determine the bucket region), the else branch emitted `""`.

ACK reconciliation:
1. kro renders `locationConstraint: ""`
2. ACK calls `GetBucketLocation` → gets `"ap-southeast-2"` (actual bucket region)
3. ACK late-initializes: writes `locationConstraint: "ap-southeast-2"` to the Bucket spec
4. kro re-renders: desired `""` ≠ actual `"ap-southeast-2"` → kro re-applies with `""`
5. Generation bumps → repeat indefinitely

This is the canonical KRO-920 trap (supply-when-absent).

### policy — omit-when-empty

`policy` resolved to `""` when `enforceHttpsOnly=false`. Unlike SNS (where AWS rejects
`policy: ""`), S3's ACK controller handles empty policy gracefully (`ACK.ResourceSynced: True`
confirmed on affected buckets). However, empty string is not omission — sending `policy: ""`
is semantically different from omitting the field and could interact with future ACK behaviour
changes. The SNS precedent (`includeWhen` split, KRO-905) applies here too.

## Fix applied

### locationConstraint

Changed the else branch to fall back to the effective region from S3Config when `spec.region`
is not set and the effective region is not `us-east-1`:

```yaml
locationConstraint: >-
  ${schema.spec.region != "" && schema.spec.region != "us-east-1"
    ? schema.spec.region
    : (rsrcCfg.size() > 0 && rsrcCfg[0].status.effectiveConfig.aws.?region.orValue("") != "" && rsrcCfg[0].status.effectiveConfig.aws.?region.orValue("") != "us-east-1"
        ? rsrcCfg[0].status.effectiveConfig.aws.?region.orValue("")
        : "")}
```

`us-east-1` guard on the fallback: S3 `CreateBucketConfiguration` must not include
`locationConstraint` for us-east-1 buckets (AWS returns `InvalidLocationConstraint` if set).
The fallback returns `""` (which kro omits) for us-east-1, consistent with the existing
`spec.region: us-east-1` path.

### policy — includeWhen split

Replaced the single `bucket` resource with two variants:

- `bucketWithPolicy` — `includeWhen: [enforceHttpsOnly true in any tier]`, includes `policy` field
- `bucket` — `includeWhen: [enforceHttpsOnly false/unset in all tiers]`, no `policy` field

The status block references only `naming.data.effectiveName` — no `bucket.status.*` fields — so
the split introduces no CEL type incompatibility issues.

## Verification

- RGD reached `Active` in one round after delete+apply.
- `cd tests && make test-s3` — all 25 s3bucket scenarios passed, including new
  `ac924-1-region-from-s3config` which confirms `locationConstraint` is populated from
  `S3Config.effectiveConfig.aws.region` when `spec.region` is not set.

## Key principles

- **KRO-920 trap**: when ACK late-initializes a field with a non-empty value, the RGD must render
  the same non-empty value — otherwise perpetual reconciliation. Use the effective config value
  as fallback instead of `""`.
- **`includeWhen` must be a YAML list**: `includeWhen: [...]`, not `includeWhen: >- ${...}`.
  The latter causes `spec.resources[N].includeWhen must be of type array: "string"` on apply.
