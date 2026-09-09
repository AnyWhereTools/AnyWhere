import XCTest
@testable import AnyWhereCore

final class WorkflowTests: XCTestCase {
    func testRunsSamePackActionsInOrderAndPassesValue() throws {
        let actions = [PackAction(id: "a", title: "A"), PackAction(id: "b", title: "B")]
        let manifest = PackManifest(schemaVersion: 4, name: "P", actions: actions)
        let workflow = PackWorkflow(id: "w", title: "W", steps: [.init(action: "a"), .init(action: "b")])
        var seen: [String] = []
        let result = try WorkflowExecutor.run(workflow, in: manifest, step: { action, input in
            seen.append(action.id)
            return .string((input.string ?? "") + action.id)
        }, input: .string("start-"))
        XCTAssertEqual(seen, ["a", "b"])
        XCTAssertEqual(result.string, "start-ab")
    }

    func testStopsOnFailure() {
        let actions = [PackAction(id: "a", title: "A"), PackAction(id: "b", title: "B")]
        let manifest = PackManifest(schemaVersion: 4, name: "P", actions: actions)
        let workflow = PackWorkflow(id: "w", title: "W", steps: [.init(action: "a"), .init(action: "b")])
        var seen: [String] = []
        XCTAssertThrowsError(try WorkflowExecutor.run(workflow, in: manifest, step: { action, _ in
            seen.append(action.id)
            if action.id == "a" { throw PluginError(.failed, "stop") }
            return .null
        }))
        XCTAssertEqual(seen, ["a"])
    }
}
