# Chainsaw Test Redesign: Unique-Name-Per-Step + skipDelete — Root-Cause Fix for CI Hangs

**Date:** 2026-08-03
**Issue:** KRO-245 (continuation)
**Scope:** All chainsaw suites under `tests/` (rolled out one suite per commit)

## Why this document exists

Over the last several sessions the CI chainsaw runs kept hanging or timing out, and
each fix addressed a *symptom* rather than the cause. The accumulated band-aids were:

- finalizer-strip patches before every delete,
- `--wait=false` on every `kubectl delete` (123 occurrences across `tests/`),
- per-step pre-cleanup `script:` blocks (AC22–AC39 in dynamodbtable, 18 steps),
- bounded poll `script:` loops replacing plain `assert:` (19 occurrences),
- kro dynamic-controller rate-limiter env tuning in `tests/setup.sh`,
- `.chainsaw.yaml` cleanup/delete timeouts padded 2m → 3m,
- `finally:` blocks on the last step of long suites,
- `CONCURRENT_RECONCILES` tuned up to 5, then back to 2 when CI regressed.

That is the textbook "3+ fixes each surface a new symptom elsewhere → the architecture
is wrong" signal. This session stopped fixing symptoms and changed the architecture.

## The single root cause

The test cluster runs **kro but no ACK controllers** — `tests/setup.sh` installs the kro
operator plus the ACK **CRD schemas only** (`hack/install-provider-crds.sh`), never the
ACK controllers themselves. Consequently:

1. Every ACK child CR (`Table`, `Topic`, `Role`, `Bucket`, `Key`, `Queue`, `Secret`, …)
   receives an ACK finalizer (`finalizers.<svc>.services.k8s.aws`) and kro adds its own
   `kro.run/foreground-deletion` finalizer. **Nothing in the cluster ever removes them**,
   so any `kubectl delete` of such a CR blocks until manually patched.

Compounding this, every suite was written to **reuse a single resource name** (e.g.
`test-table`) across all its steps and **delete-then-recreate** it between steps to reset
state. That one decision spawned every observed failure:

| Observed failure | Direct cause (reuse-name + inter-step delete) |
|---|---|
| `kubectl delete` hangs forever | no controller removes ACK/kro finalizers |
| kro backoff compounding to 51s+ gaps | the *same* object key `<ns>/<name>` accrues per-key exponential backoff across every step |
| AC22–AC39 empty child `spec` (stale-state) | `kubectl apply` merge-patches leftover fields from the prior step onto the reused object; kro CEL bails |
| cleanup `context deadline exceeded` | 30+ accumulated CRs cascade-delete through a controller-less queue at teardown, past the timeout |
| `IAMIdentityProvider` cleanup always times out (prior OPEN ISSUE) | same controller-less cascade-delete, per step |

## The redesign

Four rules, applied per suite:

1. **Unique resource name per step.** `ac1-table`, `ac2-table`, … Each step's resource is
   its own kro object key, reconciled exactly once from a clean slate. This dissolves the
   per-key backoff accumulation *and* the stale-state-reuse class (a never-before-seen name
   cannot inherit a prior step's fields).
2. **Never delete between steps.** Remove all pre-cleanup scripts, per-step `cleanup:`
   deletes, `--wait=false`, and finalizer-strip patches. Resources simply accumulate — they
   are tiny CRs and make no cloud calls (no controller), so the cost is negligible.
3. **`spec.skipDelete: true`.** Set on each Test (chainsaw v1alpha1 supports `skipDelete` at
   Configuration, Test, and Step level; the CLI flag is `--skip-delete`). This stops
   chainsaw's own end-of-test auto-delete — the cascade that caused the cleanup-phase
   timeouts. The kind cluster is ephemeral and destroyed after the suite (`make teardown`
   / CI job end), so nothing needs deleting; namespace isolation keeps the 4 parallel
   suites apart during the run.
4. **Plain `assert:` again.** Most of the 19 poll-scripts existed only to survive the
   delete/recreate gap on a reused name. Against a fresh, monotonically-reconciling object,
   a declarative `assert:` retries value mismatches cleanly. Keep a poll only where a
   genuine multi-hop `externalRef`/`includeWhen` chain can leave the object briefly absent.

### Net effect

No finalizer hangs, no backoff accumulation, no stale-state reuse, no cleanup-cascade
timeout — and far fewer `kubectl` shell-outs (which also removes the intermittent
`signal: killed` seen after many consecutive runs). The full suite can still be run when
needed; it is simply no longer self-defeating.

## Rollout sequence (one commit per suite)

1. **This commit — documentation only** (no behavior change): this log + the new canonical
   section in `docs/frequent-rgd-errors.md`, with supersede pointers added to the five
   band-aid sections it replaces.
2. Then, one suite per commit, starting with the worst offender and working out:
   `dynamodb/dynamodbtable` → `sns/snstopic` → the IAM suites → `kms/kmskey` →
   `s3/s3bucket` → `sqs/sqsqueue` → `secretsmanager/secretsmanagersecret` → the `*config`
   / schema-validation suites. Each suite keeps its own per-Test `spec.skipDelete: true`
   during the rollout so un-converted suites are never disturbed.
3. **Final commit** — flip `spec.skipDelete: true` to the global default in `.chainsaw.yaml`,
   drop the now-redundant kro rate-limiter tuning and the 3m timeout padding from
   `tests/setup.sh` / `.chainsaw.yaml` if the converted suites no longer need them, and
   remove the per-Test flags made redundant by the global default.

Each per-suite commit must pass `cd tests && make test-<service>` locally before moving on
(per CLAUDE.md's local test gate).

## Superseded sections in `docs/frequent-rgd-errors.md`

The following entries documented the *symptoms* of the reuse-name + delete architecture and
are superseded by the canonical pattern (they are kept for historical context, each with a
pointer at its head):

- "Chainsaw `cleanup:` Blocks Run at End-of-File — Reused Resource Names Need Explicit Pre-Cleanup"
- "kro Dynamic-Controller Rate Limiter Compounds Backoff Under Rapid Test Churn"
- "Chainsaw Cleanup Timeout — kro Cascade Deletion Queue Backup"
- "Chainsaw `assert:` Retries a Value Mismatch, But Not a Completely Missing Resource"
- "OPEN ISSUE: `IAMIdentityProvider`/`OpenIDConnectProvider` CLEANUP Always Times Out" (now resolved by `skipDelete`)
