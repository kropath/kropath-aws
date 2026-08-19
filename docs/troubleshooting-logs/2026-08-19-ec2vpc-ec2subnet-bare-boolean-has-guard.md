# EC2VPC + EC2Subnet: bare boolean fields cause "no such key" CEL error when omitted

> **Point-in-time disclaimer:** This log reflects the author's understanding at the time of
> writing (2026-08-19). Later discoveries may supersede these conclusions. Treat as a
> hypothesis that has been mechanically verified, not a permanent invariant.

## Ticket / PR

KRO-473 — PR #130 (kropath-aws)

## Symptom

CI failures for `ec2vpc` and `ec2subnet` Chainsaw test suites (300s timeout). All other EC2
suites pass. Chainsaw asserts `ec2.services.k8s.aws/v1alpha1/VPC @ ec2vpc/ac1-vpc` and
`ec2.services.k8s.aws/v1alpha1/Subnet @ ec2subnet/ac1-subnet` as "actual resource not found".

Both RGDs were `Active` (graph compiled). The issue was at *instance reconciliation* time, not
compile time.

## Root cause

Bare boolean fields in the RGD schema (no `| default=`) leave the field **absent** from the
stored CR spec when the user does not provide a value. kro's CEL runtime treats accessing an
absent field as "no such key", causing the entire template evaluation to fail. With the
reconciler failing, kro never creates the ACK child resource.

Affected expressions:

**ec2vpc** — direct access without `has()` guard:
```yaml
enableDNSSupport: ${schema.spec.enableDnsSupport}
enableDNSHostnames: ${schema.spec.enableDnsHostnames}
```
When user creates EC2VPC without setting these (ac1-basic-creation test), both fields are
absent → CEL "no such key" → reconciler error → ACK VPC CR never created → Chainsaw timeout.

**ec2subnet** — bare boolean in ternary condition:
```yaml
mapPublicIPOnLaunch: >-
  ${!(... ? true : (schema.spec.restrictPublicIpOnLaunch ? true : ...))}
```
When user omits `restrictPublicIpOnLaunch`, field is absent → evaluating
`schema.spec.restrictPublicIpOnLaunch` in the ternary throws "no such key".

## What was tried

Only one approach was needed:
1. Add `has()` guards before each bare boolean access.

## Fix

**ec2vpc**: Wrap bare boolean access in `has() ? value : false`:
```yaml
enableDNSSupport: '${has(schema.spec.enableDnsSupport) ? schema.spec.enableDnsSupport : false}'
enableDNSHostnames: '${has(schema.spec.enableDnsHostnames) ? schema.spec.enableDnsHostnames : false}'
```
Note: single-quote YAML quoting is required because the ternary expression contains `: ` (colon
space) which YAML misparses as a mapping separator in an unquoted scalar.

**ec2subnet**: Wrap bare boolean access in `has() &&`:
```yaml
mapPublicIPOnLaunch: >-
  ${!(... ? true : ((has(schema.spec.restrictPublicIpOnLaunch) && schema.spec.restrictPublicIpOnLaunch)
      ? true : ...))}
```

## Verification

Locally applied both RGDs → both reached `Active`. Created EC2VPC and EC2Subnet instances
without the optional boolean fields → ACK VPC and ACK Subnet CRs created within 2 seconds.

## CEL/YAML pattern learned

- **Bare boolean fields must ALWAYS be accessed via `has()` guards.** Never use
  `schema.spec.boolField` directly — always `has(schema.spec.boolField) && schema.spec.boolField`
  or `has(schema.spec.boolField) ? schema.spec.boolField : <default>`.
- **Quote ternary CEL expressions that contain `: ` (colon-space) in unquoted YAML scalars.**
  The YAML parser interprets `: ` as a mapping separator. Use single quotes or `>-` block scalar.

## Cross-reference

`docs/frequent-rgd-errors.md` §"Boolean `has()` — Zero-Value Stripping" — confirms that bare
booleans are omitted when user does not set them, and that `has()` is the correct presence check.
