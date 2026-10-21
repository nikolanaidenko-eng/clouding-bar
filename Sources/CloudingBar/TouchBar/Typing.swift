import AppKit

/// The answer field on the bar (TB-Typing): what you type on the keyboard
/// shows here. 13 pt text that drops to 11 and 9.5 pt as it grows
/// (40 / 70 characters), then scrolls to keep the end in view.
final class TypingFieldView: NSView {
    private let clip = NSView()
    private let label = NSTextField(labelWithString: "")
    private let caret = CALayer()
    private var text = ""
    /// What the empty field says.
    var placeholder = "Type your answer" { didSet { set(text: text) } }
    /// The blinking caret: off where the field only waits for a tap.
    var showsCaret = true { didSet { caret.isHidden = !showsCaret } }
    /// Room kept clear at the right end, for the commands inside the field.
    var trailingInset: CGFloat = 0 { didSet { needsLayout = true } }

    override init(frame: NSRect) {
        super.init(frame: frame)
        wantsLayer = true
        layer?.cornerRadius = Palette.radius
        layer?.borderWidth = 1
        layer?.borderColor = Palette.border.cgColor
        layer?.backgroundColor = Palette.field.cgColor
        clip.wantsLayer = true
        clip.layer?.masksToBounds = true
        addSubview(clip)
        label.lineBreakMode = .byClipping
        clip.addSubview(label)
        caret.backgroundColor = Palette.text.cgColor
        clip.layer?.addSublayer(caret)
        if !Palette.reduceMotion {
            let blink = CAKeyframeAnimation(keyPath: "opacity")
            blink.values = [1, 1, 0, 0]
            blink.keyTimes = [0, 0.5, 0.5, 1]
            blink.duration = 1
            blink.repeatCount = .infinity
            caret.add(blink, forKey: "blink")
        }
        setAccessibilityRole(.textField)
        set(text: "")
    }

    required init?(coder: NSCoder) { fatalError("not used") }

    func set(text: String) {
        self.text = text
        let size: CGFloat = text.count <= 40 ? 13 : text.count <= 70 ? 11 : 9.5
        if text.isEmpty {
            label.attributedStringValue = NSAttributedString(string: placeholder, attributes: [
                .font: NSFont.systemFont(ofSize: 13), .foregroundColor: Palette.placeholder,
            ])
        } else {
            label.attributedStringValue = NSAttributedString(string: text, attributes: [
                .font: NSFont.systemFont(ofSize: size), .foregroundColor: Palette.text,
            ])
        }
        setAccessibilityValue(text)
        needsLayout = true
    }

    override func layout() {
        super.layout()
        clip.frame = bounds.insetBy(dx: 10, dy: 1)
        clip.frame.size.width = max(0, clip.frame.width - trailingInset)
        let width = ceil(label.attributedStringValue.size().width) + 4
        let height = ceil(label.attributedStringValue.size().height) + 2
        // Keep the end (where you type) in view.
        let textWidth = text.isEmpty ? 0 : width - 4
        let x = min(0, clip.bounds.width - 3 - textWidth)
        label.frame = CGRect(x: x, y: (clip.bounds.height - height) / 2, width: width, height: height)
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        caret.frame = CGRect(x: x + textWidth + 1, y: (clip.bounds.height - 15) / 2, width: 1.5, height: 15)
        CATransaction.commit()
    }
}

/// The chat field with your commands inside it, at its right end, as in
/// the widget's message box: `field` is the typing field or, between
/// messages, a button that looks like one.
final class ChatBoxView: NSView {
    private let field: NSView
    private let commands: [BarButton]
    private let widths: [CGFloat]
    static let gap: CGFloat = 4

    init(field: NSView, commands: [BarButton], compact: Bool = false) {
        self.field = field
        self.commands = commands
        widths = commands.map { compact ? min(86, max(44, $0.fittingWidth(padding: 7)))
                                        : min(110, max(46, $0.fittingWidth(padding: 10))) }
        super.init(frame: .zero)
        addSubview(field)
        commands.forEach(addSubview)
        let inset = commandsWidth + (commands.isEmpty ? 0 : 4)
        (field as? TypingFieldView)?.trailingInset = inset
        (field as? ComposeFieldButton)?.trailingInset = inset
    }

    required init?(coder: NSCoder) { fatalError("not used") }

    var commandsWidth: CGFloat { widths.reduce(0, +) + Self.gap * CGFloat(max(0, commands.count - 1)) }

    override func layout() {
        super.layout()
        field.frame = bounds
        var x = bounds.maxX - 3
        for (b, w) in zip(commands, widths).reversed() {
            x -= w
            b.frame = CGRect(x: x, y: 3, width: w, height: max(0, bounds.height - 6))
            x -= Self.gap
        }
    }
}

