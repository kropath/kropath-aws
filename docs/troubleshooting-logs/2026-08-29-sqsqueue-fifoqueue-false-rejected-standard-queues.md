# 2026-08-29 — SQSQueue: fifoQueue=false rejected by AWS for standard queues (KRO-912)

> **Point-in-time disclaimer**: This log records observations and conclusions made on 2026-08-29.
> Claims about runtime or AWS API behaviour are hypotheses confirmed against available evidence at
> that time; verify mechanically before acting on them in a new context.

## Symptom

Standard (non-FIFO) `SQSQueue` instances land in `ACK.Terminal`:

    Type:    ACK.Terminal
    Message: InvalidAttributeName: Unknown Attribute FifoQueue.

Confirmed on `payments-test/payment-settlements` and `data-test/ingest-backlog` — both are standard
queues (no `.fifo` suffix). The kro `SQSQueue` predicted ARN and queue URL are populated, but the
underlying ACK `Queue` never syncs.

## Root cause

The KRO-906 fix (2026-08-29) correctly split the SQS RGD into `queueStandard` and `queueFifo`
templates using `includeWhen`. It removed `deduplicationScope` and `fifoThroughputLimit` from the
standard template. However, the standard template retained:

```yaml
fifoQueue: "false"
contentBasedDeduplication: "false"
```

The KRO-906 reasoning was that valid values (`"false"`) would be accepted by AWS for standard
queues. **This assumption is wrong.** AWS SQS rejects the `FifoQueue` attribute entirely for
standard queues (queue name without `.fifo` suffix), regardless of the attribute's value. `"false"`
is not accepted — the key must be absent from the `CreateQueue` attributes.

This is the same class of bug as KRO-906 (AWS rejects FIFO-only attributes for standard queues)
but applies to `fifoQueue` and `contentBasedDeduplication`, not just `deduplicationScope` and
`fifoThroughputLimit`.

## Fix applied

Removed `fifoQueue: "false"` and `contentBasedDeduplication: "false"` from the `queueStandard`
template. Updated the block comment at both the template header and the inline comment to document
that **all four** FIFO attributes are intentionally absent from the standard-queue template.

Updated the AC-13 Chainsaw assertion: the old assert checked that `fifoQueue: "false"` was
PRESENT (which was the KRO-906 state). The new assertion uses a `- script:` step to verify
that ALL four FIFO attributes (`fifoQueue`, `contentBasedDeduplication`, `deduplicationScope`,
`fifoThroughputLimit`) are ABSENT from the rendered ACK Queue spec.

## Key principle (reinforced)

**Any FIFO-specific SQS attribute must be completely absent from the ACK resource spec for
standard queues.** AWS rejects these attributes regardless of their value — even `"false"` is
not a valid value for a standard queue. The `includeWhen` template split is the correct pattern:
FIFO attributes belong only in the `queueFifo` template.

## Verification

- `kubectl delete rgd sqsqueue.aws.kropath.run` + `kubectl apply -f rgds/sqsqueue.aws.kropath.run.yaml`
- RGD reached `Active` in one round.
- AC-13 Chainsaw scenario updated to assert absence of all four FIFO attributes on the standard queue.

## Related

- KRO-906: initial `includeWhen` split that removed `deduplicationScope` and `fifoThroughputLimit`
- `2026-08-29-sqsqueue-fifo-attribute-includeWhen-split.md`: describes KRO-906 in detail
- `2026-08-28-sns-sqs-empty-string-fifo-attributes.md`: root-cause analysis of the empty-string class
