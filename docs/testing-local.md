# Local Testing with Kind — kropath-aws

This guide walks through setting up a local Kubernetes cluster using [Kind](https://kind.sigs.k8s.io/) for developing and testing kropath-aws resources without an active AWS account or cloud cluster.

## Prerequisites

Install the following tools before running any setup scripts:

| Tool | Minimum Version | Install |
|------|-----------------|---------|
| [Docker](https://docs.docker.com/get-docker/) | 24+ | Required by Kind |
| [kind](https://kind.sigs.k8s.io/docs/user/quick-start/#installation) | v0.22+ | `brew install kind` |
| [kubectl](https://kubernetes.io/docs/tasks/tools/) | v1.29+ | `brew install kubectl` |
| [helm](https://helm.sh/docs/intro/install/) | v3.13+ | `brew install helm` |
| [chainsaw](https://kyverno.github.io/chainsaw/latest/install/) | v0.2+ | `brew install kyverno/tap/chainsaw` |

## Quick Start

```bash
# 1. Create the cluster and install all dependencies
./hack/setup-local.sh

# 2. Verify the cluster is healthy
chainsaw test ./tests/chainsaw/smoke/

# 3. Run all E2E tests
chainsaw test ./tests/chainsaw/
```

## What `setup-local.sh` Does

`hack/setup-local.sh` performs the following steps in order:

1. **Creates the Kind cluster** `kropath-aws` using `hack/kind-config.yaml`.
2. **Installs [kro](https://github.com/awslabs/kro)** via Helm from the official OCI registry.
3. **Applies kropath CRDs** from `crds/` (if the directory exists).
4. **Installs provider CRDs** via `hack/install-provider-crds.sh`.

### Flags

| Flag | Effect |
|------|--------|
| `--skip-kro` | Skip kro installation (useful if kro is already installed). |
| `--skip-crds` | Skip provider CRD installation. |

```bash
# Example: re-run without reinstalling kro
./hack/setup-local.sh --skip-kro
```

## Cluster Configuration

The cluster is defined in `hack/kind-config.yaml`:

- **Name**: `kropath-aws`
- **Topology**: 1 control-plane node + 2 worker nodes
- **Context**: `kind-kropath-aws`
- **Port mappings**: `18080->80`, `18443->443` for ingress testing

To create or recreate the cluster manually:

```bash
kind create cluster --name kropath-aws --config hack/kind-config.yaml
```

To delete it:

```bash
kind delete cluster --name kropath-aws
```

## Provider CRD Installation

`hack/install-provider-crds.sh` installs CRDs from cloud provider controller projects. Only ACK CRDs are installed by default since kropath-aws targets AWS.

### ACK (AWS Controllers for Kubernetes) — default

Installs CRDs for: `s3`, `iam`, `ec2`, `eks`, `rds`, `elasticache`, `sqs`, `sns`.

```bash
# Install a subset of ACK services
ACK_SERVICES="s3 iam" ./hack/install-provider-crds.sh

# Pin a specific ACK chart version
ACK_VERSION="v1.0.1" ./hack/install-provider-crds.sh
```

### KCC (Config Connector / GCP) — optional

Not installed by default. To enable for cross-provider testing:

```bash
SKIP_KCC=false ./hack/install-provider-crds.sh
```

### ASO (Azure Service Operator) — optional

Not installed by default. To enable for cross-provider testing:

```bash
SKIP_ASO=false ASO_VERSION=v2.9.0 ./hack/install-provider-crds.sh
```

## Running Chainsaw Tests

Chainsaw is configured via `.chainsaw.yaml` at the repo root. Tests live under `tests/chainsaw/`.

```bash
# Run all tests
chainsaw test ./tests/chainsaw/

# Run a specific test directory
chainsaw test ./tests/chainsaw/smoke/

# Override the cluster context
chainsaw test ./tests/chainsaw/ --kube-context kind-kropath-aws

# Increase verbosity for debugging
chainsaw test ./tests/chainsaw/ --verbose
```

### Test Layout

```
tests/chainsaw/
└── smoke/
    └── chainsaw-test.yaml   # Verifies kro + ACK CRDs are installed
```

Add a new test by creating a directory under `tests/chainsaw/` containing a `chainsaw-test.yaml`. Chainsaw discovers tests recursively.

### Timeouts and Parallelism

Default timeouts (from `.chainsaw.yaml`):

| Operation | Timeout |
|-----------|---------|
| `apply` | 30s |
| `assert` | 5m |
| `delete` | 2m |
| `exec` | 5m |

Tests run with `parallel: 4` by default. Each test runs in the `kropath-aws-test` namespace.

## Troubleshooting

### `kind: command not found`

Install Kind: `brew install kind` or see https://kind.sigs.k8s.io/docs/user/quick-start/#installation.

### `helm show crds` fails for an ACK service

The ACK service may not have a published chart at the version specified. Set `ACK_VERSION` to a known published version, or set `SKIP_ACK=true` and install CRDs manually from the ACK GitHub releases.

### Chainsaw assertion timeout

1. Check kro controller logs: `kubectl logs -n kro deploy/kro -f`
2. Describe the failing resource: `kubectl describe <kind> <name> -n kropath-aws-test`
3. Increase `assert` timeout in `.chainsaw.yaml` for slow machines.

### Cluster already exists

`setup-local.sh` skips cluster creation if `kropath-aws` already exists. To start fresh:

```bash
kind delete cluster --name kropath-aws
./hack/setup-local.sh
```
