---
# Troubleshooting Log: ACMPrivateCA type_ field + ACMEDomainValidation hostedZoneID

**Date:** 2026-08-24
**Ticket:** KRO-717
**PR:** kropath-aws#141 (commit d8b509d)
**Author:** Implementer (automated)

> **Point-in-time disclaimer:** This log records what was observed during CI failure investigation
> for commit d8b509d. The claims below were verified mechanically against the local cluster and
> the kropath-core CRD cache. Code and CRD schemas may evolve — verify mechanically rather than
> trusting this log blindly.

---

## CI Failure: Commit d8b509d (ci_fail_streak: 2)

CI run `32724907011` showed three failures:

### 1. ACMEDomainValidation: `hostedZoneID` missing from schema and template

**Error:**
```
type mismatch ... map value incompatible with struct field "hostedZoneID":
type kind mismatch: got "map(string, dyn)", expected "string"
```

**Root cause:** The `prevalidationOptions` expression built:
```
{"dnsPrevalidation": {"domainScope": {...}}}
```
The real ACK `AcmeDomainValidation` CRD has `dnsPrevalidation.hostedZoneID: string` as an
additional field. Since it was not in the RGD schema or template, kro type-check failed.

**Fix:**
- Added `hostedZoneID: string | default=""` to the RGD spec schema.
- Added `"hostedZoneID": schema.spec.hostedZoneID` inside the `dnsPrevalidation` map in the
  `prevalidationOptions` CEL expression.
- Added `hostedZoneID: type: string` to `dnsPrevalidation.properties` in the CRD fixture
  `acm.services.k8s.aws_acmedomainvalidations.yaml`.

---

### 2. ACMPrivateCA + ACMPrivateCertificate: `type_:` should be `type:` in RGD templates

**Error:**
```
error getting field schema for path spec.type_: schema not found for field type_
```

**Root cause:** The RGD templates used `type_:` as the template field key:
```yaml
spec:
  type_: "${schema.spec.caType}"
```
kro does a **literal** field name lookup against the CRD schema. The real ACK CRD for
`CertificateAuthority` has `spec.type` (not `spec.type_`). The CRD fixtures also had `type_:`
which made the RGDs Active locally, but the real ACK CRDs in CI have `type:`.

The original fixture comments incorrectly stated "kro maps type to type_ in templates". This
is **false** — kro has no such mapping. kro uses the template key name literally to look up the
CRD schema field.

**Why `type_:` originally worked locally:** The fixtures also had `type_:`, so kro found it in
the fixture CRD. But in CI, the real ACK CRDs have `type:`, so kro could not find `type_`.

**Note on YAML validity:** `type:` is a valid YAML mapping key. There is no YAML/CEL conflict
when using `type:` as the template field key, because the potential conflict is only inside CEL
`${}` expressions where `type` is a built-in function identifier. As a YAML mapping key in a
template block, `type:` is unambiguous.

**Fix:**
- Changed `type_:` to `type:` in `rgds/acmprivateca.aws.kropath.run.yaml` (1 occurrence).
- Changed `type_:` to `type:` in `rgds/acmprivatecertificate.aws.kropath.run.yaml` (2 occurrences).
- Changed `type_:` to `type:` in `tests/fixtures/crds/acmpca/acmpca.services.k8s.aws_certificateauthorities.yaml`.
- Changed `type_:` to `type:` in `tests/fixtures/crds/acmpca/acmpca.services.k8s.aws_certificates.yaml`.
- Updated fixture comments to reflect correct understanding.

**ACMPrivateCertificate cascade:** The Inactive `acmprivateca` RGD caused `acmprivatecertificate`
to fail with "cannot resolve group version kind ACMPrivateCA". Fixing `acmprivateca` automatically
resolved `acmprivatecertificate`.

---

## Verification

All 5 ACM RGDs confirmed Active after fixes via delete-apply loop:

```
acmcertificate.aws.kropath.run       Active
acmedomainvalidation.aws.kropath.run Active
acmeendpoint.aws.kropath.run         Active
acmprivateca.aws.kropath.run         Active
acmprivatecertificate.aws.kropath.run Active
```

---

## Rule: kro template field names are literal CRD field names

> **When writing a kro RGD template, the YAML key in `spec:` (e.g., `type:`, `value:`) must
> match the exact field name in the target CRD's `spec.properties`. There is no automatic
> mapping for reserved words. If the CRD has `type:`, the template must also use `type:`.
> Verify against the CRD cache before naming any template field.**

This rule applies even when the field name appears to conflict with YAML or CEL keywords:
- YAML: `type:` as a mapping key is valid YAML — not a conflict.
- CEL: conflicts only arise inside `${}` expressions; template keys are plain YAML, not CEL.
