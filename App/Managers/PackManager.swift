import Foundation
import CryptoKit
import AnyWhereCore

// MARK: - Public value types

/// 已安装扩展包的视图模型(由 installed.json + config 派生)。
struct InstalledPack: Identifiable, Equatable {
    var id: String { key }
    let key: String              // 安装目录名(owner-repo sanitize)
    let manifest: PackManifest
    let repoURL: String          // 克隆用完整 URL
    let repo: String             // owner/repo 显示
    let commitSHA: String        // 短 SHA
    let enabledCount: Int        // config 中 packID==key 且 isEnabled 的动作数
    let totalCount: Int          // config 中 packID==key 的动作数
    var isLocal = false
}

/// `clone` 的产物:已克隆到临时目录、解析+校验过的包,附每个动作脚本源码供审查。
/// 此阶段绝不执行任何脚本。
struct ClonedPack {
    let tempDir: URL
    let key: String
    let manifest: PackManifest
    let repoURL: String
    let repo: String             // owner/repo
    let commitSHA: String        // 短 SHA
    let scripts: [String: String]   // PackAction.id → 脚本源码(读不到则缺省)
    var extraFiles: [PackFile] = []  // manifest 未声明、需审查的文件(隐藏脚本/可执行/二进制)
    var isLocal = false
}

/// `checkUpdate` 结果:远端 HEAD 与本地 commitSHA 不同。
struct PackUpdateAvailable: Equatable {
    let key: String
    let currentSHA: String
    let remoteSHA: String
}

/// `cloneUpdate` 的产物:新克隆 + 与本地的逐文件 diff(本期为「按文件给出 old/new 全文 + 变更统计」)。
struct PackUpdate {
    let key: String
    let tempDir: URL
    let newManifest: PackManifest
    let newSHA: String
    let newRepoURL: String
    let newRepo: String
    let diffsByFile: [FileDiff]      // 脚本(相对路径)的新旧全文,UI 端渲染逐行
    let newScripts: [String: String] // 新动作脚本源码(审查用)

    struct FileDiff: Equatable {
        let path: String         // 相对仓库根
        let oldText: String?     // nil = 远端新增
        let newText: String?     // nil = 远端删除
        var isAdded: Bool { oldText == nil && newText != nil }
        var isRemoved: Bool { newText == nil && oldText != nil }
        var isModified: Bool { oldText != nil && newText != nil && oldText != newText }
        var isUnchanged: Bool { oldText == newText }
    }
}

struct PluginLauncherEntry: Identifiable {
    let id: UUID
    let action: MenuAction
    let definition: PackAction
    let directory: URL
}

// MARK: - PackManager

@MainActor
final class PackManager: ObservableObject {
    @Published private(set) var packs: [InstalledPack] = []
    let preferences = PluginPreferencesStore(directory: AppPaths.configDirectory())
    static func dataDirectory(_ key: String) -> URL {
        AppPaths.configDirectory().appendingPathComponent("PluginData", isDirectory: true).appendingPathComponent(key, isDirectory: true)
    }

    /// 注入点:默认用全局 AppState 单例,测试可替换。
    /// 默认参数避免引用 @MainActor 的 AppState.shared(默认参数在非隔离上下文求值);
    /// 传 nil 时由 appState() 在 @MainActor 调用点惰性解析。
    private let appStateOverride: (() -> AppState)?
    init(appState: (() -> AppState)? = nil) {
        self.appStateOverride = appState
    }
    private func appState() -> AppState { appStateOverride?() ?? AppState.shared }

    enum PackError: LocalizedError {
        case gitFailed(String)
        case noManifest
        case manifestInvalid(String)
        case packNotInstalled(String)
        case notAGitRepo
        case alreadyInstalled

        var errorDescription: String? {
            switch self {
            case .gitFailed(let m): return String(format: String(localized: "packs.errorGit"), m)
            case .noManifest: return String(localized: "packs.errorNoManifest")
            case .manifestInvalid(let m): return String(format: String(localized: "packs.errorManifest"), m)
            case .packNotInstalled(let k): return String(format: String(localized: "packs.errorPackNotFound"), k)
            case .notAGitRepo: return String(localized: "packs.errorNotAGitRepo")
            case .alreadyInstalled: return String(localized: "packs.errorAlreadyInstalled")
            }
        }
    }

