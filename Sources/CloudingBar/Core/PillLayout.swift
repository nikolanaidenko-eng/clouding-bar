import CoreGraphics
import Foundation

// The pill's arithmetic, from plain widths (no AppKit, so `make test` can
// check it): what it shows at a given size, in rows or as a column.

/// Lays items of the given widths into rows within `width`, left to right;
/// every row starts at `indent`.
func flowSlots(_ items: [(id: String, width: CGFloat)], width: CGFloat, rowHeight: CGFloat, gap: CGFloat,
               rowGap: CGFloat = 0, indent: CGFloat = 0) -> (slots: [String: CGRect], size: CGSize) {
    var slots: [String: CGRect] = [:]
    var x = indent, y: CGFloat = 0, widest = indent
    var rowEmpty = true
    for item in items {
        if !rowEmpty && x + gap + item.width > width {
            x = indent
            y += rowHeight + rowGap
            rowEmpty = true
        }
        if !rowEmpty { x += gap }
        slots[item.id] = CGRect(x: x, y: y, width: item.width, height: rowHeight)
        x += item.width
        rowEmpty = false
        widest = max(widest, x)
    }
    return (slots, CGSize(width: widest, height: y + rowHeight))
}

// MARK: - Layout

/// What the pill shows for a given size, in the owner's order (by default
/// the character, then the numbers, their bars, the metrics, the chat with
/// the buttons, then templates · screenshot · mic). Pulling the pill's
/// outline sets its width and its number of rows; it shows the longest run
/// that fits, flowing from row to row.
struct PillLayout {
    enum Part: Hashable {
        case focus, session, context, reset, cost, sessionBar, contextBar
        case metric(String), button(Int), chat, templates, shot, mic
    }

    static let pad: CGFloat = 10 + 16
    static let gap: CGFloat = 14
    static let character: CGFloat = 30
    /// The character alone: a circle.
    static let minWidth: CGFloat = 44
    static let barWidth: CGFloat = 44
    static let rowHeight: CGFloat = 34
    /// Above the first row and under the last: one row is 44 pt.
    static let vPad: CGFloat = 5
    /// The empty bit of the chat you click to write.
    static let chatField: CGFloat = 64
    /// The metrics the pill and the panel can show.
    static let metricIDs = ["model", "time", "lines", "git", "agents", "cost"]

    /// Each part, the width it adds (a bar widens its number's group) and
    /// its id for swapping.
    let parts: [(part: Part, width: CGFloat, id: String)]

    /// Items dragged wider or narrower by their right edge.
    let widths: [String: Double]

    /// The chat as a column: the bit to write in, the buttons under it.
    let chatSize: CGSize

    init(parts: [(part: Part, width: CGFloat, id: String)], widths: [String: Double], chatSize: CGSize) {
        self.parts = parts
        self.widths = widths
        self.chatSize = chatSize
    }

    /// The parts in the order of `ids`, the bars right after the last number.
    static func ordered(_ parts: [(part: Part, width: CGFloat, id: String)], by ids: [String]) -> [(part: Part, width: CGFloat, id: String)] {
        func rank(_ id: String) -> Int { ids.firstIndex(of: id) ?? .max }
        var list = parts
        list = list.enumerated().sorted { a, b in
            let ra = rank(a.element.id), rb = rank(b.element.id)
            return ra != rb ? ra < rb : a.offset < b.offset
        }.map(\.element)
        // The bars come right after the last number.
        let numbers: Set<Part> = [.session, .context, .reset, .cost]
        var at = (list.lastIndex { numbers.contains($0.part) } ?? -1) + 1
        if list.contains(where: { $0.part == .session }) {
            list.insert((.sessionBar, Self.barWidth + 8, "sessionBar"), at: at)
        } else {
            at -= 1
        }
        if list.contains(where: { $0.part == .context }) {
            at += 1
            list.insert((.contextBar, Self.barWidth + 6, "contextBar"), at: at)
        }
        return list
    }

    static func percent(_ p: Double?) -> String { p.map { "\(Int($0.rounded()))%" } ?? "—" }
    static func cost(_ c: Double?) -> String { c.map { String(format: "$%.2f", $0) } ?? "$—" }

