# kropath-aws

[![RGD Tests](https://github.com/kropath/kropath-aws/actions/workflows/rgd-tests.yaml/badge.svg?branch=main)](https://github.com/kropath/kropath-aws/actions/workflows/rgd-tests.yaml)
[![CRD Classification Check](https://github.com/kropath/kropath-aws/actions/workflows/crd-classification-check.yml/badge.svg?branch=main)](https://github.com/kropath/kropath-aws/actions/workflows/crd-classification-check.yml)
[![License](https://img.shields.io/badge/license-Apache--2.0-blue.svg)](LICENSE)

kropath-aws is the governance and production-knowledge layer for Kubernetes-native AWS cloud
resource provisioning. It ships [kro](https://github.com/kubernetes-sigs/kro)
ResourceGraphDefinitions (RGDs) that wrap
[AWS Controllers for Kubernetes (ACK)](https://aws-controllers-k8s.github.io/community/) resources,
plus governance CRDs that let a platform team declare mandatory settings, defaults, naming
conventions, and tagging policy once and have every resource inherit them.

> ### ⚠️ EXPERIMENTAL
>
> **This project is under active development and is not production-ready.** APIs, schemas, and
> resource kinds may change without notice, and there are no compatibility guarantees between
> commits.
>
> CI validates RGDs against a local [kind](https://kind.sigs.k8s.io/) cluster running kro with
> ACK **CRD schemas only** — no ACK controllers and no AWS credentials. **Integration testing
> against a live AWS environment is currently in progress and runs outside CI.** Cloud-side
> behaviour (real resource creation, ARNs, drift, deletion semantics) is therefore not yet
> covered by the automated suite in this repository.

---

## Why

ACK gives you a Kubernetes CR per AWS resource, but it has no opinion about *governance*: every
team re-invents naming, tagging, encryption defaults, and deletion policy in their own manifests,
and nothing stops an application team from overriding a security-mandated setting.

kropath-aws adds a governance layer on top:

- **Platform teams** declare policy in `KropathConfig` (org/namespace-wide) and per-service
  `<ServiceName>Config` CRs — mandatory values, defaults, naming templates, and synced
  labels/annotations/tags.
- **Application teams** create a simple kropath resource CR (`S3Bucket`, `IAMRole`,
  `LambdaFunction`, …) with only the fields they care about.
- **kro** merges the two into the underlying ACK CR, resolving the effective configuration with a
  strict precedence: **mandatory > user spec > defaults**.

## How it works

```
        ┌──────────────────────┐        ┌───────────────────────┐
        │   KropathConfig      │        │  <Service>Config      │
        │  (org / namespace)   │        │  (per resource type)  │
        └──────────┬───────────┘        └───────────┬───────────┘
                   │      mandatory / defaults / aws│
                   └───────────────┬────────────────┘
                                   │  status.effectiveConfig
                                   ▼
   ┌─────────────┐        ┌──────────────────┐        ┌──────────────────┐
   │  S3Bucket   │───────▶│  kro RGD         │───────▶│  ACK Bucket CR   │──▶ AWS
   │  (user CR)  │        │  (rgds/*.yaml)   │        │  (s3.services…)  │
   └─────────────┘        └──────────────────┘        └──────────────────┘
```

Key conventions:

| Concept | Rule |
|---|---|
| Config lookup | One `externalRef` per RGD (`effCfg`), matched by `selector.matchLabels` on `aws.kropath.run/resource-name` |
| Precedence | `mandatory` (wins) → user `spec` → `defaults` |
| Naming | `namingTemplate` (default `{namespace}-{name}`) produces `effectiveName`, used as the cloud resource name |
| ARN | `status.predictedArn` is computed from `effectiveName`; `status.arn` is only populated by a live AWS reconciliation |
| Deletion | `metadata.annotations["services.k8s.aws/deletion-policy"]` — `retain` or `delete` |
| Label prefix | `aws.kropath.run/` for Kubernetes labels/annotations; cloud tags use plain keys |

Full engineering standards live in [`docs/STANDARDS.md`](docs/STANDARDS.md) (AWS deltas) and in
the canonical `kropath-core/docs/standards/engineering-standards.md`.

## Repository layout

| Path | Contents |
|---|---|
| `rgds/` | kro ResourceGraphDefinitions — one per AWS resource kind (46 kinds) |
| `crds/` | Governance CRDs only: `KropathConfig` plus 23 per-service `<Service>Config` CRDs |
| `crds/policy/` | `PolicyDocument` CRD for reusable IAM policy documents |
| `profiles/` | Ready-to-apply governance profiles — a `general-policy` baseline per service (22 services), plus stricter variants where they exist |
| `tests/` | 74 Chainsaw suites, a `Makefile` per-service target, and cluster setup/teardown |
| `hack/` | Local cluster bootstrap and provider-CRD installation scripts |
| `docs/` | Standards, the RGD error catalog, and dated troubleshooting logs |

## Implementation status

**46 resource RGDs** across 15 services, **24 governance CRDs**, and **74 Chainsaw test suites**.

### Services with resource RGDs

| Service | RGD kinds | Config CRD | Suites |
|---|---|---|---|
| API Gateway v2 | `ApiGatewayV2HttpApi`, `ApiGatewayV2WebSocketApi`, `ApiGatewayV2Stage`, `ApiGatewayV2DomainName`, `ApiGatewayV2ApiMapping`, `ApiGatewayV2VpcLink` | `APIGatewayV2Config` | 7 |
| Auto Scaling | `AutoScalingGroup` | `AutoScalingConfig` | 2 |
| CloudFront | `CloudFrontDistribution`, `CloudFrontCachePolicy`, `CloudFrontOriginRequestPolicy`, `CloudFrontResponseHeadersPolicy`, `CloudFrontOriginAccessControl`, `CloudFrontFunction` | `CloudFrontConfig` | 7 |
| DynamoDB | `DynamoDBTable` | `DynamoDBConfig` | 2 |
| ECS | `ECSCluster`, `ECSService`, `ECSTaskDefinition`, `ECSCapacityProvider` | `ECSConfig` | 5 |
| ELBv2 | `ELBLoadBalancer`, `ELBTargetGroup`, `ELBListener`, `ELBRule` | `ELBConfig` | 5 |
| EventBridge | `EventBridgeEventBus`, `EventBridgeRule`, `EventBridgeArchive`, `EventBridgeEndpoint` | `EventBridgeConfig` | 5 |
| IAM | `IAMRole`, `IAMPolicy`, `IAMUser`, `IAMGroup`, `IAMIdentityProvider` | `IAMConfig` | 9 |
| KMS | `KMSKey` | `KMSConfig` | 2 |
| Lambda | `LambdaFunction`, `LambdaAlias`, `LambdaVersion`, `LambdaLayerVersion`, `LambdaEventSourceMapping`, `LambdaFunctionURLConfig`, `LambdaCodeSigningConfig` | `LambdaConfig` | 8 |
| RDS | `RDSCluster`, `RDSInstance`, `RDSSubnetGroup` | `RDSConfig` | 4 |
| S3 | `S3Bucket` | `S3Config` | 2 |
| Secrets Manager | `SecretsManagerSecret` | `SecretsManagerConfig` | 2 |
| SNS | `SNSTopic` | `SNSConfig` | 2 |
| SQS | `SQSQueue` | `SQSConfig` | 2 |

### Governance config only (no resource RGDs yet)

These services ship a `<Service>Config` CRD, a `general-policy` profile, and schema-level tests,
but no resource RGDs have been implemented yet:

`APIGatewayConfig` (v1) · `CloudWatchLogsConfig` · `EC2Config` · `ECRConfig` · `EFSConfig` ·
`EKSConfig` · `ElastiCacheConfig` · `MSKConfig`

### Known gaps

Acceptance criteria that are blocked on upstream ACK controller support are tracked in
[`docs/deferred-capabilities.md`](docs/deferred-capabilities.md) — currently the IAM `AccessKey`
CR and IAM user/group membership, neither of which the installed ACK IAM controller exposes.

## Getting started

### Prerequisites

| Tool | Minimum | Notes |
|---|---|---|
| [Docker](https://docs.docker.com/get-docker/) | 24+ | required by kind |
| [kind](https://kind.sigs.k8s.io/) | v0.22+ | local cluster |
| [kubectl](https://kubernetes.io/docs/tasks/tools/) | v1.29+ | |
| [helm](https://helm.sh/) | v3.13+ | installs ACK CRD charts |
| [chainsaw](https://kyverno.github.io/chainsaw/latest/install/) | v0.2+ | test runner (CI pins v0.2.15) |

No AWS account or credentials are required for the local and CI test flows — only ACK CRD
*schemas* are installed, not the controllers.

### Bring up a local cluster

```bash
cd tests
make setup        # creates the kind cluster, installs kro v0.9.2 + ACK CRDs + kropath CRDs/RGDs
```

Then apply a governance profile and a resource:

```bash
kubectl apply -f profiles/s3/general-policy.yaml
kubectl apply -f crds/examples/awsiamconfig/
```

See [`docs/testing-local.md`](docs/testing-local.md) for the full walkthrough and the
`hack/setup-local.sh` flags.

### Run the tests

```bash
cd tests
make test            # every suite
make test-iam        # a single service — one target per service
make chainsaw-e2e    # smoke suite only
make teardown        # delete the kind cluster
```

Every suite follows the canonical **unique-resource-name-per-step + `spec.skipDelete: true`**
pattern (`skipDelete` is the global default in `.chainsaw.yaml`). The test cluster runs kro but
no ACK controllers, so ACK finalizers are never removed and any delete of an ACK child would
hang — suites therefore delete nothing between steps and the ephemeral cluster is discarded
after the run.

### Lint governance CRDs

```bash
make lint-crds       # fails if a resource-kind CRD is added under crds/
```

`crds/` is reserved for governance CRDs. Resource kinds belong in `rgds/` as kro RGDs.

## CI

| Workflow | Trigger | What it does |
|---|---|---|
| [RGD Tests](.github/workflows/rgd-tests.yaml) | push to `main`, PRs touching `rgds/`, `crds/`, `tests/`, `.github/workflows/` | Spins up kind, installs kro + ACK CRD schemas, runs the smoke suite, then runs only the service suites affected by the diff (`tests/select-tests.sh`). Publishes JUnit results to the PR. |
| [CRD Classification Check](.github/workflows/crd-classification-check.yml) | PRs touching `crds/` | Runs `make lint-crds` to reject resource-kind CRDs added under `crds/`. |

## Documentation

| Doc | Purpose |
|---|---|
| [`docs/frequent-rgd-errors.md`](docs/frequent-rgd-errors.md) | The catalog of every kro/CEL/ACK trap found so far — **read this before writing any CEL** |
| [`docs/STANDARDS.md`](docs/STANDARDS.md) | AWS-specific deltas from the canonical engineering standards |
| [`docs/testing-local.md`](docs/testing-local.md) | Local kind setup walkthrough |
| [`docs/deferred-capabilities.md`](docs/deferred-capabilities.md) | Acceptance criteria blocked on upstream providers |
| [`docs/troubleshooting-logs/`](docs/troubleshooting-logs/) | Dated per-incident fix logs |
| [`CLAUDE.md`](CLAUDE.md) | Repo conventions and the debug loop, for both humans and agents |

## Contributing

Bug fixes and small changes are welcome as pull requests; larger features and architectural
changes should start as a GitHub Issue. See [CONTRIBUTION.md](CONTRIBUTION.md).

## License

Apache License 2.0 — see [LICENSE](LICENSE).
