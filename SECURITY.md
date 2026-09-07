# Security

English · [简体中文](SECURITY.zh.md) · [Back to home](README.md)

## Reporting a vulnerability

Please report security issues privately via **GitHub Security Advisories**
(repo → Security → *Report a vulnerability*) rather than a public issue. We aim to
acknowledge within a few days.

## Threat model & design notes

AnyWhere ships as a **non-sandboxed** Developer ID app plus a **sandboxed** Finder Sync
extension. The security posture follows from that split.

- **Scripts run as you.** Presets, your own actions, and imported pack actions are plain
  `zsh` scripts executed with your user privileges — the same trust level as anything you
  run in Terminal. Only enable actions and packs whose scripts you've read. Scripts are
  invoked via `/bin/zsh "$script" "$@"` with inputs passed as arguments/`ANYWHERE_PATHS`;
  AnyWhere never `eval`s or string-interpolates selected paths into a command.

- **Extension packs are read-only on import and default-disabled.** Import is a
  `git clone --depth 1` or a local folder copy that **never executes scripts**. The review step shows every
  manifest-declared script **and every other non-metadata file in the repo** (hidden
  scripts, executables, and binaries are flagged), because a declared script can `source`
  sibling files via `pack_root`. Imported actions are added **disabled** until you enable
  them individually.

- **The App↔extension snapshot is not a privilege boundary.** The app pushes the menu
  config (and, at click time, the right-clicked paths) to the extension over
  `DistributedNotificationCenter`, which is **readable by any process running as the same
  user**. This is acceptable: a same-user process already has equivalent filesystem access
  to the same `config.json` and files. There is no App Group container (that's deliberate —
  it's what avoids the macOS "wants to access data from other apps" prompts). A **forged**
  snapshot can at worst change how the menu *looks* — it can never run a script, because
  every click is re-validated against the local on-disk config: the action id must exist,
  be enabled, and its script path must exist on disk.

- **Plugin passwords are encrypted locally.** CryptoKit AES-256-GCM authenticates a versioned
  vault in `~/Library/Application Support/AnyWhere/PrivateData/`. A per-installation random
  256-bit key is stored in that directory (`0700`); the key and vault files are `0600`.
  Configuration operations do not use Keychain or request a system password. Backups require
  both files. A missing/wrong key or damaged vault fails without resetting existing data.
  This is protection at rest, not isolation from another process running as the same user:
  access to both files allows decryption. Scripts receive only their declared configuration
  fields, and literal password echoes are masked before entering execution history.

- **"Remove Quarantine" is a deliberate Gatekeeper bypass.** If you add an action that
  deletes `com.apple.quarantine`, only run it on files you trust — it removes the macOS
  "downloaded from the internet / unidentified developer" check for those items.

- **Permissions are requested once.** AnyWhere asks for Automation (to drive Finder /
  System Events for in-window navigation) and, optionally, Accessibility (to send `⌘↑` in
  non-Finder upload dialogs). It does not require Full Disk Access.

- **The AI-authoring path edits local files directly.** The
  [`anywhere-author`](skills/anywhere-author/SKILL.md) skill and any external editor write
  `config.json` / `Scripts/` directly, bypassing the pack-review gate. That's intended for
  *your own* automation; treat AI- or script-authored actions with the same scrutiny you'd
  give code you wrote.
