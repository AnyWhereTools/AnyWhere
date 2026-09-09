import AppKit
import SwiftUI
import Carbon
import AnyWhereCore

private final class LauncherPanel: NSPanel {
    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { false }
}

@MainActor
final class PluginLauncherController: NSObject, ObservableObject, NSWindowDelegate {
    static let shared = PluginLauncherController()
    private var window: NSWindow?
    private var hotKey: EventHotKeyRef?
    private var eventHandler: EventHandlerRef?
    private var actionHotKeys: [UUID: (binding: ActionHotKey, reference: EventHotKeyRef, eventID: UInt32)] = [:]
    private var nextActionEventID: UInt32 = 2
    @Published var query = ""
    @Published var selectedID: String?
    @Published private(set) var focusRequest = UUID()
    @Published var session: PluginSession?
    @Published private(set) var workflow: LauncherWorkflowEntry?
    @Published private(set) var workflowRunning = false
    @Published private(set) var workflowOutput = ""
    @Published private(set) var workflowStepIndex = 0
    private var workflowInput: JSONValue = .null
    private var workflowRun: LauncherWorkflowRun?
    private var workflowInvocation: PluginInvocation?
    private var executionID = UUID()
    private var retryAction: (() -> Void)?
    enum PanelState { case search, tool, workflowResult }
    var panelState: PanelState { session != nil ? .tool : workflow != nil ? .workflowResult : .search }
    @Published var error: String?
    @Published private(set) var shortcutLabel = "⌃⌥Space"
    private var resultCount = 0
    fileprivate var finderPath = FileManager.default.homeDirectoryForCurrentUser.path

    func start() {
        guard eventHandler == nil else { return }
        var type = EventTypeSpec(eventClass: OSType(kEventClassKeyboard), eventKind: UInt32(kEventHotKeyPressed))
        InstallEventHandler(GetApplicationEventTarget(), { _, event, _ in
            var identifier = EventHotKeyID()
            guard GetEventParameter(event, EventParamName(kEventParamDirectObject), EventParamType(typeEventHotKeyID), nil,
                                    MemoryLayout<EventHotKeyID>.size, nil, &identifier) == noErr,
                  identifier.signature == 0x4157504C else { return OSStatus(eventNotHandledErr) }
            let eventID = identifier.id
            Task { @MainActor in
                let controller = PluginLauncherController.shared
                if eventID == 1 { controller.toggle() }
                else if let id = controller.actionHotKeys.first(where: { $0.value.eventID == eventID })?.key {
                    controller.runUserAction(id)
                }
            }
            return noErr
        }, 1, &type, nil, &eventHandler)
        let prefs = UserDefaults.standard
        let key = prefs.object(forKey: "pluginShortcutKey") as? UInt32 ?? 49
        let modifiers = prefs.object(forKey: "pluginShortcutModifiers") as? UInt32 ?? UInt32(controlKey | optionKey)
        shortcutLabel = prefs.string(forKey: "pluginShortcutLabel") ?? "⌃⌥Space"
        if !prefs.bool(forKey: "pluginShortcutDisabled") { setShortcut(key: key, modifiers: modifiers, label: shortcutLabel) }
        reloadActionHotKeys()
    }
    func setShortcut(key: UInt32, modifiers: UInt32, label: String) {
        let prefs = UserDefaults.standard
        if hotKey != nil, prefs.object(forKey: "pluginShortcutKey") as? UInt32 == key,
           prefs.object(forKey: "pluginShortcutModifiers") as? UInt32 == modifiers { return }
        var candidate: EventHotKeyRef?
        let status = RegisterEventHotKey(key, modifiers, EventHotKeyID(signature: 0x4157504C, id: 1), GetApplicationEventTarget(), 0, &candidate)
        guard status == noErr else { error = String(localized: "plugins.shortcutConflict"); return }
        if let hotKey { UnregisterEventHotKey(hotKey) }
        hotKey = candidate; shortcutLabel = label; error = nil
        prefs.set(key, forKey: "pluginShortcutKey"); prefs.set(modifiers, forKey: "pluginShortcutModifiers")
        prefs.set(label, forKey: "pluginShortcutLabel"); prefs.set(false, forKey: "pluginShortcutDisabled")
    }
    func disableShortcut() {
        if let hotKey { UnregisterEventHotKey(hotKey) }; hotKey = nil
        UserDefaults.standard.set(true, forKey: "pluginShortcutDisabled"); objectWillChange.send()
    }
    func stop() {
        _ = ToolWorkspaceController.shared.close()
        back()
        if let hotKey { UnregisterEventHotKey(hotKey) }; hotKey = nil
        if let eventHandler { RemoveEventHandler(eventHandler) }; eventHandler = nil
        for value in actionHotKeys.values { UnregisterEventHotKey(value.reference) }
        actionHotKeys.removeAll()
    }

