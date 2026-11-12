import SwiftUI
import AnyWhereCore

struct PluginSettingsView: View {
    @ObservedObject var manager: PackManager
    let entry: PluginLauncherEntry
    @State private var title: String
    @State private var keywords: String
    @State private var error: String?
    @State private var saved = false

    init(manager: PackManager, entry: PluginLauncherEntry) {
        self.manager = manager; self.entry = entry
        let defaults = PluginSearchEntry(id: entry.id, title: entry.definition.title, keywords: entry.definition.launcher?.keywords ?? [])
        let shortcut = (try? manager.preferences.searchEntries([defaults]).first) ?? defaults
        _title = State(initialValue: shortcut.title)
        _keywords = State(initialValue: shortcut.keywords.joined(separator: ", "))
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            if entry.definition.mcp != nil {
                ShortcutSettingsGroup(String(localized: "mcp.section")) {
                    PluginMCPSettingsView(manager: manager, entry: entry)
                }
            }
            if entry.definition.launcher != nil {
                ShortcutSettingsGroup("基本设置") {
                    PvField("显示名称", leading: true) {
                        TextField("显示名称", text: $title).textFieldStyle(.roundedBorder)
                    }
                    PvField(String(localized: "shortcuts.keywords"), leading: true) {
                        TextField("XM, xlog", text: $keywords).textFieldStyle(.roundedBorder)
                            .accessibilityLabel(String(localized: "shortcuts.keywords"))
                        Text(String(localized: "shortcuts.keywordsHint"))
                            .font(.caption).foregroundStyle(AWColor.label2)
                    }
                    PvField("快捷键", leading: true) {
                        ActionHotKeyRecorder(actionID: entry.id)
                        Text("按下后直接打开独立窗口；无界面的插件功能直接执行。")
                            .font(.caption).foregroundStyle(AWColor.label2)
                    }
                    HStack(spacing: 12) {
                        AWButton("保存设置", kind: .primary, size: .sm, action: save)
                        if saved { Label(String(localized: "shortcuts.saved"), systemImage: "checkmark").foregroundStyle(.secondary) }
                    }
                }
            }
            if let summary = manager.summaryEntries().first(where: { $0.action.packID == entry.action.packID }),
               let packKey = summary.action.packID {
                ShortcutSettingsGroup("搜索面板") {
                    Toggle("固定摘要", isOn: Binding(
                        get: { (try? manager.preferences.pinnedSummaries().contains(packKey)) == true },
                        set: { pinned in
                            do { try manager.setSummaryPinned(pinned, entry: summary); error = nil }
                            catch { self.error = error.localizedDescription }
                        }))
                        .toggleStyle(.switch)
                    Text("每次唤起搜索面板时，展示此插件的摘要信息。")
                        .font(.caption).foregroundStyle(AWColor.label2)
                }
            }
            if !manager.configurationFields(for: entry.action).isEmpty {
                PackConfigurationForm(actionID: entry.id, fields: manager.configurationFields(for: entry.action))
            }
            if let error { Text(error).foregroundStyle(.red).textSelection(.enabled) }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .onChange(of: title) { _ in saved = false }
        .onChange(of: keywords) { _ in saved = false }
    }

    private func save() {
        do {
            try manager.setShortcut(.init(title: title, keywords: keywords.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? [] : keywords.components(separatedBy: CharacterSet(charactersIn: ",，"))), actionID: entry.id)
            error = nil; saved = true
        } catch PluginShortcutError.duplicateKeyword(let keyword) {
            error = String(format: String(localized: "shortcuts.conflict"), keyword)
        } catch PluginShortcutError.invalidShortcut {
            error = String(localized: "shortcuts.invalid")
        } catch { self.error = error.localizedDescription }
    }
}
