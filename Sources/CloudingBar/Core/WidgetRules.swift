import CoreGraphics
import Foundation

enum WidgetMode { case strip, pill, panel, chats }

/// The widget's rules, from plain values (no AppKit or SwiftUI, so `make test`
/// can check them): where a press pulls, what a pull comes to, who has the
/// keyboard, the notch's sizes.
enum WidgetRules {
    /// A chat's name in the panel's tabs: what's left of `width` by its dot and
    /// padding (33), its pulse (13), and "+N" beside it (6 + 36).
    static func tabNameMax(width: CGFloat, more: Bool, waiting: Bool, nameMax: CGFloat) -> CGFloat {
        max(40, min(nameMax, width - 33 - (waiting ? 13 : 0) - (more ? 42 : 0)))
    }

    /// How close to an end a press resizes instead of moving.
    static let pillEdge: CGFloat = 14
    /// How close to the top or bottom of the outline.
    static let pillRim: CGFloat = 7

    /// Which sides a press on the pill's outline pulls — always one end and
    /// the top or bottom, so one drag sizes it both ways (free form): `h`
    /// −1 left, 1 right (the nearer end); `v` 1 top (only from the band
    /// along the top), else −1 bottom. Nil: not on the outline. `p` in
    /// window points, y up.
    static func pillRim(_ p: CGPoint, in size: CGSize) -> (h: Int, v: Int)? {
        let onRim = p.x <= pillEdge || p.x >= size.width - pillEdge || p.y <= pillRim || p.y >= size.height - pillRim
        guard onRim else { return nil }
        return (p.x > size.width / 2 ? 1 : -1, p.y >= size.height - pillRim ? 1 : -1)
    }

    /// The pulled side follows the pointer; at the default spot it grows both
    /// ways and stays centred, so its width changes twice as fast.
    static func rawPull(from size: CGSize, h: Int, v: Int, dx: CGFloat, dy: CGFloat, centered: Bool) -> CGSize {
        CGSize(width: size.width + CGFloat(h) * dx * (centered ? 2 : 1),
               height: size.height + CGFloat(v) * dy)
    }

    /// The island let go: compact again if pulled in that far (0 saves that),
    /// else as wide and tall as it was, within the screen.
    static func notchRelease(raw: CGSize, compactWidth: CGFloat, most: CGFloat, room: CGSize, rowHeight: CGFloat) -> (width: Double, height: Double) {
        let compact = raw.width <= compactWidth + 24
        return (compact ? 0 : Double(min(most, room.width, raw.width)),
                compact ? 0 : Double(min(room.height, max(rowHeight, raw.height))))
    }

    /// The pill let go: what was shown then, not where the pointer went past the edge.
    static func pillRelease(raw: CGSize, room: CGSize, minWidth: CGFloat, rowHeight: CGFloat) -> CGSize {
        CGSize(width: max(minWidth, min(raw.width, room.width)), height: min(room.height, max(rowHeight, raw.height)))
    }

    /// The width kept for a pill in rows. Pulled all the way: everything, now
    /// and whatever's added later. (Without the room for it, it would push its
    /// fixed end away.)
    static func savedWidth(raw: CGFloat, shown: CGFloat, most: CGFloat, room: CGFloat) -> Double {
        raw >= most && room >= most ? 10_000 : Double(shown)
    }

    /// The panel's window takes the keyboard: the queue's text field needs it,
    /// and so does the Chats tab, whose composers write to any chat.
    static func wantsKey(mode: WidgetMode, request: Bool, taskQueue: Bool, pillTyping: Bool, dictated: Bool) -> Bool {
        mode == .panel && (request || taskQueue) || mode == .chats || mode == .pill && (pillTyping || dictated)
    }

    /// A chat colour light enough for a dark icon on it (yellow, mint).
    static func light(_ hex: UInt32) -> Bool {
        let r = Double((hex >> 16) & 0xFF), g = Double((hex >> 8) & 0xFF), b = Double(hex & 0xFF)
        return (0.299 * r + 0.587 * g + 0.114 * b) / 255 > 0.7
    }

    /// Greedy line breaking: indices of items per row within `width`.
    static func rows(_ widths: [CGFloat], within width: CGFloat, gap: CGFloat) -> [[Int]] {
        var rows: [[Int]] = [[]]
        var used: CGFloat = 0
        for (i, w) in widths.enumerated() {
            if !rows[rows.count - 1].isEmpty && used + gap + w > width {
                rows.append([])
                used = 0
            }
            used += (rows[rows.count - 1].isEmpty ? 0 : gap) + w
            rows[rows.count - 1].append(i)
        }
        return rows
    }
}

/// The island's sizes.
enum NotchSizes {
    /// The concave curve at each top corner, where it meets the screen edge.
    static let shoulder: CGFloat = 8
    /// Each side of the camera, at least (in a real notch).
    static let ear: CGFloat = 92

    /// The compact island's width: two ears around the camera, or, drawn,
    /// the two sides with a hairline between.
    static func compactWidth(camera: CGFloat) -> CGFloat {
        camera > 0 ? 2 * shoulder + 22 + 2 * ear + camera : 2 * shoulder + 22 + 210
    }

    /// Grown wider and taller for what needs you or what you're writing.
    static func grownWidth(camera: CGFloat) -> CGFloat { max(460, camera + 2 * ear + 80) }

    /// The camera's width (0: no notch, one is drawn) and the notch's height,
    /// from what the screen says of its top: `left`'s right end and `right`'s
    /// left end being the menu bar's areas beside the camera.
    static func notch(safeTop: CGFloat, leftMaxX: CGFloat?, rightMinX: CGFloat?) -> (width: CGFloat, height: CGFloat) {
        if safeTop > 0 {
            if let leftMaxX, let rightMinX {
                return (max(0, rightMinX - leftMaxX), safeTop)
            }
            return (200, safeTop)
        }
        return (0, 32)
    }
}
