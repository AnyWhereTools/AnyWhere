import SwiftUI

struct SettingsWindow: View {
    @ObservedObject private var state = AppState.shared
    var body: some View {
        HStack(spacing: 0) {
            VStack(alignment: .leading, spacing: 12) {
                HStack(spacing: 9) {
                    AppIcon("contextualmenu.and.cursorarrow", size: 30, hue: .purple)
                    Text("AnyWhere").font(.system(size: 17, weight: .semibold))
                }.padding(.horizontal, 18).padding(.top, 22)
                List(SettingsTab.allCases, id: \.self, selection: Binding<SettingsTab?>(
                    get: { state.settingsTab }, set: { if let tab = $0 { state.settingsTab = tab } }
                )) { tab in
                    Label(tab.title, systemImage: tab.icon).padding(.vertical, 7).tag(tab)
                }.listStyle(.sidebar)
            }
            .frame(width: 184)
            .background(.regularMaterial)
            Divider()
            VStack(alignment: .leading, spacing: 0) {
                if state.settingsTab != .shortcuts && state.settingsTab != .contextMenu {
                    Text(state.settingsTab.title)
                        .font(.system(size: 22, weight: .semibold))
                        .padding(.horizontal, 24).padding(.vertical, 20)
                    Divider()
                }
                Group {
                    switch state.settingsTab {
                    case .contextMenu: ScreenMenuHub()
                    case .shortcuts: ShortcutsScreen(manager: state.packManager)
                    case .packs: ScreenPacks(packManager: state.packManager)
                    case .general: GeneralTab()
                    }
                }.frame(maxWidth: .infinity, maxHeight: .infinity)
            }.background(AWColor.content)
        }
        .frame(minWidth: 1040, minHeight: 620)
    }
}

enum SettingsTab: Hashable, CaseIterable {
    case contextMenu, shortcuts, packs, general
    var title: String {
        switch self {
        case .contextMenu: return String(localized: "settings.tab.contextMenu")
        case .shortcuts: return String(localized: "settings.tab.shortcuts")
        case .packs: return String(localized: "settings.tab.packs")
        case .general: return String(localized: "settings.tab.general")
        }
    }
    var icon: String {
        switch self {
        case .contextMenu: return "cursorarrow.click.2"
        case .shortcuts: return "command"
        case .packs: return "shippingbox"
        case .general: return "gearshape"
        }
    }
}
