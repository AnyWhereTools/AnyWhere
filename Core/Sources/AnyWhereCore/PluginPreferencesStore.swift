import Foundation

public final class PluginPreferencesStore {
    private struct State: Codable {
        var enabled: [String: Bool] = [:]
        var recent: [String] = []
        var actions: [String: Set<UUID>] = [:]
    }
    private let file: PluginJSONFile<State>
    public init(directory: URL) {
        file = PluginJSONFile(directory: directory, name: "plugin-preferences.json", limit: 5 * 1024 * 1024, empty: { State() })
    }
    public func isEnabled(actionID: UUID) throws -> Bool { try file.read().enabled[actionID.uuidString] ?? false }
    public func setEnabled(_ enabled: Bool, actionID: UUID) throws { try file.update { $0.enabled[actionID.uuidString] = enabled } }
    public func recent() throws -> [UUID] { try file.read().recent.compactMap(UUID.init(uuidString:)) }
    public func recordUse(actionID: UUID, at: Date = Date()) throws {
        try file.update {
            $0.recent.removeAll { $0 == actionID.uuidString }
            $0.recent.insert(actionID.uuidString, at: 0)
            $0.recent = Array($0.recent.prefix(10))
        }
    }
    public func rememberActions(packKey: String, ids: Set<UUID>) throws {
        try file.update { $0.actions[packKey, default: []].formUnion(ids) }
    }
    public func knownActions(packKey: String) throws -> Set<UUID> { try file.read().actions[packKey] ?? [] }
    public func removePack(packKey: String) throws {
        try file.update { state in
            let ids = Set((state.actions.removeValue(forKey: packKey) ?? []).map(\.uuidString))
            state.enabled = state.enabled.filter { !ids.contains($0.key) }
            state.recent.removeAll { ids.contains($0) }
        }
    }
}
