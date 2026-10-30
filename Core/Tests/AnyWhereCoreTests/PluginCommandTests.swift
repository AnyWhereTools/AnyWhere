import XCTest
@testable import AnyWhereCore

final class PluginCommandTests: XCTestCase {
    private func manifest() throws -> PackManifest {
        try PackManifest.decode(Data(#"""
        {"schemaVersion":5,"name":"Commands","actions":[{"id":"test","title":"Test","contextMenu":false,
          "commands":{"entry":"commands.html","storageKeys":["items"],"operations":{
            "list":{"description":"List","readOnly":true,"inputSchema":{"type":"object","properties":{},"additionalProperties":false}},
            "create":{"description":"Create","readOnly":false,"inputSchema":{"type":"object","properties":{"title":{"type":"string","minLength":1}},"required":["title"],"additionalProperties":false}}}},
          "mcp":{"name":"test","description":"Test tools","commands":["list","create"]}}]}
        """#.utf8))
    }
    func testManifestExportsAndApprovalFollowDeclarations() throws {
        let pack = try manifest(); try pack.validate()
        let action = pack.actions[0]
        try PluginJSONSchema.validate(.object(["operation": .string("list"), "params": .object([:])]), schema: action.mcpInputSchema!)
        XCTAssertThrowsError(try PluginJSONSchema.validate(.object(["operation": .string("remove"), "params": .object([:])]), schema: action.mcpInputSchema!))
        XCTAssertThrowsError(try PluginJSONSchema.validate(.object(["operation": .string("create"), "params": .object(["title": .string("")])]), schema: action.mcpInputSchema!))
        var changed = pack; changed.schemaVersion = 4
        XCTAssertThrowsError(try changed.validate())
        changed = pack; changed.actions[0].mcp?.name = "list"
        XCTAssertThrowsError(try changed.validate())
        changed = pack; changed.actions[0].mcp?.commands.append("missing")
        XCTAssertThrowsError(try changed.validate())
        changed = pack; changed.actions[0].commands?.operations["create"]?.description = "Changed contract"
        XCTAssertNotEqual(action.mcpApproval, changed.actions[0].mcpApproval)
        changed = pack; changed.actions.append(action)
        changed.actions[1].id = "other"
        XCTAssertThrowsError(try changed.validate())
    }
    func testSchemasRejectUnknownKeywordsAndCheckValues() throws {
        func json(_ text: String) throws -> JSONValue { try JSONDecoder().decode(JSONValue.self, from: Data(text.utf8)) }
        XCTAssertThrowsError(try PluginJSONSchema.check(json(#"{"type":"object","$ref":"https://example.com"}"#)))
        let schema = try json(#"{"type":"object","properties":{"priority":{"type":"integer","enum":[0,1,2]},"note":{"type":["string","null"],"maxLength":3}},"required":["priority"],"additionalProperties":false}"#)
        try PluginJSONSchema.check(schema)
        try PluginJSONSchema.validate(json(#"{"priority":1,"note":null}"#), schema: schema)
        for invalid in [#"{"priority":true}"#, #"{"priority":1.5}"#, #"{"priority":3}"#, #"{"priority":1,"note":"long"}"#, #"{"priority":1,"other":0}"#] {
            XCTAssertThrowsError(try PluginJSONSchema.validate(json(invalid), schema: schema))
        }
        XCTAssertEqual(try json(#"{"b":1,"a":false}"#).fingerprint, try json(#"{"a":false,"b":1}"#).fingerprint)
    }
    func testMCPAuthorizationDefaultsOffAndRejectsChangedApproval() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let preferences = PluginPreferencesStore(directory: root), id = UUID()
        XCTAssertFalse(try preferences.isMCPEnabled(actionID: id, approval: "a"))
        try preferences.rememberActions(packKey: "test", ids: [id])
        try preferences.setMCPEnabled(true, actionID: id, approval: "a")
        XCTAssertTrue(try preferences.isMCPEnabled(actionID: id, approval: "a"))
        XCTAssertFalse(try preferences.isMCPEnabled(actionID: id, approval: "b"))
        try preferences.removePack(packKey: "test")
        XCTAssertFalse(try preferences.isMCPEnabled(actionID: id, approval: "a"))
    }
    func testLocalSocketRoundTripAndOwnership() async throws {
        let root = URL(fileURLWithPath: "/tmp/aw-" + UUID().uuidString), path = root.appendingPathComponent("ipc.sock").path
        let server = LocalCommandServer(path: path)
        defer { server.stop(); try? FileManager.default.removeItem(at: root) }
        try server.start { request in request }
        let input: JSONValue = .object(["title": .string("汉🙂"), "done": .bool(false)])
        let result = try await Task.detached { try LocalCommandSocket.request(input, path: path) }.value
        XCTAssertEqual(result, input)
        XCTAssertEqual((try FileManager.default.attributesOfItem(atPath: path)[.posixPermissions] as? NSNumber)?.intValue, 0o600)
        let other = LocalCommandServer(path: path)
        XCTAssertThrowsError(try other.start { $0 })
        let preserved = try await Task.detached { try LocalCommandSocket.request(input, path: path) }.value
        XCTAssertEqual(preserved, input)
    }
}
