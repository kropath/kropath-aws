# SNS Topic RGD Exceeds kubectl Annotation Size Limit

> **Point-in-time note:** This log was written on 2026-08-31 based on observations at that time.
> Claims in this log are hypotheses or verified findings, clearly labelled below.

## Symptom

CI setup step (`cd tests && make setup`) fails at the non-lambda RGD batch with:

```
The ResourceGraphDefinition "snstopic.aws.kropath.run" is invalid:
* metadata.annotations: Too long: may not be more than 262144 bytes
```

## Root Cause (verified)

`kubectl apply` (client-side apply) stores the entire resource as the
`kubectl.kubernetes.io/last-applied-configuration` annotation. Kubernetes enforces a hard
262144-byte (256KB) limit on annotations.

`snstopic.aws.kropath.run.yaml` grew to ~271KB in KRO-919 (the naming CEL expansion across all
variants) and to ~276KB in KRO-920 (adding the AWS default policy CEL to five "no-policy"
variants). Both sizes exceed the limit.

Local test in the prior session passed because the developer used `kubectl apply --server-side`
which does not write the last-applied-configuration annotation and bypasses the limit.

## Fix (verified)

Change `kubectl apply "${non_lambda_args[@]}"` to `kubectl apply --server-side "${non_lambda_args[@]}"` in `tests/setup.sh`.

Server-side apply (SSA) uses a different field-ownership model that does not store the
configuration in annotations, so files of any size can be applied. SSA is safe for fresh CI
clusters and local development (where RGDs are recreated frequently anyway).

## What to Watch For

Any RGD that grows beyond 256KB will hit this limit with client-side apply. The setup.sh
now uses SSA for the non-lambda batch, which prevents this class of failure for all future
RGDs in that batch.

Lambda waves still use client-side apply; they are all well under 30KB today and are unlikely
to need SSA in the near term.
