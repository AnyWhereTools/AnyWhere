import XCTest
@testable import AnyWhereCore

final class ApplicationSearchTests: XCTestCase {
    func testFindsNestedAppsWithoutHelpersAndRanksNames() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        for (path, name) in [("Utilities/Alpha.app", "Alpha"), ("Alphabet.app", "Alphabet"),
                             ("My Alpha.app", "My Alpha"), ("Alpha.app/Contents/Helper.app", "Helper"),
                             ("Alpha.app", "Alpha"), ("Notes.app", "备忘录")] {
            let contents = root.appendingPathComponent(path).appendingPathComponent("Contents")
            try FileManager.default.createDirectory(at: contents, withIntermediateDirectories: true)
            let info = ["CFBundleIdentifier": "test." + UUID().uuidString, "CFBundleName": name,
                        "CFBundleDisplayName": name, "CFBundlePackageType": "APPL"]
            try PropertyListSerialization.data(fromPropertyList: info, format: .xml, options: 0)
                .write(to: contents.appendingPathComponent("Info.plist"))
        }
        let apps = ApplicationSearch.discover(in: [root, root])
        XCTAssertEqual(apps.count, 5)
        XCTAssertFalse(apps.contains { $0.name == "Helper" })
        XCTAssertTrue(ApplicationSearch.matches(query: "  ", apps: apps).isEmpty)
        XCTAssertEqual(ApplicationSearch.matches(query: " alpha ", apps: apps).map(\.name), ["Alpha", "Alpha", "Alphabet", "My Alpha"])
        XCTAssertEqual(ApplicationSearch.matches(query: "notes", apps: apps).first?.name, "备忘录")
        XCTAssertEqual(ApplicationSearch.matches(query: "备忘", apps: apps).first?.name, "备忘录")
        XCTAssertEqual(ApplicationSearch.matches(query: "BWL", apps: apps).first?.name, "备忘录")
        XCTAssertEqual(ApplicationSearch.matches(query: "beiwanglu", apps: apps).first?.name, "备忘录")
        XCTAssertTrue(ApplicationSearch.matches(query: "unknown", apps: apps).isEmpty)
    }
}