    /// The pill's width budget for a size set by pulling its edge, or the old
    /// density setting; else room for everything switched on, as wide as the
    /// screen allows (`screens`: each one's frame and visible width).
    static func budget(pillWidth: Double, density: String, position: CGPoint?,
                       screens: [(frame: CGRect, visibleWidth: CGFloat)]) -> CGFloat {
        if pillWidth > 0 {
            // Pulled wide on a monitor that's gone: the screen left, for now.
            let on = position.flatMap { p in screens.first { $0.frame.contains(p) } } ?? screens.first
            return min(CGFloat(pillWidth), on?.visibleWidth ?? .infinity)
        }
        switch density {
        case "icon": return 0
        case "numbers": return 260
        default:
            // The screen the pill is on: where it was put, else the first.
            let screen = position.flatMap { p in screens.first { $0.frame.contains(p) } } ?? screens.first
            return max(370, (screen?.visibleWidth ?? 1440) - 80)
        }
    }

    static func height(rows: Int) -> CGFloat { vPad * 2 + rowHeight * CGFloat(max(1, rows)) }
    static func rows(forHeight h: CGFloat) -> Int { max(1, Int((h - vPad * 2 + 6) / rowHeight)) }

    /// The items on screen for the first `n` parts: bars fold into their
    /// numbers' groups.
    func items(_ n: Int) -> [(part: Part, width: CGFloat, id: String)] {
        let shown = parts.prefix(n)
        var list = shown.filter { $0.part != .sessionBar && $0.part != .contextBar }
        for bar in shown where bar.part == .sessionBar || bar.part == .contextBar {
            let owner: Part = bar.part == .sessionBar ? .session : .context
            if let i = list.firstIndex(where: { $0.part == owner }) { list[i].width += bar.width }
        }
        // Dragged by its right edge (owner, 24.10): that width.
        for i in list.indices { if let w = widths[list[i].id] { list[i].width = max(CGFloat(w), 20) } }
        return list
    }

    /// Items into rows within `width`. Every row starts after the
    /// character, so the rows line up under each other.
    static func flow(_ widths: [CGFloat], width: CGFloat) -> (rows: [[Int]], widths: [CGFloat]) {
        let inner = width - pad
        var rows: [[Int]] = [[]]
        var used: [CGFloat] = [character]
        for (i, w) in widths.enumerated() {
            let last = rows.count - 1
            if rows[last].isEmpty || used[last] + gap + w <= inner {
                rows[last].append(i); used[last] += gap + w
            } else {
                rows.append([i]); used.append(character + gap + w)
            }
        }
        return (rows, used)
    }

    /// Numbers, metrics, controls: a hairline goes where one kind meets another.
    static func kind(_ p: Part) -> Int {
        switch p {
        case .focus: return 3
        case .session, .context, .reset, .cost, .sessionBar, .contextBar: return 0
        case .metric: return 1
        default: return 2
        }
    }

    func fits(_ n: Int, width: CGFloat, rows: Int) -> Bool {
        guard n > 0 else { return true }
        let f = Self.flow(items(n).map(\.width), width: width)
        return f.rows.count <= rows && f.widths.allSatisfy { $0 <= width - Self.pad }
    }

    /// How many parts fit in `width` × `rows`.
    func count(width: CGFloat, rows: Int) -> Int {
        var n = 0
        while n < parts.count && fits(n + 1, width: width, rows: rows) { n += 1 }
        return n
    }

    /// The pill's size showing the first `n` parts within `width`.
    func size(_ n: Int, width: CGFloat) -> CGSize {
        guard n > 0 else { return CGSize(width: Self.minWidth, height: Self.height(rows: 1)) }
        let f = Self.flow(items(n).map(\.width), width: width)
        return CGSize(width: Self.pad + (f.widths.max() ?? 0), height: Self.height(rows: f.rows.count))
    }

    /// Everything in one row: the widest the pill gets.
    var maxWidth: CGFloat { size(parts.count, width: .greatestFiniteMagnitude).width }

    // MARK: Arrangement

