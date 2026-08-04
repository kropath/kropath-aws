# 2026-08-04 — ELB suite (KRO-368, PR #76) CI failures after rebase onto main

PR #76 (AWSELBLoadBalancer / TargetGroup / Listener / Rule RGDs + tests) failed
`Chainsaw E2E Tests` in CI. Rebased onto `main` and reproduced locally with
`cd tests && make test-elb`. Root causes were a mix of missing provider bootstrap,
RGD CEL bugs, and test-fixture bugs. Final state: all 5 ELB suites PASS.

---

## 1. Missing ACK `elbv2` provider CRDs — RGDs never leave `Inactive`

**Symptom:** All ELB RGDs stuck `Inactive`; every suite fails fast with
`the server doesn't have a resource type "awselbloadbalancer"`. RGD condition:
`cannot resolve group version "elbv2.services.k8s.aws/v1alpha1": schema not found`.

**Cause:** `hack/install-provider-crds.sh` `ACK_SERVICES` list did not include
`elbv2`, so the ELB CRDs the RGDs reference were never installed.

**Fix:** add `elbv2` to `ACK_SERVICES` (chart `elbv2-chart`, appVersion 1.5.2).

## 2. kro ServiceAccount lacks RBAC for `elbv2.services.k8s.aws`

**Symptom:** AWSELBRule/Listener instances reconcile with
`rules.elbv2.services.k8s.aws "..." is forbidden: User "system:serviceaccount:kro-system:kro" cannot get resource "rules"`.
Child ACK resources never created → `assert`/`script` steps time out or read "not found".

**Fix:** add `elbv2.services.k8s.aws` to the aggregated ClusterRole in
`tests/fixtures/rbac/kro-controller.yaml`.

## 3. RGD CEL: extra `(` in `namingStatus` (LoadBalancer + TargetGroup)

**Symptom:** `GraphAccepted=False: ... Syntax error: missing ')' at '<EOF>'` pointing
at `: "valid"`.

**Cause:** `namingStatus` opened `${((schema.spec.nameOverride ...` (two parens) while
the structurally-identical `resourceName` expression opens with one. Net +1 unmatched `(`.

**Fix:** drop one paren so the opener matches `resourceName` (`${(schema...`); the
trailing `.contains("{") ? "invalid-unresolved-tokens" : "valid"` then binds correctly.

## 4. RGD CEL: single-key map literal cannot coerce to multi-type ACK struct (Listener)

**Symptom:** `type mismatch in resource "listener" at path "spec.certificates": expression
"...map(c, {"certificateARN": c.certificateArn})" returns type "list(map(string, string))"
but expected ... struct field "isDefault": type kind mismatch: got "string", expected "bool"`.

**Cause:** ACK `Certificate` struct is `{certificateARN: string, isDefault: bool}`. A CEL
map literal with a single string key/value is inferred as concrete `map(string, string)`,
which kro cannot coerce to a struct that has a `bool` field. (The `defaultActions` map does
not hit this because its literals mix string+int → `map(string, dyn)`.)

**Fix:** wrap the value in `dyn()` so the literal becomes `map(string, dyn)`:
`schema.spec.certificates.map(c, {"certificateARN": dyn(c.certificateArn)})`. kro then
coerces by field name (certificateARN → string; isDefault omitted, which is what AWS wants).
Documented in `frequent-rgd-errors.md`.

## 5. Test fixture: `naming-mandatory` ELBConfig set namingTemplate in BOTH tiers

**Symptom (LB, TG seed step):** `The ELBConfig "naming-mandatory" is invalid: ...
namingTemplate must be set in either mandatory or defaults, not both.`

**Cause:** the ELBConfig CRD (on main) forbids both `spec.mandatory.namingTemplate` and
`spec.defaults.namingTemplate` being non-empty; the seed fixture set both.

**Fix:** leave `spec.defaults.namingTemplate: ""`. The `status.effectiveConfig` patch still
seeds both tiers, so the RGD's mandatory-wins logic is still exercised.

## 6. Test scripts raced kro's async reconcile (all four suites)

**Symptom:** `- script:` steps doing a one-shot `kubectl get <child>.elbv2 ... | jq`
immediately after `apply` failed with `NotFound` / `jq: Cannot check whether object has a
null key` (child not yet created). This is the same one-shot-read race documented for the
IAM suites.

**Fix:** prepend a `for _ in $(seq 1 60); do kubectl get <child> ... && break; sleep 1; done`
poll-until-exists guard to each racing script (28 blocks). Once the kro-built child exists
its spec is complete (kro writes the whole child in one pass; no ACK controller re-writes it),
so poll-until-exists is sufficient — no count-stabilisation loop needed.

## 7. Test bug: malformed `jq 'has(.spec.name)'` (Rule, Listener `name-override-noop`)

**Symptom:** `jq: error: Cannot check whether object has a null key`.

**Cause:** `has()` takes a key applied to an object; `has(.spec.name)` passes the *value*
of `.spec.name` (null, since the field is correctly absent) → `has(null)` errors.

**Fix:** `jq '.spec | has("name")'`.

---

## Verification

`cd tests && chainsaw test elb/ --config ../.chainsaw.yaml --parallel 4` →
all 5 suites (elbconfig, awselbloadbalancer, awselbtargetgroup, awselblistener, awselbrule)
PASS, 0 failed, 0 skipped — including on a second run against skipDelete leftover state.
