import SwiftUI
import UniformTypeIdentifiers

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
    /// Set by WidgetController: the pill hands its mouse over for moving,
    /// resizing and clicks.
    var pillMouseDown: ((NSEvent) -> Void)?
    var pillMouseDragged: ((NSEvent) -> Void)?
    var pillMouseUp: ((NSEvent) -> Void)?
    /// The pointer went over (true) or off a control on the pill.
    var controlHover: ((Bool) -> Void)?
    /// A click on the pill's numbers: open the panel.
    var openPanel: (() -> Void)?
    /// Dragging the pill's items onto each other.
    let pillRearrange = Rearrange(space: "pill")
    /// Writing in the pill's chat: everything else steps aside for the text.
    @Published var pillTyping = false
    @Published var pillDraft = ""
    /// Set by WidgetController: the window takes the keyboard for the chat
    /// and gives it back.
    var startTyping: (() -> Void)?
    var endTyping: (() -> Void)?
    /// While the pill's outline is pulled: its size, following the pointer.
    @Published var pillEditSize: CGSize?
    /// The pointer is on the pill: its outline shows faintly.
    @Published var pillHover = false
    /// Files are being dragged over the widget.
    @Published var dropHover = false
    /// Docked in the notch (or dragged over it, about to dock): the pill is
    /// the black island, the panel grows out of it.
    @Published var notched = false
    /// The camera's width (0 on Macs without a notch: one is drawn) and the
    /// notch's height.
    @Published var notchWidth: CGFloat = 0
    @Published var notchHeight: CGFloat = 32
    /// Goes up by one to put the cursor in the panel's message field.
    @Published var focusMessage = 0
    /// How close to an end a press resizes instead of moving.
    static let pillEdge: CGFloat = 14
    /// How close to the top or bottom of the outline.
    static let pillRim: CGFloat = 7

    /// Which sides a press on the pill's outline pulls — always one end and
    /// the top or bottom, so one drag sizes it both ways (free form): `h`
    /// −1 left, 1 right (the nearer end); `v` 1 top (only from the band
    /// along the top), else −1 bottom. Nil: not on the outline. `p` in
    /// window points, y up.
    static func pillRim(_ p: NSPoint, in size: NSSize) -> (h: Int, v: Int)? {
        let onRim = p.x <= pillEdge || p.x >= size.width - pillEdge || p.y <= pillRim || p.y >= size.height - pillRim
        guard onRim else { return nil }
        return (p.x > size.width / 2 ? 1 : -1, p.y >= size.height - pillRim ? 1 : -1)
    }
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

/// The open widget's background: glass, or — docked in the notch — black,
/// flush with the top of the screen and clear of the camera, so the panel
/// looks grown out of the notch.
struct PanelMaterial: ViewModifier {
    @Environment(\.cbNotch) private var notch

