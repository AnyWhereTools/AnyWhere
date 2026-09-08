# Plugin Search and Custom UI

[简体中文](plugin-ui.zh.md) · [Home](../README.md) · [Pack specification](pack-spec.md)

Plugins own local HTML/CSS/JavaScript pages displayed inside AnyWhere's search window. JSON declares entries and capabilities; it does not describe the layout. The page runs browser JavaScript, without a bundled Node/Deno runtime. Reviewed scripts can launch Go/Rust binaries for networking and file processing.

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

Search ignores case and ranks exact, prefix, then substring matches. A title or alias followed by whitespace extracts the remaining argument, preferring the longest matching prefix. Arrow keys select; Return opens, without interrupting IME composition. Empty queries show up to ten recent functions, or alphabetical entries when no usable history exists. Queries and arguments are not saved in history.

Closing the window or pressing the shortcut hides the current session. Back to Search ends it and cancels its task. A new invocation offers to preserve or replace the current operation. Finder UI actions open the same window with a snapshot of selected paths.

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
| `config.get()` | Promise of current action's ordinary configuration, with string values; excludes passwords |
| `storage.get(key)` | Promise of a JSON value, or `null` for a missing key |
| `storage.set(key, value)` / `remove(key)` | Promise; writes/deletes pack-scoped JSON |
| `clipboard.writeText(text)` | Promise; requires `clipboard.write` |
| `tasks.run(input)` | Promise of task handle; requires `task.run` and this action's `script` |

Context fields: `apiVersion`, `invocationID`, `actionID`, `source` (`launcher` / `finder`), `query`, `argument`, `paths`, optional `variant`. Launcher paths are empty; Finder query and argument are empty. Context is immutable per invocation.

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
