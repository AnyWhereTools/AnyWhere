import XCTest
import WebKit
import SwiftUI
import AnyWhereCore
@testable import AnyWhere

@MainActor
final class PluginSummaryTests: XCTestCase {
    private final class Probe: NSObject, WKScriptMessageHandler {
        var frames: [WKFrameInfo] = []
        func userContentController(_ userContentController: WKUserContentController, didReceive message: WKScriptMessage) {
            if !message.frameInfo.isMainFrame { frames.append(message.frameInfo) }
        }
    }
    private var folders: [URL] = []
    override func tearDown() {
        for folder in folders { try? FileManager.default.removeItem(at: folder) }
        super.tearDown()
    }
    private func entry(title: String, root: URL? = nil) throws -> PluginLauncherEntry {
        let folder = root ?? FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        if root == nil {
            try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true); folders.append(folder)
            try Data("<p id='value'>加载中</p><script>anywhere.storage.get('value').then(v=>document.getElementById('value').textContent=v)</script>".utf8)
                .write(to: folder.appendingPathComponent("summary.html"))
        }
        let key = "summary-test-" + UUID().uuidString
        folders.append(PackManager.dataDirectory(key))
        let action = MenuAction(id: UUID(), title: title, icon: .symbol("bolt"), kind: .openPluginUI,
                                matching: MatchRule(), placement: .topLevel, packID: key, isEnabled: true, sortOrder: 0)
        try PluginDataStore(directory: PackManager.dataDirectory(key)).set("value", value: .string(title))
        let definition = try JSONDecoder().decode(PackAction.self, from: Data(#"{"id":"test","title":"Test","ui":{"entry":"index.html"},"launcher":{"keywords":["test"]}}"#.utf8))
        return PluginLauncherEntry(id: action.id, action: action, definition: definition, directory: folder)
    }
    private func probe(_ view: WKWebView) -> Probe {
        let probe = Probe()
        view.configuration.userContentController.add(probe, name: "testProbe")
        view.configuration.userContentController.addUserScript(WKUserScript(source:
            "if(window!==window.top)window.webkit.messageHandlers.testProbe.postMessage('ready');",
            injectionTime: .atDocumentEnd, forMainFrameOnly: false))
        return probe
    }
    private func waitForFrames(_ probe: Probe, count: Int) async throws {
        for _ in 0..<200 {
            if probe.frames.count >= count { return }
            try await Task.sleep(nanoseconds: 25_000_000)
        }
        XCTFail("Expected \(count) summary frames, got \(probe.frames.count)")
    }
    private func run(_ view: WKWebView, frame: WKFrameInfo?, code: String) async throws -> Any? {
        try await view.callAsyncJavaScript(code, arguments: [:], in: frame, contentWorld: .page)
    }
    private func screenshot(_ view: WKWebView, name: String) async throws {
        let image = try await view.takeSnapshot(configuration: nil)
        let bitmap = try XCTUnwrap(image.tiffRepresentation.flatMap(NSBitmapImageRep.init(data:)))
        try XCTUnwrap(bitmap.representation(using: .png, properties: [:])).write(to: URL(fileURLWithPath: "/tmp/anywhere-summary-\(name).png"))
    }

    func testThreeFramesIsolationReadOnlyRefreshAndTheme() async throws {
        let entries = try [entry(title: "A"), entry(title: "B"), entry(title: "C")]
        let host = PluginSummaryHost(), view = host.makeWebView(), probe = probe(view)
        let window = NSWindow(contentRect: .init(x: 0, y: 0, width: 660, height: 192), styleMask: [.titled], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false; window.contentView = view; window.makeKeyAndOrderFront(nil)
        defer { host.close(); view.configuration.userContentController.removeScriptMessageHandler(forName: "testProbe"); window.close() }
        let revision = UUID(), start = Date()
        host.update(entries, revision: UUID(), dark: false)
        host.update(entries, revision: revision, dark: false)
        try await waitForFrames(probe, count: 3)
        print("SUMMARY three-frame initial load: \(Date().timeIntervalSince(start))s")
        XCTAssertTrue(host.webView === view)
        XCTAssertEqual(Set(probe.frames.compactMap { $0.request.url?.host }).count, 3)
        var names = Set<String>()
        for frame in probe.frames {
            let value = try await run(view, frame: frame, code: "return await anywhere.storage.get('value')") as? String
            names.insert(try XCTUnwrap(value))
            let denied = try await run(view, frame: frame, code: """
              let parentBlocked=false, networkBlocked=false;
              try{void parent.document.body}catch{parentBlocked=true}
              try{await fetch('https://example.com')}catch{networkBlocked=true}
              const reply=await webkit.messageHandlers.summary.postMessage({method:'storage.set',key:'value',value:'changed'});
              return {parentBlocked,networkBlocked,writeDenied:!!reply.error,hasSetter:!!anywhere.storage.set,height:innerHeight};
              """) as? [String: Any]
            XCTAssertEqual(denied?["parentBlocked"] as? Bool, true)
            XCTAssertEqual(denied?["networkBlocked"] as? Bool, true)
            XCTAssertEqual(denied?["writeDenied"] as? Bool, true)
            XCTAssertEqual(denied?["hasSetter"] as? Bool, false)
            XCTAssertEqual(denied?["height"] as? Int, 64)
        }
        XCTAssertEqual(names, ["A", "B", "C"])
        let main = try await run(view, frame: nil, code: "return await webkit.messageHandlers.summary.postMessage({method:'storage.get',key:'value'})") as? [String: Any]
        XCTAssertNotNil(main?["error"])
        try await screenshot(view, name: "three-light")
        host.update(entries, revision: revision, dark: true)
        try await Task.sleep(nanoseconds: 100_000_000)
        let dark = try await run(view, frame: probe.frames[0], code: "return matchMedia('(prefers-color-scheme:dark)').matches") as? Bool
        XCTAssertEqual(dark, true)
        XCTAssertEqual(probe.frames.count, 3, "Theme must not reload pages")
        try await screenshot(view, name: "three-dark")
        try PluginDataStore(directory: PackManager.dataDirectory(entries[0].action.packID!)).set("value", value: .string("updated"))
        probe.frames = []
        host.update(entries, revision: UUID(), dark: true)
        try await waitForFrames(probe, count: 3)
        var updated = [String]()
        for frame in probe.frames {
            let value = try await run(view, frame: frame, code: "return await anywhere.storage.get('value')") as? String
            updated.append(try XCTUnwrap(value))
        }
        XCTAssertTrue(updated.contains("updated"))
        host.isAllowed = { _ in false }
        let revoked = try await run(view, frame: probe.frames[0], code: "try{await anywhere.storage.get('value');return false}catch{return true}") as? Bool
        XCTAssertEqual(revoked, true)
        host.close()
        XCTAssertNil(view.navigationDelegate)
    }

    func testTodoSummaryAndFailureFallback() async throws {
        let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent().appendingPathComponent("anywhere-todo")
        let entry = try entry(title: "待办", root: root), host = PluginSummaryHost(), view = host.makeWebView(), probe = probe(view)
        let store = PluginDataStore(directory: PackManager.dataDirectory(entry.action.packID!))
        let window = NSWindow(contentRect: .init(x: 0, y: 0, width: 660, height: 64), styleMask: [.titled], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false; window.contentView = view; window.makeKeyAndOrderFront(nil)
        defer { host.close(); view.configuration.userContentController.removeScriptMessageHandler(forName: "testProbe"); window.close() }
        let rows: [[String: Any]] = (0..<5).map { i in
            ["id":"task\(i)","title":i == 0 ? "<script>测试长标题，不执行 HTML</script>" : "待办 \(i)","note":"","priority":i == 0 ? 2 : 0,"done":i == 4,"due":NSNull(),"recurrence":"none"]
        }
        let state = try JSONDecoder().decode(JSONValue.self, from: JSONSerialization.data(withJSONObject: ["schemaVersion":1,"items":rows]))
        try store.set("todos", value: state)
        host.update([entry], revision: UUID(), dark: false)
        try await waitForFrames(probe, count: 1)
        let result = try await run(view, frame: probe.frames[0], code: """
          for(let i=0;i<100&&!document.querySelector('article');i++)await new Promise(r=>setTimeout(r,20));
          return {count:document.querySelectorAll('article').length,text:document.body.innerText,height:innerHeight,overflow:document.documentElement.scrollWidth>innerWidth};
          """) as? [String: Any]
        XCTAssertEqual(result?["count"] as? Int, 3)
        XCTAssertEqual(result?["height"] as? Int, 64)
        XCTAssertEqual(result?["overflow"] as? Bool, false)
        XCTAssertTrue((result?["text"] as? String)?.contains("还有 1 项") == true)
        XCTAssertTrue((result?["text"] as? String)?.contains("<script>") == true)
        XCTAssertFalse((result?["text"] as? String)?.contains("待办 4") == true)
        XCTAssertEqual(try store.get("todos"), state, "Summary must not migrate/write original data")
        try await screenshot(view, name: "todo-light")
        host.update([entry], revision: UUID(), dark: true)
        probe.frames = []
        try await waitForFrames(probe, count: 1)
        _ = try await run(view, frame: probe.frames[0], code: "for(let i=0;i<100&&!document.querySelector('article');i++)await new Promise(r=>setTimeout(r,20));return true")
        try await screenshot(view, name: "todo-dark")
        _ = try await run(view, frame: probe.frames[0], code: "setTimeout(()=>{throw new Error('test failure')},0);return true")
        try await Task.sleep(nanoseconds: 100_000_000)
        let fallback = try await run(view, frame: probe.frames[0], code: "return document.body.innerText") as? String
        XCTAssertTrue(fallback?.contains("摘要暂不可用") == true)
    }

    func testLauncherPinsDiscoveryLayoutAndWebViewLifetime() async throws {
        let preferencesRoot = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        folders.append(preferencesRoot)
        let prefs = PluginPreferencesStore(directory: preferencesRoot), state = AppState()
        var packs: [InstalledPack] = []
        for i in 0..<4 {
            let key = "summary-ui-" + UUID().uuidString
            let root = AppPaths.configDirectory().appendingPathComponent("Packs").appendingPathComponent(key)
            try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true); folders.append(root)
            let definition = try JSONDecoder().decode(PackAction.self, from: Data(#"{"id":"tool","title":"摘要工具","ui":{"entry":"index.html"},"launcher":{"keywords":["summary"]}}"#.utf8))
            let action = MenuAction(id: PackManager.actionUUID(packKey: key, packActionID: "tool"), title: "工具 \(i)", icon: .symbol("bolt"), kind: .openPluginUI,
                                    matching: MatchRule(), placement: .topLevel, packID: key, isEnabled: true, sortOrder: i)
            state.config.actions.append(action)
            let manifest = PackManifest(schemaVersion: 4, name: "工具 \(i)", actions: [definition])
            packs.append(InstalledPack(key: key, manifest: manifest, repoURL: "", repo: key, commitSHA: "test", enabledCount: 1, totalCount: 1))
            if i < 3 {
                try Data("<strong>摘要工具 \(i)</strong><p>最紧要的信息 · 今天需要完成的事项</p>".utf8).write(to: root.appendingPathComponent("summary.html"))
            }
            try prefs.setEnabled(true, actionID: action.id)
            try prefs.recordUse(actionID: action.id)
        }
        let manager = PackManager(appState: { state }, packs: packs, preferences: prefs)
        XCTAssertEqual(manager.summaryEntries().count, 3, "A plugin without summary.html cannot be pinned")
        for entry in manager.summaryEntries() { try manager.setSummaryPinned(true, entry: entry) }
        let controller = PluginLauncherController()
        let existingWindows = Set(NSApp.windows.map(\.windowNumber))
        controller.show()
        let panel = try XCTUnwrap(NSApp.windows.first {
            $0.identifier?.rawValue == "AnyWhere.launcher" && !existingWindows.contains($0.windowNumber)
        })
        let content = NSHostingView(rootView: PluginLauncherView(controller: controller, manager: manager))
        panel.contentView = content
        defer { controller.hide(); panel.contentView = nil; panel.close() }
        func webViews(_ view: NSView) -> [WKWebView] { (view as? WKWebView).map { [$0] } ?? view.subviews.flatMap(webViews) }
        for _ in 0..<100 {
            if webViews(content).count == 1, panel.frame.height > 500 { break }
            try await Task.sleep(nanoseconds: 25_000_000)
        }
        XCTAssertEqual(webViews(content).count, 1)
        XCTAssertEqual(panel.frame.width, 680, accuracy: 1)
        XCTAssertEqual(panel.frame.height, 538, accuracy: 1)
        weak var oldView = webViews(content).first
        let firstView = try XCTUnwrap(webViews(content).first)
        XCTAssertEqual(firstView.frame.height, 192, accuracy: 1)
        // Wait natively: a JS promise created on about:blank is lost when the first navigation commits.
        try await Task.sleep(nanoseconds: 150_000_000)
        for _ in 0..<200 {
            if firstView.url?.scheme == "anywhere-summary", !firstView.isLoading { break }
            try await Task.sleep(nanoseconds: 25_000_000)
        }
        let frameCount = try await run(firstView, frame: nil, code: "return document.querySelectorAll('iframe').length") as? Int
        let diagnostic = try await run(firstView, frame: nil, code: "return {url:location.href,html:document.documentElement.outerHTML}")
        XCTAssertEqual(frameCount, 3, "visible=\(controller.isVisible), current=\(firstView === webViews(content).first), loading=\(firstView.isLoading), page=\(String(describing: diagnostic))")
        XCTAssertFalse(firstView.acceptsFirstResponder)
        let originalURL = firstView.url
        NotificationCenter.default.post(name: PluginSummaryHost.storageChanged, object: packs[0].key)
        for _ in 0..<200 {
            if firstView.url != originalURL, !firstView.isLoading { break }
            try await Task.sleep(nanoseconds: 25_000_000)
        }
        XCTAssertNotEqual(firstView.url, originalURL)
        XCTAssertTrue(firstView === webViews(content).first, "Data refresh reuses the one WebView")
        content.layoutSubtreeIfNeeded()
        if let bitmap = content.bitmapImageRepForCachingDisplay(in: content.bounds) {
            content.cacheDisplay(in: content.bounds, to: bitmap)
            try bitmap.representation(using: .png, properties: [:])?.write(to: URL(fileURLWithPath: "/tmp/anywhere-summary-launcher.png"))
        }
        controller.query = "summary"
        try await Task.sleep(nanoseconds: 150_000_000)
        XCTAssertEqual(webViews(content).count, 0)
        XCTAssertEqual(panel.frame.height, 382, accuracy: 1)
        controller.query = ""
        try await Task.sleep(nanoseconds: 150_000_000)
        XCTAssertEqual(webViews(content).count, 1)
        XCTAssertFalse(webViews(content).first === oldView)
        let pinned = try XCTUnwrap(manager.summaryEntries().first)
        try manager.setSummaryPinned(false, entry: pinned)
        try await Task.sleep(nanoseconds: 150_000_000)
        XCTAssertEqual(panel.frame.height, 474, accuracy: 1)
        let remaining = try prefs.pinnedSummaries()
        let disabled = try XCTUnwrap(manager.summaryEntries().first { remaining.contains($0.action.packID!) })
        try prefs.setEnabled(false, actionID: disabled.id)
        NotificationCenter.default.post(name: PluginServices.changed, object: nil)
        try await Task.sleep(nanoseconds: 150_000_000)
        XCTAssertEqual(panel.frame.height, 410, accuracy: 1)
        weak var closingView = webViews(content).first
        controller.hide()
        // WebKit teardown is asynchronous and can outlive a fixed 150 ms delay.
        for _ in 0..<100 {
            if closingView == nil { break }
            try await Task.sleep(nanoseconds: 25_000_000)
        }
        XCTAssertEqual(webViews(content).count, 0)
        XCTAssertFalse(controller.isVisible)
        XCTAssertNil(closingView, "Closing the launcher must release its summary WebView")
    }
}