    @ViewBuilder func body(content: Content) -> some View {
        if let notch {
            content
                .padding(.top, max(0, notch - 4))
                .padding(.horizontal, NotchView.shoulder)
                .background(NotchShape(radius: 22).fill(Color.black))
        } else {
            content.modifier(Glass(radius: 18))
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
    /// The bar's thickness.
    var height: CGFloat = 4
    var track = Color.white.opacity(0.12)
    var color: Color? = nil
    var delay: Double = 0
    /// Upright, filling from the bottom (the column pill).
    var vertical = false
    @State private var shown: Double = 0
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.cbStill) private var still

    var body: some View {
        GeometryReader { geo in
            let f = CGFloat(min(max(shown, 0), 100) / 100)
            ZStack(alignment: vertical ? .bottom : .leading) {
                Capsule().fill(track)
                Capsule().fill(color ?? Color.meter(percent ?? 0))
                    .frame(width: vertical ? nil : geo.size.width * f, height: vertical ? geo.size.height * f : nil)
            }
        }
        .frame(width: vertical ? height : nil, height: vertical ? nil : height)
        .onAppear { animate(to: percent ?? 0, delay: delay) }
        .onChange(of: percent ?? 0) { animate(to: $0, delay: 0) }
    }

    private func animate(to value: Double, delay: Double) {
        if reduceMotion || still { shown = value; return }
        withAnimation(.cb(0.9).delay(delay)) { shown = value }
    }
}

/// The orange "waiting for you" dot, pulsing 1.4 s (still in Do not disturb).
struct PulseDot: View {
    var size: CGFloat = 8
    var still = false
    /// Orange: needs you. The subagents' list uses the working colour.
    var color = Color.cbWarning
    @State private var dim = false
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        Circle().fill(color)
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
            case .pill:
                if state.notched { NotchView(model: model, state: state) } else { PillView(model: model, state: state) }
            case .panel:
                if model.request != nil { RequestCardView(model: model, state: state) }
                else if !model.hasSession { EmptyPanel(model: model) }
                else { MainPanel(model: model, state: state) }
            case .sessions: SessionsPanel(model: model, state: state)
            }
        }
        .fixedSize()
        .overlay(dropTarget)
        // A real notch: the panel starts under the camera. A drawn one: right away.
        .environment(\.cbNotch, state.notched ? (state.notchWidth > 0 ? state.notchHeight : 8) : nil)
        .environment(\.colorScheme, .dark)
    }

    /// Files dragged over the open panel: where they'll go.
    @ViewBuilder private var dropTarget: some View {
        if state.dropHover && (state.mode == .panel || state.mode == .sessions) {
            RoundedRectangle(cornerRadius: 18, style: .continuous).fill(Color.black.opacity(0.6))
                .overlay(VStack(spacing: 6) {
                    Image(systemName: "paperclip").font(.system(size: 20))
                    Text(model.project.map { "Attach for \($0)" } ?? "Attach").font(.system(size: 13, weight: .semibold))
                    Text("Sent to its chat with your next message").font(.system(size: 11)).foregroundColor(.cbSecondary)
                }
                .foregroundColor(.cbText))
                .overlay(RoundedRectangle(cornerRadius: 18, style: .continuous)
                    .strokeBorder(Color.cbAction, style: StrokeStyle(lineWidth: 2, dash: [7, 5])))
                .allowsHitTesting(false)
                .transition(.opacity)
        }
    }
}

/// The floating widget's window content: the widget at the top center.
/// The window may be roomier for a moment while one view turns into
/// another; the widget stays put at the top.
struct WidgetWindow: View {
    @ObservedObject var model: AppModel
    @ObservedObject var state: WidgetState

    var body: some View {
        WidgetView(model: model, state: state)
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
    }
}

extension Animation {
    /// Between the panel and the sessions: a soft spring, like a sheet.
    static let cbSwap = Animation.spring(response: 0.42, dampingFraction: 0.88)
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
            .modifier(PanelMaterial())
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
    /// "model", "lines", "git", "agents", "cost".
    let id: String
    let icon: String
    let text: String
    var action: (() -> Void)? = nil
    var help = ""

    var width: CGFloat {
        ceil((text as NSString).size(withAttributes: [.font: NSFont.monospacedDigitSystemFont(ofSize: 11, weight: .regular)]).width)
            + 14 + 5 + 16 + 2
    }

    /// On the pill: icon and text, no capsule.
    var plainWidth: CGFloat {
        ceil((text as NSString).size(withAttributes: [.font: NSFont.monospacedDigitSystemFont(ofSize: 12, weight: .regular)]).width)
            + 14 + 4 + 3
    }

    static let ids = ["model", "lines", "git", "agents", "cost"]

