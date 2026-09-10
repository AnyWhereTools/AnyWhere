import XCTest
import SwiftUI
import AnyWhereCore
@testable import AnyWhere

/// Intercept only the test process's catalog request; never change real installed records.
private final class BazaarCatalogProtocol: URLProtocol {
    static var response = Data()
    override class func canInit(with request: URLRequest) -> Bool { request.url == PackDiscovery.endpoint }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() {
        let response = HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil,
                                       headerFields: ["Content-Type": "application/json"])!
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: Self.response)
        client?.urlProtocolDidFinishLoading(self)
    }
    override func stopLoading() {}
}

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

    func testSharedUpdateStateSurvivesCancelAndClearsAfterInstallOrRemoval() async throws {
        let catalogEntry = try XCTUnwrap(catalog([entry()]).packages.first)
        let current = String(repeating: "b", count: 40)
        let manifest = PackManifest(schemaVersion: 4, name: "Tool", actions: [])
        func installed(_ revision: String, local: Bool = false) -> InstalledPack {
            InstalledPack(key: "owner-tool", manifest: manifest, repoURL: catalogEntry.repository + ".git",
                          repo: catalogEntry.repo, commitSHA: revision, enabledCount: 1, totalCount: 1, isLocal: local)
        }
        let candidate = PackUpdateAvailable(key: "owner-tool", currentSHA: current, remoteSHA: sha, catalogEntry: catalogEntry)
        let updates = [candidate.key: candidate]
        let manager = PackManager(packs: [installed(current)])
        await manager.checkUpdates(catalog: try catalog([entry()]))
        XCTAssertEqual(manager.updates, updates)
        XCTAssertFalse(manager.checkingUpdates)
        XCTAssertNotNil(manager.lastUpdateCheck)
        XCTAssertNil(manager.updateCheckError)
        // Rechecking the same catalogue keeps the same download target for both surfaces.
        await manager.checkUpdates(catalog: try catalog([entry()]))
        XCTAssertEqual(manager.updates, updates)
        // Merely opening/cancelling a review does not change the installed revision.
        XCTAssertEqual(PackManager.pendingUpdates(updates, installed: [installed(current)]), updates)
        // Applying the selected revision clears both views; late checks cannot restore the badge.
        XCTAssertTrue(PackManager.pendingUpdates(updates, installed: [installed(sha)]).isEmpty)
        XCTAssertTrue(PackManager.pendingUpdates(updates, installed: []).isEmpty)
        XCTAssertTrue(PackManager.pendingUpdates(updates, installed: [installed(current, local: true)]).isEmpty)
        // Legacy short commits already at the catalog version must never advertise an update.
        let same = PackUpdateAvailable(key: candidate.key, currentSHA: String(sha.prefix(7)), remoteSHA: sha, catalogEntry: catalogEntry)
        XCTAssertTrue(PackManager.pendingUpdates([same.key: same], installed: [installed(same.currentSHA)]).isEmpty)
        // A user may finish a different update while this request is still in flight.
        XCTAssertTrue(PackManager.pendingUpdates(updates, installed: [installed(String(repeating: "c", count: 40))]).isEmpty)
        var bound = installed(current); bound.catalogID = catalogEntry.id
        let removed = PackManager(packs: [bound])
        await removed.checkUpdates(catalog: try catalog([]))
        XCTAssertNotNil(removed.updateCheckError)
        XCTAssertTrue(removed.updates.isEmpty)
    }

    func testUpdateButtonsRenderInMarketplaceAndCollapsedInstalledRow() async throws {
        let response = try JSONSerialization.data(withJSONObject: ["schemaVersion": 1, "packages": [entry()]])
        BazaarCatalogProtocol.response = response
        URLProtocol.registerClass(BazaarCatalogProtocol.self)
        defer { URLProtocol.unregisterClass(BazaarCatalogProtocol.self) }
        let manifest = PackManifest(schemaVersion: 4, name: "更新界面自测", actions: [])
        let installed = InstalledPack(key: "owner-tool", manifest: manifest, repoURL: "https://github.com/owner/tool.git",
            repo: "owner/tool", commitSHA: String(repeating: "b", count: 40), enabledCount: 1, totalCount: 1)
        let manager = PackManager(packs: [installed])
        let market = NSHostingView(rootView: DiscoverPacksSheet(packManager: manager, onImport: { _ in }, onUpdate: { _, _ in }, onClose: {}))
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 560, height: 520), styleMask: [.titled], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.contentView = market; window.makeKeyAndOrderFront(nil)
        defer { window.contentView = nil; window.close() }
        for _ in 0..<100 {
            if manager.lastUpdateCheck != nil || manager.updateCheckError != nil { break }
            try await Task.sleep(nanoseconds: 50_000_000)
        }
        XCTAssertNil(manager.updateCheckError)
        let update = try XCTUnwrap(manager.updates[installed.key])
        try await Task.sleep(nanoseconds: 100_000_000)
        try capture(market, path: "/tmp/anywhere-update-market.png")
        let row = NSHostingView(rootView: PackRow(pack: installed, update: update, expanded: false,
            onToggleExpand: {}, onSetEnabled: { _, _ in }, onViewScript: { _ in }, onUpdate: {}, onOpenRepo: {}, onUninstall: {}))
        window.setContentSize(NSSize(width: 800, height: 80)); window.contentView = row
        try await Task.sleep(nanoseconds: 100_000_000)
        try capture(row, path: "/tmp/anywhere-update-row.png")
    }

    private func capture(_ view: NSView, path: String) throws {
        view.layoutSubtreeIfNeeded()
        let bitmap = try XCTUnwrap(view.bitmapImageRepForCachingDisplay(in: view.bounds))
        view.cacheDisplay(in: view.bounds, to: bitmap)
        try XCTUnwrap(bitmap.representation(using: .png, properties: [:])).write(to: URL(fileURLWithPath: path))
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
