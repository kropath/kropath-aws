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
