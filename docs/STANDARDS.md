# kropath Engineering Standards

**kropath** (kro + golden path) is a multi-cloud golden path platform.
**ADR-015** (`docs/adrs/015-consolidated-platform-decisions.md` in kropath-core) is the primary agent reference. ADR-001, ADR-010, and ADR-011 are also active alongside it. All other ADRs are archived in `docs/adrs/archive/` for narrative context.

## Repository Map

| Repo | Purpose |
|---|---|
| `kropath-core` | ADRs, design docs, SDD specs, shared standards (this repo) |
| `kropath-aws` | CRDs + kro RGDs for AWS (ACK-based) |
| `kropath-gcp` | CRDs + kro RGDs for GCP (KCC-based) |
| `kropath-azure` | CRDs + kro RGDs for Azure (ASO-based) |
| `kropath-controller` | Go controller — writes `status.effectiveConfig` (ADR-010) |
| `kropath-idp` | Internal developer platform — cross-provider UI |
| `kropath-docs` | Customer-facing documentation |

## Governance Config Hierarchy (ADR-010)

Three layers per provider. **kropath-controller** pre-merges all sources and writes
`status.effectiveConfig` onto the namespaced ResourceConfig CR — the single object RGDs read.

| Layer | Kind | Scope |
|---|---|---|
| 1 | `<Provider>KropathConfig` | Org-wide + namespace |
| 2 | `<Provider><Kind>Config` | ResourceConfig per-type (controller writes `status.effectiveConfig`) |
| 3 | Resource instance `spec` | Developer overrides |

## CEL Cascade Pattern (ADR-010)

**One `resources.get()` call per RGD.** Controller pre-merges; RGD reads `effCfg`:

```cel
variables._rsrcCfg: "${resources.get(metadata.namespace, \"AWSS3BucketConfig\", spec.configRef)}"
variables.effCfg:   "${variables._rsrcCfg.status.effectiveConfig}"

variables.mergedTags: >-
  ${variables.effCfg.mandatory.tags + spec.tags + variables.effCfg.defaults.tags}
```

Access pattern: `effCfg.mandatory.*`, `effCfg.defaults.*`, `effCfg.aws.*`.
Never `effCfg.spec.*`.

## Naming Convention

- `effectiveName` = cloud resource name (from naming template or `spec.nameOverride`).
- `status.resourceName` exposes `effectiveName`.
- `status.predictedArn` built from `effectiveName` — **never from `metadata.name`**.
- `spec.nameOverride: string | default=""` required in every RGD schema.

## Required Wiring (ADR-015 §6–7)

Every child K8s resource must receive:
- `metadata.labels` ← `mergedSyncedLabels` (prefixed `kropath.run/`)
- `metadata.labels` ← `app.kubernetes.io/managed-by: kro`
- `metadata.labels` ← `app.kubernetes.io/instance: ${metadata.name}`
- `metadata.annotations` ← `mergedSyncedAnnotations` (prefixed `kropath.run/`)
- Provider deletion policy annotation/field (see table)
- Cloud resource tags ← `allCloudMetadata`

**Deletion policy per provider:**

| Provider | Field | retain value | delete value |
|---|---|---|---|
| AWS (ACK) | `metadata.annotations["services.k8s.aws/deletion-policy"]` | `retain` | `delete` |
| GCP (KCC) | `metadata.annotations["cnrm.cloud.google.com/deletion-policy"]` | `abandon` | `delete` |
| Azure (ASO) | `spec.reconcilePolicy.objectDeletionPolicy` | `Detach` | `Delete` |

## CRD Rules (ADR-015 §4)

- Every field in **both** `spec.mandatory` and `spec.defaults` with safe zero-value defaults.
- `x-kubernetes-validations` to prevent both tiers being set simultaneously.
- `crds/` = CRDs only; `rgds/` = kro RGDs only.

## Metadata Key Convention

All agents use these standard keys in the Multica issue metadata bag. Keys outside this table require justification.

| Key | Type | Set by | Read by | Meaning |
|---|---|---|---|---|
| `pr_url` | string | Implementer | Reviewer | The PR to review |
| `pr_number` | number | Implementer | Reviewer | GitHub PR number |
| `blocked_by` | string | Issue creator | All agents | Prerequisite issue ID |
| `waiting_on` | string | Any | Any | Current blocker role or description |
| `completed_steps` | string (JSON array) | Any | Same agent on re-entry | Steps completed in a multi-step task |
| `design_status` | string | Design Reviewer | Spec Analyst | `draft` / `submitted` / `changes_requested` / `approved` |
| `specs_completed` | number | Spec Analyst | Design Reviewer, Human | Count of specs drafted |
| `specs_total` | number | Spec Analyst | Design Reviewer, Human | Total specs expected |

### Usage rules

- **Read on entry.** Run `multica issue metadata list <id> --output json` at the start of every run. Check `blocked_by` first — if set, fetch that issue and verify its status is `done` before proceeding.
- **Write sparingly.** Pin a value only when BOTH are true: (a) it is materially important to this issue's progress, AND (b) a future run on this same issue is likely to read it rather than re-derive it from comments or code.
- **Clean up stale keys on exit.** If a key you read on entry is now stale (e.g. `waiting_on` was set but the blocker has resolved), overwrite or delete it before exiting.
- **Never pin secrets, tokens, or API keys.** Never write logs, long quotes, or summaries — those belong in comments.

## Other Standards

- **Security First:** Default to secure; mandatory config overrides user input.
- **API group:** `kropath.run` (e.g. `apiVersion: kropath.run/v1alpha1`).
- **Licensing:** Apache 2.0 headers in every RGD and script.
- **CEL:** Use `${}` for all dynamic values.
