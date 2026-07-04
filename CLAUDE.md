@docs/STANDARDS.md

## Session Bootstrap — read these two files before touching anything

Every session, before editing any RGD, CRD, or test file:

1. **`docs/frequent-rgd-errors.md`** — complete catalog of kro/CEL/ACK traps already discovered. Check it before inventing a fix; the symptom is almost certainly already documented.
2. **Latest `docs/troubleshooting-logs/`** — run `ls -t docs/troubleshooting-logs/` and read the most recent file to see what has already been fixed, what patterns are in use, and where any partial work left off.

Skipping this will cause you to re-discover known traps and revert known-good patterns.

## This Repo

**kropath-aws** — ACK-based CRDs and kro RGDs for AWS resources.

- `crds/` contains governance CRDs only: `AWSKropathConfig` (org/namespace-wide) and `AWS<ServiceName>Config` (per-type ResourceConfigs); resource-kind definitions (e.g. `AWSIAMRole`, `AWSS3Bucket`) belong in `rgds/` as kro RGDs, not in `crds/`
- kro RGD kinds: one RGD per resource family under `rgds/`
- Deletion policy annotation: `services.k8s.aws/deletion-policy` (`retain` | `delete`)
- Resource families use ACK CRs (e.g. `s3.services.k8s.aws/Bucket`, `iam.services.k8s.aws/Role`)
- All RGDs use the single `effCfg` pattern — one `externalRef` config lookup per RGD
- `effectiveName` used as cloud resource name; `predictedArn` built from `effectiveName`

## Fixing chainsaw test failures (`tests/Makefile` → `make test-iam`, `test-s3`, etc.)

Read `docs/frequent-rgd-errors.md` first — it catalogs every CEL/RGD trap already seen. When a step in `tests/<service>/<kind>/chainsaw-test.yaml` fails:

**Autonomous test-fix loop** — When asked to fix chainsaw tests, run `cd tests && make test-<service>` without waiting for the user to trigger each run. Read the first failing step's error, apply the debug loop below to fix it, then immediately run `make test-<service>` again to find the next failure. Repeat autonomously until all steps pass.

**Debug loop (do NOT re-run `make test-iam` to verify an individual fix — use kubectl steps instead):**

1. Edit `rgds/<kind>.yaml` → `kubectl apply -f rgds/<kind>.yaml` → `kubectl get rgd <kind>.kropath.run` (state must be `Active`; if not, `kubectl describe rgd` and consult frequent-rgd-errors.md).
2. `kubectl delete crd <plural>.kropath.run` — kro re-derives the CRD from the RGD schema, picking up any schema changes (needed after any RGD schema edit).
3. `kubectl apply -f tests/<service>/<kind>/<NN>-<resource>.yaml` for the specific failing case (e.g. `tests/iam/awsiamrole/01-ec2-role.yaml` for `ec2-role-with-instance-profile`).
4. `kubectl get <kind>` — if RESOURCENAME is populated, reconciliation succeeded; else `kubectl describe <kind> <name>`.
5. Once the kubectl debug confirms the fix, run `cd tests && make test-<service>` to find the next failing step and repeat.

**Key gotchas learned from this repo:**

- **kubectl merge patch does NOT remove keys** — to fully reset `status.effectiveConfig` between manual tests, `kubectl delete` the config CR and re-apply. Chainsaw itself always seeds fresh state per step, so single-step manual reproductions may diverge from a full `make test-iam` run.
- **`{namespace}-{name}` naming template** — default in every `AWS<Kind>Config`. Chainsaw tests run in namespace `<testset>` (e.g. `awsiamrole`), so expected cloud resource names are `<namespace>-<resource>` (e.g. `awsiamrole-ec2-role`), not always `default-*`.
- **`kropath.run/` prefix is Kubernetes-only** — applies to `metadata.labels` and `metadata.annotations`, NEVER to cloud resource tags. Cloud tags use plain keys from `syncedLabels`/`syncedAnnotations`/`tags`.
- **Cross-tier tags must map-merge, not list-concat** — `mandatory > spec > defaults` requires `.merge()` on maps (last-writer-wins), then `.transformList(k, v, {"key": k, "value": v})` at the end. Concatenating pre-transformed lists with `+` produces duplicate keys and breaks mandatory-wins semantics.
- **Boolean flags meant to be tri-state (`unset` / `true` / `false`) must NOT declare `| default=false`** — kro copies the default into the generated CRD, kubernetes materializes `false` on every instance, and `has()` always returns true. Declare them as bare `boolean` in the RGD schema.
- **Test resources referenced via `externalRef` label selectors need the selector label present** — e.g. `AWSPolicyDocument`/`AWSIAMPolicy` referenced by `firstPolicyRef`/`firstInlineDoc`/`trustDoc` must carry `metadata.labels.kropath.run/resource-name: <name>` in the test manifest.
- **awsiampolicy tests run in `default` namespace** — unlike awsiamrole (namespace = `awsiamrole`), awsiampolicy chainsaw tests run in `default`. Naming template `{namespace}-{name}` therefore produces `default-<name>` (e.g. `default-my-policy`). Update assert files accordingly.
- **Chainsaw `--type=merge {}` does NOT clear existing map keys** — to reset `mandatory.tags` or `mandatory.syncedLabels` between steps, first null out the whole field: `kubectl patch ... --type=merge -p '{"status":{"effectiveConfig":null}}'`, then immediately re-patch with desired values. Apply this two-command pattern to every step that needs a clean state after a previous step set map keys.
- **`status:` expressions cannot reference `schema.*`** — `schema` and `instance` are out of scope in the `status:` block. Compute fields like `predictedArn` from child resource fields only (e.g. `policy.spec.path`, `policy.spec.name`, `rsrcCfg.status.effectiveConfig.aws.accountId`).
- **`status.arn` is only populated by real AWS; use `predictedArn` in tests** — `status.arn` reads `ackResourceMetadata.arn`, which requires a live AWS reconciliation. In mock/local tests it is always empty (kro omits empty-string fields). Assert on `status.predictedArn` (computed) instead.
- **CEL `.merge()` tag output order** — After `.merge(rightMap)`, the key iteration order is: **all keys from rightMap in their original order first**, then keys only in the left map in their original order. This applies to overwritten keys too — they move to the right-map position, not stay in the left-map position. For the standard `defaults → spec → mandatory` chain the final list starts with `mandatory`'s keys (in their map order), then `spec`-only keys, then `defaults`-only keys. Derive expected order by tracing each `.merge()` step before writing any assert. Never assume alphabetical or insertion order.
- **"passes in isolation but fails in parallel" is not automatically a race condition** — the isolation run may be asserting against stale cluster state left over from the parallel run. A suspiciously short elapsed time (e.g. 9s vs 25s in a clean run) indicates reconciliation was skipped because child resources already existed. Before dismissing a failure as a race, verify that the test's `purge-stale-leftovers` step cleans up ALL resources the test uses (not just some), and that child resources were actually re-created during the isolation run. The cascade test's purge only deletes `awsiamconfig` but not `awskropathconfig` or the already-reconciled child `Role` — so a stale Role from a prior run can make the assert pass even when the assert is wrong.

