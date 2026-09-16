# 2026-09-17 — S3Bucket lifecycle rules emitting zero-valued actions (KRO-1109)

PR: feat(KRO-1109): fix S3Bucket RGD to not emit zero-valued lifecycle/cors/notification/IT fields

---

> **Point-in-time disclaimer:** This log records what the author believed at the time of writing.
> Verify any code patterns mechanically before relying on them. See §"Knowledge source precedence"
> in the Implementer agent instructions.

## Root Cause

kro v0.9.2 materializes all `default=X` values from the RGD schema into every stored instance.
When a user sets only `abortIncompleteMultipartUpload: {daysAfterInitiation: 7}` on a lifecycle
rule, kro stores the full `S3LifecycleRule` struct with zero values for every other field:
`expiration.days: 0`, `expiration.expiredObjectDeleteMarker: false`, `filter.prefix: ""`,
`filter.tag.key: ""`, etc.

The original (broken) CEL `schema.spec.lifecycle.sortBy(x, x.id)` forwarded this full struct
to ACK. ACK s3-controller v1.9.0's `newLifecycleConfiguration` in `sdk_file_end.go` copies every
non-nil pointer, so AWS S3 received `Expiration{Days:0}` and `Filter{Prefix:"", Tag{Key:"",Value:""}}`.
S3 API rejects both (Days must be positive; Filter must have exactly one of Prefix/Tag/And).

## Fix Approach

Replaced the passthrough `sortBy(x, x.id)` with `transformList` building only the meaningful
fields of each lifecycle rule in CEL.

### Why v1 (nested ternaries) failed

```cel
rule.expiration.days > 0
  ? {"expiration": {"days": rule.expiration.days}}
  : (rule.expiration.expiredObjectDeleteMarker
      ? {"expiration": {"expiredObjectDeleteMarker": true}}
      : {})
```

kro's ternary type-checker requires both branches to have IDENTICAL types. The true branch
`{"expiration": {"days": N}}` is `map(string, map(string, int))` while the false branch
`{"expiration": {"expiredObjectDeleteMarker": true}}` is `map(string, map(string, bool))`.
These are different map(string, ?) types → type mismatch error.

### Why v2 (split `.merge()` chains) failed

Splitting each action into a separate `.merge()` call avoids the ternary type issue, but
kro's `.merge()` requires both operands to have the SAME map type throughout.

The base map `{"id": rule.id, "status": rule.status}` is `map(string, string)`. Merging with
`{"expiration": {"days": N}}` (which is `map(string, map(string, int))`) fails because the
value types differ: `string ≠ map(string, int)`.

Error example:
```
found no matching overload for 'merge' applied to 'map(string, string).(map(string, map(string, int)))'
```

### v3 Fix: `dyn()` to produce `map(string, dyn)`

**Key insight from `docs/troubleshooting-logs/2026-08-04-elb-suite-ci-failures.md`:** wrapping
a value in `dyn()` makes the containing map literal `map(string, dyn)`. A `map(string, dyn)`
can be merged with any other `map(string, dyn)` regardless of what the values actually are.

Specifically, when a map literal has mixed value types (e.g., string + int, or string + dyn),
CEL's type inference produces `map(string, dyn)` instead of a concrete `map(string, string)`.

**Implementation:**

