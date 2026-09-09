# Plugin Search and Custom UI

[简体中文](plugin-ui.zh.md) · [Home](../README.md) · [Pack specification](pack-spec.md)

Plugins own local HTML/CSS/JavaScript pages displayed in AnyWhere's tool panel or a regular independent window. JSON declares entries and capabilities; it does not describe the layout. The page runs browser JavaScript, without a bundled Node/Deno runtime. Reviewed scripts can launch Go/Rust binaries for networking and file processing.

## Manifest

```json
{
  "schemaVersion": 4,
  "uiApiVersion": 1,
  "name": "Text Tools",
  "actions": [{
    "id": "text", "title": "Text Tools",
    "launcher": {"keywords": ["text"]},
    "contextMenu": false,
    "ui": {"entry": "ui/index.html", "height": 420},
    "capabilities": ["clipboard.write"]
  }]
}
```

`script` is optional for UI actions. Declaring both loads the page without executing the script; use `tasks.run` explicitly. Script-only actions can also have launcher entries and receive structured context through the request file. `contextMenu` defaults to `true`. Every action needs a user entry and either a page or a script. Keep action IDs stable.

`ui.entry` must resolve to an HTML file inside the pack, including after symlink resolution. A positive `height` is constrained to the available screen area. Declaring `launcher` registers search; `keywords` can be omitted or empty. Titles are always searchable.

## Entry points

Imports start with both entries disabled. Enable **Context Menu** and **Search** independently in the pack details; configuration forms also work for search-only actions. General settings record or disable the global shortcut, initially `Control+Option+Space`. Registration failure preserves the previous shortcut. The menu bar also offers Open Plugin Search.

Search includes enabled tools, custom shortcut actions and same-pack workflows, followed by matching installed applications. It ignores case and supports names, full pinyin and pinyin initials. Tool/action/workflow titles rank before aliases, then pack descriptions (or pack names when no description exists); within each group, literal exact/prefix/substring matches precede transliterated matches. A literal title or alias followed by whitespace extracts the remaining argument, preferring the longest matching prefix; pinyin matching alone does not extract arguments. Arrow keys select; Return opens, without interrupting IME composition. Empty queries show recent entries only and an empty-state hint when none exist. Queries and arguments are not saved in history.

In **Shortcuts**, create an editable local script action, set its name and keywords, enable it, and optionally record a global hotkey. New custom actions start disabled and are separate from Finder context-menu actions. Pack shortcuts allow a local display name, keyword aliases and enablement; their implementation remains in the pack. Workflow enablement and Run are in pack details; workflows currently have no manifest keyword or per-workflow hotkey field.

### Tool panel and independent windows

Opening a UI action replaces the search results with its tool page. The search state hides on deactivation; an open tool stays visible. Back, Close, or toggling the launcher closed ends the panel session and cancels its task. A new invocation offers to preserve or replace the current operation. Finder UI actions use the panel with a snapshot of selected paths.

**Open in Independent Window** closes the panel session and creates a new session in a normal, resizable macOS window with close/minimize/zoom controls. It does not transfer the existing WebView or unsaved page state. Different tools can stay open together; opening an already detached action focuses its existing window. These windows remain visible when another app is active. Closing one ends its session and cancels its task. Use host storage for data that should survive session recreation.

The independent window has a native **Reload Page** toolbar button. Reload ends the old session/task and loads the installed page into a new session; unsaved page state is lost. The tool panel has its own reload control. Neither reload copies edits from the source folder: use **Reload Local Pack…** in developer mode first, review the update, then reopen the tool. Workflow steps cannot be detached.

## Injected SDK (API 1)

No SDK download is required. Copy the [TypeScript declarations](sdk/anywhere.d.ts) into your editor project. The importable [Text Toolbox example](../examples/ui-tool-pack/README.md) demonstrates persistence, clipboard and a cancellable backend.

```javascript
anywhere.onEnter(async context => {
  textarea.value = context.argument || await anywhere.storage.get('draft') || '';
});
await anywhere.storage.set('draft', 'Hello');
await anywhere.clipboard.writeText('Hello');
```

| API | Contract |
|---|---|
| `onEnter(callback)` | Delivers context once after readiness, including late subscribers; returns unsubscribe |
| `getInvocation()` | Promise of the same context object |
| `workflow.context()` | Promise of `{active, input}`; standalone pages return `{active: false, input: null}` |
| `workflow.complete(output)` | Submit one JSON result from the current interactive workflow step; host chooses the next step |
| `config.get()` | Promise of current action's ordinary configuration, with string values; excludes passwords |
| `storage.get(key)` | Promise of a JSON value, or `null` for a missing key |
| `storage.set(key, value)` / `remove(key)` | Promise; writes/deletes pack-scoped JSON |
| `clipboard.writeText(text)` | Promise; requires `clipboard.write` |
| `tasks.run(input)` | Promise of task handle; requires `task.run` and this action's `script` |

Context fields: `apiVersion`, `invocationID`, `actionID`, `source` (`launcher` / `finder`), `query`, `argument`, `paths`, `finderPath`, optional `variant`. `actionID` is the installed action UUID, not the manifest's local action ID. Launcher paths are empty; Finder query and argument are empty. `finderPath` is the captured Finder directory, falling back to the user's home directory, also available to scripts as `ANYWHERE_FINDER_PATH`. Context is immutable per invocation.

The host binds requests to the original main page, session and installed plugin. Failed promises include `message` and a stable `code`: `invalidArguments`, `denied`, `sessionClosed`, `busy`, `failed`, `timedOut`, `cancelled`, `outputLimit`, `storageLimit`. Messages and responses are limited to 1 MiB. Discard handles after the session ends.

## Backend tasks

