# AnyWhere

**A macOS launcher, plugin host and Finder context-menu manager — with local MCP access.**

English · [简体中文](README.zh.md)

[Plugins](https://github.com/AnyWhereTools/anywhere-bazaar) · [Developer docs](docs/README.md) · [Local MCP guide (Chinese)](docs/mcp.zh.md) · [Releases](https://github.com/AnyWhereTools/AnyWhere/releases)

AnyWhere brings apps, scripts and plugin tools into one keyboard-driven workspace. Search
with `Control+Option+Space`, open custom tool pages, manage Finder actions, and let MCP clients
call explicitly authorized plugin commands. Plugins can add persistent data, reminders and
search-home summaries without building a native app.

Open source under **MIT**, built with **SwiftUI + Finder Sync + WebKit**, for **macOS 13 Ventura+**.
The main app runs outside the sandbox; the Finder extension is sandboxed. UI in **English / 简体中文**.
The features below describe the current source; check release notes for availability in a packaged build.

---

## What you can do

| Area | Capabilities |
| --- | --- |
| Launcher | Find apps, plugins and local shortcuts by name, alias, pinyin or initials |
| Plugin tools | HTML/CSS/JS pages, independent windows, local storage and cancellable backends |
| Finder | Editable zsh actions, system Quick Actions / Services visibility and third-party extension toggles |
| Reminders and summaries | Plugin-defined notifications or reminder panels, plus pinned search-home summaries |
| Automation | Same-pack workflows and opt-in plugin commands through a bundled stdio MCP server |

**Script-first and extensible.** Even built-in Finder actions are editable zsh scripts.
Import reviewed plugins from Git repositories or local folders, then enable only the entries you need.

## Get started

1. [Build and launch AnyWhere](#install--build-from-source), then complete onboarding. Enable the Finder extension to use context-menu actions.
2. Open **Extension Packs** and browse the [Bazaar](https://github.com/AnyWhereTools/anywhere-bazaar), or import a Git URL / local folder. Review the files before installing.
3. Enable the desired **Search** or **Context Menu** entries in pack details; these switches are independent and start disabled.
4. Press `Control+Option+Space`, search for a tool, and press Return. Configure plugin settings, summaries or MCP access as needed.

### Plugins to try

| Plugin | Use it for |
| --- | --- |
| [Todo](https://github.com/AnyWhereTools/anywhere-todo) | Task lists, deadlines and reminders |
| [JSON Tools](https://github.com/AnyWhereTools/anywhere-json-tools) | JSON editing, formatting and persistent drafts |
| [Quicklinks](https://github.com/AnyWhereTools/anywhere-quicklinks) | Searchable websites and URL templates |
| [Tool Chain Demo](https://github.com/AnyWhereTools/anywhere-tool-chain-demo) | Interactive response → node selection → TypeScript workflows |

---

## Features

### Script-first custom actions, fully configurable

Every action is a zsh script (or an inline snippet, or “open with an app”). Give it a custom
icon (SF Symbol + tint, or import your own image), choose files / folders / empty area, and
set selection-count limits. The custom-action editor uses **literal file suffixes**, such as
`xlog, log, tar.gz`. Matching ignores case; a leading dot is optional, and an empty list means
no suffix restriction. Wildcards and regex are not accepted in this field.

Existing UTI rules are preserved for compatibility. Editing suffixes or choosing **Use Suffix
Matching** replaces those rules; changing a title or icon keeps them intact.

### Manage the *whole* right-click menu, not just your own items

One screen previews your menu, with a “simulate target” switch (image / file / folder / empty
area). The category preview approximates type filters; filename regex is evaluated against real
filenames in Finder. Items are grouped by how much AnyWhere can control them:
**●** your own & pack actions (reorder, toggle; pack scripts and matching rules are read-only),
**◐** system Quick Actions & Services (hide), **○** third-party extensions (toggle).

### Switch terminal / editor without editing scripts

Pick your default terminal and editor in **General**; the “Open in Terminal / Editor” presets
honor your choice via injected env vars — no script changes needed.

### Plugin search and custom UI

Press `Control+Option+Space`, search an installed plugin by title or alias, and press Return
to open its HTML/CSS/JS page inside the same window. Change or disable the shortcut in General,
or open search from the menu bar. Pack details provide independent **Search** and **Context Menu**
switches; both start disabled after import.

Pages can persist pack data, write to the clipboard and run cancellable scripts or bundled
Go/Rust backends without a Node runtime. See the [UI guide](docs/plugin-ui.md) and importable
[Text Toolbox](examples/ui-tool-pack/README.md). UI pages require schema 4 or later; versions 1–3 remain supported for earlier pack features.

Search also supports full pinyin and initials, enabled custom shortcuts, same-pack workflows
and installed applications. **Shortcuts** lets you create local scripts with names, keywords
and optional global hotkeys; Finder menu actions remain separate.

UI tools can open in regular independent windows with native window controls and a native
Reload Page toolbar button. Detaching/reloading creates a new session, so save drafts through
host storage. Closing the tool panel ends its session; independent windows stay open while
you work in other apps. See the [window lifecycle](docs/plugin-ui.md).

Try [Clipboard JSON workflows](examples/tool-panel-demo/README.md) for real script steps, or
[Response → TypeScript](examples/tool-chain-demo/README.md) for interactive A → B → C tool
pages. Import and review the pack, then enable each desired tool/workflow in pack details.
These workflows currently reference tools **within one pack**. Cross-developer, cross-pack
composition is [planned, not implemented](docs/cross-pack-workflows.md).

### Reminders and search-home summaries

Plugins can schedule macOS notifications or AnyWhere reminder panels, with buttons such as
Snooze and Complete. The plugin owns task state and button behavior; AnyWhere handles scheduling
and presentation. Panels require AnyWhere to stay running, but the plugin page may close.
See the [notification guide](docs/plugin-notifications.md).

Plugins with a `summary.html` page can be pinned to the search home. Summaries read their own
plugin's stored data; clicking a summary opens the full tool. See the
[summary guide (Chinese)](docs/plugin-summaries.zh.md).

### Local MCP and plugin commands

The bundled `anywhere-mcp` helper exposes explicitly authorized plugin commands to MCP clients
over stdio. Enable **Allow calls through AnyWhere MCP** in the plugin's settings and register
`/Applications/AnyWhere.app/Contents/MacOS/anywhere-mcp` as your client's server executable
(adjust the path if installed elsewhere). **AnyWhere must remain running.**

The `list` tool discovers authorized plugins and their operation schemas. Plugins using
manifest schema 5 declare which commands they export; an installed plugin must include these
declarations to be callable. Revoking access blocks later calls. This is local
integration, not a remote service; other processes running as the same macOS user can also
call authorized functionality. See the [MCP setup and command contract (Chinese)](docs/mcp.zh.md).

### Importing packs

An extension pack is a folder with a root `manifest.json` and its scripts. In **Extension Packs
→ Import**, paste a Git URL / `owner/repo`, or choose **Choose Local Folder…**; a local pack
does not need Git. AnyWhere clones or copies the pack, asks you to review its scripts and
additional files (including bundled CLIs), and adds its actions **disabled**.

Local imports preserve executable permissions and install a snapshot: moving or editing the
source folder does not change the installed copy. Local packs do not check Git updates. To
replace one, use **Reload Local Pack…** in developer mode, or uninstall and import again;
duplicate imports are rejected.

### Plugin configuration: save once, reuse on every run

Packs can declare **text, password, toggle and dropdown** fields. Select a pack action under
**Context Menu**, fill in **Plugin Configuration**, and click **Save Configuration**. Scripts
receive saved values through `ANYWHERE_CONFIG_<KEY>` without asking for them on each run.
**Clear Configuration** removes saved values and restores defaults.

App data stays in `~/Library/Application Support/AnyWhere/`. Passwords are encrypted locally
with AES-256-GCM; ordinary settings remain local JSON files. Configuration reads and writes
do not access Keychain or ask for a system password.
Updates retain values for stable action IDs and field keys. Uninstalling retains configuration
for reimport from the same source; optionally delete configuration, passwords and plugin data
together in the uninstall dialog. Search-only actions have configuration forms in pack details.

**Upgrading from Keychain storage:** enter and save the password fields once again. The app
does not read or delete old Keychain entries. Back up the entire `PrivateData/` directory,
including both `key` and `secrets.enc`; a copy of the ciphertext alone cannot be restored.

### Pack matching: UTI, suffix and filename regex

Pack authors can declare UTI conformance filters (`utis`), case-insensitive literal suffixes
(`extensions`), and a whole-filename regex (`filenamePattern`, case-insensitive by default).
An item must match **a UTI or suffix**, then satisfy the regex if supplied. If both type lists
are empty, type is unrestricted. **Every selected item** must pass; the target kind still applies.

Use manifest **schemaVersion 2 or later** for configuration fields and **3** for suffix or regex
filters. See the [pack specification](docs/pack-spec.md), [basic example](examples/example-pack/)
and [Xlog Decoder pack](examples/xlog-decoder-pack/).

To try Xlog Decoder, import `examples/xlog-decoder-pack/` as a local folder, enable **解密 Xlog**,
and save its private key in the action's configuration (leave it blank for unencrypted logs).
Select `.xlog` / `.XLOG` files in Finder to decode them beside the originals. The pack includes
its own CLI for Intel and Apple Silicon; **XlogDecoder.app is not required**.

### Bilingual & no repeating prompts

Full **English / 简体中文** UI (String Catalogs — adding a language is just a translation
column). And because the extension reads no files and there's no App Group container, AnyWhere
avoids the macOS 14/15 “wants to access data from other apps” nag; the few permissions it does
need are requested **once** in onboarding.

---

## Built-in presets (6 editable scripts)

Deliberately lean — only universal, gap-filling actions that every Mac user benefits from,
with zero external assumptions. All use built-in macOS CLIs. View/edit under
**Settings › Context Menu**; restore factory defaults under **Settings › General**.

| Script | Action | What it does |
|--------|--------|--------------|
| `copy-path.sh` | Copy Path | `pbcopy`, one path per line for multi-select |
| `new-file.sh` | New File | submenu of your template folder; `cp` + auto-numbered renames |
| `cut.sh` / `paste.sh` | Cut / Paste Here | move via a data-dir cutbuffer |
| `open-parent.sh` / `open-enclosing.sh` | Go Up One Level | navigate up in the current Finder window — or in a browser's upload dialog via `⌘↑` |

Specialized actions can be added as **optional extension packs**. These upstream projects
are references for authors; adapt their scripts to the `ANYWHERE_*` environment before
importing them. Current plugin discovery uses the [Bazaar registry](https://github.com/AnyWhereTools/anywhere-bazaar):

- **[Developer Pack](https://github.com/Hibrielle/menumate-dev-pack)** — Open in Terminal / Editor (honors your default terminal/editor).
- **[Image Pack](https://github.com/Hibrielle/menumate-image-pack)** — Convert Image ▸ png/jpeg/heic/tiff.
- **[Navigation Pack](https://github.com/Hibrielle/menumate-nav-pack)** — Go to Path… / Go to Clipboard Path (a Finder address bar).

---

## Install / build from source

Requirements: macOS 13+, Xcode 16.3+ (Swift 6.1 for the MCP helper SDK), Homebrew (for `xcodegen`).

Packaged downloads, when available, are listed under [GitHub Releases](https://github.com/AnyWhereTools/AnyWhere/releases).
Check each release's signing and notarization notes before installing.

```bash
make bootstrap   # install xcodegen + copy the local signing config
make gen         # project.yml → AnyWhere.xcodeproj (git-ignored)
make test        # run AnyWhereCore unit tests
make build       # Debug build
make run         # build + launch
```

Then enable the Finder extension (onboarding links you to System Settings, or
`pluginkit -e use -i com.anywhere.app.FinderExtension`) and grant the one-time permissions.

A signed/notarized release build requires Developer ID credentials. The GitHub release workflow
also supports an explicitly selected ad-hoc build without notarization or automatic updates —
see [docs/RELEASING.md](docs/RELEASING.md).

> **Running an unsigned/ad-hoc local build:** a `make build` (or a dmg built without a Developer ID)
> isn't notarized, so Gatekeeper will block it. Either right-click the app → **Open** (then confirm),
> or clear the quarantine flag: `xattr -dr com.apple.quarantine /path/to/AnyWhere.app`.

## Script environment contract

AnyWhere uses its own `com.anywhere.app` identity and stores configuration under
`~/Library/Application Support/AnyWhere/`. Existing installations of the upstream app keep
their data and permissions; they are not migrated automatically. Imported scripts must use
the `ANYWHERE_*` variables below.

Every script (preset or pack) is run under `/bin/zsh` with:

| variable / arg | meaning |
|----------------|---------|
| `$1 … $n` | absolute paths of selected items (the container path for empty-area actions) |
| `ANYWHERE_PATHS` | all paths, newline-separated |
| `ANYWHERE_VARIANT` | the chosen submenu value (e.g. `jpeg`) |
| `ANYWHERE_TEMPLATES` / `ANYWHERE_DATA` | template & data directories |
| `ANYWHERE_TERMINAL` / `ANYWHERE_EDITOR` | your chosen default terminal / editor bundle id |
| `ANYWHERE_SCRIPT` | this script's own absolute path; `${0:A:h}` is its directory, `${0:A:h:h}` is the pack root for a script under `actions/` |
| `ANYWHERE_CONFIG_<KEY>` | saved/default value of a field declared by this pack action; toggles use `"true"` / `"false"` |
| exit `0` | success; first stdout line is the summary |
| exit non-`0` | failure; stderr surfaced in “Recent Executions” + a notification |

## Architecture

| Target | What | Sandbox | Responsibility |
|--------|------|---------|----------------|
| AnyWhere | SwiftUI menu-bar app (`LSUIElement`) | No | launcher, plugin UI, reminders, action execution, system-menu management, packs |
| FinderExtension | `FIFinderSync` extension | Yes | draw the menu, forward clicks |
| AnyWhereMCP | bundled `anywhere-mcp` executable | No | stdio MCP bridge to authorized host commands |
| AnyWhereCore | local Swift package | — | models, config, rule matching, command validation and local IPC (unit-tested) |

The extension reads **no files**: the main app pushes a menu snapshot over
`DistributedNotificationCenter` (chunked). No App Group container — this is what eliminates the
repeating macOS permission prompts.

## Docs & contributing

- [UI, windows and workflow SDK](docs/plugin-ui.md) · [TypeScript declarations](docs/sdk/anywhere.d.ts)
- [Notifications and reminder buttons](docs/plugin-notifications.md) · [Host services](docs/plugin-services.md)
- [Local MCP and plugin commands (Chinese)](docs/mcp.zh.md) · [Search-home summaries (Chinese)](docs/plugin-summaries.zh.md)
- [Script workflow demo](examples/tool-panel-demo/README.md) · [Interactive tool-chain demo](examples/tool-chain-demo/README.md)
- [Cross-pack workflow design and implementation plan — not implemented](docs/cross-pack-workflows.md)
- [Extension Pack Specification](docs/pack-spec.md) · [basic example](examples/example-pack/) · [Xlog Decoder pack](examples/xlog-decoder-pack/)
- [Contributing](CONTRIBUTING.md) · [Releasing](docs/RELEASING.md) · [Security](SECURITY.md)
- Core unit tests + preset-script tests + an App/extension compile check run in CI on pushes to `main` and pull requests (`.github/workflows/ci.yml`).

## Known limitations

- FinderSync dead zones: `/Applications`, iCloud / File Provider directories don't trigger the
  extension (system behavior).
- Injected items always appear at the bottom of the context menu (system limitation).
- Shortcuts-based Quick Actions can only be hidden (their state lives in a TCC-protected DB).
- Preset titles are localized at seed time; switching system language later won't re-translate
  already-stored titles (restore factory presets to re-seed).

## License

[MIT](LICENSE) © 2026 Hibrielle
