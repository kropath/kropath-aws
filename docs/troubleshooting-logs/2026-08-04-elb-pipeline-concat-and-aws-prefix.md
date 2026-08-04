# 2026-08-04 — ELB pipeline: CEL `.concat()` breakage + AWS-prefix rename (KRO-368, PR #76)

PR #76 (ELB LoadBalancer / TargetGroup / Listener / Rule RGDs + tests) went red
again in CI after the stickiness/targets/forwardConfig/mutualAuthentication work
landed. This log covers the two issues fixed in that follow-up pass: the CEL
`.concat()` bug that broke the pipeline, and the `AWS`-prefix rename requested for
the ELB kinds. Final state: `RGD Tests / Chainsaw E2E Tests` GREEN, all 5 ELB
suites pass locally, all 6 review threads resolved.

---

## 1. Pipeline root cause — CEL `.concat()` is not a kro function

**Symptom (CI):** `make: *** [Makefile:20: setup] Error 1`. The setup step waits
for all RGDs to become Ready; the log showed `awselblistener`, `awselbloadbalancer`,
`awselbrule` reaching "condition met" but `awselbtargetgroup` (and then everything
after it) reporting `timed out waiting for the condition on
resourcegraphdefinitions/...`. The wall of timeouts is misleading — only one RGD is
actually broken.

**Reproduce locally:** the elbv2 ACK CRDs must be installed first, otherwise all
four ELB RGDs are `Inactive` for the unrelated reason
`cannot resolve group version "elbv2.services.k8s.aws/v1alpha1": schema not found`.
After `ACK_SERVICES="elbv2" bash hack/install-provider-crds.sh`, three ELB RGDs go
`Active` and only `awselbtargetgroup` stays `Inactive` — matching CI exactly.

**Cause:** `kubectl describe rgd elbtargetgroup.aws.kropath.run` →
```
failed to validate resource "tg": failed to compile template expression
"schema.spec.additionalAttributes.map(...).concat(...)" at path "spec.attributes":
ERROR: <input>:2:10: undeclared reference to 'concat'
Reason: InvalidResourceGraph
State:  Inactive
```
The stickiness→attributes mapping used `list.concat(otherList)`. kro's CEL dialect
has no `concat` function.

**Fix:** replace `.concat(x)` with the `+` list-concatenation operator (both the
outer and the nested call). RGD then reaches `Active`. See
`docs/frequent-rgd-errors.md` §2 "List Concatenation Uses the `+` Operator — kro's
CEL Has No `.concat()`".

**Debug lesson:** when CI reports "timed out on ALL RGDs", do NOT assume a cluster
problem — `kubectl describe rgd <name>` each ELB RGD and find the one with
`Reason: InvalidResourceGraph`; its condition message quotes the exact failing
expression and column.

---

## 2. Drop the `AWS` prefix from ELB RGD/CRD kinds

**Context:** `AWSELBListener`, `AWSELBLoadBalancer`, `AWSELBRule`,
`AWSELBTargetGroup` were the only kinds in the repo carrying an `AWS` prefix. Every
other resource kind (`IAMRole`, `S3Bucket`, `SNSTopic`, `EventBridgeRule`,
`DynamoDBTable`, `KMSKey`, …) has none. Aligns with KRO-434/KRO-459 (AWS-prefix
cleanup) and the convention now documented in CLAUDE.md / STANDARDS.md.

**Rename → `ELBListener` / `ELBLoadBalancer` / `ELBRule` / `ELBTargetGroup`.**
Touchpoints (all must move together or kro/tests break):
- RGD `spec.schema.kind`.
- RGD `metadata.name` (singular lowercased kind + group, e.g.
  `elbtargetgroup.aws.kropath.run`) — matches `iamrole.aws.kropath.run`,
  `dynamodbtable.aws.kropath.run`, etc.
- RGD file names (`rgds/elb*.aws.kropath.run.yaml`).
- Every child-resource `ownerReferences[].kind` inside the RGDs.
- Test dirs (`tests/elb/elb*`), the `00-*-namespace.yaml` files, `spec.namespace`,
  and every `kind:` / jq owner-kind assertion in the chainsaw suites.
- Stale comment `AWSELBConfig` → `ELBConfig` in `crds/kropathconfig.yaml` (the
  governance config kind was already `ELBConfig` — no AWS prefix).

**Verify:** delete the old-named RGDs/CRDs from the cluster, apply the renamed
RGDs, confirm all four reach `Active`, then `kubectl delete crd <old plural>` so kro
regenerates. `make test-elb` must be re-run — chainsaw asserts the child
`ownerReferences[0].kind` equals the new kind (e.g. `ELBRule`).

---

## 3. (Environmental, not a repo bug) kro RBAC for `elbv2` must be applied + watches re-established

**Symptom during local re-verify:** every ELB suite that creates a child ACK
resource failed with `actual resource not found`; kro logs showed
`rules.elbv2.services.k8s.aws ... is forbidden: User
"system:serviceaccount:kro-system:kro" cannot list resource "rules"`.

**Cause:** the local cluster's kro ClusterRole predated the `elbv2` grant. The repo
fixture `tests/fixtures/rbac/kro-controller.yaml` **already** lists
`elbv2.services.k8s.aws` — CI applies it fresh in `make setup`, so CI is unaffected.

**Fix (local only):** `kubectl apply -f tests/fixtures/rbac/kro-controller.yaml`
then `kubectl rollout restart deployment kro -n kro-system` so the dynamic
controller re-establishes its informers/watches with the new permissions. After
that, children are created and all 5 suites pass. No repo change needed — noted here
so a future local run recognizes stale-RBAC "not found" failures immediately.
