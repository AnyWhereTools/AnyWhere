import Foundation
import UserNotifications

enum Notifier {
    static func requestAuthorizationOnce() {
        Permissions.requestNotifications()
    }

    static func showFailure(_ title: String, _ message: String) {
        let content = UNMutableNotificationContent()
        content.title = String(format: String(localized: "notify.actionFailedTitle"), title)
        content.body = String(message.prefix(200))
        let request = UNNotificationRequest(identifier: UUID().uuidString, content: content, trigger: nil)
        UNUserNotificationCenter.current().add(request)
    }
}