    // MARK: Paths

    private static var packsRoot: URL {
        AppPaths.configDirectory().appendingPathComponent("Packs", isDirectory: true)
    }
    private static var installedFile: URL {
        packsRoot.appendingPathComponent("installed.json")
    }
    private static func packDir(_ key: String) -> URL {
        packsRoot.appendingPathComponent(key, isDirectory: true)
    }

    // MARK: - Reload (rebuild `packs` from installed.json + config)

    func reload() {
        let records = Self.loadInstalled()
        let actions = appState().config.actions
        packs = records.map { rec in
            let mine = actions.filter { $0.packID == rec.key }
            return InstalledPack(
                key: rec.key, manifest: rec.manifest, repoURL: rec.repoURL,
                repo: rec.repo, commitSHA: rec.commitSHA,
                enabledCount: mine.filter { $0.isEnabled || (try? preferences.isEnabled(actionID: $0.id)) == true }.count,
                totalCount: mine.count, isLocal: rec.isLocal == true)
        }
        .sorted { $0.manifest.name.localizedCaseInsensitiveCompare($1.manifest.name) == .orderedAscending }
        PluginLauncherController.shared.validateSession(using: self)
    }

    // MARK: - Import: step 1 — clone (NEVER executes scripts)

    func clone(_ urlOrShorthand: String) async throws -> ClonedPack {
        let repoURL = Self.normalizeRepoURL(urlOrShorthand)
        let repo = Self.repoDisplay(from: repoURL)
        let key = Self.sanitizeKey(repo)

        let tempDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("anywhere-pack-\(UUID().uuidString)", isDirectory: true)

        // git clone --depth 1 — pure fetch, no script execution.
        let clone = await Self.git(["clone", "--depth", "1", repoURL, tempDir.path], cwd: nil)
        guard clone.exitCode == 0 else {
            try? FileManager.default.removeItem(at: tempDir)
            throw PackError.gitFailed(clone.stderr.isEmpty ? clone.stdout : clone.stderr)
        }

        do {
            let (manifest, scripts) = try Self.readManifestAndScripts(in: tempDir)
            // 安全网:列出 manifest 之外的文件(脚本可经相对路径 source 它们),逼审查者看见隐藏的兄弟文件。
            let extras = PackInspector.undeclaredFiles(inDirectory: tempDir,
                                                       declared: Set(manifest.actions.compactMap(\.script)))
            let sha = await Self.shortHEAD(in: tempDir)
            return ClonedPack(tempDir: tempDir, key: key, manifest: manifest,
                              repoURL: repoURL, repo: repo, commitSHA: sha,
                              scripts: scripts, extraFiles: extras)
        } catch {
            try? FileManager.default.removeItem(at: tempDir)
            throw error
        }
    }

    // MARK: - Import: local folder snapshot (NEVER executes scripts)

    func prepareLocalDirectory(_ directory: URL) async throws -> ClonedPack {
        let source = directory.resolvingSymlinksInPath().standardizedFileURL
        let digest = SHA256.hash(data: Data(source.path.utf8))
            .map { String(format: "%02x", $0) }.joined()
        let key = "local-\(digest)"
        guard !Self.loadInstalled().contains(where: { $0.key == key }) else {
            throw PackError.alreadyInstalled
        }
        let snapshot: PackSnapshot
        do {
            snapshot = try await Task.detached(priority: .userInitiated) {
                try PackSnapshot.copyLocalDirectory(source)
            }.value
        } catch let error as PackSnapshot.ReadError {
            throw Self.mapReadError(error)
        }
        let extras = PackInspector.undeclaredFiles(inDirectory: snapshot.directory,
                                                  declared: Set(snapshot.manifest.actions.compactMap(\.script)))
        return ClonedPack(tempDir: snapshot.directory, key: key, manifest: snapshot.manifest,
                          repoURL: source.absoluteString, repo: source.lastPathComponent,
                          commitSHA: "", scripts: snapshot.scripts, extraFiles: extras, isLocal: true)
    }

    // MARK: - Import: step 2 — confirm (move into place, inject DISABLED actions)