    /// The metrics that are on and known, in the owner's order.
    static func list(_ model: AppModel) -> [Metric] {
        let on = Set(model.config.metrics)
        var items: [Metric] = []
        if on.contains("model"), let name = model.modelName {
            items.append(Metric(id: "model", icon: "cpu", text: name + (model.effort.map { " · \($0)" } ?? ""),
                                // Codex switches models its own way: no Claude picker there.
                                action: model.agentName != nil ? nil : { [weak model] in
                                    withAnimation(.cb(0.24)) { model?.pickingModel.toggle(); model?.showingAgents = false }
                                },
                                help: "Switch the model or effort"))
        }
        if on.contains("lines") {
            items.append(Metric(id: "lines", icon: "plus.forwardslash.minus", text: "+\(model.linesAdded) −\(model.linesRemoved)"))
        }
        if on.contains("git"), let b = model.branch {
            items.append(Metric(id: "git", icon: "arrow.triangle.branch", text: b))
        }
        if on.contains("agents") {
            items.append(Metric(id: "agents", icon: "person.2", text: "\(model.agents) subagent\(model.agents == 1 ? "" : "s")",
                                action: { [weak model] in
                                    withAnimation(.cb(0.24)) { model?.showingAgents.toggle(); model?.pickingModel = false }
                                },
                                help: "Which subagents are working"))
        }
        if on.contains("cost"), model.isAPI, let c = model.cost {
            items.append(Metric(id: "cost", icon: "dollarsign.circle", text: String(format: "$%.2f", c)))
        }
        return items.sorted { model.rank("metric:" + $0.id) < model.rank("metric:" + $1.id) }
    }
}

/// A metric as a small labelled chip, so several never run together. On
/// the pill (`plain`) just the icon and the text: the pill is busy enough.
struct MetricChip: View {
    let metric: Metric
    var plain = false
    @Environment(\.clickGate) private var gate

    var body: some View {
        let label = HStack(spacing: plain ? 4 : 5) {
            Image(systemName: metric.icon).font(.system(size: 10)).frame(width: 14)
            Text(metric.text).lineLimit(1).fixedSize()
        }
        .font(.system(size: plain ? 12 : 11).monospacedDigit())
        .foregroundColor(.cbSecondary)
        .padding(.horizontal, plain ? 0 : 8)
        .frame(height: 22)
        .background(Capsule().fill(Color.white.opacity(plain ? 0 : 0.06)))
        if let action = metric.action {
            Button { if gate() { action() } } label: { label }.buttonStyle(.plain).help(metric.help)
        } else {
            label.contentShape(Capsule())
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
    @FocusState private var typing: Bool
    @StateObject private var toolsRearrange = Rearrange(space: "panel-tools")
    @StateObject private var buttonsRearrange = Rearrange(space: "panel-buttons")

    private static let chrome: CGFloat = 12 + 8 + 4
    /// The text field never gets narrower than this.
    private static let fieldMin: CGFloat = 170
    /// Inside the message box.
    private static let boxPad: CGFloat = 8

    /// The panel grows with what it holds (owner's request, 17.10): wide
    /// enough for the metrics row and the buttons in a row, up to 640 pt;
    /// past that they wrap onto more rows instead of crowding.
    private var panelWidth: CGFloat {
        let tools = toolWidths
        let toolsRow = tools.reduce(0, +) + 8 * CGFloat(max(0, tools.count - 1)) + Self.chrome
        let buttons = buttonWidths
        let field = model.config.taskQueue ? Self.fieldMin + 6 + 24 + 6 : 0
        let buttonsRow = field + buttons.reduce(0, +) + 6 * CGFloat(max(0, buttons.count - 1)) + Self.chrome + Self.boxPad * 2 + 4
        return min(640, max(420, toolsRow, buttonsRow))
    }

    private var showTemplates: Bool { model.config.templatesEnabled && !model.config.templates.isEmpty }

    /// Templates · screenshot · mic, after the metrics.
    private var extras: [String] {
        (showTemplates ? ["templates"] : []) + (model.config.screenshot ? ["shot"] : [])
            + (model.config.widgetHides.contains("mic") ? [] : ["mic"])
    }

    /// The metrics row: metrics and templates · screenshot · mic, in the
    /// owner's order (drag one onto another to swap them).
    private func tools(_ order: [String]) -> [(id: String, width: CGFloat)] {
        (Metric.list(model).map { (id: "metric:" + $0.id, width: $0.width) } + extras.map { (id: $0, width: CGFloat(24)) })
            .sorted { (order.firstIndex(of: $0.id) ?? .max) < (order.firstIndex(of: $1.id) ?? .max) }
    }
    private var toolWidths: [CGFloat] { tools(model.itemIDs).map(\.width) }
    /// The buttons (index into model.buttons), in `order`.
    private func buttons(_ order: [String]) -> [(id: String, width: CGFloat, index: Int)] {
        model.buttons.indices.map { (id: "button:" + model.buttons[$0].label,
                                     width: max(56, Self.textWidth(model.buttons[$0].label, 12) + 24), index: $0) }
            .sorted { (order.firstIndex(of: $0.id) ?? .max) < (order.firstIndex(of: $1.id) ?? .max) }
    }
    private var buttonWidths: [CGFloat] { buttons(model.itemIDs).map(\.width) }

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
            // What Settings → Widget leaves on.
            let showsSession = !model.config.widgetHides.contains("session")
            let showsContext = model.config.pillShows.contains("context")
            if showsSession || showsContext {
                HStack(alignment: .top, spacing: 16) {
                    if showsSession {
                        MeterBlock(title: "Session", percent: model.sessionPercent,
                                   caption: model.config.pillShows.contains("reset") ? model.resetLong.map { "Resets in \($0)" } : nil)
                    }
                    if showsContext {
                        MeterBlock(title: "Context", percent: model.contextPercent, caption: tokens, delay: 0.12)
                    }
                }
                .padding(.trailing, 4)
            }
            if !tools(model.itemIDs).isEmpty { toolRows(inner: inner) }
            if model.pickingModel { ModelPicker(model: model).padding(.trailing, 4) }
            if model.showingAgents { AgentsList(model: model).padding(.trailing, 4) }
            if model.config.taskQueue || !model.buttons.isEmpty || !model.attachments.isEmpty {
                messageBox(inner: inner)
                    .padding(.trailing, 4)
            }
        }
        .animation(.cb(0.28), value: width)
        // Files just dropped: the cursor waits in the field for a message.
        .onChange(of: state.focusMessage) { _ in if model.config.taskQueue { typing = true } }
    }

