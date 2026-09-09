import AppKit
import UniformTypeIdentifiers
import AnyWhereCore

/// Session-scoped opaque handles. No plugin-supplied filesystem paths cross this boundary.
@MainActor
final class PluginDocuments {
    static let limit = 50 * 1024 * 1024
    static let chunkSize = 192 * 1024
    private let directory: URL
    private var readers: [String: FileHandle] = [:]
    private var writers: [String: (handle: FileHandle, url: URL, size: Int)] = [:]
    private(set) var dirty = false
    private var version = 0
    private var savedVersion = -1
    private var ended = false

    init(directory: URL) { self.directory = directory.appendingPathComponent("Documents") }
    private var draft: URL { directory.appendingPathComponent("draft.json") }
    func markDirty(_ version: Int) { if version >= self.version { self.version = version; dirty = true } }
    private func prepare() throws {
        let fm = FileManager.default
        if fm.fileExists(atPath: directory.path) {
            guard try directory.resourceValues(forKeys: [.isSymbolicLinkKey, .isDirectoryKey]).isSymbolicLink != true,
                  try directory.resourceValues(forKeys: [.isDirectoryKey]).isDirectory == true else { throw PluginError(.denied, "Invalid document directory.") }
        } else { try fm.createDirectory(at: directory, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700]) }
    }
    func open(draftOnly: Bool) async throws -> Any {
        let url: URL
        if draftOnly {
            try prepare()
            guard FileManager.default.fileExists(atPath: draft.path) else { return NSNull() }
            url = draft
        } else {
            let panel = NSOpenPanel()
            panel.canChooseDirectories = false; panel.allowsMultipleSelection = false
            panel.allowedContentTypes = [.json, .plainText, .data]
            guard await panel.begin() == .OK, let chosen = panel.url else { return NSNull() }
            url = chosen
        }
        guard !ended else { throw PluginError(.sessionClosed, "Session ended.") }
        return try reader(url)
    }
    // Internal entry point also used by native checks; plugin callers only receive picker/draft handles.
    func reader(_ url: URL) throws -> [String: Any] {
        let info = try url.resourceValues(forKeys: [.isRegularFileKey, .isSymbolicLinkKey, .fileSizeKey])
        guard info.isRegularFile == true, info.isSymbolicLink != true, let size = info.fileSize, size <= Self.limit else {
            throw PluginError(.outputLimit, "Choose a regular file up to 50 MiB.")
        }
        guard readers.count < 4 else { throw PluginError(.busy, "Too many open documents.") }
        let token = UUID().uuidString
        readers[token] = try FileHandle(forReadingFrom: url)
        return ["id": token, "name": url.lastPathComponent, "size": size]
    }
    func read(_ id: String) throws -> [String: Any] {
        guard let handle = readers[id] else { throw PluginError(.invalidArguments, "Unknown document handle.") }
        guard try handle.offset() <= Self.limit else { throw PluginError(.outputLimit, "File grew beyond 50 MiB.") }
        let data = try handle.read(upToCount: Self.chunkSize) ?? Data()
        guard try handle.offset() <= Self.limit else { throw PluginError(.outputLimit, "File grew beyond 50 MiB.") }
        if data.isEmpty { try handle.close(); readers.removeValue(forKey: id) }
        return ["data": data.base64EncodedString(), "done": data.isEmpty]
    }
    func beginWrite() throws -> String {
        try prepare()
        guard writers.count < 2 else { throw PluginError(.busy, "A document save is already in progress.") }
        let id = UUID().uuidString, url = directory.appendingPathComponent(UUID().uuidString + ".tmp")
        guard FileManager.default.createFile(atPath: url.path, contents: nil, attributes: [.posixPermissions: 0o600]) else { throw PluginError(.failed, "Could not create document.") }
        writers[id] = (try FileHandle(forWritingTo: url), url, 0)
        return id
    }
    func append(_ id: String, base64: String) throws {
        guard var writer = writers[id], let data = Data(base64Encoded: base64), data.count <= Self.chunkSize else { throw PluginError(.invalidArguments, "Invalid document chunk.") }
        guard writer.size + data.count <= Self.limit else { throw PluginError(.outputLimit, "Document exceeds 50 MiB.") }
        try writer.handle.write(contentsOf: data); writer.size += data.count; writers[id] = writer
    }
    func finish(_ id: String, draftOnly: Bool, version: Int, name: String, clipboard: Bool = false) async throws -> Bool {
        guard let writer = writers[id] else { throw PluginError(.invalidArguments, "Unknown document handle.") }
        if draftOnly && version < savedVersion { cancel(id); return false }
        try writer.handle.synchronize(); try writer.handle.close()
        if clipboard {
            defer { cancel(id) }
            let text = try String(contentsOf: writer.url, encoding: .utf8)
            NSPasteboard.general.clearContents()
            guard NSPasteboard.general.setString(text, forType: .string) else { throw PluginError(.failed, "Clipboard write failed.") }
            return true
        }
        let destination: URL
        if draftOnly { destination = draft }
        else {
            let panel = NSSavePanel()
            panel.nameFieldStringValue = String(URL(fileURLWithPath: name.isEmpty ? "document.json" : name).lastPathComponent.prefix(200))
            guard await panel.begin() == .OK, let url = panel.url else { cancel(id); return false }
            destination = url
        }
        guard !ended else { throw PluginError(.sessionClosed, "Session ended.") }
        defer { cancel(id) }
        try Data(contentsOf: writer.url, options: .mappedIfSafe).write(to: destination, options: .atomic)
        if draftOnly {
            try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: destination.path)
            if version == self.version { dirty = false }
            savedVersion = version
        }
        return true
    }
    func cancel(_ id: String) {
        if let reader = readers.removeValue(forKey: id) { try? reader.close() }
        if let writer = writers.removeValue(forKey: id) { try? writer.handle.close(); try? FileManager.default.removeItem(at: writer.url) }
    }
    func close() { ended = true; for id in Array(readers.keys) + Array(writers.keys) { cancel(id) } }
}
