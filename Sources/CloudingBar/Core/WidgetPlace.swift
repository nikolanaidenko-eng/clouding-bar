import CoreGraphics
import Foundation

/// Where the widget's window goes and how far its outline pulls, from plain
/// rectangles (no AppKit, so `make test` can check them on any arrangement
/// of screens).
enum WidgetPlace {
    struct Display {
        var frame: CGRect
        var visible: CGRect
        var notch: Bool
    }

    /// The notch's screen: the one with a camera in it, wherever it stands;
    /// with none (no notch, or the lid closed), the first, where one is drawn.
    static func notchIndex(_ displays: [Display]) -> Int {
        displays.firstIndex(where: \.notch) ?? 0
    }

    /// What the window has to stay inside. Docked: the notch's screen, by
    /// name. Else the screen its top-centre hangs in, asked a point under
    /// the anchor: a rectangle doesn't contain its top edge, so with a
    /// monitor above, the MacBook's top was the monitor's, and the widget
    /// went to the monitor's bottom (owner, 30.10). Off every screen, the
    /// nearest, not the first.
    static func bounds(anchor: CGPoint, docked: Bool, displays: [Display]) -> CGRect? {
        guard !displays.isEmpty else { return nil }
        if docked { return displays[notchIndex(displays)].frame }
        let inside = CGPoint(x: anchor.x, y: anchor.y - 1)
        func gap(_ r: CGRect) -> CGFloat {
            hypot(max(r.minX - inside.x, 0, inside.x - r.maxX), max(r.minY - inside.y, 0, inside.y - r.maxY))
        }
        let display = displays.first { $0.frame.contains(inside) } ?? displays.min { gap($0.frame) < gap($1.frame) }
        return display?.visible
    }

    /// Near enough to the notch to dock there: around it, at the very top of
    /// its screen. Not above it: that's the monitor over the MacBook.
    static func overNotch(_ p: CGPoint, screen: CGRect, camera: CGFloat) -> Bool {
        abs(p.x - screen.midX) < max(150, camera / 2 + 110) && p.y > screen.maxY - 60 && p.y <= screen.maxY
    }

    /// The window for a size hanging from `anchor` (its top-centre), or from
    /// the end that stays put while the other is pulled.
    static func frame(size: CGSize, anchor: CGPoint, fixed: (x: CGFloat, left: Bool)?, docked: Bool,
                      displays: [Display]) -> CGRect {
        var frame = CGRect(x: anchor.x - size.width / 2, y: anchor.y - size.height, width: size.width, height: size.height)
        if let fixed { frame.origin.x = fixed.left ? fixed.x : fixed.x - size.width }
        guard let bounds = bounds(anchor: anchor, docked: docked, displays: displays) else { return frame }
        frame.origin.x = min(max(frame.minX, bounds.minX), bounds.maxX - frame.width)
        frame.origin.y = min(max(frame.minY, bounds.minY), bounds.maxY - frame.height)
        return frame
    }

    // MARK: Pulling the outline

    /// The most a pull can take: to the screen's edge from the side that
    /// stays put. Past it the window was pushed back onto the screen, and
    /// that side ran away from where it was left.
    static func room(frame: CGRect, bounds: CGRect, h: Int, v: Int, centered: Bool) -> CGSize {
        let width = centered ? 2 * min(frame.midX - bounds.minX, bounds.maxX - frame.midX)
            : h == 1 ? bounds.maxX - frame.minX : frame.maxX - bounds.minX
        let height = v == 1 ? bounds.maxY - frame.minY : frame.maxY - bounds.minY
        return CGSize(width: width, height: height)
    }

    /// The size for where the pointer has pulled it: past `most` it gives a
    /// little, like a rubber band; never past the room there is.
    static func pulled(raw: CGSize, low: CGSize, most: CGSize, room: CGSize) -> CGSize {
        func one(_ x: CGFloat, _ low: CGFloat, _ most: CGFloat, _ room: CGFloat) -> CGFloat {
            let given = x > most ? most + (x - most) * 0.2 : x
            return max(low, min(given, max(low, room)))
        }
        return CGSize(width: one(raw.width, low.width, most.width, room.width),
                      height: one(raw.height, low.height, most.height, room.height))
    }
}
