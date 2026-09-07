> **Point-in-time disclaimer:** This log records observations as of 2026-09-07. Claims about kro
> behaviour, ACK CRD schema, server-side-apply semantics, and ECR chart availability are
> hypotheses confirmed locally on that date. They may not hold after a kro upgrade, an ACK chart
> bump, or a new ACK service becoming publicly available. Verify mechanically before acting.

# Fixture CRD stubs silently downgraded real ACK CRDs — `ekscluster` broke in a Bedrock-only PR

**Ticket:** KRO-815
**Date:** 2026-09-07
**Symptom:** CI `RGD Tests` failed on PR #228 with exactly one failing suite — `chainsaw/eks/ekscluster`
— in a PR that adds only Bedrock RGDs and tests and never touches EKS. All four new Bedrock suites
passed. 193 passed, 1 failed.

```
timed out waiting for the condition on resourcegraphdefinitions/ekscluster.aws.kropath.run
  - ekscluster.aws.kropath.run: failed to build resource "ackClusterWithVersion":
    failed to extract CEL expressions from schema for resource ackClusterWithVersion:
    error getting field schema for path spec.deletionProtection:
    schema not found for field deletionProtection
...
| ekscluster | ac1-ac5-basic-cluster | APPLY | ERROR | aws.kropath.run/v1alpha1/EKSCluster @ ekscluster/prod
    no matches for kind "EKSCluster" in version "aws.kropath.run/v1alpha1"
```

## What Failed

`tests/setup.sh` gained a step that blanket-applied **every** stub CRD under `tests/fixtures/crds/`:

```bash
find "${SCRIPT_DIR}/fixtures/crds" -name "*.yaml" ... | sort | while IFS= read -r f; do
    kubectl apply --server-side -f "${f}" 2>&1 | grep -v "^$" || true
  done
```

The step was added so the new Bedrock suites could get CRDs that are unavailable from ECR. But
`tests/fixtures/crds/` already contained **pre-existing stubs for services that *are* pulled from
ECR** — `eks`, `iam`, `s3`, `acm`, `acmpca`, `cognito`. Those had never been applied before. The
new `find` applied them on top of the real ACK CRDs that
`hack/install-provider-crds.sh` had just installed, one step earlier.

## Root Cause

Two compounding facts:

1. **The stubs are stale, hand-trimmed snapshots.** `tests/fixtures/crds/eks/eks.services.k8s.aws_clusters.yaml`
   predates `spec.deletionProtection`; the field does not appear anywhere in the file. The real
   `eks-controller` chart (v1.22.0 as of this date) has it.
2. **Server-side apply does NOT merge a CRD schema — it replaces it.** A CRD's `spec.versions` is an
   atomic list, so applying the stub swaps the entire OpenAPI schema for the narrower one. The
   in-code comment asserting *"server-side apply is a no-op for unchanged resources"* was simply
   wrong: the resources were not unchanged, and SSA had no reason to treat them as such.

Chain: stub clobbers real Cluster CRD → `spec.deletionProtection` disappears → kro cannot extract
CEL for `ackClusterWithVersion` → `ekscluster.aws.kropath.run` goes `Inactive` → kro never derives
the `EKSCluster` CRD → the suite's first apply dies on `no matches for kind "EKSCluster"`.

Nothing about EKS changed. The blast radius was determined purely by which stale stubs happened to
sit in the fixtures tree.

### Local reproduction (decisive)

Against a cluster holding the real EKS CRD:

```console
$ kubectl apply --server-side --force-conflicts -f tests/fixtures/crds/eks/eks.services.k8s.aws_clusters.yaml
$ kubectl get crd clusters.eks.services.k8s.aws -o json \
    | jq '.spec.versions[0].schema.openAPIV3Schema.properties.spec.properties | has("deletionProtection")'
false                                  # ← was true before the stub apply
$ kubectl delete rgd ekscluster.aws.kropath.run && kubectl apply -f rgds/ekscluster.aws.kropath.run.yaml
$ kubectl get rgd ekscluster.aws.kropath.run -o jsonpath='{.status.state}'
Inactive
```

## The Fix

Make the stub step a **strict fallback**: apply a stub only when its CRD is absent from the cluster.
Never overwrite a CRD that `install-provider-crds.sh` already installed.

```bash
while IFS= read -r f; do
  # metadata.name is the first line at indent 2 in every stub; spec.names.* sit at indent 4.
  crd_name="$(grep -m1 -E '^  name: ' "${f}" | sed 's/^  name: //')"
  if [[ -z "${crd_name}" ]]; then
    echo "    WARN: no metadata.name found in ${f} — skipping"; continue
  fi
  if kubectl get crd "${crd_name}" &>/dev/null; then
    echo "    skip ${crd_name} (real CRD already installed)"; continue
  fi
  echo "    stub ${crd_name}"
  kubectl apply --server-side -f "${f}" >/dev/null
done < <(
  find "${SCRIPT_DIR}/fixtures/crds" -name "*.yaml" -not -path "*/kind-config*" -not -path "*/rbac*" | sort
)
```

This yields exactly the intended split, verified on a fresh cluster:

- `eks`, `iam`, `s3`, `acm`, `acmpca`, `cognito` → **skipped**, real ECR CRDs retained.
- `bedrock`, `bedrockagent`, `bedrockagentcorecontrol` → **stubbed**, because their charts genuinely
  do not exist in ECR.

