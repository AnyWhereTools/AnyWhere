import Foundation

/// Declarative fields; values never belong in the installed manifest or Finder snapshot.
public struct PackSetting: Codable, Hashable, Sendable, Identifiable {
    public enum Kind: String, Codable, Hashable, Sendable { case text, password, toggle, select }
    public var id: String { key }
    public let key: String
    public let title: String
    public let type: Kind
    public var description: String?
    public var defaultValue: String?
    public var required: Bool?
    public var options: [String]?

    public init(key: String, title: String, type: Kind, description: String? = nil,
                defaultValue: String? = nil, required: Bool? = nil, options: [String]? = nil) {
        self.key = key; self.title = title; self.type = type; self.description = description
        self.defaultValue = defaultValue; self.required = required; self.options = options
    }

    public var initialValue: String { defaultValue ?? (type == .toggle ? "false" : "") }
}

public enum PackSettings {
    public enum ValidationError: LocalizedError {
        case declaration(String)
        case required(String)
        case value(String)

        public var errorDescription: String? {
            switch self {
            case .declaration(let key):
                return String(format: String(localized: "packSettings.invalidDeclaration", bundle: .module), key)
            case .required(let title):
                return String(format: String(localized: "packSettings.required", bundle: .module), title)
            case .value(let title):
                return String(format: String(localized: "packSettings.invalidValue", bundle: .module), title)
            }
        }
    }

    public static func validate(_ fields: [PackSetting]) throws {
        var seen = Set<String>()
        for field in fields {
            guard field.key.range(of: "^[A-Z][A-Z0-9_]{0,63}$", options: .regularExpression) != nil,
                  seen.insert(field.key).inserted,
                  !field.title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
                  field.type != .password || field.defaultValue == nil else {
                throw ValidationError.declaration(field.key)
            }
            if field.type == .select {
                guard let options = field.options, !options.isEmpty,
                      options.allSatisfy({ !$0.isEmpty && !$0.contains("\0") }),
                      Set(options).count == options.count else {
                    throw ValidationError.declaration(field.key)
                }
            } else if field.options != nil {
                throw ValidationError.declaration(field.key)
            }
            try validateValue(field.initialValue, for: field, checkRequired: false)
        }
    }

    private static func validateValue(_ value: String, for field: PackSetting, checkRequired: Bool) throws {
        if checkRequired && field.required == true && value.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            throw ValidationError.required(field.title)
        }
        guard !value.contains("\0"),
              field.type != .toggle || ["true", "false"].contains(value),
              field.type != .select || value.isEmpty || (field.options ?? []).contains(value) else {
            throw ValidationError.value(field.title)
        }
    }

    public static func environment(fields: [PackSetting], values: [String: String]) throws -> [String: String] {
        try validate(fields)
        var env: [String: String] = [:]
        for field in fields {
            let value = values[field.key] ?? field.initialValue
            try validateValue(value, for: field, checkRequired: true)
            env["ANYWHERE_CONFIG_" + field.key] = value
        }
        return env
    }

    /// Mask literal secret values before script output reaches notifications or execution history.
    public static func redacted(_ text: String, secrets: [String]) -> String {
        secrets.filter { !$0.isEmpty }.sorted { $0.count > $1.count }.reduce(text) {
            $0.replacingOccurrences(of: $1, with: "••••")
        }
    }
}

public protocol PackSecretStore {
    func read(account: String) throws -> String?
    func write(_ value: String?, account: String) throws
    func removeAccounts(prefix: String) throws
}

public final class PackConfigurationStore {
    // UI saves and queued executions must see one complete configuration within this process.
    private static let lock = NSLock()
    private let directory: URL
    private let secrets: any PackSecretStore

    public init(directory: URL, secrets: any PackSecretStore) {
        self.directory = directory; self.secrets = secrets
    }

    private func file(_ actionID: UUID) -> URL { directory.appendingPathComponent(actionID.uuidString + ".json") }
    private func account(_ actionID: UUID, _ key: String) -> String { actionID.uuidString + "." + key }

    public func load(actionID: UUID, fields: [PackSetting]) throws -> [String: String] {
        Self.lock.lock(); defer { Self.lock.unlock() }
        try PackSettings.validate(fields)
        let url = file(actionID)
        let plain = FileManager.default.fileExists(atPath: url.path)
            ? try JSONDecoder().decode([String: String].self, from: Data(contentsOf: url)) : [:]
        var values: [String: String] = [:]
        for field in fields {
            let saved = field.type == .password
                ? try secrets.read(account: account(actionID, field.key)) : plain[field.key]
            values[field.key] = saved ?? field.initialValue
        }
        return values
    }

    public func save(actionID: UUID, fields: [PackSetting], values: [String: String]) throws {
        Self.lock.lock(); defer { Self.lock.unlock() }
        _ = try PackSettings.environment(fields: fields, values: values)
        try persist(actionID: actionID, fields: fields, values: values)
    }

    public func clear(actionID: UUID, fields: [PackSetting]) throws {
        Self.lock.lock(); defer { Self.lock.unlock() }
        try PackSettings.validate(fields)
        try persist(actionID: actionID, fields: fields, values: [:])
    }

    public func remove(actionID: UUID) throws {
        Self.lock.lock(); defer { Self.lock.unlock() }
        try secrets.removeAccounts(prefix: actionID.uuidString + ".")
        if FileManager.default.fileExists(atPath: file(actionID).path) {
            try FileManager.default.removeItem(at: file(actionID))
        }
    }

    private func persist(actionID: UUID, fields: [PackSetting], values: [String: String]) throws {
        let passwordFields = fields.filter { $0.type == .password }
        var previous: [String: String] = [:]
        for field in passwordFields { previous[field.key] = try secrets.read(account: account(actionID, field.key)) ?? "" }
        do {
            for field in passwordFields {
                let value = values[field.key] ?? ""
                try secrets.write(value.isEmpty ? nil : value, account: account(actionID, field.key))
            }
            var plain: [String: String] = [:]
            for field in fields where field.type != .password { plain[field.key] = values[field.key] }
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true,
                                                    attributes: [.posixPermissions: 0o700])
            try JSONEncoder().encode(plain).write(to: file(actionID), options: .atomic)
        } catch {
            for field in passwordFields {
                let old = previous[field.key] ?? ""
                try? secrets.write(old.isEmpty ? nil : old, account: account(actionID, field.key))
            }
            throw error
        }
    }
}
