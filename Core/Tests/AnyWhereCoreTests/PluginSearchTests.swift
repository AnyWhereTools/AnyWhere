import XCTest
@testable import AnyWhereCore

final class PluginSearchTests: XCTestCase {
    func testAliasesAndArguments() {
        let a = PluginSearchEntry(id: UUID(), title: "翻译", keywords: ["tr"])
        let b = PluginSearchEntry(id: UUID(), title: "Translate file", keywords: ["tr file"])
        let matches = PluginSearch.matches(query: "TR file Hello World", entries: [a,b], recent: [])
        XCTAssertEqual(matches.first?.entry.id, b.id)
        XCTAssertEqual(matches.first?.argument, "Hello World")
        XCTAssertEqual(PluginSearch.matches(query: "译", entries: [a,b], recent: []).first?.argument, "")
        XCTAssertEqual(PluginSearch.matches(query: "", entries: [a,b], recent: [b.id]).first?.entry.id, b.id)
        XCTAssertTrue(PluginSearch.matches(query: "zzzz", entries: [a,b], recent: []).isEmpty)
        XCTAssertEqual(PluginSearch.matches(query: "  TR Hello\nWorld  ", entries: [a], recent: []).first?.argument, "Hello\nWorld  ")
        XCTAssertEqual(PluginSearch.matches(query: "", entries: [a,b], recent: [b.id]).count, 1)
    }
}
