# tenant-namespace-onboarding

Renders the plain manifests a namespace needs before any kro resource instance can reconcile in
it: the `Namespace` itself, one empty-spec `<Family>Config` per family the team declares
(ADR-015 §5.8.5, KRO-1140), and the namespace's empty-spec `KropathConfig/baseline` singleton
(ADR-015 §3.1, §5.7) for namespace-wide blanket governance overrides. It never applies
anything — output is meant to be committed to your Argo/Flux repo, or referenced as a Helm
source from an Argo CD `Application` pointed at this chart with a per-tenant values file.

This chart serves both onboarding flows from **ADR-019 D-5**, selected by `namespaceRole`:

| `namespaceRole` | Who uses it | Namespace annotations rendered | `KropathConfig`/`<Family>Config` rendered? |
| --- | --- | --- | --- |
| `local` | Developer teams onboarding a resource namespace whose family-owned cloud resources participate in the placement gate (ADR-015 §5.6). | All three: `aws.kropath.run/global-config-namespace`, `services.k8s.aws/owner-account-id`, `services.k8s.aws/default-region`. | Yes |
| `global` | Platform teams onboarding a governance-only namespace that other namespaces' `globalConfigNamespace` points at (ADR-019 D-5) — it has no resource instances of its own. | None of the three. | Yes |

Both roles render `KropathConfig/baseline` and one `<Family>Config` per declared family, named
after the `configRef` profile (default `general-policy`, override with `--set
configRef=<team-profile-name>` or in your values file) — only the `Namespace`'s annotations
differ between the two roles.

## Why this exists

Three defects collapse into one artifact (full detail: `kropath-core` KRO-1139):

- **No race.** kro and kropath-controller are independent reconcile loops with no ordering
  between them. A resource namespace with no local `<Family>Config` gets no reconcile at all
  (ADR-015 §5.9) — not a retry, a permanent stall — so the config CR must exist *before* the
  first resource instance, not be created lazily on first use.
- **No role-ARN-mismatch surface for the operator.** Nothing here removes `C-4` (a typo'd
  `ack-role-account-map` entry silently placing resources in the wrong account — see below),
  but the namespace annotation half is generated from the same `accountId` input the operator
  already has to supply, so at minimum that half is never hand-typed.
- **No kropath-native placement key.** The chart emits exactly the provider-native annotations
  ACK's own CARM integration already reads (`services.k8s.aws/owner-account-id`,
  `services.k8s.aws/default-region`) — never a parallel kropath-prefixed key that could drift
  from them with nothing to reconcile the two (ADR-019 D-3 stands; see ADR-015 §5.8.5).

## Usage

### Local (resource namespace)

```bash
cp tests/values-sample.yaml values-payments-dev.yaml
# edit values-payments-dev.yaml: namespace, globalConfigNamespace, accountId, region, families

helm template payments-dev . -f values-payments-dev.yaml > rendered/payments-dev.yaml
# commit rendered/payments-dev.yaml to your GitOps repo, or point an Argo CD Application's
# helm source at this chart + values-payments-dev.yaml directly.
```

### Global (governance-only namespace)

```bash
cp tests/values-sample-global.yaml values-platform-governance.yaml
# edit values-platform-governance.yaml: namespace, families
# (namespaceRole stays "global"; globalConfigNamespace/accountId/region are not used)

helm template platform-governance . -f values-platform-governance.yaml > rendered/platform-governance.yaml
```

`values.schema.json` rejects an invalid `namespaceRole`, a malformed `accountId` and empty
`globalConfigNamespace`/`region` when `namespaceRole` is `local` (they are unused and
unvalidated when `global`), and an empty `families` list — no cluster needed to catch any of
these at render time.

## The rendered `KropathConfig/baseline`

Every render includes one empty-spec `KropathConfig/baseline` in the tenant namespace — the
local tier of the singleton (ADR-015 §3.1, §5.7). An empty spec is valid and inherits everything
from the global tier in `globalConfigNamespace`; its absence would have been equally valid
(§3.1 — "silently skipped, not an error"). It is rendered anyway so a team that later needs a
namespace-wide blanket override (e.g. a team-specific mandatory tag, levels 2/8 of the
ten-level cascade in ADR-015 §5.3) has exactly one existing object to edit — `spec.mandatory.*`
/ `spec.defaults.*`, top-level (`tags`, `syncedLabels`, `syncedAnnotations`, `namingTemplate`) or
under a `<family>` section such as `spec.mandatory.s3` — rather than hand-deriving the schema.
Every field must be set in exactly one tier (§3.2); `KropathConfig` carries no provider
connection fields (§3.3) and is never selected by `configRef` (§3.4).

See `tests/values-sample.yaml` for a filled-in example and `family-kind-map.yaml` for the
accepted `families` slugs (generated from `crds/*config.yaml` — see
`../../hack/gen-family-kind-map.sh`).

## Why `ack-role-account-map` is not rendered here

This section applies only to `namespaceRole: local` — a `global` namespace has no `accountId`
and is not placed anywhere, so there is no role-ARN mapping to reason about for it.

The spec (KRO-1140) asked this chart to also emit the `ack-role-account-map` ConfigMap entry
for `accountId`, on the reasoning that generating it from the same input makes the C-4
role-ARN mismatch (ADR-015 §5.8.4 precondition 4) unconstructible the same way the namespace
annotation is. **Verified infeasible for v1, for two independent reasons — recorded here per
the ticket's own instruction not to drop this silently:**

1. **Shared-object, not fragment-level, GitOps ownership.** `ack-role-account-map` is one
   ConfigMap holding every onboarded account's role ARN. A plain Kubernetes manifest can only
   express whole-object ownership — there is no manifest kind for "patch in one key of an
   existing ConfigMap". If this chart rendered the full ConfigMap, every tenant's onboarding
   render would need the complete, current set of every other tenant's entries to avoid
   clobbering them on apply — which defeats the entire "one declared input block per tenant"
   design this chart exists to provide. Rendering only this tenant's key as a
   `kubectl patch`-style fragment is not expressible as a static manifest at all.
2. **Different ownership boundary.** The ConfigMap lives in the ACK system namespace, installed
   and owned by cluster/platform operators — not the application team's own GitOps app that
   owns this tenant namespace's manifests (the spec's own caveat, confirmed here). Even if (1)
   had a clean answer, merging a tenant-authored fragment into a platform-owned object from the
   tenant's own Argo/Flux App crosses an ownership boundary this chart has no business crossing.

**What this chart does instead:** the rendered `NOTES.txt` output states the exact
`{accountId: <role-ARN-placeholder>}` entry to confirm or add, and calls out precondition 4
(role ARN's account segment must equal `accountId`) explicitly, so a human still has to type
the role ARN — but never the account ID half, and never hand-copy it into YAML syntax. This is
strictly weaker than "unconstructible": a human can still bind `accountId` to a role ARN in
the wrong account. It is the honest ceiling for a per-tenant, GitOps-rendered artifact; closing
it fully needs either a platform-owned reconciler for that ConfigMap (out of scope — ADR-003
keeps kropath-controller a pure config store with no such write surface) or the
`kropath-aws` KRO-1141 install-conformance checker catching the mismatch after the fact.
