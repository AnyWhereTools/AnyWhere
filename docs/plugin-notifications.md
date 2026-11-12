# Plugin Notification Guide

English · [简体中文](plugin-notifications.zh.md) · [Developer docs](README.md) · [Host services](plugin-services.md) · [SDK types](sdk/anywhere.d.ts)

## Ownership

| AnyWhere host | Plugin, such as Todo |
| --- | --- |
| Provide presentations, permission status, scheduling and cancellation | Decide presentation and reminder time; Todo always requests panels |
| Display supplied titles, bodies and buttons | Define Snooze, Complete and their business meaning |
| Validate the source and deliver button IDs | Choose snooze duration, save business state and synchronize remaining reminders |

The host does not understand Todo's model, change `done`, or decide how long to snooze.

## 1. Declare and detect capabilities

Declare the capability on the corresponding manifest **action**:

```json
"capabilities": ["notifications"]
```

The user must enable the action's Search entry. UI pages use the injected `anywhere` object without importing an npm package.

```js
const supportsActions = anywhere.notifications?.supportsActions === true;
const presentations = anywhere.notifications?.presentations ?? ["system"];
const authorization = await anywhere.notifications.status();
```

Older hosts lack `supportsActions` and `presentations`. The presence of `notifications` alone does not imply button or panel support. Prompt for an upgrade or explicitly offer only ordinary system notifications.

## 2. Choose a presentation in the plugin

| `presentation` | Display | Requirements |
| --- | --- | --- |
| `system` (default) | macOS notification | System authorization; once registered, neither the page nor AnyWhere needs to stay open |
| `panel` | AnyWhere reminder window | No system notification authorization; AnyWhere must run, but the page may close |

Users choose temporary or persistent system styles in macOS settings. Plugins cannot force a style, and buttons may be grouped in notification options. Panels display the declared buttons. Neither mode guarantees reminders while the computer is powered off.

Past one-time system reminders are not resubmitted during synchronization. An overdue one-time panel that has never been shown resumes at the next host launch; a panel already shown and closed does not repeatedly reopen. Dismissing a reminder does not complete business work.

## 3. Save business data, then replace all reminders

This example uses Todo-style `items` already saved by the plugin; they are not SDK variables:

```js
async function syncReminders(items) {
  const reminders = items.filter(t => !t.done && t.due !== null).map(t => ({
    id: t.id,
    title: t.title,
    body: t.note,
    date: t.due / 1000, // JavaScript milliseconds to Unix seconds
    recurrence: t.recurrence,
    presentation: "panel", // Todo always uses floating reminders
    actions: [
      { id: "snooze", title: "Snooze", background: true,
        options: [{id: "snooze-5", title: "In 5 minutes"}, {id: "snooze-60", title: "In 1 hour"}] },
      { id: "complete", title: "Complete", background: true }
    ]
  }));

  const result = await anywhere.notifications.replace(reminders);
  if (result.errors.length) throw new Error(result.errors.join("; "));
}
```

Catch synchronization failures, show that data was saved but reminders failed, and offer a retry. Other plugins choosing `system` must also check `result.authorization === 'authorized'`. Do not roll back saved business data because authorization failed, or claim that a successful save guarantees delivery.

### Parameters and limits

| Field | Contract |
| --- | --- |
| `id` | Stable reminder ID, 1–128 bytes; ASCII letters, digits, `-`, `_` only |
| `title` | Required, nonempty, at most 512 UTF-8 bytes |
| `body` | May be empty; at most 4096 UTF-8 bytes |
| `date` | Positive, valid Unix **seconds**, earlier than year 3000 |
| `recurrence` | `none`, `daily`, `weekly`; repeats use the next matching local time/weekday, not an arbitrary future start date |
| `presentation` | Optional `system` or `panel`; defaults to `system` |
| `actions` | Optional, at most two `{id,title}` objects; unique IDs with the same format as reminder IDs; nonempty titles at most 128 UTF-8 bytes |

**`replace` replaces the current action's entire set; it does not append.** The maximum is 50 reminders with unique IDs. Include all reminders to retain when changing one. A plugin cannot modify another action's notifications.

```js
// The action's only reminder, five minutes from now.
await anywhere.notifications.replace([{
  id: "example-001", title: "Submit weekly report", body: "Review completed work",
  date: Date.now() / 1000 + 5 * 60,
  recurrence: "none", presentation: "system"
}]);

// Use only when intentionally cancelling every reminder for this action.
await anywhere.notifications.replace([]);
```

