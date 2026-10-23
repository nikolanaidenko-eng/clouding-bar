import AppKit
import SwiftUI
import UniformTypeIdentifiers

// The pill: what it shows at a given size, its chat, and dragging items
// onto each other to swap them (owner's requests, 18.10).

// MARK: - Order

extension AppModel {
    /// Every item the pill and the panel can show, in the owner's order.
    var itemIDs: [String] {
        let all = ["focus", "session", "context", "reset", "cost"] + Metric.ids.map { "metric:" + $0 } + ["chat"]
            + buttons.map { "button:" + $0.label } + ["templates", "shot", "mic"]
        let order = config.itemOrder
        // Which chat it shows comes first, unless it was moved.
        func rank(_ e: (offset: Int, element: String)) -> Int {
            order.firstIndex(of: e.element) ?? (e.element == "focus" ? -1 : order.count + e.offset)
        }
        return all.enumerated().sorted { rank($0) < rank($1) }.map(\.element)
    }

    func rank(_ id: String) -> Int { itemIDs.firstIndex(of: id) ?? .max }

    /// Dropped one item onto another: they trade places, here and wherever
    /// else both show.
    func swapItems(_ a: String, _ b: String) {
        var ids = itemIDs
        guard a != b, let i = ids.firstIndex(of: a), let j = ids.firstIndex(of: b) else { return }
        ids.swapAt(i, j)
        setConfig("itemOrder", ids)
    }
}

/// Drag one item onto another to swap them, the way the iPhone's Home
/// Screen and Finder's toolbar rearrange things: the item lifts (a touch
/// bigger, with a shadow) and follows the pointer, leaving its slot empty;
/// the item under the pointer glides into that slot on a spring before you
/// let go; let go and it settles into place. Back over its own slot, the
/// swap is called off.
final class Rearrange: ObservableObject {
    let space: String
    @Published private(set) var dragging: String?
    @Published private(set) var target: String?
    /// The lifted copy's top-left, in the board's space.
    @Published private(set) var liftAt: CGPoint = .zero
    @Published private(set) var lifted = false
    /// Where each item sits right now; the board sets it on every render.
    var slots: [String: CGRect] = [:]
    /// Whether swapping these two is allowed (on the pill: the dragged item
    /// must still fit).
    var accepts: (String, String) -> Bool = { _, _ in true }
    private var grab: CGSize = .zero
    private var changedAt = Date.distantPast
    private var endedAt = Date.distantPast

    static let reflow = Animation.spring(response: 0.38, dampingFraction: 0.82)
    static let lift = Animation.spring(response: 0.24, dampingFraction: 0.68)
    static let settle = Animation.spring(response: 0.36, dampingFraction: 0.8)

    init(space: String) { self.space = space }

    /// The order on screen: the owner's, with the dragged item and the one
    /// under it already traded.
    func order(_ ids: [String]) -> [String] {
        guard let a = dragging, let b = target, let i = ids.firstIndex(of: a), let j = ids.firstIndex(of: b) else { return ids }
        var o = ids
        o.swapAt(i, j)
        return o
    }

    /// A click that ends a drag isn't a click.
    var clickAllowed: Bool { dragging == nil && Date().timeIntervalSince(endedAt) > 0.3 }

    var isDragging: Bool { dragging != nil }

    func changed(_ id: String, _ v: DragGesture.Value) {
        if dragging == nil {
            guard let slot = slots[id] else { return }
            grab = CGSize(width: v.startLocation.x - slot.minX, height: v.startLocation.y - slot.minY)
            liftAt = slot.origin
            dragging = id
            withAnimation(Self.lift) { lifted = true }
        }
        guard dragging == id else { return }
        liftAt = CGPoint(x: v.location.x - grab.width, y: v.location.y - grab.height)
        // Let a glide finish before the next one.
        guard Date().timeIntervalSince(changedAt) > 0.18 else { return }
        let under = slots.first { $0.key != id && $0.value.contains(v.location) }?.key
        guard let under else { return }
        // The current target sits in the dragged item's own slot: back home.
        let next: String? = under == target ? nil : under
        guard next == nil || accepts(id, under) else { return }
        changedAt = Date()
        withAnimation(Self.reflow) { target = next }
    }

    func ended(_ commit: (String, String) -> Void) {
        guard let id = dragging else { return }
        endedAt = Date()
        let to = target
        withAnimation(Self.settle) {
            if let to { commit(id, to) }
            target = nil
            lifted = false
            if let slot = slots[id] { liftAt = slot.origin }
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.34) { [weak self] in
            guard let self, self.dragging == id else { return }
            self.dragging = nil
            self.endedAt = Date()
        }
    }
}