### Why the Bedrock stubs are still needed

All three Bedrock controllers have upstream GitHub releases, so
`resolve_ack_chart_version` succeeds and the service is *not* skipped at that stage — but the Helm
chart pull fails, and `install-provider-crds.sh` only emits a `WARNING` and continues:

```console
$ helm pull oci://public.ecr.aws/aws-controllers-k8s/bedrock-chart --version 1.4.0
Error: ... (chart not found in ECR)
```

Confirmed 2026-09-07 for `bedrock` 1.4.0, `bedrockagent` 1.3.1, `bedrockagentcorecontrol` 1.15.0.
Having a GitHub release is therefore **not** evidence that a chart is pullable — check the chart,
not the release.

## Rules To Carry Forward

- **Never blanket-apply fixture CRDs.** Gate every stub on `kubectl get crd <name>` returning
  non-zero. A stub is a fallback for an *absent* CRD, never a patch on a present one.
- **`kubectl apply --server-side` on a CRD replaces the schema.** `spec.versions` is an atomic list;
  SSA does not deep-merge OpenAPI properties. Do not reason about it as a merge.
- **A one-suite failure in an unrelated service points at shared setup**, not at that service. When a
  PR that touches only service A breaks only service B, read `tests/setup.sh` and
  `hack/install-provider-crds.sh` before touching B's RGD.
- **`kubectl apply --dry-run=client` still contacts the API server** and cannot be used to parse a
  manifest offline. Parse the file directly when a name is needed before the cluster exists.
- **Adding a service to `ACK_SERVICES` does not guarantee real CRDs.** Verify with an actual
  `helm pull` against `public.ecr.aws/aws-controllers-k8s/<svc>-chart`.

---

# BedrockHarness `tools[].config` — modelling a real ACK discriminated union

**Ticket:** KRO-815
**Date:** 2026-09-07
**Symptom:** After the stub-clobber fix above, `bedrockharness/ac19-tools-configuration` failed with
`ASSERT ERROR: actual resource not found` — the ACK `Harness` child was never created. The other
four Bedrock suites passed.

## Root Cause

With the real `bedrockagentcorecontrol` CRD in play (it *is* published to ECR — the stub was never
needed), `spec.tools[].config` is a **discriminated union**, not a free-form map:

```console
$ kubectl get crd harnesses.bedrockagentcorecontrol.services.k8s.aws -o json \
  | jq '.spec.versions[0].schema.openAPIV3Schema.properties.spec.properties.tools.items.properties.config.properties | keys'
["agentCoreBrowser","agentCoreCodeInterpreter","agentCoreGateway","inlineFunction","remoteMcp"]
```

The RGD declared `config: map[string]string | default={}` and the test sent
`config: {browserID: "br-123"}`. ACK rejects the undeclared key, so the child never materialises.
This is the standing repo rule in action: **verify every field name AND type against the live ACK
CRD.** The earlier "fix" (adding `x-kubernetes-preserve-unknown-fields` to the *fixture*) only
appeared to work because the fixture was illegitimately overriding the real CRD.

## The Fix

Model the union with nested named types in the RGD (kro supports type-to-type references):

```yaml
types:
  BedrockHarnessTool:
    name: string | default=""
    type: string | default=""
    config: BedrockHarnessToolConfig
  BedrockHarnessToolConfig:
    agentCoreBrowser: BedrockHarnessToolBrowser
    agentCoreCodeInterpreter: BedrockHarnessToolCodeInterpreter
    agentCoreGateway: BedrockHarnessToolGateway
    inlineFunction: BedrockHarnessToolInlineFunction
    remoteMcp: BedrockHarnessToolRemoteMcp
  BedrockHarnessToolBrowser:
    browserARN: string          # NOTE: no `| default=""` — see below
  ...
```

and send the real shape from the test:

```yaml
tools:
  - name: browser
    type: agentCoreBrowser
    config:
      agentCoreBrowser:
        browserARN: "arn:aws:bedrock-agentcore:ap-southeast-2:123456789012:browser/aws.browser.v1"
```

## Trap: leaf defaults make kro materialise EVERY union branch

A named-type field is given a synthesized `{}` default in the derived CRD **iff every one of its
leaves carries a default**. With `browserARN: string | default=""` on all five members, the derived
CRD looked like this — and every tool would ship all five branches to AWS:

```console
$ kubectl get crd bedrockharnesses.aws.kropath.run -o json | jq -c '... .config.properties | map_values(.default // "NO-DEFAULT")'
{"agentCoreBrowser":{},"agentCoreCodeInterpreter":{},"agentCoreGateway":{},"inlineFunction":{},"remoteMcp":{}}
```

Dropping `| default=""` from the leaves removes the synthesized parent defaults:

```console
{"agentCoreBrowser":"NO-DEFAULT","agentCoreCodeInterpreter":"NO-DEFAULT", ... }
```

This is the same defaulting trap already documented for tri-state booleans, one level up: **declare
union members and their leaves bare so only the branch the user actually sets is emitted.** The
ac19 assert now pins this explicitly:

```bash
[ "$(echo "$TOOL" | jq -r '.config | keys | join(",")')" = "agentCoreBrowser" ]
```
