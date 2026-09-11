# RecycleBinRule — assert races and stale `effectiveConfig` keys (KRO-1040)

Found while rebasing PR #260 onto `main` and reproducing the CI failure locally.

## 1. `ac4-retention-defaults-when-instance-unset` timed out in CI (300s)

Already fixed by `07fdc71` (effective-retention cascade in `includeWhen`), but that commit
was never validated: the next CI run died in `make setup` before any test ran. Confirmed
passing locally in this session.

## 2. `ac12` / `ac13` / `ac14` ran `- script:` directly after `- apply:`

`apply` returns as soon as the parent `RecycleBinRule` is admitted — the ACK `Rule` child
does not exist yet. The `kubectl get rules... | jq` script therefore failed with
`Error from server (NotFound)` / `exit status 4`.

**Fix:** insert an `- assert:` on the child `Rule` between the `apply` and the `script`,
matching the existing repo convention (`tests/documentdb/documentdbsubnetgroup` AC-9).
`assert` retries until the child materializes; the script then only validates content.

## 3. `mandatory.retentionPeriodValue: 365` leaked out of `ac6` into every later step

`ac6` sets `mandatory.retentionPeriodValue: 365`, then its reset script re-patches
`mandatory` *without* that key. A `--type=merge` patch never removes keys, so `365`
survived and every subsequent step (and every re-run, because `skipDelete: true` keeps the
namespace) saw it. Locally this surfaced as `ac1` asserting `retentionPeriodValue: 7` but
reading `365`.

**Fix:** every `kubectl patch recyclebinconfig ... --subresource=status` in the suite is now
preceded by a null-out patch:

```sh
kubectl patch recyclebinconfig <name> -n recyclebinrule \
  --subresource=status --type=merge -p '{"status":{"effectiveConfig":null}}'
```

This is the two-command pattern already documented in `CLAUDE.md`
(“Chainsaw `--type=merge {}` does NOT clear existing map keys”). Applied to all 9 patch
sites so the suite is idempotent across re-runs.

## 4. `ac13` / `ac14` scripts raced kro's config cache

Even with the `assert` from (2), the child `Rule` is first created with the *instance* tag
(`Environment: staging`) and only converges to the config-derived value
(`Environment: production`) once kro re-reads the patched `RecycleBinConfig`. The
name-only assert was satisfied before convergence, so the jq script read the pre-merge value.

**Fix:** the `assert` for `ac13`/`ac14` now asserts the expected `spec.tags` entry, so
chainsaw retries until the merge has converged. Both cases merge down to a **single** tag
key, so the list order is deterministic and a positional assert is safe here — this is not
a violation of the “never assert a CEL-generated list by position” rule, which concerns
multi-key maps. `ac12` (two keys, unstable order) keeps the jq script.

## Local verification

`make test-recyclebin` — 2 passed / 0 failed, from a clean namespace and again on re-run
against the dirty namespace (confirms the idempotency fix in (3)).

## Cluster-state note

The local kind cluster needed `kubectl apply -f tests/fixtures/rbac/kro-controller.yaml`
plus a `kro` rollout restart before any of this reproduced — without the
`recyclebin.services.k8s.aws` RBAC entry added in `c61573c`, kro reports
`failed to list external collection ackRbRuleRef: ... is forbidden`.
