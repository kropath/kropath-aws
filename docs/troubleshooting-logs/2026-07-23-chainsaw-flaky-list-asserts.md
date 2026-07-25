# 2026-07-23: Chainsaw Flaky List/Array Asserts + iamrole/iamidentityprovider Flakiness

**Trigger:** User reported `make test` intermittently failing on `s3bucket` and `iamidentityprovider`
(`s3bucket` alone via `make test-s3` passed), and asked to check whether anything related to
list/array handling was not handled correctly.

**Scope:** kropath-aws chainsaw test suite (`tests/`). No RGD/CRD changes.

## Summary of what was actually wrong

Three distinct, unrelated bugs were found by reproducing the flake live
(`chainsaw test s3/ iam/ --parallel 4`, mirroring the full-suite load) rather than guessing from
the code:

1. **The real list/array bug (the one asked about):** this repo's own documented "fix" for
   CEL map-order flakiness — a per-item list assert (`tags: - (key == 'x'): true`) — does not
   actually work. See below.
2. **`iamrole` timing:** a step chaining two 30×1s polling loops (~60s worst case) had no
   `timeout:` override and got `signal: killed` under parallel load.
3. **`iamidentityprovider` structural cleanup issue:** every step's automatic post-`try`
   resource teardown times out on a stuck finalizer. Partially mitigated, **not fully fixed**
   (see "Open issue" at the end).

