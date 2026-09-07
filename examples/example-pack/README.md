# AnyWhere Example Pack

A reference [extension pack](../../docs/pack-spec.md) for AnyWhere. Copy this folder or fork
it as a starting point for your own. Its version 1 manifest demonstrates the basic features;
it remains compatible with the current version 3 format.

It defines three actions that show off the manifest features:

| Action | `targets` / `utis` | Demonstrates |
|--------|--------------------|--------------|
| Copy file name (no extension) | `files` | positional args, `pbcopy`, stdout summary |
| Total size of selection | `any` | reading `$@`, shelling out, first-line summary |
| Convert image to… | `files`, `public.image` | a submenu (`variants.fixed`) via `$ANYWHERE_VARIANT` |

## Try it

1. In AnyWhere → **Extension Packs** → **Import**, choose **Choose Local Folder…** and select
   this folder, which contains `manifest.json`. No Git repository is needed.
2. Alternatively, push this folder to its **own** Git repository with `manifest.json` at the
   root, then import its URL or `owner/repo`.
3. Review each script, confirm, then enable the actions you want.

Local import copies a snapshot. Edits to the source do not update installed actions; uninstall
and reimport from the same folder to replace it. Duplicate imports are rejected.

## Add configuration and matching rules

- **Configuration:** version 2 or later supports `settings` with text, password, toggle and
  dropdown fields. Users save values in the action detail panel; scripts read
  `ANYWHERE_CONFIG_<KEY>`. Passwords are stored in Keychain.
- **Suffix and regex:** version 3 adds `extensions` (literal, case-insensitive suffixes) and
  `filenamePattern` (whole-filename regex, case-insensitive by default). A UTI **or** suffix
  must match, followed by the regex if present; every selected item must pass.
- **Working example:** [Xlog Decoder](../xlog-decoder-pack/) combines version 3 suffix matching,
  a saved private-key field and a bundled standalone CLI. No XlogDecoder.app installation is needed.

See the [pack specification](../../docs/pack-spec.md) for field definitions and examples.

## Make yours discoverable

Add the GitHub topic `anywhere-pack` to your repository so it shows up under
“Browse community packs”.
