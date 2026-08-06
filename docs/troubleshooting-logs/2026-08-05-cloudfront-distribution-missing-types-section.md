# CloudFront Distribution RGD — Missing `types:` Section Caused CI-Wide Timeout

**Date:** 2026-08-05
**Issue:** KRO-443
**PR:** #88

## Symptom

CI `make setup` step timed out waiting for ALL RGDs (including unrelated IAM, S3, DynamoDB, ELB) to
reach `Active` state:

```
timed out waiting for the condition on resourcegraphdefinitions/cloudfrontdistribution.aws.kropath.run
timed out waiting for the condition on resourcegraphdefinitions/iamrole.aws.kropath.run
...
make: *** [Makefile:20: setup] Error 1
```

## Root Cause

`rgds/cloudfrontdistribution.aws.kropath.run.yaml` used 4 custom named types in the schema:
- `CloudFrontOrigin` (in `origins: "[]CloudFrontOrigin"`)
- `CloudFrontFunctionAssociation` (in `functionAssociations: "[]CloudFrontFunctionAssociation"`)
- `CloudFrontCacheBehavior` (in `cacheBehaviors: "[]CloudFrontCacheBehavior"`)
- `CloudFrontCustomErrorResponse` (in `customErrorResponses: "[]CloudFrontCustomErrorResponse"`)

These types were referenced but never defined — no `types:` section existed in the schema block.

When kro loads RGDs on startup it validates all schemas. A schema with undefined named types makes
kro fail to process the RGD — and kro loads all RGDs in the same reconciliation loop, so one
broken RGD blocks all others from reaching `Active`. Hence the cluster-wide timeout in `make setup`.

## What Failed

All 3 Chainsaw test suites (cloudfront, plus existing IAM/DynamoDB/ELB/EventBridge suites)
timed out in setup because no RGD reached Active while kro was stuck on the invalid schema.

## Fix Applied

Added a `types:` block to the schema (between the spec fields and `status:` block), defining all
referenced custom types:

```yaml
    types:
      CloudFrontCustomHeader:
        headerName: string | required=true
        headerValue: string | required=true
      CloudFrontOrigin:
        id: string | required=true
        domainName: string | required=true
        originPath: string | default=""
        connectionAttempts: integer | default=3
        connectionTimeout: integer | default=10
        originAccessControlRef: string | default=""
        originAccessControlID: string | default=""
        customHeaders:
          items: "[]CloudFrontCustomHeader | default=[]"
        s3OriginConfig:
          originAccessIdentity: string | default=""
        customOriginConfig:
          httpPort: integer | default=80
          httpsPort: integer | default=443
          originProtocolPolicy: string | default=""
          originSSLProtocols:
            items: "[]string | default=[]"
        originShield:
          enabled: boolean | default=false
          originShieldRegion: string | default=""
      CloudFrontFunctionAssociation:
        functionARN: string | required=true
        eventType: string | required=true
      CloudFrontCacheBehavior:
        pathPattern: string | required=true
        targetOriginID: string | required=true
        viewerProtocolPolicy: string | default=""
        cachePolicyID: string | default=""
        originRequestPolicyID: string | default=""
        responseHeadersPolicyID: string | default=""
        compress: boolean | default=true
        allowedMethods: "[]string | default=[]"
        cachedMethods: "[]string | default=[]"
        functionAssociations: "[]CloudFrontFunctionAssociation | default=[]"
      CloudFrontCustomErrorResponse:
        errorCode: integer | required=true
        responseCode: integer | default=0
        responsePagePath: string | default=""
        errorCachingMinTTL: integer | default=0
```

## Verification

After the fix, `kubectl apply -f rgds/cloudfrontdistribution.aws.kropath.run.yaml` followed by
`kubectl describe rgd cloudfrontdistribution.aws.kropath.run` shows kro now successfully parses
the schema (moved past `InvalidResourceGraph`). The remaining `Inactive` state locally is only
because `CloudFrontConfig` CRD is not installed in the dev cluster — this is expected and CI's
`make setup` installs it.

## Key Rule

**Every RGD that uses named types in a `"[]TypeName"` list MUST include a `types:` block** defining
every named type. Missing named types cause kro to fail loading ALL RGDs in the cluster, not just
the one with the missing type. Reference: `rgds/dynamodbtable.aws.kropath.run.yaml` line 71.

The `types:` block must appear at the same indentation level as `spec:` and `status:` inside the
`schema:` block, after all spec field definitions.
