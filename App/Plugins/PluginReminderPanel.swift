import AppKit
import UserNotifications
import AnyWhereCore

/// Renders plugin-supplied content and returns opaque action IDs.
@MainActor
final class PluginReminderPanel: NSWindowController, NSWindowDelegate {
    private final class CardPanel: NSPanel {
        override var canBecomeKey: Bool { true }
        override var canBecomeMain: Bool { false }
    }
    private enum Style {
        static func color(_ light: Int, _ dark: Int) -> NSColor {
            NSColor(name: nil) { appearance in
                let value = appearance.bestMatch(from: [.aqua, .darkAqua]) == .darkAqua ? dark : light
                return NSColor(srgbRed: CGFloat((value >> 16) & 255) / 255,
                               green: CGFloat((value >> 8) & 255) / 255,
                               blue: CGFloat(value & 255) / 255, alpha: 1)
            }
        }
        static let secondary = color(0x797b8c, 0xafb0c1)
        @MainActor static func drawButton(_ cell: NSButtonCell, frame: NSRect, menu: Bool, primary: Bool) {
            let emphasized = primary || cell.isHighlighted
            let background = emphasized ? color(0xeee9fc, 0x48415e) : color(0xffffff, 0x404351)
            let foreground = emphasized ? color(0x6650cb, 0xd3c2ff) : color(0x535667, 0xd9dbe7)
            let border = emphasized ? color(0xe4defc, 0x5f517c) : color(0xe1e3ec, 0x505465)
            let shape = NSBezierPath(roundedRect: frame.insetBy(dx: 0.5, dy: 0.5), xRadius: 9, yRadius: 9)
            background.setFill(); shape.fill()
            (NSWorkspace.shared.accessibilityDisplayShouldIncreaseContrast ? NSColor.labelColor : border).setStroke()
            shape.lineWidth = 1; shape.stroke()
            let paragraph = NSMutableParagraphStyle(); paragraph.lineBreakMode = .byTruncatingTail
            paragraph.alignment = .center
            let text = NSAttributedString(string: cell.title, attributes: [
                .font: NSFont.systemFont(ofSize: 12, weight: .medium),
                .foregroundColor: cell.isEnabled ? foreground : NSColor.disabledControlTextColor,
                .paragraphStyle: paragraph
            ])
            let width = min(text.size().width, max(0, frame.width - (menu ? 42 : 24)))
            let start = frame.midX - (width + (menu ? 18 : 0)) / 2
            text.draw(in: NSRect(x: start, y: frame.midY - text.size().height / 2, width: width, height: text.size().height))
            if menu {
                let image = NSImage(systemSymbolName: "chevron.down", accessibilityDescription: nil)?
                    .withSymbolConfiguration(.init(pointSize: 10, weight: .medium))?
                    .withSymbolConfiguration(.init(paletteColors: [cell.isEnabled ? foreground : .disabledControlTextColor]))
                image?.draw(in: NSRect(x: start + width + 7, y: frame.midY - 5, width: 11, height: 10),
                            from: .zero, operation: .sourceOver, fraction: 1, respectFlipped: true, hints: nil)
            }
        }
    }
    private final class CardSurface: NSView {
        override func draw(_ dirtyRect: NSRect) {
            super.draw(dirtyRect)
            let shape = NSBezierPath(roundedRect: bounds.insetBy(dx: 0.5, dy: 0.5), xRadius: 19, yRadius: 19)
            NSGradient(starting: Style.color(0xfdfdff, 0x353744), ending: Style.color(0xf5f6fb, 0x2d303c))?
                .draw(in: shape, angle: -45)
            Style.color(0xffffff, 0x535565).setStroke(); shape.lineWidth = 1; shape.stroke()
        }
        override func viewDidChangeEffectiveAppearance() {
            super.viewDidChangeEffectiveAppearance(); needsDisplay = true
            subviews.forEach { $0.needsDisplay = true }
        }
    }
    private final class ActionCell: NSButtonCell {
        var primary = false
        override func draw(withFrame cellFrame: NSRect, in controlView: NSView) {
            Style.drawButton(self, frame: cellFrame, menu: false, primary: primary)
        }
    }
    private final class MenuCell: NSPopUpButtonCell {
        override func draw(withFrame cellFrame: NSRect, in controlView: NSView) {
            Style.drawButton(self, frame: cellFrame, menu: true, primary: false)
        }
    }
    let entryID: UUID
    let reminder: PluginReminder
    let display: NSScreen?
    private var onResponse: ((String?) -> Void)?
    private let buttons = NSStackView()
    private let errorLabel = NSTextField(wrappingLabelWithString: "")
    private let closeButton = NSButton()
    private let stack = NSStackView()

