import CoreGraphics
import Foundation

/// How the Touch Bar's blocks share its width, from plain numbers (no AppKit,
/// so `make test` can check them): who stays when there's too much, and how
/// wide each one comes out.
enum BarLayout {
    enum Width {
        case fixed(CGFloat)
        case shrinkable(CGFloat)  // fixed, but gives way when space runs out
        case flex(weight: CGFloat, min: CGFloat)
    }

    /// The room these take shrunk as far as they go, with the gaps between.
    static func need(_ list: [Width], gap: CGFloat) -> CGFloat {
        list.reduce(CGFloat(0)) { sum, width in
            switch width {
            case let .fixed(w): return sum + w
            case let .shrinkable(w): return sum + min(w, 72) // readable, not crammed
            case let .flex(_, min): return sum + min
            }
        } + gap * CGFloat(max(0, list.count - 1))
    }

    /// Too much even when shrunk: droppable things leave, from the right.
    static func shown(_ slots: [(width: Width, droppable: Bool)], available: CGFloat, gap: CGFloat) -> [Int] {
        var shown = Array(slots.indices)
        while need(shown.map { slots[$0].width }, gap: gap) > available, let last = shown.lastIndex(where: { slots[$0].droppable }) {
            shown.remove(at: last)
        }
        return shown
    }

    /// More than the width, at each one's own size (flexible ones at their least).
    static func overflow(_ visible: [Width], available: CGFloat, gap: CGFloat) -> CGFloat {
        let gaps = gap * CGFloat(max(0, visible.count - 1))
        let natural = visible.reduce(CGFloat(0)) {
            switch $1 {
            case let .fixed(w), let .shrinkable(w): return $0 + w
            case let .flex(_, min): return $0 + min
            }
        }
        return natural + gaps - available
    }

    /// Each visible block's width.
    static func widths(_ visible: [Width], available: CGFloat, gap: CGFloat) -> [CGFloat] {
        let gaps = gap * CGFloat(max(0, visible.count - 1))
        var widths: [CGFloat] = visible.map {
            switch $0 {
            case let .fixed(w), let .shrinkable(w): return w
            case .flex: return 0
            }
        }
        let flexMin = visible.reduce(CGFloat(0)) {
            if case let .flex(_, min) = $1 { return $0 + min }
            return $0
        }
        // Not enough room: shrinkable slots give way first — as many as can
        // keep their whole names do (the shortest first); the rest share
        // what's left, and their names slide.
        let over = overflow(visible, available: available, gap: gap)
        if over > 0 {
            let shrinkable = visible.indices.filter { if case .shrinkable = visible[$0] { return true }; return false }
            let total = shrinkable.reduce(CGFloat(0)) { $0 + widths[$1] }
            if total > 0 {
                let fitted = fitWidths(shrinkable.map { widths[$0] }, total: total - over)
                for (i, w) in zip(shrinkable, fitted) { widths[i] = w }
            }
        }
        // Flexible slots: each its minimum first, then the rest by weight.
        let remaining = max(0, available - gaps - widths.reduce(0, +))
        let weights = visible.reduce(CGFloat(0)) {
            if case let .flex(w, _) = $1 { return $0 + w }
            return $0
        }
        let extra = max(0, remaining - flexMin)
        let squeeze = flexMin > 0 ? min(1, remaining / flexMin) : 1
        for (i, slot) in visible.enumerated() {
            if case let .flex(w, min) = slot, weights > 0 {
                widths[i] = min * squeeze + extra * w / weights
            }
        }
        return widths
    }

    /// `widths` brought down to `total`: as many as possible keep theirs
    /// (the narrowest first, while the others can still have `floor`), the
    /// rest share what's left equally, none under `floor` (or its own width).
    static func fitWidths(_ widths: [CGFloat], total: CGFloat, floor: CGFloat = 72) -> [CGFloat] {
        guard widths.reduce(0, +) > total else { return widths }
        let least = widths.map { min($0, floor) }
        let order = widths.indices.sorted { widths[$0] < widths[$1] }
        var kept = 0
        var used: CGFloat = 0
        for (n, i) in order.enumerated() {
            let others = order[(n + 1)...].reduce(CGFloat(0)) { $0 + least[$1] }
            guard used + widths[i] + others <= total else { break }
            used += widths[i]
            kept += 1
        }
        var out = widths
        let rest = order[kept...]
        guard !rest.isEmpty else { return out }
        let share = max(0, total - used) / CGFloat(rest.count)
        for i in rest { out[i] = min(widths[i], max(least[i], share)) }
        return out
    }

    // MARK: Your arrangement

    /// Where each block goes: its place in your order; one not in it right
    /// after the nearest block before it here that is (else first).
    static func places(_ keys: [String], order: [String]) -> [Double] {
        let rank = Dictionary(order.enumerated().map { ($1, Double($0)) }, uniquingKeysWith: { a, _ in a })
        var last = -1.0, step = 0.0
        return keys.map { key in
            if let r = rank[key] {
                last = r
                step = 0
                return r
            }
            step += 0.001
            return last + 0.5 + step
        }
    }

    /// Moved in Settings: the order with `key` where its middle comes to,
    /// among the others' middles when the drag began.
    static func moved(_ key: String, to mid: CGFloat, order: [String], middles: [String: CGFloat]) -> [String] {
        var rest = order.filter { $0 != key }
        let index = rest.firstIndex { (middles[$0] ?? 0) > mid } ?? rest.count
        rest.insert(key, at: index)
        return rest
    }

    /// Pulled in Settings: never past the bar (Cloud, "Whole bar" and a little
    /// room stay on it), nor past where something would leave it.
    static func pulled(width: CGFloat, by dx: CGFloat, barWidth: CGFloat, widest: CGFloat?) -> Double {
        let most = min(barWidth - 120, widest ?? .infinity)
        return Double(min(max(width + dx, 24), max(most, 24))).rounded(.down)
    }

    // MARK: The short bar

    static let shortChatMin: CGFloat = 120

    /// Each short-bar block's own size; the chat line takes what's left.
    static func shortWidth(_ key: String, shows: Set<String>) -> CGFloat {
        switch key {
        case "name": return 34
        case "meters": return shows.contains("session") && shows.contains("context") ? 180 : 90
        case "reset": return 52
        case "model": return 110
        case "agents": return 96
        case "lines": return 90
        case "branch": return 100
        case "cost": return 76
        case "templates", "shot", "mic": return 40
        case "chat": return shortChatMin
        default: return 0
        }
    }

    /// Whether these fit on the short bar, each block at its size: a gap
    /// after Cloud and after each block, and after the spacer that takes the
    /// chat line's place when there's none.
    static func shortFits(_ shows: Set<String>, room: CGFloat, gap: CGFloat) -> Bool {
        var widths: [CGFloat] = []
        if shows.contains("name") { widths.append(shortWidth("name", shows: shows)) }
        if shows.contains("session") || shows.contains("context") { widths.append(shortWidth("meters", shows: shows)) }
        for key in ["reset", "model", "agents", "lines", "branch", "cost", "chat", "templates", "shot", "mic"] where shows.contains(key) {
            widths.append(shortWidth(key, shows: shows))
        }
        let gaps = CGFloat(widths.count + (shows.contains("chat") ? 1 : 2))
        return widths.reduce(0, +) + gap * gaps <= room
    }
}