```cel
{"id": dyn(rule.id), "status": rule.status}           ← wrapping one value → map(string, dyn)
.merge(rule.expiration.days > 0
  ? {"expiration": dyn({"days": rule.expiration.days})} ← value wrapped → map(string, dyn)
  : {})
.merge(rule.expiration.days == 0 && rule.expiration.expiredObjectDeleteMarker
  ? {"expiration": dyn({"expiredObjectDeleteMarker": true})}
  : {})
.merge(rule.filter.prefix != "" && rule.filter.tag.key == ""
  ? {"filter": dyn({"prefix": rule.filter.prefix})}
  : {})
.merge(rule.filter.tag.key != ""
  ? {"filter": dyn({"tag": dyn({"key": rule.filter.tag.key, "value": rule.filter.tag.value})})}
  : {})
.merge(rule.noncurrentVersionExpiration.noncurrentDays > 0
  ? {"noncurrentVersionExpiration": dyn({"noncurrentDays": rule.noncurrentVersionExpiration.noncurrentDays})}
  : {})
.merge(rule.abortIncompleteMultipartUpload.daysAfterInitiation > 0
  ? {"abortIncompleteMultipartUpload": dyn({"daysAfterInitiation": rule.abortIncompleteMultipartUpload.daysAfterInitiation})}
  : {})
.merge(rule.transitions.size() > 0
  ? {"transitions": dyn(rule.transitions)}
  : {})
.merge(rule.noncurrentVersionTransitions.size() > 0
  ? {"noncurrentVersionTransitions": dyn(rule.noncurrentVersionTransitions)}
  : {})
```

The same `dyn()` pattern was applied to CORS rules (`maxAgeSeconds: int` merge), notification
configurations (filter sub-object merge), and intelligentTiering (filter merge).

## Negative Assertions

Added `script:` steps after each of the three existing lifecycle test steps (P2-01, P2-02, P2-03)
that use `kubectl get ... -o jsonpath | jq -e 'has(...) | not'` to assert the absence of
zero-valued fields in the rendered ACK Bucket. Declarative `assert:` blocks use partial-match
semantics and cannot verify field absence — `script:` with jq is required for negative assertions.

## S3 API Error — Observed on Integration Cluster (AC-1)

A real S3 API error confirming S3 rejects the zero-valued lifecycle payload was observed on the
`kind-kropath-aws-integration-test` cluster:

**ACK Bucket:** `central-logging` in namespace `platform-shared-test`
**AWS resource:** `arn:aws:s3:::central-logging-ap-southeast-2` (account `283209026888`, region `ap-southeast-2`)
**Error timestamp:** `2026-09-16T14:25:53Z` (4 seconds after bucket creation)
**S3 API response:**
```
api error MalformedXML: The XML you provided was not well-formed or did not validate against our published schema
```

This was observed by reading the ACK Bucket conditions:
```bash
kubectl get buckets.s3.services.k8s.aws central-logging -n platform-shared-test \
  --context kind-kropath-aws-integration-test \
  -o jsonpath='{.status.conditions}' | jq .
```
Output:
```json
[
  {
    "message": "api error MalformedXML: The XML you provided was not well-formed or did not validate against our published schema",
    "status": "True",
    "type": "ACK.Terminal"
  },
  {
    "lastTransitionTime": "2026-09-16T14:25:53Z",
    "message": "Resource not synced",
    "reason": "resource is in terminal condition",
    "status": "False",
    "type": "ACK.ResourceSynced"
  }
]
```

The `MalformedXML` error confirms S3 does NOT accept or normalise the zero-valued payload —
it rejects it outright. The conditional branch in the issue plan ("If S3 accepts and normalises
the payload, downgrade to drift check") is closed: the error is terminal, not a warning.

**Note on direct CLI verification:** AWS CLI credentials were expired during this session
(`ExpiredToken` returned by `aws sts get-caller-identity`). The integration cluster evidence
above was collected from an existing ACK-managed Bucket that was created when the pre-fix RGD
was active. A dedicated `aws s3api put-bucket-lifecycle-configuration` repro call was not
possible in this session; the integration cluster evidence is the recorded AC-1 confirmation.

## Verification

`cd tests && make test-s3` → all steps PASS, including OK P2-01, OK P2-02, OK P2-03 for the
lifecycle negative assertions. RGD reached `Active` on first apply with the v3 fix.

Additional negative assertions added in review response (2026-09-17):
- P2-04b: zero `maxAgeSeconds` correctly absent from corsRules
- P2-06b: zero `filter` correctly absent from queueConfigurations (SQS)
- P2-07b: zero `filter` correctly absent from topicConfigurations (SNS)
- P2-08b: zero `filter` correctly absent from intelligentTiering
