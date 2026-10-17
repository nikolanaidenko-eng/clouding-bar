import AppKit

/// The bar's character from design/Mascot.dc.html: a light rounded pebble
/// with oval eyes, three states, drawn with Core Animation layers in the
/// mockup's 40×40 SVG coordinates (y down) and scaled to fit.
///
///   sleep  dim, eyes closed, slow breathing (3.6 s), a floating "z"
///   work   hops (0.7 s), blinks every 3.4 s, typing dots overhead
///   wait   sways ±7° (1.4 s), a pulsing orange "!" badge
final class MascotView: NSView {
    var activity: Activity = .sleep {
        didSet { if activity != oldValue { rebuild() } }
    }

    private let stage = CALayer()

    init(size: CGFloat) {
        super.init(frame: NSRect(x: 0, y: 0, width: size, height: size))
        wantsLayer = true
        stage.isGeometryFlipped = true
        stage.anchorPoint = .zero
        stage.bounds = CGRect(x: 0, y: 0, width: 40, height: 40)
        layer?.addSublayer(stage)
        rebuild()
    }

    required init?(coder: NSCoder) { fatalError("not used") }

    override var intrinsicContentSize: NSSize { frame.size }

    /// Taps go to whatever holds it (the bar's widget button).
    override func hitTest(_ point: NSPoint) -> NSView? { nil }

    override func layout() {
        super.layout()
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        let s = min(bounds.width, bounds.height) / 40
        stage.position = CGPoint(x: (bounds.width - 40 * s) / 2, y: (bounds.height - 40 * s) / 2)
        stage.transform = CATransform3DMakeScale(s, s, 1)
        CATransaction.commit()
    }

    private func rebuild() {
        stage.sublayers?.forEach { $0.removeFromSuperlayer() }
        let motion = !Palette.reduceMotion
        switch activity {
        case .sleep:
            setAccessibilityLabel("Sleeping")
            stage.addSublayer(ellipse(cx: 20, cy: 35.5, rx: 9, ry: 1.6, color: .black, opacity: 0.35))
            let body = group()
            body.addSublayer(rect(x: 7, y: 11, w: 26, h: 23, r: 11.5, color: NSColor(hex: 0xB8B6B1)))
            body.addSublayer(arcEye(x: 13.6))
            body.addSublayer(arcEye(x: 21.6))
            stage.addSublayer(body)
            let z = CATextLayer()
            z.string = "z"
            z.font = NSFont.systemFont(ofSize: 6, weight: .semibold)
            z.fontSize = 6
            z.foregroundColor = Palette.muted.cgColor
            z.contentsScale = 2
            z.frame = CGRect(x: 29, y: 2.5, width: 6, height: 8) // baseline near y = 9
            stage.addSublayer(z)
            if motion {
                // SVG scales around the origin (0,0), so does this.
                body.add(keyframes("transform.scale.x", [1, 1.02, 1], 3.6), forKey: "sx")
                body.add(keyframes("transform.scale.y", [1, 0.97, 1], 3.6), forKey: "sy")
                z.add(keyframes("opacity", [0, 1, 0], 3.6), forKey: "fade")
                z.add(keyframes("transform.translation.y", [1, -3, 1], 3.6), forKey: "float")
            }

        case .work:
            setAccessibilityLabel("Working")
            let shadow = ellipse(cx: 20, cy: 35.5, rx: 9, ry: 1.6, color: .black, opacity: 0.35)
            stage.addSublayer(shadow)
            let body = group()
            body.addSublayer(rect(x: 7, y: 10, w: 26, h: 23, r: 11.5, color: NSColor(hex: 0xECEAE5)))
            let eyes = [ellipse(cx: 16, cy: 20.5, rx: 2, ry: 2.8, color: NSColor(hex: 0x1C1C1E)),
                        ellipse(cx: 24, cy: 20.5, rx: 2, ry: 2.8, color: NSColor(hex: 0x1C1C1E))]
            eyes.forEach(body.addSublayer)
            stage.addSublayer(body)
            let dots = [14, 20, 26].map { ellipse(cx: CGFloat($0), cy: 4.5, rx: 1.5, ry: 1.5, color: Palette.secondary) }
            dots.forEach(stage.addSublayer)
            if motion {
                shadow.add(keyframes("transform.scale.x", [1, 7.0 / 9, 1], 0.7), forKey: "squash")
                let hop = keyframes("transform.translation.y", [0, -2.2, 0], 0.7, keyTimes: [0, 0.45, 1])
                hop.timingFunctions = [CAMediaTimingFunction(controlPoints: 0.3, 0, 0.4, 1),
                                       CAMediaTimingFunction(controlPoints: 0.6, 0, 0.7, 1)]
                body.add(hop, forKey: "hop")
                for eye in eyes {
                    eye.add(keyframes("transform.scale.y", [1, 1, 0.3 / 2.8, 1], 3.4,
                                      keyTimes: [0, 0.92, 0.96, 1]), forKey: "blink")
                }
                for (i, dot) in dots.enumerated() {
                    let a = keyframes("opacity", [0.25, 1, 0.25], 1.2)
                    a.beginTime = CACurrentMediaTime() + 0.2 * Double(i)
                    a.fillMode = .backwards
                    dot.add(a, forKey: "type")
                }
            }

        case .wait:
            setAccessibilityLabel("Waiting for you")
            stage.addSublayer(ellipse(cx: 20, cy: 35.5, rx: 9, ry: 1.6, color: .black, opacity: 0.35))
            let body = group(anchorX: 20, anchorY: 34)
            body.addSublayer(rect(x: 7, y: 11, w: 26, h: 23, r: 11.5, color: NSColor(hex: 0xECEAE5)))
            body.addSublayer(ellipse(cx: 16, cy: 20.5, rx: 2.2, ry: 3, color: NSColor(hex: 0x1C1C1E)))
            body.addSublayer(ellipse(cx: 24, cy: 20.5, rx: 2.2, ry: 3, color: NSColor(hex: 0x1C1C1E)))
            body.addSublayer(ellipse(cx: 20, cy: 27, rx: 1.6, ry: 1.2, color: NSColor(hex: 0x1C1C1E)))
            stage.addSublayer(body)
            let badge = ellipse(cx: 33, cy: 8, rx: 4.2, ry: 4.2, color: Palette.warning)
            stage.addSublayer(badge)
            stage.addSublayer(rect(x: 32.3, y: 5.4, w: 1.4, h: 3.4, r: 0.7, color: NSColor(hex: 0x1C1C1E)))
            stage.addSublayer(ellipse(cx: 33, cy: 10.4, rx: 0.8, ry: 0.8, color: NSColor(hex: 0x1C1C1E)))
            if motion {
                let deg = CGFloat.pi / 180
                body.add(keyframes("transform.rotation.z", [0, -7 * deg, 0, 7 * deg, 0], 1.4), forKey: "sway")
                badge.add(keyframes("transform.scale", [1, 5 / 4.2, 1], 1), forKey: "pulse")
            }
        }
    }

