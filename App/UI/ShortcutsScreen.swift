import SwiftUI
import AppKit
import Carbon
import AnyWhereCore

struct ShortcutsScreen: View {
    @ObservedObject var manager: PackManager
    @State private var entries: [PluginSearchEntry] = []
    @State private var selection: UUID?
    @State private var error: String?
    @State private var searchText = ""

    private var filteredEntries: [PluginSearchEntry] {
        let query = searchText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !query.isEmpty else { return entries }
        let matches = Set(PluginSearch.matches(query: query, entries: entries, recent: []).map { $0.entry.id })
        return entries.filter { matches.contains($0.id) }
    }

    var body: some View {
        HStack(spacing: 0) {
            VStack(alignment: .leading, spacing: 0) {
                VStack(alignment: .leading, spacing: 10) {
                    HStack {
                        Text("快捷指令").font(.system(size: 17, weight: .semibold))
                        Spacer()
                        Button { create() } label: { Image(systemName: "plus") }
                            .buttonStyle(.bordered).controlSize(.regular)
                            .accessibilityLabel("新建快捷指令")
                    }
                    Text("用关键词或快捷键快速执行工具")
                        .font(.system(size: 12)).foregroundStyle(.secondary)
                    HStack(spacing: 6) {
                        Image(systemName: "magnifyingglass").foregroundStyle(.secondary)
                        TextField(String(localized: "shortcuts.search"), text: $searchText)
                            .textFieldStyle(.plain)
                            .accessibilityLabel(String(localized: "shortcuts.search"))
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
                List(filteredEntries, id: \.id, selection: $selection) { entry in
                    let action = AppState.shared.config.actions.first { $0.id == entry.id }
                    HStack(spacing: 10) {
                        ActionIconView(icon: action?.icon ?? .symbol("bolt"),
                                       hue: action?.iconHue.flatMap(AppIconHue.init(rawValue:)) ?? .gray, size: 32)
                        VStack(alignment: .leading, spacing: 3) {
                            Text(entry.title).fontWeight(.medium).lineLimit(1)
                            Text(entry.keywords.isEmpty ? String(localized: "shortcuts.unconfigured") : entry.keywords.joined(separator: " · "))
                                .font(.system(size: 11)).foregroundStyle(.secondary).lineLimit(1)
                        }
                        Spacer(minLength: 0)
                        if action?.isEnabled == true {
                            Circle().fill(Color.accentColor).frame(width: 6, height: 6)
                                .accessibilityLabel(String(localized: "shortcuts.enabled"))
                        }
                    }
                    .padding(.vertical, 5)
                    .padding(.horizontal, 4)
                    .listRowBackground(selection == entry.id ? Color.primary.opacity(0.06) : Color.clear)
                    .tag(entry.id)
                }
                .listStyle(.plain)
                .scrollContentBackground(.hidden)
                .overlay {
                    if !entries.isEmpty && filteredEntries.isEmpty {
                        Text(String(localized: "shortcuts.noMatches"))
                            .font(.callout).foregroundStyle(.secondary).padding()
                    }
                }
                if let error { Banner(error, tone: .red).padding(12) }
            }
            .frame(width: 260)
            Divider()
            detail
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
        .onAppear { reload() }
        .onReceive(manager.$packs) { _ in DispatchQueue.main.async { reload() } }
    }

    @ViewBuilder private var detail: some View {
        if entries.isEmpty {
            VStack(spacing: 14) {
                Image(systemName: "command").font(.system(size: 40)).foregroundStyle(.secondary)
                Text(String(localized: "shortcuts.empty")).font(.headline)
                Text(String(localized: "shortcuts.emptyHint")).foregroundStyle(.secondary)
                Button(String(localized: "settings.tab.packs")) { AppState.shared.settingsTab = .packs }
            }.frame(maxWidth: .infinity, maxHeight: .infinity)
        } else if let selected = entries.first(where: { $0.id == selection }),
                  let action = AppState.shared.config.actions.first(where: { $0.id == selected.id && $0.shortcutOnly == true }) {
            ScrollView {
                PvEditor(action: action, onSave: { saved in
                    AppState.shared.mutateConfig { config in
                        if let i = config.actions.firstIndex(where: { $0.id == saved.id }) { config.actions[i] = saved }
                    }
                    reload()
                }, onDelete: {
                    AppState.shared.mutateConfig { $0.actions.removeAll { $0.id == action.id } }
                    reload()
                }, basicFields: {
                    ShortcutKeywordEditor(manager: manager, action: action, shortcut: selected)
                }, advancedFields: {
                    PvField("快捷键", leading: true) {
                        ActionHotKeyRecorder(actionID: action.id, label: action.shortcutHotKey?.label ?? "未设置")
                            .frame(width: 150, height: 28)
                    }
                })
                .padding(20)
            }.id(selected.id)
        } else if let selected = entries.first(where: { $0.id == selection }),
                  let entry = manager.launcherEntry(actionID: selected.id) {
            ShortcutEditor(manager: manager, entry: entry, shortcut: selected).id(selected.id)
        } else {
            Text(String(localized: "shortcuts.select")).foregroundStyle(.secondary)
        }
    }

    private func reload() {
        do {
            entries = try manager.shortcutEntries(includeDisabled: true)
            if !entries.contains(where: { $0.id == selection }) { selection = entries.first?.id }
            error = nil
        } catch { self.error = error.localizedDescription }
    }

    private func create() {
        searchText = ""
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
        PvField(String(localized: "shortcuts.keywords"), leading: true) {
            VStack(alignment: .leading, spacing: 6) {
                TextField("XM, xlog", text: $keywords).textFieldStyle(.roundedBorder)
                    .accessibilityLabel(String(localized: "shortcuts.keywords"))
                Text(String(localized: "shortcuts.keywordsHint")).font(.caption).foregroundStyle(.secondary)
                HStack(spacing: 8) {
                    AWButton(String(localized: "shortcuts.save"), kind: .normal, size: .sm) { save() }
                    if let message { Text(message).font(.caption).foregroundStyle(.secondary) }
                }
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
            VStack(alignment: .leading, spacing: 16) {
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
                ShortcutSettingsGroup(String(localized: "shortcuts.name")) {
                    TextField(String(localized: "shortcuts.name"), text: $title).textFieldStyle(.roundedBorder)
                }
                ShortcutSettingsGroup(String(localized: "shortcuts.keywords")) {
                    TextField("XM, xlog", text: $keywords).textFieldStyle(.roundedBorder)
                        .accessibilityLabel(String(localized: "shortcuts.keywords"))
                    Text(String(localized: "shortcuts.keywordsHint")).font(.caption).foregroundStyle(AWColor.label2)
                }
                ShortcutSettingsGroup(String(localized: "shortcuts.target")) {
                    Label(entry.definition.title, systemImage: "shippingbox").foregroundStyle(AWColor.label2)
                }
                HStack(spacing: 12) {
                    AWButton(String(localized: "shortcuts.save"), kind: .primary, size: .sm, action: save)
                    if saved { Label(String(localized: "shortcuts.saved"), systemImage: "checkmark").foregroundStyle(.secondary) }
                }
                if let error { Text(error).foregroundStyle(.red).textSelection(.enabled) }
                ShortcutSettingsGroup("使用方式") {
                    Label(String(localized: "shortcuts.usage"), systemImage: "magnifyingglass")
                        .font(.callout).foregroundStyle(AWColor.label2)
                    Button(String(localized: "plugins.openSearch")) { PluginLauncherController.shared.show() }
                        .buttonStyle(.link)
                }
            }.padding(24)
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


// Shared group chrome for custom actions and installed plugin shortcuts.
struct ShortcutSettingsGroup<Content: View>: View {
    let title: String
    @ViewBuilder var content: Content

    init(_ title: String, @ViewBuilder content: () -> Content) {
        self.title = title
        self.content = content()
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            Text(title)
                .font(.system(size: 13, weight: .semibold))
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.horizontal, 14).padding(.vertical, 10)
                .background(Color.primary.opacity(0.025))
            VStack(alignment: .leading, spacing: 12) { content }
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(14)
        }
        .background(AWColor.card)
        .clipShape(RoundedRectangle(cornerRadius: AWRadius.card, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: AWRadius.card, style: .continuous)
            .stroke(AWColor.hairline, lineWidth: 0.5))
    }
}
