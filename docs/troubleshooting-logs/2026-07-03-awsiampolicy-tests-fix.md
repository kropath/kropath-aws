# Logs for awsiampolicy chainsaw tests fix (2026-07-03)

All 10 steps of `tests/iam/awsiampolicy/chainsaw-test.yaml` were failing. Fixed iteratively via the debug loop.

---

## ac1-documentjson / ac1b-documentref — ACK Policy not created

### Root cause

`policyDoc` used `includeWhen` conditioned on `documentRef != ""`. When excluded, references to `policyDoc` in the `policy` template caused "no such variable: policyDoc" — the unbound variable freeze halts reconciliation entirely.

### Fix

Removed `includeWhen` from `policyDoc`. Replaced with sentinel selector pattern: when `documentRef` is empty, the selector targets `kropath.run/resource-name: kro-empty-fallback-sentinel` (matches nothing → resolves to `[]`). The `policyDocument` expression then falls back to `schema.spec.documentJSON`.

`02-awspolicydocument.yaml`: added `metadata.labels.kropath.run/resource-name: my-policy-doc` so the selector matches when `documentRef` is set.

---

## ac1c-mutual-exclusion — rate limiter / `$error` approach impossible

### Root cause

Test used chainsaw `expect ($error != null)` to assert that setting both `documentJSON` and `documentRef` would be rejected. kro SimpleSchema supports only `default`, `required`, `min`, `max` markers — no `x-kubernetes-validations`. The resource was accepted, chainsaw retried until rate limiter timeout.

### Fix

Used the `includeWhen`-gated ConfigMap advisory pattern (same as `awsiamidentityprovider` URL validation and `awsiamrole` maxSessionDuration):

- Added `mutualExclusionError` ConfigMap resource included only when `documentJSON != "" && documentRef != ""`
- Added `status.validationError` field reading from `mutualExclusionError.data.error`
- Changed chainsaw step to `apply + assert: 03-assert-mutual-exclusion.yaml`

---

## ac4-resource-name — `status.resourceName` showed K8s name, not effective name

### Root cause

`status.resourceName` read `schema.metadata.name` instead of the naming-template-resolved name. `policy.spec.name` was also not wired through the naming template.

### Fix

**`rgds/awsiampolicy.yaml`:**
- Added naming template logic to `policy.spec.name`: `nameOverride` wins, then mandatory `namingTemplate`, then defaults `namingTemplate`, then `schema.metadata.name`.
- `status.resourceName: ${policy.?spec.?name.orValue("")}` — reads effective name from ACK child.

**Assert files**: `spec.name` updated to `default-<name>` in all assert files (namespace `default` + naming template `{namespace}-{name}`).

---

## ac5-tags — mandatory tags missing from assert; RGD used list-concat not map-merge

### Root cause

`07-assert-tags.yaml` only checked for `{team: payments}`. The config set `mandatory.tags: {cost-centre: platform}`, producing `[{cost-centre, platform}, {team, payments}]`. Chainsaw requires exact slice length match.

Also, the RGD tags expression used `+` list concatenation which omits `syncedLabels`/`syncedAnnotations` from cloud tags and breaks mandatory-wins semantics.

### Fix

**`rgds/awsiampolicy.yaml`**: Replaced list-concat with map-merge pattern (defaults → spec → mandatory for all of syncedAnnotations, syncedLabels, tags), then `.transformList()` at end.

**`07-assert-tags.yaml`**: Added `{key: cost-centre, value: platform}` before `{key: team, value: payments}` (CEL map → list is alphabetical order).

---

## ac6-synced-labels — inter-step state pollution; cloud tag key had `kropath.run/` prefix

### Root causes

1. **`--type=merge` with `{}` is a no-op**: `ac5-tags` set `mandatory.tags: {cost-centre: platform}`. `ac6-synced-labels` tried to clear it with `"tags":{}` via merge patch. JSON merge patch with an empty object does NOT remove existing map keys. The tag persisted.

2. **Wrong cloud tag key**: `08-assert-synced-labels.yaml` expected `kropath.run/environment` for the cloud tag. Cloud tags must use plain keys — `kropath.run/` prefix is Kubernetes-only.

### Fix

**`chainsaw-test.yaml`**: Added `kubectl patch ... -p '{"status":{"effectiveConfig":null}}'` before each status patch in steps `ac6`–`ac10`. JSON merge patch treats `null` as field removal, giving a blank slate before the desired values are applied.

**`08-assert-synced-labels.yaml`**: Cloud tag key changed from `kropath.run/environment` to `environment`.

---

## ac7-status-arn / ac9-status-arn-actual — `status.arn` always empty in tests

### Root cause

`status.arn` and `status.predictedArn` both read from `policy.status.ackResourceMetadata.arn`, which is only populated when real AWS reconciles the resource. In mock tests it is always empty; kro omits empty-string status fields; chainsaw sees `status: {}`.

Additionally, the assert expected `arn-policy` (no prefix) but naming template produces `default-arn-policy`.

### Fix

**`rgds/awsiampolicy.yaml`**: `predictedArn` changed to be computed:
```yaml
predictedArn: >-
  ${has(policy.spec) ? "arn:aws:iam::" + rsrcCfg.status.effectiveConfig.aws.accountId + ":policy" + policy.spec.path + policy.spec.name : ""}
```
Must use `policy.spec.path` / `policy.spec.name` (child resource fields) — `schema.*` is unavailable in `status:` expressions.

`status.arn` stays as `${policy.status.?ackResourceMetadata.?arn.orValue("")}` for when real AWS is present.

**`09-assert-status-arn.yaml`**: Changed to `status.predictedArn: arn:aws:iam::123456789012:policy/default-arn-policy`.
