> **Point-in-time disclaimer:** This log records findings from 2026-09-12. Conclusions were valid
> at time of writing. Verify mechanically before acting on any claim here.

# Organizations: ACK Children Never Created — Missing kro RBAC (KRO-1000, PR #262)

**Date:** 2026-09-12
**Ticket:** KRO-1000
**PR:** kropath/kropath-aws#262
**Affected suites:** `tests/organizations/organizationsaccount`, `tests/organizations/organizationsou`

## Symptom

Identical to the previous round logged in
`2026-09-11-organizations-includewhen-naming-configmap.md`: both suites failed in CI after
exactly 300 s (`AssertTimeout`) on their *first* ACK-child assert —

```
organizationsou       | ou-ac1-parentID-from-defaults | ASSERT | ERROR |
  organizations.services.k8s.aws/v1alpha1/OrganizationalUnit @ organizationsou/ou-ac1-ou
    === ERROR
    actual resource not found
```

`organizationsconfig` passed, the RGDs were `Active`, and `tests/setup.sh` printed no
RGD diagnosis — so the graph itself was fine.

## Root cause

The kro controller ClusterRole (`tests/fixtures/rbac/kro-controller.yaml`) had no
`organizations.services.k8s.aws` entry, so kro could not create the `Account` /
`OrganizationalUnit` children. Confirmed in one command:

```
$ kubectl auth can-i create organizationalunits.organizations.services.k8s.aws \
    --as=system:serviceaccount:kro-system:kro
no
```

`organizations` was the **first** organizations family with ACK children — the pre-existing
`organizationsconfig` is a governance CR with no ACK child, so no group was ever needed.
The ACK CRDs come from local stubs in `tests/fixtures/crds/organizations/`, not from
`hack/install-provider-crds.sh`, so the drift check recorded for KRO-992 (which iterates
`ACK_SERVICES`) does **not** cover this path. Use instead:

```bash
grep -rh "^  group: " tests/fixtures/crds/*/*.yaml | sort -u | sed 's/^  group: //' \
  | grep -v '^services\.k8s\.aws$' \
  | while read g; do grep -q -- "- ${g}$" tests/fixtures/rbac/kro-controller.yaml \
      || echo "MISSING from RBAC: $g"; done
```

> **Note for the next session:** the previous round attributed this same 300 s /
> `actual resource not found` symptom to the KRO-919 `includeWhen` bug. That change was
> correct on its own merits but was **not** what unblocked CI. Check RBAC *first* —
> it is one `kubectl auth can-i` away.

## Three test bugs unmasked by the RBAC fix

With RBAC granted, the suites ran past step 1 for the first time and surfaced real bugs:

| Steps | Symptom | Fix |
|---|---|---|
| `ac10-naming-mandatory`, `ou-ac2-mandatory-parentID`, `ou-ac17-naming-mandatory-template` | `OrganizationsConfig … is invalid: parentID/namingTemplate cannot be set in both mandatory and defaults` | The applied `spec` set the same scalar in both tiers, which the CRD's ADR-015 §4.2 mutual-exclusivity rule rejects. Dropped the duplicate tier from `spec`. The `status.effectiveConfig` patch still carries both tiers — that is what actually drives the RGD's precedence logic, so test intent is unchanged. |
| `ac13-tag-merge`, `ou-ac11-tag-merge` | `Error from server (NotFound): accounts… "ac13-acct" not found` inside the `- script:` step | Classic `apply` → `script` race against the ACK child. Added a content `assert` on the child (`spec.name`) before the script. |
| `ou-ac7-valid-root-parentID`, `ou-ac8-valid-ou-parentID` | `status.validationError: Required value: field not found in the input object` | These negative cases asserted `validationError: ""`, but kro omits empty-string status fields, so the key never materialises. Replaced with an assert on the child `OrganizationalUnit.spec.parentID` plus a chainsaw `- error:` block proving the advisory `<name>-parentid-error` ConfigMap was **not** created. |

## Verification

```
$ cd tests && make test-organizations
--- PASS: chainsaw/organizations/organizationsou[organizationsou]           (5.35s)
--- PASS: chainsaw/organizations/organizationsaccount[organizationsaccount] (6.11s)
--- PASS: chainsaw/organizations/organizationsconfig[organizationsconfig]   (7.29s)
- Passed  tests 3 / Failed  tests 0 / Skipped tests 0
```

Also re-run after deleting the `organizationsou` / `organizationsaccount` namespaces
(finalizers stripped first, since the test cluster has kro but no ACK controllers) to rule
out a stale-state pass. Clean-state run: 3 passed, 0 failed.
