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

---

## Tenant-namespace onboarding — `ack-role-account-map` entry (KRO-1140)

### Emitting the CARM role-map entry from the same onboarding artifact

**Spec requirement:** `onboarding/tenant-namespace` (KRO-1140) was asked to emit the
`ack-role-account-map` ConfigMap entry for `accountId` alongside the Namespace and
`<Family>Config` manifests, so the C-4 role-ARN mismatch (ADR-015 §5.8.4 precondition 4 — the
resolved IAM role's account segment silently overriding kropath's own `accountId`) becomes
unconstructible the same way the namespace annotation is.

**Blocking constraint:** not an upstream CRD/kro limitation — a structural GitOps-ownership
one. `ack-role-account-map` is a single ConfigMap holding every onboarded account's role ARN.
A static manifest can only express whole-object ownership (there is no "patch in one key of an
existing ConfigMap" manifest kind), so a per-tenant chart rendering the full object would
require every tenant's render to carry the complete, current set of every other tenant's
entries to avoid clobbering them on apply — defeating the "one declared input block per
tenant" design. The ConfigMap also lives in the ACK system namespace, owned by cluster/platform
operators, a different GitOps ownership boundary than the tenant's own namespace manifests.

**Current behaviour:** the chart's rendered `NOTES.txt` states the exact `accountId: <role
ARN>` entry to confirm or add and calls out precondition 4 explicitly. A human still has to
supply and merge the role ARN by hand. Full detail and rationale:
`onboarding/tenant-namespace/README.md` § "Why `ack-role-account-map` is not rendered here".

**To unblock:** either a platform-owned reconciler for `ack-role-account-map` (out of scope —
ADR-003 keeps kropath-controller a pure config store with no such write surface), or rely on
the KRO-1141 install-conformance checker to catch a mismatched entry after the fact.

---

## AWS Lambda — Resource-Based Policy (`Permission`) (KRO-1202)

### Granting an AWS service principal invoke rights on a Function via a declarative resource policy

**Spec requirement:** the data-team integration-test story (KRO-1182, documented in KRO-1184)
needs an EventBridge rule to invoke `file-process-lambda`. More generally, any story where an AWS
service (S3 bucket notifications, SNS topic subscriptions, API Gateway integrations, etc.) invokes
a Lambda function needs the equivalent of `aws lambda add-permission` /
`AWS::Lambda::Permission` — a resource-based policy statement on the function granting
`lambda:InvokeFunction` to a named principal, scoped by `SourceArn`/`SourceAccount`.

**Blocking constraint:** the ACK lambda-controller has no CRD for this. Confirmed live against
controller `v1.17.3` and against the current upstream `main` branch CRD bases (2026-09-22):

```bash
$ kubectl get crd -o name | grep lambda.services.k8s.aws
aliases.lambda.services.k8s.aws
codesigningconfigs.lambda.services.k8s.aws
eventsourcemappings.lambda.services.k8s.aws
functions.lambda.services.k8s.aws
functionurlconfigs.lambda.services.k8s.aws
layerversions.lambda.services.k8s.aws
versions.lambda.services.k8s.aws
# no permissions.lambda.services.k8s.aws

$ kubectl get crd functions.lambda.services.k8s.aws -o json \
    | jq '.spec.versions[0].schema.openAPIV3Schema.properties.spec.properties | keys'
[
  "architectures", "code", "codeSigningConfigARN", "codeSigningConfigRef", "deadLetterConfig",
  "description", "durableConfig", "environment", "ephemeralStorage", "fileSystemConfigs",
  "functionEventInvokeConfig", "handler", "imageConfig", "kmsKeyARN", "kmsKeyRef", "layerRefs",
  "layers", "loggingConfig", "memorySize", "name", "packageType", "publish",
  "reservedConcurrentExecutions", "role", "roleRef", "runtime", "snapStart", "tags",
  "tenancyConfig", "timeout", "tracingConfig", "vpcConfig"
]
# no "permissions" field
```

The only `permissions` array anywhere in the controller is `Alias.spec.permissions`, which is
scoped to a specific alias and cannot grant a principal invoke rights on the function itself (or
on other aliases/`$LATEST`). This is upstream, not a kro/CEL/RGD limitation — an RGD cannot create
a resource ACK does not model — so kropath-aws cannot close this gap alone.

**Upstream issue:** [aws-controllers-k8s/community#3051](https://github.com/aws-controllers-k8s/community/issues/3051)
requests a `Permission` CRD (or a `Function.spec.permissions` array analogous to
`Alias.spec.permissions`). `lambda-controller` itself has GitHub Issues disabled — ACK centralizes
issue tracking in the `community` repo.

**Current behaviour / interim position, by invoke path:**

- **EventBridge → Lambda:** fully supported today. Point the EventBridge rule target's `roleARN`
  at an IAM role holding `lambda:InvokeFunction`, instead of relying on a resource policy on the
  function. EventBridge is the one target type that supports role assumption in place of a
  resource policy. This is what the KRO-1184 guide uses.
- **S3 bucket notifications, SNS topic subscriptions, API Gateway integrations, and any other
  principal that requires a resource-based policy (no role-assumption option):** **not supported
  today.** There is no declarative (reconciled) way to grant this. In order of preference:
  1. Scope the story to EventBridge-mediated invocation, as KRO-1184 does. Preferred — no drift
     risk, fully reconciled.
  2. An out-of-band, imperative `aws lambda add-permission` step run outside kropath, with the
     explicit caveat that kro/ACK will never reconcile or detect drift on it, and a deletion of
     the kropath-managed function will not clean it up.
  3. A kropath-owned CRD plus controller support for `Permission` — a much larger commitment
     (new CRD, new controller reconciliation logic, its own AWS SDK calls) that should not be
     taken on without a second blocked story to justify the investment beyond this one.

**To unblock:** upstream `aws-controllers-k8s/lambda-controller` ships a `Permission` CRD (or
`Function.spec.permissions`) per the linked issue. Re-open this entry and wire the RGD once that
lands and the cache in `kropath-core/docs/crd-cache/aws/lambda-controller-v*.md` is refreshed to
include it.

---

## AWS Auto Scaling — `AutoScalingGroup` (aws-autoscaling-02)

### AC-23 / AC-24 — warm pool (`spec.warmPool`) is accepted but reaches nothing

**What the user can set.** The kropath `AutoScalingGroup` CRD exposes a full `spec.warmPool` block
and the API server accepts every field:

```yaml
spec:
  warmPool:
    poolState: Stopped              # Stopped | Running | Hibernated
    minSize: 1
    maxGroupPreparedCapacity: 3
    reuseOnScaleIn: true
```

**What actually happens.** Nothing. `rgds/autoscalinggroup.aws.kropath.run.yaml` never templates
these fields into the ACK `AutoScalingGroup` child, so no warm pool is created and no error is
raised. The CR reports `Ready`, `status.warmPoolSize` is never populated, and the only way a user
discovers the gap is by looking for a warm pool in the AWS console. This is a **silent no-op on a
user-visible field** — the most costly shape of gap in this register.

**Blocking constraint.** The ACK `autoscaling-controller` CRD has no spec-level warm pool field at
any version from `v1.0.1` through `v1.3.2`. `warmPoolConfiguration` and `warmPoolSize` exist **only
under `status`** and are read-only, populated by the controller from the AWS API:

```
docs/crd-cache/aws/autoscaling-controller-v1.3.2.md
  § "`warmPoolConfiguration` — status-only, no spec-level equivalent"
  "There is no `spec.warmPool` (or `spec.warmPoolConfiguration`) field in this CRD version."
```

An RGD cannot create a resource or set a field ACK does not model, so kropath-aws cannot close this
gap alone. The underlying AWS API (`PutWarmPool`) is a separate call from `CreateAutoScalingGroup`,
which is why ACK models the result but not the input.

**Interim position.** Leave the schema block in place — it is already part of the shipped CRD
surface and removing it is a breaking change for any CR that sets it. Document it as inert in
customer docs. There is no supported declarative alternative; an out-of-band
`aws autoscaling put-warm-pool` is possible but will never be reconciled, drift-detected, or cleaned
up when the kropath-managed group is deleted.

**To unblock.** Upstream `aws-controllers-k8s/autoscaling-controller` adds a spec-level warm pool
field (`spec.warmPool` or `spec.warmPoolConfiguration`) to the `AutoScalingGroup` CRD. When it does:
refresh `kropath-core/docs/crd-cache/aws/autoscaling-controller-v*.md`, wire the existing kropath
`spec.warmPool` fields straight through in the RGD, and replace AC-23/AC-24 (currently
`negative: warm-pool-inert` and `negative: warm-pool-inert-parity`) with happy-path scenarios that
assert the forwarded configuration.

**Spec reference:** `kropath-core/docs/specs/aws/aws-autoscaling-02-autoscalinggroup.md` —
AC-23, AC-24, and the `[Post-implementation discovery]` callout in § Schema Surface.