    init(entry: PluginLauncherEntry, reminder: PluginReminder, onResponse: @escaping (String?) -> Void) {
        entryID = entry.id; self.reminder = reminder; self.onResponse = onResponse
        display = NSScreen.screens.first { NSMouseInRect(NSEvent.mouseLocation, $0.frame, false) } ?? NSScreen.main
        let panel = CardPanel(contentRect: NSRect(x: 0, y: 0, width: 360, height: 160),
                              styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        panel.title = "AnyWhere · " + entry.definition.title
        panel.isReleasedWhenClosed = false; panel.hidesOnDeactivate = false
        panel.level = .floating; panel.isOpaque = false; panel.backgroundColor = .clear
        panel.hasShadow = true; panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        super.init(window: panel)
        panel.delegate = self
        let surface = CardSurface()
        surface.wantsLayer = true; surface.layer?.cornerRadius = 19; surface.layer?.masksToBounds = true
        panel.contentView = surface
        let icon = NSImageView(image: NSApp.applicationIconImage)
        icon.translatesAutoresizingMaskIntoConstraints = false
        icon.widthAnchor.constraint(equalToConstant: 24).isActive = true
        icon.heightAnchor.constraint(equalToConstant: 24).isActive = true
        let source = NSTextField(labelWithString: "AnyWhere · " + entry.definition.title)
        let sourceText = NSMutableAttributedString(string: source.stringValue, attributes: [
            .font: NSFont.systemFont(ofSize: 11), .foregroundColor: Style.secondary
        ])
        sourceText.addAttributes([.font: NSFont.systemFont(ofSize: 11, weight: .medium), .foregroundColor: NSColor.labelColor],
                                 range: NSRange(location: 0, length: "AnyWhere".count))
        source.attributedStringValue = sourceText
        source.lineBreakMode = .byTruncatingTail
        closeButton.image = NSImage(systemSymbolName: "xmark", accessibilityDescription: "关闭通知")
        closeButton.symbolConfiguration = NSImage.SymbolConfiguration(pointSize: 10, weight: .medium)
        closeButton.contentTintColor = .secondaryLabelColor
        closeButton.isBordered = false; closeButton.target = self; closeButton.action = #selector(dismiss)
        closeButton.setAccessibilityLabel("关闭通知")
        closeButton.widthAnchor.constraint(equalToConstant: 24).isActive = true
        closeButton.heightAnchor.constraint(equalToConstant: 24).isActive = true
        let header = NSStackView(views: [icon, source, NSView(), closeButton])
        header.spacing = 8
        let title = NSTextField(wrappingLabelWithString: reminder.title)
        title.font = .systemFont(ofSize: 16, weight: .semibold); title.maximumNumberOfLines = 3
        let body = NSTextField(wrappingLabelWithString: reminder.body)
        body.font = .systemFont(ofSize: 12); body.textColor = Style.secondary; body.maximumNumberOfLines = 4
        body.allowsEditingTextAttributes = true
        let bodyText = NSMutableAttributedString(string: reminder.body, attributes: [
            .font: NSFont.systemFont(ofSize: 12), .foregroundColor: Style.secondary
        ])
        if let detector = try? NSDataDetector(types: NSTextCheckingResult.CheckingType.link.rawValue) {
            for match in detector.matches(in: reminder.body, range: NSRange(location: 0, length: bodyText.length)) {
                guard let url = match.url, ["http", "https"].contains(url.scheme?.lowercased() ?? "") else { continue }
                bodyText.addAttributes([
                    .link: url, .foregroundColor: Style.color(0x6650cb, 0xd3c2ff),
                    .underlineStyle: NSUnderlineStyle.single.rawValue, .cursor: NSCursor.pointingHand
                ], range: match.range)
            }
        }
        body.attributedStringValue = bodyText
        buttons.orientation = .horizontal; buttons.spacing = 9; buttons.distribution = .fillEqually
        let actions = reminder.actions ?? []
        for (index, action) in actions.enumerated() {
            let button: NSButton
            if let options = action.options {
                let popup = NSPopUpButton(frame: .zero, pullsDown: true)
                popup.cell = MenuCell(textCell: "", pullsDown: true)
                popup.addItem(withTitle: action.title)
                popup.menu?.font = .systemFont(ofSize: 12)
                popup.menu?.minimumWidth = 184
                for option in options {
                    let item = NSMenuItem(title: option.title, action: #selector(chooseOption(_:)), keyEquivalent: "")
                    item.target = self; item.representedObject = option.id; popup.menu?.addItem(item)
                }
                button = popup
            } else {
                button = NSButton(title: action.title, target: self, action: #selector(choose(_:)))
                let cell = ActionCell(textCell: action.title); cell.primary = index == actions.count - 1
                button.cell = cell; button.target = self; button.action = #selector(choose(_:))
            }
            button.identifier = NSUserInterfaceItemIdentifier(action.id)
            button.setAccessibilityLabel(action.title)
            button.font = .systemFont(ofSize: 12, weight: .medium)
            button.cell?.lineBreakMode = .byTruncatingTail
            button.bezelStyle = .rounded; button.controlSize = .regular
            button.heightAnchor.constraint(equalToConstant: 33).isActive = true
            buttons.addArrangedSubview(button)
        }
        if reminder.actions?.isEmpty != false {
            let open = NSButton(title: "打开", target: self, action: #selector(openPlugin))
            let cell = ActionCell(textCell: "打开"); cell.primary = true
            open.cell = cell; open.target = self; open.action = #selector(openPlugin)
            open.heightAnchor.constraint(equalToConstant: 33).isActive = true
            open.bezelStyle = .rounded; buttons.addArrangedSubview(open)
        }
        errorLabel.font = .systemFont(ofSize: 11); errorLabel.textColor = .systemRed
        errorLabel.maximumNumberOfLines = 3; errorLabel.isHidden = true
        stack.orientation = .vertical; stack.alignment = .leading; stack.spacing = 13
        for view in [header, title] { stack.addArrangedSubview(view) }
        if !reminder.body.isEmpty { stack.addArrangedSubview(body) }
        stack.addArrangedSubview(errorLabel); stack.addArrangedSubview(buttons)
        stack.setCustomSpacing(reminder.body.isEmpty ? 17 : 6, after: title)
        if !reminder.body.isEmpty { stack.setCustomSpacing(17, after: body) }
        stack.translatesAutoresizingMaskIntoConstraints = false; surface.addSubview(stack)
        NSLayoutConstraint.activate([
            stack.leadingAnchor.constraint(equalTo: surface.leadingAnchor, constant: 16),
            stack.trailingAnchor.constraint(equalTo: surface.trailingAnchor, constant: -16),
            stack.topAnchor.constraint(equalTo: surface.topAnchor, constant: 15)
        ])
        for view in stack.arrangedSubviews { view.widthAnchor.constraint(equalTo: stack.widthAnchor).isActive = true }
        resizeToContent()
        if let display { panel.setFrameTopLeftPoint(NSPoint(x: display.visibleFrame.maxX - panel.frame.width - 16, y: display.visibleFrame.maxY - 12)) }
    }
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }
    private func resizeToContent() {
        window?.contentView?.layoutSubtreeIfNeeded()
        let top = window.map { $0.frame.maxY } ?? 0
        window?.setContentSize(NSSize(width: 360, height: stack.fittingSize.height + 29))
        if let window { window.setFrameTopLeftPoint(NSPoint(x: window.frame.minX, y: top)) }
    }
    func setProcessing(_ processing: Bool, error: String? = nil) {
        buttons.arrangedSubviews.compactMap { $0 as? NSButton }.forEach { $0.isEnabled = !processing }
        closeButton.isEnabled = !processing
        errorLabel.stringValue = processing ? "正在处理…" : error ?? ""
        errorLabel.textColor = processing ? .secondaryLabelColor : .systemRed
        errorLabel.isHidden = errorLabel.stringValue.isEmpty
        resizeToContent()
    }
    @objc private func choose(_ sender: NSButton) {
        if let id = sender.identifier?.rawValue { selectAction(id) }
    }
    @objc private func chooseOption(_ sender: NSMenuItem) {
        if let id = sender.representedObject as? String { selectAction(id) }
    }
    func selectAction(_ id: String) {
        guard let action = reminder.action(for: id) else { return }
        if action.background == true {
            setProcessing(true); onResponse?(id)
        } else { finish(id) }
    }
    @objc private func dismiss() { finish(nil) }
    @objc private func openPlugin() { finish(UNNotificationDefaultActionIdentifier) }
    private func finish(_ action: String?) {
        let callback = onResponse; onResponse = nil
        close(); callback?(action)
    }
    func windowWillClose(_ notification: Notification) {
        let callback = onResponse; onResponse = nil; callback?(nil)
    }
}
