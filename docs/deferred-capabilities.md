# Deferred Capabilities

This document lists acceptance criteria that cannot be implemented with the current upstream
provider controller versions. Each entry records the blocking constraint and the condition
needed to unblock it.

---

## AWS IAM — `AWSIAMUser` (aws-iam-06)

### AC-2 / AC-14 — ACK AccessKey CR (`accesskeys.iam.services.k8s.aws`)

**Spec requirement:** When `createAccessKey: true` and governance allows it, create an ACK
`AccessKey` CR and store credentials in a K8s Secret `<user-cr-name>-access-key`.
AC-14 also requires `services.k8s.aws/deletion-policy` on the `AccessKey` child.

**Blocking constraint:** The `accesskeys.iam.services.k8s.aws` CRD is not installed in this
cluster. The ACK IAM controller version in use does not include the AccessKey CRD.

```
kubectl get crd accesskeys.iam.services.k8s.aws
Error from server (NotFound)
```

**To unblock:** Install/upgrade the ACK IAM controller to a version that ships the
`accesskeys.iam.services.k8s.aws` CRD. Then re-open these acceptance criteria in the spec.

---

### AC-6 — IAM User group membership (`spec.groups`)

**Spec requirement:** When `groups: ["ops-admins"]` is set and `IAMGroup/ops-admins` exists
in the same namespace, the IAM User should be a member of that group in AWS.

**Blocking constraint:** Neither upstream ACK CRD supports this association:
- `users.iam.services.k8s.aws` spec fields: `inlinePolicies, name, path, permissionsBoundary,
  permissionsBoundaryRef, policies, policyRefs, tags` — no `groups` field
- `groups.iam.services.k8s.aws` spec fields: `inlinePolicies, name, path, policies, policyRefs`
  — no `users` or `usernames` field

`spec.groups` is retained in the `AWSIAMUser` schema for API-surface stability but has no
downstream effect until upstream support is added.

**To unblock:** Either the ACK IAM User CRD gains a `groups` field, or the ACK IAM Group CRD
gains a `users`/`usernames` field that lists member user ARNs. Re-open AC-6 when either lands.

---

## AWS SNS — `SNSTopic` (KRO-928)

### Mixed delivery-feedback ARN configuration (partial ARN set)

**Spec requirement:** When only some of the 10 ARN fields (5 protocols × `successFeedbackRoleArn`
and `failureFeedbackRoleArn`) are configured, the RGD should omit the unconfigured ARN fields
so that AWS SNS does not receive empty-string attribute values (which AWS rejects).

**Blocking constraint:** kro v0.9.2 cannot conditionally omit scalar string fields from a
template at render time. The `optional.none()` type is not supported in write position — kro's
CEL type checker rejects any ternary whose branches are `string` and `optional_type(dyn)`:

```
# KRO-928 probe 4 result (2026-08-31):
# Template field: ${conditionMet ? someString : optional.none()}
# kro error: found no matching overload for '_?_:_' applied to
#            '(bool, string, optional_type(dyn))'
# RGD reaches Inactive; not usable.
```

The `omit-don't-empty` rule in `docs/frequent-rgd-errors.md` documents that empty-string
ARN fields cause AWS to reject the SNS Topic API call. Field omission via `optional.none()` is
the correct fix but is not achievable in kro v0.9.2.

**Mitigation in place:** The RGD detects mixed-ARN configurations via the `hasMixedFeedbackARN`
flag in the naming ConfigMap. When detected, an advisory `mixedFeedbackARNError` ConfigMap is
created in-graph, no ACK Topic CR is rendered for the feedback variant, and the user receives a
clear error message instructing them to configure all 10 ARN fields or none.

**To unblock:** When kro supports `optional.none()` (or equivalent field-omission semantics) in
template write position, remove the 12-variant template structure and replace with a single
template using conditional field emission. Also remove the `mixedFeedbackARNError` ConfigMap and
the `hasMixedFeedbackARN` flag from the naming ConfigMap.

---

## AWS OpenSearch — `OpenSearchDomain` (KRO-807)

### AC-21 — `logPublishingOptions` passthrough

**Spec requirement:** When `logPublishingOptions` is set on an `OpenSearchDomain`, the ACK
`Domain` `spec.logPublishingOptions` field should be populated accordingly.

**Blocking constraint:** The ACK `Domain` CRD `spec.logPublishingOptions` field is typed as a
map of objects — each value is `{cloudWatchLogsLogGroupARN: string, enabled: bool}`. kro's
schema type system has no first-class support for `map[string]object` with named nested fields.
A `map[string]string` schema misrepresents the type and would be rejected at kro validation time.
Implementing this field would require kro to support heterogeneous map values or a dedicated
nested schema type, neither of which is available in kro v0.9.2.

**Current behaviour:** AC-21 tests `advancedOptions` passthrough (a `map[string]string` field
that _is_ correctly typed). The `logPublishingOptions` field is not exposed in the
`OpenSearchDomain` schema.

**To unblock:** When kro supports `map[string]<namedObjectType>` schema fields, add
`logPublishingOptions` to the `OpenSearchDomain` schema with appropriate nested-object typing
and wire it to `ackDomain.spec.logPublishingOptions`.
