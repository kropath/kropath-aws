> **Point-in-time disclaimer:** This log records what was observed on 2026-09-04 against kro v0.9.2
> in the `kropath-aws-test` kind cluster and in GitHub Actions run 33731687628. kro behaviour, ACK
> CRD shapes, and RGD patterns evolve; verify claims mechanically before acting on them.

# KRO-873: Three CI failures on PR #215 — one deterministic, one a genuine cross-suite race

**Date:** 2026-09-04
**Issue:** KRO-873 (PR [#215](https://github.com/kropath/kropath-aws/pull/215))
**CI run:** [33731687628](https://github.com/kropath/kropath-aws/actions/runs/33731687628) — 175 passed, 3 failed

PR #215 only adds a `pipes` section to `crds/kropathconfig.yaml`, and the implementer reported the
CI failure as an unrelated flaky test. Both halves of that need qualifying: the failures are indeed
unrelated to the PR, but only one of the three is flaky. The other two are a hard breakage that had
landed on `main` and fails on every run.

| Failing suite | Elapsed | Nature |
|---|---|---|
| `stepfunctions/stepfunctionsstatemachine` | 60.25s | Deterministic — RGD does not compile |
| `stepfunctions/stepfunctionsactivity` | 60.24s | Deterministic — RGD does not compile |
| `acm/acmcertificate` | 127.41s | Genuinely flaky — cross-suite race on shared cluster state |

---

## Failure 1 + 2: `stepfunctions*` RGDs have an unbalanced CEL expression

### Symptom

Neither suite reports a CEL error of its own. The evidence is in the **Setup test environment**
step, ~10 minutes before the suites run:

```
timed out waiting for the condition on resourcegraphdefinitions/stepfunctionsactivity.aws.kropath.run
timed out waiting for the condition on resourcegraphdefinitions/stepfunctionsstatemachine.aws.kropath.run
...
  - stepfunctionsactivity.aws.kropath.run: failed to build dependency graph: failed to extract
    dependencies: failed to inspect expression: parse error: ERROR: <input>:38:50:
    Syntax error: mismatched input ')' expecting <EOF>
 |   .replace("{configRef}", schema.spec.configRef))).contains("{")
 | .................................................^
```

Both RGDs stay `Inactive`, their CRDs are never derived, and each suite burns its full 60s before
failing. This reproduces on every run — it is not flaky.

### Root cause

Commit `76e31ac` (KRO-977, "apply {token} substitution to nameOverride in all 77 RGDs") ran
`scripts/fix_nameoverride_parens.py`, which made two paired edits per naming expression:

1. `${(schema.spec.nameOverride` → `${((schema.spec.nameOverride`
2. the false-branch close `: "{namespace}-{name}"))` → `)))`

The pairing is what keeps the expression balanced. In 75 of the 77 RGDs both edits fired. In
`stepfunctionsactivity` and `stepfunctionsstatemachine`, the `namingStatus` expression **already**
opened with `((` — it needs an extra group so `.contains("{")` applies to the fully-substituted
string — so edit 1 did not match while edit 2 still fired, leaving one unmatched `)`.

Confirmed by diffing the pre-KRO-977 `stepfunctions` block against the post-KRO-977 `gluejob` block
(a peer that the script handled correctly): they differ on exactly two lines, the `{namespace}-{name}`
close and the `.contains` close.

### Fix

Drop the surplus paren so the `.contains` close matches `gluejob`'s:

```diff
-              .replace("{configRef}", schema.spec.configRef))).contains("{")
+              .replace("{configRef}", schema.spec.configRef)).contains("{")
```

This is the correct target, not merely a balanced one. After the fix the whole 41-line
`namingStatus` block in both files is **byte-identical** to `gluejob`'s, which means the method
chain binds to the entire ternary (the precedence bug KRO-977 set out to fix) rather than only to
its false branch.

### Regression guard

`hack/check-rgd-cel-balance.sh` (`make lint-rgd-cel`, wired into the Static Checks workflow) walks
every `${...}` in `rgds/*.yaml` and fails on any paren imbalance, quote-aware so that
`.contains("{")` and `.split("{tag.")` do not confuse it. Verified by reintroducing the bug: it
reports `rgds/stepfunctionsactivity.aws.kropath.run.yaml:173: ... 1 extra closing paren` and exits 1.

It is a balance check, not a CEL parser — it targets the mechanical failure mode a scripted
mass-edit produces. kro stays the authority on everything else. The value is turning a 20-minute
Chainsaw run that fails with a wall of unrelated-looking `timed out waiting for the condition`
lines into a sub-second PR check that names the file and line.

---

## Failure 3: `acmcertificate` — the ACM preambles fight each other

### Symptom

```
| acmcertificate | preamble-apply-crds-and-rgds | SCRIPT | ERROR |
error: timed out waiting for the condition on resourcegraphdefinitions/acmcertificate.aws.kropath.run
```

The suite never reached AC-1. It failed in its own preamble, after 127s.

### Root cause

All five ACM suites opened with the same preamble shape:

```bash
kubectl apply -f ../../fixtures/crds/acm/          # overwrite live CRDs
kubectl apply -f ../../fixtures/crds/acmpca/
kubectl delete rgd <shared-rgd> --ignore-not-found=true
kubectl apply  -f ../../../rgds/<shared-rgd>.yaml
kubectl wait rgd <shared-rgd> --for=condition=Ready --timeout=120s
```

Every line mutates **cluster-wide** state, and chainsaw runs these suites concurrently
(`--parallel 4`) against one kro pod:

1. **The fixture CRDs are minimal hand-written stubs.** Their own headers say so ("Minimal CRD
   fixture ... Used by kro to resolve schema when compiling"). They exist as a fallback for a
   cluster without the real ACK charts. But `tests/setup.sh` installs the genuine ACK `acm`/`acmpca`
   CRDs from ECR (`hack/install-provider-crds.sh`, line 28), so applying the stubs on top **narrows
   the live schema** out from under whichever sibling suite is mid-compile. The CI log confirms the
   apply mutates them — `kubectl` reports `configured`, not `unchanged`.
2. **Shared RGDs get deleted out from under waiting suites.** `acmprivateca` is deleted and
   recreated by both the `acmprivateca` and `acmprivatecertificate` suites while `acmcertificate`
   waits on it; `acmeendpoint` likewise by both `acmeendpoint` and `acmedomainvalidation`. The
   `acmeendpoint` suite additionally deleted the kro-**generated** CRD `acmeendpoints.aws.kropath.run`.
3. **Each delete forces kro to tear down and re-derive a CRD.** Five suites doing that at once
   regularly pushed one RGD past the 120s wait.

None of this work is needed. `tests/setup.sh` already installs the real ACK CRDs *and* applies
*and* waits for every RGD before chainsaw starts — the CI log shows
`resourcegraphdefinition.kro.run/acmcertificate.aws.kropath.run condition met` during setup.
The preamble was pure churn that only created opportunities to race.

This is also why the failure looked like a "flaky test" while the `stepfunctions` ones did not: it
depends on how five concurrent suites interleave, so it fails on some runs and not others.

### Fix

Replaced all five preambles with one shared helper, `tests/acm/ensure-acm-prereqs.sh <rgd>...`,
that **verifies** instead of mutating:

- Applies the fixture CRDs **only when a required ACK CRD is genuinely absent**, so the normal path
  never touches a live schema and a bare-cluster `chainsaw test acm/` still works.
- Waits for each named RGD with `--timeout=30s`; on a cluster prepared by `setup.sh` this returns
  immediately. Only if that fails does it `kubectl apply --server-side` the RGD and wait 300s.
- **Deletes nothing.** If an RGD still will not go Ready it fails with kro's own condition message.

The dropped `acmcertificate` step that separately waited on `acmprivateca` is now redundant —
`acmprivateca` is passed to the helper in that suite's preamble.

### Why the helper does not "repair" a stuck RGD

A tempting extra step is: if the RGD stays `Inactive` with
`cannot update CRD ...: breaking changes detected: Property X was removed`, delete the RGD and its
generated CRD and rebuild. **Do not.** kro only re-derives a CRD on a fresh create, so the delete
is the only way — but on this cluster it cascades into the ACK child resources, whose finalizers
are never removed because the test cluster runs kro with **no ACK controllers**, and the delete
hangs. That is the trap `frequent-rgd-errors.md` §"CANONICAL: Unique-Name-Per-Step + `skipDelete`"
already documents.

That state only arises on a long-lived local cluster holding CRDs derived from an older revision of
an RGD. CI never hits it: `setup.sh` applies each RGD once into a freshly created kind cluster. The
correct local fix is `make teardown && make setup`, and the helper's error message says so rather
than attempting a delete that would hang.

---

## What removing the CRD overwrite unmasked

Once the ACM preambles stopped applying the stub CRDs over the real ACK ones, `acmedomainvalidation`
failed — on two bugs the overwrite had been hiding. Both are real: they would have failed against
actual AWS, and only ever "passed" because the suite replaced the live schema with a wrong one.

### 1. `domainScope.subdomains` / `wildcards` are `ENABLED`/`DISABLED`, not booleans

```
.spec.prevalidationOptions.dnsPrevalidation.domainScope.subdomains:
  expected string, got &value.valueUnstructured{Value:true}
```

The real ACK CRD types all three `domainScope` fields as `string`, and its own description says
"ExactDomain, Subdomains, Wildcards — each ENABLED or DISABLED". The fixture stub typed
`subdomains`/`wildcards` as `boolean`, and the RGD emitted raw booleans to match the stub.

Fixed in both `prevalidationOptions` emissions in `rgds/acmedomainvalidation.aws.kropath.run.yaml`:

```
"subdomains": (has(schema.spec.dnsPrevalidationSubdomains) && schema.spec.dnsPrevalidationSubdomains)
                ? "ENABLED" : "DISABLED"
```

The kropath-facing schema keeps `dnsPrevalidationSubdomains: boolean` — the enum is a wire-format
detail of the ACK API, not something to push onto users. Asserts updated to the wire values.

> **Left alone deliberately:** `exactDomain` is emitted as `schema.spec.dnsPrevalidationExactDomain`,
> a domain name (`ac4.example.com`), into a field the ACK description also documents as an
> ENABLED/DISABLED enum. It is structurally valid (`string` on both sides) so it is not what was
> breaking, but it looks semantically wrong. Changing it would redefine
> `spec.dnsPrevalidationExactDomain`, which is a spec decision, not a test fix — flagged here rather
> than changed.

### 2. A hand-rolled ACK `AcmeEndpoint` omitted a required field

```
The AcmeEndpoint "ref-ep" is invalid:
* spec.certificateAuthority: Required value
```

The real ACK CRD has `spec.required = [authorizationBehavior, certificateAuthority]`; the stub had
no `required` list at all. The `ac2-domain-validation-with-endpoint-ref` step builds a raw ACK
`AcmeEndpoint` by hand and set only `authorizationBehavior`. Added `certificateAuthority` (matching
what the ACMEEndpoint RGD emits).

### Fixture audit

Every ACM/ACMPCA stub was then diffed field-by-field against the live ACK CRD. After the fix there
are **no type mismatches**; five stubs were missing their `spec.required` lists, now added:

| Fixture | `required` added |
|---|---|
| `acmedomainvalidations.acm` | `domainName`, `prevalidationOptions` |
| `acmeendpoints.acm` | `authorizationBehavior`, `certificateAuthority` |
| `certificateauthorities.acmpca` | `certificateAuthorityConfiguration`, `type` |
| `certificateauthorityactivations.acmpca` | `certificate` |
| `certificates.acmpca` | `signingAlgorithm`, `validity` |

A stub that is laxer than the real CRD is exactly what let both bugs through, so keeping them
faithful is the point — not tidiness.

---

## A fourth failure, found by the local full-suite run

`apigatewayauthorizer` failed at `ac6-restapi-ref` after the full 5m assert timeout. It is unrelated
to any change here (it passed in the CI run under investigation) and is a genuine pre-existing race:

```
* spec.restAPIID: Invalid value: "": Expected value: "abc123def"
Authorizer "ac6-auth" is invalid: spec.restAPIID: Invalid value: "abc123def":
  Value is immutable once set
```

The step patches `status.id` on the **ACK** `RestApi`, then immediately applies the Authorizer. But
the authorizer RGD reads `status.restApiId` on the **kropath** `APIGatewayRestAPI`, which kro only
surfaces on a further reconcile hop. Losing that race creates the ACK `Authorizer` with
`restAPIID: ""` — and ACK marks that field immutable once set, so the correct value is rejected
permanently. Whether the hop wins varies with cluster load.

Fixed in the test, not the RGD: after patching, poll the kropath `APIGatewayRestAPI` until
`status.restApiId` is `abc123def`, and assert it, before applying the Authorizer.

> **Why not gate the RGD instead:** an `includeWhen` requiring a resolved `restAPIID` would be the
> stronger fix, but only `ac6` of the suite's 13 steps populates a RestAPI status at all — the other
> twelve deliberately exercise the authorizer with an unresolved ref and assert the ACK child
> exists. Gating would break all twelve. Making them each seed a status is a suite redesign, not a
> flake fix, so it is out of scope here.

---

## Verification

Full suite, against a kind cluster rebuilt from scratch (`make teardown && make setup && make test`):

```
Tests Summary...
- Passed  tests 178
- Failed  tests 0
- Skipped tests 0
```

The four suites that failed before:

```
--- PASS: chainsaw/stepfunctions/stepfunctionsactivity[stepfunctionsactivity]     (11.61s)
--- PASS: chainsaw/stepfunctions/stepfunctionsstatemachine[stepfunctionsstatemachine] (24.38s)
--- PASS: chainsaw/acm/acmcertificate[acmcertificate]                             (25.14s)
--- PASS: chainsaw/apigateway/apigatewayauthorizer[apigatewayauthorizer]          (16.35s)
--- PASS: chainsaw/pipes/pipesconfig[pipesconfig]                                  (0.98s)
```

Also verified:

- All RGDs reach `Active` — including both `stepfunctions` RGDs, which never compiled before.
- The ACM preambles now report `ACK ACM CRDs present — leaving the live schemas untouched` and
  `RGD <name> already Active`, i.e. they mutate nothing on the steady-state path.
- `make lint-rgd-cel`, `make lint-crds`, `tests/lint-test-scripts.sh` — pass.
- The CEL guard was verified negatively: reintroducing the surplus paren makes it exit 1 and name
  the file and line.

> **Setup note (environment, not code):** `hack/install-provider-crds.sh` resolves each ACK chart
> version through the unauthenticated GitHub API, which is capped at 60 req/hr. Repeated local
> `make setup` runs exhaust that and ~16 chart families get silently skipped
> (`WARNING: Could not resolve ACK chart version for <svc> (GitHub API error) — skipping`), leaving
> ~50 RGDs `Inactive` and the run meaningless. Export `GITHUB_TOKEN=$(gh auth token)` before
> `make setup` — the script already honours it (5000 req/hr). CI sets it from the workflow env, so
> this only bites locally. Worth knowing: the symptom looks like a mass RGD failure, not a
> rate limit.
