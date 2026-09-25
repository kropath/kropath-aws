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

---

## AWS KMS — `KMSGrant` (aws-kms-03)

### AC-3 / AC-4 / AC-9 — `x-kubernetes-validations` rejection on the RGD-derived CRD

**Spec requirement:** applying a `KMSGrant` CR with both `keyRef` and `keyArn` set (AC-3), with
neither set (AC-4), or with `operations: []` (AC-9) should be rejected by the API server via
`x-kubernetes-validations`.

**Blocking constraint:** kro v0.9.2 regenerates the RGD-derived `KMSGrant` CRD from the RGD schema
on every apply and does not preserve hand-authored `x-kubernetes-validations` — confirmed
repo-wide, see `docs/frequent-rgd-errors.md` §"x-kubernetes-validations Cannot Be Auto-Generated by
kro v0.9.2". kro's SimpleSchema also has no `minItems=` marker (confirmed absent across every RGD
in this repo; see `rgds/rdsproxy.aws.kropath.run.yaml` header), so `operations: []` still satisfies
"required" presence at admission.

**Current behaviour:** all three CRs are accepted by the API server. The RGD's `gate` ConfigMap
computes a combined validity check; when any of the three conditions holds, no ACK `Grant` child is
rendered and `status.validationError` names the problem (mirrors `rgds/kmskey.yaml` AC-8 and
`rgds/dsqlcluster.aws.kropath.run.yaml`). Verified live: applying each invalid shape produces the
expected `status.validationError` string and no `grants.kms.services.k8s.aws` child.

**To unblock:** when kro preserves hand-authored `x-kubernetes-validations` on RGD-derived CRDs (or
gains native `minItems=`/cross-field validation markers), replace the `gate` ConfigMap check with
real admission-time rejection and update the three Chainsaw scenarios (`grant-key-mutual-exclusion`,
`grant-key-required`, `grant-operations-empty`) to assert on `$error != null` instead of
`status.validationError`.

### AC-30 — `configRef` fallthrough to `general-policy`

**Spec requirement:** `spec.configRef: "does-not-exist"` should cause the RGD to resolve governance
against `KMSConfig/general-policy` instead.

**Blocking constraint:** not a kro/ACK limitation — a conflict with ADR-015 §4.4/§5.2 ("RGDs carry
no fallback chain for missing input config CRs... RGDs declare exactly one `externalRef` resource
entry for config CR lookup"). No RGD in this repo performs a second config lookup when a *named*
`configRef` fails to resolve; the single-lookup `.orValue("general-policy")` pattern only covers an
*empty* `configRef`. Implementing AC-30 literally would introduce the first RGD-level config
fallback chain in the repo.

**Current behaviour:** `rgds/kmsgrant.aws.kropath.run.yaml` follows ADR-015 — an unresolvable
`configRef` makes the `rsrcCfg` lookup return an empty list, so every `effectiveConfig`-sourced
value (the operations allowlist, tags) degrades to its "tier empty" branch (no restriction, no
config-sourced tags) rather than redirecting to `general-policy`. Verified live: `configRef:
"does-not-exist"` with `operations: ["Decrypt", "Encrypt"]` and no allowlist elsewhere forwards both
operations unfiltered — the tier is empty, not silently substituted.

**To unblock:** this is a spec/ADR conflict, not a capability gap — resolve by either amending
ADR-015 to permit an RGD-level fallback chain (repo-wide change, well beyond this RGD) or amending
the `aws-kms-03-kmsgrant.md` spec's AC-30 to match the platform-wide "tier empty" behavior. Flagged
on KRO-1235 for Design Reviewer / human disposition.

### AC-5 — withholding the ACK `Grant` child until `keyRef` resolves

**Spec requirement:** when `spec.keyRef` points to a `KMSKey` whose `status.keyID` is not yet
populated, no ACK `Grant` child CR should be created; the child should appear once the key
resolves.

**Blocking constraint:** not a kro/ACK limitation — an `includeWhen` graph-read safety violation
(KRO-919 class), caught in Implementation Reviewer's PR #311 review. The only way to implement
"no child until X" is to make X part of the `includeWhen` gate that selects which of the 8
variants renders. But `keyRef` resolution requires reading `keySrc[0].status.keyID` — the
*observed state* of an independently-lifecycled sibling `KMSKey` CR, not `schema.spec` or
resolved config. `kropath-core/docs/checklists/pre-review.md`'s "includeWhen graph-read safety
check" prohibits exactly this: a structural gate that reads a sibling node cannot be safely
evaluated during that sibling's teardown — if `KMSKey/app-key` were deleted while a `KMSGrant`
still referenced it, the gate would flip `false` on the next reconcile and kro would try to
un-render an already-materialized variant, which is the "hangs in `DELETING` holding
`kro.run/finalizer`, never self-heals" failure mode KRO-919 documents (same class as the
`snssubscription.aws.kropath.run.yaml` `dlqCr` fix in
`docs/troubleshooting-logs/2026-09-24-snssubscription-includewhen-graph-read-unsafe.md`).

**Current behaviour:** `rgds/kmsgrant.aws.kropath.run.yaml`'s `childShouldExist` (the `includeWhen`
gate) is schema/resolved-config-only — it no longer reads `keySrc`. The ACK `Grant` child now
renders as soon as the `KMSGrant` CR itself is valid (key reference set, operations non-empty and
allowlist-permitted), regardless of whether `keyRef` has resolved yet. `keySrc` is still read, but
only in the `keyID` *template value* (`resolvedKeyID` in the `gate` ConfigMap) — an unresolved or
subsequently-deleted key degrades the rendered `keyID` to `""` (mirrored on
`status.resolvedKeyID`) instead of toggling the child's existence. Same tradeoff already accepted
for `rgds/acmprivatecertificate.aws.kropath.run.yaml`'s `certificateAuthorityRef` (documented in
`docs/frequent-rgd-errors.md`'s "Variant-Split Resources..." section: "`acmprivatecertificate`
was not [gated on readiness]: its gate enforced 'exactly one of ARN/Ref is set' but not 'the
referenced CA resolved'... an unresolved `caRefCr` fell through to `""`").

Verified live: applying a `KMSGrant` with `keyRef` pointing at an unresolved `KMSKey` produces an
ACK `Grant` child immediately with `spec.keyID: ""` and `status.resolvedKeyID: ""`; patching the
key's `status.keyID` updates `spec.keyID` on the existing child (no re-create); deleting the
referenced `KMSKey` afterward leaves the `Grant` child's `spec.keyID` unchanged (confirmed the
KRO-919 hazard no longer applies — the child's existence is stable regardless of the sibling's
lifecycle).

**To unblock:** none needed — this is the correct, permanent behavior for kro v0.9.2's
`includeWhen` model, not a version-gated limitation. Re-open only if kro adds a supported way to
express "structural existence contingent on a sibling's resolved state" without the teardown
hazard.

**Spec reference:** `kropath-core/docs/specs/aws/aws-kms-03-kmsgrant.md` — AC-3, AC-4, AC-5, AC-9,
AC-30.
