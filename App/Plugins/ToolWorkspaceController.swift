import AppKit
import SwiftUI
import AnyWhereCore

@MainActor
final class ToolWorkspaceController {
    static let shared = ToolWorkspaceController()
    private(set) var windows: [UUID: ToolWindowController] = [:]

    @discardableResult func open(_ entry: PluginLauncherEntry, invocation: PluginInvocation) -> ToolWindowController {
        if let existing = windows[entry.id] { existing.showWindow(nil); existing.window?.makeKeyAndOrderFront(nil); return existing }
        let controller = ToolWindowController(entry: entry, invocation: invocation)
        controller.onClose = { [weak self] in self?.windows.removeValue(forKey: entry.id) }
        windows[entry.id] = controller
        controller.showWindow(nil)
        NSApp.activate(ignoringOtherApps: true)
        controller.window?.makeKeyAndOrderFront(nil)
        return controller
    }

    @discardableResult func close(packKey: String? = nil) -> Bool {
        let targets = windows.values.filter { packKey == nil || $0.session.entry.action.packID == packKey }
        return targets.reduce(true) { $1.endSession() && $0 }
    }

    func validate(using manager: PackManager) {
        for controller in Array(windows.values) {
            let session = controller.session
            let current = manager.launcherEntry(actionID: session.entry.id)
            let enabled = session.invocation.source == .finder
                ? current?.action.isEnabled == true && current?.definition.contextMenu == true
                : (try? manager.preferences.isEnabled(actionID: session.entry.id)) == true
            if current?.definition != session.entry.definition || !enabled { _ = controller.endSession() }
        }
    }
}

@MainActor
final class ToolWindowController: NSWindowController, NSWindowDelegate, NSToolbarDelegate {
    private static let reloadItem = NSToolbarItem.Identifier("AnyWhere.tool.reload")
    private(set) var session: PluginSession
    var onClose: (() -> Void)?

    init(entry: PluginLauncherEntry, invocation: PluginInvocation) {
        session = PluginSession(entry: entry, invocation: invocation)
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 680, height: CGFloat(entry.definition.ui?.height ?? 460)),
                             styleMask: [.titled, .closable, .miniaturizable, .resizable], backing: .buffered, defer: false)
        window.title = entry.definition.title
        window.identifier = NSUserInterfaceItemIdentifier("AnyWhere.tool." + entry.id.uuidString)
        window.isReleasedWhenClosed = false
        window.hidesOnDeactivate = false
        window.level = .normal
        window.minSize = NSSize(width: 420, height: 280)
        super.init(window: window)
        window.delegate = self
        let toolbar = NSToolbar(identifier: "AnyWhere.tool")
        toolbar.delegate = self
        toolbar.displayMode = .iconOnly
        window.toolbar = toolbar
        window.toolbarStyle = .unifiedCompact
        window.center()
        installContent()
    }
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    private func installContent() {
        session.onBack = { [weak self] in _ = self?.endSession() }
        window?.contentView = NSHostingView(rootView: PluginSessionView(session: session,
            onBack: { [weak self] in _ = self?.endSession() }, onReload: { [weak self] in self?.reload() },
            onClose: { [weak self] in _ = self?.endSession() }))
    }
    func toolbarAllowedItemIdentifiers(_ toolbar: NSToolbar) -> [NSToolbarItem.Identifier] {
        [.flexibleSpace, Self.reloadItem]
    }
    func toolbarDefaultItemIdentifiers(_ toolbar: NSToolbar) -> [NSToolbarItem.Identifier] {
        [.flexibleSpace, Self.reloadItem]
    }
    func toolbar(_ toolbar: NSToolbar, itemForItemIdentifier itemIdentifier: NSToolbarItem.Identifier,
                 willBeInsertedIntoToolbar flag: Bool) -> NSToolbarItem? {
        guard itemIdentifier == Self.reloadItem else { return nil }
        let item = NSToolbarItem(itemIdentifier: itemIdentifier)
        item.label = String(localized: "plugins.reload")
        item.toolTip = item.label
        item.image = NSImage(systemSymbolName: "arrow.clockwise", accessibilityDescription: item.label)
        item.target = self
        item.action = #selector(reload)
        return item
    }
    @objc func reload() {
        let entry = session.entry, invocation = session.invocation
        guard session.close(waitForTask: true) else { return }
        window?.contentView = nil
        session = PluginSession(entry: entry, invocation: invocation)
        installContent()
    }
    @discardableResult func endSession() -> Bool {
        guard session.close(waitForTask: true) else { return false }
        window?.contentView = nil
        window?.close()
        return true
    }
    func windowShouldClose(_ sender: NSWindow) -> Bool { session.close(waitForTask: true) }
    func windowWillClose(_ notification: Notification) {
        _ = session.close(waitForTask: true)
        window?.contentView = nil
        onClose?()
    }
}
