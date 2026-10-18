import SwiftUI

// The floating widget, drawn to design/Main.dc.html and design/Widget-*.dc.html.
// Sizes are in points; colors and timings come from the mockups.

enum WidgetMode { case strip, pill, panel, sessions }

final class WidgetState: ObservableObject {
    @Published var mode: WidgetMode = .pill
    /// What it collapses to: the pill, or the thin line.
    var rest: WidgetMode = .pill
    /// Set when collapsing means something else (the drawer slides away).
    var collapse: (() -> Void)?
    /// Cloud already stands on top of the island; no second one in the header.
    var hidesHeaderCharacter = false
    /// Set by WidgetController: the pill hands its mouse-downs over for dragging.
    var pillMouseDown: ((NSEvent) -> Void)?
    /// The pointer went over (true) or off a control on the pill.
    var controlHover: ((Bool) -> Void)?
    /// While the pill's edge is pulled: its width, following the pointer.
    @Published var pillEditWidth: CGFloat?
    /// The pointer is on the pill: its grips show.
    @Published var pillHover = false
    /// How close to an end a click resizes instead of moving.
    static let pillEdge: CGFloat = 14
}

extension Color {
    init(hex: UInt32, opacity: Double = 1) {
        self.init(.sRGB, red: Double((hex >> 16) & 0xFF) / 255, green: Double((hex >> 8) & 0xFF) / 255,
                  blue: Double(hex & 0xFF) / 255, opacity: opacity)
    }
    static let cbText = Color(hex: 0xF5F5F7)
    static let cbSecondary = Color(hex: 0xA1A1A6)
    static let cbMuted = Color(hex: 0x8E8E93)
    static let cbAction = Color(hex: 0x0071E3)
    static let cbWarning = Color(hex: 0xFF9F0A)
    static let cbWarningText = Color(hex: 0xFFB340)
    static let cbDeny = Color(hex: 0xFF6961)
    static let cbFill = Color(hex: 0xE5E5EA)
    static let cbHairline = Color.white.opacity(0.14)

    static func meter(_ percent: Double) -> Color {
        percent >= 90 ? Color(hex: 0xFF453A) : percent >= 70 ? .cbWarning : .cbFill
    }
}

extension Animation {
    /// cubic-bezier(.2,.8,.2,1)
    static func cb(_ duration: Double) -> Animation { .timingCurve(0.2, 0.8, 0.2, 1, duration: duration) }
}

// MARK: - Building blocks

struct MascotIcon: NSViewRepresentable {
    let activity: Activity
    let size: CGFloat
    /// Idle but up, not asleep.
    var awake = false
    /// Goes up by one per poke; each one makes it jump and smile.
    var pokes = 0

    final class Coordinator { var pokes = 0 }
    func makeCoordinator() -> Coordinator { Coordinator() }

    func makeNSView(context: Context) -> MascotView {
        context.coordinator.pokes = pokes
        return MascotView(size: size)
    }
    func updateNSView(_ view: MascotView, context: Context) {
        view.activity = activity
        view.awake = awake
        if pokes != context.coordinator.pokes {
            context.coordinator.pokes = pokes
            view.poke()
        }
    }
}

/// The widget's material: dark blur, rgba(40,40,42,0.78), 0.5 pt hairline.
struct Glass: ViewModifier {
    let radius: CGFloat
    var border = Color.cbHairline

    func body(content: Content) -> some View {
        content
            .background(
                ZStack {
                    VisualEffect(radius: radius)
                    Color(red: 40 / 255, green: 40 / 255, blue: 42 / 255).opacity(0.78)
                }
                .clipShape(RoundedRectangle(cornerRadius: radius, style: .continuous))
            )
            .overlay(RoundedRectangle(cornerRadius: radius, style: .continuous).strokeBorder(border, lineWidth: 0.5))
    }
}

/// Blur of what's behind the window, blur 28 + saturate in the mockup.
/// SwiftUI can't clip an AppKit view, so the rounded shape is a mask image
/// (which also gives the window's shadow its shape).
struct VisualEffect: NSViewRepresentable {
    var radius: CGFloat = 0

    func makeNSView(context: Context) -> NSVisualEffectView {
        let v = NSVisualEffectView()
        v.material = .hudWindow
        v.blendingMode = .behindWindow
        v.state = .active
        v.appearance = NSAppearance(named: .darkAqua)
        v.maskImage = Self.mask(radius)
        return v
    }

    func updateNSView(_ nsView: NSVisualEffectView, context: Context) {}

    static func mask(_ radius: CGFloat) -> NSImage? {
        guard radius > 0 else { return nil }
        let edge = radius * 2 + 1
        let image = NSImage(size: NSSize(width: edge, height: edge), flipped: false) { rect in
            NSColor.black.setFill()
            NSBezierPath(roundedRect: rect, xRadius: radius, yRadius: radius).fill()
            return true
        }
        image.capInsets = NSEdgeInsets(top: radius, left: radius, bottom: radius, right: radius)
        image.resizingMode = .stretch
        return image
    }
}

/// A meter bar that fills from 0 on appear and slides on change (900 ms).
struct MeterBar: View {
    let percent: Double?
    var height: CGFloat = 4
    var track = Color.white.opacity(0.12)
    var color: Color? = nil
    var delay: Double = 0
    @State private var shown: Double = 0
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        GeometryReader { geo in
            ZStack(alignment: .leading) {
                Capsule().fill(track)
                Capsule().fill(color ?? Color.meter(percent ?? 0))
                    .frame(width: geo.size.width * CGFloat(min(max(shown, 0), 100) / 100))
            }
        }
        .frame(height: height)
        .onAppear { animate(to: percent ?? 0, delay: delay) }
        .onChange(of: percent ?? 0) { animate(to: $0, delay: 0) }
    }

    private func animate(to value: Double, delay: Double) {
        if reduceMotion { shown = value; return }
        withAnimation(.cb(0.9).delay(delay)) { shown = value }
    }
}