    func confirmImport(_ cloned: ClonedPack) throws {
        // Check again at confirmation: another import may have completed during review.
        guard !Self.loadInstalled().contains(where: { $0.key == cloned.key }),
              !appState().config.actions.contains(where: { $0.packID == cloned.key }) else {
            throw PackError.alreadyInstalled
        }
        let fm = FileManager.default
        let dest = Self.packDir(cloned.key)

        // Move tempDir → Packs/<key>/ (replace if a stale dir exists).
        try fm.createDirectory(at: Self.packsRoot, withIntermediateDirectories: true)
        if fm.fileExists(atPath: dest.path) { try fm.removeItem(at: dest) }
        try fm.moveItem(at: cloned.tempDir, to: dest)

        // Inject actions into config — ALL disabled by default.
        var config = appState().config
        let baseOrder = (config.actions.map(\.sortOrder).max() ?? -1) + 1
        let newActions = cloned.manifest.actions.enumerated().map { offset, pa in
            Self.menuAction(from: pa, packKey: cloned.key, repo: cloned.repo,
                            packDir: dest, sortOrder: baseOrder + offset)
        }
        config.actions.append(contentsOf: newActions)
        let importedIDs = Set(newActions.map(\.id) + cloned.manifest.workflows.map { Self.workflowUUID(packKey: cloned.key, workflowID: $0.id) })
        try preferences.rememberActions(packKey: cloned.key, ids: importedIDs)
        for id in importedIDs { try preferences.setEnabled(false, actionID: id) }

        // Persist installed.json BEFORE update() so reload() sees the record.
        var records = Self.loadInstalled().filter { $0.key != cloned.key }
        records.append(InstalledRecord(key: cloned.key, repoURL: cloned.repoURL,
                                       repo: cloned.repo, commitSHA: cloned.commitSHA,
                                       manifest: cloned.manifest, isLocal: cloned.isLocal ? true : nil))
        try Self.saveInstalled(records)

        appState().update(config)
        reload()
    }

    // MARK: - Enable / disable a single pack action

    func configurationFields(for action: MenuAction) -> [PackSetting] {
        guard let key = action.packID,
              let pack = packs.first(where: { $0.key == key }),
              let definition = pack.manifest.actions.first(where: {
                  Self.actionUUID(packKey: key, packActionID: $0.id) == action.id
              }) else { return [] }
        return definition.settings
    }

    func launcherEntries(includeDisabled: Bool = false) -> [PluginLauncherEntry] {
        packs.flatMap { (pack: InstalledPack) -> [PluginLauncherEntry] in
            let directory = Self.packDir(pack.key)
            return pack.manifest.actions.compactMap { definition in
                guard definition.launcher != nil,
                      let action = appState().config.actions.first(where: {
                          $0.id == Self.actionUUID(packKey: pack.key, packActionID: definition.id)
                      }), includeDisabled || (try? preferences.isEnabled(actionID: action.id)) == true else { return nil }
                return PluginLauncherEntry(id: action.id, action: action, definition: definition, directory: directory)
            }
        }
    }

    func shortcutEntries(includeDisabled: Bool = false) throws -> [PluginSearchEntry] {
        let installed = try preferences.searchEntries(launcherEntries(includeDisabled: includeDisabled).map {
            PluginSearchEntry(id: $0.id, title: $0.definition.title, keywords: $0.definition.launcher?.keywords ?? [])
        })
        let local = appState().config.actions.filter { $0.shortcutOnly == true && (includeDisabled || $0.isEnabled) }
        let configured = try preferences.searchEntries(local.map { PluginSearchEntry(id: $0.id, title: $0.title, keywords: []) })
        return zip(local, configured).map { PluginSearchEntry(id: $0.0.id, title: $0.0.title, keywords: $0.1.keywords) } + installed
    }

    nonisolated static func workflowUUID(packKey: String, workflowID: String) -> UUID {
        actionUUID(packKey: "workflow:" + packKey, packActionID: workflowID)
    }

    func workflowEntry(packKey: String, workflowID: String) -> LauncherWorkflowEntry? {
        guard let pack = packs.first(where: { $0.key == packKey }),
              let definition = pack.manifest.workflows.first(where: { $0.id == workflowID }) else { return nil }
        return LauncherWorkflowEntry(pack: pack, definition: definition, directory: Self.packDir(packKey))
    }

