# 2026-09-01: KinesisStream Chainsaw Test — Dual-Tier Field in KinesisConfig Spec

> **Point-in-time disclaimer:** This log records what was observed and concluded at the time of
> writing. It may be superseded by later discoveries. Verify claims mechanically before acting on
> them; do not elevate this log above `docs/frequent-rgd-errors.md` or agent instructions.

## Ticket

KRO-747 — [kropath-aws] RGD + Tests: Kinesis resources (PR #198)

## Symptom

Local `make test-kinesis` failed on step `ac10-naming-mandatory-template` with:

```
KinesisConfig.aws.kropath.run "ac10-cfg" is invalid: <nil>: Invalid value:
namingTemplate cannot be set in both mandatory and defaults.
```

The KinesisConfig APPLY step kept retrying for ~60 s (chainsaw retry loop) and then
errored. All subsequent steps were skipped.

## Root Cause

The `ac10-naming-mandatory-template` test step created a `KinesisConfig` with
`spec.mandatory.namingTemplate` AND `spec.defaults.namingTemplate` both set to non-empty
values. The KinesisConfig CRD has three CEL mutual-exclusion `x-kubernetes-validations` rules:

1. `streamMode` cannot be set in both mandatory and defaults
2. `shardCount` cannot be set in both mandatory and defaults
3. `namingTemplate` cannot be set in both mandatory and defaults

Setting the same field in both tiers on a single config resource is semantically wrong anyway:
the tiers represent **different governance sources** (mandatory = this KinesisConfig; defaults =
global KropathConfig or parent config). A single KinesisConfig should declare at most one tier
for any given field.

The `effectiveConfig` status (pre-populated by the test's `kubectl patch --subresource=status`)
correctly encodes both tiers' merged values — that is where the two values coexist, not in the
spec.

## Approaches Tried

### Approach 1 (successful): Remove defaults.namingTemplate from spec

Remove `defaults: namingTemplate: "{namespace}-{name}"` from the KinesisConfig spec in ac10.
The effectiveConfig status patch already includes `defaults.namingTemplate` at the right value,
simulating what the controller would merge from the global KropathConfig.

**Result:** All tests pass — `chainsaw/kinesis/kinesisstream[kinesisstream] 9.55s PASS`.

## Pattern Learned

**When testing mandatory-wins-over-defaults precedence**: the KinesisConfig spec should only
set the tier being tested for this config resource. The "other tier" value appears only in the
effectiveConfig status patch (simulating the controller's merge from upstream governance).

Example for testing "mandatory.namingTemplate wins over defaults.namingTemplate":
- KinesisConfig spec: set ONLY `mandatory.namingTemplate`
- effectiveConfig status patch: set BOTH `mandatory.namingTemplate` and `defaults.namingTemplate`

This matches how the real cascade works:
- `KinesisConfig.spec.mandatory.*` → this namespace's mandatory overrides
- `KropathConfig.spec.defaults.*` → org-wide defaults (a separate resource)
- Controller merges both into `effectiveConfig`

## Related

- `docs/frequent-rgd-errors.md` — §"CRD Tier-Tier Mutual Exclusion": add if not present
- KRO-747, PR kropath/kropath-aws#198