/// Items placed by hand in `slots` (one container, so an item keeps its
/// identity — and its drag — when it moves to another row), with the lifted
/// copy on top while one is dragged.
struct RearrangeBoard<Item: View>: View {
    let ids: [String]
    let slots: [String: CGRect]
    let size: CGSize
    @ObservedObject var rearrange: Rearrange
    let commit: (String, String) -> Void
    @ViewBuilder let item: (String) -> Item

    var body: some View {
        rearrange.slots = slots
        return ZStack(alignment: .topLeading) {
            ForEach(ids, id: \.self) { id in
                if let r = slots[id] {
                    item(id)
                        .frame(width: r.width, height: r.height)
                        // Nearly 0, not 0: it must keep the drag going.
                        .opacity(rearrange.dragging == id ? 0.001 : 1)
                        .offset(x: r.minX, y: r.minY)
                        .simultaneousGesture(DragGesture(minimumDistance: 4, coordinateSpace: .named(rearrange.space))
                            .onChanged { rearrange.changed(id, $0) }
                            .onEnded { _ in rearrange.ended(commit) })
                        .transition(.opacity.combined(with: .scale(scale: 0.85)))
                }
            }
            if let id = rearrange.dragging, let r = slots[id] {
                item(id)
                    .environment(\.cbStill, true)
                    .frame(width: r.width, height: r.height)
                    .scaleEffect(rearrange.lifted ? 1.08 : 1)
                    .shadow(color: .black.opacity(rearrange.lifted ? 0.45 : 0), radius: rearrange.lifted ? 10 : 0,
                            y: rearrange.lifted ? 6 : 0)
                    .offset(x: rearrange.liftAt.x, y: rearrange.liftAt.y)
                    .allowsHitTesting(false)
                    .zIndex(1)
            }
        }
        .frame(width: size.width, height: size.height, alignment: .topLeading)
        .coordinateSpace(name: rearrange.space)
        .environment(\.clickGate, { [weak rearrange] in rearrange?.clickAllowed ?? true })
    }
}

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

private struct ClickGateKey: EnvironmentKey { static let defaultValue: () -> Bool = { true } }
private struct StillKey: EnvironmentKey { static let defaultValue = false }

extension EnvironmentValues {
    /// False just after a drag: the release isn't a click.
    var clickGate: () -> Bool {
        get { self[ClickGateKey.self] }
        set { self[ClickGateKey.self] = newValue }
    }
    /// A copy that shouldn't animate in (the lifted item).
    var cbStill: Bool {
        get { self[StillKey.self] }
        set { self[StillKey.self] = newValue }
    }
}

extension View {
    /// Tells the widget the pointer is over a control, so hovering it
    /// doesn't open the panel underneath.
    func hoverReport(_ state: WidgetState) -> some View {
        onHover { [weak state] inside in state?.controlHover?(inside) }
    }
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

    /// Each part, the width it adds (a bar widens its number's group) and
    /// its id for swapping.
    let parts: [(part: Part, width: CGFloat, id: String)]
    private let model: AppModel?

    /// `order`: the items' ids in the order to show them (the owner's by
    /// default; mid-drag, with the swap being previewed).
    init(model: AppModel, order: [String]? = nil) {
        self.model = model
        let ids = order ?? model.itemIDs
        func rank(_ id: String) -> Int { ids.firstIndex(of: id) ?? .max }
        // A little over the measured width: SwiftUI's text runs a hair wider.
        func text(_ t: String, _ size: CGFloat = 13) -> CGFloat {
            ceil((t as NSString).size(withAttributes: [.font: NSFont.monospacedDigitSystemFont(ofSize: size, weight: .regular)]).width) + 3
        }
        let shows = model.config.pillShows
        let hides = Set(model.config.widgetHides)
        var list: [(part: Part, width: CGFloat, id: String)] = []
        // With several chats: which one this is.
        if model.sessions.count > 1, let name = model.chatName {
            list.append((.focus, Self.focusWidth(name), "focus"))
        }
        if !hides.contains("session") { list.append((.session, text(Self.percent(model.sessionPercent)), "session")) }
        if shows.contains("context"), let c = model.contextPercent {
            list.append((.context, text("ctx", 11) + 6 + text(Self.percent(c)), "context"))
        }
        if shows.contains("reset"), let r = model.resetShort { list.append((.reset, 12 + 4 + text(r), "reset")) }
        if shows.contains("cost"), let c = model.cost { list.append((.cost, text(String(format: "$%.2f", c)), "cost")) }
        // Cost shown as a number already: not again as a metric.
        for m in Metric.list(model) where !(m.id == "cost" && shows.contains("cost")) {
            list.append((.metric(m.id), m.plainWidth, "metric:" + m.id))
        }
        if model.config.taskQueue {
            list.append((.chat, Self.chatWidth(model), "chat"))
        } else {
            for (i, b) in model.buttons.enumerated() {
                list.append((.button(i), Self.buttonWidth(b.label), "button:" + b.label))
            }
        }
        if model.config.templatesEnabled && !model.config.templates.isEmpty { list.append((.templates, 26, "templates")) }
        if model.config.screenshot { list.append((.shot, 26, "shot")) }
        if !hides.contains("mic") { list.append((.mic, 26, "mic")) }
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
        parts = list
    }

