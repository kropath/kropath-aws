# DynamoDBTable: Boolean Sentinel has() Bug + Cleanup Hang

**Date:** 2026-08-02
**Issue:** KRO-306 (re-entry after REQUEST CHANGES on PR #68)

## Symptoms

1. AC-7 asserted `sseSpecification.enabled: true` but observed `false`. Instance set `spec.encryption.enabled: true` with no mandatory override.
2. After AC-7 failed, CLEANUP ran `kubectl delete dynamodbtable test-table` and hung for 30+ minutes, blocking CI entirely.

## Root Cause 1: has() Always True for Bare Booleans

The RGD used has() guards on boolean config fields. For bare boolean fields (no | default=false in RGD schema), kubernetes materializes false on every instance. So has(mandatory.encryptionEnabled) when mandatory.encryptionEnabled = false returns true and the ternary resolves to false, short-circuiting before the instance value is ever read.

This affected all three boolean sentinel fields: encryptionEnabled, deletionProtectionEnabled, pointInTimeRecoveryEnabled.

Fix: Replace has()-guarded ternary with OR logic. Any tier being true enables the feature:

  enabled: >-
    ${(rsrcCfg.size() > 0 && rsrcCfg[0].status.effectiveConfig.mandatory.encryptionEnabled)
      || schema.spec.?encryption.?enabled.orValue(false)
      || (rsrcCfg.size() > 0 && rsrcCfg[0].status.effectiveConfig.defaults.encryptionEnabled)}

mandatory false means "not mandated" -- it does not force lower tiers to false. OR semantics are correct for this governance model.

## Root Cause 2: kubectl delete Hang (No ACK Controllers in CI)

ACK controllers are not deployed in the CI cluster -- only CRDs are installed. kro adds kro.run/foreground-deletion finalizer to DynamoDBTable CRs and reconciles child ACK Table CRs. ACK adds finalizers.dynamodb.services.k8s.aws to Table CRs. With no controller to remove the ACK finalizer, deletion blocks forever.

Fix: Strip finalizers from both child table CRs and parent dynamodbtable CRs, then use --wait=false. Pattern from 2026-08-02-snstopic-ci-hang.md -- apply to all ACK-backed resource families.

  for name in $(kubectl get table -n dynamodbtable -o jsonpath='{.items[*].metadata.name}' 2>/dev/null); do
    kubectl patch table "$name" -n dynamodbtable --type=merge -p '{"metadata":{"finalizers":[]}}' 2>/dev/null || true
  done
  kubectl delete table --all -n dynamodbtable --ignore-not-found=true --wait=false
  for name in $(kubectl get dynamodbtable -n dynamodbtable -o jsonpath='{.items[*].metadata.name}' 2>/dev/null); do
    kubectl patch dynamodbtable "$name" -n dynamodbtable --type=merge -p '{"metadata":{"finalizers":[]}}' 2>/dev/null || true
  done
  kubectl delete dynamodbtable --all -n dynamodbtable --ignore-not-found=true --wait=false
  kubectl delete dynamodbconfig general-policy -n dynamodbtable --ignore-not-found=true --wait=false

## Files Changed

- rgds/dynamodbtable.aws.kropath.run.yaml -- fixed 3 boolean sentinel CEL expressions
- tests/dynamodb/dynamodbtable/chainsaw-test.yaml -- updated all 39 cleanup blocks
