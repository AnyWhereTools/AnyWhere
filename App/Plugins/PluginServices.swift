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
    private var activations: [(UUID, String, String, PluginReminder?, Date)] = []
    private var entries: [PluginLauncherEntry] = []
    private var timer: Timer?
    private var scheduledPanels: [String: (PluginLauncherEntry, PluginReminder, Date)] = [:]
    private var panels: [String: PluginReminderPanel] = [:]
    private var respondingPacks = Set<String>()
    init(namespace: String = "anywhere.plugin.") { self.namespace = namespace; super.init() }
    deinit { timer?.invalidate() }

    static func directory(_ entry: PluginLauncherEntry) -> URL {
        PackManager.dataDirectory(entry.action.packID!).appendingPathComponent("HostServices").appendingPathComponent(entry.id.uuidString)
    }
    static func store(_ entry: PluginLauncherEntry) -> PluginServiceStore { PluginServiceStore(directory: directory(entry)) }
    private func prefix(_ id: UUID) -> String { namespace + id.uuidString + "." }

    func start() {
        center.delegate = self
        if timer == nil {
            timer = Timer.scheduledTimer(withTimeInterval: 1, repeats: true) { [weak self] _ in
                Task { @MainActor in self?.presentDuePanels() }
            }
        }
    }

    func reconcile(_ entries: [PluginLauncherEntry]) {
        start()
        self.entries = entries
        enabled = Set(entries.filter { $0.definition.capabilities.contains(.notifications) }.map(\.id))
        scheduledPanels = scheduledPanels.filter { enabled.contains($0.value.0.id) }
        for (key, panel) in Array(panels) where !enabled.contains(panel.entryID) { panel.close(); panels.removeValue(forKey: key) }
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
            for entry in entries where enabled.contains(entry.id) && !updating.contains(entry.id) && entry.definition.commands == nil {
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
        try updatePanels(reminders, entry: entry)
        registerCategories()
        if requestPermission, reminders.contains(where: { !$0.usesPanel }) {
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
            if reminder.usesPanel { continue }
            if reminder.recurrence == .none && reminder.date <= Date().timeIntervalSince1970 { continue }
            let content = UNMutableNotificationContent()
            content.title = reminder.title; content.body = reminder.body; content.sound = .default
            content.userInfo = ["pluginActionID": entry.id.uuidString, "itemID": reminder.id]
            content.userInfo["reminder"] = try JSONEncoder().encode(reminder)
            content.categoryIdentifier = categoryID(reminder, entryID: entry.id)
            let date = Date(timeIntervalSince1970: reminder.date)
            let fields: Set<Calendar.Component> = reminder.recurrence == .none ? [.year, .month, .day, .hour, .minute, .second] :
                reminder.recurrence == .weekly ? [.weekday, .hour, .minute, .second] : [.hour, .minute, .second]
            let trigger = UNCalendarNotificationTrigger(dateMatching: Calendar.current.dateComponents(fields, from: date), repeats: reminder.recurrence != .none)
            do { try await center.add(UNNotificationRequest(identifier: ownPrefix + reminder.id, content: content, trigger: trigger)) }
            catch { errors.append("\(reminder.title): \(error.localizedDescription)") }
        }
        if !enabled.contains(entry.id) {
            center.removePendingNotificationRequests(withIdentifiers: reminders.map { ownPrefix + $0.id })
        }
        return ["authorization": authorization, "errors": errors]
    }

    private func categoryID(_ reminder: PluginReminder, entryID: UUID) -> String {
        let encoder = JSONEncoder(); encoder.outputFormatting = [.sortedKeys]
        let data = (try? encoder.encode(reminder.actions ?? [])) ?? Data()
        return prefix(entryID) + "actions." + UUID.deterministic(data.base64EncodedString()).uuidString
    }
    private func registerCategories() {
        let categories = entries.filter { enabled.contains($0.id) }.flatMap { entry in
            ((try? Self.store(entry).reminders()) ?? []).filter { !$0.usesPanel }.map { reminder in
                UNNotificationCategory(identifier: categoryID(reminder, entryID: entry.id), actions: (reminder.actions ?? []).map {
                    UNNotificationAction(identifier: $0.id, title: $0.title, options: [.foreground])
                }, intentIdentifiers: [], options: [])
            }
        }
        center.setNotificationCategories(Set(categories))
    }

    private func updatePanels(_ reminders: [PluginReminder], entry: PluginLauncherEntry) throws {
        let wanted = enabled.contains(entry.id) ? reminders.filter(\.usesPanel) : []
        let ownPrefix = prefix(entry.id)
        for (key, panel) in Array(panels) where key.hasPrefix(ownPrefix) && !wanted.contains(panel.reminder) {
            panel.close(); panels.removeValue(forKey: key)
        }
        scheduledPanels = scheduledPanels.filter { !$0.key.hasPrefix(ownPrefix) || wanted.contains($0.value.1) }
        for reminder in wanted {
            let key = ownPrefix + reminder.id
            guard scheduledPanels[key] == nil else { continue }
            let previous = try Self.store(entry).lastPresented(reminder.id)
            let next: Date?
            if reminder.recurrence == .none {
                next = previous == nil ? Date(timeIntervalSince1970: reminder.date) : nil
            } else {
                next = reminder.nextDate(after: previous.map(Date.init(timeIntervalSince1970:)) ?? Date())
            }
            if let next { scheduledPanels[key] = (entry, reminder, next) }
        }
    }

    func presentDuePanels(now: Date = Date()) {
        for (key, (entry, reminder, date)) in Array(scheduledPanels) where date <= now {
            guard enabled.contains(entry.id) else { scheduledPanels.removeValue(forKey: key); continue }
            do { try Self.store(entry).markPresented(reminder.id, date: now) }
            catch { NSLog("[AnyWhere] Reminder delivery state: %@", error.localizedDescription); scheduledPanels.removeValue(forKey: key); continue }
            if let next = reminder.nextDate(after: now) { scheduledPanels[key] = (entry, reminder, next) }
            else { scheduledPanels.removeValue(forKey: key) }
            panels[key]?.close()
            let panel = PluginReminderPanel(entry: entry, reminder: reminder) { [weak self] action in
                guard let self else { return }
                if let action, reminder.action(for: action)?.background == true, let panel = self.panels[key] {
                    let event = PluginNotificationResponse(id: UUID.deterministic(self.prefix(entry.id) + reminder.id + String(now.timeIntervalSince1970) + action).uuidString,
                                                           itemID: reminder.id, actionID: action)
                    Task { await self.performInlineAction(event, entry: entry, panel: panel) }
                    return
                }
                self.panels.removeValue(forKey: key)
                self.layoutPanels()
                guard let action else { return }
                self.activations.append((entry.id, reminder.id, action, reminder, now))
                self.activatePending(in: self.entries)
            }
            panels[key] = panel
            panel.showWindow(nil)
        }
        layoutPanels()
    }

    private func layoutPanels() {
        var positions: [ObjectIdentifier: NSPoint] = [:]
        for panel in panels.values.sorted(by: { ($0.window?.windowNumber ?? 0) < ($1.window?.windowNumber ?? 0) }) {
            guard let window = panel.window, let screen = panel.display else { continue }
            let frame = screen.visibleFrame, key = ObjectIdentifier(screen)
            var point = positions[key] ?? NSPoint(x: frame.maxX - window.frame.width - 16, y: frame.maxY - 12)
            if point.y - window.frame.height < frame.minY + 12 {
                point = NSPoint(x: point.x - window.frame.width - 12, y: frame.maxY - 12)
            }
            window.setFrameTopLeftPoint(point)
            positions[key] = NSPoint(x: point.x, y: point.y - window.frame.height - 12)
        }
    }

    private func performInlineAction(_ event: PluginNotificationResponse, entry: PluginLauncherEntry, panel: PluginReminderPanel) async {
        let pack = entry.action.packID!
        guard respondingPacks.insert(pack).inserted else {
            panel.setProcessing(false, error: "另一条提醒正在处理，请稍后重试。"); return
        }
        defer { respondingPacks.remove(pack); layoutPanels() }
        do {
            guard enabled.contains(entry.id), try Self.store(entry).reminders().contains(panel.reminder) else {
                panel.close(); return
            }
            if let operation = entry.definition.commands?.notification {
                PluginCommandRuntime.shared.remember(entry, services: self)
                let input = try JSONDecoder().decode(JSONValue.self, from: JSONEncoder().encode(event))
                let snapshot = try JSONDecoder().decode(JSONValue.self, from: JSONEncoder().encode(panel.reminder))
                let result = try await PluginCommandRuntime.shared.invoke(entry: entry, operation: operation, params: .object(["event": input, "reminder": snapshot]))
                if result.object?["reminderSync"]?.object?["status"] == .string("failed") { throw PluginError(.failed, "Task saved, but reminder synchronization failed. Retry to synchronize.") }
            } else {
                let session = PluginSession(entry: entry, invocation: PluginInvocation(actionID: entry.id, source: .launcher), notificationServices: self)
                defer { session.close(discardUnsaved: true) }
                try await session.performNotificationAction(event)
            }
            panel.close()
        } catch {
            let message = (error as NSError).userInfo["WKJavaScriptExceptionMessage"] as? String ?? error.localizedDescription
            panel.setProcessing(false, error: "处理失败：" + String(message.prefix(200)))
        }
    }

    nonisolated func userNotificationCenter(_ center: UNUserNotificationCenter, willPresent notification: UNNotification,
                                           withCompletionHandler completionHandler: @escaping (UNNotificationPresentationOptions) -> Void) {
        completionHandler([.banner, .sound])
    }
    nonisolated func userNotificationCenter(_ center: UNUserNotificationCenter, didReceive response: UNNotificationResponse,
                                           withCompletionHandler completionHandler: @escaping () -> Void) {
        let info = response.notification.request.content.userInfo
        let action = info["pluginActionID"] as? String, item = info["itemID"] as? String
        let selected = response.actionIdentifier
        let snapshot = (info["reminder"] as? Data).flatMap { try? JSONDecoder().decode(PluginReminder.self, from: $0) }
        let deliveredAt = response.notification.date
        let identifier = response.notification.request.identifier
        Task { @MainActor in
            if selected != UNNotificationDismissActionIdentifier, let action, let id = UUID(uuidString: action), let item,
               identifier == prefix(id) + item {
                activations.append((id, item, selected, snapshot, deliveredAt))
                let manager = AppState.shared.packManager
                if !manager.packs.isEmpty { activatePending(in: manager.launcherEntries()) }
            }
            completionHandler()
        }
    }
    private func activatePending(in entries: [PluginLauncherEntry]) {
        let pending = activations; activations.removeAll()
        for (id, item, selected, snapshot, date) in pending {
            guard let entry = entries.first(where: { $0.id == id && $0.definition.capabilities.contains(.notifications) }),
                  let reminders = try? Self.store(entry).reminders(),
                  let current = reminders.first(where: { $0.id == item }) else { continue }
            guard snapshot == nil || snapshot == current else { continue }
            var event: PluginNotificationResponse?
            if selected != UNNotificationDefaultActionIdentifier {
                guard snapshot != nil, current.action(for: selected) != nil else { continue }
                event = PluginNotificationResponse(id: UUID.deterministic(prefix(id) + item + String(date.timeIntervalSince1970) + selected).uuidString,
                                                   itemID: item, actionID: selected)
            }
            PluginLauncherController.shared.open(entry, invocation: PluginInvocation(actionID: id, source: .launcher, argument: item, notification: event))
        }
    }
}
