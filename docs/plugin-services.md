# Plugin host services

[简体中文](plugin-services.zh.md) · [Type declarations](sdk/anywhere.d.ts) · [UI SDK](plugin-ui.md)

Three new capabilities extend schema 4 / UI API 1: `documents`, `launcher.entries`, `notifications`. Older hosts reject unknown capabilities and must be upgraded. Existing capability escalation reviews still apply.

## Documents

`documents.open()` returns `{name,text}` from a native picker, or null when cancelled. `saveAs(text,name)` uses a native save panel, not a plugin-provided path. UTF-8 regular files are limited to 50 MiB. Internal transfers use 192 KiB binary chunks and session-scoped opaque handles; ordinary bridge messages remain limited to 1 MiB.

Call `markDirty(version)` on edits and `saveDraft(text,version)` to atomically replace the action's draft. Only a matching version clears the dirty state. `draft()` restores the latest complete draft. Cancellation/failure retains the previous draft; closing releases handles and unfinished writes and prompts for unsaved document edits. `copyText(text)` handles large clipboard writes and also requires `clipboard.write`.

Document-capable pages may use Blob Workers for local computation. CSP still denies network connections. The JSON editor uses this service rather than enlarging arbitrary bridge/storage limits.

## Launcher entries

`launcher.setEntries([{id,title,keywords,url}])` replaces this action's persisted index, up to 1000 entries. IDs use ASCII alphanumeric characters, hyphens or underscores, at most 128 bytes. URLs must be HTTP(S) without credentials; `{query}` is replaced with percent-encoded search arguments.

The host owns source identity and reuses its name/pinyin/initial/alias matching. Entries survive closing the page and disappear when the source is disabled/uninstalled. `launcher.open(id,argument)` opens a registered entry only. Launcher execution revalidates the current source and entry. Persist the complete plugin model first, index the searchable subset, and surface/retry indexing failures.

## Notifications

`notifications.status()` reports `authorized`, `denied` or `notDetermined`. `replace(reminders)` persists the action's desired set and synchronizes OS requests. Each reminder is `{id,title,body,date,recurrence}`, with Unix **seconds** and recurrence `none`, `daily` or `weekly`. Limit: 50 per action; OS restrictions are returned as errors. An empty list cancels this action's requests.

Past one-time dates are not replayed. Repeating reminders match the local time/weekday at the next occurrence. Stable identifiers are namespaced by the host; updates replace, completion/deletion cancels, and unchanged synchronization retains delivered notifications. A plugin cannot cancel another action's reminders. Disabling/removing a source or its capability cancels its notifications; re-enabling retained data restores still-valid schedules.

The first requested reminder may ask for OS permission. Denial is returned explicitly. Check `{authorization,errors}` and distinguish saved task data from scheduled or delivered notifications. Scheduling is owned by macOS, not a page timer.

Notification clicks verify installation/enablement and open the action with `invocation.argument` equal to the reminder ID. Cold starts wait for packs to load. Existing panels receive a new `onEnter` context; detached windows are focused. Subscribe to reactivation instead of reading invocation only once at startup.

## Persistence and checks

Host metadata/documents live under `PluginData/<packKey>/HostServices/<actionUUID>/`, separately from arbitrary page storage keys. Uninstall can retain data; explicit clear-data removes it. Existing Finder configuration is not migrated.

`OfficialPluginTests` covers cross-chunk UTF-8, cancellation, isolation, safe URLs, persisted indexing, real editor/forms and OS delivery after closing a page. Notification checks use a dedicated namespace and existing system authorization. Each pack also supplies Node checks. JSON dependencies are lockfile-pinned and the built bundle is committed; end users need no npm installation.
