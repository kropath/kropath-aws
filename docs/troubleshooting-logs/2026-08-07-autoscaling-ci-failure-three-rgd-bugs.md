# 2026-08-07 — AutoScalingGroup CI failure: three RGD bugs + fixture issues

**Ticket:** KRO-484 — fix CI failure on PR #91

## What failed

CI `Chainsaw E2E Tests` step timed out because `kubectl wait rgd --all --for=condition=Ready
--timeout=120s` in `setup.sh` never completed. The `autoscalinggroup.aws.kropath.run` RGD was
`Inactive` (STATE=Inactive), which causes the single cluster-wide wait to time out and then lists
every RGD not yet `Ready` at the deadline as a "failure" — those others (rdssubnetgroup, s3bucket,
etc.) were red herrings.

## Root causes (three independent bugs in the RGD)

### Bug 1 — `autoScalingGroupName` instead of `name`

The ACK `autoscaling-chart:1.1.0` AutoScalingGroup CRD uses `spec.name` as the cloud resource
name field. The RGD template had `autoScalingGroupName: ${naming.data.resourceName}`.

kro error:
```
error getting field schema for path spec.autoScalingGroupName: schema not found for field autoScalingGroupName
```

**Fix:** change `autoScalingGroupName:` to `name:` in the ACK ASG template spec.

### Bug 2 — `warmPoolConfiguration` is status-only in ACK v1.1.0

The RGD template had a `warmPoolConfiguration:` block in the ACK ASG `spec`. In ACK
`autoscaling-chart:1.1.0`, `warmPoolConfiguration` only exists in `status` (read-only reporting)
— there is no `spec.warmPoolConfiguration`. kro's schema extractor rejected the field.

kro error:
```
error getting field schema for path spec.warmPoolConfiguration: schema not found for field warmPoolConfiguration
```

**Fix:** remove the `warmPoolConfiguration:` block from the ACK template. The kropath schema's
`spec.warmPool.*` fields are retained for future use (when ACK adds spec-side warm pool support);
they are accepted by the kropath schema but not forwarded to ACK. The AC-34 test was updated to
assert only that the ACK resource is created with the correct `spec.name`.

### Bug 3 — `| required` instead of `| required=true`

The RGD schema used `integer | required` for `minSize` and `maxSize` and `string | required` for
`launchTemplate.name`. kro v0.9.2 simple-schema requires `| required=true` (with a value).

kro error:
```
field minSize: marker key 'required' without a value
```

**Fix:** change all three occurrences to `| required=true`.

## Fixture bugs (test setup)

### effectiveConfig not seeded (wait-for-controller pattern)

The autoscaling test setup used a `until kubectl get autoscalingconfig ...` loop waiting for
`kropath-controller` to populate `status.effectiveConfig`. No `kropath-controller` runs in the
local kind cluster (matching all other suites). The loop timed out.

**Fix:** replace with a `kubectl patch --subresource=status --type=merge` loop that seeds
`effectiveConfig` from `spec.mandatory` and `spec.defaults` for every config in the namespace —
the same approach used by all other suites (IAM, RDS, KMS, etc.).

### Dual-tier `namingTemplate` in two config fixtures

`mandatory-naming-cfg` and `tag-naming-cfg` both had non-empty `namingTemplate` in both
`mandatory` and `defaults`. The AutoScalingConfig CRD's `x-kubernetes-validations` rule rejects
this:

```
namingTemplate must be set in either mandatory or defaults, not both.
```

The rule fires when BOTH `mandatory.namingTemplate != ""` AND `defaults.namingTemplate != ""`.

**Fix:** set `defaults.namingTemplate: ""` in both fixtures. `mandatory-naming-cfg` tests
mandatory override (AC-4); only `mandatory.namingTemplate` need be non-empty. `tag-naming-cfg`
tests `{tag.env}` interpolation in mandatory (AC-6); same pattern.

### Stale RBAC ClusterRole in cluster

The `tests/fixtures/rbac/kro-controller.yaml` had already been updated to include
`autoscaling.services.k8s.aws` in the API group list, but `make test-autoscaling` does not
re-run `make setup`. The in-cluster ClusterRole was stale (missing the autoscaling API group).

kro error:
```
autoscalinggroups.autoscaling.services.k8s.aws "ac1-asg" is forbidden:
User "system:serviceaccount:kro-system:kro" cannot get resource "autoscalinggroups"
```

**Fix:** run `kubectl apply -f tests/fixtures/rbac/kro-controller.yaml` to re-apply the RBAC.
On CI this runs via `make setup` before the test, so CI picks it up correctly.

### AC-34 assert used invalid Chainsaw JMESPath syntax

The AC-34 assert used `name: (contains(@, 'ac34'))`. Chainsaw/kyverno-json evaluated the
parenthesized expression on the LEFT side as a JMESPath query key, not as an assertion on the
right-side value — the result was an instant "resource not found" failure because the expression
didn't match the field path.

**Fix:** replace with the exact expected value: `name: autoscalinggroup-ac34-asg` (namespace
`autoscalinggroup` + resource name `ac34-asg` via `{namespace}-{name}` template).

## Diagnostic commands used

```bash
# Check which RGD is Inactive (don't use kubectl describe — it buries the error):
kubectl get rgd
kubectl get rgd autoscalinggroup.aws.kropath.run -o jsonpath='{.status.conditions}'

# Verify ACK CRD field names via Helm chart:
helm pull oci://public.ecr.aws/aws-controllers-k8s/autoscaling-chart --version 1.1.0 --untar -d /tmp/autoscaling-chart
python3 -c "import yaml; crd=yaml.safe_load(open('...autoscalinggroups.yaml')); print(sorted(crd['spec']['versions'][0]['schema']['openAPIV3Schema']['properties']['spec']['properties'].keys()))"

# Re-apply stale RBAC:
kubectl apply -f tests/fixtures/rbac/kro-controller.yaml
```

## Pattern to watch for

Any new resource family whose RGD template references ACK `spec.*` fields must verify those
fields exist in `spec` (not only in `status`) by inspecting the ACK CRD. ACK often reports
current state in `status` for fields that are write-only via a separate API action (warm pool,
instance refresh, etc.) and not configurable via `spec`.

Also: every multi-tier `*Config` test fixture with a non-empty `mandatory.*` governance field
must have the corresponding `defaults.*` field set to empty/zero (not a duplicate non-empty
value) to avoid the mutual-exclusion validation rule.
