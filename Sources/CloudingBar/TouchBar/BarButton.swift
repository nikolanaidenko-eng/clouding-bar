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

    /// A title too long for the button plays across it, slowly, and
    /// starts over (chat names).
    private let marquee: Bool
    private let fullTitle: String
    private let dotColor: UInt32?
    private var scroller: CALayer?

    init(_ title: String, style: Style = .normal, fontSize: CGFloat = Palette.buttonFont,
         icon: NSImage? = nil, dot: UInt32? = nil, symbol: (name: String, tint: UInt32)? = nil,
         marquee: Bool = false, onTap: (() -> Void)? = nil) {
        self.style = style
        self.fontSize = fontSize
        self.onTap = onTap
        self.marquee = marquee && symbol == nil && icon == nil
        self.fullTitle = title
        self.dotColor = dot
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
        if let dot {
            // A chat's colour before its name.
            image = Self.dot(dot)
            imagePosition = .imageLeading
            imageHugsTitle = true
            hasDot = true
        } else if let symbol, let img = NSImage(systemSymbolName: symbol.name, accessibilityDescription: nil)?
            .withSymbolConfiguration(NSImage.SymbolConfiguration(pointSize: 11, weight: .semibold)
                .applying(NSImage.SymbolConfiguration(paletteColors: [NSColor(hex: symbol.tint)]))) {
            // A coloured icon before the words, as in Settings.
            image = img
            imagePosition = .imageLeading
            imageHugsTitle = true
            hasDot = true
        }
        if marquee {
            // Drawn in updateMarquee, sliding when it doesn't fit.
            attributedTitle = NSAttributedString(string: "")
            image = nil
        }
        updateLook()
    }

    private var hasDot = false

    static func dot(_ color: UInt32) -> NSImage {
        NSImage(size: NSSize(width: 13, height: 8), flipped: false) { _ in
            NSColor(srgbRed: CGFloat((color >> 16) & 0xFF) / 255, green: CGFloat((color >> 8) & 0xFF) / 255,
                    blue: CGFloat(color & 0xFF) / 255, alpha: 1).setFill()
            NSBezierPath(ovalIn: NSRect(x: 0, y: 0, width: 8, height: 8)).fill()
            return true
        }
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
        ceil(titleWidth) + padding * 2 + (hasDot ? 17 : 0)
    }

    private var titleFont: NSFont { NSFont.systemFont(ofSize: fontSize, weight: style == .primary ? .semibold : .regular) }
    private var titleWidth: CGFloat { (fullTitle as NSString).size(withAttributes: [.font: titleFont]).width }

    override func layout() {
        super.layout()
        if marquee { updateMarquee() }
    }

    /// The dot and the name, drawn here: centred when the name fits, else
    /// from the left edge, sliding along to its end and starting over.
    private func updateMarquee() {
        guard let layer else { return }
        scroller?.removeFromSuperlayer()
        scroller = nil
        let dotRoom: CGFloat = dotColor != nil ? 13 : 0
        let width = ceil(titleWidth)
        let room = bounds.width - 18 - dotRoom
        guard room > 10 else { return }
        let slides = width > room + 1 && !Palette.reduceMotion
        let shown = min(width, room)
        let x0 = slides ? 9 : (bounds.width - dotRoom - shown) / 2

        let box = CALayer()
        box.frame = bounds
        if let dotColor {
            let dot = CALayer()
            dot.frame = CGRect(x: x0, y: bounds.midY - 4, width: 8, height: 8)
            dot.cornerRadius = 4
            dot.backgroundColor = NSColor(hex: dotColor).cgColor
            box.addSublayer(dot)
        }
        let clip = CALayer()
        clip.frame = CGRect(x: x0 + dotRoom, y: 0, width: shown, height: bounds.height)
        clip.masksToBounds = true
        let text = CATextLayer()
        let color: NSColor = style == .deny ? Palette.denyText : style == .primary ? .white : Palette.text
        text.string = NSAttributedString(string: fullTitle, attributes: [.font: titleFont, .foregroundColor: color])
        text.contentsScale = window?.backingScaleFactor ?? 2
        text.truncationMode = slides ? .none : .end
        let height = ceil(titleFont.ascender - titleFont.descender) + 2
        text.frame = CGRect(x: 0, y: (bounds.height - height) / 2, width: slides ? width : shown, height: height)
        clip.addSublayer(text)
        box.addSublayer(clip)
        layer.addSublayer(box)
        scroller = box
        guard slides else { return }
        // Rest at the start, glide to the end (about 25 pt/s), rest, again.
        let travel = width - room
        let move = Double(travel) / 25, rest = 1.4
        let total = rest + move + rest
        let slide = CAKeyframeAnimation(keyPath: "position.x")
        let start = width / 2
        slide.values = [start, start, start - travel, start - travel]
        slide.keyTimes = [0, NSNumber(value: rest / total), NSNumber(value: (rest + move) / total), 1]
        slide.duration = total
        slide.repeatCount = .infinity
        text.add(slide, forKey: "marquee")
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
