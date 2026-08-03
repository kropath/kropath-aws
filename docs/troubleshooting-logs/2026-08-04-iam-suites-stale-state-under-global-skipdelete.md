# 2026-08-04 — Four IAM chainsaw suites failing under global `skipDelete: true`

`make test` reported 4 IAM suite failures. Root cause in all four: these suites still
use the **old numbered-file / shared-config-reset** structure (they were never migrated
to the canonical unique-name-per-step pattern), and `.chainsaw.yaml` now forces
`skipDelete: true` globally (commit `cadda21`). Resources therefore persist between runs,
and the suites' one-shot verification scripts / merge-patch config resets are not robust
to that leftover state. The RGDs themselves are correct — the live cluster showed the
expected end-state in every case; the tests were racing the reconcile or reading stale
keys.

Fix pattern reused from the passing `iamgroup` suite: poll until the reconciled end-state
appears (instead of one-shot reads), and reset shared config via delete+reapply (not a
`--type=merge` patch, which does not remove stale map keys).

---

## iam/metadata[iamrole-standard-metadata]

**Failing step:** `assert-deletion-policy-retain` — expected child Role annotation
`services.k8s.aws/deletion-policy: retain`, live value was `delete`.

**Cause:** `01-iamrole-lambda.yaml` omitted `deletionPolicy` (relied on the default
`retain`). A later step (`04-iamrole-delete-policy.yaml`) sets `delete` on the **same**
`my-lambda-role`. Under `skipDelete`, the role is left in `delete` across runs, and
chainsaw's `apply` is a merge — an omitted field is **not** cleared — so re-applying `01`
never reset it. Parent and child both stayed `delete`.

**Fix:** set `deletionPolicy: retain` **explicitly** in `01-iamrole-lambda.yaml` so the
merge-apply overwrites the leftover `delete`.

## iam/iamuser[iamuser]

**Failing step:** `ac11-tags-merge` — expected 2 tags (`cost-centre`=platform mandatory +
`team`=ops spec), got only `team`=ops.

**Cause:** one-shot `kubectl get user … | jq` read ran immediately after apply, catching
kro's spec-tags-first reconcile pass before the mandatory tag landed.

**Fix:** wrapped the `ac11-tags-merge` and `ac12-synced-labels` tag checks in a
`for i in $(seq 1 60)` poll-until-`COUNT`-matches loop (`timeout: 3m`).

## iam/iamrole[iamrole]

**Failing step:** `boundary-and-naming` — one-shot `test -z "$boundary"` on
`boundary-optout-role` found a non-empty boundary (read before kro created/reconciled the
child; under `skipDelete` it read a not-yet-reconciled leftover).

**Fix:** poll-wait for the ACK Role child to exist with an empty `permissionsBoundary`.
Also poll-wrapped the two other one-shot jq tag checks in the suite
(`lambda-role-standard-metadata`, `tag-merge-prefers-mandatory-values`) to pre-empt the
same race.

## iam/iamidentityprovider[iamidentityprovider]

**Failing step:** `mandatory-tags` — asserted `tagged-oidc` had exactly
`[cost-centre=platform]`; live had 3 tags (`cost-centre`, `environment=mandatory`,
`team=ops`). Standalone this **hung** on the 5m assert; in parallel it failed fast.

**Cause:** the step reset the shared `general-policy` config with a plain
`--type=merge` patch, which does **not** remove stale map keys. Under `skipDelete`, the
`environment`/`team` tags written to `general-policy` by the later
`tag-merge-prefers-mandatory-values` step on a **prior** run survived, so `tagged-oidc`
reconciled to 3 tags. Every other tag step in this file already resets via
delete+reapply; `mandatory-tags` did not.

**Fix:** prepend `kubectl delete iamconfig general-policy --ignore-not-found=true` +
`apply 00-iamconfig.yaml` before the patch (mirroring the sibling steps), giving a clean
config base each run. Also poll-wrapped the `synced-labels` and `tag-merge` one-shot jq
checks.

---

## Verification

- Each suite passes individually AND on an immediate second run (idempotent under
  `skipDelete` leftover state).
- Full parallel `make test-iam` (`--parallel 4`): all 9 IAM suites PASS, 0 failed.

## Note for future work

These four suites remain on the pre-canonical structure (shared-config resets, numbered
files). The mandated long-term direction (CLAUDE.md / frequent-rgd-errors.md) is to
migrate them to unique-name-per-step + per-step unique config, which eliminates cross-run
stale state entirely rather than polling around it. This session applied the minimal
robustness fixes to get them green without a full rewrite.
