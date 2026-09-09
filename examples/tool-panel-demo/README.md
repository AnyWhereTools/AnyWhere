# Tool panels and clipboard JSON workflows

[简体中文](README.zh.md) · [UI guide](../../docs/plugin-ui.md) · [Manifest](manifest.json)

An importable local pack with Notes and JSON pages, plus real clipboard formatting/compaction workflows. Uses macOS zsh, osascript/JXA and system frameworks, without Node, Python or networking. Demo labels are currently Chinese.

## Import and use

Import this directory from Extension Packs, review scripts and `json-workflow.js`, then enable **便笺**, **JSON** and the desired workflows. The four actions labelled **工作流步骤** are reusable script steps; their standalone search entries can stay disabled. If replacing an older demo, use developer mode's **Reload Local Pack…**, review the update and enable the new workflows replacing the old success/failure demos.

| Entry | Behavior |
| --- | --- |
| 剪贴板 JSON 格式化 | Copy JSON, search this name or use Run in pack details; get two-space-indented JSON in the result and clipboard |
| 剪贴板 JSON 压缩 | Copy multiline JSON and run; get compact single-line JSON in the result and clipboard |

Copy this input:

```json
{"name":"AnyWhere","items":[1,true,null]}
```

Formatting produces:

```json
{
  "name": "AnyWhere",
  "items": [
    1,
    true,
    null
  ]
}
```

Compaction returns the original single line. Copy `{broken` and run: validation fails without replacing the clipboard. Correct and copy the input, then Retry; it restarts at the read step. There is no deliberately failing demo entry.

The JSON page also lets you edit and copy text before running a workflow, then paste results into Notes or another app. Notes and JSON can both open as regular independent windows. Detaching closes the panel session and creates a new one; opening the same detached action again focuses its window. Native toolbar reload recreates the page. Input is session-only and is lost on detach, reload or close; this does not promise the historical prototype's WebView transfer behavior.

## Reused steps and data

```text
read-clipboard ──→ format-json  ──→ write-clipboard
               └→ compact-json ──→ write-clipboard
```

Both workflows reference the same pack's action IDs and share read/write scripts:

```json
{"id":"format-clipboard-json","title":"剪贴板 JSON 格式化","steps":[
  {"action":"read-clipboard"},{"action":"format-json"},{"action":"write-clipboard"}
]}
```

| Step | Input | Output and side effects |
| --- | --- | --- |
| read-clipboard | Ignores initial workflow input | Reads clipboard text, emits `{text, changeCount}`; stops if no text |
| format-json / compact-json | Request-file `input` | Validates JSON, emits transformed `{text, changeCount}` without writing clipboard |
| write-clipboard | Transformed value | Checks clipboard version before writing, then emits a JSON string displayed as plain text |

- `ANYWHERE_REQUEST_FILE` identifies host JSON `{input, invocation}`. Previous stdout JSON becomes the next input. Keep stdout for the result; stderr for diagnostics.
- zsh wrappers pass the operation and request-file path to JXA `run(argv)` in `json-workflow.js`; clipboard text is not inserted into shell source.
- Errors exit nonzero and stop later steps. Retry rereads the clipboard from the beginning.
- `changeCount` detects a newer copy operation and stops replacement. Unsafe integer values are rejected; use strings for large integer IDs.
- Bridge capabilities such as `clipboard.write` constrain WebView calls, not unsandboxed scripts. Scripts here use AppKit to read/write the clipboard and require source review; there is no invented `clipboard.read` capability.
- Pages are `json.html` / `notes.html`, styled by `style.css`. This demo composes same-pack scripts and uses the clipboard to connect manual page use with the workflow. Pages have no start-workflow SDK. For interactive `workflow.context/complete`, see [Response → TypeScript](../tool-chain-demo/README.md). Cross-pack composition is [not implemented](../../docs/cross-pack-workflows.md).

## Runnable check

From the repository root:

```sh
xcodebuild -project AnyWhere.xcodeproj -scheme AnyWhere -configuration Debug \
  -derivedDataPath build \
  -only-testing:AnyWhereTests/LauncherWorkflowTests/testClipboardJSONWorkflowsPreserveInputOnFailure test
```

Executes the pack's scripts and host workflow for formatting, compaction, malformed JSON, empty text, unsafe integers and concurrent clipboard changes. The test uses `ANYWHERE_DEMO_PASTEBOARD` for a temporary named pasteboard, without reading or replacing the system clipboard. Normal use does not require that variable.
