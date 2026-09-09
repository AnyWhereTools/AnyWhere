import Foundation
import AnyWhereCore

final class ActionRunner: ActionRunning {
    private static let queue = DispatchQueue(label: "com.anywhere.action-runner", qos: .userInitiated)
    @MainActor private static var launcherTasks: [UUID: PluginTask] = [:]
    @MainActor @discardableResult static func cancelLauncherTasks(actionIDs: Set<UUID>? = nil) -> Bool {
        let tasks = launcherTasks.filter { actionIDs?.contains($0.key) ?? true }.map(\.value)
        for task in tasks { task.cancel() }
        return tasks.reduce(true) { $1.waitUntilFinished() && $0 }
    }

    @MainActor func runLauncher(entry: PluginLauncherEntry, invocation: PluginInvocation) {
        guard Self.launcherTasks[entry.id] == nil else {
            Notifier.showFailure(entry.definition.title, String(localized: "plugins.taskBusy")); return
        }
        let task = PluginTask(), extraEnv = Self.contractEnv()
        Self.launcherTasks[entry.id] = task
        DispatchQueue.global(qos: .userInitiated).async {
            let outcome: ExecutionOutcome
            do {
                guard let path = entry.definition.script else { throw PluginError(.failed, "No script declared.") }
                let script = try PluginResourceResolver.resolve(root: entry.directory, relativePath: path)
                let fields = entry.definition.settings
                let values = try PackConfiguration.store().load(actionID: entry.id, fields: fields)
                let env = extraEnv.merging(try PackSettings.environment(fields: fields, values: values)) { _, new in new }
                let secrets = fields.filter { $0.type == .password }.compactMap { values[$0.key] }
                let result = task.run(script: script, directory: entry.directory, invocation: invocation, input: .null,
                                      environment: env, secrets: secrets, timeout: TimeInterval(entry.definition.timeoutSeconds)) { _, _ in }
                if let error = result.error { outcome = .failure(message: error.message + "\n" + result.stderr) }
                else { outcome = .success(summary: result.stdout.split(separator: "\n").first.map(String.init)) }
            } catch { outcome = .failure(message: error.localizedDescription) }
            Task { @MainActor in
                Self.launcherTasks[entry.id] = nil
                ExecutionLog.shared.append(title: entry.definition.title, outcome: outcome)
                if case .failure(let message) = outcome { Notifier.showFailure(entry.definition.title, message) }
            }
        }
    }

    /// 执行环境契约的非选中相关部分(模板/数据目录 + 用户选的终端/编辑器)。
    /// 抽出来供真实执行与编辑器「试运行」共用,保证两者环境一致、不漂移。
    static func contractEnv() -> [String: String] {
        var env = ["ANYWHERE_TEMPLATES": AppPaths.templatesDirectory().path,
                   "ANYWHERE_DATA": AppPaths.dataDirectory().path]
        if let term = AppPrefs.terminalBundleID { env["ANYWHERE_TERMINAL"] = term }
        if let editor = AppPrefs.editorBundleID { env["ANYWHERE_EDITOR"] = editor }
        return env
    }

    /// cwd = 第一个选中项的所在文件夹(若它本身是文件夹,则取它自己),与 Finder 一致。
    static func workingDirectory(for urls: [URL]) -> URL? {
        urls.first.map { url in
            var isDir: ObjCBool = false
            FileManager.default.fileExists(atPath: url.path, isDirectory: &isDir)
            return isDir.boolValue ? url : url.deletingLastPathComponent()
        }
    }

    @MainActor
    func run(action: MenuAction, variant: String?, urls: [URL]) {
        run(action: action, variant: variant, urls: urls, invocation: nil)
    }

    @MainActor
    func run(action: MenuAction, variant: String?, urls: [URL], invocation: PluginInvocation?) {
        let title = action.title
        let kind = action.kind
        // Treat launcher input as one literal argument; never interpolate it into shell source.
        let paths = invocation.map { $0.argument.isEmpty ? [] : [$0.argument] } ?? urls.map(\.path)
        let cwd = Self.workingDirectory(for: urls)
        let scriptBase = AppPaths.configDirectory()
        var extraEnv = Self.contractEnv()
        extraEnv["ANYWHERE_FINDER_PATH"] = invocation?.finderPath ?? cwd?.path ?? FileManager.default.homeDirectoryForCurrentUser.path
        if let invocation {
            extraEnv["ANYWHERE_QUERY"] = invocation.query
            extraEnv["ANYWHERE_ARGUMENT"] = invocation.argument
        }
        let fields = AppState.shared.packManager.configurationFields(for: action)
        let actionID = action.id

        // 串行队列：保证动作按派发顺序执行（cut 必先于 paste 写完 cutbuffer），
        // 且不占用 Swift 协作线程池（ShellRunner 同步阻塞最长到 timeoutSeconds）。
        // 代价：队头阻塞——一个 60s 的转换会延后后续动作，对 v1 来说这种可预测性是可接受的。
        Self.queue.async {
            let outcome: ExecutionOutcome
            do {
                let values = fields.isEmpty ? [:] : try PackConfiguration.store().load(actionID: actionID, fields: fields)
                let configurationEnv = try PackSettings.environment(fields: fields, values: values)
                let secrets = fields.filter { $0.type == .password }.compactMap { values[$0.key] }
                outcome = Self.execute(kind: kind, variant: variant, paths: paths,
                                       scriptBase: scriptBase, cwd: cwd,
                                       extraEnv: extraEnv.merging(configurationEnv) { _, new in new },
                                       secrets: secrets)
            } catch {
                outcome = .failure(message: String(format: String(localized: "packConfig.executionError"), error.localizedDescription))
            }
            Task { @MainActor in
                ExecutionLog.shared.append(title: title, outcome: outcome)
                if case .failure(let message) = outcome { Notifier.showFailure(title, message) }
            }
        }
    }

    private static func execute(kind: MenuAction.Kind, variant: String?, paths: [String],
                                scriptBase: URL, cwd: URL?, extraEnv: [String: String], secrets: [String]) -> ExecutionOutcome {
        switch kind {
        case .openPluginUI:
            return .failure(message: "Open this plugin from its UI entry.")
        case .runScript(let spec):
            let r = ShellRunner.runScript(spec, paths: paths, variant: variant,
                                          scriptBase: scriptBase, cwd: cwd, extraEnv: extraEnv)
            if r.timedOut { return .failure(message: String(format: String(localized: "runtime.timeout"), spec.timeoutSeconds)) }
            if r.exitCode != 0 { return .failure(message: "exit \(r.exitCode): \(PackSettings.redacted(r.stderr, secrets: secrets))") }
            // stdout 首行作为成功摘要（脚本环境契约）
            let summary = PackSettings.redacted(r.stdout, secrets: secrets).split(separator: "\n").first.map(String.init)
            return .success(summary: summary)
        case .openWith(let bundleID):
            let r = ShellRunner.run("/usr/bin/open", ["-b", bundleID] + paths, timeout: 15)
            return r.exitCode == 0 ? .success(summary: nil) : .failure(message: r.stderr)
        }
    }
}
