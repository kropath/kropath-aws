> **Point-in-time disclaimer:** This log records what was observed and believed at the time of
> writing (2026-09-08). Claims here are hypotheses unless mechanically verified. If this log
> conflicts with `frequent-rgd-errors.md` or agent instructions, those sources win.

# `select-tests.sh` picked the wrong diff base on PRs — same commit, two different CI verdicts

## Symptom

Two CI runs on PR #243, **both on commit `58017d7`**, disagreed:

| | [34199440638](https://github.com/kropath/kropath-aws/actions/runs/34199440638) | [34204699057](https://github.com/kropath/kropath-aws/actions/runs/34204699057) |
|---|---|---|
| Verdict | success | failure |
| `BASE_SHA` | `07c903d` | `289b6cb` |
| Selected target | `make test-sagemaker` | `make test` (full suite) |
| Duration of "Run tests" | 74 s | 12 min |
| Result | 24 passed / 0 failed | 229 passed / **2 failed** |

This reads as flakiness. It is not. Both runs were deterministic given their inputs; the inputs
differed. The cluster state was **identical** — the `Setup test environment` step of *both* runs
logged the same two broken NetworkFirewall RGDs. The green run simply never ran their suites.

The 2 failures were:

```
--- FAIL: chainsaw/networkfirewall/networkfirewallrulegroup (60.32s)
--- FAIL: chainsaw/networkfirewall/networkfirewallfirewall  (60.32s)
```

Both are pre-existing `main` breakage tracked as **KRO-1066**, not caused by PR #243:

- `networkfirewallfirewall` — status expr `ackFirewallRef[0].?status.?firewallARN` →
  `undefined field 'firewallARN'`
- `networkfirewallrulegroup` — `spec.ruleGroup.referenceSets` type mismatch, `iPSetReferences`
  exists in output but not in the expected type

## Root cause

`.github/workflows/rgd-tests.yaml` fed the diff base to `tests/select-tests.sh` as:

```yaml
BASE_SHA: ${{ github.event.before || github.event.pull_request.base.sha }}
```

Neither operand is the right base for a PR.

### 1. `github.event.before` covers only the latest push

The workflow comment argued that `base.sha` "would accumulate the whole PR's diff forever, so it
must be the fallback, not the primary." That has it backwards — accumulating the whole PR diff
**is the job of a merge gate**. Selecting on the last push alone produces silent false-greens:

> push #1 touches sagemaker → run #1 selects `test-sagemaker`
> push #2 touches only iam  → run #2 selects `test-iam`, goes green

The head commit now shows green while the SageMaker changes were never validated against the
final tree. Same class of trap as the `main`-side subset illusion described in
`2026-09-08-kro1064-sagemaker-main-ci-regression.md`.

### 2. `github.event.before` is not guaranteed to be an ancestor of the head

This is what actually produced the divergence above. The failing run was the `synchronize` event
for a **force-push that reset the branch backwards**, from `289b6cb` to `58017d7`. `289b6cb`
("fix(KRO-1064): correct networkfirewall RGD field paths and schema names") is **not** in PR
#243's commit list — it was discarded.

So `git diff 289b6cb..58017d7` was a **reverse diff describing the work that was undone**:

```
rgds/networkfirewallfirewall.aws.kropath.run.yaml
rgds/networkfirewallrulegroup.aws.kropath.run.yaml
tests/fixtures/crds/networkfirewall/networkfirewall.services.k8s.aws_firewalls.yaml   <-- SHARED_PATTERN
tests/networkfirewall/networkfirewallfirewall/chainsaw-test.yaml
tests/networkfirewall/networkfirewallrulegroup/chainsaw-test.yaml
```

`tests/fixtures/` matches `SHARED_PATTERN` → `full_suite()` → all 24 suites. Garbage input,
arbitrary output. It failed *loud* here (over-selection), but the same flaw under-selects just as
easily when a branch is force-pushed forward.

### 3. `pull_request.base.sha` is the branch tip, not the merge-base

The fallback is also wrong, in the opposite direction. `base.sha` tracks the target branch tip and
drifts as `main` advances, so commits that landed on `main` **after** the branch forked get
attributed to the PR — pulling in unrelated suites and reporting failures the PR did not cause.
The workflow comment asserting `base.sha` "is the merge-base with the target branch" is incorrect.

## Fix

The base for a `pull_request` must be the **merge-base of the target branch with the PR head** —
`git diff base...HEAD` semantics. That is exactly "what this PR changed", independent of whatever
has since landed on `main`.

**`.github/workflows/rgd-tests.yaml`** — pass the target *branch*, not a SHA, and let the script
resolve the merge-base. `BASE_REF` and `BASE_SHA` are mutually exclusive by event type; each
expands to `""` on the event it does not apply to:

```yaml
BASE_REF: ${{ github.event.pull_request.base.ref }}   # pull_request only
BASE_SHA: ${{ github.event.before }}                  # push (main) only
HEAD_SHA: ${{ github.event.pull_request.head.sha || github.sha }}
```

**`tests/select-tests.sh`** — two changes:

1. When `BASE_REF` is set, resolve `origin/<ref>` (falling back to a local ref, then to one
   explicit `git fetch`; `full_suite` if the branch cannot be located) and compute
   `git merge-base "$base_tip" "$HEAD_SHA"`.
2. New guard on the push path — the base must be an ancestor of the head, or the diff is
   meaningless:

```bash
if ! git merge-base --is-ancestor "${BASE_SHA}" "${HEAD_SHA}" 2>/dev/null; then
  full_suite
fi
```

A merge-base is an ancestor by construction, so this only ever fires for `github.event.before`
after a force-push — precisely the case that broke run 34204699057.

`fetch-depth: 0` was already set on the checkout step, so full history and `origin/main` are
available for the merge-base computation.

## Tests

New: **`tests/select-tests-test.sh`**, wired in as `make test-select-tests` and run in CI as its
own step *before* the selection step that depends on it. Each case builds a throwaway git repo
with a real commit graph — real git, real merge-bases, no mocking of the script under test. Needs
no cluster, ~1s.

Confirmed meaningful by running the suite against the pre-change script (`SELECT_TESTS_SH=`
override): **5 of the 10 cases fail on the old script**, including the exact regression and the
force-push case. The other 5 pass on both — they guard behavior that had to be preserved.

```
ok  PR diff excludes commits that landed on main after the fork      <-- fails on old
ok  a shared-file change on main does not escalate to the full suite <-- fails on old
ok  selects the union of every push in the PR, not just the last     <-- fails on old
ok  non-ancestor BASE_SHA (force-push) falls back to the full suite  <-- fails on old
ok  a non-resource change selects no per-service suite               <-- fails on old
ok  push event uses BASE_SHA (the push delta)
ok  a shared file changed BY THE PR still escalates to the full suite
ok  an RGD with no matching Makefile target escalates to the full suite
ok  an unknown BASE_REF falls back to the full suite
ok  an empty base falls back to the full suite
```

## Consequence for PR #243 — read this before assuming the fix broke something

Under the corrected logic, PR #243 selects the **full suite**, and that is the right answer. Its
own diff against the merge-base `4af5b41` includes `tests/fixtures/rbac/kro-controller.yaml` — a
shared RBAC change that legitimately affects every service:

```bash
$ BASE_REF=main HEAD_SHA=58017d7 ./tests/select-tests.sh
test
```

So PR #243 will now surface the two KRO-1066 NetworkFirewall failures on every run. **Those are
pre-existing `main` breakage, not a regression from this change.** The earlier 74-second green run
was the false result; the red one was closer to the truth, even though it arrived there by a
broken route. PR #243 stays red until KRO-1066 lands.

## Takeaways

- **A green CI run on this repo proves only that the *selected* suites passed.** Always check
  which target the `Select tests for changed files` step actually chose before reading a green
  check as "the branch is clean". This is the third incident in this class.
- **`github.event.before` is not a safe diff base.** It is not an ancestor of the head after a
  force-push, and it only ever describes one push. For a PR gate, use the merge-base.
- **`pull_request.base.sha` is not the merge-base**, despite what the old workflow comment
  claimed. Compute the merge-base explicitly with `git merge-base`.
- **Selection logic that gates test coverage needs its own tests.** `select-tests.sh` decided
  which suites ran for months with no test of its own; a wrong answer there is invisible by
  construction, because the output is "fewer tests ran" rather than an error.
