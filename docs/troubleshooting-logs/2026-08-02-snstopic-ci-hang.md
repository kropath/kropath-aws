# 2026-08-02 SNSTopic Chainsaw CI Hang Investigation

**Ticket:** KRO-324 / KRO-260  
**PR:** #62 (`KRO-260-snstopic-rgd-tests`)  
**Symptom:** `make test` in CI hangs indefinitely (Bug 1) and later times out at 2 minutes (Bug 2) on the `chainsaw/sns/snstopic` suite.

---

## Bug 1 — `kubectl delete` hangs indefinitely

### What failed

Every `cleanup:` script in `tests/sns/snstopic/chainsaw-test.yaml` ran `kubectl delete topic --all -n snstopic` without `--wait=false`. Because no ACK controllers are deployed in the test cluster (only the CRD definitions are installed), no ACK controller can remove the `finalizers.sns.services.k8s.aws` finalizer from Topic CRs. kro also adds its own `kro.run/foreground-deletion` finalizer to ACK Topic CRs as part of cascade deletion. Both finalizers blocked the `kubectl delete` call — and with no controllers to clear them, the delete never completed.

CI run where this was first observed: the `make test` step simply hung with no output, eventually killed by CI timeout.

### Fix (commit ff48691)

Added `--wait=false` to every `kubectl delete` call in all 34 `cleanup:` scripts so `kubectl` returns immediately after issuing the delete request rather than waiting for finalizer removal.

Also added finalizer-stripping patches before each delete so kro's `kro.run/foreground-deletion` finalizer is removed first:

```bash
for name in $(kubectl get topic -n snstopic -o jsonpath='{.items[*].metadata.name}' 2>/dev/null); do
  kubectl patch topic "$name" -n snstopic --type=merge -p '{"metadata":{"finalizers":[]}}' 2>/dev/null || true
done
kubectl delete topic --all -n snstopic --ignore-not-found=true --wait=false
```

---

## Bug 2 — Chainsaw `context deadline exceeded` at cleanup timeout (2m)

### What failed

After fixing Bug 1, CI ran (run 30738660054) but failed with:

```
ERROR: context deadline exceeded
  - ac33-attribute-subscription-filter-policy-scope / cleanup (2m0s)
  - ac34-deletion-policy-retain / cleanup (2m0s)
```

Exactly at the `cleanup: 2m` timeout set in `.chainsaw.yaml`.

### Root cause

Chainsaw automatically deletes every resource that was `apply`-ed in a step's `try:` block during the cleanup phase. For ac34 (the last step), Chainsaw's auto-delete triggers kro's cascade deletion: kro must delete all 34 accumulated SNSTopic instances and their associated ACK Topic child CRs. With no ACK controllers running, kro cannot get AWS confirmation of deletion, so each cascade cycle takes 60-90s, and with 34 CRs queued, the full cascade takes well over 2 minutes.

Even with `cleanup: 2m` in `.chainsaw.yaml`, the kro queue takes longer than 2 minutes for a full 34-resource teardown.

### Why `cleanup: 2m` was insufficient

The `cleanup:` script (with `--wait=false` from Bug 1 fix) returns immediately. But Chainsaw still has to wait for its own auto-delete of the `try:`-applied SNSTopic CRs to complete before it can mark the step done. kro processes 34 items in its queue before it handles ac33/ac34's SNSTopic deletion, so Chainsaw's auto-delete wait exceeds 2 minutes even with the increased timeout.

### Fix (this PR)

Added a `finally:` block to `ac34-deletion-policy-retain` in `tests/sns/snstopic/chainsaw-test.yaml`.

**Why `finally:` works where `cleanup:` did not:**

- Chainsaw's `finally:` block runs during **test execution** phase, immediately after the step's `try:` completes.
- Chainsaw's `cleanup:` (and its auto-delete) run during the **cleanup phase**, after all steps' `finally:` blocks.
- So by placing the finalizer-strip + bulk-delete in `finally:`, all 34 SNSTopic and Topic CRs are patched and deleted _before_ the cleanup phase starts.
- When the cleanup phase runs, Chainsaw's auto-delete for ac34 and ac33 finds resources already in `Terminating` state with no finalizers — deletion completes immediately (sub-second).

The `finally:` block:

```yaml
finally:
  - script:
      content: |
        for name in $(kubectl get topic -n snstopic -o jsonpath='{.items[*].metadata.name}' 2>/dev/null); do
          kubectl patch topic "$name" -n snstopic --type=merge -p '{"metadata":{"finalizers":[]}}' 2>/dev/null || true
        done
        kubectl delete topic --all -n snstopic --ignore-not-found=true --wait=false 2>/dev/null || true
        for name in $(kubectl get snstopic -n snstopic -o jsonpath='{.items[*].metadata.name}' 2>/dev/null); do
          kubectl patch snstopic "$name" -n snstopic --type=merge -p '{"metadata":{"finalizers":[]}}' 2>/dev/null || true
        done
        kubectl delete snstopic --all -n snstopic --ignore-not-found=true --wait=false 2>/dev/null || true
```

### Commits

- `606f316` — initial investigation, identified Bug 1
- `ff48691` — Bug 1 fix: `--wait=false` + finalizer-strip in all 34 cleanup scripts
- `e402527` — raised `.chainsaw.yaml` `cleanup:` timeout to `2m` (necessary but not sufficient)
- this commit — Bug 2 fix: `finally:` block on ac34

---

## Pattern: use `finally:` on the last step of long Chainsaw suites

When a Chainsaw test suite accumulates many resources across many steps and teardown exceeds the `cleanup` timeout, add a `finally:` block to the **last `try:` step** to pre-strip all finalizers and issue `--wait=false` deletes. This ensures Chainsaw's auto-delete in the cleanup phase finds resources already gone and completes instantly.

See `docs/frequent-rgd-errors.md` section "Chainsaw Cleanup Timeout — kro Cascade Deletion Queue Backup" for the canonical write-up.
