import AppKit
import SwiftUI
import Carbon
import AnyWhereCore

@MainActor
final class PluginLauncherController: NSObject, ObservableObject, NSWindowDelegate {
    static let shared = PluginLauncherController()
    private var window: NSWindow?
    private var hotKey: EventHotKeyRef?
    private var eventHandler: EventHandlerRef?
    @Published var query = ""
    @Published var selectedID: UUID?
    @Published var session: PluginSession?
    @Published var error: String?
    @Published private(set) var shortcutLabel = "⌃⌥Space"

    func start() {
        guard eventHandler == nil else { return }
        var type = EventTypeSpec(eventClass: OSType(kEventClassKeyboard), eventKind: UInt32(kEventHotKeyPressed))
        InstallEventHandler(GetApplicationEventTarget(), { _, event, _ in
            var identifier = EventHotKeyID()
            guard GetEventParameter(event, EventParamName(kEventParamDirectObject), EventParamType(typeEventHotKeyID), nil,
                                    MemoryLayout<EventHotKeyID>.size, nil, &identifier) == noErr,
                  identifier.signature == 0x4157504C else { return OSStatus(eventNotHandledErr) }
            Task { @MainActor in PluginLauncherController.shared.toggle() }; return noErr
        }, 1, &type, nil, &eventHandler)
        let prefs = UserDefaults.standard
        let key = prefs.object(forKey: "pluginShortcutKey") as? UInt32 ?? 49
        let modifiers = prefs.object(forKey: "pluginShortcutModifiers") as? UInt32 ?? UInt32(controlKey | optionKey)
        shortcutLabel = prefs.string(forKey: "pluginShortcutLabel") ?? "⌃⌥Space"
        if !prefs.bool(forKey: "pluginShortcutDisabled") { setShortcut(key: key, modifiers: modifiers, label: shortcutLabel) }
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
    }
    func toggle() { if window?.isKeyWindow == true { window?.orderOut(nil) } else { show() } }
    func show() {
        if window == nil {
            let w = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 640, height: 480),
                             styleMask: [.titled, .closable, .resizable], backing: .buffered, defer: false)
            w.title = String(localized: "plugins.title")
            w.contentView = NSHostingView(rootView: PluginLauncherView(controller: self, manager: AppState.shared.packManager))
            w.isReleasedWhenClosed = false; w.delegate = self
            if let screen = NSScreen.screens.first(where: { $0.frame.contains(NSEvent.mouseLocation) }) {
                let area = screen.visibleFrame
                w.setFrameOrigin(NSPoint(x: area.midX - w.frame.width / 2, y: area.midY - w.frame.height / 2))
            }
            window = w
        }
        NSApp.activate(ignoringOtherApps: true); window?.makeKeyAndOrderFront(nil)
    }
    func windowShouldClose(_ sender: NSWindow) -> Bool { sender.orderOut(nil); return false }
    func back() { session?.close(); session = nil }
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
        let context = invocation ?? PluginInvocation(actionID: entry.id, source: .launcher, query: query)
        do { try AppState.shared.packManager.preferences.recordUse(actionID: entry.id) }
        catch { self.error = error.localizedDescription }
        if entry.definition.ui == nil {
            ActionRunner().runLauncher(entry: entry, invocation: context)
        } else {
            session = PluginSession(entry: entry, invocation: context)
            show()
            if let height = entry.definition.ui?.height, let window {
                let maxHeight = (window.screen?.visibleFrame.height ?? 800) - 70
                window.setContentSize(NSSize(width: window.contentLayoutRect.width, height: min(max(CGFloat(height) + 48, 280), maxHeight)))
            }
        }
    }
    func reload() {
        guard let session else { return }
        let entry = session.entry, context = session.invocation
        back(); open(entry, invocation: PluginInvocation(actionID: context.actionID, source: context.source,
                                                       query: context.query, argument: context.argument, paths: context.paths, variant: context.variant))
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
    private var matches: [PluginSearchMatch] {
        let entries = manager.launcherEntries().map { PluginSearchEntry(id: $0.id, title: $0.definition.title, keywords: $0.definition.launcher?.keywords ?? []) }
        return PluginSearch.matches(query: controller.query, entries: entries, recent: (try? manager.preferences.recent()) ?? [])
    }
    private func launch(_ id: UUID?) {
        guard let match = matches.first(where: { $0.entry.id == (id ?? matches.first?.entry.id) }),
              let entry = manager.launcherEntry(actionID: match.entry.id) else { return }
        controller.selectedID = entry.id
        controller.open(entry, invocation: PluginInvocation(actionID: entry.id, source: .launcher,
                                                           query: controller.query, argument: match.argument))
    }
    private func move(_ delta: Int) {
        guard !matches.isEmpty else { return }
        let current = matches.firstIndex { $0.entry.id == controller.selectedID } ?? 0
        controller.selectedID = matches[max(0, min(matches.count - 1, current + delta))].entry.id
    }
    var body: some View {
        VStack(spacing: 0) {
            if let session = controller.session {
                PluginSessionView(session: session, controller: controller)
            } else {
                PluginSearchField(text: $controller.query, onSubmit: { launch(controller.selectedID) },
                                  onMove: move, onEscape: { controller.toggle() }).padding(12)
                if matches.isEmpty {
                    Text(String(localized: "plugins.noMatches")).foregroundStyle(.secondary).padding(); Spacer()
                } else {
                    List(selection: $controller.selectedID) {
                        ForEach(matches, id: \.entry.id) { match in
                            Button { launch(match.entry.id) } label: {
                                VStack(alignment: .leading) {
                                    Text(match.entry.title)
                                    Text(match.entry.keywords.joined(separator: ", ")).font(.caption).foregroundStyle(.secondary)
                                }.frame(maxWidth: .infinity, alignment: .leading).contentShape(Rectangle())
                            }.buttonStyle(.plain).tag(match.entry.id)
                        }
                    }
                }
            }
            if let error = controller.error { Text(error).font(.caption).foregroundStyle(.red).padding(8) }
        }.frame(minWidth: 420, minHeight: 280)
            .onChange(of: controller.query) { _ in controller.selectedID = matches.first?.entry.id }
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
            }.padding(12)
            if let error = session.error { Text(error).font(.caption).foregroundStyle(.red).textSelection(.enabled).padding(8) }
            Divider(); PluginWebView(session: session).id(session.id)
        }
    }
}

