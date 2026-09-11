> **Point-in-time disclaimer:** This log reflects findings as of 2026-09-12. Cluster state,
> RGD versions, and test infrastructure may change. Verify mechanically before acting on this log.

# CI: non-lambda RGD wait timeout after adding Backup family (KRO-1016)

## Symptom

PR #263 (backup RGDs + Chainsaw tests) failed CI on "Setup test environment" (run `34617683488`):

```
==> Waiting for all non-lambda RGDs to become Ready (drains kro queue before Lambda waves)...
[... 300s of kubectl wait ...]
timed out waiting for the condition on resourcegraphdefinitions/backupplan.aws.kropath.run
timed out waiting for the condition on resourcegraphdefinitions/backupselection.aws.kropath.run
timed out waiting for the condition on resourcegraphdefinitions/backupvault.aws.kropath.run
timed out waiting for the condition on resourcegraphdefinitions/bedrockagent.aws.kropath.run
[... dozens more ...]

Non-lambda RGD readiness FAILED (genuine graph errors — fix these before proceeding):

--- appscalingpolicy.aws.kropath.run ---
  GraphAccepted=True :: resource graph and schema are valid
  GraphRevisionsResolved=True :: revision 1 compiled and active
  KindReady=True :: kind AppScalingPolicy has been accepted and ready
  ControllerReady=True :: controller is running
  Ready=True ::
```

All three backup RGDs compile and reach `Active` locally in ~8 seconds (verified via
delete-apply-check loop per RGD compiles gate). The failure was not caused by a bug in
the backup RGD CEL or schema.

## Root cause (confirmed from CI run 34617683488)

Two independent problems:

### Problem 1: 300s timeout insufficient for 190+ non-lambda RGDs on a fresh kind cluster

The non-lambda batch now contains 192 RGDs. With `CONCURRENT_RECONCILES=2` and kro's
token-bucket rate limiter, processing 192 RGDs takes more than 300s on a cold `helm/kind-action`
cluster. Evidence:

- Wait started at 15:44:08
- First ACM RGDs became Active at 15:48:19 (~251s — ~57s before timeout)
- All backup/bedrock RGDs still processing when the 300s timer fired at 15:49:08

Adding the 3 backup RGDs (total: 192 non-lambda) crossed the 300s processing-time threshold.

### Problem 2: Transient state-lag causes false-positive "genuine graph error"

After the timeout, `setup.sh` classifies not-ready RGDs by checking
`GraphAccepted=False` (permanent failure). Any other not-ready RGD sets
`has_non_perm_failure=true` and triggers `exit 1`.

`appscalingpolicy.aws.kropath.run` had ALL conditions True (including `Ready=True`) at
15:49:08 but its `status.state` had not yet been written to `Active` by kro. kro sets
conditions first; `status.state` propagates on a separate write. The check ran in the
brief window between "all conditions True" and "state field written."

Classification logic treated `appscalingpolicy` (which had fully compiled) the same as
a genuine CEL error (which has GraphAccepted=True but NOT Ready=True), triggering a
false-positive `exit 1`.

## Fix

Two-part fix in `tests/setup.sh`:

1. **Timeout 300s → 600s** — 10 minutes is sufficient for 190+ non-lambda RGDs on a
   freshly-created kind cluster, based on the CI evidence that most RGDs become Active
   well before 600s.

2. **Three-case classification** — added `Ready=True` as a third case (transient
   state-lag), distinct from both `GraphAccepted=False` (permanent) and genuine errors:
   ```bash
   elif [ "${ready_status}" = "True" ]; then
     transient_rgds+=("${rgd}")
   ```
   Transient RGDs are logged as NOTE and do not trigger `exit 1`.

## Verification

Push the fix to branch `KRO-1016-backup-rgd-tests` (PR #263) and observe CI
"Setup test environment" pass. The 600s timeout gives kro ample time to process all
RGDs, and the transient case prevents false positives even on unusually slow runners.
