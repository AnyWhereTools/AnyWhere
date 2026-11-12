import XCTest
import AppKit
import AnyWhereCore
@testable import AnyWhere

@MainActor
final class PluginReminderPanelTests: XCTestCase {
    private final class LinkEditor: NSTextView {
        var opened: [URL] = []
        override func clicked(onLink link: Any, at charIndex: Int) {
            if let url = link as? URL { opened.append(url) }
        }
    }
    private final class FieldEditorDelegate: NSObject, NSWindowDelegate {
        let editor = LinkEditor()
        override init() { super.init(); editor.isFieldEditor = true }
        func windowWillReturnFieldEditor(_ sender: NSWindow, to client: Any?) -> Any? { editor }
    }
    private func panel(body: String, onResponse: @escaping (String?) -> Void = { _ in }) throws -> PluginReminderPanel {
        let action = MenuAction(id: UUID(), title: "待办 Todo", icon: .symbol("checklist"), kind: .openPluginUI,
                                matching: MatchRule(), placement: .topLevel, packID: "reminder-link-test", isEnabled: true, sortOrder: 0)
        let definition = try JSONDecoder().decode(PackAction.self, from: Data(#"{"id":"todo","title":"待办 Todo","ui":{"entry":"index.html"}}"#.utf8))
        let entry = PluginLauncherEntry(id: action.id, action: action, definition: definition, directory: FileManager.default.temporaryDirectory)
        let data: [String: Any] = ["id": "link-test", "title": "[TAPD任务][1045438]【登录】Android 端体验优化", "body": body,
                                   "date": 2000000000, "recurrence": "none", "presentation": "panel",
                                   "actions": [["id": "later", "title": "推迟"], ["id": "complete", "title": "确认完成"]]]
        let reminder = try JSONDecoder().decode(PluginReminder.self, from: JSONSerialization.data(withJSONObject: data))
        return PluginReminderPanel(entry: entry, reminder: reminder, onResponse: onResponse)
    }
    private func bodyField(_ panel: PluginReminderPanel) throws -> NSTextField {
        let stack = try XCTUnwrap(panel.window?.contentView?.subviews.first as? NSStackView)
        return try XCTUnwrap(stack.arrangedSubviews[2] as? NSTextField)
    }

    func testLinksPreserveQueriesAndExcludeSurroundingPunctuation() throws {
        let urls = ["https://www.tapd.cn/tapd_fe/my/work?dialog_preview_id=task_1140685585001045438&from=todo#detail",
                    "http://example.com/task?id=2"]
        let text = "项目：UGOS_PRO 🙂\n链接：\(urls[0])，继续处理。\n参考：(\(urls[1]))."
        let panel = try panel(body: text)
        defer { panel.close() }
        let field = try bodyField(panel), content = field.attributedStringValue
        XCTAssertEqual(content.string, text)
        XCTAssertFalse(field.isEditable)
        XCTAssertTrue(field.isSelectable)
        XCTAssertTrue(field.allowsEditingTextAttributes)
        var found: [String] = []
        content.enumerateAttribute(.link, in: NSRange(location: 0, length: content.length)) { value, range, _ in
            guard let url = value as? URL else { return }
            found.append(url.absoluteString)
            XCTAssertEqual((text as NSString).substring(with: range), url.absoluteString)
            XCTAssertEqual(content.attribute(.underlineStyle, at: range.location, effectiveRange: nil) as? Int, NSUnderlineStyle.single.rawValue)
        }
        XCTAssertEqual(found, urls)
    }

    func testPlainTextAndOtherSchemesRemainUnlinked() throws {
        let text = "普通备注 <b>不会解析 HTML</b>\nfile:///tmp/test ftp://example.com mailto:user@example.com javascript:alert(1)"
        let panel = try panel(body: text)
        defer { panel.close() }
        let field = try bodyField(panel)
        XCTAssertEqual(field.stringValue, text)
        field.attributedStringValue.enumerateAttribute(.link, in: NSRange(location: 0, length: (text as NSString).length)) { value, _, _ in
            XCTAssertNil(value)
        }
    }

    func testWrappedLinkClicksKeepCardAndActionsAvailable() throws {
        let url = URL(string: "https://www.tapd.cn/tapd_fe/my/work?dialog_preview_id=task_1140685585001045438")!
        var responses: [String?] = []
        let panel = try panel(body: "项目：UGOS_PRO\nTAPD任务ID：1140685585001045438\n链接：\(url.absoluteString)") { responses.append($0) }
        let window = try XCTUnwrap(panel.window), field = try bodyField(panel)
        let delegate = FieldEditorDelegate()
        window.delegate = delegate
        defer { window.delegate = panel; panel.close() }
        panel.showWindow(nil)
        window.contentView?.layoutSubtreeIfNeeded()
        field.selectText(nil)
        let editor = try XCTUnwrap(field.currentEditor() as? LinkEditor)
        let layout = try XCTUnwrap(editor.layoutManager), container = try XCTUnwrap(editor.textContainer)
        layout.ensureLayout(for: container)
        let range = (editor.string as NSString).range(of: url.absoluteString)
        let glyphs = layout.glyphRange(forCharacterRange: range, actualCharacterRange: nil)
        var points: [NSPoint] = []
        layout.enumerateLineFragments(forGlyphRange: glyphs) { _, _, _, lineRange, _ in
            let intersection = NSIntersectionRange(glyphs, lineRange)
            let rect = layout.boundingRect(forGlyphRange: NSRange(location: intersection.location, length: 1), in: container)
            points.append(NSPoint(x: rect.midX + editor.textContainerOrigin.x, y: rect.midY + editor.textContainerOrigin.y))
        }
        XCTAssertGreaterThanOrEqual(points.count, 2, "TAPD URL must wrap to exercise both lines")
        let locations = points.map { editor.convert($0, to: nil) }
        window.makeFirstResponder(nil)
        for location in locations {
            let up = try XCTUnwrap(NSEvent.mouseEvent(with: .leftMouseUp, location: location, modifierFlags: [], timestamp: 0,
                                                    windowNumber: window.windowNumber, context: nil, eventNumber: 0, clickCount: 1, pressure: 0))
            let down = try XCTUnwrap(NSEvent.mouseEvent(with: .leftMouseDown, location: location, modifierFlags: [], timestamp: 0,
                                                      windowNumber: window.windowNumber, context: nil, eventNumber: 0, clickCount: 1, pressure: 1))
            NSApp.postEvent(up, atStart: true)
            field.mouseDown(with: down)
        }
        XCTAssertEqual(editor.opened, Array(repeating: url, count: points.count))
        XCTAssertTrue(window.isVisible)
        XCTAssertTrue(responses.isEmpty)
        window.makeFirstResponder(nil)
        for appearance in [NSAppearance.Name.aqua, .darkAqua] {
            window.appearance = NSAppearance(named: appearance)
            let view = try XCTUnwrap(window.contentView)
            view.displayIfNeeded()
            let bitmap = try XCTUnwrap(view.bitmapImageRepForCachingDisplay(in: view.bounds))
            view.cacheDisplay(in: view.bounds, to: bitmap)
            try XCTUnwrap(bitmap.representation(using: .png, properties: [:]))
                .write(to: URL(fileURLWithPath: "/tmp/anywhere-reminder-links-\(appearance.rawValue).png"))
        }
        window.delegate = panel
        let stack = try XCTUnwrap(window.contentView?.subviews.first as? NSStackView)
        let buttons = try XCTUnwrap(stack.arrangedSubviews.last as? NSStackView)
        let complete = try XCTUnwrap(buttons.arrangedSubviews.last as? NSButton)
        complete.performClick(nil)
        XCTAssertEqual(responses.count, 1)
        XCTAssertEqual(responses.first ?? nil, "complete")
        XCTAssertFalse(window.isVisible)
    }
}
