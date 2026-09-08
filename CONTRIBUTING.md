# Contributing to AnyWhere

English · [简体中文](CONTRIBUTING.zh.md) · [Back to home](README.md)

Thanks for your interest! AnyWhere is a SwiftUI menu-bar app + Finder Sync extension, with a
pure-logic Swift package at its core.

## Development setup

For custom plugins, start with [Text Toolbox](examples/ui-tool-pack/README.md) and the
[UI guide](docs/plugin-ui.md). After `make gen`, run host tests with
`xcodebuild -project AnyWhere.xcodeproj -scheme AnyWhere -destination 'platform=macOS' test`.
Core and preset checks remain `make test` and `make test-presets`.

Requirements: macOS 13+, Xcode 15+ (String Catalogs), Homebrew (for `xcodegen`).

```bash
make bootstrap   # installs xcodegen, copies Local.xcconfig from the template
make gen         # project.yml → AnyWhere.xcodeproj (the .xcodeproj is git-ignored)
make test        # runs the AnyWhereCore unit tests (swift test)
make build       # xcodebuild Debug
make run         # build + launch
```

`Local.xcconfig` holds your local signing config and is git-ignored — never commit it. The
generated `AnyWhere.xcodeproj` and `build/` are git-ignored too; edit `project.yml`, not the
Xcode project.

## Architecture

| Target | What it is | Sandbox | Responsibility |
|--------|-----------|---------|----------------|
| **AnyWhere** | SwiftUI, `LSUIElement` menu-bar app + settings window | No | config editing, action execution, system-menu management, heartbeat |
| **FinderExtension** | `FIFinderSync` app extension | Yes | draws the right-click menu, forwards clicks |
| **AnyWhereCore** | local Swift package | — | data models, config codec, rule matching — pure logic, covered by `swift test` |

The extension reads **no files**: the main app pushes a menu snapshot to it over
`DistributedNotificationCenter` (chunked). This is what keeps AnyWhere free of the macOS
14/15 “wants to access data from other apps” prompts — there is no App Group container.

Put pure logic in **AnyWhereCore** with tests. Keep the extension thin.

## Tests

`make test` must stay green. Core logic is TDD'd; add tests under
`Core/Tests/AnyWhereCoreTests/`. Tests must not depend on the user's locale — look actions up
by `presetKey`, not by their (localized) title.

## Internationalization

AnyWhere uses **String Catalogs** with **abstract keys** (English is the source language):

- In code, reference a key: `String(localized: "general.launchAtLogin")`. Custom components
  take `String`, so wrap user-facing strings explicitly (SwiftUI does not auto-localize a
  `String` value). For interpolation: `String(format: String(localized: "key"), args…)`.
- The values live in `App/Localizable.xcstrings` (main app), `Core/Sources/AnyWhereCore/Localizable.xcstrings`
  (preset titles), and `FinderExtension/Localizable.xcstrings` (extension).

**Adding a language:** open the relevant `.xcstrings` in Xcode, add the language, translate
the keys. No code changes needed. Don't introduce new English-string-as-key or hard-coded
user-facing strings.

Maintain user documentation in language pairs: `.md` for English and `.zh.md` for Simplified
Chinese. Chinese pages should link to Chinese documentation, with a language switch at the top.
Keep the pack specification and examples in sync when changing pack features.

## Adding a built-in preset

1. Add the script to `App/PresetScripts/` (zsh; honor the [env contract](docs/pack-spec.md#script-environment-contract)).
2. Register it in `MenuConfig.defaultSeed()` (`Core/.../Models.swift`) with a stable
   `presetKey` and an abstract title key, and add the title to the Core catalog (en + zh-Hans).
3. Update the preset-count assertions in `ModelsTests` / `IPCTests`.

The seeder upgrades unmodified preset scripts in place and adds newly-shipped presets without
clobbering user edits; deleted presets stay deleted (a tombstone in `UserDefaults`).

## Commits & PRs

- Branch off `main`; keep commits focused with a clear subject.
- Run `make test` and `make build` before opening a PR.
- Describe the change and how you verified it. Screenshots help for UI changes.

By contributing you agree your contributions are licensed under the project's MIT License.
