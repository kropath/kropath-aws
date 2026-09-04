> **Point-in-time disclaimer:** This log records what was observed and believed at the time of writing (2026-09-05). Claims here are hypotheses unless mechanically verified. If this log conflicts with `frequent-rgd-errors.md` or agent instructions, those sources win.

# SES ConfigurationSet: Missing RBAC for ses.services.k8s.aws (KRO-962)

## Symptom

CI failure for `chainsaw/ses/sesconfigurationset[sesconfigurationset]` (60.49s timeout):

```
ASSERT ERROR: ses.services.k8s.aws/v1alpha1/ConfigurationSet @ sesconfigurationset/ac1-default
```

The `SESConfigurationSet` status was correct (`namingStatus: valid`, `resourceName` and `predictedArn` populated), meaning kro found the SESConfig, resolved effectiveName, and the naming ConfigMap was created. But the ACK `ConfigurationSet` CR was never created.

## Root Cause

`ses.services.k8s.aws` was absent from the apiGroups list in `tests/fixtures/rbac/kro-controller.yaml`. The kro controller ClusterRole aggregation did not include SES, so every `CREATE` call for `configurationsets.ses.services.k8s.aws` was RBAC-denied (silently — kro does not surface RBAC errors to the CR status; the reconciliation just silently stalls).

Reproducing command:
```
grep 'ses.services.k8s.aws' tests/fixtures/rbac/kro-controller.yaml
# → no output (not in file)
```

## Fix

Added `- ses.services.k8s.aws` to the apiGroups list in `tests/fixtures/rbac/kro-controller.yaml`, immediately after `opensearchservice.services.k8s.aws` and `pipes.services.k8s.aws`.

After the fix, local SES Chainsaw test passed in 9.51s. ACK `ConfigurationSet` CR was created with correct `spec.name = effectiveName`.

## Pattern

This is the same class of failure as:
- `2026-09-03-appscaling-missing-rbac.md`
- Prior kinesisstream and cloudtrail RBAC gaps

**When implementing a new ACK service:** always add `<service>.services.k8s.aws` to `tests/fixtures/rbac/kro-controller.yaml` AND `hack/install-provider-crds.sh` AND `tests/setup.sh` comment in the same PR as the RGD/CRD. All three must be present for CI to pass.
