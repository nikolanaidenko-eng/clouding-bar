import AppKit

/// One Cloud per chat colour (owner, 27.10: "give every session its own Cloud
/// so they can be told apart — ten, each its own colour and a small but
/// noticeable extra"). The variant is the chat's `colorIndex`: the skin is a
/// pale tint of the chat's colour (so the dot and the Cloud match) and the
/// extra is drawn in the same 40×40 SVG coordinates as MascotView, as a layer
/// that goes inside the body group — so it hops, sways, spins and nods with it.
///
///   0 blue    round glasses        5 yellow  crown
///   1 purple  wizard hat           6 indigo  top hat
///   2 cyan    headphones           7 mint    beret
///   3 green   flower               8 coral   pirate: bandana and eye patch
///   4 pink    bow                  9 lime    cap
enum CloudGear {
    /// The skin: the chat's colour, mostly white.
    static func skin(_ variant: Int) -> NSColor {
        let base = NSColor(hex: Session.colors[variant % Session.colors.count])
        return NSColor.white.blended(withFraction: 0.42, of: base) ?? base
    }

    /// The extra for a variant. `dy` follows the body (the working pose sits a
    /// point higher); `asleep` dims it with the body.
    static func layer(_ variant: Int, dy: CGFloat = 0, asleep: Bool = false) -> CALayer {
        let g = CALayer()
        g.frame = CGRect(x: 0, y: 0, width: 40, height: 40)
        g.transform = CATransform3DMakeTranslation(0, dy, 0)
        if asleep { g.opacity = 0.8 }
        let ink = NSColor(hex: 0x1C1C1E)
        let white = NSColor.white
        switch variant % 10 {
        case 0: // glasses: two rims round the eyes, a bridge between
            for cx in [15.9, 24.1] {
                let lens = oval(cx: cx, cy: 21, r: 4, fill: nil, stroke: NSColor(hex: 0x1F4FA8), width: 1.5)
                g.addSublayer(lens)
            }
            g.addSublayer(line([(19.5, 20.4), (20.5, 20.4)], color: NSColor(hex: 0x1F4FA8), width: 1.5))
            g.addSublayer(line([(11.6, 20.6), (8.2, 19.4)], color: NSColor(hex: 0x1F4FA8), width: 1.3))
            g.addSublayer(line([(28.4, 20.6), (31.8, 19.4)], color: NSColor(hex: 0x1F4FA8), width: 1.3))

        case 1: // wizard hat: a brim, a cone, a star
            g.addSublayer(oval(cx: 20, cy: 12.6, rx: 9.2, ry: 2, fill: NSColor(hex: 0x4B2FA8)))
            g.addSublayer(poly([(14.2, 12.4), (21.6, 4.2), (25.8, 12.4)], fill: NSColor(hex: 0x5E3FBE)))
            g.addSublayer(star(cx: 19.6, cy: 9, r: 1.9, fill: NSColor(hex: 0xFFD60A)))

        case 2: // headphones: a band over the head, a cup on each side
            let band = CGMutablePath()
            band.move(to: CGPoint(x: 8.2, y: 19))
            band.addQuadCurve(to: CGPoint(x: 31.8, y: 19), control: CGPoint(x: 20, y: -4.5))
            g.addSublayer(stroke(band, color: NSColor(hex: 0x48484A), width: 2))
            for x in [4.6, 30.6] {
                g.addSublayer(rrect(x: x, y: 16.4, w: 4.8, h: 8.6, r: 2.2, fill: NSColor(hex: 0xFF453A)))
            }

        case 3: // flower: five petals round a yellow heart, on the left of the head
            let (cx, cy) = (13.4, 12.6)
            g.addSublayer(oval(cx: cx + 3.6, cy: cy + 3.2, rx: 2.5, ry: 1.2, fill: NSColor(hex: 0x1F9A3E), turn: 0.6)) // a leaf
            for i in 0..<5 {
                let a = CGFloat(i) * 2 * .pi / 5 - .pi / 2
                g.addSublayer(oval(cx: cx + cos(a) * 2.6, cy: cy + sin(a) * 2.6, r: 2.1, fill: NSColor(hex: 0xFF6EB4)))
            }
            g.addSublayer(oval(cx: cx, cy: cy, r: 1.7, fill: NSColor(hex: 0xFFD60A)))

        case 4: // bow: two loops and a knot, on the right of the head
            let (cx, cy): (CGFloat, CGFloat) = (26, 12.4)
            let fill = NSColor(hex: 0xFF2D55)
            g.addSublayer(poly([(cx, cy), (cx - 5.6, cy - 3.6), (cx - 5.6, cy + 3.6)], fill: fill))
            g.addSublayer(poly([(cx, cy), (cx + 5.6, cy - 3.6), (cx + 5.6, cy + 3.6)], fill: fill))
            g.addSublayer(oval(cx: cx, cy: cy, r: 1.9, fill: NSColor(hex: 0xD70F3A)))

        case 5: // crown: three points and a jewel
            let crown = poly([(14.6, 14), (14.4, 6.8), (17.4, 10), (20, 5.6), (22.6, 10), (25.6, 6.8), (25.4, 14)],
                             fill: NSColor(hex: 0xF5A800), stroke: NSColor(hex: 0xB37400), width: 0.8)
            g.addSublayer(crown)
            for (x, y) in [(14.4, 6.6), (20.0, 5.4), (25.6, 6.6)] {
                g.addSublayer(oval(cx: x, cy: y, r: 1.2, fill: NSColor(hex: 0xFFE27A)))
            }
            g.addSublayer(oval(cx: 20, cy: 11.6, r: 1.3, fill: NSColor(hex: 0xFF453A)))

        case 6: // top hat: a flat brim, a tall crown, a red band
            let hat = NSColor(hex: 0x48484A)
            g.addSublayer(rrect(x: 14.4, y: 4.2, w: 11.2, h: 8.6, r: 1.2, fill: hat, stroke: NSColor(hex: 0x8E8E93), width: 0.5))
            g.addSublayer(rect(x: 14.4, y: 9.2, w: 11.2, h: 2, fill: NSColor(hex: 0xFF453A)))
            g.addSublayer(oval(cx: 20, cy: 12.5, rx: 9, ry: 1.7, fill: hat, stroke: NSColor(hex: 0x8E8E93), width: 0.5))

        case 7: // beret: a flat disc worn to one side, a nub on top
            g.addSublayer(oval(cx: 21.4, cy: 11, rx: 9.4, ry: 3.4, fill: NSColor(hex: 0xB5384A), turn: -0.2))
            g.addSublayer(oval(cx: 23, cy: 7.6, r: 1, fill: NSColor(hex: 0x8C2A38)))

        case 8: // pirate: a bandana over the top, an eye patch on the left eye
            let navy = NSColor(hex: 0x1F2A5A)
            g.addSublayer(cap(bottom: 16.4, fill: navy))
            for (x, y) in [(13.0, 13.4), (19.6, 12.4), (26.2, 13.6), (22.6, 15.4), (16.4, 15.6)] {
                g.addSublayer(oval(cx: x, cy: y, r: 0.8, fill: white))
            }
            g.addSublayer(poly([(31.6, 15), (37.4, 11.6), (36.4, 17.6)], fill: navy)) // knot's tails
            g.addSublayer(line([(13.4, 18.4), (8, 16)], color: ink, width: 1.1)) // the strap
            g.addSublayer(oval(cx: 16, cy: 21.2, rx: 3.5, ry: 3.7, fill: ink))

        default: // cap: a dome, a button, a bill pointing right
            let blue = NSColor(hex: 0x2F6FED)
            g.addSublayer(cap(bottom: 15.6, fill: blue))
            g.addSublayer(oval(cx: 20, cy: 10.8, r: 1, fill: NSColor(hex: 0x1F4FB5)))
            g.addSublayer(rrect(x: 22.6, y: 14.2, w: 14.6, h: 2.8, r: 1.4, fill: NSColor(hex: 0x1F4FB5)))
        }
        return g
    }

