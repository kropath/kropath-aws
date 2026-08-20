# Troubleshooting Log: StepFunctionsStateMachine Chainsaw — RBAC, Mutual Exclusion, YAML Boolean, CRD Breaking Change

> **Point-in-time disclaimer:** This log records the author's understanding at the time of writing
> (2026-08-21). Claims here are hypotheses backed by the error output shown; verify mechanically
> before acting on them in future sessions.

**Ticket:** KRO-589
**Repo:** kropath-aws
**Date:** 2026-08-21

---

## Issue 1: RBAC forbidden for sfn.services.k8s.aws

### Symptom
Chainsaw step `ac1-mandatory-logging-level` failed with:
```
User "system:serviceaccount:kro-system:kro" cannot get resource "statemachines"
in API group "sfn.services.k8s.aws" in the namespace "stepfunctionsstatemachine"
```

### Root cause
`tests/fixtures/rbac/kro-controller.yaml` (the `kro:controller-iamidentityprovider` ClusterRole)
aggregated to kro did not include `sfn.services.k8s.aws` in its `apiGroups` list.

### Fix
Added `- sfn.services.k8s.aws` to the second rule's `apiGroups` block in
`tests/fixtures/rbac/kro-controller.yaml`. Applied with `kubectl apply -f tests/fixtures/rbac/kro-controller.yaml`.

---

## Issue 2: Mutual-exclusion CRD validation rejected Chainsaw StepFunctionsConfig specs

### Symptom
```
The StepFunctionsConfig.aws.kropath.run "ac1-cfg" is invalid:
  loggingLevel cannot be set in both mandatory and defaults
```
11 scenarios (ac1, ac4, ac5, ac8, ac9, ac10, ac11, ac12, ac22, ac23, ac24) failed because the
Chainsaw spec set the same field in BOTH `mandatory` AND `defaults` tiers.

### Root cause
`StepFunctionsConfig` CRD has `x-kubernetes-validations` mutual-exclusion rules:
- `loggingLevel cannot be set in both mandatory and defaults` (non-empty string in both tiers)
- `tracingEnabled cannot be set in both mandatory and defaults` (has() true in both tiers, any value including false)
- `includeExecutionData cannot be set in both mandatory and defaults` (has() in both tiers)
- `namingTemplate cannot be set in both mandatory and defaults` (non-empty string in both tiers)

The test specs were setting the same field in both tiers to simulate a complete effectiveConfig,
but the CRD validation applies to the spec (which is the actual CR, not the status).

### Fix
For each affected scenario:
- Set one tier's value to `""` (empty string) or remove the boolean field from that tier's spec
- The `status.effectiveConfig` patch (via `kubectl patch --subresource=status`) is NOT validated
  by these rules and can represent both tiers freely

Specific changes:
- ac1: `defaults.loggingLevel: "ERROR"` → `""`
- ac4: `defaults.loggingLevel: "OFF"` → `""`
- ac5: removed `defaults.tracingEnabled: false` from spec
- ac8: removed `defaults.tracingEnabled: true` from spec
- ac9: `defaults.loggingLevel: "ALL"` → `""` + removed `defaults.includeExecutionData: false`
- ac10: `defaults.loggingLevel: "ALL"` → `""`
- ac11: `defaults.loggingLevel: "ALL"` → `""`
- ac12: `defaults.loggingLevel: "OFF"` → `""`
- ac22: `defaults.namingTemplate: "{namespace}-{name}"` → `""`
- ac23: `defaults.namingTemplate: "{namespace}-{name}"` → `""`
- ac24: `defaults.namingTemplate: "{namespace}-{name}"` → `""`

---

## Issue 3: YAML 1.1 boolean: unquoted `OFF` parsed as false

### Symptom
ac13 assertion failed after timeout. The assert block contained:
```yaml
spec:
  loggingConfiguration:
    level: OFF
```

### Root cause
YAML 1.1 treats unquoted `OFF` as boolean `false`. Chainsaw's assertion engine received `false`
instead of the string `"OFF"`, so it could never match the string `"OFF"` produced by kro.

### Fix
Quote the value: `level: "OFF"`. This applies to all YAML 1.1 boolean literals:
`ON`, `OFF`, `YES`, `NO`, `TRUE`, `FALSE`, `y`, `n` — always quote them as strings in Chainsaw asserts.

---

## Issue 4: kro breaking CRD change: `definition` newly required

### Symptom
After deleting and re-applying the updated RGD (which added `definition: string | required=true`
to the schema), kro set the RGD to Inactive with:
```
cannot update CRD stepfunctionsstatemachines.aws.kropath.run:
breaking changes detected: Field definition is newly required
```

### Root cause
The original RGD had `definition: string` (optional). A subsequent session added
`required=true`. kro refuses to upgrade a CRD in a way that makes an existing optional field
required, because it would break existing instances.

### Fix
Delete the CRD so kro recreates it fresh:
```bash
kubectl delete crd stepfunctionsstatemachines.aws.kropath.run
```

But the CRD deletion hung because `StepFunctionsStateMachine` instances in the cluster had
kro finalizers, and the API server couldn't process the finalizer removal after the CRD was gone.

**Resolution:**
```bash
# Remove finalizers from all instances first
for ns in $(kubectl get namespace -o jsonpath='{.items[*].metadata.name}'); do
  for name in $(kubectl get stepfunctionsstatemachine -n $ns -o jsonpath='{.items[*].metadata.name}' 2>/dev/null); do
    kubectl patch stepfunctionsstatemachine/$name -n $ns --type=merge -p '{"metadata":{"finalizers":[]}}' 2>/dev/null || true
  done
done
# Then the background delete completes
```

After finalizers are removed, wait for `kubectl delete crd ...` to complete. Then re-apply the
RGD and wait for `Active`:
```bash
kubectl delete rgd stepfunctionsstatemachine.aws.kropath.run --ignore-not-found=true
kubectl apply -f rgds/stepfunctionsstatemachine.aws.kropath.run.yaml
# Loop until Active (kro re-creates fresh CRD with new schema)
```

### General rule
If kro reports "breaking changes detected: Field X is newly required", you MUST delete the CRD
first. Check for instances with finalizers before deleting — remove them first or the delete hangs.
