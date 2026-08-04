# 2026-08-04 — EventBridge suite (KRO-316, PR #71) CI failures after rebase onto main

PR #71 (EventBridgeEventBus / Rule / Archive / Endpoint RGDs + tests) failed
`Chainsaw E2E Tests`. Rebased onto `main`, reproduced locally with `make test-eventbridge`.
Root causes: missing provider bootstrap, several RGD schema/CEL bugs, and the old
shared-config test pattern fighting the global `skipDelete`. Final state: all suites PASS.

---

## 1. Missing ACK `eventbridge` provider CRDs + RBAC

Same class as the ELB PR. The RGDs reference `eventbridge.services.k8s.aws`, which was not
installed and not granted:
- `hack/install-provider-crds.sh`: added `eventbridge` to `ACK_SERVICES` (chart
  `eventbridge-chart`, appVersion 1.4.1 — provides Archive/Endpoint/EventBus/Rule).
- `tests/fixtures/rbac/kro-controller.yaml`: added `eventbridge.services.k8s.aws` to the
  aggregated ClusterRole. Without it, child resources are `forbidden` and never created.

## 2. RGD CEL: `effectiveName` outer-wrap paren errors (all four RGDs)

The naming-ConfigMap `effectiveName` expression must keep its opening `(` open through the
whole `.split()…transformList()…join()…replace()` chain and close it only at the very end
(compare the known-good `rgds/iamgroup.yaml`, which ends `…"iamgroup"))}` — two closes).

- **eventbus, rule** (schema includes `spec.tags`, 6-branch tag chain): the final line was
  missing the outer-wrap close → net +1 unmatched `(` → `Syntax error: missing ')' at EOF`.
  Fix: append one `)` to the final `.replace("{configRef}", …)` line (`…configRef))}`).
- **archive, endpoint** (schema has NO `spec.tags`, 5-branch tag chain): the tag-default line
  over-closed by one (`))))))` closed 5 conditions + the else-wrapper early, so `+ (suffix)`
  fell outside the chain and the outer wrap closed before `.join()`), AND the final line was
  missing the outer-wrap close. Symptom: `found no matching overload for '_?_:_' applied to
  '(bool, string, list(string))'`. Fix (net-neutral): tag-default line `))))))` → `)))))`
  (close only the 5 conditions), and final line `…configRef)}` → `…configRef))}`.

## 3. RGD schema: bare `array` is not a valid kro type

- **rule** `targets: array` and **endpoint** `eventBuses: array` failed with
  `unknown type: array`. kro requires a named element type. Added `types:` blocks:
  `Rule.Target {id, arn, roleARN, input, inputPath}` → `targets: "[]Target | default=[]"`;
  `Endpoint.EventBusRef {eventBusARN}` → `eventBuses: "[]EventBusRef | default=[]"`.

## 4. RGD: wrong ACK field names (archive, endpoint)

- **archive**: template set `spec.archiveName`; ACK Archive's field is `spec.name`. Fixed.
- **endpoint**: template set `routingConfig.failoverConfig.primary.healthCheck.arn` (object);
  ACK's `primary.healthCheck` is a plain STRING (the ARN). Fixed to
  `healthCheck: ${…primary.healthCheckArn}`.

## 5. Environmental: leftover ELB RGDs stalled kro during eventbridge testing

While iterating locally, ELB RGDs from the previous branch remained Active but this branch's
RBAC lacks `elbv2`, so kro's watch-manager flooded `forbidden`/`Watch error` logs for
`elbv2` GVRs and stopped reconciling eventbridge instances entirely (naming ConfigMap never
observed → child never created → 5-min assert timeouts). This is NOT an RGD bug — it is the
"passes in isolation but fails with stale cluster state" trap. Removing the stray ELB RGDs +
CRDs and restarting kro fixed it. In CI the cluster is fresh, so this does not occur.

## 6. Test rewrite: shared-config cross-contamination under global `skipDelete`

All four suites used the pre-canonical structure: one shared `general-policy` config mutated
across steps (`kubectl patch … general-policy`) plus per-step `cleanup:` blocks that
finalizer-strip and delete ACK children. Under global `skipDelete`, instances from earlier
steps persist; when a later step (e.g. the `{tag.unknown}` invalid-naming case) mutated the
shared config, kro re-reconciled the persisted instances against the bad config, flipping
their `resourceName` to `…{tag.unknown}` and dropping their children (the child's `includeWhen`
requires a resolved name) — so earlier steps' asserts non-deterministically timed out.

Fix: migrated all four suites to the CANONICAL pattern (see
`tests/dynamodb/dynamodbtable/chainsaw-test.yaml` and the rewritten
`tests/eventbridge/eventbridgeeventbus/chainsaw-test.yaml`): every step creates its OWN
uniquely-named `EventBridgeConfig` (`acN-cfg`, labelled + status-patched) and a uniquely-named
resource referencing it; NO shared config, NO `cleanup:` blocks, NO inter-step deletes /
finalizer-strips. Scripts that read the ACK child poll-until-exists first. CRD note: the
EventBridgeConfig CRD forbids `namingTemplate` in both `spec.mandatory` and `spec.defaults`,
so per-step config `spec` sets it in only one tier while the `status.effectiveConfig` patch
(unvalidated) may seed both to exercise mandatory-wins.

---

## Verification

`chainsaw test eventbridge/ --config ../.chainsaw.yaml --parallel 4` → all suites
(eventbridgeconfig, eventbridgeeventbus, eventbridgearchive, eventbridgerule,
eventbridgeendpoint) PASS, including on a second run against skipDelete leftover state.
