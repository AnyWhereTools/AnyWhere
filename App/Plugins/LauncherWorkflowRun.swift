import Foundation
import AnyWhereCore

/// Owns the process currently running in a sequential workflow, including cancellation between steps.
final class LauncherWorkflowRun: @unchecked Sendable {
    private let lock = NSLock()
    private let finished = DispatchGroup()
    private var cancelled = false
    private var task: PluginTask?

    init() { finished.enter() }

    @discardableResult func cancelAndWait() -> Bool {
        lock.lock()
        cancelled = true
        task?.cancel()
        lock.unlock()
        return finished.wait(timeout: .now() + 5) == .success
    }

    func run(entry: LauncherWorkflowEntry, invocation: PluginInvocation, input: JSONValue,
             environment: [String: String]) -> Result<JSONValue, Error> {
        defer { finished.leave() }
        return Result {
            try WorkflowExecutor.run(entry.definition, in: entry.pack.manifest, step: { definition, input in
                guard let path = definition.script else {
                    throw PluginError(.failed, "Workflow step requires a script: \(definition.title)")
                }
                let script = try PluginResourceResolver.resolve(root: entry.directory, relativePath: path)
                let id = PackManager.actionUUID(packKey: entry.pack.key, packActionID: definition.id)
                let values = try PackConfiguration.store().load(actionID: id, fields: definition.settings)
                let env = environment.merging(try PackSettings.environment(fields: definition.settings, values: values)) { _, new in new }
                let secrets = definition.settings.filter { $0.type == .password }.compactMap { values[$0.key] }
                let running = PluginTask()
                lock.lock()
                if cancelled { lock.unlock(); throw PluginError(.cancelled, "Workflow cancelled.") }
                task = running
                lock.unlock()
                let context = PluginInvocation(actionID: id, source: invocation.source, query: invocation.query,
                                               argument: invocation.argument, paths: invocation.paths,
                                               variant: invocation.variant, finderPath: invocation.finderPath)
                let result = running.run(script: script, directory: entry.directory, invocation: context, input: input,
                                         environment: env, secrets: secrets, timeout: TimeInterval(definition.timeoutSeconds)) { _, _ in }
                if let error = result.error {
                    throw PluginError(error.code, definition.title + ": " + error.message + "\n" + result.stderr)
                }
                return (try? JSONDecoder().decode(JSONValue.self, from: Data(result.stdout.utf8))) ?? .string(result.stdout)
            }, input: input)
        }
    }
}