    func launcherCatalog() throws -> LauncherCatalog {
        let shortcuts = try shortcutEntries()
        var entries = launcherEntries().compactMap { plugin -> LauncherEntry? in
            guard let search = shortcuts.first(where: { $0.id == plugin.id }) else { return nil }
            let pack = packs.first { $0.key == plugin.action.packID }
            return LauncherEntry(search: search, subtitle: pack?.manifest.description ?? pack?.manifest.name ?? "",
                                 target: .plugin(plugin))
        }
        entries += appState().config.actions.filter { $0.shortcutOnly == true && $0.isEnabled }.compactMap { action in
            guard let search = shortcuts.first(where: { $0.id == action.id }) else { return nil }
            return LauncherEntry(search: search, subtitle: "", target: .action(action))
        }
        for pack in packs {
            for definition in pack.manifest.workflows {
                guard let workflow = workflowEntry(packKey: pack.key, workflowID: definition.id),
                      try preferences.isEnabled(actionID: workflow.id) else { continue }
                entries.append(LauncherEntry(search: PluginSearchEntry(id: workflow.id, title: definition.title, keywords: []),
                                             subtitle: pack.manifest.description ?? pack.manifest.name, target: .workflow(workflow)))
            }
        }
        return LauncherCatalog(entries: entries)
    }

    func setWorkflowEnabled(_ enabled: Bool, packKey: String, workflowID: String) throws {
        guard let entry = workflowEntry(packKey: packKey, workflowID: workflowID) else { return }
        if !enabled, !PluginLauncherController.shared.endWorkflow(id: entry.id) {
            throw PluginError(.busy, String(localized: "plugins.taskStopFailed"))
        }
        try preferences.rememberActions(packKey: packKey, ids: [entry.id])
        try preferences.setEnabled(enabled, actionID: entry.id)
        reload()
    }

    func setShortcut(_ shortcut: PluginShortcut, actionID: UUID) throws {
        let defaults = try shortcutEntries(includeDisabled: true)
        try preferences.setShortcut(shortcut, actionID: actionID, defaults: defaults)
        reload()
    }

    func launcherEntry(actionID: UUID) -> PluginLauncherEntry? {
        for pack in packs {
            guard let definition = pack.manifest.actions.first(where: {
                Self.actionUUID(packKey: pack.key, packActionID: $0.id) == actionID
            }),
                  let action = appState().config.actions.first(where: { $0.id == actionID }) else { continue }
            return PluginLauncherEntry(id: actionID, action: action, definition: definition,
                                       directory: Self.packDir(pack.key))
        }
        return nil
    }

    func appearsInContextMenu(_ action: MenuAction) -> Bool {
        guard action.shortcutOnly != true else { return false }
        guard let key = action.packID,
              let pack = packs.first(where: { $0.key == key }),
              let definition = pack.manifest.actions.first(where: {
                  Self.actionUUID(packKey: key, packActionID: $0.id) == action.id
              }) else { return true }
        return definition.contextMenu
    }

    func setActionEnabled(_ enabled: Bool, actionID: UUID) {
        var config = appState().config
        guard let idx = config.actions.firstIndex(where: { $0.id == actionID }),
              config.actions[idx].packID != nil else { return }
        guard config.actions[idx].isEnabled != enabled else { return }
        if !enabled, PluginLauncherController.shared.session?.entry.id == actionID,
           PluginLauncherController.shared.session?.invocation.source == .finder {
            _ = PluginLauncherController.shared.endSession(packKey: config.actions[idx].packID!)
        }
        config.actions[idx].isEnabled = enabled
        appState().update(config)
        reload()
    }

    func setLauncherEnabled(_ enabled: Bool, actionID: UUID) throws {
        try preferences.setEnabled(enabled, actionID: actionID)
        if !enabled, let entry = launcherEntry(actionID: actionID), PluginLauncherController.shared.session?.entry.id == actionID,
           PluginLauncherController.shared.session?.invocation.source == .launcher {
            _ = PluginLauncherController.shared.endSession(packKey: entry.action.packID!)
        }
        reload()
    }

    // MARK: - Uninstall

