import SwiftUI
import AnyWhereCore

struct PluginMCPSettingsView: View {
    @ObservedObject var manager: PackManager
    let entry: PluginLauncherEntry
    @State private var error: String?

    var body: some View {
        if let mcp = entry.definition.mcp {
            VStack(alignment: .leading, spacing: 6) {
                Toggle(String(localized: "mcp.allow"), isOn: Binding(
                    get: { (try? manager.preferences.isMCPEnabled(actionID: entry.id, approval: entry.definition.mcpApproval)) == true },
                    set: { enabled in
                        do { try manager.setMCPEnabled(enabled, entry: entry); error = nil }
                        catch { self.error = error.localizedDescription }
                    })).toggleStyle(.switch)
                Text("\(mcp.name)：\(mcp.description)").font(.caption).foregroundStyle(AWColor.label2)
                Text(String(format: String(localized: "mcp.operations"), mcp.commands.joined(separator: ", "))).font(.caption).foregroundStyle(AWColor.label2)
                if let error { Text(error).foregroundStyle(.red).font(.caption) }
            }
        }
    }
}
