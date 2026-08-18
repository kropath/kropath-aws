# EFS CI Failures — Three Bugs Fixed (KRO-423, PR #127, run 32142981365)

**Point-in-time disclaimer:** This log reflects findings as of 2026-08-19. Treat as hypothesis
unless mechanically verified against the current codebase.

## Symptoms

Three Chainsaw test steps timed out or failed in CI run 32142981365:
- `efsfilesystem/ac14-lifecycle-transition-to-archive` — assert timeout (5 min, value mismatch)
- `efsaccesspoint/ac2-filesystem-ref-lookup` — assert timeout (5 min, value mismatch)
- `efsmounttarget/ac1-filesystem-id-direct` — immediate failure (resource not found)

---

## Bug 1 — CEL ternary operator precedence in lifecyclePolicies

**File:** `rgds/efsfilesystem.aws.kropath.run.yaml`

**Root cause:** CEL `+` has HIGHER precedence than `?:`. The expression:
```
COND ? LIST1 : [] + (ARCHIVE_TERM) + (PRIMARY_TERM)
```
parses as:
```
COND ? LIST1 : ([] + ARCHIVE_TERM + PRIMARY_TERM)
```
When `transitionToIA` is set (COND=true), only `LIST1` is returned. Archive and Primary terms
are in the FALSE branch and are never evaluated when IA is set. ac1–ac13 pass because they only
test IA alone; ac14 is the first step testing IA + Archive together.

**Fix:** Wrap the first ternary in its own parentheses:
```
(COND ? LIST1 : []) + (ARCHIVE_TERM) + (PRIMARY_TERM)
```
Specifically: added one `(` after `${` at the start of the expression (making `${(((`) and added
one `)` after the first ternary's false branch `: [])`.

**Verification:** EFSFileSystem with `transitionToIA: AFTER_30_DAYS` and
`transitionToArchive: AFTER_90_DAYS` produces
`[{"transitionToIA":"AFTER_30_DAYS"},{"transitionToArchive":"AFTER_90_DAYS"}]` in ACK spec.

---

## Bug 2 — kro status overwrite race condition in tests

**Files:** `tests/efs/efsaccesspoint/chainsaw-test.yaml`, `tests/efs/efsmounttarget/chainsaw-test.yaml`

**Root cause:** Tests patched `EFSFileSystem.status.fileSystemId` directly. But kro's reconciler
for EFSFileSystem runs continuously and re-computes status from the ACK FileSystem's status. Since
no ACK EFS controller runs in the test cluster, the ACK FileSystem status is empty, so kro
immediately overwrites the manually-patched value with `""`.

**Fix:** Instead of patching the kro CR's status, patch the ACK FileSystem status:
```
filesystems.efs.services.k8s.aws ac2-parent-fs --subresource=status
-p '{"status":{"fileSystemID":"fs-abcdef1234567890"}}'
```
Since no ACK EFS controller runs, this patch persists. kro reads it and propagates to
EFSFileSystem's status on each reconcile. Added assertion steps:
1. Assert ACK FileSystem exists (wait for kro to create it)
2. Patch ACK FileSystem status
3. Assert EFSFileSystem status.fileSystemId propagated (wait for kro reconcile)
4. Then create AccessPoint/MountTarget

**Key insight:** Patch the ACK CHILD resource's status, not the kro CR's status. kro computes
kro-CR status FROM the ACK child status; if you patch kro-CR status directly, kro's next reconcile
overwrites it.

---

## Bug 3 — securityGroups "no such key" CEL error

**File:** `rgds/efsmounttarget.aws.kropath.run.yaml`

**Root cause:** `securityGroups: "[]string"` in the kro schema generates a CRD `array` field with
no `default: []`. Kubernetes leaves the field absent when the user doesn't set it. kro's CEL then
evaluates `schema.spec.securityGroups.size() > 5` (in `includeWhen`) and throws
`no such key: securityGroups`. kro enters ERROR state; ACK MountTarget is never created.

**Reproduced locally:**
```
"resource reconciliation failed: includeWhen \"schema.spec.securityGroups.size() > 5\": 
eval \"schema.spec.securityGroups.size() > 5\": no such key: securityGroups"
```

**Fix:** Optional chaining throughout:
- `includeWhen`: `schema.spec.?securityGroups.orValue([]).size() > 5`
- spec template: `securityGroups: ${schema.spec.?securityGroups.orValue([])}`

When `securityGroups` is absent, `?securityGroups.orValue([])` returns `[]`. kro strips empty
lists as zero values, so the ACK MountTarget is created without `securityGroups`. When provided,
the list passes through normally.

**Pattern:** For any `"[]type"` schema field without a default, ALWAYS use optional chaining
in CEL expressions that access it. Do NOT use `.size()` directly on a potentially-absent list field.
See also `kropath-rgd-cel-traps` §1 (no such key).
