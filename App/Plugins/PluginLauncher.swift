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
        _ = session?.close(waitForTask: true)
        back()
        if let hotKey { UnregisterEventHotKey(hotKey) }; hotKey = nil
        if let eventHandler { RemoveEventHandler(eventHandler) }; eventHandler = nil
        for value in actionHotKeys.values { UnregisterEventHotKey(value.reference) }
        actionHotKeys.removeAll()
    }

    func runUserAction(_ id: UUID, query: String = "", argument: String = "") {
        guard let action = AppState.shared.config.actions.first(where: { $0.id == id && $0.shortcutOnly == true && $0.isEnabled }) else { return }
        if window?.isKeyWindow != true { finderPath = FinderDirectory.currentPath() }
        ActionRunner().run(action: action, variant: nil, urls: [], invocation: PluginInvocation(
            actionID: id, source: .launcher, query: query, argument: argument, finderPath: finderPath))
        hide()
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
        window?.hidesOnDeactivate = session == nil
        NSApp.activate(ignoringOtherApps: true); window?.makeKeyAndOrderFront(nil)
    }
    func updateLayout(resultCount: Int) {
        self.resultCount = resultCount
        guard let window else { return }
        let area = window.screen?.visibleFrame ?? NSScreen.main?.visibleFrame ?? window.frame
        let hasQuery = !query.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        let searchHeight: CGFloat = hasQuery ? 74 + CGFloat(max(1, min(resultCount, 7))) * 64 + 44 : 74
        let height = min(CGFloat(session?.entry.definition.ui?.height ?? 460) + 56, area.height - 40)
        let size = NSSize(width: min(session == nil ? 680 : max(680, window.frame.width), area.width - 40),
                          height: min((session == nil ? searchHeight : height) + (error == nil ? 0 : 44), area.height - 40))
        window.minSize = session == nil ? NSSize(width: 420, height: 74) : NSSize(width: 520, height: 280)
        if session == nil { window.styleMask.remove(.resizable) } else { window.styleMask.insert(.resizable) }
        var frame = NSRect(x: window.frame.minX, y: window.frame.maxY - size.height, width: size.width, height: size.height)
        frame.origin.x = max(area.minX + 20, min(frame.origin.x, area.maxX - frame.width - 20))
        frame.origin.y = max(area.minY + 20, min(frame.origin.y, area.maxY - frame.height - 20))
        window.setFrame(frame, display: true)
        window.invalidateShadow()
    }
    func windowShouldClose(_ sender: NSWindow) -> Bool { hide(); return false }
    func back() {
        session?.close(); session = nil
        focusRequest = UUID()
        updateLayout(resultCount: resultCount)
    }
    func endSession(packKey: String, confirm: Bool = false) -> Bool {
        guard session?.entry.action.packID == packKey else { return true }
        if confirm && !confirmSwitch() { return false }
        guard session?.close(waitForTask: true) ?? true else { error = String(localized: "plugins.taskStopFailed"); return false }
        back(); return true
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
        if session != nil && !confirmSwitch() { return }
        back()
        let context = invocation ?? PluginInvocation(actionID: entry.id, source: .launcher, query: query, finderPath: finderPath)
        do { try AppState.shared.packManager.preferences.recordUse(actionID: entry.id) }
        catch { self.error = error.localizedDescription }
        if entry.definition.ui == nil {
            ActionRunner().runLauncher(entry: entry, invocation: context)
        } else {
            session = PluginSession(entry: entry, invocation: context)
            show()
        }
    }
    func reload() {
        guard let session else { return }
        let entry = session.entry, context = session.invocation
        back(); open(entry, invocation: PluginInvocation(actionID: context.actionID, source: context.source,
                                                       query: context.query, argument: context.argument, paths: context.paths,
                                                       variant: context.variant, finderPath: context.finderPath))
    }
    func validateSession(using manager: PackManager) {
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
    @State private var entries: [PluginSearchEntry] = []
    @State private var recent: [UUID] = []

    private enum Result: Identifiable {
        case plugin(PluginSearchMatch)
        var id: String {
            switch self {
            case .plugin(let match): return match.entry.id.uuidString
            }
        }
        var title: String {
            switch self {
            case .plugin(let match): return match.entry.title
            }
        }
    }
    private var results: [Result] {
        let plugins = PluginSearch.matches(query: controller.query, entries: entries, recent: recent, keywordsOnly: true)
        return plugins.map(Result.plugin)
    }
    private var hasQuery: Bool { !controller.query.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }

    private func launch(_ id: String?) {
        guard let result = results.first(where: { $0.id == (id ?? results.first?.id) }) else { return }
        controller.selectedID = result.id
        switch result {
        case .plugin(let match):
            if AppState.shared.config.actions.contains(where: { $0.id == match.entry.id && $0.shortcutOnly == true }) {
                controller.runUserAction(match.entry.id, query: controller.query, argument: match.argument)
                return
            }
            guard let entry = manager.launcherEntries().first(where: { $0.id == match.entry.id }) else { reloadEntries(); return }
            controller.open(entry, invocation: PluginInvocation(actionID: entry.id, source: .launcher,
                                                               query: controller.query, argument: match.argument,
                                                               finderPath: controller.finderPath))
        }
    }
    private func move(_ delta: Int) {
        guard !results.isEmpty else { return }
        let current = results.firstIndex { $0.id == controller.selectedID } ?? 0
        controller.selectedID = results[max(0, min(results.count - 1, current + delta))].id
    }
    var body: some View {
        VStack(spacing: 0) {
            if let session = controller.session {
                PluginSessionView(session: session, controller: controller)
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
                if hasQuery {
                    Divider().padding(.horizontal, 20)
                    if results.isEmpty {
                        Text(String(localized: "plugins.noMatches"))
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
            if let error = controller.error {
                Text(error).font(.caption).foregroundStyle(.red).lineLimit(2).padding(.horizontal, 20).frame(height: 44)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background {
            let shape = RoundedRectangle(cornerRadius: hasQuery || controller.session != nil ? 24 : 37)
            if #available(macOS 26, *) {
                shape.fill(.clear).glassEffect(in: shape)
            } else {
                shape.fill(.regularMaterial)
            }
        }
        .clipShape(RoundedRectangle(cornerRadius: hasQuery || controller.session != nil ? 24 : 37))
        .overlay(RoundedRectangle(cornerRadius: hasQuery || controller.session != nil ? 24 : 37)
            .stroke(Color(nsColor: .separatorColor).opacity(0.5), lineWidth: 0.5))
        .onChange(of: controller.query) { _ in updateResults() }
        .onChange(of: controller.error) { _ in controller.updateLayout(resultCount: results.count) }
        .onReceive(manager.$packs) { _ in DispatchQueue.main.async { reloadEntries() } }
        .task(id: controller.focusRequest) {
            reloadEntries()
            guard controller.session == nil else { return }
        }
    }

    private func resultRow(_ result: Result) -> some View {
        Button { launch(result.id) } label: {
            HStack(spacing: 14) {
                switch result {
                case .plugin(let match):
                    if let action = AppState.shared.config.actions.first(where: { $0.id == match.entry.id }) {
                        ActionIconView(icon: action.icon, size: 38)
                    }
                }
                VStack(alignment: .leading, spacing: 3) {
                    Text(result.title).font(.system(size: 18, weight: .medium)).lineLimit(1)
                    if case .plugin(let match) = result {
                        Text(match.argument.isEmpty ? match.entry.keywords.joined(separator: " · ") : match.argument)
                            .font(.caption).foregroundStyle(.secondary).lineLimit(1)
                    }
                }
                Spacer()
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
            entries = try manager.shortcutEntries()
            recent = try manager.preferences.recent()
            updateResults()
        } catch { controller.error = error.localizedDescription }
    }

    private func updateResults() {
        if !results.contains(where: { $0.id == controller.selectedID }) || controller.session == nil {
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

private struct PluginSessionView: View {
    @ObservedObject var session: PluginSession
    @ObservedObject var controller: PluginLauncherController
    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Button(String(localized: "plugins.back")) { controller.back() }
                Text(session.entry.definition.title).font(.headline); Spacer()
                Button(String(localized: "plugins.reload")) { controller.reload() }
                Button { controller.hide() } label: { Image(systemName: "xmark") }
                    .buttonStyle(.plain).accessibilityLabel(String(localized: "launcher.hide"))
            }.padding(12)
            if let error = session.error { Text(error).font(.caption).foregroundStyle(.red).textSelection(.enabled).padding(8) }
            Divider(); PluginWebView(session: session).id(session.id)
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
