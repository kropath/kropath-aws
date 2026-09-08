> **Point-in-time disclaimer:** This log records what was observed and believed at the time of
> writing (2026-09-08). Claims here are hypotheses unless mechanically verified. If this log
> conflicts with `frequent-rgd-errors.md` or agent instructions, those sources win.

# KRO-1064: `main` Chainsaw E2E regression after the SageMaker merge (SHA `efadc97e`)

## Symptom

Run [34144936306](https://github.com/kropath/kropath-aws/actions/runs/34144936306) on `main`:
**181 passed / 35 failed**, wall clock ~2h (healthy `main` runs are ~15 min).

- All 20 SageMaker suites failed at exactly ~300s — the chainsaw `AssertTimeout`.
- `sagemakerconfig` was the only SageMaker suite that passed.
- 15 unrelated suites also failed (`s3bucket`, `s3config`, `rdscluster`, `rdsinstance`,
  `rdssubnetgroup`, 5× `route53*`, `memorydbuser`, `memorydbsubnetgroup`, `mskconfiguration`,
  `pipespipe`), all with `actual resource not found` on an ACK child.

### Why this surfaced only now

PR #234 touched `tests/Makefile` (adding `test-sagemaker:`). That path is in
`select-tests.sh`'s `SHARED_PATTERN`, so CI fell back to the **full suite** instead of the
usual changed-service subset. The preceding green `main` runs were subset runs and never
exercised SageMaker.

## Root causes

Three independent defects, all introduced by PR #234. They surfaced **one layer at a time** —
each fix revealed the next, exactly as `CLAUDE.md` §8 warns.

### 1. Missing kro RBAC for `sagemaker.services.k8s.aws`

```
domains.sagemaker.services.k8s.aws is forbidden: User "system:serviceaccount:kro-system:kro"
cannot list resource "domains" in API group "sagemaker.services.k8s.aws"
```

`hack/install-provider-crds.sh` had `sagemaker` in `ACK_SERVICES` (so the ACK CRDs existed and
every RGD reached `Active`), but `tests/fixtures/rbac/kro-controller.yaml` was never extended.
The RGDs compiled fine and only failed at *instance reconcile* time.

Same class as `2026-09-05-ses-missing-rbac.md` and `2026-09-03-appscaling-missing-rbac.md`.

**Fix:** added `- sagemaker.services.k8s.aws` to the apiGroups list.

### 2. `SageMakerConfig.status` seeded via inline `apply` — silently dropped

All 20 broken suites seeded governance config like this:

```yaml
- apply:
    resource:
      kind: SageMakerConfig
      metadata: {name: general-policy, ...}
      status:                      # <-- never persisted
        effectiveConfig: {...}
```

`SageMakerConfig` declares a `status` **subresource**, so the API server discards the `status`
stanza on create. The CR ended up with *no* `status` key at all, and the shared naming macro
died on `rsrcCfg[0].status` with:

```
node "naming": failed to evaluate expression: ... no such key: status (data pending)
```

The other 174 suites in the repo already use the correct form; `sagemakerconfig` (the one
passing SageMaker suite) did too.

**Fix:** converted all 62 inline-status blocks to the established pattern —

```yaml
- apply:
    resource: {kind: SageMakerConfig, metadata: {...}}   # no status
- script:
    content: |
      kubectl patch sagemakerconfig general-policy -n sagemakerdomain \
        --subresource=status --type=merge \
        -p '{"status":{"effectiveConfig":{...}}}'
```

Each tier is emitted with `namingTemplate`/`tags`/`syncedLabels`/`syncedAnnotations` always
present, because the naming macro dereferences `.tags` **unguarded** when a template contains
`{tag.X}` (used by `sagemakerdomain` and `sagemakeruserprofile`). No config name is reused
across steps in any suite, so a plain merge patch is safe — the null-out-then-repatch reset
dance is not needed here.

### 3. Ambiguous bare `kubectl get` names

`sagemakerdomain` used `kubectl get domain`, which resolved to
`domains.opensearchservice.services.k8s.aws`:

```
Error from server (NotFound): domains.opensearchservice.services.k8s.aws "tags-domain" not found
```

Installing SageMaker created two **new** plural collisions:

| plural | colliding groups |
|---|---|
| `domains` | `opensearchservice`, `sagemaker` |
| `endpoints` | `eventbridge`, `sagemaker` (and core `v1`) |

`tests/lint-test-scripts.sh` exists to catch exactly this, but its `ACK_BARE_NAMES` list had
neither `domain` nor `endpoint`, so it passed PR #234.

**Fix:** qualified the 4 call sites, and added `domain` + `endpoint` to `ACK_BARE_NAMES`. The
hardened linter then caught **2 pre-existing latent occurrences** in
`opensearch/opensearchdomain/chainsaw-test.yaml` (working only because `opensearchservice`
happened to sort first) — those were qualified too.

### Bonus: two dead purge commands

`sagemakeruserprofile`'s purge step referenced `sagemakeruserprofils` (typo) and
`sagemakerconfigv1alpha1` (not a kind). Both were silent no-ops under
`--ignore-not-found=true`. Corrected.

## The 15 non-SageMaker failures — hypothesis, NOT addressed here

This PR is scoped to SageMaker only; the other failing suites are owned elsewhere.

Working hypothesis for why they went red in the same run: with RBAC denied, kro retried the
failing `list` for every SageMaker instance across 20 namespaces in a tight loop, starving the
controller's worker pool. The collateral suites are the ones scheduled concurrently with
SageMaker, and they timed out waiting for ACK children kro never got around to creating —
route53 suites that *did* finish took 2000-3000s versus their normal seconds, which is the
signature of a saturated controller rather than 15 independent bugs.

**This is unverified.** Confirming it needs a full-suite run on a clean cluster with the
SageMaker fix applied, which was deliberately not done here to avoid colliding with other
agents on the shared test cluster. If these suites stay red on `main` after this lands, they
need their own investigation.

## Prevention

`lint-test-scripts.sh` now covers `domain`/`endpoint`. The RBAC gap remains the recurring trap:

> **When adding a new ACK service, all three must land in the same PR:**
> `hack/install-provider-crds.sh` (`ACK_SERVICES`), `tests/fixtures/rbac/kro-controller.yaml`
> (apiGroups), and any new ambiguous plurals in `tests/lint-test-scripts.sh`.

A green RGD (`Active`) proves only that the graph compiled against the ACK schema — it says
nothing about whether kro may *act* on those resources at runtime.
