> **Point-in-time disclaimer:** This log records observations as of 2026-09-07. Claims about kro
> behaviour, ACK CRD schema, and fixture structure are hypotheses confirmed locally on that date.
> They may not hold after a kro upgrade, an ACK chart bump, or schema changes. Verify mechanically
> before acting on any claim here.

# BedrockHarness tools[].config — "field not declared in schema" with additionalProperties

**Ticket:** KRO-815
**Date:** 2026-09-07
**Symptom:** Chainsaw scenario `bedrockharness/ac19-tools-configuration` fails with ASSERT ERROR:
`actual resource not found` for `Harness bedrockharness-ac19-harness` after 5-minute timeout.
All other bedrockharness scenarios (ac01–ac18, which use empty `tools: []`) pass.

## What Failed

The ACK `Harness` child resource was never created when `spec.tools` contained items with a
non-empty `config` map. The `BedrockHarness` CR was accepted by Kubernetes (kro CRD passed
schema validation), but reconciliation errored:

```
resource reconciliation failed: apply results contain errors:
failed to create typed patch object
(bedrockharness/bedrockharness-ac19-harness;
 bedrockagentcorecontrol.services.k8s.aws/v1alpha1, Kind=Harness):
.spec.tools[0].config.browserID: field not declared in schema
```

## Root Cause

The stub CRD fixture at `tests/fixtures/crds/bedrock/bedrockagentcorecontrol.services.k8s.aws_harnesses.yaml`
defined `tools[].config` as:

```yaml
config:
  additionalProperties:
    type: string
  type: object
```

kro uses server-side apply (SSA) with a typed patch object via the Structured Merge Diff (SMD)
library. SMD does NOT automatically treat `additionalProperties: {type: string}` as "accept any
key" — it requires `x-kubernetes-preserve-unknown-fields: true` on the map field to allow
arbitrary keys to pass through without declaring them individually. Without this flag, SMD
rejected `browserID` (and any other runtime config key) as "not declared in schema", causing the
Harness creation to fail entirely.

## What Was Tried

1. Adding `tools` and `allowedTools` to the RGD schema (previous session — fixed the
   `strict decoding error: unknown field "spec.tools"` rejection at the CR apply level).
2. After that fix, the CR was accepted but the ACK Harness still wasn't created. The
   `BedrockHarness` showed state=ERROR with the typed-patch error above.

## What Worked

Add `x-kubernetes-preserve-unknown-fields: true` to the `config` field in the CRD fixture:

```yaml
config:
  additionalProperties:
    type: string
  type: object
  x-kubernetes-preserve-unknown-fields: true
```

After applying the updated CRD and re-creating the BedrockHarness instance, the ACK Harness was
created with `tools[0].config.browserID: br-123` present as expected.

## Pattern Discovered

**Any CRD fixture field typed as `additionalProperties: {type: string}` (i.e., `map[string]string`)
that kro writes to via a direct pass-through (`${schema.spec.someMap}` or an element of a custom
type list) MUST declare `x-kubernetes-preserve-unknown-fields: true`** on the field. Without it,
kro's typed-patch object creation rejects arbitrary runtime keys, and the child resource is never
created. The RGD compiles gate (delete+re-apply, wait for Active) does NOT catch this — it only
validates the schema structure, not the runtime serialization of specific key values.

Applies to: any fixture CRD field with `type: object, additionalProperties: ...` that receives
dynamic map values from kro templates.