/// The chat field on the bar between messages: looks like the typing
/// field, and a tap on it starts writing.
final class ComposeFieldButton: NSButton {
    private let field = TypingFieldView()
    var trailingInset: CGFloat {
        get { field.trailingInset }
        set { field.trailingInset = newValue }
    }
    private let onTap: () -> Void

    init(placeholder: String, onTap: @escaping () -> Void) {
        self.onTap = onTap
        super.init(frame: .zero)
        isBordered = false
        title = ""
        field.placeholder = placeholder
        field.showsCaret = false
        addSubview(field)
        target = self
        action = #selector(fire)
        setAccessibilityLabel(placeholder)
    }

    required init?(coder: NSCoder) { fatalError("not used") }

    override func layout() {
        super.layout()
        field.frame = bounds
    }

    /// The whole field is the button.
    override func hitTest(_ point: NSPoint) -> NSView? { frame.contains(point) ? self : nil }

    @objc private func fire() { onTap() }
}

/// Where the typing actually happens. Keys can't go to the Touch Bar, so
/// while you answer "Other…" an invisible panel of ours takes the keyboard
/// (a non-activating panel: your editor stays the frontmost app). A real
/// text field means every keyboard layout and dictation work.
final class TypingInput: NSObject, NSTextFieldDelegate, NSWindowDelegate {
    var onChange: ((String) -> Void)?
    var onSubmit: ((String) -> Void)?
    var onCancel: (() -> Void)?

    private var panel: KeyPanel?
    private let field = NSTextField()

    var isActive: Bool { panel?.isVisible ?? false }
    var text: String { field.stringValue }

    func begin(with draft: String = "") {
        if panel == nil {
            let p = KeyPanel(contentRect: NSRect(x: 0, y: 0, width: 320, height: 24),
                             styleMask: [.nonactivatingPanel, .borderless], backing: .buffered, defer: false)
            p.isFloatingPanel = true
            p.level = .floating
            p.alphaValue = 0
            p.ignoresMouseEvents = true
            p.hidesOnDeactivate = false
            p.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
            field.frame = p.contentView!.bounds
            field.delegate = self
            p.delegate = self // its field editor brings no Touch Bar of its own
            field.isBezeled = false
            field.focusRingType = .none
            field.cell?.isScrollable = true
            field.cell?.wraps = false
            p.contentView?.addSubview(field)
            panel = p
        }
        field.stringValue = draft
        if let screen = NSScreen.main {
            // Near the top center, so a dictation popup lands somewhere sensible.
            panel?.setFrameOrigin(NSPoint(x: screen.frame.midX - 160, y: screen.visibleFrame.maxY - 40))
        }
        panel?.orderFrontRegardless()
        panel?.makeKey()
        panel?.makeFirstResponder(field)
    }

    func end() {
        guard let panel, panel.isVisible else { return }
        panel.orderOut(nil)
        field.stringValue = ""
    }

    /// Adds dictated text at the end of the answer.
    func insert(_ text: String) {
        guard isActive else { return }
        let current = field.stringValue
        field.stringValue = current.isEmpty || current.hasSuffix(" ") ? current + text : current + " " + text
        onChange?(field.stringValue)
    }

    /// The system's dictation into the field (it asks to turn dictation on
    /// if it's off).
    func startDictation() {
        guard let panel, panel.isVisible else { return }
        panel.makeKey()
        panel.makeFirstResponder(field)
        NSApp.sendAction(Selector(("startDictation:")), to: nil, from: nil)
    }

    func controlTextDidChange(_ obj: Notification) {
        onChange?(field.stringValue)
    }

    func control(_ control: NSControl, textView: NSTextView, doCommandBy selector: Selector) -> Bool {
        switch selector {
        case #selector(NSResponder.insertNewline(_:)):
            onSubmit?(field.stringValue)
            return true
        case #selector(NSResponder.cancelOperation(_:)):
            onCancel?()
            return true
        default:
            return false
        }
    }

    /// The hidden field's editor: no Touch Bar of its own (typing
    /// suggestions), which beside Apple's buttons would take the place of
    /// Clouding Bar's while you type.
    func windowWillReturnFieldEditor(_ sender: NSWindow, to client: Any?) -> Any? {
        quietEditor.isFieldEditor = true
        quietEditor.isAutomaticTextCompletionEnabled = false
        return quietEditor
    }

    private let quietEditor = QuietEditor()
}

private final class QuietEditor: NSTextView {
    override func makeTouchBar() -> NSTouchBar? { nil }
    override var touchBar: NSTouchBar? { get { nil } set {} }
}

private final class KeyPanel: NSPanel {
    override var canBecomeKey: Bool { true }
    override func makeTouchBar() -> NSTouchBar? { nil }
}
