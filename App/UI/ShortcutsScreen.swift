import SwiftUI
import AppKit
import Carbon
import AnyWhereCore

struct ShortcutsScreen: View {
    @ObservedObject var manager: PackManager
    @State private var entries: [PluginSearchEntry] = []
    @State private var selection: UUID?
    @State private var error: String?

    var body: some View {
        VStack(spacing: 0) {
            if let error { Banner(error, tone: .red).padding(16) }
            HStack(alignment: .center) {
                VStack(alignment: .leading, spacing: 4) {
                    Text("快捷指令").font(.system(size: 24, weight: .semibold))
                    Text("用关键词或独立快捷键快速执行你的工具").font(.callout).foregroundStyle(.secondary)
                }
                Spacer()
                Button { create() } label: { Label("新建快捷指令", systemImage: "plus") }
                    .buttonStyle(.borderedProminent).controlSize(.large)
            }.padding(.horizontal, 28).padding(.vertical, 22)
            Divider()
            if entries.isEmpty {
                VStack(spacing: 14) {
                    Image(systemName: "command").font(.system(size: 40)).foregroundStyle(.secondary)
                    Text(String(localized: "shortcuts.empty")).font(.headline)
                    Text(String(localized: "shortcuts.emptyHint")).foregroundStyle(.secondary)
                    Button(String(localized: "settings.tab.packs")) { AppState.shared.settingsTab = .packs }
                }.frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                HStack(spacing: 0) {
                    VStack(alignment: .leading, spacing: 10) {
                        Text(String(localized: "shortcuts.listHint"))
                            .font(.system(size: 12, weight: .medium)).foregroundStyle(.secondary).padding(.horizontal, 16).padding(.top, 18)
                        List(entries, id: \.id, selection: $selection) { entry in
                            HStack(spacing: 10) {
                                Image(systemName: "bolt.circle.fill").font(.system(size: 22)).foregroundStyle(.blue)
                                VStack(alignment: .leading, spacing: 4) {
                                    Text(entry.title).fontWeight(.medium).lineLimit(1)
                                    Text(entry.keywords.isEmpty ? String(localized: "shortcuts.unconfigured") : entry.keywords.joined(separator: " · "))
                                        .font(.system(size: 11, design: .monospaced)).foregroundStyle(.secondary).lineLimit(1)
                                }
                                Spacer(minLength: 0)
                                if AppState.shared.config.actions.first(where: { $0.id == entry.id })?.isEnabled == true {
                                    Circle().fill(.green).frame(width: 7, height: 7)
                                }
                            }.padding(.vertical, 7).tag(entry.id)
                        }.listStyle(.sidebar)
                    }.frame(width: 270)
                    Divider()
                    if let selected = entries.first(where: { $0.id == selection }),
                       let action = AppState.shared.config.actions.first(where: { $0.id == selected.id && $0.shortcutOnly == true }) {
                        ScrollView {
                            VStack(alignment: .leading, spacing: 18) {
                                PvEditor(action: action, onSave: { saved in
                                    AppState.shared.mutateConfig { config in
                                        if let i = config.actions.firstIndex(where: { $0.id == saved.id }) { config.actions[i] = saved }
                                    }
                                    reload()
                                }, onDelete: {
                                    AppState.shared.mutateConfig { $0.actions.removeAll { $0.id == action.id } }
                                    reload()
                                })
                                ShortcutKeywordEditor(manager: manager, action: action, shortcut: selected)
                            }.padding(20)
                        }.id(selected.id).padding(.top, 8)
                    } else if let selected = entries.first(where: { $0.id == selection }),
                              let entry = manager.launcherEntry(actionID: selected.id) {
                        ShortcutEditor(manager: manager, entry: entry, shortcut: selected).id(selected.id)
                    } else {
                        Text(String(localized: "shortcuts.select")).foregroundStyle(.secondary)
                            .frame(maxWidth: .infinity, maxHeight: .infinity)
                    }
                }
            }
        }
        .onAppear { reload() }
        .onReceive(manager.$packs) { _ in DispatchQueue.main.async { reload() } }
    }

