import XCTest
@testable import AnyWhereCore

final class PackSnapshotTests: XCTestCase {
    private var source: URL!
    private var copies: [URL] = []

    override func setUpWithError() throws {
        source = FileManager.default.temporaryDirectory.appendingPathComponent("local pack 中文-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: source.appendingPathComponent("actions"), withIntermediateDirectories: true)
        try write("manifest.json", #"{"name":"Local","actions":[{"id":"run","title":"Run","script":"actions/run.zsh"}]}"#)
        try write("actions/run.zsh", "#!/bin/zsh\ntouch should-never-run\n")
    }

    override func tearDownWithError() throws {
        for directory in copies + [source!] { try? FileManager.default.removeItem(at: directory) }
    }

    private func write(_ path: String, _ text: String) throws {
        try text.write(to: source.appendingPathComponent(path), atomically: true, encoding: .utf8)
    }

    func testCopiesOrdinaryFolderAndPreservesExecutableBinaryAndSnapshot() throws {
        try FileManager.default.createDirectory(at: source.appendingPathComponent("bin"), withIntermediateDirectories: true)
        let tool = source.appendingPathComponent("bin/tool")
        try Data([0xCF, 0xFA, 0xED, 0xFE, 0]).write(to: tool)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: tool.path)
        let snapshot = try PackSnapshot.copyLocalDirectory(source)
        copies.append(snapshot.directory)
        XCTAssertEqual(snapshot.manifest.name, "Local")
        XCTAssertFalse(FileManager.default.fileExists(atPath: snapshot.directory.appendingPathComponent("should-never-run").path))
        XCTAssertFalse(FileManager.default.fileExists(atPath: snapshot.directory.appendingPathComponent(".git").path))
        let extras = PackInspector.undeclaredFiles(inDirectory: snapshot.directory, declared: ["actions/run.zsh"])
        XCTAssertEqual(extras.map(\.relativePath), ["bin/tool"])
        XCTAssertTrue(extras[0].isExecutable)
        XCTAssertTrue(extras[0].isBinary)
        try write("actions/run.zsh", "changed after review")
        XCTAssertEqual(try PackSnapshot.read(in: snapshot.directory).scripts, snapshot.scripts)
        // Cancelling review removes only the temporary snapshot.
        try FileManager.default.removeItem(at: snapshot.directory)
        XCTAssertTrue(FileManager.default.fileExists(atPath: source.appendingPathComponent("bin/tool").path))
    }

    func testRejectsMissingAndMalformedManifest() throws {
        try write("manifest.json", "not JSON")
        XCTAssertThrowsError(try PackSnapshot.copyLocalDirectory(source))
        try FileManager.default.removeItem(at: source.appendingPathComponent("manifest.json"))
        XCTAssertThrowsError(try PackSnapshot.copyLocalDirectory(source))
    }

    func testRejectsMissingScriptAndTraversal() throws {
        try FileManager.default.removeItem(at: source.appendingPathComponent("actions/run.zsh"))
        XCTAssertThrowsError(try PackSnapshot.copyLocalDirectory(source))
        try write("manifest.json", #"{"name":"Bad","actions":[{"id":"run","title":"Run","script":"../outside.sh"}]}"#)
        XCTAssertThrowsError(try PackSnapshot.copyLocalDirectory(source))
    }

    func testRejectsEscapingManifestAndHelperSymlinks() throws {
        try FileManager.default.createSymbolicLink(at: source.appendingPathComponent("helper"), withDestinationURL: URL(fileURLWithPath: "/etc/hosts"))
        XCTAssertThrowsError(try PackSnapshot.copyLocalDirectory(source))
        try FileManager.default.removeItem(at: source.appendingPathComponent("manifest.json"))
        try FileManager.default.createSymbolicLink(at: source.appendingPathComponent("manifest.json"), withDestinationURL: URL(fileURLWithPath: "/etc/hosts"))
        XCTAssertThrowsError(try PackSnapshot.read(in: source))
    }

    func testAllowsRelativeSymlinkInsidePack() throws {
        try FileManager.default.createSymbolicLink(atPath: source.appendingPathComponent("helper").path, withDestinationPath: "actions/run.zsh")
        let snapshot = try PackSnapshot.copyLocalDirectory(source)
        copies.append(snapshot.directory)
        XCTAssertEqual(try String(contentsOf: snapshot.directory.appendingPathComponent("helper")), snapshot.scripts["run"])
    }
}
