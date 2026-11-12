import SwiftUI
import AppKit
import AnyWhereCore

// MARK: - ScreenPacks(扩展包 Tab 主屏)

struct ScreenPacks: View {
    @ObservedObject var packManager: PackManager

    // Sheet 路由
    @State private var selection: String?
    @State private var searchText = ""
    @State private var showImport = false
    @State private var showDiscover = false
    @State private var pendingImport: RepoToImport?
    @State private var updatingPack: InstalledPack?
    @State private var selectedUpdate: PackUpdateAvailable?
    @State private var scriptViewer: ScriptViewerTarget?

    var body: some View {
        content
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(AWColor.content)
        .onAppear { ensureSelection(); checkAll() }
        .onReceive(packManager.$packs) { _ in DispatchQueue.main.async { ensureSelection() } }
        .onChange(of: searchText) { _ in ensureSelection() }
        .sheet(isPresented: $showImport) {
            PackImportSheet(packManager: packManager) { showImport = false }
        }
        .sheet(item: $updatingPack) { pack in
            PackUpdateSheet(packManager: packManager, pack: pack, available: selectedUpdate) {
                updatingPack = nil
                selectedUpdate = nil
            }
        }
        .sheet(item: $scriptViewer) { target in
            ScriptViewerSheet(title: target.title, path: target.path, code: target.code) {
                scriptViewer = nil
            }
        }
        .sheet(isPresented: $showDiscover) {
            DiscoverPacksSheet(
                packManager: packManager,
                onImport: { entry in
                    showDiscover = false
                    // 顺序呈现两个 sheet:先关发现,再开导入(预填仓库,仍走完整审查)
                    DispatchQueue.main.asyncAfter(deadline: .now() + 0.35) {
                        pendingImport = RepoToImport(entry: entry)
                    }
                },
                onUpdate: { pack, update in
                    showDiscover = false
                    DispatchQueue.main.asyncAfter(deadline: .now() + 0.35) {
                        beginUpdate(pack, available: update)
                    }
                },
                onClose: { showDiscover = false })
        }
        .sheet(item: $pendingImport) { item in
            PackImportSheet(packManager: packManager, catalogEntry: item.entry) {
                pendingImport = nil
                packManager.reload()
            }
        }
    }

    private var filteredPacks: [InstalledPack] {
        let query = searchText.trimmingCharacters(in: .whitespacesAndNewlines)
        return packManager.packs.filter {
            query.isEmpty || $0.manifest.name.localizedStandardContains(query) || $0.repo.localizedStandardContains(query)
        }
    }

    private func ensureSelection() {
        if !filteredPacks.contains(where: { $0.key == selection }) { selection = filteredPacks.first?.key }
    }