```javascript
const task = await anywhere.tasks.run({text: 'Hello'});
const unsubscribe = task.onOutput(({stream, text}) => { output.textContent += text; });
// await task.cancel();
const result = await task.result;
unsubscribe();
if (result.error) console.error(result.error.code, result.error.message);
```

Only the current action's declared script can run, never an arbitrary command or executable path. Tasks use `/bin/zsh`, selected-path arguments and `ANYWHERE_CONFIG_<KEY>`, with the installed pack root as working directory. `ANYWHERE_REQUEST_FILE` points to a private temporary JSON file, mode `0600`:

```json
{"input":{"text":"Hello"},"invocation":{"apiVersion":1,"source":"launcher","query":"text Hello","argument":"Hello","paths":[]}}
```

UUID fields are omitted above. Parse the file as data; never interpolate it into shell source. It is removed when the task ends. Scripts may launch bundled Go/Rust binaries; authors provide compatible architecture, OS and dependencies and preserve executable permissions.

One task runs per page; overlapping runs fail with `busy`. Output events identify `stdout` or `stderr`, preserve UTF-8 boundaries and redact configured passwords across pipe chunks. Raw combined output is limited to 4 MiB; exceeding it ends the task. `result` contains `exitCode`, up to 32768 characters per stream as summaries, and `error` (`null` on success). Subscribe to events for full output. Cancellation and timeout send SIGTERM, then terminate the managed group after at most two seconds. Backends are one-shot tasks, not daemons, and must not detach from the process group.

## Same-pack workflows: scripts and interactive tools

Declare `workflows[].steps[].action` using action IDs from **the same manifest**; see the [pack specification](pack-spec.md#same-pack-workflows). A script step executes automatically. A UI-only step opens the tool's real page and waits for user submission. An action with both `ui` and `script` executes its script when used as a workflow step, even though opening it independently loads its UI. A workflow can mix script and UI-only steps.

Use a host build that includes the workflow bridge. Older schema-4/API-1 builds may lack `anywhere.workflow`; check its presence before calling and handle rejected calls. The API version alone does not guarantee these methods exist.

The first input is the launch argument string (empty when absent). Each script receives `{input, invocation}` through `ANYWHERE_REQUEST_FILE`; its full captured stdout is decoded as JSON, falling back to a string if parsing fails. Keep stdout for one result and stderr for diagnostics. Failure stops subsequent steps; Retry starts from the first step. This does not roll back completed side effects.

```javascript
const {active, input} = await anywhere.workflow.context();
if (active) showInput(input);
// After the user finishes, submit a JSON value (including null).
await anywhere.workflow.complete(output);
```

`active` distinguishes a workflow input of `null` from standalone use. Completion requires the active step, not an extra capability. Standalone submission fails with `denied`; duplicate submission or an unfinished backend task fails with `busy`; missing/invalid output or an oversized request fails with `invalidArguments`. The existing 1 MiB bridge request/response limits apply. The page cannot choose another action, launch a workflow or skip steps. After the completion reply, the host closes the old session and advances; do not rely on that page for further work.

Intermediate JSON stays in the running host's memory. Reload recreates the current interactive step with the same upstream input, losing its unsubmitted edits. Back/Close cancels the workflow; stale pages cannot advance a replacement run. Disabling the workflow ends it; updating/reloading/uninstalling the pack ends its sessions before replacing files. Only the workflow entry must be enabled to run its steps; standalone search switches need not be enabled. Changed workflow definitions or expanded step capabilities disable the workflow after an update for review.

Import [Clipboard JSON workflows](../examples/tool-panel-demo/README.md) for real script composition, or [Response → TypeScript](../examples/tool-chain-demo/README.md) for A extracts JSON → B waits for node selection → C generates types. Each tool in the latter can also open independently, but all three still ship in **one pack**. Cross-developer, cross-pack composition is **planned, not implemented**: see the [design and implementation plan](cross-pack-workflows.md).

## Data and lifecycle

- `PluginData/<packKey>/data.json` provides 5 MiB per pack, shared by its actions. Keys must be nonempty, at most 1024 UTF-8 bytes. Atomic writes preserve old data on limit failure.
- Ordinary settings remain in `PackConfigurations/`; passwords remain locally encrypted in `PrivateData/`, managed by native forms. Pages cannot bulk-read passwords; the host loads them into task configuration variables.
- Directories use `0700`, plugin data files `0600`. WebView data is nonpersistent; use host storage instead of relying on localStorage.
- Pages load local pack resources only: no direct network, remote scripts or iframes. User-activated HTTP(S) links open in the system browser. Only the original main page receives the bridge.
- Capabilities constrain the page/host interface. Scripts and binaries still run with the current user's permissions, not an OS sandbox. Review all bundled files.
- Updates preserve identity and data; expanded capabilities disable the affected entries for review. Old sessions/tasks end before replacing installed files.
- Uninstall retains data by default. An optional checkbox deletes configuration, passwords and plugin data; failures are reported. Reinstalling the same source recovers retained data; changing source path creates a different identity.

## Development

Enable developer mode in General settings to inspect newly created pages with Web Inspector and review/reload local source folders. Reload Page recreates a session from the installed copy; it does not copy source changes. JavaScript errors and task failures appear in the host header; pages subscribe to task output.

Handle Escape with `event.preventDefault()` to dismiss page overlays; unhandled Escape returns to search. Pages should adapt to window sizes and provide accessible labels and keyboard interaction. Arbitrary native windows and Node APIs are not provided.

See [host services](plugin-services.md) for large documents, dynamic launcher entries and scheduled notifications, requiring `documents`, `launcher.entries` and `notifications` respectively. Ordinary bridge/storage limits are unchanged. `onEnter` also fires when an existing page is activated again.
