# KRO-237: KMS Key {tag.X} Dynamic Naming Template Support

**Date:** 2026-07-25
**Resource:** `kmskey.aws.kropath.run`
**Ticket:** KRO-237

---

## Problem

KMS Key RGD (`rgds/kmskey.yaml`) did not support `{tag.X}` tokens in `namingTemplate`.
The naming ConfigMap only applied static `{namespace}`, `{name}`, `{account_id}`, `{region}`, and `{configRef}` substitutions. Any `{tag.env}` or similar token in the template was passed through verbatim, producing unresolved names that caused `namingStatus: invalid-unresolved-tokens`.

---

## Pattern Applied (from KRO-235/S3Bucket)

The S3Bucket RGD (`rgds/s3bucket.yaml`) established the canonical 9-tier `{tag.X}` resolution pattern in KRO-235. KMS Key follows the same pattern with one addition: IAM-style `has()` guards around `mandatory`/`defaults` sub-object access.

### Why `has()` guards

The S3Bucket pattern accesses `rsrcCfg[0].status.effectiveConfig.mandatory.tags` directly (without `has()`). This is safe when the controller always writes both tiers. The KMS Key implementation adds `has(rsrcCfg[0].status.effectiveConfig.mandatory)` and `has(rsrcCfg[0].status.effectiveConfig.defaults)` guards for defensive safety, matching the IAM RGD style introduced in KRO-236.

### CEL structure

The `effectiveName` field uses `.split("{tag.")` → `.transformList(i, part, ...)` → `.join("")` → static `.replace()` chain:

1. **Template selection** (3-tier): mandatory.namingTemplate > defaults.namingTemplate > `{namespace}-{name}`
2. **Tag token resolution** (9-tier inside transformList): for each segment after index 0, extract key = `part.split("}")[0]`, resolve in order:
   - `mandatory.tags` > `mandatory.syncedLabels` > `mandatory.syncedAnnotations`
   - `spec.tags` > `spec.syncedLabels` > `spec.syncedAnnotations`
   - `defaults.tags` > `defaults.syncedLabels` > `defaults.syncedAnnotations`
   - If absent in all tiers: preserve verbatim as `{tag.KEY}`
3. **Tail re-attachment**: `+ (size(part.split("}")) > 1 ? part.split("}").slice(1, ...).join("}") : "")`
4. **Static replacements**: `.replace("{namespace}", ...)`, `.replace("{name}", ...)`, etc.

### Outer paren trap

The `effectiveName` expression uses `${(...)}`  — the outer `(` after `${` needs a matching `)` before the closing `}`.

```yaml
effectiveName: >-
  ${(schema.spec.nameOverride != "" ? ... : ...)
    .split(...)
    .join("")
    .replace(...)
    .replace("{configRef}", schema.spec.configRef))}
#                                               ^ outer ) closes the ${( paren
```

**Symptom when missing:** kro reports `parse error: missing ')' at '<EOF>'` on `kubectl apply -f rgds/kmskey.yaml`.

**Fix:** The last `.replace(...)` line must end with `)}` not `}` alone.

---

## namingStatus location

`namingStatus` is computed in the **status block**, not in the ConfigMap `data`:

```yaml
status:
  namingStatus: >-
    ${naming.data.effectiveName.contains("{") ? "invalid-unresolved-tokens" : "valid"}
```

The naming ConfigMap stores only `effectiveName`. If a `{tag.X}` token is unresolved (key absent in all tiers), it remains in the string as `{tag.KEY}`, which `contains("{")` detects.

---

## Stale CRD issue

After changing the RGD schema (adding/removing fields), the old CRD remains registered.
Run `kubectl delete crd kmskeys.aws.kropath.run` to force kro to re-derive the CRD from the updated RGD. Without this step, the API server rejects instances conforming to the new schema because the CRD still enforces the old schema.

---

## Chainsaw tests added (KRO-237)

Three new steps in `tests/kms/kmskey/chainsaw-test.yaml`:

| Step | Scenario | Expected outcome |
|------|----------|------------------|
| `kro237-tag-token-resolved-from-spec-tags` | `defaults.namingTemplate: "{tag.env}-{name}"`, `spec.tags.env: prod` | `effectiveName: prod-kro237-tag-key`, `namingStatus: valid` |
| `kro237-tag-token-unresolved-invalid-status` | Same template, no `spec.tags` | `namingStatus: invalid-unresolved-tokens` |
| `kro237-mandatory-tag-overrides-spec-tag` | `mandatory.namingTemplate: "{tag.env}-{name}"`, `mandatory.tags.env: corp`, `spec.tags.env: dev` | `effectiveName: corp-kro237-mandatory-key` (mandatory wins) |

All three pass in `make test-kms` (confirmed 2026-07-25).
