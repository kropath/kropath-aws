> **Point-in-time disclaimer:** This log records observations and conclusions as of 2026-08-29.
> Claims here are hypotheses drawn from that investigation; they may not hold after kro upgrades,
> controller changes, or refactors. Cross-check against `docs/frequent-rgd-errors.md` before acting.

# 2026-08-29: KRO-888 — SSMParameter CI failure: two root causes

## Symptom

Chainsaw CI for `ssmparameter` suite failed on PR #163 (`agent/implementer/c1b7b98c6433`).
`ac1-create-defaults` timed out after 5 minutes with `actual resource not found` on the ACK
Parameter. No ACK Parameter was ever created.

## Root Cause 1: kro cannot list `v1/Secret` resources (RBAC)

The `paramSecret` externalRef uses `selector.matchLabels` to find a `v1/Secret` with
`aws.kropath.run/parameter-secret: <name>`. Even when the secret doesn't exist (String/StringList
types with no `spec.valueFrom`), kro still calls the Kubernetes API to LIST secrets matching the
label selector. Without permission to list secrets, the listing call fails with:

```
resource reconciliation failed: failed to list external collection paramSecret:
secrets is forbidden: User "system:serviceaccount:kro-system:kro" cannot list
resource "secrets" in API group "" in the namespace "ssmparameter"
```

This blocked reconciliation entirely — neither the naming ConfigMap nor the ACK Parameter was
ever created.

**Verification:**
```bash
kubectl auth can-i list secrets --as=system:serviceaccount:kro-system:kro  # → no
```

**Fix:** Added `v1/secrets` (get, list, watch) to the aggregated ClusterRole in
`tests/fixtures/rbac/kro-controller.yaml`. Applied with:
```bash
kubectl apply -f tests/fixtures/rbac/kro-controller.yaml
kubectl rollout restart deployment/kro -n kro-system
```

After fix:
```bash
kubectl auth can-i list secrets --as=system:serviceaccount:kro-system:kro  # → yes
```

This fix is consistent with `docs/frequent-rgd-errors.md` lines 860-865 (provider bootstrap
reminder) and 1084-1086 (kro ClusterRole must include all API groups the RGD accesses).

## Root Cause 2: ac11-type-immutable test — strategic merge retains both `spec.value` and `spec.valueFrom`

**Symptom:** After fixing root cause 1, the ssmparameter suite ran fast (no more 5-minute
timeout) but failed at `ac11-type-immutable`. The ACK Parameter `ac11-param` disappeared after
the second `apply` step. The script check returned `Got:` (empty string).

**Analysis:**

The `ac11` scenario:
1. Creates SSMParameter with `type: String, value: original-value`
2. Asserts ACK Parameter with `type: String` — passes
3. Patches SSMParameter to `type: SecureString, valueFrom: {secretKeyRef: {name: ac11-secret, key: value}}`

The patch in step 3 did NOT include `value: ""`. Kubernetes strategic merge KEPT `spec.value:
"original-value"` from step 1. After the patch:
- `spec.value = "original-value"` (retained)
- `spec.valueFrom.secretKeyRef.name = "ac11-secret"` (newly set)

The naming ConfigMap's `valueIsValid` check fails when BOTH `spec.value` and
`spec.valueFrom.secretKeyRef.name` are non-empty (mutual exclusion rule). With `valueIsValid:
"false"`, the `ackParameter` is excluded by `includeWhen`. kro deletes the existing ACK Parameter
(which had no finalizer, since no ACK controller is running in the test cluster), and does not
create a new one.

The ACK Parameter disappeared entirely, causing the test script's
`kubectl get parameters.ssm.services.k8s.aws ... -o jsonpath='{.spec.type}'` to return empty.

**Verified separately (immutability behavior):**

When `valueIsValid` IS "true" (both fields not set simultaneously) and kro tries to update an
existing ACK Parameter from `type: String` to `type: SecureString`, the ACK SSM Parameter CRD
has `x-kubernetes-validations: self == oldSelf` on `spec.type`. The Kubernetes API rejects the
update:
```
The Parameter "..." is invalid: spec.type: Invalid value: "SecureString": Value is immutable once set
```
kro marks the SSMParameter as ERROR and retries. The ACK Parameter remains with `type: String`.

**Fix:** In the `ac11` test:
1. First apply: add `valueFrom: {secretKeyRef: {name: "", key: ""}}` — explicitly clears any
   residual `valueFrom` state from a previous test run (idempotency fix for re-runs with
   `skipDelete: true`).
2. Second apply: add `value: ""` — explicitly clears `spec.value` so strategic merge doesn't
   retain it alongside the new `valueFrom`.

With these fixes, `valueIsValid` evaluates to "true", kro includes `ackParameter` and tries to
update `spec.type` → API rejects → ACK Parameter stays `type: String` → test PASSES.

## Affected Files

| File | Change |
|---|---|
| `tests/fixtures/rbac/kro-controller.yaml` | Added `v1/secrets` get/list/watch rule to kro aggregated ClusterRole |
| `tests/ssm/ssmparameter/chainsaw-test.yaml` | Fixed `ac11-type-immutable`: explicit `value: ""` and `valueFrom: {name: "", key: ""}` in applies |

## Test Results

After both fixes:
```
PASS: chainsaw/ssm/ssmconfig[ssmconfig] (1.89s)
PASS: chainsaw/ssm/ssmdocument[ssmdocument] (11.03s)
PASS: chainsaw/ssm/ssmparameter[ssmparameter] (42.91s)
Tests Summary... Passed: 3, Failed: 0
```

All 20 acceptance criteria pass for `ssmparameter`, including:
- AC-1 through AC-10 (happy path, negative path)
- AC-11 (type immutability — ACK CRD x-kubernetes-validations enforcement)
- AC-12 through AC-20 (tier upgrade, key, tags, metadata, deletion policy)
