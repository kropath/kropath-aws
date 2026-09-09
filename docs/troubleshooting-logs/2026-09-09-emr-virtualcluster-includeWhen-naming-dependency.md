> **Point-in-time disclaimer:** This log records what was observed at the time of writing. kro behaviour may change in future versions. Verify mechanically before acting on these findings.

# EMR VirtualCluster: ConfigMap readiness dependency blocks ackVirtualCluster creation

**Date:** 2026-09-09
**Ticket:** KRO-831
**Resource:** EMRVirtualCluster (`emrvirtualcluster.aws.kropath.run`)
**Author:** Implementer

## Symptoms

- CI: `emrvirtualcluster` Chainsaw E2E test times out after 300s — VirtualCluster ACK CR never created.
- Local reproduction: `EMRVirtualCluster` conditions show `ResourcesReady: False` with message:
  `"waiting for readiness (data pending)"` on the `naming` ConfigMap node.
- Even after fixing `includeWhen` to not reference the `naming` node (see Bug 2a below), the
  `ackVirtualCluster` is still blocked because `ackVirtualCluster.template.spec.name: ${naming.data.effectiveName}`
  creates an implicit kro dependency on the `naming` ConfigMap node.

## Root cause

kro v0.9.2 ConfigMaps have no status subresource, so they never reach "ready" state. Any RGD node
that references a ConfigMap node — even in its `template:` body (not just in `includeWhen`) — will
stall waiting for that ConfigMap to become "ready".

Three bugs found in `rgds/emrvirtualcluster.aws.kropath.run.yaml`:

### Bug 1: `releaseLabel` mutual-exclusion violation in AC-1 test fixtures

`emrserverlessapplication/chainsaw-test.yaml` and `emrjobrun/chainsaw-test.yaml` AC-1 fixtures
set `releaseLabel` in both `mandatory` AND `defaults` tiers, violating the `x-kubernetes-validations`
mutual-exclusion rule on `EMRConfig`. Fix: removed `releaseLabel` from `defaults` in both AC-1 fixtures.

### Bug 2a: `includeWhen` references `naming` ConfigMap node

Original:
```yaml
includeWhen:
  - >-
    ${!naming.data.effectiveName.contains("{")}
```
ConfigMaps are never "ready" → `includeWhen` condition stalls forever.

Fix: compute the naming template selection inline using `schema.spec` and `rsrcCfg` only, with
`.contains("{tag.")` as the gate (conservative proxy for unresolved tokens):
```yaml
includeWhen:
  - >-
    ${!((schema.spec.nameOverride != "" ? schema.spec.nameOverride : ...).contains("{tag."))}
```

### Bug 2b: `ackVirtualCluster.template.spec.name` references `naming` ConfigMap node

Even with the `includeWhen` fix, the ackVirtualCluster template body had:
```yaml
spec:
  name: ${naming.data.effectiveName}
```
This creates a kro graph dependency on the `naming` node, which never becomes "ready".

Fix: inline the full effectiveName computation (same `transformList`-based expression as in the
naming ConfigMap's `data.effectiveName`) directly as `spec.name`. The naming ConfigMap node
remains in the RGD for status reporting (status block expressions are evaluated separately and
are not blocked by node readiness) but is no longer referenced from the ackVirtualCluster template.

### Bug 3: Missing RBAC for `emrcontainers.services.k8s.aws` and `emrserverless.services.k8s.aws`

The kro service account ClusterRole in `tests/fixtures/rbac/kro-controller.yaml` did not include
the `emrcontainers.services.k8s.aws` or `emrserverless.services.k8s.aws` API groups, causing:
```
User "system:serviceaccount:kro-system:kro" cannot get resource "virtualclusters" in API group
"emrcontainers.services.k8s.aws" in the namespace "emrvirtualcluster"
```
Fix: added both API groups to the ClusterRole `rules[1].apiGroups` list.

## Key lesson

**ANY reference to a ConfigMap node in an RGD node's `template:` body creates a blocking dependency.**
The `includeWhen` restriction (documented in `frequent-rgd-errors.md` §"includeWhen Must Not Read
Another Node in the Same Graph") extends to `template:` field values as well. To use a ConfigMap
for naming, its computed value must be duplicated inline in any node that needs it for cloud
resource creation — the status block is the only safe consumer of `naming.data.*` references.

## Verification

After all three fixes:
- `emrvirtualcluster.aws.kropath.run` RGD reaches `Active` in 2 delete+apply rounds.
- Manual apply of `EMRVirtualCluster` with patched `EMRConfig` status:
  - `status.resourceName: emrvirtualcluster-ac1-vc` ✓
  - `status.namingStatus: valid` ✓
  - `conditions.ResourcesReady: True` — "all resources are created and ready" ✓
  - `VirtualCluster` ACK CR created in ~12s ✓
