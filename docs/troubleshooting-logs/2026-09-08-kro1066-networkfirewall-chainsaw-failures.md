# KRO-1066 — NetworkFirewall Chainsaw failures (`networkfirewallfirewall` ac25, `networkfirewallrulegroup` ac5)

**Date:** 2026-09-08
**Branch:** `fix/kro-1066-networkfirewall`
**Baseline evidence:** CI run `34200471146` — 229 passed / 2 failed, both NetworkFirewall.

Two failures remained after commit `289b6cb2` (preserved locally as tag
`kro-1066-partial-fix-289b6cb`) corrected the ACK field paths. That commit was necessary but not
sufficient; it is folded into this branch unchanged and re-verified against the real ACK CRD
(`networkfirewall-chart:1.5.0`), not the fixture stub.

---

## Pre-work: the stub-vs-real CRD trap

The local kind cluster held the **stub** Firewall CRD with a flat `status.firewallID`, while CI
installs the **real** ACK CRD with `status.firewall.firewallID`. Diagnosing against the stub
produces phantom conclusions. Verified before touching anything:

```
kubectl get crd firewalls.networkfirewall.services.k8s.aws -o json \
  | jq '.spec.versions[0].schema.openAPIV3Schema.properties.status.properties | keys'
# stub:  ["ackResourceMetadata","conditions","firewallARN","firewallID"]
# real:  ["ackResourceMetadata","conditions","firewall","firewallStatus"]
```

All work below was done on a **dedicated fresh cluster** (`kind-kropath-aws-kro1066`) created with
`make setup CLUSTER_NAME=kropath-aws-kro1066`, so the shared `kropath-aws-test` cluster — which
other agents mutate concurrently — could not contaminate the result.

Confirmed against the real CRDs (both match `kropath-core/docs/crd-cache/aws/networkfirewall-v1.4.1.md`):

- `Firewall.status.firewall.{firewallARN,firewallID}` — nested, not flat.
- `RuleGroup.spec.ruleGroup.referenceSets.ipSetReferences[].referenceARN` — lowercase `ip`,
  Go-acronym `referenceARN`.

---

## Failure 1 — `networkfirewallfirewall` / `ac25-firewall-id-from-ack-status`

**Symptom:** `SCRIPT ERROR / exit status 1`.

**Root cause: a race, not a field-name problem.** The CI log timestamps show the step applying the
`NetworkFirewallFirewall` CR and then immediately shelling out to patch the ACK child, within the
same second:

```
07:50:04.460  ac25 | APPLY  | DONE
07:50:04.536  ac25 | SCRIPT | STDERR
              Error from server (NotFound):
              firewalls.networkfirewall.services.k8s.aws "networkfirewallfirewall-ac25-fw" not found
```

kro creates the ACK child asynchronously. A `- script:` step runs **once** and does not poll, so it
loses the race. (`assert` polls; `script` does not — that asymmetry is the whole bug.)

**Fix.** Adopt the pattern already used by `tests/ssm/ssmpatchbaseline` and
`tests/cognito/cognitouserpool`: insert an `assert` on the ACK child *before* the patch script, so
chainsaw blocks until the child exists. The resource name is also fully qualified
(`kubectl patch firewalls.networkfirewall.services.k8s.aws …` instead of bare `firewall`) per the
repo's ambiguous-short-name rule. Applied to both `ac25` and `ac26` — `ac26` had the identical
latent race and was only masked because chainsaw stops a suite at its first failing step.

---

## Failure 2 — `networkfirewallrulegroup` / `ac5-stateful-suricata-string`

**Symptom:** `ASSERT ERROR / actual resource not found` after the full 5-minute assert timeout —
i.e. the ACK `RuleGroup` child was genuinely never created, not merely late.

`ac5` is the only step that sets `spec.rules` (Suricata string) and omits `spec.ruleGroup`.

### Root cause: `has()` is useless on object-typed schema fields

**kro emits `default: {}` for every object-typed field in the generated CRD**, so Kubernetes
materializes the whole nested tree on every instance and `has(schema.spec.ruleGroup)` is
*unconditionally true*. Reproduced directly — a CR that never mentioned `ruleGroup`:

```
$ kubectl get networkfirewallrulegroup r5-rg -n nfwrepro -o json | jq -c '.spec.ruleGroup'
{"referenceSets":{"ipSetReferences":{}},"ruleVariables":{"ipSets":{},"portSets":{}},
 "rulesSource":{"rulesString":"","statefulRules":[],
 "statelessRulesAndCustomActions":{"customActions":[],"statelessRules":[]}},
 "statefulRuleOptions":{"ruleOrder":""}}
```

The defaulting is recursive; only sub-objects whose fields are *all* `required=true` escape it
(e.g. `rulesSourceList`, which therefore still answers `has()` honestly).