/// The orange "waiting for you" dot, pulsing 1.4 s (still in Do not disturb).
struct PulseDot: View {
    var size: CGFloat = 8
    var still = false
    @State private var dim = false
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        Circle().fill(Color.cbWarning)
            .frame(width: size, height: size)
            .opacity(dim ? 0.35 : 1)
            .onAppear {
                guard !still && !reduceMotion else { return }
                withAnimation(.easeInOut(duration: 0.7).repeatForever(autoreverses: true)) { dim = true }
            }
            .accessibilityHidden(true)
    }
}

struct WidgetButtonStyle: ButtonStyle {
    var background = Color.white.opacity(0.08)
    var foreground = Color.cbText
    var weight: Font.Weight = .regular
    var height: CGFloat = 44
    var radius: CGFloat = 12

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.system(size: 13, weight: weight))
            .foregroundColor(foreground)
            .frame(maxWidth: .infinity, minHeight: height)
            .background(RoundedRectangle(cornerRadius: radius, style: .continuous)
                .fill(background.opacity(configuration.isPressed ? 0.6 : 1)))
            .contentShape(Rectangle())
    }
}

struct IconButtonStyle: ButtonStyle {
    var background = Color.clear
    var foreground = Color.cbSecondary
    var size: CGFloat = 44
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .foregroundColor(foreground)
            .frame(width: size, height: size)
            .background(Circle().fill(background.opacity(configuration.isPressed ? 0.6 : 1)))
            .contentShape(Circle())
    }
}

/// SVG icons from the mockups.
struct Icon: View {
    enum Kind { case chevronUp, chevronRight, chevronLeft, mic, clock, send }
    let kind: Kind
    var size: CGFloat = 16
    var lineWidth: CGFloat = 2

    var body: some View {
        Canvas { ctx, sz in
            let s = sz.width / 24
            var p = Path()
            switch kind {
            case .chevronUp: p.move(to: .init(x: 6 * s, y: 15 * s)); p.addLine(to: .init(x: 12 * s, y: 9 * s)); p.addLine(to: .init(x: 18 * s, y: 15 * s))
            case .chevronRight: p.move(to: .init(x: 9 * s, y: 6 * s)); p.addLine(to: .init(x: 15 * s, y: 12 * s)); p.addLine(to: .init(x: 9 * s, y: 18 * s))
            case .chevronLeft: p.move(to: .init(x: 15 * s, y: 6 * s)); p.addLine(to: .init(x: 9 * s, y: 12 * s)); p.addLine(to: .init(x: 15 * s, y: 18 * s))
            case .mic:
                p.addRoundedRect(in: CGRect(x: 9 * s, y: 3 * s, width: 6 * s, height: 11 * s), cornerSize: CGSize(width: 3 * s, height: 3 * s))
                p.move(to: .init(x: 5 * s, y: 11 * s))
                p.addCurve(to: .init(x: 19 * s, y: 11 * s), control1: .init(x: 5 * s, y: 20.3 * s), control2: .init(x: 19 * s, y: 20.3 * s))
                p.move(to: .init(x: 12 * s, y: 18 * s)); p.addLine(to: .init(x: 12 * s, y: 21 * s))
            case .clock:
                p.addEllipse(in: CGRect(x: 3 * s, y: 3 * s, width: 18 * s, height: 18 * s))
                p.move(to: .init(x: 12 * s, y: 7 * s)); p.addLine(to: .init(x: 12 * s, y: 12 * s)); p.addLine(to: .init(x: 15 * s, y: 14 * s))
            case .send:
                p.move(to: .init(x: 12 * s, y: 19 * s)); p.addLine(to: .init(x: 12 * s, y: 5 * s))
                p.move(to: .init(x: 6 * s, y: 11 * s)); p.addLine(to: .init(x: 12 * s, y: 5 * s)); p.addLine(to: .init(x: 18 * s, y: 11 * s))
            }
            ctx.stroke(p, with: .foreground, style: StrokeStyle(lineWidth: lineWidth * s, lineCap: .round, lineJoin: .round))
        }
        .frame(width: size, height: size)
        .accessibilityHidden(true)
    }
}

// MARK: - Root

struct WidgetView: View {
    @ObservedObject var model: AppModel
    @ObservedObject var state: WidgetState

    var body: some View {
        Group {
            switch state.mode {
            case .strip: StripView(model: model)
            case .pill: PillView(model: model, state: state)
            case .panel:
                if model.request != nil { RequestCardView(model: model, state: state) }
                else if !model.hasSession { EmptyPanel(model: model) }
                else { MainPanel(model: model, state: state) }
            case .sessions: SessionsPanel(model: model, state: state)
            }
        }
        .fixedSize()
        .environment(\.colorScheme, .dark)
    }
}

/// At rest: a 4 pt line in the state's color, under the menu bar.
struct StripView: View {
    @ObservedObject var model: AppModel
    @State private var dim = false
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    private var waiting: Bool { model.request != nil || model.activity == .wait }

    var body: some View {
        let color: Color = waiting ? .cbWarning
            : model.listening ? .cbAction
            : !model.hasSession ? Color.cbMuted.opacity(0.5)
            : model.activity == .work ? .cbFill : Color.cbMuted
        VStack(spacing: 0) {
            Capsule().fill(color).frame(width: 64, height: 4)
                .opacity(dim ? 0.35 : 1)
            Spacer(minLength: 0)
        }
        // Barely bigger than the line itself, so it isn't in the way.
        .frame(width: 72, height: 6)
        .contentShape(Rectangle())
        .onAppear(perform: pulseIfNeeded)
        .onChange(of: waiting) { _ in pulseIfNeeded() }
        .accessibilityElement()
        .accessibilityLabel("Clouding Bar: \(model.statusTitle)")
    }

    private func pulseIfNeeded() {
        guard waiting && !model.config.doNotDisturb && !reduceMotion else {
            withAnimation(.default) { dim = false }
            return
        }
        withAnimation(.easeInOut(duration: 0.7).repeatForever(autoreverses: true)) { dim = true }
    }
}

// MARK: - Pill