    func runUserAction(_ id: UUID, query: String = "", argument: String = "") {
        guard let action = AppState.shared.config.actions.first(where: { $0.id == id && $0.shortcutOnly == true && $0.isEnabled }) else { return }
        if window?.isKeyWindow != true { finderPath = FinderDirectory.currentPath() }
        try? AppState.shared.packManager.preferences.recordUse(actionID: id)
        retryAction = { [weak self] in self?.runUserAction(id, query: query, argument: argument) }
        let token = UUID(); executionID = token; error = nil
        ActionRunner().run(action: action, variant: nil, urls: [], invocation: PluginInvocation(
            actionID: id, source: .launcher, query: query, argument: argument, finderPath: finderPath)) { [weak self] outcome in
                guard let self, self.executionID == token else { return }
                if case .failure(let message) = outcome { self.error = message; self.show() }
            }
    }

    func setActionHotKey(_ binding: ActionHotKey?, actionID: UUID) throws {
        if let binding {
            let prefs = UserDefaults.standard
            let globalKey = prefs.object(forKey: "pluginShortcutKey") as? UInt32 ?? 49
            let globalModifiers = prefs.object(forKey: "pluginShortcutModifiers") as? UInt32 ?? UInt32(controlKey | optionKey)
            guard !(binding.key == globalKey && binding.modifiers == globalModifiers),
                  !AppState.shared.config.actions.contains(where: {
                      $0.id != actionID && $0.shortcutHotKey?.key == binding.key && $0.shortcutHotKey?.modifiers == binding.modifiers
                  }) else { throw PluginError(.failed, String(localized: "plugins.shortcutConflict")) }
            try registerActionHotKey(binding, actionID: actionID)
        } else if let previous = actionHotKeys.removeValue(forKey: actionID) {
            UnregisterEventHotKey(previous.reference)
        }
        AppState.shared.mutateConfig { config in
            if let i = config.actions.firstIndex(where: { $0.id == actionID }) { config.actions[i].shortcutHotKey = binding }
        }
    }

    private func registerActionHotKey(_ binding: ActionHotKey, actionID: UUID) throws {
        if actionHotKeys[actionID]?.binding == binding { return }
        var candidate: EventHotKeyRef?
        let eventID = nextActionEventID
        let status = RegisterEventHotKey(binding.key, binding.modifiers,
            EventHotKeyID(signature: 0x4157504C, id: eventID), GetApplicationEventTarget(), 0, &candidate)
        guard status == noErr, let candidate else { throw PluginError(.failed, String(localized: "plugins.shortcutConflict")) }
        nextActionEventID += 1
        if let previous = actionHotKeys[actionID] { UnregisterEventHotKey(previous.reference) }
        actionHotKeys[actionID] = (binding, candidate, eventID)
    }

