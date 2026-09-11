# RecycleBinRule — RBAC missing for recyclebin API group + kro does not strip empty-string fields

**Date:** 2026-09-11
**Ticket:** KRO-1040
**PR:** https://github.com/kropath/kropath-aws/pull/260

> ⚠️ **Point-in-time disclaimer:** This log records findings as of 2026-09-11. kro behaviour or
> ACK CRD schemas may change in later versions. Verify mechanically before applying patterns from
> this log to a new task.

---

## Problem 1: kro RBAC missing `recyclebin.services.k8s.aws` API group

### Symptom

CI Chainsaw E2E Tests failing with:

```
ac1-region-level-ebs-snapshot | ASSERT | ERROR |
recyclebin.services.k8s.aws/v1alpha1/Rule @ recyclebinrule/ac1-region-ebs — actual resource not found
```

Local reproduction (after `tests/setup.sh`):

```bash
kubectl describe recyclebinrule ac1-region-ebs -n recyclebinrule
# Shows:
# resource reconciliation failed: failed to list external collection ackRbRuleRef:
# rules.recyclebin.services.k8s.aws is forbidden: User "system:serviceaccount:kro-system:kro"
# cannot list resource "rules" in API group "recyclebin.services.k8s.aws" in the namespace "recyclebinrule"
```

### Root Cause

`tests/fixtures/rbac/kro-controller.yaml` did not include `recyclebin.services.k8s.aws` in the
`apiGroups` list. kro's service account needs list/get/watch/create/update/patch/delete access to
ACK Rule resources. Without it, the `ackRbRuleRef` self-lookup externalRef fails, blocking kro
from creating any ACK Rule children.

### Fix

Added `- recyclebin.services.k8s.aws` to the RBAC ClusterRole after `- ram.services.k8s.aws`.

**Reproducing command:** `kubectl describe recyclebinrule <name> -n recyclebinrule`
**Fix verified by:** RecycleBinRule reached ACTIVE state; ACK Rule was created with correct spec.

---

## Problem 2: kro v0.9.2 does NOT strip empty-string fields from child resource spec templates

### Symptom

After fixing RBAC, AC-8 Chainsaw assertion fails:
```
(description): null  # expected field to be absent
```

But the ACK Rule spec has `description: ""` — the field is present as an empty string.

### Root Cause

The original RGD comment said: "kro omits empty-string fields → absent from ACK Rule when not set".
This is **incorrect for kro v0.9.2 child resource spec templates**. kro may strip empty strings
from its own internal status fields, but it does NOT strip them from templates it writes to child
resources. When `schema.spec.description` defaults to `""` and the template has
`description: ${schema.spec.description}`, kro renders and applies `description: ""` to the ACK Rule.

Attempts that failed:
- `description: ${schema.spec.description != "" ? schema.spec.description : null}` → kro CEL
  rejects mixed `string|null` ternary with "found no matching overload for '_?_:_' applied to
  '(bool, string, null)'".

### Fix

Split the 2-variant approach (locked/unlocked) into 4 variants:
- `ackRbRuleLocked`: locked + `description == ""` (no description field in template)
- `ackRbRuleUnlocked`: unlocked + `description == ""` (no description field in template)
- `ackRbRuleLockedDesc`: locked + `description != ""` (includes `description: ${schema.spec.description}`)
- `ackRbRuleUnlockedDesc`: unlocked + `description != ""` (includes `description: ${schema.spec.description}`)

The `description == ""` / `description != ""` condition is added to each variant's `includeWhen`.
This ensures the field is physically absent from the ACK Rule spec when not set by the user.

**Reproducing command:**
```bash
# Create a RecycleBinRule without description, seed RecycleBinConfig status, then check:
kubectl get rules.recyclebin.services.k8s.aws <name> -n <ns> -o json | jq '.spec.description'
# Without fix: null (field absent) expected but got ""
# With fix: null (field truly absent)
```

**Fix verified by:**
- `no-desc-test` ACK Rule: `desc: null` (field absent) ✓
- `with-desc-test` ACK Rule: `desc: "My test description"` ✓

### Lesson Learned

The "kro omits empty-string fields" behavior applies to kro's own CR status fields (e.g. a status
field whose CEL expression evaluates to `""`). It does NOT apply to child resource spec templates.
When an optional string field must be absent from the child resource when unset, use the
variant-split pattern (add a dimension to `includeWhen`) rather than relying on kro stripping.

This pattern generalises: any optional field where "absent" ≠ "empty-string/zero-value" requires
a variant split in kro v0.9.2.
