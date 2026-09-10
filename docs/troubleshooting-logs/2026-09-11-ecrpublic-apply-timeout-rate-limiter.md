> **Point-in-time disclaimer:** This log reflects findings as of 2026-09-11. Cluster state,
> RGD versions, and test infrastructure may change. Verify mechanically before acting on this log.

# ECRPublicRepository ac5: "client rate limiter Wait returned an error: context deadline exceeded"

## Symptom

PR #256 CI failed at `make test-ecrpublic` with `ac5-ecrpub-repo-mandatory-naming` APPLY step:

```
Error: failed to apply resource:
  client rate limiter Wait returned an error: context deadline exceeded
```

The failure occurred at test timestamp ~63s after the suite started. The global apply timeout
is 60s. The failing APPLY is the first operation inside `ac5-ecrpub-repo-mandatory-naming` —
creating the `open-source` ECRPublicConfig, which is the 4th config CR created in the suite.

## Root cause

`client-go`'s token-bucket rate limiter (default 5 QPS / burst 10) is shared across all
concurrent chainsaw suites in a test run. With `--parallel 4`, four suites hit the kube API
simultaneously. When the burst budget is exhausted, `rate.Limiter.Wait(ctx)` calculates the
estimated time until the next token. If that estimate exceeds the apply context deadline, it
returns `context.DeadlineExceeded` immediately rather than queuing.

The ecrpublicrepository suite has 4 ECRPublicConfig creates before ac5 (seed + ac3 + ac4 +
ac5), each followed by a status patch plus apply/assert calls on ECRPublicRepository. With
3 other suites making concurrent API calls, the aggregate rate easily exhausts the burst
and the estimated wait crosses the 60s deadline.

This is NOT a kro controller rate limiter issue (that was already addressed in setup.sh).
It is purely the Kubernetes client-side rate limiter on the chainsaw process itself.

## Fix

Increased `.chainsaw.yaml` `apply` timeout from 60s to 120s. Same rationale as the prior
`cleanup: 2m → 3m` increase (parallel-suite pressure). 120s is sufficient for the rate
limiter to drain without masking real schema/validation failures, which surface as immediate
non-deadline errors.

## Verification

CI round on commit after the fix — suite `chainsaw/ecrpublic/ecrpublicrepository` passes.

## Pattern for future suites

If a suite has many sequential steps and creates 3+ config CRs (each requiring apply +
status-patch + apply + assert), consider whether the aggregate API call count under
`--parallel 4` will exhaust the client-go burst budget within the apply timeout. If so,
splitting the suite into smaller test files (each with its own namespace) reduces the
per-suite call count and keeps the total under the threshold.