    static func percent(_ p: Double?) -> String { p.map { "\(Int($0.rounded()))%" } ?? "—" }

    /// The chat's dot and its name, cut short.
    static let focusName: CGFloat = 110
    static func focusWidth(_ name: String) -> CGFloat {
        7 + 6 + min(focusName, MainPanel.textWidth(name, 12) + 2)
    }

    static func buttonWidth(_ label: String) -> CGFloat { max(44, MainPanel.textWidth(label, 12) + 20) }

    /// The chat: a bit to write in, then the buttons, in one rounded box.
    static func chatWidth(_ model: AppModel) -> CGFloat {
        8 + chatField + model.buttons.reduce(0) { $0 + 6 + buttonWidth($1.label) } + 4
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

    /// The chat as a column: the bit to write in, the buttons under it.
    static func chatColumn(_ model: AppModel) -> CGSize {
        let widest = model.buttons.map { buttonWidth($0.label) }.max() ?? 0
        return CGSize(width: max(chatField + 16, widest + 10), height: 10 + 24 + CGFloat(model.buttons.count) * 26)
    }

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
            case .chat: item = (p.id, p.part, model.map(Self.chatColumn) ?? .zero); kind = .full
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

// MARK: - Pill

struct PillView: View {
    @ObservedObject var model: AppModel
    @ObservedObject var state: WidgetState

    private var editing: Bool { state.pillEditSize != nil }

    var body: some View {
        let layout = PillLayout(model: model)
        let special = model.request != nil || !model.hasSession
        Group {
            if model.voiceShown && model.request == nil {
                // Dictating, or the words to check: grows with them.
                DictationCard(model: model)
                    .padding(.horizontal, 16).padding(.vertical, 12)
                    .allowsHitTesting(!model.listening) // listening: a click anywhere stops it
            } else if special {
                specialContent
                    .lineLimit(1)
                    .fixedSize()
                    .padding(.leading, 10)
                    .padding(.trailing, 20)
                    .frame(height: 44)
                    .allowsHitTesting(false)
            } else if state.pillTyping {
                PillTyping(model: model, state: state, width: max(340, current(layout).width))
                    .frame(height: current(layout).height > 60 ? current(layout).height : nil, alignment: .top)
            } else {
                sized(layout)
            }
        }
        .font(.system(size: 13).monospacedDigit())
        .foregroundColor(.cbText)
        .background(PillDragHandle(state: state))
        .modifier(Glass(radius: 22, border: model.request != nil ? Color.cbWarning.opacity(0.5) : .cbHairline))
        .overlay(outline)
        .transition(.scale(scale: 0.9).combined(with: .opacity))
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Clouding Bar")
    }

    /// Edit mode: a thick outline all the way round. Hovering: a faint one.
    @ViewBuilder private var outline: some View {
        if state.dropHover {
            RoundedRectangle(cornerRadius: 22, style: .continuous)
                .strokeBorder(Color.cbAction, lineWidth: 2.5)
                .allowsHitTesting(false)
                .transition(.opacity)
        } else if editing {
            RoundedRectangle(cornerRadius: 22, style: .continuous)
                .strokeBorder(Color.cbAction, lineWidth: 3)
                .allowsHitTesting(false)
        } else if state.pillHover && model.request == nil && !model.listening && !state.pillTyping {
            RoundedRectangle(cornerRadius: 22, style: .continuous)
                .strokeBorder(Color.white.opacity(0.3), lineWidth: 1.5)
                .allowsHitTesting(false)
                .transition(.opacity)
        }
    }

    private func budget() -> CGSize {
        state.pillEditSize ?? CGSize(width: model.pillBudget, height: model.pillHeightBudget)
    }

    private func current(_ layout: PillLayout) -> CGSize {
        let b = budget()
        return layout.arrange(width: b.width, height: b.height).frame
    }

    /// The usual pill: as many rows and as much in them as its size allows.
    private func sized(_ layout: PillLayout) -> some View {
        PillBoard(model: model, state: state, rearrange: state.pillRearrange, budget: budget())
    }

    @ViewBuilder private var specialContent: some View {
        if model.listening {
            // The words as they come; the newest stay in view.
            HStack(spacing: 10) {
                MascotIcon(activity: .work, size: 30).frame(width: 30, height: 30)
                Icon(kind: .mic, size: 15, lineWidth: 1.8).foregroundColor(.cbAction)
                Text(model.heard.isEmpty ? "Listening…" : model.heard)
                    .foregroundColor(model.heard.isEmpty ? .cbSecondary : .cbText)
                    .truncationMode(.head)
                    .frame(width: 300, alignment: .leading)
            }
        } else if let r = model.request {
            HStack(spacing: 10) {
                MascotIcon(activity: .wait, size: 30).frame(width: 30, height: 30)
                Text(model.statusTitle)
                if model.sessions.count > 1, let chat = r.chat {
                    ChatTag(name: chat, color: r.color ?? 0x0A84FF, maxWidth: 140)
                }
                PulseDot(still: model.config.doNotDisturb)
            }
        } else {
            HStack(spacing: 10) {
                MascotIcon(activity: .sleep, size: 30).frame(width: 30, height: 30)
                Text(PillLayout.percent(model.sessionPercent)).foregroundColor(.cbSecondary)
            }
        }
    }

}


/// The pill's items, laid out by hand in rows after the character, so
/// they can be dragged onto each other.
struct PillBoard: View {
    @ObservedObject var model: AppModel
    @ObservedObject var state: WidgetState
    @ObservedObject var rearrange: Rearrange
    let budget: CGSize
    /// In a real notch: the camera's width, kept clear in the middle.
    var camera: CGFloat = 0
    /// In the notch: black, square, the island's shape drawn around it.
    var notched = false

    var body: some View {
        let base = model.itemIDs
        var a = PillLayout(model: model, order: rearrange.order(base)).arrange(width: budget.width, height: budget.height)
        if camera > 0 {
            a = a.makingRoom(at: a.frame.width / 2 - a.inset.width, width: camera, above: state.notchHeight - a.inset.height)
        }
        // While its outline is pulled, the pill follows the pointer exactly
        // (in the notch, the island does; the shoulders are outside this).
        let frame = state.pillEditSize.map {
            CGSize(width: max(PillLayout.minWidth, $0.width - (notched ? 2 * NotchView.shoulder : 0)),
                   height: max(PillLayout.height(rows: 1), $0.height))
        } ?? a.frame
        rearrange.accepts = { [model, budget] dragged, other in
            // The dragged item has to stay on the pill.
            var ids = base
            guard let i = ids.firstIndex(of: dragged), let j = ids.firstIndex(of: other) else { return false }
            ids.swapAt(i, j)
            return PillLayout(model: model, order: ids).arrange(width: budget.width, height: budget.height)
                .slots[dragged] != nil
        }
        return Group {
            if a.ids.isEmpty && !a.vertical {
                character
                    .frame(width: frame.width, height: frame.height)
            } else {
                ZStack(alignment: .topLeading) {
                    character
                        .offset(x: a.character.x, y: a.character.y)
                    ForEach(Array(a.dividers.enumerated()), id: \.offset) { _, d in
                        Rectangle().fill(Color.white.opacity(0.12))
                            .frame(width: d.width, height: d.height)
                            .offset(x: d.minX, y: d.minY)
                            .allowsHitTesting(false)
                    }
                    RearrangeBoard(ids: a.ids, slots: a.slots, size: a.board, rearrange: rearrange,
                                   commit: { model.swapItems($0, $1) }) { id in
                        if let part = a.parts[id] {
                            item(part, shown: a.shown, vertical: a.vertical, slot: a.slots[id]?.size ?? .zero)
                        }
                    }
                }
                .lineLimit(1)
                .padding(.leading, a.inset.width)
                .padding(.top, a.inset.height)
                .frame(width: frame.width, height: frame.height, alignment: .topLeading)
            }
        }
        .clipShape(RoundedRectangle(cornerRadius: notched ? 0 : 22, style: .continuous))
        .animation(.cb(0.2), value: a.ids)
        .animation(.cb(0.28), value: a.vertical)
    }

    /// Cloud, with the number of files waiting for Claude (or a "+" while
    /// some are dragged over).
    private var character: some View {
        MascotIcon(activity: model.activity, size: 30, pokes: model.cloudPokes).frame(width: 30, height: 30)
            .overlay(FileBadge(text: state.dropHover ? "+" : model.attachments.isEmpty ? nil : "\(model.attachments.count)")
                .offset(x: 5, y: -3), alignment: .topTrailing)
            .allowsHitTesting(false)
    }

    /// On the pill the model and the subagents open the panel, with the
    /// model picker or the list of subagents.
    private func opensPanel(_ metric: Metric) -> Metric {
        var m = metric
        let agents = metric.id == "agents"
        m.action = { [weak model, weak state] in
            model?.pickingModel = !agents
            model?.showingAgents = agents
            state?.openPanel?()
        }
        return m
    }

    /// An upright meter: the bar as tall as the slot allows, the number and
    /// what it is under it.
    private func upright(_ percent: Double?, _ label: String, height: CGFloat, delay: Double = 0) -> some View {
        VStack(spacing: 4) {
            MeterBar(percent: percent, height: 6, track: .white.opacity(0.14), delay: delay, vertical: true)
                .frame(height: max(0, height - PillLayout.meterLabels))
            Text(PillLayout.percent(percent)).font(.system(size: 12, weight: .semibold).monospacedDigit())
            Text(label).font(.system(size: 10)).foregroundColor(.cbSecondary)
        }
        .frame(width: PillLayout.meterWidth, height: height, alignment: .top)
    }

    /// As narrow as it goes: the bar alone; the number shows on hover.
    private func slim(_ percent: Double?, _ label: String, delay: Double = 0) -> some View {
        MeterBar(percent: percent, height: 6, track: .white.opacity(0.14), delay: delay, vertical: true)
            .frame(maxHeight: .infinity)
            .help("\(label): \(PillLayout.percent(percent))")
            .accessibilityLabel("\(label) \(PillLayout.percent(percent))")
    }

    /// One item: a number (with its bar, if shown), a metric or a control.
    /// A click on a number opens the panel.
    @ViewBuilder private func item(_ part: PillLayout.Part, shown: Set<PillLayout.Part>, vertical: Bool,
                                   slot: CGSize) -> some View {
        switch part {
        case .focus:
            PillFocus(model: model, dotOnly: slot.width < 40).hoverReport(state).transition(.opacity)
        case .session where vertical && slot.width < PillLayout.meterWidth:
            slim(model.sessionPercent, "5-hour limit").opensPanel(state)
        case .context where vertical && slot.width < PillLayout.meterWidth:
            slim(model.contextPercent, "Context", delay: 0.12).opensPanel(state)
        case .session where vertical:
            upright(model.sessionPercent, "5h", height: slot.height).opensPanel(state)
        case .context where vertical:
            upright(model.contextPercent, "ctx", height: slot.height, delay: 0.12).opensPanel(state)
        case .chat where vertical:
            PillChat(model: model, state: state, rearrange: rearrange, column: true)
                .frame(width: slot.width).transition(.opacity)
        case .session:
            HStack(spacing: 8) {
                if shown.contains(.sessionBar) {
                    MeterBar(percent: model.sessionPercent, height: 3, track: .white.opacity(0.14))
                        .frame(width: PillLayout.barWidth)
                }
                Text(PillLayout.percent(model.sessionPercent))
            }
            .opensPanel(state)
        case .context:
            HStack(spacing: 6) {
                Text("ctx").font(.system(size: 11)).foregroundColor(.cbSecondary)
                if shown.contains(.contextBar) {
                    MeterBar(percent: model.contextPercent, height: 3, track: .white.opacity(0.14), delay: 0.12)
                        .frame(width: PillLayout.barWidth)
                }
                Text(PillLayout.percent(model.contextPercent))
            }
            .opensPanel(state)
            .transition(.opacity)
        case .reset:
            HStack(spacing: 4) {
                Icon(kind: .clock, size: 12, lineWidth: 2.2).foregroundColor(.cbSecondary)
                    .accessibilityLabel("resets in")
                Text(model.resetShort ?? "—")
            }
            .opensPanel(state)
            .transition(.opacity)
        case .cost:
            Text(String(format: "$%.2f", model.cost ?? 0)).foregroundColor(.cbFill)
                .opensPanel(state).transition(.opacity)
        case let .metric(id):
            if let m = Metric.list(model).first(where: { $0.id == id }) {
                MetricChip(metric: id == "model" || id == "agents" ? opensPanel(m) : m, plain: true)
                    .hoverReport(state).transition(.opacity)
            }
        case let .button(i):
            if model.buttons.indices.contains(i) {
                Button(model.buttons[i].label) { if rearrange.clickAllowed { model.perform(.button(i)) } }
                    .buttonStyle(PillButtonStyle(fill: vertical))
                    .frame(width: vertical ? slot.width : nil)
                    .hoverReport(state)
                    .transition(.opacity)
            }
        case .chat: PillChat(model: model, state: state, rearrange: rearrange).transition(.opacity)
        case .templates: TemplatesButton(model: model, size: 26, plain: true).hoverReport(state).transition(.opacity)
        case .shot: ShotButton(model: model, size: 26, plain: true).hoverReport(state).transition(.opacity)
        case .mic: MicButton(model: model, size: 26, plain: true).hoverReport(state).transition(.opacity)
        case .sessionBar, .contextBar: EmptyView()
        }
    }
}

/// A click on a number opens the panel (not the release of a drag).
private struct OpensPanel: ViewModifier {
    let state: WidgetState
    @Environment(\.clickGate) private var gate
    func body(content: Content) -> some View {
        content.contentShape(Rectangle()).onTapGesture { [weak state] in if gate() { state?.openPanel?() } }
    }
}

extension View {
    fileprivate func opensPanel(_ state: WidgetState) -> some View { modifier(OpensPanel(state: state)) }
}

/// The pill's chat, as in the panel: a bit to click and write in, then the
/// buttons. Click the empty bit and the pill turns into the text box.
struct PillChat: View {
    @ObservedObject var model: AppModel
    @ObservedObject var state: WidgetState
    @ObservedObject var rearrange: Rearrange
    /// In the upright pill: the bit to write in on top, the buttons under it.
    var column = false

    var body: some View {
        let order = model.buttons.indices.sorted {
            model.rank("button:" + model.buttons[$0].label) < model.rank("button:" + model.buttons[$1].label)
        }
        let buttons = ForEach(order, id: \.self) { i in
            Button(model.buttons[i].label) { if rearrange.clickAllowed { model.perform(.button(i)) } }
                .buttonStyle(PillButtonStyle(height: 22, fill: column))
                .hoverReport(state)
        }
        Group {
            if column {
                VStack(spacing: 4) {
                    field.frame(maxWidth: .infinity, minHeight: 24, maxHeight: 24, alignment: .leading)
                    buttons
                }
                .padding(5)
            } else {
                HStack(spacing: 6) {
                    field.frame(width: PillLayout.chatField, height: 26, alignment: .leading)
                    buttons
                }
                .padding(.leading, 8)
                .padding(.trailing, 4)
                .frame(height: 30)
            }
        }
        .background(RoundedRectangle(cornerRadius: column ? 12 : 15, style: .continuous).fill(Color.black.opacity(0.25)))
        .overlay(RoundedRectangle(cornerRadius: column ? 12 : 15, style: .continuous)
            .strokeBorder(Color.white.opacity(0.12), lineWidth: 0.5))
    }

    private var field: some View {
        Text(state.pillDraft.isEmpty ? "Write…" : state.pillDraft)
            .font(.system(size: 12))
            .foregroundColor(state.pillDraft.isEmpty ? .cbMuted : .cbSecondary)
            .truncationMode(.head)
            .padding(.leading, column ? 4 : 0)
            .contentShape(Rectangle())
            .onTapGesture { [weak state, weak rearrange] in
                if rearrange?.clickAllowed ?? true { state?.startTyping?() }
            }
            .onHover { inside in if inside { NSCursor.iBeam.push() } else { NSCursor.pop() } }
            .hoverReport(state)
            .help("Write to Claude: sent now if it's free, after this reply if not")
            .accessibilityLabel("Write to Claude")
            .accessibilityAddTraits(.isButton)
    }
}

/// Writing in the pill: only the character, the text and Send. ⏎ sends
/// (now if Claude is free, else after its reply), esc puts it away.
struct PillTyping: View {
    @ObservedObject var model: AppModel
    @ObservedObject var state: WidgetState
    let width: CGFloat
    /// Inside the grown notch: no character (its header has one), no padding.
    var inline = false
    @FocusState private var focused: Bool

    var body: some View {
        HStack(spacing: 10) {
            if !inline {
                MascotIcon(activity: model.activity, size: 30, pokes: model.cloudPokes).frame(width: 30, height: 30)
                    .allowsHitTesting(false)
            }
            if !model.attachments.isEmpty {
                HStack(spacing: 3) {
                    Image(systemName: "paperclip").font(.system(size: 11))
                    Text("\(model.attachments.count)").font(.system(size: 12).monospacedDigit())
                }
                .foregroundColor(.cbSecondary)
                .help(model.attachments.map { ($0 as NSString).lastPathComponent }.joined(separator: ", "))
            }
            TextField(model.attachments.isEmpty ? "Write to " + (model.chatName.map { "“\($0)”" } ?? "Claude")
                      : "Add a message, or just send", text: $state.pillDraft)
                .textFieldStyle(.plain)
                .font(.system(size: 13))
                .focused($focused)
                .onSubmit(send)
                .onExitCommand { [weak state] in state?.endTyping?() }
                .frame(maxWidth: .infinity)
            Button(action: send) { Icon(kind: .send, size: 13, lineWidth: 2.4) }
                .buttonStyle(IconButtonStyle(background: state.pillDraft.isEmpty && model.attachments.isEmpty
                                                ? Color.white.opacity(0.1) : .cbAction,
                                             foreground: .white, size: 28))
                .accessibilityLabel("Send")
        }
        .padding(.leading, inline ? 0 : 10)
        .padding(.trailing, inline ? 0 : 8)
        .frame(width: width, height: inline ? 30 : 44)
        .onAppear { DispatchQueue.main.async { focused = true } }
        .transition(.opacity)
    }

    private func send() {
        let text = state.pillDraft.trimmingCharacters(in: .whitespacesAndNewlines)
        if !text.isEmpty || !model.attachments.isEmpty { model.addToQueue(text) }
        state.pillDraft = ""
        state.endTyping?()
    }
}

/// Which chat the pill shows: its dot and name (or the dot alone). A
/// click lists the chats to follow another one.
struct PillFocus: View {
    @ObservedObject var model: AppModel
    var dotOnly = false
    @Environment(\.clickGate) private var gate

    var body: some View {
        Button { if gate() { ChatMenu.show(model) } } label: {
            HStack(spacing: 6) {
                if model.chatDone {
                    // Done here: the widget moves on to the chat at work.
                    Image(systemName: "checkmark.circle.fill").font(.system(size: 10, weight: .semibold))
                        .foregroundColor(Color(hex: 0x30D158))
                        .transition(.scale.combined(with: .opacity))
                } else {
                    ChatDot(color: model.chatColor)
                }
                if !dotOnly {
                    Text(model.chatName ?? "").font(.system(size: 12)).foregroundColor(.cbText)
                        .lineLimit(1).truncationMode(.tail)
                        .frame(maxWidth: PillLayout.focusName, alignment: .leading)
                        .fixedSize(horizontal: true, vertical: false)
                }
            }
            .frame(minWidth: 14, minHeight: 20)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .help("Shows \(model.chatName ?? "this chat") — click to pick another chat")
        .accessibilityLabel("Chat: \(model.chatName ?? "")")
    }
}

/// The live chats as a menu at the pointer; picking one follows it.
enum ChatMenu {
    final class Target: NSObject {
        let pick: (String) -> Void
        init(_ pick: @escaping (String) -> Void) { self.pick = pick }
        @objc func chosen(_ item: NSMenuItem) { if let id = item.representedObject as? String { pick(id) } }
    }
    private static var target: Target?

    static func show(_ model: AppModel) {
        let menu = NSMenu()
        let t = Target { [weak model] id in model?.focusSession(id) }
        target = t
        for r in model.sessions {
            let item = NSMenuItem(title: r.name, action: #selector(Target.chosen(_:)), keyEquivalent: "")
            item.target = t
            item.representedObject = r.id
            item.state = r.current ? .on : .off
            item.image = dot(r.color)
            item.toolTip = r.place + " · " + r.status
            if r.waiting { item.title += "  — needs you" }
            menu.addItem(item)
        }
        menu.popUp(positioning: nil, at: NSEvent.mouseLocation, in: nil)
    }

    static func dot(_ color: UInt32) -> NSImage {
        NSImage(size: NSSize(width: 10, height: 10), flipped: false) { r in
            NSColor(srgbRed: CGFloat((color >> 16) & 0xFF) / 255, green: CGFloat((color >> 8) & 0xFF) / 255,
                    blue: CGFloat(color & 0xFF) / 255, alpha: 1).setFill()
            NSBezierPath(ovalIn: r.insetBy(dx: 1, dy: 1)).fill()
            return true
        }
    }
}

/// A small blue count on Cloud's shoulder: files waiting for Claude.
struct FileBadge: View {
    let text: String?

    var body: some View {
        if let text {
            Text(text)
                .font(.system(size: 9, weight: .bold).monospacedDigit())
                .foregroundColor(.white)
                .padding(.horizontal, 3)
                .frame(minWidth: 14, minHeight: 14)
                .background(Capsule().fill(Color.cbAction))
                .overlay(Capsule().strokeBorder(Color.black.opacity(0.35), lineWidth: 1))
                .transition(.scale.combined(with: .opacity))
                .accessibilityLabel(text == "+" ? "Drop to attach" : "\(text) files attached")
        }
    }
}

/// A button on the pill: a small capsule.
struct PillButtonStyle: ButtonStyle {
    var height: CGFloat = 26
    /// As wide as its container (the upright chat).
    var fill = false

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.system(size: 12))
            .foregroundColor(.cbText)
            .lineLimit(1)
            .padding(.horizontal, 10)
            .frame(minWidth: 44, maxWidth: fill ? .infinity : nil, minHeight: height)
            .background(Capsule().fill(Color.white.opacity(configuration.isPressed ? 0.2 : 0.1)))
            .contentShape(Capsule())
    }
}

/// Lets the pill be dragged (and clicked); its outline resizes it. It lies
/// under the pill's content, so the items get their own clicks and drags.
struct PillDragHandle: NSViewRepresentable {
    let state: WidgetState
    /// Off in the notch: it hangs from the top, so only its ends and bottom pull.
    var fromTop = true

    final class HandleView: NSView {
        weak var state: WidgetState?
        var fromTop = true
        override func mouseDown(with event: NSEvent) { state?.pillMouseDown?(event) }
        override func mouseDragged(with event: NSEvent) { state?.pillMouseDragged?(event) }
        override func mouseUp(with event: NSEvent) { state?.pillMouseUp?(event) }
        override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
        /// Diagonal resize arrows all along the outline, pointing the way
        /// it goes: the nearer end and the bottom (the top from the band
        /// along the top) — one drag sizes it both ways.
        override func resetCursorRects() {
            let edge = WidgetState.pillEdge, rim = WidgetState.pillRim
            let w = bounds.width, h = bounds.height, mid = w / 2
            // y up here: bottom-left and top-right share a diagonal.
            let rising = Self.diagonal("_windowResizeNorthEastSouthWestCursor")
            let falling = Self.diagonal("_windowResizeNorthWestSouthEastCursor")
            addCursorRect(NSRect(x: 0, y: 0, width: edge, height: h - rim), cursor: rising)
            addCursorRect(NSRect(x: w - edge, y: 0, width: edge, height: h - rim), cursor: falling)
            addCursorRect(NSRect(x: edge, y: 0, width: mid - edge, height: rim), cursor: rising)
            addCursorRect(NSRect(x: mid, y: 0, width: mid - edge, height: rim), cursor: falling)
            guard fromTop else { return }
            addCursorRect(NSRect(x: 0, y: h - rim, width: mid, height: rim), cursor: falling)
            addCursorRect(NSRect(x: mid, y: h - rim, width: mid, height: rim), cursor: rising)
        }

        /// macOS's own diagonal window-resize cursors aren't public; a
        /// crosshair stands in if they ever go away.
        private static func diagonal(_ name: String) -> NSCursor {
            let sel = NSSelectorFromString(name)
            guard NSCursor.responds(to: sel), let c = NSCursor.perform(sel)?.takeUnretainedValue() as? NSCursor else {
                return .crosshair
            }
            return c
        }

        override func setFrameSize(_ newSize: NSSize) {
            super.setFrameSize(newSize)
            window?.invalidateCursorRects(for: self)
        }
    }

    func makeNSView(context: Context) -> HandleView {
        let v = HandleView()
        v.state = state
        v.fromTop = fromTop
        return v
    }
    func updateNSView(_ nsView: HandleView, context: Context) {
        if nsView.fromTop != fromTop {
            nsView.fromTop = fromTop
            nsView.window?.invalidateCursorRects(for: nsView)
        }
    }
}
