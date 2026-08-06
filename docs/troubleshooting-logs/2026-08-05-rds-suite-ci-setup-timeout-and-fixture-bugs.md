# 2026-08-05 — RDS suite (KRO-401) CI failure: setup RGD-wait timeout + fixture bugs

CI failed at the `make setup` step with a wall of RGD-wait timeouts:

```
timed out waiting for the condition on resourcegraphdefinitions/rdscluster.aws.kropath.run
timed out waiting for the condition on resourcegraphdefinitions/rdsinstance.aws.kropath.run
timed out waiting for the condition on resourcegraphdefinitions/rdssubnetgroup.aws.kropath.run
timed out waiting for the condition on resourcegraphdefinitions/s3bucket.aws.kropath.run
timed out waiting for the condition on resourcegraphdefinitions/secretsmanagersecret.aws.kropath.run
timed out waiting for the condition on resourcegraphdefinitions/snstopic.aws.kropath.run
timed out waiting for the condition on resourcegraphdefinitions/sqsqueue.aws.kropath.run
make: *** [Makefile:20: setup] Error 1
```

Root cause was a **single** `Inactive` RGD (`rdscluster`) that hung
`setup.sh`'s `kubectl wait rgd --all --for=condition=Ready --timeout=120s`; the
other six RGDs in the list (`s3bucket`, `secretsmanager`, `sns`, `sqs`, and the
other two RDS ones) were red herrings — the `wait` reports *every* RGD not yet
`Ready` at the 120s mark. Fixing `rdscluster` unblocked setup; then the RDS
chainsaw suites surfaced four independent fixture/CRD bugs.

Final state: all 22 RGDs `Ready`; all 4 RDS suites (`rdscluster`, `rdsconfig`,
`rdsinstance`, `rdssubnetgroup`) PASS in parallel (`--parallel 4`).

> Note: the RTK `make` wrapper caches command output. After a fix, `make test-rds`
> replayed a **stale cached FAIL**. Verify with `rtk proxy chainsaw test rds/ ...`
> (raw, uncached) and trust the process **exit code**, not the replayed log.

---

## 1. `rdscluster` RGD stuck `Inactive` — `unknown type: number`

**Symptom:** `kubectl get rgd rdscluster.aws.kropath.run` → `STATE=Inactive`.
Condition:

```
reason: InvalidResourceGraph
message: failed to build OpenAPI schema for instance: field serverlessV2ScalingMinCapacity: unknown type: number
```

**Cause:** `rgds/rdscluster.aws.kropath.run.yaml` declared the two Serverless-v2
capacity fields as `number`:

```yaml
serverlessV2ScalingMinCapacity: number | default=0
serverlessV2ScalingMaxCapacity: number | default=0
```

kro v0.9.2 simple-schema has only four atomic types — `string`, `integer`,
`boolean`, `float` (`pkg/simpleschema/types/atomic.go`). `number` is rejected.

**Fix:** use `float` (maps to OpenAPI `type: number` in the generated CRD):

```yaml
serverlessV2ScalingMinCapacity: float | default=0
serverlessV2ScalingMaxCapacity: float | default=0
```

`rgds/rdscluster.aws.kropath.run.yaml`. After the edit,
`kubectl delete crd rdsclusters.aws.kropath.run` to force kro to re-derive the
CRD with the numeric field type.

---

## 2. `crds/rdsconfig.yaml` — mutual-exclusion validation rejected legitimate configs

**Symptom:** positive cascade steps (`rdsinstance/in2`, `rdssubnetgroup/sg2`,
`rdscluster/cl2`, …) failed at CREATE of a **minimal** `RDSConfig`:

```
RDSConfig "in2-cfg" is invalid: <nil>: Invalid value: storageEncrypted cannot be set in both mandatory and defaults simultaneously.
```

The config only set `spec.mandatory.storageEncrypted: true` and
`spec.defaults.namingTemplate` — it never set `defaults.storageEncrypted`.

**Cause:** `spec.defaults.*` in the CRD carried **non-zero "secure baseline"
defaults** (`storageEncrypted: true`, `deletionProtection: true`,
`backupRetentionPeriod: 7`, `storageType: "gp3"`,
`namingTemplate: "{namespace}-{name}"`, …). Creating any `spec.defaults` object
made the apiserver materialize `defaults.storageEncrypted: true`, which collided
with the explicit `mandatory.storageEncrypted: true` and tripped the
value-guarded `x-kubernetes-validations` mutual-exclusion rule. CRD-schema
defaults on a tier are fundamentally incompatible with a cross-tier
mutual-exclusion contract.

**Fix:** removed all 32 scalar `default:` values from `spec.mandatory` and
`spec.defaults` (kept the `default: {}` on the tier objects and on
`tags`/`syncedLabels`/`syncedAnnotations` maps). Verified:

