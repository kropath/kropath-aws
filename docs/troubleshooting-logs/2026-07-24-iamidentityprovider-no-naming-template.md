# IAMIdentityProvider: Remove namingTemplate/effectiveName Support

**Date:** 2026-07-24
**Resource:** `rgds/iamidentityprovider.yaml`, `tests/iam/iamidentityprovider/chainsaw-test.yaml`
**Related:** KRO-236 (`{tag.X}` dynamic naming template tokens in IAM RGDs)

## What Failed

KRO-236 added `{tag.X}` dynamic naming-template support to every IAM RGD, including
`IAMIdentityProvider`. That RGD gained a `naming` ConfigMap computing `effectiveName` from
`nameOverride` / `namingTemplate` / `{tag.X}` tokens, and:

- `status.resourceName` was set to `${naming.data.effectiveName}`
- `status.namingStatus` was set from whether `effectiveName` still contained unresolved `{tag.X}` tokens
- the child `OpenIDConnectProvider`'s `metadata.name` (the **Kubernetes object name**) was set to
  `${naming.data.effectiveName}` instead of `${schema.metadata.name}`

This is wrong at the root, not just buggy in detail: `IAMIdentityProvider` has no cloud resource
name to compute in the first place.

## Why

Checked `kropath-core/docs/crd-cache/aws/iam-controller-v1.4.2.md` (the CRD cache for the IAM ACK
controller) for the `OpenIDConnectProvider` CRD's spec fields:

| Field | Type | Required / Optional |
|---|---|---|
| `clientIDs` | `array` | optional |
| `tags` | `array` | optional |
| `thumbprints` | `array` | optional |
| `url` | `string` | required |

No `name` field. AWS identifies an OIDC identity provider by its URL — and, once created, by an
ARN derived from that URL (`arn:aws:iam::<account>:oidc-provider/<url-without-scheme>`), never by
a name. `SAMLProvider` (the RGD's other `spec.type`) isn't even implemented by the ACK IAM
controller — it's modeled as an advisory `ConfigMap` with `data.status: UNSUPPORTED` (see
`docs/frequent-rgd-errors.md` §"ACK IAM Does Not Support SAMLProvider").

So `namingTemplate`/`{tag.X}`/`nameOverride` had nothing to drive for this RGD. Worse, wiring the
computed `effectiveName` into the child `OpenIDConnectProvider`'s `metadata.name` broke a
separate, unconditional rule: the **Kubernetes child resource name** must always be
`${schema.metadata.name}` — it is never derived from a naming template, because the RGD instance
name is already unique per namespace. Naming templates only ever apply to the **cloud** resource
name (`spec.name` on the child, when the target ACK CRD has one).

## What Was Tried

Only one approach was needed once the CRD cache was checked — this wasn't a multi-attempt
exploration. The fix is a straight removal of everything the naming-template feature had added to
this specific RGD:

