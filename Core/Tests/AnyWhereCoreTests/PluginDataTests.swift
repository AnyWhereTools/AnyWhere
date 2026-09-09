import XCTest
@testable import AnyWhereCore

final class PluginDataTests: XCTestCase {
    func testShortcutOverridesMigratePersistAndRejectConflicts() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        try Data(#"{"enabled":{},"recent":[],"actions":{}}"#.utf8).write(to: root.appendingPathComponent("plugin-preferences.json"))
        let p = PluginPreferencesStore(directory: root)
        let a = PluginSearchEntry(id: UUID(), title: "Xlog", keywords: ["xlog"])
        let b = PluginSearchEntry(id: UUID(), title: "Translate", keywords: ["tr"])
        XCTAssertEqual(try p.searchEntries([a, b]), [a, b])
        try p.rememberActions(packKey: "xlog", ids: [a.id])
        try p.setShortcut(.init(title: " 日志解密 ", keywords: [" XM "]), actionID: a.id, defaults: [a, b])
        let loaded = try PluginPreferencesStore(directory: root).searchEntries([a, b])
        XCTAssertEqual(loaded[0].title, "日志解密")
        XCTAssertEqual(loaded[0].keywords, ["XM"])
        XCTAssertEqual(loaded[1], b)
        XCTAssertThrowsError(try p.setShortcut(.init(title: "Conflict", keywords: [" xm "]), actionID: b.id, defaults: [a, b]))
        XCTAssertThrowsError(try p.setShortcut(.init(title: "Conflict", keywords: ["TR"]), actionID: a.id, defaults: [a, b]))
        XCTAssertThrowsError(try p.setShortcut(.init(title: "", keywords: ["ok"]), actionID: a.id, defaults: [a, b]))
        XCTAssertThrowsError(try p.setShortcut(.init(title: "Invalid", keywords: [" "]), actionID: a.id, defaults: [a, b]))
        XCTAssertEqual(try p.searchEntries([a, b]), loaded)
        let updated = PluginSearchEntry(id: a.id, title: "Updated pack", keywords: ["new"])
        XCTAssertEqual(try p.searchEntries([updated]).first?.keywords, ["XM"])
        try p.removeShortcut(actionID: a.id)
        XCTAssertEqual(try p.searchEntries([a, b]), [a, b])
        try p.setShortcut(.init(title: "日志解密", keywords: ["XM"]), actionID: a.id, defaults: [a, b])
        try p.removePack(packKey: "xlog")
        XCTAssertEqual(try p.searchEntries([a, b]), [a, b])
    }
    func testIsolationAndPersistence() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let a = PluginDataStore(directory: root.appendingPathComponent("a"))
        let b = PluginDataStore(directory: root.appendingPathComponent("b"))
        try a.set("key", value: .string("A"))
        try b.set("key", value: .string("B"))
        XCTAssertEqual(try PluginDataStore(directory: root.appendingPathComponent("a")).get("key"), .string("A"))
        XCTAssertThrowsError(try a.set("huge", value: .string(String(repeating: "x", count: 5 * 1024 * 1024))))
        XCTAssertEqual(try a.get("key"), .string("A"))
        try a.removeAll()
        XCTAssertEqual(try b.get("key"), .string("B"))
    }
    func testPreferencesAndHistory() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let p = PluginPreferencesStore(directory: root)
        let ids = (0..<12).map { _ in UUID() }
        try p.rememberActions(packKey: "a", ids: Set(ids))
        try p.setEnabled(true, actionID: ids[0])
        for id in ids { try p.recordUse(actionID: id, at: Date()) }
        XCTAssertEqual(try p.recent().count, 10)
        XCTAssertTrue(try PluginPreferencesStore(directory: root).isEnabled(actionID: ids[0]))
        XCTAssertFalse(try p.isEnabled(actionID: ids[1]))
        try p.removePack(packKey: "a")
        XCTAssertEqual(try p.recent(), [])
        XCTAssertFalse(try p.isEnabled(actionID: ids[0]))
    }
}
