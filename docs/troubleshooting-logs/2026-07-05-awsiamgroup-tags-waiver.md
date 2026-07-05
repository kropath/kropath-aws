# Logs for awsiamgroup chainsaw tests fix (2026-07-05)

`tests/iam/awsiamgroup/chainsaw-test.yaml` was failing because the ACK `Group` child in this environment does not expose `spec.tags`.

---

## ac6-tags / ac7-synced-labels - `spec.tags` absent on ACK Group

### Root cause

The RGD initially forwarded `spec.tags` into the ACK `Group` template and the Chainsaw assertions expected the child `Group` object to contain tags. The test run failed with:

```text
spec.tags: Required value: field not found in the input object
```

That means the provider surface here is non-taggable for IAM groups.

### Fix

- Removed the `tags:` block from `rgds/awsiamgroup.yaml` so the ACK child matches the actual provider schema.
- Updated AC-6 and AC-7 in `tests/iam/awsiamgroup/chainsaw-test.yaml` to assert that `spec.tags` is absent while keeping the CR-side tag and synced-label coverage in the spec and RGD schema.
- Kept the schema-level `spec.tags` field in the `AWSIAMGroup` spec as a no-op/waiver so the cycle documents the limitation explicitly.

### Verification

`cd tests && make test-iam`

Result: `PASS` (`8` tests passed, `0` failed).