Log the fix for each failing step in `docs/troubleshooting-logs/<YYYY-MM-DD>-<slug>.md` (one section per test case) so a re-entrant session can see what's already handled.

## Creating new RGDs, CRDs, and test cases

All gotchas in the list above apply when authoring new resources, not just when fixing failures. The workflow is different from the debug loop — iterative design-and-verify rather than error-read-and-fix — but the traps are identical.

**RGD authoring loop:**

1. Write `rgds/<kind>.yaml` — schema, CEL expressions, status block. Consult `docs/frequent-rgd-errors.md` before writing any CEL; every common trap is already documented.
2. `kubectl apply -f rgds/<kind>.yaml` → `kubectl get rgd <kind>.kropath.run` — must reach `Active`. If not, `kubectl describe rgd <kind>.kropath.run` and check the error against `frequent-rgd-errors.md` before attempting a fix.
3. `kubectl delete crd <plural>.kropath.run` — kro re-derives the CRD from the updated schema. Required after **every** schema field or type change, not just the first time.
4. Apply a minimal governance config and one resource instance manually to verify reconciliation end-to-end before writing any test files. `kubectl describe <kind> <name>` will show the CEL error directly if anything is wrong.
5. Once the manual resource reconciles cleanly, write test fixtures and asserts, then run `chainsaw test iam/<kind>/` (or equivalent).

**CRD authoring (governance CRDs in `crds/`):**

- After editing a CRD YAML, `kubectl apply -f crds/<kind>.yaml` — the API server validates the schema immediately; any `x-kubernetes-validations` errors surface here.
- CRDs do not go through the kro Active/Inactive cycle — check `kubectl get crd <plural>.kropath.run` for `ESTABLISHED: True`.

**Writing test cases — mandatory rules:**

- **`effectiveConfig` must always include both `mandatory` AND `defaults`** — omitting either tier causes a `no such key: <tier>` CEL error at runtime (CEL's `has(a.b.c)` fails when the intermediate key `b` is absent). Always include all three sub-objects: `mandatory`, `defaults`, and `aws`.
- **Trace CEL before writing any assert for an ordered list** — for tags, synced labels, or any field produced by `.merge().transformList()`, trace the merge chain step by step to determine actual output order. See the CEL `.merge()` tag output order gotcha above. Never guess or use alphabetical order.
- **Purge step must delete every resource tier the test owns** — if a test uses both `AWSKropathConfig` and `AWSIAMConfig`, both must appear in `purge-stale-leftovers`. Omitting one tier leaves stale state that makes the test appear to pass in isolation while masking a wrong assert.
- **Config reset between steps that mutate shared config** — any step that sets naming template, tags, or syncedLabels must delete and recreate the config at the start of subsequent steps that need a different config state. Do not assume cleanup from an earlier step; always reset explicitly.
- **Fixed namespace in `spec.namespace`** — declare a fixed namespace in the chainsaw test's `spec.namespace` (e.g. `namespace: awsiamrole`) so resource names are predictable and `{namespace}-{name}` naming templates expand to known values.
- **Distinguish `metadata.name` from `spec.name` in asserts** — child K8s resources receive `metadata.name: ${schema.metadata.name}` (the CR's K8s name, unaffected by naming templates) and `spec.name: ${effectiveName}` (the cloud resource name, controlled by naming templates). Asserts on labels, annotations, and ownerReferences use `metadata.name`; asserts on the cloud resource name use `spec.name`.
