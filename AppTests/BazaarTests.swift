import XCTest
import AnyWhereCore
@testable import AnyWhere

@MainActor
final class BazaarTests: XCTestCase {
    private let sha = String(repeating: "a", count: 40)
    private func entry(_ changes: [String: Any] = [:]) -> [String: Any] {
        var value: [String: Any] = ["id": "owner.tool", "repository": "https://github.com/owner/tool",
            "revision": sha, "name": "Tool", "icon": "shippingbox", "manifestSchemaVersion": 4, "types": ["tool"]]
        value.merge(changes) { _, new in new }; return value
    }
    private func catalog(_ packages: [[String: Any]], version: Int = 1) throws -> PackCatalog {
        try PackCatalog.decode(JSONSerialization.data(withJSONObject: ["schemaVersion": version, "packages": packages]))
    }

    func testCatalogTrustBoundaryAndSourceBinding() throws {
        let valid = try catalog([entry()])
        XCTAssertEqual(valid.packages.first?.revision, sha)
        XCTAssertEqual(try valid.entry(repository: "https://github.com/Owner/Tool.git", catalogID: nil)?.id, "owner.tool")
        XCTAssertNil(try valid.entry(repository: "https://other.example/owner/tool.git", catalogID: nil))
        XCTAssertNil(try valid.entry(repository: "https://github.com/owner/unlisted.git", catalogID: nil))
        XCTAssertThrowsError(try valid.entry(repository: "https://github.com/owner/other.git", catalogID: "owner.tool"))
        XCTAssertThrowsError(try catalog([]).entry(repository: "https://github.com/owner/tool.git", catalogID: "owner.tool"))
        XCTAssertThrowsError(try catalog([entry()], version: 2))
        XCTAssertThrowsError(try catalog([entry(), entry(["id": "owner.second"])]))
        XCTAssertThrowsError(try catalog([entry(), entry(["repository": "https://github.com/owner/second"])]))
        for invalid in ["--upload-pack=evil", "https://github.com/owner/tool.git", "https://github.com/owner/../tool",
                        "https://user:secret@github.com/owner/tool", "https://github.com/owner/tool?ref=main",
                        "https://github.com/owner/tool#main", "https://other.example/owner/tool", "file:///tmp/tool"] {
            XCTAssertThrowsError(try catalog([entry(["repository": invalid])]), invalid)
        }
        for invalid in ["HEAD", "--help", String(sha.prefix(7)), String(repeating: "g", count: 40)] {
            XCTAssertThrowsError(try catalog([entry(["revision": invalid])]))
        }
        XCTAssertThrowsError(try catalog([entry(["types": ["extension"]])]))
        XCTAssertThrowsError(try catalog([entry(["manifestSchemaVersion": 5])]))
        XCTAssertThrowsError(try catalog([entry(["name": " "])]))
        XCTAssertThrowsError(try PackCatalog.decode(Data(repeating: 32, count: PackCatalog.byteLimit + 1)))
    }

    func testLegacyRecordAndManifestCompatibility() throws {
        let action = PackAction(id: "tool", title: "Tool", icon: "bolt", script: "run.sh",
                                launcher: PackLauncher(keywords: ["tool"]), contextMenu: false)
        let manifest = PackManifest(schemaVersion: 4, name: "Tool", actions: [action])
        let pack = try XCTUnwrap(catalog([entry()]).packages.first)
        try pack.validate(manifest: manifest)
        var changed = manifest; changed.name = "Different tool"
        XCTAssertThrowsError(try pack.validate(manifest: changed))
        changed = manifest; changed.actions[0].contextMenu = true
        XCTAssertThrowsError(try pack.validate(manifest: changed))
        let old = PackManager.InstalledRecord(key: "owner-tool", repoURL: pack.repository + ".git",
            repo: pack.repo, commitSHA: String(sha.prefix(7)), manifest: manifest)
        let data = try JSONEncoder().encode(old)
        let decoded = try JSONDecoder().decode(PackManager.InstalledRecord.self, from: data)
        XCTAssertNil(decoded.catalogID); XCTAssertEqual(decoded.key, old.key)
        XCTAssertTrue(PackManager.matchesRevision(decoded.commitSHA, sha))
        XCTAssertFalse(PackManager.matchesRevision("", sha))
        XCTAssertFalse(PackManager.matchesRevision("unknown", sha))
        var bound = decoded; bound.catalogID = pack.id
        XCTAssertEqual(try JSONDecoder().decode(PackManager.InstalledRecord.self, from: JSONEncoder().encode(bound)).catalogID, pack.id)
    }

    func testCheckoutPinsSelectedCommitInsteadOfHeadAndCleansFailures() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("bazaar-test-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let source = root.appendingPathComponent("source")
        func git(_ args: [String], cwd: URL? = nil) throws -> String {
            let result = ShellRunner.run("/usr/bin/git", args, cwd: cwd, timeout: 10)
            guard result.exitCode == 0 else { throw PackCatalog.Failure(result.stderr) }
            return result.stdout.trimmingCharacters(in: .whitespacesAndNewlines)
        }
        _ = try git(["init", source.path])
        let file = source.appendingPathComponent("version.txt")
        try Data("reviewed version".utf8).write(to: file)
        _ = try git(["add", "."], cwd: source)
        _ = try git(["-c", "user.name=Test", "-c", "user.email=test@example.invalid", "-c", "commit.gpgsign=false", "commit", "-m", "feat: first"], cwd: source)
        let selected = try git(["rev-parse", "HEAD"], cwd: source)
        try Data("unreviewed head".utf8).write(to: file)
        _ = try git(["add", "."], cwd: source)
        _ = try git(["-c", "user.name=Test", "-c", "user.email=test@example.invalid", "-c", "commit.gpgsign=false", "commit", "-m", "feat: second"], cwd: source)
        let latest = try git(["rev-parse", "HEAD"], cwd: source)
        let pinned = root.appendingPathComponent("pinned")
        let actual = try await PackManager.checkout(repoURL: source.path, revision: selected, into: pinned)
        XCTAssertEqual(actual, selected); XCTAssertNotEqual(actual, latest)
        XCTAssertEqual(try String(contentsOf: pinned.appendingPathComponent("version.txt")), "reviewed version")
        let direct = root.appendingPathComponent("direct")
        let directSHA = try await PackManager.checkout(repoURL: source.path, revision: nil, into: direct)
        XCTAssertEqual(directSHA, latest)
        let failed = root.appendingPathComponent("failed")
        do {
            _ = try await PackManager.checkout(repoURL: source.path, revision: sha, into: failed)
            XCTFail("A missing catalog commit must not fall back to HEAD")
        } catch { XCTAssertFalse(FileManager.default.fileExists(atPath: failed.path)) }
        XCTAssertEqual(try git(["rev-parse", "HEAD"], cwd: source), latest)
    }
}
