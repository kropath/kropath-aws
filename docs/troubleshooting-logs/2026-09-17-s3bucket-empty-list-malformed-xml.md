# 2026-09-17 — S3Bucket RGD emitting empty lifecycle/cors/notification/intelligentTiering lists (KRO-1102)

> **Point-in-time disclaimer:** This log records what the author believed at the time of writing.
> Verify any code patterns mechanically before relying on them. See §"Knowledge source precedence"
> in the Implementer agent instructions.

## Root Cause

The KRO-1109 fix (`transformList` with conditional `.merge()` chains) correctly handled zero-valued
fields WITHIN existing lifecycle/cors/notification/intelligentTiering rules. However, when the S3Bucket
CR has NO rules at all (empty lists), `transformList` on an empty list still returns `[]`.

The ACK S3 controller calls PutBucketCors, PutBucketLifecycleConfiguration,
PutBucketNotificationConfiguration, and PutBucketIntelligentTieringConfiguration even when the
respective fields in the ACK Bucket spec are empty arrays. AWS S3 rejects these with:

```
api error MalformedXML: The XML you provided was not well-formed or did not validate against
our published schema
```

This was observed on the `central-logging` bucket in the `kropath-aws-integration-tests` cluster:
the bucket has no lifecycle/cors/notification/intelligentTiering rules configured, yet the old RGD
rendered `lifecycle: {rules: []}`, `cors: {corsRules: []}`, etc., causing ACK.Terminal.

## Why the KRO-1109 Fix Was Insufficient

The KRO-1109 `transformList` fix:
```cel
${schema.spec.lifecycle.sortBy(x, x.id).transformList(i, rule, ...)}
```
produces `[]` when `schema.spec.lifecycle` is `[]`. The `transformList` call correctly filters zero-valued
fields within each rule, but cannot produce "nothing" from an empty input list.

## Fix

Wrapped each field in a null-ternary pattern following the `website` field's existing approach:

```cel
lifecycle: >-
  ${schema.spec.lifecycle.size() > 0
    ? dyn({"rules": schema.spec.lifecycle.sortBy(x, x.id).transformList(i, rule, ...)})
    : null}
```

When the list is empty, the CEL expression evaluates to `null`. kro v0.9.2 renders this as
`lifecycle: null` in the ACK Bucket CR. The Kubernetes API server accepts `null` for this field
(despite the CRD declaring `nullable: false`) and ACK's Go code receives a nil pointer — it then
skips the `PutBucketLifecycleConfiguration` API call entirely.

Same pattern applied to `cors`, `notification` (wrapping all 3 sub-fields in one `dyn({...})`),
and `intelligentTiering`.

## Note on §10.2 of frequent-rgd-errors.md

§10.2 states "A CEL null is rendered literally — it does not drop the key." This is accurate
(the key IS present in the manifest as `lifecycle: null`), but the claim that "the API server
rejects it" appears to be incorrect for the ACK Bucket CRD fields. The API server accepts null
for these optional object/array fields, and ACK handles null as "skip this feature".

The `? dyn({...}) : null` pattern was already used for the `website` field (added in KRO-1109)
and confirmed to work. This fix extends the same pattern to lifecycle/cors/notification/intelligentTiering.

## Verification

RGD applied to `kind-kropath-aws-test` cluster → reached `Active` on first apply.
ACK Bucket CRs now show `lifecycle: null` (not `lifecycle: {rules: []}`) for buckets with no
lifecycle rules configured.
