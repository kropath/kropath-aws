# Frequent RGD Errors & Solutions Document

This document tracks technical friction points, syntax limitations, and runtime evaluation behaviors discovered while designing, deploying, and locally testing Kro ResourceGraphDefinitions (RGDs). 

---

## 1. Static Schema & Deployment Compilation Issues

### Missing Target Custom Resource Definitions (CRDs)
* **What Fails:** The graph is rejected at apply-time with logs similar to:
    ```log
    failed to build instance status schema: cannot resolve group version "eks.services.k8s.aws/v1alpha1": schema not found
    ```
* **Why:** Kro performs strict static verification of every target resource’s Group, Version, and Kind (GVK) against the live cluster API server during the RGD compilation phase. If a downstream controller (such as an AWS ACK controller) is missing from the cluster, the engine cannot validate the schema layout and marks the entire graph `Inactive`, ignoring any conditional `includeWhen` guards meant to skip that node.
* **What Works Instead:** Ensure all downstream target operator CRDs (e.g., ACK IAM, ACK S3, ACK EKS) are deployed onto the control plane *before* applying the wrapper RGDs, allowing Kro's discovery engine to discover and cache the necessary custom schemas.

### Implicit Cross-Graph Dependency Race Conditions
* **What Fails:** Applying a dependent RGD (e.g., `iamrole.aws.kropath.run`) fails at compilation because it references a separate, unapplied custom graph resource (e.g., `AWSIAMPolicy`) in its `externalRef` collection.
* **Why:** Kro's dependency engine tracks custom wrapper resources identically to native core resources. If the API server has no definition for a custom kind during initialization, the RGD validation hook fails.
* **What Works Instead:** Establish a strict ordering topology for bootstrapping clusters (e.g., apply base type definitions like `iampolicy` and `awsfooconfig` before high-level wrappers like `iamrole`). Alternatively, stub dependencies with primitive native resources like `ConfigMaps` during rapid local prototyping phases.

---

## 2. Common Expression Language (CEL) Type Engine Mismatches

### Strict Ternary Type Alignment
* **What Fails:** Compilation aborts with type mismatches when assigning block structures via inline conditionals:
    ```log
    found no matching overload for '_?_:_' applied to '(bool, SOME_TYPE, null)'
    ```
* **Why:** Kro utilizes a strictly typed subset of Google's Common Expression Language (CEL). A conditional statement (`condition ? true_expr : false_expr`) requires both resulting evaluation paths to yield identical, concrete schema layouts. Returning a custom structural map object on the true branch and an untyped primitive `null` on the false branch triggers a static type validation error.
* **What Works Instead:** Align both evaluation paths to return structurally identical data types. Fallback to default block states with safe primitive primitives rather than omitting the block via `null`.
    * *Example (Versioning Map):* `${schema.spec.versioningEnabled ? {"status": "Enabled"} : {"status": "Suspended"}}`

### Monolithic Object Gating via Ternary Loops
* **What Fails:** Wrapping complex configurations (such as an S3 public access block, location constraint, or multi-nested encryption tree) inside a macro ternary logic that switches between an entire populated map structural type and `null`.
* **Why:** The static analyzer cannot cleanly reconcile complex nested runtime types against a zero-value primitive across dynamic configuration trees.
* **What Works Instead:** Deconstruct the structural mapping entirely. Keep the parent schema structures constant and map individual, primitive conditional expressions directly down to leaf keys.
    * *Example (Public Access Properties):*
        ```yaml
        spec:
          blockPublicAcls: '${schema.spec.publicAccessBlockEnabled ? schema.spec.blockPublicAcls : true}'
          blockPublicPolicy: '${schema.spec.publicAccessBlockEnabled ? schema.spec.blockPublicPolicy : true}'
        ```
    * *Example (Location Constraint Str):*
        ```yaml
        locationConstraint: '${schema.spec.region != "us-east-1" ? schema.spec.region : ""}'
        ```

---

### List Concatenation Uses the `+` Operator — kro's CEL Has No `.concat()`

* **What Fails:** Appending one list to another with a `.concat()` method call. kro's CEL environment does **not** register a `concat` function, so the RGD never compiles:
    ```yaml
    # ❌ RGD stays Inactive — kro rejects it at validation time
    attributes: >-
      ${schema.spec.additionalAttributes.map(a, {"key": a.key, "value": a.value})
        .concat(schema.spec.stickiness.type != ""
          ? [{"key": "stickiness.enabled", "value": schema.spec.stickiness.enabled ? "true" : "false"}]
          : [])}
    ```
  The RGD's `Ready`/`GraphAccepted` condition reports:
    ```
    failed to validate resource "tg": failed to compile template expression "...": ERROR: <input>:2:10: undeclared reference to 'concat' (in container '')
    Reason: InvalidResourceGraph
    State:  Inactive
    ```

* **Why it is dangerous:** An `Inactive` RGD is silent in normal use, but the CI `setup` step waits for **every** RGD to become `Ready` (`kubectl wait ... --for=condition=... resourcegraphdefinition --all`). One RGD stuck `Inactive` makes that wait **time out**, and — because the wait is over all RGDs at once — the failure log lists *every* RGD as "timed out waiting for the condition", masking which one is actually broken. The real culprit is only visible via `kubectl describe rgd <name>` → look for `Reason: InvalidResourceGraph`. Symptom seen in CI: `make: *** [Makefile:20: setup] Error 1` with a wall of unrelated-looking RGD timeouts.

* **What Works Instead:** Use the CEL `+` operator, which concatenates lists (and works for the nested case too):
    ```yaml
    # ✅ compiles; RGD reaches Active
    attributes: >-
      ${schema.spec.additionalAttributes.map(a, {"key": a.key, "value": a.value})
        + (schema.spec.stickiness.type != ""
          ? ([{"key": "stickiness.enabled", "value": schema.spec.stickiness.enabled ? "true" : "false"},
              {"key": "stickiness.type", "value": schema.spec.stickiness.type}]
             + (schema.spec.stickiness.durationSeconds != ""
               ? [{"key": "stickiness.lb_cookie.duration_seconds", "value": schema.spec.stickiness.durationSeconds}]
               : []))
          : [])}
    ```
  Note: `+` concatenates *positionally* — it does **not** deduplicate keys. For cross-tier tag/label maps where later tiers must overwrite earlier ones, do **not** use `+` on transformed lists; merge maps first and `.transformList()` last (see "Cross-Tier Tag/Label Merge — Prefer Map Merge Over List Concatenation" in §4). Use `+` only when you genuinely want to append list segments that carry no key-uniqueness contract (e.g. folding optional stickiness attributes onto a passthrough attribute list).

* **First move when an RGD is `Inactive`:** `kubectl describe rgd <name>.aws.kropath.run` and read the `GraphAccepted`/`Ready` condition `Message` — it quotes the exact CEL expression and column where compilation failed. Do not trust the CI "timed out on all RGDs" wall; describe the RGDs to find the one with `InvalidResourceGraph`.

---

## 3. Top-Level Status Scoping Constraints

### Scope Tracking of `schema` and `instance` Tokens
* **What Fails:** Referencing `schema.spec.<field>` or `instance.spec.<field>` inside the top-level `status:` mapping tree results in an active validation freeze:
    ```log
    failed to build instance status schema: status field "predictedArn" expression "...": references unknown identifiers: [schema] (or [instance])
    ```
* **Why:** The `status:` block of a Kro `ResourceGraphDefinition` is strictly isolated from evaluating incoming user configuration specs directly. The engine design restricts this block's lookup scope exclusively to extracting data fields generated by active runtime DAG resources.
* **What Works Instead:** Utilize safe navigation operators directly on target resource outputs to read live fields generated dynamically by underlying destination operator engines.
    * *Example:* `${role.?status.?ackResourceMetadata.?arn.orValue("")}`

### Cross-Resource Condition Appending
* **What Fails:** Combining conditions from distinct, split resource paths into a uniform list field using conditional branches or inline collection lambdas:
    ```log
    references unknown identifiers: [c c c c...] # When using transformList
    OR
    found no matching overload for '_?_:_' applied to (bool, list(__type_A), list(__type_B))
    ```
* **Why:** Kro assigns unique internal data types to every unique structural ID declaration in the DAG graph. Even when both targets emit matching structures (like an array of standard Kubernetes condition items), the static compiler flags them as incompatible structures and blocks efforts to merge or switch them within a single array field. Additionally, macro list comprehension variables are dropped by the status compiler during layout mapping stages.
* **What Works Instead:** Isolate custom sub-resource status metrics into individual status tracker properties to completely decouple structural types from cross-contaminating validation paths.
    * *Example:*
        ```yaml
        status:
          roleWithTrustConditions: >-
            ${roleWithTrustRef.?status.?conditions.orValue([])}
          roleWithDefaultTrustConditions: >-
            ${roleWithDefaultTrust.?status.?conditions.orValue([])}
        ```

---

## 4. Troubleshooting: Runtime Validation & Testing Errors

### The `has()` Macro Traps
* **What Fails:** * Evaluating array elements via macro boundaries: `has(trustDoc[0].spec)`
    * Evaluating raw, top-level DAG task references: `has(trustDoc)`
    ```log
    invalid argument to has() macro
    ```
* **Why:** The CEL specification treats the `has()` macro as a static lookup explicitly designed to determine if an optional property is present on an active object map (e.g., `has(schema.spec.myField)`). Passing collection arrays, specific array indices, or un-nested graph resource descriptors violates this foundational language grammar.
* **What Works Instead:** * To safely inspect an index element, use safe-navigation chained to a default value: `trustDoc[0].?spec.orValue(null) != null`
    * To inspect the creation state of an `externalRef` collection list, look at the size of the array directly: `trustDoc.size() > 0`

### `has(parent)` Does Not Guarantee `parent.child` — Guard the Leaf You Actually Index

* **What Fails:** A guard proves the *parent* map exists, then the expression indexes a *child* key that does not:
    ```cel
    has(rsrcCfg[0].status.effectiveConfig.mandatory)
      && part in rsrcCfg[0].status.effectiveConfig.mandatory.syncedLabels
    ```
    ```log
    node "naming": failed to evaluate expression: ... no such key: syncedLabels (data pending)
    ```
    The instance stalls in `IN_PROGRESS` forever — no child resource is ever created, and the RGD itself stays `Active`, so nothing in `kubectl get rgd` points at the problem.
* **Why:** `has()` is a *presence* check on exactly the path it is given. `has(x.mandatory)` says nothing about `x.mandatory.syncedLabels`. The `in` operator then evaluates its right-hand side eagerly, and indexing an absent key on a present map is a hard CEL error, not a false. This is especially treacherous in a fall-through chain: the guard reads as if it protects the whole branch, but it only protects the first hop.
* **What Works Instead:** Guard the leaf with safe navigation and a typed default, so a missing key degrades to an empty map instead of throwing:
    ```cel
    part in rsrcCfg[0].status.effectiveConfig.mandatory.?syncedLabels.orValue({})
    ```
    **Audit every branch, not just the one that fired.** In KRO-903 the same construct appeared four times per RGD — `mandatory.syncedLabels`, `mandatory.syncedAnnotations`, `defaults.syncedLabels`, `defaults.syncedAnnotations` — and was copy-pasted into **66 RGDs**. Only one branch failed in the field; the other three were live landmines waiting on a different tenant config.
* **Why it stayed hidden:** The failure needs *both* a `{tag.X}` token whose key misses the earlier `mandatory.tags` branch *and* a config tier lacking `syncedLabels`. A tenant whose `namingTemplate` has no `{tag.}` token (e.g. `{namespace}-{name}-{account_id}`) never enters the branch and looks perfectly healthy — so a single passing tenant is not evidence the expression is safe. When a governance chain has fall-through tiers, test a config that omits an intermediate tier, not only fully-populated ones.

### The Unbound Variable Freeze
* **What Fails:** Referencing a conditionally excluded task variable name inside a shared resource template block:
    ```yaml
    assumeRolePolicyDocument: ${schema.spec.trustPolicyRef != "" ? trustDoc[0].spec.documentJSON : schema.spec.trustPolicyJSON}
    ```
* **Why:** When a graph task fails its `includeWhen` condition, Kro deletes that resource reference from the active memory context for that reconciliation loop iteration. Even though ternary strings support execution-time short-circuiting, Kro’s initialization pass validates all mentioned tokens. Encountering the uninitialized label `trustDoc` triggers an immediate runtime exception (`no such variable: trustDoc`), silently halting the entire instance reconciliation loop.
* **What Works Instead:** **The Sentinel Fallback Selector:** Eliminate the `includeWhen` directive to ensure the variable is always initialized in memory. Instead, use an inline conditional operator directly inside the task's label selector field to fetch a dummy value if the target property is missing. This guarantees the variable resolves safely to an empty bound collection (`[]`) rather than dropping out of memory completely.
    * *Example:*
        ```yaml
        - id: trustDoc
          externalRef:
            apiVersion: kropath.run/v1alpha1
            kind: PolicyDocument
            metadata:
              namespace: ${schema.metadata.namespace}
              selector:
                matchLabels:
                  aws.kropath.run/resource-name: ${schema.spec.trustPolicyRef != "" ? schema.spec.trustPolicyRef : "kro-empty-fallback-sentinel"}
        ```

### Variant-Split Resources Freeze Combined Status Expressions — Use an Always-Bound Self-Lookup

* **What Fails:** An RGD splits one ACK child into several mutually exclusive `includeWhen`
  variants (the standard way to *omit* an optional field rather than send `""`), and the `status:`
  block coalesces across them:
    ```yaml
    - id: clusterWithKms      # includeWhen: KMS configured
    - id: clusterNoKms        # includeWhen: no KMS
    status:
      arn: >-
        ${clusterWithKms.?status.?ackResourceMetadata.?arn.orValue("") != ""
          ? clusterWithKms.status.ackResourceMetadata.arn
          : clusterNoKms.?status.?ackResourceMetadata.?arn.orValue("")}
    ```
  The instance reconciles, the ACK child is created and healthy, and `status` comes back **`{}`** —
  the field is never written and there is no error anywhere. Chainsaw reports
  `* status.arn: Required value: field not found in the input object` after a full assert timeout.

