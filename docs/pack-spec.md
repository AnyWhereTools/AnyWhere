# AnyWhere Extension Pack Specification

An **extension pack** is a folder with a `manifest.json` at its root and the scripts it
declares. Import it from a Git repository or directly from a local folder, without Git.
AnyWhere installs a read-only clone or snapshot, shows the scripts and additional files for
review, and adds actions **disabled** — users enable each action after reviewing it.

Start with the [basic example pack](../examples/example-pack/) for UTI filters and submenus,
or [Xlog Decoder](../examples/xlog-decoder-pack/) for local import, a bundled CLI, suffix
matching and a saved password field.

---

## Repository layout

```
your-pack/
├── manifest.json          # required, at the repo root
├── actions/               # your script files (any layout; referenced by manifest)
│   ├── foo.zsh
│   └── bar.zsh
└── bin/                   # optional bundled CLIs; retain their executable permissions
```

Import sources accepted by AnyWhere:

- a local folder containing `manifest.json` → choose **Import → Choose Local Folder…**; no Git repository required
- `owner/repo` shorthand → expands to `https://github.com/owner/repo.git`
- a full `https://…` or `git@…` git URL

---

## `manifest.json`

```jsonc
{
  "schemaVersion": 3,              // optional, default 1; suffix/regex filters require 3
  "name": "Dev Tools",            // required, non-empty — shown as the pack name
  "author": "Li Hua",             // optional, display only
  "description": "Handy actions", // optional, display only
  "icon": "hammer",               // optional SF Symbol, default "shippingbox"
  "actions": [                     // required, non-empty
    {
      "id": "copy-basename",      // required, non-empty, unique within the pack — STABLE id
      "title": "Copy file name",  // required, non-empty — the context-menu label
      "icon": "doc.on.doc",       // optional SF Symbol, default "bolt"
      "script": "actions/copy-basename.zsh",  // required, safe relative path
      "targets": "files",         // optional: files | folders | any | container (default any)
      "utis": ["public.image"],   // optional UTI filter (default []), UTType conformance match
      "extensions": ["xlog"],     // optional literal suffixes, case-insensitive; OR with utis
      "filenamePattern": "device-.*\\.(png|xlog)", // optional whole-filename regex; AND with type filters
      "placement": "topLevel",    // optional: topLevel | submenu (default topLevel)
      "variants": { "fixed": ["png", "jpeg"] },  // optional submenu; see below
      "timeoutSeconds": 60        // optional, default 60
    }
  ]
}
```

Unknown fields are ignored (forward-compatible). All optional fields fall back to the
defaults above.

### `schemaVersion` — select the required feature level

| Version | Supported declarations |
|---------|------------------------|
| `1` | Basic actions, `targets`, `utis`, placement, variants and timeouts |
| `2` | Version 1 plus `settings` for plugin configuration |
| `3` | Version 2 plus `extensions` and `filenamePattern` |

The current version is **3**. An omitted version defaults to **1**. Declare the version needed
by your pack so older clients reject unsupported features. Combining settings with suffix or
regex filters requires **3**; existing version 1 and 2 packs remain supported.

### `id` — keep it stable

The `id` is how AnyWhere matches actions across updates to **preserve the enabled state**
the user set. Renaming an `id` makes it a different action (the old one disappears, the new
one arrives disabled). Choose stable, kebab-case ids and don't change them.

### `script` — must be a safe relative path

Validated by `isSafeRelativeScriptPath`: must be non-empty, must **not** start with `/`
(no absolute paths), and **no path segment may be `..`** (no escaping the repo). The file
must actually exist in the repo at that path.

### `targets`

| value | shows when the user right-clicks… | mutually exclusive with |
|-------|-----------------------------------|--------------------------|
| `files` | one or more files selected (no folders) | `container` |
| `folders` | one or more folders selected | `container` |
| `any` | any selection (files and/or folders) | `container` |
| `container` | empty space inside a folder (no selection) | the three above |

`container` and the selection kinds never appear together — pick the one that fits.

### `utis`

A list of Uniform Type Identifiers. Uses UTType conformance, not string equality.
Common values: `public.image`, `public.movie`, `public.audio`, `com.adobe.pdf`,
`public.text`, `public.source-code`, `public.archive`.

### `extensions` and `filenamePattern` — matching (schemaVersion 3)

Set `schemaVersion` to **3** when using either new filter. Versions 1 and 2 without these
filters remain supported. Older clients reject version 3 instead of silently dropping filters.

