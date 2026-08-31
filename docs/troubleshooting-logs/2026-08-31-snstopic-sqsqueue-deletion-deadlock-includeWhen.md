# Troubleshooting Log: SNSTopic/SQSQueue Deletion Deadlock — includeWhen Depends on Graph-Internal `naming` Node (KRO-919)

**Date:** 2026-08-31
**Author:** Implementer
**Ticket:** KRO-919
**Repo:** kropath-aws
**Files:** `rgds/snstopic.aws.kropath.run.yaml`, `rgds/sqsqueue.aws.kropath.run.yaml`

> **Point-in-time disclaimer:** This log records the author's understanding at the time of writing.
> Claims here may later be superseded by updated findings in `docs/frequent-rgd-errors.md` or
> subsequent troubleshooting logs. Verify mechanically before acting on any claim.

---

## Symptom

Deleting an `SNSTopic` (and, latently, an `SQSQueue`) instance hangs forever. The instance sits
in `DELETING` with `kro.run/finalizer` still attached. kro retries continuously with:

```
ERROR dynamic-controller Error syncing item, requeuing with rate limit
  error: includeWhen dependency "naming" not ready: node "naming":
         no observed state: waiting for readiness (data pending)
```

The only recovery is stripping the finalizer manually. Because the name stays taken, ArgoCD cannot
recreate the instance on the next sync.

---

## Root Cause

The `naming` node in both RGDs is a ConfigMap that is **owned by the parent resource** (via
`ownerReferences` with `blockOwnerDeletion: true`). During deletion, Kubernetes begins deleting
the ConfigMap simultaneously with the resource. kro needs to evaluate `includeWhen` expressions
to determine which variant nodes exist and should be deleted — but those expressions reference
`naming.data.*`, and the ConfigMap has no observed state while being deleted.

The pattern that triggers this:
```yaml
includeWhen:
  - '${!naming.data.resourceName.contains("{") && ... && naming.data.hasFeedback == "true" ...}'
```

`naming` is a **graph-internal node**; its observed state is unavailable during teardown.
`rsrcCfg` (SQSConfig/SNSConfig), `policyDoc` (PolicyDocument), `topicPolicyCr`
(PolicyDocument), and `dlqNaming` (DLQ's naming ConfigMap) are all **externalRefs** — they are
not owned by the resource being deleted and remain queryable throughout the lifecycle.

The issue grew over multiple tickets: KRO-260 → KRO-905 → KRO-911 → KRO-915, each adding more
gated variants to avoid AWS rejecting empty attributes.

---

## What Was Tried

### Approach 1 (Succeeded): Inline the gate expressions in `includeWhen`

Replace every `naming.data.*` reference in `includeWhen` with the equivalent CEL expression
derived from `schema.spec` and `rsrcCfg.*` (both always available during teardown):

**SNS** — 12 variants, three replacement types:
- `naming.data.resourceName.contains("{")` → inlined resourceName computation + `.contains("{")`
- `naming.data.hasFeedback == "true/false"` → inlined OR across all delivery-feedback fields
- `naming.data.hasAnyFeedbackARN == "true/false"` → inlined OR across ARN-only fields

**SQS** — 16 variants, three replacement types:
- `naming.data.hasKms == "true/false"` → inlined encryptionType resolution expression
- `naming.data.hasPolicyAttr == "true/false"` → `schema.spec.queuePolicyRef != "" && policyDoc.size() > 0`
- `naming.data.hasRedrivePolicy == "true/false"` → `schema.spec.redrivePolicy.deadLetterTargetRef != "" && dlqNaming.size() > 0 && rsrcCfg.size() > 0`

The `naming` ConfigMap itself is retained (it's still used for `status.resourceName`,
`status.namingStatus`, and `spec.name`/`spec.queueName` inside `template:` blocks — those
references are fine because they are inside `template:`, not `includeWhen`).

Both RGDs reach `Active` after the fix. Verified with the delete-apply-loop gate.

---

## Key Pattern

**`includeWhen` must only reference:**
- `schema.spec.*` — always available
- externalRef nodes (rsrcCfg, topicPolicyCr, policyDoc, dlqNaming) — not owned, not deleted with the resource
- `schema.metadata.*` — always available

**`includeWhen` must NOT reference:**
- `template:` nodes (ConfigMaps, ACK CRs, or any resource with `ownerReferences` pointing to the parent) — these are graph-internal and have no observed state during teardown

The same graph-internal node can safely be referenced inside `template:` blocks (where kro needs
it only when the resource is being created/updated, not when deleted) — just not in `includeWhen`.

---

## Annotation Size Note

The SNS RGD (143.9KB) exceeds the 262144-byte limit that `kubectl apply` imposes on the
`kubectl.kubernetes.io/last-applied-configuration` annotation after the `includeWhen` expressions
were inlined. Use server-side apply for large RGDs:

```bash
kubectl apply --server-side --field-manager=kropath-agent -f rgds/snstopic.aws.kropath.run.yaml
```

This does not apply to the SQS RGD (138.4KB after fix), which still fits within the annotation
limit using standard `kubectl apply`.
