import Foundation
import WebKit
import AnyWhereCore

/// All command sources share the same pack-scoped queue, including awaits and reminder replacement.
@MainActor
final class PluginCommandRuntime {
    static let shared = PluginCommandRuntime()
    static let storageChanged = Notification.Name("AnyWhere.pluginStorageChanged")
    private var entries: [UUID: PluginLauncherEntry] = [:]
    private var services: [UUID: PluginServices] = [:]
    private var tails: [String: Task<Void, Never>] = [:]
    private var pending: [String: Int] = [:]
    private var running: [String: PluginSession] = [:]
    private var protectedKeys: [String: Set<String>] = [:]

    func remember(_ entry: PluginLauncherEntry, services: PluginServices) {
        guard entry.definition.commands != nil, entries[entry.id] == nil else { return }
        entries[entry.id] = entry; self.services[entry.id] = services
        if let pack = entry.action.packID { protectedKeys[pack, default: []].formUnion(entry.definition.commands?.storageKeys ?? []) }
    }
    func reconcile(_ current: [PluginLauncherEntry], declarations: [PluginLauncherEntry]? = nil, services: PluginServices? = nil) {
        let notificationServices = services ?? .shared
        protectedKeys = [:]
        for entry in declarations ?? current {
            if let pack = entry.action.packID { protectedKeys[pack, default: []].formUnion(entry.definition.commands?.storageKeys ?? []) }
        }
        let next = Dictionary(uniqueKeysWithValues: current.filter { $0.definition.commands != nil }.map { ($0.id, $0) })
        for (pack, session) in Array(running) where next[session.entry.id]?.definition != session.entry.definition {
            session.close(discardUnsaved: true); running.removeValue(forKey: pack)
        }
        let changed = next.values.filter { entries[$0.id]?.definition != $0.definition }
        entries = next
        self.services = Dictionary(uniqueKeysWithValues: next.keys.map { ($0, notificationServices) })
        for entry in changed {
            guard let command = entry.definition.commands?.reconcile else { continue }
            Task {
                do { _ = try await invoke(entry: entry, operation: command, params: .object([:])) }
                catch { NSLog("[AnyWhere] Command reconciliation: %@", error.localizedDescription) }
            }
        }
    }
    func isCurrent(_ entry: PluginLauncherEntry) -> Bool {
        entries[entry.id]?.definition == entry.definition && entries[entry.id]?.directory == entry.directory
    }
    func managedKeys(pack: String) -> Set<String> {
        protectedKeys[pack] ?? []
    }
    func invalidate(pack: String) {
        for entry in Array(entries.values).filter({ $0.action.packID == pack }) { entries.removeValue(forKey: entry.id); services.removeValue(forKey: entry.id) }
        running[pack]?.close(discardUnsaved: true)
    }
    func invoke(entry: PluginLauncherEntry, operation: String, params: JSONValue,
                authorize: @escaping @MainActor () throws -> Void = {}) async throws -> JSONValue {
        guard let pack = entry.action.packID, let command = entry.definition.commands?.operations[operation] else {
            throw PluginError(.invalidArguments, "Command is not declared.")
        }
        try PluginJSONSchema.validate(params, schema: command.inputSchema)
        guard pending[pack, default: 0] < 64 else { throw PluginError(.busy, "Plugin command queue is full.") }
        pending[pack, default: 0] += 1
        let previous = tails[pack]
        let result = Task { @MainActor () throws -> JSONValue in
            await previous?.value
            defer { pending[pack, default: 1] -= 1 }
            guard isCurrent(entry) else { throw PluginError(.denied, "Plugin was disabled, updated or removed.") }
            try authorize()
            let session = PluginSession(entry: entry, invocation: PluginInvocation(actionID: entry.id, source: .launcher),
                                        notificationServices: services[entry.id], command: operation, commandRuntime: self,
                                        commandAuthorization: authorize)
            running[pack] = session
            defer { session.close(discardUnsaved: true); running.removeValue(forKey: pack) }
            let outcome: Result<JSONValue, Error>
            do { outcome = .success(try await session.performCommand(operation, params: params)) }
            catch { outcome = .failure(error) }
            session.close(discardUnsaved: true)
            // Closing a WebView cannot cancel native notification calls already in flight.
            // Drain them before admitting the next writer so old reminders cannot arrive last.
            await session.waitForHostOperations()
            let value = try outcome.get()
            if let schema = command.outputSchema { try PluginJSONSchema.validate(value, schema: schema) }
            return value
        }
        let tail = Task { _ = await result.result }
        tails[pack] = tail
        return try await result.value
    }
}
