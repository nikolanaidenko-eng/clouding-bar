import AppKit

/// A Touch Bar button drawn to the design: flat rounded rectangle,
/// 30 pt tall, 13 pt text. Borderless NSButton, so the Touch Bar's own
/// touch handling still drives it; the look comes from the layer.
final class BarButton: NSButton {
    enum Style {
        case normal    // #2C2C2E, white text
        case primary   // blue, white semibold (Allow, Send, Compact)
        case deny      // #2C2C2E, red text
        case outline   // black with a #48484A border (Other…)
        case selected  // a picked option in a multi-select question
    }

    var onTap: (() -> Void)?
    private let style: Style
    private let fontSize: CGFloat

    init(_ title: String, style: Style = .normal, fontSize: CGFloat = Palette.buttonFont,
         icon: NSImage? = nil, onTap: (() -> Void)? = nil) {
        self.style = style
        self.fontSize = fontSize
        self.onTap = onTap
        super.init(frame: .zero)
        isBordered = false
        wantsLayer = true
        layer?.cornerRadius = Palette.radius
        target = self
        action = #selector(fire)
        setAccessibilityLabel(title)
        if let icon {
            image = icon
            imagePosition = .imageOnly
            contentTintColor = Palette.text
            self.title = ""
        } else {
            setTitle(title)
        }
        updateLook()
    }

    required init?(coder: NSCoder) { fatalError("not used") }

    func setTitle(_ text: String) {
        let paragraph = NSMutableParagraphStyle()
        paragraph.alignment = .center
        paragraph.lineBreakMode = .byTruncatingTail
        let color: NSColor
        switch style {
        case .primary: color = .white
        case .deny: color = Palette.denyText
        default: color = Palette.text
        }
        let weight: NSFont.Weight = style == .primary ? .semibold : .regular
        attributedTitle = NSAttributedString(string: text, attributes: [
            .font: NSFont.systemFont(ofSize: fontSize, weight: weight),
            .foregroundColor: color,
            .paragraphStyle: paragraph,
        ])
    }

    /// Width that fits the title with `padding` on each side.
    func fittingWidth(padding: CGFloat) -> CGFloat {
        ceil(attributedTitle.size().width) + padding * 2
    }

    override var isHighlighted: Bool {
        didSet { updateLook() }
    }

    private func updateLook() {
        var background: NSColor
        switch style {
        case .primary: background = Palette.action
        case .outline: background = .black
        case .selected: background = Palette.action.withAlphaComponent(0.55)
        default: background = Palette.control
        }
        if isHighlighted {
            background = background.blended(withFraction: 0.25, of: .white) ?? background
        }
        layer?.backgroundColor = background.cgColor
        layer?.borderWidth = style == .outline ? 1 : 0
        layer?.borderColor = Palette.border.cgColor
    }

    @objc private func fire() { onTap?() }
}
