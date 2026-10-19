import AppKit

/// A meter from TB-Normal: label left, value right (11 pt), a 4 pt bar
/// under them. The fill grows from 0 when it appears and slides to a new
/// value when it changes (900 ms, the design curve).
///
///   Session              42% · 1:23
///   ██████████░░░░░░░░░░░░░░░░░░░░
final class MeterView: NSView {
    private let titleLabel = NSTextField(labelWithString: "")
    private let valueLabel = NSTextField(labelWithString: "—")
    private let track = CALayer()
    private let fill = CALayer()
    private var shownPercent: Double?
    private var appeared = false
    private var breathing = false

    /// The context warning look: red label and value (TB-Context).
    var alarm = false {
        didSet {
            guard alarm != oldValue else { return }
            restyle()
            if appeared { setFill(shownPercent, animated: false) }
        }
    }

    /// The context meter "breathes" (2 s) at 90% and up.
    var breathesWhenFull = false

    override init(frame: NSRect) {
        super.init(frame: frame)
        wantsLayer = true
        for label in [titleLabel, valueLabel] {
            label.lineBreakMode = .byTruncatingTail
            label.maximumNumberOfLines = 1
            label.cell?.truncatesLastVisibleLine = true
            addSubview(label)
        }
        valueLabel.alignment = .right
        track.backgroundColor = Palette.track.cgColor
        track.cornerRadius = 2
        track.masksToBounds = true
        fill.anchorPoint = .zero
        fill.cornerRadius = 2
        track.addSublayer(fill)
        layer?.addSublayer(track)
        restyle()
    }

    required init?(coder: NSCoder) { fatalError("not used") }

    func set(title: String, percent: Double?, detail: String?) {
        titleLabel.stringValue = title
        titleLabel.isHidden = title.isEmpty
        let value = NSMutableAttributedString(
            string: percent.map { "\(Int($0.rounded()))%" } ?? "—",
            attributes: [.font: valueFont, .foregroundColor: alarm ? Palette.denyText : Palette.text])
        if let detail, percent != nil {
            value.append(NSAttributedString(string: " · \(detail)", attributes: [
                .font: NSFont.monospacedDigitSystemFont(ofSize: Palette.labelFont, weight: .regular),
                .foregroundColor: Palette.secondary,
            ]))
        }
        valueLabel.attributedStringValue = value
        if percent != shownPercent || !appeared {
            setFill(percent, animated: appeared)
        }
        needsLayout = true
    }

    private var valueFont: NSFont {
        NSFont.monospacedDigitSystemFont(ofSize: Palette.labelFont, weight: alarm ? .semibold : .regular)
    }

    private func restyle() {
        titleLabel.font = .systemFont(ofSize: Palette.labelFont, weight: alarm ? .semibold : .regular)
        titleLabel.textColor = alarm ? Palette.denyText : Palette.secondary
    }

    override func layout() {
        super.layout()
        // 11 pt text, 5 pt gap, 4 pt bar: a 20 pt block centered in 30.
        let barY: CGFloat = 5
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        track.frame = CGRect(x: 0, y: barY, width: bounds.width, height: 4)
        fill.bounds.size.height = 4
        fill.position = .zero
        if let p = shownPercent {
            fill.bounds.size.width = bounds.width * CGFloat(min(max(p, 0), 100) / 100)
        }
        CATransaction.commit()

        let textY = barY + 4 + 2
        // NSTextField pads its text by a couple of points on each side.
        let valueWidth = min(ceil(valueLabel.attributedStringValue.size().width) + 6, bounds.width)
        valueLabel.frame = CGRect(x: bounds.width - valueWidth, y: textY, width: valueWidth, height: 15)
        titleLabel.frame = CGRect(x: 0, y: textY, width: max(0, bounds.width - valueWidth - 6), height: 15)

        if !appeared && bounds.width > 0 {
            appeared = true
            setFill(shownPercent, animated: false)
            growFromZero()
        }
    }

    private func setFill(_ percent: Double?, animated: Bool) {
        let old = shownPercent
        shownPercent = percent
        guard let p = percent else {
            fill.bounds.size.width = 0
            return
        }
        let clamped = min(max(p, 0), 100)
        let width = bounds.width * CGFloat(clamped / 100)
        let color = alarm ? Palette.critical : Palette.meterColor(clamped)

        CATransaction.begin()
        CATransaction.setDisableActions(true)
        fill.backgroundColor = color.cgColor
        fill.bounds.size.width = width
        CATransaction.commit()

        if animated, old != nil, !Palette.reduceMotion {
            let a = CABasicAnimation(keyPath: "bounds.size.width")
            a.fromValue = bounds.width * CGFloat(min(max(old ?? 0, 0), 100) / 100)
            a.toValue = width
            a.duration = 0.9
            a.timingFunction = Palette.curve
            fill.add(a, forKey: "grow")
        } else if animated {
            growFromZero()
        }

        // Context at 90% and up "breathes" (2 s).
        let shouldBreathe = clamped >= 90 && breathesWhenFull
        if shouldBreathe != breathing {
            breathing = shouldBreathe
            if shouldBreathe { fill.pulse(low: 0.55, period: 2) } else { fill.removeAnimation(forKey: "pulse") }
        }
    }

    private func growFromZero() {
        guard !Palette.reduceMotion else { return }
        let a = CABasicAnimation(keyPath: "transform.scale.x")
        a.fromValue = 0
        a.toValue = 1
        a.duration = 0.9
        a.timingFunction = Palette.curve
        fill.add(a, forKey: "grow")
    }
}

/// The two thin bars that stand in for the meters while you type an
/// answer (TB-Typing): Session on top, Context below in grey.
final class MiniMetersView: NSView {
    private let tracks = [CALayer(), CALayer()]
    private let fills = [CALayer(), CALayer()]
    private var percents: [Double?] = [nil, nil]

    override init(frame: NSRect) {
        super.init(frame: frame)
        wantsLayer = true
        for (track, fill) in zip(tracks, fills) {
            track.backgroundColor = Palette.track.cgColor
            track.cornerRadius = 1.5
            track.masksToBounds = true
            fill.anchorPoint = .zero
            track.addSublayer(fill)
            layer?.addSublayer(track)
        }
        fills[0].backgroundColor = Palette.meter.cgColor
        fills[1].backgroundColor = Palette.muted.cgColor
        setAccessibilityRole(.levelIndicator)
    }

    required init?(coder: NSCoder) { fatalError("not used") }

    func set(session: Double?, context: Double?) {
        percents = [session, context]
        setAccessibilityLabel("Session \(session.map { "\(Int($0))%" } ?? "—"), context \(context.map { "\(Int($0))%" } ?? "—")")
        needsLayout = true
    }

    override func layout() {
        super.layout()
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        let inset: CGFloat = 2
        let width = bounds.width - inset * 2
        // Two 3 pt bars, 4 pt apart, centered.
        let top = (bounds.height + 10) / 2
        for i in 0..<2 {
            let y = top - 3 - CGFloat(i) * 7
            tracks[i].frame = CGRect(x: inset, y: y, width: width, height: 3)
            fills[i].position = .zero
            fills[i].bounds.size = CGSize(width: width * CGFloat(min(max(percents[i] ?? 0, 0), 100) / 100), height: 3)
        }
        CATransaction.commit()
    }
}
