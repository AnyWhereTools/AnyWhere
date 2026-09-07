import XCTest
@testable import AnyWhereCore

final class FilenameMatchingTests: XCTestCase {
    private var directory: URL!

    override func setUpWithError() throws {
        directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try FileManager.default.removeItem(at: directory)
    }

    private func file(_ name: String) throws -> URL {
        let url = directory.appendingPathComponent(name)
        try Data().write(to: url)
        return url
    }

    func testLiteralSuffixIgnoresCaseAndAcceptsOptionalDot() throws {
        let rule = MatchRule(targets: .files, extensions: [" .XlOg "])
        for name in ["a.xlog", "a.XLOG", "中文 日志.Xlog"] {
            XCTAssertTrue(RuleMatcher.matches(rule: rule, context: .items([try file(name)])), name)
        }
        for name in ["a.log", "axlog", "a.xlog.bak", "xlog", ".xlog"] {
            XCTAssertFalse(RuleMatcher.matches(rule: rule, context: .items([try file(name)])), name)
        }
    }

    func testCompoundSuffixAndMixedSelection() throws {
        let rule = MatchRule(targets: .files, extensions: ["tar.gz", "xlog"])
        let archive = try file("backup.TAR.GZ")
        let log = try file("a.XLOG")
        XCTAssertTrue(RuleMatcher.matches(rule: rule, context: .items([archive, log])))
        XCTAssertFalse(RuleMatcher.matches(rule: rule, context: .items([archive, try file("a.gz")])))
        XCTAssertFalse(RuleMatcher.matches(rule: rule, context: .items([])))
    }

