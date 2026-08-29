# Troubleshooting Log: SNS Topic — Empty Delivery Feedback Attributes (KRO-911)

**Date:** 2026-08-29
**Author:** Implementer
**Ticket:** KRO-911
**Repo:** kropath-aws
**File:** `rgds/snstopic.aws.kropath.run.yaml`

> **Point-in-time disclaimer:** This log records the author's understanding at the time of writing.
> Claims here may later be superseded by updated findings in `docs/frequent-rgd-errors.md` or
> subsequent troubleshooting logs. Verify mechanically before acting on any claim.

---

## Symptom

SNS Topics created when no delivery feedback is configured fail with an `ACK.Terminal` condition:

```
InvalidParameter: Invalid parameter: Attributes Reason:
ApplicationSuccessFeedbackSampleRate: value provided is not an integer between 0-100
```

The error surfaces on a real ACK controller + AWS environment, not in Chainsaw tests (which do not
exercise the real SNS API).

---

## Root Cause

The RGD's ACK Topic templates included 15 delivery-feedback fields (5 protocols × 3 fields each)
using three-tier cascade CEL expressions that fell back to `""` when no tier configured a value.

ACK forwards **every** field present in a Topic CR's `spec` to the SNS `CreateTopic` / `SetTopicAttributes`
API verbatim as SNS Attribute key-value pairs. AWS validates `*SampleRate` attributes as integers
between 0-100. An empty string `""` fails that validation and returns `InvalidParameter`.

This is the same class of bug documented in:
- `2026-08-28-sns-sqs-empty-string-fifo-attributes.md` (FIFO attributes emitting `"false"` / `""`)
- `2026-08-29-snstopic-empty-policy-attribute.md` (policy field emitting `""` when not configured)

The key principle: **empty string `""` is NOT omission in ACK**. Any field present in spec — even
`""` — is forwarded to AWS as an SNS Attribute.

---

## Failed Approaches

**Approach 1 — Check `has()` in the CEL condition**

Considered checking `has(rsrcCfg[0].status.effectiveConfig.mandatory.deliveryFeedback)` but this is
insufficient: the existing test effectiveConfig patches include `deliveryFeedback` present in the
status with all-empty-string values (the controller always materialises the full struct). So `has()`
returns `true` even when all 15 field values are `""`.

---

## Fix

Split the two existing ACK Topic templates (with/without policy, from KRO-905) into four:

| Template ID | includeWhen |
|---|---|
| `ackTopicWithPolicyWithFeedback` | naming valid AND policy CR found AND hasFeedback=="true" |
| `ackTopicWithPolicyNoFeedback` | naming valid AND policy CR found AND hasFeedback=="false" |
| `ackTopicNoPolicyWithFeedback` | naming valid AND no policy CR AND hasFeedback=="true" |
| `ackTopicNoPolicyNoFeedback` | naming valid AND no policy CR AND hasFeedback=="false" |

The `hasFeedback` field is computed in the `naming` ConfigMap. It evaluates to `"true"` when ANY
of the 45 field values (15 fields × mandatory tier + defaults tier + instance spec) is non-empty,
and `"false"` otherwise.

The "no feedback" variants omit all 15 delivery-feedback fields entirely from the ACK Topic spec,
so ACK never forwards them as SNS Attributes.

The CEL expression in `hasFeedback` uses `.orValue("")` (optional chaining) rather than `has()`
to safely handle cases where the `deliveryFeedback` key or any nested protocol key is absent:

```cel
(rsrcCfg.size() > 0 && rsrcCfg[0].status.effectiveConfig.mandatory.?deliveryFeedback.?http.?successFeedbackSampleRate.orValue("") != "") ||
# ... (all 45 conditions)
? "true" : "false"
```

**Why not use `has()` per field:** The effectiveConfig status always materialises the full
`deliveryFeedback` struct (all 5 protocols, all 3 fields each) with `""` as the empty sentinel.
`has()` would always return `true` for these paths even when values are empty.

**Status block update:** `topicArn` fans across all 4 variants using a nested ternary:
```
topicArn: ${topicPolicyCr.size() > 0
  ? (naming.data.hasFeedback == "true"
      ? ackTopicWithPolicyWithFeedback.?status.?topicARN.orValue("")
      : ackTopicWithPolicyNoFeedback.?status.?topicARN.orValue(""))
  : (naming.data.hasFeedback == "true"
      ? ackTopicNoPolicyWithFeedback.?status.?topicARN.orValue("")
      : ackTopicNoPolicyNoFeedback.?status.?topicARN.orValue(""))}
```

`conditions` continues to reference only `ackTopicNoPolicyNoFeedback` (the most common path;
referencing multiple list-type status fields across different resource nodes causes a CEL type
conflict — see `2026-08-29-snstopic-empty-policy-attribute.md`).

---

## Test Changes

Added a `script` step to `ac15-feedback-none` in `tests/sns/snstopic/chainsaw-test.yaml` that
verifies all 15 delivery-feedback fields are absent from the ACK Topic spec when no delivery
feedback is configured. Uses `jq` with `if has($f)` to detect field presence.

---

## CEL/YAML Patterns Confirmed

- `?field.?nested.orValue("")` safely navigates optional struct paths without `has()`.
- Four-template split via `hasFeedback` in the naming ConfigMap is the correct pattern for
  conditionally omitting an entire block of ACK Topic fields.
- Checking for non-empty VALUES (not just key presence) is essential when the upstream controller
  materialises full struct skeletons with empty-string sentinels.
