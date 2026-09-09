import SwiftUI
import Sparkle
import AnyWhereCore

@main
struct AnyWhereApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) var appDelegate
    @Environment(\.openWindow) private var openWindow
    // Sparkle 自动更新:appcast 与公钥见 Info.plist(SUFeedURL / SUPublicEDKey),发布流程见 docs/RELEASING.md。
    private let updater: SPUUpdater? = {
        let driver = SPUStandardUserDriver(hostBundle: .main, delegate: nil)
        let updater = SPUUpdater(hostBundle: .main, applicationBundle: .main,
                                 userDriver: driver, delegate: nil)
        do {
            // 直接启动，避免标准控制器在配置错误时弹出启动警告。
            try updater.start()
            if updater.automaticallyChecksForUpdates {
                // 后台检查仅在发现更新时提示；无更新或网络失败时保持静默。
                updater.checkForUpdatesInBackground()
            }
            return updater
        } catch {
            NSLog("[AnyWhere][updates] 更新器启动失败: %@", error.localizedDescription)
            return nil
        }
    }()

    var body: some Scene {
        // 菜单栏下拉 — 对照 docs/design/hifi/screen-misc.jsx MenuBar(系统右键菜单外观)。
        // 用系统原生 MenuBarExtra,项与分隔结构对齐设计稿。
        MenuBarExtra("AnyWhere", systemImage: "contextualmenu.and.cursorarrow") {
            Button(String(localized: "menubar.openSettings")) {
                openWindow(id: "settings")
                NSApp.activate(ignoringOtherApps: true)
            }
            Button(String(localized: "plugins.openSearch")) {
                PluginLauncherController.shared.show()
            }
            Button(String(localized: "menubar.recentRuns")) {
                openWindow(id: "log")
                NSApp.activate(ignoringOtherApps: true)
            }
            Button(String(localized: "menubar.checkForUpdates")) { updater?.checkForUpdates() }
                .disabled(updater == nil)
            Divider()
            Button(String(localized: "menubar.restartFinder")) { ShellRunner.run("/usr/bin/killall", ["Finder"], timeout: 10) }
            Divider()
            Button(String(localized: "menubar.quit")) { NSApp.terminate(nil) }
        }
        Window(String(localized: "menubar.settingsWindowTitle"), id: "settings") { SettingsWindow() }
            .defaultSize(width: 1120, height: 720)
        Window(String(localized: "menubar.logWindowTitle"), id: "log") {
            ExecutionLogView()
        }
        .defaultSize(width: 420, height: 340)
    }
}