1. **`rgds/iamidentityprovider.yaml`:**
   - Removed the `naming` ConfigMap resource entirely (was computing `effectiveName` via the
     `{tag.X}` cascade — see `docs/frequent-rgd-errors.md` §"Cross-Tier Tag/Label Merge" for the
     pattern this was reusing).
   - Changed `oidcProvider.metadata.name` from `${naming.data.effectiveName}` back to
     `${schema.metadata.name}` (this was already fixed by a human before this session, at the line
     the ticket pointed to).
   - Removed `status.resourceName` and `status.namingStatus` (and their `additionalPrinterColumns`
     entries) — nothing to report.
   - Added a `ProviderArn` printer column (pointing at the pre-existing `status.providerArn`) in
     place of the removed naming columns, so the CRD still surfaces a useful at-a-glance identifier.
   - Left `spec.nameOverride` in the schema (required by this repo's CLAUDE.md "Never do: Omit
     `spec.nameOverride`...") but added a comment documenting it as an intentional no-op for this
     resource type.

2. **`tests/iam/iamidentityprovider/chainsaw-test.yaml`:**
   - Removed the `naming-template` and `mandatory-naming-template-wins` steps entirely (and their
     now-orphaned fixtures `10-oidc-naming-template.yaml`, `10-assert-oidc-naming-template.yaml`,
     `12-oidc-mandatory-naming.yaml`, `12-assert-oidc-mandatory-naming.yaml`) — these scenarios
     tested a feature that should never have existed for this RGD.
   - Removed all three `kro236-*` steps (`kro236-iamidp-tag-token-resolved-from-spec-tags`,
     `kro236-iamidp-tag-token-unresolved-invalid-status`,
     `kro236-iamidp-mandatory-tag-overrides-spec-tag`) for the same reason.
   - Fixed `kro222-configref-labelselector` (a KRO-222 `externalRef` label-selector regression
     test, unrelated to naming): its fixture IAMConfig had `mandatory.namingTemplate:
     "kro222-{name}"` and asserted the child `OpenIDConnectProvider`'s name as
     `kro222-kro222-oidc`. Since namingTemplate no longer applies, changed the fixture's
     `namingTemplate` to `""` and the assertion (plus the two `kubectl patch ... --type=merge`
     finalizer-clear commands referencing the same name) to the correct `kro222-oidc` (==
     `schema.metadata.name`).
   - Added a new regression step, `nameoverride-and-naming-template-are-noop-for-oidc`: sets a
     non-empty mandatory `namingTemplate` (with an unresolved `{tag.X}` token, which would have
     produced `namingStatus: invalid-unresolved-tokens` under the old code) and a non-empty
     `spec.nameOverride`, then asserts the child `OpenIDConnectProvider`'s `metadata.name` is
     unaffected and still equals the instance's own `schema.metadata.name`. This is the guard
     against this regression recurring.
   - All other steps (`oidc-create`, `oidc-provider-arn`, `saml-provider-arn`, `eks-irsa-trust`,
     `https-validation`, `mandatory-tags`, `synced-labels`, `standard-metadata`,
     `tag-merge-prefers-mandatory-values`, `retain-delete-policy`, `delete-delete-policy`) already
     used `metadata.name` equal to `schema.metadata.name` with no naming-template prefix, so they
     needed no changes — they were unaffected by the original bug because none of them set a
     non-default `namingTemplate`.

## What Worked

- Debug loop: `kubectl apply -f rgds/iamidentityprovider.yaml` → RGD `Active` → `kubectl delete crd
  iamidentityproviders.aws.kropath.run` (kro re-derives the CRD from the new schema) → RGD still
  `Active` after re-derivation.
- `chainsaw test iam/iamidentityprovider --parallel 2` — 1/1 suite passed in 11.17s (isolated run).
- Full `chainsaw test iam/ --parallel 4` (equivalent of `make test-iam`) — 9/9 suites passed,
  `iamidentityprovider` in 50.41s. Notably not the 400s+ this suite previously took per the open
  `CLEANUP ERROR: context deadline exceeded` issue documented in `docs/frequent-rgd-errors.md`
  §"OPEN ISSUE: `IAMIdentityProvider`/`OpenIDConnectProvider` CLEANUP Always Times Out" — that issue
  did not reproduce in this run, but it wasn't specifically targeted here and should still be
  treated as unresolved/intermittent until independently re-verified.

## Rule for Future RGDs

Before adding naming-template / `{tag.X}` / `effectiveName` support to any RGD (new or existing),
check `kropath-core/docs/crd-cache/aws/<controller>.md` (or the equivalent GCP/Azure cache once
those exist) for a `name` field on the target ACK/KCC/ASO CRD. If the CRD has no name field, the
cloud resource has no name to compute — skip the naming-template pattern for that RGD entirely
rather than retrofitting it "for consistency." The Kubernetes child resource's `metadata.name` is
unconditionally `${schema.metadata.name}` regardless of whether naming-template applies.

See also: `docs/frequent-rgd-errors.md` §"IAMIdentityProvider Has No Cloud Resource Name —
namingTemplate Does Not Apply" (added alongside this log).