This is the **object analogue of the documented boolean `| default=false` trap** — except no
default was declared anywhere in the RGD. kro adds it on its own, so the trap fires on *any*
object-typed field.

Three consequences, all reproduced:

1. `ackRuleGroupNoEnc` / `ackRuleGroupWithEnc` carried an `includeWhen` gate
   `${!(has(schema.spec.ruleGroup) && rules != '')}` → evaluates to `false` whenever `rules` is
   set → **both variants excluded, no child created**. This is ac5.
2. `mutualExclusionError` fired spuriously: an instance setting only `rules` reported
   `validationError: "ruleGroup and rules are mutually exclusive…"`.
3. kro still reported `Ready=True / AllResourcesReady` — the failure was completely silent.

### Second layer: `null` does not omit a field

The first attempted fix keyed the field off `rules` instead
(`${rules != "" ? null : schema.spec.ruleGroup}`). That surfaced the next error, exactly as
`CLAUDE.md` §8 predicts:

```
resource reconciliation failed: RuleGroup.networkfirewall.services.k8s.aws "nfwrepro-r5-rg"
is invalid: spec.ruleGroup: Invalid value: "null": spec.ruleGroup in body must be of type object
```

**kro renders a CEL `null` literally** — it does not drop the key — and the ACK CRD types
`spec.ruleGroup` as a non-nullable object. So `${cond ? x : null}` can never omit a field in kro
v0.9.2; the only supported way to omit one is a resource variant split (as the RGD already does for
`encryptionConfiguration`).

### Fix

- **Removed** the non-canonical mutual-exclusion `includeWhen` gate from both ACK variants. Every
  other RGD in the repo (`apigatewayrestapi`, `ecrrepository`, `cognitouserpool`, …) treats
  `mutualExclusionError` as **advisory only** and never suppresses the child; this RGD was the
  outlier. `ac7` asserts only `status.validationError`, so it is unaffected.
- **`ruleGroup` is now emitted unconditionally** (`${schema.spec.ruleGroup}`). The old ternary was
  provably dead code — its `has()` was always true — and its `null` branch was unreachable *and*
  invalid. Because kro defaults the field, an unset `spec.ruleGroup` is already a valid empty
  object. This mirrors `rules`, which is likewise emitted as `""` when unused.
- **`mutualExclusionError` now detects presence by leaf content**, not key existence — checking
  `rulesString`, `statefulRules`, `rulesSourceList`, `statelessRules`, `customActions`, `ipSets`,
  `portSets`, `ruleOrder` and `ipSetReferences`. `ac7` (both set) still reports the error; `ac5`
  (rules only) correctly reports none.

### Same trap, pre-emptively fixed in `networkfirewallpolicy`

`rgds/networkfirewallpolicy.aws.kropath.run.yaml` carried the identical dead ternary
`policyVariables: ${has(...) ? ... : null}` in both variants. It passes today *only* because
`has()` is always true, so the invalid `null` branch is never taken — verified: the instance
materializes `policyVariables: {ruleVariables:{}}` and the child receives it. Rewritten to
`${schema.spec.policyVariables}`: behaviourally identical today, but it removes a landmine that
would detonate the moment the type's fields all became `required`.

---

## Known residual (not introduced here, not in scope for KRO-1066)

`ruleGroup` and `rules` are mutually exclusive on the AWS API, but the RGD sends **both** on every
create — the unused one as its empty value (`rules: ""` or an empty `ruleGroup` tree). ACK
dereferences non-nil pointers, so against real AWS this would likely be rejected. Correctly omitting
one requires a 2×2 variant split (ruleGroup/rules × encryption), since `null` cannot omit a field.
This pre-dates KRO-1066 and is invisible to the Chainsaw suites (no ACK controller runs there);
raised on the ticket rather than fixed here to keep the change scoped.

---

## Verification

Dedicated fresh cluster, real ACK CRDs, **test namespaces deleted before the run** so no warm state
could mask a failure:

```
- Passed  tests 4
- Failed  tests 0
- Skipped tests 0
```

Substantively (not just green):

| check | result |
|---|---|
| ACK `RuleGroup` children created | 27 |
| ACK `Firewall` children created | 28 |
| ACK `FirewallPolicy` children created | 26 |
| `ac5` child `spec.rules` | Suricata string present |
| `ac25` `status.firewallId` | `test-fw-id-001` (via nested `status.firewall.*`) |
| `ac26` `status.firewallArn` | populated |
| `ac7` `status.validationError` | mutual-exclusion message still reported |

Each edited RGD was verified by `kubectl delete rgd` + `kubectl apply` (not a bare `apply`, which
does not re-run graph validation — `CLAUDE.md` §8) and reached `Active` with `GraphAccepted=True`.
`./lint-test-scripts.sh` and `./select-tests-test.sh` (10/10) both pass.
