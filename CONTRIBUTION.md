# Contributing to kropath-aws

Thanks for your interest in kropath-aws. This project is **experimental** and moving quickly —
please read the status notice in the [README](README.md) before you build anything on top of it.

## How to Contribute

**Bugs & small fixes → Open a PR!**

Broken CEL expressions, wrong ACK field names or types, flaky or incorrect test asserts, typos,
doc corrections, and single-kind fixes don't need any prior discussion. Fork, fix, and open a
pull request directly.

**New features / architecture → Start a GitHub Issue**

Feature requests are very welcome — open an
[issue](https://github.com/kropath/kropath-aws/issues). Please note that **we are not accepting
pull requests for features yet.** Accepted requests are added to the development roadmap and
implemented by the maintainers; the issue is where the design gets agreed and where you can
follow progress.

Open an issue rather than a PR when your change would:

- add a new resource RGD or a new service family
- add or reshape a governance `<Service>Config` CRD, or change `KropathConfig`
- change the config-resolution model (precedence, `externalRef` lookup, naming templates)
- change conventions that apply repo-wide (label/annotation prefixes, deletion policy, status
  field contracts)
- alter the test harness, the CI workflows, or the canonical Chainsaw pattern

Describe the problem, the proposed API surface, and which ACK CRDs back it. Agreeing on the shape
first saves a rewrite — an RGD's schema is a published API, and reversing one is expensive.

## Before You Start

Two documents will save you hours. Read them first:

1. **[`docs/frequent-rgd-errors.md`](docs/frequent-rgd-errors.md)** — the catalog of every
   kro/CEL/ACK trap already discovered in this repo. Almost every symptom you hit is already
   written down there, with the fix.
2. **The most recent file in [`docs/troubleshooting-logs/`](docs/troubleshooting-logs/)** — shows
   what has recently been fixed and which patterns are current.

[`CLAUDE.md`](CLAUDE.md) carries the full working conventions for this repo (it is written for
both humans and coding agents) and [`docs/STANDARDS.md`](docs/STANDARDS.md) covers the AWS-specific
engineering standards.

## Development Setup

No AWS account or credentials are needed — the local flow installs ACK **CRD schemas** only, not
the controllers.

```bash
# Prerequisites: docker, kind, kubectl, helm, chainsaw
cd tests
make setup        # kind cluster + kro v0.9.2 + ACK CRDs + kropath CRDs and RGDs
make test-iam     # run one service suite
make teardown     # tear the cluster down
```

Full walkthrough: [`docs/testing-local.md`](docs/testing-local.md).

## Working on an RGD

An RGD edit is **not verified until the RGD reaches `Active` in a real cluster**. Reasoning about
CEL types on paper is not verification.

```bash
kubectl delete rgd <kind>.kropath.run          # kro only re-validates on re-CREATE
kubectl apply -f rgds/<kind>.yaml
kubectl get rgd <kind>.kropath.run             # must be Active
kubectl delete crd <plural>.kropath.run        # after ANY schema change, so kro re-derives it
kubectl apply -f tests/<service>/<kind>/<NN>-<case>.yaml
kubectl describe <kind> <name>                 # CEL errors surface here
```

Expect errors to surface **one layer at a time** — budget several rounds. `kubectl apply` over an
unchanged-generation RGD does not re-run graph validation, so always delete and re-create.

Verify every ACK field **name and type** against the live CRD, never against intuition:

```bash
kubectl get crd <plural>.<service>.services.k8s.aws -o json \
  | jq '.spec.versions[0].schema.openAPIV3Schema.properties.spec.properties | map_values(.type)'
```

## Writing Tests

Every new feature needs test coverage. Suites live in `tests/<service>/<kind>/` and run with
`cd tests && make test-<service>`.

Non-negotiable rules (all learned from real CI failures):

- **Canonical pattern:** a **unique resource name per step** and `spec.skipDelete: true`
  (the global default in `.chainsaw.yaml`). Delete **nothing** between steps for ACK-child
  resources — the test cluster has no ACK controllers, so ACK finalizers are never removed and
  any delete hangs. `tests/dynamodb/dynamodbtable/chainsaw-test.yaml` is the reference suite.
- **Fixed namespace** in `spec.namespace` (never `default`), so `{namespace}-{name}` naming
  templates expand to predictable values.
- **`effectiveConfig` must always include `mandatory`, `defaults`, and `aws`** — omitting a tier
  causes a `no such key` CEL error at runtime.
- **Never assert a CEL-generated list positionally.** Map-to-list transforms have unstable
  iteration order, and chainsaw has no working order-independent list construct — use a
  `- script:` step with `kubectl ... -o json | jq` instead.
- **Distinguish `metadata.name` from `spec.name`** — child resources get
  `metadata.name: ${schema.metadata.name}` (the K8s name) and `spec.name: ${effectiveName}`
  (the cloud name, controlled by naming templates).

Log the fix for each non-obvious failure in `docs/troubleshooting-logs/<YYYY-MM-DD>-<slug>.md`
so the next contributor doesn't rediscover it.

## Governance CRDs

`crds/` is for **governance CRDs only** — `KropathConfig` and per-type `<Service>Config`. Resource
kinds belong in `rgds/` as kro RGDs. `make lint-crds` enforces this and runs in CI on every PR
touching `crds/`.

`x-kubernetes-validations` cannot be preserved by kro — it regenerates CRDs from the RGD schema on
every apply. Use the in-graph ConfigMap advisory pattern instead (see `rgds/iampolicy.yaml` and
`rgds/iamrole.yaml`).

## Pull Requests

Before opening a PR:

1. Run the full suite for every affected service (`cd tests && make test-<service>`) and make sure
   it passes — zero failures, zero skips.
2. Run `make lint-crds` if you touched `crds/`.
3. Keep the change scoped to one resource family or one concern where possible.

In the PR description, state what changed, which suites you ran, and the result. CI runs the
smoke suite plus the service suites affected by your diff; both workflows must be green before
merge.

### Commit messages

```
<type>: <description>
```

Types: `feat`, `fix`, `refactor`, `docs`, `test`, `chore`, `perf`, `ci`. Prefix with the tracking
ticket when there is one, matching the existing history:

```
[KRO-633]: feat: add ApiGatewayV2ApiMapping kro RGD
```

## Code of Conduct

Be respectful and constructive. Assume good faith, keep reviews about the code, and prefer
questions over assertions when something looks wrong.

## License

By contributing, you agree that your contributions will be licensed under the
[Apache License 2.0](LICENSE).