    /// Where everything goes for a size budget. Wider than tall: rows after
    /// the character. Taller than wide: a column — the character on top,
    /// the meters turned upright and stretched to the full height, the rest
    /// stacked under them; whatever is wider than the column stays hidden
    /// until the column is pulled wide enough for it.
    struct Arrangement {
        var vertical = false
        /// Visible items, in order, and their slots in the content's space.
        var ids: [String] = []
        var parts: [String: Part] = [:]
        var slots: [String: CGRect] = [:]
        var board: CGSize = .zero
        /// Top-left of the character in the content's space.
        var character: CGPoint = .zero
        /// From the pill's top-left to the content's.
        var inset = CGSize(width: 10, height: PillLayout.vPad)
        /// The pill's size.
        var frame = CGSize(width: PillLayout.minWidth, height: PillLayout.height(rows: 1))
        /// Its width without spare room around what it shows.
        var natural: CGFloat = PillLayout.minWidth
        var shown: Set<Part> = []
        /// Hairlines between kinds, in the content's space.
        var dividers: [CGRect] = []

        /// Room for the camera in the middle (docked in a real notch): what
        /// would sit under it, from `x` on and above `bottom` (in the
        /// content's space), moves past it. Rows below the camera keep their place.
        func makingRoom(at x: CGFloat, width: CGFloat, above bottom: CGFloat) -> Arrangement {
            guard width > 0 else { return self }
            var a = self
            for (id, r) in slots where r.maxX > x && r.minY < bottom { a.slots[id] = r.offsetBy(dx: width, dy: 0) }
            a.dividers = dividers.map { $0.minX > x && $0.minY < bottom ? $0.offsetBy(dx: width, dy: 0) : $0 }
            a.board.width += width
            a.frame.width += width
            a.natural += width
            return a
        }
    }

    static func isVertical(width: CGFloat, height: CGFloat) -> Bool { height > max(width, Self.height(rows: 1)) }

    func arrange(width: CGFloat, height: CGFloat) -> Arrangement {
        Self.isVertical(width: width, height: height) ? column(width: width, height: height) : rows(width: width, height: height)
    }

    private func rows(width: CGFloat, height: CGFloat) -> Arrangement {
        var a = Arrangement()
        let n = count(width: width, rows: Self.rows(forHeight: height))
        let list = items(n)
        let f = flowSlots(list.map { (id: $0.id, width: $0.width) }, width: width - Self.pad, rowHeight: Self.rowHeight,
                          gap: Self.gap, indent: Self.character + Self.gap)
        a.ids = list.map(\.id)
        a.parts = Dictionary(list.map { ($0.id, $0.part) }, uniquingKeysWith: { x, _ in x })
        a.slots = f.slots
        a.board = f.size
        a.character = CGPoint(x: 0, y: (Self.rowHeight - Self.character) / 2)
        a.frame = size(n, width: width)
        a.natural = a.frame.width
        a.shown = Set(parts.prefix(n).map(\.part))
        // A hairline where numbers meet metrics or metrics meet controls.
        for (prev, next) in zip(list, list.dropFirst()) where Self.kind(prev.part) != Self.kind(next.part) {
            guard let p = f.slots[prev.id], let q = f.slots[next.id], p.minY == q.minY else { continue }
            a.dividers.append(CGRect(x: (p.maxX + q.minX) / 2 - 0.5, y: p.minY + (Self.rowHeight - 16) / 2, width: 1, height: 16))
        }
        return a
    }

    static let columnPad: CGFloat = 10
    /// Between lines of one kind, and between sections (a hairline sits in it).
    static let lineGap: CGFloat = 6
    static let sectionGap: CGFloat = 17
    /// An upright meter: its bar at the least, and the labels under it.
    static let meterWidth: CGFloat = 36
    static let meterLabels: CGFloat = 34
    static let meterMinBar: CGFloat = 56
    /// Pulled as narrow as it goes: the bars alone, side by side, no numbers.
    static let slimMeter: CGFloat = 8
    static let slimGap: CGFloat = 6

    /// How a column line holds its items: meters and icons side by side,
    /// centred; a number or metric on a line of its own, from the left;
    /// the chat and buttons across the whole width.
    private enum Line { case meters, icons, list, full }

