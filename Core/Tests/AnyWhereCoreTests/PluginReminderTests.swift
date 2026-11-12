import XCTest
@testable import AnyWhereCore

final class PluginReminderTests: XCTestCase {
    private func reminder(_ fields: String = "") throws -> PluginReminder {
        try JSONDecoder().decode(PluginReminder.self, from: Data("{\"id\":\"task\",\"title\":\"Title\",\"body\":\"Body\",\"date\":2000000000,\"recurrence\":\"none\"\(fields)}".utf8))
    }
    func testLegacyAndActionValidation() throws {
        let old = try reminder()
        try old.validate(); XCTAssertFalse(old.usesPanel); XCTAssertNil(old.actions)
        let panel = try reminder(#", "presentation":"panel", "actions":[{"id":"later","title":"Later"},{"id":"accept","title":"Accept"}]"#)
        try panel.validate(); XCTAssertTrue(panel.usesPanel)
        XCTAssertThrowsError(try reminder(#", "presentation":"unknown""#))
        XCTAssertThrowsError(try reminder(#", "actions":[{"id":"same","title":"A"},{"id":"same","title":"B"}]"#).validate())
        XCTAssertThrowsError(try reminder(#", "actions":[{"id":"../other","title":"A"}]"#).validate())
        XCTAssertThrowsError(try reminder(#", "actions":[{"id":"a","title":" "}]"#).validate())
        XCTAssertThrowsError(try reminder(#", "actions":[{"id":"a","title":"A"},{"id":"b","title":"B"},{"id":"c","title":"C"}]"#).validate())
    }
    func testPanelDeliveryRecordSurvivesRestartAndClearsOnlyForChangedReminder() throws {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: folder) }
        let store = PluginServiceStore(directory: folder)
        var item = try reminder(#", "presentation":"panel""#)
        try store.setReminders([item]); try store.markPresented(item.id, date: Date(timeIntervalSince1970: 2000000001))
        try store.setReminders([item])
        XCTAssertEqual(try PluginServiceStore(directory: folder).lastPresented(item.id), 2000000001)
        item.date += 300; try store.setReminders([item])
        XCTAssertNil(try store.lastPresented(item.id))
        try store.markPresented(item.id, date: Date()); try store.setReminders([])
        XCTAssertNil(try store.lastPresented(item.id))
    }
    func testPanelActionMenusStayGenericAndValidateIDs() throws {
        let fields = #", "presentation":"panel", "actions":[{"id":"later","title":"Later","background":true,"options":[{"id":"five","title":"Five minutes"}]}]"#
        let item = try reminder(fields)
        try item.validate()
        XCTAssertEqual(item.action(for: "five")?.id, "later")
        XCTAssertNil(item.action(for: "later")); XCTAssertNil(item.action(for: "other"))
        XCTAssertThrowsError(try reminder(fields.replacingOccurrences(of: "panel", with: "system")).validate())
        XCTAssertThrowsError(try reminder(fields.replacingOccurrences(of: "\"five\"", with: "\"later\"")).validate())
        XCTAssertThrowsError(try reminder(#", "presentation":"panel", "actions":[{"id":"later","title":"Later","options":[]}]"#).validate())
        XCTAssertEqual(try JSONDecoder().decode(PluginReminder.self, from: JSONEncoder().encode(item)), item)
    }
    func testNextOccurrenceAndNotificationContextRoundTrip() throws {
        var item = try reminder()
        let now = Date(timeIntervalSince1970: item.date)
        XCTAssertNil(item.nextDate(after: now))
        XCTAssertEqual(item.nextDate(after: now.addingTimeInterval(-1)), now)
        var calendar = Calendar(identifier: .gregorian); calendar.timeZone = TimeZone(secondsFromGMT: 0)!
        item.recurrence = .daily
        XCTAssertEqual(item.nextDate(after: now, calendar: calendar), now.addingTimeInterval(86400))
        item.recurrence = .weekly
        XCTAssertEqual(item.nextDate(after: now, calendar: calendar), now.addingTimeInterval(7 * 86400))
        let event = PluginNotificationResponse(id: "delivery", itemID: item.id, actionID: "accept")
        let context = PluginInvocation(actionID: UUID(), source: .launcher, argument: item.id, notification: event)
        XCTAssertEqual(try JSONDecoder().decode(PluginInvocation.self, from: JSONEncoder().encode(context)), context)
        let old = PluginInvocation(actionID: UUID(), source: .launcher)
        XCTAssertNil(try JSONDecoder().decode(PluginInvocation.self, from: JSONEncoder().encode(old)).notification)
    }
}
