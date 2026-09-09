> **Point-in-time disclaimer:** This log reflects the state of the codebase at 2026-09-09. Patterns
> described here may have been superseded by later commits. Verify claims mechanically before acting.

# 2026-09-09: WAF Chainsaw AC-1 — `actual resource not found` due to missing kro RBAC

**Ticket:** KRO-883
**Symptom:** All three WAF test suites (wafipset, wafrulegroup, wafwebacl) timeout after 300s at AC-1 with `actual resource not found` for the ACK child resources (IPSet, RuleGroup, WebACL).

## Root cause

`tests/fixtures/rbac/kro-controller.yaml` did not include `wafv2.services.k8s.aws` in the kro controller's ClusterRole `apiGroups` list. Without this entry, kro receives a `Forbidden` error when attempting to create `wafv2.services.k8s.aws/IPSet`, `wafv2.services.k8s.aws/RuleGroup`, or `wafv2.services.k8s.aws/WebACL` resources, and the child resources are never created. Chainsaw waits the full 5-minute AssertTimeout before failing.

## Evidence

- CI log: RGDs reach `Active` state (kro validates the graph) but child resources are never created.
- `grep -n "waf\|WAF\|wafv2" tests/fixtures/rbac/kro-controller.yaml` returned 0 matches.
- Identical failure pattern seen in KRO-992 (mwaa.services.k8s.aws missing from RBAC).

## Fix

Added `wafv2.services.k8s.aws` to the `apiGroups` list in `tests/fixtures/rbac/kro-controller.yaml` alongside the other ACK service API groups.

```yaml
# before
- mwaa.services.k8s.aws
- ram.services.k8s.aws

# after
- mwaa.services.k8s.aws
- wafv2.services.k8s.aws
- ram.services.k8s.aws
```

## Checklist for new service families

Whenever a new service family is added to this repo, verify:
1. `tests/fixtures/crds/<service>/` — stub CRDs for ACK resource kinds
2. `tests/fixtures/rbac/kro-controller.yaml` — `<service>.services.k8s.aws` in apiGroups
3. `test-<service>:` target in `tests/Makefile`
4. `rgds/` and `crds/` files prefixed with service name for `select-tests.sh` routing
