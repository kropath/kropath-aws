# KRO-1258: Route53Resolver {tag.X} Dynamic Naming — namingStatus Validation Bug

**Date:** 2026-09-27
**Issue:** KRO-1258 (follow-up bug found during verification)
**Scope:** All 4 Route53Resolver RGDs (`Route53ResolverRuleAssociation`, `Route53ResolverEndpoint`, `Route53ResolverFirewallDomainList`, `Route53ResolverQueryLoggingConfig`)
**Fixed in:** All 4 RGDs during KRO-1258 verification

## Problem

After adding `{tag.fieldName}` dynamic naming template support to Route53Resolver RGDs (part of KRO-1258), the `status.namingStatus` validation was discovered to have a pre-existing logic flaw:

```yaml
# WRONG — cannot detect unresolved tokens
namingStatus: ${effectiveName != "" ? "valid" : "invalid"}
```

**Why it fails:**

When a naming template contains an unresolved `{tag.missingKey}`, the CEL result is a non-empty string like `route53resolver-rule-{tag.missingKey}`. The check `effectiveName != ""` evaluates to `true` (the string is non-empty), incorrectly reporting status as `"valid"` even though tokens are unresolved.

**Correct check per kropath-docs pattern** (see `docs/frequent-rgd-errors.md` and published [Dynamic Tag Fields in Naming Templates](https://github.com/kropath/kropath-docs/blob/main/content/en/docs/concepts/configuration/naming-templates.md)):

```yaml
# CORRECT — detects unresolved tokens
namingStatus: ${effectiveName.contains("{") ? "invalid-unresolved-tokens" : "valid"}
```

**Impact:**

- Affects user workload: users deploying Route53Resolver instances with unresolved tag placeholders would see misleading status `"valid"` instead of `"invalid-unresolved-tokens"`
- Prevents debugging: the status condition would not surface the actual naming error
- Scope: **pre-existing bug predating KRO-1258**; tag-naming support merely exposed it during testing

## Resolution

Changed all 4 Route53Resolver RGDs' status expression from `effectiveName != ""` to `effectiveName.contains("{")` check:

| RGD | File | Change |
|---|---|---|
| Route53ResolverRuleAssociation | `rgds/route53resolverruleassociation.yaml` | Updated status.namingStatus CEL |
| Route53ResolverEndpoint | `rgds/route53resolverendpoint.yaml` | Updated status.namingStatus CEL |
| Route53ResolverFirewallDomainList | `rgds/route53resolverwallfiredomainlist.yaml` | Updated status.namingStatus CEL |
| Route53ResolverQueryLoggingConfig | `rgds/route53resolverqueryloggingconfig.yaml` | Updated status.namingStatus CEL |

## Verification

**Before fix:**
```yaml
# Instance with unresolved tag token
spec:
  namingTemplate: "{tag.environment}-resolver-{name}"
  tags: {}  # missing "environment" tag

# Status WRONG:
status.namingStatus: "valid"  # false negative!
status.resourceName: "resolver-{tag.environment}"
```

**After fix:**
```yaml
# Same instance

# Status CORRECT:
status.namingStatus: "invalid-unresolved-tokens"  # correctly detects the unresolved token
status.resourceName: "resolver-{tag.environment}"
```

## Root cause

The original check (`effectiveName != ""`) was appropriate for resources with no naming concept (e.g., Route53HealthCheck has no name field), but Route53Resolver resources DO support naming templates and `{tag.X}` placeholders. The check should have been updated when tag-naming support was added to ANY RGD.

**Lesson:** When adding `{tag.X}` support to naming templates, audit the corresponding `namingStatus` validation logic on the same RGD. Apply the correct check (`contains("{")`), not the legacy empty-string check.

## Chainsaw impact

Existing Route53Resolver test suites already verify happy-path naming (valid names). This fix ensures that invalid/unresolved-token cases are also caught:

- Add a negative test step: instance with unresolved `{tag.missingKey}` in template must report `status.namingStatus: "invalid-unresolved-tokens"`
- Add a positive test step: instance with tag-naming correctly resolved must report `status.namingStatus: "valid"`

Test structure per canonical pattern (unique name per step, `skipDelete: true`, no inter-step cleanup of ACK children).

## Related resources

- **Pattern reference:** `docs/frequent-rgd-errors.md` § "namingStatus Validation for Unresolved {tag.X} Tokens"
- **Public docs:** [Dynamic Tag Fields in Naming Templates](https://github.com/kropath/kropath-docs/blob/main/content/en/docs/concepts/configuration/naming-templates.md) § Troubleshooting
