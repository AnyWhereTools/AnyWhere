import AppKit
import UserNotifications
import AnyWhereCore

@MainActor
final class PluginServices: NSObject, UNUserNotificationCenterDelegate {
    static let shared = PluginServices()
    static let changed = Notification.Name("AnyWhere.pluginServicesChanged")
    private let center = UNUserNotificationCenter.current()
    private var enabled = Set<UUID>()
    private var generation = 0
    private var updating = Set<UUID>()
    private let namespace: String
    private var activation: (UUID, String)?
    init(namespace: String = "anywhere.plugin.") { self.namespace = namespace; super.init() }

    static func directory(_ entry: PluginLauncherEntry) -> URL {
        PackManager.dataDirectory(entry.action.packID!).appendingPathComponent("HostServices").appendingPathComponent(entry.id.uuidString)
    }
    static func store(_ entry: PluginLauncherEntry) -> PluginServiceStore { PluginServiceStore(directory: directory(entry)) }
    private func prefix(_ id: UUID) -> String { namespace + id.uuidString + "." }

    func start() { center.delegate = self }

    func reconcile(_ entries: [PluginLauncherEntry]) {
        start()
        enabled = Set(entries.filter { $0.definition.capabilities.contains(.notifications) }.map(\.id))
        activatePending(in: entries)
        generation += 1
        let version = generation
        Task {
            let pending = await center.pendingNotificationRequests()
            guard version == generation else { return }
            let stale = pending.filter { request in
                request.identifier.hasPrefix(namespace) && !enabled.contains(where: { request.identifier.hasPrefix(prefix($0)) })
            }.map(\.identifier)
            center.removePendingNotificationRequests(withIdentifiers: stale)
            let delivered = await center.deliveredNotifications()
            guard version == generation else { return }
            center.removeDeliveredNotifications(withIdentifiers: delivered.filter { notification in
                notification.request.identifier.hasPrefix(namespace) && !enabled.contains(where: { notification.request.identifier.hasPrefix(prefix($0)) })
            }.map { $0.request.identifier })
            for entry in entries where enabled.contains(entry.id) && !updating.contains(entry.id) {
                guard version == generation else { return }
                do { _ = try await replace(try Self.store(entry).reminders(), entry: entry, requestPermission: false) }
                catch { NSLog("[AnyWhere] Reminder reconciliation: %@", error.localizedDescription) }
            }
        }
    }

    func status() async -> String {
        let settings = await center.notificationSettings()
        switch settings.authorizationStatus {
        case .authorized, .provisional: return "authorized"
        case .denied: return "denied"
        default: return "notDetermined"
        }
    }

    func replace(_ reminders: [PluginReminder], entry: PluginLauncherEntry, requestPermission: Bool = true) async throws -> [String: Any] {
        guard !updating.contains(entry.id) else { throw PluginError(.busy, "Reminder update is in progress.") }
        updating.insert(entry.id); defer { updating.remove(entry.id) }
        let store = Self.store(entry)
        let previous = try store.reminders()
        try store.setReminders(reminders)
        if requestPermission, !reminders.isEmpty, await status() == "notDetermined" {
            _ = try await center.requestAuthorization(options: [.alert, .sound])
        }
        let authorization = await status()
        let ownPrefix = prefix(entry.id)
        let pending = await center.pendingNotificationRequests()
        let identifiers = pending.filter { $0.identifier.hasPrefix(ownPrefix) }.map(\.identifier)
        center.removePendingNotificationRequests(withIdentifiers: identifiers)
        let delivered = await center.deliveredNotifications()
        let changed = Set(previous.filter { !reminders.contains($0) }.map { ownPrefix + $0.id })
        let retained = Set(reminders.map { ownPrefix + $0.id })
        center.removeDeliveredNotifications(withIdentifiers: delivered.filter {
            $0.request.identifier.hasPrefix(ownPrefix) && (changed.contains($0.request.identifier) || !retained.contains($0.request.identifier))
        }.map { $0.request.identifier })
        guard enabled.contains(entry.id) else { return ["authorization": authorization, "errors": reminders.isEmpty ? [] : ["请启用此工具的搜索入口，提醒才能运行。"]] }
        guard authorization == "authorized" else { return ["authorization": authorization, "errors": []] }
        var errors: [String] = []
        for reminder in reminders {
            guard enabled.contains(entry.id) else { break }
            if reminder.recurrence == .none && reminder.date <= Date().timeIntervalSince1970 { continue }
            let content = UNMutableNotificationContent()
            content.title = reminder.title; content.body = reminder.body; content.sound = .default
            content.userInfo = ["pluginActionID": entry.id.uuidString, "itemID": reminder.id]
            let date = Date(timeIntervalSince1970: reminder.date)
            let fields: Set<Calendar.Component> = reminder.recurrence == .none ? [.year, .month, .day, .hour, .minute, .second] :
                reminder.recurrence == .weekly ? [.weekday, .hour, .minute] : [.hour, .minute]
            let trigger = UNCalendarNotificationTrigger(dateMatching: Calendar.current.dateComponents(fields, from: date), repeats: reminder.recurrence != .none)
            do { try await center.add(UNNotificationRequest(identifier: ownPrefix + reminder.id, content: content, trigger: trigger)) }
            catch { errors.append("\(reminder.title): \(error.localizedDescription)") }
        }
        if !enabled.contains(entry.id) {
            center.removePendingNotificationRequests(withIdentifiers: reminders.map { ownPrefix + $0.id })
        }
        return ["authorization": authorization, "errors": errors]
    }

    nonisolated func userNotificationCenter(_ center: UNUserNotificationCenter, willPresent notification: UNNotification,
                                           withCompletionHandler completionHandler: @escaping (UNNotificationPresentationOptions) -> Void) {
        completionHandler([.banner, .sound])
    }
    nonisolated func userNotificationCenter(_ center: UNUserNotificationCenter, didReceive response: UNNotificationResponse,
                                           withCompletionHandler completionHandler: @escaping () -> Void) {
        let info = response.notification.request.content.userInfo
        let action = info["pluginActionID"] as? String, item = info["itemID"] as? String
        Task { @MainActor in
            if let action, let id = UUID(uuidString: action), let item {
                activation = (id, item)
                let manager = AppState.shared.packManager
                if !manager.packs.isEmpty { activatePending(in: manager.launcherEntries()) }
            }
            completionHandler()
        }
    }
    private func activatePending(in entries: [PluginLauncherEntry]) {
        guard let (id, item) = activation else { return }
        activation = nil
        guard let entry = entries.first(where: { $0.id == id && $0.definition.capabilities.contains(.notifications) }) else { return }
        PluginLauncherController.shared.open(entry, invocation: PluginInvocation(actionID: id, source: .launcher, argument: item))
    }
}
