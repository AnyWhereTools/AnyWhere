import Foundation
import Darwin

/// Bounded, same-user IPC. The MCP helper never opens plugin storage itself.
public enum LocalCommandSocket {
    public static let limit = 1024 * 1024
    public static var path: String { AppPaths.configDirectory().appendingPathComponent("MCP/commands.sock").path }

    static func address(_ path: String) throws -> sockaddr_un {
        var address = sockaddr_un(); address.sun_family = sa_family_t(AF_UNIX)
        let bytes = Array(path.utf8) + [0]
        guard bytes.count <= MemoryLayout.size(ofValue: address.sun_path) else { throw PluginError(.failed, "Local socket path is too long.") }
        withUnsafeMutableBytes(of: &address.sun_path) { $0.copyBytes(from: bytes) }
        address.sun_len = UInt8(MemoryLayout<sockaddr_un>.size)
        return address
    }
    static func configure(_ fd: Int32) {
        _ = fcntl(fd, F_SETFL, fcntl(fd, F_GETFL) & ~O_NONBLOCK)
        var timeout = timeval(tv_sec: 30, tv_usec: 0)
        setsockopt(fd, SOL_SOCKET, SO_RCVTIMEO, &timeout, socklen_t(MemoryLayout<timeval>.size))
        setsockopt(fd, SOL_SOCKET, SO_SNDTIMEO, &timeout, socklen_t(MemoryLayout<timeval>.size))
        var enabled: Int32 = 1
        setsockopt(fd, SOL_SOCKET, SO_NOSIGPIPE, &enabled, socklen_t(MemoryLayout<Int32>.size))
        _ = fcntl(fd, F_SETFD, FD_CLOEXEC)
    }
    public static func request(_ request: JSONValue, path: String = LocalCommandSocket.path) throws -> JSONValue {
        let fd = socket(AF_UNIX, SOCK_STREAM, 0)
        guard fd >= 0 else { throw failure() }
        defer { Darwin.close(fd) }
        configure(fd)
        var address = try address(path)
        let connected = withUnsafePointer(to: &address) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { Darwin.connect(fd, $0, socklen_t(MemoryLayout<sockaddr_un>.size)) }
        }
        guard connected == 0 else { throw PluginError(.failed, "AnyWhere is unavailable. Start AnyWhere and enable this plugin's MCP access.") }
        var uid: uid_t = 0, gid: gid_t = 0
        guard getpeereid(fd, &uid, &gid) == 0, uid == geteuid() else { throw PluginError(.denied, "Socket peer is not the current user.") }
        try send(request, fd: fd)
        do { return try receive(fd: fd) }
        catch { throw PluginError(.outcomeUnknown, "Connection ended after sending. Query current state before retrying a mutation.") }
    }
    public static func send(_ value: JSONValue, fd: Int32) throws {
        var data = try JSONEncoder().encode(value)
        guard data.count <= limit else { throw PluginError(.outputLimit, "IPC message exceeds 1 MiB.") }
        data.append(10)
        try data.withUnsafeBytes { buffer in
            var offset = 0
            while offset < buffer.count {
                let sent = Darwin.write(fd, buffer.baseAddress!.advanced(by: offset), buffer.count - offset)
                if sent < 0 && errno == EINTR { continue }
                guard sent > 0 else { throw failure() }
                offset += sent
            }
        }
    }
    public static func receive(fd: Int32) throws -> JSONValue {
        var data = Data(), buffer = [UInt8](repeating: 0, count: 8192)
        while true {
            let count = Darwin.read(fd, &buffer, buffer.count)
            if count < 0 && errno == EINTR { continue }
            guard count > 0 else { throw failure() }
            if let end = buffer[..<count].firstIndex(of: 10) {
                data.append(contentsOf: buffer[..<end]); break
            }
            data.append(contentsOf: buffer[..<count])
            guard data.count <= limit else { throw PluginError(.invalidArguments, "IPC message exceeds 1 MiB.") }
        }
        guard data.count <= limit else { throw PluginError(.invalidArguments, "IPC message exceeds 1 MiB.") }
        return try JSONDecoder().decode(JSONValue.self, from: data)
    }
    private static func failure() -> PluginError { PluginError(.failed, "Local IPC failed: \(String(cString: strerror(errno)))") }
}

