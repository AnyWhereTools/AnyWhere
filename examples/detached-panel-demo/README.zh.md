# 独立面板 Demo（临时原型）

[English](README.md) · [正式窗口开发文档](../../docs/plugin-ui.zh.md)

这是独立运行的历史原型，没有 `manifest.json`，不能作为扩展包导入。正式功能采用普通独立窗口并新建会话；下方「搬移 WebView、保留输入、关闭后恢复」只适用于此原型，不代表当前工具窗口行为。

验证同一个 WKWebView 能否在两个 SwiftUI NSHostingView / NSPanel 之间移动，保留页面会话、中文输入和点击计数。只使用系统 AppKit、SwiftUI、WebKit，不接入 AnyWhere 配置或插件数据。

在仓库根目录运行：

```sh
swift examples/detached-panel-demo/main.swift
```

输入文字并点击计数，然后依次尝试「独立打开」「隐藏」、`⌘0` 恢复、「返回搜索」。也可点窗口关闭按钮再用 `⌘0` 或 Dock 图标恢复。`⌘Q` 退出；退出后所有数据消失。

自动检查（启动真实 macOS 窗口，检查完成后退出）：

```sh
swift examples/detached-panel-demo/main.swift --check
```

检查四次往返切换的 WebView 对象身份、页面会话、中文草稿、点击计数、窗口归属及关闭隐藏/恢复。该 Demo 不包含生产 PluginSession Bridge、后端任务、Finder 调用、包更新/卸载生命周期；这些需要正式接入后另行验证。