## 4. Handle button events

Buttons activate the plugin and deliver an event through `onEnter`, potentially opening a window. Existing windows also receive events; handling only initial page load is insufficient.

```js
anywhere.onEnter(context => {
  if (context.notification) {
    handleNotification(context.notification).catch(showError);
  } else if (context.argument) {
    openItem(context.argument);
  }
});
```

`handleNotification`, `showError` and `openItem` are plugin functions, not SDK methods. Ordinary notification-body clicks pass the reminder ID in `argument`. Button events have this shape:

```js
{
  id: "stable-event-id", // Persist to prevent replay
  itemID: "todo-001",    // Reminder id passed to replace
  actionID: "complete"  // Button id declared in actions
}
```

Todo processes events in this order:

1. Reload persisted data, verify the item exists and is unfinished, and ignore previously handled event IDs.
2. For `complete`, set `done = true` and the completion time; do not toggle completion.
3. For `snooze`, show the plugin's time selector. Confirming saves a new reminder time while keeping the item unfinished. Cancelling changes nothing.
4. Save business changes and the event ID together, then call `replace` with all remaining reminders.

Serialize callbacks with in-progress saves instead of dropping events while busy. The host rejects stale buttons after the reminder changes, is cancelled, or its source is disabled.

### Card menus and background handlers

Check `anywhere.notifications.supportsInlineActions`. Panel actions accept `options` (1–6 flat menu items with unique IDs across the reminder) and `background: true`. The selected option ID becomes `actionID`; the host does not interpret its business meaning. System notifications reject these extensions.

Register `anywhere.notifications.onAction(async event => { await handleAndPersistNotification(event); })` after loading data. The handler runs in a temporary invisible plugin page; normal initialization and `onEnter` still run. Persist fresh business state and the event ID, then synchronize reminders. Finish within 20 seconds without opening dialogs. Resolve to close the card, or throw to display an error and allow retry. Deduplicate retries; if the event was already saved, only retry synchronization. Ordinary actions without `background` still open the plugin through `onEnter`.

AnyWhere owns the compact cards at the current screen's upper-right corner below the menu bar, stacking downward. Plugins own menu labels, snooze intervals, completion state and event deduplication.

The host supplies one generic notification UI: AnyWhere branding and plugin attribution, light/dark gradient surfaces with rounded shadows, softly emphasized action buttons, system dropdown menus, and progress/error feedback. Plugins supply content and action declarations, without implementing or controlling the card layout.

## 5. Test with Todo

1. Create or edit a Todo, set a future reminder, save, and inspect reminder status at the bottom of the page. Todo always uses reminder panels; no style selection is needed. Keep AnyWhere running.
2. Choose five, fifteen or thirty minutes, or one hour directly in the card's Snooze menu. The item stays unfinished and its reminder time changes without opening Todo.
3. Choose Complete: the item moves to completed and its subsequent reminder is removed. Dismissing the notification or cancelling snooze must not complete it.

Current Todo policy shifts the subsequent repeating time when snoozing and does not allow postponement beyond one recurrence period. The selector explains this. It is Todo policy, not a rule imposed on every plugin by the host.

Check out `anywhere-todo` beside the AnyWhere repository. [OfficialPluginTests.swift](../AppTests/OfficialPluginTests.swift) loads its real WebView with isolated data and notification namespaces. Run `node test.cjs` in Todo for business-logic checks. System-delivery tests require notification authorization; a skip is not delivery evidence.

After `make gen`, run these selected tests from AnyWhere:

```sh
xcodebuild -project AnyWhere.xcodeproj -scheme AnyWhere -configuration Debug \
  -derivedDataPath build -destination 'platform=macOS' \
  -only-testing:AnyWhereTests/OfficialPluginTests/testTodoSnoozeChoicesAndCancellation \
  -only-testing:AnyWhereTests/OfficialPluginTests/testTodoActualFormPersistsAndSchedulesIndependently test
```

The first covers snooze options, cancellation, invalid times and a real timer → native panel button → host routing → Todo completion → reminder removal. The second covers form persistence and system delivery after the page closes, including button category/payload registration.

Separately check real system-notification button clicks in Notification Center, including reopening a closed plugin page. WebView callback tests and native panel tests do not replace that check. As of the local development validation on 2026-09-11, the selected automated paths passed; actual Notification Center button clicks remain unverified. These results do not establish release availability.