    func uninstall(_ key: String, clearData: Bool = false) throws {
        guard PluginLauncherController.shared.endSession(packKey: key) else { throw PluginError(.busy, String(localized: "plugins.taskStopFailed")) }
        let currentIDs = Set(appState().config.actions.filter { $0.packID == key }.map(\.id) +
            (packs.first { $0.key == key }?.manifest.workflows.map { Self.workflowUUID(packKey: key, workflowID: $0.id) } ?? []))
        guard ActionRunner.cancelLauncherTasks(actionIDs: currentIDs) else { throw PluginError(.busy, String(localized: "plugins.taskStopFailed")) }
        try preferences.rememberActions(packKey: key, ids: currentIDs)
        if clearData {
            for id in try preferences.knownActions(packKey: key) { try PackConfiguration.store().remove(actionID: id) }
            try PluginDataStore(directory: Self.dataDirectory(key)).removeAll()
        }
        // Keep known IDs when retaining data, so a later uninstall can clear removed actions too.
        if clearData { try preferences.removePack(packKey: key) }
        else { for id in currentIDs { try preferences.setEnabled(false, actionID: id) } }
        var config = appState().config
        config.actions.removeAll { $0.packID == key }
        appState().update(config)

        let dir = Self.packDir(key)
        if FileManager.default.fileExists(atPath: dir.path) {
            try FileManager.default.removeItem(at: dir)
        }

        let records = Self.loadInstalled().filter { $0.key != key }
        try Self.saveInstalled(records)
        reload()
    }

    // MARK: - Update: check (compare remote HEAD SHA vs local)

    func checkUpdate(_ key: String) async -> PackUpdateAvailable? {
        guard let rec = Self.loadInstalled().first(where: { $0.key == key }) else { return nil }
        guard rec.isLocal != true else { return nil }
        // ls-remote avoids touching the working tree; compares the default-branch HEAD.
        let result = await Self.git(["ls-remote", rec.repoURL, "HEAD"], cwd: nil)
        guard result.exitCode == 0 else { return nil }
        let remoteFull = result.stdout.split(whereSeparator: { $0 == "\t" || $0 == " " }).first.map(String.init) ?? ""
        guard !remoteFull.isEmpty else { return nil }
        let remoteShort = String(remoteFull.prefix(rec.commitSHA.count))
        guard remoteShort != rec.commitSHA else { return nil }
        return PackUpdateAvailable(key: key, currentSHA: rec.commitSHA, remoteSHA: remoteShort)
    }

    // MARK: - Update: clone the new revision and diff against local

    func cloneUpdate(_ key: String) async throws -> PackUpdate {
        guard let rec = Self.loadInstalled().first(where: { $0.key == key }) else {
            throw PackError.packNotInstalled(key)
        }
        if rec.isLocal == true {
            guard let source = URL(string: rec.repoURL), source.isFileURL else { throw PackError.notAGitRepo }
            let snapshot = try await Task.detached { try PackSnapshot.copyLocalDirectory(source) }.value
            return PackUpdate(key: key, tempDir: snapshot.directory, newManifest: snapshot.manifest, newSHA: "",
                              newRepoURL: rec.repoURL, newRepo: rec.repo,
                              diffsByFile: Self.diffScripts(localDir: Self.packDir(key), localManifest: rec.manifest,
                                                           newDir: snapshot.directory, newManifest: snapshot.manifest), newScripts: snapshot.scripts)
        }
        let tempDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("anywhere-pack-update-\(UUID().uuidString)", isDirectory: true)
        let clone = await Self.git(["clone", "--depth", "1", rec.repoURL, tempDir.path], cwd: nil)
        guard clone.exitCode == 0 else {
            try? FileManager.default.removeItem(at: tempDir)
            throw PackError.gitFailed(clone.stderr.isEmpty ? clone.stdout : clone.stderr)
        }

        do {
            let (newManifest, newScripts) = try Self.readManifestAndScripts(in: tempDir)
            let newSHA = await Self.shortHEAD(in: tempDir)
            let diffs = Self.diffScripts(localDir: Self.packDir(key), localManifest: rec.manifest,
                                         newDir: tempDir, newManifest: newManifest)
            return PackUpdate(key: key, tempDir: tempDir, newManifest: newManifest, newSHA: newSHA,
                              newRepoURL: rec.repoURL, newRepo: rec.repo,
                              diffsByFile: diffs, newScripts: newScripts)
        } catch {
            try? FileManager.default.removeItem(at: tempDir)
            throw error
        }
    }

    // MARK: - Update: apply (preserve enabled state by PackAction.id)

