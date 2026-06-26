# Frequent RGD errors

This is a comprehensive post-mortem summary of the syntax, structural, and evaluation issues encountered across the four Kro ResourceGraphDefinition (RGD) manifests, along with the precise engineering resolutions applied to stabilize them.

- `awsiamidentityprovider.kropath.run`
- `awsiampolicy.kropath.run`
- `awsiamrole.kropath.run`
- `awss3bucket.kropath.run`

## 1. Syntax & Formatting Issues (All RGDs)

- **The Issue**: Inline CEL expressions containing conditional operators (? :) or string concatenations (+) were left unquoted in the YAML properties (e.g., name: ${schema.spec.nameOverride != "" ? ...}). The YAML parser saw the structural colons (:) inside the expressions and interpreted them as nested mapping values, throwing yaml: line X: mapping values are not allowed in this context.
- **The Resolution**: Wrapped all inline conditional CEL statements in strict explicit quotes ("..." or '...'), forcing the YAML engine to interpret the block as a single literal string before passing it downstream to the CEL compiler.

## 2. Dynamic Schema Validation & Cross-Controller Dependencies ()

### `awsiamrole.kropath.run`

- **The Issue**: The graph was rejected with cannot resolve group version "eks.services.k8s.aws/v1alpha1": schema not found. Kro strictly checks the existence of every resource's GVK in the cluster API at compilation time. Because the ACK EKS Controller wasn't installed yet, the entire graph was marked Inactive, bypassing the includeWhen conditional block completely.
- **The Resolution**: Identified that Kro requires target CRDs to exist upfront. The issue was resolved by deploying the AWS ACK EKS controller to the cluster, allowing Kro's discovery engine to find the PodIdentityAssociation schema and successfully validate the resource graph topology.

### `awsiampolicy.kropath.run`

- **The Issue**: The compilation failed because awsiamrole listed AWSIAMPolicy under its externalRef resource tree before the awsiampolicy RGD had been applied to register the custom schema.
- **The Resolution**: Established a strict deployment ordering rule (or stubbed with standard core resources like ConfigMaps during bootstrap) to ensure dependent custom resource schemas are applied and discovered by the API server sequentially.

## 3. Complex Computation Offloading in status

- **The Issue**: Heavy string parsing, token extraction via .split(), map addition loops (+), and token replacements (.replace()) were written directly into the custom resource's status fields to evaluate naming status and predict ARNs. This caused runtime lookup issues and graph evaluation instability.
- **The Resolution**: Offloaded the complex parsing entirely by binding the custom resource's status fields to read directly from the natively generated status outputs of the underlying AWS ACK resources (using the safe navigation operator, e.g., ${policy.status.?ackResourceMetadata.?arn.orValue("")}).

## 4. CEL Static Type Engine Mismatches (S3 Bucket)

Kro utilizes a strict, statically typed variant of Google's Common Expression Language (CEL). A recurring compilation blocker on the awss3bucket manifest was:

```log
found no matching overload for '_?_:_' applied to '(bool, SOME_TYPE, null)'
```

This occurred because ternary statements (condition ? value : null) returned a concrete schema type on the true branch but an untyped primitive (null) on the false branch.

### spec.versioning

- **The Issue**: A ternary expression evaluated to a map {"status": ...} on true, and null on false.
- **The Resolution**: Eliminated the type mismatch by ensuring both sides returned a valid map layout, shifting the fallback branch to a clean default state: {"status": "Suspended"}.
  
### spec.encryption

- **The Issue**: Attempted to return a complex nested rule map (map(string, list(map(string, dyn)))) or a null value if encryption wasn't explicitly provided across the config hierarchy.
- **The Resolution**: Stripped the global ternary condition completely. Moved the CEL evaluation logic lower down, directly onto individual string value keys (sseAlgorithm and kmsMasterKeyID), ensuring the overall parent structure remains constant and safely defaults to valid values ("aws:kms" or "").

### spec.createBucketConfiguration

- **The Issue**: Evaluated the region to return a location constraint map object or null for the us-east-1 default region, breaking CEL type matching.
- **The Resolution**: Flattened the object block configuration and pushed the conditional ternary statement directly onto the locationConstraint key string, mapping the default fallback cleanly to an empty string ("").

### spec.publicAccessBlock

- **The Issue**: Wrapped the whole public access configuration block in a ternary check that fell back to null if disabled or unconfigured in the underlying configuration map.
- **The Resolution**: Broken the macro block expression into distinct inline ternary values pinned directly to each individual boolean parameter (blockPublicACLs, blockPublicPolicy, etc.), forcing clean primitive evaluation paths (true : false) that satisfy the compiler.
