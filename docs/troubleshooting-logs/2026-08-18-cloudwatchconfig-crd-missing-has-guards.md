# CloudWatchConfig CRD — `x-kubernetes-validations` Missing `has()` Guards on Optional String Fields

**Date:** 2026-08-18
**Issue:** KRO-349
**PR:** #125

> **Point-in-time disclaimer:** This log records what the author understood at the time of
> writing. Verify claims mechanically before acting on them. See
> `docs/multica/agents/README.md` §"Knowledge source precedence".

## Symptom

All three new CloudWatch Chainsaw suites (cloudwatchalarm, cloudwatchdashboard,
cloudwatchmetricstream) failed simultaneously in CI within 30 seconds — the exact ApplyTimeout:

```
--- FAIL: chainsaw/cloudwatch/cloudwatchalarm[cloudwatchalarm] (30.09s)
--- FAIL: chainsaw/cloudwatch/cloudwatchmetricstream[cloudwatchmetricstream] (30.09s)
--- FAIL: chainsaw/cloudwatch/cloudwatchdashboard[cloudwatchdashboard] (30.09s)
client rate limiter Wait returned an error: context deadline exceeded
```

The rate limiter / deadline errors are a secondary symptom: Chainsaw retried the failed apply
repeatedly for the full 30s ApplyTimeout, exhausting the client rate limiter as the context
expired.

The root error (from the `ac1-*` step in each suite):

```
CloudWatchConfig.aws.kropath.run "ac1-cfg" is invalid: [
  <nil>: Invalid value: "object": no such key: treatMissingData evaluating rule:
    treatMissingData must be set in either mandatory or defaults, not both.,
  <nil>: Invalid value: "object": no such key: outputFormat evaluating rule:
    outputFormat must be set in either mandatory or defaults, not both.,
  <nil>: Invalid value: "object": no such key: namingTemplate evaluating rule:
    namingTemplate must be set in either mandatory or defaults, not both.,
  <nil>: Invalid value: "object": no such key: treatMissingData evaluating rule:
    mandatory.treatMissingData must be empty or one of: breaching, notBreaching, ignore, missing.,
  ...
]
```

## Root Cause

`crds/cloudwatchconfig.yaml` had `x-kubernetes-validations` rules for optional string fields
(`treatMissingData`, `outputFormat`, `namingTemplate`) that lacked `has()` guards:

```yaml
# BROKEN — fails when field is absent
- rule: >-
    !(self.spec.mandatory.treatMissingData != '' &&
      self.spec.defaults.treatMissingData != '')
  message: "treatMissingData must be set in either mandatory or defaults, not both."

- rule: >-
    self.spec.mandatory.treatMissingData == '' ||
    self.spec.mandatory.treatMissingData in ['breaching', 'notBreaching', 'ignore', 'missing']
  message: "mandatory.treatMissingData must be empty or one of: ..."
```

When a test applies a minimal `CloudWatchConfig` (e.g. only `spec.defaults.namingTemplate`),
the fields `treatMissingData` and `outputFormat` are absent from the object. CEL accesses
`self.spec.mandatory.treatMissingData` on an object where the field doesn't exist and throws
`no such key: treatMissingData` — which the Kubernetes apiserver surfaces as a validation
failure.

`spec.mandatory` and `spec.defaults` both have `default: {}`, so they always exist as empty
maps. But the leaf string fields inside them have no `default:` — they are genuinely absent
when not specified by the user. CEL requires `has()` guards before accessing optional map keys.

The `actionsEnabled` boolean field already had correct `has()` guards; only the string fields
were affected.

## Fix

Add `has()` guards to all mutual-exclusion and value-validation rules for optional string fields.

**Mutual-exclusion (before → after):**

```yaml
# BEFORE
- rule: >-
    !(self.spec.mandatory.treatMissingData != '' &&
      self.spec.defaults.treatMissingData != '')

# AFTER
- rule: >-
    !(
      (has(self.spec.mandatory.treatMissingData) && self.spec.mandatory.treatMissingData != '') &&
      (has(self.spec.defaults.treatMissingData) && self.spec.defaults.treatMissingData != '')
    )
```

**Value validation (before → after):**

```yaml
# BEFORE
- rule: >-
    self.spec.mandatory.treatMissingData == '' ||
    self.spec.mandatory.treatMissingData in ['breaching', 'notBreaching', 'ignore', 'missing']

# AFTER
- rule: >-
    !has(self.spec.mandatory.treatMissingData) ||
    self.spec.mandatory.treatMissingData == '' ||
    self.spec.mandatory.treatMissingData in ['breaching', 'notBreaching', 'ignore', 'missing']
```

Same pattern applied to `outputFormat` (both tiers) and `namingTemplate` (mutual-exclusion only).

## Pattern

Any `x-kubernetes-validations` rule that accesses an **optional field** (no `default:` in the
CRD schema) must guard with `has()` first. This is the canonical pattern used by
`cloudwatchlogsconfig.yaml` and all other governance CRDs in this repo:

```
!has(self.spec.mandatory.X) || self.spec.mandatory.X == '' || self.spec.mandatory.X in [...]
```

The correct mutual-exclusion pattern (also documented at `docs/frequent-rgd-errors.md` §"Config-CRD
Mutual-Exclusion") is:

```
!(
  (has(self.spec.mandatory.X) && self.spec.mandatory.X != '') &&
  (has(self.spec.defaults.X) && self.spec.defaults.X != '')
)
```

When authoring governance CRDs: compare every validation rule against `cloudwatchlogsconfig.yaml`
before committing. If `has()` guards are missing on optional fields, the CRD will reject any
minimal config that omits those fields.