* **Why:** Exactly one variant is ever included, so at least one of the names in that expression is
  always excluded. This is the [Unbound Variable Freeze](#the-unbound-variable-freeze) applied to the
  `status:` block: kro's initialization pass sees a token that is not in the active memory context and
  **skips the whole field** — silently, per field, rather than raising. CEL ternary short-circuiting does
  not save you; the token only has to be *mentioned*. The trap is worse than in a `template:` block
  because nothing fails loudly: the resource still reaches `ACTIVE`.

* **Blast radius is cross-RGD.** A consumer RGD that reads the producer's `status.<field>` via
  `externalRef` inherits the empty value and passes `""` to its own ACK child. In KRO-925 this made
  `APIGatewayAuthorizer` send `spec.restAPIID: ""` and made `EFSAccessPoint`/`EFSMountTarget` fail,
  none of which touch the variant-split RGD themselves.

* **What Works Instead — the always-bound self-lookup.** Add an `externalRef` that looks the RGD's
  **own** ACK child up by the `app.kubernetes.io/instance` label every variant already sets. An
  `externalRef` is never excluded — it resolves to `[]` until the child exists — so status keeps
  **one stable field per value** no matter which variant fired, and consumers keep reading one name:
    ```yaml
    resources:
      # Always-bound lookup of this instance's own ACK child.
      - id: ackClusterRef
        externalRef:
          apiVersion: dsql.services.k8s.aws/v1alpha1
          kind: Cluster
          metadata:
            namespace: ${schema.metadata.namespace}
            selector:
              matchLabels:
                app.kubernetes.io/instance: ${schema.metadata.name}
    status:
      arn: >-
        ${ackClusterRef.size() > 0 ? ackClusterRef[0].?status.?ackResourceMetadata.?arn.orValue("") : ""}
    ```
  Guard every access with `.size() > 0` ([Empty External Reference Index Crash](#the-empty-external-reference-index-crash)).
  This works because all variants render the same `metadata.name` and the same
  `app.kubernetes.io/instance` label, and the `externalRef` is scoped by `apiVersion` + `kind` +
  namespace, so it can only match this instance's own child. It also collapses `forEach` blocks that
  were duplicated per variant purely to reference `rootResourceID` (see `rgds/apigatewayrestapi.aws.kropath.run.yaml`).

* **Do NOT split the status field per variant** (`restApiId` + `noPolicyRestApiId`,
  `arn` + `noKmsArn`, …). It compiles and each field does populate, but it leaks graph-internal
  variant structure into the public CRD status, and every consumer must remember to coalesce — miss
  one and you get a silent `""`. That is precisely how KRO-925 shipped a broken
  `APIGatewayAuthorizer` while `APIGatewayDeployment` was fixed. Per-variant `*Conditions` fields are
  the one acceptable exception: `conditions` is a list that genuinely differs per variant and has no
  cross-RGD consumers.

* **Building the variants is not the fix — deleting the key is.** KRO-925 shipped `dsqlcluster`
  with a `WithWitness`/`NoWitness` variant pair where the `NoWitness` variants — selected precisely
  when `witnessRegion == ""` — still rendered `witnessRegion: ""`. The split existed; the field was
  never removed from the templates the split was created to remove it from. After adding a negative
  variant, assert the key is **absent** from it.

* **When you gate the whole resource instead (option 3), the gate must cover ref *readiness*.**
  `lambdaalias` is correct: `includeWhen: ${fnCr.size() > 0 && has(fnCr[0].status.resourceName)}`
  makes the `: ""` arm unreachable. `acmprivatecertificate` was not: its gate enforced "exactly one
  of ARN/Ref is set" but not "the referenced CA resolved", so an unresolved `caRefCr` fell through
  to `""`. Mutual-exclusion validation is not readiness validation.

* **A `!= ""` test whose false branch is `""` guards nothing.** `${schema.spec.x != "" ? schema.spec.x : ""}`
  is a no-op that renders `x: ""` in exactly the case it looks like it prevents. 27 fields shipped in
  this shape under KRO-932. Grep for it directly: `grep -rn '!= "" ? [^:]* : ""' rgds/`.

* **How to audit an RGD for this:** any `status:` expression naming **more than one** `includeWhen`-gated
  resource id is broken. Mechanical check:
    ```python
    # python3 - <<'PY'  (run from the repo root)
    import re, glob, yaml
    for f in glob.glob('rgds/*.yaml'):
        d = yaml.safe_load(open(f))
        gated = {r['id'] for r in d['spec']['resources'] if 'includeWhen' in r}
        for k, v in (d['spec']['schema'].get('status') or {}).items():
            if not isinstance(v, str):
                continue
            hit = {g for g in gated if re.search(r'\b' + re.escape(g) + r'\b', v)}
            if len(hit) > 1:
                print(f, k, '->', sorted(hit))
    # PY
    ```
  A green Chainsaw suite is **not** evidence the RGD is clean — the field only fails when a test both
  exercises a non-first variant *and* asserts that status field. Seven of the eight RGDs found by this
  check in KRO-925 had passing suites.

### The Cold-Start "Missing Key" Crash (Chainsaw / Mock Testing)
* **What Fails:** Running validation workflows on uninitialized instances crashes early with:
    ```log
    Failed to evaluate expression: eval "schema.spec.configRef": no such key: spec (data pending)
    ```
* **Why:** During initial processing loops, Kro scans graph properties before defaults have fully populated the underlying context. Direct, unguarded path mapping (`schema.spec.field`) forces an execution panic before default configurations catch up.
* **What Works Instead:** Guard the entry logic by prefixing `includeWhen` filters with explicit schema validation properties, and implement safe-navigation fallbacks.
    * *Example:* `includeWhen: ['${has(schema.spec) && has(schema.spec.field) && schema.spec.field != ""}']`

### The Kubernetes Garbage Collector Vanishing Act
* **What Fails:** Resources report successful generation states and show `ACTIVE` in Kro logs, but querying the raw downstream objects via `kubectl` returns completely empty results.
* **Why:** This occurs if the `ownerReferences` map uses dynamic parameter evaluation that omits the core API Group suffix:
    ```yaml
    apiVersion: ${schema.apiVersion} # Resolves to 'v1alpha1' instead of 'kropath.run/v1alpha1'
    kind: ${schema.kind}
    ```
    The cluster API server treats these resources as orphaned from their real parent graph controllers. The built-in Kubernetes garbage collection loop instantly prunes and deletes these objects from `etcd` the millisecond they are generated.
* **What Works Instead:** Hardcode explicit, fully qualified API Group/Version keys directly inside your resource tracking templates.
    ```yaml
    ownerReferences:
      - apiVersion: kropath.run/v1alpha1
        kind: IAMRole
    ```

### Schema Evolution Blockades
* **What Fails:** Refactoring layout elements or mutating the structure of the `status` schema block blocks future updates with:
    ```log
    cannot update CRD awsiamroles.kropath.run: breaking changes detected
    ```
* **Why:** Kro applies OpenAPI schema preservation rules to block changes that could potentially orphan or corrupt live managed instances across the control plane.
* **What Works Instead:** During active local development, refactoring, or mock execution testing, explicitly purge the generated structural layout schemas completely before pushing update changes to the cluster.
    ```bash
    kubectl delete rgd iamrole.aws.kropath.run
    kubectl apply -f rgd.yaml
    ```

### The Empty External Reference Index Crash

* **What Fails:** The resource reconciliation loop stalls indefinitely in an `IN_PROGRESS` state, logging an array lookup failure:
    ```log
    failed to evaluate expression: eval "... rsrcCfg[0].?status...": index out of bounds: 0 (data pending)
    ```
* **Why:** When an `externalRef` block queries the Kubernetes API via label selectors, a query returning no matches doesn't fail compilation or throw a missing variable error. Instead, Kro initializes the variable as an empty array (`[]`). Attempting to explicitly pull index zero (`myVar[0]`) out of an empty list triggers a runtime boundary panic.
* **What Works Instead:** Ensure that the underlying infrastructure config mapping or prerequisite resource is applied to the cluster namespace with the exact matching label schema defined by the selector. If the reference is optional, guard the usage in templates by checking `myVar.size() > 0` before attempting to access its properties.

### Cold-Start Array Boundaries and Nested Field Exceptions inside Macro Blocks

* **What Fails:** The resource reconciliation loop logs vague index or evaluation errors inside templates during initial asynchronous data lookups or when downstream config keys are omitted:
    ```log
    failed to evaluate expression: eval "... rsrcCfg[0].?status...": index out of bounds: 0 (data pending)
    ```
* **Why:** This occurs due to two interconnected engine behaviors:
    1. **The Data-Pending Phase:** When an `externalRef` dependency graph node is in a cold-start or `(data pending)` state, its collection variable initializes as an empty array (`[]`). Direct access to an index (`myArray[0]`) triggers a runtime boundary panic *before* any safe-navigation operators (`.?`) or `.orValue()` wrappers can evaluate.
    2. **The `has()` Macro Limitation:** The `has()` macro is compiled statically and does not insulate expression bodies from index bounds panics. Writing `has(rsrcCfg[0].status.field)` will still crash if `rsrcCfg` is an empty list.
    3. **Deep Chained Maps:** Chaining deep safe-navigation paths inside complex macro iterators (like `.transformMapEntry()` or `.transformList()`) can destabilize if a parent key exists but a targeted leaf property is omitted from the upstream resource layout.

* **What Works Instead:** Intercept the execution path using CEL's standard short-circuiting operator rules (`&&`). Prefix every field lookup or loop structure by asserting that the collection size is non-zero *before* allowing the evaluator to touch index zero. If the field is missing or data is pending, return an explicit empty data primitive (`{}`, `[]`, `""`, or a fallback integer) to keep processing streams uniform until the graph settles.

    * *Pattern for Labels / Annotations Maps:*
      ```yaml
      .merge((rsrcCfg.size() > 0 && has(rsrcCfg[0].status.effectiveConfig.mandatory.syncedLabels)) ? rsrcCfg[0].status.effectiveConfig.mandatory.syncedLabels.transformMapEntry(k, v, {"kropath.run/" + k: v}) : {})
      ```
    * *Pattern for Lists / Tags:*
      ```yaml
      + ((rsrcCfg.size() > 0 && has(rsrcCfg[0].status.effectiveConfig.mandatory.tags)) ? rsrcCfg[0].status.effectiveConfig.mandatory.tags.transformList(k, v, {"key": k, "value": v}) : [])
      ```
    * *Pattern for String / Primitive Scalars:*
      ```yaml
      permissionsBoundary: '${rsrcCfg.size() > 0 && has(rsrcCfg[0].status.effectiveConfig.mandatory.permissionsBoundaryArn) ? rsrcCfg[0].status.effectiveConfig.mandatory.permissionsBoundaryArn : ""}'
      ```

### String Template Substitution with `.replace()`

* **What Works:** kro's CEL runtime (cel-go) includes the `strings` extension, so `.replace(old, new)` is available as a method on string values. Use it to substitute named placeholders in naming templates:
    ```yaml
    name: >-
      ${template
        .replace("{namespace}", schema.metadata.namespace)
        .replace("{name}", schema.metadata.name)
        .replace("{account_id}", accountId)}
    ```
  After substituting all known tokens, check for leftover `{` to detect invalid tokens: `result.contains("{") ? "invalid-unresolved-tokens" : ""`

---

### Boolean Field Presence Check (`has()`) Broken by CRD Defaults

* **What Fails:** Using `has(schema.spec.booleanField)` to detect whether the user explicitly set a boolean field fails silently when the field has `| default=false` in the RGD schema. The field always appears as `false` in the stored object, so `has()` always returns `true`.
* **Why:** When the RGD schema declares `myField: boolean | default=false`, kro generates a CRD with `default: false` in the OpenAPI schema. Kubernetes auto-populates `myField: false` on every created resource even when the user omitted it.
* **What Works Instead:** Declare optional boolean flags WITHOUT a default — use `myField: boolean` (no `| default=false`). kro omits `default` from the generated CRD, Kubernetes leaves the field absent when not specified, and `has()` works correctly:
    ```yaml
    # RGD schema — no | default=false
    addSsmPolicy: boolean

    # CEL cascade: mandatory wins, then explicit spec, then config defaults
    (rsrcCfg.size() > 0 && has(rsrcCfg[0].status.effectiveConfig.mandatory.addSsmPolicy) && rsrcCfg[0].status.effectiveConfig.mandatory.addSsmPolicy) ||
    (has(schema.spec.addSsmPolicy) && schema.spec.addSsmPolicy) ||
    (!has(schema.spec.addSsmPolicy) && rsrcCfg.size() > 0 && has(rsrcCfg[0].status.effectiveConfig.defaults.addSsmPolicy) && rsrcCfg[0].status.effectiveConfig.defaults.addSsmPolicy)
    ```

### Boolean Cascade Cannot Disable a Default-True Flag (kro v0.9.2 Zero-Value Stripping + OR-Logic)

* **What Fails:** A spec acceptance criterion asks that an instance's explicit `false` override a governance `defaults.<flag>: true` (e.g. `defaults.deletionProtectionEnabled: true`, instance `spec.deletionProtectionEnabled: false` → ACK Table `false`). The RGD cannot honour it — the flag stays `true`.
* **Why:** kro v0.9.2 strips zero-value booleans from the stored instance spec, so an explicit `false` is byte-for-byte indistinguishable from "field unset". The only cascade that survives this is OR-logic:
    ```cel
    ${(rsrcCfg.size() > 0 && rsrcCfg[0].status.effectiveConfig.mandatory.<flag>)
      || schema.spec.?<flag>.orValue(false)
      || (rsrcCfg.size() > 0 && rsrcCfg[0].status.effectiveConfig.defaults.<flag>)}
    ```
  OR can only **add or strengthen** a flag. When `defaults.<flag>` is already `true`, the whole expression is `true` regardless of the instance value — there is no way for the instance to force `false`.
* **What Works Instead:** Accept the limitation. A tri-state boolean is not representable end-to-end in kro v0.9.2. Test only the achievable direction — instance turns a flag **ON** when defaults leaves it off — and document the deviation in both the test fixture and the spec note. If genuine explicit-disable is required, the field must be modelled as a string enum (`""` / `"true"` / `"false"`) rather than a bare boolean, so the "unset" state is a non-zero value that kro preserves.
* **Reference:** `tests/dynamodb/dynamodbtable/chainsaw-test.yaml` step `ac11-instance-deletion-protection-enable-over-default-off`.

### Chainsaw Inter-Step State Pollution via `--type=merge {}` (No-Op)

* **What Fails:** A later chainsaw step patches `mandatory.tags: {}` via `--type=merge` to clear tags set by a previous step. The tags still appear in the cloud resource's `spec.tags`:
    ```
    * spec.tags: Invalid value: [{"key":"cost-centre","value":"platform"},{"key":"environment","value":"production"}]: lengths of slices don't match
    ```
* **Why:** JSON merge patch (RFC 7396) merges objects recursively. Patching a map field with `{}` means "merge empty into existing" — a complete no-op. Keys set by earlier steps survive unchanged across the entire test run.
* **What Works Instead:** Before re-patching `effectiveConfig`, first null it out:
    ```bash
    kubectl patch iamconfig general-policy -n default --subresource=status --type=merge \
      -p '{"status":{"effectiveConfig":null}}'
    kubectl patch iamconfig general-policy -n default --subresource=status --type=merge \
      -p '{"status":{"effectiveConfig":{"mandatory":{...},"defaults":{...},"aws":{...}}}}'
    ```
  Setting a field to `null` in JSON merge patch removes it. The second patch adds it fresh with exactly the desired values. Apply this two-command pattern to every step that needs a clean effective config slate.

---

### Chainsaw `cleanup:` Blocks Run at End-of-File — Reused Resource Names Need Explicit Pre-Cleanup

> **Superseded** by §"CANONICAL: Unique-Name-Per-Step + `skipDelete`". Reusing a resource
> name across steps is the root problem this documents a workaround for; give each step a
> unique name and delete nothing between steps instead. Kept for historical context.

* **What Fails:** A step (e.g. `ac22-composite-key-schema`) applies a new manifest for a resource name reused across many steps (e.g. `test-table`), and the child resource's `spec` ends up **completely empty** (`spec: {}`), not merely wrong:
    ```
    * spec.(length(keySchema)): Invalid value: 1: Expected value: 2
    --- expected
    +++ actual
      spec: {}
    ```
* **Why:** Chainsaw's `cleanup:` blocks are deferred to the **end of the entire test file** (run in reverse step order), not immediately after each step. The previous step's object (with a different shape — e.g. a single-attribute `keySchema`) is still present when the next step's `kubectl apply` runs. `apply` performs a merge/strategic patch against the existing object, not a full replace; when the new manifest's shape doesn't line up with the stale object's shape, kro's CEL evaluation can bail out entirely, leaving the child resource's `spec` empty rather than partially wrong. This is the same deferred-cleanup timing already documented for **config CRs** in "Chainsaw Seed Steps Must Delete-Then-Create Config CRs" below — this entry covers the same root cause for **any** resource CR (not just config) whose name is reused across steps.
* **What Works Instead:** Add an explicit pre-cleanup `script:` step at the start of every step's `try:` block that reuses a resource name from a prior step, deleting (with finalizers stripped first) both the child ACK CR and the parent kro-managed CR before applying the new manifest:
    ```yaml
    try:
      - script:
          content: |
            for name in $(kubectl get table -n dynamodbtable -o jsonpath='{.items[*].metadata.name}' 2>/dev/null); do
              kubectl patch table "$name" -n dynamodbtable --type=merge -p '{"metadata":{"finalizers":[]}}' 2>/dev/null || true
            done
            kubectl delete table --all -n dynamodbtable --ignore-not-found=true
            for name in $(kubectl get dynamodbtable -n dynamodbtable -o jsonpath='{.items[*].metadata.name}' 2>/dev/null); do
              kubectl patch dynamodbtable "$name" -n dynamodbtable --type=merge -p '{"metadata":{"finalizers":[]}}' 2>/dev/null || true
            done
            kubectl delete dynamodbtable --all -n dynamodbtable --ignore-not-found=true
      - apply:
          file: 01-general-policy.yaml
    ```
* **Rule:** Once one step in a long chainsaw suite hits this (proven by fixing it and having the *very next* step fail identically), assume **every** subsequent step that reuses the same resource name needs the same pre-cleanup block — fix all of them proactively rather than one at a time as each fails.
* **Reference:** `docs/troubleshooting-logs/2026-08-03-dynamodbtable-ac22-ac39-stale-state-and-kro-ratelimiter.md`.

---

### YAML 1.1 Boolean Coercion of Single-Letter/Word Field Values (the "Norway Problem")

* **What Fails:** A test fixture sets a single-letter or single-word field value that happens to be a YAML 1.1 boolean literal, e.g. DynamoDB's `attributeType: N` (the "Number" type code):
    ```
    * spec.attributeDefinitions[0].attributeType: Invalid value: "boolean": must be of type string: "boolean"
    ```
* **Why:** YAML 1.1 parsers (used by `kubectl`/client-go) treat bare, unquoted `y`/`Y`/`yes`/`n`/`N`/`no`/`on`/`off`/`true`/`false` (and case variants) as booleans. `N` is silently coerced to boolean `false` before the value ever reaches the Kubernetes API server, which then rejects it against the CRD's `type: string` schema.
* **What Works Instead:** Always quote such values: `attributeType: "N"`.
* **Rule:** Any field whose valid values include a bare single letter or word that collides with a YAML 1.1 boolean literal (`attributeType: S`/`N`/`B`, or similar single-token enums elsewhere) must be quoted in every test fixture and RGD example — do not rely on the value "looking obviously like a string" to a human reader.

---

### kro Dynamic-Controller Rate Limiter Compounds Backoff Under Rapid Test Churn

> **Superseded** by §"CANONICAL: Unique-Name-Per-Step + `skipDelete`". The backoff only
> compounds because every step reuses the *same* object key; unique names per step give
> each object a fresh key and eliminate the accumulation without tuning kro's rate limiter.
> Kept for historical context.

* **What Fails:** Chainsaw asserts intermittently see `actual resource not found` on objects that should already exist, and `kubectl delete` / cleanup phases take minutes instead of seconds — worsening the more test runs are executed against the same long-lived cluster.
* **Why:** kro's dynamic-controller workqueue applies a **per-object-key** (`namespace/name`) exponential-backoff rate limiter, defaulting to `min-delay=200ms` / `max-delay=1000s` — correct for production AWS reconciliation (where backing off for minutes avoids hammering a degraded cloud API), but actively harmful for chainsaw suites that create/delete/patch the *same-named* resource dozens of times per run. Any transient "dependency not ready yet" condition trips the backoff for that object key, and consecutive trips compound (`200ms × 2ⁿ`, capped at 1000s) since every step in the suite reuses the same resource name. `KRO_DYNAMIC_CONTROLLER_CONCURRENT_RECONCILES` also defaults to `1` (fully serialized), compounding the effect further.
* **What Works Instead:** Tune the rate limiter down for local/CI test environments only (never for a production kro deployment) — apply via `kubectl set env` right after the kro rollout wait in the test-cluster bootstrap script, so it's picked up by every run:
    ```bash
    kubectl set env deployment/kro -n kro-system \
      KRO_DYNAMIC_CONTROLLER_RATE_LIMITER_MIN_DELAY=50ms \
      KRO_DYNAMIC_CONTROLLER_RATE_LIMITER_MAX_DELAY=5s \
      KRO_DYNAMIC_CONTROLLER_RATE_LIMITER_RATE_LIMIT=50 \
      KRO_DYNAMIC_CONTROLLER_RATE_LIMITER_BURST_LIMIT=200 \
      KRO_DYNAMIC_CONTROLLER_CONCURRENT_RECONCILES=5
    kubectl rollout status deployment/kro -n kro-system --timeout=120s
    ```
* **How to confirm this is the cause before applying:** grep the kro controller pod logs for repeated reconcile attempts against the same object key and compare the gaps between attempts against `200ms × 2ⁿ` (1s, 2s, 3s→4s, 6s→8s, 13s→16s, 26s→32s, 51s→64s...); a near-exact match confirms the rate limiter, not a genuine stuck dependency.
* **CI caveat — don't over-raise `CONCURRENT_RECONCILES`:** `tests/Makefile` already runs 4 chainsaw suites in parallel (`--parallel 4`) against this one kro pod, and a CI runner has far fewer cores than a local dev machine. Raising `KRO_DYNAMIC_CONTROLLER_CONCURRENT_RECONCILES` too high (5 was tried) adds CPU contention that *increases* reconcile latency in aggregate on CI, even though it measured as a clear win locally — it tipped an unrelated suite (`snstopic`) over its 2-minute cleanup-phase timeout. Keep this value modest (2 worked) and validate against an actual CI run, not just a local one, before raising it further.
* **Reference:** `tests/setup.sh` (the fix is baked in here) and `docs/troubleshooting-logs/2026-08-03-dynamodbtable-ac22-ac39-stale-state-and-kro-ratelimiter.md`.

---

### Chainsaw Seed Steps Must Delete-Then-Create Config CRs, Not Just Patch

* **What Fails:** A later step's status patch (e.g. `mandatory.tags = {cost-centre, environment:mandatory}`) appears to leak into an EARLIER step's assertion when the test is re-run against a cluster where a prior run (or manual investigation) already populated `status.effectiveConfig`:
    ```
    * spec.tags: Invalid value: [{"key":"cost-centre","value":"platform"},{"key":"environment","value":"mandatory"},{"key":"team","value":"platform"}]: lengths of slices don't match
    ```
* **Why:** Two behaviors compound. (1) Chainsaw does **not** delete a `spec.namespace` that already existed before the Test started, so the config CR survives across runs. (2) `kubectl patch --type=merge` never removes keys from a map — passing `"tags":{}` is a no-op if the field already contains keys. Any prior run's later-step patch survives into the new run's seed step, and the very first assert-step then sees polluted state.
* **What Works Instead:** In every seed step (e.g. `seed-effective-config`, and any boundary-config seed inside `boundary-and-naming`), delete the config CR before re-applying it:
    ```yaml
    - name: seed-effective-config
      try:
        - script:
            content: |
              kubectl delete iamconfig role-general-policy -n iamrole --ignore-not-found=true
        - apply:
            file: 00-iamconfig.yaml
        - script:
            content: |
              kubectl patch iamconfig role-general-policy ...
    ```
  Delete-first guarantees `status.effectiveConfig` starts empty; the subsequent `apply` + patch then defines it in full. Same pattern applies to any test that seeds a shared config CR (S3, KMS, IAM policy, etc.).

---

### Cross-Tier Tag/Label Merge — Prefer Map Merge Over List Concatenation

* **What Fails:** Building the `tags` list on an ACK resource by concatenating pre-transformed lists from each tier:
    ```yaml
    tags: >-
      ${mandatory.tags.transformList(k, v, {"key": k, "value": v})
        + schema.spec.tags.transformList(k, v, {"key": k, "value": v})
        + defaults.tags.transformList(k, v, {"key": k, "value": v})
        + mandatory.syncedLabels.transformList(...)
        + ...}
    ```
  Produces duplicate keys with different values (`environment: mandatory`, `environment: instance`, `environment: defaults`) and violates mandatory-wins semantics defined by ADR-015.

* **Why:** Once a `{key, value}` pair enters a CEL list, the list has no key-uniqueness constraint. Later entries never overwrite earlier ones. Every tier's map is fully preserved rather than being merged.

* **What Works Instead:** Merge maps in lowest-to-highest priority order (defaults → spec → mandatory), then transform to the list format at the very end. `.merge()` uses last-writer-wins on map keys, giving mandatory the correct precedence:
    ```yaml
    tags: >-
      ${(defaults.syncedAnnotations ?? {})
        .merge(defaults.syncedLabels ?? {})
        .merge(defaults.tags ?? {})
        .merge(schema.spec.syncedAnnotations)
        .merge(schema.spec.syncedLabels)
        .merge(schema.spec.tags)
        .merge(mandatory.syncedAnnotations ?? {})
        .merge(mandatory.syncedLabels ?? {})
        .merge(mandatory.tags ?? {})
        .transformList(k, v, {"key": k, "value": v})}
    ```
  Same pattern applies to any cross-tier map (Kubernetes labels, annotations, tags) — always merge maps first, transform to list last.

* **Prefix rule:** The `kropath.run/` prefix applies to **Kubernetes `metadata.labels`/`metadata.annotations` only**, never to cloud resource tags. Cloud tags use plain keys as declared in `syncedLabels`/`syncedAnnotations`/`tags`.

---

### kro Omits Empty-String and Zero-Value Status Fields

* **What Fails:** A chainsaw assert checks `status.someField: ""` — the assertion fails even though the RGD expression evaluates to `""`:
    ```
    * status.someField: Required value: field not found in the input object
    --- expected
    +++ actual
      status: {}
    ```
* **Why:** kro does not write status fields whose CEL expression evaluates to an empty string `""`, empty list `[]`, or integer `0`. The field is simply absent from the stored status object. Chainsaw's subset-match treats a missing field as an assertion failure.
* **What Works Instead:** Do not assert `field: ""` in test manifests. If you need to prove a field is absent (e.g. `providerArn` for SAML type), omit the status assertion entirely and assert the relevant observable artifact (e.g. the advisory ConfigMap) instead.

---

### `x-kubernetes-validations` Cannot Be Auto-Generated by kro v0.9.2

* **What Fails:** Hand-authoring a CRD alongside an RGD (e.g. to add `x-kubernetes-validations` for immutability or mutual-exclusivity rules) creates a maintenance burden: kro regenerates the CRD from the RGD on every kro upgrade, silently discarding any manually added CEL validation rules. The hand-authored validation is gone after the next `kubectl apply -f rgds/<kind>.yaml` cycle.
* **Why:** kro derives its CRDs directly from the RGD `spec.schema`. It has no mechanism to preserve or merge `x-kubernetes-validations` rules that were not declared in the RGD's SimpleSchema.
* **What Works Instead — the in-graph ConfigMap advisory pattern:**
  1. **Mutual exclusivity** (e.g. `spec.policy` and `spec.keyPolicyRef` cannot both be set): Add a `mutualExclusionError` ConfigMap resource to the RGD, guarded with `includeWhen: ['${spec.policy != "" && spec.keyPolicyRef != ""}']`. Wire a `status.validationError` field to `mutualExclusionError.data.error`. See `rgds/iampolicy.yaml` (`mutualExclusionError`) for a working example.
  2. **Range / floor / ceiling validation** (e.g. `maxSessionDuration` must be 0 or in `[900, 43200]`): Add a `<fieldName>Error` ConfigMap resource guarded with the out-of-range condition. Wire `status.validationError` to its `data.error`. See `rgds/iamrole.yaml` (`maxSessionDurationError`) for a working example.
  3. **Immutability after creation** (e.g. `keySpec` and `keyUsage` on a KMS key cannot change after creation): **Do not implement at admission time.** ACK controllers already reject or ignore mutating updates to immutable fields at the AWS API layer. Document in the spec that this constraint is enforced by ACK, not by Kubernetes admission. No in-graph ConfigMap is needed.

  In all three cases: write a chainsaw step that applies the invalid input and asserts the advisory ConfigMap is present (or the `status.validationError` field is set). Do NOT use `apply + expect ($error != null)` — that pattern only works when the API server rejects the resource at admission time, which kro does not do for in-graph validation.

* **Do NOT:**
  * Hand-author or JSON-patch `x-kubernetes-validations` onto the kro-generated CRD — the next kro upgrade discards the patch.
  * Use `kubectl patch` post-apply scripts to add validation rules — fragile across kro upgrades.
  * Create a separate hand-authored CRD alongside the kro RGD — the kro-generated CRD will overwrite or conflict with it.

**Reference:** `docs/troubleshooting-logs/2026-07-02-aws-iam-tests-fix.md` §"iamconfig-schema-validation suite — reject-max-session-duration-below-floor" and §"iamidentityprovider suite — https-validation" for full implementation walkthroughs.

---

### `| pattern=` SimpleSchema Marker Is Unsupported in kro v0.9.2

* **What Fails:** Adding `| pattern=^https://` (or any `| pattern=`) to a field in the RGD `spec.schema` makes the RGD go `Inactive` immediately after apply:
    ```
    kubectl get rgd iamidentityprovider.aws.kropath.run
    # STATE: Inactive   REASON: unknown marker: |pattern
    ```
* **Why:** kro v0.9.2 SimpleSchema only recognises `default`, `required`, `min`, and `max` as field markers. Any other marker token is rejected at compilation.
* **What Works Instead:** Implement validation inside the graph using an `includeWhen`-gated ConfigMap resource. Set the ConfigMap's `data.error` to the human-readable message, guard it with the inverse condition (`!url.startsWith("https://")`), and expose it through a `validationError` status field. See `rgds/iamidentityprovider.yaml` (`urlValidationError` resource) for a working example.

---

### ACK IAM Does Not Support SAMLProvider

* **What Fails:** A test step tries to assert or interact with an `iam.services.k8s.aws/v1alpha1/SAMLProvider` resource:
    ```
    no matches for kind "SAMLProvider" in group "iam.services.k8s.aws"
    ```
* **Why:** The ACK IAM controller does not implement a `SAMLProvider` CRD.
* **What Works Instead:** Model SAML support as an advisory `v1/ConfigMap` (`<instance>-samlprovider-advisory`, `data.status: UNSUPPORTED`). Gate it with `includeWhen: ['${schema.spec.type == "saml"}']`. Tests assert the ConfigMap rather than any ACK resource.

---

### IAMIdentityProvider Has No Cloud Resource Name — namingTemplate Does Not Apply

* **What Fails:** KRO-236 added generic `{tag.X}` dynamic naming-template support to every IAM RGD, including `IAMIdentityProvider`. In that RGD a `naming` ConfigMap computed `effectiveName` from `nameOverride` / `namingTemplate` / `{tag.X}` tokens, and the child `OpenIDConnectProvider`'s `metadata.name` (the Kubernetes object name) was set to `${naming.data.effectiveName}` instead of `${schema.metadata.name}`. This is wrong at the root: it conflates the *Kubernetes child resource name* with a *cloud resource name*, and this resource family has no cloud resource name at all.
* **Why:** Check the CRD cache before assuming a naming template applies — `kropath-core/docs/crd-cache/aws/iam-controller-v1.4.2.md` documents the ACK `OpenIDConnectProvider` spec as exactly `clientIDs` / `tags` / `thumbprints` / `url`, with no `name` field. AWS identifies an OIDC identity provider by its URL (and, once created, its ARN — `arn:aws:iam::<account>:oidc-provider/<url-without-scheme>`), never by a name. `SAMLProvider` isn't even implemented by the ACK IAM controller (see previous entry), so it can't take a naming template either. Since there is no cloud-side name, `namingTemplate`, `{tag.X}` tokens, and `nameOverride` have nothing to drive — computing an `effectiveName` for this RGD was solving a problem that doesn't exist for this resource family, and doing so via `naming.data.effectiveName` on the child's `metadata.name` accidentally renamed the *Kubernetes* child object too, which is a separate, unconditional rule violation (see "What Works Instead").
* **What Works Instead:**
  1. **Never compute `effectiveName` for this RGD.** Don't add a `naming` ConfigMap resource; don't reference `namingTemplate`/`{tag.X}` tokens anywhere in `iamidentityprovider.yaml`.
  2. **The Kubernetes child resource name is always `${schema.metadata.name}`**, exactly like every other RGD — the RGD instance name is already unique per namespace, so there is never a reason to derive the child object's `metadata.name` from anything else. This applies even in RGDs (like this one) that have no cloud-side naming concept at all.
  3. **Keep `spec.nameOverride` in the schema** for cross-RGD consistency (ADR-015 §"Required Wiring" / this repo's CLAUDE.md "Never do: Omit `spec.nameOverride`..."), but document it as an intentional no-op for this resource type — do not wire it to anything.
  4. **Drop `status.resourceName` / `status.namingStatus`** (and their `additionalPrinterColumns` entries) entirely — there is no naming outcome to report. Keep `status.providerArn` (the real, post-reconciliation ARN) and `status.validationError`; consider a `ProviderArn` printer column in place of the removed naming columns for at-a-glance visibility.
  5. **Before adding naming-template support to any new RGD**, check the resource family's entry in `kropath-core/docs/crd-cache/aws/<controller>.md` for a `name` field on the target ACK CRD. If the target CRD (`OpenIDConnectProvider` today; watch for similar cases in other providers/resource families) has no name field, namingTemplate does not apply — skip the `naming` ConfigMap pattern entirely rather than retrofitting it.
* **Regression test:** `tests/iam/iamidentityprovider/chainsaw-test.yaml` step `nameoverride-and-naming-template-are-noop-for-oidc` sets a non-empty mandatory `namingTemplate` (with an unresolved `{tag.X}` token) and a non-empty `spec.nameOverride`, then asserts the child `OpenIDConnectProvider`'s `metadata.name` is unaffected and still equals the instance's own `schema.metadata.name`.

---

### ACK `ackResourceMetadata` Patch Requires `ownerAccountID` and `region`

* **What Fails:** A chainsaw script patches only `arn` into `status.ackResourceMetadata` to simulate a reconciled ACK resource:
    ```
    -p '{"status":{"ackResourceMetadata":{"arn":"arn:aws:..."}}}'
    # Error: status.ownerAccountID: Required value
    #        status.region: Required value
    ```
* **Why:** ACK CRDs validate that `ackResourceMetadata` is complete — `ownerAccountID` and `region` are required fields alongside `arn`.
* **What Works Instead:** Always include all three when patching `ackResourceMetadata` in test scripts:
    ```bash
    -p '{"status":{"ackResourceMetadata":{"arn":"arn:aws:iam::123456789012:oidc-provider/...","ownerAccountID":"123456789012","region":"ap-southeast-2"}}}'
    ```

---

### `status.predictedArn` Must Be Computed from Child Resource Fields, Not `schema.*`

* **What Fails:** Writing `predictedArn` using `schema.spec.*` in the `status:` block makes the RGD go `Inactive`:
    ```
    failed to build instance status schema: status field "predictedArn" expression "...": references unknown identifiers: [schema]
    ```
* **Why:** The `status:` block of an RGD is scoped exclusively to runtime outputs from child resources. `schema` (and `instance`) are not available in this scope.
* **What Works Instead:** Derive computed ARNs entirely from child resource fields:
    ```yaml
    # For IAM policies: path and name come from the ACK Policy child resource
    predictedArn: >-
      ${has(policy.spec) ? "arn:aws:iam::" + rsrcCfg.status.effectiveConfig.aws.accountId + ":policy" + policy.spec.path + policy.spec.name : ""}
    # For IAM roles: roleName comes from the ACK Role child resource
    predictedArn: >-
      ${has(role.spec) ? "arn:aws:iam::" + rsrcCfg[0].status.effectiveConfig.aws.accountId + ":role/" + role.spec.roleName : ""}
    ```
  Both `rsrcCfg` (name-based) and `rsrcCfg[0]` (array-based) are accessible in status expressions because they are defined resources in the RGD graph.

### `status.arn` vs `status.predictedArn` — Only `predictedArn` Is Testable Without Real AWS

* **What Fails:** A chainsaw assert checks `status.arn: arn:aws:iam::123456789012:policy/my-policy` but actual is `status: {}`.
* **Why:** `status.arn` reads from `policy.status.ackResourceMetadata.arn`, which is only set when the real AWS API controller has reconciled the resource and written back its ARN. In mock/local tests without AWS, this field is always empty; kro omits empty-string status fields entirely.
* **What Works Instead:** Assert on `status.predictedArn` (computed) rather than `status.arn` (actual). Reserve `status.arn` for production observability. In test asserts, use the computed form:
    ```yaml
    status:
      predictedArn: arn:aws:iam::123456789012:policy/default-my-policy
    ```

---

## 5. Cheat Sheet Core Reference Matrix

| Feature Focus Area | Avoid Pattern | Prefer Design Pattern |
| :--- | :--- | :--- |
| **Parsing Array Index Paths** | `has(myList[0].field)` | `myList[0].?field.orValue(null) != null` |
| **Validating Collection States** | `has(myList)` | `myList.size() > 0` |
| **Optional Graph Task Variables** | `includeWhen: [condition]` | Omit `includeWhen`; use sentinel fallback selectors to safely instantiate `[]` |
| **Status Scope Pathing** | `schema.spec.x` \| `instance.spec.x` | `myActiveResourceID.?status.field.orValue("")` |
| **YAML Inline Expression Blocks** | `name: ${schema.spec.type == "x" ? "a" : "b"}` | `name: '${schema.spec.type == "x" ? "a" : "b"}'` |
| **Garbage Collector Alignment** | `apiVersion: ${schema.apiVersion}` | `apiVersion: kropath.run/v1alpha1` |
| **Boolean Field Cascade Detection** | `boolean \| default=false` + `has()` | `boolean` (no default) so k8s leaves field absent when unset |
| **String Template Substitution** | Hardcoded string concatenation | `template.replace("{namespace}", ns).replace("{name}", name)` |
| **Cross-Tier Map Merge** | Concatenating pre-transformed `{key, value}` lists with `+` | `.merge()` maps in priority order, `.transformList(...)` at the very end |
| **Cloud Tag Prefix** | Prefixing cloud tag keys with `kropath.run/` | `kropath.run/` prefix is for k8s labels/annotations only — cloud tags use plain keys |
| **Empty Status Field Assertion** | `status: {field: ""}` in chainsaw assert | Omit the assertion; kro never writes empty-string/zero-value status fields |
| **CEL Field Validation** | `myField: string \| pattern=^https://` | Use an `includeWhen`-gated ConfigMap + `validationError` status field instead |
| **`x-kubernetes-validations` (immutability / mutual-exclusivity)** | Hand-authored CRD or post-apply JSON-patch to add CEL admission rules | Use the in-graph ConfigMap advisory pattern for mutual-exclusivity and range checks; rely on ACK for immutability enforcement. See §"x-kubernetes-validations Cannot Be Auto-Generated by kro v0.9.2" |
| **ACK Simulated Status Patch** | `ackResourceMetadata: {arn: "..."}` alone | Always include `ownerAccountID` and `region` alongside `arn` |
| **Unsupported ACK Resource** | Assert `SAMLProvider` or similar missing ACK kind | Model as advisory `v1/ConfigMap` with `data.status: UNSUPPORTED` |
| **Chainsaw inter-step map clearing** | `--type=merge -p '{"status":{"effectiveConfig":{"mandatory":{"tags":{}}}}'` | Null out first: `-p '{"status":{"effectiveConfig":null}}'`, then re-patch with desired values |
| **`predictedArn` in status block** | `schema.spec.path` / `schema.spec.name` (unavailable in status scope) | Use child resource fields: `policy.spec.path` + `policy.spec.name` |
| **ARN assertion in tests** | `status.arn` (empty without real AWS) | `status.predictedArn` (computed from accountId + path + name) |
| **Chainsaw list/array assertion** | Exact-order list match on CEL-generated tags/tagging | `(length(x)): N` + `(key == 'foo'): true` item-level match per element |
| **Naming template on a nameless ACK resource** | Adding `naming` ConfigMap / `effectiveName` / `resourceName` / `namingStatus` unconditionally to every RGD | Check `kropath-core/docs/crd-cache/aws/<controller>.md` for a `name` field first; if absent (e.g. `OpenIDConnectProvider`), skip naming-template entirely |
| **Test isolation between chainsaw steps** | Reuse one resource name + delete-then-recreate between steps (hangs on finalizers, compounds backoff, leaks stale state) | Unique resource name per step + `spec.skipDelete: true`, delete nothing between steps. See §"CANONICAL: Unique-Name-Per-Step + `skipDelete`" |
| **Single-letter/word field value (e.g. `attributeType: N`)** | Bare unquoted scalar in YAML test fixture | Quote it (`"N"`) — YAML 1.1 parses bare `N`/`Y`/`on`/`off`/etc. as booleans |
| **kro test-cluster reconcile churn** | Leaving kro's production rate-limiter defaults (`max-delay=1000s`) in CI/local test clusters | Tune down via `kubectl set env deployment/kro` in the test bootstrap script (`tests/setup.sh`) |
| **Assert on a multi-hop-dependency resource** | Plain `assert:` expecting chainsaw to retry a missing (not just wrong-valued) resource | Poll-based `script:` step — chainsaw does not retry "resource not found", only value mismatches |

### CEL Is Not Supported in `externalRef.metadata.name` — Use labelSelector

* **What Fails:** Using a CEL expression in `externalRef.metadata.name` to reference a config CR by name:
    ```yaml
    - id: rsrcCfg
      externalRef:
        apiVersion: aws.kropath.run/v1alpha1
        kind: IAMConfig
        metadata:
          name: ${schema.spec.configRef}   # ← CEL NOT evaluated here
          namespace: ${schema.metadata.namespace}
    ```
* **Why:** kro only evaluates CEL (`${}`) inside `template:` blocks and `selector.matchLabels` values. In `externalRef.metadata.name`, the expression is passed verbatim to the Kubernetes API as a literal string (e.g. `"${schema.spec.configRef}"`), which never matches any real resource. The lookup silently returns nothing and the instance stalls in reconciliation with no error.
* **What Works Instead:** Use `selector.matchLabels` with the provider-prefixed `aws.kropath.run/resource-name` label key. CEL IS evaluated there.
    ```yaml
    - id: rsrcCfg
      externalRef:
        apiVersion: aws.kropath.run/v1alpha1
        kind: IAMConfig
        metadata:
          namespace: ${schema.metadata.namespace}
          selector:
            matchLabels:
              aws.kropath.run/resource-name: ${schema.?spec.?configRef.orValue("general-policy")}
    ```
    The config CR must carry the matching label:
    ```yaml
    metadata:
      name: general-policy
      labels:
        aws.kropath.run/resource-name: general-policy
    ```
* **Critical side-effect — `rsrcCfg` becomes a list:** When `selector.matchLabels` is used, kro infers the variable type as `[]IAMConfig` (a list), not a scalar. Every field access must change from `rsrcCfg.status.*` to `rsrcCfg[0].status.*`, and every access must be guarded with `rsrcCfg.size() > 0`:
    ```yaml
    # WRONG — rsrcCfg is now a list, .status does not exist on lists
    .merge(rsrcCfg.status.effectiveConfig.mandatory.syncedLabels.transformMapEntry(...))

    # CORRECT — guard size first, then index
    .merge((rsrcCfg.size() > 0 && has(rsrcCfg[0].status.effectiveConfig.mandatory.syncedLabels)) ? rsrcCfg[0].status.effectiveConfig.mandatory.syncedLabels.transformMapEntry(...) : {})
    ```
* **Label key convention (provider-prefixed):**
    | Provider | Label key |
    |---|---|
    | AWS | `aws.kropath.run/resource-name` |
    | GCP *(future)* | `gcp.kropath.run/resource-name` |
    | Azure *(future)* | `azure.kropath.run/resource-name` |
    Bare forms `kropath.run/resource-name` and `kropath.run/config-name` are **deprecated**.

---

## 6. Chainsaw Test Assertion Stability

### CANONICAL: Unique-Name-Per-Step + `skipDelete` — Test Isolation Without Inter-Step Deletion

* **Environment invariant (the reason everything below matters):** the test cluster runs
  **kro but no ACK controllers** (`tests/setup.sh` installs the kro operator + ACK CRD
  *schemas* only, never the controllers). Therefore **no ACK finalizer is ever removed** —
  ACK child CRs carry `finalizers.<svc>.services.k8s.aws` and kro adds
  `kro.run/foreground-deletion`, and nothing in the cluster clears either. Any `kubectl
  delete` of such a CR blocks until its finalizers are manually patched off.
* **What Fails (the whole symptom family):** suites that **reuse one resource name** across
  steps and **delete-then-recreate** it between steps hang or time out — finalizer deletes
  block forever, kro's per-object-key backoff compounds across steps on the shared key,
  `kubectl apply` merge-patches stale fields from the prior step onto the reused object
  (empty child `spec`), and chainsaw's end-of-test cascade-delete of all accumulated CRs
  exceeds the cleanup timeout.
* **What Works Instead — four rules, applied per suite:**
  1. **Unique resource name per step** (`ac1-table`, `ac2-table`, …). Each step is its own
     kro object key, reconciled once from a clean slate — no shared-key backoff, no
     stale-state reuse (a never-seen name cannot inherit prior fields).
  2. **Never delete between steps.** No pre-cleanup scripts, no per-step `cleanup:` deletes,
     no `--wait=false`, no finalizer-strip patches. Resources accumulate harmlessly (tiny
     CRs, zero cloud calls without a controller).
  3. **`spec.skipDelete: true`** on the Test (chainsaw v1alpha1 supports `skipDelete` at
     Configuration / Test / Step level; CLI flag `--skip-delete`). Stops chainsaw's own
     end-of-test auto-delete — the cascade that caused cleanup-phase timeouts. The kind
     cluster is ephemeral and thrown away after the suite; namespace isolation keeps the 4
     parallel suites apart during the run.
  4. **Plain `assert:`** instead of poll-scripts, except where a genuine multi-hop
     `externalRef`/`includeWhen` chain can leave the object briefly absent — a fresh,
     monotonically-reconciling object retries cleanly under chainsaw's `assert:` timeout.
* **Naming impact on asserts:** each step's cloud resource name becomes
  `{namespace}-{unique-step-name}` (e.g. `dynamodbtable-ac1-table`) — still deterministic,
  just per-step. Update `spec.name` / `metadata.name` asserts accordingly.
* **Reference:** `docs/troubleshooting-logs/2026-08-03-chainsaw-unique-name-skipdelete-redesign.md`.
  This pattern **supersedes** the five symptom-level entries flagged "**Superseded**" below.

### Flaky List/Array Asserts — CEL Map-to-List Transforms Have Unstable Order

* **What Fails:** A chainsaw `assert` on a list field produced by a CEL `.merge().transformList(...)` chain (e.g. ACK `spec.tags` / `spec.tagging` key-value lists) passes most runs but intermittently fails with a diff showing the *same elements in a different order*:
    ```yaml
    # Flaky — exact-order list match
    spec:
      tags:
        - key: cost-centre
          value: platform
        - key: environment
          value: mandatory
    ```
* **Why:** CEL's `.merge()` operates over maps, and map iteration order in the underlying Go/CEL runtime is not guaranteed stable across evaluations. `.transformList()` then serializes that iteration order into a list. Chainsaw's default assertion semantics for arrays require an **exact positional match**, so any CEL-generated list (tags, `tagging`, synced-label-derived tag lists, etc.) is a latent flake — it may pass locally and fail in CI, or pass in isolation and fail in parallel runs, purely from map-order nondeterminism. Note this only applies to *list-shaped* cloud tag fields (ACK IAM Role/User/Policy `spec.tags`, S3 `spec.tagging`, KMS `spec.tags` as `tagKey`/`tagValue`); ACK SQS `Queue.spec.tags` is a **map**, not a list, and is inherently order-stable — no fix needed there.
* **What Does NOT Work — two previously-documented false fixes:**
    1. Per-item list assertions like `- (key == 'cost-centre'): true` under the list field. **This is still positional.** Chainsaw pairs assert-list-item `[i]` with actual-list-item `[i]` and evaluates the boolean check against that fixed position — it does not search across positions for a match. So when the actual array's map-iteration order differs from the order the assert was written in, item `[0]`'s check (`key == 'cost-centre'`) gets evaluated against whatever tag actually landed at position 0, fails, and the flake reappears exactly as before — confirmed empirically via `spec.tagging[0].(key == 'cost-centre'): Invalid value: false: Expected value: true` in a real CI failure (2026-07-23, KRO-236 follow-up).
    2. A whole-array CEL `.exists()` boolean check, e.g. `(tags.exists(t, t.key == 'x' && t.value == 'y')): true`. This *would* be order-independent if it worked, but chainsaw's assertion engine is a JMESPath-style tree (kyverno-json), **not** full CEL — `.exists()` is not implemented and fails outright with `Internal error: unknown function: exists` (confirmed in the same 2026-07-23 CI run, one commit after the `.exists()` "fix" was applied).

    Do not use either pattern for any CEL-generated list.
* **What Works Instead:** Chainsaw's declarative assertion tree has no genuinely order-independent list construct for this case. Drop the tag-list check from the declarative `assert:` block entirely (an empty `spec: {}` for the fields you can't assert declaratively is fine — other fields like `metadata.name`/`labels` can still be asserted normally) and verify it with a `- script:` step using `kubectl ... -o json | jq`, which is plain shell and therefore genuinely order-independent:
    ```yaml
    - script:
        content: |
          TAGS=$(kubectl get role my-role -n myns -o json | jq -c '.spec.tags')
          COUNT=$(echo "$TAGS" | jq 'length')
          [ "$COUNT" -eq 2 ] || { echo "FAIL: expected 2 tags, got $COUNT: $TAGS"; exit 1; }
          echo "$TAGS" | jq -e 'any(.key == "cost-centre" and .value == "platform")' >/dev/null || { echo "FAIL: missing tag cost-centre=platform"; exit 1; }
          echo "$TAGS" | jq -e 'any(.key == "environment" and .value == "mandatory")' >/dev/null || { echo "FAIL: missing tag environment=mandatory"; exit 1; }
    ```
    For KMS Key's `tagKey`/`tagValue` naming, use `.tagKey`/`.tagValue` in the jq filter instead. For S3 Bucket's `tagging` field: same `key`/`value` shape as IAM, just query `.spec.tagging`.
* **Rule:** Apply this jq-script pattern to **every** chainsaw check on a list field that is populated by a CEL `.merge()`/`.transformList()` chain — even single-item lists, for consistency and to future-proof against a later test adding a second item. Do not apply it to lists that echo raw user input verbatim (e.g. `spec.mandatory.allowedKeySpecs` on a config CR, `spec.policies` ARNs on an IAMRole) — those preserve apply-time order deterministically and are not CEL-transformed, so a plain positional `assert:` is fine for them.
* **Order-independent assertions are a safety net, not the fix.** A CEL-transformed list that is unordered *in the cluster* is a production defect in its own right, not merely an awkward thing to assert against — see §6.1. Sort the list in the RGD; keep the jq pattern anyway, because it stays correct if a later refactor reorders the merge chain.

### `kubectl get role`/`kubectl get user` Short-Name Collisions with Kubernetes RBAC

* **What Fails:** A test script runs `kubectl get role <name> -n <ns> -o json`, expecting the ACK `iam.services.k8s.aws/v1alpha1` `Role`, but gets `Error from server (NotFound): roles.rbac.authorization.k8s.io "<name>" not found`. Kubernetes' built-in RBAC `Role` kind is registered under the short name `role` too, and kubectl's discovery client resolves the bare short name to the built-in RBAC resource instead of the ACK CRD. A script that only checks for empty/non-empty output (rather than the command's exit code) can silently pass even though it never queried the resource it meant to — a false-negative-tolerant bug, not a crash (found 2026-07-23 in `tests/iam/iamrole/chainsaw-test.yaml`'s `boundary-and-naming` step, which had used this pattern with `test -z "$boundary"` and coincidentally kept "passing" because the command failed and produced empty output either way).
* **Why:** `kubectl`'s short-name-to-resource mapping is not scoped per test; RBAC's `Role`/`ClusterRole` are core, well-known kinds with priority over CRD-registered kinds of the same short name.
* **What Works Instead:** Always use the fully-qualified plural resource name for ACK kinds that collide with built-in Kubernetes kinds — `roles.iam.services.k8s.aws` instead of `role`. This matches the pattern already used elsewhere in these test files for other ACK kinds (`policies.iam.services.k8s.aws`, `keys.kms.services.k8s.aws`, `groups.iam.services.k8s.aws`). ACK `User`, `Bucket`, `Key`, `OpenIDConnectProvider` have no built-in-Kubernetes-kind collision and are safe to query with their bare short name.
* **Rule:** Any new `kubectl get <ack-kind>` in a test script must use the fully-qualified `<plural>.<group>` form, never the bare kind name, for any kind that might shadow a built-in Kubernetes resource (`role`, and watch for `service`, `endpoint`, `event`, `secret`, etc. if ACK ever adds CRDs with those names).

### Ambiguous kubectl Resource Name — `Illegal number` / Wrong-Group Resolution (KRO-674)

* **Symptom string:** `Illegal number` — emitted by the Kubernetes API server when two CRDs
  registered under different API groups share the same plural name and kubectl's discovery cache
  resolves the bare name to the wrong group. The error text varies by resource but often looks like:
    ```
    Error from server: error when retrieving current configuration of:
    Resource: "iam.services.k8s.aws/v1alpha1, Resource=users", GroupVersionKind: "iam.services.k8s.aws/v1alpha1, Kind=User"
    ...
    Illegal number
    ```
  In practice the suite-level symptom is a `SCRIPT ERROR` on a `kubectl get <resource>` line, or
  a chainsaw step that returns an object from the *wrong* ACK service, causing downstream `jq`
  checks to fail on unexpected JSON shapes.

* **Why:** `kubectl` resolves bare resource names (e.g. `user`, `cluster`, `acl`, `snapshot`) by
  scanning the discovery cache and returning whichever API group sorts first alphabetically. After
  KRO-413 added `users.elasticache.services.k8s.aws` and KRO-431 added MemoryDB CRDs (`users`,
  `clusters`, `subnetgroups`, `parametergroups`, `snapshots`, `acls` under
  `memorydb.services.k8s.aws`), many ACK plural names that were unique before now have two or more
  registrations. The wrong-group lookup produces `Illegal number` (or `NotFound`) depending on
  which group sorted first and what it did with the query.

* **What Works Instead:** Always use the fully-qualified `<plural>.<service>.services.k8s.aws`
  form in every `- script:` step of a chainsaw test:
    ```bash
    # ❌ Ambiguous — resolves to whichever ACK group sorts first
    kubectl get user test-user -n iamuser -o json

    # ✅ Unambiguous — exact API group
    kubectl get users.iam.services.k8s.aws test-user -n iamuser -o json
    ```
  Qualification is required for ALL ACK resource kinds, not only the historically-known
  `role`/`user` collision with Kubernetes RBAC built-ins (see the entry immediately above).

* **Lint guard:** `tests/lint-test-scripts.sh` (run via `make lint-test-scripts`) catches
  unqualified ACK resource names in chainsaw test scripts before they reach CI. The guard checks
  all `chainsaw-test.yaml` files for `kubectl get <bare-name> ` where `<bare-name>` matches any
  known ACK plural name and the token does not already contain a dot. It is wired into
  `.github/workflows/rgd-tests.yaml` as a pre-Chainsaw CI step.

  When adding a new ACK-backed resource kind, add its plural to `ACK_BARE_NAMES` in
  `tests/lint-test-scripts.sh` so new bare names are caught from day one. Do NOT add
  kropath.run wrapper CRD names (those are unique compound names like `iamconfig`, `kmskey`
  and need no qualification).

* **Reference:** `docs/troubleshooting-logs/` for the original KRO-674 IAM/Elasticache/MemoryDB
  collision investigation. Also see §"`kubectl get role`/`kubectl get user` Short-Name Collisions"
  immediately above for the specific RBAC built-in case.

---

### Chainsaw Cleanup Timeout — kro Cascade Deletion Queue Backup

> **Superseded** by §"CANONICAL: Unique-Name-Per-Step + `skipDelete`". Setting
> `spec.skipDelete: true` stops chainsaw's end-of-test cascade-delete entirely (the
> ephemeral kind cluster is discarded after the suite), so there is no queue to back up and
> no `finally:` block needed. Kept for historical context.

* **What Fails:** The last step (or last two steps) of a long Chainsaw test suite fails with:
    ```
    ERROR: context deadline exceeded
      - ac34-... / cleanup (2m0s)
      - ac33-... / cleanup (2m0s)
    ```
    This occurs even after `cleanup: 2m` is set in `.chainsaw.yaml` and `cleanup:` scripts use `--wait=false`.
* **Why:** Chainsaw automatically deletes every resource that was `apply`-ed in a step's `try:` block during the cleanup phase. For the last step(s), Chainsaw's auto-delete triggers kro's cascade deletion of all accumulated CRs. With no cloud controllers running (e.g., ACK controllers absent — only CRD definitions installed), kro cannot get cloud-side confirmation of deletion and queues all resources for retry. With 30+ CRs queued, kro processes earlier items before reaching the last step's resources, so Chainsaw's auto-delete wait for those last resources exceeds 2 minutes.

    The `cleanup:` script's `--wait=false` helps the explicit script portion, but **Chainsaw's own auto-delete of `try:`-applied resources still waits up to `cleanup-timeout`** for each resource to disappear. The auto-delete runs alongside the `cleanup:` script — it is not replaced by it.

* **What Works Instead:** Add a `finally:` block to the **last step** in the suite. Chainsaw's `finally:` runs during the **test execution phase** (right after the step's `try:`), before the cleanup phase begins. Pre-strip all finalizers and issue bulk `--wait=false` deletes there:

    ```yaml
    finally:
      - script:
          content: |
            for name in $(kubectl get topic -n snstopic -o jsonpath='{.items[*].metadata.name}' 2>/dev/null); do
              kubectl patch topic "$name" -n snstopic --type=merge -p '{"metadata":{"finalizers":[]}}' 2>/dev/null || true
            done
            kubectl delete topic --all -n snstopic --ignore-not-found=true --wait=false 2>/dev/null || true
            for name in $(kubectl get snstopic -n snstopic -o jsonpath='{.items[*].metadata.name}' 2>/dev/null); do
              kubectl patch snstopic "$name" -n snstopic --type=merge -p '{"metadata":{"finalizers":[]}}' 2>/dev/null || true
            done
            kubectl delete snstopic --all -n snstopic --ignore-not-found=true --wait=false 2>/dev/null || true
    ```

    With finalizers stripped before the cleanup phase, Chainsaw's auto-delete finds resources already in `Terminating` state with no finalizers and completes sub-second. Also:
    - Add `cleanup: 2m` (and `delete: 2m`) to `.chainsaw.yaml` as a safety margin for suites with fewer resources.
    - Add `--wait=false` to all explicit `kubectl delete` calls in `cleanup:` scripts, regardless, to prevent the script itself from blocking.

* **Chainsaw lifecycle order (for reference):**
    1. Each step's `try:` block runs in order.
    2. If `finally:` is present on a step, it runs immediately after that step's `try:` (during execution phase).
    3. The cleanup phase starts after all steps' `finally:` blocks.
    4. Cleanup runs in reverse-step order: ac34's `cleanup:` runs first, then ac33's, down to ac01's.
    5. For each step, Chainsaw auto-deletes `try:`-applied resources (waiting up to `cleanup-timeout`), then runs the explicit `cleanup:` script.

* **Rule:** Any Chainsaw suite with 20+ accumulated resources and no live cloud controllers (mock/local clusters) must have a `finally:` block on its last step to pre-strip finalizers and bulk-delete all resource kinds before the cleanup phase. See `docs/troubleshooting-logs/2026-08-02-snstopic-ci-hang.md` for the full SNSTopic investigation.

### Chainsaw `assert:` Retries a Value Mismatch, But Not a Completely Missing Resource

> **Partially superseded** by §"CANONICAL: Unique-Name-Per-Step + `skipDelete`". Most
> "resource not found" flakes came from asserting during the delete/recreate gap on a
> reused name; a freshly-created unique-name object only ever grows toward the asserted
> state, so a plain `assert:` suffices. Keep a poll `script:` only for the genuine
> multi-hop `externalRef`/`includeWhen` case described below.

* **What Fails:** A chainsaw `assert:` step against a resource created via a multi-hop dependency chain (e.g. an `externalRef` lookup that must resolve before an `includeWhen`-gated child resource is even created) intermittently fails with `actual resource not found`, even though `.chainsaw.yaml` sets `assert: 5m`:
    ```
    ac28-resource-policy-ref | ASSERT | ERROR | ... actual resource not found
    ```
* **Why:** Chainsaw retries an assert whose target object **exists but has the wrong value** against the full configured `assert:` timeout. It does **not** retry when the target object **does not exist at all** — confirmed by comparing RUN/ERROR timestamps in the chainsaw log: a value-mismatch failure shows RUN and ERROR many seconds apart (evidence of retries), while a missing-resource failure shows RUN and ERROR in the same second (zero retries, fails on the very first check). Steps whose child resource depends on an *additional* externalRef hop resolving first (e.g. a `resourcePolicyRef` → `PolicyDocument` lookup gating the child's `includeWhen`) are structurally more likely to be checked before the object exists at all, versus a step where the object already exists and only a field value is wrong.
* **What Works Instead:** Replace the plain `assert:` with a bounded poll `script:` step that waits for the resource to exist (and have the expected field populated) before treating the step as passed:
    ```yaml
    - script:
        timeout: 30s
        content: |
          for i in $(seq 1 15); do
            RESOURCE_POLICY=$(kubectl get table test-table -n dynamodbtable -o jsonpath='{.spec.resourcePolicy}' 2>/dev/null)
            if [ -n "$RESOURCE_POLICY" ]; then
              echo "PASS: resourcePolicy is set (length ${#RESOURCE_POLICY})"
              exit 0
            fi
            echo "Attempt $i: Table not found or resourcePolicy not yet set, waiting..."
            sleep 2
          done
          echo "FAIL: resourcePolicy still not set after 30 seconds"
          kubectl get table test-table -n dynamodbtable -o yaml
          exit 1
    ```
* **Rule:** Use a poll-based `script:` step instead of a declarative `assert:` for any resource whose *existence* (not just field value) depends on a multi-hop `externalRef`/`includeWhen` chain resolving first.
* **Reference:** `docs/troubleshooting-logs/2026-08-03-dynamodbtable-ac22-ac39-stale-state-and-kro-ratelimiter.md`.

---

### OPEN ISSUE: `IAMIdentityProvider`/`OpenIDConnectProvider` CLEANUP Always Times Out

> **Resolved** by §"CANONICAL: Unique-Name-Per-Step + `skipDelete`". The per-step
> `context deadline exceeded` was chainsaw's auto-delete waiting on a controller-less
> cascade; `spec.skipDelete: true` removes the auto-delete entirely, so the timeout can no
> longer occur. Verify when the `iamidentityprovider` suite is converted in the rollout.

* **Status:** ~~Unresolved as of 2026-07-23~~ — root cause identified and fixed by the canonical pattern (2026-08-03). See `docs/troubleshooting-logs/2026-07-23-chainsaw-flaky-list-asserts.md` for the original investigation.
* **Symptom:** Every step in `tests/iam/iamidentityprovider/chainsaw-test.yaml` that creates an `IAMIdentityProvider`/`OpenIDConnectProvider` logs a `CLEANUP ERROR: context deadline exceeded` (~30s per step) before the step's explicit `cleanup:` script (which patches `metadata.finalizers: []` then deletes) runs and succeeds. This inflates the suite's runtime (400s+) and, in a full `make test` run, was enough to mark the whole `iamidentityprovider` suite FAILED even though every individual assertion passed.
* **What was tried and did NOT fix it:** Moving the finalizer-clearing patch from the `cleanup:` block to the end of `try:` (so it runs before chainsaw's own automatic post-`try` resource deletion). The timeout still recurs on every step at a regular ~30s cadence, suggesting either kro re-adds the finalizer between the patch and chainsaw's automatic delete attempt, or chainsaw's automatic delete is targeting a different/child resource than the one being patched. Needs further investigation before another fix attempt — do not re-apply the "move to end of try" pattern expecting it to work; it demonstrably does not, on its own.

---

## Single-Key Map Literal Cannot Coerce to Multi-Type ACK Struct

* **Symptom (RGD `Inactive`, `GraphAccepted=False`):**
    ```log
    type mismatch in resource "listener" at path "spec.certificates":
    expression "schema.spec.certificates.map(c, {"certificateARN": c.certificateArn})"
    returns type "list(map(string, string))" but expected "list(__type_...)":
    ... struct field "isDefault": type kind mismatch: got "string", expected "bool"
    ```
* **Why:** A CEL map literal whose values are all the same type (e.g. one `string` key)
  is inferred by kro as a concrete homogeneous `map(string, string)`. When the target ACK
  field is a struct that has fields of *other* kinds (here `isDefault: bool`), kro checks
  every struct field against the map's single value type and rejects the coercion. Map
  literals with mixed value types (e.g. `{"type": "forward", "order": a.order}` → string +
  int) are inferred as `map(string, dyn)` and coerce fine — which is why multi-field
  `.map()` renames (like ELB `defaultActions`) do not hit this and single-field ones do.
* **What Works Instead:** Force the value(s) to `dyn` so the literal is inferred as
  `map(string, dyn)`; kro then coerces by field name and leaves absent struct fields unset.
    ```yaml
    # ELB Listener certificates: rename certificateArn → ACK's certificateARN.
    certificates: ${schema.spec.certificates.map(c, {"certificateARN": dyn(c.certificateArn)})}
    ```
  Alternatively rename the schema field to match the ACK field exactly and pass the struct
  list through directly (`${schema.spec.certificates}`) — but that abandons the camelCase
  schema convention and any test asserting the rename. Prefer `dyn()`.
* **Provider bootstrap reminder:** an RGD referencing a new ACK group
  (`elbv2.services.k8s.aws`, …) also needs (1) the service added to `ACK_SERVICES` in
  `hack/install-provider-crds.sh` so its CRDs install, and (2) the API group added to the
  aggregated ClusterRole in `tests/fixtures/rbac/kro-controller.yaml` so the kro
  ServiceAccount may create/get the child resources. Missing (1) → RGD stuck `Inactive`
  with `schema not found`; missing (2) → child never created, `forbidden` in instance status.

---

### kro Simple-Schema Has No `number` Type — Use `float` for Floating-Point Fields

* **What Fails:** An RGD schema field declared `myField: number` (e.g. `serverlessV2ScalingMinCapacity: number | default=0`) makes the RGD stuck `Inactive`/`GraphAccepted=False`:
    ```
    failed to build OpenAPI schema for instance: field serverlessV2ScalingMinCapacity: unknown type: number
    ```
* **Why:** kro v0.9.2 simple-schema recognizes exactly four atomic scalar types — `string`, `integer`, `boolean`, `float` (source: `pkg/simpleschema/types/atomic.go`). `number` is **not** one of them, even though it is the OpenAPI wire type. `float` is what maps to the OpenAPI `number` type internally (`float` in → `type: number` out in the generated CRD).
* **What Works Instead:** Declare floating-point governance fields as `float`:
    ```yaml
    serverlessV2ScalingMinCapacity: float | default=0
    serverlessV2ScalingMaxCapacity: float | default=0
    ```
* **The cascade trap this creates in `setup.sh`:** `setup.sh` ends with `kubectl wait rgd --all --for=condition=Ready --timeout=120s`. **One** `Inactive` RGD makes that single `wait` time out, and the timeout message lists **every** RGD not yet `Ready` at the 120s mark — typically the alphabetically-last ones (`s3bucket`, `secretsmanager`, `sns`, `sqs`, …) that simply had not finished reconciling. Those are **red herrings**: the only broken RGD is the `Inactive` one. Always `kubectl get rgd` and look for `STATE=Inactive` first; do not chase the RGDs merely listed in the `wait` timeout. Confirm the real cause with `kubectl get rgd <name> -o jsonpath='{.status.conditions}'` (look for `reason: InvalidResourceGraph`).

### Config-CRD Mutual-Exclusion `x-kubernetes-validations` Broken by Non-Zero `spec.defaults` CRD Defaults

* **What Fails:** A governance config CRD (`<Service>Config`) has both (a) `spec.mandatory` / `spec.defaults` tiers with per-field CRD `default:` values, and (b) mutual-exclusion validation rules like *"`storageEncrypted` cannot be set in both mandatory and defaults simultaneously"*. A **minimal, legitimate** config — e.g. `spec.mandatory.storageEncrypted: true` plus any `spec.defaults` field (say `namingTemplate`) — is rejected at CREATE:
    ```
    RDSConfig "in2-cfg" is invalid: <nil>: Invalid value: storageEncrypted cannot be set in both mandatory and defaults simultaneously.
    ```
* **Why:** This is the value-guarded cousin of "[Boolean Field Presence Check (`has()`) Broken by CRD Defaults](#boolean-field-presence-check-has-broken-by-crd-defaults)". The rules are value-guarded (`&& defaults.X == true`), so a mandatory field colliding with a materialized **zero-value** default (`false`/`""`/`0`) is fine. But when the `spec.defaults` tier carries **non-zero "secure baseline" defaults** (`storageEncrypted: true`, `backupRetentionPeriod: 7`, `storageType: "gp3"`, `namingTemplate: "{namespace}-{name}"`, …), merely creating any `spec.defaults` object makes the apiserver materialize `defaults.storageEncrypted: true` — which then collides with an explicit `mandatory.storageEncrypted: true` and trips the rule. CRD-schema defaults on a tier are **fundamentally incompatible** with a cross-tier mutual-exclusion contract: you could never put a field in `mandatory` because the same field auto-materializes `true` in `defaults`.
* **What Works Instead:** Remove **all scalar `default:` values** from `spec.mandatory` and `spec.defaults` (keep the `default: {}` on the tier objects and on `tags`/`syncedLabels`/`syncedAnnotations` maps). Then `has()`/materialization reflects true admin intent, the mutual-exclusion rules only fire when the admin **explicitly** sets both tiers, and both the negative tests (explicit dual-tier → rejected) and the positive cascade tests (single-tier → accepted) pass. The `status.effectiveConfig` tiers (consumed by the RGD, and in tests patched manually) must **never** carry defaults either.

### Numeric (`float`) Instance-Spec Values Must Be Unquoted in Test Fixtures

* **What Fails:** After changing an RGD schema field to `float` (OpenAPI `number`), a test fixture that passes a **quoted** value fails at CREATE of the instance/child:
    ```
    RDSCluster "cl7-cluster" is invalid: spec.serverlessV2ScalingMinCapacity: Invalid value: "string": ... must be of type number: "string"
    ```
* **Why:** `serverlessV2ScalingMinCapacity: "0.5"` is a YAML **string**, not a number. A `number`-typed field rejects it.
* **What Works Instead:** Write numeric literals unquoted — `serverlessV2ScalingMinCapacity: 0.5`. **Do not confuse this with** the "[YAML 1.1 Boolean Coercion](#yaml-11-boolean-coercion-of-single-letterword-field-values-the-norway-problem)" / *"quote inline CEL ternary YAML values"* rules — those apply to **CEL expression strings** in the RGD YAML (where a bare `${...}` starting with a special char must be quoted), never to plain numeric literals in instance fixtures.

### A `- script:` Querying a kro Child Must Be Preceded by an `- assert:` on That Child

* **What Fails:** A chainsaw step does `- apply:` (the kro instance CR) immediately followed by a `- script:` that runs `kubectl get <child> ... | jq`. The script races the kro reconciler and reads the child before it exists:
    ```
    === STDERR
    Error from server (NotFound): dbinstances.rds.services.k8s.aws "in16-inst" not found
    === ERROR
    exit status 4
    ```
* **Why:** `- script:` steps run **once** with no retry. `- assert:` steps, by contrast, retry until `AssertTimeout` (5m). A bare script has no wait, so it fires the instant the apply returns — before kro has generated the child.
* **What Works Instead:** Insert a minimal `- assert:` on the child (any stable field, e.g. `spec.engine`) between the `- apply:` and the `- script:`. Chainsaw blocks on the assert until the child materializes, then the order-independent `jq` checks run against a real object:
    ```yaml
    - apply: { resource: { kind: RDSInstance, ... } }
    - assert:
        resource:
          apiVersion: rds.services.k8s.aws/v1alpha1
          kind: DBInstance
          metadata: { name: in16-inst, namespace: rdsinstance }
          spec: { engine: mysql }
    - script: { content: "kubectl get dbinstance in16-inst ... | jq ..." }
    ```
  Two related fixture bugs surface in the same steps: (1) **synced labels carry the `aws.kropath.run/` prefix** — assert `.metadata.labels["aws.kropath.run/team"]`, never bare `kropath.run/team`; (2) **advisory ConfigMaps are named `${schema.metadata.name}-<suffix>`** (e.g. `in21-inst-password-exclusion-error`), not the bare instance name — assert the full generated name.

---

## 6.1. Rendered Output Must Be Byte-Stable Across Reconciles

Two defects in this section share one root idea: kro compares what it rendered against what is
stored, and **any** difference is treated as a real change. A template that renders the same
*meaning* two different ways therefore never converges. Both bugs below were found in one
investigation (KRO-916, KRO-917) and both present as something other than what they are.

### `.transformList()` Over a Map Is Unordered — Sort Before Emitting

* **What Fails:** Ending a cross-tier tag merge at the transform, which is the pattern §6 recommends
  for correctness and §2 uses in its examples:
    ```yaml
    tagSet: >-
      ${(defaults.tags ?? {})
        .merge(schema.spec.tags)
        .merge(mandatory.tags ?? {})
        .transformList(k, v, {"key": k, "value": v})}     # <-- unordered
    ```
* **Symptom:** The instance never reaches `Ready`, and the reason names neither tags nor ordering:
    ```
    type: Ready
    status: "False"
    reason: NotReady
    message: 'resource reconciliation failed: cluster mutated'
    ```
  Meanwhile the ACK resource is **completely healthy** — `ACK.ResourceSynced=True`, the resource
  exists in AWS, and the tags on it are correct. Only `metadata.generation` on the ACK resource
  moves, at roughly 4 writes/second.
* **Why:** CEL `.transformList()` iterates a map, and map iteration order is not stable between
  evaluations. The rendered list holds the same entries in a different sequence each reconcile. A
  list is ordered, so kro's applyset sees a genuine object change, reports `HasClusterMutation()`,
  and requeues with `cluster mutated`. There is no pass in which nothing changed, so `Ready` is
  **structurally unreachable** — this never settles on its own and no amount of waiting or
  re-syncing helps.
* **What Works Instead:** Sort deterministically as the last step, so the same tag set always
  renders the same sequence:
    ```yaml
    tagSet: >-
      ${(defaults.tags ?? {})
        .merge(schema.spec.tags)
        .merge(mandatory.tags ?? {})
        .transformList(k, v, {"key": k, "value": v})
        .sortBy(x, x.key)}                                 # <-- required
    ```
* **Scope:** Every map-to-list conversion that reaches a rendered resource, not only tags. Families
  whose ACK schema takes a list of key/value structs (S3 `tagging.tagSet`, and any future family on
  the same shape) are exposed; families that pass `tags` through as a **map** (SNS, SQS) are not,
  which is why this surfaced on S3 first and looked S3-specific.
* **Diagnosing it:** Sample the ACK resource's spec twice and diff. Identical *content* in a
  different *order* is conclusive:
    ```bash
    for i in 1 2; do
      kubectl get bucket.s3.services.k8s.aws <name> -n <ns> \
        -o jsonpath='{.spec.tagging.tagSet}' ; echo; sleep 4
    done
    ```
  A climbing `metadata.generation` with a byte-identical *sorted* spec is the same signature.
* **Fixed in:** KRO-916.

### A Float Default Written `0.0` Drives an Unbounded CRD Write Loop

* **What Fails:** A SimpleSchema float default written with a fractional part:
    ```yaml
    throttlingRateLimit: float | default=0.0     # <-- loops
    ```
* **Symptom:** kro stops doing anything else. Its entire log output, 9–11 times per second, is:
    ```log
    rgd-controller  Updating existing CRD        <plural>.aws.kropath.run
    rgd-controller  Waiting for CRD to become ready
    ```
  The generated CRD was observed at `metadata.generation` **789140** while every other kropath CRD
  in the same cluster sat at 4 or 5.
* **Why:** kro emits the CRD schema default as the raw bytes `0.0`. The API server normalises the
  stored JSON number to `0`. kro compares schema defaults with `bytes.Equal`
  (`pkg/graph/crd/compat/schema.go`), so the comparison can never match, `Ensure` takes the patch
  branch instead of its "CRD is up-to-date" early return (`pkg/client/crd.go`), and the write
  repeats forever. The stored spec is byte-identical across writes — **only `generation` moves**,
  which is why a plain `kubectl get -o yaml` looks entirely normal.
* **Blast radius is the whole controller, not one family.** All kro controllers share one client-go
  rate limiter. One looping RGD consumes roughly 20 API QPS and starves the instance controllers,
  so unrelated resources stop converging. Symptoms appear in families that have nothing to do with
  the offending RGD.
* **What Works Instead:** Write the literal so that it survives a JSON round-trip unchanged:
    ```yaml
    throttlingRateLimit: float | default=0       # <-- stable
    ```
  This is not a style preference. `0.0`, `1.0`, `2.50` and any other trailing-zero form normalise
  on write and will loop; `0`, `1`, `2.5` will not. The bug is upstream in kro's byte-wise
  comparison, but the RGD-side literal is the fix that is available today.
* **Confirmed against a control group.** Same schema shape (`type: number`, zero default), only the
  literal differs:

  | RGD | Declaration | CRD generation |
  |---|---|---|
  | `apigatewayv2stage` | `float \| default=0.0` | **789140** |
  | `cloudfrontresponseheaderspolicy` | `float \| default=0` | 1 |
  | `rdscluster` | `float \| default=0` | 1 |

* **Diagnosing it:** Generation is the tell — the content never looks wrong.
    ```bash
    kubectl get crd -o custom-columns='NAME:.metadata.name,GEN:.metadata.generation' \
      | grep kropath | sort -k2 -nr | head
    ```
  Anything above single digits is looping. Confirm with `kubectl -n kro-system logs deploy/kro`:
  a single repeating pair of lines and nothing else.
* **Fixed in:** KRO-917.

### Omission Is Wrong for Fields the Provider Late-Initialises

The rule in §7 — an unconfigured optional attribute must be *absent*, not present-and-empty — is
correct for attributes **AWS rejects when empty**. It is wrong for fields **AWS populates itself**,
and applying it there trades a terminal error for a silent write loop.

* **What Fails:** Omitting a field that ACK late-initialises. `snstopic` stopped emitting `policy`
  when `topicPolicyRef` is empty (KRO-905). SNS returns a default access policy for every topic, so
  ACK reads it back and writes it into `spec`:
    ```json
    {"Version":"2008-10-17","Id":"__default_policy_ID",
     "Statement":[{"Sid":"__default_statement_ID","Effect":"Allow","Principal":{"AWS":"*"}, ...}]}
    ```
* **Symptom:** Nothing reports an error. ACK is `ACK.ResourceSynced=True` with no terminal
  condition, kro is `Ready=True :: AllResourcesReady` — and the ACK object is rewritten roughly
  **five times per second for the next ten to fifteen minutes**, around **2,600 writes**, before
  the two managers settle into shared ownership of the field. Every one of those reconciles is a
  real AWS API call, so a resource that looks healthy from every status field anyone would think
  to check quietly bills a few thousand calls each time it is created.
* **Why:** Omitting a field does not mean "no opinion". It hands the field to the provider's field
  manager. `managedFields` shows the split plainly:
    ```
    kro.run/applyset   Apply    -> metadata + the spec kro renders
    controller         Update   -> {"f:spec": {"f:policy": {}}}     <-- ACK owns policy
    ```
  kro renders an object without `policy`, ACK puts one back, and neither converges.
* **It converges, which is what makes it easy to miss.** Two topics created eight minutes apart
  both settled — generation 2703 and 2595 — and stayed settled. Sampling one of them mid-handover
  looks identical to an unbounded loop, so the two are indistinguishable without waiting it out.
  That also means **delete-and-recreate "fixes" it**, in the sense that the resource does reach a
  steady state; it simply re-pays the handover every time. The cost is per creation, not
  continuous — which lowers the urgency without changing the defect.
* **How to tell the two cases apart before omitting:** ask whether AWS *rejects* the field when
  empty, or *supplies* it when absent.
    * Rejects when empty → omit (§7). `ContentBasedDeduplication`, `FifoQueue`, `Policy` on
      **create**.
    * Supplies when absent → do not omit; render the value AWS would return, so the desired state
      matches the observed one. Otherwise the field is contested forever.
  The tell is an `ACK.LateInitialized=True` condition on the resource, or the field appearing in
  `spec` with a value nobody configured.
* **Diagnosing it:** a climbing `metadata.generation` on a resource whose status is entirely green.
  Sample well after creation — during the first ten minutes every freshly created resource of this
  kind is still converging, so an early sample cannot distinguish this defect from normal settling.
    ```bash
    for i in 1 2; do
      kubectl get <ack-kind> <name> -n <ns> -o jsonpath='{.metadata.generation}{"\n"}'; sleep 6
    done
    kubectl get <ack-kind> <name> -n <ns> --show-managed-fields -o json \
      | jq '.metadata.managedFields[] | {manager, operation, fields: .fieldsV1}'
    ```
  Two managers touching the same `f:spec` key is the confirmation.
* **Fixed in:** KRO-920. All six "NoPolicy" SNS Topic variants (standard + FIFO × 3 feedback
  combinations) now render the AWS default access policy explicitly, so kro's desired state matches
  what ACK would late-initialise and the ~2,600-write transient handover is eliminated. Audit
  alongside it the other fields the omit-don't-empty work touched — S3
  `createBucketConfiguration.locationConstraint` and `versioning.status` are the obvious candidates.

### `includeWhen` Must Not Read Another Node in the Same Graph

* **What Fails:** Gating resource inclusion on the observed state of a sibling node. `snstopic`
  renders twelve mutually-exclusive ACK Topic variants, each gated on the `naming` ConfigMap:
    ```
    ${!naming.data.resourceName.contains("{") && naming.data.hasFeedback == "true" && ...}
    ```
* **Symptom:** Deletion hangs forever. The instance sits in `DELETING` holding `kro.run/finalizer`,
  and kro retries indefinitely:
    ```log
    includeWhen dependency "naming" not ready: node "naming":
      no observed state: waiting for readiness (data pending)
    ```
  It never clears on its own. The name stays taken, so a GitOps re-sync cannot recreate the
  instance and the tenant Application stalls without reporting a failure.
* **Why:** On teardown kro needs `naming.data` to evaluate the gates and decide which variants exist
  to delete — but `naming` is part of the same graph and is itself being removed. **The gate
  outlives the thing it reads.** Confirmed by observing that the S3 and SQS naming ConfigMaps were
  present in the same namespaces while the SNS ones were already gone.
* **What Works Instead:** Derive gate inputs from `schema.spec` and the resolved config tiers, which
  are available at every point in the lifecycle including deletion. A `naming` ConfigMap may still
  be rendered as an *output*; it must not be an *input* to inclusion.
* **The variant count is the underlying hazard.** Gating arrived with the empty-attribute work and
  grew with it — `includeWhen` went 1 → 2 → 4 → 8 → 12 across KRO-905, KRO-911 and KRO-915. Each
  step fixed a real AWS rejection; together they built the deadlock. If presence-gating can be
  expressed without the combinatorial split, this class disappears.
* **Check the sibling families.** `sqsqueue` was expanded to 16 variants by the same work. It is
  healthy today but has not been torn down since — verify it under delete before trusting it.
* **Tracked in:** KRO-919.

## 7. ACK Target-Schema Fidelity — Verify Every Field Against the Live CRD

The RGD's user-facing `types:` block and the ACK CRD it feeds are **two independent schemas**.
kro type-checks every template expression against the ACK CRD's OpenAPI schema at RGD-validation
time, so any drift between what the RGD *declares* and what ACK *accepts* turns the RGD `Inactive`
before a single instance is created. Intuition about field names and types is not a substitute for
reading the CRD.

**Always dump the target shape first:**

```bash
kubectl get crd distributions.cloudfront.services.k8s.aws -o json \
  | jq -r '.spec.versions[0].schema.openAPIV3Schema.properties.spec.properties
           .distributionConfig.properties.origins.properties.items.items.properties
           | map_values(if .type=="object" then (.properties|map_values(.type)) else .type end)'
```

Real drift found in the CloudFront family (KRO-443), every instance of which blocked the RGD:

| RGD declared | ACK actually wants | Error text |
|---|---|---|
| `responseCode: integer` | `string` (AWS returns the HTTP status as a string) | `field "responseCode" has incompatible type: got "int", expected "string"` |
| `httpsPort` | `httpSPort` (capital S) | silently wrong / unknown field |
| flat `cachedMethods: []string` | nested `allowedMethods.cachedMethods.items` | `field "cachedMethods" exists in output but not in expected type` |
| `originType` (invented) | no such field on an origin | `strict decoding error: unknown field "spec.origins[0].originType"` |

### ACK `format: byte` Fields Need CEL `bytes()`

* **What Fails:** Assigning a string expression to an ACK field typed `string` with `format: byte`
  (e.g. `cloudfront Function.spec.functionCode`):
    ```yaml
    functionCode: ${schema.spec.functionCode}
    ```
    ```log
    failed to validate resource "ackFunction": type mismatch at path "spec.functionCode":
    expression "schema.spec.functionCode" returns type "string" but expected "bytes":
    type kind mismatch: got "string", expected "bytes"
    ```
* **Why:** kro maps OpenAPI `type: string, format: byte` to the CEL `bytes` type. A kro RGD schema
  has no `bytes` primitive, so the user-facing field must stay `string` and be converted in the
  template. There is **no pass-through option** — the type checker rejects it.
* **What Works Instead:** The CEL *standard* conversion `bytes(string)` is available (kro v0.9.2
  does **not** ship the cel-go `base64` extension, but does not need it here). The caller supplies
  **plain** content and the API server base64-encodes the bytes on write:
    ```yaml
    functionCode: ${bytes(schema.spec.functionCode)}
    ```
  Caller passes `"hello"` → the ACK CR stores `"aGVsbG8="`. Do **not** ask callers to pre-encode:
  `bytes()` would treat the base64 text as literal characters and double-encode it.

### `.orValue()` Cannot Take a Map Literal for a Named-Struct Field

* **What Fails:** Guarding an optional nested object by supplying a map-literal fallback — the
  shape that looks like the obvious replacement for a rejected `has()`:
    ```yaml
    "s3OriginConfig": o.?s3OriginConfig.orValue({"originAccessIdentity":""}).?originAccessIdentity.orValue("") != "" ? ... : {}
    "customOriginConfig": o.?customOriginConfig.orValue({"originProtocolPolicy":""}) ... ? o.customOriginConfig : {}
    ```
    ```log
    found no matching overload for 'orValue' applied to
      'optional_type(__type_schema.spec.origins.@idx.s3OriginConfig).(map(string, string))'
    found no matching overload for '_?_:_' applied to
      '(bool, __type_schema.spec.origins.@idx.customOriginConfig, map(dyn, dyn))'
    ```
* **Why:** Inside a macro, a nested object of a named RGD type is a **named struct type**
  (`__type_schema.spec.origins.@idx.s3OriginConfig`), not a map. `optional(T).orValue(x)` requires
  `x` to be exactly `T`, and a map literal never unifies with a named struct. The same rule breaks
  the ternary: returning the struct itself on one branch and `{}` on the other cannot unify either.
* **What Works Instead:** Chain the safe-navigation operator all the way down to a **scalar leaf**,
  and `orValue()` only that scalar. Build every branch as an explicit map literal so both branches
  are maps:
    ```yaml
    "s3OriginConfig": o.?s3OriginConfig.?originAccessIdentity.orValue("") != ""
      ? {"originAccessIdentity": o.s3OriginConfig.originAccessIdentity}
      : {},
    "customOriginConfig": o.?customOriginConfig.?originProtocolPolicy.orValue("") != ""
      ? {
          "httpPort": o.?customOriginConfig.?httpPort.orValue(80),
          "httpSPort": o.?customOriginConfig.?httpsPort.orValue(443),
          "originProtocolPolicy": o.customOriginConfig.originProtocolPolicy,
          "originSSLProtocols": {"items": o.?customOriginConfig.?originSSLProtocols.?items.orValue([])}
        }
      : {}
    ```
  `map(string, …)` vs the empty literal `{}` (`map(dyn, dyn)`) **does** unify — only struct-vs-map
  fails. Never return `o.someNestedObject` directly from a ternary branch.

### kro's Dependency Extractor Only Understands the 3-Argument `transformList`

* **What Fails:** The two-argument CEL form `list.transformList(v, expr)`:
    ```log
    failed to build dependency graph: failed to extract dependencies:
    references unknown identifiers: [b]
    ```
* **Why:** kro parses each expression to discover which graph resources it depends on. Its
  identifier walker recognises the loop variables of the **three-argument** form
  `transformList(indexVar, valueVar, expr)` only; with the two-argument form the value variable
  looks like an unresolved top-level resource reference and the whole graph is rejected.
* **What Works Instead:** Always use the 3-arg form, even when the index is unused:
    ```yaml
    ${schema.spec.cacheBehaviors.transformList(i, b, { "pathPattern": b.pathPattern, ... })}
    ```

---

### ACK Wrapper Objects — a Correct Element Shape Attached One Level Too High

* **What Fails:** A tag/list expression produces the right *element* shape but is bound to the container field rather than its inner array:
    ```yaml
    tagging: ${( ...merge chain... ).transformList(k, v, {"key": k, "value": v})}
    ```
    ```log
    failed to create typed patch object (ns/name; s3.services.k8s.aws/v1alpha1, Kind=Bucket):
    .spec.tagging: expected map, got &{[map[key:provisioner value:argocd] ...]}
    ```
    **No child resource is created at all** — the instance goes straight to `ERROR`, so an empty `kubectl get buckets.s3...` is the symptom, not a slow reconcile.
* **Why:** Several ACK types wrap a list in a single-property container object. S3's `Bucket` is the canonical case: `spec.tagging` is an **object** whose only property is `tagSet` (the array). `transformList` emits `[{key,value},...]`, which is exactly what `tagSet` wants and exactly what `tagging` does not. The error text is easy to misread as "your tags are the wrong shape" when the shape is fine and only the nesting is wrong.
* **What Works Instead:** Bind the expression to the inner field:
    ```yaml
    tagging:
      tagSet: ${( ...same merge chain... ).transformList(k, v, {"key": k, "value": v})}
    ```
    Before writing any list-valued ACK field, dump the container to see whether it is the array or wraps one — per the section intro above:
    ```bash
    kubectl get crd buckets.s3.services.k8s.aws -o json \
      | jq '.spec.versions[0].schema.openAPIV3Schema.properties.spec.properties.tagging'
    ```
    `"type": "object"` with a single array property means you need the extra level. `"type": "array"` means bind directly.

### Attribute-Passthrough Resources (SNS/SQS) — Omitting a Field Is Not the Same as Sending `""`

* **What Fails:** Emitting an empty string for "no value", or sending a field that only applies in another mode:
    ```yaml
    policy: ${ref != "" && cr.size() > 0 ? cr[0].spec.documentJSON : ""}   # SNS
    deduplicationScope: '${schema.spec.deduplicationScope}'                # SQS, always present
    ```
    ```log
    InvalidParameter: Invalid parameter: Policy is empty
    InvalidAttributeName: You can specify the DeduplicationScope only when FifoQueue is set to true.
    ```
* **Why:** For SNS `Topic` and SQS `Queue`, ACK forwards `spec` fields to AWS as **Attributes**, a flat string map. AWS validates every attribute it receives: an empty value is a malformed attribute rather than an absent one, and a mode-specific attribute is rejected outright when the mode is off. A CEL ternary always yields *something*, so the usual `: ""` fallback silently produces an invalid request.
* **What Works Instead:** Make the field's *presence* conditional rather than its value — split the template on `includeWhen` (KRO-905, KRO-906) so the key is absent entirely when it does not apply. Guard **every** field in a mode-gated family: SQS ships four FIFO attributes, and gating only `fifoQueue` and `contentBasedDeduplication` still leaves `deduplicationScope` and `fifoThroughputLimit` flowing from their schema defaults (`queue`, `perQueue`) onto standard queues.
* **Operational note — these do not self-heal:** Both failures land as `ACK.Terminal=True`. **ACK stops retrying a terminal condition**, so the resource sits failed indefinitely and a GitOps re-sync of an unchanged manifest will not clear it. The spec must actually change. When verifying a fix, confirm `ACK.ResourceSynced=True` rather than assuming a re-sync recovered it.

### Empty-Value Rejection Is Not Only an Attributes Problem — Structured Sub-Resource Calls Fail the Same Way (S3)

* **What Fails:** The same `: ""` fallback, on a resource that is *not* attribute-passthrough:
    ```yaml
    sseAlgorithm:   ${... : "aws:kms"}   # resolves to aws:kms from the platform baseline
    kmsMasterKeyID: ${... : ""}          # nothing configures a key anywhere
    ```
    ```log
    Error syncing property 'Encryption': operation error S3: PutBucketEncryption,
    StatusCode: 400, api error InvalidArgument: if the default sse algorithm is
    aws:kms or aws:kms:dsse and a KMSMasterKeyID is specified, it must be non-empty
    ```
* **Why:** The section above is scoped to SNS/SQS because those forward `spec` into a flat `Attributes` map. **The lesson generalises further than its examples.** ACK's S3 controller creates the bucket and then syncs each property through its own API call (`PutBucketEncryption`, `PutBucketTagging`, …). AWS applies the same rule there: a key that is present-but-empty is "specified", not absent. Any RGD field reaching a structured AWS call is exposed to this, not just attribute-passthrough families.
* **Two consequences that make it diagnose badly:**
    * **Partial success — the resource exists but is silently under-configured.** Properties sync in sequence and `Encryption` runs *before* `Tagging`. The failure aborts the reconcile, so `PutBucketTagging` is never reached. The bucket is created in AWS with **no tags**, while `spec.tagging.tagSet` is perfectly correct. The presenting symptom is "tags are missing", which points the investigation at the tag template — the wrong file. **Rule: when a resource exists in AWS but is missing configuration, look for an earlier property failing in the ACK controller log, not at the missing property's template.**
    * **`ACK.Recoverable` behaves the opposite way to `ACK.Terminal`.** The operational note above ("these do not self-heal") applies to terminal conditions. This one is `ACK.Recoverable=True`, so ACK requeues without effective backoff — the live `Bucket` advanced roughly 25 resourceVersions per second indefinitely. ArgoCD diffs an object that never settles and the tile flaps; kro's apply collides with ACK's writes and reports `ResourcesReady=False :: resource reconciliation failed: cluster mutated`. Neither symptom names encryption. A flapping ArgoCD tile plus `cluster mutated` means *something* below ArgoCD is rewriting the object every pass — it is never a kro-vs-ArgoCD problem, but it is not always ACK. There are two causes and they are told apart by one check. If the ACK resource carries `ACK.Recoverable=True`, it is this one. If ACK reports `ACK.ResourceSynced=True` and the object *still* churns, the RGD itself is rendering a different object each pass — see §6.1 on non-deterministic list ordering.
* **What Works Instead:** Omit the field when it resolves empty, or supply a genuinely valid value. Where AWS documents a managed default, prefer it: `snstopic` already defaults `kmsMasterKeyID` to `alias/aws/sns`, which is exactly why SNS never hit this. `s3bucket` had no equivalent and now defaults to `alias/aws/s3` (KRO-913). Sibling RGDs diverging on the same field is itself the smell worth checking.

### Guard *Every* Field in a Mode-Gated Family — Both Halves, Not Either Half

* **What Fails:** KRO-906 gated `deduplicationScope` and `fifoThroughputLimit` behind an `includeWhen` split but left `fifoQueue: "false"` and `contentBasedDeduplication: "false"` hardcoded on the standard-queue branch. AWS rejects those too:
    ```log
    InvalidAttributeName: Unknown Attribute FifoQueue.
    ```
* **Why:** `CreateQueue` rejects the `FifoQueue` attribute outright when the queue name does not end in `.fifo`. The value `"false"` is not "FIFO disabled" — it is an attribute that must not be sent at all. The note in the section above anticipated the converse mistake (gating `fifoQueue`/`contentBasedDeduplication` while leaving the other two flowing); the failure that actually shipped was the mirror image. **Either half left ungated fails the same way**, so the family has to be audited as a whole rather than by whichever field was named in the last ticket.
* **Fixed in:** KRO-912. Tracked history: the SNS/SQS/S3 empty-value defect was found and fixed one field group at a time across KRO-905, KRO-906, KRO-898, KRO-911, KRO-912 and KRO-913. KRO-915 sweeps all RGDs for the remaining `: ""` / literal-`"false"` fallbacks rather than waiting for AWS to reject the next one.

### `optional.none()` in Write Position Is Rejected by kro v0.9.2 — Field-Level Omission Is Not Achievable (KRO-928)

* **What Fails:** Attempting to conditionally omit a scalar string field by returning `optional.none()` from a CEL ternary:
    ```yaml
    someField: ${conditionMet ? "arn:aws:iam::..." : optional.none()}
    ```
    kro rejects the RGD immediately:
    ```
    found no matching overload for '_?_:_' applied to '(bool, string, optional_type(dyn))'
    RGD reaches Inactive — GraphAccepted: False
    ```
    Map-merge construction (`{}.merge(...)`) also cannot produce a field that is absent from the rendered CR because the template YAML structure is fixed at authoring time.

* **Why this matters for the omit-don't-empty rule:** The rule "omit the field rather than setting it to empty string" is correct but implies that omission is always achievable. It is achievable at the **resource level** — put the field in a separate template variant gated by `includeWhen` so the entire resource is absent when the condition is false. It is NOT achievable at the **field level within a single template** in kro v0.9.2. If ten fields can each be independently present or absent (e.g. 5 protocols × 2 ARNs = 10 combinations), 2^10 = 1024 template variants would be needed — which is impractical. The correct mitigation is to detect the unsupported configuration in-graph (using a named ConfigMap that computes a flag) and surface an error ConfigMap to the user instead of rendering a broken CR.

* **Proven by:** KRO-928 probe 4 on 2026-08-31 against kro v0.9.2:
    ```yaml
    # Probe RGD kro928probe4 — optional.none() in write position
    template:
      spec:
        nested:
          sqsSuccessFeedbackRoleArn: >-
            ${schema.spec.testConfig.nested.sqsSuccessFeedbackRoleArn != ""
              ? schema.spec.testConfig.nested.sqsSuccessFeedbackRoleArn
              : optional.none()}
    # Result: Inactive
    # Error: found no matching overload for '_?_:_' applied to
    #        '(bool, string, optional_type(dyn))'
    ```

* **SNS Topic example — mixed ARN detection pattern (KRO-928):** When only some of the 10 ARN fields are configured, `hasMixedFeedbackARN` is computed in the naming ConfigMap using: `(anyArn) && !(all 10 positions each have at least one non-empty source)`. When `hasMixedFeedbackARN == "true"`, the four WithARN templates are gated out via `includeWhen` (adding `&& naming.data.hasMixedFeedbackARN != "true"`) and the `mixedFeedbackARNError` advisory ConfigMap is rendered instead. See `docs/deferred-capabilities.md` for the unblock condition.

* **To unblock:** When kro adds support for `optional.none()` in write position (or equivalent field-omission semantics), replace the multi-variant template approach with a single template using conditional field emission.

## 8. Diagnosing RGD Failures — Two Traps in the Tooling Itself

### `kubectl wait rgd --all --timeout=120s` Shares ONE Budget Across All RGDs

* **What You See:** CI's `make setup` reports a *list* of RGDs that "timed out", which reads as
  though every one of them is broken:
    ```log
    resourcegraphdefinition.kro.run/cloudfrontcachepolicy.aws.kropath.run condition met
    timed out waiting for the condition on resourcegraphdefinitions/cloudfrontdistribution...
    timed out waiting for the condition on resourcegraphdefinitions/cloudfrontfunction...
    timed out waiting for the condition on resourcegraphdefinitions/cloudfrontoriginaccesscontrol...
    ```
* **Why:** `kubectl wait --all` walks resources in **name order** against a single shared deadline.
  The first genuinely-broken RGD consumes the entire 120s; every RGD alphabetically after it is
  reported as timed out without ever being given time. The failure list is therefore
  "first broken RGD + everything after it alphabetically", **not** the set of broken RGDs.
* **How to Diagnose:** Ignore the list. Reproduce locally and read the actual state:
    ```bash
    kubectl get rgd --no-headers | awk '$5!="True"{print $1, $4, $5}'
    kubectl get rgd <name> -o jsonpath='{range .status.conditions[*]}{.type}={.status} :: {.message}{"\n"}{end}'
    ```
  In KRO-443 five RGDs were reported; only **two** (`cloudfrontdistribution`,
  `cloudfrontfunction`) were actually broken.

### kro Re-Validates the Graph Only on Re-CREATE, Not on Re-Apply

* **What Fails:** Editing an RGD, running `kubectl apply`, and concluding the fix did not work
  because the `GraphAccepted` message is unchanged. Adding an annotation to force a resync does not
  help either.
* **Why:** An unchanged/annotation-only update does not bump `metadata.generation`, and a
  long-failing RGD has its controller-runtime workqueue backoff already saturated at the default
  1000s cap — so the stale message can persist for ~16 minutes. (The
  `KRO_DYNAMIC_CONTROLLER_RATE_LIMITER_*` tuning in `tests/setup.sh` applies to the *dynamic*
  controller, not the RGD controller.)
* **What Works Instead:** Delete and re-create on every iteration; it re-validates in ~2s. This
  also surfaces errors **one layer at a time** — each fix reveals the next validation failure, so
  budget several rounds:
    ```bash
    kubectl delete rgd <kind>.aws.kropath.run --timeout=60s
    kubectl apply -f rgds/<kind>.aws.kropath.run.yaml
    kubectl get rgd <kind>.aws.kropath.run -o jsonpath='{.status.conditions[?(@.type=="GraphAccepted")].message}'
    ```
  **A fix to an RGD template is not verified until the RGD reaches `Active` in a cluster.**
  Reasoning about CEL types on paper is not verification — every CloudFront fix in this cycle
  looked correct on paper and was rejected by the type checker.

### Local-Cluster-Only Failure Modes to Rule Out Before Blaming the Code

A long-lived local kind cluster diverges from CI's fresh cluster. Two artifacts that look like real
bugs:

1. **`KindReady=False: breaking changes detected: Property X was removed`** — a stale kro-generated
   CRD from an earlier branch. Fix: `kubectl delete crd <plural>.aws.kropath.run`. CI never hits it.
2. **Child ACK resources never created, asserts fail with `actual resource not found`** — the kro
   ClusterRole in the local cluster predates the new service. Fix:
   `kubectl apply -f tests/fixtures/rbac/kro-controller.yaml && kubectl rollout restart deployment/kro -n kro-system`.
   Check with `kubectl get clusterrole kro -o yaml | grep -c <service>`.

---

### Simulating ACK Status: Patch the ACK CHILD, Never the kro-Computed Parent Field

* **What Fails:** Seeding a sibling resource's id for a cross-RGD `externalRef` test by patching the
  kropath CR's status directly:
    ```bash
    kubectl patch cloudfrontcachepolicy ac10-cache-policy -n ns --subresource=status \
      --type=merge -p '{"status":{"id":"cache-policy-id-abc"}}'
    ```
  The patch appears to succeed, but the consuming resource still reads `""`:
    ```log
    * spec.distributionConfig.defaultCacheBehavior.cachePolicyID:
        Invalid value: "": Expected value: "cache-policy-id-abc"
    ```
* **Why:** `status.id` on the kropath CR is **kro-computed** — the RGD declares
  `id: ${ackCachePolicy.?status.?id.orValue("")}`. kro's instance controller owns that field and
  overwrites the manual patch on its next reconcile, silently reverting it to `""`. Every field in
  an RGD's `status:` block behaves this way; only the ACK child's status is externally writable.
* **What Works Instead:** Patch the **ACK child**, then let kro propagate the value upward:
    ```yaml
    - assert:            # required — `- script:` never retries, so it races kro's child creation
        resource: {apiVersion: cloudfront.services.k8s.aws/v1alpha1, kind: CachePolicy,
                   metadata: {name: ac10-cache-policy, namespace: ns}}
    - script:
        content: |
          kubectl patch cachepolicies.cloudfront.services.k8s.aws ac10-cache-policy -n ns \
            --subresource=status --type=merge -p '{"status":{"id":"cache-policy-id-abc"}}'
    - assert:            # required — wait for kro to propagate before the consumer reads it
        resource: {apiVersion: aws.kropath.run/v1alpha1, kind: CloudFrontCachePolicy,
                   metadata: {name: ac10-cache-policy, namespace: ns},
                   status: {id: cache-policy-id-abc}}
    ```
  Note the **two** asserts: one before the patch (the child must exist) and one after (the parent
  must have propagated) — without the second, the consuming resource reconciles against the
  pre-propagation `""`.

### `forEach` Template Missing `spec.name` on ACK Resources That Require It

* **What Fails:** A `forEach`-based kro resource (e.g. `apiAuthorizers`) creates ACK child CRs
  without `spec.name`. The Kubernetes API server rejects every CR creation because `spec.name` is
  in the CRD's `required:` list. kro logs the error but no CR ever appears. Chainsaw's `assert:`
  times out after 5 minutes with `actual resource not found`.
  ```
  ac4-jwt-authorizer | ASSERT | ERROR | apigatewayv2.services.k8s.aws/v1alpha1/Authorizer ...
  actual resource not found
  ```
* **Why:** Not all ACK CRDs use `metadata.name` as the cloud resource identity. Some — ACK
  `Authorizer`, `API`, `VPCLink` — have a dedicated `spec.name` field that is `required` in the
  CRD OpenAPI schema. The RGD template sets `metadata.name` (the K8s identity) but omits
  `spec.name` (the cloud resource name). The API server validates `spec.name` as required and
  rejects the creation request at admission. The failure is **silent to Chainsaw** — the RGD stays
  `Active`, no error appears on the parent CR status, and the only symptom is the child CR never
  materializing.
* **What Works Instead:** Add `spec.name` to the ACK child template. For `forEach` loops, bind it
  to the loop variable's name field:
    ```yaml
    spec:
      name: ${auth.name}    # required by ACK Authorizer CRD
      apiRef:
        from:
          name: ${schema.metadata.name}
    ```
* **How to catch this before CI:** Check `kropath-core/docs/crd-cache/aws/<controller>.md` for
  every ACK CRD the template targets. Fields marked `required` (without the "(required by AWS API)"
  qualifier that only means "AWS needs it but Kubernetes doesn't enforce it") must appear in the
  template. Cross-reference: the CRD cache note "No `name` field on most CRDs: `API`, `Authorizer`,
  `VPCLink` have explicit `name` fields" — these three are the high-risk cases.
* **Root cause (KRO-564):** `apiAuthorizers` forEach template omitted `spec.name` on the ACK
  `Authorizer` CR. Fixed by adding `name: ${auth.name}` to the spec block.

---

### Config CRs Must Not Set the Same Governance Field in BOTH `mandatory` and `defaults`

* **What Fails:** A `<Service>Config` fixture that sets a field non-empty in both tiers to express
  "mandatory overrides defaults":
    ```log
    CloudFrontConfig.aws.kropath.run "ac1m-cfg" is invalid: <nil>: Invalid value:
      viewerProtocolPolicy must be set in either mandatory or defaults, not both.
    ```
* **Why:** The governance CRDs carry `x-kubernetes-validations` mutual-exclusion rules of the form
  `!(has(self.spec.mandatory.X) && self.spec.mandatory.X != "" && has(self.spec.defaults.X) && self.spec.defaults.X != "")`.
  The rule fires on **non-empty in both**, so the "override" fixture is rejected at admission and
  every step depending on that config fails.
* **What Works Instead:** In the CR **spec**, set the field in one tier only and leave the other
  `""`/`false`. The override behaviour is exercised through the `status.effectiveConfig` patch that
  these suites already perform — that subresource has no mutual-exclusion rule, and it is what the
  RGD actually reads. Deliberate negative tests that assert the rejection are the one exception and
  belong in the `<service>config` suite.

---
### Minimal Fixture CRDs Are a Fallback — Never Apply Them Over a Live ACK CRD

* **What Fails:** A Chainsaw suite opens by unconditionally applying the stub CRDs under
  `tests/fixtures/crds/<service>/`, then a *different* suite fails with an error that names a field
  neither suite mentions:
    ```log
    failed to create typed patch object (acmedomainvalidation/ac4-dv; ...Kind=AcmeDomainValidation):
      .spec.prevalidationOptions.dnsPrevalidation.domainScope.subdomains:
        expected string, got &value.valueUnstructured{Value:true}
    ```
  or an ACK CR that always applied cleanly is suddenly rejected for a missing field:
    ```log
    The AcmeEndpoint "ref-ep" is invalid:
    * spec.certificateAuthority: Required value
    ```
* **Why:** Those fixtures are hand-written **minimal** stubs (their headers say so). They exist so
  a cluster without the real ACK charts can still compile the RGD. `tests/setup.sh` installs the
  genuine ACK CRDs from ECR, so applying a stub on top **replaces the live schema with a narrower,
  possibly mistyped one** — cluster-wide, for every suite running in parallel. It also cuts both
  ways: a stub that is *laxer* than the real CRD (missing a `required:` list, `boolean` where ACK
  says `string`) makes a broken RGD or an incomplete test fixture look green, and the breakage only
  surfaces later against real AWS or once the overwrite is removed.
* **What Works Instead:** Apply the stubs only when a required ACK CRD is genuinely absent — see
  `tests/acm/ensure-acm-prereqs.sh` for the pattern. Keep each stub faithful to the real CRD
  (matching types **and** `spec.required`); diff it against `kubectl get crd <name> -o json` after
  any ACK chart bump.
* **Root cause (KRO-873):** All five ACM suites overwrote the shared `acm`/`acmpca` CRDs on every
  run. Two real bugs were hiding behind it: the RGD emitted booleans into
  `domainScope.subdomains`/`wildcards`, which the real ACK CRD types as `ENABLED`/`DISABLED`
  strings, and a hand-rolled ACK `AcmeEndpoint` in a test omitted the required
  `spec.certificateAuthority`.

---

### Never Delete or Recreate a Shared RGD From Inside a Chainsaw Suite

* **What Fails:** A suite times out in its own preamble, on an RGD that `tests/setup.sh` already
  brought to `Active` minutes earlier:
    ```log
    | acmcertificate | preamble-apply-crds-and-rgds | SCRIPT | ERROR |
    error: timed out waiting for the condition on resourcegraphdefinitions/acmcertificate.aws.kropath.run
    ```
  It passes on the next run, which makes it read as an infrastructure flake.
* **Why:** Suites run concurrently (`chainsaw --parallel 4`) against one kro pod, so
  `kubectl delete rgd` is cluster-wide surgery, not suite-local setup. Two suites that share an RGD
  (`acmprivateca` is used by `acmprivateca`, `acmprivatecertificate` **and** `acmcertificate`) will
  delete it out from under each other. Every delete also makes kro tear down and re-derive the
  generated CRD; several at once regularly blow a 120s wait.
* **What Works Instead:** Verify, do not mutate. `setup.sh` has already applied and waited for every
  RGD, so `kubectl wait rgd <name> --for=condition=Ready --timeout=30s` returns instantly; only
  apply (never delete) if that fails. If an RGD still will not go Ready, fail with kro's own
  condition message.
* **Do not "repair" a stuck RGD by deleting it.** A persistent
  `cannot update CRD ...: breaking changes detected: Property X was removed` means the cluster holds
  a CRD derived from an older revision of that RGD. kro only re-derives on a fresh create, but the
  delete cascades into ACK children whose finalizers are never removed on a cluster running kro with
  no ACK controllers — so it hangs (see §"CANONICAL: Unique-Name-Per-Step + `skipDelete`"). This
  only happens on a long-lived local cluster; CI creates a fresh kind cluster every run. Fix it with
  `make teardown && make setup`.

---

### A Scripted Mass-Edit Across All RGDs Can Leave CEL Unparseable — Run `make lint-rgd-cel`

* **What Fails:** After a bulk edit, one or two RGDs never leave `Inactive`. The suites for those
  kinds fail ~20 minutes later, and the only clue is in the setup step, not the test output:
    ```log
    timed out waiting for the condition on resourcegraphdefinitions/stepfunctionsactivity.aws.kropath.run
      - stepfunctionsactivity.aws.kropath.run: failed to build dependency graph: ...
        parse error: ERROR: <input>:38:50: Syntax error: mismatched input ')' expecting <EOF>
     |   .replace("{configRef}", schema.spec.configRef))).contains("{")
    ```
* **Why:** A rewrite that adds an opening and a closing paren in two separate substitutions stays
  balanced only while *both* patterns match. KRO-977 rewrote `${(schema.spec.nameOverride` →
  `${((schema.spec.nameOverride` and the matching close `))` → `)))`. In the two RGDs whose
  expression already opened with `((`, only the closing rewrite fired.
* **What Works Instead:** Run `make lint-rgd-cel` (`hack/check-rgd-cel-balance.sh`) after any bulk
  RGD edit — it is quote-aware, sub-second, runs with no cluster, and names the file and line. It
  also runs as its own PR job in `.github/workflows/crd-classification-check.yml`. To confirm a
  fix is not merely *balanced* but *correct*, diff the whole expression against a peer RGD the
  script handled properly; after the KRO-873 fix the `namingStatus` blocks in both `stepfunctions`
  RGDs are byte-identical to `gluejob`'s.

---

### Waiting on the Injected Status Field Instead of the One the RGD Reads

* **What Fails:** A cross-resource reference resolves to `""` and the ACK child is then frozen that
  way, so the suite burns its whole 5m assert timeout:
    ```log
    * spec.restAPIID: Invalid value: "": Expected value: "abc123def"
    ...
    Authorizer "ac6-auth" is invalid: spec.restAPIID: Invalid value: "abc123def":
      Value is immutable once set
    ```
* **Why:** The test patched `status.id` on the **ACK** `RestApi` and immediately applied the
  dependent CR. But the consuming RGD reads `status.restApiId` on the **kropath**
  `APIGatewayRestAPI`, which kro surfaces only on a further reconcile hop. The dependent resource
  was created during that window with an empty ID — and many ACK identity fields are
  `x-kubernetes-validations: self == oldSelf`, so the correct value is rejected forever afterwards.
  Whether the hop wins the race varies with cluster load, which is what makes it look flaky.
* **What Works Instead:** Poll for the exact field the RGD consumes before creating the dependent
  resource, and assert it — do not just wait for the value you injected:
    ```bash
    kubectl patch restapi ac6-api -n apigatewayauthorizer \
      --subresource=status --type=merge -p '{"status":{"id":"abc123def"}}'
    for i in $(seq 1 30); do
      [ "$(kubectl get apigatewayrestapis.aws.kropath.run ac6-api -n apigatewayauthorizer \
            -o jsonpath='{.status.restApiId}' 2>/dev/null)" = "abc123def" ] && break
      sleep 2
    done
    kubectl get apigatewayrestapis.aws.kropath.run ac6-api -n apigatewayauthorizer \
      -o jsonpath='{.status.restApiId}' | grep -qx abc123def
    ```

---