    private var content: some View {
        HStack(spacing: 0) {
            VStack(alignment: .leading, spacing: 0) {
                VStack(alignment: .leading, spacing: 10) {
                    HStack {
                        Text(String(localized: "settings.tab.packs")).font(.system(size: 17, weight: .semibold))
                        Spacer()
                        Button(action: browse) { Image(systemName: "plus") }
                            .buttonStyle(.bordered).controlSize(.regular)
                            .accessibilityLabel("安装新插件")
                    }
                    Text("已安装的插件").font(.system(size: 12)).foregroundStyle(.secondary)
                    HStack(spacing: 6) {
                        Image(systemName: "magnifyingglass").foregroundStyle(.secondary)
                        TextField("搜索插件", text: $searchText)
                            .textFieldStyle(.plain).accessibilityLabel("搜索插件")
                        if !searchText.isEmpty {
                            Button { searchText = "" } label: { Image(systemName: "xmark.circle.fill") }
                                .buttonStyle(.plain).foregroundStyle(.secondary)
                                .accessibilityLabel(String(localized: "launcher.clear"))
                        }
                    }
                    .padding(8)
                    .background(Color.primary.opacity(0.04), in: RoundedRectangle(cornerRadius: 8))
                }
                .padding(18)
                List(filteredPacks, id: \.key, selection: $selection) { pack in
                    HStack(spacing: 10) {
                        PluginIconView(icon: pack.manifest.icon, directory: pack.directory, size: 32)
                        VStack(alignment: .leading, spacing: 3) {
                            Text(pack.manifest.name).fontWeight(.medium).lineLimit(1)
                            Text(String(format: String(localized: "packs.enabledCount"), pack.enabledCount, pack.totalCount))
                                .font(.system(size: 11)).foregroundStyle(.secondary)
                        }
                        Spacer(minLength: 0)
                        if packManager.updates[pack.key] != nil {
                            Circle().fill(Color.accentColor).frame(width: 6, height: 6)
                                .accessibilityLabel(String(localized: "packs.updateAvailable"))
                        }
                    }
                    .padding(.vertical, 5).padding(.horizontal, 4)
                    .listRowBackground(selection == pack.key ? Color.primary.opacity(0.06) : Color.clear)
                    .tag(pack.key)
                }
                .listStyle(.plain).scrollContentBackground(.hidden)
                .accessibilityIdentifier("packs.installed")
                Divider()
                VStack(alignment: .leading, spacing: 8) {
                    Button(String(localized: "packs.importPack")) { showImport = true }
                        .buttonStyle(.link)
                    HStack(spacing: 6) {
                        if packManager.checkingUpdates { ProgressView().controlSize(.small) }
                        Button(String(localized: "packs.checkAllUpdates"), action: checkAll)
                            .buttonStyle(.link).disabled(packManager.checkingUpdates)
                    }
                    Text(footerText).font(.system(size: 10)).foregroundStyle(.secondary)
                    if let error = packManager.updateCheckError {
                        Text(error).font(.caption).foregroundStyle(.red).textSelection(.enabled)
                    }
                }
                .padding(18)
            }
            .frame(width: 260)
            Divider()
            Group {
                if let pack = filteredPacks.first(where: { $0.key == selection }) {
                    ScrollView {
                        PackRow(
                            pack: pack,
                            update: packManager.updates[pack.key],
                            onSetEnabled: { packManager.setActionEnabled($0, actionID: $1) },
                            onViewScript: { viewScript(pack: pack, action: $0) },
                            onUpdate: { beginUpdate(pack, available: packManager.updates[pack.key]) },
                            onOpenRepo: { openRepo(pack) },
                            onUninstall: { uninstall(pack) }
                        )
                        .padding(20)
                    }
                    .id(pack.key)
                    .accessibilityIdentifier("packs.detail." + pack.key)
                } else if packManager.packs.isEmpty {
                    ScreenPacksEmpty(onImport: { showImport = true }, onBrowse: browse)
                } else {
                    Text("没有匹配的插件").foregroundStyle(.secondary)
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
    }

    private var footerText: String {
        let checked: String
        if let lastChecked = packManager.lastUpdateCheck {
            let f = DateFormatter()
            f.dateFormat = String(localized: "packs.lastCheckedFormatToday")
            if !Calendar.current.isDateInToday(lastChecked) {
                f.dateFormat = String(localized: "packs.lastCheckedFormatOther")
            }
            checked = f.string(from: lastChecked)
        } else {
            checked = String(localized: "packs.lastCheckedNever")
        }
        return String(format: String(localized: "packs.footerLastChecked"), checked)
    }

    // MARK: 行为

    private func browse() {
        showDiscover = true
    }

    private func openRepo(_ pack: InstalledPack) {
        if pack.isLocal, let url = URL(string: pack.repoURL), url.isFileURL {
            NSWorkspace.shared.open(url)
            return
        }
        // 优先用包记录的 repoURL;退化成 owner/repo 主页。
        let webURL: String
        if pack.repoURL.hasPrefix("http") {
            webURL = pack.repoURL.hasSuffix(".git") ? String(pack.repoURL.dropLast(4)) : pack.repoURL
        } else {
            webURL = "https://github.com/\(pack.repo)"
        }
        if let url = URL(string: webURL) { NSWorkspace.shared.open(url) }
    }

    private func uninstall(_ pack: InstalledPack) {
        let alert = NSAlert()
        alert.messageText = String(format: String(localized: "packs.uninstallConfirmTitle"), pack.manifest.name)
        alert.informativeText = String(format: String(localized: "packs.uninstallConfirmBody"), pack.totalCount)
        alert.alertStyle = .warning
        alert.addButton(withTitle: String(localized: "packs.uninstall"))
        alert.addButton(withTitle: String(localized: "packs.cancel"))
        let clear = NSButton(checkboxWithTitle: String(localized: "plugins.clearData"), target: nil, action: nil)
        alert.accessoryView = clear
        if alert.runModal() == .alertFirstButtonReturn {
            do {
                try packManager.uninstall(pack.key, clearData: clear.state == .on)
            } catch { NSAlert(error: error).runModal() }
        }
    }

    private func checkAll() {
        guard !packManager.checkingUpdates else { return }
        Task { await packManager.checkUpdates() }
    }

    private func beginUpdate(_ pack: InstalledPack, available: PackUpdateAvailable?) {
        selectedUpdate = available
        updatingPack = pack
    }

    private func viewScript(pack: InstalledPack, action: MenuAction) {
        guard case .runScript(let spec) = action.kind,
              let path = spec.scriptPath else { return }
        let code = (try? String(contentsOfFile: path, encoding: .utf8))
            ?? String(format: String(localized: "packs.scriptReadError"), path)
        // 显示相对仓库根的路径(去掉 packDir 前缀)更友好。
        let display = relativeScript(of: action, pack: pack) ?? path
        scriptViewer = ScriptViewerTarget(title: action.title, path: display, code: code)
    }

    private func relativeScript(of action: MenuAction, pack: InstalledPack) -> String? {
        // manifest 里 PackAction.script 即相对路径;按确定性 UUID 反查。
        for pa in pack.manifest.actions
        where PackManager.actionUUID(packKey: pack.key, packActionID: pa.id) == action.id {
            return pa.script
        }
        return nil
    }
}

struct ScriptViewerTarget: Identifiable {
    let id = UUID()
    let title: String
    let path: String
    let code: String
}

struct RepoToImport: Identifiable {
    let id = UUID()
    let entry: CatalogPack
}

// MARK: - PackRow(包信息 + 常驻操作)

struct PackRow: View {
    let pack: InstalledPack
    var update: PackUpdateAvailable?
    let onSetEnabled: (Bool, UUID) -> Void
    let onViewScript: (MenuAction) -> Void
    let onUpdate: () -> Void
    let onOpenRepo: () -> Void
    let onUninstall: () -> Void

    @ObservedObject private var state = AppState.shared
    @ObservedObject private var manager = AppState.shared.packManager
    @State private var configurationError: String?
    @AppStorage("pluginDeveloperMode") private var developerMode = false

    /// 该包的动作(按 sortOrder 稳定排序),用于动作列表 + 启停。
    private var actions: [MenuAction] {
        state.config.actions
            .filter { $0.packID == pack.key }
            .sorted { $0.sortOrder < $1.sortOrder }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            header
            Divider()
            controls
        }
    }

    private var header: some View {
        HStack(spacing: 10) {
            PluginIconView(icon: pack.manifest.icon, directory: pack.directory, size: 44)
            VStack(alignment: .leading, spacing: 1) {
                HStack(spacing: 7) {
                    Text(pack.manifest.name)
                        .font(.title2.weight(.semibold))
                        .foregroundStyle(AWColor.label)
                    if update != nil {
                        AWDot()
                        Badge(String(localized: "packs.updateAvailable"), tone: .accent)
                    }
                }
                Text("\(pack.repo) · \(pack.isLocal ? String(localized: "packs.localSource") : String(pack.commitSHA.prefix(12)))")
                    .lineLimit(1).truncationMode(.middle)
                    .font(.system(size: 11, design: .monospaced))
                    .foregroundStyle(AWColor.label2)
            }
            Spacer(minLength: 0)
            Text(String(format: String(localized: "packs.enabledCount"), pack.enabledCount, pack.totalCount))
                .font(.system(size: 12))
                .foregroundStyle(AWColor.label2)
            if update != nil {
                AWButton(String(localized: "packs.updateEllipsis"), systemImage: "arrow.down.circle",
                         kind: .primary, size: .sm, action: onUpdate)
            }
        }
    }

    private var controls: some View {
        VStack(alignment: .leading, spacing: 10) {
            // 动作小列表
            VStack(spacing: 0) {
                ForEach(Array(actions.enumerated()), id: \.element.id) { i, action in
                    if i > 0 { Rectangle().fill(AWColor.separator).frame(height: 0.5) }
                    HStack(spacing: 9) {
                        if manager.appearsInContextMenu(action) {
                        Text(String(localized: "plugins.contextMenu")).font(.caption)
                        AWSwitch(
                            Binding(get: { action.isEnabled },
                                    set: { onSetEnabled($0, action.id) }),
                            scale: 0.62)
                        }
                        if manager.launcherEntry(actionID: action.id)?.definition.launcher != nil {
                            Text("启用").font(.caption)
                            Toggle("启用插件功能", isOn: Binding(get: { (try? manager.preferences.isEnabled(actionID: action.id)) ?? false }, set: { enabled in
                                do { try manager.setLauncherEnabled(enabled, actionID: action.id); configurationError = nil }
                                catch { configurationError = error.localizedDescription }
                            })).labelsHidden().toggleStyle(.switch).controlSize(.mini)
                        }
                        Text(action.title)
                            .font(.system(size: 12.5))
                            .foregroundStyle(AWColor.label)
                        Spacer(minLength: 0)
                        if let entry = manager.launcherEntry(actionID: action.id) {
                            if entry.definition.launcher != nil {
                                AWButton("打开", systemImage: "arrow.up.forward.app", kind: .plain, size: .sm) {
                                    let invocation = PluginInvocation(actionID: entry.id, source: .launcher, finderPath: FinderDirectory.currentPath())
                                    PluginLauncherController.shared.open(entry, invocation: invocation, detached: true)
                                }
                                .disabled((try? manager.preferences.isEnabled(actionID: action.id)) != true)
                            }
                        }
                        if case .runScript = action.kind {
                            AWButton(String(localized: "packs.viewScript"), kind: .plain, size: .sm) { onViewScript(action) }
                        }
                    }
                    .padding(.horizontal, 12)
                    .padding(.vertical, 6)
                    if let entry = manager.launcherEntry(actionID: action.id) {
                        PluginSettingsView(manager: manager, entry: entry)
                            .id(action.id)
                            .padding(.vertical, 12)
                    }
                }
            }

            if !pack.manifest.workflows.isEmpty {
                VStack(alignment: .leading, spacing: 6) {
                    Text(String(localized: "panel.kind.workflow")).font(.caption).foregroundStyle(AWColor.label2)
                    ForEach(pack.manifest.workflows, id: \.id) { workflow in
                        HStack {
                            Image(systemName: "arrow.triangle.branch")
                            Text(workflow.title)
                            Spacer()
                            Toggle(String(localized: "shortcuts.enabled"), isOn: Binding(
                                get: { (try? manager.preferences.isEnabled(actionID: PackManager.workflowUUID(packKey: pack.key, workflowID: workflow.id))) == true },
                                set: { enabled in
                                    do { try manager.setWorkflowEnabled(enabled, packKey: pack.key, workflowID: workflow.id) }
                                    catch { configurationError = error.localizedDescription }
                                }))
                                .toggleStyle(.switch).controlSize(.small)
                            AWButton("运行", systemImage: "play.fill", kind: .plain, size: .sm) {
                                if let entry = manager.workflowEntry(packKey: pack.key, workflowID: workflow.id) {
                                    PluginLauncherController.shared.openWorkflow(entry)
                                }
                            }
                            .disabled((try? manager.preferences.isEnabled(actionID: PackManager.workflowUUID(packKey: pack.key, workflowID: workflow.id))) != true)
                        }
                        .padding(.horizontal, 12).padding(.vertical, 5)
                    }
                }
            }

            // 按钮行
            if let configurationError { Text(configurationError).foregroundStyle(.red).font(.caption) }
            HStack(spacing: 8) {
                if pack.isLocal && developerMode {
                    AWButton(String(localized: "plugins.reloadLocal"), size: .sm, action: onUpdate)
                }
                AWButton(pack.isLocal ? String(localized: "packs.openLocalFolder") : String(localized: "packs.openRepoHome"),
                         systemImage: pack.isLocal ? "folder" : "arrow.up.right.square",
                         size: .sm, action: onOpenRepo)
                Spacer(minLength: 0)
                AWButton(String(localized: "packs.uninstallEllipsis"), systemImage: "trash", kind: .danger, size: .sm, action: onUninstall)
            }
        }
    }
}

// MARK: - ScreenPacksEmpty(空态)

struct ScreenPacksEmpty: View {
    let onImport: () -> Void
    let onBrowse: () -> Void

    var body: some View {
        VStack(spacing: 16) {
            ZStack {
                RoundedRectangle(cornerRadius: 22, style: .continuous)
                    .fill(AWColor.accentTint)
                    .frame(width: 96, height: 96)
                Image(systemName: "shippingbox")
                    .font(.system(size: 50, weight: .light))
                    .foregroundStyle(AWColor.accent)
            }
            VStack(spacing: 6) {
                Text(String(localized: "packs.emptyTitle"))
                    .font(.system(size: 17, weight: .semibold))
                Text(String(localized: "packs.emptyBody"))
                    .font(.system(size: 12.5))
                    .foregroundStyle(AWColor.label2)
                    .multilineTextAlignment(.center)
                    .lineSpacing(2.5)
                    .frame(maxWidth: 360)
            }
            HStack(spacing: 10) {
                AWButton("安装新插件", systemImage: "plus", kind: .primary, action: onBrowse)
                AWButton(String(localized: "packs.importPack"), systemImage: "square.and.arrow.down", action: onImport)
            }
            .padding(.top, 2)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .padding(30)
    }
}
