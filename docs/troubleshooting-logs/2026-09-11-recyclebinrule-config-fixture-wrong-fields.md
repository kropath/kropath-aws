> **Point-in-time note:** This log was written on 2026-09-11. Claims here reflect understanding at that date. If any claim conflicts with `docs/frequent-rgd-errors.md` or agent instructions, those higher-precedence sources win.

# RecycleBinRule: Config fixture files included resource-level fields (KRO-1040)

**Ticket:** KRO-1040
**Date:** 2026-09-11
**Resource affected:** RecycleBinRule (`recyclebinrule.aws.kropath.run`)
**Symptom:** All Chainsaw test scenarios failed immediately at setup with a CRD strict-decoding error:
```
RecycleBinConfig in version "v1alpha1" cannot be handled as a RecycleBinConfig:
strict decoding error: unknown field "spec.configRef", unknown field "spec.deletionPolicy"
```

## CI Failure

CI check "RGD Tests" failed on PR #260, head `8f3b8dd9`.

## Root Cause

The governance config fixture files (`01-general-policy.yaml` and `02-mandatory-lock-config.yaml`) applied `RecycleBinConfig` CRs with `spec.configRef` and `spec.deletionPolicy` fields. These fields belong on **resource** CRs (`RecycleBinRule`), not on **governance config** CRs (`RecycleBinConfig`).

The `RecycleBinConfig` CRD spec only accepts `mandatory` and `defaults` governance tier objects. Setting `spec.configRef` or `spec.deletionPolicy` on a governance config CR causes a Kubernetes strict-decoding rejection and prevents the entire namespace setup from completing, which in turn causes all 22 test scenarios to fail.

## Fix

Removed `spec.configRef` and `spec.deletionPolicy` from both fixture files. The fixture spec is now `spec: {}` (empty — governance fields are not required since status is seeded directly via `kubectl patch --subresource=status`).

**Files changed:**
- `tests/recyclebin/recyclebinrule/01-general-policy.yaml`
- `tests/recyclebin/recyclebinrule/02-mandatory-lock-config.yaml`

## Pattern to remember

When authoring governance config CRs (`<Service>Config`) for Chainsaw fixtures, the spec must contain **only** `mandatory.*`, `defaults.*`, and other governance tier fields defined in the config CRD. Never include resource-level fields like `spec.configRef`, `spec.deletionPolicy`, or `spec.nameOverride` — those belong on the resource CR (the kro RGD instance), not the governance config.