/// What the pill shows for a given width, in a fixed order: the character,
/// then the numbers (session, context, reset, cost), their bars, the
/// metrics, the buttons, then templates · screenshot · mic. Pulling the
/// pill's edge sets the width; it shows the longest run that fits.
struct PillLayout {
    enum Part: Hashable {
        case session, context, reset, cost, sessionBar, contextBar
        case metric(Int), button(Int), templates, shot, mic
    }

    static let pad: CGFloat = 10 + 16
    static let gap: CGFloat = 14
    static let character: CGFloat = 30
    /// The character alone: a circle.
    static let minWidth: CGFloat = 44
    static let barWidth: CGFloat = 44

    let parts: [(part: Part, width: CGFloat)]

    init(model: AppModel) {
        func text(_ t: String, _ size: CGFloat = 13) -> CGFloat {
            ceil((t as NSString).size(withAttributes: [.font: NSFont.monospacedDigitSystemFont(ofSize: size, weight: .regular)]).width)
        }
        let shows = model.config.pillShows
        var list: [(Part, CGFloat)] = [(.session, text(Self.percent(model.sessionPercent)))]
        if shows.contains("context"), let c = model.contextPercent {
            list.append((.context, text("ctx", 11) + 6 + text(Self.percent(c))))
        }
        if shows.contains("reset"), let r = model.resetShort { list.append((.reset, 12 + 4 + text(r))) }
        if shows.contains("cost"), let c = model.cost { list.append((.cost, text(String(format: "$%.2f", c)))) }
        // Bars widen the groups above; no gap of their own.
        list.append((.sessionBar, Self.barWidth + 8 - Self.gap))
        if list.contains(where: { $0.0 == .context }) { list.append((.contextBar, Self.barWidth + 6 - Self.gap)) }
        for (i, m) in Metric.list(model).enumerated() { list.append((.metric(i), m.width)) }
        for (i, b) in model.buttons.enumerated() { list.append((.button(i), max(44, MainPanel.textWidth(b.label, 12) + 20))) }
        if model.config.templatesEnabled && !model.config.templates.isEmpty { list.append((.templates, 26)) }
        if model.config.screenshot { list.append((.shot, 26)) }
        list.append((.mic, 26))
        parts = list.map { (part: $0.0, width: $0.1) }
    }

    static func percent(_ p: Double?) -> String { p.map { "\(Int($0.rounded()))%" } ?? "—" }

    /// Everything shown: the widest the pill gets.
    var maxWidth: CGFloat { width(of: parts.count) }

    /// The pill's width with the first `n` parts.
    func width(of n: Int) -> CGFloat {
        n == 0 ? Self.minWidth
            : Self.pad + Self.character + parts.prefix(n).reduce(0) { $0 + Self.gap + $1.width }
    }

    /// How many parts fit within `budget`.
    func count(within budget: CGFloat) -> Int {
        var n = 0
        while n < parts.count && width(of: n + 1) <= budget { n += 1 }
        return n
    }

    func shown(within budget: CGFloat) -> Set<Part> { Set(parts.prefix(count(within: budget)).map(\.part)) }
}

struct PillView: View {
    @ObservedObject var model: AppModel
    @ObservedObject var state: WidgetState

    private var editing: Bool { state.pillEditWidth != nil }

    var body: some View {
        let layout = PillLayout(model: model)
        let budget = state.pillEditWidth ?? model.pillBudget
        let shown = layout.shown(within: budget)
        let special = model.listening || model.request != nil || !model.hasSession
        let iconOnly = !special && shown.isEmpty
        content(shown: shown, iconOnly: iconOnly, special: special)
            .lineLimit(1)
            .fixedSize() // numbers never wrap or squeeze
            .font(.system(size: 13).monospacedDigit())
            .foregroundColor(.cbText)
            .padding(.leading, iconOnly ? 7 : 10)
            .padding(.trailing, iconOnly ? 7 : 16)
            // While its edge is pulled, the pill follows the pointer exactly.
            .frame(width: editing && !special ? max(PillLayout.minWidth, state.pillEditWidth!) : nil,
                   height: 44, alignment: .leading)
            .clipShape(Capsule())
            .background(PillDragHandle(state: state))
            .modifier(Glass(radius: 22, border: model.request != nil ? Color.cbWarning.opacity(0.5)
                                : editing ? Color.cbAction : .cbHairline))
            .overlay(grips(editing: editing))
            .animation(.cb(0.2), value: shown.count)
            .transition(.scale(scale: 0.9).combined(with: .opacity))
            .accessibilityElement(children: .contain)
            .accessibilityLabel("Clouding Bar")
    }

    /// Edit mode: a blue outline and a grip at each end.
    @ViewBuilder private func grips(editing: Bool) -> some View {
        if editing || state.pillHover {
            HStack {
                grip
                Spacer(minLength: 0)
                grip
            }
            .padding(.horizontal, 3)
            .opacity(editing ? 1 : 0.5)
            .allowsHitTesting(false)
            .transition(.opacity)
        }
    }

    private var grip: some View {
        Capsule().fill(editing ? Color.cbAction : Color.white.opacity(0.5)).frame(width: 3, height: 16)
    }

