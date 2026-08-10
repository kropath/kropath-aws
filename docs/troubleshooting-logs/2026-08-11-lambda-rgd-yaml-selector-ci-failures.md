# Lambda RGD CI Failures: YAML Parse Errors + externalRef.selector Placement

**Date:** 2026-08-11  
**Ticket:** KRO-540  
**Symptom:** Chainsaw E2E Tests CI job failed with two error types during `make setup`:

## Error Type 1: YAML Parse Errors (3 files)

```
error parsing rgds/lambdaeventsourcemapping.aws.kropath.run.yaml: error converting YAML to JSON: yaml: line 108: mapping values are not allowed in this context
error parsing rgds/lambdafunction.aws.kropath.run.yaml: error converting YAML to JSON: yaml: line 244: mapping values are not allowed in this context
error parsing rgds/lambdaversion.aws.kropath.run.yaml: error converting YAML to JSON: yaml: line 104: mapping values are not allowed in this context
```

### Root Cause

YAML plain scalars cannot contain `: ` (colon followed by space) because that signals the start of a mapping value. Unquoted CEL ternary expressions like:
```yaml
key: ${someField != "" ? someField : "fallback-value"}
```
contain `: "fallback-value"` which YAML misparses as a nested mapping entry.

### Fix

Single-quote all inline CEL ternary expressions that contain `: ` inside them:
```yaml
key: '${someField != "" ? someField : "fallback-value"}'
```

**Affected expressions fixed:**
- `lambdaeventsourcemapping` line 108: `functionRef` sentinel fallback
- `lambdafunction` line 258: `packageType` default "Zip"
- `lambdafunction` line 319: `ipv6AllowedForDualStack` boolean default
- `lambdafunction` line 335: `ephemeralStorageSize` integer default
- `lambdaversion` line 104: `functionRef` sentinel fallback

Note: expressions inside `>-` block scalars are NOT affected — YAML treats the entire block as a string. Only inline scalar values need quoting.

## Error Type 2: Unknown field `externalRef.selector` (4+ files)

```
Error from server (BadRequest): strict decoding error: unknown field "spec.resources[0].externalRef.selector"
```

### Root Cause

All 7 lambda RGDs had `selector:` as a sibling of `metadata:` at the `externalRef` level:
```yaml
externalRef:
  apiVersion: ...
  kind: ...
  metadata:
    namespace: ${schema.metadata.namespace}
  selector:              # ← WRONG: sibling of metadata
    matchLabels:
      aws.kropath.run/resource-name: ...
```

The kro v0.9.2 API requires `selector` to be **nested under** `metadata`:
```yaml
externalRef:
  apiVersion: ...
  kind: ...
  metadata:
    namespace: ${schema.metadata.namespace}
    selector:            # ← CORRECT: nested under metadata
      matchLabels:
        aws.kropath.run/resource-name: ...
```

### Fix

Moved all `selector:` blocks to be under `metadata:` (added 2 spaces of indentation to `selector:`, `matchLabels:`, and the label key).

**Affected files:** all 7 lambda RGDs (lambdaalias, lambdacodesigningconfig, lambdaeventsourcemapping, lambdafunction, lambdafunctionurlconfig, lambdalayerversion, lambdaversion).

## Prevention

1. **Always single-quote inline CEL ternary expressions** — if the expression contains `? A : B`, it must be quoted in YAML.
2. **`selector` belongs under `metadata` in `externalRef`** — confirmed by working examples in `sqsqueue.aws.kropath.run.yaml`, `docs/frequent-rgd-errors.md`, and `docs/STANDARDS.md`.
