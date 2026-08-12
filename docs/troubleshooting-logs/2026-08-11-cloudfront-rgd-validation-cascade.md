# CloudFront RGDs — Repeat CI Timeout Was ACK Type Drift, Not a Race

**Date:** 2026-08-11 (investigation) / 2026-08-12 (written up)
**Issue:** KRO-443 (fixes), KRO-623 (process follow-up)
**PR:** #88 (the fixes themselves — merged 2026-08-12)
**Supersedes the diagnosis in:** `2026-08-05-cloudfront-distribution-missing-types-section.md`

> **Status:** the RGD/test fixes described here are **already on `main` via PR #88**. The Implementer
> converged on equivalent fixes independently, over ~8 CI round-trips. This log exists because the
> *root causes and the traps behind them* were never written down, and because the 2026-08-05 log
> records a **false** root cause that misled two sessions. It is a knowledge record, not a to-do.

## Symptom

`tests/setup.sh` → `kubectl wait rgd --all --for=condition=Ready --timeout=120s` failed, twice:

```
resourcegraphdefinition.kro.run/cloudfrontcachepolicy.aws.kropath.run condition met
timed out waiting for the condition on resourcegraphdefinitions/cloudfrontdistribution.aws.kropath.run
timed out waiting for the condition on resourcegraphdefinitions/cloudfrontfunction.aws.kropath.run
timed out waiting for the condition on resourcegraphdefinitions/cloudfrontoriginaccesscontrol.aws.kropath.run
timed out waiting for the condition on resourcegraphdefinitions/cloudfrontoriginrequestpolicy.aws.kropath.run
timed out waiting for the condition on resourcegraphdefinitions/cloudfrontresponseheaderspolicy.aws.kropath.run
```

## First Correction: Only TWO RGDs Were Broken

The five-name failure list is an artifact of `kubectl wait --all`, which walks resources in **name
order against a single shared 120s deadline**. The first genuinely-broken RGD burns the whole
budget; everything alphabetically after it is reported as "timed out" without being given any time.

Reproduced locally (install CloudFront ACK CRDs + `crds/cloudfrontconfig.yaml`, apply all six RGDs):

| RGD | Real state |
|---|---|
| `cloudfrontcachepolicy` | Active |
| `cloudfrontdistribution` | **Inactive — real bug** |
| `cloudfrontfunction` | **Inactive — real bug** |
| `cloudfrontoriginaccesscontrol` | Active |
| `cloudfrontoriginrequestpolicy` | Active |
| `cloudfrontresponseheaderspolicy` | Active |

The 2026-08-05 log's conclusion that "one broken RGD blocks all others from reaching Active" is
**wrong** and must not be relied on — sibling RGDs reconcile independently. Commit `b4a876b` acted
on that wrong model and "fixed" a symptom that did not exist, introducing a new type error.

`tests/setup.sh` now prints the real diagnosis on failure so this list can never mislead again.

## Root Causes (all ACK target-schema drift, all permanent — no race involved)

Each fix exposed the next validation error; five delete-and-recreate rounds on the distribution RGD
alone.

### 1. `cloudfrontfunction` — `functionCode` string vs bytes

```
type mismatch at path "spec.functionCode": expression "schema.spec.functionCode"
returns type "string" but expected "bytes"
```

ACK types `Function.spec.functionCode` as `string, format: byte`, which kro maps to CEL `bytes`.
KRO-443's own description prescribed `base64.encode(bytes(...))` with a fallback to *"accepting
base64-encoded input if unavailable"* — and commit `5c7a957` implemented that fallback. **The
fallback is impossible**: the type checker rejects a string into a `bytes` field regardless of the
string's content. Pass-through was never an option.

**Fix:** `functionCode: ${bytes(schema.spec.functionCode)}`. The CEL *standard* `bytes(string)`
conversion is available (no cel-go base64 extension needed). Callers supply **plain** source; the
API server base64-encodes on write. Verified end-to-end: input
`"function handler(event) { return event.request; }"` → ACK CR holds base64 that decodes back to it.

### 2. `cloudfrontdistribution` — `customErrorResponses[].responseCode` int vs string

ACK types `responseCode` as `string` (AWS returns the HTTP status as a string); the RGD's
`CloudFrontCustomErrorResponse` type declared `integer | default=0`. **Fix:** `string | default=""`.

### 3. `cloudfrontdistribution` — `.orValue({map literal})` on named-struct fields

Commit `b4a876b` replaced `has(o.s3OriginConfig)` with `o.?s3OriginConfig.orValue({"...":""})`
inside the `origins` `transformList`, producing six compile errors:

```
found no matching overload for 'orValue' applied to
  'optional_type(__type_schema.spec.origins.@idx.s3OriginConfig).(map(string, string))'
found no matching overload for '_?_:_' applied to
  '(bool, __type_schema.spec.origins.@idx.customOriginConfig, map(dyn, dyn))'
```

A nested object of a named RGD type is a **named struct**, not a map; `optional(T).orValue(x)`
requires `x` to be exactly `T`, and no map literal unifies with a named struct. Returning the struct
itself from one ternary branch and `{}` from the other fails for the same reason.

