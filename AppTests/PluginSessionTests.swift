import XCTest
import WebKit
import AnyWhereCore
@testable import AnyWhere

@MainActor
final class PluginSessionTests: XCTestCase {
    func testRealWebViewBridgeAndResourceRestrictions() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: false)
        defer { try? FileManager.default.removeItem(at: root) }
        try "<html><body><h1>Plugin</h1></body></html>".write(to: root.appendingPathComponent("index.html"), atomically: true, encoding: .utf8)
        let manifest = try PackManifest.decode(Data(#"{"schemaVersion":4,"uiApiVersion":1,"name":"Test","actions":[{"id":"ui","title":"UI","ui":{"entry":"index.html"},"launcher":{}}]}"#.utf8))
        let id = UUID(), packKey = "test-" + UUID().uuidString
        let action = MenuAction(id: id, title: "UI", icon: .symbol("bolt"), kind: .openPluginUI,
                                matching: MatchRule(), placement: .topLevel, packID: packKey, isEnabled: true, sortOrder: 0)
        let entry = PluginLauncherEntry(id: id, action: action, definition: manifest.actions[0], directory: root)
        let context = PluginInvocation(actionID: id, source: .launcher, query: "UI hello", argument: "hello")
        let session = PluginSession(entry: entry, invocation: context)
        defer { session.close(); try? FileManager.default.removeItem(at: PackManager.dataDirectory(packKey)) }
        for _ in 0..<100 {
            if session.webView.url != nil && !session.webView.isLoading { break }
            try await Task.sleep(nanoseconds: 50_000_000)
        }
        XCTAssertNil(session.error)
        let argument = try await session.webView.callAsyncJavaScript("return (await anywhere.getInvocation()).argument", arguments: [:], in: nil, contentWorld: .page)
        XCTAssertEqual(argument as? String, "hello")
        let stored = try await session.webView.callAsyncJavaScript("await anywhere.storage.set('key', false); return await anywhere.storage.get('key')", arguments: [:], in: nil, contentWorld: .page)
        XCTAssertEqual(stored as? Bool, false)
        let denied = try await session.webView.callAsyncJavaScript("try { await anywhere.clipboard.writeText('not permitted'); } catch(e) { return e.code; }", arguments: [:], in: nil, contentWorld: .page)
        XCTAssertEqual(denied as? String, "denied")
        let network = try await session.webView.callAsyncJavaScript("try { await fetch('https://example.com'); return 'allowed'; } catch(e) { return 'blocked'; }", arguments: [:], in: nil, contentWorld: .page)
        XCTAssertEqual(network as? String, "blocked")
        let oversized = try await session.webView.callAsyncJavaScript("try { await anywhere.storage.set('big', 'x'.repeat(1048576)); } catch(e) { return e.code; }", arguments: [:], in: nil, contentWorld: .page)
        XCTAssertEqual(oversized as? String, "invalidArguments")
        session.close()
        XCTAssertTrue(session.closed)

        try "printf 'start'; sleep .2; printf 'done'".write(to: root.appendingPathComponent("task.zsh"), atomically: true, encoding: .utf8)
        var definition = entry.definition
        definition.script = "task.zsh"; definition.capabilities = [.runTask]
        let taskEntry = PluginLauncherEntry(id: id, action: action, definition: definition, directory: root)
        let taskSession = PluginSession(entry: taskEntry, invocation: context)
        defer { taskSession.close() }
        for _ in 0..<100 {
            if taskSession.webView.url != nil && !taskSession.webView.isLoading { break }
            try await Task.sleep(nanoseconds: 50_000_000)
        }
        let taskResult = try await taskSession.webView.callAsyncJavaScript("""
          let output = '';
          const task = await anywhere.tasks.run({text: 'safe input'});
          task.onOutput(e => output += e.text);
          let busy;
          try { await anywhere.tasks.run(null); } catch(e) { busy = e.code; }
          const result = await task.result;
          return {code: result.exitCode, stdout: result.stdout, output, busy};
          """, arguments: [:], in: nil, contentWorld: .page) as? [String: Any]
        XCTAssertEqual(taskResult?["code"] as? Int, 0)
        XCTAssertEqual(taskResult?["stdout"] as? String, "startdone")
        XCTAssertEqual(taskResult?["output"] as? String, "startdone")
        XCTAssertEqual(taskResult?["busy"] as? String, "busy")
    }
}
