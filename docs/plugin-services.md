# Plugin host services

[简体中文](plugin-services.zh.md) · [Developer docs](README.md) · [Type declarations](sdk/anywhere.d.ts) · [UI SDK](plugin-ui.md)

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

Past one-time system dates are not replayed. Repeating reminders match the local time/weekday at the next occurrence. Stable identifiers are namespaced by the host; updates replace, completion/deletion cancels, and unchanged synchronization retains delivered notifications. A plugin cannot cancel another action's reminders. Disabling/removing a source or its capability cancels its notifications; re-enabling retained data restores still-valid schedules.

Page-initiated system synchronization requests alert and sound authorization, including for installations previously requesting alerts only. Once macOS records a choice, subsequent requests do not repeat the initial prompt or override a user's notification denial. Denial is returned explicitly. Check `{authorization,errors}` and distinguish saved task data from scheduled or delivered notifications. macOS schedules system notifications; the running AnyWhere host schedules panels. Neither depends on a page timer.

Notification clicks verify installation/enablement and open the action with `invocation.argument` equal to the reminder ID. Cold starts wait for packs to load. Existing panels receive a new `onEnter` context; detached windows are focused. Subscribe to reactivation instead of reading invocation only once at startup.

### Presentation and actions

See the [notification guide](plugin-notifications.md) for complete examples, parameter limits, button handling and Todo testing.

The plugin selects `presentation: "system" | "panel"` per reminder (default: system), and supplies up to two `actions: [{id,title}]` with unique IDs. Feature-detect `notifications.presentations` and `supportsActions` on older hosts. The host renders, schedules, validates ownership, and activates the plugin with `invocation.notification = {id,itemID,actionID}`. Plugins persist the event ID for replay protection and own all business changes and subsequent `replace` calls. Closing a notification never means completing a task. Stale actions on changed or removed reminders are ignored.

macOS controls system banner persistence, action layout and Focus. Panels require AnyWhere running, independently of the plugin page and system notification permission. Overdue one-time panels appear on the next host start; previously presented single reminders do not reappear on sync/restart. Repeating panels coalesce missed occurrences before scheduling the next one. Check errors for both presentations; authorization applies to system requests.

Todo owns the presentation selector, completion and snooze picker. Snooze keeps the task incomplete and moves its reminder time; for repeating tasks it also moves future repeat times and must remain within one repeat period, as explained in the picker.

## Persistence and checks

Host metadata/documents live under `PluginData/<packKey>/HostServices/<actionUUID>/`, separately from arbitrary page storage keys. Uninstall can retain data; explicit clear-data removes it. Existing Finder configuration is not migrated.

`OfficialPluginTests` covers cross-chunk UTF-8, cancellation, isolation, safe URLs, persisted indexing, real editor/forms and OS delivery after closing a page. Notification checks use a dedicated namespace and existing system authorization. Each pack also supplies Node checks. JSON dependencies are lockfile-pinned and the built bundle is committed; end users need no npm installation.
