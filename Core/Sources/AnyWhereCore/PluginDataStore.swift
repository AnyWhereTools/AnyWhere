import Foundation

/// Shared atomic file discipline for plugin-owned JSON and host-owned plugin preferences.
final class PluginJSONFile<Value: Codable> {
    private let file: URL
    private let empty: () -> Value
    private let limit: Int
    init(directory: URL, name: String, limit: Int, empty: @escaping () -> Value) {
        file = directory.appendingPathComponent(name); self.empty = empty; self.limit = limit
    }
    func read() throws -> Value {
        PluginFileLock.value.lock(); defer { PluginFileLock.value.unlock() }
        return try load()
    }
    func update(_ change: (inout Value) throws -> Void) throws {
        PluginFileLock.value.lock(); defer { PluginFileLock.value.unlock() }
        var value = try load()
        try change(&value)
        let data = try JSONEncoder().encode(value)
        guard data.count <= limit else { throw PluginError(.storageLimit, "Plugin storage limit exceeded.") }
        try prepare(create: true)
        try data.write(to: file, options: .atomic)
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: file.path)
    }
    func remove() throws {
        PluginFileLock.value.lock(); defer { PluginFileLock.value.unlock() }
        try prepare(create: false)
        if FileManager.default.fileExists(atPath: file.path) { try FileManager.default.removeItem(at: file) }
    }
    private func load() throws -> Value {
        try prepare(create: false)
        guard FileManager.default.fileExists(atPath: file.path) else { return empty() }
        let data = try Data(contentsOf: file)
        guard data.count <= limit else { throw PluginError(.storageLimit, "Plugin storage limit exceeded.") }
        return try JSONDecoder().decode(Value.self, from: data)
    }
    private func prepare(create: Bool) throws {
        let fm = FileManager.default
        let directory = file.deletingLastPathComponent()
        func attributes(_ url: URL) throws -> [FileAttributeKey: Any]? {
            do { return try fm.attributesOfItem(atPath: url.path) }
            catch let error as CocoaError where error.code == .fileNoSuchFile || error.code == .fileReadNoSuchFile { return nil }
        }
        if let attr = try attributes(directory) {
            guard attr[.type] as? FileAttributeType == .typeDirectory else { throw PluginError(.denied, "Invalid storage directory.") }
        } else if create {
            try fm.createDirectory(at: directory, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        } else { return }
        try fm.setAttributes([.posixPermissions: 0o700], ofItemAtPath: directory.path)
        if let attr = try attributes(file) {
            guard attr[.type] as? FileAttributeType == .typeRegular else { throw PluginError(.denied, "Invalid storage file.") }
            try fm.setAttributes([.posixPermissions: 0o600], ofItemAtPath: file.path)
        }
    }
}
private enum PluginFileLock { static let value = NSLock() }

public final class PluginDataStore {
    private let file: PluginJSONFile<[String: JSONValue]>
    public init(directory: URL) {
        file = PluginJSONFile(directory: directory, name: "data.json", limit: 5 * 1024 * 1024, empty: { [:] })
    }
    private func validate(_ key: String) throws {
        guard !key.isEmpty, key.utf8.count <= 1024, !key.contains("\0") else {
            throw PluginError(.invalidArguments, "Invalid storage key.")
        }
    }
    public func get(_ key: String) throws -> JSONValue? { try validate(key); return try file.read()[key] }
    public func set(_ key: String, value: JSONValue) throws { try validate(key); try file.update { $0[key] = value } }
    public func remove(_ key: String) throws { try validate(key); try file.update { $0.removeValue(forKey: key) } }
    public func removeAll() throws { try file.remove() }
}
