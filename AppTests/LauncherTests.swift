import XCTest
import WebKit
import JavaScriptCore
import AnyWhereCore
@testable import AnyWhere

final class LauncherCatalogTests: XCTestCase {
    func testSearchPriorityArgumentsAndRecentPersistence() throws {
        func entry(_ title: String, keys: [String] = [], description: String = "") -> LauncherEntry {
            let action = MenuAction(id: UUID(), title: title, icon: .symbol("bolt"), kind: .openPluginUI,
                                    matching: MatchRule(), placement: .topLevel, isEnabled: true, sortOrder: 0)
            return LauncherEntry(search: .init(id: action.id, title: title, keywords: keys), subtitle: description, target: .action(action))
        }
        let title = entry("Format"), alias = entry("JSON tool", keys: ["format"]), description = entry("Other", description: "Format documents")
        let catalog = LauncherCatalog(entries: [description, alias, title])
        XCTAssertEqual(catalog.search("Format", recent: [description.id]).map(\.entry.id), [title.id, alias.id, description.id])
        XCTAssertEqual(catalog.search("format hello world", recent: []).first?.argument, "hello world")
        XCTAssertTrue(catalog.search("", recent: []).isEmpty)
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let store = PluginPreferencesStore(directory: root)
        try store.recordUse(actionID: alias.id); try store.recordUse(actionID: title.id)
        let recent = try PluginPreferencesStore(directory: root).recent()
        XCTAssertEqual(catalog.search("", recent: recent).map(\.entry.id), [title.id, alias.id])
        XCTAssertEqual(LauncherCatalog(entries: [alias]).search("", recent: recent).map(\.entry.id), [alias.id])
        XCTAssertNotEqual(PackManager.workflowUUID(packKey: "p", workflowID: "a"), PackManager.actionUUID(packKey: "p", packActionID: "a"))
    }
}