    private func column(width: CGFloat, height: CGFloat) -> Arrangement {
        var a = Arrangement()
        a.vertical = true
        let pad = Self.columnPad
        let inner = max(Self.character, width - pad * 2)
        let top = Self.character + Self.sectionGap
        // Too narrow for a number under each bar: just the bars.
        let slim = inner < Self.meterWidth
        func lineGap(_ kind: Line) -> CGFloat { kind == .meters && slim ? Self.slimGap : Self.gap }
        typealias Item = (id: String, part: Part, size: CGSize)
        var lines: [(kind: Line, items: [Item])] = []
        func gapBefore(_ i: Int) -> CGFloat {
            i == 0 ? 0 : Self.kind(lines[i - 1].items[0].part) != Self.kind(lines[i].items[0].part) ? Self.sectionGap : Self.lineGap
        }
        func contentHeight() -> CGFloat {
            lines.indices.reduce(0) { $0 + gapBefore($1) + (lines[$1].items.map(\.size.height).max() ?? 0) }
        }
        for p in parts {
            let item: Item
            let kind: Line
            switch p.part {
            case .sessionBar, .contextBar: continue
            case .session, .context:
                item = (p.id, p.part, slim ? CGSize(width: Self.slimMeter, height: Self.meterMinBar)
                        : CGSize(width: Self.meterWidth, height: Self.meterMinBar + Self.meterLabels)); kind = .meters
            case .focus:
                // Its name when there's room, else just its dot.
                let w = p.width <= inner ? p.width : 14
                item = (p.id, p.part, CGSize(width: w, height: 20)); kind = .list
            case .templates, .shot, .mic: item = (p.id, p.part, CGSize(width: 26, height: 26)); kind = .icons
            case .reset, .cost, .metric: item = (p.id, p.part, CGSize(width: p.width, height: 20)); kind = .list
            case .button: item = (p.id, p.part, CGSize(width: p.width, height: 26)); kind = .full
            case .chat: item = (p.id, p.part, chatSize); kind = .full
            }
            // Too wide for the column: left out until it's pulled wider.
            guard item.size.width <= inner else { continue }
            let saved = lines
            if let last = lines.last, last.kind == kind, kind == .meters || kind == .icons,
               last.items.map(\.size.width).reduce(0, +) + lineGap(kind) * CGFloat(last.items.count) + item.size.width <= inner {
                lines[lines.count - 1].items.append(item)
            } else {
                lines.append((kind, [item]))
            }
            if pad + top + contentHeight() + pad > height {
                lines = saved
                break
            }
        }
        // The meters take whatever height is left.
        let meterLines = lines.indices.filter { lines[$0].kind == .meters }
        let extra = meterLines.isEmpty ? 0 : max(0, height - pad * 2 - top - contentHeight()) / CGFloat(meterLines.count)
        let fromLeft = inner >= 100
        var y = top
        var natural = Self.character
        for (i, line) in lines.enumerated() {
            let gap = gapBefore(i)
            y += gap
            if i > 0 && gap == Self.sectionGap {
                a.dividers.append(CGRect(x: 4, y: y - gap / 2 - 0.5, width: inner - 8, height: 1))
            }
            let grow = line.kind == .meters ? extra : 0
            let lineHeight = (line.items.map(\.size.height).max() ?? 0) + grow
            let lineWidth = line.items.map(\.size.width).reduce(0, +) + lineGap(line.kind) * CGFloat(line.items.count - 1)
            natural = max(natural, lineWidth)
            var x: CGFloat
            switch line.kind {
            case .meters, .icons: x = (inner - lineWidth) / 2
            case .list: x = fromLeft ? 0 : (inner - lineWidth) / 2
            case .full: x = 0
            }
            for item in line.items {
                let w = line.kind == .full ? inner : item.size.width
                let h = line.kind == .meters ? item.size.height + grow : item.size.height
                a.slots[item.id] = CGRect(x: x, y: y + (lineHeight - h) / 2, width: w, height: h)
                a.ids.append(item.id)
                a.parts[item.id] = item.part
                x += w + lineGap(line.kind)
            }
            y += lineHeight
        }
        a.board = CGSize(width: inner, height: y)
        a.character = CGPoint(x: (inner - Self.character) / 2, y: 0)
        a.inset = CGSize(width: pad, height: pad)
        a.frame = CGSize(width: width, height: meterLines.isEmpty ? pad * 2 + y : height)
        a.natural = max(Self.minWidth, natural + pad * 2)
        a.shown = Set(a.parts.values)
        return a
    }

    /// Everything within `width`: the tallest it gets.
    func maxHeight(width: CGFloat) -> CGFloat { size(parts.count, width: max(width, Self.minWidth)).height }
}