    func applyUpdate(_ key: String, _ update: PackUpdate) throws {
        guard PluginLauncherController.shared.endSession(packKey: key, confirm: true) else {
            throw PluginError(.cancelled, String(localized: "plugins.updateCancelled"))
        }
        let currentIDs = Set(appState().config.actions.filter { $0.packID == key }.map(\.id) +
            (packs.first { $0.key == key }?.manifest.workflows.map { Self.workflowUUID(packKey: key, workflowID: $0.id) } ?? []))
        guard ActionRunner.cancelLauncherTasks(actionIDs: currentIDs) else { throw PluginError(.busy, String(localized: "plugins.taskStopFailed")) }
        let fm = FileManager.default
        let dest = Self.packDir(key)
        let oldManifest = packs.first { $0.key == key }?.manifest

        // Preserve which pack-action-ids were enabled (match by stable PackAction.id,
        // encoded into the deterministic UUID).
        var config = appState().config
        var enabledByPackActionID: [String: Bool] = [:]
        for action in config.actions where action.packID == key {
            if let paID = Self.packActionID(of: action, packKey: key, manifest: update.newManifest) {
                enabledByPackActionID[paID] = action.isEnabled
            }
        }

        // Swap working tree.
        try fm.createDirectory(at: Self.packsRoot, withIntermediateDirectories: true)
        let backup = Self.packsRoot.appendingPathComponent(".backup-\(UUID())")
        try fm.moveItem(at: dest, to: backup)
        do { try fm.moveItem(at: update.tempDir, to: dest) }
        catch { try fm.moveItem(at: backup, to: dest); throw error }

        // Rebuild this pack's actions from the new manifest:
        // - existing PackAction.id keeps its enabled state, new ones default disabled,
        // - removed remote actions drop out.
        config.actions.removeAll { $0.packID == key }
        let baseOrder = (config.actions.map(\.sortOrder).max() ?? -1) + 1
        let newActions = update.newManifest.actions.enumerated().map { offset, pa -> MenuAction in
            var a = Self.menuAction(from: pa, packKey: key, repo: update.newRepo,
                                    packDir: dest, sortOrder: baseOrder + offset)
            a.isEnabled = enabledByPackActionID[pa.id] ?? false
            let old = oldManifest?.actions.first { $0.id == pa.id }
            if !Set(pa.capabilities).isSubset(of: Set(old?.capabilities ?? [])) { a.isEnabled = false }
            return a
        }
        config.actions.append(contentsOf: newActions)
        do {
            try preferences.rememberActions(packKey: key, ids: currentIDs.union(newActions.map(\.id)))
            for definition in update.newManifest.actions {
                let old = oldManifest?.actions.first { $0.id == definition.id }
                if old == nil || !Set(definition.capabilities).isSubset(of: Set(old?.capabilities ?? [])) {
                    try preferences.setEnabled(false, actionID: Self.actionUUID(packKey: key, packActionID: definition.id))
                }
            }
            let workflowIDs = Set(update.newManifest.workflows.map { Self.workflowUUID(packKey: key, workflowID: $0.id) })
            try preferences.rememberActions(packKey: key, ids: workflowIDs)
            for workflow in update.newManifest.workflows {
                let changed = oldManifest?.workflows.first { $0.id == workflow.id } != workflow
                let increasedCapabilities = workflow.steps.contains { step in
                    let old = oldManifest?.actions.first { $0.id == step.action }
                    let new = update.newManifest.actions.first { $0.id == step.action }
                    return !Set(new?.capabilities ?? []).isSubset(of: Set(old?.capabilities ?? []))
                }
                if changed || increasedCapabilities {
                    try preferences.setEnabled(false, actionID: Self.workflowUUID(packKey: key, workflowID: workflow.id))
                }
            }

        // Update installed.json (new SHA + manifest snapshot).
        var records = Self.loadInstalled().filter { $0.key != key }
        records.append(InstalledRecord(key: key, repoURL: update.newRepoURL, repo: update.newRepo,
                                       commitSHA: update.newSHA, manifest: update.newManifest,
                                       isLocal: packs.first { $0.key == key }?.isLocal == true ? true : nil))
        try Self.saveInstalled(records)
        } catch {
            try fm.removeItem(at: dest); try fm.moveItem(at: backup, to: dest); throw error
        }
        try? fm.removeItem(at: backup)

        appState().update(config)
        reload()
    }