    func reloadActionHotKeys() {
        guard eventHandler != nil else { return }
        let actions = AppState.shared.config.actions.filter { $0.shortcutOnly == true && $0.isEnabled && $0.shortcutHotKey != nil }
        for id in Array(actionHotKeys.keys) where !actions.contains(where: { $0.id == id }) {
            if let old = actionHotKeys.removeValue(forKey: id) { UnregisterEventHotKey(old.reference) }
        }
        for action in actions {
            do { try registerActionHotKey(action.shortcutHotKey!, actionID: action.id) }
            catch { self.error = error.localizedDescription }
        }
    }
    func hide() {
        back()
        guard panelState == .search else { return }
        window?.orderOut(nil)
        query = ""
        selectedID = nil
    }
    func toggle() { if window?.isVisible == true { hide() } else { show() } }
    func show() {
        if window?.isKeyWindow != true { finderPath = FinderDirectory.currentPath() }
        if window == nil {
            let w = LauncherPanel(contentRect: NSRect(x: 0, y: 0, width: 680, height: 74),
                                  styleMask: [.borderless], backing: .buffered, defer: false)
            w.title = String(localized: "plugins.title")
            w.identifier = NSUserInterfaceItemIdentifier("AnyWhere.launcher")
            w.isOpaque = false; w.backgroundColor = .clear; w.hasShadow = true
            w.level = .floating; w.isMovableByWindowBackground = true
            w.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
            window = w
            w.contentView = NSHostingView(rootView: PluginLauncherView(controller: self, manager: AppState.shared.packManager))
            w.isReleasedWhenClosed = false; w.delegate = self
        }
        if window?.isVisible != true, let window,
           let screen = NSScreen.screens.first(where: { $0.frame.contains(NSEvent.mouseLocation) }) {
            let area = screen.visibleFrame
            window.setFrameOrigin(NSPoint(x: area.midX - window.frame.width / 2,
                                          y: max(area.minY + 20, area.maxY - area.height * 0.22 - window.frame.height)))
        }
        updateLayout(resultCount: resultCount)
        focusRequest = UUID()
        // 搜索浮窗点击外部即隐藏；Finder 右键进入插件会话后必须保持可见。
        window?.hidesOnDeactivate = panelState == .search
        NSApp.activate(ignoringOtherApps: true); window?.makeKeyAndOrderFront(nil)
    }
    func updateLayout(resultCount: Int) {
        self.resultCount = resultCount
        guard let window else { return }
        let area = window.screen?.visibleFrame ?? NSScreen.main?.visibleFrame ?? window.frame
        let searchHeight: CGFloat = 74 + CGFloat(max(1, min(resultCount, 7))) * 64 + 66
        let height = min(CGFloat(session?.entry.definition.ui?.height ?? 460) + 56, area.height - 40)
        let size = NSSize(width: min(panelState == .search ? 680 : max(680, window.frame.width), area.width - 40),
                          height: min((panelState == .search ? searchHeight : height) + (error == nil ? 0 : 60), area.height - 40))
        window.minSize = panelState == .search ? NSSize(width: 420, height: 180) : NSSize(width: 520, height: 280)
        if panelState == .search { window.styleMask.remove(.resizable) } else { window.styleMask.insert(.resizable) }
        var frame = NSRect(x: window.frame.minX, y: window.frame.maxY - size.height, width: size.width, height: size.height)
        frame.origin.x = max(area.minX + 20, min(frame.origin.x, area.maxX - frame.width - 20))
        frame.origin.y = max(area.minY + 20, min(frame.origin.y, area.maxY - frame.height - 20))
        window.setFrame(frame, display: true)
        window.invalidateShadow()
    }
    func windowShouldClose(_ sender: NSWindow) -> Bool { hide(); return false }
    func back() {
        guard session?.close(waitForTask: true) ?? true, endWorkflow() else {
            error = String(localized: "plugins.taskStopFailed"); return
        }
        session = nil
        executionID = UUID(); retryAction = nil; error = nil
        window?.hidesOnDeactivate = true
        focusRequest = UUID()
        updateLayout(resultCount: resultCount)
    }
    func endSession(packKey: String, confirm: Bool = false) -> Bool {
        let embedded = session?.entry.action.packID == packKey || workflow?.pack.key == packKey
        let detached = ToolWorkspaceController.shared.windows.values.contains { $0.session.entry.action.packID == packKey }
        if confirm && (embedded || detached) && !confirmSwitch() { return false }
        guard ToolWorkspaceController.shared.close(packKey: packKey) else { return false }
        if workflow?.pack.key == packKey, !endWorkflow() { return false }
        if session?.entry.action.packID == packKey {
            guard session?.close(waitForTask: true) ?? true else { error = String(localized: "plugins.taskStopFailed"); return false }
            back()
        }
        return true
    }
    private func confirmSwitch() -> Bool {
        show()
        let alert = NSAlert()
        alert.messageText = String(localized: "plugins.switchTitle")
        alert.informativeText = String(localized: "plugins.switchBody")
        alert.addButton(withTitle: String(localized: "plugins.keep"))
        alert.addButton(withTitle: String(localized: "plugins.switch"))
        return alert.runModal() == .alertSecondButtonReturn
    }
    func open(_ entry: PluginLauncherEntry, invocation: PluginInvocation? = nil) {
        let context = invocation ?? PluginInvocation(actionID: entry.id, source: .launcher, query: query, finderPath: finderPath)
        let manager = AppState.shared.packManager
        guard let current = manager.launcherEntry(actionID: entry.id), current.definition == entry.definition else { return }
        let enabled = context.source == .finder ? current.action.isEnabled && current.definition.contextMenu
            : (try? manager.preferences.isEnabled(actionID: entry.id)) == true
        guard enabled else { return }
        if session?.entry.id == entry.id { show(); return }
        if (session != nil || workflowRunning) && !confirmSwitch() { return }
        back()
        guard panelState == .search else { return }
        do { try AppState.shared.packManager.preferences.recordUse(actionID: entry.id) }
        catch { self.error = error.localizedDescription }
        if entry.definition.ui == nil {
            let token = UUID(); executionID = token
            retryAction = { [weak self] in self?.open(entry, invocation: context) }
            ActionRunner().runLauncher(entry: entry, invocation: context) { [weak self] outcome in
                guard let self, self.executionID == token else { return }
                if case .failure(let message) = outcome { self.error = message; self.show() }
            }
        } else {
            session = PluginSession(entry: entry, invocation: context)
            session?.onBack = { [weak self] in self?.back() }
            show()
        }
    }
    func detachTool() {
        guard workflow == nil, let session else { return }
        hide()
        guard panelState == .search else { return }
        ToolWorkspaceController.shared.open(session.entry, invocation: session.invocation)
    }
    func openWorkflow(_ entry: LauncherWorkflowEntry, invocation: PluginInvocation? = nil) {
        let manager = AppState.shared.packManager
        guard (try? manager.preferences.isEnabled(actionID: entry.id)) == true,
              manager.workflowEntry(packKey: entry.pack.key, workflowID: entry.definition.id)?.pack.manifest == entry.pack.manifest else { return }
        if (session != nil || workflowRunning) && !confirmSwitch() { return }
        let context = invocation ?? PluginInvocation(actionID: entry.id, source: .launcher, query: query, finderPath: finderPath)
        back()
        guard panelState == .search else { return }
        try? manager.preferences.recordUse(actionID: entry.id)
        beginWorkflow(entry, invocation: context)
        show()
    }
    // Entry validation and switching are owned by openWorkflow; this starts an already accepted run.
    func beginWorkflow(_ entry: LauncherWorkflowEntry, invocation: PluginInvocation) {
        workflow = entry; workflowInvocation = invocation; workflowRunning = true; workflowOutput = ""
        workflowStepIndex = 0; workflowInput = .string(invocation.argument)
        advanceWorkflow()
    }
    private func advanceWorkflow() {
        guard let workflow, let invocation = workflowInvocation else { return }
        guard session?.close(waitForTask: true) ?? true else {
            finishWorkflow(.failure(PluginError(.failed, String(localized: "plugins.taskStopFailed")))); return
        }
        session = nil; error = nil
        guard workflowStepIndex < workflow.definition.steps.count else {
            finishWorkflow(.success(workflowInput)); return
        }
        let step = workflow.definition.steps[workflowStepIndex]
        guard let definition = workflow.pack.manifest.actions.first(where: { $0.id == step.action }) else {
            finishWorkflow(.failure(PluginError(.failed, "Workflow action not found: \(step.action)"))); return
        }
        let token = UUID(); executionID = token
        let accept: (Result<JSONValue, Error>) -> Void = { [weak self] result in
            guard let self, self.workflow != nil, self.workflowRunning, self.executionID == token else { return }
            self.workflowRun = nil
            switch result {
            case .success(let output):
                self.workflowInput = output; self.workflowStepIndex += 1; self.advanceWorkflow()
            case .failure: self.finishWorkflow(result)
            }
        }
        if definition.ui != nil && definition.script == nil {
            let id = PackManager.actionUUID(packKey: workflow.pack.key, packActionID: definition.id)
            let action = MenuAction(id: id, title: definition.title, icon: .symbol(definition.icon), kind: .openPluginUI,
                                    matching: MatchRule(), placement: .topLevel, packID: workflow.pack.key, isEnabled: true, sortOrder: 0)
            let entry = PluginLauncherEntry(id: id, action: action, definition: definition, directory: workflow.directory)
            let context = PluginInvocation(actionID: id, source: invocation.source, query: invocation.query,
                                           argument: invocation.argument, paths: invocation.paths, variant: invocation.variant, finderPath: invocation.finderPath)
            session = PluginSession(entry: entry, invocation: context, workflowInput: workflowInput) { accept(.success($0)) }
            session?.onBack = { [weak self] in self?.back() }
        } else {
            let entry = LauncherWorkflowEntry(pack: workflow.pack,
                definition: PackWorkflow(id: workflow.definition.id, title: workflow.definition.title, steps: [step]), directory: workflow.directory)
            workflowRun = ActionRunner().runWorkflow(entry: entry, invocation: invocation, input: workflowInput, completion: accept)
        }
        updateLayout(resultCount: resultCount)
    }
    private func finishWorkflow(_ result: Result<JSONValue, Error>) {
        workflowRunning = false; workflowRun = nil
        switch result {
        case .success(let value):
            if case .string(let text) = value { workflowOutput = text }
            else {
                let encoder = JSONEncoder(); encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
                workflowOutput = (try? encoder.encode(value)).flatMap { String(data: $0, encoding: .utf8) } ?? ""
            }
            ExecutionLog.shared.append(title: workflow?.definition.title ?? "", outcome: .success(summary: nil))
        case .failure(let failure):
            error = failure.localizedDescription
            ExecutionLog.shared.append(title: workflow?.definition.title ?? "", outcome: .failure(message: failure.localizedDescription))
        }
        updateLayout(resultCount: resultCount)
    }
    @discardableResult func endWorkflow(id: UUID? = nil) -> Bool {
        guard id == nil || workflow?.id == id else { return true }
        if workflow != nil {
            guard session?.close(waitForTask: true) ?? true else { return false }
            session = nil
        }
        guard workflowRun?.cancelAndWait() ?? true else { return false }
        if workflow != nil { error = nil }
        executionID = UUID(); workflowRun = nil; workflow = nil; workflowInvocation = nil
        workflowRunning = false; workflowOutput = ""
        workflowInput = .null; workflowStepIndex = 0
        updateLayout(resultCount: resultCount)
        return true
    }
    func retry() {
        if let workflow { openWorkflow(workflow, invocation: workflowInvocation) }
        else { retryAction?() }
    }
    func reload() {
        if workflow != nil, session != nil { advanceWorkflow(); return }
        guard let session else { return }
        let entry = session.entry, context = session.invocation
        back(); open(entry, invocation: PluginInvocation(actionID: context.actionID, source: context.source,
                                                       query: context.query, argument: context.argument, paths: context.paths,
                                                       variant: context.variant, finderPath: context.finderPath))
    }
    func validateSession(using manager: PackManager) {
        ToolWorkspaceController.shared.validate(using: manager)
        if let workflow {
            let current = manager.workflowEntry(packKey: workflow.pack.key, workflowID: workflow.definition.id)
            if current?.pack.manifest != workflow.pack.manifest || (try? manager.preferences.isEnabled(actionID: workflow.id)) != true {
                _ = endWorkflow()
            }
            return // Workflow enablement owns its steps; standalone tool toggles do not interrupt a run.
        }
        guard let session else { return }
        guard let current = manager.launcherEntry(actionID: session.entry.id), current.definition == session.entry.definition else { back(); return }
        let enabled = session.invocation.source == .finder ? current.action.isEnabled && current.definition.contextMenu
            : (try? manager.preferences.isEnabled(actionID: current.id)) == true
        if !enabled { back() }
    }
}