// Source lifecycle uses a lock; connection counts are confined to the accept queue.
public final class LocalCommandServer: @unchecked Sendable {
    private let path: String
    private var source: DispatchSourceRead?
    private let queue = DispatchQueue(label: "AnyWhere.commandSocket")
    private var connections = 0
    private let lifecycle = NSLock()
    public init(path: String = LocalCommandSocket.path) { self.path = path }
    public func start(handler: @escaping @Sendable (JSONValue) async -> JSONValue) throws {
        lifecycle.lock(); defer { lifecycle.unlock() }
        guard source == nil else { return }
        let directory = URL(fileURLWithPath: path).deletingLastPathComponent()
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        var info = stat()
        guard lstat(directory.path, &info) == 0, info.st_mode & S_IFMT == S_IFDIR, info.st_uid == geteuid() else { throw PluginError(.denied, "Invalid IPC directory.") }
        chmod(directory.path, 0o700)
        if lstat(path, &info) == 0 {
            guard info.st_mode & S_IFMT == S_IFSOCK, info.st_uid == geteuid() else { throw PluginError(.denied, "Invalid IPC socket.") }
            let probe = socket(AF_UNIX, SOCK_STREAM, 0)
            defer { Darwin.close(probe) }
            var existing = try LocalCommandSocket.address(path)
            let result = withUnsafePointer(to: &existing) { $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { connect(probe, $0, socklen_t(MemoryLayout<sockaddr_un>.size)) } }
            guard result != 0, errno == ECONNREFUSED else { throw PluginError(.busy, "Another AnyWhere instance owns the MCP socket.") }
            unlink(path)
        }
        let fd = socket(AF_UNIX, SOCK_STREAM, 0)
        guard fd >= 0 else { throw PluginError(.failed, "Cannot create IPC socket.") }
        LocalCommandSocket.configure(fd)
        var address = try LocalCommandSocket.address(path)
        let bound = withUnsafePointer(to: &address) { $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { bind(fd, $0, socklen_t(MemoryLayout<sockaddr_un>.size)) } }
        guard bound == 0 else { Darwin.close(fd); throw PluginError(.failed, "Cannot bind IPC socket.") }
        chmod(path, 0o600)
        guard listen(fd, 16) == 0 else { Darwin.close(fd); unlink(path); throw PluginError(.failed, "Cannot listen on IPC socket.") }
        _ = fcntl(fd, F_SETFL, O_NONBLOCK)
        let source = DispatchSource.makeReadSource(fileDescriptor: fd, queue: queue)
        source.setEventHandler { [weak self] in
            guard let self else { return }
            while true {
                let client = accept(fd, nil, nil)
                guard client >= 0 else { break }
                var uid: uid_t = 0, gid: gid_t = 0
                guard self.connections < 32, getpeereid(client, &uid, &gid) == 0, uid == geteuid() else { Darwin.close(client); continue }
                self.connections += 1
                LocalCommandSocket.configure(client)
                Task.detached {
                    defer { Darwin.close(client); self.queue.async { self.connections -= 1 } }
                    do { let request = try LocalCommandSocket.receive(fd: client); let reply = await handler(request); try LocalCommandSocket.send(reply, fd: client) }
                    catch { try? LocalCommandSocket.send(.object(["error": .object(["code": .string("failed"), "message": .string(error.localizedDescription)])]), fd: client) }
                }
            }
        }
        let ownedPath = path
        source.setCancelHandler { Darwin.close(fd); unlink(ownedPath) }
        self.source = source; source.resume()
    }
    public func stop() { lifecycle.lock(); defer { lifecycle.unlock() }; source?.cancel(); source = nil }
    deinit { stop() }
}
