import Foundation

/// Keeps a possible secret/UTF-8 suffix until the next pipe chunk arrives.
public struct PluginOutputFilter {
    private var pending = Data()
    private let secrets: [Data]
    public init(secrets: [String]) {
        self.secrets = secrets.filter { !$0.isEmpty }.map { Data($0.utf8) }.sorted { $0.count > $1.count }
    }
    public mutating func append(_ data: Data, final: Bool = false) -> String {
        pending.append(data)
        var output = Data()
        while !pending.isEmpty {
            if !final && (pending.count <= 3 || secrets.contains(where: { $0.starts(with: pending) })) { break }
            if let secret = secrets.first(where: { pending.starts(with: $0) }) {
                output.append(contentsOf: "••••".utf8)
                pending.removeFirst(secret.count)
            } else {
                let byte = pending.first!
                let length = byte < 0x80 ? 1 : byte < 0xE0 ? 2 : byte < 0xF0 ? 3 : 4
                if !final && pending.count < length { break }
                let count = min(length, pending.count)
                output.append(pending.prefix(count)); pending.removeFirst(count)
            }
        }
        return String(decoding: output, as: UTF8.self)
    }
}

public struct PluginTaskResult: Codable, Sendable {
    public let exitCode: Int32
    public let stdout: String
    public let stderr: String
    public let error: PluginError?
}

/// One managed process group. Call run on a worker queue; cancel is thread safe.
public final class PluginTask: @unchecked Sendable {
    public static let outputLimit = 4 * 1024 * 1024
    private let lock = NSLock()
    private let finished = DispatchGroup()
    private var reason: PluginError?
    public init() { finished.enter() }
    public func cancel() { stop(PluginError(.cancelled, "Task cancelled.")) }
    public func waitUntilFinished(timeout: TimeInterval = 5) -> Bool { finished.wait(timeout: .now() + timeout) == .success }
    private func stop(_ error: PluginError) {
        lock.lock(); defer { lock.unlock() }
        if reason == nil { reason = error }
    }
    private var failure: PluginError? { lock.lock(); defer { lock.unlock() }; return reason }

    public func run(script: URL, directory: URL, invocation: PluginInvocation, input: JSONValue,
                    environment: [String: String], secrets: [String], timeout: TimeInterval,
                    output: @escaping (String, String) -> Void) -> PluginTaskResult {
        defer { finished.leave() }
        let requestDirectory = FileManager.default.temporaryDirectory.appendingPathComponent("anywhere-task-\(UUID())")
        defer { try? FileManager.default.removeItem(at: requestDirectory) }
        let process = Process(), stdout = Pipe(), stderr = Pipe()
        let readers = DispatchQueue(label: "com.anywhere.plugin-output")
        var filters = ["stdout": PluginOutputFilter(secrets: secrets), "stderr": PluginOutputFilter(secrets: secrets)]
        var texts = ["stdout": "", "stderr": ""]
        var bytes = 0, accepting = true
        let drained = DispatchGroup()
        for (name, pipe) in [("stdout", stdout), ("stderr", stderr)] {
            drained.enter()
            pipe.fileHandleForReading.readabilityHandler = { handle in
                let chunk = handle.availableData
                if chunk.isEmpty { handle.readabilityHandler = nil; drained.leave(); return }
                readers.sync {
                    guard accepting else { return }
                    bytes += chunk.count
                    guard bytes <= Self.outputLimit else {
                        self.stop(PluginError(.outputLimit, "Task output exceeds 4 MiB.")); return
                    }
                    let text = filters[name]!.append(chunk)
                    texts[name]! += text
                    if !text.isEmpty { output(name, text) }
                }
            }
        }
        defer {
            stdout.fileHandleForReading.readabilityHandler = nil
            stderr.fileHandleForReading.readabilityHandler = nil
        }
        do {
            if let failure { throw failure }
            try FileManager.default.createDirectory(at: requestDirectory, withIntermediateDirectories: false,
                                                    attributes: [.posixPermissions: 0o700])
            let request = requestDirectory.appendingPathComponent("request.json")
            let context = try JSONDecoder().decode(JSONValue.self, from: JSONEncoder().encode(invocation))
            let data = try JSONEncoder().encode(JSONValue.object(["input": input, "invocation": context]))
            guard data.count <= 1024 * 1024 else { throw PluginError(.invalidArguments, "Request exceeds 1 MiB.") }
            try data.write(to: request, options: .atomic)
            try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: request.path)
            process.executableURL = URL(fileURLWithPath: "/bin/zsh")
            process.arguments = ["-lc", #"exec /bin/zsh "$ANYWHERE_SCRIPT" "$@""#, "anywhere"] + invocation.paths
            process.currentDirectoryURL = directory
            var env = ProcessInfo.processInfo.environment.merging(environment) { _, new in new }
            env["ANYWHERE_SCRIPT"] = script.path
            env["ANYWHERE_PATHS"] = invocation.paths.joined(separator: "\n")
            env["ANYWHERE_VARIANT"] = invocation.variant ?? ""
            env["ANYWHERE_REQUEST_FILE"] = request.path
            env["ANYWHERE_FINDER_PATH"] = invocation.finderPath
            process.environment = env
            process.standardInput = FileHandle.nullDevice
            process.standardOutput = stdout; process.standardError = stderr
            try process.run()
        } catch {
            return PluginTaskResult(exitCode: -1, stdout: "", stderr: "",
                                    error: error as? PluginError ?? PluginError(.failed, error.localizedDescription))
        }
        let pid = process.processIdentifier
        let group = getpgid(pid) == pid ? -pid : pid
        let deadline = DispatchTime.now() + max(0.1, min(timeout, 86400))
        var termination: DispatchTime?
        while process.isRunning {
            if DispatchTime.now() >= deadline { stop(PluginError(.timedOut, "Task timed out.")) }
            if failure != nil && termination == nil { kill(group, SIGTERM); termination = .now() + 2 }
            if let termination, DispatchTime.now() >= termination { kill(group, SIGKILL); break }
            Thread.sleep(forTimeInterval: 0.02)
        }
        process.waitUntilExit()
        // Managed tasks never keep descendants alive after their parent exits.
        if group < 0 { kill(group, SIGTERM) }
        let drainDeadline = termination ?? (.now() + 2)
        _ = drained.wait(timeout: drainDeadline)
        if group < 0 {
            while DispatchTime.now() < drainDeadline && kill(group, 0) == 0 { Thread.sleep(forTimeInterval: 0.02) }
            kill(group, SIGKILL)
        }
        return readers.sync {
            accepting = false
            for name in ["stdout", "stderr"] where failure?.code != .outputLimit {
                let tail = filters[name]!.append(Data(), final: true)
                texts[name]! += tail
                if !tail.isEmpty { output(name, tail) }
            }
            let code = process.terminationStatus + (process.terminationReason == .uncaughtSignal ? 128 : 0)
            return PluginTaskResult(exitCode: code, stdout: texts["stdout"]!, stderr: texts["stderr"]!,
                                    error: failure ?? (code == 0 ? nil : PluginError(.failed, "Task exited with code \(code).")))
        }
    }
}
