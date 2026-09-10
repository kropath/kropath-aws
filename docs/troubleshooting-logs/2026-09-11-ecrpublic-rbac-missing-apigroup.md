> **Point-in-time disclaimer:** This log reflects findings as of 2026-09-11. Cluster state,
> RGD versions, and ACK CRD schemas may change. Verify mechanically before acting on this log.

# ECRPublic RBAC: missing `ecrpublic.services.k8s.aws` API group causes state: ERROR

## Symptom

PR #256 CI failed at `make test-ecrpublic` with the AC-1 assert timing out. The
`ecrpublic.services.k8s.aws/v1alpha1/Repository` CR for the test instance was never created
after 5 minutes (Chainsaw AssertTimeout).

Local reproduction:

```bash
kubectl get ecrpublicrepository my-tool -n ecrpublicrepository -o jsonpath='{.status.conditions}'
```

Output (abridged):
```
"message": "resource reconciliation failed: failed to list external collection ackRepositoryRef:
repositories.ecrpublic.services.k8s.aws is forbidden:
User \"system:serviceaccount:kro-system:kro\" cannot list resource \"repositories\"
in API group \"ecrpublic.services.k8s.aws\" in the namespace \"ecrpublicrepository\""
```

## Root cause

`tests/fixtures/rbac/kro-controller.yaml` — the aggregated ClusterRole
`kro:controller-iamidentityprovider` (label `rbac.kro.run/aggregate-to-controller: "true"`) was
missing `ecrpublic.services.k8s.aws` from its `apiGroups` list. It had `ecr.services.k8s.aws`
(private ECR) but not `ecrpublic.services.k8s.aws` (ECR Public).

The ECRPublicRepository RGD uses an always-active `ackRepositoryRef` externalRef to read back
status from the ACK child resource:

```yaml
- id: ackRepositoryRef
  externalRef:
    apiVersion: ecrpublic.services.k8s.aws/v1alpha1
    kind: Repository
    metadata:
      namespace: ${schema.metadata.namespace}
      selector:
        matchLabels:
          app.kubernetes.io/instance: ${schema.metadata.name}
```

kro always evaluates externalRefs regardless of `includeWhen` guards on sibling resources.
Without list/watch RBAC on `ecrpublic.services.k8s.aws`, every reconciliation attempt immediately
returned a 403 and the instance went to `state: ERROR`, preventing the ACK Repository child from
ever being created.

## Fix

Added `ecrpublic.services.k8s.aws` after `ecr.services.k8s.aws` in the apiGroups list in
`tests/fixtures/rbac/kro-controller.yaml`.

## Verification

After applying the fix:

```bash
kubectl apply -f tests/fixtures/rbac/kro-controller.yaml
```

Create a test ECRPublicRepository instance:

```bash
kubectl get ecrpublicrepository my-tool-v2 -n ecrpublicrepository -o jsonpath='{.status.state}'
# → ACTIVE
kubectl get repositories.ecrpublic.services.k8s.aws -n ecrpublicrepository
# → NAME         AGE
# → my-tool-v2   10s
```

Instance reached `state: ACTIVE` and the ACK Repository child was created.

## Pattern for future services

Any new RGD that uses an always-active externalRef against a new ACK API group (e.g.
`newfamily.services.k8s.aws`) MUST add that group to the `apiGroups` list in
`tests/fixtures/rbac/kro-controller.yaml` in the same PR as the RGD.
