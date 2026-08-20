# EKSCluster Chainsaw: kubectl patch used nested field names not in the EKSConfig CRD

**Date:** 2026-08-21
**Ticket:** KRO-532
**Resource family:** EKS / ekscluster

> **Point-in-time disclaimer:** This log records what the author observed and concluded on the date
> above. Claims were verified against the CRD schema and CI failure output at the time of writing.
> Later changes to the CRD or controller may affect these conclusions. Verify mechanically before
> acting on any specific claim.

---

## Symptom

CI failure on `chainsaw/eks/ekscluster[ekscluster]` with a 302.68 s timeout in scenario
`ac9-mandatory-auth-mode`. The test creates an EKS cluster, patches the EKSConfig effectiveConfig
to set `mandatory.authenticationMode = "API_AND_CONFIG_MAP"`, then asserts the ACK Cluster resource
reflects that value. The assertion never passes.

CI log contained:
```
Warning: unknown field "status.effectiveConfig.mandatory.accessConfig"
Warning: unknown field "status.effectiveConfig.mandatory.upgradePolicy"
Warning: unknown field "status.effectiveConfig.mandatory.logging"
```

## Root cause

All `kubectl patch eksconfig general-policy --subresource=status` commands in
`tests/eks/ekscluster/chainsaw-test.yaml` used nested field names that do not exist in the
EKSConfig CRD:

| Patch field (wrong — nested) | Correct flat field |
|---|---|
| `mandatory.accessConfig.authenticationMode` | `mandatory.authenticationMode` |
| `mandatory.encryptionConfig.keyArn` | `mandatory.encryptionKeyArn` |
| `mandatory.logging.types` | `mandatory.loggingTypes` |
| `mandatory.upgradePolicy.supportType` | `mandatory.supportType` |
| `defaults.accessConfig.authenticationMode` | `defaults.authenticationMode` |
| etc. | etc. |

Kubernetes silently drops unknown fields with a Warning (it does not reject the patch). So the
`mandatory.authenticationMode` field was never set; it stayed `""`. The RGD emitted `""` to ACK's
`EKS Cluster.spec.authenticationMode`, ACK substituted its own default `"API"`, and the test
asserted `"API_AND_CONFIG_MAP"` — which never arrived.

Other test scenarios appeared to pass because their assertions did not depend on
`authenticationMode` or `supportType` being overridden from the default value.

## How to diagnose

If a Chainsaw scenario that patches EKSConfig status is timing out:
1. Look for `Warning: unknown field` in the Chainsaw output.
2. Cross-check every field name in the patch JSON against the EKSConfig CRD (`crds/eksconfig.yaml`)
   using `jsonPath` entries or `spec.versions[].schema.openAPIV3Schema`.

## Fix

Replaced all nested patch patterns with flat field names in
`tests/eks/ekscluster/chainsaw-test.yaml`:

```bash
sed -i '' \
  -e 's/"accessConfig":{"authenticationMode":"API_AND_CONFIG_MAP"}/"authenticationMode":"API_AND_CONFIG_MAP"/g' \
  -e 's/"accessConfig":{"authenticationMode":"API"}/"authenticationMode":"API"/g' \
  -e 's/"accessConfig":{"authenticationMode":""}/"authenticationMode":""/g' \
  -e 's/"upgradePolicy":{"supportType":"EXTENDED"}/"supportType":"EXTENDED"/g' \
  -e 's/"upgradePolicy":{"supportType":"STANDARD"}/"supportType":"STANDARD"/g' \
  -e 's/"upgradePolicy":{"supportType":""}/"supportType":""/g' \
  tests/eks/ekscluster/chainsaw-test.yaml
```

(The `encryptionConfig.keyArn` and `logging.types` patterns had already been fixed in the prior
session via Edit tool replace_all.)

## Pattern to avoid in future tests

When writing a `kubectl patch <resource> --subresource=status` step in Chainsaw, always verify
each field in the JSON payload against the CRD schema before committing. Never infer field structure
from the AWS provider concept or ACK CRD — the kropath CRD may flatten nested AWS structs into
top-level fields on the `<Family>Config` kind.