    private var header: some View {
        HStack(spacing: 8) {
            if !state.hidesHeaderCharacter {
                MascotIcon(activity: model.activity, size: 24).frame(width: 24, height: 24)
            }
            Text(model.statusTitle).font(.system(size: 13, weight: .semibold)).foregroundColor(.cbText)
            if let project = model.project {
                Text([project, model.agentName].compactMap { $0 }.joined(separator: " · "))
                    .font(.system(size: 12)).foregroundColor(.cbSecondary).lineLimit(1)
            }
            Spacer(minLength: 0)
            if model.config.sessionsList {
                Button {
                    withAnimation(.cbSwap) { state.mode = .sessions }
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

    /// The metrics, then templates · screenshot · mic, wrapping if needed;
    /// drag one onto another to swap them.
    private func toolRows(inner: CGFloat) -> some View {
        let metrics = Metric.list(model)
        let items = tools(toolsRearrange.order(model.itemIDs))
        let board = flowSlots(items, width: inner, rowHeight: 24, gap: 8, rowGap: 6)
        return RearrangeBoard(ids: items.map(\.id), slots: board.slots, size: board.size, rearrange: toolsRearrange,
                              commit: { model.swapItems($0, $1) }) { id in
            if let m = metrics.first(where: { "metric:" + $0.id == id }) {
                MetricChip(metric: m)
            } else if id == "templates" {
                TemplatesButton(model: model, size: 24)
            } else if id == "shot" {
                ShotButton(model: model, size: 24)
            } else {
                MicButton(model: model, size: 24)
            }
        }
    }

    /// Where a message is written: one line with the text field and the
    /// buttons after it (owner's request, 18.10). While you type, the
    /// buttons step back and can't be clicked by accident. Drag a button
    /// onto another to swap them.
    private func messageBox(inner: CGFloat) -> some View {
        let boxInner = inner - 4 - Self.boxPad * 2
        let field = model.config.taskQueue
        let items = buttons(buttonsRearrange.order(model.itemIDs))
        let index = Dictionary(items.map { ($0.id, $0.index) }, uniquingKeysWith: { a, _ in a })
        // As many buttons as fit after the field go on its line; the rest wrap below.
        let room = boxInner - (field ? Self.fieldMin + 6 + 24 + 6 : 0)
        var firstCount = 0
        var used: CGFloat = 0
        for b in items {
            let add = (firstCount == 0 ? 0 : 6) + b.width
            guard used + add <= room else { break }
            used += add
            firstCount += 1
        }
        let fieldWidth = field ? boxInner - used - (firstCount > 0 ? 6 : 0) - 6 - 24 : 0
        var slots: [String: CGRect] = [:]
        var x = field ? fieldWidth + 6 : 0
        for b in items.prefix(firstCount) {
            slots[b.id] = CGRect(x: x, y: 0, width: b.width, height: 26)
            x += b.width + 6
        }
        let rest = flowSlots(items.dropFirst(firstCount).map { (id: $0.id, width: $0.width) },
                             width: boxInner, rowHeight: 26, gap: 6, rowGap: 6)
        let restTop: CGFloat = firstCount > 0 || field ? 32 : 0
        for (id, r) in rest.slots { slots[id] = r.offsetBy(dx: 0, dy: restTop) }
        let height = items.count > firstCount ? restTop + rest.size.height : 26
        let busy = typing || !queueDraft.isEmpty
        let sendable = !queueDraft.isEmpty || !model.attachments.isEmpty
        return VStack(alignment: .leading, spacing: 8) {
            if field && !model.queue.isEmpty { queueList }
            if !model.attachments.isEmpty { attachmentRows(width: boxInner, field: field) }
            ZStack(alignment: .topLeading) {
                if field {
                    TextField(model.attachments.isEmpty ? "Queue for after this reply" : "Add a message, or just send",
                              text: $queueDraft)
                        .textFieldStyle(.plain).font(.system(size: 12))
                        .padding(.horizontal, 4)
                        .frame(width: max(0, fieldWidth), height: 26)
                        .focused($typing)
                        .onSubmit(addToQueue)
                        .onExitCommand { typing = false }
                    Button(action: addToQueue) { Icon(kind: .send, size: 13, lineWidth: 2.4) }
                        .buttonStyle(IconButtonStyle(background: sendable ? .cbAction : Color.white.opacity(0.1),
                                                     foreground: .white, size: 24))
                        .accessibilityLabel("Add to queue")
                        .offset(x: boxInner - 24, y: 1)
                }
                RearrangeBoard(ids: items.map(\.id), slots: slots, size: CGSize(width: boxInner, height: height),
                               rearrange: buttonsRearrange, commit: { model.swapItems($0, $1) }) { id in
                    if let i = index[id] {
                        Button(model.buttons[i].label) { if buttonsRearrange.clickAllowed { model.perform(.button(i)) } }
                            .buttonStyle(ComposerButtonStyle())
                            .disabled(busy)
                            .opacity(busy ? 0.35 : 1)
                            .animation(.easeOut(duration: 0.15), value: busy)
                    }
                }
            }
            .frame(width: boxInner, height: height, alignment: .topLeading)
        }
        .padding(Self.boxPad)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(RoundedRectangle(cornerRadius: 12, style: .continuous).fill(Color.black.opacity(0.25)))
        .overlay(RoundedRectangle(cornerRadius: 12, style: .continuous)
            .strokeBorder(typing ? Color.cbAction.opacity(0.6) : Color.white.opacity(0.12), lineWidth: typing ? 1 : 0.5))
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

    /// The dropped files as small chips (× takes one off). With no message
    /// field, Insert after them types them into the chat right away; with
    /// one, Send takes them along.
    private func attachmentRows(width: CGFloat, field: Bool) -> some View {
        let chips = model.attachments.map { (id: $0, width: AttachmentChip.width($0)) }
        let insertID = "\u{1}insert"
        let insertWidth = max(56, Self.textWidth("Insert", 12) + 28)
        let board = flowSlots(chips + (field ? [] : [(id: insertID, width: insertWidth)]), width: width,
                              rowHeight: 24, gap: 6, rowGap: 6)
        let insert = board.slots[insertID] ?? .zero
        return ZStack(alignment: .topLeading) {
            ForEach(model.attachments, id: \.self) { path in
                let slot = board.slots[path] ?? .zero
                AttachmentChip(path: path) { model.removeAttachment(path) }
                    .frame(width: slot.width, height: 24)
                    .offset(x: slot.minX, y: slot.minY)
                    .transition(.scale(scale: 0.85).combined(with: .opacity))
            }
            if !field {
                Button("Insert") { model.insertAttachments() }
                    .buttonStyle(ComposerButtonStyle(height: 24))
                    .disabled(!model.chatInFront)
                    .opacity(model.chatInFront ? 1 : 0.4)
                    .help(model.chatInFront ? "Type the paths into the chat now, without Enter"
                          : "Open \(model.project ?? "its") chat to insert them")
                    .frame(width: insert.width, height: 24)
                    .offset(x: insert.minX, y: insert.minY)
            }
        }
        .frame(width: width, height: board.size.height, alignment: .topLeading)
        .animation(.cb(0.22), value: model.attachments)
    }

    private func addToQueue() {
        let text = queueDraft.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty || !model.attachments.isEmpty else { return }
        model.addToQueue(text)
        queueDraft = ""
        typing = false
    }

    private var tokens: String? {
        guard let i = model.tokensIn, let o = model.tokensOut else { return nil }
        return "\(AppModel.compact(i)) in · \(AppModel.compact(o)) out"
    }
}

/// Model and effort, picked right in the panel (owner's request, 19.10): a
/// tap types /model or /effort into Claude's chat, like a button. The pick
/// lights up at once; the panel's model line follows when Claude confirms.
struct ModelPicker: View {
    @ObservedObject var model: AppModel
    @State private var pendingModel: String?
    @State private var pendingEffort: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            row("Model", ModelChoice.models.map { (id: $0.alias, label: $0.label) },
                selected: pendingModel ?? ModelChoice.alias(of: model.modelId)) { alias in
                pendingModel = alias
                model.setModel(alias)
                forget { pendingModel = nil }
            }
            row("Effort", ModelChoice.efforts.map { (id: $0, label: $0) }, selected: pendingEffort ?? model.effort) { level in
                pendingEffort = level
                model.setEffort(level)
                forget { pendingEffort = nil }
            }
        }
        .padding(8)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(RoundedRectangle(cornerRadius: 12, style: .continuous).fill(Color.black.opacity(0.25)))
        .overlay(RoundedRectangle(cornerRadius: 12, style: .continuous).strokeBorder(Color.white.opacity(0.12), lineWidth: 0.5))
        .onChange(of: model.modelId) { _ in pendingModel = nil }
        .onChange(of: model.effort) { _ in pendingEffort = nil }
        .transition(.opacity.combined(with: .offset(y: -4)))
    }

    /// If Claude never confirms (the chat wasn't in front), show what's real again.
    private func forget(_ clear: @escaping () -> Void) {
        DispatchQueue.main.asyncAfter(deadline: .now() + 8, execute: clear)
    }

    private func row(_ title: String, _ options: [(id: String, label: String)], selected: String?,
                     pick: @escaping (String) -> Void) -> some View {
        HStack(spacing: 8) {
            Text(title).font(.system(size: 11)).foregroundColor(.cbSecondary).frame(width: 38, alignment: .leading)
            HStack(spacing: 0) {
                ForEach(options, id: \.id) { option in
                    let on = selected == option.id
                    Button { if !on { pick(option.id) } } label: {
                        Text(option.label).font(.system(size: 11)).lineLimit(1).fixedSize()
                            .padding(.horizontal, 7)
                            .frame(height: 22)
                            .background(RoundedRectangle(cornerRadius: 6, style: .continuous).fill(on ? Color.cbAction : .clear))
                            .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .foregroundColor(on ? .white : .cbText)
                    .help(title == "Model" ? "/model \(option.id)" : "/effort \(option.id)")
                    .accessibilityAddTraits(on ? .isSelected : [])
                }
            }
            .padding(2)
            .background(RoundedRectangle(cornerRadius: 8, style: .continuous).fill(Color.white.opacity(0.06)))
            .animation(.easeOut(duration: 0.15), value: selected)
        }
    }
}

/// The subagents at work in this session (owner's request, 19.10): what
/// each was asked, what it's doing right now, and for how long.
struct AgentsList: View {
    @ObservedObject var model: AppModel
    private static let shown = 6

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            if model.agentRows.isEmpty {
                Text("No subagents are working right now")
                    .font(.system(size: 11)).foregroundColor(.cbSecondary)
                    .padding(.vertical, 4)
            }
            ForEach(Array(model.agentRows.prefix(Self.shown).enumerated()), id: \.element.id) { i, agent in
                row(agent)
                    .overlay(i > 0 ? Rectangle().fill(Color.white.opacity(0.07)).frame(height: 0.5) : nil, alignment: .top)
                    .transition(.opacity.combined(with: .offset(y: -3)))
            }
            if model.agentRows.count > Self.shown {
                Text("+\(model.agentRows.count - Self.shown) more").font(.system(size: 11)).foregroundColor(.cbSecondary)
                    .padding(.top, 4)
            }
        }
        .padding(.horizontal, 10).padding(.vertical, 6)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(RoundedRectangle(cornerRadius: 12, style: .continuous).fill(Color.black.opacity(0.25)))
        .overlay(RoundedRectangle(cornerRadius: 12, style: .continuous).strokeBorder(Color.white.opacity(0.12), lineWidth: 0.5))
        .animation(.cb(0.22), value: model.agentRows.map(\.id))
        .transition(.opacity.combined(with: .offset(y: -4)))
    }

    private func row(_ agent: AppModel.AgentRow) -> some View {
        HStack(alignment: .center, spacing: 10) {
            PulseDot(size: 6, still: model.config.doNotDisturb, color: .cbFill)
            VStack(alignment: .leading, spacing: 1) {
                HStack(spacing: 6) {
                    Text(agent.type).font(.system(size: 12, weight: .semibold)).lineLimit(1)
                    if agent.background {
                        Text("background").font(.system(size: 9)).foregroundColor(.cbSecondary)
                            .padding(.horizontal, 5).frame(height: 14)
                            .background(Capsule().fill(Color.white.opacity(0.08)))
                    }
                }
                Text(agent.task ?? "—").font(.system(size: 11)).foregroundColor(.cbSecondary).lineLimit(1)
            }
            Spacer(minLength: 8)
            VStack(alignment: .trailing, spacing: 1) {
                Text(agent.doing ?? "starting…").font(.system(size: 11).monospacedDigit())
                    .foregroundColor(agent.doing == nil ? .cbMuted : .cbText)
                    .lineLimit(1).truncationMode(.middle)
                Text(agent.elapsed).font(.system(size: 10).monospacedDigit()).foregroundColor(.cbSecondary)
            }
            .frame(maxWidth: 200, alignment: .trailing)
        }
        .padding(.vertical, 5)
        .accessibilityElement(children: .combine)
    }
}

/// A file waiting to go to Claude: its icon and name; × takes it off.
struct AttachmentChip: View {
    let path: String
    let remove: () -> Void

    static let nameMax: CGFloat = 150
    static func width(_ path: String) -> CGFloat {
        8 + 12 + 5 + min(nameMax, MainPanel.textWidth((path as NSString).lastPathComponent, 11)) + 5 + 14 + 4
    }

    var body: some View {
        HStack(spacing: 5) {
            Image(systemName: FileDrop.symbol(path)).font(.system(size: 10)).frame(width: 12)
                .foregroundColor(.cbSecondary)
            Text((path as NSString).lastPathComponent).font(.system(size: 11)).lineLimit(1).truncationMode(.middle)
                .frame(maxWidth: Self.nameMax, alignment: .leading)
            Button(action: remove) { Image(systemName: "xmark").font(.system(size: 8, weight: .bold)) }
                .buttonStyle(.plain).foregroundColor(.cbSecondary)
                .frame(width: 14, height: 14)
                .contentShape(Rectangle())
                .accessibilityLabel("Remove \((path as NSString).lastPathComponent)")
        }
        .padding(.leading, 8).padding(.trailing, 4)
        .frame(height: 24, alignment: .leading)
        .background(Capsule().fill(Color.cbAction.opacity(0.22)))
        .overlay(Capsule().strokeBorder(Color.cbAction.opacity(0.45), lineWidth: 0.5))
        .help(path)
    }
}

/// A button inside the message box: a quick reply chip.
struct ComposerButtonStyle: ButtonStyle {
    var height: CGFloat = 26

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.system(size: 12))
            .foregroundColor(.cbText)
            .lineLimit(1)
            .padding(.horizontal, 12)
            .frame(minWidth: 56, minHeight: height)
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
    /// Just the icon, no circle (the pill).
    var plain = false
    @Environment(\.clickGate) private var gate

    var body: some View {
        Button { if gate() { model.voiceToggle() } } label: {
            Icon(kind: .mic, size: size * 0.5, lineWidth: 1.8)
        }
        .buttonStyle(IconButtonStyle(background: model.listening ? .cbAction : plain ? .clear : Color.white.opacity(0.1),
                                     foreground: model.listening ? .white : plain ? .cbSecondary : .cbText, size: size))
        .help("Dictate")
        .accessibilityLabel("Dictate")
    }
}

struct ShotButton: View {
    @ObservedObject var model: AppModel
    var size: CGFloat = 32
    var plain = false
    @Environment(\.clickGate) private var gate

