# EKSCluster: `!= null` cascade always true for boolean fields using `false` as zero-value sentinel

**Date:** 2026-08-21
**Ticket:** KRO-532
**Resource family:** EKS / ekscluster

> **Point-in-time disclaimer:** This log records what the author observed and concluded on the date
> above. Claims were verified against the RGD, CI failure output, and local cluster at the time of
> writing. Later changes to the CRD or controller may affect these conclusions. Verify mechanically
> before acting on any specific claim.

---

## Symptom

CI failure on `chainsaw/eks/ekscluster[ekscluster]` with error:

```
* spec.resourcesVPCConfig.endpointPrivateAccess: Invalid value: false: Expected value: true
* spec.resourcesVPCConfig.endpointPublicAccess: Invalid value: false: Expected value: true
```

The `ac10-endpoint-access-defaults` step: EKSConfig `mandatory.endpointPublicAccess=false` (sentinel
= not enforced) and `defaults.endpointPublicAccess=true`. Instance does not set the field. Expected
the ACK Cluster to get `true` (from schema default=true). Got `false`.

---

## Root cause

The EKSConfig effectiveConfig stores `endpointPublicAccess` / `endpointPrivateAccess` as plain
`boolean`. The mandatory tier uses `false` as the zero-value sentinel meaning "not governed". The
RGD cascade used `!= null` to detect governance:

```cel
rsrcCfg[0].status.effectiveConfig.mandatory.?endpointPublicAccess != null
```

CEL's optional chaining `?field` on a present field with value `false` returns `optional(false)`,
NOT absent. So `false != null` is always `true`, regardless of whether the mandatory tier intended
`false` as "not enforced". The cascade always routed to the mandatory branch and passed `false` to
the ACK child, ignoring the defaults and the instance default=true.

---

## Fix

Changed the guard from `!= null` to `.orValue(false)`:

```cel
rsrcCfg[0].status.effectiveConfig.mandatory.?endpointPublicAccess.orValue(false)
```

Behaviour:
- `mandatory.?field.orValue(false)` where field=`false` → `false.orValue(false)` → `false` → fall through ✓
- `mandatory.?field.orValue(false)` where field=`true` → `true.orValue(false)` → `true` → use mandatory ✓
- `mandatory.?field.orValue(false)` where field is absent (optional()) → `false` → fall through ✓

Also corrected the `ac19-ac20-mandatory-endpoint-access` Chainsaw assertion: the test set
`mandatory.endpointPublicAccess=false` (sentinel/not-enforced), which under the fix falls through to
the schema default=true. The assertion was wrongly expecting `false`; corrected to `true`.

---

## When this applies

Any boolean field in effectiveConfig that uses `false` as the "not governed" sentinel. The `!= null`
guard is only reliable for fields that can be genuinely absent (optional fields); for always-present
booleans it is always true. Use `.orValue(false)` when the sentinel is `false`, `.orValue(true)`
when the sentinel is `true`.

**Does NOT apply to** boolean fields declared `boolean | default=true` in the RGD schema (instance
fields). These are kro-typed structs where optional chaining is not safe at all — use the
`schema.spec.field` direct access pattern with no null guard.