    @ViewBuilder private func content(shown: Set<PillLayout.Part>, iconOnly: Bool, special: Bool) -> some View {
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
            .allowsHitTesting(false)
        } else if model.request != nil {
            HStack(spacing: 10) {
                MascotIcon(activity: .wait, size: 30).frame(width: 30, height: 30)
                Text(model.statusTitle)
                PulseDot(still: model.config.doNotDisturb)
            }
            .allowsHitTesting(false)
        } else if !model.hasSession {
            HStack(spacing: 10) {
                MascotIcon(activity: .sleep, size: 30).frame(width: 30, height: 30)
                Text(PillLayout.percent(model.sessionPercent)).foregroundColor(.cbSecondary)
            }
            .allowsHitTesting(false)
        } else if iconOnly {
            MascotIcon(activity: model.activity, size: 30).frame(width: 30, height: 30)
                .allowsHitTesting(false)
        } else {
            HStack(spacing: PillLayout.gap) {
                MascotIcon(activity: model.activity, size: 30).frame(width: 30, height: 30)
                    .allowsHitTesting(false)
                numbers(shown)
                    .allowsHitTesting(false)
                controls(shown)
            }
        }
    }

    @ViewBuilder private func numbers(_ shown: Set<PillLayout.Part>) -> some View {
        HStack(spacing: 8) {
            if shown.contains(.sessionBar) {
                MeterBar(percent: model.sessionPercent, height: 3, track: .white.opacity(0.14))
                    .frame(width: PillLayout.barWidth)
                    .transition(.opacity)
            }
            Text(PillLayout.percent(model.sessionPercent))
        }
        if shown.contains(.context), let c = model.contextPercent {
            HStack(spacing: 6) {
                Text("ctx").font(.system(size: 11)).foregroundColor(.cbSecondary)
                if shown.contains(.contextBar) {
                    MeterBar(percent: c, height: 3, track: .white.opacity(0.14), delay: 0.12)
                        .frame(width: PillLayout.barWidth)
                        .transition(.opacity)
                }
                Text(PillLayout.percent(c))
            }
            .transition(.opacity)
        }
        if shown.contains(.reset), let r = model.resetShort {
            HStack(spacing: 4) {
                Icon(kind: .clock, size: 12, lineWidth: 2.2).foregroundColor(.cbSecondary)
                    .accessibilityLabel("resets in")
                Text(r)
            }
            .transition(.opacity)
        }
        if shown.contains(.cost), let cost = model.cost {
            Text(String(format: "$%.2f", cost)).foregroundColor(.cbFill).transition(.opacity)
        }
    }

    /// Metrics and buttons, once the pill is pulled wide enough.
    @ViewBuilder private func controls(_ shown: Set<PillLayout.Part>) -> some View {
        let metrics = Metric.list(model)
        ForEach(Array(metrics.enumerated()), id: \.offset) { i, m in
            if shown.contains(.metric(i)) { MetricChip(metric: m).hoverReport(state).transition(.opacity) }
        }
        ForEach(Array(model.buttons.enumerated()), id: \.offset) { i, b in
            if shown.contains(.button(i)) {
                Button(b.label) { model.perform(.button(i)) }
                    .buttonStyle(PillButtonStyle())
                    .hoverReport(state)
                    .transition(.opacity)
            }
        }
        if shown.contains(.templates) { TemplatesButton(model: model, size: 26).hoverReport(state).transition(.opacity) }
        if shown.contains(.shot) { ShotButton(model: model, size: 26).hoverReport(state).transition(.opacity) }
        if shown.contains(.mic) { MicButton(model: model, size: 26).hoverReport(state).transition(.opacity) }
    }
}

/// A button on the pill: a small capsule.
struct PillButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.system(size: 12))
            .foregroundColor(.cbText)
            .lineLimit(1)
            .padding(.horizontal, 10)
            .frame(minWidth: 44, minHeight: 26)
            .background(Capsule().fill(Color.white.opacity(configuration.isPressed ? 0.2 : 0.1)))
            .contentShape(Capsule())
    }
}

extension View {
    /// Tells the widget the pointer is over a control, so hovering it
    /// doesn't open the panel underneath.
    func hoverReport(_ state: WidgetState) -> some View {
        onHover { [weak state] inside in state?.controlHover?(inside) }
    }
}

/// Lets the pill be dragged (and clicked); its ends resize it. It lies
/// under the pill's content, so the pill's buttons get their own clicks.
struct PillDragHandle: NSViewRepresentable {
    let state: WidgetState

    final class HandleView: NSView {
        var onMouseDown: ((NSEvent) -> Void)?
        override func mouseDown(with event: NSEvent) { onMouseDown?(event) }
        override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
        /// ↔ over the ends: pull them to show more or less.
        override func resetCursorRects() {
            let edge = WidgetState.pillEdge
            addCursorRect(NSRect(x: 0, y: 0, width: edge, height: bounds.height), cursor: .resizeLeftRight)
            addCursorRect(NSRect(x: bounds.width - edge, y: 0, width: edge, height: bounds.height), cursor: .resizeLeftRight)
        }
        override func setFrameSize(_ newSize: NSSize) {
            super.setFrameSize(newSize)
            window?.invalidateCursorRects(for: self)
        }
    }

    func makeNSView(context: Context) -> HandleView {
        let v = HandleView()
        v.onMouseDown = { [weak state] in state?.pillMouseDown?($0) }
        return v
    }
    func updateNSView(_ nsView: HandleView, context: Context) {}
}

// MARK: - Panels

struct PanelChrome<Content: View>: View {
    var padding = EdgeInsets(top: 14, leading: 14, bottom: 14, trailing: 14)
    var spacing: CGFloat = 16
    var width: CGFloat = 320
    @ViewBuilder let content: Content

    var body: some View {
        VStack(alignment: .leading, spacing: spacing) { content }
            .padding(padding)
            .frame(width: width)
            .modifier(Glass(radius: 18))
            .transition(.asymmetric(insertion: .opacity.combined(with: .scale(scale: 0.97, anchor: .top))
                                        .combined(with: .offset(y: -6)),
                                    removal: .opacity))
    }
}

struct PanelHeader: View {
    let activity: Activity
    let title: String
    let subtitle: String?
    var waiting = false
    var dnd = false
    var onCollapse: (() -> Void)?

    var body: some View {
        HStack(spacing: 10) {
            MascotIcon(activity: activity, size: 32).frame(width: 32, height: 32)
            VStack(alignment: .leading, spacing: 1) {
                Text(title).font(.system(size: 13, weight: .semibold)).foregroundColor(.cbText)
                if let subtitle { Text(subtitle).font(.system(size: 12)).foregroundColor(.cbSecondary) }
            }
            Spacer(minLength: 0)
            if waiting { PulseDot(still: dnd) }
            if let onCollapse {
                Button(action: onCollapse) { Icon(kind: .chevronUp) }
                    .buttonStyle(IconButtonStyle())
                    .accessibilityLabel("Collapse")
            }
        }
    }
}

