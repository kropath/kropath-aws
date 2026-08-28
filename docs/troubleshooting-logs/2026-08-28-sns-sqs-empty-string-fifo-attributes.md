# 2026-08-28 — SNS/SQS empty-string FIFO attributes rejected by AWS

> **Point-in-time disclaimer**: This log records observations and conclusions made on 2026-08-28.
> Claims about runtime or AWS API behaviour are hypotheses confirmed against available evidence at
> that time; verify mechanically before acting on them in a new context.

## Symptom

Every non-FIFO `SNSTopic` in the integration cluster lands in `ACK.Terminal`:

    Type:    ACK.Terminal
    Message: InvalidParameter: Invalid parameter: Attributes
             Reason: FifoTopic: Invalid value []. Must be true or false.

The `[]` is how the SNS API renders an empty-string attribute value it received.

## Root cause

`rgds/snstopic.aws.kropath.run.yaml` used CEL ternaries that emitted `""` (empty string) for
non-FIFO or non-selected attribute values:

```yaml
fifoTopic: '${schema.spec.fifo ? "true" : ""}'
contentBasedDeduplication: ${schema.spec.fifo && schema.spec.contentBasedDeduplication ? "true" : ""}
fifoThroughputScope: ${schema.spec.fifo ? schema.spec.fifoThroughputScope : ""}
```

The comment above the block stated "empty string means omit" — this is **false**. ACK forwards all
fields present in the ACK resource spec to AWS as SNS Attributes, including empty-string values.
AWS validates every attribute and rejects the call outright if any value is invalid.

`FifoTopic: []` is the first attribute AWS validates. It must be `"true"` or `"false"`. An empty
string is neither, hence the rejection.

**Same class of bug in SQS:** `rgds/sqsqueue.aws.kropath.run.yaml` had the same pattern for
`contentBasedDeduplication`, `deduplicationScope`, and `fifoThroughputLimit`.

## Fix applied

### SNS (`rgds/snstopic.aws.kropath.run.yaml`)

Boolean attributes always emit `"true"` or `"false"`:
- `fifoTopic: '${schema.spec.fifo ? "true" : "false"}'`
- `contentBasedDeduplication: '${schema.spec.fifo && schema.spec.contentBasedDeduplication ? "true" : "false"}'`

Enum attribute always emits the schema value (default `Topic`; never empty string):
- `fifoThroughputScope: '${schema.spec.fifoThroughputScope}'`

For standard (non-FIFO) topics this sends `FifoThroughputScope: "Topic"`, a valid enum value. AWS
is expected to ignore FIFO-only attributes when `FifoTopic: "false"`. If AWS rejects `Topic` for
standard topics, a two-template approach (separate `ackTopicStandard` / `ackTopicFifo` templates
with `includeWhen`) is the correct next step — but was deferred to avoid duplicating ~180 lines of
delivery-feedback cascades without confirmed need.

### SQS (`rgds/sqsqueue.aws.kropath.run.yaml`)

Boolean: `contentBasedDeduplication: '${schema.spec.fifo && schema.spec.contentBasedDeduplication ? "true" : "false"}'`

Enum fields (defaults `queue` / `perQueue` — never empty when schema defaults are in place):
- `deduplicationScope: '${schema.spec.deduplicationScope}'`
- `fifoThroughputLimit: '${schema.spec.fifoThroughputLimit}'`

## Verification gate

Both RGDs reached `Active` in one round after delete+apply.

Chainsaw suites: `make test-sns` and `make test-sqs` — all scenarios PASS including the new
assertions on AC21 (SNS standard topic) and AC13 (SQS standard queue) that verify no FIFO
attribute is emitted as an empty string.

## Key principle

**Empty string is NOT omission in ACK.** Any string field present in the ACK resource spec —
even `""` — is forwarded to the AWS API. For any attribute that AWS validates (booleans, enums),
always emit a valid value. Use `includeWhen` template splitting if a field must be completely
absent from the spec for one code path.
