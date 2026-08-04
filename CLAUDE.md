@docs/STANDARDS.md

## Session Bootstrap — read these two files before touching anything

Every session, before editing any RGD, CRD, or test file:

1. **`docs/frequent-rgd-errors.md`** — complete catalog of kro/CEL/ACK traps already discovered. Check it before inventing a fix; the symptom is almost certainly already documented.
2. **Latest `docs/troubleshooting-logs/`** — run `ls -t docs/troubleshooting-logs/` and read the most recent file to see what has already been fixed, what patterns are in use, and where any partial work left off.

Skipping this will cause you to re-discover known traps and revert known-good patterns.

> **Canonical chainsaw test structure (REQUIRED as of 2026-08-04):** every suite uses a
> **unique resource name per step** and **`spec.skipDelete: true`** (also the global default
> in `.chainsaw.yaml`), and deletes **nothing** between steps — see `docs/frequent-rgd-errors.md`
> §"CANONICAL: Unique-Name-Per-Step + `skipDelete`". All 24 suites have been migrated to this
> pattern; `tests/dynamodb/dynamodbtable/chainsaw-test.yaml` is the reference. This supersedes
> the older delete-then-recreate / `--wait=false` / finalizer-strip / per-step-cleanup /
> `purge-stale-leftovers` / poll-script workarounds — they fought the fact that the test
> cluster has kro but **no ACK controllers**, so ACK finalizers are never removed and any
> delete of an ACK child hangs. When writing or fixing a suite, follow the canonical pattern
> FIRST; do not reintroduce inter-step deletes for ACK-child resources.
>
> Two carve-outs remain: (1) a **shared governance config CR** (`IAMConfig`, `S3BucketConfig`,
> …) that a suite re-patches across steps may still be `kubectl delete`+recreated to reset it —
> config CRs are not ACK resources and have no finalizer, so their delete never hangs; prefer,
> though, giving each step its own uniquely-named config. (2) A genuine **lifecycle test** that
> mutates one resource across steps (e.g. deletion-policy retain→delete on the same Role) keeps
> the single resource by design; unique-per-step names do not apply there.

## This Repo

**kropath-aws** — ACK-based CRDs and kro RGDs for AWS resources.

- `crds/` contains governance CRDs only: `KropathConfig` (org/namespace-wide) and `<ServiceName>Config` (per-type ResourceConfigs); resource-kind definitions (e.g. `IAMRole`, `S3Bucket`) belong in `rgds/` as kro RGDs, not in `crds/`
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
3. `kubectl apply -f tests/<service>/<kind>/<NN>-<resource>.yaml` for the specific failing case (e.g. `tests/iam/iamrole/01-ec2-role.yaml` for `ec2-role-with-instance-profile`).
4. `kubectl get <kind>` — if RESOURCENAME is populated, reconciliation succeeded; else `kubectl describe <kind> <name>`.
5. Once the kubectl debug confirms the fix, run `cd tests && make test-<service>` to find the next failing step and repeat.

**Key gotchas learned from this repo:**

