import XCTest
@testable import AnyWhereCore

final class PluginSearchTests: XCTestCase {
    func testNamePinyinAndInitialsWithoutConfiguredKeywords() {
        let note = PluginSearchEntry(id: UUID(), title: "面板 Demo · 便签", keywords: ["note"])
        for query in ["便签", "BQ", "bianqian", "面板", "mb"] {
            XCTAssertEqual(PluginSearch.matches(query: query, entries: [note], recent: []).first?.entry.id, note.id, query)
        }
        let jian = PluginSearchEntry(id: UUID(), title: "面板 Demo · 便笺", keywords: [])
        for query in ["便笺", "bj", "bianjian"] {
            XCTAssertEqual(PluginSearch.matches(query: query, entries: [jian], recent: []).first?.entry.id, jian.id, query)
        }
        XCTAssertTrue(PluginSearch.matches(query: "bq", entries: [jian], recent: []).isEmpty)
        XCTAssertTrue(PluginSearch.matches(query: "bq", entries: [note], recent: [], keywordsOnly: true).isEmpty)
        XCTAssertTrue(PluginSearch.matches(query: "unknown", entries: [note], recent: []).isEmpty)
        XCTAssertEqual(PluginSearch.matches(query: "note Hello World", entries: [note], recent: []).first?.argument, "Hello World")
        let explicit = PluginSearchEntry(id: UUID(), title: "Other", keywords: ["bq"])
        XCTAssertEqual(PluginSearch.matches(query: "bq", entries: [note, explicit], recent: [note.id]).first?.entry.id, explicit.id)
    }
    func testLauncherUsesExactKeywordsAndKeepsUnmatchedInputForApps() {
        let xlog = PluginSearchEntry(id: UUID(), title: "Xlog 解密", keywords: ["XM", "xm file"])
        for query in ["", "  ", "X", "Xlog 解密", "XML", "unknown"] {
            XCTAssertTrue(PluginSearch.matches(query: query, entries: [xlog], recent: [], keywordsOnly: true).isEmpty, query)
        }
        XCTAssertEqual(PluginSearch.matches(query: " xm ", entries: [xlog], recent: [], keywordsOnly: true).first?.entry.id, xlog.id)
        XCTAssertEqual(PluginSearch.matches(query: "XM file Hello World", entries: [xlog], recent: [], keywordsOnly: true).first?.argument, "Hello World")
        XCTAssertEqual(PluginSearch.matches(query: "XM /tmp/a file.xlog", entries: [xlog], recent: [], keywordsOnly: true).first?.argument, "/tmp/a file.xlog")
    }
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
