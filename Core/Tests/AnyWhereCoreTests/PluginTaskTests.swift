import XCTest
@testable import AnyWhereCore

final class PluginTaskTests: XCTestCase {
    func testFinderDirectoryReachesScriptAndRequestWithoutReplacingArguments() throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: false)
        defer { try? FileManager.default.removeItem(at: dir) }
        let script = dir.appendingPathComponent("context.zsh")
        try #"printf '%s\0' "$ANYWHERE_FINDER_PATH" "$1" "$ANYWHERE_PATHS"; cat "$ANYWHERE_REQUEST_FILE""#
            .write(to: script, atomically: true, encoding: .utf8)
        for finderPath in [nil, "/tmp/Finder space ' $(touch NEVER)\nfolder"] as [String?] {
            let original = PluginInvocation(actionID: UUID(), source: .launcher, argument: "typed input", paths: ["selected file"])
            var json = try XCTUnwrap(JSONSerialization.jsonObject(with: JSONEncoder().encode(original)) as? [String: Any])
            json["finderPath"] = finderPath
            let context = try JSONDecoder().decode(PluginInvocation.self, from: JSONSerialization.data(withJSONObject: json))
            let result = PluginTask().run(script: script, directory: dir, invocation: context, input: .null,
                                          environment: ["ANYWHERE_FINDER_PATH": "/wrong"], secrets: [], timeout: 5) { _, _ in }
            XCTAssertNil(result.error)
            let output = result.stdout.components(separatedBy: "\0")
            XCTAssertEqual(output.count, 4)
            guard output.count == 4 else { continue }
            let expected = finderPath ?? FileManager.default.homeDirectoryForCurrentUser.path
            XCTAssertEqual(output[0], expected)
            XCTAssertEqual(output[1], "selected file")
            XCTAssertEqual(output[2], "selected file")
            let request = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(output[3].utf8)) as? [String: Any])
            let invocation = try XCTUnwrap(request["invocation"] as? [String: Any])
            XCTAssertEqual(invocation["finderPath"] as? String, expected)
            XCTAssertEqual(invocation["argument"] as? String, "typed input")
            XCTAssertFalse(FileManager.default.fileExists(atPath: dir.appendingPathComponent("NEVER").path))
        }
    }

    func testEveryByteBoundaryRedactsSecretsAndKeepsUTF8() {
        let source = Data("你好 secret-密钥 世界 secret-密钥!".utf8)
        for boundary in 0...source.count {
            var filter = PluginOutputFilter(secrets: ["secret-密钥"])
            var output = filter.append(source.prefix(boundary))
            output += filter.append(source.dropFirst(boundary))
            output += filter.append(Data(), final: true)
            XCTAssertEqual(output, "你好 •••• 世界 ••••!", "boundary \(boundary)")
        }
    }

    func testManagedTaskInputOutputTimeoutAndCancellation() throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: false)
        defer { try? FileManager.default.removeItem(at: dir) }
        let script = dir.appendingPathComponent("task.sh")
        try "cat \"$ANYWHERE_REQUEST_FILE\"; printf 'sec'; sleep .05; printf 'ret你好';".write(to: script, atomically: true, encoding: .utf8)
        let context = PluginInvocation(actionID: UUID(), source: .launcher, argument: "$(touch NEVER)")
        var streamed = ""
        let result = PluginTask().run(script: script, directory: dir, invocation: context, input: .string("hello"),
                                      environment: [:], secrets: ["secret"], timeout: 5) { _, text in streamed += text }
        XCTAssertNil(result.error); XCTAssertTrue(result.stdout.contains("$(touch NEVER)"))
        XCTAssertTrue(result.stdout.hasSuffix("••••你好")); XCTAssertEqual(streamed, result.stdout)
        XCTAssertFalse(FileManager.default.fileExists(atPath: dir.appendingPathComponent("NEVER").path))
        try "sleep 30".write(to: script, atomically: true, encoding: .utf8)
        let timed = PluginTask().run(script: script, directory: dir, invocation: context, input: .null,
                                     environment: [:], secrets: [], timeout: 0.1) { _, _ in }
        XCTAssertEqual(timed.error?.code, .timedOut)
        let task = PluginTask()
        DispatchQueue.global().asyncAfter(deadline: .now() + 0.1) { task.cancel() }
        let cancelled = task.run(script: script, directory: dir, invocation: context, input: .null,
                                 environment: [:], secrets: [], timeout: 10) { _, _ in }
        XCTAssertEqual(cancelled.error?.code, .cancelled)
        try "/usr/bin/head -c 4194305 /dev/zero".write(to: script, atomically: true, encoding: .utf8)
        let limited = PluginTask().run(script: script, directory: dir, invocation: context, input: .null,
                                      environment: [:], secrets: [], timeout: 10) { _, _ in }
        XCTAssertEqual(limited.error?.code, .outputLimit)
    }
}