struct MeterBlock: View {
    let title: String
    let percent: Double?
    let caption: String?
    var delay: Double = 0

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                Text(title).foregroundColor(.cbSecondary)
                Spacer()
                Text(percent.map { "\(Int($0.rounded()))%" } ?? "—").fontWeight(.semibold).monospacedDigit()
                    .foregroundColor(.cbText)
            }
            .font(.system(size: 12))
            MeterBar(percent: percent, delay: delay)
            if let caption {
                Text(caption).font(.system(size: 11).monospacedDigit()).foregroundColor(.cbSecondary)
            }
        }
        .accessibilityElement(children: .combine)
    }
}

/// One metric of the open panel (and the wide pill): model · effort,
/// ±lines, branch, subagents, cost — whichever are on.
struct Metric {
    let icon: String
    let text: String
    var action: (() -> Void)? = nil
    var help = ""

    var width: CGFloat {
        ceil((text as NSString).size(withAttributes: [.font: NSFont.monospacedDigitSystemFont(ofSize: 11, weight: .regular)]).width)
            + 14 + 5 + 16 + 2
    }

    static func list(_ model: AppModel) -> [Metric] {
        let on = Set(model.config.metrics)
        var items: [Metric] = []
        if on.contains("model"), let name = model.modelName {
            items.append(Metric(icon: "cpu", text: name + (model.effort.map { " · \($0)" } ?? ""),
                                action: model.changeModel, help: "Change the model (/model)"))
        }
        if on.contains("lines") {
            items.append(Metric(icon: "plus.forwardslash.minus", text: "+\(model.linesAdded) −\(model.linesRemoved)"))
        }
        if on.contains("git"), let b = model.branch {
            items.append(Metric(icon: "arrow.triangle.branch", text: b))
        }
        if on.contains("agents") {
            items.append(Metric(icon: "person.2", text: "\(model.agents) subagent\(model.agents == 1 ? "" : "s")"))
        }
        if on.contains("cost"), model.isAPI, let c = model.cost {
            items.append(Metric(icon: "dollarsign.circle", text: String(format: "$%.2f", c)))
        }
        return items
    }
}

/// A metric as a small labelled chip, so several never run together.
struct MetricChip: View {
    let metric: Metric

    var body: some View {
        let label = HStack(spacing: 5) {
            Image(systemName: metric.icon).font(.system(size: 10)).frame(width: 14)
            Text(metric.text).lineLimit(1).fixedSize()
        }
        .font(.system(size: 11).monospacedDigit())
        .foregroundColor(.cbSecondary)
        .padding(.horizontal, 8)
        .frame(height: 22)
        .background(Capsule().fill(Color.white.opacity(0.06)))
        if let action = metric.action {
            Button(action: action) { label }.buttonStyle(.plain).help(metric.help)
        } else {
            label.allowsHitTesting(false)
        }
    }
}

/// The open widget, wide and low (the owner's request, 15.10): one header
/// line, Session and Context side by side, the metrics with the mic and
/// screenshot at their end, then the message box with the buttons in it
/// (owner's request, 18.10).
struct MainPanel: View {
    @ObservedObject var model: AppModel
    @ObservedObject var state: WidgetState
    @State private var queueDraft = ""

    private static let chrome: CGFloat = 12 + 8 + 4
    /// Inside the message box.
    private static let boxPad: CGFloat = 8

    /// The panel grows with what it holds (owner's request, 17.10): wide
    /// enough for the metrics row and the buttons in a row, up to 640 pt;
    /// past that they wrap onto more rows instead of crowding.
    private var panelWidth: CGFloat {
        let tools = toolWidths
        let toolsRow = tools.reduce(0, +) + 8 * CGFloat(max(0, tools.count - 1)) + Self.chrome
        let buttons = buttonWidths
        let buttonsRow = buttons.reduce(0, +) + 6 * CGFloat(max(0, buttons.count - 1)) + Self.chrome + Self.boxPad * 2
        return min(640, max(420, toolsRow, buttonsRow))
    }

    private var showTemplates: Bool { model.config.templatesEnabled && !model.config.templates.isEmpty }

    /// Templates · screenshot · mic, after the metrics.
    private var extras: [String] { (showTemplates ? ["templates"] : []) + (model.config.screenshot ? ["shot"] : []) + ["mic"] }

    private var toolWidths: [CGFloat] { Metric.list(model).map(\.width) + extras.map { _ in 24 } }
    private var buttonWidths: [CGFloat] { model.buttons.map { max(56, Self.textWidth($0.label, 12) + 24) } }

