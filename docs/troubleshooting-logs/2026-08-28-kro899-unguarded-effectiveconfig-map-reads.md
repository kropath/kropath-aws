> **Point-in-time disclaimer:** This log records observations and conclusions as of 2026-08-28.
> Claims here are hypotheses drawn from that investigation; they may not hold after kro upgrades,
> controller changes, or refactors. Cross-check against `docs/frequent-rgd-errors.md` before acting.

# 2026-08-28: KRO-899 — Unguarded effectiveConfig Map Reads (`no such key`)

## Symptom

CEL evaluation of an RGD resource template throws:

```
no such key: delaySeconds
```

when a `SQSQueue` uses a governance config where `mandatory.delaySeconds = 0`. The same class of
error affects any integer, boolean, or string field with a zero/false/"" value in either the
`mandatory` or `defaults` tier.

## Root Cause

The kropath-controller **prunes zero-value fields** from `status.effectiveConfig` when writing the
effective config back to the governance Config CR. A field set to `0`, `false`, or `""` in
`spec.mandatory` or `spec.defaults` is omitted entirely from the corresponding
`status.effectiveConfig.mandatory` / `status.effectiveConfig.defaults` map.

kro CEL evaluates templates left-to-right with no automatic optional-access semantics. The original
patterns like:

```yaml
delaySeconds: >-
  ${string(rsrcCfg.size() > 0 && rsrcCfg[0].status.effectiveConfig.mandatory.delaySeconds > 0
    ? ...
```

first evaluate `rsrcCfg[0].status.effectiveConfig.mandatory.delaySeconds` as a bare key access.
When the key is absent (pruned because its value is 0), CEL throws `no such key: delaySeconds`
before the `> 0` comparison can short-circuit anything.

The same issue applies at the **tier level**: if ALL fields in `mandatory` are zero-value, the
controller may omit the entire `mandatory` object from `status.effectiveConfig`. The bare access
`rsrcCfg[0].status.effectiveConfig.mandatory` then throws `no such key: mandatory`.

## Affected RGDs (KRO-899 audit)

All six RGDs were audited and fixed:

| RGD file | Fields fixed |
|---|---|
| `rgds/sqsqueue.aws.kropath.run.yaml` | `encryptionType`, `kmsMasterKeyId`, `visibilityTimeout`, `messageRetentionPeriod`, `delaySeconds`, `maximumMessageSize`, tags/syncedLabels/syncedAnnotations merge block |
| `rgds/dynamodbtable.aws.kropath.run.yaml` | `encryptionEnabled`, `deletionProtectionEnabled`, `pointInTimeRecoveryEnabled`, `kmsMasterKeyId` |
| `rgds/kmskey.yaml` | `keySpec`, `keyUsage`, `enableKeyRotation`, tags merge block |
| `rgds/rdscluster.aws.kropath.run.yaml` | `manageMasterUserPassword` (in `includeWhen`) |
| `rgds/rdsinstance.aws.kropath.run.yaml` | `manageMasterUserPassword` (in `includeWhen`) |
| `rgds/s3bucket.yaml` | `encryptionAlgorithm`, `kmsKeyArn`, `blockPublicACLs`, `blockPublicPolicy`, `ignorePublicACLs`, `restrictPublicBuckets`, `versioning`, `enforceHttpsOnly`, tags merge block |

## Fix Pattern

**Two-level safety is required:**

1. **Tier-level guard** — check that the tier object itself exists before accessing it:
   ```yaml
   has(rsrcCfg[0].status.effectiveConfig.mandatory)
   ```

2. **Field-level guard** — use `?.field.orValue(<zero>)` for the individual field:
   ```yaml
   rsrcCfg[0].status.effectiveConfig.mandatory.?delaySeconds.orValue(0)
   ```

The `orValue()` argument must match the field type:
- Integer: `orValue(0)`
- String: `orValue("")`
- Boolean: `orValue(false)`
- Map: `orValue({})`

### Integer field pattern (before → after)

**Before:**
```yaml
delaySeconds: >-
  ${string(rsrcCfg.size() > 0 && rsrcCfg[0].status.effectiveConfig.mandatory.delaySeconds > 0
    ? rsrcCfg[0].status.effectiveConfig.mandatory.delaySeconds
    : (schema.spec.delaySeconds > 0
        ? schema.spec.delaySeconds
        : rsrcCfg[0].status.effectiveConfig.defaults.delaySeconds))}
```

