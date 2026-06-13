@docs/STANDARDS.md

## This Repo

**kropath-aws** — ACK-based CRDs and kro RGDs for AWS resources.

- CRD kinds: `AWSKropathConfig`, `AWS<ServiceName>Config` (ResourceConfigs), `AWS<ServiceName>` (resource CRDs)
- kro RGD kinds: one RGD per resource family under `rgds/`
- Deletion policy annotation: `services.k8s.aws/deletion-policy` (`retain` | `delete`)
- Resource families use ACK CRs (e.g. `s3.services.k8s.aws/Bucket`, `iam.services.k8s.aws/Role`)
- All RGDs use the single `effCfg` pattern — one `resources.get()` call per RGD
- `effectiveName` used as cloud resource name; `predictedArn` built from `effectiveName`