    static func textWidth(_ text: String, _ size: CGFloat) -> CGFloat {
        ceil((text as NSString).size(withAttributes: [.font: NSFont.systemFont(ofSize: size)]).width)
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

    var body: some View {
        let width = panelWidth
        let inner = width - Self.chrome
        PanelChrome(padding: EdgeInsets(top: 8, leading: 12, bottom: 12, trailing: 8), spacing: 10, width: width) {
            header
            HStack(alignment: .top, spacing: 16) {
                MeterBlock(title: "Session", percent: model.sessionPercent,
                           caption: model.resetLong.map { "Resets in \($0)" })
                MeterBlock(title: "Context", percent: model.contextPercent, caption: tokens, delay: 0.12)
            }
            .padding(.trailing, 4)
            toolRows(inner: inner)
            messageBox(inner: inner)
                .padding(.trailing, 4)
        }
        .animation(.cb(0.28), value: width)
    }

    private var header: some View {
        HStack(spacing: 8) {
            if !state.hidesHeaderCharacter {
                MascotIcon(activity: model.activity, size: 24).frame(width: 24, height: 24)
            }
            Text(model.statusTitle).font(.system(size: 13, weight: .semibold)).foregroundColor(.cbText)
            if let project = model.project {
                Text(project).font(.system(size: 12)).foregroundColor(.cbSecondary).lineLimit(1)
            }
            Spacer(minLength: 0)
            if model.config.sessionsList {
                Button {
                    withAnimation(.cb(0.26)) { state.mode = .sessions }
                } label: {
                    HStack(spacing: 4) {
                        Text("\(model.sessions.count) session\(model.sessions.count == 1 ? "" : "s")")
                        Icon(kind: .chevronRight, size: 11, lineWidth: 2.2)
                    }
                    .font(.system(size: 12))
                    .foregroundColor(.cbSecondary)
                    .frame(height: 28)
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
            }
            Button {
                if let collapse = state.collapse { collapse() } else { withAnimation(.cb(0.22)) { state.mode = state.rest } }
            } label: { Icon(kind: .chevronUp, size: 14) }
                .buttonStyle(IconButtonStyle(size: 30))
                .accessibilityLabel("Collapse")
        }
    }

    /// The metrics, then templates · screenshot · mic, wrapping if needed.
    private func toolRows(inner: CGFloat) -> some View {
        let metrics = Metric.list(model)
        let kinds = extras
        return VStack(alignment: .leading, spacing: 6) {
            ForEach(Array(Self.rows(toolWidths, within: inner, gap: 8).enumerated()), id: \.offset) { _, row in
                HStack(spacing: 8) {
                    ForEach(row, id: \.self) { i in
                        if i < metrics.count {
                            MetricChip(metric: metrics[i])
                        } else {
                            switch kinds[i - metrics.count] {
                            case "templates": TemplatesButton(model: model, size: 24)
                            case "shot": ShotButton(model: model, size: 24)
                            default: MicButton(model: model, size: 24)
                            }
                        }
                    }
                }
            }
        }
    }

    /// Where a message is written: the queue (when on), and the buttons
    /// inside the same box, under the text.
    private func messageBox(inner: CGFloat) -> some View {
        let labels = model.buttons.map(\.label)
        let boxInner = inner - 4 - Self.boxPad * 2
        return VStack(alignment: .leading, spacing: 8) {
            if model.config.taskQueue {
                if !model.queue.isEmpty { queueList }
                HStack(spacing: 6) {
                    TextField("Queue a request for after this reply", text: $queueDraft)
                        .textFieldStyle(.plain).font(.system(size: 12))
                        .padding(.horizontal, 4).frame(height: 24)
                        .onSubmit(addToQueue)
                    Button(action: addToQueue) { Icon(kind: .send, size: 13, lineWidth: 2.4) }
                        .buttonStyle(IconButtonStyle(background: queueDraft.isEmpty ? Color.white.opacity(0.1) : .cbAction,
                                                     foreground: .white, size: 24))
                        .accessibilityLabel("Add to queue")
                }
            }
            VStack(alignment: .leading, spacing: 6) {
                ForEach(Array(Self.rows(buttonWidths, within: boxInner, gap: 6).enumerated()), id: \.offset) { _, row in
                    HStack(spacing: 6) {
                        ForEach(row, id: \.self) { i in
                            Button(labels[i]) { model.perform(.button(i)) }
                                .buttonStyle(ComposerButtonStyle())
                        }
                    }
                }
            }
        }
        .padding(Self.boxPad)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(RoundedRectangle(cornerRadius: 12, style: .continuous).fill(Color.black.opacity(0.25)))
        .overlay(RoundedRectangle(cornerRadius: 12, style: .continuous).strokeBorder(Color.white.opacity(0.12), lineWidth: 0.5))
    }

    /// Requests that go out one by one after each reply.
    private var queueList: some View {
        VStack(alignment: .leading, spacing: 4) {
            ForEach(Array(model.queue.prefix(4).enumerated()), id: \.element.id) { i, item in
                HStack(spacing: 6) {
                    Text("\(i + 1).").foregroundColor(.cbSecondary)
                    Text(item.text).lineLimit(1)
                    Spacer(minLength: 0)
                    Button { model.removeFromQueue(item.id) } label: { Image(systemName: "xmark").font(.system(size: 9)) }
                        .buttonStyle(.plain).foregroundColor(.cbSecondary)
                        .accessibilityLabel("Remove from queue")
                }
                .font(.system(size: 12))
            }
            if model.queue.count > 4 {
                Text("+\(model.queue.count - 4) more").font(.system(size: 11)).foregroundColor(.cbSecondary)
            }
        }
        .padding(.horizontal, 4)
    }

    private func addToQueue() {
        let text = queueDraft.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return }
        model.addToQueue(text)
        queueDraft = ""
    }

    private var tokens: String? {
        guard let i = model.tokensIn, let o = model.tokensOut else { return nil }
        return "\(AppModel.compact(i)) in · \(AppModel.compact(o)) out"
    }
}

/// A button inside the message box: a quick reply chip.
struct ComposerButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.system(size: 12))
            .foregroundColor(.cbText)
            .lineLimit(1)
            .padding(.horizontal, 12)
            .frame(minWidth: 56, minHeight: 26)
            .background(RoundedRectangle(cornerRadius: 8, style: .continuous)
                .fill(Color.white.opacity(configuration.isPressed ? 0.18 : 0.09)))
            .contentShape(Rectangle())
    }
}

/// Tap to dictate: the panel folds into the pill, which shows the words as
/// they come. It stops by itself after a pause, or tap the pill.
struct MicButton: View {
    @ObservedObject var model: AppModel
    var size: CGFloat = 32

    var body: some View {
        Button { model.voiceToggle() } label: {
            Icon(kind: .mic, size: size * 0.5, lineWidth: 1.8)
        }
        .buttonStyle(IconButtonStyle(background: model.listening ? .cbAction : Color.white.opacity(0.1),
                                     foreground: model.listening ? .white : .cbText, size: size))
        .help("Dictate")
        .accessibilityLabel("Dictate")
    }
}

struct ShotButton: View {
    @ObservedObject var model: AppModel
    var size: CGFloat = 32

    var body: some View {
        Button { model.takeScreenshot() } label: { Image(systemName: "camera.viewfinder").font(.system(size: size * 0.44)) }
            .buttonStyle(IconButtonStyle(background: Color.white.opacity(0.1), foreground: .cbText, size: size))
            .help("Screenshot an area; its path goes to Claude")
            .accessibilityLabel("Screenshot")
    }
}

