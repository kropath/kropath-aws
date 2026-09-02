## KRO-821 Implementer Entry

Starting implementation of `[kropath-aws] CRD: SageMakerConfig schema additions`.

Branch: `feat/KRO-821-sagemakerconfig-crd`

### AC-to-Scenario Table

| # | AC | Chainsaw Scenario | Type | Status |
|---|---|---|---|---|
| AC-1 | SageMakerConfig CR with `mandatory.kmsKeyId="arn:aws:kms:…/key1"` is admitted | `happy-path: config-admission` | Happy path | Planned |
| AC-2 | SageMakerConfig with `mandatory.instanceType` AND `defaults.instanceType` both set → rejected | `negative: dual-tier-scalar-rejection` | Negative | Planned |
| AC-3 | SageMakerConfig with `mandatory.enableNetworkIsolation=true` AND `defaults.enableNetworkIsolation=true` → rejected | `negative: dual-tier-boolean-rejection` | Negative | Planned |
| AC-4 | SageMakerConfig with `mandatory.tags={"env":"prod"}` AND `defaults.tags={"team":"ml"}` → accepted (maps merge) | `happy-path: map-both-tiers` | Happy path | Planned |
| AC-5 | SageMakerConfig with only `defaults` fields set → accepted | `happy-path: defaults-only-profile` | Happy path | Planned |
| AC-6 | `general-policy` CR found via `labelSelector` with `aws.kropath.run/resource-name: general-policy` | `happy-path: label-selector-lookup` | Happy path | Planned |
| AC-7 | KropathConfig `mandatory.sagemaker.kmsKeyId` cascades into `status.effectiveConfig.mandatory.kmsKeyId` | `happy-path: kropathconfig-cascade-precedence` | Happy path | Planned |
| AC-8 | SageMakerConfig with only `mandatory.rootAccess="Disabled"` → accepted (single tier) | `happy-path: single-tier-string-field` | Happy path | Planned |
| AC-9 | SageMakerConfig with `mandatory.namingTemplate` AND `defaults.namingTemplate` both set → rejected | `negative: dual-tier-naming-rejection` | Negative | Planned |
| AC-10 | `general-policy` effectiveConfig has `defaults.namingTemplate="{namespace}-{name}"`, `volumeSizeInGB=5`, `rootAccess="Enabled"`, `directInternetAccess="Enabled"` | `happy-path: general-policy-baseline` | Happy path | Planned |

Spec doc: https://github.com/kropath/kropath-core/blob/main/docs/specs/aws/aws-sagemaker-01-sagemakerconfig.md
