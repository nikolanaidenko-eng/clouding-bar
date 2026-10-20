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

/// Where the typing actually happens. Keys can't go to the Touch Bar, so
/// while you answer "Other…" an invisible panel of ours takes the keyboard
/// (a non-activating panel: your editor stays the frontmost app). A real
/// text field means every keyboard layout and dictation work.
final class TypingInput: NSObject, NSTextFieldDelegate {
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
}

private final class KeyPanel: NSPanel {
    override var canBecomeKey: Bool { true }
}
