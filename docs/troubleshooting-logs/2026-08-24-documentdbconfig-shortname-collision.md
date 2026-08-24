# 2026-08-24: DocumentDB CRD short name `ddbcfg` collided with DynamoDB — 14 CRDs never established

> **Point-in-time note:** This log records what was observed and verified on 2026-08-24 for PR #140
> (KRO-781). Claims are based on local reproduction and CI log analysis. Treat as field notes, not
> canonical truth — verify mechanically before acting on them.

**Trigger:** CI setup (`tests/setup.sh`) timed out on commit `ea14a3a`. `kubectl wait` reported 14
CRDs as "timed out", starting with `dynamodbconfigs.aws.kropath.run`.

**Scope:** `crds/documentdbconfig.yaml` (new file, KRO-781). No RGD or controller changes.

## Root cause

`crds/documentdbconfig.yaml` defined `shortNames: [ddbcfg]`. The existing
`crds/dynamodbconfig.yaml` also defines `shortNames: [ddbcfg]`. Both short names are identical,
causing a `NamesAccepted` conflict.

On a fresh cluster, `kubectl apply -f crds/*.yaml` applies CRDs in alphabetical (glob) order.
`documentdbconfig.yaml` (`doc…`) sorts before `dynamodbconfig.yaml` (`dyn…`), so DocumentDB claims
`ddbcfg` first. DynamoDB then fails with:

```
NamesAccepted=False: "ddbcfg" is already in use
Established=False: not all names are accepted
```

`dynamodbconfigs` never reaches `Established=True`. The `kubectl wait` in `setup.sh` (which
processes CRDs sequentially with a shared 120s deadline) blocks on `dynamodbconfigs`. When the
deadline expires, `dynamodbconfigs` and the 13 alphabetically-subsequent CRDs are all reported as
"timed out" — even though most of those 13 would have established quickly once `dynamodbconfigs`
was skipped.

## Confirmed locally

```bash
kubectl delete crd documentdbconfigs.aws.kropath.run dynamodbconfigs.aws.kropath.run
kubectl apply -f crds/documentdbconfig.yaml crds/dynamodbconfig.yaml
kubectl get crd dynamodbconfigs.aws.kropath.run -o json | jq '.status'
# NamesAccepted=False, message: '"ddbcfg" is already in use'
```

After fix (rename DocumentDB short name to `docdbcfg`):
```bash
kubectl delete crd documentdbconfigs.aws.kropath.run dynamodbconfigs.aws.kropath.run
kubectl apply -f crds/documentdbconfig.yaml crds/dynamodbconfig.yaml
kubectl wait crd/documentdbconfigs.aws.kropath.run crd/dynamodbconfigs.aws.kropath.run \
  --for=condition=Established --timeout=30s
# Both: condition met (<1s)
```

## Fix

Changed `crds/documentdbconfig.yaml` line:
```yaml
shortNames:
  - ddbcfg   # WRONG — conflicts with dynamodbconfig.yaml
```
to:
```yaml
shortNames:
  - docdbcfg   # DocumentDB → docdb + cfg
```

## Pattern to avoid

When naming a new `<Resource>Config` CRD, check that its short name doesn't collide with any
existing CRD in the repo **and** with ACK/kro system CRDs in the cluster:

```bash
# Before adding a new shortName:
kubectl get crd -o json | jq -r '.items[] | select(.spec.names.shortNames != null) | select(.spec.names.shortNames[] == "YOUR_PROPOSED_SHORT_NAME") | .metadata.name'
# Must return empty. Any output = collision.
```

For DocumentDB specifically: `ddb` prefix is ambiguous (DynamoDB also abbreviates to DDB in AWS
docs). Prefer `docdb` for DocumentDB to match the AWS service name (`docdb.amazonaws.com`) and CLI
(`aws docdb …`).
