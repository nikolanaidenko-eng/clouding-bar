import AppKit

/// A compact two-line meter for the Touch Bar:
///
///   Session              42% · resets 1:23
///   ██████████░░░░░░░░░░░░░░░░░░░░░░░░░░░
///
/// Built from labels and layers (not custom drawing), which the Touch Bar
/// renders reliably. Bar color goes green → yellow (70%) → red (90%).
final class MeterView: NSView {
    var title: String { didSet { titleLabel.stringValue = title } }
    var valueText: String = "—" { didSet { valueLabel.stringValue = valueText } }
    /// 0...100, or nil when no data has arrived yet.
    var percent: Double? { didSet { updateFill() } }

    private let preferredWidth: CGFloat
    private let titleLabel = NSTextField(labelWithString: "")
    private let valueLabel = NSTextField(labelWithString: "—")
    private let trackLayer = CALayer()
    private let fillLayer = CALayer()

    init(title: String, width: CGFloat) {
        self.title = title
        self.preferredWidth = width
        super.init(frame: NSRect(x: 0, y: 0, width: width, height: 30))
        wantsLayer = true
        translatesAutoresizingMaskIntoConstraints = false
        widthAnchor.constraint(equalToConstant: width).isActive = true
        heightAnchor.constraint(equalToConstant: 30).isActive = true

        let font = NSFont.monospacedDigitSystemFont(ofSize: 12, weight: .regular)
        titleLabel.font = font
        titleLabel.textColor = .secondaryLabelColor
        titleLabel.stringValue = title
        valueLabel.font = font
        valueLabel.textColor = .labelColor
        valueLabel.alignment = .right

        for label in [titleLabel, valueLabel] {
            label.translatesAutoresizingMaskIntoConstraints = false
            addSubview(label)
        }
        NSLayoutConstraint.activate([
            titleLabel.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 2),
            titleLabel.topAnchor.constraint(equalTo: topAnchor, constant: 1),
            valueLabel.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -2),
            valueLabel.topAnchor.constraint(equalTo: topAnchor, constant: 1),
            valueLabel.leadingAnchor.constraint(greaterThanOrEqualTo: titleLabel.trailingAnchor, constant: 6),
        ])

        trackLayer.backgroundColor = NSColor(white: 0.28, alpha: 1).cgColor
        trackLayer.cornerRadius = 3
        fillLayer.cornerRadius = 3
        layer?.addSublayer(trackLayer)
        layer?.addSublayer(fillLayer)
    }

    required init?(coder: NSCoder) { fatalError("not used") }

    override var intrinsicContentSize: NSSize {
        NSSize(width: preferredWidth, height: 30)
    }

    override func layout() {
        super.layout()
        updateFill()
    }

    private func updateFill() {
        let track = CGRect(x: 2, y: 3, width: max(0, bounds.width - 4), height: 6)
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        trackLayer.frame = track
        if let p = percent {
            let clamped = min(max(p, 0), 100)
            var fill = track
            fill.size.width = clamped > 0 ? max(6, track.width * CGFloat(clamped / 100)) : 0
            fillLayer.frame = fill
            fillLayer.backgroundColor = Self.color(for: clamped).cgColor
        } else {
            fillLayer.frame = .zero
        }
        CATransaction.commit()
    }

    static func color(for percent: Double) -> NSColor {
        switch percent {
        case ..<70: return NSColor(srgbRed: 0.36, green: 0.79, blue: 0.65, alpha: 1)
        case ..<90: return NSColor(srgbRed: 0.94, green: 0.62, blue: 0.15, alpha: 1)
        default: return NSColor(srgbRed: 0.89, green: 0.29, blue: 0.29, alpha: 1)
        }
    }
}
