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

/// Drag an item onto another to swap them; the one under the pointer gets
/// a blue ring.
struct Swappable: ViewModifier {
    let id: String
    let model: AppModel
    @State private var targeted = false

    func body(content: Content) -> some View {
        content
            .onDrag { NSItemProvider(object: id as NSString) }
            .onDrop(of: [UTType.plainText], isTargeted: $targeted) { providers in
                guard let provider = providers.first else { return false }
                _ = provider.loadObject(ofClass: NSString.self) { object, _ in
                    guard let other = object as? String else { return }
                    DispatchQueue.main.async { model.swapItems(other, id) }
                }
                return true
            }
            .overlay(RoundedRectangle(cornerRadius: 13, style: .continuous)
                .strokeBorder(Color.cbAction, lineWidth: 2)
                .padding(-3)
                .opacity(targeted ? 1 : 0)
                .allowsHitTesting(false))
    }
}

extension View {
    func swappable(_ id: String, _ model: AppModel) -> some View { modifier(Swappable(id: id, model: model)) }

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

    init(model: AppModel) {
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
            let ra = model.rank(a.element.id), rb = model.rank(b.element.id)
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

    private func budget() -> (width: CGFloat, rows: Int) {
        (state.pillEditSize?.width ?? model.pillBudget,
         state.pillEditSize.map { PillLayout.rows(forHeight: $0.height) } ?? max(1, model.config.pillRows))
    }

    private func current(_ layout: PillLayout) -> CGSize {
        let b = budget()
        return layout.size(layout.count(width: b.width, rows: b.rows), width: b.width)
    }

    /// The usual pill: as many rows and as much in them as its size allows.
    private func sized(_ layout: PillLayout) -> some View {
        let b = budget()
        let n = layout.count(width: b.width, rows: b.rows)
        let items = layout.items(n)
        let shown = Set(layout.parts.prefix(n).map(\.part))
        let flow = PillLayout.flow(items.map(\.width), width: b.width)
        // While its outline is pulled, the pill follows the pointer exactly.
        let frame = state.pillEditSize.map {
            CGSize(width: max(PillLayout.minWidth, $0.width), height: max(PillLayout.height(rows: 1), $0.height))
        } ?? layout.size(n, width: b.width)
        return Group {
            if n == 0 {
                MascotIcon(activity: model.activity, size: 30).frame(width: 30, height: 30)
                    .allowsHitTesting(false)
                    .frame(width: frame.width, height: frame.height)
            } else {
                VStack(alignment: .leading, spacing: 0) {
                    ForEach(Array(flow.rows.enumerated()), id: \.offset) { r, row in
                        HStack(spacing: PillLayout.gap) {
                            if r == 0 {
                                MascotIcon(activity: model.activity, size: 30).frame(width: 30, height: 30)
                                    .allowsHitTesting(false)
                            }
                            ForEach(row, id: \.self) { i in
                                item(items[i].part, shown: shown).fixedSize().swappable(items[i].id, model)
                            }
                        }
                        .frame(height: PillLayout.rowHeight)
                    }
                }
                .lineLimit(1)
                .fixedSize()
                .padding(.leading, 10)
                .padding(.vertical, PillLayout.vPad)
                .frame(width: frame.width, height: frame.height, alignment: .topLeading)
            }
        }
        .clipShape(RoundedRectangle(cornerRadius: 22, style: .continuous))
        .animation(.cb(0.2), value: n)
        .animation(.cb(0.2), value: flow.rows.count)
        .animation(.cb(0.25), value: model.config.itemOrder)
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

    /// One item: a number (with its bar, if shown), a metric or a control.
    /// A click on a number opens the panel.
    @ViewBuilder private func item(_ part: PillLayout.Part, shown: Set<PillLayout.Part>) -> some View {
        switch part {
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
                Button(model.buttons[i].label) { model.perform(.button(i)) }
                    .buttonStyle(PillButtonStyle())
                    .hoverReport(state)
                    .transition(.opacity)
            }
        case .chat: PillChat(model: model, state: state).transition(.opacity)
        case .templates: TemplatesButton(model: model, size: 26).hoverReport(state).transition(.opacity)
        case .shot: ShotButton(model: model, size: 26).hoverReport(state).transition(.opacity)
        case .mic: MicButton(model: model, size: 26).hoverReport(state).transition(.opacity)
        case .sessionBar, .contextBar: EmptyView()
        }
    }
}

extension View {
    fileprivate func opensPanel(_ state: WidgetState) -> some View {
        contentShape(Rectangle()).onTapGesture { [weak state] in state?.openPanel?() }
    }
}

/// The pill's chat, as in the panel: a bit to click and write in, then the
/// buttons. Click the empty bit and the pill turns into the text box.
struct PillChat: View {
    @ObservedObject var model: AppModel
    @ObservedObject var state: WidgetState

    var body: some View {
        HStack(spacing: 6) {
            Text(state.pillDraft.isEmpty ? "Write…" : state.pillDraft)
                .font(.system(size: 12))
                .foregroundColor(state.pillDraft.isEmpty ? .cbMuted : .cbSecondary)
                .truncationMode(.head)
                .frame(width: PillLayout.chatField, height: 26, alignment: .leading)
                .contentShape(Rectangle())
                .onTapGesture { [weak state] in state?.startTyping?() }
                .onHover { inside in if inside { NSCursor.iBeam.push() } else { NSCursor.pop() } }
                .hoverReport(state)
                .help("Write to Claude: sent now if it's free, after this reply if not")
                .accessibilityLabel("Write to Claude")
                .accessibilityAddTraits(.isButton)
            let order = model.buttons.indices.sorted {
                model.rank("button:" + model.buttons[$0].label) < model.rank("button:" + model.buttons[$1].label)
            }
            ForEach(order, id: \.self) { i in
                Button(model.buttons[i].label) { model.perform(.button(i)) }
                    .buttonStyle(PillButtonStyle(height: 22))
                    .hoverReport(state)
                    .swappable("button:" + model.buttons[i].label, model)
            }
        }
        .padding(.leading, 8)
        .padding(.trailing, 4)
        .frame(height: 30)
        .background(RoundedRectangle(cornerRadius: 15, style: .continuous).fill(Color.black.opacity(0.25)))
        .overlay(RoundedRectangle(cornerRadius: 15, style: .continuous).strokeBorder(Color.white.opacity(0.12), lineWidth: 0.5))
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

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.system(size: 12))
            .foregroundColor(.cbText)
            .lineLimit(1)
            .padding(.horizontal, 10)
            .frame(minWidth: 44, minHeight: height)
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
