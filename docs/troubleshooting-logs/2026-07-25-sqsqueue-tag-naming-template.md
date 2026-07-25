# KRO-238: SQS Queue {tag.X} Dynamic Naming Template Support

**Date:** 2026-07-25
**Resource:** `sqsqueue.aws.kropath.run`
**Ticket:** KRO-238

---

## Problem

SQS Queue RGD (`rgds/sqsqueue.aws.kropath.run.yaml`) did not support `{tag.X}` tokens in `namingTemplate`. The naming ConfigMap only applied static `{namespace}`, `{name}`, `{account_id}`, `{region}`, and `{configRef}` substitutions. Any `{tag.env}` or similar token in the template was passed through verbatim, causing invalid names and `namingStatus: invalid-unresolved-tokens`.

---

## Pattern Applied (from KRO-237/KMSKey)

Follows the same 9-tier `{tag.X}` resolution pattern as KMSKey (KRO-237), with `has()` guards on `mandatory`/`defaults` sub-objects for defensive safety (IAM/KMS style, KRO-236/237).

### SQS-specific complication vs KMS

KMS has only one field in its naming ConfigMap (`effectiveName`). SQS has **three**:
- `effectiveName` — base name with `{tag.X}` substitution and static replaces
- `resourceName` — `effectiveName + ".fifo"` suffix when `spec.fifo == true`
- `namingStatus` — `"valid"` or `"invalid-unresolved-tokens"` based on whether `{` remains after substitution

Each field requires a different outer paren structure in CEL:

| Field | CEL outer structure | Outer paren count |
|-------|---------------------|-------------------|
| `effectiveName` | `${(name_chain)}` | 1 |
| `resourceName` | `${((name_chain) + (fifo_suffix))}` | 2 |
| `namingStatus` | `${((name_chain) + (fifo_suffix)).contains("{") ? "..." : "valid"}` | 2 |

### Outer paren trap

The CEL `${}` block requires balanced parentheses. The `namingStatus` field originally had 3 opening parens `${(((` but only 2 closing parens — causing `parse error: missing ')' at '<EOF>'` on `kubectl apply`.

**Fix:** Changed `${(((schema.spec.nameOverride` to `${((schema.spec.nameOverride` (removed one `(`).

After the fix: `kubectl get rgd sqsqueue.aws.kropath.run` shows `STATE: Active, READY: True`.

### CEL structure

All three naming fields use:

1. **Template selection** (3-tier): `mandatory.namingTemplate` > `defaults.namingTemplate` > `{namespace}-{name}`
2. **Tag token resolution** (9-tier inside transformList): for each `{tag.X}` split segment, extract key = `part.split("}")[0]`, resolve in cascade order:
   - `mandatory.tags` > `mandatory.syncedLabels` > `mandatory.syncedAnnotations`
   - `spec.tags` > `spec.syncedLabels` > `spec.syncedAnnotations`
   - `defaults.tags` > `defaults.syncedLabels` > `defaults.syncedAnnotations`
   - If absent in all tiers: preserve verbatim as `{tag.KEY}` (detected by `contains("{")`)
3. **Tail re-attachment**: `+ (size(part.split("}")) > 1 ? part.split("}").slice(1, ...).join("}") : "")`
4. **Static replacements**: `.replace("{name}", ...)`, `.replace("{namespace}", ...)`, etc.

---

## namingStatus location

Unlike KMSKey (which computes `namingStatus` in the status block from `naming.data.effectiveName.contains("{")`), SQSQueue computes `namingStatus` **inside the naming ConfigMap data** and the status block reads from it:

```yaml
# In naming ConfigMap data:
namingStatus: >-
  ${((name_chain) + (fifo_suffix)).contains("{") ? "invalid-unresolved-tokens" : "valid"}

# In SQSQueue spec.schema.status:
namingStatus: >-
  ${naming.data.namingStatus}
```

The `contains("{")` check applies to the full `resourceName` string (including `.fifo` suffix if applicable), so that any unresolved brace in the complete resource identifier is detected.

---

## Chainsaw tests added (KRO-238)

Four new steps appended to `tests/sqs/sqsqueue/chainsaw-test.yaml`:

| Step | Scenario | Expected outcome |
|------|----------|------------------|
| `kro238-tag-token-resolved-from-spec-tags` | `defaults.namingTemplate: "{tag.env}-{name}"`, `spec.tags.env: prod` | `resourceName: prod-kro238-tag-queue`, `namingStatus: valid` |
| `kro238-tag-token-unresolved-invalid-status` | Same template, no `spec.tags` | `namingStatus: invalid-unresolved-tokens` |
| `kro238-mandatory-tag-overrides-spec-tag` | `mandatory.namingTemplate: "{tag.env}-{name}"`, `mandatory.tags.env: corp`, `spec.tags.env: dev` | `resourceName: corp-kro238-mandatory-queue` (mandatory wins) |
| `kro238-tag-token-fifo-suffix` | `defaults.namingTemplate: "{tag.env}-{name}"`, `spec.tags.env: prod`, `fifo: true` | `resourceName: prod-kro238-fifo-queue.fifo`, `namingStatus: valid` |

All four pass in `chainsaw test sqs/sqsqueue/` (confirmed 2026-07-25). Full suite: 36 steps, 0 failures.
