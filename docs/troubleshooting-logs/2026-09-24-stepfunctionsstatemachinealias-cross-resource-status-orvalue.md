# Troubleshooting Log — `2026-09-24-stepfunctionsstatemachinealias-cross-resource-status-orvalue.md`

> **⚠ POINT-IN-TIME RECORD.** This log captures what was observed and concluded at the time
> of writing. The claims it makes may be incorrect or may become incorrect as kro, ACK/KCC/ASO,
> or the platform evolves. Do NOT treat any claim in a troubleshooting log as authoritative.
>
> Authority precedence: **agent instructions > `docs/frequent-rgd-errors.md` > this log**.

---

## Context

**Date:** 2026-09-24
**Ticket:** KRO-1225
**Repo:** kropath-aws
**Resource family / technique:** Step Functions — `StepFunctionsStateMachineAlias` RGD, a status field reading from one of two mutually-exclusive template variants (`ackAliasWithDescription` / `ackAliasNoDescription`, split to work around the `optional.none()`-in-write-position trap for the optional `description` field).

---

## Problem

`status.aliasArn` was defined as:

```
aliasArn: >-
  ${ackAliasWithDescription.?status.?ackResourceMetadata.?arn.orValue(ackAliasNoDescription.?status.?ackResourceMetadata.?arn.orValue(""))}
```

The RGD reached `Active` (`GraphAccepted: True`) — this expression type-checks fine. But in a live
Chainsaw run, after the child (`ackAliasNoDescription`, since the test instance had no
`spec.description`) was patched with `status.ackResourceMetadata.arn`, the parent's `status` stayed
completely empty (`status: {}`) — not just `aliasArn` missing, every other status field
(`resourceName`, `namingStatus`, `conditions`) was gone too, even though those fields had been
correctly populated moments earlier at `CREATE` time.

```
* status.aliasArn: Required value: field not found in the input object
--- expected
+++ actual
@@ -3,6 +3,5 @@
 metadata:
   name: ac25-alias
   namespace: stepfunctionsstatemachinealias
-status:
-  aliasArn: arn:aws:states:...
+status: {}
```

## Root cause

Referencing a resource ID that was never created (`includeWhen` false throughout, zero observed
state) inside a status CEL expression that ALSO references a second, different resource ID appears
to make the *entire* status computation for that reconcile fail silently — kro drops every field in
`status`, not just the one expression that touches the never-created resource. This reproduced
reliably (empty `status: {}` persisted for 5+ minutes, well past the 962s in the affected chainsaw
run, and remained empty when re-checked directly with `kubectl get ... -o json | jq .status`
afterward — this was not a timing/backlog issue).

Verified by: reproducing with `ackAliasWithDescription`/`ackAliasNoDescription` — for an instance
with no `spec.description`, only `ackAliasNoDescription` is ever created
(`includeWhen: schema.spec.description == ""`); `ackAliasWithDescription` never exists. The
`aliasArn` expression above references `ackAliasWithDescription` first. Splitting the field into two
single-resource-reference fields (see "What worked") made every other status field populate
correctly again on the same instance.

This is the same underlying class of problem already documented in `frequent-rgd-errors.md` /
`mwaaenvironment.aws.kropath.run.yaml` as "kro cannot merge list types across mutually-exclusive
resources — separate fields required" — but that existing writeup frames it as a **type-checking**
problem specific to lists of named struct types. This log's finding is broader: the same failure
occurs for a **plain scalar field** (`arn`, a `string`), where the expression **does** type-check
(RGD reaches `Active`) but still fails at **runtime**, silently, dropping the whole `status` object
rather than just the offending field.

## Approaches tried

### Approach 1 — nested `.orValue()` chain across two resource IDs (scalar field)

```yaml
aliasArn: >-
  ${ackAliasWithDescription.?status.?ackResourceMetadata.?arn.orValue(ackAliasNoDescription.?status.?ackResourceMetadata.?arn.orValue(""))}
```

Result: RGD `Active`. Runtime: `status: {}` entirely, once the not-created resource's absence was
exercised (i.e. for any instance where only one of the two variants was ever created — which is
every instance, by construction).

Conclusion: type-checking success does not guarantee safe runtime evaluation when a status
expression spans two independently `includeWhen`-gated resources, even for scalar (non-list)
fields.

### Approach 2 — ternary discriminated by a staged ConfigMap flag (`naming.data.hasDescription`)

Tried this first for the analogous `conditions` field (a list of the ACK CRD's condition struct,
which — per the already-documented list-type-mismatch trap — is a genuinely different named type
per resource ID):

```yaml
conditions: >-
  ${naming.data.hasDescription == "true"
    ? ackAliasWithDescription.?status.?conditions.orValue([])
    : ackAliasNoDescription.?status.?conditions.orValue([])}
```

Result: `GraphAccepted: False` — `found no matching overload for '_?_:_' applied to
(bool, list(__type_ackAliasWithDescription...), list(__type_ackAliasNoDescription...))`. Ruled out
for list-typed fields; not attempted for the scalar `aliasArn` field once approach 3 below was
already confirmed working and simpler.

## What worked

Split every status field that would otherwise need to read from either
`ackAliasWithDescription` or `ackAliasNoDescription` into **two separate status fields**, each
referencing **exactly one** resource ID:

```yaml
aliasArn: >-
  ${ackAliasWithDescription.?status.?ackResourceMetadata.?arn.orValue("")}
aliasArnNoDescription: >-
  ${ackAliasNoDescription.?status.?ackResourceMetadata.?arn.orValue("")}
conditions: >-
  ${ackAliasWithDescription.?status.?conditions.orValue([])}
conditionsNoDescription: >-
  ${ackAliasNoDescription.?status.?conditions.orValue([])}
```

Reproduced fix: re-ran the same Chainsaw scenario (alias with no `spec.description`, patch the
child's `status.ackResourceMetadata.arn`, assert parent `status`) — `resourceName`, `namingStatus`,
and `conditionsNoDescription` all populated correctly, in under 25 seconds, no `status: {}` regression.

Why it works: each field now touches only a single resource ID's observed state. When that resource
doesn't exist, `.orValue()` on it cleanly resolves to the empty fallback in isolation, without a
second, absent resource ID anywhere in the same expression to trip up evaluation.

## Pattern / rule derived

> **Rule (candidate for `frequent-rgd-errors.md`):** When an RGD splits one logical child resource
> into two (or more) mutually-exclusive `includeWhen`-gated template variants (the KRO-928
> optional-field-omission workaround), **every** status field that would read from "whichever
> variant exists" must be split into one field per variant — never reference more than one
> variant's resource ID inside a single status CEL expression, not even via `.orValue()` chaining
> on a plain scalar field. This generalizes the existing "list-type-mismatch" writeup
> (`mwaaenvironment` `conditions`/`noKmsConditions`): the failure mode is not specific to lists —
> it silently zeroes out the *entire* `status` object at runtime for scalar fields too, even though
> the RGD reaches `Active`. Verify any such split field empirically against a live Chainsaw
> assertion, not just `GraphAccepted: True`, before trusting it.

## Corrections to prior logs

None — this extends, rather than corrects, the existing `mwaaenvironment` write-up.
