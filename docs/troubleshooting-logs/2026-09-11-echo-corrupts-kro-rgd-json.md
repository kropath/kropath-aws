> **Point-in-time disclaimer:** This log captures what was observed and concluded at the time of writing (2026-09-11). It is a field note, not a verified canonical reference. If it conflicts with `docs/frequent-rgd-errors.md` or agent instructions, those sources take precedence.

# 2026-09-11 — POSIX sh `echo` corrupts kro RGD JSON in Chainsaw test scripts

**Ticket:** KRO-887
**Symptom:** `ac8-no-naming-fields` Chainsaw step failed in CI with:
```
ERROR: spec.nameOverride found in OpenSearchVPCEndpoint schema (KRO-236 violation)
```
despite the RGD having no `nameOverride` field in `spec.schema.spec`.

## Root cause

The Chainsaw `- script:` step runs under `/bin/sh` (dash on Ubuntu CI). In POSIX sh, `echo "$VAR"` interprets backslash escape sequences in the variable value. kro RGD JSON serialised by `kubectl get rgd ... -o json` contains CEL expression strings with `\"` (escaped double-quotes), e.g.:

```
"orValue(\"general-policy\")"
```

When passed through `echo`, the backslash sequences are interpreted and stripped, producing corrupt JSON. The corruption causes `json.load(sys.stdin)` to raise `json.JSONDecodeError`. Because the python3 invocation had `2>/dev/null`, the traceback was silenced. python3 exits with code 1 on the exception, which the `if` statement interprets as false — printing the misleading "nameOverride found" error.

## Reproduction

```bash
SCHEMA=$(kubectl get rgd opensearchvpcendpoint.aws.kropath.run -o json)
# Corrupt path (POSIX sh echo):
/bin/sh -c 'echo "$1" | wc -c' -- "$SCHEMA"   # smaller — backslashes stripped
# Safe path (printf):
/bin/sh -c 'printf "%s\n" "$1" | wc -c' -- "$SCHEMA"   # correct byte count
```

## Fix

Replace `echo "$SCHEMA"` and `echo "$STATUS"` with `printf '%s\n' "$SCHEMA"` / `printf '%s\n' "$STATUS"` wherever JSON from a shell variable is piped into python3 or grep in Chainsaw `- script:` steps.

`printf '%s\n'` prints the string literally without interpreting backslash sequences, preserving the JSON for downstream parsers.

## Approaches tried

1. **Direct kubectl pipe** (did not land in prod code, but verified working):
   ```bash
   kubectl get rgd ... -o json | python3 -c "..."
   ```
   Works, but requires re-running kubectl for each check. `printf` is simpler for the existing variable-reuse pattern.

2. **`printf '%s\n' "$VAR"` (chosen fix):** Verified that both the grep and python3 checks pass locally under `/bin/sh`.

## Lesson / pattern to follow

**Never use `echo "$VAR"` to pipe large JSON (especially kro RGD output) into python3 or jq in Chainsaw `- script:` steps that run under POSIX sh.**

Use `printf '%s\n' "$VAR"` instead. This issue can appear silently when `2>/dev/null` hides the `JSONDecodeError`.
