# Detached panel demo (historical prototype)

[简体中文](README.zh.md) · [Production window guide](../../docs/plugin-ui.md)

This standalone prototype has no `manifest.json` and cannot be imported as an extension pack. Production tools create new sessions in regular independent windows. The WebView transfer, input preservation and close/reopen behavior below applies only to this prototype.

It checks moving one WKWebView between SwiftUI NSHostingView/NSPanel containers while preserving its page session, Chinese text input and click count. Uses AppKit, SwiftUI and WebKit only, without AnyWhere configuration or plugin storage.

From the repository root:

```sh
swift examples/detached-panel-demo/main.swift
```

Enter text and increment the counter. Try **独立打开** (detach), **隐藏** (hide), `⌘0` to restore and **返回搜索** (back). Close the window and restore with `⌘0` or the Dock icon. `⌘Q` exits, losing all data.

Automatic check, opening real macOS windows and exiting when finished:

```sh
swift examples/detached-panel-demo/main.swift --check
```

Checks four round trips for WebView identity, session, Chinese draft, counter, window ownership and close/hide restoration. It does not exercise the production PluginSession bridge, backend tasks, Finder invocation or pack update/uninstall lifecycle; production checks belong to the integrated app.
