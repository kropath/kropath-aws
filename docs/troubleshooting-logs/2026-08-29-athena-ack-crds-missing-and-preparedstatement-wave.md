# Athena ACK CRDs Missing + AthenaPreparedStatement Cross-RGD Wave

**Date:** 2026-08-29  
**Ticket:** KRO-858  
**Author:** Implementer  
**Point-in-time disclaimer:** This log records the author's understanding at the time of writing.
Claims here are hypotheses unless corroborated by `docs/frequent-rgd-errors.md` or agent instructions.

---

## Symptom

All three Athena RGDs (`athenaworkgroup`, `athenadatacatalog`, `athenapreparedstatement`) showed
`GraphAccepted=False` / `Inactive` immediately after `kubectl apply` in CI setup:

```
athenaworkgroup.aws.kropath.run:
  cannot resolve group version "athena.services.k8s.aws/v1alpha1": schema not found

athenadatacatalog.aws.kropath.run:
  cannot resolve group version "athena.services.k8s.aws/v1alpha1": schema not found

athenapreparedstatement.aws.kropath.run:
  cannot resolve group version kind "aws.kropath.run/v1alpha1, Kind=AthenaWorkGroup": schema not found
```

Chainsaw tests then failed at the first `APPLY` step (ApplyTimeout=60s) because the API server
did not recognise `AthenaWorkGroup`/`AthenaDataCatalog`/`AthenaPreparedStatement` kinds — none of
the RGDs were Active, so kro never generated the CRDs.

---

## Root cause (two-part)

### Part 1 — `athena` missing from `ACK_SERVICES` in `hack/install-provider-crds.sh`

`kro` validates every `externalRef` GVK against the live API server schema at compile time. The
Athena RGDs reference ACK kinds in the `athena.services.k8s.aws/v1alpha1` group, but
`hack/install-provider-crds.sh` never installed the Athena ACK CRDs — `athena` was not in the
`ACK_SERVICES` list. Without those CRDs present, kro cannot resolve the group/version and marks
every Athena RGD `GraphAccepted=False`.

### Part 2 — `AthenaPreparedStatement` applied in the same batch as `AthenaWorkGroup`

`AthenaPreparedStatement` references `AthenaWorkGroup` (a kro-generated kind) via a `wgRef`
`externalRef`. kro validates this reference at compile time too. If `athenapreparedstatement` is
applied simultaneously with `athenaworkgroup` (or before it reaches `Active`), the
`AthenaWorkGroup` CRD does not yet exist and kro rejects the PreparedStatement RGD with
`schema not found`.

This is the same pattern as the Lambda cross-RGD dependency already handled in `tests/setup.sh`
via Lambda waves 1–3.

---

## Fix

### 1. `hack/install-provider-crds.sh` — add `athena` to `ACK_SERVICES`

```bash
# Before (abridged):
ACK_SERVICES="${ACK_SERVICES:-... glue}"
# After:
ACK_SERVICES="${ACK_SERVICES:-... glue athena}"
```

### 2. `tests/setup.sh` — exclude `athenapreparedstatement` from the non-lambda batch

The non-lambda `kubectl apply` loop was updated to skip `athenapreparedstatement*.yaml` (using
the same `case` pattern already in place for `lambda*.yaml`).

### 3. `tests/setup.sh` — add an Athena wave after the non-lambda wait

After the non-lambda `kubectl wait rgd --all` completes (guaranteeing `athenaworkgroup` is
`Active` and its `AthenaWorkGroup` CRD exists), a new Athena wave applies
`athenapreparedstatement.aws.kropath.run.yaml`:

```bash
echo "==> Athena wave (AthenaPreparedStatement, needs AthenaWorkGroup CRD from non-lambda batch)..."
kubectl apply -f "${SCRIPT_DIR}/../rgds/athenapreparedstatement.aws.kropath.run.yaml"
```

This mirrors the existing Lambda wave pattern (Lambda waves 1–3 in `tests/setup.sh`).

---

## Verification

No local cluster available; fix pushed to CI per Theme 35 push-first rule. The two failure modes
are mechanical and deterministic — once the Athena ACK CRDs are installed and the dependency
ordering is enforced, all three RGDs will reach `Active` and the Chainsaw suites will be able to
APPLY their test resources.

---

## Patterns discovered / confirmed

- **Any new ACK service family requires `athena`-style addition to `ACK_SERVICES`** — kro
  compile-time GVK resolution fails silently in tests if the upstream CRD is not installed.
- **Cross-RGD `externalRef` dependencies require dependency-ordered waves in `setup.sh`** — the
  referencing RGD cannot be applied until the referenced RGD is `Active` and has generated its
  CRD. See the Lambda wave pattern as the reference implementation.
- Both of these checks should be done at family implementation time, not discovered by CI.
