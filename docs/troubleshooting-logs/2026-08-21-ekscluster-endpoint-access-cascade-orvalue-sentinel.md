# EKSCluster endpoint access cascade: orValue(false) for zero-value sentinel

> **Point-in-time disclaimer:** This log records what the author believed at the time of
> writing. Verify mechanically before acting on any claim here; do not elevate above
> `docs/frequent-rgd-errors.md` or agent instructions if a conflict exists.

**Date:** 2026-08-21
**Ticket:** KRO-532
**PR:** kropath-aws#134

---

## Symptom

CI failed on `ac10-endpoint-access-defaults` in `chainsaw/eks/ekscluster[ekscluster]`:

```
spec.resourcesVPCConfig.endpointPublicAccess: Invalid value: false: Expected value: true
spec.resourcesVPCConfig.endpointPrivateAccess: Invalid value: false: Expected value: true
```

Test config: `mandatory.endpointPublicAccess=false` (zero-value sentinel), `defaults.endpointPublicAccess=true`, instance does not set the field. Expected: `true`.

---

## Root cause

The governance mandatory tier for `endpointPublicAccess`/`endpointPrivateAccess` uses `false` as the zero-value sentinel (not-enforced). The cascade used `!= null` to check whether mandatory was set:

```cel
rsrcCfg[0].status.effectiveConfig.mandatory.?endpointPublicAccess != null
```

Since `false != null` is always `true` in CEL, the RGD treated the zero-value `false` (not-enforced) as an explicitly-governed value, bypassing the instance field and returning `false` instead of the expected `true`.

---

## Approaches tried

### Attempt 1: 3-tier cascade with bare `boolean` schema

Changed instance schema from `boolean | default=true` to bare `boolean` (nullable) and added a 3-tier cascade (mandatory → instance → defaults) using `?field != null` for the instance tier. kro accepted the RGD as Active but at runtime threw:

```
no such key: endpointPrivateAccess (data pending)
```

**Why it failed:** kro's CEL engine treats instance schema fields as typed structs, not dynamic maps. The `?` optional chaining accessor on a typed struct field that is absent (bare boolean, not materialized) throws "no such key" rather than returning `null`. The `?` chaining only works on dynamic objects (e.g., `effectiveConfig` status fields which are map/dict). This is documented in the existing RGD comments: "CEL null-checks only work on effectiveConfig (dynamic) fields."

### Attempt 2: 2-tier cascade with `.orValue(false)` on mandatory — CORRECT

Reverted to `boolean | default=true` (instance field always present via materialized default). Changed only the mandatory check to use `.orValue(false)`:

```cel
rsrcCfg[0].status.effectiveConfig.mandatory.?endpointPublicAccess.orValue(false)
  ? true
  : schema.spec.resourcesVPCConfig.endpointPublicAccess
```

With mandatory=false (sentinel):
- `?endpointPublicAccess` returns `optional(false)`, `.orValue(false)` returns `false`
- Condition is `false` → fall through to instance → instance is `true` (materialized default=true) ✓

With mandatory=true (enforced):
- `.orValue(false)` returns `true` → condition is `true` → return `true` ✓

With mandatory absent from effectiveConfig JSON:
- `.orValue(false)` returns `false` → fall through ✓

---

## Related test fix

`ac19-ac20-mandatory-endpoint-access` had a wrong assertion: `endpointPublicAccess: false`. With `mandatory.endpointPublicAccess=false` (sentinel), the cascade falls through to the instance field (materialized default=true), so the correct assertion is `endpointPublicAccess: true`. The original assertion was written assuming the broken cascade behavior.

---

## Pattern to remember

**For governance boolean fields where `false` = zero-value sentinel (not-enforced):**

```cel
# WRONG — false != null is always true
rsrcCfg[0].status.effectiveConfig.mandatory.?boolField != null

# CORRECT — orValue(false) returns false for both "absent" and "present-as-false"
rsrcCfg[0].status.effectiveConfig.mandatory.?boolField.orValue(false)
```

**For instance schema boolean fields (2-tier cascade, keep `| default=X`):**

Do NOT use `?field != null` on kro schema typed struct fields — kro's CEL throws "no such key" for absent fields. Instead, keep `| default=X` to ensure the field is always present, making null-checks unnecessary.
