# 2026-09-10 — `| required` Marker Not Supported in kro v0.9.2

> **Point-in-time disclaimer:** This log records what was observed at the time of writing.
> Verify claims against the current kro version before acting on them.

## What Failed

Adding `type: string | required` and `policy: string | required` to the RGD schema for
`opensearchsecuritypolicy.aws.kropath.run` produced the following kro error:

```
failed to build resourcegraphdefinition "opensearchsecuritypolicy.aws.kropath.run":
failed to build OpenAPI schema for instance: field policy: marker key 'required' without a value
```

The RGD stayed `Inactive` across all 8 delete+apply rounds.

## Root Cause

kro v0.9.2's schema parser does not recognise `| required` as a valid marker. The parser treats
`required` as a key that must have an associated value (e.g. `key=value` form) and fails when it
finds none.

## Fix

Changed both fields to use sentinel `default=""`:

```yaml
type: string | default=""
policy: string | default=""
```

The in-graph `validationErrors` ConfigMap advisory pattern then enforces the non-empty constraint:

```yaml
data:
  typeError: >-
    ${schema.spec.type == "" ? "type is required" : ""}
  policyError: >-
    ${schema.spec.policy == "" ? "policy is required" : ""}
```

The `status.validationError` field surfaces the first non-empty error from the ConfigMap.

## Context

- Ticket: KRO-886
- RGD: `rgds/opensearchsecuritypolicy.aws.kropath.run.yaml`
- kro version: v0.9.2
- Reproducible with: `kubectl delete rgd opensearchsecuritypolicy.aws.kropath.run && kubectl apply -f rgds/opensearchsecuritypolicy.aws.kropath.run.yaml && kubectl get rgd opensearchsecuritypolicy.aws.kropath.run -o jsonpath='{.status.conditions[?(@.type=="GraphAccepted")].message}'`
