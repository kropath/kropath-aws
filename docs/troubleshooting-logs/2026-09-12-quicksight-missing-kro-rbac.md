> **Point-in-time note:** This log was written on 2026-09-12. Claims here reflect understanding at that date. If any claim conflicts with `docs/frequent-rgd-errors.md` or agent instructions, those higher-precedence sources win.

# QuickSight: missing kro RBAC for quicksight.services.k8s.aws causes all 4 ACK CRs not to be created (KRO-1024)

**Ticket:** KRO-1024
**Date:** 2026-09-12
**Resources affected:** QuickSightDataSource, QuickSightDataSet, QuickSightDashboard, QuickSightAnalysis
**Symptom:** All 4 QuickSight Chainsaw suites timed out on their first step. ACK child CRs (DataSource, DataSet, Dashboard, Analysis) were never created.

## CI Failure (ci_fail_streak: 2)

Both CI runs at commits `9fd7f2c` (before `ackAnalysisRef` removal) and `be1f38c` (after `ackAnalysisRef` removal) showed the same failure:

```
--- FAIL: chainsaw/quicksight/quicksightanalysis[quicksightanalysis] (300.43s)
--- FAIL: chainsaw/quicksight/quicksightdataset[quicksightdataset] (300.45s)
--- FAIL: chainsaw/quicksight/quicksightdatasource[quicksightdatasource] (300.48s)
--- FAIL: chainsaw/quicksight/quicksightdashboard[quicksightdashboard] (300.49s)
actual resource not found   (after 300s assert timeout)
```

The fact that ALL 4 suites failed on their first step simultaneously — not just QuickSightAnalysis — was the key diagnostic signal: this is an infrastructure/RBAC issue, not an RGD logic issue.

## Root Cause

`quicksight.services.k8s.aws` was missing from the kro controller's ClusterRole in `tests/fixtures/rbac/kro-controller.yaml`.

Without this RBAC entry, kro's controller cannot create, get, list, patch, update, watch, or delete resources in the `quicksight.services.k8s.aws` API group. The reconciler silently fails to create any ACK QuickSight CR — Kubernetes rejects the CREATE with a 403 Forbidden, kro treats it as an irrecoverable reconciliation error, and no child resource ever appears.

## Misattribution

The Implementation Reviewer initially diagnosed the CI failure as caused by `ackAnalysisRef` (an always-bound externalRef on the ACK Analysis kind) creating a watcher feedback loop that starved DataSource/DataSet/Dashboard reconciliation under `CONCURRENT_RECONCILES=2`. This was plausible given the symptom, and removing `ackAnalysisRef` was a valid improvement (it avoided a potential feedback loop), but it was NOT the root cause of the timeout failure. The missing RBAC was the root cause: all 4 suites failed because no ACK child of any kind could be created.

## Prior Art

Identical pattern documented for:
- WAF (`docs/troubleshooting-logs/2026-09-09-waf-missing-kro-rbac.md`) — `wafv2.services.k8s.aws` was missing.
- ECR Public (`docs/troubleshooting-logs/2026-09-11-ecrpublic-rbac-missing-apigroup.md`) — `ecrpublic.services.k8s.aws` was missing.
- OpenSearch Serverless (`docs/troubleshooting-logs/2026-09-11-opensearchcollection-missing-kro-rbac.md`) — `opensearchserverless.services.k8s.aws` was missing.

## Fix Applied

Added `quicksight.services.k8s.aws` to the `apiGroups` list in `tests/fixtures/rbac/kro-controller.yaml`, adjacent to `wafv2.services.k8s.aws`:

```yaml
      - wafv2.services.k8s.aws
      - quicksight.services.k8s.aws   # <-- added
      - ram.services.k8s.aws
```

## Verification

RGD compiles gate passed for all 4 RGDs after delete+apply: QuickSightDataSource, QuickSightDataSet, QuickSightDashboard, QuickSightAnalysis all reach `Active` in iteration 1. The RBAC fix takes effect on the next `setup.sh` run in CI, which applies `tests/fixtures/rbac/kro-controller.yaml` to the test cluster.

## Pattern

When a new ACK resource family is added to kropath-aws and Chainsaw tests show `resource not found` for ALL ACK child resources of the family (not a single resource, not a subset) after the first step of every suite:

1. Check `tests/fixtures/rbac/kro-controller.yaml` — is the API group listed?
2. If not, add it to the `apiGroups` list.
3. Confirm CRD fixtures exist under `tests/fixtures/crds/<service>/`.
4. The `test-<service>:` target must also exist in `tests/Makefile` (was already present for quicksight).
