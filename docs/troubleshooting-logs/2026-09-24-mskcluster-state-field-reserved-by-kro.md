# Troubleshooting Log — kro v0.9.2 reserves the status field name `state`

> **⚠ POINT-IN-TIME RECORD.** This log captures what was observed and concluded at the time
> of writing. The claims it makes may be incorrect or may become incorrect as kro, ACK/KCC/ASO,
> or the platform evolves. Do NOT treat any claim in a troubleshooting log as authoritative.
>
> Authority precedence: **agent instructions > `docs/frequent-rgd-errors.md` > this log**.
>
> If this log contradicts `frequent-rgd-errors.md` or agent instructions, the log is wrong —
> flag the conflict rather than acting on the log.

---

## Context

**Date:** 2026-09-24
**Ticket:** KRO-1219
**Repo:** kropath-aws
**Resource family / technique:** MSKCluster RGD — status field wiring for the ACK child's lifecycle state

---

## Problem

While implementing `rgds/mskcluster.aws.kropath.run.yaml`, a status field declared as:

```yaml
status:
  state: >-
    ${cluster.?status.?state.orValue("")}
```

showed `status.state: "ACTIVE"` on a **brand-new instance whose child ACK `Cluster` CR had no
status at all yet** (confirmed via `kubectl get clusters.kafka.services.k8s.aws <name> -o
jsonpath='{.status}'` returning nothing). The CEL expression should have evaluated to `""` in
that state. Manually patching the child's real `status.state` to a different value afterward did
not change the parent's `status.state`, while sibling fields on the same status block wired the
same way (`clusterArn`, `bootstrapBrokerStringTLS`) *did* correctly pick up the corresponding
child status changes on the same reconcile pass.

A code-review comment on PR #299 flagged this as unsubstantiated, citing 9 other RGDs in this repo
(`ec2vpc`, `ec2instance`, `ec2natgateway`, `ec2prefixlist`, `ec2subnet`, `ec2transitgateway`,
`ec2transitgatewayattachment`, `ec2vpcendpoint`, `emrjobrun`, `emrserverlessapplication`) that
declare `status.state` directly from a child resource's real status "without issue." None of those
suites' Chainsaw tests actually assert a non-default `status.state` value, so "without issue" meant
"never exercised," not "confirmed working." This log reproduces the problem independently on one
of the cited RGDs (`ec2vpc`) to settle it.

---

## Root cause

**Verified mechanically** on `EC2VPC` (one of the 9 RGDs cited as a counter-example), using the
identical CEL pattern already present in `rgds/ec2vpc.aws.kropath.run.yaml`:

```yaml
status:
  state: >-
    ${ackVpc.?status.?state.orValue("")}
```

Reproduction:

```bash
kubectl create namespace state-probe
cat <<'EOF' | kubectl apply -f -
apiVersion: aws.kropath.run/v1alpha1
kind: EC2VPC
metadata:
  name: probe-vpc
  namespace: state-probe
spec:
  cidrBlock: "10.99.0.0/16"
EOF
# wait for reconcile
kubectl get ec2vpc probe-vpc -n state-probe -o jsonpath='{.status}'
```

Output (child `vpcs.ec2.services.k8s.aws/probe-vpc` had **no status at all** at this point):

```json
{"conditions":[...,{"reason":"NotReady","status":"False","type":"Ready"}],
 "flowLogStatus":"","state":"ACTIVE","vpcID":""}
```

`status.state` already reads `"ACTIVE"` while `vpcID` (wired the same way, from
`ackVpc.?status.?vpcID`) correctly reads `""` — proving the CEL evaluation itself is fine and the
anomaly is specific to the field named `state`.

Then, patching the **real** child status directly:

```bash
kubectl patch vpcs.ec2.services.k8s.aws probe-vpc -n state-probe --subresource=status --type=merge -p '{
  "status":{
    "vpcID":"vpc-0123456789abcdef0",
    "state":"pending",
    "ackResourceMetadata":{"arn":"arn:aws:ec2:ap-southeast-2:123456789012:vpc/vpc-0123456789abcdef0","ownerAccountID":"123456789012","region":"ap-southeast-2"}
  }
}'
kubectl get ec2vpc probe-vpc -n state-probe -o jsonpath='{.status.vpcID}{"\n"}{.status.state}{"\n"}'
kubectl get vpcs.ec2.services.k8s.aws probe-vpc -n state-probe -o jsonpath='{.status}'
```

Output:

```
vpc-0123456789abcdef0
ACTIVE
```

Child's real status (for comparison): `{"ackResourceMetadata":{...},"state":"pending","vpcID":"vpc-0123456789abcdef0"}`

`status.vpcID` correctly picked up the new value (`vpc-0123456789abcdef0`) on the same reconcile
pass. `status.state` did **not** — it stayed `"ACTIVE"` even though the real child now reports
`"pending"`. This rules out a stale-cache or reconcile-timing explanation: the pipeline is
demonstrably re-evaluating the status block and picking up other child fields correctly; only the
key literally named `state` is unaffected by its own CEL expression.

This reproduces the exact same symptom independently observed on `MSKCluster` during this PR's
implementation (a brand-new instance showed `status.state: "ACTIVE"` before its child `Cluster` had
any status, and a subsequent patch to the child's real `state` never propagated).

## Conclusion

kro v0.9.2 appears to reserve the literal status field name `state` for its own
instance-lifecycle summary (mirroring the `state` field kro already exposes on
`ResourceGraphDefinition` objects themselves) and overwrites it, regardless of the RGD author's
CEL expression for a field with that exact name. This affects **every** RGD in this repo that
declares a status field named `state` — including the 9 cited as counter-examples — not just
`MSKCluster`. It was not caught earlier because none of those suites' Chainsaw tests assert a
`status.state` transition away from the reconciler's own default.

**This is a hypothesis about kro's internal behavior, not something verified against kro's
source.** It is verified *empirically* (reproduced twice, on two unrelated resource families,
with a clean before/after comparison against sibling fields on the same object) but not by
reading kro's controller code. Treat the specific mechanism ("reserves the literal name `state`")
as the best available explanation for a well-reproduced symptom, not a confirmed root cause at the
source level.

---

## What worked

Rename the status field to avoid the collision — e.g. `clusterState` for `MSKCluster`:

```yaml
status:
  clusterState: >-
    ${cluster.?status.?state.orValue("")}
```

Re-tested on `MSKCluster`: after the rename, patching the child ACK `Cluster`'s real `status.state`
correctly propagates to `status.clusterState` on the next reconcile (see PR #299's Chainsaw
suite, AC-56).

---

## Pattern / rule derived

> **Rule (candidate for `frequent-rgd-errors.md`):** Do not name any RGD status field `state`.
> kro v0.9.2 silently overwrites a status field with that exact name with its own
> instance-lifecycle summary, regardless of the CEL expression assigned to it — sibling status
> fields on the same object wired identically (`vpcID`, `clusterArn`, etc.) are unaffected.  Use a
> more specific name instead (`clusterState`, `instanceState`, `<child>State`, …). This affects
> every RGD in this repo that currently declares `state` directly from a child resource — none of
> which have a Chainsaw scenario that would have caught it, since doing so requires patching the
> child's real status to a non-default value and asserting the parent tracks it (not just asserting
> presence).

---

## Corrections to prior logs

None — no prior log made a conflicting claim about `status.state`. This is the first
investigation of this specific symptom.