    var body: some View {
        Button { if gate() { model.takeScreenshot() } } label: { Image(systemName: "camera.viewfinder").font(.system(size: size * 0.44)) }
            .buttonStyle(IconButtonStyle(background: plain ? .clear : Color.white.opacity(0.1),
                                         foreground: plain ? .cbSecondary : .cbText, size: size))
            .help("Screenshot an area; its path goes to Claude")
            .accessibilityLabel("Screenshot")
    }
}

struct TemplatesButton: View {
    @ObservedObject var model: AppModel
    var size: CGFloat = 32
    var plain = false

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
        .foregroundColor(plain ? .cbSecondary : .cbText)
        .frame(width: size, height: size)
        .background(Circle().fill(Color.white.opacity(plain ? 0 : 0.1)))
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
                Button { withAnimation(.cbSwap) { state.mode = .panel } } label: { Icon(kind: .chevronLeft, lineWidth: 2.2) }
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
                        if s.waiting {
                            model.showRequest(s.id)
                            withAnimation(.cbSwap) { state.mode = .panel }
                        } else {
                            model.openSession(s.id)
                        }
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
        .modifier(PanelMaterial())
        // In from the right as the panel fades back, like a page turning.
        .transition(.asymmetric(insertion: .opacity.combined(with: .offset(x: 24)).combined(with: .scale(scale: 0.98, anchor: .top)),
                                removal: .opacity.combined(with: .offset(x: 24))))
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
