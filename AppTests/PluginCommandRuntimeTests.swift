import XCTest
import WebKit
import AnyWhereCore
@testable import AnyWhere

@MainActor
final class PluginCommandRuntimeTests: XCTestCase {
    private var folders: [URL] = []
    private var sessions: [PluginSession] = []
    override func tearDown() {
        for session in sessions { session.close(discardUnsaved: true) }
        for folder in folders { try? FileManager.default.removeItem(at: folder) }
        super.tearDown()
    }
    private func todo() throws -> (PluginLauncherEntry, PluginServices) {
        let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent().appendingPathComponent("anywhere-todo")
        let manifest = try PackSnapshot.read(in: root).manifest
        let pack = "test-mcp-" + UUID().uuidString, id = PluginActionIdentity.uuid(packKey: pack, actionID: "todo")
        let action = MenuAction(id: id, title: "Todo", icon: .symbol("bolt"), kind: .openPluginUI,
            matching: MatchRule(), placement: .topLevel, packID: pack, isEnabled: true, sortOrder: 0)
        let entry = PluginLauncherEntry(id: id, action: action, definition: manifest.actions[0], directory: root)
        folders.append(PackManager.dataDirectory(pack))
        let services = PluginServices(namespace: "test.mcp.\(UUID()).")
        services.reconcile([entry]); PluginCommandRuntime.shared.remember(entry, services: services)
        return (entry, services)
    }
    private func call(_ entry: PluginLauncherEntry, _ operation: String, _ json: String = "{}") async throws -> JSONValue {
        try await PluginCommandRuntime.shared.invoke(entry: entry, operation: operation, params: JSONDecoder().decode(JSONValue.self, from: Data(json.utf8)))
    }
    func testRealWorkerSerializesWritesRejectsConflictsAndProtectsReminders() async throws {
        let (entry, _) = try todo()
        async let a = call(entry, "create", #"{"requestId":"a","fields":{"title":"A","due":null}}"#)
        async let b = call(entry, "create", #"{"requestId":"b","fields":{"title":"B"}}"#)
        let (createdA, createdB) = try await (a, b)
        let idA = try XCTUnwrap(createdA.object?["item"]?.object?["id"]?.string)
        let idB = try XCTUnwrap(createdB.object?["item"]?.object?["id"]?.string)
        XCTAssertNotEqual(idA, "a"); XCTAssertNotEqual(idB, "b")
        let snapshot = try await call(entry, "snapshot")
        let versions = try XCTUnwrap(snapshot.object?["versions"]?.object)
        let va = try XCTUnwrap(versions[idA]?.string), vb = try XCTUnwrap(versions[idB]?.string)
        async let updateA = call(entry, "update", "{\"id\":\"\(idA)\",\"expectedVersion\":\"\(va)\",\"patch\":{\"note\":\"AI\"}}")
        async let updateB = call(entry, "update", "{\"id\":\"\(idB)\",\"expectedVersion\":\"\(vb)\",\"patch\":{\"note\":\"UI\"}}")
        _ = try await (updateA, updateB)
        do {
            _ = try await call(entry, "update", "{\"id\":\"\(idA)\",\"expectedVersion\":\"\(va)\",\"patch\":{\"title\":\"stale\"}}")
            XCTFail("Stale edit must fail")
        } catch { XCTAssertEqual((error as? PluginError)?.code, .conflict) }
        let listed = try await call(entry, "list", #"{"status":"all"}"#)
        let items = try XCTUnwrap(listed.object?["items"]?.array)
        XCTAssertEqual(items.count, 2)
        XCTAssertEqual(items.first { $0.object?["id"] == .string(idA) }?.object?["note"], .string("AI"))
        XCTAssertEqual(items.first { $0.object?["id"] == .string(idB) }?.object?["note"], .string("UI"))
        let latest = try XCTUnwrap(items.first { $0.object?["id"] == .string(idA) }?.object?["version"]?.string)
        let reminded = try await call(entry, "update", "{\"id\":\"\(idA)\",\"expectedVersion\":\"\(latest)\",\"patch\":{\"due\":\(Date().addingTimeInterval(3600).timeIntervalSince1970 * 1000),\"recurrence\":\"daily\"}}")
        XCTAssertEqual(try PluginServices.store(entry).reminders().count, 1)
        let reminderVersion = try XCTUnwrap(reminded.object?["versions"]?.object?[idA]?.string)
        _ = try await call(entry, "complete", "{\"id\":\"\(idA)\",\"expectedVersion\":\"\(reminderVersion)\"}")
        XCTAssertTrue(try PluginServices.store(entry).reminders().isEmpty)
        let session = PluginSession(entry: entry, invocation: .init(actionID: entry.id, source: .launcher))
        sessions.append(session)
        for _ in 0..<200 { if session.webView.url != nil && !session.webView.isLoading { break }; try await Task.sleep(nanoseconds: 25_000_000) }
        let denied = try await session.webView.callAsyncJavaScript("try {await anywhere.storage.set('todos', {});return 'unsafe'}catch(e){return e.code}", arguments: [:], in: nil, contentWorld: .page)
        XCTAssertEqual(denied as? String, "denied")
    }
    func testMCPDiscoveryRoutesOnlyApprovedExportsAndRevokesImmediately() async throws {
        let (entry, _) = try todo(), registry = PluginMCPRegistry()
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        folders.append(root)
        let preferences = PluginPreferencesStore(directory: root)
        registry.reconcile([entry], preferences: preferences)
        var tools = await registry.handle(.object(["method": .string("tools")]))
        XCTAssertEqual(tools.object?["result"]?.array?.count, 0)
        try preferences.setMCPEnabled(true, actionID: entry.id, approval: entry.definition.mcpApproval!)
        tools = await registry.handle(.object(["method": .string("tools")]))
        XCTAssertEqual(tools.object?["result"]?.array?.first?.object?["name"], .string("todo"))
        let info = await registry.handle(.object(["method": .string("call"), "name": .string("list"), "arguments": .object(["plugin": .string("todo")])]))
        XCTAssertEqual(info.object?["result"]?.object?["plugins"]?.array?.count, 1)
        let forbidden = await registry.handle(.object(["method": .string("call"), "name": .string("todo"), "arguments": .object(["operation": .string("remove"), "params": .object([:])])]))
        XCTAssertNotNil(forbidden.object?["error"])
        let created = await registry.handle(.object(["method": .string("call"), "name": .string("todo"), "arguments": .object(["operation": .string("create"), "params": .object(["requestId": .string("mcp"), "fields": .object(["title": .string("MCP task")])])])]))
        XCTAssertNil(created.object?["error"])
        try preferences.setMCPEnabled(false, actionID: entry.id, approval: entry.definition.mcpApproval!)
        let revoked = await registry.handle(.object(["method": .string("call"), "name": .string("todo"), "arguments": .object(["operation": .string("list"), "params": .object([:])])]))
        XCTAssertNotNil(revoked.object?["error"])
    }
    func testUIRetainsDraftWhenAIChangesSameTask() async throws {
        let (entry, services) = try todo()
        let created = try await call(entry, "create", #"{"fields":{"title":"Original"}}"#)
        let taskID = try XCTUnwrap(created.object?["item"]?.object?["id"]?.string)
        let session = PluginSession(entry: entry, invocation: .init(actionID: entry.id, source: .launcher), notificationServices: services)
        sessions.append(session)
        for _ in 0..<200 { if session.webView.url != nil && !session.webView.isLoading { break }; try await Task.sleep(nanoseconds: 25_000_000) }
        _ = try await session.webView.callAsyncJavaScript("""
          for(let i=0;i<200&&document.getElementById('new').disabled;i++)await new Promise(r=>setTimeout(r,25));
          document.querySelector('[data-view="all"]').click();
          document.querySelector('#todo-'+taskID+' .task-title').click();
          document.getElementById('title').value='Unsaved draft';
          document.getElementById('title').dispatchEvent(new Event('input',{bubbles:true}));
          """, arguments: ["taskID": taskID], in: nil, contentWorld: .page)
        let snapshot = try await call(entry, "snapshot"), version = try XCTUnwrap(snapshot.object?["versions"]?.object?[taskID]?.string)
        _ = try await call(entry, "update", "{\"id\":\"\(taskID)\",\"expectedVersion\":\"\(version)\",\"patch\":{\"title\":\"AI saved\"}}")
        let result = try await session.webView.callAsyncJavaScript("""
          document.getElementById('form').requestSubmit();
          const disabledImmediately = document.getElementById('new').disabled;
          for(let i=0;i<200&&!document.getElementById('message').textContent.includes('其他操作');i++)await new Promise(r=>setTimeout(r,25));
          return {draft:document.getElementById('title').value,open:!document.getElementById('form').hidden,message:document.getElementById('message').textContent,disabledImmediately};
          """, arguments: [:], in: nil, contentWorld: .page) as? [String: Any]
        XCTAssertEqual(result?["draft"] as? String, "Unsaved draft")
        XCTAssertEqual(result?["open"] as? Bool, true)
        XCTAssertEqual(result?["disabledImmediately"] as? Bool, true)
        XCTAssertTrue((result?["message"] as? String)?.contains("其他操作") == true)
        let stored = try await call(entry, "list", "{\"id\":\"\(taskID)\"}")
        XCTAssertEqual(stored.object?["items"]?.array?.first?.object?["title"], .string("AI saved"))
    }
    func testPackagedStdioMCPCallsRealTodoWorker() async throws {
        let (entry, _) = try todo()
        let root = URL(fileURLWithPath: "/tmp/aw-mcp-" + UUID().uuidString)
        folders.append(root)
        let path = root.appendingPathComponent("ipc.sock").path
        let preferences = PluginPreferencesStore(directory: root)
        try preferences.setMCPEnabled(true, actionID: entry.id, approval: entry.definition.mcpApproval!)
        let registry = PluginMCPRegistry(socketPath: path)
        registry.reconcile([entry], preferences: preferences); registry.start()
        defer { registry.stop() }
        let revokeFile = root.appendingPathComponent("revoke").path
        let revocation = Task { @MainActor in
            while !Task.isCancelled && !FileManager.default.fileExists(atPath: revokeFile) { try? await Task.sleep(nanoseconds: 25_000_000) }
            if !Task.isCancelled { try preferences.setMCPEnabled(false, actionID: entry.id, approval: entry.definition.mcpApproval!) }
        }
        defer { revocation.cancel() }
        let helper = Bundle.main.bundleURL.appendingPathComponent("Contents/MacOS/anywhere-mcp").path
        XCTAssertTrue(FileManager.default.isExecutableFile(atPath: helper))
        let script = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().appendingPathComponent("scripts/test-mcp.py").path
        let outcome = try await Task.detached { () throws -> (Int32, String) in
            let process = Process(), pipe = Pipe()
            process.executableURL = URL(fileURLWithPath: "/usr/bin/python3"); process.arguments = [script, helper]
            var environment = ProcessInfo.processInfo.environment; environment["ANYWHERE_MCP_SOCKET_PATH"] = path
            environment["ANYWHERE_MCP_REVOKE_FILE"] = revokeFile
            process.environment = environment; process.standardOutput = pipe; process.standardError = pipe
            try process.run()
            let data = pipe.fileHandleForReading.readDataToEndOfFile(); process.waitUntilExit()
            return (process.terminationStatus, String(decoding: data, as: UTF8.self))
        }.value
        XCTAssertEqual(outcome.0, 0, outcome.1)
        XCTAssertTrue(outcome.1.contains("passed"), outcome.1)
    }
    func testWorkersDenyReadOnlySideEffectsDrainTasksAndRecheckAuthorization() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true); folders.append(root)
        let marker = root.appendingPathComponent("stopped")
        let launches = root.appendingPathComponent("launches")
        try "trap 'sleep 1; echo stopped > \"\(marker.path)\"; exit' TERM\necho started >> \"\(launches.path)\"\nprintf started\nwhile :; do /bin/sleep .05; done\n".write(to: root.appendingPathComponent("task.zsh"), atomically: true, encoding: .utf8)
        try #"""
        <meta charset="utf-8"><script>
        anywhere.commands.register({
          probe: async () => {
            const codes = [];
            for (const operation of [() => anywhere.tasks.run(null), () => anywhere.launcher.setEntries([]), () => anywhere.documents.saveDraft('x', 1), () => anywhere.storage.set('items', 1)]) {
              try {await operation();codes.push('unsafe')} catch(error) {codes.push(error.code)}
            }
            return {codes};
          },
          fire: async () => {
            const task = await anywhere.tasks.run(null);
            task.result.catch(() => anywhere.tasks.run(null)).catch(() => {});
            await new Promise(resolve => task.onOutput(resolve));
            return {started:true};
          },
          late: async () => {await new Promise(resolve=>setTimeout(resolve,300));await anywhere.storage.set('items', 'late');return {};}
        });
        </script>
        """#.write(to: root.appendingPathComponent("commands.html"), atomically: true, encoding: .utf8)
        let manifest = try PackManifest.decode(Data(#"""
        {"schemaVersion":5,"name":"Worker test","actions":[{"id":"worker","title":"Worker","contextMenu":false,"script":"task.zsh","capabilities":["task.run","launcher.entries","documents"],
        "commands":{"entry":"commands.html","storageKeys":["items"],"operations":{
        "probe":{"description":"probe","readOnly":true,"inputSchema":{"type":"object"}},
        "fire":{"description":"fire","readOnly":false,"inputSchema":{"type":"object"}},
        "late":{"description":"late","readOnly":false,"inputSchema":{"type":"object"}}}}}]}
        """#.utf8)); try manifest.validate()
        let pack = "test-worker-" + UUID().uuidString, id = UUID()
        let action = MenuAction(id: id, title: "Worker", icon: .symbol("bolt"), kind: .openPluginUI,
            matching: MatchRule(), placement: .topLevel, packID: pack, isEnabled: true, sortOrder: 0)
        let entry = PluginLauncherEntry(id: id, action: action, definition: manifest.actions[0], directory: root)
        folders.append(PackManager.dataDirectory(pack))
        let runtime = PluginCommandRuntime(), services = PluginServices(namespace: "test.worker.\(UUID()).")
        runtime.remember(entry, services: services)
        let checked = try await runtime.invoke(entry: entry, operation: "probe", params: .object([:]))
        XCTAssertEqual(checked.object?["codes"]?.array, Array(repeating: .string("denied"), count: 4))
        let first = Task { try await runtime.invoke(entry: entry, operation: "fire", params: .object([:])) }
        try await Task.sleep(nanoseconds: 150_000_000)
        let second = Task { try await runtime.invoke(entry: entry, operation: "probe", params: .object([:])) }
        _ = try await first.value; _ = try await second.value
        XCTAssertTrue(FileManager.default.fileExists(atPath: marker.path), "Next command must wait for the old script's termination handler")
        XCTAssertEqual(try String(contentsOf: launches).split(separator: "\n").count, 1, "A completing task cannot start another task while draining")
        var allowed = true
        let pending = Task { try await runtime.invoke(entry: entry, operation: "late", params: .object([:])) {
            if !allowed { throw PluginError(.denied, "revoked") }
        } }
        try await Task.sleep(nanoseconds: 100_000_000); allowed = false
        do { _ = try await pending.value; XCTFail("Revoked command must not save") }
        catch { XCTAssertEqual((error as? PluginError)?.code, .denied) }
        XCTAssertNil(try PluginDataStore(directory: PackManager.dataDirectory(pack)).get("items"))
    }
}