**After:**
```yaml
delaySeconds: >-
  ${string(rsrcCfg.size() > 0 && has(rsrcCfg[0].status.effectiveConfig.mandatory) && rsrcCfg[0].status.effectiveConfig.mandatory.?delaySeconds.orValue(0) > 0
    ? rsrcCfg[0].status.effectiveConfig.mandatory.?delaySeconds.orValue(0)
    : (schema.spec.delaySeconds > 0
        ? schema.spec.delaySeconds
        : (rsrcCfg.size() > 0 && has(rsrcCfg[0].status.effectiveConfig.defaults) && rsrcCfg[0].status.effectiveConfig.defaults.?delaySeconds.orValue(0) > 0
            ? rsrcCfg[0].status.effectiveConfig.defaults.?delaySeconds.orValue(0)
            : 0)))}
```

### Boolean field pattern (before → after)

**Before:**
```yaml
encryptionEnabled: >-
  ${rsrcCfg[0].status.effectiveConfig.mandatory.encryptionEnabled
    || schema.spec.?encryption.?enabled.orValue(false)
    || rsrcCfg[0].status.effectiveConfig.defaults.encryptionEnabled}
```

**After:**
```yaml
encryptionEnabled: >-
  ${(rsrcCfg.size() > 0 && has(rsrcCfg[0].status.effectiveConfig.mandatory) && rsrcCfg[0].status.effectiveConfig.mandatory.?encryptionEnabled.orValue(false))
    || schema.spec.?encryption.?enabled.orValue(false)
    || (rsrcCfg.size() > 0 && has(rsrcCfg[0].status.effectiveConfig.defaults) && rsrcCfg[0].status.effectiveConfig.defaults.?encryptionEnabled.orValue(false))}
```

### Tags merge block pattern (before → after)

**Before:**
```yaml
tags: >-
  ${rsrcCfg[0].status.effectiveConfig.defaults.tags
    .merge(...)
    .merge(rsrcCfg[0].status.effectiveConfig.mandatory.tags)
    ...}
```

**After:**
```yaml
tags: >-
  ${((rsrcCfg.size() > 0 && has(rsrcCfg[0].status.effectiveConfig.defaults)) ? rsrcCfg[0].status.effectiveConfig.defaults.?tags.orValue({}) : {})
    .merge(...)
    .merge((rsrcCfg.size() > 0 && has(rsrcCfg[0].status.effectiveConfig.mandatory)) ? rsrcCfg[0].status.effectiveConfig.mandatory.?tags.orValue({}) : {})
    ...}
```

## CRD Mutual-Exclusion Interaction

When writing Chainsaw test fixtures for the pruned-mandatory scenario, a constraint becomes
relevant: governance CRDs have `x-kubernetes-validations` rules preventing the same field from
being set non-zero in BOTH `mandatory` and `defaults` simultaneously. For example, if
`mandatory.visibilityTimeout = 120` and `defaults.visibilityTimeout = 30`, the CRD rejects the
config with:

```
visibilityTimeout cannot be set in both mandatory and defaults
```

**Workaround in test fixtures:** Set `defaults.<field>` to `0` in the `spec` (so CRD validation
passes), then inject the desired values into `status.effectiveConfig.defaults` via
`kubectl patch --subresource=status`, which bypasses spec validation. This way the test simulates
the controller having written real non-zero defaults into effectiveConfig while keeping a single
non-zero mandatory value.

## Verification

All affected RGDs were verified to reach `Active` state using the delete-apply-loop:

```bash
kubectl delete rgd <name>.aws.kropath.run --ignore-not-found=true --timeout=60s
kubectl apply -f rgds/<name>.yaml
# Check .status.state = Active
```

All 6 RGDs reached Active on the first round after the fix.

## Test Results

- **SQS tests:** all 32+ scenarios pass, including the new `kro899-zero-value-pruned-mandatory-fields` scenario
- **RDS tests:** all pass
- **S3 tests:** all pass  
- **KMS kmskey tests:** all pass
- **DynamoDB tests:** `ac34-tags-merge-cascade` and related failures are **pre-existing** (confirmed by running on baseline without KRO-899 changes — same failures observed)
- **KMS kmsconfig tests:** `ac9-invalid-keyspec-not-in-allowed-list` is **pre-existing** (unrelated to kmskey.yaml changes)