**Fix:** chain `.?` down to a **scalar leaf**, `orValue()` only that scalar, and make every ternary
branch an explicit map literal (`map(string,…)` vs `{}` unifies fine). Also corrected here: ACK's
field is `httpSPort` (capital S), not `httpsPort`.

### 4. `cloudfrontdistribution` — `cacheBehaviors` flat-vs-nested shape

```
list element type incompatible: field "cachedMethods" exists in output but not in expected type
```

`cacheBehaviors: items: ${schema.spec.cacheBehaviors}` passed the flat user-facing
`CloudFrontCacheBehavior` straight through, but ACK nests `allowedMethods.items`,
`allowedMethods.cachedMethods.items`, and `functionAssociations.items`. `defaultCacheBehavior`
already did this mapping field-by-field; the list form was never updated to match.
**Fix:** explicit `transformList` mapping into ACK's nested shape.

### 5. `cacheBehaviors` — 2-arg `transformList` breaks dependency extraction

```
failed to build dependency graph: failed to extract dependencies: references unknown identifiers: [b]
```

kro's identifier walker only recognises the loop variables of the **3-argument**
`transformList(indexVar, valueVar, expr)` form. **Fix:** use the 3-arg form even when the index is
unused.

### 6. Test fixtures — phantom `originType` field

```
strict decoding error: unknown field "spec.origins[0].originType"
```

`originType` was set on 14 origins and one `CloudFrontOriginAccessControl` but defined nowhere. PR
\#88 resolved this by **adding** `originType` to the RGD schema; the alternative (removing it from
the fixtures, since ACK origins have no such field) is also valid.

### 7. Tests patched `status.id` on the kro-owned CR instead of the ACK child

```
* spec.distributionConfig.defaultCacheBehavior.cachePolicyID:
    Invalid value: "": Expected value: "cache-policy-id-abc"
```

The sibling-ref scenarios seeded ids with `kubectl patch cloudfrontcachepolicy … status.id`. But
`status.id` on the kropath CR is **kro-computed** (`${ackCachePolicy.?status.?id.orValue("")}`) —
kro's instance controller overwrites the patch on its next reconcile, so the value silently reverts
to `""`. **Fix:** patch the **ACK child** and let kro propagate upward, bracketed by two asserts —
one before (the child must exist; `- script:` steps never retry) and one after (the parent's
`status.id` must have propagated before the consuming resource reads it).

### 8. Config fixtures set the same field in BOTH `mandatory` and `defaults`

```
CloudFrontConfig.aws.kropath.run "ac1m-cfg" is invalid: <nil>: Invalid value:
  viewerProtocolPolicy must be set in either mandatory or defaults, not both.
```

Fixtures expressed "mandatory overrides defaults" by setting the field non-empty in both spec
tiers — exactly what the CRD's `x-kubernetes-validations` mutual-exclusion rules forbid. The
override belongs in the `status.effectiveConfig` patch (no mutual-exclusion rule there, and it is
what the RGD actually reads). Deliberate rejection tests in the `cloudfrontconfig` suite are the
one exception.

## Latent Bug Fixed Separately (this branch, KRO-623)

`defaultCacheBehavior.allowedMethods` / `cachedMethods` and the `CloudFrontCacheBehavior` type all
defaulted to `[]`. CI was green only because the fixtures set them explicitly — but a caller who
omits them gets an empty AllowedMethods list, which **AWS rejects**. CloudFront's own default is
`["GET","HEAD"]`; both schemas now default to that. Verified the non-empty list default propagates
into the kro-generated CRD.

## Process Lessons (tracked in KRO-623)

* **An RGD template change is not verified until the RGD reaches `Active` in a cluster.** Every fix
  above looked correct on paper and was rejected by kro's type checker. Errors surface one layer at
  a time, so paper reasoning cannot find them.
* **kro re-validates only on re-CREATE.** `kubectl apply` over an unchanged-generation RGD does not
  re-run validation, and a long-failing RGD's backoff caps at ~1000s — the stale message can persist
  ~16 minutes and read as "my fix didn't work". Always `delete` + `apply`.
* **The information was already available.** `kropath-core/docs/crd-cache/aws/cloudfront-controller-v1.6.0.md`
  already recorded `functionCode | byte`, `httpSPort`, and `allowedMethods` as a nested object. More
  documentation would not have prevented this — only a mechanical check would.

## Local-Cluster Artifacts to Rule Out Before Blaming the Code

* `KindReady=False: breaking changes detected: Property X was removed` — a stale kro-generated CRD
  from an earlier branch. Fix: `kubectl delete crd <plural>.aws.kropath.run`. CI starts fresh.
* Child ACK resources never created (`actual resource not found`) — the local kro ClusterRole
  predates the new service. Fix:
  `kubectl apply -f tests/fixtures/rbac/kro-controller.yaml && kubectl rollout restart deployment/kro -n kro-system`.
  Check with `kubectl get clusterrole kro -o yaml | grep -c <service>`.
