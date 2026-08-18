# MemoryDB CI failures: RBAC omission, missing accessString, kubectl get user ambiguity

**Point-in-time disclaimer:** This log records the author's understanding at the time of writing
(2026-08-19). Claims here should be verified mechanically before acting on them in future sessions.
If this log conflicts with `docs/frequent-rgd-errors.md` or agent instructions, those sources win.

---

## Ticket
KRO-431 — PR #128 (https://github.com/kropath/kropath-aws/pull/128)

## Symptoms

CI ran Chainsaw E2E tests and reported:

- `memorydbackl`, `memorydbcluster`, `memorydbparametergroup`, `memorydbsnapshot`,
  `memorydbsubnetgroup`: all failed with `actual resource not found` on the ACK child resource.
- `memorydbuser`: failed with `MemoryDBUser.aws.kropath.run "ac1-user" is invalid:
  spec.accessString: Required value`.
- `iam/iamuser`: failed with `exit status 1` (secondary issue; same root cause #3 below).

## Root Cause 1 — memorydb.services.k8s.aws missing from kro ClusterRole

`tests/fixtures/rbac/kro-controller.yaml` is an RBAC ClusterRole (aggregation label
`rbac.kro.run/aggregate-to-controller: "true"`) that grants the kro controller permissions to
create and manage ACK child resources. The `memorydb.services.k8s.aws` API group was entirely
absent from the `apiGroups` list.

**Effect:** kro silently failed to create any ACK MemoryDB resource (SubnetGroup, ACL, Cluster,
ParameterGroup, Snapshot, User). The kropath resource instance appeared healthy from kro's
perspective, but the ACK child was never materialised — hence every `assert` step's
`actual resource not found`.

**Fix:** Added `- memorydb.services.k8s.aws` to the apiGroups list alongside the other ACK
groups (`elasticache.services.k8s.aws`, `efs.services.k8s.aws`, etc.).

**Detection:** The group was discovered by reading `kro-controller.yaml` directly and diffing
against the working ElastiCache implementation, not from a kubectl error message.

## Root Cause 2 — accessString missing from all 10 MemoryDBUser test fixtures

The MemoryDBUser CRD schema declares `accessString: string | required=true`. All 10 apply
fixtures in `tests/memorydb/memorydbuser/chainsaw-test.yaml` (AC-MDB04-01 through AC-MDB04-10)
were missing `spec.accessString`. The Kubernetes API server rejected the apply immediately.

**Fix:** Added `accessString: "on ~* &* +@all"` (Redis ACL string granting full access) to all
10 fixtures before the `authenticationMode:` field.

## Root Cause 3 — kubectl get user is ambiguous with three User CRDs installed

MemoryDB adds a third CRD that registers the `User` kind:
- `users.iam.services.k8s.aws` (IAM)
- `users.elasticache.services.k8s.aws` (ElastiCache)
- `users.memorydb.services.k8s.aws` (MemoryDB)

`kubectl get user` is now ambiguous and fails with an error asking the caller to specify the
resource group. This broke existing tests in `iamuser` and `elasticacheuser` that predated the
MemoryDB CRD installation.

**Fix:** Replaced all bare `kubectl get user` calls with fully-qualified forms:
- `tests/memorydb/memorydbuser/chainsaw-test.yaml` → `kubectl get users.memorydb.services.k8s.aws`
- `tests/iam/iamuser/chainsaw-test.yaml` → `kubectl get users.iam.services.k8s.aws`
- `tests/elasticache/elasticacheuser/chainsaw-test.yaml` → `kubectl get users.elasticache.services.k8s.aws`

**Lesson:** Any time a new CRD registers an already-used short-name Kind (User, Role, Policy,
etc.), audit ALL test files for bare `kubectl get <kind>` calls and replace with
`kubectl get <plural>.<group>`.

## Pattern to add to frequent-rgd-errors.md

The RBAC omission pattern is worth cataloguing: when a new ACK provider group is added to the
project, `tests/fixtures/rbac/kro-controller.yaml` must be updated in the same PR. Omitting the
group causes silent child-resource creation failure that is indistinguishable from a CEL bug at
first glance (all ACK child asserts fail as "not found").