    /// Discard a clone/update temp dir without applying (UI cancel path).
    func discard(tempDir: URL) {
        try? FileManager.default.removeItem(at: tempDir)
    }

    // MARK: - Translation: PackAction → MenuAction

    /// Deterministic UUID for a pack action so enabled-state survives updates and
    /// snapshot rebuilds: derived from packKey + PackAction.id.
    nonisolated static func actionUUID(packKey: String, packActionID: String) -> UUID {
        PluginActionIdentity.uuid(packKey: packKey, actionID: packActionID)
    }

    /// Recover a MenuAction's originating PackAction.id by matching its deterministic UUID.
    private static func packActionID(of action: MenuAction, packKey: String,
                                     manifest: PackManifest) -> String? {
        for pa in manifest.actions where actionUUID(packKey: packKey, packActionID: pa.id) == action.id {
            return pa.id
        }
        return nil
    }

    private static func menuAction(from pa: PackAction, packKey: String, repo: String,
                                   packDir: URL, sortOrder: Int) -> MenuAction {
        // Absolute scriptPath into the installed pack dir (validate() already rejected `..`).
        let kind: MenuAction.Kind
        if pa.ui != nil {
            kind = .openPluginUI
        } else if let script = pa.script {
            let scriptAbs = packDir.appendingPathComponent(script).path
            kind = .runScript(ScriptSpec(scriptPath: scriptAbs, inlineSource: nil, timeoutSeconds: pa.timeoutSeconds))
        } else {
            kind = .openPluginUI
        }
        return MenuAction(
            id: actionUUID(packKey: packKey, packActionID: pa.id),
            title: pa.title,
            icon: .symbol(pa.icon),
            kind: kind,
            matching: pa.matching,
            placement: pa.placement,
            variants: pa.variants,
            presetKey: nil,
            packID: packKey,
            packRepo: repo,
            isEnabled: false,        // ALWAYS disabled on import.
            sortOrder: sortOrder)
    }

    // MARK: - Manifest + script reading

    private static func readManifestAndScripts(in dir: URL) throws -> (PackManifest, [String: String]) {
        do {
            let snapshot = try PackSnapshot.read(in: dir)
            return (snapshot.manifest, snapshot.scripts)
        } catch let error as PackSnapshot.ReadError {
            throw mapReadError(error)
        }
    }

    private static func mapReadError(_ error: PackSnapshot.ReadError) -> PackError {
        switch error {
        case .noManifest: return .noManifest
        case .invalidManifest(let detail): return .manifestInvalid(detail)
        }
    }

    private static func diffScripts(localDir: URL, localManifest: PackManifest,
                                    newDir: URL, newManifest: PackManifest) -> [PackUpdate.FileDiff] {
        // Union of script paths declared by old & new manifests.
        func paths(_ dir: URL, _ manifest: PackManifest) -> Set<String> {
            Set(manifest.actions.compactMap(\.script))
                .union(PackInspector.undeclaredFiles(inDirectory: dir, declared: []).map(\.relativePath))
                .union(["manifest.json"])
        }
        let oldPaths = paths(localDir, localManifest)
        let newPaths = paths(newDir, newManifest)
        let allPaths = oldPaths.union(newPaths).sorted()
        return allPaths.map { rel in
            let oldText = oldPaths.contains(rel)
                ? try? String(contentsOf: localDir.appendingPathComponent(rel), encoding: .utf8) : nil
            let newText = newPaths.contains(rel)
                ? try? String(contentsOf: newDir.appendingPathComponent(rel), encoding: .utf8) : nil
            func reviewed(_ text: String?, _ root: URL, _ exists: Bool) -> String? {
                guard exists else { return nil }
                if let text { return text }
                guard let file = try? PluginResourceResolver.resolve(root: root, relativePath: rel), let data = try? Data(contentsOf: file) else { return "[unreadable resource]" }
                return "[binary] SHA256: " + SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
            }
            return PackUpdate.FileDiff(path: rel, oldText: reviewed(oldText, localDir, oldPaths.contains(rel)), newText: reviewed(newText, newDir, newPaths.contains(rel)))
        }
    }

