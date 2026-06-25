@docs/STANDARDS.md

## This Repo

**kropath-aws** — ACK-based CRDs and kro RGDs for AWS resources.

- `crds/` contains governance CRDs only: `AWSKropathConfig` (org/namespace-wide) and `AWS<ServiceName>Config` (per-type ResourceConfigs); resource-kind definitions (e.g. `AWSIAMRole`, `AWSS3Bucket`) belong in `rgds/` as kro RGDs, not in `crds/`
- kro RGD kinds: one RGD per resource family under `rgds/`
- Deletion policy annotation: `services.k8s.aws/deletion-policy` (`retain` | `delete`)
- Resource families use ACK CRs (e.g. `s3.services.k8s.aws/Bucket`, `iam.services.k8s.aws/Role`)
- All RGDs use the single `effCfg` pattern — one `externalRef` config lookup per RGD
- `effectiveName` used as cloud resource name; `predictedArn` built from `effectiveName`