    // MARK: Shapes

    private static func shape(_ path: CGPath, fill: NSColor?, stroke: NSColor?, width: CGFloat) -> CAShapeLayer {
        let l = CAShapeLayer()
        l.path = path
        l.fillColor = fill?.cgColor
        l.strokeColor = stroke?.cgColor
        l.lineWidth = width
        l.lineCap = .round
        l.lineJoin = .round
        l.contentsScale = 2
        return l
    }

    private static func oval(cx: CGFloat, cy: CGFloat, rx: CGFloat, ry: CGFloat, fill: NSColor?,
                             stroke: NSColor? = nil, width: CGFloat = 0, turn: CGFloat = 0) -> CAShapeLayer {
        let l = shape(CGPath(ellipseIn: CGRect(x: -rx, y: -ry, width: rx * 2, height: ry * 2), transform: nil),
                      fill: fill, stroke: stroke, width: width)
        l.position = CGPoint(x: cx, y: cy)
        if turn != 0 { l.transform = CATransform3DMakeRotation(turn, 0, 0, 1) }
        return l
    }

    private static func oval(cx: CGFloat, cy: CGFloat, r: CGFloat, fill: NSColor?,
                             stroke: NSColor? = nil, width: CGFloat = 0) -> CAShapeLayer {
        oval(cx: cx, cy: cy, rx: r, ry: r, fill: fill, stroke: stroke, width: width)
    }

