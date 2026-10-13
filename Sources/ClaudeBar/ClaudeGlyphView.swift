import AppKit

/// The easter egg: a tiny Claude starburst that lives on the Touch Bar,
/// gently breathing while Claude works. Drawn by hand so we don't need
/// any image assets.
final class ClaudeGlyphView: NSView {
    /// Anthropic's signature coral.
    private let coral = NSColor(srgbRed: 0.85, green: 0.47, blue: 0.34, alpha: 1)
    private var phase: CGFloat = 0
    private var timer: Timer?

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        // ~12fps is plenty for a gentle pulse and easy on the battery.
        timer = Timer.scheduledTimer(withTimeInterval: 1.0 / 12.0, repeats: true) { [weak self] _ in
            guard let self = self else { return }
            self.phase += 0.08
            self.needsDisplay = true
        }
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) is not used")
    }

    override var intrinsicContentSize: NSSize {
        NSSize(width: 30, height: 30)
    }

    override func draw(_ dirtyRect: NSRect) {
        let center = CGPoint(x: bounds.midX, y: bounds.midY)
        // Breathe between 80% and 100% size.
        let breathe = 0.9 + 0.1 * sin(phase)
        let rayLength = min(bounds.width, bounds.height) * 0.42 * breathe

        let path = NSBezierPath()
        path.lineWidth = 2
        path.lineCapStyle = .round

        // Claude's starburst: rays fanning out from the center.
        let rayCount = 9
        for i in 0..<rayCount {
            let angle = (CGFloat(i) / CGFloat(rayCount)) * 2 * .pi + phase * 0.15
            path.move(to: CGPoint(x: center.x + cos(angle) * rayLength * 0.35,
                                  y: center.y + sin(angle) * rayLength * 0.35))
            path.line(to: CGPoint(x: center.x + cos(angle) * rayLength,
                                  y: center.y + sin(angle) * rayLength))
        }

        coral.setStroke()
        path.stroke()
    }

    deinit {
        timer?.invalidate()
    }
}
