# 2026-08-29 — SQSQueue FIFO attributes: includeWhen split required; CEL `+` on distinct named list types fails

> **Point-in-time disclaimer**: This log records observations and conclusions made on 2026-08-29.
> Claims about runtime or AWS API behaviour are hypotheses confirmed against available evidence at
> that time; verify mechanically before acting on them in a new context.

## Symptom

Standard (non-FIFO) `SQSQueue` instances land in `ACK.Terminal`:

    Type:    ACK.Terminal
    Message: InvalidAttributeName: You can specify the DeduplicationScope only when
             FifoQueue is set to true.

This persists even after the 2026-08-28 fix that gave `deduplicationScope` a valid enum default
(`queue`) instead of an empty string. AWS SQS rejects the attribute unconditionally when
`FifoQueue: "false"`, regardless of the value of `DeduplicationScope`.

## Root cause

The 2026-08-28 SQS fix (see `2026-08-28-sns-sqs-empty-string-fifo-attributes.md`) assumed that
AWS SQS — like AWS SNS — would silently ignore FIFO-only attributes for standard queues when those
attributes contain valid values. This assumption is **wrong for SQS**:

- **SNS** ignores `FifoThroughputScope` for standard topics when it carries a valid enum value.
- **SQS** rejects `DeduplicationScope` and `FifoThroughputLimit` entirely when `FifoQueue` is
  `false`, regardless of the attribute value.

## Fix applied

Split the single `queue` ACK resource template into two templates with `includeWhen`:

```yaml
- id: queueStandard
  includeWhen:
    - '${!schema.spec.fifo}'
  template:
    spec:
      # No deduplicationScope or fifoThroughputLimit — omitted entirely (KRO-906)
      fifoQueue: "false"
      contentBasedDeduplication: "false"

- id: queueFifo
  includeWhen:
    - '${schema.spec.fifo}'
  template:
    spec:
      fifoQueue: "true"
      contentBasedDeduplication: '${schema.spec.contentBasedDeduplication ? "true" : "false"}'
      deduplicationScope: '${schema.spec.deduplicationScope}'
      fifoThroughputLimit: '${schema.spec.fifoThroughputLimit}'
```

This ensures FIFO-only attributes are completely absent from the ACK resource spec for standard
queues — not just set to valid values.

## CEL `+` type overload error with distinct named list types

**Symptom:** RGD stays `Inactive` with:

    found no matching overload for '_+_' applied to
    '(list(__type_queueStandard.status.conditions.@idx),
      list(__type_queueFifo.status.conditions.@idx))'

**Root cause:** kro's CEL type system assigns unique named types to each resource's fields. Even
though `queueStandard.status.conditions` and `queueFifo.status.conditions` are structurally
identical (`list(Condition)`), they are distinct named types. The `+` operator requires both
operands to have the same type.

**Wrong approach:**
```yaml
conditions: >-
  ${queueStandard.?status.?conditions.orValue([]) + queueFifo.?status.?conditions.orValue([])}
```

**Fix — SNS single-reference pattern:**
```yaml
conditions: >-
  ${queueStandard.?status.?conditions.orValue([])}
```

This follows the same pattern as `snstopic.aws.kropath.run.yaml`, which only references
`ackTopicNoPolicy.?status.?conditions`. Conditions from the inactive path (`queueFifo` for
standard queues, `queueStandard` for FIFO queues) are not surfaced — this is an accepted
limitation of the split-template pattern in kro.

**Note on ternary:** A ternary (`schema.spec.fifo ? queueFifo.?status.?conditions.orValue([]) :
queueStandard.?status.?conditions.orValue([])`) would also fail — kro's type checker requires both
branches to be the same type, and they are distinct named types. The single-reference approach is
the correct solution.

## Verification

- `kubectl delete rgd sqsqueue.aws.kropath.run` + `kubectl apply -f rgds/sqsqueue.aws.kropath.run.yaml`
- RGD reached `Active` in one round.
- `cd tests && make test-sqs` — all steps PASS including AC-13 which verifies via script that
  `deduplicationScope` and `fifoThroughputLimit` are absent from the standard queue ACK resource spec.
