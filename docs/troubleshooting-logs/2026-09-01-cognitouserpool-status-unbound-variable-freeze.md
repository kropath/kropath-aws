> **Point-in-time disclaimer:** This log records what was observed on 2026-09-01. kro behaviour,
> ACK CRD shapes, and RGD patterns evolve; verify claims mechanically before acting on them.

# CognitoUserPool: status.userPoolArn/userPoolId Empty Due to Unbound Variable Freeze

**Date:** 2026-09-01  
**Issue:** KRO-738  
**Symptom:** `ac41-status-outputs` Chainsaw scenario failed: `FAIL: status.userPoolArn/userPoolId not populated after 60s` even after patching the ACK UserPool status.

## Root Cause

The status block in the CognitoUserPool RGD used a conditional expression referencing BOTH `ackUserPool` and `ackUserPoolFull`:

```yaml
userPoolArn: >-
  ${has(ackUserPoolFull.status) && has(ackUserPoolFull.status.ackResourceMetadata) ? ackUserPoolFull.status.?ackResourceMetadata.?arn.orValue("") : ackUserPool.?status.?ackResourceMetadata.?arn.orValue("")}
```

When `ackUserPoolFull` is excluded by its `includeWhen` condition (i.e., `resolvedAdvancedSecurityMode == ""`), kro removes `ackUserPoolFull` from the active memory context. Any status expression that **mentions** the excluded variable — even in a branch that would not be taken — silently evaluates to `""`. This is the "Unbound Variable Freeze" documented in `frequent-rgd-errors.md`.

Confirmed locally: kro DOES re-reconcile the CognitoUserPool after patching the ACK UserPool status (watch event triggers reconciliation), but the expression returns `""` because `ackUserPoolFull` is not in context.

## Fix

Added an `externalRef` resource `activePool` that selects the active ACK UserPool via kro's own ownership label:

```yaml
- id: activePool
  externalRef:
    apiVersion: cognitoidentityprovider.services.k8s.aws/v1alpha1
    kind: UserPool
    metadata:
      namespace: ${schema.metadata.namespace}
      selector:
        matchLabels:
          kro.run/instance-name: ${schema.metadata.name}
```

kro sets `kro.run/instance-name: <parent-name>` on all owned child resources. Since `ackUserPool` and `ackUserPoolFull` are mutually exclusive, this `externalRef` list has exactly one entry when a variant is active. As an `externalRef` (not conditionally included), `activePool` is always in context.

Updated status expressions to use `activePool[0]` with size/has guards:

```yaml
userPoolArn: >-
  ${activePool.size() > 0 && has(activePool[0].status) && has(activePool[0].status.ackResourceMetadata) ? activePool[0].status.?ackResourceMetadata.?arn.orValue("") : ""}
userPoolId: >-
  ${activePool.size() > 0 && has(activePool[0].status) && has(activePool[0].status.id) ? activePool[0].status.?id.orValue("") : ""}
```

## Verification

- RGD reaches `Active` after delete+apply
- Manual test: after patching ACK UserPool status, `userPoolArn` and `userPoolId` propagate to the CognitoUserPool CR within 1 second
- Full Chainsaw suite passes: `cognitoconfig` (0.60s PASS), `cognitouserpool` (21.22s PASS), 0 failures
