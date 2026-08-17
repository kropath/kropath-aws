# Local Testing with Kind — kropath-aws

This guide walks through setting up a local Kubernetes cluster using [Kind](https://kind.sigs.k8s.io/)
for developing and testing kropath-aws resources without an active AWS account or cloud cluster.

The cluster runs **kro only — no ACK controllers**. Only the ACK *CRD schemas* are installed, so
child resources (`Bucket`, `Role`, …) are created and validated by the API server but never
reconciled against AWS. Nothing in this guide talks to AWS or needs credentials.

## Prerequisites

Install the following tools before running any setup scripts:

| Tool | Version | Install |
|------|---------|---------|
| [Docker](https://docs.docker.com/get-docker/) | 24+ | Required by Kind |
| [kind](https://kind.sigs.k8s.io/docs/user/quick-start/#installation) | v0.32.0 (CI pin) | `brew install kind` |
| [kubectl](https://kubernetes.io/docs/tasks/tools/) | v1.29+ | `brew install kubectl` |
| [helm](https://helm.sh/docs/intro/install/) | v3.13+ | `brew install helm` — used to pull ACK CRD charts |
| [chainsaw](https://kyverno.github.io/chainsaw/latest/install/) | v0.2.15 (CI pin) | `brew install kyverno/tap/chainsaw` |
| `curl`, `jq` | any | Used to resolve the latest ACK chart version per service |

## Quick Start

Everything runs from the `tests/` directory:

```bash
cd tests

# 1. Create the cluster and install kro, ACK CRDs, kropath CRDs and all RGDs
make setup

# 2. Verify the cluster is healthy (smoke suite)
make chainsaw-e2e

# 3. Run one service's suite
make test-iam

# 4. Or run every suite
make test

# 5. Tear the cluster down
make teardown
```

The cluster name defaults to `kropath-aws-test` and can be overridden:

```bash
make setup CLUSTER_NAME=my-cluster
make teardown CLUSTER_NAME=my-cluster
```

## What `make setup` Does

`make setup` runs `tests/setup.sh` and then creates `tests/test-results/`. Both `setup.sh` and
`teardown.sh` read the cluster name from the **`CLUSTER_NAME` environment variable**, not from
their positional argument — `make setup CLUSTER_NAME=…` works because make exports command-line
variables, but `./setup.sh my-cluster` does not.

`tests/setup.sh` performs the following steps in order:

1. **Creates the Kind cluster** (`$CLUSTER_NAME`, default `kropath-aws-test`) from
   `tests/fixtures/kind-config.yaml`, skipping creation if the cluster already exists, then
   switches the kubectl context to `kind-$CLUSTER_NAME`.
2. **Creates the `kro-system` namespace** (skipped if it exists).
3. **Installs kro v0.9.2** from the pinned release manifest
   (`kro-core-install-manifests.yaml`), applies `tests/fixtures/rbac/kro-controller.yaml`,
   and waits for the `kro` deployment rollout.
4. **Tunes the kro dynamic-controller rate limiter** for test-suite churn, by setting these
   env vars on `deployment/kro` and waiting for a second rollout:

   | Variable | Value |
   |---|---|
   | `KRO_DYNAMIC_CONTROLLER_RATE_LIMITER_MIN_DELAY` | `50ms` |
   | `KRO_DYNAMIC_CONTROLLER_RATE_LIMITER_MAX_DELAY` | `5s` |
   | `KRO_DYNAMIC_CONTROLLER_RATE_LIMITER_RATE_LIMIT` | `50` |
   | `KRO_DYNAMIC_CONTROLLER_RATE_LIMITER_BURST_LIMIT` | `200` |
   | `KRO_DYNAMIC_CONTROLLER_CONCURRENT_RECONCILES` | `2` |

   kro's production defaults (200ms–1000s backoff) make chainsaw asserts time out under the
   create/patch churn of a full run. See the comment block in `tests/setup.sh` for the full
   rationale, including why concurrency is only raised to 2.
5. **Installs ACK CRDs** by sourcing `hack/install-provider-crds.sh` (see below).
6. **Installs kropath governance CRDs** from `crds/*.yaml` plus
   `crds/policy/policydocument.yaml`, then waits for **all** CRDs to reach
   `condition=Established` (kro validates `externalRef` GVKs against the live API server, and
   an RGD applied before registration completes stays permanently `Inactive`).
7. **Applies all non-lambda RGDs** from `rgds/`.
8. **Applies the lambda RGDs in three dependency-ordered waves**, waiting for `condition=Ready`
   between waves, because lambda RGDs reference each other's kro-generated kinds via
   `externalRef`:
   - wave 1: `lambdacodesigningconfig`, `lambdalayerversion`
   - wave 2: `lambdafunction`
   - wave 3: `lambdaalias`, `lambdaeventsourcemapping`, `lambdafunctionurlconfig`, `lambdaversion`
9. **Waits for every RGD to reach `condition=Ready`** (300s). On failure it prints a real
   diagnosis — `kubectl wait --all` shares one deadline across RGDs in name order, so its
   "timed out" list is "first broken RGD + everything alphabetically after it", not the set of
   broken RGDs. Trust the explicit `--- <rgd> ---` condition dump the script prints instead.

## Cluster Configuration

The cluster used by `make setup` and by CI is defined in `tests/fixtures/kind-config.yaml`:

- **Topology**: a single `control-plane` node (no workers, no port mappings)
- **Name**: supplied on the command line by `setup.sh` (`--name "$CLUSTER_NAME"`), which
  overrides the `name:` field in the config file
- **Context**: `kind-$CLUSTER_NAME`, e.g. `kind-kropath-aws-test`

To create or delete the cluster manually:

```bash
kind create cluster --name kropath-aws-test --config tests/fixtures/kind-config.yaml
kind delete cluster --name kropath-aws-test
```

## Provider CRD Installation

`hack/install-provider-crds.sh` installs CRDs from cloud provider controller projects. Only ACK
CRDs are installed by default since kropath-aws targets AWS. Charts are pulled with `helm pull`
and only the `crds/` directory is applied — no controller pods, no cloud credentials.

### ACK (AWS Controllers for Kubernetes) — default

Default `ACK_SERVICES`:

```
s3 iam kms ec2 dynamodb rds sns sqs secretsmanager eks ecr cloudwatch
elbv2 eventbridge autoscaling cloudfront ecs apigatewayv2 lambda
```

This covers every `*.services.k8s.aws` group referenced by `rgds/`. When adding a resource
family that uses a new ACK service, add its service name here or the RGD will fail to compile.

The chart version is **resolved per service at runtime** from that controller's latest GitHub
release (`api.github.com/repos/aws-controllers-k8s/<svc>-controller/releases/latest`) — this is
why `curl` and `jq` are prerequisites. A service whose version can't be resolved, or whose chart
can't be pulled, logs a `WARNING` and is skipped rather than failing the run.

```bash
# Install a subset of ACK services (env vars pass through `make setup`)
ACK_SERVICES="s3 iam" ./hack/install-provider-crds.sh

# Skip ACK CRDs entirely
SKIP_ACK=true ./hack/install-provider-crds.sh
```

> The script's header comment mentions an `ACK_CHART_VERSION` variable; it is **not** honored —
> versions always come from the GitHub API lookup above.

### KCC (Config Connector / GCP) — optional

Not installed by default (`SKIP_KCC=true`). To enable for cross-provider testing:

```bash
SKIP_KCC=false ./hack/install-provider-crds.sh
```

### ASO (Azure Service Operator) — optional

Not installed by default (`SKIP_ASO=true`). To enable for cross-provider testing:

```bash
SKIP_ASO=false ASO_VERSION=v2.9.0 ./hack/install-provider-crds.sh
```

## Running Chainsaw Tests

Chainsaw is configured via `.chainsaw.yaml` at the repo root; `tests/Makefile` passes it
explicitly (`--config ../.chainsaw.yaml`) along with `--parallel 4` and JUnit reporting into
`tests/test-results/`.

```bash
cd tests

make test                  # every suite (chainsaw test .)
make chainsaw-e2e          # smoke suite only (tests/chainsaw/)
make test-<service>        # one service suite, e.g. make test-kms
```

To run a suite directly without make — note the config path is relative to your cwd:

```bash
chainsaw test tests/kms/ --config .chainsaw.yaml            # from repo root
chainsaw test kms/ --config ../.chainsaw.yaml               # from tests/

# Override the cluster context
chainsaw test tests/kms/ --config .chainsaw.yaml --kube-context kind-kropath-aws-test
```

### Test Layout

```
tests/
├── chainsaw/smoke/        # verifies kro + ACK CRDs are installed (make chainsaw-e2e)
├── fixtures/              # kind config, kro RBAC, pinned CRDs, shared config CRs
├── test-results/          # JUnit XML output
└── <service>/<kind>/      # one directory per resource kind, each with chainsaw-test.yaml
```

There are 24 per-service suites, each with a matching `test-<service>` make target:

```
apigateway  apigatewayv2  autoscaling  cloudfront  cloudwatchlogs  dynamodb
ec2  ecr  ecs  efs  eks  elasticache  elb  eventbridge  iam  kms
lambda  msk  policy  rds  s3  secretsmanager  sns  sqs
```

Adding a new resource family means adding `tests/<service>/<kind>/`, the `rgds/`/`crds/` files
prefixed with the service name, and a `test-<service>:` target in `tests/Makefile` — CI's test
selection then picks it up automatically (see below).

For the mandatory suite structure (unique resource name per step, `spec.skipDelete: true`, no
inter-step deletes of ACK children), see `docs/frequent-rgd-errors.md`
§"CANONICAL: Unique-Name-Per-Step + `skipDelete`" and the reference suite
`tests/dynamodb/dynamodbtable/chainsaw-test.yaml`.

### Timeouts and Defaults

From `.chainsaw.yaml`:

| Setting | Value |
|---------|-------|
| `timeouts.apply` | 30s |
| `timeouts.assert` | 5m |
| `timeouts.cleanup` | 3m |
| `timeouts.delete` | 3m |
| `timeouts.error` | 30s |
| `timeouts.exec` | 5m |
| `skipDelete` | `true` (global default) |
| `namespace` | `kropath-aws-test` |
| `parallel` | 4 |
| `failFast` | `false` |

`skipDelete: true` is a global default because the cluster has kro but **no ACK controllers**:
ACK finalizers are never removed, so any delete of an ACK child hangs. The kind cluster is
discarded after the run instead. Individual suites declare their own `spec.namespace`
(e.g. `iamrole`), which is what `{namespace}-{name}` naming templates expand against — the
`kropath-aws-test` default above applies only to suites that don't set one.

## CI

`.github/workflows/rgd-tests.yaml` runs the same targets:

1. `helm/kind-action` creates the `kropath-aws-test` cluster from `tests/fixtures/kind-config.yaml`.
2. `cd tests && make setup` (the cluster already exists, so `setup.sh` skips creation).
3. `cd tests && make chainsaw-e2e` — smoke suite, always.
4. `tests/select-tests.sh` diffs `$BASE_SHA..$HEAD_SHA` and prints the `make` targets needed to
   cover the changed files; `cd tests && make <targets>` runs them.
5. JUnit results are published to the PR and uploaded as artifacts.

`select-tests.sh` maps a changed `rgds/`/`crds/` file to a service by longest-prefix match
against the `test-<service>:` targets in `tests/Makefile` (`dynamodbtable` → `dynamodb`). It
falls back to the **full** `test` target whenever a shared file changes (`tests/setup.sh`,
`tests/Makefile`, `tests/fixtures/`, `.chainsaw.yaml`, `hack/`, `crds/kropathconfig.yaml`,
`crds/policy/`, `.github/workflows/`) or a path can't be mapped unambiguously.

To reproduce CI's selection locally:

```bash
BASE_SHA=$(git merge-base origin/main HEAD) HEAD_SHA=HEAD tests/select-tests.sh
```

## `hack/` Contents

| Path | Used by |
|---|---|
| `hack/install-provider-crds.sh` | sourced by `tests/setup.sh` (step 5) |
| `hack/check-crd-classification.sh` | root `Makefile` → `make lint-crds`, and the `crd-classification-check` workflow |
| `hack/kro/` | vendored kro manifests, currently unreferenced (`tests/setup.sh` fetches the v0.9.2 release manifest from GitHub instead) |

> `hack/setup-local.sh` and `hack/kind-config.yaml` were removed — they predated the lambda
> dependency waves, the CRD `Established` wait, and the rate-limiter tuning in `tests/setup.sh`,
> and produced a cluster where the lambda RGDs never reached `Active`. Use `make setup`.

## Troubleshooting

### `kind: command not found`

Install Kind: `brew install kind` or see https://kind.sigs.k8s.io/docs/user/quick-start/#installation.

### `make setup` fails at "Waiting for all RGDs to become Ready"

Ignore the `kubectl wait` "timed out" list — it shares one deadline in name order. Read the
`--- <rgd> ---` condition dump the script prints after it, then iterate:

```bash
# kro re-validates only on re-CREATE — `kubectl apply` over an unchanged RGD does nothing
kubectl delete rgd <name> && kubectl apply -f rgds/<name>.yaml
kubectl get rgd <name> -o jsonpath='{.status.conditions[?(@.type=="GraphAccepted")].message}'
```

Errors surface one layer at a time; budget several rounds. See `docs/frequent-rgd-errors.md`
§7 and §8.

### ACK CRDs missing for a service

`install-provider-crds.sh` logs a `WARNING` and continues when a chart version can't be
resolved or the chart can't be pulled — an unauthenticated GitHub API rate limit is the usual
cause. Check the setup output for warnings, then re-run, or export `GITHUB_TOKEN` and use a
pinned copy from `tests/fixtures/crds/`.

### Chainsaw assertion timeout

1. Check kro controller logs: `kubectl logs -n kro-system deploy/kro -f`
2. Describe the failing resource in the suite's own namespace:
   `kubectl describe <kind> <name> -n <suite-namespace>`
3. Confirm the relevant RGD is `Active`: `kubectl get rgd --no-headers | awk '$5!="True"'`

### Cluster already exists

`setup.sh` skips cluster creation if `$CLUSTER_NAME` already exists — and will therefore reuse
stale state. To start fresh:

```bash
cd tests && make teardown && make setup
```
