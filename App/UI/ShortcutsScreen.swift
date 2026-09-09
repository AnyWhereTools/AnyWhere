import SwiftUI
import AnyWhereCore

struct ShortcutsScreen: View {
    @ObservedObject var manager: PackManager
    @State private var entries: [PluginSearchEntry] = []
    @State private var selection: UUID?
    @State private var error: String?

    var body: some View {
        VStack(spacing: 0) {
            if let error { Banner(error, tone: .red).padding(16) }
            if entries.isEmpty {
                VStack(spacing: 14) {
                    Image(systemName: "command").font(.system(size: 40)).foregroundStyle(.secondary)
                    Text(String(localized: "shortcuts.empty")).font(.headline)
                    Text(String(localized: "shortcuts.emptyHint")).foregroundStyle(.secondary)
                    Button(String(localized: "settings.tab.packs")) { AppState.shared.settingsTab = .packs }
                }.frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                HStack(spacing: 0) {
                    VStack(alignment: .leading, spacing: 12) {
                        Text(String(localized: "shortcuts.listHint"))
                            .font(.caption).foregroundStyle(.secondary).padding(.horizontal, 16).padding(.top, 18)
                        List(entries, id: \.id, selection: $selection) { entry in
                            VStack(alignment: .leading, spacing: 6) {
                                Text(entry.title).fontWeight(.medium)
                                Text(entry.keywords.isEmpty ? String(localized: "shortcuts.unconfigured") : entry.keywords.joined(separator: " · "))
                                    .font(.caption.monospaced()).foregroundStyle(.secondary)
                            }.padding(.vertical, 8).tag(entry.id)
                        }.listStyle(.sidebar)
                    }.frame(width: 270)
                    Divider()
                    if let selected = entries.first(where: { $0.id == selection }),
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
