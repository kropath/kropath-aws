# Troubleshooting Log: ACM RBAC Missing + Empty SecretKeyReference

**Date:** 2026-08-24
**Ticket:** KRO-717
**PR:** kropath-aws#141
**Author:** Implementer (automated)

> **Point-in-time disclaimer:** This log records what was observed during CI failure investigation.
> The claims below were verified against the cluster at the time of writing. Code and CRD schemas may
> evolve — verify mechanically rather than trusting this log blindly.

---

## Symptoms

All 5 ACM Chainsaw tests (acmcertificate, acmprivateca, acmprivatecertificate, acmeendpoint, acmedomainvalidation) failed in CI with:

```
actual resource not found (AssertTimeout: 5m0s)
```

The failing assertion was on the ACK child resources (e.g., `acm.services.k8s.aws/v1alpha1/Certificate`). No ACK child resources were created.

## Root Cause 1: RBAC Missing for ACM/ACMPCA API Groups

### Evidence

kro controller logs showed:

```
ERROR dynamic-controller.watch-manager Watch error
certificates.acm.services.k8s.aws is forbidden: User "system:serviceaccount:kro-system:kro"
cannot list resource "certificates" in API group "acm.services.k8s.aws" at the cluster scope
```

kro's watch manager failed with a 403 and entered exponential backoff, preventing it from watching or
creating any `acm.services.k8s.aws` or `acmpca.services.k8s.aws` resources.

Reproduced locally by applying an ACMCertificate instance and checking kro logs.

### Fix

Added `acm.services.k8s.aws` and `acmpca.services.k8s.aws` to the second rule's `apiGroups` list in
`tests/fixtures/rbac/kro-controller.yaml`:

```yaml
- apiGroups:
    # ... existing entries ...
    - sfn.services.k8s.aws
    - acm.services.k8s.aws      # added
    - acmpca.services.k8s.aws   # added
  resources:
    - "*"
  verbs:
    - create
    - delete
    - get
    - list
    - patch
    - update
    - watch
```

**Every new resource family must add its API group to this file** before tests will pass. The RBAC
file is the first thing to check when all tests fail with "actual resource not found".

---

## Root Cause 2: Empty SecretKeyReference `{}` Rejected by ACK CRDs

### Evidence

The ACMCertificate RGD template had:

```yaml
certificate: >-
  ${schema.spec.importCertificateSecret != ""
    ? {"name": schema.spec.importCertificateSecret, "key": "tls.crt"}
    : {}}
privateKey: >-
  ${...}
certificateChain: >-
  ${...}
```

For non-import certs, all three evaluated to `{}`. The ACK Certificate CRD has these as optional at
the spec level but with `required: [key, name]` inside:

```yaml
certificate:
  properties:
    key:
      type: string
    name:
      type: string
  required:
    - key
    - name
  type: object
```

Setting an optional object field to `{}` causes a 422 from the Kubernetes API server:
```
spec.certificate.key: Required value
spec.certificate.name: Required value
```

The same pattern affected `acmpca.services.k8s.aws/Certificate.spec.certificateOutput` in the
ACMPrivateCertificate RGD when `certificateSecretName == ""`.

### Fix

Split each affected resource into separate `includeWhen`-gated variants: one that omits the
SecretKeyReference fields entirely (for the non-import path) and one that sets them with actual
values (for the import path):

**ACMCertificate:** `ackCertificate` (non-import, no import fields), `ackImportCertificate` (import
without chain), `ackImportCertificateWithChain` (import with chain).

**ACMPrivateCertificate:** `ackPrivateCert` (no output secret), `ackPrivateCertWithOutput` (with
output secret).

**Rule:** When an ACK CRD field has `required: [key, name]` inside its object schema, it must NEVER
be set to `{}`. Either omit the field entirely (via a split resource) or set it with real values.
Check every optional object field in the CRD fixture against this pattern before wiring templates.

---

## Root Cause 3: Cross-Resource List Type Mismatch in Status Block

### Evidence

After splitting `ackCertificate` into three resources, the initial fix tried to merge conditions
using nested ternaries:

```yaml
conditions: >-
  ${has(ackCertificate.status) && has(ackCertificate.status.conditions) ? ackCertificate.status.conditions
    : (has(ackImportCertificate.status) && ... ? ackImportCertificate.status.conditions
    : ...)}
```

kro rejected this at compile time:

```
found no matching overload for '_?_:_' applied to
'(bool, list(__type_ackImportCertificate.status.conditions.@idx),
         list(__type_ackImportCertificateWithChain.status.conditions.@idx))'
```

kro assigns unique internal types to every resource's status fields. Even when two resources both
have a `conditions` list, the types are different from kro's perspective and cannot be unified in a
ternary. This matches the documented behavior in `docs/frequent-rgd-errors.md §3 "Cross-Resource
Condition Appending"`.

### Fix

Use **separate status fields per resource path** with `?.orValue()` on each resource independently:

```yaml
status:
  conditions: >-
    ${ackCertificate.?status.?conditions.orValue([])}
  importConditions: >-
    ${ackImportCertificate.?status.?conditions.orValue([])}
  importWithChainConditions: >-
    ${ackImportCertificateWithChain.?status.?conditions.orValue([])}
```

**Rule:** Never write `resourceA.status.listField ? ... : resourceB.status.listField` across
different resource IDs — kro's type checker will reject it. Always expose list-type status fields
as one field per resource. String scalar fields (like `arn`) can use ternaries but are safer as
separate fields too.

---

## Verification

All 5 ACM RGDs reached `Active` after fixes (verified locally via delete-apply-Active loop).

Command used:
```bash
kubectl delete rgd acmcertificate.aws.kropath.run --ignore-not-found=true --timeout=60s
kubectl apply -f rgds/acmcertificate.aws.kropath.run.yaml
kubectl get rgd acmcertificate.aws.kropath.run -o jsonpath='{.status.state}'
# → Active
```
