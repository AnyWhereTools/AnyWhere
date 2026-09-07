import XCTest
@testable import AnyWhereCore

final class PackSettingsTests: XCTestCase {
    private final class Secrets: PackSecretStore {
        var values: [String: String] = [:]
        func read(account: String) throws -> String? { values[account] }
        func write(_ value: String?, account: String) throws { values[account] = value }
    }
    private var directory: URL!
    private var secrets: Secrets!
    private let fields = [
        PackSetting(key: "HOST", title: "Host", type: .text, defaultValue: "localhost", required: true),
        PackSetting(key: "TOKEN", title: "Token", type: .password),
        PackSetting(key: "VERBOSE", title: "Verbose", type: .toggle),
        PackSetting(key: "FORMAT", title: "Format", type: .select, defaultValue: "text", options: ["text", "json"])
    ]
    override func setUpWithError() throws {
        directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        secrets = Secrets()
    }
    override func tearDownWithError() throws { try? FileManager.default.removeItem(at: directory) }
    private func store() -> PackConfigurationStore { PackConfigurationStore(directory: directory, secrets: secrets) }

    func testManifestRoundTripAndLegacyWithoutSettings() throws {
        let manifest = PackManifest(schemaVersion: 2, name: "Settings", actions: [
            PackAction(id: "run", title: "Run", script: "run.zsh", settings: fields)
        ])
        try manifest.validate()
        XCTAssertEqual(try PackManifest.decode(JSONEncoder().encode(manifest)), manifest)
        let legacy = try PackManifest.decode(Data(#"{"name":"Old","actions":[{"id":"run","title":"Run","script":"run.zsh"}]}"#.utf8))
        try legacy.validate()
        XCTAssertEqual(legacy.schemaVersion, 1)
        XCTAssertTrue(legacy.actions[0].settings.isEmpty)
    }

    func testRejectsInvalidDeclarationsAndSecretDefaults() throws {
        for key in ["", "bad-key", "lowercase", "A=B", "A\nB", "9KEY"] {
            XCTAssertThrowsError(try PackSettings.validate([PackSetting(key: key, title: "x", type: .text)]))
        }
        XCTAssertThrowsError(try PackSettings.validate([fields[0], fields[0]]))
        XCTAssertThrowsError(try PackSettings.validate([PackSetting(key: "TOKEN", title: "x", type: .password, defaultValue: "secret")]))
        XCTAssertThrowsError(try PackSettings.validate([PackSetting(key: "MODE", title: "x", type: .select, options: [])]))
        XCTAssertThrowsError(try PackSettings.validate([PackSetting(key: "FLAG", title: "x", type: .toggle, defaultValue: "yes")]))
    }

    func testRequiredAndTypedValuesAndReservedEnvironmentIsolation() throws {
        XCTAssertThrowsError(try PackSettings.environment(fields: fields, values: ["HOST": " "]))
        XCTAssertThrowsError(try PackSettings.environment(fields: fields, values: ["FORMAT": "xml"]))
        XCTAssertThrowsError(try PackSettings.environment(fields: fields, values: ["VERBOSE": "1"]))
        XCTAssertThrowsError(try PackSettings.environment(fields: fields, values: ["TOKEN": "bad\0value"]))
        let env = try PackSettings.environment(fields: fields, values: ["PATH": "injected", "OTHER": "not declared"])
        XCTAssertEqual(Set(env.keys), Set(["ANYWHERE_CONFIG_HOST", "ANYWHERE_CONFIG_TOKEN", "ANYWHERE_CONFIG_VERBOSE", "ANYWHERE_CONFIG_FORMAT"]))
        XCTAssertEqual(env["ANYWHERE_CONFIG_VERBOSE"], "false")
    }

    func testPersistenceIsolationAndSecretsNeverWrittenToJSON() throws {
        let first = UUID(), second = UUID()
        try store().save(actionID: first, fields: fields, values: ["TOKEN": "private-test-value", "HOST": "example", "VERBOSE": "true"])
        let contents = try String(contentsOf: directory.appendingPathComponent(first.uuidString + ".json"))
        XCTAssertFalse(contents.contains("private-test-value"))
        XCTAssertFalse(contents.contains("TOKEN"))
        // Recreating the store simulates an app restart; action IDs isolate every pack/action.
        XCTAssertEqual(try store().load(actionID: first, fields: fields)["TOKEN"], "private-test-value")
        XCTAssertEqual(try store().load(actionID: second, fields: fields)["TOKEN"], "")
        XCTAssertEqual(try store().load(actionID: second, fields: fields)["HOST"], "localhost")
    }

    func testStableFieldsSurvivePackUpdatesAndClearingRestoresDefaults() throws {
        let id = UUID()
        try store().save(actionID: id, fields: fields, values: ["TOKEN": "kept", "HOST": "custom"])
        let updated = fields + [PackSetting(key: "NEW", title: "New", type: .text, defaultValue: "added")]
        XCTAssertEqual(try store().load(actionID: id, fields: updated)["TOKEN"], "kept")
        XCTAssertEqual(try store().load(actionID: id, fields: updated)["NEW"], "added")
        try store().clear(actionID: id, fields: updated)
        XCTAssertTrue(secrets.values.isEmpty)
        XCTAssertEqual(try store().load(actionID: id, fields: fields)["HOST"], "localhost")
    }

    func testInvalidSaveLeavesExistingSecretsUnchanged() throws {
        let id = UUID()
        try store().save(actionID: id, fields: fields, values: ["TOKEN": "old"])
        XCTAssertThrowsError(try store().save(actionID: id, fields: fields, values: ["TOKEN": "new", "HOST": ""]))
        XCTAssertEqual(try store().load(actionID: id, fields: fields)["TOKEN"], "old")
    }

    func testDiskFailureRollsBackSecretWrite() throws {
        let id = UUID()
        let old = "old-secret"
        secrets.values[id.uuidString + ".TOKEN"] = old
        // A file at the settings-directory path makes the eventual JSON write fail.
        try Data().write(to: directory)
        XCTAssertThrowsError(try store().save(actionID: id, fields: fields, values: ["TOKEN": "replacement"]))
        XCTAssertEqual(secrets.values[id.uuidString + ".TOKEN"], old)
    }

    func testValuesArePassedLiterallyAndSecretEchoIsRedacted() throws {
        let token = "test value $(exit 99)\nsecond line"
        let env = try PackSettings.environment(fields: fields, values: ["TOKEN": token])
        let result = ShellRunner.runScript(ScriptSpec(inlineSource: #"printf '%s' "$ANYWHERE_CONFIG_TOKEN""#),
                                           paths: [], variant: nil, scriptBase: directory, cwd: nil, extraEnv: env)
        XCTAssertEqual(result.exitCode, 0)
        XCTAssertEqual(result.stdout, token)
        XCTAssertEqual(PackSettings.redacted(result.stdout, secrets: [token]), "••••")
        XCTAssertEqual(PackSettings.redacted("unchanged", secrets: [""]), "unchanged")
    }
}