private struct PluginSearchField: NSViewRepresentable {
    @Binding var text: String
    let onSubmit: () -> Void
    let onMove: (Int) -> Void
    let onEscape: () -> Void
    func makeCoordinator() -> Coordinator { Coordinator(self) }
    func makeNSView(context: Context) -> NSSearchField {
        let field = NSSearchField(); field.placeholderString = String(localized: "plugins.search"); field.delegate = context.coordinator
        DispatchQueue.main.async { field.window?.makeFirstResponder(field) }; return field
    }
    func updateNSView(_ field: NSSearchField, context: Context) {
        context.coordinator.parent = self
        if field.stringValue != text { field.stringValue = text }
    }
    final class Coordinator: NSObject, NSSearchFieldDelegate {
        var parent: PluginSearchField
        init(_ parent: PluginSearchField) { self.parent = parent }
        func controlTextDidChange(_ notification: Notification) { parent.text = (notification.object as? NSSearchField)?.stringValue ?? "" }
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
        override var acceptsFirstResponder: Bool { true }
        @objc func record() { recording = true; title = String(localized: "plugins.pressShortcut"); window?.makeFirstResponder(self) }
        override func keyDown(with event: NSEvent) {
            guard recording else { super.keyDown(with: event); return }
            if event.keyCode == 53 { recording = false; title = PluginLauncherController.shared.shortcutLabel; return }
            let flags = event.modifierFlags
            guard flags.contains(.control) || flags.contains(.option) || flags.contains(.command) else { return }
            var modifiers: UInt32 = 0, label = ""
            for (flag, carbon, symbol) in [(NSEvent.ModifierFlags.control, controlKey, "⌃"), (.option, optionKey, "⌥"), (.shift, shiftKey, "⇧"), (.command, cmdKey, "⌘")] {
                if flags.contains(flag) { modifiers |= UInt32(carbon); label += symbol }
            }
            label += event.keyCode == 49 ? "Space" : (event.charactersIgnoringModifiers ?? "").uppercased()
            PluginLauncherController.shared.setShortcut(key: UInt32(event.keyCode), modifiers: modifiers, label: label)
            recording = false; title = PluginLauncherController.shared.shortcutLabel
        }
    }
}
