import XCTest
@testable import AnyWhereCore

final class LocalEncryptedSecretStoreTests: XCTestCase {
    private var directory: URL!
    private var keyFile: URL { directory.appendingPathComponent("key") }
    private var vaultFile: URL { directory.appendingPathComponent("secrets.enc") }
    private func store() -> LocalEncryptedSecretStore { LocalEncryptedSecretStore(directory: directory) }

    override func setUpWithError() throws {
        directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: directory)
    }

    func testEmptyReadDoesNotCreateFiles() throws {
        XCTAssertNil(try store().read(account: "action.TOKEN"))
        XCTAssertFalse(FileManager.default.fileExists(atPath: directory.path))
    }

    func testEncryptedPersistenceAcrossInstancesAndAccountIsolation() throws {
        let value = "test-private-value-中文-$(exit 99)"
        try store().write(value, account: "first.TOKEN")
        try store().write("another", account: "second.TOKEN")
        XCTAssertEqual(try store().read(account: "first.TOKEN"), value)
        XCTAssertEqual(try store().read(account: "second.TOKEN"), "another")
        XCTAssertNil(try store().read(account: "missing.TOKEN"))
        let encrypted = try Data(contentsOf: vaultFile)
        XCTAssertNil(encrypted.range(of: Data(value.utf8)))
        XCTAssertNil(encrypted.range(of: Data("first.TOKEN".utf8)))
        XCTAssertEqual(try Data(contentsOf: keyFile).count, 32)
    }

    func testPrivatePermissionsAndFreshNonce() throws {
        try store().write("same-value", account: "action.TOKEN")
        let first = try Data(contentsOf: vaultFile)
        let key = try Data(contentsOf: keyFile)
        try store().write("same-value", account: "action.TOKEN")
        XCTAssertNotEqual(try Data(contentsOf: vaultFile), first)
        XCTAssertEqual(try Data(contentsOf: keyFile), key)
        for (url, expected) in [(directory!, 0o700), (keyFile, 0o600), (vaultFile, 0o600)] {
            let attributes = try FileManager.default.attributesOfItem(atPath: url.path)
            XCTAssertEqual((attributes[.posixPermissions] as? NSNumber)?.intValue, expected)
        }
    }

    func testClearRemovesOnlyTheSelectedSecret() throws {
        try store().write("first", account: "first.TOKEN")
        try store().write("second", account: "second.TOKEN")
        try store().write(nil, account: "first.TOKEN")
        XCTAssertNil(try store().read(account: "first.TOKEN"))
        XCTAssertEqual(try store().read(account: "second.TOKEN"), "second")
    }

    func testTamperedCiphertextIsRejectedWithoutOverwritingIt() throws {
        try store().write("original", account: "action.TOKEN")
        var corrupted = try Data(contentsOf: vaultFile)
        corrupted[corrupted.count - 1] ^= 0xff
        try corrupted.write(to: vaultFile)
        XCTAssertThrowsError(try store().read(account: "action.TOKEN"))
        XCTAssertThrowsError(try store().write("replacement", account: "action.TOKEN"))
        XCTAssertEqual(try Data(contentsOf: vaultFile), corrupted)
    }

    func testMissingOrInvalidKeyNeverResetsExistingVault() throws {
        try store().write("original", account: "action.TOKEN")
        let encrypted = try Data(contentsOf: vaultFile)
        try FileManager.default.removeItem(at: keyFile)
        XCTAssertThrowsError(try store().read(account: "action.TOKEN"))
        XCTAssertThrowsError(try store().write("replacement", account: "action.TOKEN"))
        XCTAssertFalse(FileManager.default.fileExists(atPath: keyFile.path))
        try Data([1, 2, 3]).write(to: keyFile)
        XCTAssertThrowsError(try store().read(account: "action.TOKEN"))
        XCTAssertThrowsError(try store().write(nil, account: "action.TOKEN"))
        XCTAssertEqual(try Data(contentsOf: vaultFile), encrypted)
    }

    func testWrongKeyIsRejectedAndBackupWithKeyCanBeRestored() throws {
        try store().write("original", account: "action.TOKEN")
        let key = try Data(contentsOf: keyFile)
        try Data(repeating: 0, count: 32).write(to: keyFile)
        XCTAssertThrowsError(try store().read(account: "action.TOKEN"))
        try key.write(to: keyFile)
        let backup = directory.appendingPathComponent("restored")
        try FileManager.default.createDirectory(at: backup, withIntermediateDirectories: false)
        try FileManager.default.copyItem(at: keyFile, to: backup.appendingPathComponent("key"))
        try FileManager.default.copyItem(at: vaultFile, to: backup.appendingPathComponent("secrets.enc"))
        XCTAssertEqual(try LocalEncryptedSecretStore(directory: backup).read(account: "action.TOKEN"), "original")
    }

    func testExistingSymlinkIsRejected() throws {
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: false)
        let target = directory.appendingPathComponent("outside")
        try Data(repeating: 42, count: 32).write(to: target)
        try FileManager.default.createSymbolicLink(at: keyFile, withDestinationURL: target)
        XCTAssertThrowsError(try store().write("secret", account: "action.TOKEN"))
        XCTAssertEqual(try Data(contentsOf: target), Data(repeating: 42, count: 32))
    }

    func testConfigurationSaveLoadClearUsesEncryptedSecrets() throws {
        let fields = [PackSetting(key: "HOST", title: "Host", type: .text),
                      PackSetting(key: "TOKEN", title: "Token", type: .password)]
        let id = UUID()
        let plainDirectory = directory.appendingPathComponent("config")
        func configuration() -> PackConfigurationStore {
            PackConfigurationStore(directory: plainDirectory, secrets: store())
        }
        try configuration().save(actionID: id, fields: fields, values: ["HOST": "localhost", "TOKEN": "private-test-key"])
        let plain = try String(contentsOf: plainDirectory.appendingPathComponent(id.uuidString + ".json"))
        XCTAssertFalse(plain.contains("private-test-key"))
        XCTAssertEqual(try configuration().load(actionID: id, fields: fields)["TOKEN"], "private-test-key")
        try configuration().clear(actionID: id, fields: fields)
        XCTAssertEqual(try configuration().load(actionID: id, fields: fields)["TOKEN"], "")
    }

    func testConcurrentWritersPreserveOtherAccounts() throws {
        let failuresLock = NSLock()
        var failures: [Error] = []
        DispatchQueue.concurrentPerform(iterations: 12) { index in
            do { try store().write("value-\(index)", account: "action-\(index).TOKEN") }
            catch { failuresLock.lock(); failures.append(error); failuresLock.unlock() }
        }
        XCTAssertTrue(failures.isEmpty)
        for index in 0..<12 {
            XCTAssertEqual(try store().read(account: "action-\(index).TOKEN"), "value-\(index)")
        }
    }

    func testPlainConfigWriteFailureRollsBackEncryptedValue() throws {
        let id = UUID()
        let account = id.uuidString + ".TOKEN"
        try store().write("original", account: account)
        let invalidDirectory = directory.appendingPathComponent("not-a-directory")
        try Data().write(to: invalidDirectory)
        let configuration = PackConfigurationStore(directory: invalidDirectory, secrets: store())
        XCTAssertThrowsError(try configuration.save(actionID: id,
            fields: [PackSetting(key: "TOKEN", title: "Token", type: .password)], values: ["TOKEN": "replacement"]))
        XCTAssertEqual(try store().read(account: account), "original")
    }
}
