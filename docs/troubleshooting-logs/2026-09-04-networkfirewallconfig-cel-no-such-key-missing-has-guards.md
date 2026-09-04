> **Point-in-time disclaimer:** This log records observations made on 2026-09-04. CEL behaviour,
> CRD schema, and test fixtures may have changed since then. Verify claims mechanically before
> acting on them.

# NetworkFirewallConfig CRD — `x-kubernetes-validations` CEL "no such key" on Optional Fields

**Ticket:** KRO-943  
**PR:** kropath-aws#225  
**Date:** 2026-09-04  
**Failing test:** `networkfirewallconfig` / `ac14-naming-template-in-effective-config`

## Symptom

CI (and local reproduction) rejected the `naming-config` NetworkFirewallConfig CR with 6 errors:

```
NetworkFirewallConfig.aws.kropath.run "naming-config" is invalid:
  no such key: deleteProtection evaluating rule: deleteProtection cannot be set to true in both mandatory and defaults
  no such key: firewallPolicyChangeProtection ...
  no such key: subnetChangeProtection ...
  no such key: encryptionType ...
  no such key: statefulRuleOrder ...
  no such key: streamExceptionPolicy ...
```

The `naming-config` CR only sets `namingTemplate` and `statefulDefaultActions`; it does not set
the protection booleans or other string fields.

## Root Cause

The `x-kubernetes-validations` rules in `crds/networkfirewallconfig.yaml` accessed optional fields
(booleans: `deleteProtection`, `firewallPolicyChangeProtection`, `subnetChangeProtection`; strings:
`encryptionType`, `statefulRuleOrder`, `streamExceptionPolicy`, `namingTemplate`) without wrapping
them in `has()` guards.

These fields have **no CRD `default:` values** — when absent from a CR, the Kubernetes API server
does not materialize them, and CEL throws `"no such key"` on access. The `x-kubernetes-validations`
rules evaluated at the root object level cannot assume optional fields are present.

Fields with explicit `default:` values (`statefulDefaultActions: default: []`) are always
materialized and do NOT need `has()` guards.

## Fix

Added `has(self.spec.mandatory.<field>)` and `has(self.spec.defaults.<field>)` guards before every
field access in the 7 affected validation rules. The short-circuit `&&` ensures the guard fires
before the access:

```yaml
# BEFORE (broken — throws "no such key" when field is absent):
- rule: >-
    !(self.spec.mandatory.deleteProtection == true &&
      self.spec.defaults.deleteProtection == true)

# AFTER (correct — guard prevents access of absent field):
- rule: >-
    !(has(self.spec.mandatory.deleteProtection) && self.spec.mandatory.deleteProtection == true &&
      has(self.spec.defaults.deleteProtection) && self.spec.defaults.deleteProtection == true)
```

## Verification

```bash
# Reproduced failure:
kubectl apply -f crds/networkfirewallconfig.yaml   # old CRD
# → 6 "no such key" errors on naming-config

# Applied fix:
kubectl apply -f crds/networkfirewallconfig.yaml   # patched CRD
kubectl apply -f 14-config-naming-template.yaml    # → created ✓

# Negative path still works:
# dual-true deleteProtection → rejected with "deleteProtection cannot be set to true in both mandatory and defaults" ✓
# mandatory=true + defaults=false → accepted ✓
```

## Pattern

Any governance Config CRD with `x-kubernetes-validations` rules must wrap access to optional scalar
fields (those without `default:` values) in `has()` before accessing them. Fields with
`default: []` / `default: {}` / `default: ""` / `default: false` are always materialized and safe
to access directly, but scalars (string, integer, boolean) with no default are absent when not
explicitly set.

See also: `docs/frequent-rgd-errors.md` §"Config-CRD Mutual-Exclusion `x-kubernetes-validations`
Broken by Non-Zero `spec.defaults` CRD Defaults" (related but different — that section covers
non-zero defaults colliding with mutual-exclusion rules; this log covers missing fields throwing
"no such key").
