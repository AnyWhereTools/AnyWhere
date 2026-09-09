# Cross-developer, cross-pack workflows: design and implementation plan

[简体中文](cross-pack-workflows.zh.md) · [UI guide](plugin-ui.md) · [Pack specification](pack-spec.md)

**Status: planned, not implemented. This document publishes neither a new SDK nor an importable manifest and makes no cross-pack verification claim.** Today `steps[].action` resolves only inside its own manifest and `actions` cannot be empty. The [Response → TypeScript demo](../examples/tool-chain-demo/README.md) demonstrates same-pack reuse.

## Goal and scope

Developer A publishes a JSON extractor, B a JSON node selector, and C a TypeScript generator. Each tool installs and works independently, without depending on the others. A third party or user publishes a fourth, workflow-only pack that declares A's public entry → B's public entry → C's public entry. Tool authors need not know other tools or change/copy their implementation for each composition. The host resolves dependencies, passes data, displays the real tool pages and owns execution.

The first version supports ordered steps mixing scripts and interactive UI. Branches, loops, parallelism, nested workflows, remote invocation and automatic execution recovery are outside its scope.

## Identity and public contracts

Names below are **design proposals**, not current manifest or SDK fields. Freeze the exact format and version gate before implementation.

| Element | Proposed contract |
| --- | --- |
| Stable pack ID | Immutable publisher-namespaced ID such as `dev.alpha.json-extractor`, independent of Git URL, local path, display name and installed key |
| Stable tool ID | Immutable entry ID such as `extract`; address an entry by pack ID + tool ID, never title, keyword or machine-local UUID |
| Public entry | Explicit export bound to a local action, execution mode (script or interactive UI), contract version, input and output definitions; private actions cannot be called across packs |
| Input/output | Bounded JSON with validated structure, required fields, size limits, errors and declared side effects; validate input before invocation and output before handoff |
| Workflow pack | Own identity, metadata, dependencies and steps; may omit tool actions and reference public entries only, without copying scripts or reading dependency-private files |
| Versions | Separate package versions from entry contract versions; dependencies declare supported ranges, and the host locks installed versions and resource digests for each run |

Conceptual references (**not a JSON manifest**):

```text
user.response-types
  dev.alpha.json-extractor / extract @ contract 1
  dev.beta.json-selector   / select  @ contract 1
  dev.gamma.ts-generator  / types   @ contract 1
```

The existing demo suggests these data contracts: A takes text and emits an object/array; B takes JSON, waits for selection and emits any JSON node; C takes JSON and emits a TypeScript string. Incompatible contracts must be blocked or require explicit author-defined mapping. The host must not guess field conversions; a general mapping-expression engine is unnecessary for the first version.

A pack ID is not proof of trust. Store the reviewed source-to-identity binding. If two sources claim the same ID, block silent replacement and require source selection; updates must retain that binding. A namesake pack must not take over existing dependencies. Preserve old source-derived keys, configuration and data without automatic identity migration.

## Host execution, permissions and lifecycle

1. **Resolve the whole chain first.** Look up installed public entries, validate versions, contracts, execution modes, enablement and grants, then freeze an execution plan. Missing or incompatible dependencies stop the run before any step produces side effects.
2. **Execute as the target tool.** Each step uses its target pack's resource root, action settings, secrets and storage. The workflow pack does not inherit or pool tools' permissions. Tools cannot read previous packs' private storage or settings through the bridge.
3. **Pass only declared data.** Transfer JSON through host memory, without clipboard or shared temporary-directory shortcuts. Treat JSON as data, never shell/JavaScript source. If large-file transfer becomes necessary, design scoped, expiring host handles separately; an arbitrary path is not authorization.
4. **Authorize the composition.** Show each publisher/source, entry, side effects and data destination when enabling a workflow. Standalone search switches control discovery; a separate composition grant controls external invocation. Disabling search does not revoke that grant. Revoking a step's grant terminates affected runs.
5. **Advance real entries serially.** Validate script output; display interactive pages and await one submission. Reuse the page experience of `workflow.context/complete`, while binding host sessions to run ID, step ID, target identity and locked version. Tools cannot choose the next target.
6. **Cancel safely on change.** Preserve reload-with-upstream-input, Back/Close cancellation and stale-submission rejection. Before updating, reloading, uninstalling or revoking a dependency, cancel and await every affected run/task. A run must not mix resource versions.
7. **Explain failures and retries.** Identify the failed pack, entry and step with an actionable cause. Stop by default without skipping. Retry starts over and may repeat completed side effects; do not promise rollback or crash recovery. Do not persist full inputs, outputs or secrets in default run logs.

This proposes isolation of host bridge access, resources, settings and data. Current scripts execute as the user with **no OS sandbox**. Composition grants must not be described as strong containment of arbitrary scripts. That guarantee would require a separate process-sandbox and file-authorization design.

## Versions and missing dependencies

- Introduce an explicit new manifest version or negotiated feature gate so old clients reject cross-pack manifests. Do not hide proposed fields inside today's schema 4, where unknown fields are ignored.
- Distinguish missing packages, private/missing entries, incompatible contracts, identity collisions and absent grants. Offer source inspection and install/update/authorization actions. Dependency installation must use the existing review flow, without automatic code download and execution.
- Support one installed version per pack initially. Conflicting workflow requirements block affected runs rather than silently choosing the latest version. Show composition differences after dependency, contract or permission changes and require renewed review.

## Implementation sequence and acceptance gates

| Stage | Minimum change boundary | Exit condition |
| --- | --- | --- |
| 1. Freeze format | Extend `PackManifest` for stable identity, exports, versions, dependencies and workflow-only packs, retaining old parsing | Legacy imports work; old clients reject cross-pack manifests; identity collisions and invalid references have checks |
| 2. Install and resolve | `PackManager` stores reviewed source bindings, indexes exports and resolves the whole chain | Missing/version-conflicting/private entries block before execution; migration preserves data/settings |
| 3. Execute | Extend existing launcher/workflow dispatch to select target sessions, settings and resource roots per step | Mixed script/UI runs use target permissions; data validation, cancellation and stale-submission protection pass |
| 4. Review and revoke | Pack details show dependencies and composition grants; updates/uninstall find every affected run | Permission changes trigger review; tasks end before replacement; no silent privilege expansion |
| 5. Four-pack acceptance | Three independent tool packs plus a fourth workflow pack, with examples and bilingual documentation | All real checks below pass before claiming cross-pack support |

Format, resolution and execution share contracts, so establish format and resolution serially before execution and authorization UI. This documentation task does not start those production changes.

Acceptance uses four independently imported folders/repositories and different tool publisher identities. The three tools must have no dependencies on each other:

- A, B and C each work alone and remain usable after removing the workflow pack.
- The fourth pack contains dependencies and steps only, with no tool implementation. A → B → C opens real pages, B waits for selection, outputs pass directly, and C matches standalone output for the same input.
- The workflow author can reorder entries or replace C with a compatible entry without changing A/B source; incompatible contracts fail explicitly.
- Missing B, wrong versions, private entries, same-ID/different-source collisions and denied grants fail before step one, without partial side effects.
- Host checks cover cancellation, current-page reload, duplicate/stale submissions, grant revocation and dependency updates/uninstall; expired resources cannot continue running.
- Use distinct packs' actual storage, settings and permissions to check isolation, while recording the OS-sandbox limitation. Three pages bundled together are not cross-developer acceptance.

Run focused parser and dispatch checks first, then one four-pack host and real-interaction pass after code review and scope freeze. Record source inspection, automated tests and manual interaction separately; existing same-pack checks do not satisfy this gate.