    func testSuffixDoesNotTreatFoldersAsFiles() throws {
        let folder = directory.appendingPathComponent("folder.xlog")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: false)
        XCTAssertFalse(RuleMatcher.matches(rule: MatchRule(extensions: ["xlog"]), context: .items([folder])))
        XCTAssertTrue(RuleMatcher.matches(rule: MatchRule(utis: ["public.folder"], extensions: ["xlog"]), context: .items([folder])))
    }

    func testUTIAndSuffixAreAlternatives() throws {
        let rule = MatchRule(targets: .files, utis: ["public.image"], extensions: ["xlog"])
        XCTAssertTrue(RuleMatcher.matches(rule: rule, context: .items([try file("a.png"), try file("a.xlog")])))
        XCTAssertFalse(RuleMatcher.matches(rule: rule, context: .items([try file("a.txt")])))
    }

    func testPatternRestrictsTypeMatchesAndUsesWholeBasename() throws {
        let rule = MatchRule(targets: .files, utis: ["public.image"], extensions: ["xlog"],
                             filenamePattern: #"device-.*\.(xlog|png)"#)
        for name in ["device-中文.XLOG", "DEVICE-1.PNG"] {
            XCTAssertTrue(RuleMatcher.matches(rule: rule, context: .items([try file(name)])), name)
        }
        for name in ["other.xlog", "prefix-device-a.xlog", "device-a.txt", "device-a.png.bak"] {
            XCTAssertFalse(RuleMatcher.matches(rule: rule, context: .items([try file(name)])), name)
        }
        let onlyPattern = MatchRule(filenamePattern: #"a\.xlog|b\.log"#)
        XCTAssertTrue(RuleMatcher.matches(rule: onlyPattern, context: .items([try file("b.log")])))
        XCTAssertFalse(RuleMatcher.matches(rule: onlyPattern, context: .items([try file("prefix-b.log")])))
        XCTAssertFalse(RuleMatcher.matches(rule: MatchRule(filenamePattern: #".*[/\\].*"#), context: .items([try file("device.log")])))
    }

    func testInvalidFiltersFailClosed() throws {
        let url = try file("a.xlog")
        for pattern in ["[", "", "("] {
            XCTAssertFalse(RuleMatcher.matches(rule: MatchRule(filenamePattern: pattern), context: .items([url])))
        }
        for suffix in ["", ".", "*.xlog", "x(log)", "a/b", "x..log"] {
            XCTAssertFalse(RuleMatcher.matches(rule: MatchRule(extensions: [suffix]), context: .items([url])))
        }
    }

    func testUserInputIsNormalizedAndReplacesLegacyFiltersOnlyExplicitly() {
        let parsed = MatchRule.parseExtensions(" .XLOG, xlog；LOG，tar.GZ\n png ")
        XCTAssertEqual(parsed, ["xlog", "log", "tar.gz", "png"])
        XCTAssertFalse(MatchRule.parseExtensions(".").allSatisfy(MatchRule.isValidExtension))
        var rule = MatchRule(utis: ["public.image"], filenamePattern: ".*", maxSelectionCount: 2)
        rule.targets = .files
        XCTAssertEqual(rule.utis, ["public.image"])
        rule.setUserExtensions(parsed)
        XCTAssertEqual(rule.extensions, parsed)
        XCTAssertTrue(rule.utis.isEmpty)
        XCTAssertNil(rule.filenamePattern)
        XCTAssertEqual(rule.maxSelectionCount, 2)
    }

    func testLegacyAndNewRuleRoundTrip() throws {
        let old = try JSONDecoder().decode(MatchRule.self, from: Data(#"{"utis":["public.image"]}"#.utf8))
        XCTAssertEqual(old.extensions, [])
        XCTAssertNil(old.filenamePattern)
        XCTAssertEqual(old.utis, ["public.image"])
        let rule = MatchRule(targets: .files, extensions: ["xlog"], filenamePattern: #"日志.*\.xlog"#)
        let restored = try JSONDecoder().decode(MatchRule.self, from: JSONEncoder().encode(rule))
        XCTAssertEqual(restored, rule)
    }

    func testPackImportTranslationAndSchemaValidation() throws {
        let json = #"{"schemaVersion":3,"name":"Xlog","actions":[{"id":"decode","title":"Decode","script":"decode.zsh","targets":"files","extensions":["xlog"],"filenamePattern":"device-.*\\.xlog"}]}"#
        let pack = try PackManifest.decode(Data(json.utf8))
        try pack.validate()
        let action = try XCTUnwrap(pack.actions.first)
        XCTAssertEqual(action.matching.extensions, ["xlog"])
        XCTAssertTrue(RuleMatcher.matches(rule: action.matching, context: .items([try file("device-1.XLOG")])))
        XCTAssertEqual(try PackManifest.decode(JSONEncoder().encode(pack)), pack)
        var invalid = pack
        invalid.schemaVersion = 2
        XCTAssertThrowsError(try invalid.validate())
        invalid = pack
        invalid.actions[0].filenamePattern = "["
        XCTAssertThrowsError(try invalid.validate())
        invalid = pack
        invalid.actions[0].extensions = ["*.xlog"]
        XCTAssertThrowsError(try invalid.validate())
        invalid = pack
        invalid.actions[0].targets = .container
        XCTAssertThrowsError(try invalid.validate())
    }

    func testPreviewIncludesSuffixAlternatives() {
        let xlog = MatchRule(extensions: [".XLOG"])
        XCTAssertTrue(MenuPreviewVisibility.isVisible(xlog, in: .file))
        XCTAssertFalse(MenuPreviewVisibility.isVisible(xlog, in: .image))
        XCTAssertFalse(MenuPreviewVisibility.isVisible(xlog, in: .folder))
        let image = MatchRule(extensions: ["JPG"])
        XCTAssertTrue(MenuPreviewVisibility.isVisible(image, in: .image))
        XCTAssertFalse(MenuPreviewVisibility.isVisible(image, in: .file))
        let mixed = MatchRule(utis: ["public.image"], extensions: ["xlog"])
        XCTAssertTrue(MenuPreviewVisibility.isVisible(mixed, in: .image))
        XCTAssertTrue(MenuPreviewVisibility.isVisible(mixed, in: .file))
    }

    func testFinderSnapshotPreservesFiltersAndSelectionLimits() throws {
        let action = MenuAction(id: UUID(), title: "Xlog", icon: .symbol("doc"),
                                kind: .runScript(ScriptSpec(inlineSource: "true")),
                                matching: MatchRule(targets: .files, extensions: ["xlog"],
                                                    filenamePattern: #"device-.*\.xlog"#, maxSelectionCount: 2),
                                placement: .topLevel, isEnabled: true, sortOrder: 0)
        let snapshot = ExtensionSnapshot(config: MenuConfig(schemaVersion: 1, actions: [action]), variantListings: [:])
        let restored = try ExtensionSnapshot.decode(snapshot.encodedString())
        let allowed = try file("device-1.XLOG")
        XCTAssertEqual(RuleMatcher.visibleActions(in: restored.config, context: .items([allowed])).map(\.id), [action.id])
        XCTAssertTrue(RuleMatcher.visibleActions(in: restored.config, context: .items([allowed, try file("other.xlog")])).isEmpty)
        XCTAssertTrue(RuleMatcher.visibleActions(in: restored.config, context: .items([allowed, allowed, allowed])).isEmpty)
    }
}
