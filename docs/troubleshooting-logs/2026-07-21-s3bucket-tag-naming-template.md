# KRO-235: {tag.X} Dynamic Naming Template Tokens — S3Bucket RGD

**Date:** 2026-07-21
**Issue:** KRO-235
**Scope:** `rgds/s3bucket.yaml` only (exploration limited to S3Bucket RGD per ticket scope)

## Problem

The `namingTemplate` field supported static substitution tokens (`{namespace}`, `{name}`,
`{account_id}`, `{region}`, `{configRef}`) but had no mechanism to resolve values from resource
tags, synced labels, or synced annotations at runtime.

The goal was to explore whether tokens like `{tag.productID}`, `{tag.team}`, `{tag.environment}`
could be resolved from `spec.tags`, `spec.syncedLabels`, or `spec.syncedAnnotations` at runtime.

## Approach: Naming ConfigMap pattern

Adopted the same pattern as `sqsqueue.aws.kropath.run.yaml`:

1. Add a `naming` ConfigMap resource between `rsrcCfg` and `bucket` in the resource graph.
2. The ConfigMap computes `effectiveName` with full `{tag.X}` resolution in its CEL expression.
3. `bucket.spec.name`, `status.resourceName`, `status.namingStatus`, and `status.predictedArn`
   all reference `naming.data.effectiveName`.

## What failed: `map.?[dynamicKey]` syntax

The `kropath-rgd-patterns` skill shows `mergedTags.?[part.split("}")[0]].orValue(...)`.

kro v0.9.2 **does NOT support** dynamic optional bracket access `map.?[expr]` when the key is
a runtime expression. Only struct field optional access with a literal identifier (`struct.?field`)
is supported.

Error from kro:
```
GraphAccepted: False - parse error: ERROR: <input>:20:12:
  Syntax error: extraneous input '[' expecting {IDENTIFIER, ESC_IDENTIFIER}
   |         ).?[part.split("}")[0]].orValue("{tag." + part.split("}")[0] + "}")
```

## What works: `(key in map ? map[key] : default)`

Replaced the optional bracket access with standard CEL `in` operator:

```cel
(rsrcCfg.size() > 0 && part.split("}")[0] in rsrcCfg[0].status.effectiveConfig.mandatory.tags
    ? rsrcCfg[0].status.effectiveConfig.mandatory.tags[part.split("}")[0]]
    : (part.split("}")[0] in schema.spec.tags
        ? schema.spec.tags[part.split("}")[0]]
        : ...
            : "{tag." + part.split("}")[0] + "}"))
```

This is verbose but is entirely standard CEL with no extensions required.

## CEL functions confirmed supported in kro v0.9.2

| Function | Supported |
|---|---|
| `string.split(delim)` | Yes |
| `list.transformList(i, item, expr)` | Yes |
| `list[index]` | Yes |
| `size(list)` | Yes |
| `list.slice(start, end)` | Yes |
| `list.join(sep)` | Yes |
| `key in map` | Yes |
| `map[key]` | Yes |
| `map.?[dynamicExpr]` | **No** — parse error in kro v0.9.2 |

## Resolution cascade

Priority (highest to lowest):
1. `mandatory.tags[key]`
2. `mandatory.syncedLabels[key]`
3. `spec.tags[key]`
4. `spec.syncedLabels[key]`
5. `defaults.tags[key]`
6. `defaults.syncedLabels[key]`
7. verbatim `{tag.KEY}` — causes `namingStatus: invalid-unresolved-tokens`

## Pre-existing stale CRD: delete before first apply

The S3Bucket CRD had `KindReady: False` due to stale schema. Fixed by:
```bash
kubectl delete crd s3buckets.aws.kropath.run
```
Required any time the RGD schema changes.

## s3config ac11 timing fix

`ac11-synced-labels-propagate-through-effectiveconfig` was checking for the ACK Bucket
immediately after creating the S3Bucket. After adding the naming ConfigMap as an intermediate
resource, kro must create `naming` first before `bucket`, so the ACK Bucket takes slightly longer
to appear. Fixed with a 30-second retry loop (15 x 2s) in the test's Python check script.

## Verification

```
status.resourceName:  default-tag-test-bucket-platform   ({tag.team} resolved to "platform")
status.namingStatus:  valid
status.predictedArn:  arn:aws:s3:::default-tag-test-bucket-platform

# missing tag kept verbatim:
status.resourceName:  default-tag-missing-test-{tag.team}
status.namingStatus:  invalid-unresolved-tokens
```

## Chainsaw tests added (KRO-235)

Three new steps in `tests/s3/s3bucket/chainsaw-test.yaml`:

| Step | Verifies |
|---|---|
| `kro235-tag-token-resolved-from-spec-tags` | `{tag.team}` resolves from `spec.tags.team` |
| `kro235-tag-token-unresolved-invalid-status` | missing tag yields verbatim + `invalid-unresolved-tokens` |
| `kro235-mandatory-tag-overrides-spec-tag` | `mandatory.tags.team=admin` overrides `spec.tags.team=dev` |

Full `make test-s3` exits 0.
