import Foundation

public struct PluginLink: Codable, Equatable, Sendable {
    public var id: String
    public var title: String
    public var keywords: [String]
    public var url: String

    public func destination(argument: String) throws -> URL {
        let safe = CharacterSet(charactersIn: "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789-._~")
        let address = url.replacingOccurrences(of: "{query}", with: argument.addingPercentEncoding(withAllowedCharacters: safe) ?? "")
        guard address.utf8.count <= 16384, let result = URL(string: address),
              ["https", "http"].contains(result.scheme?.lowercased() ?? ""),
              result.host?.isEmpty == false, result.user == nil, result.password == nil,
              !address.contains("\0") else { throw PluginError(.invalidArguments, "Expected an HTTP(S) website without credentials.") }
        return result
    }
    public func validate() throws {
        try PluginServiceStore.validateID(id)
        guard !title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty, title.utf8.count <= 512,
              keywords.count <= 20, keywords.allSatisfy({ !$0.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty && $0.utf8.count <= 256 && !$0.contains("\0") }),
              url.utf8.count <= 8192 else { throw PluginError(.invalidArguments, "Invalid website entry.") }
        _ = try destination(argument: "query")
    }
}

public struct PluginReminder: Codable, Equatable, Sendable {
    public enum Recurrence: String, Codable, Sendable { case none, daily, weekly }
    public var id: String
    public var title: String
    public var body: String
    /// Seconds since Unix epoch; repeating reminders use its local time/weekday.
    public var date: Double
    public var recurrence: Recurrence
    public func validate() throws {
        try PluginServiceStore.validateID(id)
        guard !title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty, title.utf8.count <= 512,
              body.utf8.count <= 4096, date.isFinite, date > 0, date < 32503680000 else {
            throw PluginError(.invalidArguments, "Invalid reminder.")
        }
    }
}

/// Host-owned service data is separate from arbitrary plugin storage keys.
public final class PluginServiceStore {
    private struct State: Codable { var links: [PluginLink] = []; var reminders: [PluginReminder] = [] }
    private let file: PluginJSONFile<State>
    public init(directory: URL) {
        file = PluginJSONFile(directory: directory, name: "services.json", limit: 1024 * 1024, empty: { State() })
    }
    public static func validateID(_ id: String) throws {
        guard !id.isEmpty, id.utf8.count <= 128,
              id.unicodeScalars.allSatisfy({ CharacterSet(charactersIn: "abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789-_").contains($0) }) else {
            throw PluginError(.invalidArguments, "Expected a stable alphanumeric entry ID.")
        }
    }
    public func links() throws -> [PluginLink] { try file.read().links }
    public func reminders() throws -> [PluginReminder] { try file.read().reminders }
    public func setLinks(_ links: [PluginLink]) throws {
        guard links.count <= 1000, Set(links.map(\.id)).count == links.count else { throw PluginError(.invalidArguments, "At most 1000 unique websites.") }
        try links.forEach { try $0.validate() }
        try file.update { $0.links = links }
    }
    public func setReminders(_ reminders: [PluginReminder]) throws {
        guard reminders.count <= 50, Set(reminders.map(\.id)).count == reminders.count else { throw PluginError(.invalidArguments, "At most 50 active reminders per tool.") }
        try reminders.forEach { try $0.validate() }
        try file.update { $0.reminders = reminders }
    }
}
