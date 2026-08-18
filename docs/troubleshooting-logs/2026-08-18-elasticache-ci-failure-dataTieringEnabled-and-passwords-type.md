# Troubleshooting Log: ElastiCache CI Failure — dataTieringEnabled + AuthenticationMode.passwords type mismatch

**Date:** 2026-08-18  
**Ticket:** KRO-413  
**Repo:** kropath-aws  
**Commit fixed:** (this commit)

> **Point-in-time disclaimer:** This log records what the author believed at the time of writing.
> Claims here are hypotheses unless mechanically verified. Verify before acting.

---

## Summary

Two Chainsaw test suites failed in CI after commit `c2f5c6f`:

1. `elasticachereplicationgroup[ac1-basic-create]` — 5-minute timeout on ACK ReplicationGroup assert
2. `elasticacheuser[ac3-password-auth]` — 5-minute timeout on ACK User assert

---

## Issue 1: `dataTieringEnabled` — bare boolean without `has()` guard causes "no such key" at runtime

### Symptom

`elasticachereplicationgroup/ac1-basic-create` times out (300s) asserting on the ACK ReplicationGroup.
The ElastiCacheReplicationGroup instance status shows:

```
resource reconciliation failed: waiting for unresolved resource: gvr "elasticache.services.k8s.aws/v1alpha1, Resource=replicationgroups":
node "ackReplicationGroup": failed to evaluate expression: eval "schema.spec.dataTieringEnabled": no such key: dataTieringEnabled (data pending)
```

### Root Cause

`rgds/elasticachereplicationgroup.aws.kropath.run.yaml` declared `dataTieringEnabled: boolean`
(no default) and used a bare passthrough in the template:

```yaml
dataTieringEnabled: ${schema.spec.dataTieringEnabled}
```

When the user does not set `dataTieringEnabled`, kro's CEL evaluator throws "no such key: dataTieringEnabled"
because the field is absent from the spec. Unlike fields with `| default=X`, bare `boolean` fields
are truly optional — they are absent from the schema object when not set. All other governed booleans
(`atRestEncryptionEnabled`, `transitEncryptionEnabled`, `automaticFailoverEnabled`, `multiAZEnabled`)
use `has()` guards and were unaffected.

Reproduced locally: `kubectl get elasticachereplicationgroup debug-rg -o jsonpath='{.status.conditions}'`
confirmed the exact error.

### Fix

```yaml
# BEFORE
dataTieringEnabled: ${schema.spec.dataTieringEnabled}

# AFTER
dataTieringEnabled: >-
  ${has(schema.spec.dataTieringEnabled) ? schema.spec.dataTieringEnabled : false}
```

### Rule

Every bare `boolean` (no `| default=`) field used in an RGD template must be accessed via `has()`:
```yaml
myBoolField: >-
  ${has(schema.spec.myBoolField) ? schema.spec.myBoolField : false}
```
Direct passthrough without `has()` always fails when the user omits the field.

---

## Issue 2: `AuthenticationMode.passwords` declared as `[]string` but ACK expects `[]SecretKeyReference`

### Symptom

`elasticacheuser/ac3-password-auth` times out (300s) asserting on the ACK User.

### Root Cause

`rgds/elasticacheuser.aws.kropath.run.yaml` declared:

```yaml
types:
  AuthenticationMode:
    type: string | default=""
    passwords: "[]string | default=[]"
```

But the ACK ElastiCache User CRD defines `authenticationMode.passwords` as `[]SecretKeyReference`:

```json
{
  "passwords": {
    "items": {
      "properties": {
        "key": {"type": "string"},   // required
        "name": {"type": "string"},
        "namespace": {"type": "string"}
      },
      "required": ["key"],
      "type": "object"
    },
    "type": "array"
  }
}
```

When the Chainsaw test supplied `passwords: ["SecretPass123!"]` (plain strings), kro passed this
to the ACK API server which rejected the create request (string ≠ object). The ACK User CR was
never created, causing the assert to time out.

Verified via: `kubectl get crd users.elasticache.services.k8s.aws -o json | jq '.spec.versions[0].schema.openAPIV3Schema.properties.spec.properties.authenticationMode'`

### Fix

Added a `PasswordSecretRef` named type:

```yaml
types:
  AuthenticationMode:
    type: string | default=""
    passwords: "[]PasswordSecretRef | default=[]"
  PasswordSecretRef:
    name: string | default=""
    key: string | default=""
    namespace: string | default=""
```

Updated `ac3-password-auth` Chainsaw step to:
1. Create a K8s Secret `ac3-pass-secret`
2. Reference it via `passwords: [{name: ac3-pass-secret, key: password}]`
3. Assert that the ACK User receives the correct SecretKeyReference

### Note on CRD Breaking Change

Changing `passwords` from `[]string` to `[]PasswordSecretRef` is a breaking CRD schema change.
During local testing, had to delete the stale generated CRD:
```bash
kubectl delete crd elasticacheusers.aws.kropath.run
```
CI runs on a fresh cluster and are unaffected.

---

## Rule Summary

1. **Every bare `boolean` in an RGD template must use `has()`.** Do not use direct passthrough.
2. **Always verify upstream (ACK/KCC/ASO) field types from the live CRD** before writing kro types.
   Use `kubectl get crd <name> -o json | jq '.spec.versions[0].schema...'` to confirm.
   `[]string` and `[]SecretKeyReference` look the same in YAML but are completely different types.
