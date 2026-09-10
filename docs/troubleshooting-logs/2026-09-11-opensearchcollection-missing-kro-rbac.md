> **Point-in-time note:** This log was written on 2026-09-11. Claims here reflect understanding at that date. If any claim conflicts with `docs/frequent-rgd-errors.md` or agent instructions, those higher-precedence sources win.

# OpenSearchCollection: missing kro RBAC for opensearchserverless causes ACK Collection not to be created (KRO-885)

**Ticket:** KRO-885
**Date:** 2026-09-11
**Resource affected:** OpenSearchCollection (`opensearchcollection.aws.kropath.run`)
**Symptom:** All 15 Chainsaw AC scenarios timed out. The ACK Collection CR was never created even after the `includeWhen` removal fix (see `2026-09-11-opensearchcollection-includewhen-naming-configmap.md`).

## CI Failure (ci_fail_streak: 2)

CI check "RGD Tests" still failed on `chainsaw/opensearch/opensearchcollection` after the `includeWhen` fix:

```
step ac1-type-search
assert: resource not found: collections.opensearchserverless.services.k8s.aws
```

## Root Cause

`opensearchserverless.services.k8s.aws` was missing from the kro controller's ClusterRole in `tests/fixtures/rbac/kro-controller.yaml`.

The file listed `opensearchservice.services.k8s.aws` (for OpenSearch domains) but NOT `opensearchserverless.services.k8s.aws`. Without this RBAC entry, kro's controller cannot create, get, list, patch, update, watch, or delete resources in the `opensearchserverless.services.k8s.aws` API group. The reconciler silently fails to create the ACK Collection CR — Kubernetes rejects the CREATE with a 403 Forbidden, kro treats it as an irrecoverable reconciliation error, and the child resource never appears.

## Prior Art

Identical pattern documented for:
- WAF (`docs/troubleshooting-logs/2026-09-09-waf-missing-kro-rbac.md`) — `wafv2.services.k8s.aws` was missing.
- ECR Public (`docs/troubleshooting-logs/2026-09-11-ecrpublic-rbac-missing-apigroup.md`) — `ecrpublic.services.k8s.aws` was missing.

In both cases, the ACK child resource was never created despite the RGD being Active. The fix in all three cases is the same: add the missing API group to `tests/fixtures/rbac/kro-controller.yaml`.

## Fix Applied

Added `opensearchserverless.services.k8s.aws` to the `apiGroups` list in `tests/fixtures/rbac/kro-controller.yaml`, adjacent to `opensearchservice.services.k8s.aws`:

```yaml
      - opensearchservice.services.k8s.aws
      - opensearchserverless.services.k8s.aws   # <-- added
```

## Verification

This fix requires a CI run to verify (no local cluster available in this session for `setup.sh`). The root cause is mechanically confirmed: the API group was absent from the ClusterRole and `setup.sh` installs that ClusterRole via `kubectl apply -f "${SCRIPT_DIR}/fixtures/rbac/kro-controller.yaml"` (line 40).

## Pattern

When a new ACK resource family is added to kropath-aws and the Chainsaw tests show `resource not found` for the ACK child even after the RGD is Active:

1. Check `tests/fixtures/rbac/kro-controller.yaml` — is the API group listed?
2. If not, add it to the `apiGroups` list.
3. The CRD fixture must also exist under `tests/fixtures/crds/<service>/` — that was already present for opensearch (`opensearchserverless.services.k8s.aws_collections.yaml`).
