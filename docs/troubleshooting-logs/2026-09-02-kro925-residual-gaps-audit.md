> **Point-in-time disclaimer:** This log records what was observed on 2026-09-02 against
> `origin/main` @ `0846d93` and kro v0.9.2 in the `kropath-aws-test` kind cluster. Verify claims
> mechanically before acting on them.

# KRO-925 Residual Gaps: Auditing a Batch Sweep After It Was Closed

**Date:** 2026-09-02
**Issue:** KRO-925 (follow-up after PR #195 merged)

KRO-925 was a batch sweep driven by a checked-in verdict table (`docs/kro-925-verdicts.tsv`).
Batch tickets close on "the PR merged", not on "every row in the table is applied" — so the useful
question after merge is not *did CI pass* but *does the artifact the ticket was scoped against
still have unapplied rows*. Auditing that mechanically found three residual defects.

## Audit 1 — verdict rows vs. rendered templates

Do not grep for `""`. Most hits are validation ConfigMaps where `""` is correct. Parse the RGD,
walk `spec.resources[*].template` for ACK kinds only, and ask **per variant** whether the field's
key is present:

* every variant renders it → the `omit` verdict was **not** applied
* some render, some do not → applied
* the resource is gated so the `""` arm is unreachable → also applied (option 3)

```python
# python3 - <<'PY'   (from repo root)
import csv, os, yaml
def probe(spec, parts):
    cur = spec
    for p in parts:
        if not isinstance(cur, dict):
            return 'opaque'
        if p not in cur:
            return 'absent'
        cur = cur[p]
    return 'present'
for r in csv.DictReader(open('docs/kro-925-verdicts.tsv'), delimiter='\t'):
    if r['verdict'] != 'omit':
        continue
    f = 'rgds/' + r['file']
    if not os.path.exists(f):
        continue
    d = yaml.safe_load(open(f))
    vs = [x['template'].get('spec') or {} for x in d['spec']['resources']
          if x.get('template') and 'services.k8s.aws' in str(x['template'].get('apiVersion', ''))]
    st = [probe(sp, r['field_path'].split('.')[1:]) for sp in vs]
    if st and all(s == 'present' for s in st):
        print('NOT APPLIED:', r['file'], r['field_path'])
# PY
```

Two genuine gaps out of 24 actionable rows:

1. **`dsqlcluster.spec.multiRegionProperties.witnessRegion`** — the `WithWitness`/`NoWitness`
   variant pair was built, and the `NoWitness` variants are selected exactly when
   `witnessRegion == ""` … and then still rendered `witnessRegion: ""`. The variant split was done
   and the field was never removed from the templates it existed to remove it from. **Building the
   variants is not the fix; deleting the key from the negative variant is.**
2. **`acmprivatecertificate.spec.certificateAuthorityARN`** — the resource-level `includeWhen`
   enforced "exactly one of ARN/Ref is set" but not "the referenced CA is resolved", so
   `caRefCr.size() == 0` fell through to `: ""`. Compare `lambdaalias`/`lambdaeventsourcemapping`,
   which gate on `fnCr.size() > 0 && has(fnCr[0].status.resourceName)` and are correct. When option 3
   (whole-resource gating) is the chosen fix, the gate must cover **ref readiness**, not just
   mutual exclusion.

The other 22 rows were correctly applied, including both `default=` rows in `ecrrepository`
(`MUTABLE`, `AES256`), and the four single-variant families whose gate makes the `""` arm
unreachable — those look like gaps to a naive key-presence check and are not.

## Audit 2 — status freeze across the whole repo

The audit script from `docs/frequent-rgd-errors.md` §"Variant-Split Resources Freeze Combined Status
Expressions" found one remaining hit, in a family KRO-925 explicitly excluded from scope:

**`snstopic.status.topicArn`** coalesced across six variant names — and the family has **twelve**
variants, so the four FIFO variants were not even represented in the expression. No `SNSTopic` of
any shape has ever reported a `topicArn`. `status.conditions` had a milder form of the same bug: it
named a single variant (`ackTopicNoPolicyNoFeedback`), so eleven of twelve variants produced none.

Both now read the always-bound `ackTopicRef` self-lookup.

**No Chainsaw scenario asserted `topicArn`** (`grep -c topicArn tests/sns/snstopic/chainsaw-test.yaml`
→ 0), which is why twelve variants shipped with a permanently empty field and a green suite. Added
`ac36-topic-arn-propagation`, which patches the ACK child's `status.topicARN` and asserts it reaches
`SNSTopic.status.topicArn`.

## Verified live, not just by the suite

The mock cluster runs no ACK controllers, so `status.topicArn` is empty in a passing suite for the
same reason it was empty when broken. Inject the child status and watch it propagate:

```bash
kubectl patch topic.sns.services.k8s.aws <name> -n snstopic --subresource=status --type=merge \
  -p '{"status":{"topicARN":"arn:aws:sns:us-east-1:123456789012:probe-topic"}}'
kubectl get snstopic <name> -n snstopic -o jsonpath='{.status.topicArn}'
# -> arn:aws:sns:us-east-1:123456789012:probe-topic   (empty before the fix)
```

Propagation took ~15 s (three 5 s polls) — an assert with a short timeout will flake.

## Gotcha: `snstopic` cannot be `kubectl apply`-ed

The file is >144 KB, so client-side apply exceeds the 262144-byte
`kubectl.kubernetes.io/last-applied-configuration` annotation limit:

```
The ResourceGraphDefinition "snstopic.aws.kropath.run" is invalid:
* metadata.annotations: Too long: may not be more than 262144 bytes
```

Use `kubectl apply --server-side --force-conflicts` (already the case in `tests/setup.sh` — see
`docs/troubleshooting-logs/2026-08-31-snstopic-rgd-annotation-size-limit.md`). The RGD compiles gate
in the agent instructions says `kubectl apply`; for `snstopic` and `sqsqueue` it must be server-side.

## Verification

RGD compiles gate on `dsqlcluster`, `acmprivatecertificate`, `snstopic` (all `Active`), then
`test-dsql`, `test-acm`, `test-sns` — all pass locally.

## Related

KRO-932 (the escalated-families follow-up) was audited the same way at the same time and found
**27 of its 49 fields still emitting `""`** via the no-op guard `${x != "" ? x : ""}`; it was
re-opened. A `!= ""` test whose false branch is `""` changes nothing — worth grepping for directly:
`grep -rn '!= "" ? [^:]* : ""' rgds/`.