- **kubectl merge patch does NOT remove keys** — to fully reset `status.effectiveConfig` between manual tests, `kubectl delete` the config CR and re-apply. Chainsaw itself always seeds fresh state per step, so single-step manual reproductions may diverge from a full `make test-iam` run.
- **`{namespace}-{name}` naming template** — default in every `AWS<Kind>Config`. Chainsaw tests run in namespace `<testset>` (e.g. `iamrole`), so expected cloud resource names are `<namespace>-<resource>` (e.g. `iamrole-ec2-role`), not always `default-*`.
- **`kropath.run/` prefix is Kubernetes-only** — applies to `metadata.labels` and `metadata.annotations`, NEVER to cloud resource tags. Cloud tags use plain keys from `syncedLabels`/`syncedAnnotations`/`tags`.
- **Cross-tier tags must map-merge, not list-concat** — `mandatory > spec > defaults` requires `.merge()` on maps (last-writer-wins), then `.transformList(k, v, {"key": k, "value": v})` at the end. Concatenating pre-transformed lists with `+` produces duplicate keys and breaks mandatory-wins semantics.
- **Boolean flags meant to be tri-state (`unset` / `true` / `false`) must NOT declare `| default=false`** — kro copies the default into the generated CRD, kubernetes materializes `false` on every instance, and `has()` always returns true. Declare them as bare `boolean` in the RGD schema.
- **Test resources referenced via `externalRef` label selectors need the selector label present** — e.g. `PolicyDocument`/`AWSIAMPolicy` referenced by `firstPolicyRef`/`firstInlineDoc`/`trustDoc` must carry `metadata.labels.aws.kropath.run/resource-name: <name>` in the test manifest.
- **iampolicy tests run in `default` namespace** — unlike iamrole (namespace = `iamrole`), iampolicy chainsaw tests run in `default`. Naming template `{namespace}-{name}` therefore produces `default-<name>` (e.g. `default-my-policy`). Update assert files accordingly.
- **Chainsaw `--type=merge {}` does NOT clear existing map keys** — to reset `mandatory.tags` or `mandatory.syncedLabels` between steps, first null out the whole field: `kubectl patch ... --type=merge -p '{"status":{"effectiveConfig":null}}'`, then immediately re-patch with desired values. Apply this two-command pattern to every step that needs a clean state after a previous step set map keys.
- **`status:` expressions cannot reference `schema.*`** — `schema` and `instance` are out of scope in the `status:` block. Compute fields like `predictedArn` from child resource fields only (e.g. `policy.spec.path`, `policy.spec.name`, `rsrcCfg.status.effectiveConfig.aws.accountId`).
- **`status.arn` is only populated by real AWS; use `predictedArn` in tests** — `status.arn` reads `ackResourceMetadata.arn`, which requires a live AWS reconciliation. In mock/local tests it is always empty (kro omits empty-string fields). Assert on `status.predictedArn` (computed) instead.
- **`x-kubernetes-validations` cannot be preserved by kro** — kro regenerates the CRD from the RGD schema on every apply; any hand-authored or JSON-patched `x-kubernetes-validations` rules are silently discarded after the next kro upgrade. Use the **in-graph ConfigMap advisory pattern** instead: for mutual-exclusivity add an `includeWhen`-gated `mutualExclusionError` ConfigMap (see `rgds/iampolicy.yaml`); for range/floor checks add a `<field>Error` ConfigMap (see `rgds/iamrole.yaml` `maxSessionDurationError`); for immutability rely on ACK enforcement and document the constraint in the spec. Full details in `docs/frequent-rgd-errors.md` §"x-kubernetes-validations Cannot Be Auto-Generated by kro v0.9.2".
- **CEL `.merge()` tag output order** — After `.merge(rightMap)`, the key iteration order is: **all keys from rightMap in their original order first**, then keys only in the left map in their original order. This applies to overwritten keys too — they move to the right-map position, not stay in the left-map position. For the standard `defaults → spec → mandatory` chain the final list starts with `mandatory`'s keys (in their map order), then `spec`-only keys, then `defaults`-only keys. Derive expected order by tracing each `.merge()` step before writing any assert. Never assume alphabetical or insertion order.
- **"passes in isolation but fails in parallel" is not automatically a race condition** — the isolation run may be asserting against stale cluster state left over from the parallel run. A suspiciously short elapsed time (e.g. 9s vs 25s in a clean run) indicates reconciliation was skipped because child resources already existed. Before dismissing a failure as a race, verify that the test's `purge-stale-leftovers` step cleans up ALL resources the test uses (not just some), and that child resources were actually re-created during the isolation run. The cascade test's purge only deletes `iamconfig` but not `awskropathconfig` or the already-reconciled child `Role` — so a stale Role from a prior run can make the assert pass even when the assert is wrong.
- **Not every RGD has a cloud resource name — check the CRD cache before wiring namingTemplate.** `rgds/iamidentityprovider.yaml` has no `effectiveName`/`status.resourceName`/`status.namingStatus`: its only supported ACK resource, `OpenIDConnectProvider`, has no `name` field at all (confirmed in `kropath-core/docs/crd-cache/aws/iam-controller-v1.4.2.md` — its spec is `clientIDs`/`tags`/`thumbprints`/`url` only), and AWS identifies OIDC providers by URL, not name. `SAMLProvider` isn't implemented by ACK IAM at all. `spec.nameOverride` stays in the schema for cross-RGD consistency but is a documented no-op there. The Kubernetes child resource's `metadata.name` is still always `${schema.metadata.name}` (never `naming.data.effectiveName`) — that rule holds even for RGDs with no cloud-side naming concept. **Before adding naming-template/`{tag.X}` support to any RGD, check `kropath-core/docs/crd-cache/aws/<controller>.md` for a `name` field on the target ACK CRD first** — do not assume every resource family takes one. Full writeup in `docs/frequent-rgd-errors.md` §"IAMIdentityProvider Has No Cloud Resource Name — namingTemplate Does Not Apply".

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

- **Canonical pattern FIRST (see the Session-Bootstrap note above):** unique resource name per
  step, `spec.skipDelete: true`, and NO inter-step deletes/`cleanup:`/`finally:`/finalizer-strips
  for ACK-child resources. The `purge-stale-leftovers` / config-reset rules below apply ONLY to
  shared governance **config CRs** (no ACK finalizer) or genuine single-resource lifecycle tests.