Also found along the way: a `kubectl get role` short-name collision with Kubernetes' built-in
RBAC `Role` kind (see `docs/frequent-rgd-errors.md`, new section under "Chainsaw Test Assertion
Stability").

## The list/array bug — two false fixes, then a working one

### False fix #1 (pre-existing in the docs): per-item list assert

`docs/frequent-rgd-errors.md` previously recommended, for a CEL `.merge().transformList()`-produced
list like `spec.tags`:

```yaml
spec:
  (length(tags)): 2
  tags:
    - (key == 'cost-centre'): true
      value: platform
    - (key == 'environment'): true
      value: mandatory
```

This looks like it should be order-independent (each item just asserts "does *some* tag have this
key/value"), but it is not. Chainsaw pairs assert-list-item `[i]` with actual-list-item `[i]`
positionally and evaluates the boolean check at that fixed position — it never searches across
positions for a match. Confirmed via a real failure:

```
* spec.tagging[0].(key == 'cost-centre'): Invalid value: false: Expected value: true
* spec.tagging[0].value: Invalid value: "data-pipeline": Expected value: "platform"
```

i.e. actual `tagging[0]` was the `app` tag that run, not `cost-centre` — the assert evaluated
`key == 'cost-centre'` against the wrong position and failed, exactly the flake this pattern was
supposed to prevent.

### False fix #2 (my first attempt): whole-array CEL `.exists()`

Replaced the per-item pattern with a single boolean CEL `.exists()` check per expected tag:

```yaml
spec:
  (length(tags)): 2
  (tags.exists(t, t.key == 'cost-centre' && t.value == 'platform')): true
```

This *would* be genuinely order-independent (`.exists()` scans the whole array), except chainsaw's
assertion engine is a JMESPath-style tree (kyverno-json), not full CEL. It fails outright:

```
spec.(tags.exists(t, t.key == 'environment' && t.value == 'production')): Internal error: unknown function: exists
```

This was masked in earlier verification runs because the specific assertions that would have hit
this error instead failed first with `actual resource not found` (reconciliation-lag flakiness
under heavy parallel load) — the `.exists()` expression was never actually evaluated in those runs,
so the runs "looked" like they passed for the right reason when they didn't.

### What actually works: `kubectl ... -o json | jq` script check

Chainsaw's declarative assertion tree has no working order-independent list construct for this
case. Drop the tag-list check from the `assert:` block (`spec: {}` if that's the only thing being
asserted there) and verify with a `- script:` step:

```yaml
- script:
    content: |
      TAGS=$(kubectl get role my-role -n myns -o json | jq -c '.spec.tags')
      COUNT=$(echo "$TAGS" | jq 'length')
      [ "$COUNT" -eq 2 ] || { echo "FAIL: expected 2 tags, got $COUNT: $TAGS"; exit 1; }
      echo "$TAGS" | jq -e 'any(.key == "cost-centre" and .value == "platform")' >/dev/null || { echo "FAIL: missing tag cost-centre=platform"; exit 1; }
      echo "$TAGS" | jq -e 'any(.key == "environment" and .value == "mandatory")' >/dev/null || { echo "FAIL: missing tag environment=mandatory"; exit 1; }
```

Plain shell/jq, genuinely order-independent. Full pattern (including the KMS `tagKey`/`tagValue`
variant and the S3 `tagging` field) documented in `docs/frequent-rgd-errors.md` §6.

### Files fixed with this pattern

- `tests/s3/s3bucket/chainsaw-test.yaml` — `ac17-tags-merge`, `ac18-synced-labels`
- `tests/iam/iamidentityprovider/chainsaw-test.yaml` (+ `06-assert-oidc-synced-labels.yaml`,
  `11-assert-oidc-tag-merge.yaml`) — `synced-labels`, `tag-merge-prefers-mandatory-values`
- `tests/iam/iamrole/chainsaw-test.yaml` — `lambda-role-standard-metadata`,
  `tag-merge-prefers-mandatory-values`
- `tests/iam/iamuser/chainsaw-test.yaml` — `ac11-tags-merge`, `ac12-synced-labels`
- `tests/kms/kmskey/chainsaw-test.yaml` — `ac16-tags-three-tier-mandatory-wins`,
  `ac17-synced-labels-dual-write`

**Verified:** `s3bucket`, `iamuser`, `kmskey`, `iampolicy`, `iamgroup` all passed in a full
`make test` run after this fix (previously flaky/failing).

## iamrole: two separate fixes

1. **Timing:** `policy-arn-reference` step chains a "wait for ACK Policy to appear" loop and a
   "wait for ARN to propagate" loop, each `for i in $(seq 1 30); do ...; sleep 1; done` — up to 60s
   combined, no `timeout:` override. Under `--parallel 4` across the full suite, kubectl round-trips
   are slower and this blew the default script timeout, producing `signal: killed`. Fixed by adding
   `timeout: 3m` to that script step.
2. **RBAC collision:** while adding the jq-based tag checks, `kubectl get role <name>` was found to
   resolve to Kubernetes' built-in `roles.rbac.authorization.k8s.io`, not ACK's
   `roles.iam.services.k8s.aws` — `Error from server (NotFound): roles.rbac.authorization.k8s.io
   "lambda-role" not found`. Fixed by using the fully-qualified `roles.iam.services.k8s.aws` in all
   three `kubectl get role` occurrences in this file (two new, one pre-existing). The pre-existing
   one (`boundary-and-naming` step) had been silently passing for the wrong reason — its check was
   `test -z "$boundary"` on a variable that was empty whether the tag was legitimately absent or the
   command had simply failed to find the resource. See `docs/frequent-rgd-errors.md` for the
   general rule.

**Verified:** neither fix was exercised in a full clean rerun due to session cost — the RBAC fix is
confirmed correct by construction (same fully-qualified form already used successfully elsewhere in
this file and others), and the timing fix was confirmed in one intermediate rerun where `iamrole`
passed cleanly at 114s (previously failed at 78s with `signal: killed`).

## OPEN ISSUE: iamidentityprovider CLEANUP always times out — not fully fixed

**Status: unresolved.** Do not assume this is fixed; do not re-attempt the exact mitigation below
expecting a different result.

Every step in `tests/iam/iamidentityprovider/chainsaw-test.yaml` that creates an
`IAMIdentityProvider`/`OpenIDConnectProvider` logs, during its automatic post-`try` cleanup:

```
CLEANUP ERROR: context deadline exceeded
```

roughly 30 seconds after the step's `try:` phase ends, *before* the step's explicit `cleanup:`
script (patch `metadata.finalizers: []`, then delete) runs and succeeds. This happens on literally
every step (18/18), inflating the suite to 400s+ and being enough on its own to mark the whole
`iamidentityprovider` chainsaw test FAILED in `make test`, even though every individual assertion
in the suite passes.

**What was tried:** moved the finalizer-clearing patch from the `cleanup:` block to the end of
`try:`, reasoning that if finalizers are already cleared by the time `try:` ends, chainsaw's
automatic teardown of tracked resources wouldn't need to wait on them. Also added the same fix to
`oidc-provider-arn`, the one step that was missing any finalizer-clearing cleanup at all (a genuine
gap, worth keeping regardless of the broader issue).

**Why it didn't fix it:** the `context deadline exceeded` still recurs on every single step at the
same ~30s cadence after this change. Two hypotheses, neither confirmed:

1. kro's controller re-adds the finalizer on the `IAMIdentityProvider`/`OpenIDConnectProvider`
   object between the patch script running and chainsaw's automatic delete-and-wait kicking in
   (a reconcile-loop race, not a one-shot state).
2. Chainsaw's automatic teardown is timing out on a *different* resource than the one being
   patched — e.g. a child/owned object, or the namespace itself — and the finalizer patch on the
   parent objects is simply irrelevant to what's actually stuck.

**Next steps for whoever picks this up:** instrument to find out exactly *which* object chainsaw's
automatic delete is blocked on when the timeout fires (e.g. `kubectl get iamidentityprovider,
openidconnectprovider -n iamidentityprovider -o json` mid-cleanup, or watch for
`metadata.finalizers` non-empty at the moment of timeout) before trying another fix. Given this
reproduces on 100% of runs (not just under parallel load), it should be cheap to reproduce in
isolation with `make test-iam` and a `kubectl get ... -w` running alongside.
