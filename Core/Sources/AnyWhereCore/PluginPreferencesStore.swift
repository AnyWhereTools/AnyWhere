import Foundation

public struct PluginShortcut: Codable, Equatable, Sendable {
    public let title: String
    public let keywords: [String]
    public init(title: String, keywords: [String]) { self.title = title; self.keywords = keywords }
}

public enum PluginShortcutError: Error {
    case invalidShortcut
    case duplicateKeyword(String)
}

public final class PluginPreferencesStore {
    private struct State: Codable {
        var enabled: [String: Bool] = [:]
        var recent: [String] = []
        var actions: [String: Set<UUID>] = [:]
        // Optional so preference files written before shortcuts still decode.
        var shortcuts: [String: PluginShortcut]?
        var pinnedSummaries: [String]?
        var mcpApprovals: [String: String]?
    }
    private let file: PluginJSONFile<State>
    public init(directory: URL) {
        file = PluginJSONFile(directory: directory, name: "plugin-preferences.json", limit: 5 * 1024 * 1024, empty: { State() })
    }
    public func isEnabled(actionID: UUID) throws -> Bool { try file.read().enabled[actionID.uuidString] ?? false }
    public func isMCPEnabled(actionID: UUID, approval: String?) throws -> Bool {
        guard let approval else { return false }
        return try file.read().mcpApprovals?[actionID.uuidString] == approval
    }
    public func setMCPEnabled(_ enabled: Bool, actionID: UUID, approval: String) throws {
        try file.update { state in
            if state.mcpApprovals == nil { state.mcpApprovals = [:] }
            state.mcpApprovals?[actionID.uuidString] = enabled ? approval : nil
        }
    }
    public func setEnabled(_ enabled: Bool, actionID: UUID) throws { try file.update { $0.enabled[actionID.uuidString] = enabled } }
    public func recentIDs() throws -> [String] { try file.read().recent }
    public func recent() throws -> [UUID] { try recentIDs().compactMap(UUID.init(uuidString:)) }
    public func pinnedSummaries() throws -> [String] { try file.read().pinnedSummaries ?? [] }
    public func setSummaryPinned(_ pinned: Bool, packKey: String) throws {
        try file.update { state in
            var keys = state.pinnedSummaries ?? []
            if pinned {
                if !keys.contains(packKey) { keys.append(packKey) }
            } else { keys.removeAll { $0 == packKey } }
            state.pinnedSummaries = keys
        }
    }
    public func removeShortcut(actionID: UUID) throws {
        try file.update {
            $0.shortcuts?.removeValue(forKey: actionID.uuidString)
            $0.enabled.removeValue(forKey: actionID.uuidString)
            $0.recent.removeAll { $0 == actionID.uuidString }
        }
    }
    public func searchEntries(_ defaults: [PluginSearchEntry]) throws -> [PluginSearchEntry] {
        let overrides = try file.read().shortcuts ?? [:]
        return defaults.map { entry in
            guard let shortcut = overrides[entry.id.uuidString] else { return entry }
            return PluginSearchEntry(id: entry.id, title: shortcut.title, keywords: shortcut.keywords)
        }
    }
    public func setShortcut(_ shortcut: PluginShortcut, actionID: UUID, defaults: [PluginSearchEntry]) throws {
        let title = shortcut.title.trimmingCharacters(in: .whitespacesAndNewlines)
        let keywords = shortcut.keywords.map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
        guard !title.isEmpty,
              keywords.allSatisfy({ !$0.isEmpty && $0.rangeOfCharacter(from: .controlCharacters) == nil }) else {
            throw PluginShortcutError.invalidShortcut
        }
        try file.update { state in
            let others = defaults.filter { $0.id != actionID }.flatMap {
                state.shortcuts?[$0.id.uuidString]?.keywords ?? $0.keywords
            }
            var seen = others.map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            for keyword in keywords {
                guard !seen.contains(where: { $0.compare(keyword, options: .caseInsensitive) == .orderedSame }) else {
                    throw PluginShortcutError.duplicateKeyword(keyword)
                }
                seen.append(keyword)
            }
            if state.shortcuts == nil { state.shortcuts = [:] }
            state.shortcuts?[actionID.uuidString] = PluginShortcut(title: title, keywords: keywords)
        }
    }
    public func recordUse(actionID: UUID, at: Date = Date()) throws {
        try recordUse(id: actionID.uuidString)
    }
    public func recordUse(applicationURL: URL) throws {
        try recordUse(id: applicationURL.path)
    }
    private func recordUse(id: String) throws {
        try file.update {
            $0.recent.removeAll { $0 == id }
            $0.recent.insert(id, at: 0)
            $0.recent = Array($0.recent.prefix(10))
        }
    }
    public func rememberActions(packKey: String, ids: Set<UUID>) throws {
        try file.update { $0.actions[packKey, default: []].formUnion(ids) }
    }
    public func knownActions(packKey: String) throws -> Set<UUID> { try file.read().actions[packKey] ?? [] }
    public func removePack(packKey: String) throws {
        try file.update { state in
            state.pinnedSummaries?.removeAll { $0 == packKey }
            let ids = Set((state.actions.removeValue(forKey: packKey) ?? []).map(\.uuidString))
            state.enabled = state.enabled.filter { !ids.contains($0.key) }
            state.recent.removeAll { ids.contains($0) }
            state.shortcuts = state.shortcuts?.filter { !ids.contains($0.key) }
            state.mcpApprovals = state.mcpApprovals?.filter { !ids.contains($0.key) }
        }
    }
}