- **`effectiveConfig` must always include both `mandatory` AND `defaults`** — omitting either tier causes a `no such key: <tier>` CEL error at runtime (CEL's `has(a.b.c)` fails when the intermediate key `b` is absent). Always include all three sub-objects: `mandatory`, `defaults`, and `aws`.
- **Never assert a CEL-generated list by exact position — and note that chainsaw has NO working declarative order-independent list construct for this.** Any list field produced by a CEL `.merge().transformList()` chain (ACK `spec.tags`, S3 `spec.tagging`, KMS `tagKey`/`tagValue` tags, etc.) has map-derived iteration order that is not guaranteed stable across runs. Two patterns that look like fixes are NOT: a per-item list assert (`tags: - (key == 'x'): true`) is still positional (chainsaw pairs assert-item `[i]` with actual-item `[i]`, no cross-position search); a whole-array CEL `.exists()` check (`(tags.exists(t, ...)): true`) fails outright with `Internal error: unknown function: exists` because chainsaw's assertion engine is JMESPath-style (kyverno-json), not full CEL. Both were tried and confirmed broken via real CI failures. **Use a `- script:` step with `kubectl ... -o json | jq` instead** — plain shell, genuinely order-independent. See `docs/frequent-rgd-errors.md` §6 "Flaky List/Array Asserts — CEL Map-to-List Transforms Have Unstable Order" for the working jq pattern. Exception: lists that echo raw user input verbatim (e.g. `allowedKeySpecs`, `policies` ARNs) are apply-order-stable and may use plain positional asserts.
- **Purge step must delete every resource tier the test owns** — if a test uses both `AWSKropathConfig` and `IAMConfig`, both must appear in `purge-stale-leftovers`. Omitting one tier leaves stale state that makes the test appear to pass in isolation while masking a wrong assert.
- **Config reset between steps that mutate shared config** — any step that sets naming template, tags, or syncedLabels must delete and recreate the config at the start of subsequent steps that need a different config state. Do not assume cleanup from an earlier step; always reset explicitly.
- **Fixed namespace in `spec.namespace`** — declare a fixed namespace in the chainsaw test's `spec.namespace` (e.g. `namespace: iamrole`) so resource names are predictable and `{namespace}-{name}` naming templates expand to known values. Never use `default` namespace for tests.
- **Distinguish `metadata.name` from `spec.name` in asserts** — child K8s resources receive `metadata.name: ${schema.metadata.name}` (the CR's K8s name, unaffected by naming templates) and `spec.name: ${effectiveName}` (the cloud resource name, controlled by naming templates). Asserts on labels, annotations, and ownerReferences use `metadata.name`; asserts on the cloud resource name use `spec.name`.

## Local test gate — mandatory before PR creation

Before creating or updating a PR, the full Chainsaw test suite for the affected service MUST pass locally:

1. Run `cd tests && make test-<service>` (e.g. `make test-kms` for KMS work).
2. All test steps must pass (zero failures, zero skips due to missing resources).
3. Post the final make output (last 30 lines) as a comment on the Multica issue with the heading "Local test run — PASS" before pushing.
4. Do NOT create the PR until step 3 is complete.

If tests are failing, continue the autonomous test-fix loop (see "Fixing chainsaw test failures" above) until they pass. Do not submit a PR with known test failures.

## Theme 28: ExternalRef Config Lookup — labelSelector Required (KRO-143, KRO-222)

**Rule:** Never use CEL (`${}`) in `externalRef.metadata.name`. Use `selector.matchLabels` with the provider-prefixed label key instead.

**Why it matters:** kro evaluates CEL only in `template:` blocks and `selector.matchLabels` entries. In `externalRef.metadata.name`, the `${}` expression is treated as a literal string and never resolved — the config lookup silently fails and the instance stalls in reconciliation. Additionally, when `selector.matchLabels` is used, kro infers the variable as a **list** — all accesses must use `rsrcCfg[0].*` with `rsrcCfg.size() > 0` guards.

**Correct pattern (AWS):**
```yaml
- id: rsrcCfg
  externalRef:
    apiVersion: aws.kropath.run/v1alpha1
    kind: IAMConfig
    metadata:
      namespace: ${schema.metadata.namespace}
      selector:
        matchLabels:
          aws.kropath.run/resource-name: ${schema.?spec.?configRef.orValue("general-policy")}
```

The config CR must carry the matching label:
```yaml
metadata:
  name: general-policy
  labels:
    aws.kropath.run/resource-name: general-policy
```

**Accessing the list result — always guard:**
```yaml
# WRONG — rsrcCfg.status fails when list is empty
.merge(rsrcCfg.status.effectiveConfig.mandatory.syncedLabels.transformMapEntry(...))

# CORRECT — guard with size() > 0 before indexing
.merge((rsrcCfg.size() > 0 && has(rsrcCfg[0].status.effectiveConfig.mandatory.syncedLabels)) ? rsrcCfg[0].status.effectiveConfig.mandatory.syncedLabels.transformMapEntry(...) : {})
```

**Label key convention:**

| Provider | Label key |
|---|---|
| AWS | `aws.kropath.run/resource-name` |
| GCP *(future)* | `gcp.kropath.run/resource-name` |
| Azure *(future)* | `azure.kropath.run/resource-name` |

**What to avoid:**
- `metadata.name: ${schema.spec.configRef}` — CEL not evaluated in `externalRef.metadata.name`
- `kropath.run/config-name:` — deprecated bare form, no provider prefix
- `kropath.run/resource-name:` — deprecated bare form, no provider prefix

**See also:** `docs/frequent-rgd-errors.md` §"CEL Is Not Supported in `externalRef.metadata.name`" and §"The Unbound Variable Freeze".
