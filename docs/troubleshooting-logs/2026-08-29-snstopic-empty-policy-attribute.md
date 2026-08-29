# 2026-08-29 — SNSTopic RGD emits empty `policy` attribute, AWS rejects with 'Policy is empty'

> **Point-in-time disclaimer**: This log records observations and conclusions made on 2026-08-29.
> Claims about runtime or AWS API behaviour are hypotheses confirmed against available evidence at
> that time; verify mechanically before acting on them in a new context.

## Symptom

Every `SNSTopic` with `spec.topicPolicyRef: ''` (empty/unresolved) landed in `ACK.Terminal`:

    Type:    ACK.Terminal
    Message: InvalidParameter: Policy is empty

The ACK Topic CR `spec.policy` was `""` (empty string). AWS validates every SNS Attribute value
and rejects an empty `Policy` attribute outright.

## Root cause

`rgds/snstopic.aws.kropath.run.yaml` used a CEL ternary on the `ackTopic` resource:

```yaml
policy: >-
  ${topicPolicyCr.size() > 0
    ? topicPolicyCr[0].spec.documentJSON
    : ""}
```

The `else` branch emitted `""`. ACK forwards every spec field to AWS as an SNS Attribute verbatim
— including empty strings. AWS rejects `Policy=""` with `InvalidParameter: Policy is empty`.

The same class of bug was documented in `2026-08-28-sns-sqs-empty-string-fifo-attributes.md` for
FIFO attributes; the fix pattern is identical.

## Fix applied

Split the single `ackTopic` resource into two variants using `includeWhen`:

- `ackTopicWithPolicy` — includes `policy: ${topicPolicyCr[0].spec.documentJSON}`, active when
  `topicPolicyCr.size() > 0`.
- `ackTopicNoPolicy` — omits the `policy` field entirely, active when `topicPolicyCr.size() == 0`.

Status block updated to fan out to the active variant:

```yaml
topicArn: >-
  ${topicPolicyCr.size() > 0
    ? ackTopicWithPolicy.?status.?topicARN.orValue("")
    : ackTopicNoPolicy.?status.?topicARN.orValue("")}
conditions: >-
  ${ackTopicNoPolicy.?status.?conditions.orValue([])}
```

**CEL type trap encountered:** kro's strict ternary type alignment assigns different internal type
names to lists from different resource nodes:
- `list(__type_ackTopicWithPolicy.status.conditions.@idx)`
- `list(__type_ackTopicNoPolicy.status.conditions.@idx)`

Both ternary (`_?_:_`) and list concatenation (`_+_`) fail when the two branches have different
internal list element types — even if the CRD types are structurally identical. To avoid this, the
`conditions` status field references only `ackTopicNoPolicy`. When the with-policy variant is
active, `conditions` returns `[]` in the SNSTopic status (minor observability tradeoff — ACK Topic
conditions are still accessible via `kubectl get topic`). No tests assert SNSTopic `status.conditions`.

## Verification gate

RGD reached `Active` in one round after delete+apply.

Chainsaw suite: `cd tests && make test-sns` — all scenarios PASS, including the new script
assertion in `ac17-no-topic-policy` that confirms `spec.policy` is absent from the ACK Topic CR.

## Key principle

**Empty string is NOT omission in ACK.** Use `includeWhen` template splitting to completely omit
a field for one code path. A ternary that emits `""` as the else branch is not equivalent to
omitting the field.

**CEL list type incompatibility across resource nodes:** When two resource nodes provide the same
CRD field (e.g. `status.conditions`), kro assigns distinct internal type names per node. Ternary
and `+` concatenation between these lists both fail with `found no matching overload`. Reference
only one resource node for such fields, or accept that the field is empty when that node is
excluded.