struct TemplatesButton: View {
    @ObservedObject var model: AppModel
    var size: CGFloat = 32

    var body: some View {
        Menu {
            ForEach(model.config.templates, id: \.self) { t in
                Button(t) { model.insertTemplate(t) }
            }
        } label: {
            Image(systemName: "text.bubble").font(.system(size: size * 0.44))
        }
        .menuStyle(.borderlessButton)
        .menuIndicator(.hidden)
        .frame(width: size, height: size)
        .background(Circle().fill(Color.white.opacity(0.1)))
        .help("Templates")
        .accessibilityLabel("Templates")
    }
}

struct EmptyPanel: View {
    @ObservedObject var model: AppModel

    var body: some View {
        PanelChrome(padding: EdgeInsets(top: 20, leading: 16, bottom: 16, trailing: 16), spacing: 12) {
            VStack(spacing: 12) {
                MascotIcon(activity: .sleep, size: 56).frame(width: 56, height: 56)
                VStack(spacing: 4) {
                    Text("No Claude Code session").font(.system(size: 13, weight: .semibold))
                    Text("Start Claude Code in VS Code or Terminal.").font(.system(size: 12)).foregroundColor(.cbSecondary)
                }
                .multilineTextAlignment(.center)
                if let p = model.sessionPercent {
                    VStack(spacing: 6) {
                        HStack {
                            Text("Session" + (model.limitAge.map { " · \($0)" } ?? "")).foregroundColor(.cbSecondary)
                            Spacer()
                            Text("\(Int(p.rounded()))%").monospacedDigit().foregroundColor(Color(hex: 0xC7C7CC))
                        }
                        .font(.system(size: 12))
                        MeterBar(percent: p, color: .cbMuted)
                    }
                    .padding(.top, 12)
                    .overlay(Rectangle().fill(Color.white.opacity(0.1)).frame(height: 0.5), alignment: .top)
                }
            }
            .frame(maxWidth: .infinity)
        }
    }
}

// MARK: - Requests

struct RequestCardView: View {
    @ObservedObject var model: AppModel
    @ObservedObject var state: WidgetState
    @FocusState private var otherFocused: Bool

    var body: some View {
        if let r = model.request {
            if r.kind == .permission {
                // Wider and lower than the mockup, at the owner's request.
                PanelChrome(padding: EdgeInsets(top: 10, leading: 12, bottom: 12, trailing: 12), spacing: 10, width: 420) {
                    permission(r)
                }
            } else {
                PanelChrome(spacing: 14) { question(r) }
            }
        }
    }

    /// One line of header, the command, one row of buttons.
    @ViewBuilder private func permission(_ r: AppModel.RequestCard) -> some View {
        HStack(spacing: 8) {
            MascotIcon(activity: .wait, size: 24).frame(width: 24, height: 24)
            Text("Needs your OK").font(.system(size: 13, weight: .semibold)).foregroundColor(.cbText)
            Text([r.project, r.verb == "Run" ? "run in terminal" : r.verb.lowercased()]
                    .compactMap { $0 }.joined(separator: " · "))
                .font(.system(size: 12)).foregroundColor(.cbSecondary).lineLimit(1)
            Spacer(minLength: 0)
            PulseDot(still: model.config.doNotDisturb)
        }
        Text(r.detail)
            .font(.system(size: 12, design: .monospaced))
            .lineSpacing(2)
            .lineLimit(3)
            .foregroundColor(.cbText)
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.vertical, 8).padding(.horizontal, 10)
            .background(RoundedRectangle(cornerRadius: 9, style: .continuous).fill(Color.black.opacity(0.3)))
            .textSelection(.enabled)
        HStack(spacing: 6) {
            Button("Allow") { model.perform(.allow) }
                .buttonStyle(WidgetButtonStyle(background: .cbAction, foreground: .white, weight: .semibold,
                                               height: 32, radius: 9))
                .keyboardShortcut(.defaultAction)
                .help("Return")
            Button("Always allow") { model.perform(.always) }
                .buttonStyle(WidgetButtonStyle(height: 32, radius: 9))
            Button("Deny") { model.perform(.deny) }
                .buttonStyle(WidgetButtonStyle(foreground: .cbDeny, height: 32, radius: 9))
                .keyboardShortcut(.cancelAction)
                .help("Esc")
        }
    }

    @ViewBuilder private func question(_ r: AppModel.RequestCard) -> some View {
        PanelHeader(activity: .wait, title: "Claude asks",
                    subtitle: [r.project, r.count > 1 ? "\(r.index + 1) of \(r.count)" : nil].compactMap { $0 }.joined(separator: " · "),
                    waiting: true, dnd: model.config.doNotDisturb)
        Text(r.question).font(.system(size: 14, weight: .medium)).lineSpacing(2).foregroundColor(.cbText)
            .fixedSize(horizontal: false, vertical: true)
        VStack(spacing: 0) {
            ForEach(Array(r.options.enumerated()), id: \.offset) { i, label in
                OptionRow(label: label, description: r.descriptions.indices.contains(i) ? r.descriptions[i] : "",
                          picked: r.multiSelect ? r.picked.contains(i) : nil, delay: 0.08 + 0.04 * Double(i)) {
                    model.perform(.option(i))
                }
                .numberKey(i + 1, enabled: i < 9 && !otherFocused)
                Rectangle().fill(Color.white.opacity(0.08)).frame(height: 0.5)
            }
            HStack(spacing: 8) {
                Text("Other").font(.system(size: 13)).foregroundColor(.cbSecondary)
                TextField("", text: $model.otherDraft)
                    .textFieldStyle(.plain)
                    .font(.system(size: 13))
                    .padding(.horizontal, 10)
                    .frame(height: 36)
                    .background(RoundedRectangle(cornerRadius: 9, style: .continuous).fill(Color.black.opacity(0.25)))
                    .overlay(RoundedRectangle(cornerRadius: 9, style: .continuous).strokeBorder(Color.white.opacity(0.18), lineWidth: 0.5))
                    .focused($otherFocused)
                    .onSubmit(sendOther)
                Button(action: sendOther) { Icon(kind: .send, size: 16, lineWidth: 2.4) }
                    .buttonStyle(IconButtonStyle(background: .cbAction, foreground: .white))
                    .accessibilityLabel("Send")
            }
            .padding(.leading, 12).padding(.trailing, 8).padding(.vertical, 8)
        }
        .background(RoundedRectangle(cornerRadius: 12, style: .continuous).fill(Color.white.opacity(0.06)))
        .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
        if r.multiSelect && !r.picked.isEmpty {
            Button("Send \(r.picked.count) selected") { model.perform(.sendPicked) }
                .buttonStyle(WidgetButtonStyle(background: .cbAction, foreground: .white, weight: .semibold))
        }
        Text(r.options.isEmpty ? "Hold right ⌥ to answer by voice"
             : "1–\(min(9, r.options.count)) to pick · hold right ⌥ to answer by voice")
            .font(.system(size: 11)).foregroundColor(.cbSecondary)
    }

    private func sendOther() {
        let text = model.otherDraft.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return }
        model.answerText(text)
    }

    private var meters: String {
        "Session \(model.sessionPercent.map { "\(Int($0.rounded()))%" } ?? "—") · Context \(model.contextPercent.map { "\(Int($0.rounded()))%" } ?? "—")"
    }

    private func footer(left: String, right: String) -> some View {
        HStack {
            Text(left)
            Spacer()
            Text(right)
        }
        .font(.system(size: 11).monospacedDigit())
        .foregroundColor(.cbSecondary)
    }
}

