// Throwaway prototype: move one WKWebView between two SwiftUI-hosted NSPanels.
// Run: swift examples/detached-panel-demo/main.swift [--check]
import AppKit
import SwiftUI
import WebKit

struct WebPage: NSViewRepresentable {
    let webView: WKWebView
    func makeNSView(context: Context) -> WKWebView { webView }
    func updateNSView(_ view: WKWebView, context: Context) {}
}

@MainActor
final class Demo: NSObject, NSApplicationDelegate, NSWindowDelegate, WKNavigationDelegate {
    let webView = WKWebView(frame: .zero, configuration: {
        let config = WKWebViewConfiguration()
        config.websiteDataStore = .nonPersistent()
        return config
    }())
    let search = NSPanel(contentRect: NSRect(x: 0, y: 0, width: 680, height: 480),
                         styleMask: [.titled, .closable, .resizable], backing: .buffered, defer: false)
    let detached = NSPanel(contentRect: NSRect(x: 0, y: 0, width: 680, height: 480),
                           styleMask: [.titled, .closable, .resizable], backing: .buffered, defer: false)
    var isDetached = false
    var current: NSPanel { isDetached ? detached : search }

    func applicationDidFinishLaunching(_ notification: Notification) {
        search.title = "AnyWhere Demo · 搜索面板"
        detached.title = "AnyWhere Demo · 独立面板"
        for panel in [search, detached] {
            panel.delegate = self
            panel.isReleasedWhenClosed = false
            panel.hidesOnDeactivate = false
            panel.minSize = NSSize(width: 480, height: 340)
            panel.center()
        }
        detached.setFrameOrigin(NSPoint(x: search.frame.minX + 80, y: search.frame.minY - 40))
        let menu = NSMenu()
        let appItem = NSMenuItem()
        let appMenu = NSMenu()
        appMenu.addItem(withTitle: "显示当前面板", action: #selector(showCurrent), keyEquivalent: "0").target = self
        appMenu.addItem(.separator())
        appMenu.addItem(withTitle: "退出 Demo", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")
        appItem.submenu = appMenu
        menu.addItem(appItem)
        let editItem = NSMenuItem(title: "编辑", action: nil, keyEquivalent: "")
        let editMenu = NSMenu(title: "编辑")
        for (title, action, key) in [("剪切", "cut:", "x"), ("复制", "copy:", "c"),
                                     ("粘贴", "paste:", "v"), ("全选", "selectAll:", "a")] {
            editMenu.addItem(withTitle: title, action: Selector(action), keyEquivalent: key)
        }
        editItem.submenu = editMenu
        menu.addItem(editItem)
        NSApp.mainMenu = menu
        webView.navigationDelegate = self
        move(toDetached: false)
        webView.loadHTMLString(Self.html, baseURL: nil)
        if CommandLine.arguments.contains("--check") {
            DispatchQueue.main.asyncAfter(deadline: .now() + 30) {
                fputs("FAIL: Demo check timed out\n", stderr)
                exit(1)
            }
        }
    }

    func move(toDetached: Bool) {
        // Release the old SwiftUI host before mounting the same WebView elsewhere.
        current.contentView = nil
        webView.removeFromSuperview()
        current.orderOut(nil)
        isDetached = toDetached
        current.contentView = NSHostingView(rootView: VStack(spacing: 0) {
            HStack {
                Text(toDetached ? "独立面板" : "搜索面板 · 文本工具").font(.headline)
                Spacer()
                Button(toDetached ? "返回搜索" : "独立打开") { [weak self] in
                    self?.move(toDetached: !toDetached)
                }
                Button("隐藏") { [weak self] in self?.current.orderOut(nil) }
            }.padding(12)
            Divider()
            WebPage(webView: webView)
            Divider()
            Text("关闭仅隐藏 · ⌘0 或点击 Dock 图标恢复 · ⌘Q 退出")
                .font(.caption).foregroundStyle(.secondary).padding(10)
        })
        showCurrent()
    }

    @objc func showCurrent() {
        NSApp.activate(ignoringOtherApps: true)
        current.makeKeyAndOrderFront(nil)
    }

    func windowShouldClose(_ sender: NSWindow) -> Bool { sender.orderOut(nil); return false }
    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        showCurrent()
        return true
    }

    func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
        guard CommandLine.arguments.contains("--check") else { return }
        Task { @MainActor in
            do {
                let identity = ObjectIdentifier(webView)
                let expected = try await webView.evaluateJavaScript("""
                    document.querySelector('textarea').value = '中文草稿 🧪';
                    document.querySelector('button').click();
                    window.probe = () => JSON.stringify([session, document.querySelector('textarea').value, clicks]);
                    probe();
                    """) as! String
                for target in [true, false, true, false] {
                    move(toDetached: target)
                    let actual = try await webView.evaluateJavaScript("probe()") as! String
                    precondition(actual == expected, "Page state changed during transfer")
                    precondition(ObjectIdentifier(self.webView) == identity, "WebView was replaced")
                    precondition(webView.window === current, "WebView attached to wrong window")
                    precondition(!(target ? search : detached).isVisible, "Old panel remains visible")
                    current.performClose(nil)
                    precondition(!current.isVisible, "Close should hide the panel")
                    let hiddenState = try await webView.evaluateJavaScript("probe()") as! String
                    precondition(hiddenState == expected, "Close lost page state")
                    showCurrent()
                    precondition(current.isVisible, "Restore failed")
                }
                print("PASS: 4 transfers; same WKWebView, page session, Chinese draft and click count; close/hide/restore.")
                NSApp.terminate(nil)
            } catch {
                fputs("FAIL: \(error)\n", stderr)
                exit(1)
            }
        }
    }

    static let html = """
    <!doctype html><html lang="zh-CN"><meta charset="utf-8">
    <meta name="viewport" content="width=device-width, initial-scale=1">
    <style>
      :root { color-scheme: light dark; font: 15px -apple-system, sans-serif; }
      body { margin: 24px; } h2 { margin-top: 0; }
      textarea { box-sizing: border-box; width: 100%; height: 120px; margin: 8px 0 16px;
                 padding: 12px; font: inherit; border-radius: 8px; }
      button { padding: 8px 18px; font: inherit; } p { line-height: 1.6; }
      code { overflow-wrap: anywhere; } small { opacity: .7; }
    </style>
    <h2>独立面板测试</h2>
    <label for="draft">输入内容，再点击上方「独立打开」和「返回搜索」</label>
    <textarea id="draft" placeholder="这段内容应该一直保留"></textarea>
    <button type="button" onclick="clicks++; render()">点击计数 +1</button>
    <p>点击次数：<b id="count">0</b> · 页面存活：<b id="age">0</b> 秒</p>
    <small>页面会话：<code id="session"></code><br>切换后会话 ID、草稿和计数应保持不变。计时只是页面示意，并非插件后端任务。</small>
    <script>
      const session = String(Date.now()) + '-' + Math.random().toString(36).slice(2);
      const started = Date.now(); let clicks = 0;
      document.querySelector('#session').textContent = session;
      function render() { document.querySelector('#count').textContent = clicks; }
      setInterval(() => document.querySelector('#age').textContent = Math.floor((Date.now()-started)/1000), 1000);
    </script></html>
    """
}

let app = NSApplication.shared
app.setActivationPolicy(.regular)
let demo = MainActor.assumeIsolated { Demo() }
app.delegate = demo
app.run()
