# Response tool chain: A → B → C

[简体中文](README.zh.md) · [UI guide](../../docs/plugin-ui.md) · [Manifest](manifest.json)

An importable **same-pack** workflow using three real tools. Each page works alone or inside the host's chain, sharing its implementation and passing intermediate data without the clipboard. These are not three independent extension packs; cross-developer composition is [planned, not implemented](../../docs/cross-pack-workflows.md).

| Tool | Standalone | In the workflow |
| --- | --- | --- |
| A: JSON extractor (`extract`) | Paste logs/text, extract candidates, select and copy JSON | Send the selected object/array to B |
| B: JSON node selector (`select`) | Paste JSON, select and copy a node | Receive A's output and wait for selection before sending it to C |
| C: JSON → TypeScript (`types`) | Paste JSON, name a type and generate code | Receive B's selected data; generate, edit/copy and finish |

## Try it

1. Import this folder in Extension Packs, review the HTML/JS/CSS and enable **接口响应 → TypeScript**. Enable the three tools too if you want to try them separately; their search switches are not required for workflow execution.
2. Search `接口响应`, press Return and enter A. The host shows the three steps.
3. Click **填入示例** (sample), **提取 JSON** (extract) and **交给 B** (send to B).
4. B receives the response automatically. Select `$/data/items` in **数据节点**, preview the two fictional user records and click **交给 C**. No copying/pasting is required.
5. C generates `Response` types containing user fields, with missing `email`/`active` marked optional, without the response's outer `status/data` wrapper.
6. Change the type name and regenerate, edit or copy the code, then click **完成工作流** to show the final result.

Standalone searches: `JSON 提取器`, `JSON 节点选择器`, `JSON 转 TypeScript`, or aliases `extract json`, `select json`, `json ts`. Standalone pages accept pasted input and omit the next-step button. Demo UI labels are currently Chinese.

To refresh an installed copy, enable developer mode, choose **Reload Local Pack…**, review source changes and re-enable changed workflows. Reload Page alone does not copy source files. Sample data is fictional; the demo does not read the clipboard, access the network or write user files. Copy buttons write the clipboard only when clicked.

## Contract and lifecycle

```json
{"id":"response-types","title":"接口响应 → TypeScript","steps":[
  {"action":"extract"},{"action":"select"},{"action":"types"}
]}
```

The host opens each actual WebView, injects the preceding JSON and waits for submission. Tools do not know the next tool's address:

```javascript
const {active, input} = await anywhere.workflow.context();
if (active) renderInput(input);
// After the user finishes:
await anywhere.workflow.complete(output);
```

- Standalone context is `{active:false,input:null}`. Hide the next-step control and retain paste/copy behavior.
- A outputs an object/array, B any selected JSON node, and C a TypeScript string. Intermediate data stays in the host run's memory.
- Complete once; the host switches pages after replying. Standalone submission is denied; duplicates or unfinished backend tasks are busy. Existing 1 MiB bridge limits apply.
- Until `complete`, the host waits. Show validation errors in the page and allow correction; tools cannot choose the next action.
- Back/Close cancels the run. Reload restores the current step's upstream input and discards unsubmitted edits. Active workflow pages cannot detach.
- Standalone tools can open in regular independent windows, creating new sessions and losing unsaved input. Native toolbar reload recreates the session; closing ends it. This demo does not persist drafts.
- Uses schema 4 / UI API 1, requiring a host build with workflow SDK support. These interactive actions have no scripts; actions declaring scripts execute those scripts in workflows.

## Files and limits

- `extract.html`, `select.html`, `types.html`: independent tool pages.
- `tools.js`: host-independent extraction, node lookup and type inference. Key-path arrays support dots/slashes in keys without `eval`.
- `ui.js`: input, buttons and completion. Text/form APIs render user content without treating logs as HTML.
- `style.css`: system fonts, light/dark appearance and keyboard focus styling.

Extraction accepts objects/arrays with candidate selection, at most 128 KiB input, 64 levels and 2,000 data nodes. Unsafe JavaScript integers are rejected. Type inference checks every array sample, merges fields/unions and marks missing fields optional; empty arrays produce `Array<unknown>`. Sorted fields keep standalone and workflow output consistent. Sample inference cannot determine dates, enums or business-required fields; review generated types.

## Runnable checks

From the AnyWhere repository root:

```sh
xcodebuild -project AnyWhere.xcodeproj -scheme AnyWhere -configuration Debug \
  -derivedDataPath build -only-testing:AnyWhereTests/ToolChainTests test
```

The suite covers algorithms, real A→B→C WebViews, waiting at B, reload with upstream input, matching standalone/workflow C output, denied standalone and duplicate submission, and cancellation. It does not write the system clipboard. This README documents the check; it is not a claim that cross-pack execution was tested.