    private static func rect(x: CGFloat, y: CGFloat, w: CGFloat, h: CGFloat, fill: NSColor) -> CAShapeLayer {
        shape(CGPath(rect: CGRect(x: x, y: y, width: w, height: h), transform: nil), fill: fill, stroke: nil, width: 0)
    }

    private static func rrect(x: CGFloat, y: CGFloat, w: CGFloat, h: CGFloat, r: CGFloat, fill: NSColor,
                              stroke: NSColor? = nil, width: CGFloat = 0) -> CAShapeLayer {
        shape(CGPath(roundedRect: CGRect(x: x, y: y, width: w, height: h), cornerWidth: r, cornerHeight: r, transform: nil),
              fill: fill, stroke: stroke, width: width)
    }

    private static func poly(_ points: [(CGFloat, CGFloat)], fill: NSColor, stroke: NSColor? = nil,
                             width: CGFloat = 0) -> CAShapeLayer {
        let path = CGMutablePath()
        path.move(to: CGPoint(x: points[0].0, y: points[0].1))
        points.dropFirst().forEach { path.addLine(to: CGPoint(x: $0.0, y: $0.1)) }
        path.closeSubpath()
        return shape(path, fill: fill, stroke: stroke, width: width)
    }

    private static func line(_ points: [(CGFloat, CGFloat)], color: NSColor, width: CGFloat) -> CAShapeLayer {
        let path = CGMutablePath()
        path.move(to: CGPoint(x: points[0].0, y: points[0].1))
        points.dropFirst().forEach { path.addLine(to: CGPoint(x: $0.0, y: $0.1)) }
        return shape(path, fill: nil, stroke: color, width: width)
    }

    private static func stroke(_ path: CGPath, color: NSColor, width: CGFloat) -> CAShapeLayer {
        shape(path, fill: nil, stroke: color, width: width)
    }

    private static func star(cx: CGFloat, cy: CGFloat, r: CGFloat, fill: NSColor) -> CAShapeLayer {
        let points = (0..<10).map { i -> (CGFloat, CGFloat) in
            let a = CGFloat(i) * .pi / 5 - .pi / 2, d = i % 2 == 0 ? r : r * 0.45
            return (cx + cos(a) * d, cy + sin(a) * d)
        }
        return poly(points, fill: fill)
    }

    /// The top of the head down to `bottom`: the body's outline, cut off.
    private static func cap(bottom: CGFloat, fill: NSColor) -> CAShapeLayer {
        let l = shape(CGPath(roundedRect: CGRect(x: 7, y: 11, width: 26, height: 23), cornerWidth: 11.5, cornerHeight: 11.5, transform: nil),
                      fill: fill, stroke: nil, width: 0)
        l.mask = rect(x: 0, y: 0, w: 40, h: bottom, fill: .black)
        return l
    }
}