- `extensions`: an array of **literal filename suffixes**, for example `["xlog", "tar.gz"]`.
  Matching ignores case and accepts an optional leading dot (`".XLOG"` equals `"xlog"`).
  `tar.gz` matches `backup.TAR.GZ`; `xlog` does not match `a.xlog.bak` or a bare `.xlog`.
  Suffixes only match files, never directories. Use letters, numbers, dots, `_`, `-` or `+`;
  wildcards, paths, regex syntax, empty suffixes and empty dot-separated segments are rejected.
- `filenamePattern`: an ICU regular expression matched against the **entire last path component**,
  including its suffix, never the parent path. Case-insensitive by default (ICU inline flags can
  override this). For example, `"device-.*\\.xlog"` matches `DEVICE-001.XLOG`.
  JSON backslashes must be escaped. Empty or invalid expressions are rejected on import;
  invalid filters in manually edited runtime config hide the action for selected items.
- `targets` and selection-count limits still apply. If either `utis` or `extensions` is nonempty,
  **at least one UTI or suffix** must match each selected item. If both are empty, type is unrestricted.
  A supplied `filenamePattern` is an **additional AND condition**. **Every selected item** must pass.
  `container` actions cannot declare suffix or filename filters, since they have no selected filename.

To show Xlog only for `.xlog` files on any Mac:

```json
{
  "targets": "files",
  "extensions": ["xlog"]
}
```

These are action-field fragments; place them inside an entry in `actions` alongside its
`id`, `title` and `script`. UTI matching uses system-registered types; suffix matching is
independent of the UTI registered for that extension on a particular Mac.

The custom-action editor exposes only literal suffixes, separated by commas or whitespace,
and normalizes case. Existing UTI/regex rules remain read-only until the user explicitly changes
suffixes or chooses **Use Suffix Matching**, which replaces those legacy filters. Unrelated edits
preserve them. Pack filters are read-only in the action panel and shown in the import review.
Category previews approximate UTI/suffix matching; filename regex requires real filenames and
is evaluated in the actual Finder menu.

### `variants` — submenus

Expands one action into a submenu; the chosen value is passed to the script via
`$ANYWHERE_VARIANT`.

- `{ "fixed": ["png", "jpeg", "webp"] }` — a fixed list of submenu items.
- `{ "directoryListing": "SomeDir" }` — one item per file in `SomeDir` (relative to the
  AnyWhere data directory). If the directory is empty, the whole action is hidden.

Omit `variants` for a normal (non-submenu) action.

### `settings` — plugin configuration (schemaVersion 2 or later)

An action can declare a `settings` array. Set the pack's `schemaVersion` to **2** or **3** so
older clients reject the pack instead of silently omitting its configuration form. Use **3**
if the action also declares suffix or filename filters. Actions without settings keep their
existing behavior.

```json
{
  "settings": [
    { "key": "HOST", "title": "Server", "type": "text", "defaultValue": "localhost", "required": true },
    { "key": "TOKEN", "title": "API token", "type": "password", "description": "Stored in Keychain" },
    { "key": "VERBOSE", "title": "Verbose output", "type": "toggle", "defaultValue": "false" },
    { "key": "FORMAT", "title": "Format", "type": "select", "options": ["text", "json"], "defaultValue": "text" }
  ]
}
```

| `type` | UI control | Value passed to the script |
|--------|------------|----------------------------|
| `text` | Text field | A string |
| `password` | Masked password field | A string loaded from Keychain; no default allowed |
| `toggle` | Switch | `"true"` or `"false"`; defaults to `"false"` |
| `select` | Dropdown | One of `options`, or an empty string when optional and unset |

- In **Context Menu**, select the pack action to see these fields above its read-only script.
  **Save Configuration** validates and persists the values; later runs load them automatically,
  including after an app restart. **Clear Configuration** deletes saved values and restores defaults.
- `key` must match `[A-Z][A-Z0-9_]{0,63}` and be unique within the action. Keys are stable identifiers.
- `title` is required; `description`, `defaultValue` and `required` are optional. All values/defaults
  are strings; toggles use `"true"` / `"false"` and default to `"false"`. Other types default to empty.
- `select` requires nonempty, unique `options`. Password fields cannot declare a default.
- At execution time, the action receives only its declared fields as `ANYWHERE_CONFIG_<KEY>`.
  Unset values use `defaultValue`; without a default, toggles use `"false"` and other types use
  an empty string. Required/invalid values stop execution with a configuration error.
  Read variables as quoted data, for example `"$ANYWHERE_CONFIG_HOST"`; never evaluate them as shell code.