    private func reload() {
        do {
            entries = try manager.shortcutEntries(includeDisabled: true)
            if !entries.contains(where: { $0.id == selection }) { selection = entries.first?.id }
            error = nil
        } catch { self.error = error.localizedDescription }
    }

    private func create() {
        let action = MenuAction(id: UUID(), title: "新建快捷指令",
                                icon: .symbol("bolt"), kind: .runScript(ScriptSpec(inlineSource: "#!/bin/zsh\n")),
                                matching: MatchRule(), placement: .topLevel, isEnabled: false,
                                sortOrder: (AppState.shared.config.actions.map(\.sortOrder).max() ?? 0) + 1,
                                shortcutOnly: true)
        AppState.shared.mutateConfig { $0.actions.append(action) }
        selection = action.id
        reload()
    }
}

private struct ShortcutKeywordEditor: View {
    @ObservedObject var manager: PackManager
    let action: MenuAction
    @State private var keywords: String
    @State private var message: String?
    init(manager: PackManager, action: MenuAction, shortcut: PluginSearchEntry) {
        self.manager = manager; self.action = action
        _keywords = State(initialValue: shortcut.keywords.joined(separator: ", "))
    }
    var body: some View {
        VStack(alignment: .leading, spacing: 9) {
            Text(String(localized: "shortcuts.keywords")).fontWeight(.medium)
            TextField("XM, xlog", text: $keywords).textFieldStyle(.roundedBorder)
            Text(String(localized: "shortcuts.keywordsHint")).font(.caption).foregroundStyle(.secondary)
            HStack {
                Button(String(localized: "shortcuts.save")) { save() }.buttonStyle(.borderedProminent)
                if let message { Text(message).font(.caption).foregroundStyle(.secondary) }
            }
            HStack(spacing: 10) {
                Text("快捷键")
                ActionHotKeyRecorder(actionID: action.id, label: action.shortcutHotKey?.label ?? "未设置")
                    .frame(width: 150, height: 28)
            }
        }
    }
    private func save() {
        do {
            try manager.setShortcut(.init(title: action.title, keywords: keywords.components(separatedBy: CharacterSet(charactersIn: ",，"))), actionID: action.id)
            message = String(localized: "shortcuts.saved")
        } catch PluginShortcutError.duplicateKeyword(let value) {
            message = String(format: String(localized: "shortcuts.conflict"), value)
        } catch { message = error.localizedDescription }
    }
}

private struct ActionHotKeyRecorder: NSViewRepresentable {
    let actionID: UUID
    let label: String
    func makeNSView(context: Context) -> Recorder { Recorder(actionID: actionID, label: label) }
    func updateNSView(_ view: Recorder, context: Context) { view.actionID = actionID; if !view.recording { view.title = label } }
    final class Recorder: NSButton {
        var actionID: UUID; var recording = false; var monitor: Any?
        init(actionID: UUID, label: String) { self.actionID = actionID; super.init(frame: .zero); title = label; bezelStyle = .rounded; target = self; action = #selector(begin) }
        required init?(coder: NSCoder) { fatalError() }
        override var acceptsFirstResponder: Bool { true }
        @objc func begin() {
            guard !recording else { return }; recording = true; title = "请按快捷键…"; window?.makeFirstResponder(self)
            monitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
                guard let self, self.recording else { return event }
                guard self.window?.firstResponder === self else { self.end(); return event }
                if event.keyCode == 53 { self.end(); return nil }
                let flags = event.modifierFlags
                guard flags.contains(.control) || flags.contains(.option) || flags.contains(.command) else { return nil }
                var modifiers: UInt32 = 0; var text = ""
                for (flag, carbon, symbol) in [(NSEvent.ModifierFlags.control, controlKey, "⌃"), (.option, optionKey, "⌥"), (.shift, shiftKey, "⇧"), (.command, cmdKey, "⌘")] where flags.contains(flag) { modifiers |= UInt32(carbon); text += symbol }
                let label = text + (event.keyCode == 49 ? "Space" : (event.charactersIgnoringModifiers ?? "").uppercased())
                do { try PluginLauncherController.shared.setActionHotKey(ActionHotKey(key: UInt32(event.keyCode), modifiers: modifiers, label: label), actionID: self.actionID); self.title = label }
                catch { self.title = "冲突" }
                self.end(keepTitle: true); return nil
            }
        }
        func end(keepTitle: Bool = false) { recording = false; if let monitor { NSEvent.removeMonitor(monitor); self.monitor = nil }; if !keepTitle { title = "未设置" } }
        deinit { if let monitor { NSEvent.removeMonitor(monitor) } }
    }
}

