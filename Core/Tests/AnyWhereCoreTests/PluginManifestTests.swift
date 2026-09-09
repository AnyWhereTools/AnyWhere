import XCTest
@testable import AnyWhereCore

final class PluginManifestTests: XCTestCase {
    private func manifest(_ version: Int = 4, script: String = "", extra: String = "") throws -> PackManifest {
        let json = """
        {"schemaVersion":\(version),"uiApiVersion":1,"name":"Tools","actions":[{"id":"text","title":"Text","contextMenu":false,"launcher":{"keywords":["text"]},"ui":{"entry":"ui/index.html"}\(script)\(extra)}]}
        """
        return try PackManifest.decode(Data(json.utf8))
    }
    func testPureUI() throws {
        let pack = try manifest()
        try pack.validate()
        XCTAssertNil(pack.actions[0].script)
        XCTAssertEqual(pack.actions[0].ui?.entry, "ui/index.html")
    }
    func testMarketTypesAreDerivedAndComposable() throws {
        var pack = try manifest()
        XCTAssertEqual(pack.types, [.tool])
        pack.actions[0].contextMenu = true
        XCTAssertEqual(pack.types, [.finder, .tool])
        let data = try JSONEncoder().encode(pack)
        let legacy = try PackManifest.decode(data)
        XCTAssertEqual(legacy.types, [.finder, .tool])
    }
    func testUIRequiresNewSchema() throws {
        XCTAssertThrowsError(try manifest(3).validate())
    }
    func testTaskCapabilityRequiresScript() throws {
        XCTAssertThrowsError(try manifest(extra: #","capabilities":["task.run"]"#).validate())
        XCTAssertNoThrow(try manifest(script: #","script":"actions/run.zsh""#, extra: #","capabilities":["task.run"]"#).validate())
    }
    func testUIAPIAndEntrypointValidation() throws {
        var pack = try manifest()
        pack.uiApiVersion = 2
        XCTAssertThrowsError(try pack.validate())
        pack.uiApiVersion = 1
        pack.actions[0].ui?.entry = "../secret"
        XCTAssertThrowsError(try pack.validate())
    }
    func testResourcesStayInsidePackAndHTMLIsRequired() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: false)
        defer { try? FileManager.default.removeItem(at: root) }
        let ui = root.appendingPathComponent("ui")
        try FileManager.default.createDirectory(at: ui, withIntermediateDirectories: false)
        try "<html></html>".write(to: ui.appendingPathComponent("index.html"), atomically: true, encoding: .utf8)
        try JSONEncoder().encode(manifest()).write(to: root.appendingPathComponent("manifest.json"))
        XCTAssertNoThrow(try PackSnapshot.read(in: root))
        XCTAssertNoThrow(try PluginResourceResolver.resolve(root: root, relativePath: "ui/./index.html"))
        XCTAssertThrowsError(try PluginResourceResolver.resolve(root: root, relativePath: "../outside"))
        try FileManager.default.createSymbolicLink(at: root.appendingPathComponent("escape"), withDestinationURL: URL(fileURLWithPath: "/etc/hosts"))
        XCTAssertThrowsError(try PluginResourceResolver.resolve(root: root, relativePath: "escape"))
        try FileManager.default.removeItem(at: ui.appendingPathComponent("index.html"))
        XCTAssertThrowsError(try PackSnapshot.read(in: root))
    }
}
