> **Point-in-time note:** This log reflects the state of the codebase and cluster on 2026-08-29.
> Claims about ACK/AWS API behavior are based on the ACK S3 CRD schema and prod evidence at that
> date. Verify mechanically before relying on these notes in a future session.

# 2026-08-29 — S3 RGD: empty kmsMasterKeyID with aws:kms causes ACK hot-loop + tags never applied (KRO-913)

## Symptom

S3 buckets are created in AWS but:
1. Carry no tags — `PutBucketTagging` is never reached.
2. The `S3Bucket` instances never stabilise — ArgoCD reports continuous `ResourcesReady=False`.

ACK `Bucket` condition:

```
ACK.Recoverable=True :: api error InvalidArgument: if the default sse algorithm is
  aws:kms or aws:kms:dsse and a KMSMasterKeyID is specified, it must be non-empty
ACK.ResourceSynced=Unknown
```

ACK s3 controller log:

```
Error syncing property 'Encryption': operation error S3: PutBucketEncryption,
StatusCode: 400, api error InvalidArgument: if the default sse algorithm is
aws:kms or aws:kms:dsse and a KMSMasterKeyID is specified, it must be non-empty
```

## Root cause

`rgds/s3bucket.aws.kropath.run.yaml` (formerly `s3bucket.yaml`) resolved `kmsMasterKeyID` with a
final fallback of `""`. The platform baseline sets
`defaults.encryptionAlgorithm: aws:kms` with no KMS key anywhere:

```
status.effectiveConfig:
  mandatory: { encryptionAlgorithm: "", kmsKeyArn: "" }
  defaults:  { encryptionAlgorithm: "aws:kms", kmsKeyArn: "" }
```

So the RGD emitted:

```yaml
encryption:
  rules:
    - applyServerSideEncryptionByDefault:
        sseAlgorithm: aws:kms
        kmsMasterKeyID: ""      # rejected by AWS
```

ACK sent this to `PutBucketEncryption`. AWS rejected it with the `InvalidArgument` above.

**Why tags never apply:** ACK applies encryption *before* tagging. The encryption failure aborts the
reconcile, so `PutBucketTagging` is never called. The tag set in the spec is correct — it is simply
never sent.

**Why ArgoCD hot-loops:** This error is `ACK.Recoverable` (not terminal). ACK requeues
continuously without effective backoff, producing ~25 Kubernetes object writes/second. ArgoCD diffs
a live object that never stops changing and reports `ResourcesReady=False ::
resource reconciliation failed: cluster mutated`.

## Fix applied

Changed the final fallback in `kmsMasterKeyID` from `""` to `"alias/aws/s3"` (the AWS-managed
S3 KMS key alias), also adding a non-empty guard on the `defaults.kmsKeyArn` check so the
fallback is only used when all tiers resolve to empty.

**Before** (line 173–178):
```yaml
kmsMasterKeyID: >-
  ${rsrcCfg.size() > 0 && has(rsrcCfg[0].status.effectiveConfig.mandatory) && rsrcCfg[0].status.effectiveConfig.mandatory.?kmsKeyArn.orValue("") != ""
    ? rsrcCfg[0].status.effectiveConfig.mandatory.?kmsKeyArn.orValue("")
    : (schema.spec.encryption.kmsKeyArn != ""
        ? schema.spec.encryption.kmsKeyArn
        : (rsrcCfg.size() > 0 && has(rsrcCfg[0].status.effectiveConfig.defaults)) ? rsrcCfg[0].status.effectiveConfig.defaults.?kmsKeyArn.orValue("") : "")}
```

**After**:
```yaml
kmsMasterKeyID: >-
  ${rsrcCfg.size() > 0 && has(rsrcCfg[0].status.effectiveConfig.mandatory) && rsrcCfg[0].status.effectiveConfig.mandatory.?kmsKeyArn.orValue("") != ""
    ? rsrcCfg[0].status.effectiveConfig.mandatory.?kmsKeyArn.orValue("")
    : (schema.spec.encryption.kmsKeyArn != ""
        ? schema.spec.encryption.kmsKeyArn
        : (rsrcCfg.size() > 0 && has(rsrcCfg[0].status.effectiveConfig.defaults) && rsrcCfg[0].status.effectiveConfig.defaults.?kmsKeyArn.orValue("") != ""
            ? rsrcCfg[0].status.effectiveConfig.defaults.?kmsKeyArn.orValue("")
            : "alias/aws/s3"))}
```

## Bonus: file renamed to follow naming convention

`rgds/s3bucket.yaml` was renamed to `rgds/s3bucket.aws.kropath.run.yaml` to match the
`<kind>.aws.kropath.run.yaml` convention used by every other RGD in this repo. The old name
caused hardening scripts (keyed on `.aws.kropath.run.yaml`) to silently skip this file — root cause
of several past CEL guard omissions on this RGD (KRO-828, KRO-899).

One reference updated: `tests/s3/s3config/chainsaw-test.yaml:224`.

## Verification

- `kubectl delete rgd s3bucket.aws.kropath.run && kubectl apply -f rgds/s3bucket.aws.kropath.run.yaml` → RGD reached `Active` in one pass.
- `cd tests && make test-s3` → 2 passed, 0 failed (including new AC-1 assertion on `kmsMasterKeyID: alias/aws/s3`).

## Test coverage added

Added `kmsMasterKeyID: alias/aws/s3` assertion to `ac1-encryption-defaults` in
`tests/s3/s3bucket/chainsaw-test.yaml`. This step previously tested only `sseAlgorithm` and left
the key fallback unasserted, so the bug would have passed through future test runs undetected.
