# AnyWhere Developer Documentation

English · [简体中文](README.zh.md) · [Project home](../README.md)

Start here to build plugins or contribute to the host. These guides describe the current source tree. Releases may lag behind it: use a host build containing the required feature and check availability as described in each guide. `schemaVersion: 4` / `uiApiVersion: 1` alone does not guarantee every newer method exists.

## Choose a starting point

| Goal | Reading path |
| --- | --- |
| Build a UI plugin | Quickstart below → [UI SDK and lifecycle](plugin-ui.md) → [TypeScript declarations](sdk/anywhere.d.ts) |
| Add Finder scripts | [Pack specification](pack-spec.md) → [Basic example](../examples/example-pack/README.md) |
| Add reminders | [Notification guide](plugin-notifications.md): capabilities, presentations, button events, snooze and completion |
| Show a search-home summary | [Summary guide (Chinese)](plugin-summaries.zh.md): `summary.html` and read-only storage |
| Compose tools | [Same-pack workflows](plugin-ui.md#same-pack-workflows-scripts-and-interactive-tools) → [Tool-chain example](../examples/tool-chain-demo/README.md) |
| Contribute to the host | Source map below → [Contributing](../CONTRIBUTING.md) → [Releasing](RELEASING.md) |

## Run your first UI plugin

An installed AnyWhere app and HTML/CSS/JavaScript are enough to develop a plugin. You do not need to compile the host or install a Node runtime.

1. Copy [examples/ui-tool-pack](../examples/ui-tool-pack/) to a stable development directory. It contains root `manifest.json`, page `ui/index.html`, and demo backend `actions/demo.zsh`.
2. In AnyWhere, choose **Extension Packs → Import → Choose Local Folder…**, review the files and import. Enable **Search** for “文本工具”. Search and Finder context-menu switches are independent.
3. Press the default shortcut `Control+Option+Space`, type `text hello`, and press Return. The page receives `hello`. Try uppercase conversion, copying, saving a draft and cancelling a backend task.
4. Enable developer mode in General, edit the source page, then **Reload Local Pack…**, review and apply the update, and reopen the tool. Web Inspector is available for newly created pages.

**Reload Local Pack** copies source files into the installed snapshot. **Reload Page** only recreates a session from that snapshot. Closing, reloading or detaching ends the old session: persist data with `anywhere.storage` first. Keep the source directory and action IDs stable to preserve identity.

The host injects `window.anywhere`; do not load an SDK from the network. See the [minimal manifest](plugin-ui.md#manifest) and use [anywhere.d.ts](sdk/anywhere.d.ts) for editor completion.

## Capabilities and API reference

| Feature | Page API | Declaration and reference |
| --- | --- | --- |
| Invocation and reactivation | `onEnter`, `getInvocation` | [UI SDK](plugin-ui.md#injected-sdk-api-1); no extra capability |
| Configuration and plugin data | `config.get`, `storage.get/set/remove` | [Data and lifecycle](plugin-ui.md#data-and-lifecycle); no extra capability; configuration excludes passwords |
| Clipboard | `clipboard.writeText` | Declare `clipboard.write` on the action |
| Scripts or Go/Rust backends | `tasks.run` | Declare `task.run` and `script`; see [backend tasks](plugin-ui.md#backend-tasks) |
| Large text files and drafts | `documents.*` | Declare `documents`; see [host services](plugin-services.md) |
| Dynamic search entries | `launcher.setEntries/open` | Declare `launcher.entries`; see [host services](plugin-services.md) |
| Notifications and buttons | `notifications.status/replace` | Declare `notifications` and enable Search; see [notification guide](plugin-notifications.md) |
| Workflow input and output | `workflow.context/complete` | [Current same-pack step](plugin-ui.md#same-pack-workflows-scripts-and-interactive-tools); no extra capability |

Declare `capabilities` on the corresponding manifest action. The host validates calls against the actual page and installed source. Page capabilities do not sandbox a bundled script's system access. Pages cannot connect directly to the network; use reviewed backend tasks for that work.

### Notification ownership

**AnyWhere provides notifications; plugins decide how to use them.** The host offers `system` notifications and `panel` reminder windows, handling scheduling, permission, presentation, cancellation and button-event routing. Plugins own presentation preferences, content, buttons and business data.

For example, Todo defines Snooze and Complete. Todo chooses five minutes or one hour and saves the new deadline, or saves `done = true`, then calls `replace` with **all remaining reminders for the action**. The host neither understands Todo state nor chooses a snooze duration.

The [notification guide](plugin-notifications.md) covers samples, seconds versus milliseconds, full replacement, event deduplication, failures and testing. macOS controls system-notification styles; panels require AnyWhere to run, but the plugin page may close.

## Importable examples

| Example | Demonstrates |
| --- | --- |
| [Basic pack](../examples/example-pack/README.md) | Scripts, matching and submenus |
| [Text Toolbox](../examples/ui-tool-pack/README.md) | UI, invocation, storage, clipboard and cancellable tasks |
| [Independent windows](../examples/detached-panel-demo/README.md) | Windows and page state |
| [Clipboard JSON workflows](../examples/tool-panel-demo/README.md) | Same-pack script composition |
| [Response → TypeScript](../examples/tool-chain-demo/README.md) | Interactive same-pack tool chains |
| [Xlog Decoder](../examples/xlog-decoder-pack/README.md) | Bundled CLI, suffix matching and password configuration |

Todo lives in the separate `anywhere-todo` repository. The host's [OfficialPluginTests.swift](../AppTests/OfficialPluginTests.swift) loads its real page for integration testing. See the notification guide for directory requirements and selected test commands.

## Host development and testing

See [Contributing](../CONTRIBUTING.md) for build prerequisites, signing configuration, localization and contribution practices. Basic source commands:

```sh
make gen           # Install xcodegen if needed; generate local project/configuration
make test          # Core unit tests
make test-presets  # Preset script tests
make run           # Build Debug and launch AnyWhere
```

| Area | Source entry |
| --- | --- |
| Manifest, capabilities, data and validation | [AnyWhereCore](../Core/Sources/AnyWhereCore/) |
| Import, installation and update review | [PackManager.swift](../App/Managers/PackManager.swift) |
| WebView and injected SDK | [PluginSession.swift](../App/Plugins/PluginSession.swift) |
| Notification scheduling and routing | [PluginServices.swift](../App/Plugins/PluginServices.swift), [PluginReminderPanel.swift](../App/Plugins/PluginReminderPanel.swift) |
| Search, windows and workflows | [App/Plugins](../App/Plugins/) |
| Search-home summaries | [PluginSummaryHost.swift](../App/Plugins/PluginSummaryHost.swift) |
| Finder extension | [FinderExtension](../FinderExtension/) |
| Host integration tests | [AppTests](../AppTests/) |

Current [CI](../.github/workflows/ci.yml) runs Core tests, preset tests and an App/FinderExtension compile check, not host WebView tests. `make test` also excludes `AppTests`. Generate the project first, then run Xcode tests as described in [Contributing](../CONTRIBUTING.md#tests); official-plugin tests also require plugin source checkouts. Compilation does not replace interactive Finder, window or Notification Center acceptance checks.

## Troubleshooting

| Symptom | Check first |
| --- | --- |
| Imported plugin is missing from search | Enable its action's Search switch; Finder enablement is separate |
| Source edits do not appear | Reload Local Pack before reopening the page |
| Input disappears after reopening | Save through host storage; do not rely on WebView localStorage |
| API is missing or returns `denied` | Host feature availability, action capabilities and session validity |
| Todo saves but no reminder appears | `replace.errors`, system authorization and a running host for panels; see [notifications](plugin-notifications.md) |

## Designs and implementation records

These explain background rather than define released APIs:

- [Cross-pack workflow design](cross-pack-workflows.md): planned, not implemented; current workflows compose same-pack actions only.
- [Three official plugins (Chinese)](three-plugins-plan.zh.md): implementation record; use the guides for API contracts.
- [Plugin marketplace research (Chinese)](research/siyuan-plugin-marketplace.zh.md): research reference.

When changing a contract, update its guide and [SDK declarations](sdk/anywhere.d.ts), and add navigation here. Mark plans, experiments and test records with their status so they cannot be mistaken for released features.
