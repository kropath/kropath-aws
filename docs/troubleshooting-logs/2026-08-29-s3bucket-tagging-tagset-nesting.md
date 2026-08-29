> **Point-in-time note:** This log reflects the state of the codebase and cluster on 2026-08-29.
> Claims about API behavior are based on the ACK CRD schema at that date. Verify mechanically
> before relying on these notes in a future session.

# 2026-08-29 — s3bucket RGD: tagging must be nested under tagSet (KRO-904)

## Symptom

`payments-test/receipts` (S3Bucket) stuck in `ERROR`. No ACK `Bucket` child created:

```
failed to create typed patch object (payments-test/receipts; s3.services.k8s.aws/v1alpha1, Kind=Bucket):
.spec.tagging: expected map, got &{[map[key:provisioner value:argocd] ...]}
```

## Root cause

The RGD wrote the `transformList` output directly to `spec.tagging`:

```yaml
tagging: >-
  ${( ...merge chain... ).transformList(k, v, {"key": k, "value": v})}
```

But the ACK `buckets.s3.services.k8s.aws` CRD defines `spec.tagging` as an object:

```json
"tagging": {
  "type": "object",
  "properties": {
    "tagSet": { "type": "array", "items": { ... } }
  }
}
```

The list was attached one level too high.

## Fix

Wrap the CEL expression under `tagging.tagSet`:

```yaml
tagging:
  tagSet: >-
    ${( ...merge chain... ).transformList(k, v, {"key": k, "value": v})}
```

Also updated two jq-based tag checks in `tests/s3/s3bucket/chainsaw-test.yaml` from
`.spec.tagging` to `.spec.tagging.tagSet` (the old checks treated `.spec.tagging` as a bare
array; it is now an object with one key).

## Verification

- `kubectl delete rgd s3bucket.aws.kropath.run && kubectl apply -f rgds/s3bucket.yaml` → RGD reached `Active` in one pass.
- `cd tests && make test-s3` → 2 passed, 0 failed.
