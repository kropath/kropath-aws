> **Point-in-time disclaimer:** This log records what was observed and believed at the time of writing (2026-09-07). Claims here are hypotheses unless mechanically verified. If this log conflicts with `frequent-rgd-errors.md` or agent instructions, those sources win.

# PipesPipe: three latent Chainsaw failures broke `main` (KRO-1058)

## Symptom

Every `main` push since `58042ea` (KRO-876, PR #222) failed the RGD Tests workflow with exactly
one failing suite:

```
--- FAIL: chainsaw/pipes/pipespipe[pipespipe] (61.65s)
- Failed  tests 1
```

Reproduced across runs `33866949372`, `33867552693`, `33916472707`, `33924291003` — deterministic,
not flaky. Suites for every other service passed.

## Why it was never caught on a PR

`.github/workflows/rgd-tests.yaml` runs `tests/select-tests.sh`, which maps the changed files to
the affected `make test-<service>` targets. On the PR that introduced this suite, only the touched
family ran; the full `make test` (which includes `pipes`) runs on `main` pushes and whenever a
shared/cross-cutting file changes. So the suite's own failures only surfaced *after* merge.

**Takeaway:** a PR that adds a brand-new suite must be verified by running that suite locally
(`cd tests && make test-<service>`) — CI's per-PR selection does not prove a new suite passes.
This is the existing "Local test gate" rule in `CLAUDE.md`; this incident is what it exists to prevent.

## Root cause 1 — fixtures violated the PipesConfig CRD's own mutual-exclusion rules

`crds/pipesconfig.yaml` carries two root-level `x-kubernetes-validations` rules: `desiredState`
and `namingTemplate` may each be set in `spec.mandatory` **or** `spec.defaults`, never both.
Five `tests/pipes/pipespipe/` config fixtures set both tiers, so the apiserver rejected them at
CREATE:

```
PipesConfig.aws.kropath.run "config-mandatory-stopped" is invalid: <nil>: Invalid value:
desiredState must be set in either mandatory or defaults, not both.
```

Chainsaw retried the apply until the 1m `ApplyTimeout`, which then surfaced as the misleading
`client rate limiter Wait returned an error: rate: Wait(n=1) would exceed context deadline` — the
*last* error, not the real one. The real cause is two frames earlier in the log.

Offending fixtures (`defaults` tier was the redundant one in every case — `mandatory` is what each
AC actually exercises):

| File | Field set in both tiers |
|---|---|
| `05-config-mandatory-stopped.yaml` | `desiredState` |
| `21-config-mandatory-naming.yaml` | `namingTemplate` |
| `24-pipe-ac19-naming-missing-tag-empty.yaml` | `namingTemplate` |
| `25-pipe-ac19a-negative-naming-unresolved-token.yaml` | `namingTemplate` |
| `34-config-team-profile.yaml` | `desiredState` |

**Fix:** blank the `defaults` tier's copy of the field in each fixture, and mirror that in the
corresponding `kubectl patch ... --subresource=status` seed in `chainsaw-test.yaml`. The status
`effectiveConfig` must stay consistent with what a real config controller could have produced
from a *valid* spec — otherwise the test asserts an unreachable state.

Assertions are unaffected: in every one of these ACs the `mandatory` tier is non-empty and wins
the RGD's precedence chain regardless of what `defaults` holds.

The two fixtures in `tests/pipes/pipesconfig/` that still set both tiers
(`02-desired-state-both-tiers.yaml`, `04-naming-both-tiers.yaml`) are **deliberate negative tests**
guarded by `expect: - check: ($error != null): true`. Leave them alone.

## Root cause 2 — ACK field-name drift in the AC-12 ECS fixture

`16-pipe-ac12-target-ecs-fargate.yaml` used the AWS-API spellings. ACK capitalises the initialisms:

| Fixture used | ACK `Pipe` CRD actually has |
|---|---|
| `taskDefinitionArn` | `taskDefinitionARN` |
| `awsvpcConfiguration` | `awsVPCConfiguration` |

Because `spec.targetParameters` is a **typed** object on the ACK CRD, the apiserver silently
**pruned** the unknown keys rather than erroring, producing a half-populated child:

```
ecsTaskParameters:
  launchType: FARGATE          # survived
  networkConfiguration: {}      # emptied — awsvpcConfiguration pruned
                                # taskDefinitionArn gone entirely
```

The `launchType` field surviving while its siblings vanished is the tell-tale signature of
schema pruning, not of a broken CEL expression.

**Fix:** rename both keys in the fixture and in the `chainsaw-test.yaml` assert. Verified against
the live CRD, per `frequent-rgd-errors.md` §7:

```
kubectl get crd pipes.pipes.services.k8s.aws -o json \
  | jq '.spec.versions[0].schema.openAPIV3Schema.properties.spec.properties.targetParameters
        .properties.ecsTaskParameters.properties | map_values(.type)'
```

A whole-suite sweep of every `sourceParameters`/`targetParameters`/`enrichmentParameters` block
against that schema found no other drift.

## Root cause 3 — AC-23 `ownerReferences` assert nested at the wrong level

```yaml
              metadata:
                name: ac23-standard-metadata
                ...
              (ownerReferences[0]):     # <-- sibling of metadata, i.e. resource root
                kind: PipesPipe
```

`ownerReferences` lives under `metadata`, so chainsaw looked for it at the root of the `Pipe`
object and reported `field not found in the input object` — even though the diff it printed
showed the ownerReference present and correct under `metadata`. **When an assert error says
"field not found" but the `+++ actual` block visibly contains the field, the assert path is
wrong, not the RGD.**

**Fix:** use the same plain nested form every other suite uses (e.g.
`tests/autoscaling/autoscalinggroup/chainsaw-test.yaml` AC-44):

```yaml
              metadata:
                ...
                ownerReferences:
                  - apiVersion: aws.kropath.run/v1alpha1
                    kind: PipesPipe
                    name: ac23-standard-metadata
                    controller: true
                    blockOwnerDeletion: true
```

## Also fixed

`chainsaw-test.yaml` AC-26 patched `pipesconfig config-team-profile`, but the CR in
`34-config-team-profile.yaml` is named `team-profile`. The patch would have failed `NotFound`.
Corrected to `team-profile`.

Stale comments in `24-pipe-ac19-naming-missing-tag-empty.yaml` claimed an unresolved `{tag.env}`
yields `invalid-unresolved-tokens`. It does not: the RGD's `{tag.*}` branch resolves an unmatched
tag key to `""`, so no `{` survives and `namingStatus` is `valid` — which is what the assert
already expected. Comments corrected to match behaviour.

## Verification

Namespaces `pipespipe`/`pipesconfig` torn down (kro + ACK finalizers stripped, since the test
cluster has no ACK controllers) so the run started from genuinely clean state:

```
--- PASS: chainsaw/pipes/pipesconfig[pipesconfig] (1.04s)
--- PASS: chainsaw/pipes/pipespipe[pipespipe] (9.85s)
- Passed  tests 2
- Failed  tests 0
```

Children confirmed created, not stale: 29 `PipesPipe` CRs → 28 ACK `Pipe` CRs (the 29th,
`ac19a-negative-naming-unresolved-token`, is correctly excluded by the `includeWhen` naming
guard), `ac12` carries the full `ecsTaskParameters` payload, and `ac3` resolves to
`desiredState: STOPPED`.
