import AppKit

/// Values from the approved design (design/DESIGN_NOTES.md, design/TB-*).
/// The mockups are in Touch Bar pixels (2170×60 at 2x); points are half.
enum Palette {
    static let text = NSColor(hex: 0xF5F5F7)
    static let secondary = NSColor(hex: 0xA1A1A6)
    static let muted = NSColor(hex: 0x8E8E93)
    static let control = NSColor(hex: 0x2C2C2E)
    static let field = NSColor(hex: 0x1C1C1E)
    static let border = NSColor(hex: 0x48484A)
    static let action = NSColor(hex: 0x0071E3)
    static let warning = NSColor(hex: 0xFF9F0A)
    static let critical = NSColor(hex: 0xFF453A)
    static let denyText = NSColor(hex: 0xFF6961)
    static let track = NSColor(hex: 0x2C2C2E)
    static let fill = NSColor(hex: 0xE5E5EA)
    /// A limit's bar below 70%: the blue of Settings' charts.
    static let meter = NSColor(hex: 0x64A8FF)
    static let placeholder = NSColor(hex: 0x6E6E73)

    /// < 70% blue, 70–90% orange, ≥ 90% red.
    static func meterColor(_ percent: Double) -> NSColor {
        switch percent {
        case ..<70: return meter
        case ..<90: return warning
        default: return critical
        }
    }

    /// cubic-bezier(.2,.8,.2,1), used by every animation in the design.
    static let curve = CAMediaTimingFunction(controlPoints: 0.2, 0.8, 0.2, 1)

    /// The system "Reduce motion" setting.
    static var reduceMotion: Bool { NSWorkspace.shared.accessibilityDisplayShouldReduceMotion }

    // Sizes, in points.
    static let height: CGFloat = 30
    static let gap: CGFloat = 6
    static let edge: CGFloat = 4
    static let radius: CGFloat = 6
    static let buttonFont: CGFloat = 13
    static let labelFont: CGFloat = 11
}

extension NSColor {
    convenience init(hex: UInt32, alpha: CGFloat = 1) {
        self.init(srgbRed: CGFloat((hex >> 16) & 0xFF) / 255,
                  green: CGFloat((hex >> 8) & 0xFF) / 255,
                  blue: CGFloat(hex & 0xFF) / 255,
                  alpha: alpha)
    }
}

extension CALayer {
    /// Opacity pulse: 1 ↔ `low`, ease-in-out, forever (the "waiting" dot,
    /// the breathing context bar). Nothing under Reduce motion.
    func pulse(low: Float, period: CFTimeInterval, key: String = "pulse") {
        removeAnimation(forKey: key)
        guard !Palette.reduceMotion else { return }
        let a = CABasicAnimation(keyPath: "opacity")
        a.fromValue = 1
        a.toValue = low
        a.duration = period / 2
        a.autoreverses = true
        a.repeatCount = .infinity
        a.timingFunction = CAMediaTimingFunction(name: .easeInEaseOut)
        add(a, forKey: key)
    }

    /// Slides in from the right and fades in (request content, 260 ms).
    func slideIn(distance: CGFloat = 12, duration: CFTimeInterval = 0.26, delay: CFTimeInterval = 0) {
        guard !Palette.reduceMotion else { return }
        let move = CABasicAnimation(keyPath: "transform.translation.x")
        move.fromValue = distance
        move.toValue = 0
        let fade = CABasicAnimation(keyPath: "opacity")
        fade.fromValue = 0
        fade.toValue = 1
        let group = CAAnimationGroup()
        group.animations = [move, fade]
        group.duration = duration
        group.beginTime = CACurrentMediaTime() + delay
        group.fillMode = .backwards
        group.timingFunction = Palette.curve
        add(group, forKey: "slideIn")
    }

    /// Scale 0.9 → 1 around the center, with a fade (buttons, 220 ms).
    /// View layers are anchored at their corner, hence the translation.
    func popIn() {
        guard !Palette.reduceMotion else { return }
        var from = CATransform3DMakeTranslation(bounds.width * 0.05, bounds.height * 0.05, 0)
        from = CATransform3DScale(from, 0.9, 0.9, 1)
        let scale = CABasicAnimation(keyPath: "transform")
        scale.fromValue = from
        scale.toValue = CATransform3DIdentity
        let fade = CABasicAnimation(keyPath: "opacity")
        fade.fromValue = 0
        fade.toValue = 1
        let group = CAAnimationGroup()
        group.animations = [scale, fade]
        group.duration = 0.22
        group.timingFunction = Palette.curve
        add(group, forKey: "popIn")
    }
}