    private static func shortHEAD(in dir: URL) async -> String {
        let r = await git(["rev-parse", "--short", "HEAD"], cwd: dir)
        let sha = r.stdout.trimmingCharacters(in: .whitespacesAndNewlines)
        return sha.isEmpty ? "unknown" : sha
    }

    // MARK: - git helper (off the main actor; blocking ShellRunner)

    private static func git(_ args: [String], cwd: URL?) async -> ShellResult {
        await Task.detached(priority: .userInitiated) {
            ShellRunner.run("/usr/bin/git", args, cwd: cwd, timeout: 120)
        }.value
    }

    // MARK: - URL / key normalization

    /// `owner/repo` → `https://github.com/owner/repo.git`; https/git URLs pass through.
    static func normalizeRepoURL(_ input: String) -> String {
        let s = input.trimmingCharacters(in: .whitespacesAndNewlines)
        // 本地路径 / file:// 原样返回(供本地或私有包导入)。否则 "/a/b" 会被下面的
        // owner/repo 分支误判成 GitHub 仓库(正好两段)。
        if s.hasPrefix("/") || s.hasPrefix("file://") || s.hasPrefix("~") {
            return (s as NSString).expandingTildeInPath
        }
        if s.hasPrefix("http://") || s.hasPrefix("https://") || s.hasPrefix("git@") || s.hasPrefix("ssh://") {
            return s
        }
        // owner/repo shorthand (exactly one slash, no scheme).
        let parts = s.split(separator: "/")
        if parts.count == 2 {
            let owner = parts[0]
            var repo = parts[1]
            if repo.hasSuffix(".git") { repo = repo.dropLast(4) }
            return "https://github.com/\(owner)/\(repo).git"
        }
        return s
    }

    /// Extract `owner/repo` for display from a full URL or shorthand.
    static func repoDisplay(from urlOrShorthand: String) -> String {
        var s = urlOrShorthand.trimmingCharacters(in: .whitespacesAndNewlines)
        if s.hasSuffix(".git") { s = String(s.dropLast(4)) }
        // git@github.com:owner/repo
        if let range = s.range(of: ":"), s.hasPrefix("git@") {
            s = String(s[range.upperBound...])
        } else if let range = s.range(of: "://") {
            // strip scheme + host: keep last two path components.
            let afterScheme = String(s[range.upperBound...])
            let comps = afterScheme.split(separator: "/").map(String.init)
            if comps.count >= 3 { s = comps.suffix(2).joined(separator: "/") }
            else if comps.count == 2 { s = comps.joined(separator: "/") }
        }
        let comps = s.split(separator: "/").map(String.init)
        if comps.count >= 2 { return comps.suffix(2).joined(separator: "/") }
        return s
    }

    /// Filesystem-safe install key derived from owner/repo.
    static func sanitizeKey(_ repo: String) -> String {
        let allowed = CharacterSet.alphanumerics.union(CharacterSet(charactersIn: "-_."))
        let mapped = String(repo.unicodeScalars.map { allowed.contains($0) ? Character($0) : "-" })
        // collapse runs of "-" and trim, replace path separators (already mapped) ".." safety.
        var key = mapped.replacingOccurrences(of: "/", with: "-")
        while key.contains("--") { key = key.replacingOccurrences(of: "--", with: "-") }
        key = key.trimmingCharacters(in: CharacterSet(charactersIn: "-._"))
        return key.isEmpty ? "pack-\(abs(repo.hashValue))" : key
    }

    // MARK: - installed.json persistence

    /// Lock file record: enough to rebuild `packs` and run update checks offline.
    struct InstalledRecord: Codable, Equatable {
        let key: String
        let repoURL: String
        let repo: String
        let commitSHA: String
        let manifest: PackManifest
        // Optional for compatibility with existing Git pack records.
        var isLocal: Bool? = nil
    }

    private static func loadInstalled() -> [InstalledRecord] {
        guard let data = try? Data(contentsOf: installedFile) else { return [] }
        return (try? JSONDecoder().decode([InstalledRecord].self, from: data)) ?? []
    }

    private static func saveInstalled(_ records: [InstalledRecord]) throws {
        try FileManager.default.createDirectory(at: packsRoot, withIntermediateDirectories: true)
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        try encoder.encode(records).write(to: installedFile, options: .atomic)
    }
}
