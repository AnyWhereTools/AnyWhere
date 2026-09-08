import XCTest
@testable import AnyWhereCore

final class PluginDataTests: XCTestCase {
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
