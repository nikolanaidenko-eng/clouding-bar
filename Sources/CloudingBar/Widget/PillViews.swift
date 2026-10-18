import AppKit
import SwiftUI
import UniformTypeIdentifiers

// The pill: what it shows at a given size, its chat, and dragging items
// onto each other to swap them (owner's requests, 18.10).

// MARK: - Order

extension AppModel {
    /// Every item the pill and the panel can show, in the owner's order.
    var itemIDs: [String] {
        let all = ["session", "context", "reset", "cost"] + Metric.ids.map { "metric:" + $0 } + ["chat"]
            + buttons.map { "button:" + $0.label } + ["templates", "shot", "mic"]
        let order = config.itemOrder
        return all.enumerated().sorted { a, b in
            (order.firstIndex(of: a.element) ?? order.count + a.offset) < (order.firstIndex(of: b.element) ?? order.count + b.offset)
        }.map(\.element)
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
/// `firstRowStart` leaves room at the start of the first row.
func flowSlots(_ items: [(id: String, width: CGFloat)], width: CGFloat, rowHeight: CGFloat, gap: CGFloat,
               rowGap: CGFloat = 0, firstRowStart: CGFloat = 0) -> (slots: [String: CGRect], size: CGSize) {
    var slots: [String: CGRect] = [:]
    var x = firstRowStart, y: CGFloat = 0, widest = firstRowStart
    var rowEmpty = firstRowStart == 0
    for item in items {
        if !rowEmpty && x + gap + item.width > width {
            x = 0
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
        case session, context, reset, cost, sessionBar, contextBar
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
        var list: [(part: Part, width: CGFloat, id: String)] = [(.session, text(Self.percent(model.sessionPercent)), "session")]
        if shows.contains("context"), let c = model.contextPercent {
            list.append((.context, text("ctx", 11) + 6 + text(Self.percent(c)), "context"))
        }
        if shows.contains("reset"), let r = model.resetShort { list.append((.reset, 12 + 4 + text(r), "reset")) }
        if shows.contains("cost"), let c = model.cost { list.append((.cost, text(String(format: "$%.2f", c)), "cost")) }
        for m in Metric.list(model) { list.append((.metric(m.id), m.width, "metric:" + m.id)) }
        if model.config.taskQueue {
            list.append((.chat, Self.chatWidth(model), "chat"))
        } else {
            for (i, b) in model.buttons.enumerated() {
                list.append((.button(i), Self.buttonWidth(b.label), "button:" + b.label))
            }
        }
        if model.config.templatesEnabled && !model.config.templates.isEmpty { list.append((.templates, 26, "templates")) }
        if model.config.screenshot { list.append((.shot, 26, "shot")) }
        list.append((.mic, 26, "mic"))
        list = list.enumerated().sorted { a, b in
            let ra = rank(a.element.id), rb = rank(b.element.id)
            return ra != rb ? ra < rb : a.offset < b.offset
        }.map(\.element)
        // The bars come right after the last number.
        let numbers: Set<Part> = [.session, .context, .reset, .cost]
        var at = (list.lastIndex { numbers.contains($0.part) } ?? 0) + 1
        list.insert((.sessionBar, Self.barWidth + 8, "sessionBar"), at: at)
        if list.contains(where: { $0.part == .context }) {
            at += 1
            list.insert((.contextBar, Self.barWidth + 6, "contextBar"), at: at)
        }
        parts = list
    }

    static func percent(_ p: Double?) -> String { p.map { "\(Int($0.rounded()))%" } ?? "—" }

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

    /// Items into rows within `width`; the first row starts after the character.
    static func flow(_ widths: [CGFloat], width: CGFloat) -> (rows: [[Int]], widths: [CGFloat]) {
        let inner = width - pad
        var rows: [[Int]] = [[]]
        var used: [CGFloat] = [character]
        for (i, w) in widths.enumerated() {
            let last = rows.count - 1
            if rows[last].isEmpty && last > 0 {
                rows[last].append(i); used[last] = w
            } else if used[last] + gap + w <= inner {
                rows[last].append(i); used[last] += gap + w
            } else {
                rows.append([i]); used.append(w)
            }
        }
        return (rows, used)
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
        var shown: Set<Part> = []
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
                          gap: Self.gap, firstRowStart: Self.character)
        a.ids = list.map(\.id)
        a.parts = Dictionary(list.map { ($0.id, $0.part) }, uniquingKeysWith: { x, _ in x })
        a.slots = f.slots
        a.board = f.size
        a.character = CGPoint(x: 0, y: (Self.rowHeight - Self.character) / 2)
        a.frame = size(n, width: width)
        a.shown = Set(parts.prefix(n).map(\.part))
        return a
    }

    static let columnPad: CGFloat = 8
    static let columnGap: CGFloat = 8
    /// An upright meter: its bar at the least, and the labels under it.
    static let meterWidth: CGFloat = 36
    static let meterLabels: CGFloat = 34
    static let meterMinBar: CGFloat = 56

    /// The chat as a column: the bit to write in, the buttons under it.
    static func chatColumn(_ model: AppModel) -> CGSize {
        let widest = model.buttons.map { buttonWidth($0.label) }.max() ?? 0
        return CGSize(width: max(chatField + 16, widest + 10), height: 10 + 24 + CGFloat(model.buttons.count) * 26)
    }

    private func column(width: CGFloat, height: CGFloat) -> Arrangement {
        var a = Arrangement()
        a.vertical = true
        let pad = Self.columnPad, gap = Self.columnGap
        let inner = max(Self.character, width - pad * 2)
        let top = Self.character + gap
        // Sizes standing up; bars go into the meters.
        var sized: [(id: String, part: Part, size: CGSize)] = []
        for p in parts {
            let size: CGSize
            switch p.part {
            case .sessionBar, .contextBar: continue
            case .session, .context: size = CGSize(width: Self.meterWidth, height: Self.meterMinBar + Self.meterLabels)
            case .reset, .cost: size = CGSize(width: p.width, height: 20)
            case .metric: size = CGSize(width: p.width, height: 22)
            case .button: size = CGSize(width: p.width, height: 26)
            case .chat: size = model.map(Self.chatColumn) ?? .zero
            case .templates, .shot, .mic: size = CGSize(width: 26, height: 26)
            }
            sized.append((p.id, p.part, size))
        }
        // Rows of whatever fits side by side, centred; too wide: left out.
        var rows: [[(id: String, part: Part, size: CGSize)]] = [[]]
        var used: CGFloat = 0
        func contentHeight(_ rows: [[(id: String, part: Part, size: CGSize)]]) -> CGFloat {
            let filled = rows.filter { !$0.isEmpty }
            return filled.reduce(0) { $0 + ($1.map(\.size.height).max() ?? 0) } + gap * CGFloat(max(0, filled.count - 1))
        }
        for item in sized where item.size.width <= inner {
            var next = rows
            if !next[next.count - 1].isEmpty && used + gap + item.size.width > inner {
                next.append([item])
            } else {
                next[next.count - 1].append(item)
            }
            guard pad + top + contentHeight(next) + pad <= height else { break }
            used = next[next.count - 1].count == 1 ? item.size.width : used + gap + item.size.width
            rows = next
        }
        rows = rows.filter { !$0.isEmpty }
        // The meters take whatever height is left.
        let meterRows = rows.indices.filter { rows[$0].contains { $0.part == .session || $0.part == .context } }
        let extra = meterRows.isEmpty ? 0 : max(0, height - pad * 2 - top - contentHeight(rows)) / CGFloat(meterRows.count)
        var y = top
        var widest = Self.character
        for (r, row) in rows.enumerated() {
            let grow = meterRows.contains(r) ? extra : 0
            let rowHeight = (row.map(\.size.height).max() ?? 0) + grow
            let rowWidth = row.map(\.size.width).reduce(0, +) + gap * CGFloat(row.count - 1)
            widest = max(widest, rowWidth)
            var x = (inner - rowWidth) / 2
            for item in row {
                let meter = item.part == .session || item.part == .context
                let h = meter ? item.size.height + grow : item.size.height
                a.slots[item.id] = CGRect(x: x, y: y + (meter ? 0 : (rowHeight - h) / 2), width: item.size.width, height: h)
                a.ids.append(item.id)
                a.parts[item.id] = item.part
                x += item.size.width + gap
            }
            y += rowHeight + gap
        }
        a.board = CGSize(width: inner, height: max(Self.character, y - gap))
        a.character = CGPoint(x: (inner - Self.character) / 2, y: 0)
        a.inset = CGSize(width: pad, height: pad)
        a.frame = CGSize(width: max(Self.minWidth, widest + pad * 2),
                         height: meterRows.isEmpty ? pad * 2 + a.board.height : height)
        // The column was narrowed below what it shows: centre in what's there.
        if a.frame.width < width {
            let shift = (inner - (a.frame.width - pad * 2)) / 2
            for (id, r) in a.slots { a.slots[id] = r.offsetBy(dx: -shift, dy: 0) }
            a.character.x -= shift
            a.board.width = a.frame.width - pad * 2
        }
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
        let special = model.listening || model.request != nil || !model.hasSession
        Group {
            if special {
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
        if editing {
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
        } else if model.request != nil {
            HStack(spacing: 10) {
                MascotIcon(activity: .wait, size: 30).frame(width: 30, height: 30)
                Text(model.statusTitle)
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

    var body: some View {
        let base = model.itemIDs
        let a = PillLayout(model: model, order: rearrange.order(base)).arrange(width: budget.width, height: budget.height)
        // While its outline is pulled, the pill follows the pointer exactly.
        let frame = state.pillEditSize.map {
            CGSize(width: max(PillLayout.minWidth, $0.width), height: max(PillLayout.height(rows: 1), $0.height))
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
                MascotIcon(activity: model.activity, size: 30).frame(width: 30, height: 30)
                    .allowsHitTesting(false)
                    .frame(width: frame.width, height: frame.height)
            } else {
                ZStack(alignment: .topLeading) {
                    MascotIcon(activity: model.activity, size: 30).frame(width: 30, height: 30)
                        .offset(x: a.character.x, y: a.character.y)
                        .allowsHitTesting(false)
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
        .clipShape(RoundedRectangle(cornerRadius: 22, style: .continuous))
        .animation(.cb(0.2), value: a.ids)
        .animation(.cb(0.28), value: a.vertical)
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

    /// One item: a number (with its bar, if shown), a metric or a control.
    /// A click on a number opens the panel.
    @ViewBuilder private func item(_ part: PillLayout.Part, shown: Set<PillLayout.Part>, vertical: Bool,
                                   slot: CGSize) -> some View {
        switch part {
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
                MetricChip(metric: m).hoverReport(state).transition(.opacity)
            }
        case let .button(i):
            if model.buttons.indices.contains(i) {
                Button(model.buttons[i].label) { if rearrange.clickAllowed { model.perform(.button(i)) } }
                    .buttonStyle(PillButtonStyle())
                    .hoverReport(state)
                    .transition(.opacity)
            }
        case .chat: PillChat(model: model, state: state, rearrange: rearrange).transition(.opacity)
        case .templates: TemplatesButton(model: model, size: 26).hoverReport(state).transition(.opacity)
        case .shot: ShotButton(model: model, size: 26).hoverReport(state).transition(.opacity)
        case .mic: MicButton(model: model, size: 26).hoverReport(state).transition(.opacity)
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
    @FocusState private var focused: Bool

    var body: some View {
        HStack(spacing: 10) {
            MascotIcon(activity: model.activity, size: 30).frame(width: 30, height: 30)
                .allowsHitTesting(false)
            TextField("Write to Claude", text: $state.pillDraft)
                .textFieldStyle(.plain)
                .font(.system(size: 13))
                .focused($focused)
                .onSubmit(send)
                .onExitCommand { [weak state] in state?.endTyping?() }
                .frame(maxWidth: .infinity)
            Button(action: send) { Icon(kind: .send, size: 13, lineWidth: 2.4) }
                .buttonStyle(IconButtonStyle(background: state.pillDraft.isEmpty ? Color.white.opacity(0.1) : .cbAction,
                                             foreground: .white, size: 28))
                .accessibilityLabel("Send")
        }
        .padding(.leading, 10)
        .padding(.trailing, 8)
        .frame(width: width, height: 44)
        .onAppear { DispatchQueue.main.async { focused = true } }
        .transition(.opacity)
    }

    private func send() {
        let text = state.pillDraft.trimmingCharacters(in: .whitespacesAndNewlines)
        if !text.isEmpty { model.addToQueue(text) }
        state.pillDraft = ""
        state.endTyping?()
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

    final class HandleView: NSView {
        weak var state: WidgetState?
        override func mouseDown(with event: NSEvent) { state?.pillMouseDown?(event) }
        override func mouseDragged(with event: NSEvent) { state?.pillMouseDragged?(event) }
        override func mouseUp(with event: NSEvent) { state?.pillMouseUp?(event) }
        override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
        /// Resize arrows all along the outline: ↔ at the ends, ↕ along the
        /// top and bottom, diagonal at the corners.
        override func resetCursorRects() {
            let edge = WidgetState.pillEdge, rim = WidgetState.pillRim
            let w = bounds.width, h = bounds.height
            addCursorRect(NSRect(x: 0, y: rim, width: edge, height: h - rim * 2), cursor: .resizeLeftRight)
            addCursorRect(NSRect(x: w - edge, y: rim, width: edge, height: h - rim * 2), cursor: .resizeLeftRight)
            addCursorRect(NSRect(x: edge, y: 0, width: w - edge * 2, height: rim), cursor: .resizeUpDown)
            addCursorRect(NSRect(x: edge, y: h - rim, width: w - edge * 2, height: rim), cursor: .resizeUpDown)
            // y up here: bottom-left and top-right share a diagonal.
            let rising = Self.diagonal("_windowResizeNorthEastSouthWestCursor")
            let falling = Self.diagonal("_windowResizeNorthWestSouthEastCursor")
            addCursorRect(NSRect(x: 0, y: 0, width: edge, height: rim), cursor: rising)
            addCursorRect(NSRect(x: w - edge, y: h - rim, width: edge, height: rim), cursor: rising)
            addCursorRect(NSRect(x: 0, y: h - rim, width: edge, height: rim), cursor: falling)
            addCursorRect(NSRect(x: w - edge, y: 0, width: edge, height: rim), cursor: falling)
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
        return v
    }
    func updateNSView(_ nsView: HandleView, context: Context) {}
}