private struct ShortcutEditor: View {
    @ObservedObject var manager: PackManager
    let entry: PluginLauncherEntry
    @State private var title: String
    @State private var keywords: String
    @State private var enabled = false
    @State private var error: String?
    @State private var saved = false

    init(manager: PackManager, entry: PluginLauncherEntry, shortcut: PluginSearchEntry) {
        self.manager = manager; self.entry = entry
        _title = State(initialValue: shortcut.title)
        _keywords = State(initialValue: shortcut.keywords.joined(separator: ", "))
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 24) {
                HStack(spacing: 12) {
                    ActionIconView(icon: entry.action.icon, size: 44)
                    VStack(alignment: .leading, spacing: 4) {
                        Text(entry.definition.title).font(.title2.weight(.semibold))
                        Text(manager.packs.first(where: { $0.key == entry.action.packID })?.manifest.name ?? "")
                            .foregroundStyle(.secondary)
                    }
                    Spacer()
                    Toggle(String(localized: "shortcuts.enabled"), isOn: Binding(get: { enabled }, set: setEnabled))
                        .toggleStyle(.switch).labelsHidden().accessibilityLabel(String(localized: "shortcuts.enabled"))
                }
                VStack(alignment: .leading, spacing: 8) {
                    Text(String(localized: "shortcuts.name")).fontWeight(.medium)
                    TextField(String(localized: "shortcuts.name"), text: $title).textFieldStyle(.roundedBorder)
                }
                VStack(alignment: .leading, spacing: 8) {
                    Text(String(localized: "shortcuts.keywords")).fontWeight(.medium)
                    TextField("XM, xlog", text: $keywords).textFieldStyle(.roundedBorder)
                        .accessibilityLabel(String(localized: "shortcuts.keywords"))
                    Text(String(localized: "shortcuts.keywordsHint")).font(.caption).foregroundStyle(.secondary)
                }
                VStack(alignment: .leading, spacing: 8) {
                    Text(String(localized: "shortcuts.target")).fontWeight(.medium)
                    Label(entry.definition.title, systemImage: "shippingbox").foregroundStyle(.secondary)
                }
                HStack {
                    Button(String(localized: "shortcuts.save"), action: save).buttonStyle(.borderedProminent)
                    if saved { Label(String(localized: "shortcuts.saved"), systemImage: "checkmark").foregroundStyle(.secondary) }
                }
                if let error { Text(error).foregroundStyle(.red).textSelection(.enabled) }
                Divider()
                Label(String(localized: "shortcuts.usage"), systemImage: "magnifyingglass")
                    .font(.callout).foregroundStyle(.secondary)
                Button(String(localized: "plugins.openSearch")) { PluginLauncherController.shared.show() }
            }.padding(28)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .onAppear {
            do { enabled = try manager.preferences.isEnabled(actionID: entry.id) }
            catch { self.error = error.localizedDescription }
        }
        .onChange(of: title) { _ in saved = false }
        .onChange(of: keywords) { _ in saved = false }
    }

    private func setEnabled(_ value: Bool) {
        do { try manager.setLauncherEnabled(value, actionID: entry.id); enabled = value; error = nil }
        catch { self.error = error.localizedDescription }
    }

    private func save() {
        do {
            try manager.setShortcut(.init(title: title, keywords: keywords.components(separatedBy: CharacterSet(charactersIn: ",，"))), actionID: entry.id)
            error = nil; saved = true
        } catch PluginShortcutError.duplicateKeyword(let keyword) {
            error = String(format: String(localized: "shortcuts.conflict"), keyword)
        } catch PluginShortcutError.invalidShortcut {
            error = String(localized: "shortcuts.invalid")
        } catch { self.error = error.localizedDescription }
    }
}