struct OptionRow: View {
    let label: String
    let description: String
    /// nil for single choice; picked or not for multiple choice.
    let picked: Bool?
    let delay: Double
    let action: () -> Void
    @State private var shown = false
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        Button(action: action) {
            HStack(spacing: 10) {
                if let picked {
                    Image(systemName: picked ? "checkmark.circle.fill" : "circle")
                        .foregroundColor(picked ? .cbAction : .cbSecondary)
                }
                VStack(alignment: .leading, spacing: 2) {
                    title.font(.system(size: 13)).foregroundColor(.cbText)
                    if !description.isEmpty {
                        Text(description).font(.system(size: 11)).foregroundColor(.cbSecondary).lineLimit(2)
                    }
                }
                Spacer(minLength: 0)
            }
            .padding(.vertical, 8).padding(.horizontal, 12)
            .frame(minHeight: 48)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .opacity(shown ? 1 : 0)
        .offset(y: shown ? 0 : 4)
        .onAppear {
            if reduceMotion { shown = true } else { withAnimation(.easeOut(duration: 0.24).delay(delay)) { shown = true } }
        }
    }

    /// "SQLite (Recommended)" → "SQLite · recommended", as in the mockup.
    private var title: Text {
        let marker = "(Recommended)"
        if label.contains(marker) {
            let name = label.replacingOccurrences(of: marker, with: "").trimmingCharacters(in: .whitespaces)
            return Text(name) + Text(" · recommended").foregroundColor(.cbSecondary)
        }
        return Text(label)
    }
}

// MARK: - Sessions

struct SessionsPanel: View {
    @ObservedObject var model: AppModel
    @ObservedObject var state: WidgetState

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 4) {
                Button { withAnimation(.cb(0.26)) { state.mode = .panel } } label: { Icon(kind: .chevronLeft, lineWidth: 2.2) }
                    .buttonStyle(IconButtonStyle())
                    .padding(.leading, -12)
                    .accessibilityLabel("Back")
                Text("Sessions").font(.system(size: 13, weight: .semibold))
                Spacer()
                Text("Session \(model.sessionPercent.map { "\(Int($0.rounded()))%" } ?? "—")")
                    .font(.system(size: 12)).foregroundColor(.cbSecondary)
            }
            VStack(spacing: 0) {
                ForEach(model.sessions) { s in
                    Button {
                        if s.waiting { model.showRequest(s.id); state.mode = .panel } else { model.openSession(s.id) }
                    } label: { row(s) }
                    .buttonStyle(.plain)
                    Rectangle().fill(Color.white.opacity(0.08)).frame(height: 0.5)
                }
            }
            .background(RoundedRectangle(cornerRadius: 12, style: .continuous).fill(Color.white.opacity(0.06)))
            .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
            Text("Click to open its conversation · % = context")
                .font(.system(size: 11)).foregroundColor(.cbSecondary).padding(.horizontal, 2)
        }
        .foregroundColor(.cbText)
        .padding(EdgeInsets(top: 8, leading: 14, bottom: 14, trailing: 14))
        .frame(width: 320)
        .modifier(Glass(radius: 18))
        .transition(.opacity.combined(with: .offset(x: 12)))
    }

    private func row(_ s: AppModel.SessionRow) -> some View {
        HStack(spacing: 10) {
            MascotIcon(activity: s.activity, size: 28).frame(width: 28, height: 28)
            VStack(alignment: .leading, spacing: 1) {
                Text(s.name).font(.system(size: 13))
                Text(s.status).font(.system(size: 11)).foregroundColor(s.waiting ? .cbWarningText : .cbSecondary)
            }
            Spacer(minLength: 0)
            Text(s.context.map { "\(Int($0.rounded()))%" } ?? "—")
                .font(.system(size: 12).monospacedDigit())
                .foregroundColor((s.context ?? 0) >= 90 ? .cbDeny : (s.context ?? 0) >= 70 ? .cbWarningText : .cbSecondary)
        }
        .padding(.leading, 8).padding(.trailing, 12)
        .frame(height: 52)
        .background(s.waiting ? Color.cbWarning.opacity(0.10) : Color.clear)
        .contentShape(Rectangle())
    }
}

extension View {
    /// 1–9 picks an option, but not while you type in the Other field.
    @ViewBuilder func numberKey(_ n: Int, enabled: Bool) -> some View {
        if enabled {
            keyboardShortcut(KeyEquivalent(Character("\(n)")), modifiers: [])
        } else {
            self
        }
    }
}
