import AppKit

/// Owns what's on the Touch Bar. Two layouts:
///
///   idle:        [esc] [✳] [usage]            [skills…] [⚡ skip perms]
///   permission:  [esc] [✳] [message]  [Allow Once] [Always Allow] [Reject]
///
/// Presented system-modally via SystemModalTouchBar (see that file for the
/// fine print). The physical Esc key disappears while a system-modal bar is
/// up, which is why we always draw our own as the leftmost item.
final class TouchBarController: NSObject, NSTouchBarDelegate {
    enum Mode: Equatable {
        case idle
        case permission(message: String)
    }

    private let config: Config
    private let usageTracker: UsageTracker
    private var presentedBar: NSTouchBar?
    private var mode: Mode = .idle
    private var usageLabel: NSTextField?

    init(config: Config, usageTracker: UsageTracker) {
        self.config = config
        self.usageTracker = usageTracker
        super.init()
        usageTracker.onUpdate = { [weak self] in
            self?.usageLabel?.stringValue = usageTracker.summary
        }
    }

    // MARK: - Presenting

    func show(_ mode: Mode) {
        // Re-presenting an identical bar makes it flicker; skip if unchanged.
        if presentedBar != nil && mode == self.mode { return }
        self.mode = mode
        dismiss()

        let bar = NSTouchBar()
        bar.delegate = self
        switch mode {
        case .idle:
            var ids: [NSTouchBarItem.Identifier] = [.escKey, .claudeGlyph]
            if config.showUsage { ids.append(.usage) }
            ids.append(.flexibleSpace)
            ids.append(.skills)
            if config.offerSkipPermissions { ids.append(.skipPermissions) }
            bar.defaultItemIdentifiers = ids
        case .permission:
            bar.defaultItemIdentifiers = [
                .escKey, .claudeGlyph, .permissionMessage, .flexibleSpace,
                .allowOnce, .alwaysAllow, .reject,
            ]
        }

        SystemModalTouchBar.present(bar)
        presentedBar = bar
    }

    func dismiss() {
        if let bar = presentedBar {
            SystemModalTouchBar.dismiss(bar)
            presentedBar = nil
        }
    }

    // MARK: - NSTouchBarDelegate

    func touchBar(_ touchBar: NSTouchBar,
                  makeItemForIdentifier identifier: NSTouchBarItem.Identifier) -> NSTouchBarItem? {
        switch identifier {
        case .escKey:
            // The one key everyone still needs. Sends a real Escape keypress.
            return button(identifier, title: "esc", action: #selector(pressEscape))

        case .claudeGlyph:
            let item = NSCustomTouchBarItem(identifier: identifier)
            item.view = ClaudeGlyphView(frame: NSRect(x: 0, y: 0, width: 30, height: 30))
            return item

        case .usage:
            let item = NSCustomTouchBarItem(identifier: identifier)
            let label = NSTextField(labelWithString: usageTracker.summary)
            label.font = .monospacedDigitSystemFont(ofSize: 13, weight: .regular)
            label.textColor = .secondaryLabelColor
            usageLabel = label
            item.view = label
            return item

        case .skills:
            // One button per configured skill, side by side.
            let item = NSCustomTouchBarItem(identifier: identifier)
            let stack = NSStackView()
            stack.orientation = .horizontal
            stack.spacing = 8
            for skill in config.skills {
                let b = NSButton(title: skill, target: self, action: #selector(runSkill(_:)))
                b.bezelColor = NSColor.darkGray
                stack.addArrangedSubview(b)
            }
            item.view = stack
            return item

        case .skipPermissions:
            return button(identifier, title: "⚡ skip perms", action: #selector(startSkipPermissionsSession))

        case .permissionMessage:
            guard case let .permission(message) = mode else { return nil }
            let item = NSCustomTouchBarItem(identifier: identifier)
            let label = NSTextField(labelWithString: message)
            label.lineBreakMode = .byTruncatingTail
            label.font = .systemFont(ofSize: 13)
            item.view = label
            return item

        case .allowOnce:
            return button(identifier, title: "Allow Once", action: #selector(allowOnce))

        case .alwaysAllow:
            return button(identifier, title: "Always Allow", action: #selector(alwaysAllow))

        case .reject:
            let item = button(identifier, title: "Reject", action: #selector(reject))
            (item.view as? NSButton)?.bezelColor = NSColor(srgbRed: 0.45, green: 0.15, blue: 0.12, alpha: 1)
            return item

        default:
            return nil
        }
    }

    private func button(_ identifier: NSTouchBarItem.Identifier,
                        title: String, action: Selector) -> NSCustomTouchBarItem {
        let item = NSCustomTouchBarItem(identifier: identifier)
        item.view = NSButton(title: title, target: self, action: action)
        return item
    }

    // MARK: - Button actions
    // Claude Code's prompts are keyboard-driven, so each button just presses
    // the matching key in the frontmost terminal.

    @objc private func pressEscape() {
        KeySender.tap(KeySender.escape)
    }

    @objc private func runSkill(_ sender: NSButton) {
        KeySender.type(sender.title, pressReturn: true)
    }

    @objc private func startSkipPermissionsSession() {
        // Typed, not auto-submitted — a deliberate speed bump so nobody
        // YOLOs into --dangerously-skip-permissions by fat finger.
        KeySender.type("claude --dangerously-skip-permissions")
    }

    @objc private func allowOnce() {
        KeySender.type("1")
        show(.idle)
    }

    @objc private func alwaysAllow() {
        KeySender.type("2")
        show(.idle)
    }

    @objc private func reject() {
        KeySender.tap(KeySender.escape)
        show(.idle)
    }
}

private extension NSTouchBarItem.Identifier {
    static let escKey = Self("dev.claudebar.esc")
    static let claudeGlyph = Self("dev.claudebar.glyph")
    static let usage = Self("dev.claudebar.usage")
    static let skills = Self("dev.claudebar.skills")
    static let skipPermissions = Self("dev.claudebar.skip-permissions")
    static let permissionMessage = Self("dev.claudebar.permission.message")
    static let allowOnce = Self("dev.claudebar.permission.allow-once")
    static let alwaysAllow = Self("dev.claudebar.permission.always-allow")
    static let reject = Self("dev.claudebar.permission.reject")
}
