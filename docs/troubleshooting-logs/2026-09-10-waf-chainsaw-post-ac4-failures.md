> **Point-in-time disclaimer:** This log reflects the state of the codebase at 2026-09-10. Patterns
> described here may have been superseded by later commits. Verify claims mechanically before acting.

# 2026-09-10: WAF Chainsaw — the four failures hidden behind AC-4

**Ticket:** KRO-883
**Symptom:** PR #253 CI reported exactly three failures — `wafipset`, `wafrulegroup`, `wafwebacl`,
each aborting at its `ac4-scope-immutable*` step after ~3s with:

```
($stdout): Internal error: types are not comparable, bool - string
```

## Why one symptom hid four bugs

Chainsaw stops a test at its first failing step. AC-4 sits near the top of all three suites, so
**every step after it was never executed in CI** — the run looked like a single, narrow assertion
bug. Fixing AC-4 and running the suites on a clean cluster surfaced three further failures that CI
had never reached.

Takeaway: when an early step fails in a brand-new suite, treat the remaining steps as *unverified*,
not as passing. Re-run locally end-to-end before declaring the suite fixed.

## Bug 1 — `check:` compared a string against a boolean (the CI symptom)

```yaml
check:
  ($stdout): (contains(@, 'REJECTED AS EXPECTED'))   # WRONG: string == bool
```

`($stdout)` is the *left-hand* value (a string); `(contains(@, …))` evaluates to a boolean, so the
assertion engine refuses to compare them. Canonical form puts the predicate on the left and the
expected boolean on the right:

```yaml
check:
  (contains($stdout, 'REJECTED AS EXPECTED')): true   # CORRECT
```

`contains()` is a JMESPath builtin and *is* supported by chainsaw's kyverno-json engine — unlike
CEL's `exists()`, which is not (see §6 of `frequent-rgd-errors.md`).

## Bug 2 — `--for=jsonpath='{.status.resourceName}'` is satisfied before the child exists

```yaml
# WRONG — resourceName is set by kro's naming ConfigMap, which resolves BEFORE
# the ACK child is created. The next line then races and hits NotFound.
kubectl wait wafipset ipset-tags -n wafipset \
  --for=jsonpath='{.status.resourceName}'=wafipset-ipset-tags --timeout=30s
TAGS=$(kubectl get ipsets.wafv2.services.k8s.aws ipset-tags -n wafipset -o json | jq -r '.spec.tags // []')
```

Observed gap: `kubectl wait` returned at 10:55:58; the child `IPSet` was created at 10:56:03 —
5 seconds later. The script failed with
`Error from server (NotFound): ipsets.wafv2.services.k8s.aws "ipset-tags" not found`.

```yaml
# CORRECT — kro sets Ready only once "all resources are created and ready".
kubectl wait wafipset ipset-tags -n wafipset --for=condition=Ready --timeout=60s
```

Two wafwebacl steps (AC-32, AC-33) had **no** readiness gate at all and failed the same way.

**Rule:** any `- script:` step that reads an ACK child must first gate on the kro instance's
`Ready` condition. Never gate on `status.resourceName` — that field is populated a full
reconciliation phase earlier.

## Bug 3 — bare `rulegroup` resolved to the wrong API group

```
Error from server (NotFound): rulegroups.networkfirewall.services.k8s.aws "rg-tags" not found
```

`kubectl get rulegroup` is ambiguous once **both** `rulegroups.networkfirewall.services.k8s.aws`
and `rulegroups.wafv2.services.k8s.aws` are installed; discovery picks the alphabetically-first
group (`networkfirewall`). This is the trap `tests/lint-test-scripts.sh` exists to catch — but its
`ACK_BARE_NAMES` list did not yet contain the wafv2 plurals, so the lint passed.

Fix: qualify every reference (`rulegroups.wafv2.services.k8s.aws`, `ipsets.…`, `webacls.…`) **and**
add `ipset`, `rulegroup`, `webacl` to `ACK_BARE_NAMES`. Adding them immediately flagged two
pre-existing bare `rulegroup` references in `tests/networkfirewall/networkfirewallrulegroup/` —
latent until this PR introduced the second `rulegroup` CRD, and fixed in the same commit.

**Rule:** when a PR adds an ACK CRD whose plural collides with an existing one, add the plural to
`ACK_BARE_NAMES` in the same PR and fix whatever the lint then reports in *other* suites.

## Bug 4 — AC-12 asserted a derived name while supplying an explicit one

`wafwebacl` AC-12 ("visibility metricName derived") applied
`spec.visibilityConfig.metricName: placeholder` and then asserted the child carried
`wafwebacl-block-ips`. The RGD only derives the metric name when the field is empty:

```yaml
metricName: >-
  ${schema.?spec.?visibilityConfig.?metricName.orValue("") != ""
    ? schema.spec.visibilityConfig.metricName
    : naming.data.effectiveName}
```

The test, not the RGD, was wrong — the instance must omit `metricName` for derivation to apply.
Verified directly against the cluster: a WAFWebACL with no `visibilityConfig` yields
`metricName: wafwebacl-<name>`.

## Non-bug — `{tag.env}` "unresolved" test passing on a re-run

`ac31-naming-unresolved-token` expects `status.namingStatus: invalid-unresolved-tokens` for the
template `{tag.env}-{name}`. On a **second** run in an already-used namespace it reported `valid`
with `resourceName: prod-webacl-unresolved-token`.

Cause: AC-32/AC-33 (later steps) patch `mandatory.tags.env=prod`, and `spec.skipDelete: true` keeps
the `WAFConfig` between runs. AC-31's reset patch uses `--type=merge` with `"tags":{}`, which
**does not remove existing keys** (documented trap), so the stale `env` survived and the token
resolved. CI always starts from a fresh cluster, so this is a local re-run artefact, not a test bug.

When re-running a suite locally, delete the test namespaces first:

```sh
kubectl delete ns wafconfig wafipset wafrulegroup wafwebacl
```

## Verification

Clean cluster (`kind-kropath-aws-kro883`), single run per suite:

```
--- PASS: chainsaw/waf/wafconfig[wafconfig] (0.79s)
--- PASS: chainsaw/waf/wafipset[wafipset] (38.92s)
--- PASS: chainsaw/waf/wafrulegroup[wafrulegroup] (59.67s)
--- PASS: chainsaw/waf/wafwebacl[wafwebacl] (112.24s)
Passed 4 / Failed 0

--- PASS: chainsaw/networkfirewall/... (4 suites)
Passed 4 / Failed 0
```
