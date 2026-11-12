import XCTest
import SwiftUI
import Carbon
import AnyWhereCore
@testable import AnyWhere

@MainActor
final class ShortcutPluginTests: XCTestCase {
    func testSeparateSettingsSharedSearchAndDirectHotKeyLifecycle() async throws {
        let state = AppState.shared, originalConfig = AppState.shared.config, originalManager = AppState.shared.packManager
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let preferences = PluginPreferencesStore(directory: root)
        let key = "shortcut-plugin-test-" + UUID().uuidString
        let directory = AppPaths.configDirectory().appendingPathComponent("Packs").appendingPathComponent(key)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        try Data("<h1>Todo</h1>".utf8).write(to: directory.appendingPathComponent("index.html"))
        let definition = try JSONDecoder().decode(PackAction.self, from: Data(#"{"id":"todo","title":"待办 Todo","ui":{"entry":"index.html"},"launcher":{"keywords":["todo"]},"contextMenu":false}"#.utf8))
        let binding = ActionHotKey(key: 79, modifiers: UInt32(controlKey | optionKey | cmdKey), label: "⌃⌥⌘F18")
        let plugin = MenuAction(id: PackManager.actionUUID(packKey: key, packActionID: definition.id), title: definition.title,
                                icon: .symbol("checklist"), kind: .openPluginUI, matching: MatchRule(), placement: .topLevel,
                                packID: key, isEnabled: false, sortOrder: 1, shortcutHotKey: binding)
        var command = MenuAction(id: UUID(), title: "用户指令", icon: .symbol("terminal"),
                                 kind: .runScript(ScriptSpec(inlineSource: "#!/bin/zsh\nprintf ran > \"$ANYWHERE_ARGUMENT\"")),
                                 matching: MatchRule(), placement: .topLevel, isEnabled: true, sortOrder: 0, shortcutOnly: true)
        let pack = InstalledPack(key: key, manifest: PackManifest(schemaVersion: 4, name: "待办 Todo", actions: [definition]),
                                 repoURL: "", repo: key, commitSHA: "test", enabledCount: 1, totalCount: 1)
        state.config.actions = [command, plugin]
        let manager = PackManager(packs: [pack], preferences: preferences)
        state.packManager = manager
        let controller = PluginLauncherController.shared
        defer {
            controller.stop()
            state.config = originalConfig; state.packManager = originalManager
            try? FileManager.default.removeItem(at: root)
            try? FileManager.default.removeItem(at: directory)
            try? FileManager.default.removeItem(at: PackManager.dataDirectory(key))
        }
        try preferences.setEnabled(true, actionID: plugin.id)
        try preferences.setShortcut(.init(title: command.title, keywords: ["run"]), actionID: command.id,
                                    defaults: manager.searchEntries(includeDisabled: true))
        XCTAssertEqual(try manager.shortcutEntries(includeDisabled: true).map(\.id), [command.id])
        XCTAssertEqual(Set(try manager.searchEntries().map(\.id)), [command.id, plugin.id])
        let catalog = try manager.launcherCatalog()
        XCTAssertEqual(catalog.search("run", recent: []).first?.entry.id, command.id)
        XCTAssertEqual(catalog.search("todo", recent: []).first?.entry.id, plugin.id)
        XCTAssertThrowsError(try preferences.setShortcut(.init(title: command.title, keywords: ["TODO"]), actionID: command.id,
                                                       defaults: manager.searchEntries(includeDisabled: true)))
        XCTAssertEqual(controller.hotKeyActions.map(\.id), [plugin.id], "Plugin enablement is independent of Finder enablement")

        // Exercise actual Carbon registration; a second registration must fail while enabled and succeed after disabling.
        controller.start()
        func canRegisterPluginBinding() -> Bool {
            var reference: EventHotKeyRef?
            let status = RegisterEventHotKey(binding.key, binding.modifiers, EventHotKeyID(signature: 0x41575453, id: 1),
                                             GetApplicationEventTarget(), 0, &reference)
            if let reference { UnregisterEventHotKey(reference) }
            return status == noErr
        }
        XCTAssertFalse(canRegisterPluginBinding())
        controller.runHotKeyAction(plugin.id)
        let tool = try XCTUnwrap(ToolWorkspaceController.shared.windows[plugin.id])
        XCTAssertTrue(tool.window?.isVisible == true)
        XCTAssertFalse(controller.isVisible)
        XCTAssertNil(controller.session)
        let sessionID = tool.session.id
        controller.runHotKeyAction(plugin.id)
        XCTAssertEqual(ToolWorkspaceController.shared.windows[plugin.id]?.session.id, sessionID)
        XCTAssertTrue(ToolWorkspaceController.shared.close(packKey: key))
        try preferences.setEnabled(false, actionID: plugin.id)
        controller.reloadActionHotKeys()
        XCTAssertTrue(canRegisterPluginBinding())
        controller.runHotKeyAction(plugin.id)
        XCTAssertNil(ToolWorkspaceController.shared.windows[plugin.id])

        let output = root.appendingPathComponent("result.txt")
        controller.runUserAction(command.id, query: "run", argument: output.path)
        for _ in 0..<100 {
            if FileManager.default.fileExists(atPath: output.path) { break }
            try await Task.sleep(nanoseconds: 20_000_000)
        }
        XCTAssertEqual(try String(contentsOf: output), "ran")
        XCTAssertFalse(controller.isVisible)
        command.kind = .runScript(ScriptSpec(inlineSource: "#!/bin/zsh\nexit 7"))
        command.title = "指令失败测试 " + UUID().uuidString
        state.config.actions[0] = command
        controller.runUserAction(command.id)
        for _ in 0..<100 {
            if ExecutionLog.shared.records.contains(where: { $0.title == command.title }) { break }
            try await Task.sleep(nanoseconds: 20_000_000)
        }
        XCTAssertEqual(ExecutionLog.shared.records.first(where: { $0.title == command.title })?.success, false)
        XCTAssertFalse(controller.isVisible, "A failed command must not open the launcher")
        XCTAssertNil(controller.session)

        // Render the installed plugin's settings and actions using the actual SwiftUI views.
        let entry = try XCTUnwrap(manager.launcherEntry(actionID: plugin.id))
        let views: [(String, AnyView, NSSize)] = [
            ("plugin-settings", AnyView(PluginSettingsView(manager: manager, entry: entry)), NSSize(width: 620, height: 640)),
            ("plugin-row", AnyView(PackRow(pack: pack, onSetEnabled: { _, _ in }, onViewScript: { _ in },
                                           onUpdate: {}, onOpenRepo: {}, onUninstall: {})), NSSize(width: 900, height: 190))
        ]
        let window = NSWindow(contentRect: .zero, styleMask: [.titled], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        defer { window.contentView = nil; window.close() }
        for (name, view, size) in views {
            let host = NSHostingView(rootView: view.background(Color(nsColor: .windowBackgroundColor)))
            window.setContentSize(size); window.contentView = host; window.makeKeyAndOrderFront(nil)
            try await Task.sleep(nanoseconds: 150_000_000)
            host.layoutSubtreeIfNeeded()
            let bitmap = try XCTUnwrap(host.bitmapImageRepForCachingDisplay(in: host.bounds))
            host.cacheDisplay(in: host.bounds, to: bitmap)
            try XCTUnwrap(bitmap.representation(using: .png, properties: [:]))
                .write(to: URL(fileURLWithPath: "/tmp/anywhere-" + name + ".png"))
        }
    }
}