@MainActor
final class ToolWorkspaceTests: XCTestCase {
    func testDemoManifestAndJSONPanel() async throws {
        let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("examples/tool-panel-demo")
        let manifest = try PackManifest.decode(Data(contentsOf: root.appendingPathComponent("manifest.json")))
        try manifest.validate()
        let definition = try XCTUnwrap(manifest.actions.first { $0.id == "json" })
        let action = MenuAction(id: UUID(), title: definition.title, icon: .symbol(definition.icon), kind: .openPluginUI,
                                matching: MatchRule(), placement: .topLevel, packID: "demo-test", isEnabled: true, sortOrder: 0)
        let entry = PluginLauncherEntry(id: action.id, action: action, definition: definition, directory: root)
        let session = PluginSession(entry: entry, invocation: .init(actionID: entry.id, source: .launcher))
        defer { session.close() }
        for _ in 0..<100 {
            if session.webView.url != nil && !session.webView.isLoading { break }
            try await Task.sleep(nanoseconds: 50_000_000)
        }
        let formatted = try await session.webView.evaluateJavaScript("document.getElementById('json').value = '{\"n\":1}'; document.getElementById('format').click(); document.getElementById('json').value")
        XCTAssertEqual(formatted as? String, "{\n  \"n\": 1\n}")
        XCTAssertNil(session.error)
        for (appearance, expected) in [(NSAppearance.Name.darkAqua, "rgb(32, 33, 37)"), (.aqua, "rgb(246, 246, 248)")] {
            session.webView.appearance = NSAppearance(named: appearance)
            var color: String?
            for _ in 0..<30 {
                color = try await session.webView.evaluateJavaScript("getComputedStyle(document.documentElement).backgroundColor") as? String
                if color == expected { break }
                try await Task.sleep(nanoseconds: 50_000_000)
            }
            XCTAssertEqual(color, expected)
        }
    }
    func testIndependentWebViewsCloseReopenAndSearchContext() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        try "<html><body><input id='text' value='initial'></body></html>".write(to: root.appendingPathComponent("index.html"), atomically: true, encoding: .utf8)
        let manifest = try PackManifest.decode(Data(#"{"schemaVersion":4,"uiApiVersion":1,"name":"Test","actions":[{"id":"ui","title":"UI","ui":{"entry":"index.html"},"launcher":{}}]}"#.utf8))
        func entry() -> PluginLauncherEntry {
            let action = MenuAction(id: UUID(), title: "UI", icon: .symbol("bolt"), kind: .openPluginUI,
                                    matching: MatchRule(), placement: .topLevel, packID: "window-test", isEnabled: true, sortOrder: 0)
            return PluginLauncherEntry(id: action.id, action: action, definition: manifest.actions[0], directory: root)
        }
        let first = entry(), second = entry()
        let invocation = PluginInvocation(actionID: first.id, source: .launcher, query: "UI hello")
        let workspace = ToolWorkspaceController()
        defer { workspace.close() }
        let a = workspace.open(first, invocation: invocation), b = workspace.open(second, invocation: invocation)
        let window = try XCTUnwrap(a.window)
        XCTAssertFalse(window is NSPanel)
        XCTAssertEqual(window.level, .normal)
        XCTAssertFalse(window.hidesOnDeactivate)
        XCTAssertEqual(window.toolbarStyle, .unifiedCompact)
        let panel = PluginLauncherController()
        panel.query = "UI hello"; panel.selectedID = first.id.uuidString
        panel.session = PluginSession(entry: first, invocation: invocation)
        XCTAssertEqual(panel.panelState, .tool)
        XCTAssertFalse(panel.session?.webView === a.session.webView)
        XCTAssertFalse(a.session.webView === b.session.webView)
        XCTAssertTrue(workspace.open(first, invocation: invocation) === a)
        for _ in 0..<100 {
            if a.session.webView.url != nil && !a.session.webView.isLoading && b.session.webView.url != nil && !b.session.webView.isLoading { break }
            try await Task.sleep(nanoseconds: 50_000_000)
        }
        _ = try await a.session.webView.evaluateJavaScript("document.getElementById('text').value = 'changed'")
        let value = try await b.session.webView.evaluateJavaScript("document.getElementById('text').value")
        XCTAssertEqual(value as? String, "initial")
        let reload = try XCTUnwrap(window.toolbar?.items.first { $0.action != nil })
        let previousSession = a.session
        XCTAssertTrue(NSApp.sendAction(try XCTUnwrap(reload.action), to: reload.target, from: reload))
        XCTAssertTrue(previousSession.closed)
        XCTAssertNotEqual(previousSession.id, a.session.id)
        for _ in 0..<100 {
            if a.session.webView.url != nil && !a.session.webView.isLoading { break }
            try await Task.sleep(nanoseconds: 50_000_000)
        }
        let reloadedValue = try await a.session.webView.evaluateJavaScript("document.getElementById('text').value")
        XCTAssertEqual(reloadedValue as? String, "initial")
        panel.back()
        XCTAssertEqual(panel.panelState, .search)
        XCTAssertEqual(panel.query, "UI hello")
        XCTAssertEqual(panel.selectedID, first.id.uuidString)
        XCTAssertFalse(a.session.closed)
        XCTAssertTrue(a.endSession()); XCTAssertTrue(a.session.closed)
        XCTAssertEqual(workspace.windows.count, 1)
        XCTAssertFalse(b.session.closed)
        let reopened = workspace.open(first, invocation: invocation)
        XCTAssertNotEqual(reopened.session.id, a.session.id)
        panel.hide(); XCTAssertNil(panel.session); XCTAssertEqual(panel.query, "")
        panel.session = PluginSession(entry: first, invocation: invocation)
        let embedded = try XCTUnwrap(panel.session)
        panel.detachTool()
        defer { _ = ToolWorkspaceController.shared.close(packKey: "window-test") }
        XCTAssertTrue(embedded.closed)
        XCTAssertNil(panel.session)
        XCTAssertEqual(panel.panelState, .search)
        XCTAssertEqual(ToolWorkspaceController.shared.windows[first.id]?.window?.isVisible, true)
        XCTAssertTrue(workspace.close(packKey: "window-test")); XCTAssertTrue(workspace.windows.isEmpty)
    }
}

@MainActor
final class ToolChainTests: XCTestCase {
    private var root: URL {
        URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().appendingPathComponent("examples/tool-chain-demo")
    }
    func testPureToolsExtractionSelectionAndTypeInference() throws {
        let js = try XCTUnwrap(JSContext())
        js.evaluateScript(try String(contentsOf: root.appendingPathComponent("tools.js")))
        let result = js.evaluateScript(#"""
          (() => {
            const values = ToolChain.extract('log [INFO] {"text":"} [ \\\"","items":[1]} tail {"next":true}');
            const data = {'a.b': {'x/y': [1, null]}};
            const path = ToolChain.nodes(data).find(n => n.label.startsWith('$/a.b/x~1y —')).path;
            const types = ToolChain.types([{id:1,name:'a'}, {id:2,active:true,name:null}], 'User');
            function fails(fn) { try { fn(); return false; } catch (_) { return true; } }
            return {count:values.length, selected:ToolChain.select(data,path), types,
              invalid:fails(() => ToolChain.extract('not JSON')),
              large:fails(() => ToolChain.parse('{"id":9007199254740993}')),
              depth:fails(() => ToolChain.extract('['.repeat(65)+'0'+']'.repeat(65))),
              name:fails(() => ToolChain.types({}, 'invalid name')),
              empty:ToolChain.types([]), primitive:ToolChain.types([1,'a',null])};
          })()
        """#)?.toDictionary()
        XCTAssertNil(js.exception)
        XCTAssertEqual(result?["count"] as? Int, 2)
        XCTAssertEqual((result?["selected"] as? [Any])?.first as? Int, 1)
        let types = try XCTUnwrap(result?["types"] as? String)
        XCTAssertTrue(types.contains("name: string | null"))
        XCTAssertTrue(types.contains("active?: boolean"))
        for key in ["invalid", "large", "depth", "name"] { XCTAssertEqual(result?[key] as? Bool, true, key) }
        XCTAssertEqual(result?["empty"] as? String, "export type Response = Array<unknown>;")
        XCTAssertEqual(result?["primitive"] as? String, "export type Response = Array<string | number | null>;")
    }
    private func waitForStep(_ controller: PluginLauncherController, _ index: Int) async throws -> PluginSession {
        for _ in 0..<100 {
            if controller.workflowStepIndex == index, let session = controller.session, !session.closed,
               session.webView.url != nil, !session.webView.isLoading,
               (try? await session.webView.evaluateJavaScript("document.getElementById('mode').textContent.includes('步骤')")) as? Bool == true {
                return session
            }
            try await Task.sleep(nanoseconds: 50_000_000)
        }
        XCTFail("Did not reach workflow step \(index)")
        return try XCTUnwrap(controller.session)
    }
    func testRealPagesChainAndStandaloneTool() async throws {
        let manifest = try PackManifest.decode(Data(contentsOf: root.appendingPathComponent("manifest.json")))
        try manifest.validate()
        let pack = InstalledPack(key: "tool-chain-test", manifest: manifest, repoURL: "", repo: "", commitSHA: "", enabledCount: 0, totalCount: 3)
        let workflow = LauncherWorkflowEntry(pack: pack, definition: manifest.workflows[0], directory: root)
        let controller = PluginLauncherController()
        defer { controller.back() }
        controller.beginWorkflow(workflow, invocation: .init(actionID: workflow.id, source: .launcher))
        let a = try await waitForStep(controller, 0)
        _ = try await a.webView.evaluateJavaScript("document.getElementById('sample').click(); document.getElementById('process').click(); document.getElementById('next').click(); true")
        let b = try await waitForStep(controller, 1)
        XCTAssertTrue(a.closed)
        let received = try await b.webView.callAsyncJavaScript("return (await anywhere.workflow.context()).input.data.items.length", arguments: [:], in: nil, contentWorld: .page)
        XCTAssertEqual(received as? Int, 2)
        try await Task.sleep(nanoseconds: 150_000_000)
        XCTAssertEqual(controller.workflowStepIndex, 1) // B waits; it must not silently pass the root.
        controller.reload()
        let reloaded = try await waitForStep(controller, 1)
        XCTAssertTrue(b.closed)
        _ = try await reloaded.webView.evaluateJavaScript("const choice = document.getElementById('choice'); choice.value = Array.from(choice.options).find(o => o.textContent.startsWith('$/data/items —')).value; choice.dispatchEvent(new Event('change')); document.getElementById('next').click(); true")
        let c = try await waitForStep(controller, 2)
        let generated = try await c.webView.evaluateJavaScript("document.getElementById('code').value")
        let code = try XCTUnwrap(generated as? String)
        XCTAssertTrue(code.contains("email?: string"))
        XCTAssertTrue(code.contains("active?: boolean"))
        XCTAssertFalse(code.contains("status:"))
        let standalone = PluginSession(entry: c.entry, invocation: c.invocation)
        defer { standalone.close() }
        for _ in 0..<100 {
            if standalone.webView.url != nil && !standalone.webView.isLoading { break }
            try await Task.sleep(nanoseconds: 50_000_000)
        }
        let standaloneCode = try await standalone.webView.callAsyncJavaScript("document.getElementById('sample').click(); document.getElementById('process').click(); return document.getElementById('code').value", arguments: [:], in: nil, contentWorld: .page)
        XCTAssertEqual(standaloneCode as? String, code)
        let denied = try await standalone.webView.callAsyncJavaScript("try { await anywhere.workflow.complete('invalid'); return 'allowed'; } catch(e) { return e.code; }", arguments: [:], in: nil, contentWorld: .page)
        XCTAssertEqual(denied as? String, "denied")
        _ = try await c.webView.evaluateJavaScript("document.getElementById('next').click(); true")
        for _ in 0..<100 where controller.workflowRunning { try await Task.sleep(nanoseconds: 20_000_000) }
        XCTAssertFalse(controller.workflowRunning)
        XCTAssertNil(controller.session)
        XCTAssertEqual(controller.workflowOutput, code)
        controller.beginWorkflow(workflow, invocation: .init(actionID: workflow.id, source: .launcher))
        let cancelled = try await waitForStep(controller, 0)
        controller.back()
        XCTAssertTrue(cancelled.closed); XCTAssertNil(controller.workflow); XCTAssertNil(controller.session)
    }
    func testWorkflowBridgeRejectsDuplicateSubmission() async throws {
        let manifest = try PackManifest.decode(Data(contentsOf: root.appendingPathComponent("manifest.json")))
        let definition = manifest.actions[0], id = UUID()
        let action = MenuAction(id: id, title: definition.title, icon: .symbol(definition.icon), kind: .openPluginUI,
                                matching: MatchRule(), placement: .topLevel, packID: "bridge-test", isEnabled: true, sortOrder: 0)
        let entry = PluginLauncherEntry(id: id, action: action, definition: definition, directory: root)
        var submitted: [JSONValue] = []
        let session = PluginSession(entry: entry, invocation: .init(actionID: id, source: .launcher), workflowInput: .null) { submitted.append($0) }
        defer { session.close() }
        for _ in 0..<100 {
            if session.webView.url != nil && !session.webView.isLoading { break }
            try await Task.sleep(nanoseconds: 50_000_000)
        }
        let duplicate = try await session.webView.callAsyncJavaScript("await anywhere.workflow.complete({value:42}); try { await anywhere.workflow.complete('duplicate'); } catch(e) { return e.code; }", arguments: [:], in: nil, contentWorld: .page)
        XCTAssertEqual(duplicate as? String, "busy")
        XCTAssertEqual(submitted, [.object(["value": .number(42)])])
    }
    func testScriptWorkflowControllerPassesDataAndStops() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        try "printf '{\"id\":42}'".write(to: directory.appendingPathComponent("a.zsh"), atomically: true, encoding: .utf8)
        try "/usr/bin/plutil -extract input.id raw -o - \"$ANYWHERE_REQUEST_FILE\"".write(to: directory.appendingPathComponent("b.zsh"), atomically: true, encoding: .utf8)
        let manifest = PackManifest(schemaVersion: 4, name: "Script test", actions: [
            PackAction(id: "a", title: "A", script: "a.zsh"), PackAction(id: "b", title: "B", script: "b.zsh")])
        let pack = InstalledPack(key: "script-chain-test", manifest: manifest, repoURL: "", repo: "", commitSHA: "", enabledCount: 0, totalCount: 2)
        let workflow = LauncherWorkflowEntry(pack: pack, definition: .init(id: "test", title: "Script chain test", steps: [.init(action: "a"), .init(action: "b")]), directory: directory)
        let controller = PluginLauncherController()
        defer { controller.back() }
        controller.beginWorkflow(workflow, invocation: .init(actionID: workflow.id, source: .launcher))
        for _ in 0..<200 where controller.workflowRunning { try await Task.sleep(nanoseconds: 20_000_000) }
        XCTAssertFalse(controller.workflowRunning); XCTAssertEqual(controller.workflowOutput, "42"); XCTAssertNil(controller.error)
        controller.back()
        try "exit 7".write(to: directory.appendingPathComponent("a.zsh"), atomically: true, encoding: .utf8)
        try "touch should-not-exist".write(to: directory.appendingPathComponent("b.zsh"), atomically: true, encoding: .utf8)
        controller.beginWorkflow(workflow, invocation: .init(actionID: workflow.id, source: .launcher))
        for _ in 0..<200 where controller.workflowRunning { try await Task.sleep(nanoseconds: 20_000_000) }
        XCTAssertFalse(controller.workflowRunning); XCTAssertNotNil(controller.error)
        XCTAssertEqual(controller.workflowStepIndex, 0)
        XCTAssertFalse(FileManager.default.fileExists(atPath: directory.appendingPathComponent("should-not-exist").path))
    }
}

final class LauncherWorkflowTests: XCTestCase {
    func testClipboardJSONWorkflowsPreserveInputOnFailure() throws {
        let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("examples/tool-panel-demo")
        let manifest = try PackManifest.decode(Data(contentsOf: root.appendingPathComponent("manifest.json")))
        try manifest.validate()
        let pack = InstalledPack(key: "clipboard-workflow-test", manifest: manifest, repoURL: "", repo: "", commitSHA: "", enabledCount: 0, totalCount: manifest.actions.count)
        let boardName = "AnyWhere.tests." + UUID().uuidString
        let board = NSPasteboard(name: .init(boardName))
        defer { board.releaseGlobally() }
        let environment = ["ANYWHERE_DEMO_PASTEBOARD": boardName]
        func copy(_ text: String) {
            board.clearContents()
            XCTAssertTrue(board.setString(text, forType: .string))
        }
        func run(_ id: String) throws -> JSONValue {
            let definition = try XCTUnwrap(manifest.workflows.first { $0.id == id })
            let entry = LauncherWorkflowEntry(pack: pack, definition: definition, directory: root)
            return try LauncherWorkflowRun().run(entry: entry, invocation: .init(actionID: entry.id, source: .launcher), input: .null, environment: environment).get()
        }
        let compact = #"{"name":"便笺","items":[1,true,null]}"#
        let formatted = "{\n  \"name\": \"便笺\",\n  \"items\": [\n    1,\n    true,\n    null\n  ]\n}"
        copy(compact)
        XCTAssertEqual(try run("format-clipboard-json"), .string(formatted))
        XCTAssertEqual(board.string(forType: .string), formatted)
        XCTAssertEqual(try run("compact-clipboard-json"), .string(compact))
        XCTAssertEqual(board.string(forType: .string), compact)
        for invalid in ["", "{broken", #"{"id":9007199254740993}"#] {
            copy(invalid)
            let version = board.changeCount
            XCTAssertThrowsError(try run("format-clipboard-json"))
            XCTAssertEqual(board.string(forType: .string), invalid)
            XCTAssertEqual(board.changeCount, version)
        }
        // 在最后一步之前复制新内容，旧工作流不能覆盖用户的新剪贴板。
        copy(compact)
        let staleInput: JSONValue = .object(["text": .string(formatted), "changeCount": .number(Double(board.changeCount))])
        copy("new copy")
        let result = PluginTask().run(script: root.appendingPathComponent("write-clipboard.zsh"), directory: root,
                                     invocation: .init(actionID: UUID(), source: .launcher), input: staleInput,
                                     environment: environment, secrets: [], timeout: 10) { _, _ in }
        XCTAssertNotNil(result.error)
        XCTAssertEqual(board.string(forType: .string), "new copy")
    }

    func testRealScriptsPassOutputStopOnFailureAndCancel() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        func write(_ name: String, _ script: String) throws {
            try script.write(to: root.appendingPathComponent(name), atomically: true, encoding: .utf8)
        }
        try write("a.zsh", "printf '\"first\"'")
        try write("b.zsh", "value=$(/usr/bin/plutil -extract input raw -o - \"$ANYWHERE_REQUEST_FILE\"); printf '%s-second' \"$value\"")
        let actions = [PackAction(id: "a", title: "A", script: "a.zsh"), PackAction(id: "b", title: "B", script: "b.zsh")]
        let manifest = PackManifest(schemaVersion: 4, name: "Test", actions: actions)
        let pack = InstalledPack(key: "workflow-test", manifest: manifest, repoURL: "", repo: "", commitSHA: "", enabledCount: 0, totalCount: 2)
        let entry = LauncherWorkflowEntry(pack: pack, definition: .init(id: "w", title: "Workflow", steps: [.init(action: "a"), .init(action: "b")]), directory: root)
        let invocation = PluginInvocation(actionID: entry.id, source: .launcher)
        let result = LauncherWorkflowRun().run(entry: entry, invocation: invocation, input: .null, environment: [:])
        XCTAssertEqual(try result.get(), .string("first-second"))
        try write("a.zsh", "exit 7")
        try write("b.zsh", "touch should-not-exist")
        XCTAssertThrowsError(try LauncherWorkflowRun().run(entry: entry, invocation: invocation, input: .null, environment: [:]).get())
        XCTAssertFalse(FileManager.default.fileExists(atPath: root.appendingPathComponent("should-not-exist").path))
        try write("a.zsh", "sleep 30")
        let run = LauncherWorkflowRun()
        let executing = Task.detached { run.run(entry: entry, invocation: invocation, input: .null, environment: [:]) }
        try await Task.sleep(nanoseconds: 150_000_000)
        XCTAssertTrue(run.cancelAndWait())
        let cancelled = await executing.value
        XCTAssertThrowsError(try cancelled.get())
        XCTAssertFalse(FileManager.default.fileExists(atPath: root.appendingPathComponent("should-not-exist").path))
    }
}