    // MARK: Shapes (SVG coordinates)

    /// A layer covering the stage; `anchor` is the point it rotates about.
    private func group(anchorX: CGFloat = 0, anchorY: CGFloat = 0) -> CALayer {
        let g = CALayer()
        g.bounds = CGRect(x: 0, y: 0, width: 40, height: 40)
        g.anchorPoint = CGPoint(x: anchorX / 40, y: anchorY / 40)
        g.position = CGPoint(x: anchorX, y: anchorY)
        g.contentsScale = 2
        return g
    }

    private func rect(x: CGFloat, y: CGFloat, w: CGFloat, h: CGFloat, r: CGFloat, color: NSColor) -> CAShapeLayer {
        let l = CAShapeLayer()
        l.path = CGPath(roundedRect: CGRect(x: x, y: y, width: w, height: h), cornerWidth: r, cornerHeight: r, transform: nil)
        l.fillColor = color.cgColor
        l.contentsScale = 2
        return l
    }

    /// An ellipse in its own layer centered on (cx, cy), so it can scale in place.
    private func ellipse(cx: CGFloat, cy: CGFloat, rx: CGFloat, ry: CGFloat,
                         color: NSColor, opacity: Float = 1) -> CAShapeLayer {
        let l = CAShapeLayer()
        l.bounds = CGRect(x: 0, y: 0, width: rx * 2, height: ry * 2)
        l.position = CGPoint(x: cx, y: cy)
        l.path = CGPath(ellipseIn: l.bounds, transform: nil)
        l.fillColor = color.cgColor
        l.opacity = opacity
        l.contentsScale = 2
        return l
    }

    /// A closed eye: "M x 22.2 q 2.4 1.8 4.8 0".
    private func arcEye(x: CGFloat) -> CAShapeLayer {
        let path = CGMutablePath()
        path.move(to: CGPoint(x: x, y: 22.2))
        path.addQuadCurve(to: CGPoint(x: x + 4.8, y: 22.2), control: CGPoint(x: x + 2.4, y: 24))
        let l = CAShapeLayer()
        l.path = path
        l.fillColor = nil
        l.strokeColor = NSColor(hex: 0x2C2C2E).cgColor
        l.lineWidth = 1.6
        l.lineCap = .round
        l.contentsScale = 2
        return l
    }

    private func keyframes(_ keyPath: String, _ values: [CGFloat], _ duration: CFTimeInterval,
                           keyTimes: [NSNumber]? = nil) -> CAKeyframeAnimation {
        let a = CAKeyframeAnimation(keyPath: keyPath)
        a.values = values
        a.keyTimes = keyTimes
        a.duration = duration
        a.repeatCount = .infinity
        return a
    }

    // MARK: Menu bar icon

    /// The pebble as a template image for the menu bar.
    static func menuBarImage() -> NSImage {
        let image = NSImage(size: NSSize(width: 18, height: 18), flipped: true) { _ in
            let s: CGFloat = 18 / 40
            NSColor.black.setFill()
            NSBezierPath(roundedRect: NSRect(x: 7 * s, y: 9 * s, width: 26 * s, height: 25 * s),
                         xRadius: 12 * s, yRadius: 12 * s).fill()
            NSGraphicsContext.current?.compositingOperation = .clear
            for cx in [16.0, 24.0] {
                NSBezierPath(ovalIn: NSRect(x: (cx - 2.4) * s, y: (20.5 - 3.2) * s,
                                            width: 4.8 * s, height: 6.4 * s)).fill()
            }
            return true
        }
        image.isTemplate = true
        return image
    }
}