- User values live outside the installed pack: ordinary values in
  `~/Library/Application Support/AnyWhere/PackConfigurations/<action UUID>.json`,
  passwords in Keychain. Password values are excluded from menu snapshots and ordinary config files;
  literal secret echoes in execution output are masked. Scripts still receive and can use their secrets.
- Pack updates keep values for stable action IDs and field keys. Uninstall retains configuration so
  reimporting the same source can reuse it; use Clear Configuration before uninstalling to remove values.
  A different source has a different action identity; do not rely on it inheriting saved values.

For a working password example, Xlog Decoder declares `PRIVATE_KEY` as `password` and reads
`"${ANYWHERE_CONFIG_PRIVATE_KEY-}"`. The manifest contains the field declaration, never a real
private key. Users save the key once in the configuration form; the script calls the bundled
decoder without displaying a per-run input dialog. See its [manifest](../examples/xlog-decoder-pack/manifest.json)
and [script](../examples/xlog-decoder-pack/actions/decode-xlog.zsh).

---

## Script environment contract

Pack scripts run exactly like built-in presets — under `/bin/zsh`, no executable bit needed:

| variable / arg | meaning |
|----------------|---------|
| `$1 … $n` | absolute paths of the selected items (the container path for `container` actions) |
| `ANYWHERE_PATHS` | all paths, newline-separated (handy for loops) |
| `ANYWHERE_VARIANT` | the chosen submenu value (empty when there is no submenu) |
| `ANYWHERE_DATA` | absolute path to AnyWhere's data directory (persist state here) |
| `ANYWHERE_TEMPLATES` | absolute path to the templates directory |
| `ANYWHERE_TERMINAL` / `ANYWHERE_EDITOR` | preferred terminal / editor bundle ID, when configured |
| `ANYWHERE_SCRIPT` | this script's own absolute path; `${0:A:h}` is the script directory |
| `ANYWHERE_CONFIG_<KEY>` | saved/default value of a configuration field declared by this action |
| working directory | the first selected item's parent folder, or the item itself if it is a folder |
| exit `0` | success; the first stdout line becomes the success summary |
| exit non-`0` | failure; stderr is surfaced in “Recent Executions” and a notification |

Reference the input via `"$@"` / `$ANYWHERE_PATHS`; never build shell commands by string
interpolation of paths.

The declared zsh script does not need its executable bit because AnyWhere invokes it with
`/bin/zsh`. A bundled CLI that the script invokes directly **does** need executable permission.
For the layout above, a script under `actions/` can locate `bin/` without depending on its
working directory or a separately installed app:

```zsh
pack_root="${0:A:h:h}"
decoder="$pack_root/bin/xlog-decoder"
```

---

## How import works (and why it's safe)

1. **Prepare** — `git clone --depth 1` for a Git source, or copy the selected local folder into a temp dir (preserving executable permissions). **No script is executed** at any point
   during import.
2. **Review** — AnyWhere shows every script read-only; you must open each one before you can
   continue. It also lists files not declared as action scripts, including bundled binaries,
   and requires acknowledging those additional files. The review includes each action's
   target kind, UTI/suffix filters and filename regex.
3. **Confirm** — the pack is moved to `…/Application Support/AnyWhere/Packs/<key>/`, and its
   actions are added to your config **disabled**, tagged with the pack id, their `script`
   resolved to the on-disk absolute path. You enable each action individually.

Installed scripts and matching rules are read-only. To change them, edit the source folder
or fork the source repository, then import the replacement. Users can still change menu titles,
placement, order, enabled state and the declared configuration values in the settings UI.

### Updates

Local folders are installed as snapshots and do not participate in Git update checks. Moving
the original folder does not affect installed actions. Importing the same source again is
rejected; uninstall its existing pack before importing a replacement.

“Check for updates” compares the remote `HEAD` SHA to the installed one. An update clones the
new version, shows a per-file diff (added / removed / modified) and any new actions (which
arrive disabled), and only applies after you confirm. Enabled state is preserved per action
`id`; actions removed upstream disappear.

---

## Publishing & discovery

Any conforming public git repo is importable by URL — no registry, no submission. To make a
pack discoverable, add the GitHub **topic** `anywhere-pack` to your repository; AnyWhere's
“Browse community packs” opens that topic search.

**Security note for authors and users:** pack scripts run with the user's privileges. Keep
scripts auditable and dependency-free; users should review every script before enabling it and
never import packs from untrusted sources.
