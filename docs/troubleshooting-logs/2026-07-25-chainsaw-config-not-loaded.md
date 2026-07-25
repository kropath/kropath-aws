# 2026-07-25: `.chainsaw.yaml` Was Never Loaded — CI-only "signal: killed" on iamgroup/iamuser

**Trigger:** CI failed on `iamgroup | ac5-resource-name | SCRIPT | ERROR: signal: killed` for a
commit that only changed a comment. `make test` passed locally on the same commit.

**Scope:** `tests/Makefile`, `tests/iam/iamgroup/chainsaw-test.yaml`,
`tests/iam/iamuser/chainsaw-test.yaml`. No RGD/CRD changes.

## Root cause

`.chainsaw.yaml` at the repo root declares generous timeouts (`apply: 30s`, `assert: 5m`,
`delete: 2m`, `error: 30s`, `exec: 5m`) specifically to give polling-loop script steps headroom
under `--parallel` load. **But no target in `tests/Makefile` ever passed `--config` to chainsaw**,
and Chainsaw v0.2.15 does not auto-discover a config file in a parent directory (or even the
current directory) — it silently falls back to its own hardcoded defaults instead:
`apply: 5s`, `assert: 30s`, `cleanup: 30s`, `delete: 15s`, `error: 5s`, `exec: 5s`.

Confirmed empirically:

```
$ chainsaw test iam/iamgroup --parallel 4
Loading default configuration...
- ExecTimeout 5s

$ chainsaw test iam/iamgroup --config ../.chainsaw.yaml --parallel 4
Loading config (../.chainsaw.yaml)...
- ExecTimeout 5m0s
```

Every `script:` step without a per-step `timeout:` override has therefore been running on a
**5-second** exec timeout since `.chainsaw.yaml` was introduced — not the intended 5 minutes.
`iamgroup` and `iamuser` have several steps with `for i in $(seq 1 30); do ...; sleep 1; done`
polling loops (waiting for kro to reconcile a child resource). Locally, reconciliation is usually
fast enough that the loop breaks in 1-2 iterations, comfortably inside 5s. In CI (`--parallel 4`
across the whole suite, on a resource-constrained `ubuntu-latest` runner, with `make chainsaw-e2e`
and `make test` both run in the same job back-to-back), reconciliation is slower and the loop can
still be running when the 5s exec timeout fires, so chainsaw sends SIGKILL to the script process —
`signal: killed`. This is inherently timing-dependent, which is why it's flaky and uncorrelated
with the actual diff in the triggering commit (a comment-only change).

This is the same underlying failure mode already documented in
`docs/troubleshooting-logs/2026-07-23-chainsaw-flaky-list-asserts.md` for `iamrole`'s
`policy-arn-reference` step — but that fix (`timeout: 3m` on the specific step) only patched the
one step that had already been observed failing. It did not address the fact that `.chainsaw.yaml`
itself was never being loaded, so every other unprotected polling-loop step across the suite
(`iamgroup` had 10, `iamuser` had 1 two-loop step) remained exposed to the same 5s default and can
still flake under load.

## Fix

1. **`tests/Makefile`** — added `CHAINSAW_CONFIG := ../.chainsaw.yaml` and `--config
   $(CHAINSAW_CONFIG)` to every `chainsaw test` invocation (`test`, `chainsaw-e2e`, `test-iam`,
   `test-policy`, `test-kms`, `test-s3`, `test-sqs`). This is the real fix — it restores the
   suite-wide 5-minute exec timeout the repo already intended.
2. **`tests/iam/iamgroup/chainsaw-test.yaml`** — added explicit `timeout: 3m` to all 10
   polling-loop script steps (`ac1` through `ac8`), as defense in depth matching the existing
   `iamrole` precedent, in case any single step's polling loop genuinely needs more than 5 minutes
   under extreme load.
3. **`tests/iam/iamuser/chainsaw-test.yaml`** — same `timeout: 3m` fix applied to the
   `ac8-policy-ref-user` step's two-loop script (same shape as `iamrole`'s already-fixed
   `policy-arn-reference` step).

**Verified:** `make test` (full 17-file suite, all services) passed locally with 0 failures/errors
after both fixes, including `iamgroup` (51.6s) and `iamuser`. Confirmed `--config` is now honored
(`ExecTimeout 5m0s` printed at test start instead of the previous silent `5s` default).

## Note for future sessions

Other `chainsaw-test.yaml` files with unprotected `for i in $(seq 1 30)` polling loops (any file
without a per-step `timeout:` override) were relying entirely on the now-fixed suite-wide 5m
default. They should no longer flake now that `--config` is wired up, but if a *new* flake shows
`signal: killed` again, check first whether the offending step's polling loop is unusually long
(e.g. chained loops like `iamrole`/`iamuser`'s two-loop ARN-wait pattern) and needs its own
`timeout:` override beyond 5m, rather than re-diagnosing the config-loading issue from scratch.