struct PluginLauncherView: View {
    @ObservedObject var controller: PluginLauncherController
    @ObservedObject var manager: PackManager
    @State private var catalog = LauncherCatalog()
    @State private var recent: [UUID] = []
    @State private var apps: [ApplicationSearchEntry] = []
    @State private var loadingApps = false

    private enum Result: Identifiable {
        case plugin(LauncherCatalog.Match), application(ApplicationSearchEntry)
        var id: String {
            switch self {
            case .plugin(let match): return match.entry.id.uuidString
            case .application(let app): return app.id
            }
        }
        var title: String {
            switch self {
            case .plugin(let match): return match.entry.search.title
            case .application(let app): return app.name
            }
        }
    }
    private var results: [Result] {
        let plugins = catalog.search(controller.query, recent: recent)
        return plugins.map(Result.plugin) + (hasQuery ? ApplicationSearch.matches(query: controller.query, apps: apps).map(Result.application) : [])
    }
    private var hasQuery: Bool { !controller.query.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }

    private func launch(_ id: String?) {
        guard let result = results.first(where: { $0.id == (id ?? results.first?.id) }) else { return }
        controller.selectedID = result.id
        switch result {
        case .plugin(let match):
            let invocation = PluginInvocation(actionID: match.entry.id, source: .launcher, query: controller.query,
                                              argument: match.argument, finderPath: controller.finderPath)
            switch match.entry.target {
            case .action(let action): controller.runUserAction(action.id, query: controller.query, argument: match.argument)
            case .plugin(let entry): controller.open(entry, invocation: invocation)
            case .workflow(let entry): controller.openWorkflow(entry, invocation: invocation)
            }
        case .application(let app):
            controller.hide()
            NSWorkspace.shared.openApplication(at: app.url, configuration: .init()) { _, error in
                Task { @MainActor in
                    if let error { controller.error = error.localizedDescription; controller.show() }
                    else { controller.query = "" }
                }
            }
        }
    }
    private func move(_ delta: Int) {
        guard !results.isEmpty else { return }
        let current = results.firstIndex { $0.id == controller.selectedID } ?? 0
        controller.selectedID = results[max(0, min(results.count - 1, current + delta))].id
    }
    var body: some View {
        VStack(spacing: 0) {
            if let workflow = controller.workflow {
                VStack(spacing: 0) {
                    HStack {
                        Button(String(localized: "plugins.back"), action: controller.back).keyboardShortcut(.escape, modifiers: [])
                        Text(workflow.definition.title).font(.headline)
                        Spacer()
                        if controller.session != nil { Button(String(localized: "plugins.reload"), action: controller.reload) }
                        else if controller.workflowRunning { ProgressView().controlSize(.small) }
                        else { Button(String(localized: "panel.retry"), action: controller.retry) }
                        Button { controller.hide() } label: { Image(systemName: "xmark") }
                            .accessibilityLabel(String(localized: "launcher.hide"))
                    }.padding(12)
                    Divider()
                    ScrollView(.horizontal) {
                        HStack(spacing: 12) {
                            ForEach(Array(workflow.definition.steps.enumerated()), id: \.offset) { index, step in
                                let title = workflow.pack.manifest.actions.first { $0.id == step.action }?.title ?? step.action
                                Label("\(index + 1). \(title)", systemImage: index < controller.workflowStepIndex ? "checkmark.circle.fill" :
                                        index == controller.workflowStepIndex ? "circle.inset.filled" : "circle")
                                    .foregroundStyle(index == controller.workflowStepIndex ? Color.accentColor : Color.secondary)
                            }
                        }.font(.caption).padding(.horizontal, 16).padding(.vertical, 8)
                    }
                    Divider()
                    if let session = controller.session {
                        if !session.closed { PluginWebView(session: session).id(session.id) }
                    } else {
                        ScrollView {
                            Text(controller.workflowRunning ? String(localized: "panel.running") :
                                 controller.workflowOutput.isEmpty ? String(localized: controller.error == nil ? "panel.finished" : "panel.failed") : controller.workflowOutput)
                                .font(.system(.body, design: .monospaced)).textSelection(.enabled)
                                .frame(maxWidth: .infinity, alignment: .leading).padding(16)
                        }
                    }
                    if let error = controller.error ?? controller.session?.error {
                        ScrollView {
                            Text(error).font(.callout).foregroundStyle(.red).textSelection(.enabled)
                                .frame(maxWidth: .infinity, alignment: .leading).padding(16)
                        }.frame(maxHeight: 160)
                    }
                }
            } else if let session = controller.session {
                PluginSessionView(session: session, onBack: controller.back, onReload: controller.reload,
                                  onClose: controller.hide, onDetach: controller.detachTool)
            } else {
                HStack(spacing: 16) {
                    Image(systemName: "magnifyingglass").font(.system(size: 26, weight: .regular)).foregroundStyle(.secondary)
                    PluginSearchField(text: $controller.query, focusRequest: controller.focusRequest,
                                      onSubmit: { launch(controller.selectedID) }, onMove: move,
                                      onEscape: { controller.hide() })
                        .frame(height: 34)
                    if !controller.query.isEmpty {
                        Button { controller.query = "" } label: {
                            Image(systemName: "xmark.circle.fill").foregroundStyle(.tertiary)
                        }.buttonStyle(.plain).accessibilityLabel(String(localized: "launcher.clear"))
                    }
                }.padding(.horizontal, 24).frame(height: 74)
                Group {
                    Divider().padding(.horizontal, 20)
                    HStack {
                        Text(String(localized: hasQuery ? "panel.results" : "panel.recent"))
                        Spacer()
                    }.font(.caption).foregroundStyle(.secondary).padding(.horizontal, 24).padding(.top, 8)
                    if results.isEmpty {
                        Text(String(localized: hasQuery ? (loadingApps ? "launcher.loadingApps" : "plugins.noMatches") : "panel.emptyRecent"))
                            .foregroundStyle(.secondary).frame(maxWidth: .infinity, maxHeight: .infinity)
                    } else {
                        ScrollViewReader { proxy in
                            ScrollView {
                                LazyVStack(spacing: 0) {
                                    ForEach(results) { result in
                                        resultRow(result).id(result.id)
                                    }
                                }.padding(.horizontal, 10).padding(.vertical, 6)
                            }
                            .onChange(of: controller.selectedID) { id in
                                if let id { proxy.scrollTo(id) }
                            }
                        }
                    }
                    HStack {
                        Text(String(localized: "launcher.footer"))
                        Spacer()
                        Text("AnyWhere")
                    }.font(.system(size: 11)).foregroundStyle(.tertiary)
                        .padding(.horizontal, 24).frame(height: 30)
                }
            }
            if controller.workflow == nil, let error = controller.error {
                HStack {
                    Text(error).font(.caption).foregroundStyle(.red).lineLimit(2).textSelection(.enabled)
                    Spacer()
                    if controller.workflow == nil {
                        Button(String(localized: "plugins.back"), action: controller.back)
                        Button(String(localized: "panel.retry"), action: controller.retry)
                    }
                }.padding(.horizontal, 20).frame(height: 60)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background {
            let shape = RoundedRectangle(cornerRadius: 24)
            if #available(macOS 26, *) {
                shape.fill(.clear).glassEffect(in: shape)
            } else {
                shape.fill(.regularMaterial)
            }
        }
        .clipShape(RoundedRectangle(cornerRadius: 24))
        .overlay(RoundedRectangle(cornerRadius: 24)
            .stroke(Color(nsColor: .separatorColor).opacity(0.5), lineWidth: 0.5))
        .onChange(of: controller.query) { _ in updateResults(resetSelection: true) }
        .onChange(of: controller.error) { _ in controller.updateLayout(resultCount: results.count) }
        .onReceive(manager.$packs) { _ in DispatchQueue.main.async { reloadEntries() } }
        .onReceive(AppState.shared.$config) { _ in DispatchQueue.main.async { reloadEntries() } }
        .task(id: controller.focusRequest) {
            reloadEntries()
            guard controller.panelState == .search else { return }
            loadingApps = true
            let discovered = await Task.detached(priority: .utility) {
                ApplicationSearch.discover(in: ApplicationSearch.directories)
            }.value
            guard !Task.isCancelled else { return }
            apps = discovered; loadingApps = false; updateResults()
        }
    }

    private func resultRow(_ result: Result) -> some View {
        Button { launch(result.id) } label: {
            HStack(spacing: 14) {
                switch result {
                case .plugin(let match):
                    Image(systemName: match.entry.icon).font(.system(size: 26)).frame(width: 38, height: 38)
                case .application(let app):
                    Image(nsImage: NSWorkspace.shared.icon(forFile: app.url.path)).resizable().frame(width: 38, height: 38)
                }
                VStack(alignment: .leading, spacing: 3) {
                    Text(result.title).font(.system(size: 18, weight: .medium)).lineLimit(1)
                    if case .plugin(let match) = result {
                        Text(match.argument.isEmpty ? match.entry.subtitle : match.argument)
                            .font(.caption).foregroundStyle(.secondary).lineLimit(1)
                    }
                }
                Spacer()
                if case .plugin(let match) = result {
                    Text(match.entry.kind).font(.caption).foregroundStyle(.secondary)
                }
                if result.id == controller.selectedID {
                    Text(String(localized: "launcher.open")).font(.caption).foregroundStyle(.secondary)
                    Text("↵").font(.system(size: 15)).padding(.horizontal, 7).padding(.vertical, 3)
                        .background(.quaternary, in: RoundedRectangle(cornerRadius: 5))
                }
            }
            .padding(.horizontal, 14).frame(height: 64)
            .background(result.id == controller.selectedID ? Color.primary.opacity(0.08) : Color.clear,
                        in: RoundedRectangle(cornerRadius: 15))
            .contentShape(Rectangle())
        }.buttonStyle(.plain).accessibilityLabel(result.title)
    }

    private func reloadEntries() {
        do {
            catalog = try manager.launcherCatalog()
            recent = try manager.preferences.recent()
            updateResults()
        } catch { controller.error = error.localizedDescription }
    }

    private func updateResults(resetSelection: Bool = false) {
        if resetSelection || !results.contains(where: { $0.id == controller.selectedID }) {
            controller.selectedID = results.first?.id
        }
        controller.updateLayout(resultCount: results.count)
    }
}

private struct PluginSearchField: NSViewRepresentable {
    @Binding var text: String
    let focusRequest: UUID
    let onSubmit: () -> Void
    let onMove: (Int) -> Void
    let onEscape: () -> Void
    func makeCoordinator() -> Coordinator { Coordinator(self) }
    func makeNSView(context: Context) -> NSTextField {
        let field = NSTextField()
        field.placeholderString = String(localized: "plugins.search")
        field.delegate = context.coordinator
        field.isBordered = false
        field.drawsBackground = false
        field.focusRingType = .none
        field.font = .systemFont(ofSize: 24)
        field.setAccessibilityLabel(String(localized: "plugins.search"))
        return field
    }
    func updateNSView(_ field: NSTextField, context: Context) {
        context.coordinator.parent = self
        if field.stringValue != text { field.stringValue = text }
        if context.coordinator.focusRequest != focusRequest {
            context.coordinator.focusRequest = focusRequest
            DispatchQueue.main.async { field.window?.makeFirstResponder(field); field.selectText(nil) }
        }
    }
    final class Coordinator: NSObject, NSTextFieldDelegate {
        var parent: PluginSearchField
        var focusRequest: UUID?
        init(_ parent: PluginSearchField) { self.parent = parent }
        func controlTextDidChange(_ notification: Notification) {
            parent.text = (notification.object as? NSTextField)?.stringValue ?? ""
        }
        func control(_ control: NSControl, textView: NSTextView, doCommandBy commandSelector: Selector) -> Bool {
            guard !textView.hasMarkedText() else { return false }
            switch commandSelector {
            case #selector(NSResponder.insertNewline(_:)): parent.onSubmit()
            case #selector(NSResponder.moveDown(_:)): parent.onMove(1)
            case #selector(NSResponder.moveUp(_:)): parent.onMove(-1)
            case #selector(NSResponder.cancelOperation(_:)): parent.onEscape()
            default: return false
            }
            return true
        }
    }
}

struct PluginSessionView: View {
    @ObservedObject var session: PluginSession
    let onBack: () -> Void
    let onReload: () -> Void
    let onClose: () -> Void
    var onDetach: (() -> Void)?
    var body: some View {
        VStack(spacing: 0) {
            if let onDetach {
                HStack {
                    Button(String(localized: "plugins.back"), action: onBack)
                        .keyboardShortcut(.escape, modifiers: [])
                    Text(session.entry.definition.title).font(.headline); Spacer()
                    Button(String(localized: "panel.detach"), action: onDetach)
                    Button(String(localized: "plugins.reload"), action: onReload)
                    Button(action: onClose) { Image(systemName: "xmark") }
                        .buttonStyle(.plain).accessibilityLabel(String(localized: "launcher.hide"))
                }.padding(12)
                Divider()
            }
            if let error = session.error { Text(error).font(.caption).foregroundStyle(.red).textSelection(.enabled).padding(8) }
            if !session.closed { PluginWebView(session: session).id(session.id) }
        }
    }
}

struct PluginShortcutSettings: View {
    @ObservedObject private var controller = PluginLauncherController.shared
    @AppStorage("pluginDeveloperMode") private var developerMode = false
    var body: some View {
        VStack(alignment: .leading) {
            HStack {
                Text(String(localized: "plugins.shortcut"))
                ShortcutRecorder(label: controller.shortcutLabel).frame(width: 160, height: 28)
                Button(String(localized: "plugins.disableShortcut")) { controller.disableShortcut() }
                if UserDefaults.standard.bool(forKey: "pluginShortcutDisabled") { Text(String(localized: "plugins.disabled")).foregroundStyle(.secondary) }
            }
            if let error = controller.error { Text(error).foregroundStyle(.red) }
            Toggle(String(localized: "plugins.developerMode"), isOn: $developerMode)
        }.padding(12)
    }
}
private struct ShortcutRecorder: NSViewRepresentable {
    let label: String
    func makeNSView(context: Context) -> Recorder { let button = Recorder(); button.bezelStyle = .rounded; button.target = button; button.action = #selector(Recorder.record); return button }
    func updateNSView(_ button: Recorder, context: Context) { if !button.recording { button.title = label } }
    final class Recorder: NSButton {
        var recording = false
        private var monitor: Any?
        override var acceptsFirstResponder: Bool { true }
        @objc func record() {
            guard !recording else { return }
            recording = true; title = String(localized: "plugins.pressShortcut"); window?.makeFirstResponder(self)
            monitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
                guard let self, self.recording else { return event }
                guard self.window?.isKeyWindow == true, self.window?.firstResponder === self else {
                    self.endRecording()
                    return event
                }
                self.keyDown(with: event)
                return nil
            }
        }
        override func viewWillMove(toWindow newWindow: NSWindow?) {
            if newWindow == nil { endRecording() }
            super.viewWillMove(toWindow: newWindow)
        }
        private func endRecording() {
            recording = false
            if let monitor { NSEvent.removeMonitor(monitor); self.monitor = nil }
            title = PluginLauncherController.shared.shortcutLabel
        }
        override func keyDown(with event: NSEvent) {
            guard recording else { super.keyDown(with: event); return }
            if event.keyCode == 53 { endRecording(); return }
            let flags = event.modifierFlags
            guard flags.contains(.control) || flags.contains(.option) || flags.contains(.command) else { return }
            var modifiers: UInt32 = 0, label = ""
            for (flag, carbon, symbol) in [(NSEvent.ModifierFlags.control, controlKey, "⌃"), (.option, optionKey, "⌥"), (.shift, shiftKey, "⇧"), (.command, cmdKey, "⌘")] {
                if flags.contains(flag) { modifiers |= UInt32(carbon); label += symbol }
            }
            label += event.keyCode == 49 ? "Space" : (event.charactersIgnoringModifiers ?? "").uppercased()
            PluginLauncherController.shared.setShortcut(key: UInt32(event.keyCode), modifiers: modifiers, label: label)
            endRecording()
        }
        deinit { if let monitor { NSEvent.removeMonitor(monitor) } }
    }
}
