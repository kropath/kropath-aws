---
date: 2026-08-28
ticket: KRO-717
pr: kropath-aws#141
author: Implementer (e9bf59b4)
disclaimer: Point-in-time hypothesis; verify before acting on claims.
---

# ACM Chainsaw tests: kubectl loop hangs cause 6-hour CI timeout

## Symptom

`make test-acm` (runs `chainsaw test acm/ --parallel 4`) was killed by GitHub Actions'
default 6-hour job timeout after 4 consecutive CI failures. The CI log showed this as the
last meaningful output before silence:

```
13:57:24 | acmcertificate | ac8-private-cert-via-ca-ref | CMD | RUN
  === COMMAND
  /usr/bin/sh -c # Wait for kro to create the ACK CertificateAuthority child...
  for i in $(seq 1 30); do
    kubectl get certificateauthorities.acmpca.services.k8s.aws ac8-ca -n acmcertificate 2>/dev/null && break
    sleep 3
  done
```

Six hours of silence followed. The job was killed with orphan processes: `make`, `chainsaw`,
`kubectl` — the `kubectl` command was still running when killed.

## Root cause

Three cross-RGD scenarios seed a child `CertificateAuthority` ACK resource and then poll
until it appears:

| Scenario | File |
|---|---|
| `ac8-private-cert-via-ca-ref` | `tests/acm/acmcertificate/chainsaw-test.yaml` |
| `ac6-root-ca-activation` | `tests/acm/acmprivateca/chainsaw-test.yaml` |
| `ac2-issue-cert-via-ref` | `tests/acm/acmprivatecertificate/chainsaw-test.yaml` |

Each uses a shell loop of the form:

```bash
for i in $(seq 1 30); do
  kubectl get certificateauthorities.acmpca.services.k8s.aws <name> -n <ns> 2>/dev/null && break
  sleep 3
done
```

Without `--request-timeout`, `kubectl get` makes a blocking API call with no server-side
deadline. When the kind cluster's API server becomes unresponsive — which happens under load
from 4 parallel Chainsaw suites all creating cross-RGD resources simultaneously — the
`kubectl get` call hangs indefinitely. The loop never iterates. The script never exits.
Chainsaw never times out the step (the timeout fires on the step's declared timeout, but if
the shell process is stuck, the timeout may not propagate). The GitHub Actions 6-hour wall
clock eventually kills everything.

## Why this didn't fail locally

The local kind cluster runs a single test suite at a time (not 4 in parallel). The API
server is far less loaded, and `kubectl get` responses arrive within milliseconds, so the
loops always exit cleanly.

## Fix applied (commit 9d52988)

Added `--request-timeout=10s` to every `kubectl get` and `kubectl patch` inside loop
scripts across all three affected scenarios:

```bash
for i in $(seq 1 30); do
  kubectl get certificateauthorities.acmpca.services.k8s.aws <name> -n <ns> \
    --request-timeout=10s 2>/dev/null && break
  sleep 3
done
kubectl patch certificateauthorities.acmpca.services.k8s.aws <name> -n <ns> \
  --subresource=status --type=merge --request-timeout=10s \
  -p '...'
```

With this fix:
- If the API server is unresponsive, each `kubectl get` attempt fails within 10 seconds
  (rather than hanging forever)
- The loop retries up to 30 times: worst case ~6.5 minutes (30 × (10s timeout + 3s sleep))
- If the resource genuinely doesn't appear within that window, the loop exits and either the
  patch fails with a clear error or the `exit 1` fires — both are explicit failures rather
  than silent hangs
- The `kubectl patch` also has a hard 10s deadline, preventing a second hang point after
  the loop exits

## Affected files

- `tests/acm/acmcertificate/chainsaw-test.yaml` (3 commands in ac8 step)
- `tests/acm/acmprivateca/chainsaw-test.yaml` (2 commands in ac6 step)
- `tests/acm/acmprivatecertificate/chainsaw-test.yaml` (3 commands in ac2 step)

## Pattern to follow for future cross-RGD scripts

Any `kubectl get`/`kubectl patch`/`kubectl wait` inside a Chainsaw `script:` step that
polls for a child resource MUST include `--request-timeout=<N>s`. Without it, a loaded
CI API server will hang the step indefinitely.