- minimal `mandatory.storageEncrypted: true` + `defaults.namingTemplate` → **accepted**;
- explicit `mandatory.storageEncrypted: true` + `defaults.storageEncrypted: true` → **rejected** (negative tests `ac3`–`ac9` still pass).

`crds/rdsconfig.yaml`. After the edit, `kubectl apply -f crds/rdsconfig.yaml`
(API server validates immediately; check `ESTABLISHED: True`).

---

## 3. `rdscluster` fixtures — quoted `float` values

**Symptom:** after fix #1, `cl7`–`cl9` failed at CREATE of the RDSCluster:

```
RDSCluster "cl7-cluster" is invalid: spec.serverlessV2ScalingMinCapacity: Invalid value: "string": ... must be of type number: "string"
```

**Cause:** the instance-spec and `RDSConfig.spec.mandatory` fixture values were
quoted strings (`serverlessV2ScalingMinCapacity: "0.5"`), which no longer
validate against the `float` (number) field.

**Fix:** unquoted all 8 occurrences (`0.5`, `4.0`, `0.3`, `8.0`, `6.0`) in
`tests/rds/rdscluster/chainsaw-test.yaml`. The `status.effectiveConfig` patch
JSON already used numeric literals, so no change there. (Do **not** confuse with
the "quote inline CEL ternary" rule — that applies to CEL expression strings in
the RGD YAML, not to numeric literals in instance fixtures.)

---

## 4. `rdsinstance`/`rdscluster`/`rdssubnetgroup` — `- script:` race + label/ConfigMap-name bugs

**Symptom (race):** tag-merge steps (`in16`, `cl14`, latently `sg4`) ran a bare
`- script:` querying the kro child immediately after `- apply:`:

```
Error from server (NotFound): dbinstances.rds.services.k8s.aws "in16-inst" not found
exit status 4
```

**Cause:** `- script:` runs once with no retry, racing the reconciler. `cl7`–`cl9`
had the same race (masked earlier by the string-type error).

**Fix:** inserted a minimal `- assert:` on the child (`spec.engine` /
`spec.description`) between the `- apply:` and the `- script:` in every affected
step — `in16`, `cl7`, `cl8`, `cl9`, `cl14`, `sg4`. Chainsaw asserts retry to
`AssertTimeout` (5m), so the child is guaranteed present before the `jq` runs.

**Symptom (label prefix):** after the race fix, `in16`/`cl14` label check failed
— `jq -e '.metadata.labels["kropath.run/team"] == ...'` returned nothing.

**Cause:** the RGD prefixes synced labels with `aws.kropath.run/` (RGD
`transformMapEntry(k, v, {"aws.kropath.run/" + k: v})`). Actual label was
`aws.kropath.run/team`, not bare `kropath.run/team`.

**Fix:** `kropath.run/team` → `aws.kropath.run/team` in the `in16` and `cl14` jq.

**Symptom (ConfigMap name):** `in21-password-mutual-exclusion` timed out at 5m
asserting `ConfigMap in21-inst`.

**Cause:** the RGD's advisory ConfigMap is named
`${schema.metadata.name}-password-exclusion-error` → `in21-inst-password-exclusion-error`,
not `in21-inst`.

**Fix:** asserted the full generated name
`in21-inst-password-exclusion-error` in `tests/rds/rdsinstance/chainsaw-test.yaml`.

---

## Files changed

| File | Change |
|---|---|
| `rgds/rdscluster.aws.kropath.run.yaml` | `number` → `float` (2 serverless-v2 fields) |
| `crds/rdsconfig.yaml` | removed 32 scalar `spec.mandatory`/`spec.defaults` defaults |
| `tests/rds/rdscluster/chainsaw-test.yaml` | unquoted 8 float values; +4 wait-asserts (cl7/cl8/cl9/cl14); label prefix (cl14) |
| `tests/rds/rdsinstance/chainsaw-test.yaml` | +1 wait-assert (in16); label prefix (in16); ConfigMap name (in21) |
| `tests/rds/rdssubnetgroup/chainsaw-test.yaml` | +1 wait-assert (sg4) |

## Local test run — PASS

```
--- PASS: chainsaw (0.01s)
    --- PASS: chainsaw/rds/rdssubnetgroup[rdssubnetgroup] (1.79s)
    --- PASS: chainsaw/rds/rdsconfig[rdsconfig] (1.94s)
    --- PASS: chainsaw/rds/rdscluster[rdscluster] (4.99s)
    --- PASS: chainsaw/rds/rdsinstance[rdsinstance] (5.88s)
PASS
- Passed  tests 4
- Failed  tests 0
- Skipped tests 0
```

All 22 RGDs `Ready` (setup gate `kubectl wait rgd --all` passes).
