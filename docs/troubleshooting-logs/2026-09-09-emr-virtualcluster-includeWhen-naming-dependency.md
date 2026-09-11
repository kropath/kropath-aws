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
  `ackVirtualCluster` appeared to stay blocked.

## Root cause

**CORRECTED 2026-09-11 (KRO-831 follow-up).** The original conclusion below was wrong. The real
root cause of this stall was **Bug 3 — the missing kro RBAC** for `emrcontainers.services.k8s.aws`
/ `emrserverless.services.k8s.aws`. `waiting for readiness (data pending)` on a ConfigMap node is a
**transient** message that kro emits early in reconciliation; it is not a permanent state. When the
kro ServiceAccount cannot `get` the ACK child's resource, the child is never created and that
transient message is what you are left staring at. Fixing the RBAC alone unblocks it.

Referencing a ConfigMap node from another node — in `includeWhen` **or** in the `template:` body —
works. See "Evidence" below.

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

Fix applied at the time: inline the full effectiveName computation directly as `spec.name`.

**REVERTED 2026-09-11.** This was not a bug. `spec.name: ${naming.data.effectiveName}` is correct
and is what the sibling EMR RGDs (and most of `rgds/`) do; the stall was Bug 3 below. The inlined
copy has been removed — see "Key lesson — RETRACTED".

### Bug 3: Missing RBAC for `emrcontainers.services.k8s.aws` and `emrserverless.services.k8s.aws`

The kro service account ClusterRole in `tests/fixtures/rbac/kro-controller.yaml` did not include
the `emrcontainers.services.k8s.aws` or `emrserverless.services.k8s.aws` API groups, causing:
```
User "system:serviceaccount:kro-system:kro" cannot get resource "virtualclusters" in API group
"emrcontainers.services.k8s.aws" in the namespace "emrvirtualcluster"
```
Fix: added both API groups to the ClusterRole `rules[1].apiGroups` list.

## Key lesson — RETRACTED

The original lesson claimed: *"ANY reference to a ConfigMap node in an RGD node's `template:` body
creates a blocking dependency ... the status block is the only safe consumer of `naming.data.*`."*

**That is wrong.** It also cited `frequent-rgd-errors.md` §"includeWhen Must Not Read Another Node
in the Same Graph", **a section that does not exist** in this repo. Acting on it costs real work:
it forces the ~40-line `effectiveName` expression to be duplicated into every node that needs the
cloud resource name, and duplication is exactly what made the `{tag.X}` fallback bug in this same
ticket require a fix at two sites per RGD.

The actual lesson: **when a child resource is never created and the instance reports
`waiting for readiness (data pending)` on a ConfigMap node, check kro's RBAC for the child's API
group first.** The ConfigMap is almost never the problem.

## Evidence (2026-09-11)

1. `rgds/emrserverlessapplication.aws.kropath.run.yaml` and `rgds/emrjobrun.aws.kropath.run.yaml`
   both set `spec.name: ${naming.data.effectiveName}` in the ACK child template (and the serverless
   one also reads `resolved.data.*`). Both suites pass — all 37 and all 21 ACs.
2. 85 of the 194 RGDs in `rgds/` read `naming.data.*` from `includeWhen`. `tests/eks/eksnodegroup/`
   — whose `includeWhen` is exactly `${!naming.data.effectiveName.contains("{")}` — passes and
   creates all 12 ACK children.
3. Reproduced the original symptom directly: applying the EMR RGDs to a cluster **without** the
   RBAC entry produced `dependent node "resolved" not ready: waiting for readiness (data pending)`,
   then `User "system:serviceaccount:kro-system:kro" cannot get resource "applications"`. Applying
   `tests/fixtures/rbac/kro-controller.yaml` unchanged — no RGD edit — made the child appear in
   seconds, with the ConfigMap references still in place.
4. `rgds/emrvirtualcluster.aws.kropath.run.yaml` has since been reverted to
   `spec.name: ${naming.data.effectiveName}`; a fresh `EMRVirtualCluster` in a clean namespace
   produced its ACK child with `spec.name: emrvcprobe-fresh-vc`, and `make test-emr` stays green.

## Verification

After all three fixes:
- `emrvirtualcluster.aws.kropath.run` RGD reaches `Active` in 2 delete+apply rounds.
- Manual apply of `EMRVirtualCluster` with patched `EMRConfig` status:
  - `status.resourceName: emrvirtualcluster-ac1-vc` ✓
  - `status.namingStatus: valid` ✓
  - `conditions.ResourcesReady: True` — "all resources are created and ready" ✓
  - `VirtualCluster` ACK CR created in ~12s ✓
