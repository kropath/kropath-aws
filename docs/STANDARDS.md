# kropath-aws Provider Standards

Shared engineering standards (API group, kind naming, label/annotation conventions, CRD schema
rules, naming, wiring) are documented in the public baseline:
[`Engineering Standards`](https://github.com/kropath/kropath-docs/blob/main/docs/engineering-standards.md).
This file contains **AWS-specific deltas only**.

---

## ACK `externalRef` Example

```yaml
resources:
- id: rsrcCfg
  externalRef:
    apiVersion: aws.kropath.run/v1alpha1
    kind: S3Config
    selector:
      matchLabels:
        aws.kropath.run/resource-name: ${schema.?spec.?configRef.orValue("general")}

- id: ackResource
  template:
    spec:
      tags: ${rsrcCfg[0].status.effectiveConfig.mandatory.tags + schema.spec.tags + rsrcCfg[0].status.effectiveConfig.defaults.tags}
```

Access pattern: `rsrcCfg[0].status.effectiveConfig.mandatory.*`, `rsrcCfg[0].status.effectiveConfig.defaults.*`,
`rsrcCfg[0].status.effectiveConfig.aws.*`. Never `rsrcCfg.spec.*`.

---

## AWS Label / Annotation Key Prefix

`aws.kropath.run/` — e.g. `aws.kropath.run/resource-name`.

---

## AWS Deletion Policy

| Field | Retain value | Delete value |
|---|---|---|
| `metadata.annotations["services.k8s.aws/deletion-policy"]` | `retain` | `delete` |
